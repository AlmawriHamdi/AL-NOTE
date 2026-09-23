// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/pdf.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_protocol.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_resources.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

const _page = {
  'kind': 'resolvedBounds',
  'bounds': [0, 0, 1, 1],
  'rotation': 0,
  'width': 1,
  'height': 1,
};
const _inspect = {
  'version': 1,
  'id': 1,
  'status': 'ok',
  'pages': [_page],
};
Uint8List _frame(Object value) {
  final data = value is List<int> ? value : utf8.encode(jsonEncode(value));
  return Uint8List.fromList([
    ...(ByteData(4)..setUint32(0, data.length)).buffer.asUint8List(),
    ...data,
  ]);
}

LinuxPdfFrames _decoder({bool render = false}) =>
    LinuxPdfFrames(width: 1, height: 1, render: render, onReady: () {});

void main() {
  test('Linux protocol exact integer types and oversized geometry', () {
    for (final field in ['id', 'version']) {
      for (final invalid in [true, 1.0, false, null, 2]) {
        final decoder = _decoder()..add(_frame({'ready': true}));
        expect(
          () => decoder.add(_frame({..._inspect, field: invalid})),
          throwsFormatException,
        );
      }
    }
    for (final field in ['width', 'height', 'bytes']) {
      for (final invalid in [true, false, field == 'bytes' ? 4.0 : 1.0]) {
        final decoder = _decoder(render: true)..add(_frame({'ready': true}));
        expect(
          () => decoder.add(
            _frame({
              'version': 1,
              'id': 1,
              'status': 'ok',
              'page': _page,
              'width': 1,
              'height': 1,
              'bytes': 4,
              field: invalid,
            }),
          ),
          throwsFormatException,
        );
      }
    }
    final huge = '1${List.filled(400, '0').join()}';
    final decoder = _decoder()..add(_frame({'ready': true}));
    final payload = utf8.encode(
      '{"version":1,"id":1,"status":"ok","pages":['
      '{"kind":"resolvedBounds","bounds":[0,0,$huge,1],"rotation":0,"width":1,"height":1}]}',
    );
    expect(() => decoder.add(_frame(payload)), throwsFormatException);
  });

  test('Linux protocol fragmented valid frames and bounded rejection', () {
    final bytes = [
      ..._frame({'ready': true}),
      ..._frame(_inspect),
    ];
    final decoder = _decoder();
    for (final byte in bytes) {
      decoder.add([byte]);
    }
    decoder.finish();
    expect(decoder.frames.length, 2);
    expect(() => decoder.add([0]), throwsFormatException);
    expect(
      () => (_decoder()..add([0, 0, 0, 5, 1])).finish(),
      throwsFormatException,
    );
    expect(() => _decoder().add([255, 255, 255, 255]), throwsFormatException);
  });

  test('Linux integration admission is explicit and fixture bounded', () {
    final source = File('test/fixtures/phase8/linux-integration/ordinary.pdf')
        .readAsBytesSync();
    final token = CancellationController().token;
    expect(
      PdfFixtureAdmission.permits(source, token),
      Platform.isLinux &&
          !const bool.fromEnvironment('dart.vm.product') &&
          const bool.fromEnvironment('ALNOTE_LINUX_INTEGRATION_TEST'),
    );
    source[source.length - 1] ^= 1;
    expect(PdfFixtureAdmission.permits(source, token), isFalse);
  });

  final host =
      Platform.isLinux &&
      const bool.fromEnvironment('ALNOTE_LINUX_INTEGRATION_TEST');
  test('Linux packaged real worker inspect render and cancellation cleanup', () async {
    final source = File('test/fixtures/phase8/linux-integration/ordinary.pdf')
        .readAsBytesSync();
    final before = Directory.systemTemp
        .listSync()
        .where((e) => e.path.split('/').last.startsWith('alnote-pdf-'))
        .map((e) => e.path)
        .toSet();
    final elapsed = <String, int>{};
    for (final render in [false, true]) {
      final watch = Stopwatch()..start();
      final token = CancellationController().token;
      final stage = await LinuxPdfResources(
        Directory('build/linux-pdf-resources'),
      ).stage(token);
      try {
        final output = await const LinuxPdfSupervisor().operate(
          runtime: stage,
          source: source,
          token: token,
          render: render,
        );
        expect(output.length, render ? 3 : 2);
        if (render) {
          final rgba = output[2] as Uint8List;
          expect(rgba.length, 400 * 300 * 4);
          expect(rgba.toSet().length, greaterThan(2));
        } else {
          expect((output[1] as Map)['pages'], hasLength(3));
        }
      } finally {
        await stage.delete(recursive: true);
      }
      elapsed[render ? 'render_ms' : 'inspect_ms'] = watch.elapsedMilliseconds;
    }
    final controller = CancellationController();
    final stage = await LinuxPdfResources(
      Directory('build/linux-pdf-resources'),
    ).stage(controller.token);
    try {
      controller.cancel();
      await expectLater(
        const LinuxPdfSupervisor().operate(
          runtime: stage,
          source: source,
          token: controller.token,
        ),
        throwsFormatException,
      );
    } finally {
      await stage.delete(recursive: true);
    }
    final after = Directory.systemTemp
        .listSync()
        .where((e) => e.path.split('/').last.startsWith('alnote-pdf-'))
        .map((e) => e.path)
        .toSet();
    expect(after.difference(before), isEmpty);
    // Includes verification, staging, transport, operation, reap and deletion.
    // ignore: avoid_print
    print('LINUX_END_TO_END ${jsonEncode(elapsed)}');
  }, skip: !host);

  test('Linux heavy inspection and active native cancellation', () async {
    final source = File('test/fixtures/phase8/linux-integration/heavy.pdf')
        .readAsBytesSync();
    final stage = await LinuxPdfResources(
      Directory('build/linux-pdf-resources'),
    ).stage(CancellationController().token);
    addTearDown(() => stage.deleteSync(recursive: true));
    final output = await const LinuxPdfSupervisor().operate(
      runtime: stage,
      source: source,
      token: CancellationController().token,
    );
    expect((output[1] as Map)['pages'], hasLength(3));
    final controller = CancellationController();
    final timer = Timer(const Duration(milliseconds: 200), controller.cancel);
    try {
      await expectLater(
        const LinuxPdfSupervisor().operate(
          runtime: stage,
          source: source,
          render: true,
          token: controller.token,
        ),
        throwsFormatException,
      );
    } finally {
      timer.cancel();
    }
  }, skip: !host);

  test('Linux supervisor hostile output transport crash and cancellation reaps', () async {
    final stage = await LinuxPdfResources(
      Directory('build/linux-pdf-resources'),
    ).stage(CancellationController().token);
    addTearDown(() => stage.deleteSync(recursive: true));
    File('${stage.path}/worker').deleteSync();
    File('build/linux-pdf-tools/protocol-worker')
        .copySync('${stage.path}/worker');
    const render = {
      'version': 1,
      'id': 1,
      'status': 'ok',
      'page': _page,
      'width': 1,
      'height': 1,
      'bytes': 4,
    };
    final huge = '1${List.filled(400, '0').join()}';
    final badGeometry = utf8.encode(
      '{"version":1,"id":1,"status":"ok","pages":['
      '{"kind":"resolvedBounds","bounds":[0,0,$huge,1],"rotation":0,"width":1,"height":1}]}',
    );
    final cases = <(String, List<int>, int, bool)>[
      ('short-input', _frame(_inspect), 3, false),
      (
        'short-input-rejection',
        _frame({
          'version': 1,
          'id': 1,
          'status': 'rejected',
          'reason': 'failed',
        }),
        3,
        false,
      ),
      (
        'nonzero-rejection',
        _frame({
          'version': 1,
          'id': 1,
          'status': 'rejected',
          'reason': 'passwordRequired',
        }),
        1,
        false,
      ),
      (
        'cancel-descendant-rejection',
        _frame({
          'version': 1,
          'id': 1,
          'status': 'rejected',
          'reason': 'unsupported',
        }),
        6,
        false,
      ),
      ('boolean-id', _frame({..._inspect, 'id': true}), 6, false),
      ('float-id', _frame({..._inspect, 'id': 1.0}), 6, false),
      (
        'boolean-size',
        [
          ..._frame({...render, 'width': true}),
          ..._frame([1, 2, 3, 4]),
        ],
        6,
        true,
      ),
      (
        'float-length',
        [
          ..._frame({...render, 'bytes': 4.0}),
          ..._frame([1, 2, 3, 4]),
        ],
        6,
        true,
      ),
      ('huge-geometry', _frame(badGeometry), 6, false),
      ('invalid-json', _frame(utf8.encode('{')), 6, false),
      ('truncated', _frame(_inspect).sublist(0, 20), 0, false),
      ('oversized', [255, 255, 255, 255], 6, false),
      (
        'extra-frame',
        [
          ..._frame(_inspect),
          ..._frame([0]),
        ],
        0,
        false,
      ),
      ('nonzero-exit', _frame(_inspect), 1, false),
      ('crash-after-output', _frame(_inspect), 11, false),
      ('stderr-flood', _frame(_inspect), 5, false),
      ('early-exit', [], 8, false),
      ('hang', _frame(_inspect), 2, false),
      ('cancel-descendant', _frame(_inspect), 6, false),
    ];
    for (final (name, response, mode, rendering) in cases) {
      File('${stage.path}/response').writeAsBytesSync(response);
      File('${stage.path}/mode').writeAsStringSync('$mode');
      final controller = CancellationController();
      final timer = name.startsWith('cancel-descendant')
          ? Timer(const Duration(milliseconds: 200), controller.cancel)
          : null;
      try {
        await expectLater(
          const LinuxPdfSupervisor().operate(
            runtime: stage,
            source: name.startsWith('short-input')
                ? Uint8List(1000000)
                : [1, 2, 3],
            token: controller.token,
            render: rendering,
            width: 1,
            height: 1,
            timeout: name == 'hang'
                ? const Duration(milliseconds: 300)
                : const Duration(seconds: 30),
          ),
          name == 'early-exit'
              ? throwsA(isA<LinuxPdfIsolationUnavailable>())
              : throwsFormatException,
          reason: name,
        );
      } finally {
        timer?.cancel();
      }
      final units = await Process.run('/usr/bin/systemctl', [
        '--user',
        'list-units',
        '--state=running',
        '--no-legend',
        '--plain',
        'alnote-pdf-*.service',
      ]);
      expect(
        units.stdout.toString().trim(),
        isEmpty,
        reason: 'reaped $name including descendants',
      );
    }
    await expectLater(
      const LinuxPdfSupervisor(systemdRun: '/nonexistent/alnote-systemd')
          .operate(
            runtime: stage,
            source: [1],
            token: CancellationController().token,
          ),
      throwsA(isA<LinuxPdfIsolationUnavailable>()),
    );
    await expectLater(
      const LinuxPdfSupervisor(bubblewrap: '/nonexistent/alnote-bwrap').operate(
        runtime: stage,
        source: [1],
        token: CancellationController().token,
      ),
      throwsA(isA<LinuxPdfIsolationUnavailable>()),
    );
  }, skip: !host);

  test(
    'Linux resource integrity covers worker guard engine runtime and notices',
    () async {
      final bundle = Directory.systemTemp.createTempSync(
        'alnote-package-integrity-',
      );
      addTearDown(() => bundle.deleteSync(recursive: true));
      final original = Directory('build/linux-pdf-resources');
      for (final entity in original.listSync(recursive: true)) {
        final relative = entity.path.substring(original.path.length + 1);
        if (entity is Directory) {
          Directory('${bundle.path}/$relative').createSync(recursive: true);
        }
        if (entity is File) {
          entity.copySync('${bundle.path}/$relative');
        }
      }
      for (final name in [
        'worker',
        'transport',
        'libguard.so',
        'libpdfium.so',
        'libc.so.6',
        'ld-linux-x86-64.so.2',
        'libdl.so.2',
        'libpthread.so.0',
        'libm.so.6',
        'libgcc_s.so.1',
        'notices/dart-sdk/LICENSE',
      ]) {
        final target = File('${bundle.path}/$name');
        target.deleteSync();
        await expectLater(
          LinuxPdfResources(bundle).stage(CancellationController().token),
          throwsA(isA<Object>()),
          reason: 'missing $name',
        );
        target.writeAsBytesSync([1]);
        await expectLater(
          LinuxPdfResources(bundle).stage(CancellationController().token),
          throwsFormatException,
          reason: 'corrupt $name',
        );
        target.deleteSync();
        File('${original.path}/$name').copySync(target.path);
      }
      final worker = File('${bundle.path}/worker');
      final chmod = await Process.run('/usr/bin/chmod', ['520', worker.path]);
      expect(chmod.exitCode, 0);
      await expectLater(
        LinuxPdfResources(bundle).stage(CancellationController().token),
        throwsFormatException,
        reason: 'group-writable executable',
      );
      worker.deleteSync();
      Link(worker.path)
          .createSync(File('${original.path}/worker').absolute.path);
      await expectLater(
        LinuxPdfResources(bundle).stage(CancellationController().token),
        throwsFormatException,
        reason: 'symlink resource',
      );
    },
    skip: !host,
  );

  test(
    'Linux package missing or corrupt manifest rejects before launch',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'alnote-package-negative-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final resource = LinuxPdfResources(temp);
      final token = CancellationController().token;
      await expectLater(resource.stage(token), throwsA(isA<Object>()));
      File('${temp.path}/manifest.json').writeAsStringSync('{}');
      await expectLater(resource.stage(token), throwsFormatException);
    },
    skip: !host,
  );
}
