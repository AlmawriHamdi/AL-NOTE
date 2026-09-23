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

/// Bounds-based built-in PDF page hit testing.
final class PdfPageHitTestingDefinition extends _BoundsHitTestingDefinition
    implements ObjectPageClippedHitTestingDefinition {
  /// Creates a definition with explicit PDF model limits.
  const PdfPageHitTestingDefinition(this.pdfLimits) : _pageBounds = null;

  const PdfPageHitTestingDefinition._(this.pdfLimits, this._pageBounds);

  final Rect2? _pageBounds;

  @override
  PdfPageHitTestingDefinition withPageBounds(Rect2 bounds) =>
      PdfPageHitTestingDefinition._(pdfLimits, bounds);

  @override
  bool _contains(Point2 point, List<Point2> polygon) {
    if (_inside(point, polygon)) return true;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i], b = polygon[(i + 1) % polygon.length];
      if (_cross(a, b, point) == 0 && _onSegment(a, b, point)) return true;
    }
    return false;
  }

  @override
  List<Point2>? _pagePolygon(ObjectEnvelope object) {
    final polygon = super._pagePolygon(object);
    final bounds = _pageBounds;
    return polygon == null || bounds == null
        ? polygon
        : _clipToPage(polygon, bounds);
  }

  @override
  Result<bool, StructuredFailure> wholePoint({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) {
    if (!pageTolerance.isFinite || pageTolerance < 0) {
      return Err(_failure('invalid_tolerance'));
    }
    // Selection tolerance must not acquire invisible content through the margin.
    if (_pageBounds?.contains(pagePosition) == false) return const Ok(false);
    return super.wholePoint(
      object: object,
      pagePosition: pagePosition,
      pageTolerance: pageTolerance,
    );
  }

  /// PDF model limits.
  final PdfModelLimits pdfLimits;
  @override
  ObjectTypeKey get typeKey => pdfPageObjectTypeKey;
  @override
  Rect2? localBounds(ObjectEnvelope object) =>
      object.typeKey == pdfPageObjectTypeKey &&
          object.typeSchemaVersion == pdfPageObjectSchemaVersion
      ? PdfPageObjectPayload.decode(
          object.payload,
          limits: pdfLimits,
        ).fold<Rect2?>(onOk: (value) => value.bounds, onErr: (_) => null)
      : null;
}

/// Bounds-based built-in Text hit testing.
final class TextHitTestingDefinition extends _BoundsHitTestingDefinition {
  /// Creates a definition with explicit Text limits.
  const TextHitTestingDefinition(this.textLimits, this.layoutEngine);

  /// Text payload limits.
  final TextLimits textLimits;

  /// Shared bounded layout authority.
  final TextLayoutEngine layoutEngine;
  @override
  ObjectTypeKey get typeKey => textObjectTypeKey;
  @override
  Rect2? localBounds(ObjectEnvelope object) {
    if (object.typeKey != textObjectTypeKey ||
        object.typeSchemaVersion != textSchemaVersion) {
      return null;
    }
    final payload = TextPayload.decode(object.payload, limits: textLimits);
    if (payload is! Ok<TextPayload, StructuredFailure>) return null;
    return layoutEngine
        .layout(TextLayoutRequest(payload: payload.value))
        .fold<Rect2?>(onOk: (value) => value.logicalBounds, onErr: (_) => null);
  }
}

abstract base class _BoundsHitTestingDefinition
    implements ObjectHitTestingDefinition, ObjectWholeHitTestingDefinition {
  const _BoundsHitTestingDefinition();
  Rect2? localBounds(ObjectEnvelope object);
  bool _contains(Point2 point, List<Point2> polygon) => _inside(point, polygon);
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
    if (polygon.isEmpty) return const Ok(false);
    return Ok(
      _contains(pagePosition, polygon) ||
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
    if (polygon.isEmpty) return const Ok(false);
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
    if (objectPolygon.isEmpty) return const Ok(false);
    final bounds = _bounds(objectPolygon);
    if (!_intersects(bounds, polygon.bounds)) return const Ok(false);
    return Ok(
      mode == AreaHitMode.containment
          ? objectPolygon.every((point) => _contains(point, polygon.points))
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
    if (polygon.isEmpty) return const Ok(false);
    if (_contains(start, polygon) || _contains(end, polygon))
      return const Ok(true);
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

// A transformed crop is convex. Four half-plane clips retain at most eight
// vertices; neither source geometry nor query positions are modified.
List<Point2> _clipToPage(List<Point2> polygon, Rect2 bounds) {
  var result = polygon;
  for (final edge in [
    (x: true, minimum: true, value: bounds.left),
    (x: true, minimum: false, value: bounds.right),
    (x: false, minimum: true, value: bounds.top),
    (x: false, minimum: false, value: bounds.bottom),
  ]) {
    if (result.isEmpty) return const [];
    final next = <Point2>[];
    var previous = result.last;
    var previousValue = edge.x ? previous.x : previous.y;
    var previousInside = edge.minimum
        ? previousValue >= edge.value
        : previousValue <= edge.value;
    for (final current in result) {
      final currentValue = edge.x ? current.x : current.y;
      final currentInside = edge.minimum
          ? currentValue >= edge.value
          : currentValue <= edge.value;
      if (currentInside != previousInside) {
        final t = (edge.value - previousValue) / (currentValue - previousValue);
        next.add(
          edge.x
              ? _point(edge.value, previous.y + t * (current.y - previous.y))
              : _point(previous.x + t * (current.x - previous.x), edge.value),
        );
      }
      if (currentInside) next.add(current);
      previous = current;
      previousValue = currentValue;
      previousInside = currentInside;
    }
    result = next;
  }
  if (result.length < 3) return const [];
  // An Object only touching the Page along a line/point has no visible area.
  final origin = result.first;
  var twiceArea = 0.0;
  for (var i = 1; i + 1 < result.length; i++) {
    twiceArea +=
        (result[i].x - origin.x) * (result[i + 1].y - origin.y) -
        (result[i].y - origin.y) * (result[i + 1].x - origin.x);
  }
  return twiceArea == 0 ? const [] : result;
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
  return (Rect2.fromEdges(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  ) as Ok<Rect2, StructuredFailure>).value;
}

Point2 _point(double x, double y) =>
    (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;
StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.bounds_hit_testing.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Object hit testing is invalid or unavailable.',
);
