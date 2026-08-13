// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../geometry.dart';
import '../selection.dart';

/// Whether an area query requires containment or any intersection.
enum AreaHitMode { containment, intersection }

/// Immutable hit identifying structural ownership and optional stroke target.
final class HitTestResult {
  /// Creates complete hit evidence.
  const HitTestResult({
    required this.pageId,
    required this.layerId,
    required this.objectId,
    this.strokeId,
  });

  /// Owning Page.
  final PageId pageId;

  /// Owning Layer.
  final LayerId layerId;

  /// Owning Object.
  final ObjectId objectId;

  /// Optional stable handwriting subtarget.
  final StrokeId? strokeId;

  /// Converts this hit into a real whole-Object or Handwriting Stroke target.
  SelectionTarget toSelectionTarget() {
    final stroke = strokeId;
    if (stroke == null) {
      return SelectionTarget.wholeObject(pageId: pageId, objectId: objectId);
    }
    return SelectionTarget.subTarget(
      pageId: pageId,
      objectId: objectId,
      kind: handwritingStrokeSelectionSubTargetKind,
      id: SelectionSubTargetId.fromUuid(stroke.uuid),
    ).fold(
      onOk: (value) => value,
      onErr: (_) => throw StateError('Validated hit target must be valid.'),
    );
  }
}

/// AL NOTE-owned hit-testing behavior for one already supported Object type.
abstract interface class ObjectHitTestingDefinition {
  /// Permanent Object type key, captured exactly once by the Registry.
  ObjectTypeKey get typeKey;

  /// Returns the topmost subtarget inside this one Object for a point query.
  Result<StrokeId?, StructuredFailure> point({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  });

  /// Returns matching subtargets in topmost-first stroke order.
  Result<List<StrokeId>, StructuredFailure> rectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  });

  /// Returns matching subtargets for a validated Page-space polygon.
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  });
}

/// Optional whole-Object hit behavior for types without stable subtargets.
abstract interface class ObjectWholeHitTestingDefinition {
  /// Whether the Object is hit by a Page-space point.
  Result<bool, StructuredFailure> wholePoint({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  });

  /// Whether the Object matches a rectangle area query.
  Result<bool, StructuredFailure> wholeRectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  });

  /// Whether the Object matches a lasso area query.
  Result<bool, StructuredFailure> wholeLasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  });

  /// Whether a bounded Page-space swept capsule intersects visible content.
  Result<bool, StructuredFailure> wholeSweptSegment({
    required ObjectEnvelope object,
    required Point2 start,
    required Point2 end,
    required double radius,
  });
}

/// Immutable bounded nonglobal Hit-Testing Registry.
final class HitTestingRegistry {
  HitTestingRegistry._(this.definitions);

  /// Captures metadata incrementally and rejects duplicate keys.
  static Result<HitTestingRegistry, StructuredFailure> create(
    Iterable<ObjectHitTestingDefinition> source, {
    required int maximumDefinitions,
    required int maximumBehaviorResults,
  }) {
    if (maximumDefinitions < 0 ||
        maximumDefinitions > Revision.maximumValue ||
        maximumBehaviorResults < 0 ||
        maximumBehaviorResults > Revision.maximumValue) {
      return Err(
        _failure('invalid_registry_limit', FailureCategory.validation),
      );
    }
    final values = <_CapturedHitTestingDefinition>[];
    try {
      final iterator = source.iterator;
      while (iterator.moveNext()) {
        if (values.length >= maximumDefinitions) {
          return Err(_failure('registry_limit', FailureCategory.resource));
        }
        final delegate = iterator.current;
        final key = delegate.typeKey;
        values.add(
          _CapturedHitTestingDefinition(delegate, key, maximumBehaviorResults),
        );
      }
    } on Object {
      return Err(
        _failure('registry_metadata_unavailable', FailureCategory.dependency),
      );
    }
    values.sort((left, right) => left.typeKey.compareTo(right.typeKey));
    final map = <ObjectTypeKey, ObjectHitTestingDefinition>{};
    for (final value in values) {
      if (map.containsKey(value.typeKey)) {
        return Err(
          _failure('duplicate_definition', FailureCategory.validation),
        );
      }
      map[value.typeKey] = value;
    }
    return Ok(HitTestingRegistry._(Map.unmodifiable(map)));
  }

  /// Captured definitions in deterministic type-key order.
  final Map<ObjectTypeKey, ObjectHitTestingDefinition> definitions;
}

final class _CapturedHitTestingDefinition
    implements ObjectHitTestingDefinition, ObjectWholeHitTestingDefinition {
  const _CapturedHitTestingDefinition(
    this._delegate,
    this.typeKey,
    this._maximumBehaviorResults,
  );
  final ObjectHitTestingDefinition _delegate;
  final int _maximumBehaviorResults;
  @override
  final ObjectTypeKey typeKey;

  @override
  Result<StrokeId?, StructuredFailure> point({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) {
    try {
      final result = _delegate.point(
        object: object,
        pagePosition: pagePosition,
        pageTolerance: pageTolerance,
      );
      return result is Ok<StrokeId?, StructuredFailure>
          ? result
          : Err(_failure('behavior_unavailable', FailureCategory.dependency));
    } on Object {
      return Err(_failure('behavior_unavailable', FailureCategory.dependency));
    }
  }

  @override
  Result<List<StrokeId>, StructuredFailure> rectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) => _isolateList(
    () => _delegate.rectangle(object: object, area: area, mode: mode),
  );

  @override
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) => _isolateList(
    () => _delegate.lasso(object: object, polygon: polygon, mode: mode),
  );

  Result<List<StrokeId>, StructuredFailure> _isolateList(
    Result<List<StrokeId>, StructuredFailure> Function() invoke,
  ) {
    try {
      final result = invoke();
      if (result is! Ok<List<StrokeId>, StructuredFailure>) {
        return Err(
          _failure('behavior_unavailable', FailureCategory.dependency),
        );
      }
      final captured = <StrokeId>[];
      final unique = <StrokeId>{};
      final iterator = result.value.iterator;
      while (true) {
        final hasNext = iterator.moveNext();
        if (!hasNext) break;
        if (captured.length >= _maximumBehaviorResults) {
          return Err(
            _failure('behavior_result_limit', FailureCategory.resource),
          );
        }
        final current = iterator.current;
        if (!unique.add(current)) {
          return Err(
            _failure('duplicate_behavior_result', FailureCategory.validation),
          );
        }
        captured.add(current);
      }
      return Ok(List<StrokeId>.unmodifiable(captured));
    } on Object {
      return Err(_failure('behavior_unavailable', FailureCategory.dependency));
    }
  }

  @override
  Result<bool, StructuredFailure> wholePoint({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) => _isolateWhole(
    (delegate) => delegate.wholePoint(
      object: object,
      pagePosition: pagePosition,
      pageTolerance: pageTolerance,
    ),
  );

  @override
  Result<bool, StructuredFailure> wholeRectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) => _isolateWhole(
    (delegate) =>
        delegate.wholeRectangle(object: object, area: area, mode: mode),
  );

  @override
  Result<bool, StructuredFailure> wholeLasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) => _isolateWhole(
    (delegate) =>
        delegate.wholeLasso(object: object, polygon: polygon, mode: mode),
  );

  @override
  Result<bool, StructuredFailure> wholeSweptSegment({
    required ObjectEnvelope object,
    required Point2 start,
    required Point2 end,
    required double radius,
  }) => _isolateWhole(
    (delegate) => delegate.wholeSweptSegment(
      object: object,
      start: start,
      end: end,
      radius: radius,
    ),
  );

  Result<bool, StructuredFailure> _isolateWhole(
    Result<bool, StructuredFailure> Function(ObjectWholeHitTestingDefinition)
    invoke,
  ) {
    final delegate = _delegate;
    if (delegate is! ObjectWholeHitTestingDefinition) return const Ok(false);
    try {
      final result = invoke(delegate as ObjectWholeHitTestingDefinition);
      if (result is Ok<bool, StructuredFailure>) return result;
      final trusted = _trustedWholeFailure(
        typeKey,
        (result as Err<bool, StructuredFailure>).error.code,
      );
      return Err(
        trusted ?? _failure('behavior_unavailable', FailureCategory.dependency),
      );
    } on Object {
      return Err(_failure('behavior_unavailable', FailureCategory.dependency));
    }
  }
}

StructuredFailure? _trustedWholeFailure(ObjectTypeKey typeKey, String code) {
  if (typeKey != shapeObjectTypeKey) return null;
  return switch (code) {
    'drawing.shape_hit_testing.work_limit' => StructuredFailure(
      code: 'drawing.shape_hit_testing.work_limit',
      category: FailureCategory.resource,
      retryDisposition: RetryDisposition.never,
      message: 'Shape hit testing is invalid or unavailable.',
    ),
    'drawing.shape_hit_testing.numeric_uncertain' => StructuredFailure(
      code: 'drawing.shape_hit_testing.numeric_uncertain',
      category: FailureCategory.validation,
      retryDisposition: RetryDisposition.never,
      message: 'Shape hit testing is invalid or unavailable.',
    ),
    _ => null,
  };
}

/// Built-in transform-correct handwriting hit-testing definition.
final class HandwritingHitTestingDefinition
    implements ObjectHitTestingDefinition {
  /// Creates the definition with explicit decoding and geometry boundaries.
  HandwritingHitTestingDefinition({
    required this.handwritingLimits,
    required this.geometryResolver,
    this.geometryCache,
  });

  /// Handwriting decode limits.
  final HandwritingLimits handwritingLimits;

  /// Shared affine geometry resolver.
  final StrokeGeometryResolver geometryResolver;

  /// Optional bounded cache shared with rendering and gesture preparation.
  final HandwritingGeometryCache? geometryCache;

  int _detailedHitCount = 0;

  /// Exact geometry predicates evaluated after conservative bounds filtering.
  int get detailedHitCount => _detailedHitCount;

  @override
  ObjectTypeKey get typeKey => handwritingObjectTypeKey;

  HandwritingPayload? _payload(ObjectEnvelope object) {
    if (object.typeKey != handwritingObjectTypeKey ||
        object.typeSchemaVersion != handwritingSchemaVersion)
      return null;
    return HandwritingPayload.decode(
      object.payload,
      limits: handwritingLimits,
    ).fold<HandwritingPayload?>(onOk: (value) => value, onErr: (_) => null);
  }

  PreparedHandwritingGeometry? _prepared(ObjectEnvelope object) => geometryCache
      ?.prepare(
        object: object,
        handwritingLimits: handwritingLimits,
        geometryResolver: geometryResolver,
      )
      .fold<PreparedHandwritingGeometry?>(
        onOk: (value) => value,
        onErr: (_) => null,
      );

  @override
  Result<StrokeId?, StructuredFailure> point({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) {
    if (!pageTolerance.isFinite || pageTolerance < 0) {
      return Err(_failure('invalid_tolerance', FailureCategory.validation));
    }
    final prepared = _prepared(object);
    final payload = prepared?.payload ?? _payload(object);
    if (payload == null)
      return Err(_failure('invalid_object', FailureCategory.validation));
    if (prepared != null &&
        !_pointInExpandedRect(pagePosition, prepared.bounds, pageTolerance)) {
      return const Ok(null);
    }
    for (var index = payload.strokes.length - 1; index >= 0; index -= 1) {
      final stroke = payload.strokes[index];
      final geometry = prepared == null
          ? geometryResolver.resolve(
              stroke: stroke,
              localToPage: object.transform,
            )
          : Ok<TransformedStrokeGeometry, StructuredFailure>(
              prepared.geometries[index],
            );
      if (geometry is Err<TransformedStrokeGeometry, StructuredFailure>) {
        return Err(
          _failure('geometry_unavailable', FailureCategory.dependency),
        );
      }
      _detailedHitCount += 1;
      if ((geometry as Ok<TransformedStrokeGeometry, StructuredFailure>).value
          .hitsPoint(pagePosition, pageTolerance))
        return Ok(stroke.id);
    }
    return const Ok(null);
  }

  @override
  Result<List<StrokeId>, StructuredFailure> rectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) => _area(
    object,
    mode,
    boundsRejects: (bounds) => !_rectanglesIntersect(bounds, area),
    boundsAccepts: mode == AreaHitMode.containment
        ? (bounds) => _rectContainsRect(area, bounds)
        : null,
    matches: (geometry) => Ok(
      mode == AreaHitMode.containment
          ? geometry.containedByRectangle(area)
          : geometry.intersectsRectangle(area),
    ),
  );

  @override
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) => _area(
    object,
    mode,
    boundsRejects: (bounds) {
      return !_rectanglesIntersect(bounds, polygon.bounds);
    },
    matches: (geometry) => mode == AreaHitMode.containment
        ? geometry.containedByPolygon(polygon)
        : Ok(geometry.intersectsPolygon(polygon)),
  );

  Result<List<StrokeId>, StructuredFailure> _area(
    ObjectEnvelope object,
    AreaHitMode mode, {
    required bool Function(Rect2 bounds) boundsRejects,
    bool Function(Rect2 bounds)? boundsAccepts,
    required Result<bool, StructuredFailure> Function(
      TransformedStrokeGeometry geometry,
    )
    matches,
  }) {
    final prepared = _prepared(object);
    final payload = prepared?.payload ?? _payload(object);
    if (payload == null)
      return Err(_failure('invalid_object', FailureCategory.validation));
    if (prepared != null && boundsRejects(prepared.bounds)) {
      return const Ok([]);
    }
    if (prepared != null && boundsAccepts?.call(prepared.bounds) == true) {
      return Ok(
        List.unmodifiable(payload.strokes.reversed.map((stroke) => stroke.id)),
      );
    }
    final result = <StrokeId>[];
    for (var index = payload.strokes.length - 1; index >= 0; index -= 1) {
      final stroke = payload.strokes[index];
      final geometry = prepared == null
          ? geometryResolver.resolve(
              stroke: stroke,
              localToPage: object.transform,
            )
          : Ok<TransformedStrokeGeometry, StructuredFailure>(
              prepared.geometries[index],
            );
      if (geometry is Err<TransformedStrokeGeometry, StructuredFailure>) {
        return Err(
          _failure('geometry_unavailable', FailureCategory.dependency),
        );
      }
      _detailedHitCount += 1;
      final matched = matches(
        (geometry as Ok<TransformedStrokeGeometry, StructuredFailure>).value,
      );
      if (matched is Err<bool, StructuredFailure>) return Err(matched.error);
      if ((matched as Ok<bool, StructuredFailure>).value) {
        result.add(stroke.id);
      }
    }
    return Ok(List.unmodifiable(result));
  }
}

/// Registry-driven Page query orchestrator that fails closed for inert Objects.
final class PageHitTester {
  /// Creates the orchestrator with authoritative validity and hit registries.
  PageHitTester({
    required this.objectRegistry,
    required this.hitTestingRegistry,
    required this.maximumCandidates,
    required this.maximumResults,
    required this.maximumLassoPoints,
  });

  /// Authoritative Object validity registry.
  final ObjectRegistry objectRegistry;

  /// Separate hit-testing behavior registry.
  final HitTestingRegistry hitTestingRegistry;

  /// Maximum eligible Objects retained by one cached Page candidate index.
  final int maximumCandidates;

  /// Result ceiling.
  final int maximumResults;

  /// Lasso input ceiling.
  final int maximumLassoPoints;

  DocumentPage? _indexedPage;
  List<_PageHitCandidate> _candidates = const [];
  int _candidateIndexBuildCount = 0;
  int _registryResolutionCount = 0;

  /// Number of exact Page identities indexed for hit-test candidates.
  int get candidateIndexBuildCount => _candidateIndexBuildCount;

  /// Registry resolutions performed while building candidate indexes.
  int get registryResolutionCount => _registryResolutionCount;

  /// Returns the topmost editable Page hit.
  Result<HitTestResult?, StructuredFailure> point({
    required DocumentPage page,
    required Point2 pagePosition,
    required double pageTolerance,
  }) {
    final candidates = _index(page);
    if (candidates == null) {
      return Err(_failure('candidate_limit', FailureCategory.resource));
    }
    for (final candidate in candidates) {
      final result = candidate.definition.point(
        object: candidate.object,
        pagePosition: pagePosition,
        pageTolerance: pageTolerance,
      );
      if (result is Err<StrokeId?, StructuredFailure>) {
        return Err(result.error);
      }
      if (result is Ok<StrokeId?, StructuredFailure> && result.value != null) {
        return Ok(
          HitTestResult(
            pageId: page.id,
            layerId: candidate.layerId,
            objectId: candidate.object.id,
            strokeId: result.value,
          ),
        );
      }
      final definition = candidate.definition;
      if (definition is ObjectWholeHitTestingDefinition) {
        final whole = (definition as ObjectWholeHitTestingDefinition)
            .wholePoint(
              object: candidate.object,
              pagePosition: pagePosition,
              pageTolerance: pageTolerance,
            );
        if (whole is Err<bool, StructuredFailure>) return Err(whole.error);
        if (whole is Ok<bool, StructuredFailure> && whole.value) {
          return Ok(
            HitTestResult(
              pageId: page.id,
              layerId: candidate.layerId,
              objectId: candidate.object.id,
            ),
          );
        }
      }
    }
    return const Ok(null);
  }

  /// Returns rectangle hits in deterministic topmost-first order.
  Result<List<HitTestResult>, StructuredFailure> rectangle({
    required DocumentPage page,
    required Rect2 area,
    required AreaHitMode mode,
  }) => _area(
    page,
    (definition, object) =>
        definition.rectangle(object: object, area: area, mode: mode),
    (definition, object) =>
        definition.wholeRectangle(object: object, area: area, mode: mode),
  );

  /// Safely captures and validates a simple lasso before querying Objects.
  Result<List<HitTestResult>, StructuredFailure> lasso({
    required DocumentPage page,
    required Iterable<Point2> polygon,
    required AreaHitMode mode,
  }) {
    final captured = GeometryQueryPolygon.create(
      polygon,
      maximumPoints: maximumLassoPoints,
    );
    if (captured is Err<GeometryQueryPolygon, StructuredFailure>) {
      return Err(captured.error);
    }
    final values =
        (captured as Ok<GeometryQueryPolygon, StructuredFailure>).value;
    return _area(
      page,
      (definition, object) =>
          definition.lasso(object: object, polygon: values, mode: mode),
      (definition, object) =>
          definition.wholeLasso(object: object, polygon: values, mode: mode),
    );
  }

  Result<List<HitTestResult>, StructuredFailure> _area(
    DocumentPage page,
    Result<List<StrokeId>, StructuredFailure> Function(
      ObjectHitTestingDefinition definition,
      ObjectEnvelope object,
    )
    query,
    Result<bool, StructuredFailure> Function(
      ObjectWholeHitTestingDefinition definition,
      ObjectEnvelope object,
    )
    wholeQuery,
  ) {
    if (maximumResults < 0 || maximumResults > Revision.maximumValue) {
      return Err(_failure('invalid_result_limit', FailureCategory.validation));
    }
    final hits = <HitTestResult>[];
    final candidates = _index(page);
    if (candidates == null) {
      return Err(_failure('candidate_limit', FailureCategory.resource));
    }
    for (final candidate in candidates) {
      final result = query(candidate.definition, candidate.object);
      if (result is Err<List<StrokeId>, StructuredFailure>) {
        return Err(result.error);
      }
      final strokeIds = (result as Ok<List<StrokeId>, StructuredFailure>).value;
      for (final stroke in strokeIds) {
        if (hits.length >= maximumResults) {
          return Err(_failure('result_limit', FailureCategory.resource));
        }
        hits.add(
          HitTestResult(
            pageId: page.id,
            layerId: candidate.layerId,
            objectId: candidate.object.id,
            strokeId: stroke,
          ),
        );
      }
      final definition = candidate.definition;
      if (strokeIds.isEmpty && definition is ObjectWholeHitTestingDefinition) {
        final whole = wholeQuery(
          definition as ObjectWholeHitTestingDefinition,
          candidate.object,
        );
        if (whole is Err<bool, StructuredFailure>) return Err(whole.error);
        if (whole is Ok<bool, StructuredFailure> && whole.value) {
          if (hits.length >= maximumResults) {
            return Err(_failure('result_limit', FailureCategory.resource));
          }
          hits.add(
            HitTestResult(
              pageId: page.id,
              layerId: candidate.layerId,
              objectId: candidate.object.id,
            ),
          );
        }
      }
    }
    return Ok(List.unmodifiable(hits));
  }

  List<_PageHitCandidate>? _index(DocumentPage page) {
    if (maximumCandidates <= 0 || maximumCandidates > Revision.maximumValue) {
      return null;
    }
    if (identical(page, _indexedPage)) return _candidates;
    final candidates = <_PageHitCandidate>[];
    for (final layer in page.layers.reversed) {
      if (layer is! ContentLayer || !layer.visible || layer.locked) continue;
      for (final object in layer.objects.reversed) {
        if (!object.visible || object.locked) continue;
        if (object.typeKey == handwritingObjectTypeKey &&
            object.typeSchemaVersion != handwritingSchemaVersion)
          continue;
        _registryResolutionCount += 1;
        if (objectRegistry.resolve(object) is! SupportedObjectResolution) {
          continue;
        }
        final definition = hitTestingRegistry.definitions[object.typeKey];
        if (definition == null) continue;
        if (candidates.length >= maximumCandidates) return null;
        candidates.add(_PageHitCandidate(layer.id, object, definition));
      }
    }
    _indexedPage = page;
    _candidates = List.unmodifiable(candidates);
    _candidateIndexBuildCount += 1;
    return _candidates;
  }
}

final class _PageHitCandidate {
  const _PageHitCandidate(this.layerId, this.object, this.definition);
  final LayerId layerId;
  final ObjectEnvelope object;
  final ObjectHitTestingDefinition definition;
}

bool _rectanglesIntersect(Rect2 first, Rect2 second) =>
    first.left <= second.right &&
    first.right >= second.left &&
    first.top <= second.bottom &&
    first.bottom >= second.top;

bool _rectContainsRect(Rect2 outer, Rect2 inner) =>
    outer.left <= inner.left &&
    outer.top <= inner.top &&
    outer.right >= inner.right &&
    outer.bottom >= inner.bottom;

bool _pointInExpandedRect(Point2 point, Rect2 bounds, double amount) =>
    point.x >= bounds.left - amount &&
    point.x <= bounds.right + amount &&
    point.y >= bounds.top - amount &&
    point.y <= bounds.bottom + amount;

StructuredFailure _failure(String leaf, FailureCategory category) =>
    StructuredFailure(
      code: 'drawing.hit_testing.$leaf',
      category: category,
      retryDisposition: RetryDisposition.never,
      message: 'Hit-testing input or behavior is invalid or unavailable.',
    );
