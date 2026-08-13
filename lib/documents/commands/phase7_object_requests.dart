// SPDX-License-Identifier: GPL-3.0-or-later

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
    final envelope = _replacementEnvelope(source, payload.encode());
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
    );
  }
}

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
  PreservedData payload,
) => ObjectEnvelope.create(
  id: source.id,
  typeKey: source.typeKey,
  envelopeVersion: source.envelopeVersion,
  typeSchemaVersion: source.typeSchemaVersion,
  transform: source.transform,
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
