// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../geometry.dart';
import 'hit_testing.dart';

extension<T, E> on Result<T, E> {
  T get value => (this as Ok<T, E>).value;
  E get error => (this as Err<T, E>).error;
}

/// Transform-complete Shape interaction over authoritative rendered geometry.
final class ShapeHitTestingDefinition
    implements ObjectHitTestingDefinition, ObjectWholeHitTestingDefinition {
  const ShapeHitTestingDefinition({
    required this.shapeLimits,
    required this.interactionLimits,
  });

  final ShapeLimits shapeLimits;
  final ShapeInteractionLimits interactionLimits;

  @override
  ObjectTypeKey get typeKey => shapeObjectTypeKey;

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
    if (!pageTolerance.isFinite || pageTolerance < 0) {
      return Err(_failure('invalid_tolerance'));
    }
    final budget = ShapeWorkBudget(interactionLimits.maximumChecks);
    final prepared = _prepare(object, budget);
    if (prepared is! Ok<_PreparedShape, StructuredFailure>) {
      return Err(prepared.error);
    }
    for (
      var index = 0;
      index < prepared.value.visiblePolygons.length;
      index++
    ) {
      final polygon = prepared.value.visiblePolygons[index];
      final inside = _insideOrOn(
        pagePosition,
        polygon,
        budget,
        evenOdd:
            prepared.value.hasFill && index == 0 && prepared.value.fillEvenOdd,
      );
      if (inside is Err<bool, StructuredFailure>) return inside;
      if (inside.value) return const Ok(true);
      final within = _withinDistanceToPolygon(
        pagePosition,
        polygon,
        pageTolerance,
        budget,
      );
      if (within is Err<bool, StructuredFailure>) return Err(within.error);
      if (within.value) return const Ok(true);
    }
    return const Ok(false);
  }

  @override
  Result<bool, StructuredFailure> wholeRectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) {
    final budget = ShapeWorkBudget(interactionLimits.maximumChecks);
    final prepared = _prepare(object, budget);
    if (prepared is! Ok<_PreparedShape, StructuredFailure>) {
      return Err(prepared.error);
    }
    final query = <Point2>[
      area.topLeft,
      _point(area.right, area.top),
      area.bottomRight,
      _point(area.left, area.bottom),
    ];
    return _areaMatches(prepared.value.visiblePolygons, query, mode, budget);
  }

  @override
  Result<bool, StructuredFailure> wholeLasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) {
    final budget = ShapeWorkBudget(interactionLimits.maximumChecks);
    final prepared = _prepare(object, budget);
    if (prepared is! Ok<_PreparedShape, StructuredFailure>) {
      return Err(prepared.error);
    }
    if (!_rectanglesIntersect(prepared.value.bounds, polygon.bounds)) {
      return const Ok(false);
    }
    return _areaMatches(
      prepared.value.visiblePolygons,
      polygon.points,
      mode,
      budget,
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
    final budget = ShapeWorkBudget(interactionLimits.maximumChecks);
    final prepared = _prepare(object, budget);
    if (prepared is! Ok<_PreparedShape, StructuredFailure>) {
      return Err(prepared.error);
    }
    for (final polygon in prepared.value.visiblePolygons) {
      final hit = _capsuleIntersectsPolygon(
        start,
        end,
        radius,
        polygon,
        budget,
      );
      if (hit is Err<bool, StructuredFailure>) return hit;
      if (hit.value) return const Ok(true);
    }
    return const Ok(false);
  }

  Result<_PreparedShape, StructuredFailure> _prepare(
    ObjectEnvelope object,
    ShapeWorkBudget budget,
  ) {
    if (object.typeKey != shapeObjectTypeKey ||
        object.typeSchemaVersion != shapeSchemaVersion) {
      return Err(_failure('invalid_object'));
    }
    final payload = ShapePayload.decode(object.payload, limits: shapeLimits);
    if (payload is! Ok<ShapePayload, StructuredFailure>) {
      return Err(_failure('invalid_object'));
    }
    final derived = ShapeDerivedGeometry.derive(
      payload: payload.value,
      shapeLimits: shapeLimits,
      curveSegments: shapeCurveSegmentsFor(shapeLimits),
      budget: budget,
    );
    if (derived is! Ok<ShapeDerivedGeometry, StructuredFailure>) {
      return Err(_failureFor(budget));
    }
    final visible = <List<Point2>>[];
    if (derived.value.fillPath.isNotEmpty) {
      final transformed = _transformPolygon(
        derived.value.fillPath,
        object,
        budget,
      );
      if (transformed == null) return Err(_failureFor(budget));
      visible.add(transformed);
    }
    for (final polygon in derived.value.strokePolygons) {
      final transformed = _transformPolygon(polygon, object, budget);
      if (transformed == null) return Err(_failureFor(budget));
      visible.add(transformed);
    }
    if (visible.isEmpty) {
      return Ok(
        _PreparedShape(
          const [],
          _rect(0, 0, 0, 0),
          hasFill: false,
          fillEvenOdd: false,
        ),
      );
    }
    final bounds = _polygonsBounds(visible, budget);
    if (bounds == null) return Err(_failureFor(budget));
    return Ok(
      _PreparedShape(
        List.unmodifiable(visible),
        bounds,
        hasFill: derived.value.fillPath.isNotEmpty,
        fillEvenOdd: payload.value.style.fillRule == ShapeFillRule.evenOdd,
      ),
    );
  }
}

final class _PreparedShape {
  const _PreparedShape(
    this.visiblePolygons,
    this.bounds, {
    required this.hasFill,
    required this.fillEvenOdd,
  });
  final List<List<Point2>> visiblePolygons;
  final Rect2 bounds;
  final bool hasFill;
  final bool fillEvenOdd;
}

Result<bool, StructuredFailure> _areaMatches(
  List<List<Point2>> visible,
  List<Point2> query,
  AreaHitMode mode,
  ShapeWorkBudget budget,
) {
  if (visible.isEmpty) return const Ok(false);
  if (mode == AreaHitMode.intersection) {
    for (final polygon in visible) {
      final intersects = _polygonsIntersect(polygon, query, budget);
      if (intersects is Err<bool, StructuredFailure>) return intersects;
      if (intersects.value) return const Ok(true);
    }
    return const Ok(false);
  }
  for (final polygon in visible) {
    for (final point in polygon) {
      final inside = _insideOrOn(point, query, budget);
      if (inside is Err<bool, StructuredFailure>) return inside;
      if (!inside.value) return const Ok(false);
    }
    final crossing = _properEdgeCrossing(polygon, query, budget);
    if (crossing is Err<bool, StructuredFailure>) return crossing;
    if (crossing.value) return const Ok(false);
  }
  return const Ok(true);
}

Result<bool, StructuredFailure> _polygonsIntersect(
  List<Point2> first,
  List<Point2> second,
  ShapeWorkBudget budget,
) {
  for (final point in first) {
    final inside = _insideOrOn(point, second, budget);
    if (inside is Err<bool, StructuredFailure>) return inside;
    if (inside.value) return const Ok(true);
  }
  for (final point in second) {
    final inside = _insideOrOn(point, first, budget);
    if (inside is Err<bool, StructuredFailure>) return inside;
    if (inside.value) return const Ok(true);
  }
  for (var i = 0; i < first.length; i++) {
    for (var j = 0; j < second.length; j++) {
      final hit = _segmentsIntersect(
        first[i],
        first[(i + 1) % first.length],
        second[j],
        second[(j + 1) % second.length],
        budget,
      );
      if (hit is Err<bool, StructuredFailure>) return hit;
      if (hit.value) return const Ok(true);
    }
  }
  return const Ok(false);
}

Result<bool, StructuredFailure> _properEdgeCrossing(
  List<Point2> first,
  List<Point2> second,
  ShapeWorkBudget budget,
) {
  for (var i = 0; i < first.length; i++) {
    for (var j = 0; j < second.length; j++) {
      if (!budget.charge()) return Err(_failure('work_limit'));
      final a = _orientation(
        first[i],
        first[(i + 1) % first.length],
        second[j],
        budget,
      );
      final b = _orientation(
        first[i],
        first[(i + 1) % first.length],
        second[(j + 1) % second.length],
        budget,
      );
      final c = _orientation(
        second[j],
        second[(j + 1) % second.length],
        first[i],
        budget,
      );
      final d = _orientation(
        second[j],
        second[(j + 1) % second.length],
        first[(i + 1) % first.length],
        budget,
      );
      if (a is Err<int, StructuredFailure>) return Err(a.error);
      if (b is Err<int, StructuredFailure>) return Err(b.error);
      if (c is Err<int, StructuredFailure>) return Err(c.error);
      if (d is Err<int, StructuredFailure>) return Err(d.error);
      if (a.value != 0 &&
          b.value != 0 &&
          c.value != 0 &&
          d.value != 0 &&
          a.value != b.value &&
          c.value != d.value) {
        return const Ok(true);
      }
    }
  }
  return const Ok(false);
}

Result<bool, StructuredFailure> _insideOrOn(
  Point2 point,
  List<Point2> polygon,
  ShapeWorkBudget budget, {
  bool evenOdd = false,
}) {
  var winding = 0;
  var crossings = 0;
  for (var index = 0; index < polygon.length; index++) {
    if (!budget.charge()) return Err(_failure('work_limit'));
    final a = polygon[index];
    final b = polygon[(index + 1) % polygon.length];
    final orientation = _orientation(a, b, point, budget);
    if (orientation is Err<int, StructuredFailure>)
      return Err(orientation.error);
    if (orientation.value == 0 && _onSegment(a, b, point)) {
      return const Ok(true);
    }
    if ((a.y > point.y) != (b.y > point.y)) {
      final upward = b.y > a.y;
      if (upward && orientation.value > 0 || !upward && orientation.value < 0) {
        crossings++;
      }
    }
    if (a.y <= point.y && b.y > point.y && orientation.value > 0) winding++;
    if (a.y > point.y && b.y <= point.y && orientation.value < 0) winding--;
  }
  return Ok(evenOdd ? crossings.isOdd : winding != 0);
}

Result<bool, StructuredFailure> _segmentsIntersect(
  Point2 a,
  Point2 b,
  Point2 c,
  Point2 d,
  ShapeWorkBudget budget,
) {
  if (!budget.charge()) return Err(_failure('work_limit'));
  final abC = _orientation(a, b, c, budget);
  final abD = _orientation(a, b, d, budget);
  final cdA = _orientation(c, d, a, budget);
  final cdB = _orientation(c, d, b, budget);
  if (abC is Err<int, StructuredFailure>) return Err(abC.error);
  if (abD is Err<int, StructuredFailure>) return Err(abD.error);
  if (cdA is Err<int, StructuredFailure>) return Err(cdA.error);
  if (cdB is Err<int, StructuredFailure>) return Err(cdB.error);
  if (abC.value == 0 && _onSegment(a, b, c) ||
      abD.value == 0 && _onSegment(a, b, d) ||
      cdA.value == 0 && _onSegment(c, d, a) ||
      cdB.value == 0 && _onSegment(c, d, b)) {
    return const Ok(true);
  }
  return Ok(abC.value != abD.value && cdA.value != cdB.value);
}

Result<bool, StructuredFailure> _capsuleIntersectsPolygon(
  Point2 start,
  Point2 end,
  double radius,
  List<Point2> polygon,
  ShapeWorkBudget budget,
) {
  final first = _insideOrOn(start, polygon, budget);
  if (first is Err<bool, StructuredFailure> || first.value) return first;
  final last = _insideOrOn(end, polygon, budget);
  if (last is Err<bool, StructuredFailure> || last.value) return last;
  for (var index = 0; index < polygon.length; index++) {
    final within = _segmentsWithinDistance(
      start,
      end,
      polygon[index],
      polygon[(index + 1) % polygon.length],
      radius,
      budget,
    );
    if (within is Err<bool, StructuredFailure>) return Err(within.error);
    if (within.value) return const Ok(true);
  }
  return const Ok(false);
}

Result<bool, StructuredFailure> _segmentsWithinDistance(
  Point2 a,
  Point2 b,
  Point2 c,
  Point2 d,
  double tolerance,
  ShapeWorkBudget budget,
) {
  final intersects = _segmentsIntersect(a, b, c, d, budget);
  if (intersects is Err<bool, StructuredFailure>) return Err(intersects.error);
  if (intersects.value) return const Ok(true);
  for (final entry in <(Point2, Point2, Point2)>[
    (a, c, d),
    (b, c, d),
    (c, a, b),
    (d, a, b),
  ]) {
    final within = _pointWithinDistance(
      entry.$1,
      entry.$2,
      entry.$3,
      tolerance,
      budget,
    );
    if (within is Err<bool, StructuredFailure>) return within;
    if (within.value) return const Ok(true);
  }
  return const Ok(false);
}

Result<bool, StructuredFailure> _withinDistanceToPolygon(
  Point2 point,
  List<Point2> polygon,
  double tolerance,
  ShapeWorkBudget budget,
) {
  for (var index = 0; index < polygon.length; index++) {
    final within = _pointWithinDistance(
      point,
      polygon[index],
      polygon[(index + 1) % polygon.length],
      tolerance,
      budget,
    );
    if (within is Err<bool, StructuredFailure>) return within;
    if (within.value) return const Ok(true);
  }
  return const Ok(false);
}

Result<bool, StructuredFailure> _pointWithinDistance(
  Point2 point,
  Point2 start,
  Point2 end,
  double tolerance,
  ShapeWorkBudget budget,
) {
  if (!budget.charge()) return Err(_failure('work_limit'));
  if (!tolerance.isFinite || tolerance < 0) {
    return Err(_failure('numeric_uncertain'));
  }
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final px = point.x - start.x;
  final py = point.y - start.y;
  if (![dx, dy, px, py].every((value) => value.isFinite)) {
    return _exactPointWithinDistance(point, start, end, tolerance, budget);
  }
  final scale = [
    dx.abs(),
    dy.abs(),
    px.abs(),
    py.abs(),
    tolerance,
  ].reduce(math.max);
  if (scale == 0) return const Ok(true);
  final ndx = dx / scale, ndy = dy / scale;
  final npx = px / scale, npy = py / scale;
  final normalizedTolerance = tolerance / scale;
  final lengthSquared = ndx * ndx + ndy * ndy;
  final dot = npx * ndx + npy * ndy;
  if (normalizedTolerance == 0 && tolerance != 0 ||
      lengthSquared == 0 && (dx != 0 || dy != 0)) {
    return _exactPointWithinDistance(point, start, end, tolerance, budget);
  }
  const coefficient = 1.4210854715202004e-14; // 64 * binary64 epsilon.
  final dotError =
      coefficient * (npx.abs() * ndx.abs() + npy.abs() * ndy.abs());
  final lengthError =
      coefficient * (ndx.abs() * ndx.abs() + ndy.abs() * ndy.abs());

  double left;
  double right;
  var collapsedEvidence = false;
  if (lengthSquared == 0 || dot < -dotError) {
    left = npx * npx + npy * npy;
    right = normalizedTolerance * normalizedTolerance;
    collapsedEvidence = left == 0 && (npx != 0 || npy != 0);
  } else if (dot > lengthSquared + dotError + lengthError) {
    final ex = npx - ndx;
    final ey = npy - ndy;
    left = ex * ex + ey * ey;
    right = normalizedTolerance * normalizedTolerance;
    collapsedEvidence = left == 0 && (ex != 0 || ey != 0);
  } else if (dot > dotError && dot < lengthSquared - dotError - lengthError) {
    final cross = ndx * npy - ndy * npx;
    left = cross * cross;
    right = normalizedTolerance * normalizedTolerance * lengthSquared;
    collapsedEvidence = cross == 0;
  } else {
    return _exactPointWithinDistance(point, start, end, tolerance, budget);
  }
  if (collapsedEvidence ||
      right == 0 && tolerance != 0 ||
      !left.isFinite ||
      !right.isFinite) {
    return _exactPointWithinDistance(point, start, end, tolerance, budget);
  }
  final comparisonError = coefficient * (left.abs() + right.abs());
  if (left < right - comparisonError) return const Ok(true);
  if (left > right + comparisonError) return const Ok(false);
  return _exactPointWithinDistance(point, start, end, tolerance, budget);
}

Result<bool, StructuredFailure> _exactPointWithinDistance(
  Point2 point,
  Point2 start,
  Point2 end,
  double tolerance,
  ShapeWorkBudget budget,
) {
  if (!budget.charge(32)) return Err(_failure('work_limit'));
  try {
    final vx = _exactDifference(end.x, start.x);
    final vy = _exactDifference(end.y, start.y);
    final wx = _exactDifference(point.x, start.x);
    final wy = _exactDifference(point.y, start.y);
    final dot = _exactAdd(_exactProduct(wx, vx), _exactProduct(wy, vy));
    final lengthSquared = _exactAdd(
      _exactProduct(vx, vx),
      _exactProduct(vy, vy),
    );
    final threshold = _exactDouble(tolerance);
    final thresholdSquared = _exactProduct(threshold, threshold);
    late final (BigInt, int) left;
    late final (BigInt, int) right;
    if (_exactSign(dot) <= 0 || _exactSign(lengthSquared) == 0) {
      left = _exactAdd(_exactProduct(wx, wx), _exactProduct(wy, wy));
      right = thresholdSquared;
    } else if (_exactCompare(dot, lengthSquared) >= 0) {
      final ex = _exactDifference(point.x, end.x);
      final ey = _exactDifference(point.y, end.y);
      left = _exactAdd(_exactProduct(ex, ex), _exactProduct(ey, ey));
      right = thresholdSquared;
    } else {
      final cross = _exactSubtract(
        _exactProduct(vx, wy),
        _exactProduct(vy, wx),
      );
      left = _exactProduct(cross, cross);
      right = _exactProduct(thresholdSquared, lengthSquared);
    }
    return Ok(_exactCompare(left, right) <= 0);
  } on Object {
    return Err(_failure('numeric_uncertain'));
  }
}

Result<int, StructuredFailure> _orientation(
  Point2 a,
  Point2 b,
  Point2 c,
  ShapeWorkBudget budget,
) {
  final abx = b.x - a.x;
  final aby = b.y - a.y;
  final acx = c.x - a.x;
  final acy = c.y - a.y;
  if (![a.x, a.y, b.x, b.y, c.x, c.y].every((value) => value.isFinite)) {
    return Err(_failure('numeric_uncertain'));
  }
  if (![abx, aby, acx, acy].every((value) => value.isFinite)) {
    return _exactOrientation(a, b, c, budget);
  }
  final scale = [abx.abs(), aby.abs(), acx.abs(), acy.abs()].reduce(math.max);
  if (scale == 0) return const Ok(0);
  final normalizedAbx = abx / scale;
  final normalizedAby = aby / scale;
  final normalizedAcx = acx / scale;
  final normalizedAcy = acy / scale;
  final first = normalizedAbx * normalizedAcy;
  final second = normalizedAby * normalizedAcx;
  if (first == 0 && normalizedAbx != 0 && normalizedAcy != 0 ||
      second == 0 && normalizedAby != 0 && normalizedAcx != 0) {
    return _exactOrientation(a, b, c, budget);
  }
  final cross = first - second;
  if (!cross.isFinite) return _exactOrientation(a, b, c, budget);
  const errorCoefficient = 3.3306690738754716e-16;
  final errorBound = errorCoefficient * (first.abs() + second.abs());
  if (cross.abs() > errorBound) return Ok(cross > 0 ? 1 : -1);
  return _exactOrientation(a, b, c, budget);
}

Result<int, StructuredFailure> _exactOrientation(
  Point2 a,
  Point2 b,
  Point2 c,
  ShapeWorkBudget budget,
) {
  // The fallback operates on exact IEEE-754 binary rationals. Its fixed charge
  // covers the bounded decomposition, shifts (at most 2,097 bits), and products.
  if (!budget.charge(16)) return Err(_failure('work_limit'));
  try {
    final abx = _exactDifference(b.x, a.x);
    final aby = _exactDifference(b.y, a.y);
    final acx = _exactDifference(c.x, a.x);
    final acy = _exactDifference(c.y, a.y);
    final first = _exactProduct(abx, acy);
    final second = _exactProduct(aby, acx);
    final exponent = math.min(first.$2, second.$2);
    final determinant =
        (first.$1 << (first.$2 - exponent)) -
        (second.$1 << (second.$2 - exponent));
    return Ok(determinant.sign);
  } on Object {
    return Err(_failure('numeric_uncertain'));
  }
}

(BigInt, int) _exactDifference(double left, double right) {
  final a = _exactDouble(left);
  final b = _exactDouble(right);
  final exponent = math.min(a.$2, b.$2);
  return ((a.$1 << (a.$2 - exponent)) - (b.$1 << (b.$2 - exponent)), exponent);
}

(BigInt, int) _exactProduct((BigInt, int) left, (BigInt, int) right) =>
    (left.$1 * right.$1, left.$2 + right.$2);

(BigInt, int) _exactAdd((BigInt, int) left, (BigInt, int) right) {
  final exponent = math.min(left.$2, right.$2);
  return (
    (left.$1 << (left.$2 - exponent)) + (right.$1 << (right.$2 - exponent)),
    exponent,
  );
}

(BigInt, int) _exactSubtract((BigInt, int) left, (BigInt, int) right) =>
    _exactAdd(left, (-right.$1, right.$2));

int _exactSign((BigInt, int) value) => value.$1.sign;

int _exactCompare((BigInt, int) left, (BigInt, int) right) =>
    _exactSign(_exactSubtract(left, right));

(BigInt, int) _exactDouble(double value) {
  if (value == 0) return (BigInt.zero, 0);
  final bytes = ByteData(8)..setFloat64(0, value);
  final high = bytes.getUint32(0);
  final low = bytes.getUint32(4);
  final exponentBits = (high >>> 20) & 0x7ff;
  var coefficient = (BigInt.from(high & 0xfffff) << 32) | BigInt.from(low);
  final exponent = exponentBits == 0 ? -1074 : exponentBits - 1023 - 52;
  if (exponentBits != 0) coefficient |= BigInt.one << 52;
  if ((high & 0x80000000) != 0) coefficient = -coefficient;
  return (coefficient, exponent);
}

List<Point2>? _transformPolygon(
  List<Point2> local,
  ObjectEnvelope object,
  ShapeWorkBudget budget,
) {
  final page = <Point2>[];
  for (final point in local) {
    if (!budget.charge()) return null;
    final transformed = object.transform.applyToPoint(point);
    if (transformed is! Ok<Point2, StructuredFailure>) return null;
    page.add(transformed.value);
  }
  return List.unmodifiable(page);
}

Rect2? _polygonsBounds(List<List<Point2>> polygons, ShapeWorkBudget budget) {
  if (polygons.isEmpty || polygons.first.isEmpty) return null;
  var left = polygons.first.first.x;
  var right = left;
  var top = polygons.first.first.y;
  var bottom = top;
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

bool _onSegment(Point2 a, Point2 b, Point2 p) =>
    p.x >= math.min(a.x, b.x) &&
    p.x <= math.max(a.x, b.x) &&
    p.y >= math.min(a.y, b.y) &&
    p.y <= math.max(a.y, b.y);

bool _rectanglesIntersect(Rect2 first, Rect2 second) =>
    first.left <= second.right &&
    first.right >= second.left &&
    first.top <= second.bottom &&
    first.bottom >= second.top;

StructuredFailure _failureFor(ShapeWorkBudget budget) =>
    _failure(budget.exhausted ? 'work_limit' : 'numeric_uncertain');

Point2 _point(double x, double y) =>
    (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;
Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
            as Ok<Rect2, StructuredFailure>)
        .value;

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.shape_hit_testing.$leaf',
  category: leaf == 'work_limit'
      ? FailureCategory.resource
      : FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Shape hit testing is invalid or unavailable.',
);
