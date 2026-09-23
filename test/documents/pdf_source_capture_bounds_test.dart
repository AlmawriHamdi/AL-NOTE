// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:collection';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/pdf/src/pdf_source_preparation.dart';
import 'package:al_note/documents/pdf/src/pdf_source_preparation_stub.dart'
    as portable;
import 'package:flutter_test/flutter_test.dart';

enum _Route { capture, publicPreparation, portablePreparation }

Future<CapturedResourceBytes> _prepare(
  _Route route,
  List<int> bytes,
  int maximum,
  CancellationToken token,
) => switch (route) {
  _Route.capture => CapturedResourceBytes.capture(
    bytes,
    maximumBytes: maximum,
    cancellationToken: token,
  ),
  _Route.publicPreparation => preparePdfSource(bytes, maximum, token),
  _Route.portablePreparation => portable.preparePdfSource(
    bytes,
    maximum,
    token,
  ),
};

void _expectOwned(CapturedResourceBytes captured, List<int> expected) {
  expect(captured.bytes, expected);
  // Check the backing buffer too: a short view of an oversized capture is not
  // sufficient to enforce the receiving allocation ceiling.
  expect(captured.bytes.buffer.lengthInBytes, expected.length);
  expect(
    captured.digest,
    (Sha256Digest.calculate(
      expected,
    ) as Ok<Sha256Digest, StructuredFailure>).value,
  );
  expect(() => captured.bytes[0] = 0, throwsUnsupportedError);
  expect(
    () => captured.bytes.buffer.asUint8List()[0] = 0,
    throwsUnsupportedError,
  );
}

void main() {
  for (final route in _Route.values) {
    test('$route changing lengths cannot enlarge a two-byte capture', () async {
      for (final threshold in [1, 2, 3, 4]) {
        final source = _ChangingLength(threshold);
        CapturedResourceBytes? captured;
        try {
          captured = await _prepare(
            route,
            source,
            2,
            CancellationController().token,
          );
        } on FormatException {
          // A second receiving boundary may reject the changed reported length.
          expect(route, _Route.publicPreparation);
        }
        expect(
          source.lengthReads,
          1,
          reason: 'Snapshot caller length once; never use isEmpty or reread to allocate.',
        );
        if (captured != null) _expectOwned(captured, [7, 7]);
        if (route != _Route.publicPreparation) {
          expect(source.indices, [0, 1]);
        }
      }
    });

    test(
      '$route throws and shrinking sources reject without unbounded traversal',
      () async {
        for (final mode in [
          'length',
          'index',
          'shrink',
          'negativeOctet',
          'largeOctet',
        ]) {
          final source = _FaultyList(mode);
          await expectLater(
            _prepare(route, source, 2, CancellationController().token),
            throwsFormatException,
            reason: mode,
          );
          expect(source.lengthReads, 1);
          if (route != _Route.publicPreparation) {
            expect(source.indices.every((i) => i >= 0 && i < 2), isTrue);
          }
        }
      },
    );

    test(
      '$route first length is the bound even when later length access throws',
      () async {
        final source = _FaultyList('laterLength');
        try {
          final captured = await _prepare(
            route,
            source,
            2,
            CancellationController().token,
          );
          _expectOwned(captured, [7, 7]);
        } on FormatException {
          expect(route, _Route.publicPreparation);
        }
        expect(source.lengthReads, 1);
      },
    );

    test(
      '$route growth during indexing stays bounded and digest follows owned bytes',
      () async {
        final source = _FaultyList('grow');
        final captured = await _prepare(
          route,
          source,
          2,
          CancellationController().token,
        );
        _expectOwned(captured, [7, 9]);
        expect(source.lengthReads, 1);
        if (route != _Route.publicPreparation) expect(source.indices, [0, 1]);
      },
    );

    test(
      '$route rejects invalid receiving lengths before element access',
      () async {
        for (final length in [-1, 0, 3, 8]) {
          final source = _FixedLength(length);
          await expectLater(
            _prepare(route, source, 2, CancellationController().token),
            throwsFormatException,
          );
          expect(source.lengthReads, 1);
          expect(source.indices, isEmpty);
        }
        for (final maximum in [-1, 0]) {
          final source = _FixedLength(2);
          await expectLater(
            _prepare(route, source, maximum, CancellationController().token),
            throwsFormatException,
          );
          expect(source.lengthReads, 0);
          expect(source.indices, isEmpty);
        }
      },
    );

    test(
      '$route ordinary typed views are owned before caller mutation',
      () async {
        final input = Uint8List.fromList([99, 1, 2, 3, 99]);
        final view = Uint8List.sublistView(input, 1, 4);
        final pending = _prepare(
          route,
          view,
          3,
          CancellationController().token,
        );
        input.fillRange(0, input.length, 9);
        _expectOwned(await pending, [1, 2, 3]);
        await expectLater(
          _prepare(route, Uint8List(8), 2, CancellationController().token),
          throwsFormatException,
        );
      },
    );

    test(
      '$route cancellation rejects before source access and during capture',
      () async {
        final cancelled = CancellationController()..cancel();
        final source = _FaultyList('length');
        await expectLater(
          _prepare(route, source, 2, cancelled.token),
          throwsFormatException,
        );
        expect(source.lengthReads, 0);
        final during = CancellationController();
        final pending = _prepare(
          route,
          Uint8List(131072),
          131072,
          during.token,
        );
        during.cancel();
        await expectLater(pending, throwsFormatException);
        _expectOwned(
          await _prepare(route, [1, 2], 2, CancellationController().token),
          [1, 2],
        );
      },
    );
  }
}

class _FixedLength extends ListBase<int> {
  _FixedLength(this.reportedLength);
  final int reportedLength;
  int lengthReads = 0;
  final indices = <int>[];
  @override
  int get length {
    lengthReads++;
    return reportedLength;
  }

  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  int operator [](int index) {
    indices.add(index);
    return 7;
  }

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('read only');
}

final class _ChangingLength extends _FixedLength {
  _ChangingLength(this.threshold) : super(2);
  final int threshold;
  @override
  int get length => ++lengthReads <= threshold ? 2 : 8;
}

final class _FaultyList extends _FixedLength {
  _FaultyList(this.mode) : super(2);
  final String mode;
  final contents = [7, 7];
  @override
  int get length {
    lengthReads++;
    if (mode == 'length' || (mode == 'laterLength' && lengthReads > 1)) {
      throw StateError('private getter details');
    }
    return contents.length;
  }

  @override
  int operator [](int index) {
    indices.add(index);
    if (mode == 'index') throw StateError('private index details');
    if (mode == 'negativeOctet') return -1;
    if (mode == 'largeOctet') return 256;
    if (index == 0 && mode == 'shrink') contents.removeLast();
    if (index == 0 && mode == 'grow') {
      contents[1] = 9;
      contents.addAll(List.filled(6, 7));
    }
    return contents[index];
  }
}
