// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/identity/namespaced_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/schema_version.dart';
import '../files/src/sha256_adapter.dart';
import '../model/identifiers.dart';

/// An immutable exact 256-bit SHA-256 digest.
///
/// A digest proves exact-byte integrity only. It is not evidence of authorship,
/// authenticity, authorization, or trust.
final class Sha256Digest implements Comparable<Sha256Digest> {
  Sha256Digest._(List<int> bytes)
    : bytes = List<int>.unmodifiable(List<int>.of(bytes)),
      hexadecimal = _hex(bytes);

  /// Parses exactly 64 lowercase hexadecimal characters.
  static Result<Sha256Digest, StructuredFailure> parse(String source) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(source)) {
      return Err<Sha256Digest, StructuredFailure>(
        _resourceFailure(
          'documents.resources.invalid_sha256',
          'A SHA-256 digest must use 64 lowercase hexadecimal characters.',
        ),
      );
    }
    return Ok<Sha256Digest, StructuredFailure>(
      Sha256Digest._(<int>[
        for (var index = 0; index < source.length; index += 2)
          int.parse(source.substring(index, index + 2), radix: 16),
      ]),
    );
  }

  /// Creates a digest from exactly 32 octets.
  static Result<Sha256Digest, StructuredFailure> fromBytes(
    Iterable<int> source,
  ) {
    final bytes = <int>[];
    try {
      for (final value in source) {
        if (value < 0 || value > 255 || bytes.length == 32) {
          return Err<Sha256Digest, StructuredFailure>(
            _resourceFailure(
              'documents.resources.invalid_sha256',
              'A SHA-256 digest must contain exactly 32 octets.',
            ),
          );
        }
        bytes.add(value);
      }
    } on Object {
      return Err<Sha256Digest, StructuredFailure>(
        _resourceFailure(
          'documents.resources.invalid_sha256',
          'A SHA-256 digest must contain exactly 32 octets.',
        ),
      );
    }
    if (bytes.length != 32) {
      return Err<Sha256Digest, StructuredFailure>(
        _resourceFailure(
          'documents.resources.invalid_sha256',
          'A SHA-256 digest must contain exactly 32 octets.',
        ),
      );
    }
    return Ok<Sha256Digest, StructuredFailure>(Sha256Digest._(bytes));
  }

  /// Validates octets and calculates SHA-256 through the private adapter.
  static Result<Sha256Digest, StructuredFailure> calculate(
    Iterable<int> source,
  ) {
    final bytes = <int>[];
    try {
      for (final value in source) {
        if (value < 0 || value > 255) {
          return Err<Sha256Digest, StructuredFailure>(
            _resourceFailure(
              'documents.resources.invalid_bytes',
              'Byte input must contain only octets.',
            ),
          );
        }
        bytes.add(value);
      }
      return Ok<Sha256Digest, StructuredFailure>(
        Sha256Digest._(calculateSha256(bytes)),
      );
    } on Object {
      return Err<Sha256Digest, StructuredFailure>(
        _resourceFailure(
          'documents.resources.invalid_bytes',
          'Byte input must contain only octets.',
        ),
      );
    }
  }

  /// The immutable 32 digest octets.
  final List<int> bytes;

  /// The canonical 64-character lowercase hexadecimal representation.
  final String hexadecimal;

  @override
  int compareTo(Sha256Digest other) => hexadecimal.compareTo(other.hexadecimal);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Sha256Digest && other.hexadecimal == hexadecimal;

  @override
  int get hashCode => hexadecimal.hashCode;

  @override
  String toString() => 'Sha256Digest(redacted)';
}

/// A validated lowercase ASCII media type without parameters.
final class ResourceMediaType implements Comparable<ResourceMediaType> {
  const ResourceMediaType._(this.value);

  /// Parses a bounded lowercase ASCII `type/subtype` value.
  static Result<ResourceMediaType, StructuredFailure> parse(String source) {
    if (source.length > 127 ||
        !RegExp(
          r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
        ).hasMatch(source)) {
      return Err<ResourceMediaType, StructuredFailure>(
        _resourceFailure(
          'documents.resources.invalid_media_type',
          'A resource media type must be a lowercase ASCII type and subtype.',
        ),
      );
    }
    return Ok<ResourceMediaType, StructuredFailure>(
      ResourceMediaType._(source),
    );
  }

  /// The canonical media type.
  final String value;

  @override
  int compareTo(ResourceMediaType other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceMediaType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A validated permanent namespaced role for a document resource.
final class ResourceRole implements Comparable<ResourceRole> {
  /// Creates a role from an already validated identifier.
  const ResourceRole.fromIdentifier(this.identifier);

  /// Parses a lowercase namespaced role.
  static Result<ResourceRole, StructuredFailure> parse(String source) =>
      NamespacedIdentifier.parse(source).map(ResourceRole.fromIdentifier);

  /// The validated namespaced identifier.
  final NamespacedIdentifier identifier;

  /// The canonical role text.
  String get value => identifier.value;

  @override
  int compareTo(ResourceRole other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceRole && other.identifier == identifier;

  @override
  int get hashCode => identifier.hashCode;

  @override
  String toString() => value;
}

/// Immutable metadata and bytes for one logical document resource.
final class DocumentResource {
  DocumentResource._({
    required this.identity,
    required this.digest,
    required this.mediaType,
    required this.role,
    required this.schemaVersion,
    required this.packagePath,
    required List<int> bytes,
  }) : bytes = List<int>.unmodifiable(List<int>.of(bytes));

  /// Creates and independently verifies one immutable resource.
  static Result<DocumentResource, StructuredFailure> create({
    required ResourceIdentity identity,
    required Sha256Digest digest,
    required int decodedByteLength,
    required ResourceMediaType mediaType,
    required ResourceRole role,
    required SchemaVersion schemaVersion,
    required String packagePath,
    required Iterable<int> bytes,
  }) {
    final copied = <int>[];
    try {
      for (final value in bytes) {
        if (value < 0 || value > 255) {
          return Err<DocumentResource, StructuredFailure>(
            _resourceFailure(
              'documents.resources.invalid_bytes',
              'Resource byte input must contain only octets.',
            ),
          );
        }
        copied.add(value);
      }
    } on Object {
      return Err<DocumentResource, StructuredFailure>(
        _resourceFailure(
          'documents.resources.invalid_bytes',
          'Resource byte input must contain only octets.',
        ),
      );
    }
    if (copied.length != decodedByteLength) {
      return Err<DocumentResource, StructuredFailure>(
        _resourceFailure(
          'documents.resources.size_mismatch',
          'Resource bytes do not match the declared byte length.',
        ),
      );
    }
    final calculated = Sha256Digest.calculate(copied);
    if (calculated is! Ok<Sha256Digest, StructuredFailure> ||
        calculated.value != digest) {
      return Err<DocumentResource, StructuredFailure>(
        _resourceFailure(
          'documents.resources.hash_mismatch',
          'Resource bytes do not match the declared digest.',
        ),
      );
    }
    final expectedPath =
        'resources/${digest.hexadecimal.substring(0, 2)}/${digest.hexadecimal}';
    if (packagePath != expectedPath) {
      return Err<DocumentResource, StructuredFailure>(
        _resourceFailure(
          'documents.resources.path_hash_mismatch',
          'A resource package path must be derived from its digest.',
        ),
      );
    }
    return Ok<DocumentResource, StructuredFailure>(
      DocumentResource._(
        identity: identity,
        digest: digest,
        mediaType: mediaType,
        role: role,
        schemaVersion: schemaVersion,
        packagePath: packagePath,
        bytes: copied,
      ),
    );
  }

  /// Creates a resource while calculating its canonical digest and path.
  static Result<DocumentResource, StructuredFailure> capture({
    required ResourceIdentity identity,
    required ResourceMediaType mediaType,
    required ResourceRole role,
    required SchemaVersion schemaVersion,
    required Iterable<int> bytes,
  }) {
    final copied = <int>[];
    try {
      for (final value in bytes) {
        if (value < 0 || value > 255) {
          return Err<DocumentResource, StructuredFailure>(
            _resourceFailure(
              'documents.resources.invalid_bytes',
              'Resource byte input must contain only octets.',
            ),
          );
        }
        copied.add(value);
      }
    } on Object {
      return Err<DocumentResource, StructuredFailure>(
        _resourceFailure(
          'documents.resources.invalid_bytes',
          'Resource byte input must contain only octets.',
        ),
      );
    }
    final digestResult = Sha256Digest.calculate(copied);
    if (digestResult is Err<Sha256Digest, StructuredFailure>) {
      return Err<DocumentResource, StructuredFailure>(digestResult.error);
    }
    final digest = (digestResult as Ok<Sha256Digest, StructuredFailure>).value;
    return Ok<DocumentResource, StructuredFailure>(
      DocumentResource._(
        identity: identity,
        digest: digest,
        mediaType: mediaType,
        role: role,
        schemaVersion: schemaVersion,
        packagePath:
            'resources/${digest.hexadecimal.substring(0, 2)}/${digest.hexadecimal}',
        bytes: copied,
      ),
    );
  }

  /// The logical document-scoped identity.
  final ResourceIdentity identity;

  /// The exact-byte SHA-256 digest.
  final Sha256Digest digest;

  /// The exact decoded byte length.
  int get decodedByteLength => bytes.length;

  /// The validated media type.
  final ResourceMediaType mediaType;

  /// The validated namespaced role.
  final ResourceRole role;

  /// The positive role schema version.
  final SchemaVersion schemaVersion;

  /// The digest-derived canonical package path.
  final String packagePath;

  /// A defensively copied immutable byte list.
  final List<int> bytes;

  @override
  String toString() => 'DocumentResource(bytes: ${bytes.length})';
}

/// An immutable save-capture snapshot of one document resource.
final class DocumentResourceSnapshot {
  /// Defensively captures [resource].
  DocumentResourceSnapshot(DocumentResource resource)
    : identity = resource.identity,
      digest = resource.digest,
      decodedByteLength = resource.decodedByteLength,
      mediaType = resource.mediaType,
      role = resource.role,
      schemaVersion = resource.schemaVersion,
      packagePath = resource.packagePath,
      bytes = List<int>.unmodifiable(List<int>.of(resource.bytes));

  /// The logical document-scoped identity.
  final ResourceIdentity identity;

  /// The exact-byte digest.
  final Sha256Digest digest;

  /// The exact decoded byte length.
  final int decodedByteLength;

  /// The media type.
  final ResourceMediaType mediaType;

  /// The resource role.
  final ResourceRole role;

  /// The positive resource schema version.
  final SchemaVersion schemaVersion;

  /// The canonical package path.
  final String packagePath;

  /// The immutable bytes.
  final List<int> bytes;
}

String _hex(List<int> bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

StructuredFailure _resourceFailure(String code, String message) =>
    StructuredFailure(
      code: code,
      category: FailureCategory.validation,
      retryDisposition: RetryDisposition.never,
      message: message,
    );
