// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// An immutable finite point in page space.
final class Point2 {
  const Point2._(this.x, this.y);

  /// Creates a page-space point from finite coordinates.
  static Result<Point2, StructuredFailure> create({
    required double x,
    required double y,
  }) {
    if (!x.isFinite || !y.isFinite) {
      return Err<Point2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.non_finite_point',
          message: 'Point coordinates must be finite.',
        ),
      );
    }
    return Ok<Point2, StructuredFailure>(Point2._(x, y));
  }

  /// The page-space horizontal coordinate.
  final double x;

  /// The page-space vertical coordinate.
  final double y;

  /// Returns this point translated by [vector].
  Result<Point2, StructuredFailure> translatedBy(Vector2 vector) =>
      create(x: x + vector.x, y: y + vector.y);

  /// Returns the vector from this point to [other].
  Result<Vector2, StructuredFailure> vectorTo(Point2 other) =>
      Vector2.create(x: other.x - x, y: other.y - y);

  /// Compares coordinates using an explicit finite positive [tolerance].
  Result<bool, StructuredFailure> approximatelyEquals(
    Point2 other, {
    required double tolerance,
  }) {
    final toleranceFailure = _validateTolerance(tolerance);
    if (toleranceFailure != null) {
      return Err<bool, StructuredFailure>(toleranceFailure);
    }
    return Ok<bool, StructuredFailure>(
      (x - other.x).abs() <= tolerance && (y - other.y).abs() <= tolerance,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Point2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point2($x, $y)';
}

/// An immutable finite page-space vector.
final class Vector2 {
  const Vector2._(this.x, this.y);

  /// Creates a vector from finite components.
  static Result<Vector2, StructuredFailure> create({
    required double x,
    required double y,
  }) {
    if (!x.isFinite || !y.isFinite) {
      return Err<Vector2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.non_finite_vector',
          message: 'Vector components must be finite.',
        ),
      );
    }
    return Ok<Vector2, StructuredFailure>(Vector2._(x, y));
  }

  /// The horizontal vector component.
  final double x;

  /// The vertical vector component.
  final double y;

  /// Returns the sum of this vector and [other].
  Result<Vector2, StructuredFailure> addedTo(Vector2 other) =>
      create(x: x + other.x, y: y + other.y);

  /// Returns this vector multiplied by finite [factor].
  Result<Vector2, StructuredFailure> scaledBy(double factor) {
    if (!factor.isFinite) {
      return Err<Vector2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.non_finite_scale_factor',
          message: 'A vector scale factor must be finite.',
        ),
      );
    }
    return create(x: x * factor, y: y * factor);
  }

  /// Compares components using an explicit finite positive [tolerance].
  Result<bool, StructuredFailure> approximatelyEquals(
    Vector2 other, {
    required double tolerance,
  }) {
    final toleranceFailure = _validateTolerance(tolerance);
    if (toleranceFailure != null) {
      return Err<bool, StructuredFailure>(toleranceFailure);
    }
    return Ok<bool, StructuredFailure>(
      (x - other.x).abs() <= tolerance && (y - other.y).abs() <= tolerance,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Vector2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vector2($x, $y)';
}

/// An immutable finite nonnegative page-space size.
final class Size2 {
  const Size2._(this.width, this.height);

  /// Creates a finite size with nonnegative dimensions.
  static Result<Size2, StructuredFailure> create({
    required double width,
    required double height,
  }) {
    if (!width.isFinite || !height.isFinite) {
      return Err<Size2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.non_finite_size',
          message: 'Size dimensions must be finite.',
        ),
      );
    }
    if (width < 0 || height < 0) {
      return Err<Size2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.negative_size',
          message: 'Size dimensions must be nonnegative.',
        ),
      );
    }
    return Ok<Size2, StructuredFailure>(Size2._(width, height));
  }

  /// The nonnegative page-space width.
  final double width;

  /// The nonnegative page-space height.
  final double height;

  /// Whether either dimension is zero.
  bool get isEmpty => width == 0 || height == 0;

  /// Compares dimensions using an explicit finite positive [tolerance].
  Result<bool, StructuredFailure> approximatelyEquals(
    Size2 other, {
    required double tolerance,
  }) {
    final toleranceFailure = _validateTolerance(tolerance);
    if (toleranceFailure != null) {
      return Err<bool, StructuredFailure>(toleranceFailure);
    }
    return Ok<bool, StructuredFailure>(
      (width - other.width).abs() <= tolerance &&
          (height - other.height).abs() <= tolerance,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Size2 && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'Size2($width, $height)';
}

/// An immutable finite axis-aligned rectangle in page space.
final class Rect2 {
  const Rect2._({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Creates a rectangle from finite, non-inverted page-space edges.
  static Result<Rect2, StructuredFailure> fromEdges({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    if (!left.isFinite ||
        !top.isFinite ||
        !right.isFinite ||
        !bottom.isFinite) {
      return Err<Rect2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.non_finite_rectangle',
          message: 'Rectangle edges must be finite.',
        ),
      );
    }
    if (right < left || bottom < top) {
      return Err<Rect2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.inverted_rectangle',
          message: 'Rectangle edges must not be inverted.',
        ),
      );
    }
    final width = right - left;
    final height = bottom - top;
    if (!width.isFinite || !height.isFinite) {
      return Err<Rect2, StructuredFailure>(
        _geometryFailure(
          code: 'core.geometry.non_finite_rectangle_extent',
          message: 'Rectangle extents must be finite.',
        ),
      );
    }
    return Ok<Rect2, StructuredFailure>(
      Rect2._(left: left, top: top, right: right, bottom: bottom),
    );
  }

  /// Creates a rectangle from a finite page-space [origin] and [size].
  static Result<Rect2, StructuredFailure> fromOriginAndSize({
    required Point2 origin,
    required Size2 size,
  }) => fromEdges(
    left: origin.x,
    top: origin.y,
    right: origin.x + size.width,
    bottom: origin.y + size.height,
  );

  /// The left page-space edge.
  final double left;

  /// The top page-space edge.
  final double top;

  /// The right page-space edge.
  final double right;

  /// The bottom page-space edge.
  final double bottom;

  /// The finite nonnegative width.
  double get width => right - left;

  /// The finite nonnegative height.
  double get height => bottom - top;

  /// The top-left page-space point.
  Point2 get topLeft => Point2._(left, top);

  /// The bottom-right page-space point.
  Point2 get bottomRight => Point2._(right, bottom);

  /// The finite nonnegative rectangle size.
  Size2 get size => Size2._(width, height);

  /// Whether [point] lies on or within every rectangle edge.
  bool contains(Point2 point) =>
      point.x >= left &&
      point.x <= right &&
      point.y >= top &&
      point.y <= bottom;

  /// Compares edges using an explicit finite positive [tolerance].
  Result<bool, StructuredFailure> approximatelyEquals(
    Rect2 other, {
    required double tolerance,
  }) {
    final toleranceFailure = _validateTolerance(tolerance);
    if (toleranceFailure != null) {
      return Err<bool, StructuredFailure>(toleranceFailure);
    }
    return Ok<bool, StructuredFailure>(
      (left - other.left).abs() <= tolerance &&
          (top - other.top).abs() <= tolerance &&
          (right - other.right).abs() <= tolerance &&
          (bottom - other.bottom).abs() <= tolerance,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Rect2 &&
          other.left == left &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Rect2($left, $top, $right, $bottom)';
}

StructuredFailure? _validateTolerance(double tolerance) {
  if (!tolerance.isFinite || tolerance <= 0) {
    return _geometryFailure(
      code: 'core.geometry.invalid_tolerance',
      message: 'Approximate-comparison tolerance must be finite and positive.',
    );
  }
  return null;
}

StructuredFailure _geometryFailure({
  required String code,
  required String message,
}) => StructuredFailure(
  code: code,
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: message,
);
