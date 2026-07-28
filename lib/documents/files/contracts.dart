// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import '../../core/versioning/schema_version.dart';
import '../model/document_root.dart';
import '../model/preserved_data.dart';
import '../resources/resource_records.dart';

/// The provisional package media type for format version 1.
const String alnotePackageMediaType = 'application/vnd.al-note+zip';

/// A positive AL NOTE package-format version independent of app versions.
final class AlnotePackageVersion implements Comparable<AlnotePackageVersion> {
  const AlnotePackageVersion._(this.value);

  /// Package format version 1.
  static const AlnotePackageVersion version1 = AlnotePackageVersion._(1);

  /// Creates a positive package version.
  static Result<AlnotePackageVersion, StructuredFailure> create(int value) {
    if (value <= 0) {
      return Err<AlnotePackageVersion, StructuredFailure>(
        storageFailure('version', 'The package version must be positive.'),
      );
    }
    return Ok<AlnotePackageVersion, StructuredFailure>(
      AlnotePackageVersion._(value),
    );
  }

  /// The positive format version.
  final int value;

  @override
  int compareTo(AlnotePackageVersion other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlnotePackageVersion && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// The persistent root form recorded in a version-1 manifest.
enum AlnoteDocumentForm {
  /// An ordered Section notebook.
  notebook,

  /// One standalone Page.
  standalonePage,

  /// A PDF-backed document with ordinary Pages.
  standalonePdf,
}

/// Immutable metadata for one authoritative structured package entry.
final class AlnoteManifestEntry implements Comparable<AlnoteManifestEntry> {
  /// Creates validated manifest-entry metadata.
  AlnoteManifestEntry({
    required this.path,
    required this.mediaType,
    required this.decodedByteLength,
    required this.digest,
    required this.schemaVersion,
    PreservedMap? unknownFields,
  }) : unknownFields = unknownFields ?? PreservedMap.empty();

  /// The canonical package path.
  final String path;

  /// The entry media type.
  final ResourceMediaType mediaType;

  /// The exact decoded byte length.
  final int decodedByteLength;

  /// The exact-byte SHA-256 digest.
  final Sha256Digest digest;

  /// The positive record schema version.
  final SchemaVersion schemaVersion;

  /// Unknown nested catalog fields preserved inertly.
  final PreservedMap unknownFields;

  @override
  int compareTo(AlnoteManifestEntry other) => path.compareTo(other.path);
}

/// Immutable catalog metadata for one logical resource.
final class AlnoteResourceEntry implements Comparable<AlnoteResourceEntry> {
  /// Creates resource catalog metadata.
  AlnoteResourceEntry({
    required this.identity,
    required this.path,
    required this.mediaType,
    required this.decodedByteLength,
    required this.digest,
    required this.role,
    required this.schemaVersion,
    PreservedMap? unknownFields,
  }) : unknownFields = unknownFields ?? PreservedMap.empty();

  /// The logical resource identity as a canonical UUID string.
  final String identity;

  /// The canonical digest-derived byte-entry path.
  final String path;

  /// The validated resource media type.
  final ResourceMediaType mediaType;

  /// The exact decoded byte length.
  final int decodedByteLength;

  /// The exact-byte digest.
  final Sha256Digest digest;

  /// The validated resource role.
  final ResourceRole role;

  /// The positive resource schema version.
  final SchemaVersion schemaVersion;

  /// Unknown nested resource-catalog fields preserved inertly.
  final PreservedMap unknownFields;

  @override
  int compareTo(AlnoteResourceEntry other) =>
      identity.compareTo(other.identity);
}

/// An inert, safe unknown extension entry preserved byte-for-byte.
final class AlnoteOpaqueEntry implements Comparable<AlnoteOpaqueEntry> {
  AlnoteOpaqueEntry._({
    required this.path,
    required this.mediaType,
    required this.schemaVersion,
    required List<int> bytes,
  }) : bytes = List<int>.unmodifiable(bytes);

  /// Validates and defensively captures inert extension metadata and bytes.
  static Result<AlnoteOpaqueEntry, StructuredFailure> create({
    required String path,
    required ResourceMediaType mediaType,
    required SchemaVersion schemaVersion,
    required Iterable<int> bytes,
  }) {
    try {
      final copied = <int>[];
      for (final byte in bytes) {
        if (byte < 0 || byte > 255) {
          return Err<AlnoteOpaqueEntry, StructuredFailure>(
            storageFailure('extension_catalog', _invalidExtensionMessage),
          );
        }
        copied.add(byte);
      }
      if (!isCanonicalAlnoteExtensionPath(path)) {
        return Err<AlnoteOpaqueEntry, StructuredFailure>(
          storageFailure('extension_catalog', _invalidExtensionMessage),
        );
      }
      return Ok<AlnoteOpaqueEntry, StructuredFailure>(
        AlnoteOpaqueEntry._(
          path: path,
          mediaType: mediaType,
          schemaVersion: schemaVersion,
          bytes: copied,
        ),
      );
    } on Object {
      return Err<AlnoteOpaqueEntry, StructuredFailure>(
        storageFailure('extension_catalog', _invalidExtensionMessage),
      );
    }
  }

  /// The canonical `extensions/<namespace>/...` path.
  final String path;

  /// The exact validated manifest media type.
  final ResourceMediaType mediaType;

  /// The exact positive manifest schema version.
  final SchemaVersion schemaVersion;

  /// The immutable uninterpreted bytes.
  final List<int> bytes;

  @override
  int compareTo(AlnoteOpaqueEntry other) => path.compareTo(other.path);
}

/// Structurally and byte-preserved data carried through package operations.
final class AlnotePackagePreservation {
  AlnotePackagePreservation._({
    required this.unknownManifestFields,
    required this.optionalFeatures,
    required this.extensionNamespaces,
    required this.opaqueEntries,
    required this.entryCatalogFields,
    required this.resourceCatalogFields,
  });

  /// Creates empty preservation state.
  factory AlnotePackagePreservation.empty() => AlnotePackagePreservation._(
    unknownManifestFields: PreservedMap.empty(),
    optionalFeatures: const <String>[],
    extensionNamespaces: const <String>[],
    opaqueEntries: const <AlnoteOpaqueEntry>[],
    entryCatalogFields: const <String, PreservedMap>{},
    resourceCatalogFields: const <String, PreservedMap>{},
  );

  /// Validates and defensively captures deterministic preservation state.
  static Result<AlnotePackagePreservation, StructuredFailure> create({
    PreservedMap? unknownManifestFields,
    Iterable<String> optionalFeatures = const <String>[],
    Iterable<String> extensionNamespaces = const <String>[],
    Iterable<AlnoteOpaqueEntry> opaqueEntries = const <AlnoteOpaqueEntry>[],
    Map<String, PreservedMap> entryCatalogFields =
        const <String, PreservedMap>{},
    Map<String, PreservedMap> resourceCatalogFields =
        const <String, PreservedMap>{},
  }) {
    try {
      final features = List<String>.of(optionalFeatures)..sort();
      final namespaces = List<String>.of(extensionNamespaces)..sort();
      final entries = List<AlnoteOpaqueEntry>.of(opaqueEntries)..sort();
      final copiedEntryFields = _copyCatalogFields(entryCatalogFields);
      final copiedResourceFields = _copyCatalogFields(resourceCatalogFields);
      final usedNamespaces =
          entries
              .map((entry) => extensionNamespaceForPath(entry.path))
              .toSet()
              .toList()
            ..sort();
      if (!_validUniqueIdentifiers(features) ||
          !_validUniqueIdentifiers(namespaces) ||
          _hasDuplicateStrings(entries.map((entry) => entry.path)) ||
          !_sameStringLists(namespaces, usedNamespaces)) {
        return Err<AlnotePackagePreservation, StructuredFailure>(
          storageFailure('extension_catalog', _invalidExtensionMessage),
        );
      }
      return Ok<AlnotePackagePreservation, StructuredFailure>(
        AlnotePackagePreservation._(
          unknownManifestFields: unknownManifestFields ?? PreservedMap.empty(),
          optionalFeatures: List<String>.unmodifiable(features),
          extensionNamespaces: List<String>.unmodifiable(namespaces),
          opaqueEntries: List<AlnoteOpaqueEntry>.unmodifiable(entries),
          entryCatalogFields: copiedEntryFields,
          resourceCatalogFields: copiedResourceFields,
        ),
      );
    } on Object {
      return Err<AlnotePackagePreservation, StructuredFailure>(
        storageFailure('extension_catalog', _invalidExtensionMessage),
      );
    }
  }

  /// Unknown manifest data preserved structurally and canonically.
  final PreservedMap unknownManifestFields;

  /// Unknown optional feature declarations retained inertly.
  final List<String> optionalFeatures;

  /// Exact validated extension namespace declarations.
  final List<String> extensionNamespaces;

  /// Safe extension entries preserved inertly.
  final List<AlnoteOpaqueEntry> opaqueEntries;

  /// Unknown fields keyed by canonical structured-entry path.
  final Map<String, PreservedMap> entryCatalogFields;

  /// Unknown fields keyed by canonical logical-resource UUID.
  final Map<String, PreservedMap> resourceCatalogFields;
}

/// The immutable version-1 manifest.
final class AlnoteManifest {
  /// Defensively captures all deterministic catalogs and features.
  AlnoteManifest({
    required this.packageVersion,
    required this.documentSchemaVersion,
    required this.documentForm,
    required this.documentId,
    required this.entryPoint,
    Iterable<String> requiredFeatures = const <String>[],
    Iterable<String> optionalFeatures = const <String>[],
    required Iterable<AlnoteManifestEntry> entries,
    required Iterable<AlnoteResourceEntry> resources,
    Iterable<String> extensionNamespaces = const <String>[],
    PreservedMap? unknownFields,
  }) : requiredFeatures = _sortedStrings(requiredFeatures),
       optionalFeatures = _sortedStrings(optionalFeatures),
       entries = List<AlnoteManifestEntry>.unmodifiable(
         List<AlnoteManifestEntry>.of(entries)..sort(),
       ),
       resources = List<AlnoteResourceEntry>.unmodifiable(
         List<AlnoteResourceEntry>.of(resources)..sort(),
       ),
       extensionNamespaces = _sortedStrings(extensionNamespaces),
       unknownFields = unknownFields ?? PreservedMap.empty();

  /// The package-format version.
  final AlnotePackageVersion packageVersion;

  /// The document-root schema version.
  final SchemaVersion documentSchemaVersion;

  /// The root document form.
  final AlnoteDocumentForm documentForm;

  /// The canonical document UUID string.
  final String documentId;

  /// The root structured-record path.
  final String entryPoint;

  /// Required feature identifiers in deterministic order.
  final List<String> requiredFeatures;

  /// Optional feature identifiers in deterministic order.
  final List<String> optionalFeatures;

  /// Structured entries in canonical path order.
  final List<AlnoteManifestEntry> entries;

  /// Logical resources in canonical UUID order.
  final List<AlnoteResourceEntry> resources;

  /// Declared extension namespaces in deterministic order.
  final List<String> extensionNamespaces;

  /// Unknown manifest fields preserved structurally.
  final PreservedMap unknownFields;
}

/// One immutable complete package save-capture.
final class AlnotePackageSnapshot {
  AlnotePackageSnapshot._({
    required this.version,
    required this.document,
    required this.resources,
    required this.preservation,
  });

  /// Captures and validates a complete package snapshot.
  static Result<AlnotePackageSnapshot, StructuredFailure> create({
    AlnotePackageVersion version = AlnotePackageVersion.version1,
    required DocumentRoot document,
    required Iterable<DocumentResourceSnapshot> resources,
    AlnotePackagePreservation? preservation,
  }) {
    final preserved = preservation ?? AlnotePackagePreservation.empty();
    final copied = List<DocumentResourceSnapshot>.of(resources)
      ..sort(
        (left, right) =>
            left.identity.uuid.value.compareTo(right.identity.uuid.value),
      );
    final identities = <String>{};
    final digestBytes = <Sha256Digest, List<int>>{};
    for (final resource in copied) {
      if (!identities.add(resource.identity.uuid.value)) {
        return Err<AlnotePackageSnapshot, StructuredFailure>(
          storageFailure(
            'resource_count',
            'Resource identities must be unique.',
          ),
        );
      }
      final existing = digestBytes[resource.digest];
      if (existing != null && !_bytesEqual(existing, resource.bytes)) {
        return Err<AlnotePackageSnapshot, StructuredFailure>(
          storageFailure(
            'resource_integrity',
            'One digest maps to conflicting bytes.',
          ),
        );
      }
      digestBytes[resource.digest] = resource.bytes;
    }
    final catalogIds = document.resources.entries
        .map((entry) => entry.identity.uuid.value)
        .toSet();
    if (catalogIds.length != identities.length ||
        !catalogIds.containsAll(identities)) {
      return Err<AlnotePackageSnapshot, StructuredFailure>(
        storageFailure(
          'resource_catalog',
          'The resource catalog is incomplete.',
        ),
      );
    }
    final entryPaths = <String>{
      'mimetype',
      'document.json',
      for (final page in document.pages) 'pages/${page.id.uuid.value}.json',
      if (document case NotebookDocument(:final sections))
        for (final section in sections)
          'sections/${section.id.uuid.value}.json',
      for (final opaque in preserved.opaqueEntries) opaque.path,
    };
    if (preserved.entryCatalogFields.keys.any(
          (path) => !entryPaths.contains(path),
        ) ||
        preserved.resourceCatalogFields.keys.any(
          (identity) => !identities.contains(identity),
        )) {
      return Err<AlnotePackageSnapshot, StructuredFailure>(
        storageFailure(
          'manifest_catalog',
          'Preserved catalog metadata does not match the package catalog.',
        ),
      );
    }
    return Ok<AlnotePackageSnapshot, StructuredFailure>(
      AlnotePackageSnapshot._(
        version: version,
        document: document,
        resources: List<DocumentResourceSnapshot>.unmodifiable(copied),
        preservation: preserved,
      ),
    );
  }

  /// The package-format version.
  final AlnotePackageVersion version;

  /// The complete immutable authoritative document.
  final DocumentRoot document;

  /// Every manifest resource; unknown reachability never discards resources.
  final List<DocumentResourceSnapshot> resources;

  /// Preserved unknown manifest and extension data.
  final AlnotePackagePreservation preservation;
}

/// An immutable external-change fingerprint.
final class PackageFingerprint {
  /// Creates fingerprint evidence from exact size and optional full hash.
  const PackageFingerprint({required this.byteLength, this.fullDigest});

  /// The observed package byte length.
  final int byteLength;

  /// An optional full-content SHA-256 digest.
  final Sha256Digest? fullDigest;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PackageFingerprint &&
          other.byteLength == byteLength &&
          other.fullDigest == fullDigest;

  @override
  int get hashCode => Object.hash(byteLength, fullDigest);
}

/// Portable AL NOTE-owned source of package bytes.
abstract interface class PackageByteSource {
  /// Reads at most the caller-policy package byte ceiling.
  Future<OperationOutcome<List<int>, StructuredFailure>> readAll({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });
}

/// One staged replacement output controlled by a destination adapter.
abstract interface class PackageStagingArea {
  /// Whether the adapter can explicitly flush staged output.
  bool get supportsFlush;

  /// Writes a chunk and reports the exact accepted byte count.
  Future<OperationOutcome<int, StructuredFailure>> write(
    List<int> bytes, {
    required CancellationToken cancellationToken,
  });

  /// Flushes staged output when supported.
  Future<OperationOutcome<SaveDurabilityEvidence, StructuredFailure>> flush({
    required CancellationToken cancellationToken,
  });

  /// Reads the complete staged bytes back for independent validation.
  Future<OperationOutcome<List<int>, StructuredFailure>> readBack({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });

  /// Atomically verifies [expectedFingerprint] and replaces the destination.
  ///
  /// `null` means the destination must still be absent. A mismatch fails
  /// without replacement; adapters must never implement this as two separate
  /// check and replace operations.
  Future<OperationOutcome<SaveReplacementEvidence, StructuredFailure>> commit({
    required PackageFingerprint? expectedFingerprint,
    required CancellationToken cancellationToken,
  });

  /// Aborts and best-effort cleans the staged generation.
  Future<OperationOutcome<void, StructuredFailure>> abort();
}

/// Portable AL NOTE-owned complete-replacement destination.
abstract interface class PackageReplacementDestination {
  /// Reads preliminary conflict evidence before conditional publication.
  ///
  /// This is an early conflict check only; [PackageStagingArea.commit] remains
  /// the authoritative atomic comparison-and-replacement boundary.
  Future<OperationOutcome<PackageFingerprint?, StructuredFailure>> fingerprint({
    required CancellationToken cancellationToken,
  });

  /// Creates isolated staging without changing the prior valid generation.
  Future<OperationOutcome<PackageStagingArea, StructuredFailure>> beginStaging({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });
}

/// Flush and durability evidence that never infers durability from close/write.
final class SaveDurabilityEvidence {
  /// Creates explicit adapter-supplied durability evidence.
  const SaveDurabilityEvidence({required this.flushed, required this.durable});

  /// Whether an explicit flush completed.
  final bool flushed;

  /// Whether the destination explicitly proved durability.
  final bool durable;
}

/// Evidence describing the completed replacement strength.
final class SaveReplacementEvidence {
  /// Creates explicit replacement evidence.
  const SaveReplacementEvidence({required this.atomic, required this.durable});

  /// Whether replacement was explicitly atomic.
  final bool atomic;

  /// Whether committed bytes were explicitly durable.
  final bool durable;
}

/// Redaction-safe successful load evidence.
final class AlnoteLoadEvidence {
  /// Creates bounded load evidence.
  const AlnoteLoadEvidence({required this.entryCount, required this.lazy});

  /// The validated package entry count.
  final int entryCount;

  /// Whether Page and resource interpretation remains lazy.
  final bool lazy;
}

/// Redaction-safe successful save evidence.
final class AlnoteSaveEvidence {
  /// Creates save evidence from exact package and destination facts.
  const AlnoteSaveEvidence({
    required this.packageByteLength,
    required this.replacement,
    required this.flush,
  });

  /// The complete encoded package byte length.
  final int packageByteLength;

  /// The replacement evidence.
  final SaveReplacementEvidence replacement;

  /// Flush and durability evidence.
  final SaveDurabilityEvidence flush;
}

/// Redaction-safe successful migration evidence.
final class AlnoteMigrationEvidence {
  /// Creates deterministic migration evidence.
  const AlnoteMigrationEvidence({required this.stepCount});

  /// The applied trusted step count.
  final int stepCount;
}

/// Redaction-safe validation evidence.
final class AlnoteValidationEvidence {
  /// Creates validation evidence without content-derived diagnostics.
  const AlnoteValidationEvidence({required this.validatedEntryCount});

  /// The count of independently validated entries.
  final int validatedEntryCount;
}

/// Fully validated storage limits extracted from caller-supplied policy.
final class AlnoteStorageLimits {
  AlnoteStorageLimits._(this.values);

  /// Requires every Phase 4 key with its exact unit and fails closed.
  static Result<AlnoteStorageLimits, StructuredFailure> fromSnapshot(
    ResourceLimitSnapshot snapshot,
  ) {
    final values = <String, int>{};
    for (final requirement in alnoteStorageLimitRequirements.entries) {
      final key = ResourceLimitKey.parse(requirement.key).fold(
        onOk: (value) => value,
        onErr: (_) => throw StateError('Invalid trusted storage limit key.'),
      );
      final ceiling = snapshot.ceilingFor(key);
      if (ceiling == null || ceiling.unit != requirement.value) {
        return Err<AlnoteStorageLimits, StructuredFailure>(
          storageFailure(
            requirement.key.substring('alnote.storage.'.length),
            'A required storage policy dimension is missing or has the wrong unit.',
          ),
        );
      }
      if (ceiling.value > maximumWebSafeInteger) {
        return Err<AlnoteStorageLimits, StructuredFailure>(
          storageFailure(
            requirement.key.substring('alnote.storage.'.length),
            'A storage policy ceiling exceeds checked Web-safe arithmetic.',
          ),
        );
      }
      values[requirement.key] = ceiling.value;
    }
    return Ok<AlnoteStorageLimits, StructuredFailure>(
      AlnoteStorageLimits._(Map<String, int>.unmodifiable(values)),
    );
  }

  /// Every validated ceiling keyed by its stable policy identifier.
  final Map<String, int> values;

  /// Returns a required validated ceiling.
  int operator [](String key) => values[key]!;
}

/// Stable Phase 4 policy keys and required units, with no numeric defaults.
final Map<String, ResourceLimitUnit> alnoteStorageLimitRequirements =
    UnmodifiableMapView<String, ResourceLimitUnit>(<String, ResourceLimitUnit>{
      'alnote.storage.package_bytes': ResourceLimitUnit.bytes,
      'alnote.storage.entry_count': ResourceLimitUnit.count,
      'alnote.storage.entry_name_bytes': ResourceLimitUnit.bytes,
      'alnote.storage.entry_path_segments': ResourceLimitUnit.count,
      'alnote.storage.entry_compressed_bytes': ResourceLimitUnit.bytes,
      'alnote.storage.entry_decoded_bytes': ResourceLimitUnit.bytes,
      'alnote.storage.total_decoded_bytes': ResourceLimitUnit.bytes,
      'alnote.storage.compression_ratio': ResourceLimitUnit.ratio,
      'alnote.storage.json_bytes': ResourceLimitUnit.bytes,
      'alnote.storage.json_depth': ResourceLimitUnit.depth,
      'alnote.storage.json_values': ResourceLimitUnit.count,
      'alnote.storage.string_code_units': ResourceLimitUnit.count,
      'alnote.storage.section_count': ResourceLimitUnit.count,
      'alnote.storage.page_count': ResourceLimitUnit.count,
      'alnote.storage.layer_count': ResourceLimitUnit.count,
      'alnote.storage.object_count': ResourceLimitUnit.count,
      'alnote.storage.resource_count': ResourceLimitUnit.count,
      'alnote.storage.unknown_entry_count': ResourceLimitUnit.count,
      'alnote.storage.migration_steps': ResourceLimitUnit.count,
      'alnote.storage.migration_expansion_bytes': ResourceLimitUnit.bytes,
    });

/// Creates a fixed redaction-safe storage failure for one policy [dimension].
StructuredFailure storageFailure(String dimension, String message) =>
    StructuredFailure(
      code: 'documents.storage.$dimension',
      category: FailureCategory.validation,
      retryDisposition: RetryDisposition.never,
      message: message,
    );

List<String> _sortedStrings(Iterable<String> source) =>
    List<String>.unmodifiable(List<String>.of(source)..sort());

/// Whether [source] is one bounded lowercase ASCII AL NOTE identifier.
bool isAlnoteOwnedIdentifier(String source) =>
    RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(source);

/// Whether [path] is a canonical inert extension entry path.
bool isCanonicalAlnoteExtensionPath(String path) {
  final segments = path.split('/');
  return segments.length >= 3 &&
      segments.length <= maximumAlnotePathSegments &&
      segments.first == 'extensions' &&
      isAlnoteOwnedIdentifier(segments[1]) &&
      segments.skip(2).every(_isSafePathSegment);
}

/// Extracts the declared namespace from an already validated extension path.
String extensionNamespaceForPath(String path) => path.split('/')[1];

/// Explicit path-segment ceiling, measured in path components.
const int maximumAlnotePathSegments = 16;

const String _invalidExtensionMessage =
    'Extension metadata does not satisfy the required contract.';

bool _validUniqueIdentifiers(List<String> values) =>
    values.every(isAlnoteOwnedIdentifier) && !_hasDuplicateStrings(values);

bool _hasDuplicateStrings(Iterable<String> values) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) return true;
  }
  return false;
}

Map<String, PreservedMap> _copyCatalogFields(
  Map<String, PreservedMap> source,
) => UnmodifiableMapView<String, PreservedMap>(
  SplayTreeMap<String, PreservedMap>.of(source),
);

bool _sameStringLists(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _isSafePathSegment(String segment) {
  if (segment.isEmpty ||
      segment == '.' ||
      segment == '..' ||
      !RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(segment)) {
    return false;
  }
  final base = segment.split('.').first;
  return !RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(base);
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
