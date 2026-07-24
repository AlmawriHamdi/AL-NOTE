// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('finite geometry validation', () {
    test('rejects every non-finite point and vector component', () {
      for (final invalid in <double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          Point2.create(x: invalid, y: 0),
          isA<Err<Point2, StructuredFailure>>(),
        );
        expect(
          Point2.create(x: 0, y: invalid),
          isA<Err<Point2, StructuredFailure>>(),
        );
        expect(
          Vector2.create(x: invalid, y: 0),
          isA<Err<Vector2, StructuredFailure>>(),
        );
        expect(
          Vector2.create(x: 0, y: invalid),
          isA<Err<Vector2, StructuredFailure>>(),
        );
      }
    });

    test('rejects non-finite sizes and rectangle edges', () {
      expect(
        Size2.create(width: double.infinity, height: 1),
        isA<Err<Size2, StructuredFailure>>(),
      );
      expect(
        Rect2.fromEdges(left: 0, top: 0, right: double.nan, bottom: 1),
        isA<Err<Rect2, StructuredFailure>>(),
      );
      expect(
        Rect2.fromEdges(
          left: -double.maxFinite,
          top: 0,
          right: double.maxFinite,
          bottom: 1,
        ),
        isA<Err<Rect2, StructuredFailure>>(),
      );
    });
  });

  group('Point2 and Vector2', () {
    test('translate points and calculate vectors', () {
      final point = _point(2, 3);
      final vector = _vector(4, -1);

      final translated =
          (point.translatedBy(vector) as Ok<Point2, StructuredFailure>).value;
      final displacement =
          (point.vectorTo(translated) as Ok<Vector2, StructuredFailure>).value;

      expect(translated, _point(6, 2));
      expect(displacement, vector);
    });

    test('add and scale vectors while preserving finite results', () {
      final first = _vector(2, 3);
      final second = _vector(-1, 4);

      expect(
        (first.addedTo(second) as Ok<Vector2, StructuredFailure>).value,
        _vector(1, 7),
      );
      expect(
        (first.scaledBy(2) as Ok<Vector2, StructuredFailure>).value,
        _vector(4, 6),
      );
      expect(
        first.scaledBy(double.infinity),
        isA<Err<Vector2, StructuredFailure>>(),
      );
      expect(
        _point(double.maxFinite, 0).translatedBy(_vector(double.maxFinite, 0)),
        isA<Err<Point2, StructuredFailure>>(),
      );
    });
  });

  group('Size2 and Rect2', () {
    test('accepts zero sizes and rejects negative dimensions', () {
      final empty = _size(0, 10);

      expect(empty.isEmpty, isTrue);
      expect(
        Size2.create(width: -0.1, height: 1),
        isA<Err<Size2, StructuredFailure>>(),
      );
      expect(
        Size2.create(width: 1, height: -0.1),
        isA<Err<Size2, StructuredFailure>>(),
      );
    });

    test('rejects inverted rectangles', () {
      expect(
        Rect2.fromEdges(left: 2, top: 0, right: 1, bottom: 1),
        isA<Err<Rect2, StructuredFailure>>(),
      );
      expect(
        Rect2.fromEdges(left: 0, top: 2, right: 1, bottom: 1),
        isA<Err<Rect2, StructuredFailure>>(),
      );
    });

    test('exposes finite edges, points, size, and containment', () {
      final rectangle =
          (Rect2.fromOriginAndSize(origin: _point(2, 3), size: _size(4, 5))
                  as Ok<Rect2, StructuredFailure>)
              .value;

      expect(rectangle.left, 2);
      expect(rectangle.top, 3);
      expect(rectangle.right, 6);
      expect(rectangle.bottom, 8);
      expect(rectangle.topLeft, _point(2, 3));
      expect(rectangle.bottomRight, _point(6, 8));
      expect(rectangle.size, _size(4, 5));
      expect(rectangle.contains(_point(4, 4)), isTrue);
      expect(rectangle.contains(_point(7, 4)), isFalse);
    });
  });

  group('geometry equality', () {
    test('exact equality does not use approximate semantics', () {
      final exact = _point(1, 2);
      final same = _point(1, 2);
      final nearby = _point(1.0000001, 2);

      expect(exact, same);
      expect(exact.hashCode, same.hashCode);
      expect(exact, isNot(nearby));
    });

    test('approximate comparison requires an explicit valid tolerance', () {
      final first = _point(1, 2);
      final nearby = _point(1.0000001, 1.9999999);

      expect(
        (first.approximatelyEquals(nearby, tolerance: 0.000001)
                as Ok<bool, StructuredFailure>)
            .value,
        isTrue,
      );
      expect(
        (first.approximatelyEquals(nearby, tolerance: 0.00000001)
                as Ok<bool, StructuredFailure>)
            .value,
        isFalse,
      );
      for (final invalid in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          first.approximatelyEquals(nearby, tolerance: invalid),
          isA<Err<bool, StructuredFailure>>(),
        );
      }
    });

    test('vectors, sizes, and rectangles support explicit approximation', () {
      expect(
        (_vector(
                  1,
                  2,
                ).approximatelyEquals(_vector(1.001, 2.001), tolerance: 0.01)
                as Ok<bool, StructuredFailure>)
            .value,
        isTrue,
      );
      expect(
        (_size(1, 2).approximatelyEquals(_size(1.001, 2.001), tolerance: 0.01)
                as Ok<bool, StructuredFailure>)
            .value,
        isTrue,
      );
      expect(
        (_rect(0, 0, 1, 1).approximatelyEquals(
                  _rect(0.001, 0.001, 1.001, 1.001),
                  tolerance: 0.01,
                )
                as Ok<bool, StructuredFailure>)
            .value,
        isTrue,
      );
    });
  });
}

Point2 _point(double x, double y) =>
    (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;

Vector2 _vector(double x, double y) =>
    (Vector2.create(x: x, y: y) as Ok<Vector2, StructuredFailure>).value;

Size2 _size(double width, double height) =>
    (Size2.create(width: width, height: height) as Ok<Size2, StructuredFailure>)
        .value;

Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
            as Ok<Rect2, StructuredFailure>)
        .value;
