// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/identity/namespaced_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/schema_version.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';
import '../objects/object_envelope.dart';

/// A permanent namespaced Layer type identity.
final class LayerTypeKey implements Comparable<LayerTypeKey> {
  /// Creates a key from a validated AL NOTE namespaced identifier.
  const LayerTypeKey.fromIdentifier(this.identifier);

  /// Parses a permanent namespaced Layer type key.
  static Result<LayerTypeKey, StructuredFailure> parse(String source) =>
      NamespacedIdentifier.parse(source).map(LayerTypeKey.fromIdentifier);

  /// The ordinary built-in mixed-content Layer type key.
  static final LayerTypeKey content = _trustedLayerTypeKey(
    'alnote.layer.content',
  );

  /// The wrapped AL NOTE namespaced identifier.
  final NamespacedIdentifier identifier;

  /// The stable namespaced value.
  String get value => identifier.value;

  @override
  int compareTo(LayerTypeKey other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayerTypeKey && other.identifier == identifier;

  @override
  int get hashCode => Object.hash(LayerTypeKey, identifier);

  @override
  String toString() => value;
}

/// A closed core-understood Layer ordering role.
enum LayerCoreRole {
  /// Ordinary editable content.
  content,

  /// A constrained background source below other roles.
  backgroundSource,

  /// A constrained PDF source below content.
  pdfSource,
}

/// Immutable common state for a directly Page-owned Layer.
sealed class DocumentLayer {
  DocumentLayer._({
    required this.id,
    required this.typeKey,
    required this.envelopeVersion,
    required this.typeSchemaVersion,
    required this.name,
    required this.role,
    required this.visible,
    required this.locked,
    required this.opacity,
    required Iterable<ObjectEnvelope> objects,
    required this.typeData,
    required this.extensionData,
  }) : objects = List<ObjectEnvelope>.unmodifiable(objects);

  /// The document-unique Layer identity.
  final LayerId id;

  /// The permanent Layer type key.
  final LayerTypeKey typeKey;

  /// The positive common-envelope schema version.
  final SchemaVersion envelopeVersion;

  /// The positive Layer-type schema version.
  final SchemaVersion typeSchemaVersion;

  /// The sensitive user-visible Layer name.
  final String name;

  /// The closed core ordering role.
  final LayerCoreRole role;

  /// Whether the Layer is visible.
  final bool visible;

  /// Whether the Layer is locked.
  final bool locked;

  /// The finite opacity in the inclusive range zero through one.
  final double opacity;

  /// The directly owned Objects in authoritative order.
  final List<ObjectEnvelope> objects;

  /// The immutable preserved Layer-type data.
  final PreservedData typeData;

  /// The immutable preserved common extension data.
  final PreservedMap extensionData;

  /// Whether [object] is effectively visible in this Layer.
  bool isObjectEffectivelyVisible(ObjectEnvelope object) =>
      visible && object.visible;

  /// Whether [object] is effectively locked in this Layer.
  bool isObjectEffectivelyLocked(ObjectEnvelope object) =>
      locked || object.locked;

  /// Builds the same Layer variant with a replacement Object collection.
  ///
  /// This is a model-building primitive. It does not authorize or publish a
  /// persistent mutation.
  Result<DocumentLayer, StructuredFailure> withObjects(
    Iterable<ObjectEnvelope> replacement,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other.runtimeType != runtimeType || other is! DocumentLayer) {
      return false;
    }
    return other.id == id &&
        other.typeKey == typeKey &&
        other.envelopeVersion == envelopeVersion &&
        other.typeSchemaVersion == typeSchemaVersion &&
        other.name == name &&
        other.role == role &&
        other.visible == visible &&
        other.locked == locked &&
        other.opacity == opacity &&
        _objectListsEqual(other.objects, objects) &&
        other.typeData == typeData &&
        other.extensionData == extensionData;
  }

  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    typeKey,
    envelopeVersion,
    typeSchemaVersion,
    name,
    role,
    visible,
    locked,
    opacity,
    Object.hashAll(objects),
    typeData,
    extensionData,
  );

  @override
  String toString() => '$runtimeType(id: $id, type: $typeKey, role: $role)';
}

/// The built-in ordinary mixed-content Layer.
final class ContentLayer extends DocumentLayer {
  ContentLayer._({
    required super.id,
    required super.envelopeVersion,
    required super.typeSchemaVersion,
    required super.name,
    required super.visible,
    required super.locked,
    required super.opacity,
    required super.objects,
    required super.typeData,
    required super.extensionData,
  }) : super._(typeKey: LayerTypeKey.content, role: LayerCoreRole.content);

  /// Creates a built-in content Layer after validating common state.
  static Result<ContentLayer, StructuredFailure> create({
    required LayerId id,
    required SchemaVersion envelopeVersion,
    required SchemaVersion typeSchemaVersion,
    required String name,
    required bool visible,
    required bool locked,
    required double opacity,
    required Iterable<ObjectEnvelope> objects,
    required PreservedData typeData,
    required PreservedMap extensionData,
  }) {
    final failure = _opacityFailure(opacity);
    if (failure != null) {
      return Err<ContentLayer, StructuredFailure>(failure);
    }
    return Ok<ContentLayer, StructuredFailure>(
      ContentLayer._(
        id: id,
        envelopeVersion: envelopeVersion,
        typeSchemaVersion: typeSchemaVersion,
        name: name,
        visible: visible,
        locked: locked,
        opacity: opacity,
        objects: objects,
        typeData: typeData,
        extensionData: extensionData,
      ),
    );
  }

  @override
  Result<DocumentLayer, StructuredFailure> withObjects(
    Iterable<ObjectEnvelope> replacement,
  ) => create(
    id: id,
    envelopeVersion: envelopeVersion,
    typeSchemaVersion: typeSchemaVersion,
    name: name,
    visible: visible,
    locked: locked,
    opacity: opacity,
    objects: replacement,
    typeData: typeData,
    extensionData: extensionData,
  );
}

/// An inert preserved Layer whose specialized type behavior is unavailable.
final class UnknownLayer extends DocumentLayer {
  UnknownLayer._({
    required super.id,
    required super.typeKey,
    required super.envelopeVersion,
    required super.typeSchemaVersion,
    required super.name,
    required super.role,
    required super.visible,
    required super.locked,
    required super.opacity,
    required super.objects,
    required super.typeData,
    required super.extensionData,
  }) : super._();

  /// Creates an inert unknown Layer while preserving its complete envelope.
  static Result<UnknownLayer, StructuredFailure> create({
    required LayerId id,
    required LayerTypeKey typeKey,
    required SchemaVersion envelopeVersion,
    required SchemaVersion typeSchemaVersion,
    required String name,
    required LayerCoreRole role,
    required bool visible,
    required bool locked,
    required double opacity,
    required Iterable<ObjectEnvelope> objects,
    required PreservedData typeData,
    required PreservedMap extensionData,
  }) {
    final failure = _opacityFailure(opacity);
    if (failure != null) {
      return Err<UnknownLayer, StructuredFailure>(failure);
    }
    return Ok<UnknownLayer, StructuredFailure>(
      UnknownLayer._(
        id: id,
        typeKey: typeKey,
        envelopeVersion: envelopeVersion,
        typeSchemaVersion: typeSchemaVersion,
        name: name,
        role: role,
        visible: visible,
        locked: locked,
        opacity: opacity,
        objects: objects,
        typeData: typeData,
        extensionData: extensionData,
      ),
    );
  }

  @override
  Result<DocumentLayer, StructuredFailure> withObjects(
    Iterable<ObjectEnvelope> replacement,
  ) => create(
    id: id,
    typeKey: typeKey,
    envelopeVersion: envelopeVersion,
    typeSchemaVersion: typeSchemaVersion,
    name: name,
    role: role,
    visible: visible,
    locked: locked,
    opacity: opacity,
    objects: replacement,
    typeData: typeData,
    extensionData: extensionData,
  );
}

LayerTypeKey _trustedLayerTypeKey(String source) {
  final parsed = LayerTypeKey.parse(source);
  return parsed.fold(
    onOk: (value) => value,
    onErr: (_) => throw StateError('Invalid trusted Layer type key.'),
  );
}

StructuredFailure? _opacityFailure(double opacity) {
  if (!opacity.isFinite || opacity < 0 || opacity > 1) {
    return StructuredFailure(
      code: 'documents.layers.invalid_opacity',
      category: FailureCategory.validation,
      retryDisposition: RetryDisposition.never,
      message: 'Layer opacity must be finite and between zero and one.',
    );
  }
  return null;
}

bool _objectListsEqual(List<ObjectEnvelope> left, List<ObjectEnvelope> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
