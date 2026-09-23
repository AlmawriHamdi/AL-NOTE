// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/pdf.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late FileSelectorPlatform original;
  late _Picker picker;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('al-note-bounded-reader-');
    original = FileSelectorPlatform.instance;
    picker = _Picker();
    FileSelectorPlatform.instance = picker;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() async {
    FileSelectorPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
    await temp.delete(recursive: true);
  });

  test('Android uses the private bounded channel without invoking its eager picker', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(platformLocalPdfOpeningAvailable, isTrue);
    const channel = MethodChannel('alnote/pdf_fixture_reader');
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final result =
        await LocalPdfFileSelector(host: createPlatformLocalPdfPickerHost())
            .select(
              maximumEncodedBytes: 4,
              cancellationToken: CancellationController().token,
            );
    expect(result, isA<LocalPdfSelectionCancelled>());
    expect(methods, ['select', 'close']);
    expect(picker.calls, 0);
  });

  test(
    'actual desktop reads enforce empty/exact/over limits without copies',
    () async {
      for (final length in [0, 4, 5, 131072]) {
        final file = File('${temp.path}/candidate.pdf');
        await file.writeAsBytes(List<int>.filled(length, 37));
        picker.path = file.path;
        final limit = length > 5 ? length : 4;
        final result =
            await LocalPdfFileSelector(host: createPlatformLocalPdfPickerHost())
                .select(
                  maximumEncodedBytes: limit,
                  cancellationToken: CancellationController().token,
                );
        if (length == 0) {
          expect(
            (result as LocalPdfSelectionFailure).reason,
            LocalPdfSelectionFailureReason.unavailable,
          );
        } else if (length > limit) {
          expect(
            (result as LocalPdfSelectionFailure).reason,
            LocalPdfSelectionFailureReason.resourceLimit,
          );
        } else {
          expect((result as LocalPdfSelectionSuccess).bytes, hasLength(length));
        }
        expect(
          await temp.list().length,
          1,
        ); // Reader creates no disk/cache copy.
        expect(await file.length(), length);
        expect(result.toString(), isNot(contains(temp.path)));
      }
    },
  );

  test(
    'actual stream cancellation closes the opened file descriptor',
    () async {
      final file = File('${temp.path}/candidate.pdf');
      await file.writeAsBytes(List<int>.filled(131072, 37));
      picker.path = file.path;
      final token = CancellationController();
      final handle = await createPlatformLocalPdfPickerHost().selectOnePdf(
        cancellationToken: token.token,
      );
      final chunks = <int>[];
      await for (final chunk in handle!.openRead(
        maximumEncodedBytes: 131072,
        cancellationToken: token.token,
      )) {
        chunks.add(chunk.length);
        token.cancel();
      }
      expect(chunks, [localPdfReadChunkBytes]);
      final descriptors = Directory('/proc/self/fd');
      for (final entry in descriptors.listSync()) {
        try {
          expect(Link(entry.path).targetSync(), isNot(file.path));
        } on FileSystemException {
          /* FD can close during enumeration. */
        }
      }
    },
  );

  test(
    'missing selected file is fixed failure without exposing path',
    () async {
      picker.path = '${temp.path}/secret-missing.pdf';
      final result =
          await LocalPdfFileSelector(host: createPlatformLocalPdfPickerHost())
              .select(
                maximumEncodedBytes: 4,
                cancellationToken: CancellationController().token,
              );
      expect(result.toString(), 'LocalPdfSelectionFailure(unavailable)');
    },
  );
}

final class _Picker extends FileSelectorPlatform {
  String? path;
  int calls = 0;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    return path == null ? null : XFile(path!);
  }
}
