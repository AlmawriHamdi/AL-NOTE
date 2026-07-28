// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import '../../core/versioning/schema_version.dart';
import '../model/document_root.dart';
import '../model/document_validator.dart';
import '../model/preserved_data.dart';
import '../objects/object_registry.dart';
import '../resources/resource_records.dart';
import 'contracts.dart';
import 'src/archive_adapter.dart';
import 'src/bounded_json.dart';
import 'src/manifest_codec.dart';
import 'src/record_codec.dart';

/// Deterministic version-1 `.alnote` package encoder.
final class AlnotePackageCodec {
  /// Creates a codec using the supplied nonglobal immutable Object Registry.
  const AlnotePackageCodec({required this.objectRegistry});

  /// The registry used for complete document validation.
  final ObjectRegistry objectRegistry;

  /// Encodes a complete snapshot or returns a redaction-safe failure.
  Result<List<int>, StructuredFailure> encode(
    AlnotePackageSnapshot snapshot, {
    required ResourceLimitSnapshot limits,
  }) {
    final storageLimits = AlnoteStorageLimits.fromSnapshot(limits);
    if (storageLimits is Err<AlnoteStorageLimits, StructuredFailure>) {
      return Err<List<int>, StructuredFailure>(storageLimits.error);
    }
    return _encode(
      snapshot,
      (storageLimits as Ok<AlnoteStorageLimits, StructuredFailure>).value,
    );
  }

  /// Cancellation-aware encoding with cancellation separate from failure.
  OperationOutcome<List<int>, StructuredFailure> encodeOperation(
    AlnotePackageSnapshot snapshot, {
    required ResourceLimitSnapshot limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Cancelled<List<int>, StructuredFailure>(cancellationToken.reason);
    }
    final result = encode(snapshot, limits: limits);
    if (cancellationToken.isCancelled) {
      return Cancelled<List<int>, StructuredFailure>(cancellationToken.reason);
    }
    return result.fold(
      onOk: Completed<List<int>, StructuredFailure>.new,
      onErr: Failed<List<int>, StructuredFailure>.new,
    );
  }

  Result<List<int>, StructuredFailure> _encode(
    AlnotePackageSnapshot snapshot,
    AlnoteStorageLimits limits,
  ) {
    if (snapshot.version != AlnotePackageVersion.version1) {
      return Err<List<int>, StructuredFailure>(
        storageFailure(
          'version',
          'Only package format version 1 can be encoded.',
        ),
      );
    }
    final validation = DocumentValidator(
      objectRegistry,
    ).validate(snapshot.document);
    if (!validation.isValid) {
      return Err<List<int>, StructuredFailure>(
        storageFailure(
          'document_validation',
          'The complete document is not valid.',
        ),
      );
    }
    final limitFailure = _validateSnapshotLimits(snapshot, limits);
    if (limitFailure != null)
      return Err<List<int>, StructuredFailure>(limitFailure);

    final json = BoundedJsonCodec(
      maximumBytes: limits['alnote.storage.json_bytes'],
      maximumDepth: limits['alnote.storage.json_depth'],
      maximumValues: limits['alnote.storage.json_values'],
      maximumStringCodeUnits: limits['alnote.storage.string_code_units'],
    );
    final recordEncoder = RecordEncoder();
    final schemaOne = SchemaVersion.create(1).fold(
      onOk: _identitySchemaVersion,
      onErr: (_) => throw StateError('Invalid trusted schema version.'),
    );
    final jsonMedia = _mediaType('application/json');
    final packageMedia = _mediaType(alnotePackageMediaType);
    final payloads = <String, List<int>>{};

    Result<void, StructuredFailure> addJson(String path, PreservedData record) {
      final encoded = json.encode(record);
      return encoded.fold(
        onOk: (bytes) {
          payloads[path] = bytes;
          return const Ok<void, StructuredFailure>(null);
        },
        onErr: Err<void, StructuredFailure>.new,
      );
    }

    final documentResult = addJson(
      'document.json',
      recordEncoder.document(snapshot.document),
    );
    if (documentResult is Err<void, StructuredFailure>) {
      return Err<List<int>, StructuredFailure>(documentResult.error);
    }
    for (final section in _sections(snapshot.document)) {
      final result = addJson(
        'sections/${section.id.uuid.value}.json',
        recordEncoder.section(section),
      );
      if (result is Err<void, StructuredFailure>) {
        return Err<List<int>, StructuredFailure>(result.error);
      }
    }
    for (final page in snapshot.document.pages) {
      final result = addJson(
        'pages/${page.id.uuid.value}.json',
        recordEncoder.page(page),
      );
      if (result is Err<void, StructuredFailure>) {
        return Err<List<int>, StructuredFailure>(result.error);
      }
    }

    final mimetype = List<int>.unmodifiable(
      ascii.encode(alnotePackageMediaType),
    );
    final manifestEntries = <AlnoteManifestEntry>[
      AlnoteManifestEntry(
        path: 'mimetype',
        mediaType: packageMedia,
        decodedByteLength: mimetype.length,
        digest: _trustedDigest(mimetype),
        schemaVersion: schemaOne,
        unknownFields: snapshot.preservation.entryCatalogFields['mimetype'],
      ),
      for (final entry in payloads.entries)
        AlnoteManifestEntry(
          path: entry.key,
          mediaType: jsonMedia,
          decodedByteLength: entry.value.length,
          digest: _trustedDigest(entry.value),
          schemaVersion: schemaOne,
          unknownFields: snapshot.preservation.entryCatalogFields[entry.key],
        ),
      for (final entry in snapshot.preservation.opaqueEntries)
        AlnoteManifestEntry(
          path: entry.path,
          mediaType: entry.mediaType,
          decodedByteLength: entry.bytes.length,
          digest: _trustedDigest(entry.bytes),
          schemaVersion: entry.schemaVersion,
          unknownFields: snapshot.preservation.entryCatalogFields[entry.path],
        ),
    ];
    final resourceEntries = <AlnoteResourceEntry>[
      for (final resource in snapshot.resources)
        AlnoteResourceEntry(
          identity: resource.identity.uuid.value,
          path: resource.packagePath,
          mediaType: resource.mediaType,
          decodedByteLength: resource.decodedByteLength,
          digest: resource.digest,
          role: resource.role,
          schemaVersion: resource.schemaVersion,
          unknownFields: snapshot
              .preservation
              .resourceCatalogFields[resource.identity.uuid.value],
        ),
    ];
    final manifest = AlnoteManifest(
      packageVersion: snapshot.version,
      documentSchemaVersion: snapshot.document.schemaVersion,
      documentForm: _form(snapshot.document),
      documentId: snapshot.document.id.uuid.value,
      entryPoint: 'document.json',
      optionalFeatures: snapshot.preservation.optionalFeatures,
      entries: manifestEntries,
      resources: resourceEntries,
      extensionNamespaces: snapshot.preservation.extensionNamespaces,
      unknownFields: snapshot.preservation.unknownManifestFields,
    );
    final manifestBytesResult = json.encode(ManifestCodec().encode(manifest));
    if (manifestBytesResult is Err<List<int>, StructuredFailure>) {
      return Err<List<int>, StructuredFailure>(manifestBytesResult.error);
    }
    final manifestBytes =
        (manifestBytesResult as Ok<List<int>, StructuredFailure>).value;

    final resourceBytesByPath = <String, List<int>>{};
    for (final resource in snapshot.resources) {
      final calculated = Sha256Digest.calculate(resource.bytes);
      if (calculated is! Ok<Sha256Digest, StructuredFailure> ||
          calculated.value != resource.digest ||
          resource.decodedByteLength != resource.bytes.length) {
        return Err<List<int>, StructuredFailure>(
          storageFailure(
            'resource_integrity',
            'A resource failed exact-byte validation.',
          ),
        );
      }
      final prior = resourceBytesByPath[resource.packagePath];
      if (prior != null && !_bytesEqual(prior, resource.bytes)) {
        return Err<List<int>, StructuredFailure>(
          storageFailure(
            'resource_integrity',
            'A digest maps to conflicting resource bytes.',
          ),
        );
      }
      resourceBytesByPath[resource.packagePath] = resource.bytes;
    }
    final sectionPaths =
        payloads.keys.where((path) => path.startsWith('sections/')).toList()
          ..sort();
    final pagePaths =
        payloads.keys.where((path) => path.startsWith('pages/')).toList()
          ..sort();
    final resourcePaths = resourceBytesByPath.keys.toList()..sort();
    final opaque = List<AlnoteOpaqueEntry>.of(
      snapshot.preservation.opaqueEntries,
    )..sort();
    final entries = <ArchiveEntryBytes>[
      ArchiveEntryBytes('mimetype', mimetype),
      ArchiveEntryBytes('manifest.json', manifestBytes),
      ArchiveEntryBytes('document.json', payloads['document.json']!),
      for (final path in sectionPaths) ArchiveEntryBytes(path, payloads[path]!),
      for (final path in pagePaths) ArchiveEntryBytes(path, payloads[path]!),
      for (final path in resourcePaths)
        ArchiveEntryBytes(path, resourceBytesByPath[path]!),
      for (final entry in opaque) ArchiveEntryBytes(entry.path, entry.bytes),
    ];
    final entriesFailure = _validateEntryLimits(entries, limits);
    if (entriesFailure != null)
      return Err<List<int>, StructuredFailure>(entriesFailure);
    final encoded = encodeCanonicalZip(entries);
    return encoded.fold(
      onOk: (bytes) => bytes.length > limits['alnote.storage.package_bytes']
          ? Err<List<int>, StructuredFailure>(
              storageFailure(
                'package_bytes',
                'The encoded package exceeds its byte ceiling.',
              ),
            )
          : Ok<List<int>, StructuredFailure>(bytes),
      onErr: Err<List<int>, StructuredFailure>.new,
    );
  }
}

StructuredFailure? _validateSnapshotLimits(
  AlnotePackageSnapshot snapshot,
  AlnoteStorageLimits limits,
) {
  final sections = _sections(snapshot.document);
  if (sections.length > limits['alnote.storage.section_count']) {
    return storageFailure(
      'section_count',
      'The Section count ceiling was exceeded.',
    );
  }
  if (snapshot.document.pages.length > limits['alnote.storage.page_count']) {
    return storageFailure('page_count', 'The Page count ceiling was exceeded.');
  }
  var layers = 0;
  var objects = 0;
  for (final page in snapshot.document.pages) {
    layers += page.layers.length;
    for (final layer in page.layers) objects += layer.objects.length;
  }
  if (layers > limits['alnote.storage.layer_count']) {
    return storageFailure(
      'layer_count',
      'The Layer count ceiling was exceeded.',
    );
  }
  if (objects > limits['alnote.storage.object_count']) {
    return storageFailure(
      'object_count',
      'The Object count ceiling was exceeded.',
    );
  }
  if (snapshot.resources.length > limits['alnote.storage.resource_count']) {
    return storageFailure(
      'resource_count',
      'The resource count ceiling was exceeded.',
    );
  }
  if (snapshot.preservation.opaqueEntries.length >
      limits['alnote.storage.unknown_entry_count']) {
    return storageFailure(
      'unknown_entry_count',
      'The unknown-entry count ceiling was exceeded.',
    );
  }
  return null;
}

StructuredFailure? _validateEntryLimits(
  List<ArchiveEntryBytes> entries,
  AlnoteStorageLimits limits,
) {
  if (entries.length > limits['alnote.storage.entry_count']) {
    return storageFailure(
      'entry_count',
      'The entry count ceiling was exceeded.',
    );
  }
  var total = 0;
  final maximumSegments = _minimum(
    maximumAlnotePathSegments,
    limits['alnote.storage.entry_path_segments'],
  );
  for (final entry in entries) {
    if (ascii.encode(entry.path).length >
        limits['alnote.storage.entry_name_bytes']) {
      return storageFailure(
        'entry_name_bytes',
        'An entry-name ceiling was exceeded.',
      );
    }
    if (entry.path.split('/').length > maximumSegments) {
      return storageFailure(
        'entry_path_segments',
        'An entry path-segment ceiling was exceeded.',
      );
    }
    if (entry.bytes.length > limits['alnote.storage.entry_decoded_bytes']) {
      return storageFailure(
        'entry_decoded_bytes',
        'An entry byte ceiling was exceeded.',
      );
    }
    if (entry.bytes.length > limits['alnote.storage.entry_compressed_bytes']) {
      return storageFailure(
        'entry_compressed_bytes',
        'An entry compressed-byte ceiling was exceeded.',
      );
    }
    total += entry.bytes.length;
    if (total > limits['alnote.storage.total_decoded_bytes']) {
      return storageFailure(
        'total_decoded_bytes',
        'The total decoded byte ceiling was exceeded.',
      );
    }
  }
  return null;
}

int _minimum(int left, int right) => left < right ? left : right;

List<DocumentSection> _sections(DocumentRoot document) => switch (document) {
  NotebookDocument(:final sections) => sections,
  _ => const <DocumentSection>[],
};

AlnoteDocumentForm _form(DocumentRoot document) => switch (document) {
  NotebookDocument() => AlnoteDocumentForm.notebook,
  StandalonePageDocument() => AlnoteDocumentForm.standalonePage,
  StandalonePdfDocument() => AlnoteDocumentForm.standalonePdf,
};

ResourceMediaType _mediaType(String source) =>
    ResourceMediaType.parse(source).fold(
      onOk: (value) => value,
      onErr: (_) => throw StateError('Invalid trusted media type.'),
    );

SchemaVersion _identitySchemaVersion(SchemaVersion value) => value;

Sha256Digest _trustedDigest(List<int> bytes) =>
    (Sha256Digest.calculate(bytes) as Ok<Sha256Digest, StructuredFailure>)
        .value;

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
