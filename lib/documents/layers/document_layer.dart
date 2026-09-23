// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/identity/namespaced_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/schema_version.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';
import '../objects/object_envelope.dart';
import '../pdf/pdf_model.dart';

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

  /// The built-in immutable PDF source Layer type key.
  static final LayerTypeKey pdfSource = _trustedLayerTypeKey(
    'alnote.pdf.source',
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

/// Built-in Page-filling PDF source Layer.
///
/// It owns no ordinary Objects and shares one immutable resource identity
/// through [reference]. It has no transform surface and is always locked.
final class PdfSourceLayer extends DocumentLayer {
  PdfSourceLayer._({
    required super.id,
    required super.envelopeVersion,
    required super.name,
    required super.visible,
    required super.opacity,
    required this.reference,
    required super.extensionData,
  }) : super._(
         typeKey: LayerTypeKey.pdfSource,
         typeSchemaVersion: pdfPageReferenceSchemaVersion,
         role: LayerCoreRole.pdfSource,
         locked: true,
         objects: const <ObjectEnvelope>[],
         typeData: reference.encode(),
       );

  /// Creates a locked built-in source Layer with exactly one Page reference.
  static Result<PdfSourceLayer, StructuredFailure> create({
    required LayerId id,
    required SchemaVersion envelopeVersion,
    required String name,
    required bool visible,
    required double opacity,
    required PdfPageReference reference,
    required PdfModelLimits limits,
    PreservedMap? extensionData,
  }) {
    final checkedReference = reference.validatedFor(limits);
    final extensions = extensionData ?? PreservedMap.empty();
    if (_opacityFailure(opacity) != null ||
        checkedReference is! Ok<PdfPageReference, StructuredFailure> ||
        _containsReservedLayerField(extensions) ||
        !preservedUnknownDataAllowed(
          root: extensions,
          maximumFieldsPerBoundary: limits.maximumUnknownFields,
          maximumNodes: limits.maximumUnknownNodes,
          maximumDepth: limits.maximumNestingDepth,
          maximumStringCodeUnits: limits.maximumUnknownStringCodeUnits,
        )) {
      return Err<PdfSourceLayer, StructuredFailure>(_invalidPdfSourceLayer());
    }
    return Ok<PdfSourceLayer, StructuredFailure>(
      PdfSourceLayer._(
        id: id,
        envelopeVersion: envelopeVersion,
        name: name,
        visible: visible,
        opacity: opacity,
        reference: checkedReference.value,
        extensionData: extensions,
      ),
    );
  }

  /// Reopens the exact schema-1 envelope or rejects corrupt built-in data.
  static Result<PdfSourceLayer, StructuredFailure> reopen({
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
    required PdfModelLimits limits,
  }) {
    if (typeSchemaVersion != pdfPageReferenceSchemaVersion || !locked) {
      return Err<PdfSourceLayer, StructuredFailure>(_invalidPdfSourceLayer());
    }
    try {
      if (objects.iterator.moveNext()) {
        return Err<PdfSourceLayer, StructuredFailure>(_invalidPdfSourceLayer());
      }
    } on Object {
      return Err<PdfSourceLayer, StructuredFailure>(_invalidPdfSourceLayer());
    }
    final decoded = PdfPageReference.decode(typeData, limits: limits);
    if (decoded is! Ok<PdfPageReference, StructuredFailure>) {
      return Err<PdfSourceLayer, StructuredFailure>(_invalidPdfSourceLayer());
    }
    return create(
      id: id,
      envelopeVersion: envelopeVersion,
      name: name,
      visible: visible,
      opacity: opacity,
      reference: decoded.value,
      limits: limits,
      extensionData: extensionData,
    );
  }

  /// The exact persisted Page reference and shared resource identity.
  final PdfPageReference reference;

  /// Rebuilds the validated Layer with a new document-scoped identity.
  PdfSourceLayer withIdentity(LayerId replacementId) => PdfSourceLayer._(
    id: replacementId,
    envelopeVersion: envelopeVersion,
    name: name,
    visible: visible,
    opacity: opacity,
    reference: reference,
    extensionData: extensionData,
  );

  @override
  Result<DocumentLayer, StructuredFailure> withObjects(
    Iterable<ObjectEnvelope> replacement,
  ) {
    try {
      if (replacement.iterator.moveNext()) {
        return Err<DocumentLayer, StructuredFailure>(_invalidPdfSourceLayer());
      }
    } on Object {
      return Err<DocumentLayer, StructuredFailure>(_invalidPdfSourceLayer());
    }
    return Ok<DocumentLayer, StructuredFailure>(this);
  }

  @override
  String toString() => 'PdfSourceLayer(id: $id, visible: $visible)';
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

const Set<String> _reservedLayerFields = <String>{
  'envelopeVersion',
  'id',
  'locked',
  'name',
  'objects',
  'opacity',
  'role',
  'type',
  'typeData',
  'typeSchemaVersion',
  'visible',
};

bool _containsReservedLayerField(PreservedMap value) {
  try {
    return value.values.keys.any(_reservedLayerFields.contains);
  } on Object {
    return true;
  }
}

StructuredFailure _invalidPdfSourceLayer() => StructuredFailure(
  code: 'documents.layers.invalid_pdf_source',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'The PDF source Layer does not satisfy its bounded contract.',
);

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
