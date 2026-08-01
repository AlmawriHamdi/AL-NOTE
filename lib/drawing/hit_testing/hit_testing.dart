// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

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
    required List<Point2> polygon,
    required AreaHitMode mode,
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
    implements ObjectHitTestingDefinition {
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
    required List<Point2> polygon,
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
    required List<Point2> polygon,
    required AreaHitMode mode,
  }) => _area(
    object,
    mode,
    boundsRejects: (bounds) {
      final polygonBounds = _polygonBounds(polygon);
      return polygonBounds != null &&
          !_rectanglesIntersect(bounds, polygonBounds);
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
  );

  /// Safely captures and validates a simple lasso before querying Objects.
  Result<List<HitTestResult>, StructuredFailure> lasso({
    required DocumentPage page,
    required Iterable<Point2> polygon,
    required AreaHitMode mode,
  }) {
    final captured = _captureLasso(polygon, maximumLassoPoints);
    if (captured is Err<List<Point2>, StructuredFailure>)
      return Err(captured.error);
    final values = (captured as Ok<List<Point2>, StructuredFailure>).value;
    return _area(
      page,
      (definition, object) =>
          definition.lasso(object: object, polygon: values, mode: mode),
    );
  }

  Result<List<HitTestResult>, StructuredFailure> _area(
    DocumentPage page,
    Result<List<StrokeId>, StructuredFailure> Function(
      ObjectHitTestingDefinition definition,
      ObjectEnvelope object,
    )
    query,
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
      if (result is! Ok<List<StrokeId>, StructuredFailure>) continue;
      for (final stroke in result.value) {
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

Result<List<Point2>, StructuredFailure> _captureLasso(
  Iterable<Point2> source,
  int maximum,
) {
  if (maximum < 3 || maximum > Revision.maximumValue) {
    return Err(_failure('invalid_lasso_limit', FailureCategory.validation));
  }
  final points = <Point2>[];
  try {
    final iterator = source.iterator;
    while (true) {
      final next = iterator.moveNext();
      if (!next) break;
      if (points.length >= maximum) {
        return Err(_failure('lasso_limit', FailureCategory.resource));
      }
      points.add(iterator.current);
    }
  } on Object {
    return Err(_failure('invalid_lasso_iterable', FailureCategory.dependency));
  }
  if (points.length < 3 || points.toSet().length != points.length) {
    return Err(_failure('invalid_lasso', FailureCategory.validation));
  }
  var twiceArea = 0.0;
  for (var index = 0; index < points.length; index += 1) {
    final next = points[(index + 1) % points.length];
    twiceArea += points[index].x * next.y - next.x * points[index].y;
  }
  if (!twiceArea.isFinite || twiceArea == 0 || _selfIntersects(points)) {
    return Err(_failure('invalid_lasso', FailureCategory.validation));
  }
  return Ok(List.unmodifiable(points));
}

bool _selfIntersects(List<Point2> points) {
  for (var first = 0; first < points.length; first += 1) {
    final firstNext = (first + 1) % points.length;
    for (var second = first + 1; second < points.length; second += 1) {
      final secondNext = (second + 1) % points.length;
      if (first == second || firstNext == second || secondNext == first)
        continue;
      if (_segmentsIntersect(
        points[first],
        points[firstNext],
        points[second],
        points[secondNext],
      )) {
        return true;
      }
    }
  }
  return false;
}

bool _segmentsIntersect(Point2 a, Point2 b, Point2 c, Point2 d) {
  double orientation(Point2 p, Point2 q, Point2 r) =>
      (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x);
  bool onSegment(Point2 p, Point2 q, Point2 r) =>
      q.x >= math.min(p.x, r.x) &&
      q.x <= math.max(p.x, r.x) &&
      q.y >= math.min(p.y, r.y) &&
      q.y <= math.max(p.y, r.y);
  final one = orientation(a, b, c), two = orientation(a, b, d);
  final three = orientation(c, d, a), four = orientation(c, d, b);
  if (one == 0 && onSegment(a, c, b)) return true;
  if (two == 0 && onSegment(a, d, b)) return true;
  if (three == 0 && onSegment(c, a, d)) return true;
  if (four == 0 && onSegment(c, b, d)) return true;
  return one.sign != two.sign && three.sign != four.sign;
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

Rect2? _polygonBounds(List<Point2> polygon) {
  if (polygon.isEmpty) return null;
  var left = polygon.first.x;
  var right = left;
  var top = polygon.first.y;
  var bottom = top;
  for (final point in polygon.skip(1)) {
    left = math.min(left, point.x);
    right = math.max(right, point.x);
    top = math.min(top, point.y);
    bottom = math.max(bottom, point.y);
  }
  return Rect2.fromEdges(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
}

StructuredFailure _failure(String leaf, FailureCategory category) =>
    StructuredFailure(
      code: 'drawing.hit_testing.$leaf',
      category: category,
      retryDisposition: RetryDisposition.never,
      message: 'Hit-testing input or behavior is invalid or unavailable.',
    );
