// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import '../model/document_root.dart';
import '../model/document_validator.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';
import '../objects/object_registry.dart';
import '../resources/resources.dart';
import 'contracts.dart';
import 'src/archive_adapter.dart';
import 'src/bounded_json.dart';
import 'src/manifest_codec.dart';
import 'src/record_codec.dart';

/// A lazy immutable handle for one independently verified Page record.
final class AlnotePageHandle {
  AlnotePageHandle._(this.id, this._owner, this._entry);

  /// The canonical Page UUID.
  final String id;
  final OpenedAlnotePackage _owner;
  final AlnoteManifestEntry _entry;

  /// Loads, hash-verifies, parses, and validates this Page on demand.
  OperationOutcome<DocumentPage, StructuredFailure> load({
    required CancellationToken cancellationToken,
  }) => _owner._loadPage(_entry, cancellationToken);
}

/// A lazy immutable handle for one logical resource.
final class AlnoteResourceHandle {
  AlnoteResourceHandle._(this._owner, this.entry);

  final OpenedAlnotePackage _owner;

  /// Immutable manifest metadata for the logical resource.
  final AlnoteResourceEntry entry;

  /// Loads and independently verifies exact resource bytes on demand.
  OperationOutcome<DocumentResource, StructuredFailure> load({
    required CancellationToken cancellationToken,
  }) => _owner._loadResource(entry, cancellationToken);
}

/// A staged package with eager manifest/root evidence and lazy Page/resources.
final class OpenedAlnotePackage {
  OpenedAlnotePackage._({
    required List<int> packageBytes,
    required this.manifest,
    required this.evidence,
    required this.preservation,
    required BoundedMemoryArchive archive,
    required AlnoteStorageLimits limits,
    required ObjectRegistry registry,
    required PreservedData rootRecord,
    required Map<String, PreservedData> sectionRecords,
  }) : packageBytes = List<int>.unmodifiable(List<int>.of(packageBytes)),
       _archive = archive,
       _limits = limits,
       _registry = registry,
       _rootRecord = rootRecord,
       _sectionRecords = Map<String, PreservedData>.unmodifiable(
         sectionRecords,
       );

  /// The immutable original package bytes, never modified by migration/load.
  final List<int> packageBytes;

  /// The eagerly parsed immutable manifest.
  final AlnoteManifest manifest;

  /// Redaction-safe staged-load evidence.
  final AlnoteLoadEvidence evidence;

  /// Structurally and byte-preserved safe unknown data.
  final AlnotePackagePreservation preservation;

  /// Lazy Page handles in canonical UUID order.
  late final List<AlnotePageHandle> pageHandles;

  /// Lazy logical-resource handles in canonical UUID order.
  late final List<AlnoteResourceHandle> resourceHandles;
  final BoundedMemoryArchive _archive;
  final AlnoteStorageLimits _limits;
  final ObjectRegistry _registry;
  final PreservedData _rootRecord;
  final Map<String, PreservedData> _sectionRecords;

  /// Materializes all Pages and validates one complete candidate DocumentRoot.
  ///
  /// Resource bytes remain lazy; the complete logical catalog and every known
  /// required reference are nevertheless validated by [DocumentValidator].
  OperationOutcome<DocumentRoot, StructuredFailure> materializeDocument({
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Cancelled<DocumentRoot, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    final pages = <String, DocumentPage>{};
    var layerCount = 0;
    var objectCount = 0;
    for (final handle in pageHandles) {
      final outcome = handle.load(cancellationToken: cancellationToken);
      switch (outcome) {
        case Completed<DocumentPage, StructuredFailure>(:final value):
          if (pages.containsKey(value.id.uuid.value)) {
            return Failed<DocumentRoot, StructuredFailure>(
              storageFailure('identity', 'A Page identity is duplicated.'),
            );
          }
          pages[value.id.uuid.value] = value;
          layerCount += value.layers.length;
          for (final layer in value.layers) objectCount += layer.objects.length;
        case Failed<DocumentPage, StructuredFailure>(:final failure):
          return Failed<DocumentRoot, StructuredFailure>(failure);
        case Cancelled<DocumentPage, StructuredFailure>(:final reason):
          return Cancelled<DocumentRoot, StructuredFailure>(reason);
      }
    }
    if (layerCount > _limits['alnote.storage.layer_count']) {
      return Failed<DocumentRoot, StructuredFailure>(
        storageFailure('layer_count', 'The Layer count ceiling was exceeded.'),
      );
    }
    if (objectCount > _limits['alnote.storage.object_count']) {
      return Failed<DocumentRoot, StructuredFailure>(
        storageFailure(
          'object_count',
          'The Object count ceiling was exceeded.',
        ),
      );
    }
    final sections = <String, DocumentSection>{};
    final decoder = RecordDecoder();
    for (final entry in _sectionRecords.entries) {
      final decoded = decoder.section(entry.value, pages);
      if (decoded is Err<DocumentSection, StructuredFailure>) {
        return Failed<DocumentRoot, StructuredFailure>(decoded.error);
      }
      final section = (decoded as Ok<DocumentSection, StructuredFailure>).value;
      if (sections.containsKey(section.id.uuid.value)) {
        return Failed<DocumentRoot, StructuredFailure>(
          storageFailure('identity', 'A Section identity is duplicated.'),
        );
      }
      sections[section.id.uuid.value] = section;
    }
    final catalogResult = ResourceCatalog.create(
      resourceHandles.map(
        (handle) => ResourceCatalogEntry(
          ResourceIdentity.fromUuid(_uuid(handle.entry.identity)),
        ),
      ),
    );
    if (catalogResult is Err<ResourceCatalog, StructuredFailure>) {
      return Failed<DocumentRoot, StructuredFailure>(catalogResult.error);
    }
    final decoded = decoder.document(
      record: _rootRecord,
      sections: sections,
      pages: pages,
      resources:
          (catalogResult as Ok<ResourceCatalog, StructuredFailure>).value,
    );
    if (decoded is Err<DocumentRoot, StructuredFailure>) {
      return Failed<DocumentRoot, StructuredFailure>(decoded.error);
    }
    final document = (decoded as Ok<DocumentRoot, StructuredFailure>).value;
    final report = DocumentValidator(_registry).validate(document);
    if (!report.isValid) {
      return Failed<DocumentRoot, StructuredFailure>(
        storageFailure(
          'document_validation',
          'The complete document is not valid.',
        ),
      );
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<DocumentRoot, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<DocumentRoot, StructuredFailure>(document);
  }

  /// Loads every resource and returns a complete independently verified snapshot.
  OperationOutcome<AlnotePackageSnapshot, StructuredFailure>
  materializeSnapshot({required CancellationToken cancellationToken}) {
    final documentOutcome = materializeDocument(
      cancellationToken: cancellationToken,
    );
    if (documentOutcome is Failed<DocumentRoot, StructuredFailure>) {
      return Failed<AlnotePackageSnapshot, StructuredFailure>(
        documentOutcome.failure,
      );
    }
    if (documentOutcome is Cancelled<DocumentRoot, StructuredFailure>) {
      return Cancelled<AlnotePackageSnapshot, StructuredFailure>(
        documentOutcome.reason,
      );
    }
    final resources = <DocumentResourceSnapshot>[];
    for (final handle in resourceHandles) {
      final outcome = handle.load(cancellationToken: cancellationToken);
      switch (outcome) {
        case Completed<DocumentResource, StructuredFailure>(:final value):
          resources.add(DocumentResourceSnapshot(value));
        case Failed<DocumentResource, StructuredFailure>(:final failure):
          return Failed<AlnotePackageSnapshot, StructuredFailure>(failure);
        case Cancelled<DocumentResource, StructuredFailure>(:final reason):
          return Cancelled<AlnotePackageSnapshot, StructuredFailure>(reason);
      }
    }
    final result = AlnotePackageSnapshot.create(
      version: manifest.packageVersion,
      document:
          (documentOutcome as Completed<DocumentRoot, StructuredFailure>).value,
      resources: resources,
      preservation: preservation,
    );
    return result.fold(
      onOk: Completed<AlnotePackageSnapshot, StructuredFailure>.new,
      onErr: Failed<AlnotePackageSnapshot, StructuredFailure>.new,
    );
  }

  OperationOutcome<DocumentPage, StructuredFailure> _loadPage(
    AlnoteManifestEntry entry,
    CancellationToken cancellationToken,
  ) {
    if (cancellationToken.isCancelled) {
      return Cancelled<DocumentPage, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    final verified = _readVerified(
      entry.path,
      entry.decodedByteLength,
      entry.digest,
    );
    if (verified is Err<List<int>, StructuredFailure>) {
      return Failed<DocumentPage, StructuredFailure>(verified.error);
    }
    final parsed = _json().decode(
      (verified as Ok<List<int>, StructuredFailure>).value,
    );
    if (parsed is Err<PreservedData, StructuredFailure>) {
      return Failed<DocumentPage, StructuredFailure>(parsed.error);
    }
    final page = RecordDecoder().page(
      (parsed as Ok<PreservedData, StructuredFailure>).value,
    );
    if (page is Err<DocumentPage, StructuredFailure>) {
      return Failed<DocumentPage, StructuredFailure>(page.error);
    }
    final decodedPage = (page as Ok<DocumentPage, StructuredFailure>).value;
    final pathId = entry.path.substring(
      'pages/'.length,
      entry.path.length - '.json'.length,
    );
    if (decodedPage.id.uuid.value != pathId) {
      return Failed<DocumentPage, StructuredFailure>(
        storageFailure('identity', 'A Page record identity is not valid.'),
      );
    }
    var objectCount = 0;
    for (final layer in decodedPage.layers) {
      objectCount += layer.objects.length;
    }
    if (decodedPage.layers.length > _limits['alnote.storage.layer_count']) {
      return Failed<DocumentPage, StructuredFailure>(
        storageFailure('layer_count', 'The Layer count ceiling was exceeded.'),
      );
    }
    if (objectCount > _limits['alnote.storage.object_count']) {
      return Failed<DocumentPage, StructuredFailure>(
        storageFailure(
          'object_count',
          'The Object count ceiling was exceeded.',
        ),
      );
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<DocumentPage, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<DocumentPage, StructuredFailure>(decodedPage);
  }

  OperationOutcome<DocumentResource, StructuredFailure> _loadResource(
    AlnoteResourceEntry entry,
    CancellationToken cancellationToken,
  ) {
    if (cancellationToken.isCancelled) {
      return Cancelled<DocumentResource, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    final verified = _readVerified(
      entry.path,
      entry.decodedByteLength,
      entry.digest,
    );
    if (verified is Err<List<int>, StructuredFailure>) {
      return Failed<DocumentResource, StructuredFailure>(verified.error);
    }
    final identity = ResourceIdentity.fromUuid(_uuid(entry.identity));
    final resource = DocumentResource.create(
      identity: identity,
      digest: entry.digest,
      decodedByteLength: entry.decodedByteLength,
      mediaType: entry.mediaType,
      role: entry.role,
      schemaVersion: entry.schemaVersion,
      packagePath: entry.path,
      bytes: (verified as Ok<List<int>, StructuredFailure>).value,
    );
    if (resource is Err<DocumentResource, StructuredFailure>) {
      return Failed<DocumentResource, StructuredFailure>(resource.error);
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<DocumentResource, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<DocumentResource, StructuredFailure>(
      (resource as Ok<DocumentResource, StructuredFailure>).value,
    );
  }

  Result<List<int>, StructuredFailure> _readVerified(
    String path,
    int expectedLength,
    Sha256Digest expectedDigest,
  ) {
    final read = _archive.read(path);
    if (read is Err<List<int>, StructuredFailure>) return read;
    final bytes = (read as Ok<List<int>, StructuredFailure>).value;
    final calculated = Sha256Digest.calculate(bytes);
    if (bytes.length != expectedLength ||
        calculated is! Ok<Sha256Digest, StructuredFailure> ||
        calculated.value != expectedDigest) {
      return Err<List<int>, StructuredFailure>(
        storageFailure(
          'entry_integrity',
          'An entry failed manifest integrity validation.',
        ),
      );
    }
    return Ok<List<int>, StructuredFailure>(bytes);
  }

  BoundedJsonCodec _json() => BoundedJsonCodec(
    maximumBytes: _limits['alnote.storage.json_bytes'],
    maximumDepth: _limits['alnote.storage.json_depth'],
    maximumValues: _limits['alnote.storage.json_values'],
    maximumStringCodeUnits: _limits['alnote.storage.string_code_units'],
  );
}

/// Staged, bounded, lazy `.alnote` package reader.
final class AlnotePackageReader {
  /// Creates a reader with a nonglobal immutable Object Registry.
  const AlnotePackageReader({required this.objectRegistry});

  /// The registry used only during complete materialization validation.
  final ObjectRegistry objectRegistry;

  /// Reads a portable source and opens it without interpreting Page/resources.
  Future<OperationOutcome<OpenedAlnotePackage, StructuredFailure>> open(
    PackageByteSource source, {
    required ResourceLimitSnapshot limits,
    required CancellationToken cancellationToken,
  }) async {
    final parsedLimits = AlnoteStorageLimits.fromSnapshot(limits);
    if (parsedLimits is Err<AlnoteStorageLimits, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(parsedLimits.error);
    }
    final storageLimits =
        (parsedLimits as Ok<AlnoteStorageLimits, StructuredFailure>).value;
    OperationOutcome<List<int>, StructuredFailure> read;
    try {
      read = await source.readAll(
        maximumBytes: storageLimits['alnote.storage.package_bytes'],
        cancellationToken: cancellationToken,
      );
    } on Object {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        storageFailure('source', 'The package source could not be read.'),
      );
    }
    try {
      return switch (read) {
        Completed<List<int>, StructuredFailure>(:final value) =>
          value.length > storageLimits['alnote.storage.package_bytes']
              ? Failed<OpenedAlnotePackage, StructuredFailure>(
                  storageFailure(
                    'package_bytes',
                    'The package byte ceiling was exceeded.',
                  ),
                )
              : openBytes(
                  value,
                  limits: limits,
                  cancellationToken: cancellationToken,
                ),
        Failed<List<int>, StructuredFailure>() =>
          Failed<OpenedAlnotePackage, StructuredFailure>(
            storageFailure('source', 'The package source could not be read.'),
          ),
        Cancelled<List<int>, StructuredFailure>() =>
          Cancelled<OpenedAlnotePackage, StructuredFailure>(
            cancellationToken.isCancelled ? cancellationToken.reason : null,
          ),
      };
    } on Object {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        storageFailure('source', 'The package source could not be read.'),
      );
    }
  }

  /// Opens immutable in-memory bytes using the same bounded staged path.
  OperationOutcome<OpenedAlnotePackage, StructuredFailure> openBytes(
    Iterable<int> source, {
    required ResourceLimitSnapshot limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Cancelled<OpenedAlnotePackage, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    final parsedLimits = AlnoteStorageLimits.fromSnapshot(limits);
    if (parsedLimits is Err<AlnoteStorageLimits, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(parsedLimits.error);
    }
    final storageLimits =
        (parsedLimits as Ok<AlnoteStorageLimits, StructuredFailure>).value;
    final copied = _copyPackageBytes(
      source,
      storageLimits['alnote.storage.package_bytes'],
    );
    if (copied is Err<List<int>, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(copied.error);
    }
    final packageBytes = (copied as Ok<List<int>, StructuredFailure>).value;
    final opened = openBoundedZip(packageBytes, storageLimits);
    if (opened is Err<BoundedMemoryArchive, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(opened.error);
    }
    final archive =
        (opened as Ok<BoundedMemoryArchive, StructuredFailure>).value;
    if (archive.entries.length < 3 ||
        archive.entries[0].path != 'mimetype' ||
        archive.entries[1].path != 'manifest.json' ||
        archive.entries[2].path != 'document.json') {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        storageFailure(
          'entry_order',
          'Required package entries are not in canonical order.',
        ),
      );
    }
    final mimetype = archive.read('mimetype');
    if (mimetype is Err<List<int>, StructuredFailure> ||
        !_bytesEqual(
          (mimetype as Ok<List<int>, StructuredFailure>).value,
          ascii.encode(alnotePackageMediaType),
        )) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        storageFailure('mimetype', 'The package media type is not recognized.'),
      );
    }
    final manifestBytes = archive.read('manifest.json');
    if (manifestBytes is Err<List<int>, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        manifestBytes.error,
      );
    }
    final json = BoundedJsonCodec(
      maximumBytes: storageLimits['alnote.storage.json_bytes'],
      maximumDepth: storageLimits['alnote.storage.json_depth'],
      maximumValues: storageLimits['alnote.storage.json_values'],
      maximumStringCodeUnits: storageLimits['alnote.storage.string_code_units'],
    );
    final parsedManifest = json.decode(
      (manifestBytes as Ok<List<int>, StructuredFailure>).value,
    );
    if (parsedManifest is Err<PreservedData, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        parsedManifest.error,
      );
    }
    final decodedManifest = ManifestCodec().decode(
      (parsedManifest as Ok<PreservedData, StructuredFailure>).value,
    );
    if (decodedManifest is Err<AlnoteManifest, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        decodedManifest.error,
      );
    }
    final manifest =
        (decodedManifest as Ok<AlnoteManifest, StructuredFailure>).value;
    final catalogFailure = _validateCatalog(archive, manifest, storageLimits);
    if (catalogFailure != null) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(catalogFailure);
    }
    final eager = <String, PreservedData>{};
    for (final entry in manifest.entries.where(
      (entry) =>
          entry.path == 'document.json' || entry.path.startsWith('sections/'),
    )) {
      final verified = _verifiedRead(archive, entry);
      if (verified is Err<List<int>, StructuredFailure>) {
        return Failed<OpenedAlnotePackage, StructuredFailure>(verified.error);
      }
      final parsed = json.decode(
        (verified as Ok<List<int>, StructuredFailure>).value,
      );
      if (parsed is Err<PreservedData, StructuredFailure>) {
        return Failed<OpenedAlnotePackage, StructuredFailure>(parsed.error);
      }
      eager[entry.path] =
          (parsed as Ok<PreservedData, StructuredFailure>).value;
    }
    final root = eager['document.json'];
    if (root == null || !_rootMatchesManifest(root, manifest)) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(
        storageFailure(
          'manifest_root',
          'The root record does not match the manifest.',
        ),
      );
    }
    final eagerFailure = _validateEagerRecords(root, eager, manifest);
    if (eagerFailure != null) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(eagerFailure);
    }
    final opaqueEntries = <AlnoteOpaqueEntry>[];
    for (final entry in manifest.entries.where(
      (entry) => entry.path.startsWith('extensions/'),
    )) {
      final verified = _verifiedRead(archive, entry);
      if (verified is Err<List<int>, StructuredFailure>) {
        return Failed<OpenedAlnotePackage, StructuredFailure>(verified.error);
      }
      final opaque = AlnoteOpaqueEntry.create(
        path: entry.path,
        mediaType: entry.mediaType,
        schemaVersion: entry.schemaVersion,
        bytes: (verified as Ok<List<int>, StructuredFailure>).value,
      );
      if (opaque is Err<AlnoteOpaqueEntry, StructuredFailure>) {
        return Failed<OpenedAlnotePackage, StructuredFailure>(opaque.error);
      }
      opaqueEntries.add(
        (opaque as Ok<AlnoteOpaqueEntry, StructuredFailure>).value,
      );
    }
    final preservation = AlnotePackagePreservation.create(
      unknownManifestFields: manifest.unknownFields,
      optionalFeatures: manifest.optionalFeatures,
      extensionNamespaces: manifest.extensionNamespaces,
      opaqueEntries: opaqueEntries,
      entryCatalogFields: <String, PreservedMap>{
        for (final entry in manifest.entries)
          if (entry.unknownFields.values.isNotEmpty)
            entry.path: entry.unknownFields,
      },
      resourceCatalogFields: <String, PreservedMap>{
        for (final resource in manifest.resources)
          if (resource.unknownFields.values.isNotEmpty)
            resource.identity: resource.unknownFields,
      },
    );
    if (preservation is Err<AlnotePackagePreservation, StructuredFailure>) {
      return Failed<OpenedAlnotePackage, StructuredFailure>(preservation.error);
    }
    final package = OpenedAlnotePackage._(
      packageBytes: packageBytes,
      manifest: manifest,
      evidence: AlnoteLoadEvidence(
        entryCount: archive.entries.length,
        lazy: true,
      ),
      preservation:
          (preservation as Ok<AlnotePackagePreservation, StructuredFailure>)
              .value,
      archive: archive,
      limits: storageLimits,
      registry: objectRegistry,
      rootRecord: root,
      sectionRecords: <String, PreservedData>{
        for (final entry in eager.entries)
          if (entry.key.startsWith('sections/')) entry.key: entry.value,
      },
    );
    final pages =
        manifest.entries
            .where((entry) => entry.path.startsWith('pages/'))
            .map(
              (entry) => AlnotePageHandle._(
                entry.path.substring(
                  'pages/'.length,
                  entry.path.length - '.json'.length,
                ),
                package,
                entry,
              ),
            )
            .toList()
          ..sort((left, right) => left.id.compareTo(right.id));
    final resources =
        manifest.resources
            .map((entry) => AlnoteResourceHandle._(package, entry))
            .toList()
          ..sort(
            (left, right) =>
                left.entry.identity.compareTo(right.entry.identity),
          );
    package.pageHandles = List<AlnotePageHandle>.unmodifiable(pages);
    package.resourceHandles = List<AlnoteResourceHandle>.unmodifiable(
      resources,
    );
    if (cancellationToken.isCancelled) {
      return Cancelled<OpenedAlnotePackage, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<OpenedAlnotePackage, StructuredFailure>(package);
  }
}

StructuredFailure? _validateCatalog(
  BoundedMemoryArchive archive,
  AlnoteManifest manifest,
  AlnoteStorageLimits limits,
) {
  final parsedDocumentId = UuidIdentifier.parse(manifest.documentId);
  if (parsedDocumentId is! Ok<UuidIdentifier, StructuredFailure> ||
      parsedDocumentId.value.value != manifest.documentId ||
      manifest.entryPoint != 'document.json' ||
      manifest.resources.length > limits['alnote.storage.resource_count']) {
    return storageFailure(
      'manifest_catalog',
      'The manifest catalog is not valid.',
    );
  }
  final sectionCount = manifest.entries
      .where((entry) => entry.path.startsWith('sections/'))
      .length;
  final pageCount = manifest.entries
      .where((entry) => entry.path.startsWith('pages/'))
      .length;
  final unknownCount = manifest.entries
      .where((entry) => entry.path.startsWith('extensions/'))
      .length;
  if (sectionCount > limits['alnote.storage.section_count'] ||
      pageCount > limits['alnote.storage.page_count'] ||
      unknownCount > limits['alnote.storage.unknown_entry_count']) {
    return storageFailure(
      'manifest_catalog',
      'A manifest catalog count exceeds caller policy.',
    );
  }
  final expected = <String>{'manifest.json'};
  final metadata = <String, ArchiveEntryMetadata>{
    for (final entry in archive.entries) entry.path: entry,
  };
  for (final entry in manifest.entries) {
    if (!expected.add(entry.path)) {
      return storageFailure(
        'manifest_catalog',
        'The manifest catalog has a duplicate entry.',
      );
    }
    final actual = metadata[entry.path];
    if (actual == null || actual.decodedByteLength != entry.decodedByteLength) {
      return storageFailure(
        'manifest_catalog',
        'Manifest entry metadata does not match ZIP metadata.',
      );
    }
    final knownFailure = _validateKnownEntryMetadata(entry);
    if (knownFailure != null) return knownFailure;
  }
  final mimetypeEntry = manifest.entries
      .where((entry) => entry.path == 'mimetype')
      .firstOrNull;
  if (mimetypeEntry == null ||
      _verifiedRead(archive, mimetypeEntry)
          is Err<List<int>, StructuredFailure>) {
    return storageFailure(
      'mimetype',
      'The package media type metadata is not valid.',
    );
  }
  final actualNamespaces = <String>{
    for (final entry in manifest.entries)
      if (entry.path.startsWith('extensions/'))
        extensionNamespaceForPath(entry.path),
  }.toList()..sort();
  if (!_stringListsEqual(actualNamespaces, manifest.extensionNamespaces)) {
    return storageFailure(
      'extension_catalog',
      'Extension metadata does not satisfy the required contract.',
    );
  }
  final resourcePaths = <String, AlnoteResourceEntry>{};
  for (final resource in manifest.resources) {
    final resourceId = UuidIdentifier.parse(resource.identity);
    if (resourceId is! Ok<UuidIdentifier, StructuredFailure> ||
        resourceId.value.value != resource.identity) {
      return storageFailure(
        'resource_catalog',
        'A resource catalog identity is invalid.',
      );
    }
    final expectedPath =
        'resources/${resource.digest.hexadecimal.substring(0, 2)}/${resource.digest.hexadecimal}';
    if (resource.path != expectedPath) {
      return storageFailure(
        'resource_catalog',
        'A resource path does not match its digest.',
      );
    }
    final prior = resourcePaths[resource.path];
    if (prior != null &&
        (prior.digest != resource.digest ||
            prior.decodedByteLength != resource.decodedByteLength)) {
      return storageFailure(
        'resource_catalog',
        'Shared resource bytes have conflicting metadata.',
      );
    }
    resourcePaths[resource.path] = resource;
    expected.add(resource.path);
    final actual = metadata[resource.path];
    if (actual == null ||
        actual.decodedByteLength != resource.decodedByteLength) {
      return storageFailure(
        'resource_catalog',
        'Resource metadata does not match ZIP metadata.',
      );
    }
  }
  if (expected.length != metadata.length ||
      !expected.containsAll(metadata.keys)) {
    return storageFailure(
      'manifest_catalog',
      'The ZIP contains an uncataloged or missing entry.',
    );
  }
  return null;
}

Result<List<int>, StructuredFailure> _verifiedRead(
  BoundedMemoryArchive archive,
  AlnoteManifestEntry entry,
) {
  final read = archive.read(entry.path);
  if (read is Err<List<int>, StructuredFailure>) return read;
  final bytes = (read as Ok<List<int>, StructuredFailure>).value;
  final calculated = Sha256Digest.calculate(bytes);
  if (bytes.length != entry.decodedByteLength ||
      calculated is! Ok<Sha256Digest, StructuredFailure> ||
      calculated.value != entry.digest) {
    return Err<List<int>, StructuredFailure>(
      storageFailure(
        'entry_integrity',
        'An entry failed manifest integrity validation.',
      ),
    );
  }
  return Ok<List<int>, StructuredFailure>(bytes);
}

bool _rootMatchesManifest(PreservedData root, AlnoteManifest manifest) {
  if (root is! PreservedMap) return false;
  final id = root.values['documentId'];
  final form = root.values['form'];
  final version = root.values['schemaVersion'];
  return id is PreservedString &&
      id.value == manifest.documentId &&
      form is PreservedString &&
      form.value == manifest.documentForm.name &&
      version is PreservedInteger &&
      version.value == manifest.documentSchemaVersion.value;
}

StructuredFailure? _validateKnownEntryMetadata(AlnoteManifestEntry entry) {
  final schemaOne = entry.schemaVersion.value == 1;
  if (entry.path == 'mimetype') {
    return entry.mediaType.value == alnotePackageMediaType && schemaOne
        ? null
        : storageFailure(
            'manifest_catalog',
            'Known entry metadata does not satisfy the required contract.',
          );
  }
  if (entry.path == 'document.json' ||
      entry.path.startsWith('sections/') ||
      entry.path.startsWith('pages/')) {
    return entry.mediaType.value == 'application/json' && schemaOne
        ? null
        : storageFailure(
            'manifest_catalog',
            'Known entry metadata does not satisfy the required contract.',
          );
  }
  return null;
}

StructuredFailure? _validateEagerRecords(
  PreservedData root,
  Map<String, PreservedData> eager,
  AlnoteManifest manifest,
) {
  try {
    final rootMap = _recordMap(root);
    _recordUuid(rootMap, 'documentId');
    _recordString(rootMap, 'title');
    final form = _recordString(rootMap, 'form');
    final schema = _recordInteger(rootMap, 'schemaVersion');
    if (form != manifest.documentForm.name ||
        schema != manifest.documentSchemaVersion.value) {
      throw const _EagerRejected();
    }
    final sectionPaths =
        eager.keys.where((path) => path.startsWith('sections/')).toList()
          ..sort();
    final pagePathIds = manifest.entries
        .where((entry) => entry.path.startsWith('pages/'))
        .map(_recordPathId)
        .toSet();
    final resourceIds = manifest.resources
        .map((resource) => resource.identity)
        .toSet();
    final referencedPages = <String>{};
    switch (manifest.documentForm) {
      case AlnoteDocumentForm.notebook:
        if (rootMap.containsKey('pageId') ||
            rootMap.containsKey('pageIds') ||
            rootMap.containsKey('sourceResourceId')) {
          throw const _EagerRejected();
        }
        final sectionIds = _recordUuidList(rootMap, 'sectionIds');
        if (sectionIds.length != sectionIds.toSet().length ||
            sectionIds.length != sectionPaths.length ||
            !sectionIds.toSet().containsAll(sectionPaths.map(_recordPathId))) {
          throw const _EagerRejected();
        }
        for (final path in sectionPaths) {
          final section = _recordMap(eager[path]!);
          final pathId = _recordPathId(path);
          if (_recordUuid(section, 'id') != pathId ||
              _recordInteger(section, 'schemaVersion') != 1) {
            throw const _EagerRejected();
          }
          _recordString(section, 'name');
          final pages = _recordUuidList(section, 'pageIds');
          if (pages.length != pages.toSet().length ||
              pages.any((page) => !referencedPages.add(page))) {
            throw const _EagerRejected();
          }
        }
      case AlnoteDocumentForm.standalonePage:
        if (sectionPaths.isNotEmpty ||
            rootMap.containsKey('sectionIds') ||
            rootMap.containsKey('pageIds') ||
            rootMap.containsKey('sourceResourceId')) {
          throw const _EagerRejected();
        }
        referencedPages.add(_recordUuid(rootMap, 'pageId'));
      case AlnoteDocumentForm.standalonePdf:
        if (sectionPaths.isNotEmpty ||
            rootMap.containsKey('sectionIds') ||
            rootMap.containsKey('pageId')) {
          throw const _EagerRejected();
        }
        final pages = _recordUuidList(rootMap, 'pageIds');
        if (pages.length != pages.toSet().length) throw const _EagerRejected();
        referencedPages.addAll(pages);
        final sourceResourceId = _recordUuid(rootMap, 'sourceResourceId');
        if (!resourceIds.contains(sourceResourceId)) {
          throw const _EagerRejected();
        }
    }
    if (referencedPages.length != pagePathIds.length ||
        !referencedPages.containsAll(pagePathIds)) {
      throw const _EagerRejected();
    }
    return null;
  } on Object {
    return storageFailure(
      'record_validation',
      'An authoritative record does not satisfy the required contract.',
    );
  }
}

Map<String, PreservedData> _recordMap(PreservedData value) {
  if (value is! PreservedMap) throw const _EagerRejected();
  return value.values;
}

String _recordString(Map<String, PreservedData> map, String key) {
  final value = map[key];
  if (value is! PreservedString) throw const _EagerRejected();
  return value.value;
}

int _recordInteger(Map<String, PreservedData> map, String key) {
  final value = map[key];
  if (value is! PreservedInteger) throw const _EagerRejected();
  return value.value;
}

String _recordUuid(Map<String, PreservedData> map, String key) {
  final value = _recordString(map, key);
  final parsed = UuidIdentifier.parse(value);
  if (parsed is! Ok<UuidIdentifier, StructuredFailure> ||
      parsed.value.value != value) {
    throw const _EagerRejected();
  }
  return value;
}

List<String> _recordUuidList(Map<String, PreservedData> map, String key) {
  final value = map[key];
  if (value is! PreservedList) throw const _EagerRejected();
  return value.values
      .map((item) {
        if (item is! PreservedString) throw const _EagerRejected();
        final parsed = UuidIdentifier.parse(item.value);
        if (parsed is! Ok<UuidIdentifier, StructuredFailure> ||
            parsed.value.value != item.value) {
          throw const _EagerRejected();
        }
        return item.value;
      })
      .toList(growable: false);
}

String _recordPathId(Object pathOrEntry) {
  final path = pathOrEntry is String
      ? pathOrEntry
      : (pathOrEntry as AlnoteManifestEntry).path;
  final slash = path.indexOf('/');
  return path.substring(slash + 1, path.length - '.json'.length);
}

Result<List<int>, StructuredFailure> _copyPackageBytes(
  Iterable<int> source,
  int maximumBytes,
) {
  final copied = <int>[];
  try {
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (copied.length == maximumBytes) {
        return Err<List<int>, StructuredFailure>(
          storageFailure(
            'package_bytes',
            'The package byte ceiling was exceeded.',
          ),
        );
      }
      final byte = iterator.current;
      if (byte < 0 || byte > 255) {
        return Err<List<int>, StructuredFailure>(
          storageFailure('package_bytes', 'Package bytes are not valid.'),
        );
      }
      copied.add(byte);
    }
    return Ok<List<int>, StructuredFailure>(List<int>.unmodifiable(copied));
  } on Object {
    return Err<List<int>, StructuredFailure>(
      storageFailure('package_bytes', 'Package bytes are not valid.'),
    );
  }
}

bool _stringListsEqual(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _EagerRejected implements Exception {
  const _EagerRejected();
}

UuidIdentifier _uuid(String source) => UuidIdentifier.parse(source).fold(
  onOk: (value) => value,
  onErr: (_) => throw StateError('Invalid package UUID.'),
);

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
