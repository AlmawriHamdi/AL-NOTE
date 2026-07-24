// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('controlled transform operations', () {
    test(
      'exposes exactly identity, translation, rotation, and scale variants',
      () {
        final operations = <TransformOperation2D>[
          const IdentityTransformOperation2D(),
          TranslationTransformOperation2D(_vector(1, 2)),
          _rotation(0, _point(0, 0)),
          _scale(1, 1, _point(0, 0)),
        ];

        expect(
          operations.map((operation) => operation.runtimeType).toSet(),
          <Type>{
            IdentityTransformOperation2D,
            TranslationTransformOperation2D,
            RotationTransformOperation2D,
            ScaleTransformOperation2D,
          },
        );
      },
    );

    test('rejects non-finite rotation and scale values', () {
      expect(
        RotationTransformOperation2D.create(
          radians: double.nan,
          pivot: _point(0, 0),
        ),
        isA<Err<RotationTransformOperation2D, StructuredFailure>>(),
      );
      expect(
        ScaleTransformOperation2D.create(
          scaleX: double.infinity,
          scaleY: 1,
          pivot: _point(0, 0),
        ),
        isA<Err<ScaleTransformOperation2D, StructuredFailure>>(),
      );
    });

    test('rejects reflection, zero, and lower-bound-or-smaller scales', () {
      for (final invalid in <double>[
        -1,
        0,
        minimumScaleValue,
        minimumScaleValue / 2,
      ]) {
        expect(
          ScaleTransformOperation2D.create(
            scaleX: invalid,
            scaleY: 1,
            pivot: _point(0, 0),
          ),
          isA<Err<ScaleTransformOperation2D, StructuredFailure>>(),
        );
      }
    });

    test('accepts scale values whose nonzero determinant is below 1e-12', () {
      final result = ScaleTransformOperation2D.create(
        scaleX: 1e-7,
        scaleY: 1e-7,
        pivot: _point(0, 0),
      );

      expect(result, isA<Ok<ScaleTransformOperation2D, StructuredFailure>>());
    });
  });

  group('AffineTransform2D', () {
    test('identity preserves points and vectors', () {
      final identity = _transform(const IdentityTransformOperation2D());

      expect(_apply(identity, _point(2, 3)), _point(2, 3));
      expect(
        (identity.applyToVector(_vector(4, 5))
                as Ok<Vector2, StructuredFailure>)
            .value,
        _vector(4, 5),
      );
      expect(identity.determinant, 1);
    });

    test('translation moves points but not vectors', () {
      final translation = _transform(
        TranslationTransformOperation2D(_vector(4, -2)),
      );

      expect(_apply(translation, _point(1, 3)), _point(5, 1));
      expect(
        (translation.applyToVector(_vector(1, 3))
                as Ok<Vector2, StructuredFailure>)
            .value,
        _vector(1, 3),
      );
    });

    test('rotation keeps its pivot fixed and rotates around it', () {
      final pivot = _point(1, 1);
      final rotation = _transform(_rotation(math.pi / 2, pivot));

      _expectPointNear(_apply(rotation, pivot), pivot);
      _expectPointNear(_apply(rotation, _point(2, 1)), _point(1, 2));
    });

    test('positive scaling keeps its pivot fixed and scales offsets', () {
      final pivot = _point(1, 1);
      final scale = _transform(_scale(2, 3, pivot));

      expect(_apply(scale, pivot), pivot);
      expect(_apply(scale, _point(2, 3)), _point(3, 7));
    });

    test('first.then(second) applies first and then second', () {
      final translation = _transform(
        TranslationTransformOperation2D(_vector(1, 0)),
      );
      final scale = _transform(_scale(2, 2, _point(0, 0)));
      final translationThenScale =
          (translation.then(scale) as Ok<AffineTransform2D, StructuredFailure>)
              .value;
      final scaleThenTranslation =
          (scale.then(translation) as Ok<AffineTransform2D, StructuredFailure>)
              .value;

      expect(_apply(translationThenScale, _point(1, 1)), _point(4, 2));
      expect(_apply(scaleThenTranslation, _point(1, 1)), _point(3, 2));
    });

    test('inverse provides deterministic point round trips', () {
      final translation = _transform(
        TranslationTransformOperation2D(_vector(7, -3)),
      );
      final rotation = _transform(_rotation(math.pi / 3, _point(2, 5)));
      final scale = _transform(_scale(2, 0.5, _point(-1, 4)));
      final first =
          (translation.then(rotation)
                  as Ok<AffineTransform2D, StructuredFailure>)
              .value;
      final combined =
          (first.then(scale) as Ok<AffineTransform2D, StructuredFailure>).value;
      final inverse =
          (combined.inverse() as Ok<AffineTransform2D, StructuredFailure>)
              .value;
      final original = _point(11, -8);

      final transformed = _apply(combined, original);
      final roundTrip = _apply(inverse, transformed);

      _expectPointNear(roundTrip, original);
    });

    test('uniform scale 1e-7 is accepted, invertible, and round-trips', () {
      final transform = _transform(_scale(1e-7, 1e-7, _point(0, 0)));
      final inverse =
          (transform.inverse() as Ok<AffineTransform2D, StructuredFailure>)
              .value;
      final point = _point(3, -4);

      expect(transform.determinant, closeTo(1e-14, 1e-28));
      _expectPointNear(_apply(inverse, _apply(transform, point)), point);
    });

    test('uniform scale 1e7 and its inverse are accepted and round-trip', () {
      final transform = _transform(_scale(1e7, 1e7, _point(0, 0)));
      final inverse =
          (transform.inverse() as Ok<AffineTransform2D, StructuredFailure>)
              .value;
      final point = _point(3, -4);

      expect(inverse.determinant, closeTo(1e-14, 1e-28));
      _expectPointNear(_apply(inverse, _apply(transform, point)), point);
    });

    test('composition rejects once its inverse is not representable', () {
      final tiny = _transform(_scale(1e-7, 1e-7, _point(0, 0)));
      var current = tiny;
      Result<AffineTransform2D, StructuredFailure>? rejected;

      for (var index = 0; index < 32; index += 1) {
        final result = current.then(tiny);
        if (result is Err<AffineTransform2D, StructuredFailure>) {
          rejected = result;
          break;
        }
        current = (result as Ok<AffineTransform2D, StructuredFailure>).value;
      }

      final failure =
          (rejected as Err<AffineTransform2D, StructuredFailure>).error;
      expect(failure.code, 'core.geometry.non_representable_inverse');
    });

    test('rejects a transform without a finite representable inverse', () {
      final operation = _scale(1e-11, 1, _point(double.maxFinite, 0));

      final result = AffineTransform2D.fromOperation(operation);

      final failure =
          (result as Err<AffineTransform2D, StructuredFailure>).error;
      expect(failure.code, 'core.geometry.non_representable_inverse');
    });

    test('application rejects non-finite arithmetic results', () {
      final translation = _transform(
        TranslationTransformOperation2D(_vector(double.maxFinite, 0)),
      );

      expect(
        translation.applyToPoint(_point(double.maxFinite, 0)),
        isA<Err<Point2, StructuredFailure>>(),
      );
    });

    test('exact equality stays exact and approximation is explicit', () {
      final exact = _transform(TranslationTransformOperation2D(_vector(1, 2)));
      final same = _transform(TranslationTransformOperation2D(_vector(1, 2)));
      final nearby = _transform(
        TranslationTransformOperation2D(_vector(1.000001, 2)),
      );

      expect(exact, same);
      expect(exact.hashCode, same.hashCode);
      expect(exact, isNot(nearby));
      expect(
        (exact.approximatelyEquals(nearby, tolerance: 0.00001)
                as Ok<bool, StructuredFailure>)
            .value,
        isTrue,
      );
    });

    test('approximation rejects nonpositive and non-finite tolerances', () {
      final identity = _transform(const IdentityTransformOperation2D());

      for (final invalid in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          identity.approximatelyEquals(identity, tolerance: invalid),
          isA<Err<bool, StructuredFailure>>(),
        );
      }
    });
  });
}

Point2 _point(double x, double y) =>
    (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;

Vector2 _vector(double x, double y) =>
    (Vector2.create(x: x, y: y) as Ok<Vector2, StructuredFailure>).value;

RotationTransformOperation2D _rotation(double radians, Point2 pivot) =>
    (RotationTransformOperation2D.create(radians: radians, pivot: pivot)
            as Ok<RotationTransformOperation2D, StructuredFailure>)
        .value;

ScaleTransformOperation2D _scale(double scaleX, double scaleY, Point2 pivot) =>
    (ScaleTransformOperation2D.create(
              scaleX: scaleX,
              scaleY: scaleY,
              pivot: pivot,
            )
            as Ok<ScaleTransformOperation2D, StructuredFailure>)
        .value;

AffineTransform2D _transform(TransformOperation2D operation) =>
    (AffineTransform2D.fromOperation(operation)
            as Ok<AffineTransform2D, StructuredFailure>)
        .value;

Point2 _apply(AffineTransform2D transform, Point2 point) =>
    (transform.applyToPoint(point) as Ok<Point2, StructuredFailure>).value;

void _expectPointNear(Point2 actual, Point2 expected) {
  expect(
    (actual.approximatelyEquals(expected, tolerance: 1e-10)
            as Ok<bool, StructuredFailure>)
        .value,
    isTrue,
  );
}
