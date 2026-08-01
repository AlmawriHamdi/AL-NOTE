// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
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

/// Immutable shared Page-space visible geometry for one transformed stroke.
final class TransformedStrokeGeometry {
  TransformedStrokeGeometry._(
    List<StrokeGeometryElement> elements,
    this.bounds,
    this.maximumContainmentChecks,
  ) : elements = List<StrokeGeometryElement>.unmodifiable(elements);

  /// Convex elements whose union is the visible transformed raw stroke.
  final List<StrokeGeometryElement> elements;

  /// Bounds of the complete visible geometry.
  final Rect2 bounds;

  final int maximumContainmentChecks;

  /// Whether a Page-space point lies within geometry plus [tolerance].
  bool hitsPoint(Point2 point, double tolerance) {
    if (!tolerance.isFinite || tolerance < 0) return false;
    final expanded = _expanded(bounds, tolerance);
    // If finite inputs overflow during the conservative bounds expansion, do
    // not use the original bounds as a rejecting prefilter.
    if (expanded != null && !expanded.contains(point)) return false;
    for (final element in elements) {
      if (_pointInConvex(point, element.vertices) ||
          _distanceToPolygon(point, element.vertices) <= tolerance) {
        return true;
      }
    }
    return false;
  }

  /// Whether any visible geometry intersects [rectangle].
  bool intersectsRectangle(Rect2 rectangle) => elements.any(
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
    if (path.isEmpty || !radius.isFinite || radius < 0) return false;
    for (final element in elements) {
      if (path.any(
        (point) =>
            _pointInPolygon(point, element.vertices) ||
            _distanceToPolygon(point, element.vertices) <= radius,
      ))
        return true;
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
    }
    return false;
  }
}

/// Builds the common transform-correct visible geometry used by every subsystem.
final class StrokeGeometryResolver {
  /// Creates a resolver with explicit geometry ceilings.
  const StrokeGeometryResolver(this.limits);

  /// Geometry construction ceilings.
  final StrokeGeometryLimits limits;

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
    var verticesUsed = 0;

    Result<void, StructuredFailure> addLocalPolygon(List<Point2> local) {
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
      return const Ok(null);
    }

    for (final sample in samples) {
      final circle = _circle(
        sample.position,
        style.widthFor(sample.pressure) / 2,
        limits.ellipseVertexCount,
      );
      final added = addLocalPolygon(circle);
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
      final added = addLocalPolygon(polygon);
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
        bounds,
        limits.maximumContainmentChecks,
      ),
    );
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
