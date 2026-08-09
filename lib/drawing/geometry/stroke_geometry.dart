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

/// An immutable, bounded swept pointer path used by Whole Eraser geometry.
final class SweptPath {
  SweptPath._(List<Point2> points) : points = List.unmodifiable(points);

  /// Largest path ceiling accepted by [create].
  static const int maximumSupportedPoints = 1000000;

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

  /// Geometry construction ceilings.
  final StrokeGeometryLimits limits;

  /// Prepares authoritative transformed cross-sections once for one Stroke.
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

final class _GeometryBuildException implements Exception {
  const _GeometryBuildException();
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.geometry.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Stroke geometry is invalid or unavailable.',
);
