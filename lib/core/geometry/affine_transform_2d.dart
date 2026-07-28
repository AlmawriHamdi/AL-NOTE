// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import 'geometry_values.dart';
import 'transform_operations.dart';

/// The inclusive scale-relative determinant bound for affine inversion.
///
/// For linear coefficients `a`, `b`, `c`, and `d`, each coefficient is divided
/// by their maximum absolute magnitude before the determinant is calculated.
/// The resulting magnitude must be at least this value.
const double minimumNormalizedAffineDeterminant = 1e-10;

/// An immutable finite invertible affine transform in page space.
///
/// There is no public raw-matrix constructor. Instances originate from a
/// controlled [TransformOperation2D], composition, or inversion.
///
/// Numerical conditioning is scale-relative. If `m` is the maximum absolute
/// linear coefficient, the transform requires
/// `|(a / m)(d / m) - (b / m)(c / m)|` to be at least
/// [minimumNormalizedAffineDeterminant]. Normalizing before multiplication
/// prevents coefficient squaring from overflowing or underflowing. The same
/// criterion is applied to the calculated inverse, so every accepted transform
/// and its inverse satisfy the documented conditioning boundary.
final class AffineTransform2D {
  const AffineTransform2D._({
    required double m00,
    required double m01,
    required double m10,
    required double m11,
    required double tx,
    required double ty,
    required double determinant,
  }) : _m00 = m00,
       _m01 = m01,
       _m10 = m10,
       _m11 = m11,
       _tx = tx,
       _ty = ty,
       _determinant = determinant;

  final double _m00;
  final double _m01;
  final double _m10;
  final double _m11;
  final double _tx;
  final double _ty;
  final double _determinant;

  /// Restores six authoritative coefficients from persistent storage.
  ///
  /// The fixed order is `m00`, `m01`, `m10`, `m11`, `tx`, `ty`. This is a
  /// storage-only bridge: it applies the same finite, positive-determinant,
  /// representable-inverse, non-reflection, and conditioning checks as every
  /// other construction path. It is not an unrestricted raw-matrix constructor.
  static Result<AffineTransform2D, StructuredFailure> restoreFromStorage(
    List<double> coefficients,
  ) {
    if (coefficients.length != 6) {
      return Err<AffineTransform2D, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.invalid_persisted_transform',
          message:
              'A persisted affine transform must contain six coefficients.',
        ),
      );
    }
    return _validated(
      m00: coefficients[0],
      m01: coefficients[1],
      m10: coefficients[2],
      m11: coefficients[3],
      tx: coefficients[4],
      ty: coefficients[5],
    );
  }

  /// The exact authoritative coefficients in persistent storage order.
  ///
  /// The returned list is immutable and ordered as `m00`, `m01`, `m10`,
  /// `m11`, `tx`, `ty`.
  List<double> get storageCoefficients =>
      List<double>.unmodifiable(<double>[_m00, _m01, _m10, _m11, _tx, _ty]);

  /// Creates an affine transform from one controlled [operation].
  static Result<AffineTransform2D, StructuredFailure> fromOperation(
    TransformOperation2D operation,
  ) {
    switch (operation) {
      case IdentityTransformOperation2D():
        return _validated(m00: 1, m01: 0, m10: 0, m11: 1, tx: 0, ty: 0);
      case TranslationTransformOperation2D(:final offset):
        return _validated(
          m00: 1,
          m01: 0,
          m10: 0,
          m11: 1,
          tx: offset.x,
          ty: offset.y,
        );
      case RotationTransformOperation2D(:final radians, :final pivot):
        final cosine = math.cos(radians);
        final sine = math.sin(radians);
        return _validated(
          m00: cosine,
          m01: -sine,
          m10: sine,
          m11: cosine,
          tx: pivot.x - cosine * pivot.x + sine * pivot.y,
          ty: pivot.y - sine * pivot.x - cosine * pivot.y,
        );
      case ScaleTransformOperation2D(
        :final scaleX,
        :final scaleY,
        :final pivot,
      ):
        return _validated(
          m00: scaleX,
          m01: 0,
          m10: 0,
          m11: scaleY,
          tx: pivot.x * (1 - scaleX),
          ty: pivot.y * (1 - scaleY),
        );
    }
  }

  /// The finite determinant of the transform.
  double get determinant => _determinant;

  /// Applies this transform to [point].
  Result<Point2, StructuredFailure> applyToPoint(Point2 point) => Point2.create(
    x: _m00 * point.x + _m01 * point.y + _tx,
    y: _m10 * point.x + _m11 * point.y + _ty,
  );

  /// Applies only the linear portion of this transform to [vector].
  Result<Vector2, StructuredFailure> applyToVector(Vector2 vector) =>
      Vector2.create(
        x: _m00 * vector.x + _m01 * vector.y,
        y: _m10 * vector.x + _m11 * vector.y,
      );

  /// Composes this transform with [second].
  ///
  /// `first.then(second)` applies `first` to a point and then applies `second`
  /// to that result.
  Result<AffineTransform2D, StructuredFailure> then(AffineTransform2D second) =>
      _validated(
        m00: second._m00 * _m00 + second._m01 * _m10,
        m01: second._m00 * _m01 + second._m01 * _m11,
        m10: second._m10 * _m00 + second._m11 * _m10,
        m11: second._m10 * _m01 + second._m11 * _m11,
        tx: second._m00 * _tx + second._m01 * _ty + second._tx,
        ty: second._m10 * _tx + second._m11 * _ty + second._ty,
      );

  /// Returns the finite representable inverse.
  Result<AffineTransform2D, StructuredFailure> inverse() {
    final inverseDeterminant = 1 / _determinant;
    final inverseM00 = _m11 * inverseDeterminant;
    final inverseM01 = -_m01 * inverseDeterminant;
    final inverseM10 = -_m10 * inverseDeterminant;
    final inverseM11 = _m00 * inverseDeterminant;
    return Ok<AffineTransform2D, StructuredFailure>(
      AffineTransform2D._(
        m00: inverseM00,
        m01: inverseM01,
        m10: inverseM10,
        m11: inverseM11,
        tx: -(inverseM00 * _tx + inverseM01 * _ty),
        ty: -(inverseM10 * _tx + inverseM11 * _ty),
        determinant: inverseDeterminant,
      ),
    );
  }

  /// Compares all affine coefficients using an explicit finite positive
  /// [tolerance].
  Result<bool, StructuredFailure> approximatelyEquals(
    AffineTransform2D other, {
    required double tolerance,
  }) {
    if (!tolerance.isFinite || tolerance <= 0) {
      return Err<bool, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.invalid_tolerance',
          message:
              'Approximate-comparison tolerance must be finite and positive.',
        ),
      );
    }
    return Ok<bool, StructuredFailure>(
      (_m00 - other._m00).abs() <= tolerance &&
          (_m01 - other._m01).abs() <= tolerance &&
          (_m10 - other._m10).abs() <= tolerance &&
          (_m11 - other._m11).abs() <= tolerance &&
          (_tx - other._tx).abs() <= tolerance &&
          (_ty - other._ty).abs() <= tolerance,
    );
  }

  static Result<AffineTransform2D, StructuredFailure> _validated({
    required double m00,
    required double m01,
    required double m10,
    required double m11,
    required double tx,
    required double ty,
  }) {
    if (!m00.isFinite ||
        !m01.isFinite ||
        !m10.isFinite ||
        !m11.isFinite ||
        !tx.isFinite ||
        !ty.isFinite) {
      return Err<AffineTransform2D, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.non_finite_transform',
          message: 'Affine transform coefficients must remain finite.',
        ),
      );
    }
    final determinant = m00 * m11 - m01 * m10;
    if (!determinant.isFinite || determinant == 0) {
      return Err<AffineTransform2D, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.non_invertible_transform',
          message: 'Affine determinant must remain finite and nonzero.',
        ),
      );
    }
    if (determinant < 0) {
      return Err<AffineTransform2D, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.reflection_not_supported',
          message: 'Affine reflections are not supported.',
        ),
      );
    }
    final inverseDeterminant = 1 / determinant;
    final inverseM00 = m11 * inverseDeterminant;
    final inverseM01 = -m01 * inverseDeterminant;
    final inverseM10 = -m10 * inverseDeterminant;
    final inverseM11 = m00 * inverseDeterminant;
    final inverseTx = -(inverseM00 * tx + inverseM01 * ty);
    final inverseTy = -(inverseM10 * tx + inverseM11 * ty);
    if (!inverseDeterminant.isFinite ||
        !inverseM00.isFinite ||
        !inverseM01.isFinite ||
        !inverseM10.isFinite ||
        !inverseM11.isFinite ||
        !inverseTx.isFinite ||
        !inverseTy.isFinite) {
      return Err<AffineTransform2D, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.non_representable_inverse',
          message: 'The affine inverse must be finitely representable.',
        ),
      );
    }
    if (_normalizedDeterminantMagnitude(m00, m01, m10, m11) <
        minimumNormalizedAffineDeterminant) {
      return Err<AffineTransform2D, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.ill_conditioned_transform',
          message:
              'The affine linear matrix is too ill-conditioned to invert '
              'reliably.',
        ),
      );
    }
    if (_normalizedDeterminantMagnitude(
          inverseM00,
          inverseM01,
          inverseM10,
          inverseM11,
        ) <
        minimumNormalizedAffineDeterminant) {
      return Err<AffineTransform2D, StructuredFailure>(
        _affineFailure(
          code: 'core.geometry.ill_conditioned_transform',
          message:
              'The affine inverse is too ill-conditioned for reliable '
              'coordinate recovery.',
        ),
      );
    }
    return Ok<AffineTransform2D, StructuredFailure>(
      AffineTransform2D._(
        m00: m00,
        m01: m01,
        m10: m10,
        m11: m11,
        tx: tx,
        ty: ty,
        determinant: determinant,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AffineTransform2D &&
          other._m00 == _m00 &&
          other._m01 == _m01 &&
          other._m10 == _m10 &&
          other._m11 == _m11 &&
          other._tx == _tx &&
          other._ty == _ty;

  @override
  int get hashCode => Object.hash(_m00, _m01, _m10, _m11, _tx, _ty);
}

double _normalizedDeterminantMagnitude(
  double m00,
  double m01,
  double m10,
  double m11,
) {
  final maximumMagnitude = math.max(
    math.max(m00.abs(), m01.abs()),
    math.max(m10.abs(), m11.abs()),
  );
  if (maximumMagnitude == 0) {
    return 0;
  }
  final normalizedM00 = m00 / maximumMagnitude;
  final normalizedM01 = m01 / maximumMagnitude;
  final normalizedM10 = m10 / maximumMagnitude;
  final normalizedM11 = m11 / maximumMagnitude;
  return (normalizedM00 * normalizedM11 - normalizedM01 * normalizedM10).abs();
}

StructuredFailure _affineFailure({
  required String code,
  required String message,
}) => StructuredFailure(
  code: code,
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: message,
);
