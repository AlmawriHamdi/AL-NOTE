// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../../core/geometry/geometry_values.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../../core/versioning/revision.dart';
import 'shape_model.dart';

/// Preferred deterministic curve resolution shared by every Shape consumer.
const int preferredShapeCurveSegments = 64;

/// Returns the authoritative bounded curve resolution for [limits].
int shapeCurveSegmentsFor(ShapeLimits limits) =>
    math.min(preferredShapeCurveSegments, limits.maximumDerivedSegments);

/// Explicit synchronous-work ceiling for one Shape interaction query.
final class ShapeInteractionLimits {
  const ShapeInteractionLimits._(this.maximumChecks);

  /// Largest deliberately practical synchronous query ceiling.
  static const int maximumSupportedChecks = 10000000;

  /// Creates a positive Web-safe practical check ceiling.
  static Result<ShapeInteractionLimits, StructuredFailure> create({
    required int maximumChecks,
  }) {
    if (maximumChecks <= 0 ||
        maximumChecks > maximumSupportedChecks ||
        maximumChecks > Revision.maximumValue) {
      return Err(_failure('invalid_interaction_limit'));
    }
    return Ok(ShapeInteractionLimits._(maximumChecks));
  }

  /// Maximum charged derivation and predicate operations per query.
  final int maximumChecks;
}

/// One immutable AL NOTE-owned interpretation of visible Shape geometry.
final class ShapeDerivedGeometry {
  ShapeDerivedGeometry._({
    required List<Point2> fillPath,
    required List<List<Point2>> strokePolygons,
    required this.localVisibleBounds,
  }) : fillPath = List<Point2>.unmodifiable(fillPath),
       strokePolygons = List<List<Point2>>.unmodifiable(
         strokePolygons.map(List<Point2>.unmodifiable),
       );

  /// Local fill path. Empty when the Shape has no visible fill.
  final List<Point2> fillPath;

  /// Local filled polygons that exactly form the rendered stroke and arrows.
  final List<List<Point2>> strokePolygons;

  /// Exact conservative local bounds of the complete visible polygon union.
  final Rect2 localVisibleBounds;

  /// Derives bounded render/interaction geometry using the same semantics.
  static Result<ShapeDerivedGeometry, StructuredFailure> derive({
    required ShapePayload payload,
    required ShapeLimits shapeLimits,
    required int curveSegments,
    ShapeWorkBudget? budget,
  }) {
    if (curveSegments < 16 ||
        curveSegments > shapeLimits.maximumDerivedSegments ||
        shapeLimits.maximumDerivedSegments > Revision.maximumValue ~/ 4) {
      return Err(_failure('invalid_curve_segments'));
    }
    final work = budget ?? ShapeWorkBudget.unlimited();
    final path = _localPath(payload.geometry, curveSegments, work);
    if (path == null ||
        path.length > shapeLimits.maximumDerivedSegments ||
        work.exhausted) {
      return Err(_failure(work.exhausted ? 'work_limit' : 'geometry_limit'));
    }
    final closed = switch (payload.geometry.kind) {
      ShapeKind.rectangle || ShapeKind.ellipse || ShapeKind.polygon => true,
      _ => false,
    };
    final stroke = <List<Point2>>[];
    if (payload.style.strokeEnabled) {
      final body = _strokePolygons(
        path,
        closed: closed,
        style: payload.style,
        curveSegments: curveSegments,
        maximumDerived: shapeLimits.maximumDerivedSegments,
        budget: work,
      );
      if (body == null) {
        return Err(_failure(work.exhausted ? 'work_limit' : 'geometry_limit'));
      }
      stroke.addAll(body);
      if (!closed) {
        final arrows = _arrowPolygons(
          path,
          payload.style,
          curveSegments,
          shapeLimits.maximumDerivedSegments,
          work,
        );
        if (arrows == null) {
          return Err(
            _failure(work.exhausted ? 'work_limit' : 'geometry_limit'),
          );
        }
        stroke.addAll(arrows);
      }
    }
    if (work.exhausted ||
        stroke.length > shapeLimits.maximumDerivedSegments * 4) {
      return Err(_failure(work.exhausted ? 'work_limit' : 'geometry_limit'));
    }
    final visible = <List<Point2>>[if (payload.paintsFill) path, ...stroke];
    final bounds = _polygonBounds(visible, work);
    if (bounds == null) {
      return Err(_failure(work.exhausted ? 'work_limit' : 'geometry_limit'));
    }
    return Ok(
      ShapeDerivedGeometry._(
        fillPath: payload.paintsFill ? path : const [],
        strokePolygons: stroke,
        localVisibleBounds: bounds,
      ),
    );
  }
}

Rect2? _polygonBounds(List<List<Point2>> polygons, ShapeWorkBudget budget) {
  if (polygons.isEmpty) {
    return Rect2.fromEdges(
      left: 0,
      top: 0,
      right: 0,
      bottom: 0,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
  }
  Point2? first;
  for (final polygon in polygons) {
    if (polygon.isNotEmpty) {
      first = polygon.first;
      break;
    }
  }
  if (first == null) return null;
  var left = first.x, right = first.x, top = first.y, bottom = first.y;
  for (final polygon in polygons) {
    for (final point in polygon) {
      if (!budget.charge()) return null;
      left = math.min(left, point.x);
      right = math.max(right, point.x);
      top = math.min(top, point.y);
      bottom = math.max(bottom, point.y);
    }
  }
  return Rect2.fromEdges(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
}

/// Mutable query-local counter that never appears in persistent evidence.
final class ShapeWorkBudget {
  ShapeWorkBudget(this.maximumChecks) : _remaining = maximumChecks;
  ShapeWorkBudget.unlimited()
    : maximumChecks = Revision.maximumValue,
      _remaining = Revision.maximumValue;

  final int maximumChecks;
  int _remaining;
  bool _exhausted = false;

  bool get exhausted => _exhausted;
  int get consumed => maximumChecks - _remaining;

  bool charge([int amount = 1]) {
    if (amount < 0 || amount > _remaining) {
      _exhausted = true;
      return false;
    }
    _remaining -= amount;
    return true;
  }
}

List<Point2>? _localPath(
  ShapeGeometry geometry,
  int curveSegments,
  ShapeWorkBudget budget,
) {
  switch (geometry) {
    case ShapeLineGeometry(:final start, :final end):
      return budget.charge(2) ? [start, end] : null;
    case ShapeRectangleGeometry(:final localBounds, :final cornerRadius):
      if (cornerRadius == 0) {
        return budget.charge(4) ? _rectPoints(localBounds) : null;
      }
      return _roundedRectangle(
        localBounds,
        cornerRadius,
        curveSegments,
        budget,
      );
    case ShapeEllipseGeometry(:final localBounds):
      return _ellipse(localBounds, curveSegments, budget);
    case ShapeVertexGeometry(:final vertices):
      if (!budget.charge(vertices.length)) return null;
      return vertices;
  }
}

List<List<Point2>>? _strokePolygons(
  List<Point2> points, {
  required bool closed,
  required ShapeStyle style,
  required int curveSegments,
  required int maximumDerived,
  required ShapeWorkBudget budget,
}) {
  if (points.length < 2) return const [];
  if (maximumDerived > Revision.maximumValue ~/ 4) return null;
  final segments = <_StrokeSegment>[];
  final count = closed ? points.length : points.length - 1;
  for (var index = 0; index < count; index++) {
    if (!budget.charge()) return null;
    segments.add(
      _StrokeSegment(
        points[index],
        points[(index + 1) % points.length],
        capStart: !closed && index == 0,
        capEnd: !closed && index == count - 1,
      ),
    );
  }
  final dashed = style.dashArray.isEmpty
      ? null
      : _dashedSegments(
          segments,
          style.dashArray,
          style.dashOffset,
          maximumDerived,
          budget,
        );
  if (style.dashArray.isNotEmpty && dashed == null) return null;
  final visible = dashed ?? segments;
  final polygons = <List<Point2>>[];
  final half = style.strokeWidth / 2;
  for (var index = 0; index < visible.length; index++) {
    final segment = visible[index];
    final vector = _unitVector(segment.start, segment.end);
    if (!budget.charge()) return null;
    if (vector == null) {
      if (style.cap == ShapeStrokeCap.round &&
          (segment.capStart || segment.capEnd)) {
        final circle = _circle(segment.start, half, curveSegments, budget);
        if (circle == null) return null;
        polygons.add(circle);
      }
      continue;
    }
    Point2? start = segment.start;
    Point2? end = segment.end;
    if (style.cap == ShapeStrokeCap.square) {
      if (segment.capStart) {
        start = _safePoint(
          start.x - vector.$1 * half,
          start.y - vector.$2 * half,
        );
      }
      if (segment.capEnd) {
        end = _safePoint(end.x + vector.$1 * half, end.y + vector.$2 * half);
      }
      if (start == null || end == null) return null;
    }
    final resolvedStart = start;
    final resolvedEnd = end;
    final nx = -vector.$2 * half;
    final ny = vector.$1 * half;
    final body = _points([
      (resolvedStart.x + nx, resolvedStart.y + ny),
      (resolvedEnd.x + nx, resolvedEnd.y + ny),
      (resolvedEnd.x - nx, resolvedEnd.y - ny),
      (resolvedStart.x - nx, resolvedStart.y - ny),
    ]);
    if (body == null) return null;
    polygons.add(body);
    if (style.cap == ShapeStrokeCap.round) {
      if (segment.capStart) {
        final first = _circle(segment.start, half, curveSegments, budget);
        if (first == null) return null;
        polygons.add(first);
      }
      if (segment.capEnd) {
        final last = _circle(segment.end, half, curveSegments, budget);
        if (last == null) return null;
        polygons.add(last);
      }
    }
    if (polygons.length > maximumDerived * 4) return null;
  }

  if (visible.length > 1) {
    final pairCount = closed ? visible.length : visible.length - 1;
    for (var index = 0; index < pairCount; index++) {
      final incoming = visible[index];
      final outgoing = visible[(index + 1) % visible.length];
      if (incoming.capEnd ||
          outgoing.capStart ||
          incoming.end != outgoing.start) {
        continue;
      }
      final join = _joinPolygon(
        incoming.start,
        incoming.end,
        outgoing.end,
        half,
        style.join,
        style.miterLimit,
        curveSegments,
        budget,
      );
      if (join == null) return null;
      if (join.isNotEmpty) polygons.add(join);
      if (polygons.length > maximumDerived * 4) return null;
    }
  }
  return polygons;
}

List<Point2>? _joinPolygon(
  Point2 previous,
  Point2 center,
  Point2 next,
  double half,
  ShapeStrokeJoin join,
  double miterLimit,
  int curveSegments,
  ShapeWorkBudget budget,
) {
  if (!budget.charge()) return null;
  final incoming = _unitVector(previous, center);
  final outgoing = _unitVector(center, next);
  if (incoming == null || outgoing == null) return const [];
  final turn = incoming.$1 * outgoing.$2 - incoming.$2 * outgoing.$1;
  if (!turn.isFinite) return null;
  if (turn == 0) return const [];
  final side = turn > 0 ? -1.0 : 1.0;
  final first = _safePoint(
    center.x - incoming.$2 * half * side,
    center.y + incoming.$1 * half * side,
  );
  final second = _safePoint(
    center.x - outgoing.$2 * half * side,
    center.y + outgoing.$1 * half * side,
  );
  if (first == null || second == null) return null;
  if (join == ShapeStrokeJoin.bevel) return [center, first, second];
  if (join == ShapeStrokeJoin.round) {
    final start = math.atan2(first.y - center.y, first.x - center.x);
    var end = math.atan2(second.y - center.y, second.x - center.x);
    if (turn > 0) {
      while (end < start) end += math.pi * 2;
    } else {
      while (end > start) end -= math.pi * 2;
    }
    final arc = (end - start).abs();
    final segments = math.max(1, (curveSegments * arc / (math.pi * 2)).ceil());
    if (!budget.charge(segments + 1)) return null;
    final result = <Point2>[center];
    for (var index = 0; index <= segments; index++) {
      final angle = start + (end - start) * index / segments;
      final point = _safePoint(
        center.x + math.cos(angle) * half,
        center.y + math.sin(angle) * half,
      );
      if (point == null) return null;
      result.add(point);
    }
    return result;
  }
  final miter = _lineIntersection(
    first,
    incoming.$1,
    incoming.$2,
    second,
    outgoing.$1,
    outgoing.$2,
  );
  if (miter == null) return [center, first, second];
  final distance = _safeDistance(center, miter);
  if (distance == null) return null;
  if (distance <= half * miterLimit) return [center, first, miter, second];
  return [center, first, second];
}

List<_StrokeSegment>? _dashedSegments(
  List<_StrokeSegment> source,
  List<double> pattern,
  double offset,
  int maximum,
  ShapeWorkBudget budget,
) {
  var cycle = 0.0;
  for (final value in pattern) {
    if (!budget.charge()) return null;
    cycle += value;
    if (!cycle.isFinite) return null;
  }
  if (cycle <= 0) return null;
  var phase = offset % cycle;
  if (phase < 0) phase += cycle;
  var patternIndex = 0;
  while (phase >= pattern[patternIndex]) {
    if (!budget.charge()) return null;
    phase -= pattern[patternIndex];
    patternIndex = (patternIndex + 1) % pattern.length;
  }
  var remaining = pattern[patternIndex] - phase;
  var paints = patternIndex.isEven;
  final result = <_StrokeSegment>[];
  var paintRunOpen = false;
  for (final segment in source) {
    final length = _safeDistance(segment.start, segment.end);
    if (length == null) return null;
    if (length == 0) continue;
    final dx = (segment.end.x - segment.start.x) / length;
    final dy = (segment.end.y - segment.start.y) / length;
    if (!dx.isFinite || !dy.isFinite) return null;
    var consumed = 0.0;
    while (consumed < length) {
      if (!budget.charge()) return null;
      final amount = math.min(remaining, length - consumed);
      if (paints && amount > 0) {
        if (result.length >= maximum) return null;
        final reachesSourceEnd = consumed + amount >= length;
        final start = consumed == 0
            ? segment.start
            : _safePoint(
                segment.start.x + dx * consumed,
                segment.start.y + dy * consumed,
              );
        final end = reachesSourceEnd
            ? segment.end
            : _safePoint(
                segment.start.x + dx * (consumed + amount),
                segment.start.y + dy * (consumed + amount),
              );
        if (start == null || end == null) return null;
        final endsAtPatternBoundary = remaining - amount <= 1e-12;
        final capStart = !paintRunOpen || segment.capStart;
        final capEnd = endsAtPatternBoundary || segment.capEnd;
        result.add(
          _StrokeSegment(start, end, capStart: capStart, capEnd: capEnd),
        );
        paintRunOpen = !capEnd;
      } else if (!paints) {
        paintRunOpen = false;
      }
      consumed += amount;
      remaining -= amount;
      if (remaining <= 1e-12) {
        patternIndex = (patternIndex + 1) % pattern.length;
        remaining = pattern[patternIndex];
        paints = patternIndex.isEven;
      }
    }
  }
  return result;
}

List<List<Point2>>? _arrowPolygons(
  List<Point2> points,
  ShapeStyle style,
  int curveSegments,
  int maximumDerived,
  ShapeWorkBudget budget,
) {
  if (points.length < 2) return const [];
  final result = <List<Point2>>[];
  for (final arrow in <(ShapeArrowhead, Point2, Point2)>[
    (style.startArrowhead, points.first, points[1]),
    (style.endArrowhead, points.last, points[points.length - 2]),
  ]) {
    if (!budget.charge()) return null;
    if (arrow.$1 == ShapeArrowhead.none) continue;
    final direction = _unitVector(arrow.$3, arrow.$2);
    if (direction == null) continue;
    final size = math.max(style.strokeWidth * 4, 6.0);
    final base = _safePoint(
      arrow.$2.x - direction.$1 * size,
      arrow.$2.y - direction.$2 * size,
    );
    if (base == null) return null;
    final px = -direction.$2 * size * .45;
    final py = direction.$1 * size * .45;
    final left = _safePoint(base.x + px, base.y + py);
    final right = _safePoint(base.x - px, base.y - py);
    if (left == null || right == null) return null;
    switch (arrow.$1) {
      case ShapeArrowhead.open:
        final openStyle = ShapeStyle.create(
          strokeEnabled: true,
          strokeColor: style.strokeColor,
          strokeWidth: style.strokeWidth,
          cap: ShapeStrokeCap.round,
          join: ShapeStrokeJoin.round,
          miterLimit: style.miterLimit,
          dashArray: const [],
          dashOffset: 0,
          fillEnabled: false,
          fillColor: style.fillColor,
          fillRule: style.fillRule,
          opacity: style.opacity,
          startArrowhead: ShapeArrowhead.none,
          endArrowhead: ShapeArrowhead.none,
          limits: _arrowLimits(style, maximumDerived),
        );
        if (openStyle is! Ok<ShapeStyle, StructuredFailure>) return null;
        final polygons = _strokePolygons(
          [left, arrow.$2, right],
          closed: false,
          style: openStyle.value,
          curveSegments: curveSegments,
          maximumDerived: maximumDerived,
          budget: budget,
        );
        if (polygons == null) return null;
        result.addAll(polygons);
      case ShapeArrowhead.triangle:
        result.add([arrow.$2, left, right]);
      case ShapeArrowhead.diamond:
        final back = _safePoint(
          arrow.$2.x - direction.$1 * size * 1.5,
          arrow.$2.y - direction.$2 * size * 1.5,
        );
        if (back == null) return null;
        result.add([arrow.$2, left, back, right]);
      case ShapeArrowhead.circle:
        final circle = _circle(base, size * .4, curveSegments, budget);
        if (circle == null) return null;
        result.add(circle);
      case ShapeArrowhead.none:
        break;
    }
  }
  return result;
}

ShapeLimits _arrowLimits(ShapeStyle style, int maximumDerived) =>
    (ShapeLimits.create(
              maximumVertices: math.max(3, maximumDerived),
              maximumDashValues: 0,
              maximumUnknownFields: 0,
              maximumUnknownNodes: 1,
              maximumNestingDepth: 1,
              maximumUnknownStringCodeUnits: 1,
              maximumCoordinateMagnitude: double.maxFinite,
              maximumStrokeWidth: style.strokeWidth,
              maximumMiterLimit: math.max(1, style.miterLimit),
              maximumCornerRadius: 0,
              maximumDerivedSegments: math.max(3, maximumDerived),
            )
            as Ok<ShapeLimits, StructuredFailure>)
        .value;

List<Point2>? _ellipse(Rect2 bounds, int segments, ShapeWorkBudget budget) {
  if (!budget.charge(segments)) return null;
  final result = <Point2>[];
  for (var index = 0; index < segments; index++) {
    final angle = index * math.pi * 2 / segments;
    final point = _safePoint(
      (bounds.left + bounds.right) / 2 + math.cos(angle) * bounds.width / 2,
      (bounds.top + bounds.bottom) / 2 + math.sin(angle) * bounds.height / 2,
    );
    if (point == null) return null;
    result.add(point);
  }
  return result;
}

List<Point2>? _roundedRectangle(
  Rect2 bounds,
  double radius,
  int segments,
  ShapeWorkBudget budget,
) {
  final perCorner = math.max(2, segments ~/ 4);
  if (!budget.charge(perCorner * 4)) return null;
  final result = <Point2>[];
  for (final corner in <(double, double, double)>[
    (bounds.right - radius, bounds.top + radius, -math.pi / 2),
    (bounds.right - radius, bounds.bottom - radius, 0),
    (bounds.left + radius, bounds.bottom - radius, math.pi / 2),
    (bounds.left + radius, bounds.top + radius, math.pi),
  ]) {
    for (var index = 0; index < perCorner; index++) {
      final angle = corner.$3 + index * math.pi / 2 / (perCorner - 1);
      final point = _safePoint(
        corner.$1 + math.cos(angle) * radius,
        corner.$2 + math.sin(angle) * radius,
      );
      if (point == null) return null;
      result.add(point);
    }
  }
  return result;
}

List<Point2>? _circle(
  Point2 center,
  double radius,
  int segments,
  ShapeWorkBudget budget,
) {
  if (!radius.isFinite || radius < 0 || !budget.charge(segments)) return null;
  final result = <Point2>[];
  for (var index = 0; index < segments; index++) {
    final angle = index * math.pi * 2 / segments;
    final point = _safePoint(
      center.x + math.cos(angle) * radius,
      center.y + math.sin(angle) * radius,
    );
    if (point == null) return null;
    result.add(point);
  }
  return result;
}

(double, double)? _unitVector(Point2 start, Point2 end) {
  final distance = _safeDistance(start, end);
  if (distance == null || distance == 0) return null;
  final dx = (end.x - start.x) / distance;
  final dy = (end.y - start.y) / distance;
  return dx.isFinite && dy.isFinite ? (dx, dy) : null;
}

double? _safeDistance(Point2 first, Point2 second) {
  final dx = first.x - second.x;
  final dy = first.y - second.y;
  if (!dx.isFinite || !dy.isFinite) return null;
  final scale = math.max(dx.abs(), dy.abs());
  if (scale == 0) return 0;
  final value =
      scale *
      math.sqrt((dx / scale) * (dx / scale) + (dy / scale) * (dy / scale));
  return value.isFinite ? value : null;
}

Point2? _lineIntersection(
  Point2 first,
  double firstDx,
  double firstDy,
  Point2 second,
  double secondDx,
  double secondDy,
) {
  final denominator = firstDx * secondDy - firstDy * secondDx;
  if (!denominator.isFinite || denominator == 0) return null;
  final dx = second.x - first.x;
  final dy = second.y - first.y;
  if (!dx.isFinite || !dy.isFinite) return null;
  final t = (dx * secondDy - dy * secondDx) / denominator;
  return _safePoint(first.x + firstDx * t, first.y + firstDy * t);
}

List<Point2>? _points(List<(double, double)> values) {
  final result = <Point2>[];
  for (final value in values) {
    final point = _safePoint(value.$1, value.$2);
    if (point == null) return null;
    result.add(point);
  }
  return result;
}

Point2? _safePoint(double x, double y) => Point2.create(
  x: x,
  y: y,
).fold<Point2?>(onOk: (value) => value, onErr: (_) => null);

List<Point2> _rectPoints(Rect2 rect) => [
  rect.topLeft,
  (Point2.create(x: rect.right, y: rect.top) as Ok<Point2, StructuredFailure>)
      .value,
  rect.bottomRight,
  (Point2.create(x: rect.left, y: rect.bottom) as Ok<Point2, StructuredFailure>)
      .value,
];

final class _StrokeSegment {
  const _StrokeSegment(
    this.start,
    this.end, {
    required this.capStart,
    required this.capEnd,
  });
  final Point2 start;
  final Point2 end;
  final bool capStart;
  final bool capEnd;
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.shape_geometry.$leaf',
  category: leaf == 'work_limit'
      ? FailureCategory.resource
      : FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Shape geometry is invalid or unavailable.',
);
