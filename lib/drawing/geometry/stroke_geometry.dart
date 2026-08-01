// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';
import 'dart:math' as math;

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
  bool intersectsPolygon(List<Point2> polygon) =>
      elements.any((element) => _polygonsIntersect(element.vertices, polygon));

  /// Whether all visible geometry is contained by a validated simple polygon.
  Result<bool, StructuredFailure> containedByPolygon(List<Point2> polygon) {
    var checks = 0;
    bool consume() => ++checks <= maximumContainmentChecks;
    for (final element in elements) {
      for (final point in element.vertices) {
        if (!consume()) return Err(_failure('containment_limit'));
        if (!_pointInPolygon(point, polygon)) return const Ok(false);
      }
      for (var edge = 0; edge < element.vertices.length; edge += 1) {
        final first = element.vertices[edge];
        final second = element.vertices[(edge + 1) % element.vertices.length];
        final parameters = <double>[0, 1];
        for (var boundary = 0; boundary < polygon.length; boundary += 1) {
          if (!consume()) return Err(_failure('containment_limit'));
          final value = _segmentIntersectionParameter(
            first,
            second,
            polygon[boundary],
            polygon[(boundary + 1) % polygon.length],
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
          if (!_pointInPolygon(midpoint, polygon)) return const Ok(false);
        }
      }
    }
    return const Ok(true);
  }

  /// Whether visible geometry intersects a Page-space polyline swept by radius.
  bool intersectsSweptPath(List<Point2> path, double radius) {
    return querySweptPath(path, radius).intersects;
  }

  /// Queries the prepared spatial index and reports detailed element work.
  ({bool intersects, int examinedElements}) querySweptPath(
    List<Point2> path,
    double radius,
  ) {
    if (path.isEmpty || !radius.isFinite || radius < 0) {
      return (intersects: false, examinedElements: 0);
    }
    final queryBounds = _pathBounds(path, radius);
    if (queryBounds == null) return (intersects: false, examinedElements: 0);
    var examined = 0;
    final hit = _spatialIndex.any(queryBounds, (element) {
      examined += 1;
      return _elementIntersectsSweptPath(element, path, radius);
    });
    return (intersects: hit, examinedElements: examined);
  }

  /// Returns source-sample segment indices touched by one bounded swept path.
  ({List<int> sourceSegments, int examinedElements})
  querySweptPathSourceSegments(List<Point2> path, double radius) {
    if (path.isEmpty || !radius.isFinite || radius < 0) {
      return (sourceSegments: const [], examinedElements: 0);
    }
    final queryBounds = _pathBounds(path, radius);
    if (queryBounds == null) {
      return (sourceSegments: const [], examinedElements: 0);
    }
    var examined = 0;
    final segments = <int>{};
    _spatialIndex.visitMatches(queryBounds, (element) {
      examined += 1;
      if (_elementIntersectsSweptPath(element, path, radius)) {
        segments.addAll(_elementSourceSegments[element] ?? const {});
      }
    });
    final ordered = segments.toList()..sort();
    return (
      sourceSegments: List<int>.unmodifiable(ordered),
      examinedElements: examined,
    );
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

  /// Geometry construction ceilings.
  final StrokeGeometryLimits limits;

  /// Classifies erased intervals for one source segment and one latest swept
  /// Eraser segment without revisiting earlier gesture segments.
  Result<List<StrokeErasureInterval>, StructuredFailure>
  classifySourceSegmentErasure({
    required StrokeSample first,
    required StrokeSample second,
    required StrokeStyle style,
    required AffineTransform2D localToPage,
    required List<Point2> eraserSegment,
    required double radius,
    required HandwritingLimits handwritingLimits,
  }) {
    if (eraserSegment.isEmpty ||
        eraserSegment.length > 2 ||
        !radius.isFinite ||
        radius < 0) {
      return Err(_failure('invalid_erasure_segment'));
    }
    final pageFirst = localToPage
        .applyToPoint(first.position)
        .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    final pageSecond = localToPage
        .applyToPoint(second.position)
        .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    if (pageFirst == null || pageSecond == null) {
      return Err(_failure('nonrepresentable_geometry'));
    }
    bool erased(double t) {
      final sample = _interpolatedGeometrySample(
        first,
        second,
        t,
        handwritingLimits,
      );
      if (sample == null) throw const _GeometryBuildException();
      final dot = _resolve(
        samples: [sample],
        style: style,
        localToPage: localToPage,
      );
      if (dot is! Ok<TransformedStrokeGeometry, StructuredFailure>) {
        throw const _GeometryBuildException();
      }
      return dot.value.intersectsSweptPath(eraserSegment, radius);
    }

    try {
      if (first == second) {
        return Ok(erased(0) ? const [StrokeErasureInterval._(0, 1)] : const []);
      }
      final candidates = <double>{0, 1};
      if (eraserSegment.length == 1) {
        candidates.add(
          _projectionParameter(
            erasurePoint: eraserSegment.single,
            first: pageFirst,
            second: pageSecond,
          ),
        );
      } else {
        candidates.add(
          _closestParameterOnFirstSegment(
            pageFirst,
            pageSecond,
            eraserSegment.first,
            eraserSegment.last,
          ),
        );
      }
      final ordered = candidates.toList()..sort();
      final probes = <double>{...ordered};
      for (var index = 1; index < ordered.length; index += 1) {
        probes.add((ordered[index - 1] + ordered[index]) / 2);
      }
      final sorted = probes.toList()..sort();
      final marks = sorted.map(erased).toList(growable: false);
      final transitions = <double>[];
      for (var index = 1; index < sorted.length; index += 1) {
        if (marks[index - 1] == marks[index]) continue;
        var low = sorted[index - 1], high = sorted[index];
        final lowMark = marks[index - 1];
        for (var iteration = 0; iteration < 32; iteration += 1) {
          final middle = (low + high) / 2;
          if (erased(middle) == lowMark) {
            low = middle;
          } else {
            high = middle;
          }
        }
        transitions.add((low + high) / 2);
      }
      final cuts = <double>[0, ...transitions, 1];
      final intervals = <StrokeErasureInterval>[];
      for (var part = 1; part < cuts.length; part += 1) {
        final start = cuts[part - 1], end = cuts[part];
        if (erased((start + end) / 2)) {
          intervals.add(StrokeErasureInterval._(start, end));
        }
      }
      return Ok(List.unmodifiable(intervals));
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
    final cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
    if (cross == 0) continue;
    final current = cross.sign;
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
  final dx = second.x - first.x, dy = second.y - first.y;
  final scale = math.max(dx.abs(), dy.abs());
  if (scale == 0) return _hypot(point.x - first.x, point.y - first.y);
  if (!scale.isFinite) {
    return math.min(
      _hypot(point.x - first.x, point.y - first.y),
      _hypot(point.x - second.x, point.y - second.y),
    );
  }
  final normalizedX = dx / scale, normalizedY = dy / scale;
  final squared = normalizedX * normalizedX + normalizedY * normalizedY;
  final projectedX = normalizedX == 0
      ? 0.0
      : (point.x - first.x) / scale * normalizedX;
  final projectedY = normalizedY == 0
      ? 0.0
      : (point.y - first.y) / scale * normalizedY;
  final t = math.max(0.0, math.min(1.0, (projectedX + projectedY) / squared));
  final x = first.x + t * dx, y = first.y + t * dy;
  return _hypot(point.x - x, point.y - y);
}

double _hypot(double x, double y) {
  final scale = math.max(x.abs(), y.abs());
  if (scale == 0 || !scale.isFinite) return scale;
  final a = x / scale, b = y / scale;
  return scale * math.sqrt(a * a + b * b);
}

StrokeSample? _interpolatedGeometrySample(
  StrokeSample first,
  StrokeSample second,
  double t,
  HandwritingLimits limits,
) {
  double? optional(double? a, double? b) =>
      a == null || b == null ? null : a + (b - a) * t;
  final position = Point2.create(
    x: first.position.x + (second.position.x - first.position.x) * t,
    y: first.position.y + (second.position.y - first.position.y) * t,
  );
  if (position is! Ok<Point2, StructuredFailure>) return null;
  return StrokeSample.create(
    position: position.value,
    timeMicros: (first.timeMicros + (second.timeMicros - first.timeMicros) * t)
        .round(),
    limits: limits,
    pressure: optional(first.pressure, second.pressure),
    tilt: optional(first.tilt, second.tilt),
    orientation: optional(first.orientation, second.orientation),
    unknownFields: PreservedMap.empty(),
  ).fold<StrokeSample?>(onOk: (value) => value, onErr: (_) => null);
}

double _projectionParameter({
  required Point2 erasurePoint,
  required Point2 first,
  required Point2 second,
}) {
  final dx = second.x - first.x, dy = second.y - first.y;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return 0;
  return (((erasurePoint.x - first.x) * dx + (erasurePoint.y - first.y) * dy) /
          lengthSquared)
      .clamp(0.0, 1.0);
}

double _closestParameterOnFirstSegment(
  Point2 first,
  Point2 second,
  Point2 pathFirst,
  Point2 pathSecond,
) {
  final ux = second.x - first.x, uy = second.y - first.y;
  final vx = pathSecond.x - pathFirst.x, vy = pathSecond.y - pathFirst.y;
  final wx = first.x - pathFirst.x, wy = first.y - pathFirst.y;
  final a = ux * ux + uy * uy;
  final b = ux * vx + uy * vy;
  final c = vx * vx + vy * vy;
  final d = ux * wx + uy * wy;
  final e = vx * wx + vy * wy;
  if (a == 0) return 0;
  if (c == 0) {
    return _projectionParameter(
      erasurePoint: pathFirst,
      first: first,
      second: second,
    );
  }
  final denominator = a * c - b * b;
  var s = denominator == 0
      ? 0.0
      : ((b * e - c * d) / denominator).clamp(0.0, 1.0);
  var t = ((b * s + e) / c).clamp(0.0, 1.0);
  s = ((b * t - d) / a).clamp(0.0, 1.0);
  t = ((b * s + e) / c).clamp(0.0, 1.0);
  return ((b * t - d) / a).clamp(0.0, 1.0);
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
  double orientation(Point2 p, Point2 q, Point2 r) =>
      (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x);
  bool onSegment(Point2 p, Point2 q, Point2 r) =>
      q.x >= math.min(p.x, r.x) &&
      q.x <= math.max(p.x, r.x) &&
      q.y >= math.min(p.y, r.y) &&
      q.y <= math.max(p.y, r.y);
  final first = orientation(a, b, c), second = orientation(a, b, d);
  final third = orientation(c, d, a), fourth = orientation(c, d, b);
  if (first == 0 && onSegment(a, c, b)) return true;
  if (second == 0 && onSegment(a, d, b)) return true;
  if (third == 0 && onSegment(c, a, d)) return true;
  if (fourth == 0 && onSegment(c, b, d)) return true;
  return first.sign != second.sign && third.sign != fourth.sign;
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

final class _GeometryBuildException implements Exception {
  const _GeometryBuildException();
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.geometry.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Stroke geometry is invalid or unavailable.',
);
