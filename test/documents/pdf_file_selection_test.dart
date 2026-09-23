// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/pdf.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('local PDF file selection boundary', () {
    test('picker cancellation is a normal no-op', () async {
      final outcome = await LocalPdfFileSelector(host: _Host(null))
          .select(maximumEncodedBytes: 8, cancellationToken: _token());

      expect(outcome, isA<LocalPdfSelectionCancelled>());
      expect(outcome.toString(), 'LocalPdfSelectionCancelled');
    });

    test('adapter exception becomes a fixed redaction-safe failure', () async {
      final outcome = await LocalPdfFileSelector(
        host: _ThrowingHost('private/path/password'),
      ).select(maximumEncodedBytes: 8, cancellationToken: _token());

      expect(outcome, isA<LocalPdfSelectionFailure>());
      expect(
        (outcome as LocalPdfSelectionFailure).reason,
        LocalPdfSelectionFailureReason.unavailable,
      );
      expect(outcome.toString(), 'LocalPdfSelectionFailure(unavailable)');
      expect(outcome.toString(), isNot(contains('private')));
      expect(outcome.toString(), isNot(contains('password')));
    });

    test('captures stream once without consulting reported length', () async {
      final handle = _Handle(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[0x25, 0x50],
          <int>[0x44, 0x46],
        ]),
      );
      final outcome = await LocalPdfFileSelector(host: _Host(handle))
          .select(maximumEncodedBytes: 4, cancellationToken: _token());

      expect(handle.openCount, 1);
      expect(outcome, isA<LocalPdfSelectionSuccess>());
      final bytes = (outcome as LocalPdfSelectionSuccess).bytes;
      expect(bytes, <int>[0x25, 0x50, 0x44, 0x46]);
      expect(() => bytes[0] = 0, throwsUnsupportedError);
      expect(outcome.toString(), 'LocalPdfSelectionSuccess(redacted)');
    });

    test(
      'exact byte ceiling succeeds and one extra byte is rejected',
      () async {
        Future<LocalPdfSelectionOutcome> capture(List<int> bytes) =>
            LocalPdfFileSelector(
              host: _Host(_Handle(Stream<List<int>>.value(bytes))),
            ).select(maximumEncodedBytes: 4, cancellationToken: _token());

        expect(
          await capture(<int>[1, 2, 3, 4]),
          isA<LocalPdfSelectionSuccess>(),
        );
        final rejected = await capture(<int>[1, 2, 3, 4, 5]);
        expect(rejected, isA<LocalPdfSelectionFailure>());
        expect(
          (rejected as LocalPdfSelectionFailure).reason,
          LocalPdfSelectionFailureReason.resourceLimit,
        );
      },
    );

    test(
      'hostile chunks and invalid octets fail without leaking evidence',
      () async {
        for (final chunk in <List<int>>[
          _ThrowingLengthList('secret-uri'),
          <int>[1, -1],
          <int>[256],
        ]) {
          final outcome = await LocalPdfFileSelector(
            host: _Host(_Handle(Stream<List<int>>.value(chunk))),
          ).select(maximumEncodedBytes: 8, cancellationToken: _token());

          expect(outcome, isA<LocalPdfSelectionFailure>());
          expect(outcome.toString(), 'LocalPdfSelectionFailure(unavailable)');
          expect(outcome.toString(), isNot(contains('secret')));
        }
      },
    );

    test('pre-cancellation does not invoke the picker', () async {
      final host = _Host(null);
      final controller = CancellationController()..cancel('private reason');

      final outcome = await LocalPdfFileSelector(host: host)
          .select(maximumEncodedBytes: 8, cancellationToken: controller.token);

      expect(outcome, isA<LocalPdfSelectionCancelled>());
      expect(host.selectCount, 0);
    });

    test(
      'mid-stream cancellation stops capture and returns no bytes',
      () async {
        final stream = StreamController<List<int>>();
        final controller = CancellationController();
        final future = LocalPdfFileSelector(
          host: _Host(_Handle(stream.stream)),
        ).select(maximumEncodedBytes: 8, cancellationToken: controller.token);

        stream.add(<int>[1, 2]);
        await Future<void>.delayed(Duration.zero);
        controller.cancel('sensitive cancellation');

        final outcome = await future;
        expect(outcome, isA<LocalPdfSelectionCancelled>());
        expect(outcome.toString(), isNot(contains('sensitive')));
        await stream.close();
      },
    );

    test(
      'empty source fails and many short chunks preserve exact bytes',
      () async {
        for (final chunks in [
          <List<int>>[],
          <List<int>>[[], []],
        ]) {
          final result = await LocalPdfFileSelector(
            host: _Host(_Handle(Stream<List<int>>.fromIterable(chunks))),
          ).select(maximumEncodedBytes: 8, cancellationToken: _token());
          expect(result, isA<LocalPdfSelectionFailure>());
        }
        final result = await LocalPdfFileSelector(
          host: _Host(
            _Handle(
              Stream<List<int>>.fromIterable(
                List.generate(1000, (i) => [i % 256]),
              ),
            ),
          ),
        ).select(maximumEncodedBytes: 1000, cancellationToken: _token());
        expect(
          (result as LocalPdfSelectionSuccess).bytes,
          List.generate(1000, (i) => i % 256),
        );
      },
    );

    test(
      'one budget reaches host read and oversize chunks are rejected',
      () async {
        final handle = _Handle(
          Stream.value(List.filled(localPdfReadChunkBytes + 1, 0)),
        );
        final result = await LocalPdfFileSelector(host: _Host(handle)).select(
          maximumEncodedBytes: localPdfReadChunkBytes * 2,
          cancellationToken: _token(),
        );
        expect(handle.budget, localPdfReadChunkBytes * 2);
        expect(
          (result as LocalPdfSelectionFailure).reason,
          LocalPdfSelectionFailureReason.resourceLimit,
        );
      },
    );

    test(
      'concurrent selection is rejected before a second picker invocation',
      () async {
        final host = _PendingHost();
        final selector = LocalPdfFileSelector(host: host);
        final first = selector.select(
          maximumEncodedBytes: 4,
          cancellationToken: _token(),
        );
        final second = await selector.select(
          maximumEncodedBytes: 4,
          cancellationToken: _token(),
        );
        expect(second, isA<LocalPdfSelectionFailure>());
        expect(host.calls, 1);
        host.done.complete(null);
        expect(await first, isA<LocalPdfSelectionCancelled>());
      },
    );

    test(
      'late picker completion after cancellation never opens content',
      () async {
        final host = _PendingHost();
        final token = CancellationController();
        final operation = LocalPdfFileSelector(host: host)
            .select(maximumEncodedBytes: 4, cancellationToken: token.token);
        token.cancel();
        final handle = _Handle(Stream.value([1, 2]));
        host.done.complete(handle);
        expect(await operation, isA<LocalPdfSelectionCancelled>());
        expect(handle.openCount, 0);
      },
    );

    test('file_selector imports remain in the private adapter', () async {
      final files = <String>[
        'lib/documents/pdf.dart',
        'lib/documents/pdf/pdf_backend.dart',
        'lib/documents/pdf/pdf_file_selection.dart',
        'lib/documents/pdf/pdf_model.dart',
      ];
      for (final path in files) {
        final contents = await File(path).readAsString();
        expect(contents, isNot(contains('package:file_selector/')));
        expect(contents, isNot(contains('XFile')));
      }
    });
  });
}

CancellationToken _token() => CancellationController().token;

final class _Host implements LocalPdfPickerHost {
  _Host(this.handle);

  final LocalPdfFileHandle? handle;
  int selectCount = 0;

  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async {
    selectCount += 1;
    return handle;
  }
}

final class _ThrowingHost implements LocalPdfPickerHost {
  _ThrowingHost(this.secret);

  final String secret;

  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => throw StateError(secret);
}

final class _Handle implements LocalPdfFileHandle {
  _Handle(this.stream);

  final Stream<List<int>> stream;
  int openCount = 0;
  int? budget;

  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) {
    openCount += 1;
    budget = maximumEncodedBytes;
    return stream;
  }
}

final class _ThrowingLengthList extends ListBase<int> {
  _ThrowingLengthList(this.secret);

  final String secret;

  @override
  int get length => throw StateError(secret);

  @override
  set length(int value) => throw UnsupportedError('fixed');

  @override
  int operator [](int index) => throw StateError(secret);

  @override
  void operator []=(int index, int value) => throw UnsupportedError('fixed');
}

final class _PendingHost implements LocalPdfPickerHost {
  final done = Completer<LocalPdfFileHandle?>();
  int calls = 0;
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) {
    calls++;
    return done.future;
  }
}
