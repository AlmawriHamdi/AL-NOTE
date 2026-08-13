// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../geometry.dart';
import 'hit_testing.dart';

/// Bounds-based built-in Image hit testing.
final class ImageHitTestingDefinition extends _BoundsHitTestingDefinition {
  /// Creates a definition with explicit Image limits.
  const ImageHitTestingDefinition(this.imageLimits);

  /// Image payload limits.
  final ImageLimits imageLimits;
  @override
  ObjectTypeKey get typeKey => imageObjectTypeKey;
  @override
  Rect2? localBounds(ObjectEnvelope object) =>
      object.typeKey == imageObjectTypeKey &&
          object.typeSchemaVersion == imageSchemaVersion
      ? ImagePayload.decode(
          object.payload,
          limits: imageLimits,
        ).fold<Rect2?>(onOk: (value) => value.bounds, onErr: (_) => null)
      : null;
}

/// Bounds-based built-in Text hit testing.
final class TextHitTestingDefinition extends _BoundsHitTestingDefinition {
  /// Creates a definition with explicit Text limits.
  const TextHitTestingDefinition(this.textLimits);

  /// Text payload limits.
  final TextLimits textLimits;
  @override
  ObjectTypeKey get typeKey => textObjectTypeKey;
  @override
  Rect2? localBounds(ObjectEnvelope object) =>
      object.typeKey == textObjectTypeKey &&
          object.typeSchemaVersion == textSchemaVersion
      ? TextPayload.decode(
          object.payload,
          limits: textLimits,
        ).fold<Rect2?>(onOk: (value) => value.bounds, onErr: (_) => null)
      : null;
}

abstract base class _BoundsHitTestingDefinition
    implements ObjectHitTestingDefinition, ObjectWholeHitTestingDefinition {
  const _BoundsHitTestingDefinition();
  Rect2? localBounds(ObjectEnvelope object);
  @override
  ObjectTypeKey get typeKey;
  @override
  Result<StrokeId?, StructuredFailure> point({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) => const Ok(null);
  @override
  Result<List<StrokeId>, StructuredFailure> rectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) => const Ok([]);
  @override
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) => const Ok([]);
  @override
  Result<bool, StructuredFailure> wholePoint({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) {
    if (!pageTolerance.isFinite || pageTolerance < 0)
      return Err(_failure('invalid_tolerance'));
    final polygon = _pagePolygon(object);
    if (polygon == null) return Err(_failure('invalid_object'));
    return Ok(
      _inside(pagePosition, polygon) ||
          _distanceToPolygon(pagePosition, polygon) <= pageTolerance,
    );
  }

  @override
  Result<bool, StructuredFailure> wholeRectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) {
    final polygon = _pagePolygon(object);
    if (polygon == null) return Err(_failure('invalid_object'));
    final areaPolygon = <Point2>[
      area.topLeft,
      _point(area.right, area.top),
      area.bottomRight,
      _point(area.left, area.bottom),
    ];
    return Ok(
      mode == AreaHitMode.containment
          ? polygon.every(area.contains)
          : _polygonsIntersect(polygon, areaPolygon),
    );
  }

  @override
  Result<bool, StructuredFailure> wholeLasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) {
    final objectPolygon = _pagePolygon(object);
    if (objectPolygon == null) return Err(_failure('invalid_object'));
    final bounds = _bounds(objectPolygon);
    if (!_intersects(bounds, polygon.bounds)) return const Ok(false);
    return Ok(
      mode == AreaHitMode.containment
          ? objectPolygon.every((point) => _inside(point, polygon.points))
          : _polygonsIntersect(objectPolygon, polygon.points),
    );
  }

  @override
  Result<bool, StructuredFailure> wholeSweptSegment({
    required ObjectEnvelope object,
    required Point2 start,
    required Point2 end,
    required double radius,
  }) {
    if (!radius.isFinite || radius < 0) {
      return Err(_failure('invalid_tolerance'));
    }
    final polygon = _pagePolygon(object);
    if (polygon == null) return Err(_failure('invalid_object'));
    if (_inside(start, polygon) || _inside(end, polygon)) return const Ok(true);
    for (var index = 0; index < polygon.length; index++) {
      if (_distanceBetweenSegments(
            start,
            end,
            polygon[index],
            polygon[(index + 1) % polygon.length],
          ) <=
          radius) {
        return const Ok(true);
      }
    }
    return const Ok(false);
  }

  List<Point2>? _pagePolygon(ObjectEnvelope object) {
    final bounds = localBounds(object);
    if (bounds == null) return null;
    final local = <Point2>[
      bounds.topLeft,
      _point(bounds.right, bounds.top),
      bounds.bottomRight,
      _point(bounds.left, bounds.bottom),
    ];
    final page = <Point2>[];
    for (final point in local) {
      final transformed = object.transform.applyToPoint(point);
      if (transformed is! Ok<Point2, StructuredFailure>) return null;
      page.add(transformed.value);
    }
    return List<Point2>.unmodifiable(page);
  }
}

bool _intersects(Rect2 a, Rect2 b) =>
    a.left <= b.right &&
    a.right >= b.left &&
    a.top <= b.bottom &&
    a.bottom >= b.top;
bool _inside(Point2 point, List<Point2> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i], b = polygon[j];
    if ((a.y > point.y) != (b.y > point.y) &&
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x)
      inside = !inside;
  }
  return inside;
}

bool _polygonsIntersect(List<Point2> first, List<Point2> second) {
  if (first.any((point) => _inside(point, second)) ||
      second.any((point) => _inside(point, first))) {
    return true;
  }
  for (var firstIndex = 0; firstIndex < first.length; firstIndex++) {
    final firstStart = first[firstIndex];
    final firstEnd = first[(firstIndex + 1) % first.length];
    for (var secondIndex = 0; secondIndex < second.length; secondIndex++) {
      if (_segmentsIntersect(
        firstStart,
        firstEnd,
        second[secondIndex],
        second[(secondIndex + 1) % second.length],
      )) {
        return true;
      }
    }
  }
  return false;
}

bool _segmentsIntersect(Point2 a, Point2 b, Point2 c, Point2 d) {
  final abC = _cross(a, b, c);
  final abD = _cross(a, b, d);
  final cdA = _cross(c, d, a);
  final cdB = _cross(c, d, b);
  if (abC == 0 && _onSegment(a, b, c) ||
      abD == 0 && _onSegment(a, b, d) ||
      cdA == 0 && _onSegment(c, d, a) ||
      cdB == 0 && _onSegment(c, d, b)) {
    return true;
  }
  return (abC > 0) != (abD > 0) && (cdA > 0) != (cdB > 0);
}

double _cross(Point2 a, Point2 b, Point2 c) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
bool _onSegment(Point2 a, Point2 b, Point2 p) =>
    p.x >= math.min(a.x, b.x) &&
    p.x <= math.max(a.x, b.x) &&
    p.y >= math.min(a.y, b.y) &&
    p.y <= math.max(a.y, b.y);
double _distanceToPolygon(Point2 point, List<Point2> polygon) {
  var minimum = double.infinity;
  for (var index = 0; index < polygon.length; index++) {
    minimum = math.min(
      minimum,
      _distanceToSegment(
        point,
        polygon[index],
        polygon[(index + 1) % polygon.length],
      ),
    );
  }
  return minimum;
}

double _distanceToSegment(Point2 point, Point2 start, Point2 end) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final squared = dx * dx + dy * dy;
  if (squared == 0) return math.sqrt(_squaredDistance(point, start));
  final projection =
      ((point.x - start.x) * dx + (point.y - start.y) * dy) / squared;
  final t = projection.clamp(0.0, 1.0);
  return math.sqrt(
    _squaredDistance(point, _point(start.x + t * dx, start.y + t * dy)),
  );
}

double _distanceBetweenSegments(Point2 a, Point2 b, Point2 c, Point2 d) {
  if (_segmentsIntersect(a, b, c, d)) return 0;
  return math.min(
    math.min(_distanceToSegment(a, c, d), _distanceToSegment(b, c, d)),
    math.min(_distanceToSegment(c, a, b), _distanceToSegment(d, a, b)),
  );
}

double _squaredDistance(Point2 first, Point2 second) {
  final dx = first.x - second.x;
  final dy = first.y - second.y;
  return dx * dx + dy * dy;
}

Rect2 _bounds(List<Point2> polygon) {
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
  return (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
          as Ok<Rect2, StructuredFailure>)
      .value;
}

Point2 _point(double x, double y) =>
    (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;
StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.bounds_hit_testing.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Object hit testing is invalid or unavailable.',
);
