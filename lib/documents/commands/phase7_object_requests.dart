// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';
import '../objects/image.dart';
import '../objects/object_envelope.dart';
import '../objects/object_registry.dart';
import '../objects/shape.dart';
import '../objects/text.dart';
import '../resources/resource_records.dart';
import 'command_contracts.dart';
import 'document_mutation_coordinator.dart';
import 'revision_snapshot.dart';

/// Replacement-oriented Shape Object command construction.
final class ShapeObjectEditRequest {
  const ShapeObjectEditRequest._();

  /// Replaces direct Shape geometry while preserving style and unknown fields.
  static Result<AtomicObjectReplacementRequest, StructuredFailure>
  replaceGeometry({
    required DocumentId documentId,
    required ObjectEnvelope source,
    required ShapeGeometry geometry,
    required ShapeLimits limits,
    required CommandMetadata metadata,
    required RevisionPreconditions preconditions,
  }) {
    final decoded = ShapePayload.decode(source.payload, limits: limits);
    if (source.typeKey != shapeObjectTypeKey ||
        source.typeSchemaVersion != shapeSchemaVersion ||
        decoded is! Ok<ShapePayload, StructuredFailure>) {
      return Err(_failure('invalid_shape_source'));
    }
    final replacement = ShapePayload.create(
      geometry: geometry,
      style: decoded.value.style,
      limits: limits,
      unknownFields: decoded.value.unknownFields,
    );
    return _shapeRequest(
      documentId: documentId,
      source: source,
      payload: replacement,
      metadata: metadata,
      preconditions: preconditions,
      categories: const ObjectReplacementChangeCategories(
        geometry: true,
        appearance: false,
        text: false,
        metadata: false,
      ),
    );
  }

  /// Replaces direct Shape style while preserving geometry and unknown fields.
  static Result<AtomicObjectReplacementRequest, StructuredFailure>
  replaceStyle({
    required DocumentId documentId,
    required ObjectEnvelope source,
    required ShapeStyle style,
    required ShapeLimits limits,
    required CommandMetadata metadata,
    required RevisionPreconditions preconditions,
  }) {
    final decoded = ShapePayload.decode(source.payload, limits: limits);
    if (source.typeKey != shapeObjectTypeKey ||
        source.typeSchemaVersion != shapeSchemaVersion ||
        decoded is! Ok<ShapePayload, StructuredFailure>) {
      return Err(_failure('invalid_shape_source'));
    }
    final replacement = ShapePayload.create(
      geometry: decoded.value.geometry,
      style: style,
      limits: limits,
      unknownFields: decoded.value.unknownFields,
    );
    return _shapeRequest(
      documentId: documentId,
      source: source,
      payload: replacement,
      metadata: metadata,
      preconditions: preconditions,
      categories: const ObjectReplacementChangeCategories(
        appearance: true,
        text: false,
        metadata: false,
      ),
    );
  }
}

/// Replacement-oriented persistent Text Object command construction.
final class TextObjectEditRequest {
  const TextObjectEditRequest._();

  /// Creates one expected-revision Text payload replacement.
  static Result<AtomicObjectReplacementRequest, StructuredFailure> replace({
    required DocumentId documentId,
    required ObjectEnvelope source,
    required TextPayload payload,
    required TextLimits limits,
    required TextLayoutEngine layoutEngine,
    required CommandMetadata metadata,
    required RevisionPreconditions preconditions,
    required ObjectReplacementChangeCategories changeCategories,
    TextBoxResizeTransformEvidence? textBoxResizeTransform,
  }) {
    final sourcePayload = TextPayload.decode(source.payload, limits: limits);
    final replacementPayload = TextPayload.decode(
      payload.encode(),
      limits: limits,
    );
    if (source.typeKey != textObjectTypeKey ||
        source.typeSchemaVersion != textSchemaVersion ||
        sourcePayload is! Ok<TextPayload, StructuredFailure> ||
        replacementPayload is! Ok<TextPayload, StructuredFailure>) {
      return Err(_failure('invalid_text_source'));
    }
    final dimensionsChanged = _textBoxDimensionsChanged(
      sourcePayload.value,
      replacementPayload.value,
    );
    if ((dimensionsChanged && textBoxResizeTransform == null) ||
        (!dimensionsChanged && textBoxResizeTransform != null) ||
        (textBoxResizeTransform != null &&
            !_validTextBoxResizeTransform(
              source: source,
              sourcePayload: sourcePayload.value,
              replacementPayload: replacementPayload.value,
              evidence: textBoxResizeTransform,
              definition: TextObjectTypeDefinition(limits, layoutEngine),
            ))) {
      return Err(_failure('invalid_text_resize_transform'));
    }
    final classified = TextObjectTypeDefinition.classifyChange(
      sourcePayload.value.encode(),
      replacementPayload.value.encode(),
      textSchemaVersion,
      limits,
      layoutEngine,
    );
    if (classified is! Ok<ObjectPayloadChangeSemantics, StructuredFailure>) {
      return Err(_failure('invalid_text_replacement'));
    }
    final authoritativeCategories = ObjectReplacementChangeCategories(
      geometry: classified.value.geometry,
      appearance: classified.value.appearance,
      text: classified.value.text,
      metadata: classified.value.metadata,
    );
    if (authoritativeCategories != changeCategories) {
      return Err(_failure('inaccurate_text_change_evidence'));
    }
    final envelope = _replacementEnvelope(
      source,
      payload.encode(),
      transform: textBoxResizeTransform?.replacementTransform,
    );
    if (envelope is! Ok<ObjectEnvelope, StructuredFailure>) {
      return Err(_failure('invalid_text_replacement'));
    }
    return AtomicObjectReplacementRequest.create(
      documentId: documentId,
      metadata: metadata,
      preconditions: preconditions,
      targetIds: [source.id],
      replacements: [envelope.value],
      changeCategories: authoritativeCategories,
      textBoxResizeTransform: textBoxResizeTransform,
    );
  }
}

bool _textBoxDimensionsChanged(TextPayload before, TextPayload after) =>
    before.intrinsicWidth != after.intrinsicWidth ||
    before.intrinsicHeight != after.intrinsicHeight;

bool _validTextBoxResizeTransform({
  required ObjectEnvelope source,
  required TextPayload sourcePayload,
  required TextPayload replacementPayload,
  required TextBoxResizeTransformEvidence evidence,
  required TextObjectTypeDefinition definition,
}) {
  if ((sourcePayload.intrinsicHeight == null) !=
      (replacementPayload.intrinsicHeight == null)) {
    return false;
  }
  if (evidence.kind == TextBoxResizeTransformKind.resize &&
      !_isCornerTextAnchor(evidence.preservedAnchor)) {
    return false;
  }
  if (evidence.kind == TextBoxResizeTransformKind.visibleContentFit) {
    final validated = definition.validateIntrinsicVisibleContentFit(
      sourcePayload.encode(),
      replacementPayload.encode(),
      textSchemaVersion,
    );
    if (validated is! Ok<IntrinsicVisibleContentFitChange, StructuredFailure> ||
        _textAnchor(
              validated.value.horizontalAnchor,
              validated.value.verticalAnchor,
            ) !=
            evidence.preservedAnchor) {
      return false;
    }
  }
  final expected = _expectedTextBoxResizeTransform(
    source.transform,
    sourcePayload,
    replacementPayload,
    evidence.preservedAnchor,
  );
  return expected != null && expected == evidence.replacementTransform;
}

AffineTransform2D? _expectedTextBoxResizeTransform(
  AffineTransform2D source,
  TextPayload before,
  TextPayload after,
  TextBoxResizePreservedAnchor anchor,
) {
  final horizontalFactor = switch (anchor) {
    TextBoxResizePreservedAnchor.topLeft ||
    TextBoxResizePreservedAnchor.centerLeft ||
    TextBoxResizePreservedAnchor.bottomLeft => 0.0,
    TextBoxResizePreservedAnchor.topCenter ||
    TextBoxResizePreservedAnchor.center ||
    TextBoxResizePreservedAnchor.bottomCenter => 0.5,
    TextBoxResizePreservedAnchor.topRight ||
    TextBoxResizePreservedAnchor.centerRight ||
    TextBoxResizePreservedAnchor.bottomRight => 1.0,
  };
  final verticalFactor = switch (anchor) {
    TextBoxResizePreservedAnchor.topLeft ||
    TextBoxResizePreservedAnchor.topCenter ||
    TextBoxResizePreservedAnchor.topRight => 0.0,
    TextBoxResizePreservedAnchor.centerLeft ||
    TextBoxResizePreservedAnchor.center ||
    TextBoxResizePreservedAnchor.centerRight => 0.5,
    TextBoxResizePreservedAnchor.bottomLeft ||
    TextBoxResizePreservedAnchor.bottomCenter ||
    TextBoxResizePreservedAnchor.bottomRight => 1.0,
  };
  final dx = (before.intrinsicWidth - after.intrinsicWidth) * horizontalFactor;
  final beforeHeight = before.intrinsicHeight;
  final afterHeight = after.intrinsicHeight;
  if ((beforeHeight == null) != (afterHeight == null)) return null;
  final dy = beforeHeight != null
      ? (beforeHeight - afterHeight!) * verticalFactor
      : 0.0;
  final delta = Vector2.create(x: dx, y: dy);
  if (delta is! Ok<Vector2, StructuredFailure>) return null;
  final localTranslation = AffineTransform2D.fromOperation(
    TranslationTransformOperation2D(delta.value),
  );
  if (localTranslation is! Ok<AffineTransform2D, StructuredFailure>) {
    return null;
  }
  return localTranslation.value
      .then(source)
      .fold(onOk: (value) => value, onErr: (_) => null);
}

bool _isCornerTextAnchor(TextBoxResizePreservedAnchor anchor) =>
    anchor == TextBoxResizePreservedAnchor.topLeft ||
    anchor == TextBoxResizePreservedAnchor.topRight ||
    anchor == TextBoxResizePreservedAnchor.bottomLeft ||
    anchor == TextBoxResizePreservedAnchor.bottomRight;

TextBoxResizePreservedAnchor _textAnchor(
  IntrinsicHorizontalAnchor horizontal,
  IntrinsicVerticalAnchor vertical,
) => switch ((horizontal, vertical)) {
  (IntrinsicHorizontalAnchor.left, IntrinsicVerticalAnchor.top) =>
    TextBoxResizePreservedAnchor.topLeft,
  (IntrinsicHorizontalAnchor.center, IntrinsicVerticalAnchor.top) =>
    TextBoxResizePreservedAnchor.topCenter,
  (IntrinsicHorizontalAnchor.right, IntrinsicVerticalAnchor.top) =>
    TextBoxResizePreservedAnchor.topRight,
  (IntrinsicHorizontalAnchor.left, IntrinsicVerticalAnchor.center) =>
    TextBoxResizePreservedAnchor.centerLeft,
  (IntrinsicHorizontalAnchor.center, IntrinsicVerticalAnchor.center) =>
    TextBoxResizePreservedAnchor.center,
  (IntrinsicHorizontalAnchor.right, IntrinsicVerticalAnchor.center) =>
    TextBoxResizePreservedAnchor.centerRight,
  (IntrinsicHorizontalAnchor.left, IntrinsicVerticalAnchor.bottom) =>
    TextBoxResizePreservedAnchor.bottomLeft,
  (IntrinsicHorizontalAnchor.center, IntrinsicVerticalAnchor.bottom) =>
    TextBoxResizePreservedAnchor.bottomCenter,
  (IntrinsicHorizontalAnchor.right, IntrinsicVerticalAnchor.bottom) =>
    TextBoxResizePreservedAnchor.bottomRight,
};

/// Coordinator-backed all-or-nothing Image resource and Object publisher.
final class CoordinatorImageAtomicPublisher implements ImageAtomicPublisher {
  /// Creates a publisher for one explicit editable destination.
  const CoordinatorImageAtomicPublisher({
    required this.coordinator,
    required this.pageId,
    required this.layerId,
    required this.metadata,
    required this.maximumOperations,
  });

  /// Sole authoritative mutation gateway.
  final DocumentMutationCoordinator coordinator;

  /// Destination Page.
  final PageId pageId;

  /// Destination content Layer.
  final LayerId layerId;

  /// Persistent command metadata.
  final CommandMetadata metadata;

  /// Explicit collection-operation ceiling.
  final int maximumOperations;

  @override
  Result<void, StructuredFailure> publish(
    ImageAtomicPublicationRequest request,
  ) {
    final revalidated = ImageAtomicPublicationRequest.create(
      preparation: request.preparation,
      object: request.object,
      limits: request.limits,
      expectedDocumentRevision: request.expectedDocumentRevision,
      cancellationToken: request.cancellationToken,
    );
    if (revalidated is! Ok<ImageAtomicPublicationRequest, StructuredFailure>) {
      return Err(_failure('invalid_image_publication'));
    }
    final validRequest = revalidated.value;
    final snapshot = coordinator.snapshot;
    final layerRevision = snapshot.revisions.layerMembership[layerId];
    final pageRevision = snapshot.revisions.pages[pageId];
    final decoded = ImagePayload.decode(
      validRequest.object.payload,
      limits: validRequest.limits,
    );
    if (validRequest.cancellationToken.isCancelled ||
        snapshot.revisions.document != validRequest.expectedDocumentRevision ||
        layerRevision == null ||
        pageRevision == null ||
        validRequest.object.typeKey != imageObjectTypeKey ||
        validRequest.object.typeSchemaVersion != imageSchemaVersion ||
        decoded is! Ok<ImagePayload, StructuredFailure> ||
        decoded.value.encode() != validRequest.preparation.payload.encode() ||
        decoded.value.resourceIdentity !=
            validRequest.preparation.resource.identity ||
        metadata.family != CommandFamily.objectCollectionEdit) {
      return Err(_failure('invalid_image_publication'));
    }
    final command = AtomicObjectCollectionEditRequest.create(
      documentId: snapshot.root.id,
      metadata: metadata,
      preconditions: RevisionPreconditions(
        document: validRequest.expectedDocumentRevision,
        pages: {pageId: pageRevision},
        layerMembership: {layerId: layerRevision},
        resourceCatalog: snapshot.revisions.resourceCatalog,
      ),
      pageId: pageId,
      additions: [
        ObjectCollectionAddition(layerId: layerId, object: validRequest.object),
      ],
      resourceAdditions: [
        DocumentResourceSnapshot(validRequest.preparation.resource),
      ],
      maximumOperations: maximumOperations,
    );
    if (command is! Ok<AtomicObjectCollectionEditRequest, StructuredFailure>) {
      return Err(_failure('invalid_image_publication'));
    }
    final committed = coordinator.execute(command.value);
    return committed is Ok<CommandCommit, CommandFailure>
        ? const Ok(null)
        : Err(_failure('image_publication_rejected'));
  }
}

Result<AtomicObjectReplacementRequest, StructuredFailure> _shapeRequest({
  required DocumentId documentId,
  required ObjectEnvelope source,
  required Result<ShapePayload, StructuredFailure> payload,
  required CommandMetadata metadata,
  required RevisionPreconditions preconditions,
  required ObjectReplacementChangeCategories categories,
}) {
  if (payload is! Ok<ShapePayload, StructuredFailure>) {
    return Err(_failure('invalid_shape_replacement'));
  }
  final envelope = _replacementEnvelope(source, payload.value.encode());
  if (envelope is! Ok<ObjectEnvelope, StructuredFailure>) {
    return Err(_failure('invalid_shape_replacement'));
  }
  return AtomicObjectReplacementRequest.create(
    documentId: documentId,
    metadata: metadata,
    preconditions: preconditions,
    targetIds: [source.id],
    replacements: [envelope.value],
    changeCategories: categories,
  );
}

Result<ObjectEnvelope, StructuredFailure> _replacementEnvelope(
  ObjectEnvelope source,
  PreservedData payload, {
  AffineTransform2D? transform,
}) => ObjectEnvelope.create(
  id: source.id,
  typeKey: source.typeKey,
  envelopeVersion: source.envelopeVersion,
  typeSchemaVersion: source.typeSchemaVersion,
  transform: transform ?? source.transform,
  visible: source.visible,
  locked: source.locked,
  payload: payload,
  extensionData: source.extensionData,
);

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.commands.phase7.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Object edit request is invalid.',
);
