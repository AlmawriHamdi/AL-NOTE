// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';

final _limits = _ok(
  HandwritingLimits.create(
    maximumStrokes: 8,
    maximumSamplesPerStroke: 16,
    maximumUnknownFields: 8,
    maximumNestingDepth: 8,
    maximumUnknownNodes: 1024,
    maximumCoordinateMagnitude: 10000,
    maximumStrokeWidth: 100,
    maximumAbsoluteTilt: 2,
    maximumAbsoluteOrientation: 7,
  ),
);

void main() {
  test(
    'schema one payload round trips exactly and preserves unknown fields',
    () {
      final payload = _payload(
        unknown: PreservedMap({'future': const PreservedString('safe')}),
      );
      final decoded = _ok(
        HandwritingPayload.decode(payload.encode(), limits: _limits),
      );
      expect(decoded, payload);
      expect(decoded.encode(), payload.encode());
      expect(handwritingObjectTypeKey.value, 'alnote.objects.handwriting');
      expect(handwritingSchemaVersion.value, 1);
    },
  );

  test('samples reject invalid sensors and non-monotonic time', () {
    expect(
      StrokeSample.create(
        position: _point(0, 0),
        timeMicros: 0,
        limits: _limits,
        pressure: 1.1,
      ),
      isA<Err<Object?, Object?>>(),
    );
    final stroke = HandwritingStroke.create(
      id: StrokeId.fromUuid(testUuid(20)),
      style: _style(),
      limits: _limits,
      samples: [_sample(1, 0, 2), _sample(2, 0, 1)],
    );
    expect(stroke, isA<Err<Object?, Object?>>());
  });

  test(
    'payload rejects duplicate stroke identities and protects collections',
    () {
      final stroke = _stroke();
      final input = [stroke];
      final payload = _ok(
        HandwritingPayload.create(strokes: input, limits: _limits),
      );
      input.clear();
      expect(payload.strokes, hasLength(1));
      expect(() => payload.strokes.add(stroke), throwsUnsupportedError);
      expect(
        HandwritingPayload.create(strokes: [stroke, stroke], limits: _limits),
        isA<Err<Object?, Object?>>(),
      );
    },
  );

  test('intrinsic bounds include full visible width and dots', () {
    final dot = _payload(samples: [_sample(10, 20, 0)]);
    expect(dot.bounds.left, 8);
    expect(dot.bounds.right, 12);
    expect(dot.bounds.top, 18);
    expect(dot.bounds.bottom, 22);
  });

  test(
    'definition validates, derives geometry, and duplicates preservation',
    () {
      final definition = HandwritingObjectTypeDefinition(_limits);
      final payload = _payload();
      expect(
        definition
            .validatePayload(payload.encode(), handwritingSchemaVersion)
            .isValid,
        isTrue,
      );
      expect(
        _ok(
          definition.intrinsicGeometry(
            payload.encode(),
            handwritingSchemaVersion,
          ),
        ),
        payload.bounds,
      );
      expect(
        _ok(
          definition.duplicatePayload(
            payload.encode(),
            handwritingSchemaVersion,
            IdentityRemapping(),
          ),
        ),
        payload.encode(),
      );
    },
  );

  test('invalid limits and unsafe numeric magnitudes fail structurally', () {
    expect(
      HandwritingLimits.create(
        maximumStrokes: 1,
        maximumSamplesPerStroke: 1,
        maximumUnknownFields: 1,
        maximumNestingDepth: 1,
        maximumUnknownNodes: 1,
        maximumCoordinateMagnitude: double.infinity,
        maximumStrokeWidth: 1,
        maximumAbsoluteTilt: 1,
        maximumAbsoluteOrientation: 1,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(
      StrokeSample.create(
        position: _point(10001, 0),
        timeMicros: 0,
        limits: _limits,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(
      StrokeStyle.create(
        argb: 0,
        opacity: 1,
        baseWidth: 101,
        pressureInfluence: 0,
        minimumPressureFactor: 0,
        limits: _limits,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(
      StrokeSample.create(
        position: _point(0, 0),
        timeMicros: 0,
        limits: _limits,
        tilt: 2,
        orientation: 7,
      ),
      isA<Ok<Object?, Object?>>(),
    );
  });

  test(
    'nested unknown ceilings apply independently and preserve accepted data',
    () {
      final oversized = PreservedMap({
        for (var index = 0; index < 9; index += 1)
          'field$index': const PreservedString('safe'),
      });
      expect(
        StrokeSample.create(
          position: _point(0, 0),
          timeMicros: 0,
          limits: _limits,
          unknownFields: oversized,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        StrokeStyle.create(
          argb: 0,
          opacity: 1,
          baseWidth: 1,
          pressureInfluence: 0,
          minimumPressureFactor: 0,
          limits: _limits,
          unknownFields: oversized,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        HandwritingStroke.create(
          id: StrokeId.fromUuid(testUuid(99)),
          samples: [_sample(0, 0, 0)],
          style: _style(),
          limits: _limits,
          unknownFields: oversized,
        ),
        isA<Err<Object?, Object?>>(),
      );
      var nested = const PreservedString('leaf') as PreservedData;
      for (var depth = 0; depth < 9; depth += 1) {
        nested = PreservedMap({'nested': nested});
      }
      expect(
        HandwritingPayload.create(
          strokes: [_stroke()],
          limits: _limits,
          unknownFields: PreservedMap({'future': nested}),
        ),
        isA<Err<Object?, Object?>>(),
      );
    },
  );

  test('stroke capture stops before a rejected hostile tail current', () {
    final hostile = _TailIterable<StrokeSample>([_sample(0, 0, 0)]);
    final tight = _ok(
      HandwritingLimits.create(
        maximumStrokes: 1,
        maximumSamplesPerStroke: 1,
        maximumUnknownFields: 1,
        maximumNestingDepth: 2,
        maximumUnknownNodes: 8,
        maximumCoordinateMagnitude: 10,
        maximumStrokeWidth: 10,
        maximumAbsoluteTilt: 2,
        maximumAbsoluteOrientation: 7,
      ),
    );
    expect(
      HandwritingStroke.create(
        id: StrokeId.fromUuid(testUuid(98)),
        samples: hostile,
        style: _style(),
        limits: tight,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(hostile.rejectedCurrentRead, isFalse);
  });

  test('every Object behavior rejects unsupported Handwriting schemas', () {
    final definition = HandwritingObjectTypeDefinition(_limits);
    final unsupported = _ok(SchemaVersion.create(2));
    expect(
      definition.validatePayload(_payload().encode(), unsupported).isValid,
      isFalse,
    );
    expect(
      definition.intrinsicGeometry(_payload().encode(), unsupported),
      isA<Err<Object?, Object?>>(),
    );
    expect(
      definition.resourceReferences(_payload().encode(), unsupported),
      isA<Err<Object?, Object?>>(),
    );
    expect(
      definition.duplicatePayload(
        _payload().encode(),
        unsupported,
        IdentityRemapping(),
      ),
      isA<Err<Object?, Object?>>(),
    );
  });

  test('unknown validation is iterative, node-bounded, and redaction-safe', () {
    HandwritingLimits limits(int nodes, int depth) => _ok(
      HandwritingLimits.create(
        maximumStrokes: 1,
        maximumSamplesPerStroke: 2,
        maximumUnknownFields: 1,
        maximumNestingDepth: depth,
        maximumUnknownNodes: nodes,
        maximumCoordinateMagnitude: 100,
        maximumStrokeWidth: 10,
        maximumAbsoluteTilt: 2,
        maximumAbsoluteOrientation: 7,
      ),
    );

    final exact = PreservedMap({
      'a': PreservedMap({'b': const PreservedString('accepted-secret')}),
    });
    final accepted = HandwritingPayload.create(
      strokes: [_stroke()],
      limits: limits(3, 3),
      unknownFields: exact,
    );
    expect(accepted, isA<Ok<Object?, Object?>>());
    expect(_ok(accepted).unknownFields, exact);
    expect(
      HandwritingPayload.create(
        strokes: [_stroke()],
        limits: limits(2, 3),
        unknownFields: exact,
      ),
      isA<Err<Object?, Object?>>(),
    );

    var deep = const PreservedString('never-expose-this') as PreservedData;
    for (var index = 0; index < 20000; index += 1) {
      deep = PreservedMap({'n': deep});
    }
    final rejected = HandwritingPayload.create(
      strokes: [_stroke()],
      limits: limits(100, 8),
      unknownFields: PreservedMap({'future': deep}),
    );
    expect(rejected, isA<Err<Object?, Object?>>());
    expect(rejected.toString(), isNot(contains('never-expose-this')));
  });

  test('wide unknown data reserves total nodes before accepting a child', () {
    HandwritingLimits limits(int nodes) => _ok(
      HandwritingLimits.create(
        maximumStrokes: 1,
        maximumSamplesPerStroke: 2,
        maximumUnknownFields: 1000,
        maximumNestingDepth: 4,
        maximumUnknownNodes: nodes,
        maximumCoordinateMagnitude: 100,
        maximumStrokeWidth: 10,
        maximumAbsoluteTilt: 2,
        maximumAbsoluteOrientation: 7,
      ),
    );
    final wide = PreservedMap({
      'wide': PreservedList([
        const PreservedString('one'),
        const PreservedString('two'),
        const PreservedString('rejected-tail-secret'),
      ]),
    });
    expect(
      HandwritingPayload.create(
        strokes: [_stroke()],
        limits: limits(5),
        unknownFields: wide,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    final rejected = HandwritingPayload.create(
      strokes: [_stroke()],
      limits: limits(4),
      unknownFields: wide,
    );
    expect(rejected, isA<Err<Object?, Object?>>());
    expect(rejected.toString(), isNot(contains('rejected-tail-secret')));
  });
}

HandwritingPayload _payload({
  PreservedMap? unknown,
  List<StrokeSample>? samples,
}) => _ok(
  HandwritingPayload.create(
    strokes: [_stroke(samples: samples)],
    limits: _limits,
    unknownFields: unknown,
  ),
);
HandwritingStroke _stroke({List<StrokeSample>? samples}) => _ok(
  HandwritingStroke.create(
    id: StrokeId.fromUuid(testUuid(10)),
    samples: samples ?? [_sample(0, 0, 0), _sample(4, 0, 1)],
    style: _style(),
    limits: _limits,
  ),
);
StrokeStyle _style() => _ok(
  StrokeStyle.create(
    argb: 0xff000000,
    opacity: 1,
    baseWidth: 4,
    pressureInfluence: 0,
    minimumPressureFactor: 0,
    limits: _limits,
  ),
);
StrokeSample _sample(double x, double y, int time) => _ok(
  StrokeSample.create(
    position: _point(x, y),
    timeMicros: time,
    limits: _limits,
  ),
);
Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));
T _ok<T, E>(Result<T, E> result) => (result as Ok<T, E>).value;

final class _TailIterable<T> extends Iterable<T> {
  _TailIterable(this.values);
  final List<T> values;
  bool rejectedCurrentRead = false;
  @override
  Iterator<T> get iterator => _TailIterator<T>(this);
}

final class _TailIterator<T> implements Iterator<T> {
  _TailIterator(this.owner);
  final _TailIterable<T> owner;
  var index = -1;
  @override
  bool moveNext() {
    index += 1;
    return index <= owner.values.length;
  }

  @override
  T get current {
    if (index >= owner.values.length) {
      owner.rejectedCurrentRead = true;
      throw StateError('secret rejected tail');
    }
    return owner.values[index];
  }
}
