// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/pdf.dart';
import 'package:al_note/documents/pdf/src/local_pdf_picker_android.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('alnote/pdf_fixture_reader');
const _session = '00000000-0000-4000-8000-000000000001';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handle;
  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) {
      calls.add(call);
      return handle(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));
  Future<LocalPdfSelectionOutcome> capture({
    int budget = 4,
    CancellationController? cancellation,
  }) => LocalPdfFileSelector(host: createAndroidPdfPickerHost()).select(
    maximumEncodedBytes: budget,
    cancellationToken: (cancellation ?? CancellationController()).token,
  );

  test(
    'Android bridge uses bounded sequential typed chunks and opaque ownership',
    () async {
      var active = 0;
      var maximum = 0;
      handle = (call) async {
        if (call.method == 'select') return _session;
        if (call.method == 'close') return null;
        active++;
        if (active > maximum) maximum = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        final args = call.arguments as Map;
        expect(args['budget'], 4);
        return args['sequence'] == 0
            ? Uint8List.fromList([1, 2, 3, 4])
            : Uint8List(0);
      };
      final result = await capture() as LocalPdfSelectionSuccess;
      expect(result.bytes, [1, 2, 3, 4]);
      expect(maximum, 1);
      expect(calls.map((c) => c.method), ['select', 'read', 'read', 'close']);
      final owner = (calls.first.arguments as Map)['owner'];
      expect(owner, isA<String>());
      for (final call in calls) {
        expect((call.arguments as Map)['owner'], owner);
        expect(
          (call.arguments as Map).keys,
          everyElement(isIn(['owner', 'session', 'budget', 'sequence'])),
        );
      }
      expect(() => result.bytes[0] = 0, throwsUnsupportedError);
    },
  );
  for (final bad in [
    'oversize',
    'budget',
    'type',
    'error',
    'limit',
    'session',
    'empty',
  ]) {
    test('Android bridge rejects $bad and closes once', () async {
      handle = (call) async {
        if (call.method == 'select')
          return bad == 'session' ? 'content://private' : _session;
        if (call.method == 'close') return null;
        return switch (bad) {
          'oversize' => Uint8List(65537),
          'budget' => Uint8List(5),
          'type' => [1, 2],
          'empty' => Uint8List(0),
          _ => throw PlatformException(code: bad, message: 'private/uri'),
        };
      };
      final result = await capture();
      expect(result, isA<LocalPdfSelectionFailure>());
      expect(
        (result as LocalPdfSelectionFailure).reason,
        ['oversize', 'budget', 'limit'].contains(bad)
            ? LocalPdfSelectionFailureReason.resourceLimit
            : LocalPdfSelectionFailureReason.unavailable,
      );
      expect(result.toString(), isNot(contains('private')));
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
    });
  }
  test(
    'Android selection cancellation handles a late activity response',
    () async {
      final selected = Completer<Object?>();
      handle = (call) async => call.method == 'select' ? selected.future : null;
      final cancellation = CancellationController();
      final result = capture(cancellation: cancellation);
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      await Future<void>.delayed(Duration.zero);
      selected.complete(_session);
      expect(await result, isA<LocalPdfSelectionCancelled>());
      expect(calls.map((c) => c.method), ['select', 'close']);
    },
  );
  test(
    'Android cancellation during read drops late bytes and closes once',
    () async {
      final reading = Completer<Object?>();
      final entered = Completer<void>();
      handle = (call) async {
        if (call.method == 'select') return _session;
        if (call.method == 'read') {
          entered.complete();
          return reading.future;
        }
        return null;
      };
      final cancellation = CancellationController();
      final result = capture(cancellation: cancellation);
      await entered.future;
      cancellation.cancel();
      reading.complete(Uint8List.fromList([1, 2]));
      expect(await result, isA<LocalPdfSelectionCancelled>());
      expect(calls.where((c) => c.method == 'read'), hasLength(1));
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
    },
  );
  test(
    'Android handle rejects duplicate reads, stream cancellation closes',
    () async {
      handle = (call) async => call.method == 'select'
          ? _session
          : call.method == 'read'
          ? Uint8List.fromList([1])
          : null;
      final host = createAndroidPdfPickerHost();
      final token = CancellationController().token;
      final file = (await host.selectOnePdf(cancellationToken: token))!;
      await expectLater(
        host.selectOnePdf(cancellationToken: token),
        throwsA(isA<LocalPdfRouteUnavailableException>()),
      );
      await file
          .openRead(maximumEncodedBytes: 4, cancellationToken: token)
          .take(1)
          .toList();
      await expectLater(
        file
            .openRead(maximumEncodedBytes: 4, cancellationToken: token)
            .toList(),
        throwsA(isA<LocalPdfRouteUnavailableException>()),
      );
      expect(calls.where((c) => c.method == 'read'), hasLength(1));
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
    },
  );
  test(
    'Android excessive budget is rejected before any native allocation',
    () async {
      handle = (call) async => call.method == 'select' ? _session : null;
      final result =
          await capture(budget: 50000001) as LocalPdfSelectionFailure;
      expect(result.reason, LocalPdfSelectionFailureReason.resourceLimit);
      expect(calls.map((c) => c.method), ['select', 'close']);
    },
  );
}
