// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/identity/namespaced_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/schema_version.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';

/// A permanent namespaced Object type identity.
final class ObjectTypeKey implements Comparable<ObjectTypeKey> {
  /// Creates a key from a validated AL NOTE namespaced identifier.
  const ObjectTypeKey.fromIdentifier(this.identifier);

  /// Parses a permanent namespaced Object type key.
  static Result<ObjectTypeKey, StructuredFailure> parse(String source) =>
      NamespacedIdentifier.parse(source).map(ObjectTypeKey.fromIdentifier);

  /// The wrapped AL NOTE namespaced identifier.
  final NamespacedIdentifier identifier;

  /// The stable namespaced value.
  String get value => identifier.value;

  @override
  int compareTo(ObjectTypeKey other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectTypeKey && other.identifier == identifier;

  @override
  int get hashCode => Object.hash(ObjectTypeKey, identifier);

  @override
  String toString() => value;
}

/// The immutable persistent common envelope for a Page Object.
final class ObjectEnvelope {
  const ObjectEnvelope._({
    required this.id,
    required this.typeKey,
    required this.envelopeVersion,
    required this.typeSchemaVersion,
    required this.transform,
    required this.visible,
    required this.locked,
    required this.payload,
    required this.extensionData,
  });

  /// Creates an Object envelope from already validated portable values.
  static Result<ObjectEnvelope, StructuredFailure> create({
    required ObjectId id,
    required ObjectTypeKey typeKey,
    required SchemaVersion envelopeVersion,
    required SchemaVersion typeSchemaVersion,
    required AffineTransform2D transform,
    required bool visible,
    required bool locked,
    required PreservedData payload,
    required PreservedMap extensionData,
  }) => Ok<ObjectEnvelope, StructuredFailure>(
    ObjectEnvelope._(
      id: id,
      typeKey: typeKey,
      envelopeVersion: envelopeVersion,
      typeSchemaVersion: typeSchemaVersion,
      transform: transform,
      visible: visible,
      locked: locked,
      payload: payload,
      extensionData: extensionData,
    ),
  );

  /// The document-unique Object identity.
  final ObjectId id;

  /// The permanent Object type key.
  final ObjectTypeKey typeKey;

  /// The positive common-envelope schema version.
  final SchemaVersion envelopeVersion;

  /// The positive type-payload schema version.
  final SchemaVersion typeSchemaVersion;

  /// The local-to-page transform.
  final AffineTransform2D transform;

  /// Whether the Object is independently visible.
  final bool visible;

  /// Whether the Object is independently locked.
  final bool locked;

  /// The immutable preserved type payload.
  final PreservedData payload;

  /// The immutable preserved common extension data.
  final PreservedMap extensionData;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectEnvelope &&
          other.id == id &&
          other.typeKey == typeKey &&
          other.envelopeVersion == envelopeVersion &&
          other.typeSchemaVersion == typeSchemaVersion &&
          other.transform == transform &&
          other.visible == visible &&
          other.locked == locked &&
          other.payload == payload &&
          other.extensionData == extensionData;

  @override
  int get hashCode => Object.hash(
    id,
    typeKey,
    envelopeVersion,
    typeSchemaVersion,
    transform,
    visible,
    locked,
    payload,
    extensionData,
  );

  @override
  String toString() => 'ObjectEnvelope(id: $id, type: $typeKey)';
}
