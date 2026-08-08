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
import 'tools.dart';

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
    Iterable<EraserPreviewSegmentUpdate> previewSegmentUpdates = const [],
  }) : changedObjectIds = Set<ObjectId>.unmodifiable(changedObjectIds),
       previewSegmentUpdates = List.unmodifiable(previewSegmentUpdates);

  /// Objects whose cached transient rendering must be refreshed.
  final Set<ObjectId> changedObjectIds;

  /// Strokes first affected by this point or swept segment.
  final int newlyAffectedStrokeCount;

  /// Incremental exact survivor ranges changed by this accepted segment.
  final List<EraserPreviewSegmentUpdate> previewSegmentUpdates;
}

/// Immutable Object identity and Page bounds eligible for visual erasure.
final class EraserVisualObjectEvidence {
  const EraserVisualObjectEvidence._({
    required this.objectId,
    required this.pageBounds,
  });

  /// Eligible handwriting Object identity.
  final ObjectId objectId;

  /// Complete transformed Page-space bounds of the Object's strokes.
  final Rect2 pageBounds;
}

/// Immutable evidence from one bounded partial-Eraser processing batch.
final class PartialEraseWorkBatch {
  PartialEraseWorkBatch._({
    required this.pointCompleted,
    required this.candidateSourceSegments,
    required this.intervalClassifications,
    required this.classificationChecks,
    this.update,
  });

  /// Whether the pending pointer point completed in this batch.
  final bool pointCompleted;

  /// Candidate source segments completed in this batch.
  final int candidateSourceSegments;

  /// Direct interval classifications completed in this batch.
  final int intervalClassifications;

  /// Direct interval-distance checks completed in this batch.
  final int classificationChecks;

  /// Exact preview update, present only when [pointCompleted] is true.
  final EraserGestureUpdate? update;
}

/// Exact prepared survivor geometry for one source Stroke segment.
final class EraserPreviewSegmentUpdate {
  EraserPreviewSegmentUpdate._({
    required this.objectId,
    required this.strokeId,
    required this.sourceSegment,
    required this.style,
    required Iterable<StrokeGeometryElement> elements,
  }) : elements = List.unmodifiable(elements);

  /// Affected Object whose committed rendering must be excluded.
  final ObjectId objectId;

  /// Source Stroke owning this segment.
  final StrokeId strokeId;

  /// Stable zero-based source sample-segment index.
  final int sourceSegment;

  /// Exact source appearance retained by every survivor.
  final StrokeStyle style;

  /// Transparent visible survivor geometry for this segment.
  final List<StrokeGeometryElement> elements;
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

/// Incremental partial-Eraser state that never replays accepted path segments.
final class PartialEraseGesturePlan {
  PartialEraseGesturePlan._({
    required this.document,
    required this.pageId,
    required this.radius,
    required this.maximumPoints,
    required this.maximumIntersections,
    required this.maximumFragments,
    required this.maximumOutputSamples,
    required this.maximumOperations,
    required this.maximumClassificationChecks,
    required this.handwritingLimits,
    required this.geometryResolver,
    required int geometryResolutionCount,
    required List<_PartialObjectPlan> objects,
    required Set<StrokeId> existingStrokeIds,
  }) : _objects = objects,
       _geometryResolutionCount = geometryResolutionCount,
       _existingStrokeIds = existingStrokeIds;

  /// Captures eligible Objects, payloads, and revisions once without UUID use.
  static Result<PartialEraseGesturePlan, StructuredFailure> prepare({
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
    required int maximumIntersections,
    required int maximumFragments,
    required int maximumOutputSamples,
    required int maximumOperations,
    required int maximumClassificationChecks,
  }) {
    if (!_validLimits(
          radius,
          maximumPoints,
          maximumFragments,
          maximumOperations,
        ) ||
        maximumIntersections < 0 ||
        maximumOutputSamples < 0 ||
        maximumClassificationChecks <= 0 ||
        maximumClassificationChecks > Revision.maximumValue ||
        !_validCaptureLimits(maximumObjects, maximumStrokes)) {
      return Err(_failure('invalid_partial_plan'));
    }
    final page = document.root.pages
        .where((value) => value.id == pageId)
        .firstOrNull;
    if (page == null || document.revisions.pages[pageId] == null) {
      return Err(_failure('missing_partial_page'));
    }
    final existing = <StrokeId>{};
    var capturedObjectCount = 0;
    var capturedStrokeCount = 0;
    for (final object
        in document.root.pages
            .expand((value) => value.layers.whereType<ContentLayer>())
            .expand((value) => value.objects)) {
      if (object.typeKey != handwritingObjectTypeKey ||
          object.typeSchemaVersion != handwritingSchemaVersion)
        continue;
      if (capturedObjectCount >= maximumObjects) {
        return Err(_failure('partial_object_limit'));
      }
      capturedObjectCount += 1;
      if (!_eligibleHandwritingObject(objectRegistry, object)) continue;
      final payload =
          geometryCache
              ?.prepare(
                object: object,
                handwritingLimits: handwritingLimits,
                geometryResolver: geometryResolver,
              )
              .fold<HandwritingPayload?>(
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
      if (payload == null) return Err(_failure('invalid_partial_object'));
      for (final stroke in payload.strokes) {
        if (capturedStrokeCount >= maximumStrokes) {
          return Err(_failure('partial_stroke_limit'));
        }
        capturedStrokeCount += 1;
        if (!existing.add(stroke.id))
          return Err(_failure('duplicate_stroke_identity'));
      }
    }
    final objects = <_PartialObjectPlan>[];
    var geometryResolutionCount = 0;
    for (final layer in page.layers) {
      if (layer is! ContentLayer || !layer.visible || layer.locked) continue;
      final membership = document.revisions.layerMembership[layer.id];
      if (membership == null) return Err(_failure('missing_revision'));
      for (final object in layer.objects) {
        if (!object.visible ||
            object.locked ||
            object.typeKey != handwritingObjectTypeKey ||
            object.typeSchemaVersion != handwritingSchemaVersion)
          continue;
        if (objects.length >= maximumObjects) {
          return Err(_failure('partial_object_limit'));
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
        final revision = document.revisions.objects[object.id];
        if (payload == null || revision == null)
          return Err(_failure('invalid_partial_object'));
        final working = <_WorkingStroke>[];
        for (
          var strokeIndex = 0;
          strokeIndex < payload.strokes.length;
          strokeIndex += 1
        ) {
          final stroke = payload.strokes[strokeIndex];
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
            return Err(_failure('partial_geometry_unavailable'));
          }
          geometryResolutionCount += 1;
          final erasure = geometryResolver.prepareStrokeErasure(
            stroke: stroke,
            localToPage: object.transform,
          );
          if (erasure
              is! Ok<PreparedStrokeErasureGeometry, StructuredFailure>) {
            return Err(_failure('partial_geometry_unavailable'));
          }
          working.add(
            _WorkingStroke(stroke, false, geometry.value, erasure.value),
          );
        }
        objects.add(
          _PartialObjectPlan(
            layerId: layer.id,
            object: object,
            payload: payload,
            objectRevision: revision,
            membershipRevision: membership,
            working: working,
          ),
        );
      }
    }
    return Ok(
      PartialEraseGesturePlan._(
        document: document,
        pageId: pageId,
        radius: radius,
        maximumPoints: maximumPoints,
        maximumIntersections: maximumIntersections,
        maximumFragments: maximumFragments,
        maximumOutputSamples: maximumOutputSamples,
        maximumOperations: maximumOperations,
        maximumClassificationChecks: maximumClassificationChecks,
        handwritingLimits: handwritingLimits,
        geometryResolver: geometryResolver,
        geometryResolutionCount: geometryResolutionCount,
        objects: objects,
        existingStrokeIds: existing,
      ),
    );
  }

  /// Captured document baseline.
  final DocumentCoordinatorSnapshot document;

  /// Captured Page identity.
  final PageId pageId;

  /// Fixed Page-space radius.
  final double radius;

  /// Maximum accepted pointer points.
  final int maximumPoints;

  /// Cumulative intersection ceiling.
  final int maximumIntersections;

  /// Cumulative generated-fragment ceiling.
  final int maximumFragments;

  /// Cumulative generated-sample ceiling.
  final int maximumOutputSamples;

  /// Maximum affected Object operations.
  final int maximumOperations;

  /// Aggregate direct interval-classification work allowed for this gesture.
  final int maximumClassificationChecks;

  /// Handwriting validation limits.
  final HandwritingLimits handwritingLimits;

  /// Shared geometry resolver.
  final StrokeGeometryResolver geometryResolver;

  final List<_PartialObjectPlan> _objects;
  final Set<StrokeId> _existingStrokeIds;
  Point2? _lastPoint;
  int _pointCount = 0;
  int _segmentCount = 0;
  int _splitInvocationCount = 0;
  int _fragmentCount = 0;
  final int _geometryResolutionCount;
  int _terminalMaterializationCount = 0;
  int _terminalSourceSegmentPassCount = 0;
  int _intervalEvidenceCount = 0;
  int _previewRangeMaterializationCount = 0;
  int _candidateSourceSegmentCount = 0;
  int _spatialElementExaminationCount = 0;
  int _classificationCheckCount = 0;
  int _maximumClassificationDepth = 0;
  int _maximumPendingClassificationIntervals = 0;
  int _intervalMergeCount = 0;
  int _uuidAllocationCount = 0;
  int _classificationCacheHitCount = 0;
  int _classificationGeometryResolutionCount = 0;
  int _processedBatchCount = 0;
  int _maximumProcessedBatchSize = 0;
  _PendingPartialPoint? _pendingPoint;
  bool _finalPreviewMaterialized = false;

  /// Accepted pointer-point count.
  int get pointCount => _pointCount;

  /// Newly processed point/swept-segment count.
  int get processedSegmentCount => _segmentCount;

  /// Incremental fragment-classification calls performed.
  int get splitInvocationCount => _splitInvocationCount;

  /// Object payload decode count fixed at preparation time.
  int get preparedObjectCount => _objects.length;

  /// Source and newly created fragment geometries resolved so far.
  int get geometryResolutionCount => _geometryResolutionCount;

  /// Cumulative fragment geometries created and resolved by accepted segments.
  int get fragmentGeometryResolutionCount => _fragmentCount;

  /// Exact affected-Stroke materializations performed at terminal creation.
  int get terminalMaterializationCount => _terminalMaterializationCount;

  /// Source sample segments visited by terminal materialization.
  int get terminalSourceSegmentPassCount => _terminalSourceSegmentPassCount;

  /// Changed survivor ranges materialized for incremental preview updates.
  int get previewRangeMaterializationCount => _previewRangeMaterializationCount;

  /// Candidate Strokes captured once during preparation.
  int get candidateStrokeCount =>
      _objects.fold(0, (count, object) => count + object.working.length);

  /// Candidate source segments returned by spatial queries so far.
  int get candidateSourceSegmentCount => _candidateSourceSegmentCount;

  /// Spatial-index elements examined across accepted and rejected updates.
  int get spatialElementExaminationCount => _spatialElementExaminationCount;

  /// Aggregate direct interval-distance evaluations consumed by this gesture.
  int get classificationCheckCount => _classificationCheckCount;

  /// Maximum fixed direct-search depth reached by one classification.
  int get maximumClassificationDepth => _maximumClassificationDepth;

  /// Maximum pending interval work; direct classification keeps this at one.
  int get maximumPendingClassificationIntervals =>
      _maximumPendingClassificationIntervals;

  /// Interval merge operations performed across accepted pointer segments.
  int get intervalMergeCount => _intervalMergeCount;

  /// Fragment count produced by the one terminal materialization pass.
  int get fragmentCount => _fragmentCount;

  /// UUID generation attempts made only during terminal request creation.
  int get uuidAllocationCount => _uuidAllocationCount;

  /// Exact source-segment interval classifications reused by this gesture.
  int get classificationCacheHitCount => _classificationCacheHitCount;

  /// Preparation, classification-envelope, and preview geometry resolutions.
  int get totalGeometryResolutionCount =>
      _geometryResolutionCount +
      _classificationGeometryResolutionCount +
      _previewRangeMaterializationCount;

  /// Stroke-level parametric erasure preparations reused by the gesture.
  int get erasurePreparationCount => candidateStrokeCount;

  /// Number of explicitly bounded input batches processed by this gesture.
  int get processedBatchCount => _processedBatchCount;

  /// Largest accepted bounded batch size.
  int get maximumProcessedBatchSize => _maximumProcessedBatchSize;

  /// Whether the plan has any predictive change.
  bool get hasChanges => _objects.any((value) => value.affected);

  /// Bounded immutable visual-erasure eligibility captured at preparation.
  List<EraserVisualObjectEvidence> get visualObjectEvidence =>
      List.unmodifiable(
        _objects.expand((object) sync* {
          if (object.working.isEmpty) return;
          var bounds = object.working.first.geometry.bounds;
          for (final working in object.working.skip(1)) {
            final next = working.geometry.bounds;
            bounds = _rect(
              math.min(bounds.left, next.left),
              math.min(bounds.top, next.top),
              math.max(bounds.right, next.right),
              math.max(bounds.bottom, next.bottom),
            );
          }
          yield EraserVisualObjectEvidence._(
            objectId: object.object.id,
            pageBounds: bounds,
          );
        }),
      );

  /// Whether a pointer segment has retained candidate work for a later batch.
  bool get hasPendingPointWork => _pendingPoint != null;

  /// Whether [latest] still has the captured content identity.
  bool isCurrent(DocumentCoordinatorSnapshot latest) =>
      latest.currentContentIdentity == document.currentContentIdentity;

  /// Classifies only the newest point or swept segment against cached source
  /// geometry. Exact survivor materialization is deferred to [createRequest].
  Result<EraserGestureUpdate, StructuredFailure> acceptPoint(Point2 point) {
    if (_pendingPoint != null) {
      return Err(_failure('partial_point_work_pending'));
    }
    if (_pointCount >= maximumPoints) return Err(_failure('eraser_path_limit'));
    final first = _lastPoint ?? point;
    final path = SweptPath.create([first, point], maximumPoints: 2);
    if (path is! Ok<SweptPath, StructuredFailure>) {
      return Err(_failure('invalid_segment'));
    }
    final sweptBounds = _sweptBounds(first, point, radius);
    final changed = <ObjectId>{};
    final previewUpdates = <EraserPreviewSegmentUpdate>[];
    final stagedIntervals =
        <
          (_PartialObjectPlan, _WorkingStroke, int),
          List<StrokeErasureInterval>
        >{};
    var stagedIntervalEvidenceCount = _intervalEvidenceCount;
    var newlyAffected = 0;
    for (final object in _objects) {
      for (final working in object.working) {
        if (sweptBounds != null &&
            !_boundsIntersect(working.geometry.bounds, sweptBounds)) {
          continue;
        }
        final query = working.geometry.querySweptPathSourceSegments(
          path.value,
          radius,
        );
        if (query
            is! Ok<
              ({List<int> sourceSegments, int examinedElements}),
              StructuredFailure
            >) {
          return Err(_failure('partial_geometry_unavailable'));
        }
        _spatialElementExaminationCount += query.value.examinedElements;
        _candidateSourceSegmentCount += query.value.sourceSegments.length;
        for (final segmentIndex in query.value.sourceSegments) {
          _splitInvocationCount += 1;
          final cacheKey = _classificationCacheKey(
            segmentIndex,
            path.value.points.first,
            path.value.points.last,
          );
          var classifiedIntervals = working.classificationCache[cacheKey];
          if (classifiedIntervals == null) {
            final remainingChecks =
                maximumClassificationChecks - _classificationCheckCount;
            if (remainingChecks <= 0) {
              return Err(_failure('partial_classification_work_limit'));
            }
            final classified = geometryResolver
                .classifyPreparedSourceSegmentErasure(
                  prepared: working.erasure,
                  sourceSegment: segmentIndex,
                  eraserSegment: path.value,
                  radius: radius,
                  maximumChecks: math.min(
                    remainingChecks,
                    geometryResolver.limits.maximumContainmentChecks,
                  ),
                );
            if (classified
                is! Ok<
                  StrokeErasureClassificationEvidence,
                  StructuredFailure
                >) {
              if (classified
                      is Err<
                        StrokeErasureClassificationEvidence,
                        StructuredFailure
                      > &&
                  classified.error.code ==
                      'drawing.geometry.erasure_classification_limit') {
                _classificationCheckCount = maximumClassificationChecks;
                return Err(_failure('partial_classification_work_limit'));
              }
              return Err(_failure('partial_split_unavailable'));
            }
            _classificationCheckCount += classified.value.classificationChecks;
            _classificationGeometryResolutionCount +=
                classified.value.geometryResolutions;
            _spatialElementExaminationCount +=
                classified.value.spatialElementsExamined;
            _maximumClassificationDepth = math.max(
              _maximumClassificationDepth,
              classified.value.maximumSearchDepth,
            );
            _maximumPendingClassificationIntervals = math.max(
              _maximumPendingClassificationIntervals,
              classified.value.maximumPendingIntervals,
            );
            classifiedIntervals = classified.value.intervals;
            working.classificationCache[cacheKey] = classifiedIntervals;
          } else {
            _classificationCacheHitCount += 1;
          }
          if (classifiedIntervals.isEmpty) continue;
          final key = (object, working, segmentIndex);
          final existing =
              stagedIntervals[key] ??
              working.erasedIntervals[segmentIndex] ??
              const [];
          if (_sameIntervals(existing, classifiedIntervals)) continue;
          _intervalMergeCount += 1;
          final merged = _mergeIntervals(existing, classifiedIntervals);
          if (_sameIntervals(existing, merged)) continue;
          final previousLength = existing.length;
          final nextEvidence =
              stagedIntervalEvidenceCount - previousLength + merged.length;
          if (nextEvidence > math.max(maximumIntersections, maximumFragments)) {
            return Err(_failure('eraser_cumulative_limit'));
          }
          stagedIntervals[key] = merged;
          stagedIntervalEvidenceCount = nextEvidence;
        }
      }
    }
    final changedObjects = stagedIntervals.keys
        .map((entry) => entry.$1)
        .toSet();
    final affectedObjectCount = _objects
        .where((object) => object.affected || changedObjects.contains(object))
        .length;
    if (affectedObjectCount > maximumOperations) {
      return Err(_failure('eraser_operation_limit'));
    }
    final stagedPreviews =
        <
          (_PartialObjectPlan, _WorkingStroke, int),
          List<StrokeGeometryElement>
        >{};
    for (final entry in stagedIntervals.entries) {
      final key = entry.key;
      final preview = _survivorElementsForSegment(
        key.$2,
        key.$3,
        erased: entry.value,
        localToPage: key.$1.object.transform,
        geometryResolver: geometryResolver,
        handwritingLimits: handwritingLimits,
      );
      if (preview == null) {
        return Err(_failure('partial_preview_unavailable'));
      }
      stagedPreviews[key] = preview.elements;
      _previewRangeMaterializationCount += preview.materializations;
    }
    for (final object in changedObjects) {
      final initialize = !object.affected;
      if (initialize) {
        for (final working in object.working) {
          final count = working.stroke.samples.length == 1
              ? 1
              : working.stroke.samples.length - 1;
          for (var segment = 0; segment < count; segment += 1) {
            working.previewElements[segment] = working.geometry
                .sourceSegmentElements(segment);
          }
        }
      }
      final entries = stagedIntervals.entries.where(
        (entry) => identical(entry.key.$1, object),
      );
      for (final entry in entries) {
        final working = entry.key.$2;
        if (!working.requiresIdentity) newlyAffected += 1;
        working.requiresIdentity = true;
        working.erasedIntervals[entry.key.$3] = entry.value;
        working.previewElements[entry.key.$3] =
            stagedPreviews[entry.key] ?? const [];
      }
      final publishedSegments = initialize
          ? object.working.expand((working) sync* {
              for (final entry in working.previewElements.entries) {
                yield (working, entry.key);
              }
            })
          : entries.map((entry) => (entry.key.$2, entry.key.$3));
      for (final entry in publishedSegments) {
        previewUpdates.add(
          EraserPreviewSegmentUpdate._(
            objectId: object.object.id,
            strokeId: entry.$1.stroke.id,
            sourceSegment: entry.$2,
            style: entry.$1.stroke.style,
            elements: entry.$1.previewElements[entry.$2] ?? const [],
          ),
        );
      }
      object.affected = true;
      changed.add(object.object.id);
    }
    _intervalEvidenceCount = stagedIntervalEvidenceCount;
    _lastPoint = point;
    _pointCount += 1;
    _segmentCount += 1;
    return Ok(
      EraserGestureUpdate._(
        changed,
        newlyAffectedStrokeCount: newlyAffected,
        previewSegmentUpdates: previewUpdates,
      ),
    );
  }

  /// Processes one pointer point under explicit candidate and classifier work
  /// ceilings, resuming the same internally owned point on later calls.
  Result<PartialEraseWorkBatch, StructuredFailure> processPointWork({
    Point2? point,
    required int maximumCandidateSourceSegments,
    required int maximumClassifications,
    required int maximumChecks,
    required bool materializePreviewEvidence,
  }) {
    if (maximumCandidateSourceSegments <= 0 ||
        maximumClassifications <= 0 ||
        maximumChecks <
            StrokeGeometryResolver.maximumPreparedClassificationChecks ||
        maximumCandidateSourceSegments > Revision.maximumValue ||
        maximumClassifications > Revision.maximumValue ||
        maximumChecks > Revision.maximumValue) {
      return Err(_failure('invalid_partial_work_batch'));
    }
    if (_pendingPoint == null) {
      if (point == null || _pointCount >= maximumPoints) {
        return Err(_failure('eraser_path_limit'));
      }
      final first = _lastPoint ?? point;
      final path = SweptPath.create([first, point], maximumPoints: 2);
      if (path is! Ok<SweptPath, StructuredFailure>) {
        return Err(_failure('invalid_segment'));
      }
      _pendingPoint = _PendingPartialPoint(
        point: point,
        path: path.value,
        sweptBounds: _sweptBounds(first, point, radius),
        stagedIntervalEvidenceCount: _intervalEvidenceCount,
      );
    } else if (point != null) {
      return Err(_failure('partial_point_work_pending'));
    }

    final pending = _pendingPoint!;
    var candidates = 0;
    var classifications = 0;
    var checks = 0;
    while (candidates < maximumCandidateSourceSegments) {
      final next = _nextPartialCandidate(pending);
      if (next is! Ok<_PartialCandidate?, StructuredFailure>) {
        _pendingPoint = null;
        return Err(_failure('partial_geometry_unavailable'));
      }
      final candidate = next.value;
      if (candidate == null) {
        final completed = _completePendingPoint(
          pending,
          materializePreviewEvidence: materializePreviewEvidence,
        );
        _pendingPoint = null;
        if (completed is! Ok<EraserGestureUpdate, StructuredFailure>) {
          return Err(_failure('partial_point_failed'));
        }
        return Ok(
          PartialEraseWorkBatch._(
            pointCompleted: true,
            candidateSourceSegments: candidates,
            intervalClassifications: classifications,
            classificationChecks: checks,
            update: completed.value,
          ),
        );
      }

      final cacheKey = _classificationCacheKey(
        candidate.segmentIndex,
        pending.path.points.first,
        pending.path.points.last,
      );
      var classifiedIntervals = candidate.working.classificationCache[cacheKey];
      if (classifiedIntervals == null) {
        final gestureChecksRemaining =
            maximumClassificationChecks - _classificationCheckCount;
        final requiredChecks = math.min(
          StrokeGeometryResolver.maximumPreparedClassificationChecks,
          gestureChecksRemaining,
        );
        if (classifications >= maximumClassifications ||
            requiredChecks <= 0 ||
            maximumChecks - checks < requiredChecks) {
          if (requiredChecks <= 0) {
            _pendingPoint = null;
            return Err(_failure('partial_classification_work_limit'));
          }
          return Ok(
            PartialEraseWorkBatch._(
              pointCompleted: false,
              candidateSourceSegments: candidates,
              intervalClassifications: classifications,
              classificationChecks: checks,
            ),
          );
        }
        final classified = geometryResolver
            .classifyPreparedSourceSegmentErasure(
              prepared: candidate.working.erasure,
              sourceSegment: candidate.segmentIndex,
              eraserSegment: pending.path,
              radius: radius,
              maximumChecks: requiredChecks,
            );
        if (classified
            is! Ok<StrokeErasureClassificationEvidence, StructuredFailure>) {
          _pendingPoint = null;
          if (classified
                  is Err<
                    StrokeErasureClassificationEvidence,
                    StructuredFailure
                  > &&
              classified.error.code ==
                  'drawing.geometry.erasure_classification_limit') {
            _classificationCheckCount = maximumClassificationChecks;
            return Err(_failure('partial_classification_work_limit'));
          }
          return Err(_failure('partial_split_unavailable'));
        }
        classifications += 1;
        checks += classified.value.classificationChecks;
        _classificationCheckCount += classified.value.classificationChecks;
        _classificationGeometryResolutionCount +=
            classified.value.geometryResolutions;
        _spatialElementExaminationCount +=
            classified.value.spatialElementsExamined;
        _maximumClassificationDepth = math.max(
          _maximumClassificationDepth,
          classified.value.maximumSearchDepth,
        );
        _maximumPendingClassificationIntervals = math.max(
          _maximumPendingClassificationIntervals,
          classified.value.maximumPendingIntervals,
        );
        classifiedIntervals = classified.value.intervals;
        candidate.working.classificationCache[cacheKey] = classifiedIntervals;
      } else {
        _classificationCacheHitCount += 1;
      }

      _splitInvocationCount += 1;
      _candidateSourceSegmentCount += 1;
      candidates += 1;
      pending.currentCandidate = null;
      if (classifiedIntervals.isEmpty) continue;
      final key = (candidate.object, candidate.working, candidate.segmentIndex);
      final existing =
          pending.stagedIntervals[key] ??
          candidate.working.erasedIntervals[candidate.segmentIndex] ??
          const [];
      if (_sameIntervals(existing, classifiedIntervals)) continue;
      _intervalMergeCount += 1;
      final merged = _mergeIntervals(existing, classifiedIntervals);
      if (_sameIntervals(existing, merged)) continue;
      final nextEvidence =
          pending.stagedIntervalEvidenceCount - existing.length + merged.length;
      if (nextEvidence > math.max(maximumIntersections, maximumFragments)) {
        _pendingPoint = null;
        return Err(_failure('eraser_cumulative_limit'));
      }
      pending.stagedIntervals[key] = merged;
      pending.stagedIntervalEvidenceCount = nextEvidence;
    }
    return Ok(
      PartialEraseWorkBatch._(
        pointCompleted: false,
        candidateSourceSegments: candidates,
        intervalClassifications: classifications,
        classificationChecks: checks,
      ),
    );
  }

  Result<_PartialCandidate?, StructuredFailure> _nextPartialCandidate(
    _PendingPartialPoint pending,
  ) {
    final retained = pending.currentCandidate;
    if (retained != null) return Ok(retained);
    while (true) {
      if (pending.sourceSegmentIndex < pending.sourceSegments.length) {
        final candidate = _PartialCandidate(
          object: pending.sourceObject!,
          working: pending.sourceWorking!,
          segmentIndex: pending.sourceSegments[pending.sourceSegmentIndex++],
        );
        pending.currentCandidate = candidate;
        return Ok(candidate);
      }
      pending.sourceSegments = const [];
      pending.sourceSegmentIndex = 0;
      pending.sourceObject = null;
      pending.sourceWorking = null;
      if (pending.objectIndex >= _objects.length) return const Ok(null);
      final object = _objects[pending.objectIndex];
      if (pending.workingIndex >= object.working.length) {
        pending.objectIndex += 1;
        pending.workingIndex = 0;
        continue;
      }
      final working = object.working[pending.workingIndex++];
      if (pending.sweptBounds != null &&
          !_boundsIntersect(working.geometry.bounds, pending.sweptBounds!)) {
        continue;
      }
      final query = working.geometry.querySweptPathSourceSegments(
        pending.path,
        radius,
      );
      if (query
          is! Ok<
            ({List<int> sourceSegments, int examinedElements}),
            StructuredFailure
          >) {
        return Err(_failure('partial_geometry_unavailable'));
      }
      _spatialElementExaminationCount += query.value.examinedElements;
      if (query.value.sourceSegments.isEmpty) continue;
      pending.sourceObject = object;
      pending.sourceWorking = working;
      pending.sourceSegments = query.value.sourceSegments;
    }
  }

  Result<EraserGestureUpdate, StructuredFailure> _completePendingPoint(
    _PendingPartialPoint pending, {
    required bool materializePreviewEvidence,
  }) {
    final changedObjects = pending.stagedIntervals.keys
        .map((entry) => entry.$1)
        .toSet();
    final affectedObjectCount = _objects
        .where((object) => object.affected || changedObjects.contains(object))
        .length;
    if (affectedObjectCount > maximumOperations) {
      return Err(_failure('eraser_operation_limit'));
    }
    final stagedPreviews =
        <
          (_PartialObjectPlan, _WorkingStroke, int),
          List<StrokeGeometryElement>
        >{};
    if (materializePreviewEvidence) {
      for (final entry in pending.stagedIntervals.entries) {
        final key = entry.key;
        final preview = _survivorElementsForSegment(
          key.$2,
          key.$3,
          erased: entry.value,
          localToPage: key.$1.object.transform,
          geometryResolver: geometryResolver,
          handwritingLimits: handwritingLimits,
        );
        if (preview == null) {
          return Err(_failure('partial_preview_unavailable'));
        }
        stagedPreviews[key] = preview.elements;
        _previewRangeMaterializationCount += preview.materializations;
      }
    }
    final changed = <ObjectId>{};
    final previewUpdates = <EraserPreviewSegmentUpdate>[];
    var newlyAffected = 0;
    for (final object in changedObjects) {
      final initialize = !object.affected;
      if (initialize && materializePreviewEvidence) {
        for (final working in object.working) {
          final count = working.stroke.samples.length == 1
              ? 1
              : working.stroke.samples.length - 1;
          for (var segment = 0; segment < count; segment += 1) {
            working.previewElements[segment] = working.geometry
                .sourceSegmentElements(segment);
          }
        }
      }
      final entries = pending.stagedIntervals.entries.where(
        (entry) => identical(entry.key.$1, object),
      );
      for (final entry in entries) {
        final working = entry.key.$2;
        if (!working.requiresIdentity) newlyAffected += 1;
        working.requiresIdentity = true;
        working.erasedIntervals[entry.key.$3] = entry.value;
        if (materializePreviewEvidence) {
          working.previewElements[entry.key.$3] =
              stagedPreviews[entry.key] ?? const [];
        }
      }
      final publishedSegments = !materializePreviewEvidence
          ? const <(_WorkingStroke, int)>[]
          : initialize
          ? object.working.expand((working) sync* {
              for (final entry in working.previewElements.entries) {
                yield (working, entry.key);
              }
            })
          : entries.map((entry) => (entry.key.$2, entry.key.$3));
      for (final entry in publishedSegments) {
        previewUpdates.add(
          EraserPreviewSegmentUpdate._(
            objectId: object.object.id,
            strokeId: entry.$1.stroke.id,
            sourceSegment: entry.$2,
            style: entry.$1.stroke.style,
            elements: entry.$1.previewElements[entry.$2] ?? const [],
          ),
        );
      }
      object.affected = true;
      changed.add(object.object.id);
    }
    _intervalEvidenceCount = pending.stagedIntervalEvidenceCount;
    _lastPoint = pending.point;
    _pointCount += 1;
    _segmentCount += 1;
    return Ok(
      EraserGestureUpdate._(
        changed,
        newlyAffectedStrokeCount: newlyAffected,
        previewSegmentUpdates: previewUpdates,
      ),
    );
  }

  /// Processes new points once in one explicitly bounded batch.
  Result<EraserGestureUpdate, StructuredFailure> acceptBatch(
    Iterable<Point2> source, {
    required int maximumBatchPoints,
  }) {
    if (maximumBatchPoints <= 0 ||
        maximumBatchPoints > maximumPoints ||
        maximumBatchPoints > Revision.maximumValue) {
      return Err(_failure('invalid_partial_batch'));
    }
    final points = <Point2>[];
    try {
      final iterator = source.iterator;
      while (iterator.moveNext()) {
        if (points.length >= maximumBatchPoints) {
          return Err(_failure('partial_batch_limit'));
        }
        points.add(iterator.current);
      }
    } on Object {
      return Err(_failure('partial_batch_unavailable'));
    }
    if (points.isEmpty) return Err(_failure('empty_partial_batch'));
    final changed = <ObjectId>{};
    final previews = <(ObjectId, StrokeId, int), EraserPreviewSegmentUpdate>{};
    var newlyAffected = 0;
    for (final point in points) {
      final update = acceptPoint(point);
      if (update is! Ok<EraserGestureUpdate, StructuredFailure>) {
        return Err(_failure('partial_batch_failed'));
      }
      changed.addAll(update.value.changedObjectIds);
      for (final preview in update.value.previewSegmentUpdates) {
        previews[(preview.objectId, preview.strokeId, preview.sourceSegment)] =
            preview;
      }
      newlyAffected += update.value.newlyAffectedStrokeCount;
    }
    _processedBatchCount += 1;
    _maximumProcessedBatchSize = math.max(
      _maximumProcessedBatchSize,
      points.length,
    );
    return Ok(
      EraserGestureUpdate._(
        changed,
        newlyAffectedStrokeCount: newlyAffected,
        previewSegmentUpdates: previews.values,
      ),
    );
  }

  /// Cached source evidence for affected Objects.
  List<EraserPreviewObject> get previews => List.unmodifiable(
    _objects
        .where((value) => value.affected)
        .map(
          (value) => EraserPreviewObject._(
            objectId: value.object.id,
            localToPage: value.object.transform,
            strokes: value.working.map(
              (entry) => EraserPreviewStroke(
                stroke: entry.stroke,
                geometry: entry.geometry,
              ),
            ),
          ),
        ),
  );

  /// Builds cached source evidence for one changed Object, when affected.
  EraserPreviewObject? previewFor(ObjectId objectId) {
    final value = _objects
        .where(
          (candidate) => candidate.object.id == objectId && candidate.affected,
        )
        .firstOrNull;
    return value == null
        ? null
        : EraserPreviewObject._(
            objectId: value.object.id,
            localToPage: value.object.transform,
            strokes: value.working.map(
              (entry) => EraserPreviewStroke(
                stroke: entry.stroke,
                geometry: entry.geometry,
              ),
            ),
          );
  }

  /// Materializes complete exact survivor Strokes once for terminal display.
  Result<List<EraserPreviewObject>, StructuredFailure>
  materializeFinalObjectPreviews() {
    if (_pendingPoint != null || _finalPreviewMaterialized) {
      return Err(_failure('final_preview_unavailable'));
    }
    final previews = <EraserPreviewObject>[];
    var intersections = 0;
    var fragments = 0;
    var outputSamples = 0;
    for (final object in _objects.where((value) => value.affected)) {
      final strokes = <EraserPreviewStroke>[];
      for (final working in object.working) {
        final survivors = <HandwritingStroke>[];
        if (!working.requiresIdentity) {
          survivors.add(working.stroke);
        } else {
          final split = _materializeIntervals(
            working,
            handwritingLimits: handwritingLimits,
            maximumIntersections: maximumIntersections,
            maximumFragments: maximumFragments,
            maximumOutputSamples: maximumOutputSamples,
          );
          _terminalMaterializationCount += 1;
          _terminalSourceSegmentPassCount += working.stroke.samples.length == 1
              ? 1
              : working.stroke.samples.length - 1;
          if (split is! Ok<StrokeSplitResult, StructuredFailure>) {
            return Err(_failure('partial_split_unavailable'));
          }
          working.terminalSplit = split.value;
          intersections += split.value.intersectionCount;
          fragments += split.value.affected ? split.value.strokes.length : 0;
          outputSamples += split.value.outputSampleCount;
          if (intersections > maximumIntersections ||
              fragments > maximumFragments ||
              outputSamples > maximumOutputSamples) {
            return Err(_failure('eraser_cumulative_limit'));
          }
          survivors.addAll(split.value.strokes);
        }
        for (final survivor in survivors) {
          final geometry = identical(survivor, working.stroke)
              ? Ok<TransformedStrokeGeometry, StructuredFailure>(
                  working.geometry,
                )
              : geometryResolver.resolve(
                  stroke: survivor,
                  localToPage: object.object.transform,
                );
          if (geometry is! Ok<TransformedStrokeGeometry, StructuredFailure>) {
            return Err(_failure('partial_geometry_unavailable'));
          }
          strokes.add(
            EraserPreviewStroke(stroke: survivor, geometry: geometry.value),
          );
        }
      }
      previews.add(
        EraserPreviewObject._(
          objectId: object.object.id,
          localToPage: object.object.transform,
          strokes: strokes,
        ),
      );
    }
    if (previews.isEmpty) return Err(_failure('nothing_erased'));
    _fragmentCount = fragments;
    _finalPreviewMaterialized = true;
    return Ok(List.unmodifiable(previews));
  }

  /// Allocates fragment and correlation identities only at terminal request time.
  Result<AtomicObjectCollectionEditRequest, StructuredFailure> createRequest({
    required UuidGenerator uuidGenerator,
  }) {
    final affected = _objects.where((value) => value.affected).toList();
    if (affected.isEmpty) return Err(_failure('nothing_erased'));
    final planned = <_PartialTerminalPlan>[];
    var intersections = 0;
    var fragments = 0;
    var outputSamples = 0;
    for (final object in affected) {
      final strokes = <_PartialTerminalStroke>[];
      for (final working in object.working) {
        if (!working.requiresIdentity) {
          strokes.add(_PartialTerminalStroke(working.stroke, null));
          continue;
        }
        final cached = working.terminalSplit;
        final split = cached == null
            ? _materializeIntervals(
                working,
                handwritingLimits: handwritingLimits,
                maximumIntersections: maximumIntersections,
                maximumFragments: maximumFragments,
                maximumOutputSamples: maximumOutputSamples,
              )
            : Ok<StrokeSplitResult, StructuredFailure>(cached);
        if (cached == null) {
          _terminalMaterializationCount += 1;
          _terminalSourceSegmentPassCount += working.stroke.samples.length == 1
              ? 1
              : working.stroke.samples.length - 1;
        }
        if (split is! Ok<StrokeSplitResult, StructuredFailure>) {
          return Err(_failure('partial_split_unavailable'));
        }
        final value = split.value;
        intersections += value.intersectionCount;
        fragments += value.affected ? value.strokes.length : 0;
        outputSamples += value.outputSampleCount;
        if (intersections > maximumIntersections ||
            fragments > maximumFragments ||
            outputSamples > maximumOutputSamples) {
          return Err(_failure('eraser_cumulative_limit'));
        }
        strokes.add(_PartialTerminalStroke(working.stroke, value));
      }
      planned.add(_PartialTerminalPlan(object, strokes));
    }
    _fragmentCount = fragments;
    final occupied = <StrokeId>{..._existingStrokeIds};
    final occupiedUuids = _occupiedUuids(document.root);
    final replacements = <ObjectEnvelope>[];
    final removals = <ObjectId>[];
    final objectRevisions = <ObjectId, Revision>{};
    final membershipRevisions = <LayerId, Revision>{};
    for (final terminal in planned) {
      final plan = terminal.object;
      final survivors = <HandwritingStroke>[];
      for (final terminalStroke in terminal.strokes) {
        final split = terminalStroke.split;
        if (split == null || !split.affected) {
          survivors.add(terminalStroke.source);
          continue;
        }
        for (final fragment in split.strokes) {
          _uuidAllocationCount += 1;
          final uuid = _generate(uuidGenerator);
          final id = uuid == null ? null : StrokeId.fromUuid(uuid);
          if (id == null ||
              occupied.contains(id) ||
              !occupied.add(id) ||
              !occupiedUuids.add(uuid!.value)) {
            return Err(_failure('stroke_id_collision'));
          }
          final stroke = HandwritingStroke.create(
            id: id,
            samples: fragment.samples,
            style: fragment.style,
            limits: handwritingLimits,
            unknownFields: fragment.unknownFields,
          );
          if (stroke is! Ok<HandwritingStroke, StructuredFailure>) {
            return Err(_failure('fragment_unavailable'));
          }
          survivors.add(stroke.value);
        }
      }
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
    _uuidAllocationCount += 1;
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
        description: 'Partially erase handwriting',
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

final class _PendingPartialPoint {
  _PendingPartialPoint({
    required this.point,
    required this.path,
    required this.sweptBounds,
    required this.stagedIntervalEvidenceCount,
  });

  final Point2 point;
  final SweptPath path;
  final Rect2? sweptBounds;
  int objectIndex = 0;
  int workingIndex = 0;
  _PartialObjectPlan? sourceObject;
  _WorkingStroke? sourceWorking;
  List<int> sourceSegments = const [];
  int sourceSegmentIndex = 0;
  _PartialCandidate? currentCandidate;
  final Map<
    (_PartialObjectPlan, _WorkingStroke, int),
    List<StrokeErasureInterval>
  >
  stagedIntervals = {};
  int stagedIntervalEvidenceCount;
}

final class _PartialCandidate {
  const _PartialCandidate({
    required this.object,
    required this.working,
    required this.segmentIndex,
  });

  final _PartialObjectPlan object;
  final _WorkingStroke working;
  final int segmentIndex;
}

final class _PartialObjectPlan {
  _PartialObjectPlan({
    required this.layerId,
    required this.object,
    required this.payload,
    required this.objectRevision,
    required this.membershipRevision,
    required this.working,
  });
  final LayerId layerId;
  final ObjectEnvelope object;
  final HandwritingPayload payload;
  final Revision objectRevision;
  final Revision membershipRevision;
  final List<_WorkingStroke> working;
  bool affected = false;
}

final class _WorkingStroke {
  _WorkingStroke(
    this.stroke,
    this.requiresIdentity,
    this.geometry,
    this.erasure,
  );
  final HandwritingStroke stroke;
  bool requiresIdentity;
  final TransformedStrokeGeometry geometry;
  final PreparedStrokeErasureGeometry erasure;
  final Map<int, List<StrokeErasureInterval>> erasedIntervals = {};
  final Map<int, List<StrokeGeometryElement>> previewElements = {};
  StrokeSplitResult? terminalSplit;
  final Map<(int, Point2, Point2), List<StrokeErasureInterval>>
  classificationCache = {};
}

(int, Point2, Point2) _classificationCacheKey(
  int sourceSegment,
  Point2 first,
  Point2 second,
) {
  final ordered =
      first.x < second.x || (first.x == second.x && first.y <= second.y);
  return ordered
      ? (sourceSegment, first, second)
      : (sourceSegment, second, first);
}

final class _PartialTerminalPlan {
  const _PartialTerminalPlan(this.object, this.strokes);
  final _PartialObjectPlan object;
  final List<_PartialTerminalStroke> strokes;
}

final class _PartialTerminalStroke {
  const _PartialTerminalStroke(this.source, this.split);
  final HandwritingStroke source;
  final StrokeSplitResult? split;
}

({List<StrokeGeometryElement> elements, int materializations})?
_survivorElementsForSegment(
  _WorkingStroke working,
  int segment, {
  required List<StrokeErasureInterval> erased,
  required AffineTransform2D localToPage,
  required StrokeGeometryResolver geometryResolver,
  required HandwritingLimits handwritingLimits,
}) {
  final samples = working.stroke.samples;
  if (samples.length == 1) {
    return (elements: const [], materializations: 0);
  }
  final first = samples[segment], second = samples[segment + 1];
  final elements = <StrokeGeometryElement>[];
  var cursor = 0.0;
  var materializations = 0;

  bool appendRange(double start, double end) {
    if (end <= start) return true;
    final a = _partialBoundarySample(first, second, start, handwritingLimits);
    final b = _partialBoundarySample(first, second, end, handwritingLimits);
    if (a == null || b == null) return false;
    final geometry = geometryResolver.resolvePreview(
      samples: [a, b],
      style: working.stroke.style,
      localToPage: localToPage,
      maximumSamples: 2,
    );
    if (geometry is! Ok<TransformedStrokeGeometry, StructuredFailure>) {
      return false;
    }
    elements.addAll(geometry.value.elements);
    materializations += 1;
    return true;
  }

  for (final interval in erased) {
    if (!appendRange(cursor, interval.start)) return null;
    cursor = math.max(cursor, interval.end);
  }
  if (!appendRange(cursor, 1)) return null;
  return (
    elements: List<StrokeGeometryElement>.unmodifiable(elements),
    materializations: materializations,
  );
}

List<StrokeErasureInterval> _mergeIntervals(
  List<StrokeErasureInterval> existing,
  List<StrokeErasureInterval> additions,
) {
  final ordered = <StrokeErasureInterval>[...existing, ...additions]
    ..sort((a, b) => a.start.compareTo(b.start));
  final merged = <StrokeErasureInterval>[];
  for (final value in ordered) {
    if (merged.isEmpty || value.start > merged.last.end) {
      merged.add(value);
      continue;
    }
    final previous = merged.removeLast();
    merged.add(_interval(previous.start, math.max(previous.end, value.end)));
  }
  return List.unmodifiable(merged);
}

StrokeErasureInterval _interval(double start, double end) =>
    (StrokeErasureInterval.create(start: start, end: end)
            as Ok<StrokeErasureInterval, StructuredFailure>)
        .value;

bool _sameIntervals(
  List<StrokeErasureInterval> first,
  List<StrokeErasureInterval> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index += 1) {
    if (first[index].start != second[index].start ||
        first[index].end != second[index].end) {
      return false;
    }
  }
  return true;
}

Result<StrokeSplitResult, StructuredFailure> _materializeIntervals(
  _WorkingStroke working, {
  required HandwritingLimits handwritingLimits,
  required int maximumIntersections,
  required int maximumFragments,
  required int maximumOutputSamples,
}) {
  final source = working.stroke;
  if (!working.requiresIdentity) {
    return StrokeSplitResult.create(strokes: [source], maximumStrokes: 1);
  }
  final runs = <List<StrokeSample>>[];
  List<StrokeSample>? run;
  var intersections = 0;
  var outputSamples = 0;

  bool append(StrokeSample sample) {
    run ??= <StrokeSample>[];
    if (run!.isEmpty) runs.add(run!);
    if (run!.isEmpty || run!.last != sample) {
      if (outputSamples >= maximumOutputSamples) return false;
      run!.add(sample);
      outputSamples += 1;
    }
    return true;
  }

  if (source.samples.length == 1) {
    if ((working.erasedIntervals[0] ?? const []).isEmpty) {
      return StrokeSplitResult.create(strokes: [source], maximumStrokes: 1);
    }
  } else {
    for (var segment = 0; segment + 1 < source.samples.length; segment += 1) {
      final first = source.samples[segment];
      final second = source.samples[segment + 1];
      final erased = working.erasedIntervals[segment] ?? const [];
      var cursor = 0.0;
      for (final interval in erased) {
        if (interval.start > cursor) {
          final start = _partialBoundarySample(
            first,
            second,
            cursor,
            handwritingLimits,
          );
          final end = _partialBoundarySample(
            first,
            second,
            interval.start,
            handwritingLimits,
          );
          if (start == null || end == null || !append(start) || !append(end)) {
            return Err(_failure('eraser_output_limit'));
          }
        }
        if (interval.start > 0) intersections += 1;
        if (interval.end < 1) intersections += 1;
        if (intersections > maximumIntersections) {
          return Err(_failure('eraser_intersection_limit'));
        }
        run = null;
        cursor = math.max(cursor, interval.end);
      }
      if (cursor < 1) {
        final start = _partialBoundarySample(
          first,
          second,
          cursor,
          handwritingLimits,
        );
        if (start == null || !append(start) || !append(second)) {
          return Err(_failure('eraser_output_limit'));
        }
      }
    }
  }
  if (runs.length > maximumFragments) {
    return Err(_failure('eraser_output_limit'));
  }
  final fragments = <HandwritingStroke>[];
  for (final samples in runs) {
    final fragment = HandwritingStroke.create(
      id: source.id,
      samples: samples,
      style: source.style,
      limits: handwritingLimits,
      unknownFields: source.unknownFields,
    );
    if (fragment is! Ok<HandwritingStroke, StructuredFailure>) {
      return Err(_failure('fragment_unavailable'));
    }
    fragments.add(fragment.value);
  }
  return StrokeSplitResult.create(
    strokes: fragments,
    maximumStrokes: math.max(1, maximumFragments),
    intersectionCount: intersections,
    outputSampleCount: outputSamples,
    affected: true,
  );
}

StrokeSample? _partialBoundarySample(
  StrokeSample first,
  StrokeSample second,
  double t,
  HandwritingLimits limits,
) {
  if (t <= 0) return first;
  if (t >= 1) return second;
  double? optional(double? a, double? b) =>
      a == null || b == null ? null : a + (b - a) * t;
  final point = Point2.create(
    x: first.position.x + (second.position.x - first.position.x) * t,
    y: first.position.y + (second.position.y - first.position.y) * t,
  );
  if (point is! Ok<Point2, StructuredFailure>) return null;
  return StrokeSample.create(
    position: point.value,
    timeMicros: (first.timeMicros + (second.timeMicros - first.timeMicros) * t)
        .round(),
    limits: limits,
    pressure: optional(first.pressure, second.pressure),
    tilt: optional(first.tilt, second.tilt),
    orientation: optional(first.orientation, second.orientation),
    unknownFields: PreservedMap.empty(),
  ).fold<StrokeSample?>(onOk: (value) => value, onErr: (_) => null);
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

Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
            as Ok<Rect2, StructuredFailure>)
        .value;

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
