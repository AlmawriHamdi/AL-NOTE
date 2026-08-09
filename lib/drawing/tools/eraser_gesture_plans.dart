// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../documents/commands.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../geometry.dart';

/// Immutable transient rendering evidence for one affected handwriting Object.
final class EraserPreviewObject {
  /// Creates defensively copied preview evidence.
  EraserPreviewObject._({
    required this.objectId,
    required this.localToPage,
    required Iterable<EraserPreviewStroke> strokes,
  }) : strokes = List<EraserPreviewStroke>.unmodifiable(strokes);

  /// Object hidden from committed rendering while this preview is shown.
  final ObjectId objectId;

  /// Transform applied to every preview Stroke.
  final AffineTransform2D localToPage;

  /// Complete current survivor set for the Object.
  final List<EraserPreviewStroke> strokes;
}

/// One transient survivor paired with its already resolved Page geometry.
final class EraserPreviewStroke {
  /// Creates immutable prepared preview evidence.
  const EraserPreviewStroke({required this.stroke, required this.geometry});

  /// Current transient handwriting Stroke value.
  final HandwritingStroke stroke;

  /// Transform-correct geometry resolved exactly once for [stroke].
  final TransformedStrokeGeometry geometry;
}

/// Bounded work evidence returned after one newly accepted Eraser point.
final class EraserGestureUpdate {
  /// Creates immutable update evidence.
  EraserGestureUpdate._(
    Iterable<ObjectId> changedObjectIds, {
    required this.newlyAffectedStrokeCount,
  }) : changedObjectIds = Set<ObjectId>.unmodifiable(changedObjectIds);

  /// Objects whose cached transient rendering must be refreshed.
  final Set<ObjectId> changedObjectIds;

  /// Strokes first affected by this point or swept segment.
  final int newlyAffectedStrokeCount;
}

/// Prepared whole-stroke Eraser state that decodes and resolves geometry once.
final class WholeEraseGesturePlan {
  WholeEraseGesturePlan._({
    required this.document,
    required this.pageId,
    required this.radius,
    required this.maximumPoints,
    required this.maximumTargets,
    required this.maximumOperations,
    required this.handwritingLimits,
    required List<_WholeObjectPlan> objects,
    required List<_WholeCandidate> candidates,
  }) : _objects = objects,
       _candidates = candidates;

  /// Prepares immutable gesture-local Object, revision, payload, and geometry
  /// evidence without UUID allocation or document publication.
  static Result<WholeEraseGesturePlan, StructuredFailure> prepare({
    required DocumentCoordinatorSnapshot document,
    required PageId pageId,
    required double radius,
    required HandwritingLimits handwritingLimits,
    required ObjectRegistry objectRegistry,
    required StrokeGeometryResolver geometryResolver,
    HandwritingGeometryCache? geometryCache,
    required int maximumObjects,
    required int maximumStrokes,
    required int maximumPoints,
    required int maximumTargets,
    required int maximumOperations,
  }) {
    if (!_validLimits(
          radius,
          maximumPoints,
          maximumTargets,
          maximumOperations,
        ) ||
        !_validCaptureLimits(maximumObjects, maximumStrokes)) {
      return Err(_failure('invalid_whole_plan'));
    }
    final page = document.root.pages
        .where((value) => value.id == pageId)
        .firstOrNull;
    final pageRevision = document.revisions.pages[pageId];
    if (page == null || pageRevision == null) {
      return Err(_failure('missing_whole_page'));
    }
    final objects = <_WholeObjectPlan>[];
    final candidates = <_WholeCandidate>[];
    for (final layer in page.layers) {
      if (layer is! ContentLayer || !layer.visible || layer.locked) continue;
      final membershipRevision = document.revisions.layerMembership[layer.id];
      if (membershipRevision == null) return Err(_failure('missing_revision'));
      for (final object in layer.objects) {
        if (!object.visible ||
            object.locked ||
            object.typeKey != handwritingObjectTypeKey ||
            object.typeSchemaVersion != handwritingSchemaVersion) {
          continue;
        }
        if (objects.length >= maximumObjects) {
          return Err(_failure('whole_object_limit'));
        }
        if (!_eligibleHandwritingObject(objectRegistry, object)) continue;
        final prepared = geometryCache?.prepare(
          object: object,
          handwritingLimits: handwritingLimits,
          geometryResolver: geometryResolver,
        );
        final payload =
            prepared?.fold<HandwritingPayload?>(
              onOk: (value) => value.payload,
              onErr: (_) => null,
            ) ??
            HandwritingPayload.decode(
              object.payload,
              limits: handwritingLimits,
            ).fold<HandwritingPayload?>(
              onOk: (value) => value,
              onErr: (_) => null,
            );
        final objectRevision = document.revisions.objects[object.id];
        if (payload == null || objectRevision == null) {
          return Err(_failure('invalid_whole_object'));
        }
        final plan = _WholeObjectPlan(
          layerId: layer.id,
          object: object,
          payload: payload,
          objectRevision: objectRevision,
          membershipRevision: membershipRevision,
        );
        objects.add(plan);
        for (
          var strokeIndex = 0;
          strokeIndex < payload.strokes.length;
          strokeIndex += 1
        ) {
          final stroke = payload.strokes[strokeIndex];
          if (candidates.length >= maximumStrokes) {
            return Err(_failure('whole_stroke_limit'));
          }
          final geometry =
              prepared is Ok<PreparedHandwritingGeometry, StructuredFailure>
              ? Ok<TransformedStrokeGeometry, StructuredFailure>(
                  prepared.value.geometries[strokeIndex],
                )
              : geometryResolver.resolve(
                  stroke: stroke,
                  localToPage: object.transform,
                );
          if (geometry is! Ok<TransformedStrokeGeometry, StructuredFailure>) {
            return Err(_failure('whole_geometry_unavailable'));
          }
          final candidate = _WholeCandidate(plan, stroke, geometry.value);
          candidates.add(candidate);
          plan.candidates.add(candidate);
        }
      }
    }
    return Ok(
      WholeEraseGesturePlan._(
        document: document,
        pageId: pageId,
        radius: radius,
        maximumPoints: maximumPoints,
        maximumTargets: maximumTargets,
        maximumOperations: maximumOperations,
        handwritingLimits: handwritingLimits,
        objects: objects,
        candidates: candidates,
      ),
    );
  }

  /// Captured document baseline.
  final DocumentCoordinatorSnapshot document;

  /// Captured Page identity.
  final PageId pageId;

  /// Page-space Eraser radius fixed at gesture start.
  final double radius;

  /// Maximum accepted pointer points.
  final int maximumPoints;

  /// Maximum affected Stroke targets.
  final int maximumTargets;

  /// Maximum affected Object operations.
  final int maximumOperations;

  /// Handwriting construction limits.
  final HandwritingLimits handwritingLimits;

  final List<_WholeObjectPlan> _objects;
  final List<_WholeCandidate> _candidates;
  Point2? _lastPoint;
  int _pointCount = 0;
  int _segmentCount = 0;
  int _geometryCheckCount = 0;
  int _geometryElementExaminationCount = 0;
  int _affectedCount = 0;

  /// Accepted pointer-point count.
  int get pointCount => _pointCount;

  /// Newly processed point/swept-segment count.
  int get processedSegmentCount => _segmentCount;

  /// Cached-geometry intersection checks performed so far.
  int get geometryCheckCount => _geometryCheckCount;

  /// Spatially narrowed geometry elements examined across pointer updates.
  int get geometryElementExaminationCount => _geometryElementExaminationCount;

  /// Geometry resolutions completed exactly once during preparation.
  int get geometryResolutionCount => _candidates.length;

  /// Number of unique affected Strokes.
  int get affectedStrokeCount => _affectedCount;

  /// Whether [latest] still has the captured content identity.
  bool isCurrent(DocumentCoordinatorSnapshot latest) =>
      latest.currentContentIdentity == document.currentContentIdentity;

  /// Processes only the new point or swept segment against cached geometry.
  Result<EraserGestureUpdate, StructuredFailure> acceptPoint(Point2 point) {
    if (_pointCount >= maximumPoints) return Err(_failure('eraser_path_limit'));
    final first = _lastPoint ?? point;
    final path = SweptPath.create([first, point], maximumPoints: 2);
    if (path is! Ok<SweptPath, StructuredFailure>) {
      return Err(_failure('invalid_segment'));
    }
    final sweptBounds = _sweptBounds(first, point, radius);
    final changed = <ObjectId>{};
    var newlyAffected = 0;
    for (final candidate in _candidates) {
      if (candidate.affected) continue;
      if (sweptBounds != null &&
          !_boundsIntersect(candidate.geometry.bounds, sweptBounds))
        continue;
      _geometryCheckCount += 1;
      final query = candidate.geometry.querySweptPath(path.value, radius);
      if (query
          is! Ok<
            ({bool intersects, int examinedElements}),
            StructuredFailure
          >) {
        return Err(_failure('whole_geometry_unavailable'));
      }
      _geometryElementExaminationCount += query.value.examinedElements;
      if (!query.value.intersects) continue;
      if (_affectedCount >= maximumTargets) {
        return Err(_failure('whole_target_limit'));
      }
      candidate.affected = true;
      candidate.owner.erased.add(candidate.stroke.id);
      _affectedCount += 1;
      newlyAffected += 1;
      changed.add(candidate.owner.object.id);
    }
    if (_objects.where((value) => value.erased.isNotEmpty).length >
        maximumOperations) {
      return Err(_failure('eraser_operation_limit'));
    }
    _lastPoint = point;
    _pointCount += 1;
    _segmentCount += 1;
    return Ok(
      EraserGestureUpdate._(changed, newlyAffectedStrokeCount: newlyAffected),
    );
  }

  /// Current exact survivor evidence for affected Objects.
  List<EraserPreviewObject> get previews => List.unmodifiable(
    _objects
        .where((value) => value.erased.isNotEmpty)
        .map(
          (value) => EraserPreviewObject._(
            objectId: value.object.id,
            localToPage: value.object.transform,
            strokes: value.candidates
                .where((candidate) => !candidate.affected)
                .map(
                  (candidate) => EraserPreviewStroke(
                    stroke: candidate.stroke,
                    geometry: candidate.geometry,
                  ),
                ),
          ),
        ),
  );

  /// Builds current preview evidence for one changed Object, when affected.
  EraserPreviewObject? previewFor(ObjectId objectId) {
    final value = _objects
        .where(
          (candidate) =>
              candidate.object.id == objectId && candidate.erased.isNotEmpty,
        )
        .firstOrNull;
    return value == null
        ? null
        : EraserPreviewObject._(
            objectId: value.object.id,
            localToPage: value.object.transform,
            strokes: value.candidates
                .where((candidate) => !candidate.affected)
                .map(
                  (candidate) => EraserPreviewStroke(
                    stroke: candidate.stroke,
                    geometry: candidate.geometry,
                  ),
                ),
          );
  }

  /// Builds the one terminal atomic request from prepared target evidence.
  Result<AtomicObjectCollectionEditRequest, StructuredFailure> createRequest({
    required UuidGenerator uuidGenerator,
  }) {
    final affected = _objects
        .where((value) => value.erased.isNotEmpty)
        .toList();
    if (affected.isEmpty) return Err(_failure('nothing_erased'));
    final replacements = <ObjectEnvelope>[];
    final removals = <ObjectId>[];
    final objectRevisions = <ObjectId, Revision>{};
    final membershipRevisions = <LayerId, Revision>{};
    for (final plan in affected) {
      final survivors = plan.payload.strokes
          .where((stroke) => !plan.erased.contains(stroke.id))
          .toList(growable: false);
      objectRevisions[plan.object.id] = plan.objectRevision;
      membershipRevisions[plan.layerId] = plan.membershipRevision;
      if (survivors.isEmpty) {
        removals.add(plan.object.id);
        continue;
      }
      final replacement = _replacement(
        plan.object,
        plan.payload,
        survivors,
        handwritingLimits,
      );
      if (replacement is Err<ObjectEnvelope, StructuredFailure>) {
        return Err(replacement.error);
      }
      replacements.add(
        (replacement as Ok<ObjectEnvelope, StructuredFailure>).value,
      );
    }
    final occupiedUuids = _occupiedUuids(document.root);
    final correlation = _generate(uuidGenerator);
    if (correlation == null || !occupiedUuids.add(correlation.value)) {
      return Err(_failure('uuid_generation'));
    }
    return AtomicObjectCollectionEditRequest.create(
      documentId: document.root.id,
      pageId: pageId,
      metadata: CommandMetadata(
        family: CommandFamily.objectCollectionEdit,
        correlationId: CommandCorrelationId.fromUuid(correlation),
        description: 'Erase strokes',
      ),
      preconditions: RevisionPreconditions(
        pages: {pageId: document.revisions.pages[pageId]!},
        objects: objectRevisions,
        layerMembership: membershipRevisions,
      ),
      removals: removals,
      replacements: replacements,
      replacementChangeCategories: ObjectReplacementChangeCategories(
        geometry: replacements.isNotEmpty,
        appearance: false,
        text: false,
        metadata: replacements.isNotEmpty,
      ),
      maximumOperations: maximumOperations,
    );
  }
}

final class _WholeObjectPlan {
  _WholeObjectPlan({
    required this.layerId,
    required this.object,
    required this.payload,
    required this.objectRevision,
    required this.membershipRevision,
  });
  final LayerId layerId;
  final ObjectEnvelope object;
  final HandwritingPayload payload;
  final Revision objectRevision;
  final Revision membershipRevision;
  final Set<StrokeId> erased = {};
  final List<_WholeCandidate> candidates = [];
}

final class _WholeCandidate {
  _WholeCandidate(this.owner, this.stroke, this.geometry);
  final _WholeObjectPlan owner;
  final HandwritingStroke stroke;
  final TransformedStrokeGeometry geometry;
  bool affected = false;
}

bool _validCaptureLimits(int objects, int strokes) =>
    objects > 0 &&
    strokes > 0 &&
    objects <= Revision.maximumValue &&
    strokes <= Revision.maximumValue;

bool _eligibleHandwritingObject(
  ObjectRegistry registry,
  ObjectEnvelope object,
) {
  try {
    final resolution = registry.resolve(object);
    if (resolution is! SupportedObjectResolution) return false;
    final capabilities = resolution.definition.capabilities;
    return resolution.envelope.typeKey == handwritingObjectTypeKey &&
        resolution.envelope.typeSchemaVersion == handwritingSchemaVersion &&
        capabilities.hasIntrinsicGeometry &&
        capabilities.selectable &&
        resolution.supportsPayloadChangeClassification;
  } on Object {
    return false;
  }
}

bool _validLimits(double radius, int points, int targets, int operations) =>
    radius.isFinite &&
    radius >= 0 &&
    points > 0 &&
    targets > 0 &&
    operations > 0 &&
    points <= Revision.maximumValue &&
    targets <= Revision.maximumValue &&
    operations <= Revision.maximumValue;

Result<ObjectEnvelope, StructuredFailure> _replacement(
  ObjectEnvelope object,
  HandwritingPayload previous,
  List<HandwritingStroke> survivors,
  HandwritingLimits limits,
) {
  final payload = HandwritingPayload.create(
    strokes: survivors,
    limits: limits,
    unknownFields: previous.unknownFields,
  );
  if (payload is! Ok<HandwritingPayload, StructuredFailure>) {
    return Err(_failure('payload_unavailable'));
  }
  return ObjectEnvelope.create(
    id: object.id,
    typeKey: object.typeKey,
    envelopeVersion: object.envelopeVersion,
    typeSchemaVersion: object.typeSchemaVersion,
    transform: object.transform,
    visible: object.visible,
    locked: object.locked,
    payload: payload.value.encode(),
    extensionData: object.extensionData,
  );
}

UuidIdentifier? _generate(UuidGenerator generator) {
  try {
    final value = generator.generateV4();
    return value is Ok<UuidIdentifier, StructuredFailure> ? value.value : null;
  } on Object {
    return null;
  }
}

Rect2? _sweptBounds(Point2 first, Point2 second, double radius) =>
    Rect2.fromEdges(
      left: math.min(first.x, second.x) - radius,
      top: math.min(first.y, second.y) - radius,
      right: math.max(first.x, second.x) + radius,
      bottom: math.max(first.y, second.y) + radius,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);

bool _boundsIntersect(Rect2 first, Rect2 second) =>
    first.left <= second.right &&
    first.right >= second.left &&
    first.top <= second.bottom &&
    first.bottom >= second.top;

Set<String> _occupiedUuids(DocumentRoot root) => {
  root.id.uuid.value,
  for (final page in root.pages) ...[
    page.id.uuid.value,
    for (final layer in page.layers) ...[
      layer.id.uuid.value,
      for (final object in layer.objects) object.id.uuid.value,
    ],
  ],
};

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.tools.gesture_plan.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Eraser gesture input is invalid.',
);
