// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import 'geometry_values.dart';

/// The minimum accepted positive scale and determinant magnitude.
const double minimumAffineMagnitude = 1e-12;

/// A controlled page-space operation from which an affine transform may be
/// created.
///
/// The sealed variants are the complete public operation set. Raw matrices,
/// reflection, skew, and perspective operations are intentionally absent.
sealed class TransformOperation2D {
  /// Creates a controlled operation for use by the sealed variants.
  const TransformOperation2D();
}

/// The identity transform operation.
final class IdentityTransformOperation2D extends TransformOperation2D {
  /// Creates an identity operation.
  const IdentityTransformOperation2D();
}

/// A page-space translation operation.
final class TranslationTransformOperation2D extends TransformOperation2D {
  /// Creates a translation by a validated finite [offset].
  const TranslationTransformOperation2D(this.offset);

  /// The finite page-space translation vector.
  final Vector2 offset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TranslationTransformOperation2D && other.offset == offset;

  @override
  int get hashCode => offset.hashCode;
}

/// A rotation in radians about a page-space pivot.
final class RotationTransformOperation2D extends TransformOperation2D {
  const RotationTransformOperation2D._({
    required this.radians,
    required this.pivot,
  });

  /// Creates a rotation from finite [radians] about [pivot].
  static Result<RotationTransformOperation2D, StructuredFailure> create({
    required double radians,
    required Point2 pivot,
  }) {
    if (!radians.isFinite) {
      return Err<RotationTransformOperation2D, StructuredFailure>(
        _transformFailure(
          code: 'core.geometry.non_finite_rotation',
          message: 'Rotation radians must be finite.',
        ),
      );
    }
    return Ok<RotationTransformOperation2D, StructuredFailure>(
      RotationTransformOperation2D._(radians: radians, pivot: pivot),
    );
  }

  /// The finite page-space angle in radians using mathematical rotation.
  final double radians;

  /// The page-space pivot held fixed by the rotation.
  final Point2 pivot;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RotationTransformOperation2D &&
          other.radians == radians &&
          other.pivot == pivot;

  @override
  int get hashCode => Object.hash(radians, pivot);
}

/// Strictly positive independent scaling about a page-space pivot.
final class ScaleTransformOperation2D extends TransformOperation2D {
  const ScaleTransformOperation2D._({
    required this.scaleX,
    required this.scaleY,
    required this.pivot,
  });

  /// Creates positive scaling about [pivot].
  ///
  /// Both scale values and their determinant must be finite and have magnitude
  /// greater than [minimumAffineMagnitude].
  static Result<ScaleTransformOperation2D, StructuredFailure> create({
    required double scaleX,
    required double scaleY,
    required Point2 pivot,
  }) {
    if (!scaleX.isFinite || !scaleY.isFinite) {
      return Err<ScaleTransformOperation2D, StructuredFailure>(
        _transformFailure(
          code: 'core.geometry.non_finite_scale',
          message: 'Scale values must be finite.',
        ),
      );
    }
    if (scaleX <= minimumAffineMagnitude || scaleY <= minimumAffineMagnitude) {
      return Err<ScaleTransformOperation2D, StructuredFailure>(
        _transformFailure(
          code: 'core.geometry.invalid_scale',
          message: 'Scale values must be strictly positive and above epsilon.',
        ),
      );
    }
    final determinant = scaleX * scaleY;
    if (!determinant.isFinite || determinant.abs() <= minimumAffineMagnitude) {
      return Err<ScaleTransformOperation2D, StructuredFailure>(
        _transformFailure(
          code: 'core.geometry.non_invertible_transform',
          message: 'Scale determinant must be finite and above epsilon.',
        ),
      );
    }
    return Ok<ScaleTransformOperation2D, StructuredFailure>(
      ScaleTransformOperation2D._(scaleX: scaleX, scaleY: scaleY, pivot: pivot),
    );
  }

  /// The strictly positive horizontal scale.
  final double scaleX;

  /// The strictly positive vertical scale.
  final double scaleY;

  /// The page-space pivot held fixed by the scaling.
  final Point2 pivot;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScaleTransformOperation2D &&
          other.scaleX == scaleX &&
          other.scaleY == scaleY &&
          other.pivot == pivot;

  @override
  int get hashCode => Object.hash(scaleX, scaleY, pivot);
}

StructuredFailure _transformFailure({
  required String code,
  required String message,
}) => StructuredFailure(
  code: code,
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: message,
);
