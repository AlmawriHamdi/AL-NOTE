// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';

/// Explicit ceilings and deterministic ellipse resolution for stroke geometry.
final class StrokeGeometryLimits {
  const StrokeGeometryLimits._({
    required this.maximumElements,
    required this.maximumVertices,
    required this.ellipseVertexCount,
    required this.maximumContainmentChecks,
  });

  /// Creates Web-safe geometry ceilings and an ellipse resolution of at least 8.
  static Result<StrokeGeometryLimits, StructuredFailure> create({
    required int maximumElements,
    required int maximumVertices,
    required int ellipseVertexCount,
    required int maximumContainmentChecks,
  }) {
    if (maximumElements <= 0 ||
        maximumElements > Revision.maximumValue ||
        maximumVertices <= 0 ||
        maximumVertices > Revision.maximumValue ||
        ellipseVertexCount < 8 ||
        ellipseVertexCount > maximumVertices ||
        maximumContainmentChecks <= 0 ||
        maximumContainmentChecks > Revision.maximumValue) {
      return Err(_failure('invalid_limits'));
    }
    return Ok(
      StrokeGeometryLimits._(
        maximumElements: maximumElements,
        maximumVertices: maximumVertices,
        ellipseVertexCount: ellipseVertexCount,
        maximumContainmentChecks: maximumContainmentChecks,
      ),
    );
  }

  /// Maximum visible polygons produced for one stroke.
  final int maximumElements;

  /// Maximum combined vertices produced for one stroke.
  final int maximumVertices;

  /// Deterministic vertex count used for transformed circular joins and caps.
  final int ellipseVertexCount;

  /// Maximum edge and interval checks permitted for one containment query.
  final int maximumContainmentChecks;
}

/// One immutable finite convex Page-space polygon forming visible stroke area.
final class StrokeGeometryElement {
  StrokeGeometryElement._(List<Point2> vertices, this.bounds)
    : vertices = List<Point2>.unmodifiable(vertices);

  /// Ordered polygon vertices.
  final List<Point2> vertices;

  /// Exact bounds of the represented polygon.
  final Rect2 bounds;
}

/// One normalized erased interval on a source sample segment.
final class StrokeErasureInterval {
  const StrokeErasureInterval._(this.start, this.end);

  /// Creates one finite ordered normalized interval.
  static Result<StrokeErasureInterval, StructuredFailure> create({
    required double start,
    required double end,
  }) {
    if (!start.isFinite ||
        !end.isFinite ||
        start < 0 ||
        end > 1 ||
        start > end) {
      return Err(_failure('invalid_erasure_interval'));
    }
    return Ok(StrokeErasureInterval._(start, end));
  }

  /// Inclusive normalized interval start in the range zero through one.
  final double start;

  /// Inclusive normalized interval end in the range zero through one.
  final double end;
}

/// Bounded work evidence for one exact source-segment erasure classification.
final class StrokeErasureClassificationEvidence {
  StrokeErasureClassificationEvidence._({
    required List<StrokeErasureInterval> intervals,
    required this.geometryResolutions,
    required this.spatialElementsExamined,
    required this.classificationChecks,
    required this.maximumSearchDepth,
    required this.maximumPendingIntervals,
    required this.ordinaryAnalyticClassifications,
    required this.exactFallbackClassifications,
    required this.exactFallbackExhaustions,
    required this.maximumInnerOperationMicros,
  }) : intervals = List.unmodifiable(intervals);

  /// Exact erased intervals in ascending source order.
  final List<StrokeErasureInterval> intervals;

  /// Authoritative source-envelope geometries resolved.
  final int geometryResolutions;

  /// Spatial-index elements examined by the source-envelope preflight.
  final int spatialElementsExamined;

  /// Direct convex-distance evaluations performed.
  final int classificationChecks;

  /// Deepest certified representable interval subdivision reached.
  final int maximumSearchDepth;

  /// Maximum pending certified parameter intervals.
  final int maximumPendingIntervals;

  /// Classifications completed by the bounded analytic hot path.
  final int ordinaryAnalyticClassifications;

  /// Ambiguous classifications or predicates requiring exact dyadic work.
  final int exactFallbackClassifications;

  /// Exact fallbacks stopped by their deterministic aggregate ceiling.
  final int exactFallbackExhaustions;

  /// Largest measured duration of one indivisible classifier operation.
  final int maximumInnerOperationMicros;
}

/// One bounded resumable advance of a prepared erasure classification.
final class StrokeErasureClassificationProgress {
  const StrokeErasureClassificationProgress._({
    required this.completed,
    required this.evidence,
    required this.predicateEvaluations,
    required this.rootIsolationAdvances,
    required this.featureTransitions,
    required this.pendingIntervals,
  });

  /// Whether the classification produced final [evidence].
  final bool completed;

  /// Final certified evidence, present only when [completed] is true.
  final StrokeErasureClassificationEvidence? evidence;

  /// Primitive polygon/capsule predicates evaluated by this advance.
  final int predicateEvaluations;

  /// Search or boundary brackets advanced by this call.
  final int rootIsolationAdvances;

  /// Fixed-size polygon features traversed by this call.
  final int featureTransitions;

  /// Certified parameter intervals retained for later calls.
  final int pendingIntervals;
}

/// Mutable-internal, caller-owned prepared classification state.
///
/// Each [advance] call performs no more than the explicitly supplied primitive
/// ceilings. Search brackets, witnesses, and boundary state remain owned by
/// this object, so no completed predicate or root-isolation step is replayed.
final class PreparedStrokeErasureClassification {
  PreparedStrokeErasureClassification._(
    this._classifier, {
    required this._countPreparation,
  });

  final _ResumableErasureClassifier _classifier;
  final bool _countPreparation;

  /// Advances certified work under independent primitive ceilings.
  Result<StrokeErasureClassificationProgress, StructuredFailure> advance({
    required int maximumPredicateEvaluations,
    required int maximumRootIsolationAdvances,
    required int maximumFeatureTransitions,
    required int maximumElapsedMicros,
  }) {
    try {
      final advanced = _classifier.advance(
        maximumPredicateEvaluations: maximumPredicateEvaluations,
        maximumRootIsolationAdvances: maximumRootIsolationAdvances,
        maximumFeatureTransitions: maximumFeatureTransitions,
        maximumElapsedMicros: maximumElapsedMicros,
      );
      if (advanced is! Ok<_ResumableAdvance, StructuredFailure>) {
        return Err(
          (advanced as Err<_ResumableAdvance, StructuredFailure>).error,
        );
      }
      final value = advanced.value;
      return Ok(
        StrokeErasureClassificationProgress._(
          completed: value.intervals != null,
          evidence: value.intervals == null
              ? null
              : StrokeErasureClassificationEvidence._(
                  intervals: value.intervals!,
                  geometryResolutions: _countPreparation ? 1 : 0,
                  spatialElementsExamined: 0,
                  classificationChecks: _classifier.totalPredicates,
                  maximumSearchDepth: _classifier.maximumDepth,
                  maximumPendingIntervals: _classifier.maximumPending,
                  ordinaryAnalyticClassifications:
                      _classifier.ordinaryClassifications,
                  exactFallbackClassifications:
                      _classifier.exactFallbackClassifications,
                  exactFallbackExhaustions:
                      _classifier.exactFallbackExhaustions,
                  maximumInnerOperationMicros:
                      _classifier.maximumInnerOperationMicros,
                ),
          predicateEvaluations: value.predicateEvaluations,
          rootIsolationAdvances: value.rootIsolationAdvances,
          featureTransitions: value.featureTransitions,
          pendingIntervals: _classifier.pendingCount,
        ),
      );
    } on Object {
      return Err(_failure('erasure_classification_unavailable'));
    }
  }
}

/// Stroke-owned transformed cross-section evidence prepared once for erasure.
///
/// The evidence contains no caller-controlled collections and is created only
/// by [StrokeGeometryResolver.prepareStrokeErasure]. It can be reused for
/// every swept segment in one Eraser gesture.
final class PreparedStrokeErasureGeometry {
  PreparedStrokeErasureGeometry._(List<_PreparedErasureSegment> segments)
    : _segments = List.unmodifiable(segments);

  final List<_PreparedErasureSegment> _segments;

  /// Number of source sample segments represented by this evidence.
  int get sourceSegmentCount => _segments.length;
}

/// Immutable finite Page-space path captured under an explicit practical cap.
final class SweptPath {
  SweptPath._(List<Point2> points) : points = List.unmodifiable(points);

  /// Largest path ceiling accepted by [create].
  static const int maximumSupportedPoints = 1000000;

  /// Whether [middle] is exactly redundant between [first] and [last].
  ///
  /// Only exact duplicates or exactly collinear same-direction evidence is
  /// removable. Exact dyadic arithmetic prevents a rounded near-collinear
  /// point from changing authoritative swept-capsule coverage.
  static Result<bool, StructuredFailure> isRedundantMiddle({
    required Point2 first,
    required Point2 middle,
    required Point2 last,
  }) {
    if (middle == first || middle == last) return const Ok(true);
    try {
      final exactFirst = _ExactPoint.fromPoint(first);
      final exactMiddle = _ExactPoint.fromPoint(middle);
      final exactLast = _ExactPoint.fromPoint(last);
      final incoming = exactMiddle - exactFirst;
      final outgoing = exactLast - exactMiddle;
      return Ok(
        _exactCross(incoming, outgoing).compareTo(_Dyadic._zero) == 0 &&
            _exactDot(incoming, outgoing).compareTo(_Dyadic._zero) > 0,
      );
    } on Object {
      return Err(_failure('swept_compaction_unavailable'));
    }
  }

  /// Safely captures [source] without trusting collection metadata or tails.
  static Result<SweptPath, StructuredFailure> create(
    Iterable<Point2> source, {
    required int maximumPoints,
  }) {
    if (maximumPoints <= 0 ||
        maximumPoints > Revision.maximumValue ||
        maximumPoints > maximumSupportedPoints) {
      return Err(_failure('invalid_path_limit'));
    }
    final points = <Point2>[];
    try {
      final iterator = source.iterator;
      while (true) {
        final more = iterator.moveNext();
        if (!more) break;
        if (points.length >= maximumPoints) {
          return Err(_failure('path_limit'));
        }
        points.add(iterator.current);
      }
    } on Object {
      return Err(_failure('path_unavailable'));
    }
    if (points.isEmpty) return Err(_failure('empty_path'));
    return Ok(SweptPath._(points));
  }

  /// Validated immutable points in accepted order.
  final List<Point2> points;
}

/// Immutable validated simple Page-space polygon for geometry queries.
final class GeometryQueryPolygon {
  GeometryQueryPolygon._(List<Point2> points, this.bounds)
    : points = List.unmodifiable(points);

  /// Largest explicit polygon point ceiling accepted by [create].
  static const int maximumSupportedPoints = 10000;

  /// Safely captures and validates one simple nondegenerate polygon.
  static Result<GeometryQueryPolygon, StructuredFailure> create(
    Iterable<Point2> source, {
    required int maximumPoints,
  }) {
    if (maximumPoints < 3 ||
        maximumPoints > maximumSupportedPoints ||
        maximumPoints > Revision.maximumValue) {
      return Err(_failure('invalid_polygon_limit'));
    }
    final points = <Point2>[];
    try {
      final iterator = source.iterator;
      while (true) {
        final more = iterator.moveNext();
        if (!more) break;
        if (points.length >= maximumPoints) {
          return Err(_failure('polygon_limit'));
        }
        points.add(iterator.current);
      }
    } on Object {
      return Err(_failure('polygon_unavailable'));
    }
    if (points.length < 3 || points.toSet().length != points.length) {
      return Err(_failure('invalid_polygon'));
    }
    final scale = points
        .map((point) => math.max(point.x.abs(), point.y.abs()))
        .reduce(math.max);
    if (scale == 0 || !scale.isFinite) {
      return Err(_failure('invalid_polygon'));
    }
    var twiceArea = 0.0;
    for (var index = 0; index < points.length; index += 1) {
      final next = points[(index + 1) % points.length];
      twiceArea +=
          points[index].x / scale * (next.y / scale) -
          next.x / scale * (points[index].y / scale);
    }
    if (!twiceArea.isFinite || twiceArea == 0 || _selfIntersects(points)) {
      return Err(_failure('invalid_polygon'));
    }
    final bounds = _boundsOf(points);
    if (bounds == null) return Err(_failure('invalid_polygon'));
    return Ok(GeometryQueryPolygon._(points, bounds));
  }

  /// Validated immutable vertices in boundary order.
  final List<Point2> points;

  /// Exact finite bounds of [points].
  final Rect2 bounds;
}

/// Immutable shared Page-space visible geometry for one transformed stroke.
final class TransformedStrokeGeometry {
  TransformedStrokeGeometry._(
    List<StrokeGeometryElement> elements,
    List<Set<int>> elementSourceSegments,
    this.bounds,
    this.maximumContainmentChecks,
  ) : elements = List<StrokeGeometryElement>.unmodifiable(elements),
      _spatialIndex = _StrokeGeometryNode.build(elements),
      _elementSourceSegments = HashMap.identity() {
    var maximumSourceSegment = 0;
    for (var index = 0; index < elements.length; index += 1) {
      final segments = Set<int>.unmodifiable(elementSourceSegments[index]);
      _elementSourceSegments[elements[index]] = segments;
      for (final segment in segments) {
        maximumSourceSegment = math.max(maximumSourceSegment, segment);
      }
    }
    final grouped = List.generate(
      maximumSourceSegment + 1,
      (_) => <StrokeGeometryElement>[],
    );
    for (final element in elements) {
      for (final segment in _elementSourceSegments[element] ?? const <int>{}) {
        grouped[segment].add(element);
      }
    }
    _sourceSegmentElements = List.unmodifiable(
      grouped.map(List<StrokeGeometryElement>.unmodifiable),
    );
  }

  /// Convex elements whose union is the visible transformed raw stroke.
  final List<StrokeGeometryElement> elements;

  /// Bounds of the complete visible geometry.
  final Rect2 bounds;

  /// Maximum exact checks permitted by one containment query.
  final int maximumContainmentChecks;
  final _StrokeGeometryNode _spatialIndex;
  final HashMap<StrokeGeometryElement, Set<int>> _elementSourceSegments;
  late final List<List<StrokeGeometryElement>> _sourceSegmentElements;

  /// Returns prepared visible elements associated with one source segment.
  List<StrokeGeometryElement> sourceSegmentElements(int sourceSegment) =>
      sourceSegment < 0 || sourceSegment >= _sourceSegmentElements.length
      ? const []
      : _sourceSegmentElements[sourceSegment];

  /// Whether a Page-space point lies within geometry plus [tolerance].
  bool hitsPoint(Point2 point, double tolerance) {
    if (!tolerance.isFinite || tolerance < 0) return false;
    final expanded = _expanded(bounds, tolerance);
    // If finite inputs overflow during the conservative bounds expansion, do
    // not use the original bounds as a rejecting prefilter.
    if (expanded != null && !expanded.contains(point)) return false;
    bool matches(StrokeGeometryElement element) =>
        _pointInConvex(point, element.vertices) ||
        _distanceToPolygon(point, element.vertices) <= tolerance;
    final query = Rect2.fromEdges(
      left: point.x - tolerance,
      top: point.y - tolerance,
      right: point.x + tolerance,
      bottom: point.y + tolerance,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
    return query == null
        ? elements.any(matches)
        : _spatialIndex.any(query, matches);
  }

  /// Whether any visible geometry intersects [rectangle].
  bool intersectsRectangle(Rect2 rectangle) => _spatialIndex.any(
    rectangle,
    (element) => _polygonIntersectsRectangle(element.vertices, rectangle),
  );

  /// Whether all visible geometry is contained by [rectangle].
  bool containedByRectangle(Rect2 rectangle) =>
      elements.every((element) => element.vertices.every(rectangle.contains));

  /// Whether any visible geometry intersects a validated simple polygon.
  bool intersectsPolygon(GeometryQueryPolygon polygon) => elements.any(
    (element) => _polygonsIntersect(element.vertices, polygon.points),
  );

  /// Whether all visible geometry is contained by a validated simple polygon.
  Result<bool, StructuredFailure> containedByPolygon(
    GeometryQueryPolygon polygon,
  ) {
    final points = polygon.points;
    var checks = 0;
    bool consume() => ++checks <= maximumContainmentChecks;
    for (final element in elements) {
      for (final point in element.vertices) {
        if (!consume()) return Err(_failure('containment_limit'));
        if (!_pointInPolygon(point, points)) return const Ok(false);
      }
      for (var edge = 0; edge < element.vertices.length; edge += 1) {
        final first = element.vertices[edge];
        final second = element.vertices[(edge + 1) % element.vertices.length];
        final parameters = <double>[0, 1];
        for (var boundary = 0; boundary < points.length; boundary += 1) {
          if (!consume()) return Err(_failure('containment_limit'));
          final value = _segmentIntersectionParameter(
            first,
            second,
            points[boundary],
            points[(boundary + 1) % points.length],
          );
          if (value != null && value > 0 && value < 1) parameters.add(value);
        }
        parameters.sort();
        for (var index = 1; index < parameters.length; index += 1) {
          if (!consume()) return Err(_failure('containment_limit'));
          final t = (parameters[index - 1] + parameters[index]) / 2;
          final midpoint = _point(
            first.x + (second.x - first.x) * t,
            first.y + (second.y - first.y) * t,
          );
          if (!_pointInPolygon(midpoint, points)) return const Ok(false);
        }
      }
    }
    return const Ok(true);
  }

  /// Whether visible geometry intersects a validated swept Page path.
  Result<bool, StructuredFailure> intersectsSweptPath(
    SweptPath path,
    double radius,
  ) => querySweptPath(
    path,
    radius,
  ).fold(onOk: (value) => Ok(value.intersects), onErr: Err.new);

  /// Queries the prepared spatial index and reports detailed element work.
  Result<({bool intersects, int examinedElements}), StructuredFailure>
  querySweptPath(SweptPath path, double radius) {
    if (!radius.isFinite || radius < 0) {
      return Err(_failure('invalid_swept_query'));
    }
    final queryBounds = _pathBounds(path.points, radius);
    var examined = 0;
    bool matches(StrokeGeometryElement element) {
      examined += 1;
      return _elementIntersectsSweptPath(element, path.points, radius);
    }

    final hit = queryBounds == null
        ? elements.any(matches)
        : _spatialIndex.any(queryBounds, matches);
    return Ok((intersects: hit, examinedElements: examined));
  }

  /// Returns source-sample segment indices touched by one bounded swept path.
  Result<({List<int> sourceSegments, int examinedElements}), StructuredFailure>
  querySweptPathSourceSegments(SweptPath path, double radius) {
    if (!radius.isFinite || radius < 0) {
      return Err(_failure('invalid_swept_query'));
    }
    final queryBounds = _pathBounds(path.points, radius);
    var examined = 0;
    final segments = <int>{};
    void visit(StrokeGeometryElement element) {
      examined += 1;
      if (_elementIntersectsSweptPath(element, path.points, radius)) {
        segments.addAll(_elementSourceSegments[element] ?? const {});
      }
    }

    if (queryBounds == null) {
      for (final element in elements) {
        visit(element);
      }
    } else {
      _spatialIndex.visitMatches(queryBounds, visit);
    }
    final ordered = segments.toList()..sort();
    return Ok((
      sourceSegments: List<int>.unmodifiable(ordered),
      examinedElements: examined,
    ));
  }
}

bool _elementIntersectsSweptPath(
  StrokeGeometryElement element,
  List<Point2> path,
  double radius,
) {
  if (path.any(
    (point) =>
        _pointInPolygon(point, element.vertices) ||
        _distanceToPolygon(point, element.vertices) <= radius,
  )) {
    return true;
  }
  for (var index = 1; index < path.length; index += 1) {
    final first = path[index - 1], second = path[index];
    for (var edge = 0; edge < element.vertices.length; edge += 1) {
      final a = element.vertices[edge];
      final b = element.vertices[(edge + 1) % element.vertices.length];
      if (_segmentsIntersect(first, second, a, b) ||
          _segmentToSegmentDistance(first, second, a, b) <= radius) {
        return true;
      }
    }
  }
  return false;
}

Rect2? _pathBounds(List<Point2> path, double radius) {
  final bounds = _boundsOf(path);
  return bounds == null ? null : _expanded(bounds, radius);
}

Rect2 _elementBounds(List<StrokeGeometryElement> elements) =>
    _rectUnion(elements.map((value) => value.bounds));

Rect2 _rectUnion(Iterable<Rect2> values) {
  final iterator = values.iterator;
  if (!iterator.moveNext()) throw const _GeometryBuildException();
  var result = iterator.current;
  while (iterator.moveNext()) {
    final value = iterator.current;
    result =
        Rect2.fromEdges(
          left: math.min(result.left, value.left),
          top: math.min(result.top, value.top),
          right: math.max(result.right, value.right),
          bottom: math.max(result.bottom, value.bottom),
        ).fold<Rect2>(
          onOk: (created) => created,
          onErr: (_) => throw const _GeometryBuildException(),
        );
  }
  return result;
}

bool _rectanglesIntersect(Rect2 first, Rect2 second) =>
    first.left <= second.right &&
    first.right >= second.left &&
    first.top <= second.bottom &&
    first.bottom >= second.top;

final class _StrokeGeometryNode {
  const _StrokeGeometryNode._(this.bounds, this.children, this.elements);

  factory _StrokeGeometryNode.build(List<StrokeGeometryElement> source) {
    var level = <_StrokeGeometryNode>[];
    for (var start = 0; start < source.length; start += 16) {
      final end = math.min(start + 16, source.length);
      final elements = List<StrokeGeometryElement>.unmodifiable(
        source.sublist(start, end),
      );
      level.add(
        _StrokeGeometryNode._(_elementBounds(elements), const [], elements),
      );
    }
    while (level.length > 1) {
      final next = <_StrokeGeometryNode>[];
      for (var start = 0; start < level.length; start += 2) {
        final children = List<_StrokeGeometryNode>.unmodifiable(
          level.sublist(start, math.min(start + 2, level.length)),
        );
        next.add(
          _StrokeGeometryNode._(
            _rectUnion(children.map((value) => value.bounds)),
            children,
            const [],
          ),
        );
      }
      level = next;
    }
    return level.single;
  }

  final Rect2 bounds;
  final List<_StrokeGeometryNode> children;
  final List<StrokeGeometryElement> elements;

  bool any(Rect2 query, bool Function(StrokeGeometryElement) matches) {
    if (!_rectanglesIntersect(bounds, query)) return false;
    for (final child in children) {
      if (child.any(query, matches)) return true;
    }
    for (final element in elements) {
      if (_rectanglesIntersect(element.bounds, query) && matches(element)) {
        return true;
      }
    }
    return false;
  }

  void visitMatches(
    Rect2 query,
    void Function(StrokeGeometryElement element) visitor,
  ) {
    if (!_rectanglesIntersect(bounds, query)) return;
    for (final child in children) {
      child.visitMatches(query, visitor);
    }
    for (final element in elements) {
      if (_rectanglesIntersect(element.bounds, query)) visitor(element);
    }
  }
}

/// Builds the common transform-correct visible geometry used by every subsystem.
final class StrokeGeometryResolver {
  /// Creates a resolver with explicit geometry ceilings.
  const StrokeGeometryResolver(this.limits);

  /// Maximum point/envelope predicates used by one classification.
  ///
  /// Classification treats a prepared cross-section as a homothetic convex
  /// polygon whose center and radius vary affinely with the source parameter.
  /// The union over any parameter interval is therefore exactly the convex
  /// hull of its endpoint polygons. Ordinary positive-radius predicates use
  /// scale-normalized floating distance bounds. The error band is widened
  /// outward by accumulated-operation ulps; only a lower bound above the
  /// radius proves a miss and only an upper bound below it proves a hit.
  /// Ambiguous boundary predicates use the exact dyadic fallback as one
  /// resumable primitive, never an unbounded search inside one call.
  /// A returned interval is bounded by representable hit witnesses. If a
  /// tangent has no representable witness, ordering cannot progress, or this
  /// proof budget is exhausted, classification fails instead of guessing.
  static const int maximumPreparedClassificationChecks = 256;

  /// Geometry construction ceilings.
  final StrokeGeometryLimits limits;

  /// Prepares authoritative transformed cross-sections once for one Stroke.
  Result<PreparedStrokeErasureGeometry, StructuredFailure>
  prepareStrokeErasure({
    required HandwritingStroke stroke,
    required AffineTransform2D localToPage,
  }) => _prepareStrokeErasure(
    samples: stroke.samples,
    style: stroke.style,
    localToPage: localToPage,
  );

  Result<PreparedStrokeErasureGeometry, StructuredFailure>
  _prepareStrokeErasure({
    required List<StrokeSample> samples,
    required StrokeStyle style,
    required AffineTransform2D localToPage,
  }) {
    try {
      final count = samples.length == 1 ? 1 : samples.length - 1;
      final segments = <_PreparedErasureSegment>[];
      for (var index = 0; index < count; index += 1) {
        final first = samples.length == 1 ? samples.single : samples[index];
        final second = samples.length == 1
            ? samples.single
            : samples[index + 1];
        final startPolygon = <Point2>[];
        for (final point in _circle(
          first.position,
          style.widthFor(first.pressure) / 2,
          limits.ellipseVertexCount,
        )) {
          final transformed = localToPage.applyToPoint(point);
          if (transformed is! Ok<Point2, StructuredFailure>) {
            return Err(_failure('erasure_preparation_unavailable'));
          }
          startPolygon.add(transformed.value);
        }
        final endPolygon = <Point2>[];
        for (final point in _circle(
          second.position,
          style.widthFor(second.pressure) / 2,
          limits.ellipseVertexCount,
        )) {
          final transformed = localToPage.applyToPoint(point);
          if (transformed is! Ok<Point2, StructuredFailure>) {
            return Err(_failure('erasure_preparation_unavailable'));
          }
          endPolygon.add(transformed.value);
        }
        segments.add(
          _PreparedErasureSegment(
            localStart: first.position,
            localEnd: second.position,
            startRadius: style.widthFor(first.pressure) / 2,
            endRadius: style.widthFor(second.pressure) / 2,
            transformCoefficients: localToPage.storageCoefficients,
            vertexCount: limits.ellipseVertexCount,
            startPolygon: startPolygon,
            endPolygon: endPolygon,
          ),
        );
      }
      return Ok(PreparedStrokeErasureGeometry._(segments));
    } on Object {
      return Err(_failure('erasure_preparation_unavailable'));
    }
  }

  /// Classifies erased intervals for one source segment and one latest swept
  /// Eraser segment without revisiting earlier gesture segments.
  Result<List<StrokeErasureInterval>, StructuredFailure>
  classifySourceSegmentErasure({
    required StrokeSample first,
    required StrokeSample second,
    required StrokeStyle style,
    required AffineTransform2D localToPage,
    required SweptPath eraserSegment,
    required double radius,
    required HandwritingLimits handwritingLimits,
  }) => classifySourceSegmentErasureDetailed(
    first: first,
    second: second,
    style: style,
    localToPage: localToPage,
    eraserSegment: eraserSegment,
    radius: radius,
    handwritingLimits: handwritingLimits,
    maximumChecks: limits.maximumContainmentChecks,
  ).fold(onOk: (value) => Ok(value.intervals), onErr: Err.new);

  /// Classifies one source segment with a caller-supplied remaining work cap.
  Result<StrokeErasureClassificationEvidence, StructuredFailure>
  classifySourceSegmentErasureDetailed({
    required StrokeSample first,
    required StrokeSample second,
    required StrokeStyle style,
    required AffineTransform2D localToPage,
    required SweptPath eraserSegment,
    required double radius,
    required HandwritingLimits handwritingLimits,
    required int maximumChecks,
  }) {
    final prepared = _prepareStrokeErasure(
      samples: first == second ? [first] : [first, second],
      style: style,
      localToPage: localToPage,
    );
    if (prepared is! Ok<PreparedStrokeErasureGeometry, StructuredFailure>) {
      return Err(_failure('erasure_classification_unavailable'));
    }
    return classifyPreparedSourceSegmentErasure(
      prepared: prepared.value,
      sourceSegment: 0,
      eraserSegment: eraserSegment,
      radius: radius,
      maximumChecks: maximumChecks,
      countPreparation: true,
    );
  }

  /// Classifies one prepared source segment without rebuilding its geometry.
  Result<StrokeErasureClassificationEvidence, StructuredFailure>
  classifyPreparedSourceSegmentErasure({
    required PreparedStrokeErasureGeometry prepared,
    required int sourceSegment,
    required SweptPath eraserSegment,
    required double radius,
    required int maximumChecks,
    bool countPreparation = false,
  }) {
    if (eraserSegment.points.length > 2 ||
        !radius.isFinite ||
        radius < 0 ||
        sourceSegment < 0 ||
        sourceSegment >= prepared._segments.length) {
      return Err(_failure('invalid_erasure_segment'));
    }
    if (maximumChecks <= 0 || maximumChecks > limits.maximumContainmentChecks) {
      return Err(_failure('erasure_classification_limit'));
    }
    final begun = beginPreparedSourceSegmentErasure(
      prepared: prepared,
      sourceSegment: sourceSegment,
      eraserSegment: eraserSegment,
      radius: radius,
      maximumChecks: maximumChecks,
      countPreparation: countPreparation,
    );
    if (begun is! Ok<PreparedStrokeErasureClassification, StructuredFailure>) {
      return Err(_failure('erasure_classification_unavailable'));
    }
    try {
      while (true) {
        final advanced = begun.value.advance(
          maximumPredicateEvaluations: maximumChecks,
          maximumRootIsolationAdvances: maximumChecks,
          maximumFeatureTransitions: limits.ellipseVertexCount * 2,
          maximumElapsedMicros: 1000000,
        );
        if (advanced
            is! Ok<StrokeErasureClassificationProgress, StructuredFailure>) {
          return Err(
            (advanced
                    as Err<
                      StrokeErasureClassificationProgress,
                      StructuredFailure
                    >)
                .error,
          );
        }
        if (advanced.value.completed) return Ok(advanced.value.evidence!);
      }
    } on Object {
      return Err(_failure('erasure_classification_unavailable'));
    }
  }

  /// Begins one prepared source-segment classification for bounded resumption.
  Result<PreparedStrokeErasureClassification, StructuredFailure>
  beginPreparedSourceSegmentErasure({
    required PreparedStrokeErasureGeometry prepared,
    required int sourceSegment,
    required SweptPath eraserSegment,
    required double radius,
    required int maximumChecks,
    bool countPreparation = false,
  }) {
    if (eraserSegment.points.length > 2 ||
        !radius.isFinite ||
        radius < 0 ||
        sourceSegment < 0 ||
        sourceSegment >= prepared._segments.length ||
        maximumChecks <= 0 ||
        maximumChecks > limits.maximumContainmentChecks) {
      return Err(_failure('invalid_erasure_segment'));
    }
    try {
      return Ok(
        PreparedStrokeErasureClassification._(
          _ResumableErasureClassifier(
            section: prepared._segments[sourceSegment],
            path: eraserSegment.points,
            radius: radius,
            maximumChecks: maximumChecks,
          ),
          countPreparation: countPreparation,
        ),
      );
    } on Object {
      return Err(_failure('erasure_classification_unavailable'));
    }
  }

  /// Applies the complete affine transform to stroke bodies, joins, caps, and dots.
  Result<TransformedStrokeGeometry, StructuredFailure> resolve({
    required HandwritingStroke stroke,
    required AffineTransform2D localToPage,
  }) {
    try {
      return _resolve(
        samples: stroke.samples,
        style: stroke.style,
        localToPage: localToPage,
      );
    } on _GeometryBuildException {
      return Err(_failure('nonrepresentable_geometry'));
    } on Object {
      return Err(_failure('geometry_unavailable'));
    }
  }

  /// Resolves bounded temporary samples without requiring a persistent Stroke ID.
  Result<TransformedStrokeGeometry, StructuredFailure> resolvePreview({
    required Iterable<StrokeSample> samples,
    required StrokeStyle style,
    required AffineTransform2D localToPage,
    required int maximumSamples,
  }) {
    if (maximumSamples <= 0 || maximumSamples > Revision.maximumValue) {
      return Err(_failure('invalid_limits'));
    }
    final captured = <StrokeSample>[];
    try {
      final iterator = samples.iterator;
      while (true) {
        final hasNext = iterator.moveNext();
        if (!hasNext) break;
        if (captured.length >= maximumSamples)
          return Err(_failure('geometry_limit'));
        captured.add(iterator.current);
      }
    } on Object {
      return Err(_failure('geometry_unavailable'));
    }
    if (captured.isEmpty) return Err(_failure('empty_geometry'));
    try {
      return _resolve(
        samples: captured,
        style: style,
        localToPage: localToPage,
      );
    } on Object {
      return Err(_failure('nonrepresentable_geometry'));
    }
  }

  Result<TransformedStrokeGeometry, StructuredFailure> _resolve({
    required List<StrokeSample> samples,
    required StrokeStyle style,
    required AffineTransform2D localToPage,
  }) {
    final elements = <StrokeGeometryElement>[];
    final elementSourceSegments = <Set<int>>[];
    var verticesUsed = 0;

    Result<void, StructuredFailure> addLocalPolygon(
      List<Point2> local,
      Set<int> sourceSegments,
    ) {
      if (elements.length >= limits.maximumElements ||
          local.length > limits.maximumVertices - verticesUsed) {
        return Err(_failure('geometry_limit'));
      }
      final transformed = <Point2>[];
      for (final point in local) {
        final page = localToPage.applyToPoint(point);
        if (page is Err<Point2, StructuredFailure>) {
          return Err(_failure('nonrepresentable_geometry'));
        }
        transformed.add((page as Ok<Point2, StructuredFailure>).value);
      }
      final bounds = _boundsOf(transformed);
      if (bounds == null) return Err(_failure('nonrepresentable_geometry'));
      verticesUsed += transformed.length;
      elements.add(StrokeGeometryElement._(transformed, bounds));
      elementSourceSegments.add(sourceSegments);
      return const Ok(null);
    }

    for (var index = 0; index < samples.length; index += 1) {
      final sample = samples[index];
      final circle = _circle(
        sample.position,
        style.widthFor(sample.pressure) / 2,
        limits.ellipseVertexCount,
      );
      final added = addLocalPolygon(circle, {
        if (samples.length == 1) 0,
        if (index > 0) index - 1,
        if (index + 1 < samples.length) index,
      });
      if (added is Err<void, StructuredFailure>) return Err(added.error);
    }
    for (var index = 1; index < samples.length; index += 1) {
      final first = samples[index - 1];
      final second = samples[index];
      final dx = second.position.x - first.position.x;
      final dy = second.position.y - first.position.y;
      final length = math.sqrt(dx * dx + dy * dy);
      if (!length.isFinite) return Err(_failure('nonrepresentable_geometry'));
      if (length == 0) continue;
      final nx = -dy / length;
      final ny = dx / length;
      final firstRadius = style.widthFor(first.pressure) / 2;
      final secondRadius = style.widthFor(second.pressure) / 2;
      final polygon = <Point2>[
        _point(
          first.position.x + nx * firstRadius,
          first.position.y + ny * firstRadius,
        ),
        _point(
          second.position.x + nx * secondRadius,
          second.position.y + ny * secondRadius,
        ),
        _point(
          second.position.x - nx * secondRadius,
          second.position.y - ny * secondRadius,
        ),
        _point(
          first.position.x - nx * firstRadius,
          first.position.y - ny * firstRadius,
        ),
      ];
      final added = addLocalPolygon(polygon, {index - 1});
      if (added is Err<void, StructuredFailure>) return Err(added.error);
    }
    if (elements.isEmpty) return Err(_failure('empty_geometry'));
    var bounds = elements.first.bounds;
    for (final element in elements.skip(1)) {
      final merged = Rect2.fromEdges(
        left: math.min(bounds.left, element.bounds.left),
        top: math.min(bounds.top, element.bounds.top),
        right: math.max(bounds.right, element.bounds.right),
        bottom: math.max(bounds.bottom, element.bounds.bottom),
      );
      if (merged is Err<Rect2, StructuredFailure>) {
        return Err(_failure('nonrepresentable_geometry'));
      }
      bounds = (merged as Ok<Rect2, StructuredFailure>).value;
    }
    return Ok(
      TransformedStrokeGeometry._(
        elements,
        elementSourceSegments,
        bounds,
        limits.maximumContainmentChecks,
      ),
    );
  }
}

/// Immutable decoded handwriting and aligned transformed Stroke geometries.
final class PreparedHandwritingGeometry {
  PreparedHandwritingGeometry._({
    required this.payload,
    required List<TransformedStrokeGeometry> geometries,
  }) : geometries = List.unmodifiable(geometries);

  /// Validated handwriting payload captured for one exact Object envelope.
  final HandwritingPayload payload;

  /// Geometry aligned one-for-one with [HandwritingPayload.strokes].
  final List<TransformedStrokeGeometry> geometries;

  /// Conservative Page-space bounds shared by rendering and hit testing.
  Rect2 get bounds => _rectUnion(geometries.map((value) => value.bounds));
}

/// Bounded view/runtime-local cache keyed by exact immutable Object identity.
final class HandwritingGeometryCache {
  /// Creates a cache with explicit positive Web-safe Object and Stroke limits.
  HandwritingGeometryCache({
    required this.maximumObjects,
    required this.maximumStrokes,
  }) : _values =
           HashMap<ObjectEnvelope, PreparedHandwritingGeometry>.identity();

  /// Maximum exact Object envelopes retained.
  final int maximumObjects;

  /// Maximum combined Stroke geometries retained.
  final int maximumStrokes;

  final HashMap<ObjectEnvelope, PreparedHandwritingGeometry> _values;
  int _strokeCount = 0;
  int _resolutionCount = 0;

  /// Geometry resolutions performed across cache misses.
  int get resolutionCount => _resolutionCount;

  /// Returns prepared evidence, resolving each exact Object at most once.
  Result<PreparedHandwritingGeometry, StructuredFailure> prepare({
    required ObjectEnvelope object,
    required HandwritingLimits handwritingLimits,
    required StrokeGeometryResolver geometryResolver,
  }) {
    if (maximumObjects <= 0 ||
        maximumObjects > Revision.maximumValue ||
        maximumStrokes <= 0 ||
        maximumStrokes > Revision.maximumValue) {
      return Err(_failure('invalid_cache_limits'));
    }
    final existing = _values[object];
    if (existing != null) return Ok(existing);
    if (_values.length >= maximumObjects) {
      return Err(_failure('geometry_cache_object_limit'));
    }
    final decoded = HandwritingPayload.decode(
      object.payload,
      limits: handwritingLimits,
    );
    if (decoded is! Ok<HandwritingPayload, StructuredFailure>) {
      return Err(_failure('geometry_cache_payload'));
    }
    if (decoded.value.strokes.length > maximumStrokes - _strokeCount) {
      return Err(_failure('geometry_cache_stroke_limit'));
    }
    final geometries = <TransformedStrokeGeometry>[];
    for (final stroke in decoded.value.strokes) {
      final geometry = geometryResolver.resolve(
        stroke: stroke,
        localToPage: object.transform,
      );
      if (geometry is! Ok<TransformedStrokeGeometry, StructuredFailure>) {
        return Err(_failure('geometry_cache_unavailable'));
      }
      geometries.add(geometry.value);
    }
    final prepared = PreparedHandwritingGeometry._(
      payload: decoded.value,
      geometries: geometries,
    );
    _values[object] = prepared;
    _strokeCount += geometries.length;
    _resolutionCount += geometries.length;
    return Ok(prepared);
  }
}

List<Point2> _circle(Point2 center, double radius, int count) =>
    List<Point2>.generate(count, (index) {
      final angle = math.pi * 2 * index / count;
      return _point(
        center.x + math.cos(angle) * radius,
        center.y + math.sin(angle) * radius,
      );
    }, growable: false);

Point2 _point(double x, double y) => Point2.create(x: x, y: y).fold(
  onOk: (value) => value,
  onErr: (_) => throw const _GeometryBuildException(),
);

Rect2? _boundsOf(List<Point2> points) {
  if (points.isEmpty) return null;
  var left = points.first.x, right = left, top = points.first.y, bottom = top;
  for (final point in points.skip(1)) {
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

Rect2? _expanded(Rect2 value, double amount) => Rect2.fromEdges(
  left: value.left - amount,
  top: value.top - amount,
  right: value.right + amount,
  bottom: value.bottom + amount,
).fold<Rect2?>(onOk: (result) => result, onErr: (_) => null);

bool _pointInConvex(Point2 point, List<Point2> polygon) {
  double? sign;
  for (var index = 0; index < polygon.length; index += 1) {
    final a = polygon[index], b = polygon[(index + 1) % polygon.length];
    final current = _orientationSign(a, b, point);
    if (current == 0) continue;
    sign ??= current;
    if (current != sign) return false;
  }
  return true;
}

double _distanceToPolygon(Point2 point, List<Point2> polygon) {
  var best = double.infinity;
  for (var index = 0; index < polygon.length; index += 1) {
    best = math.min(
      best,
      _segmentDistance(
        point,
        polygon[index],
        polygon[(index + 1) % polygon.length],
      ),
    );
  }
  return best;
}

double _segmentDistance(Point2 point, Point2 first, Point2 second) {
  var dx = second.x - first.x, dy = second.y - first.y;
  var px = point.x - first.x, py = point.y - first.y;
  var scale = <double>[dx.abs(), dy.abs(), px.abs(), py.abs()].reduce(math.max);
  if (!scale.isFinite) {
    scale = <double>[
      point.x.abs(),
      point.y.abs(),
      first.x.abs(),
      first.y.abs(),
      second.x.abs(),
      second.y.abs(),
    ].reduce(math.max);
    if (scale == 0) return 0;
    dx = second.x / scale - first.x / scale;
    dy = second.y / scale - first.y / scale;
    px = point.x / scale - first.x / scale;
    py = point.y / scale - first.y / scale;
  } else if (scale != 0) {
    dx /= scale;
    dy /= scale;
    px /= scale;
    py /= scale;
  }
  if (dx == 0 && dy == 0) return scale * _hypot(px, py);
  final squared = dx * dx + dy * dy;
  if (squared == 0) return scale * _hypot(px, py);
  final t = math.max(0.0, math.min(1.0, (px * dx + py * dy) / squared));
  return scale * _hypot(px - t * dx, py - t * dy);
}

double _hypot(double x, double y) {
  final scale = math.max(x.abs(), y.abs());
  if (scale == 0 || !scale.isFinite) return scale;
  final a = x / scale, b = y / scale;
  return scale * math.sqrt(a * a + b * b);
}

double _segmentToSegmentDistance(Point2 a, Point2 b, Point2 c, Point2 d) {
  if (_segmentsIntersect(a, b, c, d)) return 0;
  return math.min(
    math.min(_segmentDistance(a, c, d), _segmentDistance(b, c, d)),
    math.min(_segmentDistance(c, a, b), _segmentDistance(d, a, b)),
  );
}

bool _polygonIntersectsRectangle(List<Point2> polygon, Rect2 rectangle) {
  if (polygon.any(rectangle.contains)) return true;
  final corners = <Point2>[
    rectangle.topLeft,
    _point(rectangle.right, rectangle.top),
    rectangle.bottomRight,
    _point(rectangle.left, rectangle.bottom),
  ];
  if (corners.any((point) => _pointInPolygon(point, polygon))) return true;
  return _polygonEdgesIntersect(polygon, corners);
}

bool _polygonsIntersect(List<Point2> first, List<Point2> second) =>
    first.any((point) => _pointInPolygon(point, second)) ||
    second.any((point) => _pointInPolygon(point, first)) ||
    _polygonEdgesIntersect(first, second);

bool _selfIntersects(List<Point2> points) {
  for (var first = 0; first < points.length; first += 1) {
    final firstNext = (first + 1) % points.length;
    for (var second = first + 1; second < points.length; second += 1) {
      final secondNext = (second + 1) % points.length;
      if (first == second || firstNext == second || secondNext == first) {
        continue;
      }
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

bool _polygonEdgesIntersect(List<Point2> first, List<Point2> second) {
  for (var a = 0; a < first.length; a += 1) {
    for (var b = 0; b < second.length; b += 1) {
      if (_segmentsIntersect(
        first[a],
        first[(a + 1) % first.length],
        second[b],
        second[(b + 1) % second.length],
      ))
        return true;
    }
  }
  return false;
}

bool _segmentsIntersect(Point2 a, Point2 b, Point2 c, Point2 d) {
  bool onSegment(Point2 p, Point2 q, Point2 r) =>
      q.x >= math.min(p.x, r.x) &&
      q.x <= math.max(p.x, r.x) &&
      q.y >= math.min(p.y, r.y) &&
      q.y <= math.max(p.y, r.y);
  final first = _orientationSign(a, b, c);
  final second = _orientationSign(a, b, d);
  final third = _orientationSign(c, d, a);
  final fourth = _orientationSign(c, d, b);
  if (first == 0 && onSegment(a, c, b)) return true;
  if (second == 0 && onSegment(a, d, b)) return true;
  if (third == 0 && onSegment(c, a, d)) return true;
  if (fourth == 0 && onSegment(c, b, d)) return true;
  return first != second && third != fourth;
}

double _orientationSign(Point2 p, Point2 q, Point2 r) {
  var qx = q.x - p.x, qy = q.y - p.y;
  var rx = r.x - p.x, ry = r.y - p.y;
  var scale = <double>[qx.abs(), qy.abs(), rx.abs(), ry.abs()].reduce(math.max);
  if (!scale.isFinite) {
    scale = <double>[
      p.x.abs(),
      p.y.abs(),
      q.x.abs(),
      q.y.abs(),
      r.x.abs(),
      r.y.abs(),
    ].reduce(math.max);
    if (scale == 0) return 0;
    qx = q.x / scale - p.x / scale;
    qy = q.y / scale - p.y / scale;
    rx = r.x / scale - p.x / scale;
    ry = r.y / scale - p.y / scale;
  } else if (scale != 0) {
    qx /= scale;
    qy /= scale;
    rx /= scale;
    ry /= scale;
  }
  return (qx * ry - qy * rx).sign;
}

double? _segmentIntersectionParameter(Point2 a, Point2 b, Point2 c, Point2 d) {
  final rx = b.x - a.x, ry = b.y - a.y;
  final sx = d.x - c.x, sy = d.y - c.y;
  final denominator = rx * sy - ry * sx;
  if (!denominator.isFinite || denominator == 0) return null;
  final qx = c.x - a.x, qy = c.y - a.y;
  final t = (qx * sy - qy * sx) / denominator;
  final u = (qx * ry - qy * rx) / denominator;
  if (!t.isFinite || !u.isFinite || t < 0 || t > 1 || u < 0 || u > 1) {
    return null;
  }
  return t;
}

bool _pointInPolygon(Point2 point, List<Point2> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if (_segmentDistance(point, a, b) == 0) return true;
    if ((a.y > point.y) != (b.y > point.y) &&
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x)
      inside = !inside;
  }
  return inside;
}

final class _PreparedErasureSegment {
  _PreparedErasureSegment({
    required this.localStart,
    required this.localEnd,
    required this.startRadius,
    required this.endRadius,
    required List<double> transformCoefficients,
    required int vertexCount,
    required List<Point2> startPolygon,
    required List<Point2> endPolygon,
  }) : transformCoefficients = List.unmodifiable(transformCoefficients),
       startPolygon = List.unmodifiable(startPolygon),
       endPolygon = List.unmodifiable(endPolygon),
       envelopePolygon = _convexHull([...startPolygon, ...endPolygon]),
       unitPolygon = List.unmodifiable(
         List.generate(
           vertexCount,
           (index) => (
             _Dyadic.fromDouble(math.cos(math.pi * 2 * index / vertexCount)),
             _Dyadic.fromDouble(math.sin(math.pi * 2 * index / vertexCount)),
           ),
           growable: false,
         ),
       );

  final Point2 localStart;
  final Point2 localEnd;
  final double startRadius;
  final double endRadius;
  final List<double> transformCoefficients;
  final List<Point2> startPolygon;
  final List<Point2> endPolygon;
  final List<Point2> envelopePolygon;
  final List<(_Dyadic, _Dyadic)> unitPolygon;

  bool get isDot => localStart == localEnd && startRadius == endRadius;

  Point2? vertexAtDouble(int index, double parameter) {
    final first = startPolygon[index];
    final second = endPolygon[index];
    return Point2.create(
      x: first.x + (second.x - first.x) * parameter,
      y: first.y + (second.y - first.y) * parameter,
    ).fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
  }

  List<Point2>? polygonAtDouble(double parameter) {
    final result = <Point2>[];
    for (var index = 0; index < startPolygon.length; index += 1) {
      final vertex = vertexAtDouble(index, parameter);
      if (vertex == null) return null;
      result.add(vertex);
    }
    return result;
  }

  List<_ExactPoint> polygonAt(_Dyadic parameter) {
    final center = _ExactPoint.lerp(
      _ExactPoint.fromPoint(localStart),
      _ExactPoint.fromPoint(localEnd),
      parameter,
    );
    final firstRadius = _Dyadic.fromDouble(startRadius);
    final radius =
        firstRadius + (_Dyadic.fromDouble(endRadius) - firstRadius) * parameter;
    final coefficients = transformCoefficients
        .map(_Dyadic.fromDouble)
        .toList(growable: false);
    return List.generate(unitPolygon.length, (index) {
      final unit = unitPolygon[index];
      final localX = center.x + radius * unit.$1;
      final localY = center.y + radius * unit.$2;
      return _ExactPoint(
        coefficients[0] * localX + coefficients[1] * localY + coefficients[4],
        coefficients[2] * localX + coefficients[3] * localY + coefficients[5],
      );
    }, growable: false);
  }
}

enum _ClassifierPhase {
  endpointZero,
  endpointOne,
  rootEnvelope,
  searchMidpoint,
  searchLeftEnvelope,
  searchRightEnvelope,
  leftBoundary,
  rightBoundary,
  completed,
}

enum _PredicateRelation { hit, miss }

final class _ResumableAdvance {
  const _ResumableAdvance({
    required this.intervals,
    required this.predicateEvaluations,
    required this.rootIsolationAdvances,
    required this.featureTransitions,
  });

  final List<StrokeErasureInterval>? intervals;
  final int predicateEvaluations;
  final int rootIsolationAdvances;
  final int featureTransitions;
}

enum _AnalyticPhase {
  spatial,
  features,
  probes,
  leftBoundary,
  rightBoundary,
  fallback,
  completed,
}

final class _ResumableErasureClassifier {
  _ResumableErasureClassifier({
    required this.section,
    required List<Point2> path,
    required this.radius,
    required this.maximumChecks,
  }) : pagePath = List.unmodifiable(path);

  final _PreparedErasureSegment section;
  final List<Point2> pagePath;
  final double radius;
  final int maximumChecks;
  int totalPredicates = 0;
  int maximumDepth = 0;
  int maximumPending = 1;
  int ordinaryClassifications = 0;
  int exactFallbackClassifications = 0;
  int exactFallbackExhaustions = 0;
  int maximumInnerOperationMicros = 0;
  int responsivenessBudgetOverruns = 0;
  _AnalyticPhase _phase = _AnalyticPhase.spatial;
  int _feature = 0;
  final List<double> _events = [];
  List<double> _probes = const [];
  int _probe = 0;
  final List<double> _hits = [];
  final List<double> _misses = [];
  double? _leftMiss;
  double? _leftHit;
  double? _rightHit;
  double? _rightMiss;
  List<StrokeErasureInterval>? _result;
  _SubdivisionErasureClassifier? _fallback;

  int get pendingCount => _phase == _AnalyticPhase.completed ? 0 : 1;

  Result<_ResumableAdvance, StructuredFailure> advance({
    required int maximumPredicateEvaluations,
    required int maximumRootIsolationAdvances,
    required int maximumFeatureTransitions,
    required int maximumElapsedMicros,
  }) {
    if (maximumPredicateEvaluations <= 0 ||
        maximumRootIsolationAdvances <= 0 ||
        maximumFeatureTransitions <= 0 ||
        maximumElapsedMicros <= 0) {
      return Err(_failure('invalid_erasure_work_limit'));
    }
    var predicates = 0;
    var roots = 0;
    var features = 0;
    final budgetClock = Stopwatch()..start();
    while (_phase != _AnalyticPhase.completed &&
        budgetClock.elapsedMicroseconds < maximumElapsedMicros) {
      final nextFeatureCost = switch (_phase) {
        _AnalyticPhase.probes ||
        _AnalyticPhase.leftBoundary ||
        _AnalyticPhase.rightBoundary => section.startPolygon.length,
        _AnalyticPhase.fallback => section.startPolygon.length * 2,
        _ => 1,
      };
      if (predicates >= maximumPredicateEvaluations ||
          roots >= maximumRootIsolationAdvances ||
          features + nextFeatureCost > maximumFeatureTransitions) {
        break;
      }
      if (totalPredicates >= maximumChecks) {
        exactFallbackExhaustions += 1;
        return Err(_failure('erasure_classification_limit'));
      }
      final clock = Stopwatch()..start();
      final step = _step(
        maximumPredicateEvaluations: maximumPredicateEvaluations - predicates,
        maximumRootIsolationAdvances: maximumRootIsolationAdvances - roots,
        maximumFeatureTransitions: maximumFeatureTransitions - features,
      );
      clock.stop();
      maximumInnerOperationMicros = math.max(
        maximumInnerOperationMicros,
        clock.elapsedMicroseconds,
      );
      if (step is! Ok<_ResumableAdvance, StructuredFailure>) {
        return Err((step as Err<_ResumableAdvance, StructuredFailure>).error);
      }
      if (clock.elapsedMicroseconds > maximumElapsedMicros) {
        responsivenessBudgetOverruns += 1;
      }
      predicates += step.value.predicateEvaluations;
      roots += step.value.rootIsolationAdvances;
      features += step.value.featureTransitions;
      totalPredicates += step.value.predicateEvaluations;
      if (step.value.predicateEvaluations == 0 &&
          step.value.rootIsolationAdvances == 0 &&
          step.value.featureTransitions == 0) {
        break;
      }
    }
    return Ok(
      _ResumableAdvance(
        intervals: _result,
        predicateEvaluations: predicates,
        rootIsolationAdvances: roots,
        featureTransitions: features,
      ),
    );
  }

  Result<_ResumableAdvance, StructuredFailure> _step({
    required int maximumPredicateEvaluations,
    required int maximumRootIsolationAdvances,
    required int maximumFeatureTransitions,
  }) {
    switch (_phase) {
      case _AnalyticPhase.spatial:
        if (radius == 0) {
          _startFallback();
          return const Ok(
            _ResumableAdvance(
              intervals: null,
              predicateEvaluations: 0,
              rootIsolationAdvances: 0,
              featureTransitions: 1,
            ),
          );
        }
        final relation = _floatingRelation(section.envelopePolygon);
        if (relation == _FloatingRelation.miss) {
          ordinaryClassifications = 1;
          _complete(const []);
        } else {
          _phase = _AnalyticPhase.features;
        }
        return const Ok(
          _ResumableAdvance(
            intervals: null,
            predicateEvaluations: 1,
            rootIsolationAdvances: 0,
            featureTransitions: 1,
          ),
        );
      case _AnalyticPhase.features:
        if (_feature < section.startPolygon.length) {
          _addFeatureEvents(_feature);
          _feature += 1;
          return const Ok(
            _ResumableAdvance(
              intervals: null,
              predicateEvaluations: 0,
              rootIsolationAdvances: 0,
              featureTransitions: 1,
            ),
          );
        }
        _prepareProbes();
        _phase = _AnalyticPhase.probes;
        return const Ok(
          _ResumableAdvance(
            intervals: null,
            predicateEvaluations: 0,
            rootIsolationAdvances: 0,
            featureTransitions: 1,
          ),
        );
      case _AnalyticPhase.probes:
        if (_probe < _probes.length) {
          final parameter = _probes[_probe++];
          final relation = _certifiedHitAt(parameter);
          if (relation.$1) {
            _hits.add(parameter);
          } else {
            _misses.add(parameter);
          }
          return Ok(
            _ResumableAdvance(
              intervals: null,
              predicateEvaluations: 1,
              rootIsolationAdvances: 0,
              featureTransitions: section.startPolygon.length,
            ),
          );
        }
        if (_hits.isEmpty) {
          _startFallback();
        } else {
          _hits.sort();
          if (exactFallbackClassifications == 0) ordinaryClassifications = 1;
          _complete([StrokeErasureInterval._(_hits.first, _hits.last)]);
        }
        return const Ok(
          _ResumableAdvance(
            intervals: null,
            predicateEvaluations: 0,
            rootIsolationAdvances: 0,
            featureTransitions: 1,
          ),
        );
      case _AnalyticPhase.leftBoundary:
        final middle = _analyticBracketAdvance(_leftMiss!, _leftHit!);
        if (middle == null) {
          _phase = _AnalyticPhase.rightBoundary;
          return const Ok(
            _ResumableAdvance(
              intervals: null,
              predicateEvaluations: 0,
              rootIsolationAdvances: 1,
              featureTransitions: 1,
            ),
          );
        }
        final relation = _certifiedHitAt(middle);
        if (relation.$1) {
          _leftHit = middle;
        } else {
          _leftMiss = middle;
        }
        maximumDepth += 1;
        return Ok(
          _ResumableAdvance(
            intervals: null,
            predicateEvaluations: 1,
            rootIsolationAdvances: 1,
            featureTransitions: section.startPolygon.length,
          ),
        );
      case _AnalyticPhase.rightBoundary:
        if (_rightMiss == null) {
          if (exactFallbackClassifications == 0) ordinaryClassifications = 1;
          _complete([StrokeErasureInterval._(_leftHit!, _rightHit!)]);
          return const Ok(
            _ResumableAdvance(
              intervals: null,
              predicateEvaluations: 0,
              rootIsolationAdvances: 1,
              featureTransitions: 1,
            ),
          );
        }
        final middle = _analyticBracketAdvance(_rightMiss!, _rightHit!);
        if (middle == null) {
          if (exactFallbackClassifications == 0) ordinaryClassifications = 1;
          _complete([StrokeErasureInterval._(_leftHit!, _rightHit!)]);
          return const Ok(
            _ResumableAdvance(
              intervals: null,
              predicateEvaluations: 0,
              rootIsolationAdvances: 1,
              featureTransitions: 1,
            ),
          );
        }
        final relation = _certifiedHitAt(middle);
        if (relation.$1) {
          _rightHit = middle;
        } else {
          _rightMiss = middle;
        }
        maximumDepth += 1;
        return Ok(
          _ResumableAdvance(
            intervals: null,
            predicateEvaluations: 1,
            rootIsolationAdvances: 1,
            featureTransitions: section.startPolygon.length,
          ),
        );
      case _AnalyticPhase.fallback:
        final advanced = _fallback!.advance(
          maximumPredicateEvaluations: math.min(1, maximumPredicateEvaluations),
          maximumRootIsolationAdvances: math.min(
            1,
            maximumRootIsolationAdvances,
          ),
          maximumFeatureTransitions: math.min(
            section.startPolygon.length * 2,
            maximumFeatureTransitions,
          ),
        );
        if (advanced is! Ok<_ResumableAdvance, StructuredFailure>) {
          exactFallbackExhaustions += 1;
          return advanced;
        }
        maximumDepth = math.max(maximumDepth, _fallback!.maximumDepth);
        maximumPending = math.max(maximumPending, _fallback!.maximumPending);
        if (advanced.value.intervals != null) {
          _complete(advanced.value.intervals!);
        }
        return advanced;
      case _AnalyticPhase.completed:
        return Ok(
          _ResumableAdvance(
            intervals: _result,
            predicateEvaluations: 0,
            rootIsolationAdvances: 0,
            featureTransitions: 0,
          ),
        );
    }
  }

  void _startFallback() {
    exactFallbackClassifications = math.max(exactFallbackClassifications, 1);
    _fallback ??= _SubdivisionErasureClassifier(
      section: section,
      path: pagePath,
      radius: radius,
      maximumChecks: maximumChecks - totalPredicates,
    );
    _phase = _AnalyticPhase.fallback;
  }

  void _addFeatureEvents(int index) {
    final start = section.startPolygon[index];
    final end = section.endPolygon[index];
    final velocityX = end.x - start.x;
    final velocityY = end.y - start.y;
    for (final point in pagePath) {
      final offsetX = start.x - point.x;
      final offsetY = start.y - point.y;
      _addQuadraticRoots(
        velocityX * velocityX + velocityY * velocityY,
        2 * (offsetX * velocityX + offsetY * velocityY),
        offsetX * offsetX + offsetY * offsetY - radius * radius,
      );
    }
    if (pagePath.length == 2) {
      final first = pagePath.first;
      final second = pagePath.last;
      final dx = second.x - first.x;
      final dy = second.y - first.y;
      final length = math.sqrt(dx * dx + dy * dy);
      if (length.isFinite && length > 0) {
        final initial = (start.x - first.x) * dy - (start.y - first.y) * dx;
        final change = velocityX * dy - velocityY * dx;
        for (final signedRadius in [radius * length, -radius * length]) {
          if (change != 0 && change.isFinite) {
            final t = (signedRadius - initial) / change;
            final vertex = t >= 0 && t <= 1
                ? section.vertexAtDouble(index, t)
                : null;
            if (vertex != null) {
              final projection =
                  ((vertex.x - first.x) * dx + (vertex.y - first.y) * dy) /
                  (length * length);
              if (projection >= 0 && projection <= 1) _addEvent(t);
            }
          }
        }
      }
    }
    final next = (index + 1) % section.startPolygon.length;
    final edgeStart = section.startPolygon[next];
    final edgeX = edgeStart.x - start.x;
    final edgeY = edgeStart.y - start.y;
    final edgeLength = math.sqrt(edgeX * edgeX + edgeY * edgeY);
    if (edgeLength.isFinite && edgeLength > 0) {
      final normalX = -edgeY / edgeLength;
      final normalY = edgeX / edgeLength;
      final tangentX = edgeX / edgeLength;
      final tangentY = edgeY / edgeLength;
      for (final point in pagePath) {
        final initial =
            (point.x - start.x) * normalX + (point.y - start.y) * normalY;
        final change = -(velocityX * normalX + velocityY * normalY);
        for (final signedRadius in [radius, -radius]) {
          if (change == 0 || !change.isFinite) continue;
          final t = (signedRadius - initial) / change;
          if (t < 0 || t > 1) continue;
          final firstVertex = section.vertexAtDouble(index, t);
          final secondVertex = section.vertexAtDouble(next, t);
          if (firstVertex == null || secondVertex == null) continue;
          final projection =
              (point.x - firstVertex.x) * tangentX +
              (point.y - firstVertex.y) * tangentY;
          final lengthAt =
              (secondVertex.x - firstVertex.x) * tangentX +
              (secondVertex.y - firstVertex.y) * tangentY;
          if (projection >= 0 && projection <= lengthAt) _addEvent(t);
        }
      }
    }
  }

  void _addQuadraticRoots(double a, double b, double c) {
    if (![a, b, c].every((value) => value.isFinite)) return;
    if (a == 0) {
      if (b != 0) _addEvent(-c / b);
      return;
    }
    final discriminant = b * b - 4 * a * c;
    if (!discriminant.isFinite || discriminant < 0) return;
    final root = math.sqrt(discriminant);
    final q = -.5 * (b + (b < 0 ? -root : root));
    if (q == 0) {
      _addEvent(-b / (2 * a));
    } else {
      _addEvent(q / a);
      _addEvent(c / q);
    }
  }

  void _addEvent(double value) {
    if (value.isFinite && value >= 0 && value <= 1) _events.add(value);
  }

  void _prepareProbes() {
    _events.sort();
    final unique = <double>[];
    for (final value in _events) {
      if (unique.isEmpty || value != unique.last) unique.add(value);
    }
    final probes = <double>{0, 1};
    if (unique.isEmpty) {
      probes.add(.5);
    } else if (unique.length == 1) {
      probes.add(unique.single);
    } else {
      final span = unique.last - unique.first;
      final inset = math.max(span * 1e-10, double.minPositive);
      probes
        ..add(math.min(unique.last, unique.first + inset))
        ..add(math.max(unique.first, unique.last - inset));
      final middle = _representableMidpoint(unique.first, unique.last);
      if (middle != null) probes.add(middle);
    }
    _probes = probes.toList()..sort();
  }

  (_FloatingRelation, double) _floatingDistanceAt(double parameter) {
    final polygon = section.polygonAtDouble(parameter);
    if (polygon == null) return (_FloatingRelation.ambiguous, double.nan);
    final distance = _polygonPathDistance(polygon, pagePath);
    final scale = <double>[
      radius.abs(),
      distance.abs(),
      ...polygon.expand((point) => [point.x.abs(), point.y.abs()]),
      ...pagePath.expand((point) => [point.x.abs(), point.y.abs()]),
    ].reduce(math.max);
    final error = scale * 2.842170943040401e-14;
    if (!distance.isFinite || !error.isFinite) {
      return (_FloatingRelation.ambiguous, distance);
    }
    if (distance + error < radius) return (_FloatingRelation.hit, distance);
    if (distance - error > radius) return (_FloatingRelation.miss, distance);
    return (_FloatingRelation.ambiguous, distance);
  }

  _FloatingRelation _floatingRelation(List<Point2> polygon) {
    final distance = _polygonPathDistance(polygon, pagePath);
    final scale = <double>[
      radius.abs(),
      distance.abs(),
      ...polygon.expand((point) => [point.x.abs(), point.y.abs()]),
      ...pagePath.expand((point) => [point.x.abs(), point.y.abs()]),
    ].reduce(math.max);
    final error = scale * 2.842170943040401e-14;
    if (distance.isFinite && error.isFinite) {
      if (distance + error < radius) return _FloatingRelation.hit;
      if (distance - error > radius) return _FloatingRelation.miss;
    }
    return _FloatingRelation.ambiguous;
  }

  (bool, bool) _certifiedHitAt(double parameter) {
    final floating = _floatingDistanceAt(parameter).$1;
    if (floating != _FloatingRelation.ambiguous) {
      return (floating == _FloatingRelation.hit, false);
    }
    final exact = _shapeWithinRadius(
      section.polygonAt(_Dyadic.fromDouble(parameter)),
      pagePath.map(_ExactPoint.fromPoint).toList(growable: false),
      _Dyadic.fromDouble(radius) * _Dyadic.fromDouble(radius),
    );
    return (exact, true);
  }

  double? _analyticBracketAdvance(double miss, double hit) {
    if (_representableMidpoint(math.min(miss, hit), math.max(miss, hit)) ==
        null) {
      return null;
    }
    final missGap = _floatingDistanceAt(miss).$2 - radius;
    final hitGap = _floatingDistanceAt(hit).$2 - radius;
    if (missGap.isFinite &&
        hitGap.isFinite &&
        missGap > 0 &&
        hitGap <= 0 &&
        missGap != hitGap) {
      final candidate = miss + (hit - miss) * missGap / (missGap - hitGap);
      final low = math.min(miss, hit);
      final high = math.max(miss, hit);
      if (candidate.isFinite && candidate > low && candidate < high) {
        return candidate;
      }
      final adjacent = miss < hit
          ? _previousDouble(hit)
          : _nextPositiveDouble(hit);
      if (adjacent > low && adjacent < high) return adjacent;
    }
    return _representableMidpoint(math.min(miss, hit), math.max(miss, hit));
  }

  void _complete(List<StrokeErasureInterval> intervals) {
    _result = List.unmodifiable(intervals);
    _phase = _AnalyticPhase.completed;
  }
}

enum _FloatingRelation { hit, miss, ambiguous }

final class _SubdivisionErasureClassifier {
  _SubdivisionErasureClassifier({
    required this.section,
    required List<Point2> path,
    required double radius,
    required this.maximumChecks,
  }) : pagePath = List.unmodifiable(path),
       exactPath = List.unmodifiable(path.map(_ExactPoint.fromPoint)),
       radius = radius,
       radiusSquared = _Dyadic.fromDouble(radius) * _Dyadic.fromDouble(radius);

  final _PreparedErasureSegment section;
  final List<Point2> pagePath;
  final List<_ExactPoint> exactPath;
  final double radius;
  final _Dyadic radiusSquared;
  final int maximumChecks;
  int totalPredicates = 0;
  int maximumDepth = 0;
  int maximumPending = 1;
  _ClassifierPhase _phase = _ClassifierPhase.endpointZero;
  bool _zeroHit = false;
  bool _oneHit = false;
  double? _witness;
  final List<_ParameterInterval> _pending = [];
  _ParameterInterval? _active;
  double? _middle;
  bool _leftPossible = false;
  double _leftMiss = 0;
  double _leftHit = 0;
  double _rightHit = 0;
  double _rightMiss = 1;
  double? _leftResult;
  double? _rightResult;
  List<StrokeErasureInterval>? _result;

  int get pendingCount => _pending.length + (_active == null ? 0 : 1);

  Result<_ResumableAdvance, StructuredFailure> advance({
    required int maximumPredicateEvaluations,
    required int maximumRootIsolationAdvances,
    required int maximumFeatureTransitions,
  }) {
    if (maximumPredicateEvaluations <= 0 ||
        maximumRootIsolationAdvances <= 0 ||
        maximumFeatureTransitions < section.unitPolygon.length) {
      return Err(_failure('invalid_erasure_work_limit'));
    }
    var predicates = 0;
    var roots = 0;
    var features = 0;
    while (_phase != _ClassifierPhase.completed) {
      final envelope =
          _phase == _ClassifierPhase.rootEnvelope ||
          _phase == _ClassifierPhase.searchLeftEnvelope ||
          _phase == _ClassifierPhase.searchRightEnvelope;
      final featureCost = section.unitPolygon.length * (envelope ? 2 : 1);
      final rootCost = switch (_phase) {
        _ClassifierPhase.searchMidpoint ||
        _ClassifierPhase.leftBoundary ||
        _ClassifierPhase.rightBoundary => 1,
        _ => 0,
      };
      if (predicates >= maximumPredicateEvaluations ||
          roots + rootCost > maximumRootIsolationAdvances ||
          features + featureCost > maximumFeatureTransitions) {
        break;
      }
      if (totalPredicates >= maximumChecks) {
        return Err(_failure('erasure_classification_limit'));
      }
      final step = _step();
      if (step is Err<void, StructuredFailure>) return Err(step.error);
      predicates += 1;
      roots += rootCost;
      features += featureCost;
      totalPredicates += 1;
    }
    return Ok(
      _ResumableAdvance(
        intervals: _result,
        predicateEvaluations: predicates,
        rootIsolationAdvances: roots,
        featureTransitions: features,
      ),
    );
  }

  Result<void, StructuredFailure> _step() {
    switch (_phase) {
      case _ClassifierPhase.endpointZero:
        _zeroHit = _hitAt(0);
        _phase = _ClassifierPhase.endpointOne;
        return const Ok(null);
      case _ClassifierPhase.endpointOne:
        _oneHit = _hitAt(1);
        if (section.isDot) {
          _complete(
            _zeroHit ? const [StrokeErasureInterval._(0, 1)] : const [],
          );
        } else if (_zeroHit || _oneHit) {
          _witness = _zeroHit ? 0 : 1;
          _startBoundaries();
        } else {
          _phase = _ClassifierPhase.rootEnvelope;
        }
        return const Ok(null);
      case _ClassifierPhase.rootEnvelope:
        if (!_envelopeMayHit(0, 1)) {
          _complete(const []);
        } else {
          _pending.add(const _ParameterInterval(0, 1, 0));
          maximumPending = math.max(maximumPending, _pending.length);
          _phase = _ClassifierPhase.searchMidpoint;
        }
        return const Ok(null);
      case _ClassifierPhase.searchMidpoint:
        if (_active == null) {
          if (_pending.isEmpty) {
            return Err(_failure('erasure_classification_uncertain'));
          }
          _active = _pending.removeLast();
          maximumDepth = math.max(maximumDepth, _active!.depth);
          _middle = _representableMidpoint(_active!.low, _active!.high);
          if (_middle == null) {
            return Err(_failure('erasure_classification_uncertain'));
          }
        }
        if (_hitAt(_middle!)) {
          _witness = _middle;
          _startBoundaries();
        } else {
          _phase = _ClassifierPhase.searchLeftEnvelope;
        }
        return const Ok(null);
      case _ClassifierPhase.searchLeftEnvelope:
        _leftPossible = _envelopeMayHit(_active!.low, _middle!);
        _phase = _ClassifierPhase.searchRightEnvelope;
        return const Ok(null);
      case _ClassifierPhase.searchRightEnvelope:
        final rightPossible = _envelopeMayHit(_middle!, _active!.high);
        final depth = _active!.depth + 1;
        if (rightPossible) {
          _pending.add(_ParameterInterval(_middle!, _active!.high, depth));
        }
        if (_leftPossible) {
          _pending.add(_ParameterInterval(_active!.low, _middle!, depth));
        }
        maximumPending = math.max(maximumPending, _pending.length);
        _active = null;
        _middle = null;
        _phase = _ClassifierPhase.searchMidpoint;
        return const Ok(null);
      case _ClassifierPhase.leftBoundary:
        final middle = _representableMidpoint(_leftMiss, _leftHit);
        if (middle == null) {
          _leftResult = _leftHit;
          _phase = _ClassifierPhase.rightBoundary;
        } else {
          maximumDepth += 1;
          if (_hitAt(middle)) {
            _leftHit = middle;
          } else {
            _leftMiss = middle;
          }
        }
        return const Ok(null);
      case _ClassifierPhase.rightBoundary:
        final middle = _representableMidpoint(_rightHit, _rightMiss);
        if (middle == null) {
          _rightResult = _rightHit;
          _complete([StrokeErasureInterval._(_leftResult ?? 0, _rightResult!)]);
        } else {
          maximumDepth += 1;
          if (_hitAt(middle)) {
            _rightHit = middle;
          } else {
            _rightMiss = middle;
          }
        }
        return const Ok(null);
      case _ClassifierPhase.completed:
        return const Ok(null);
    }
  }

  void _startBoundaries() {
    _leftMiss = 0;
    _leftHit = _witness!;
    _rightHit = _witness!;
    _rightMiss = 1;
    if (_zeroHit) _leftResult = 0;
    if (_oneHit) _rightResult = 1;
    _phase = _leftResult == null
        ? _ClassifierPhase.leftBoundary
        : _ClassifierPhase.rightBoundary;
    if (_rightResult != null && _leftResult != null) {
      _complete([StrokeErasureInterval._(_leftResult!, _rightResult!)]);
    }
  }

  void _complete(List<StrokeErasureInterval> value) {
    _result = List.unmodifiable(value);
    _phase = _ClassifierPhase.completed;
  }

  bool _hitAt(double parameter) =>
      _boundedRelation(
        section.polygonAtDouble(parameter),
        () => section.polygonAt(_Dyadic.fromDouble(parameter)),
      ) ==
      _PredicateRelation.hit;

  bool _envelopeMayHit(double low, double high) =>
      _boundedRelation(
        _convexHull([
          ...?section.polygonAtDouble(low),
          ...?section.polygonAtDouble(high),
        ]),
        () => _exactConvexHull([
          ...section.polygonAt(_Dyadic.fromDouble(low)),
          ...section.polygonAt(_Dyadic.fromDouble(high)),
        ]),
      ) ==
      _PredicateRelation.hit;

  _PredicateRelation _boundedRelation(
    List<Point2>? polygon,
    List<_ExactPoint> Function() exactPolygon,
  ) {
    if (polygon != null && polygon.length >= 3 && radius > 0) {
      final distance = _polygonPathDistance(polygon, pagePath);
      final scale = <double>[
        radius.abs(),
        distance.abs(),
        ...polygon.expand((point) => [point.x.abs(), point.y.abs()]),
        ...pagePath.expand((point) => [point.x.abs(), point.y.abs()]),
      ].reduce(math.max);
      final error = scale * 2.842170943040401e-14;
      if (distance.isFinite && error.isFinite) {
        if (distance + error < radius) return _PredicateRelation.hit;
        if (distance - error > radius) return _PredicateRelation.miss;
      }
    }
    return _shapeWithinRadius(exactPolygon(), exactPath, radiusSquared)
        ? _PredicateRelation.hit
        : _PredicateRelation.miss;
  }
}

final class _ParameterInterval {
  const _ParameterInterval(this.low, this.high, this.depth);

  final double low;
  final double high;
  final int depth;
}

List<Point2> _convexHull(List<Point2> source) {
  if (source.length <= 1) return List.unmodifiable(source);
  final points = List<Point2>.of(source)
    ..sort((first, second) {
      final x = first.x.compareTo(second.x);
      return x == 0 ? first.y.compareTo(second.y) : x;
    });
  final lower = <Point2>[];
  for (final point in points) {
    while (lower.length >= 2 &&
        _orientationSign(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }
  final upper = <Point2>[];
  for (final point in points.reversed) {
    while (upper.length >= 2 &&
        _orientationSign(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }
  lower.removeLast();
  upper.removeLast();
  return List.unmodifiable([...lower, ...upper]);
}

double _polygonPathDistance(List<Point2> polygon, List<Point2> path) {
  var best = double.infinity;
  for (final point in path) {
    if (_pointInConvex(point, polygon)) return 0;
    best = math.min(best, _distanceToPolygon(point, polygon));
  }
  for (var pathIndex = 1; pathIndex < path.length; pathIndex += 1) {
    final first = path[pathIndex - 1];
    final second = path[pathIndex];
    for (var edge = 0; edge < polygon.length; edge += 1) {
      final distance = _segmentToSegmentDistance(
        first,
        second,
        polygon[edge],
        polygon[(edge + 1) % polygon.length],
      );
      if (distance == 0) return 0;
      best = math.min(best, distance);
    }
  }
  return best;
}

double? _representableMidpoint(double low, double high) {
  final next = _nextPositiveDouble(low);
  if (next >= high) return null;
  final middle = low + (high - low) / 2;
  if (middle > low && middle < high) return middle;
  return next < high ? next : null;
}

double _nextPositiveDouble(double value) {
  if (value == 0) return double.minPositive;
  final bytes = ByteData(8)..setFloat64(0, value);
  var high = bytes.getUint32(0);
  var low = bytes.getUint32(4);
  if (low == 0xffffffff) {
    low = 0;
    high += 1;
  } else {
    low += 1;
  }
  bytes
    ..setUint32(0, high)
    ..setUint32(4, low);
  return bytes.getFloat64(0);
}

double _previousDouble(double value) {
  if (value <= 0) return -double.minPositive;
  final bytes = ByteData(8)..setFloat64(0, value);
  var high = bytes.getUint32(0);
  var low = bytes.getUint32(4);
  if (low == 0) {
    low = 0xffffffff;
    high -= 1;
  } else {
    low -= 1;
  }
  bytes
    ..setUint32(0, high)
    ..setUint32(4, low);
  return bytes.getFloat64(0);
}

final class _ExactPoint {
  const _ExactPoint(this.x, this.y);

  factory _ExactPoint.fromPoint(Point2 value) =>
      _ExactPoint(_Dyadic.fromDouble(value.x), _Dyadic.fromDouble(value.y));

  factory _ExactPoint.lerp(_ExactPoint first, _ExactPoint second, _Dyadic t) =>
      _ExactPoint(
        first.x + (second.x - first.x) * t,
        first.y + (second.y - first.y) * t,
      );

  final _Dyadic x;
  final _Dyadic y;

  _ExactPoint operator -(_ExactPoint other) =>
      _ExactPoint(x - other.x, y - other.y);
}

final class _Dyadic implements Comparable<_Dyadic> {
  const _Dyadic(this.coefficient, this.exponent);

  factory _Dyadic.fromDouble(double value) {
    if (!value.isFinite) throw const _GeometryBuildException();
    if (value == 0) return _zero;
    final bytes = ByteData(8)..setFloat64(0, value);
    final high = bytes.getUint32(0);
    final low = bytes.getUint32(4);
    final negative = high & 0x80000000 != 0;
    final encodedExponent = (high >>> 20) & 0x7ff;
    final fraction = (BigInt.from(high & 0xfffff) << 32) | BigInt.from(low);
    final coefficient = encodedExponent == 0
        ? fraction
        : (BigInt.one << 52) | fraction;
    return _Dyadic(
      negative ? -coefficient : coefficient,
      encodedExponent == 0 ? -1074 : encodedExponent - 1075,
    );
  }

  static final _Dyadic _zero = _Dyadic(BigInt.zero, 0);
  final BigInt coefficient;
  final int exponent;

  _Dyadic operator +(_Dyadic other) {
    if (coefficient == BigInt.zero) return other;
    if (other.coefficient == BigInt.zero) return this;
    final common = math.min(exponent, other.exponent);
    return _Dyadic(
      (coefficient << (exponent - common)) +
          (other.coefficient << (other.exponent - common)),
      common,
    );
  }

  _Dyadic operator -(_Dyadic other) =>
      this + _Dyadic(-other.coefficient, other.exponent);

  _Dyadic operator *(_Dyadic other) =>
      _Dyadic(coefficient * other.coefficient, exponent + other.exponent);

  @override
  int compareTo(_Dyadic other) {
    if (coefficient == BigInt.zero && other.coefficient == BigInt.zero) {
      return 0;
    }
    final common = math.min(exponent, other.exponent);
    return (coefficient << (exponent - common))
        .compareTo(other.coefficient << (other.exponent - common))
        .sign;
  }
}

_Dyadic _exactDot(_ExactPoint first, _ExactPoint second) =>
    first.x * second.x + first.y * second.y;

_Dyadic _exactCross(_ExactPoint first, _ExactPoint second) =>
    first.x * second.y - first.y * second.x;

int _exactOrientation(_ExactPoint a, _ExactPoint b, _ExactPoint c) =>
    _exactCross(b - a, c - a).compareTo(_Dyadic._zero);

bool _exactOnSegment(_ExactPoint a, _ExactPoint point, _ExactPoint b) =>
    point.x.compareTo(a.x.compareTo(b.x) <= 0 ? a.x : b.x) >= 0 &&
    point.x.compareTo(a.x.compareTo(b.x) >= 0 ? a.x : b.x) <= 0 &&
    point.y.compareTo(a.y.compareTo(b.y) <= 0 ? a.y : b.y) >= 0 &&
    point.y.compareTo(a.y.compareTo(b.y) >= 0 ? a.y : b.y) <= 0;

bool _exactSegmentsIntersect(
  _ExactPoint a,
  _ExactPoint b,
  _ExactPoint c,
  _ExactPoint d,
) {
  final first = _exactOrientation(a, b, c);
  final second = _exactOrientation(a, b, d);
  final third = _exactOrientation(c, d, a);
  final fourth = _exactOrientation(c, d, b);
  if (first == 0 && _exactOnSegment(a, c, b)) return true;
  if (second == 0 && _exactOnSegment(a, d, b)) return true;
  if (third == 0 && _exactOnSegment(c, a, d)) return true;
  if (fourth == 0 && _exactOnSegment(c, b, d)) return true;
  return first != second && third != fourth;
}

bool _exactPointSegmentWithinRadius(
  _ExactPoint point,
  _ExactPoint first,
  _ExactPoint second,
  _Dyadic radiusSquared,
) {
  final direction = second - first;
  final offset = point - first;
  final lengthSquared = _exactDot(direction, direction);
  if (lengthSquared.compareTo(_Dyadic._zero) == 0) {
    return _exactDot(offset, offset).compareTo(radiusSquared) <= 0;
  }
  final projection = _exactDot(offset, direction);
  if (projection.compareTo(_Dyadic._zero) <= 0) {
    return _exactDot(offset, offset).compareTo(radiusSquared) <= 0;
  }
  if (projection.compareTo(lengthSquared) >= 0) {
    final tail = point - second;
    return _exactDot(tail, tail).compareTo(radiusSquared) <= 0;
  }
  final cross = _exactCross(offset, direction);
  return (cross * cross).compareTo(radiusSquared * lengthSquared) <= 0;
}

bool _exactPointInConvex(_ExactPoint point, List<_ExactPoint> polygon) {
  int? sign;
  for (var index = 0; index < polygon.length; index += 1) {
    final value = _exactOrientation(
      polygon[index],
      polygon[(index + 1) % polygon.length],
      point,
    );
    if (value == 0) continue;
    sign ??= value;
    if (sign != value) return false;
  }
  return true;
}

bool _exactHasArea(List<_ExactPoint> polygon) {
  if (polygon.length < 3) return false;
  final first = polygon.first;
  for (var index = 1; index + 1 < polygon.length; index += 1) {
    if (_exactOrientation(first, polygon[index], polygon[index + 1]) != 0) {
      return true;
    }
  }
  return false;
}

bool _shapeWithinRadius(
  List<_ExactPoint> polygon,
  List<_ExactPoint> path,
  _Dyadic radiusSquared,
) {
  if (polygon.isEmpty || path.isEmpty) throw const _GeometryBuildException();
  if (_exactHasArea(polygon) &&
      path.any((point) => _exactPointInConvex(point, polygon))) {
    return true;
  }
  for (var edge = 0; edge < polygon.length; edge += 1) {
    final first = polygon[edge];
    final second = polygon[(edge + 1) % polygon.length];
    for (final point in path) {
      if (_exactPointSegmentWithinRadius(point, first, second, radiusSquared)) {
        return true;
      }
    }
    if (path.length == 2) {
      if (_exactSegmentsIntersect(first, second, path.first, path.last) ||
          _exactPointSegmentWithinRadius(
            first,
            path.first,
            path.last,
            radiusSquared,
          ) ||
          _exactPointSegmentWithinRadius(
            second,
            path.first,
            path.last,
            radiusSquared,
          )) {
        return true;
      }
    }
  }
  return false;
}

List<_ExactPoint> _exactConvexHull(List<_ExactPoint> values) {
  final points = List<_ExactPoint>.of(values)
    ..sort((first, second) {
      final x = first.x.compareTo(second.x);
      return x != 0 ? x : first.y.compareTo(second.y);
    });
  final unique = <_ExactPoint>[];
  for (final point in points) {
    if (unique.isEmpty ||
        point.x.compareTo(unique.last.x) != 0 ||
        point.y.compareTo(unique.last.y) != 0) {
      unique.add(point);
    }
  }
  if (unique.length <= 2) return List.unmodifiable(unique);
  final lower = <_ExactPoint>[];
  for (final point in unique) {
    while (lower.length >= 2 &&
        _exactOrientation(lower[lower.length - 2], lower.last, point) <= 0) {
      lower.removeLast();
    }
    lower.add(point);
  }
  final upper = <_ExactPoint>[];
  for (final point in unique.reversed) {
    while (upper.length >= 2 &&
        _exactOrientation(upper[upper.length - 2], upper.last, point) <= 0) {
      upper.removeLast();
    }
    upper.add(point);
  }
  return List.unmodifiable([...lower..removeLast(), ...upper..removeLast()]);
}

final class _GeometryBuildException implements Exception {
  const _GeometryBuildException();
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.geometry.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Stroke geometry is invalid or unavailable.',
);
