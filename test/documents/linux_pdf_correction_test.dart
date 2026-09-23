// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_backend.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_resources.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_supervisor.dart';
import 'package:al_note/ui/canvas/pdf_raster_image.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdf_geometry_checks.dart';

final _limits = geometryOk(
  PdfProcessingLimits.create(
    maximumEncodedBytes: 50000000,
    maximumPageCount: 1000,
    maximumRenderDimension: 4096,
    maximumRenderPixels: 16777216,
    maximumExtractedGlyphs: 1000000,
    maximumLinks: 100000,
    maximumOperations: 1000000,
  ),
);
final _bytes = File('test/fixtures/phase8/admitted/blank-workflow.pdf')
    .readAsBytesSync();
PdfInspectRequest _inspect(CancellationToken token) => PdfInspectRequest(
  resourceIdentity: geometryIdentity,
  trust: PdfInputTrust.trustedDevelopmentFixture,
  modelLimits: geometryModelLimits,
  limits: _limits,
  cancellationToken: token,
);
PdfRenderRequest _render(
  PdfPageReference reference,
  CancellationToken token, [
  int dimension = 400,
]) => geometryOk(
  PdfRenderRequest.create(
    reference: reference,
    trust: PdfInputTrust.trustedDevelopmentFixture,
    region: PdfPageClip.full,
    pixelWidth: dimension,
    pixelHeight: dimension,
    includeSafeNativeAppearances: false,
    limits: _limits,
    cancellationToken: token,
  ),
);
PdfPageReference _reference(PdfInspectedPage page) => geometryOk(
  PdfPageReference.create(
    resourceIdentity: geometryIdentity,
    pageIndex: 0,
    boxKind: page.boxKind,
    sourceBox: page.sourceBox,
    rotation: page.rotation,
    displayedWidth: page.displayedWidth,
    displayedHeight: page.displayedHeight,
    limits: geometryModelLimits,
  ),
);
Set<String> _stages() => Directory.systemTemp
    .listSync()
    .whereType<Directory>()
    .where((d) => d.path.split('/').last.startsWith('alnote-pdf-'))
    .map((d) => d.path)
    .toSet();
Future<void> _until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition() && clock.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  test('Linux typed raster capture owns exact immutable bytes and receiving limits', () {
    final bytes = Uint8List.fromList([0, 127, 255, 128]);
    final result = geometryOk(
      PdfRenderOutput.capture(
        backendIdentity: geometryOk(PdfBackendIdentity.parse('test.capture')),
        region: PdfPageClip.full,
        pixelWidth: 1,
        pixelHeight: 1,
        rgbaBytes: bytes,
        limits: _limits,
        cancellationToken: CancellationController().token,
      ),
    );
    bytes[0] = 99;
    expect(result.rgbaBytes, [0, 127, 255, 128]);
    expect(result.rgbaBytes, isA<Uint8List>());
    expect(() => result.rgbaBytes[0] = 1, throwsUnsupportedError);
    expect(
      () => (result.rgbaBytes as Uint8List).buffer.asUint8List()[0] = 1,
      throwsUnsupportedError,
    );
    for (final length in [0, 3, 5]) {
      expect(
        PdfRenderOutput.capture(
          backendIdentity: result.backendIdentity,
          region: result.region,
          pixelWidth: 1,
          pixelHeight: 1,
          rgbaBytes: Uint8List(length),
          limits: _limits,
          cancellationToken: CancellationController().token,
        ),
        isA<Err<PdfRenderOutput, StructuredFailure>>(),
      );
    }
    final cancelled = CancellationController()..cancel();
    expect(
      PdfRenderOutput.capture(
        backendIdentity: result.backendIdentity,
        region: result.region,
        pixelWidth: 1,
        pixelHeight: 1,
        rgbaBytes: Uint8List(4),
        limits: _limits,
        cancellationToken: cancelled.token,
      ),
      isA<Err<PdfRenderOutput, StructuredFailure>>(),
    );
  });

  test(
    'Linux final image preparation cancels without publishing an image',
    () async {
      final output = geometryOk(
        PdfRenderOutput.capture(
          backendIdentity: geometryOk(PdfBackendIdentity.parse('test.image')),
          region: PdfPageClip.full,
          pixelWidth: 10,
          pixelHeight: 10,
          rgbaBytes: Uint8List(400),
          limits: _limits,
          cancellationToken: CancellationController().token,
        ),
      );
      final cancelled = CancellationController()..cancel();
      expect(await preparePdfRasterImage(output, cancelled.token), isNull);
      final during = CancellationController();
      Timer.run(during.cancel);
      expect(await preparePdfRasterImage(output, during.token), isNull);
      final valid = await preparePdfRasterImage(
        output,
        CancellationController().token,
      );
      expect(valid!.width, 10);
      valid.dispose();
    },
  );

  final host =
      Platform.isLinux &&
      const bool.fromEnvironment('ALNOTE_LINUX_INTEGRATION_TEST');
  test(
    'Linux obsolete cold staging cancels promptly and latest recovers',
    () async {
      final before = _stages();
      for (var round = 0; round < 3; round++) {
        final backend = createLinuxIsolatedPdfBackend(
          bundle: Directory('build/linux-pdf-resources'),
        );
        // Metadata is independently established by a real inspection control.
        final control = createLinuxIsolatedPdfBackend(
          bundle: Directory('build/linux-pdf-resources'),
        );
        final inspected = await control.inspect(
          _inspect(CancellationController().token),
          resourceReader: _Reader(),
        );
        final reference = _reference(
          (inspected as PdfInspectSuccess).pages.first,
        );
        final a = CancellationController();
        final aReader = _Reader(), bReader = _Reader(), cReader = _Reader();
        final old = backend.render(
          _render(reference, a.token),
          resourceReader: aReader,
        );
        await _until(() => _stages().difference(before).isNotEmpty);
        final middle = backend.render(
          _render(reference, CancellationController().token),
          resourceReader: bReader,
        );
        final c = CancellationController();
        final latest = backend.render(
          _render(reference, c.token, 800),
          resourceReader: cReader,
        );
        final watch = Stopwatch()..start();
        a.cancel();
        a.cancel();
        expect(await old, isA<PdfRenderFailure>());
        final cancelledMs = watch.elapsedMilliseconds;
        expect(
          cancelledMs,
          lessThan(250),
          reason: 'cold hash is cooperatively abandoned',
        );
        expect(await middle, isA<PdfRenderFailure>());
        expect(bReader.calls, 0);
        expect(await latest, isA<PdfRenderSuccess>());
        expect(cReader.calls, 1);
        expect(_stages().difference(before), isEmpty);
        // A warm operation cancelled during disposal still owns cleanup to return.
        final dispose = CancellationController();
        final disposed = backend.render(
          _render(reference, dispose.token),
          resourceReader: _Reader(),
        );
        dispose.cancel();
        expect(await disposed, isA<PdfRenderFailure>());
        expect(_stages().difference(before), isEmpty);
        // ignore: avoid_print
        print('LINUX_COLD_CANCEL_MS ${cancelledMs} round=$round');
      }
    },
    skip: !host,
  );

  test('Linux verified cache keeps private bytes and invalidates package changes', () async {
    final original = Directory('build/linux-pdf-resources');
    final bundle = await Directory.systemTemp.createTemp(
      'alnote-cached-package-',
    );
    Directory? stage;
    try {
      for (final entity in original.listSync(recursive: true)) {
        final path =
            '${bundle.path}/${entity.path.substring(original.path.length + 1)}';
        if (entity is Directory) Directory(path).createSync(recursive: true);
        if (entity is File) entity.copySync(path);
      }
      final resources = LinuxPdfResources(bundle);
      stage = await resources.stage(CancellationController().token);
      final originalWorker = File('${stage.path}/worker').readAsBytesSync();
      // A caller can modify its test runtime, never the private verified cache.
      File('${stage.path}/worker').deleteSync();
      File('${stage.path}/worker').writeAsBytesSync([1, 2, 3]);
      await stage.delete(recursive: true);
      stage = await resources.stage(CancellationController().token);
      expect(
        geometryOk(
          Sha256Digest.calculate(
            File('${stage.path}/worker').readAsBytesSync(),
          ),
        ),
        geometryOk(Sha256Digest.calculate(originalWorker)),
      );
      await stage.delete(recursive: true);
      stage = null;
      final worker = File('${bundle.path}/worker');
      worker.deleteSync();
      worker.writeAsBytesSync([1, 2, 3]);
      await expectLater(
        resources.stage(CancellationController().token),
        throwsFormatException,
      );
      worker.writeAsBytesSync(originalWorker);
      stage = await resources.stage(CancellationController().token);
      await stage.delete(recursive: true);
      stage = null;
      File('${bundle.path}/notices/dart-sdk/LICENSE').deleteSync();
      await expectLater(
        resources.stage(CancellationController().token),
        throwsFormatException,
      );
    } finally {
      if (stage != null && stage.existsSync())
        await stage.delete(recursive: true);
      await bundle.delete(recursive: true);
    }
  }, skip: !host);

  test('Linux controller outage retains surviving descendants and guard admission until recovery', () async {
    final stage = await LinuxPdfResources(
      Directory('build/linux-pdf-resources'),
    ).stage(CancellationController().token);
    final controls = await Directory.systemTemp.createTemp(
      'alnote-controller-',
    );
    final marker = File('${controls.path}/offline');
    final hanging = File('${controls.path}/hang');
    final wrapper = File('${controls.path}/systemctl');
    await wrapper.writeAsString(
      '#!/bin/sh\nif [ -f "${hanging.path}" ]; then exec /usr/bin/sleep 30; fi\nif [ -f "${marker.path}" ]; then exit 1; fi\nexec /usr/bin/systemctl "\$@"\n',
    );
    expect(
      (await Process.run('/usr/bin/chmod', ['700', wrapper.path])).exitCode,
      0,
    );
    final delegate = _ControlledBackend(
      stage,
      LinuxPdfSupervisor(systemctl: wrapper.path),
    );
    final backend = DevelopmentFixturePdfBackend(delegate: delegate);
    String? unit;
    try {
      for (var round = 0; round < 2; round++) {
        File('${stage.path}/worker').deleteSync();
        File('build/linux-pdf-tools/protocol-worker')
            .copySync('${stage.path}/worker');
        File('${stage.path}/mode').writeAsStringSync('6');
        final payload = utf8.encode(
          jsonEncode({
            'version': 1,
            'id': 1,
            'status': 'ok',
            'pages': [
              {
                'kind': 'resolvedBounds',
                'bounds': [0, 0, 1, 1],
                'rotation': 0,
                'width': 1,
                'height': 1,
              },
            ],
          }),
        );
        File('${stage.path}/response').writeAsBytesSync([
          ...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
          ...payload,
        ]);
        final controller = CancellationController();
        var returned = false;
        final old = backend
            .inspect(_inspect(controller.token), resourceReader: _Reader())
            .then((value) {
              returned = true;
              return value;
            });
        List<String> members = [];
        String group = '';
        final watch = Stopwatch()..start();
        while (members.length < 4 &&
            watch.elapsed < const Duration(seconds: 10)) {
          final units = await Process.run('/usr/bin/systemctl', [
            '--user',
            'list-units',
            '--state=running',
            '--no-legend',
            '--plain',
            'alnote-pdf-*.service',
          ]);
          final text = units.stdout.toString().trim();
          if (text.isNotEmpty) {
            unit = text.split(RegExp(r'\s+')).first;
            group = (await Process.run('/usr/bin/systemctl', [
              '--user',
              'show',
              unit,
              '-p',
              'ControlGroup',
              '--value',
            ])).stdout.toString().trim();
            final file = File('/sys/fs/cgroup$group/cgroup.procs');
            if (group.isNotEmpty && file.existsSync())
              members = file.readAsLinesSync();
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(members.length, greaterThanOrEqualTo(4));
        marker.writeAsStringSync('offline');
        if (round == 1) hanging.writeAsStringSync('timeout');
        controller.cancel();
        controller.cancel();
        await _until(() => LinuxPdfSupervisor.cleanupUnconfirmed);
        expect(returned, isFalse);
        expect(
          File('/sys/fs/cgroup$group/cgroup.procs').readAsLinesSync(),
          isNotEmpty,
        );
        final rejectedReader = _Reader();
        expect(
          await backend.inspect(
            _inspect(CancellationController().token),
            resourceReader: rejectedReader,
          ),
          isA<PdfBackendUnavailable>(),
        );
        expect(rejectedReader.calls, 0);
        final reference = _reference(
          geometryOk(
            PdfInspectedPage.create(
              pageIndex: 0,
              boxKind: PdfPageBoxKind.resolvedBounds,
              sourceBox: geometryOk(
                PdfSourceBox.create(
                  left: 0,
                  bottom: 0,
                  right: 1,
                  top: 1,
                  limits: geometryModelLimits,
                ),
              ),
              rotation: PdfPageRotation.degrees0,
              displayedWidth: 1,
              displayedHeight: 1,
              limits: geometryModelLimits,
            ),
          ),
        );
        final pendingReader = _Reader(), latestReader = _Reader();
        final pending = backend.render(
          _render(reference, CancellationController().token),
          resourceReader: pendingReader,
        );
        final latest = backend.render(
          _render(reference, CancellationController().token),
          resourceReader: latestReader,
        );
        expect(await pending, isA<PdfRenderFailure>());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(latestReader.calls, 0);
        expect(returned, isFalse);
        marker.deleteSync();
        if (hanging.existsSync()) hanging.deleteSync();
        expect(await old, isA<PdfInspectionCancelled>());
        expect(
          await latest,
          isA<PdfRenderFailure>(),
        ); // control delegate only checks admission
        expect(latestReader.calls, 1);
        expect(pendingReader.calls, 0);
        expect(LinuxPdfSupervisor.cleanupUnconfirmed, isFalse);
        final events = File('/sys/fs/cgroup$group/cgroup.events');
        expect(
          !events.existsSync() ||
              events.readAsStringSync().contains('populated 0'),
          isTrue,
        );
        for (final pid in members) {
          expect(Directory('/proc/$pid').existsSync(), isFalse);
        }
        // ignore: avoid_print
        print(
          'LINUX_CONTROLLER_RECOVERY round=$round pids=${members.length} empty=true reaped=true',
        );
        unit = null;
      }
      // Actual worker recovery uses the same supervisor after confirmed cleanup.
      File('${stage.path}/worker').deleteSync();
      File('build/linux-pdf-resources/worker').copySync('${stage.path}/worker');
      for (final render in [false, true]) {
        final frames = await const LinuxPdfSupervisor().operate(
          runtime: stage,
          source: _bytes,
          token: CancellationController().token,
          render: render,
        );
        expect(frames.length, render ? 3 : 2);
      }
    } finally {
      if (marker.existsSync()) marker.deleteSync();
      if (hanging.existsSync()) hanging.deleteSync();
      if (unit != null) {
        await Process.run('/usr/bin/systemctl', [
          '--user',
          'kill',
          '--signal=KILL',
          unit,
        ]);
      }
      await _until(() => !LinuxPdfSupervisor.cleanupUnconfirmed);
      await stage.delete(recursive: true);
      await controls.delete(recursive: true);
    }
  }, skip: !host);

  test('Linux large raster full handoff keeps event loop responsive and pixels exact', () async {
    final backend = createLinuxIsolatedPdfBackend(
      bundle: Directory('build/linux-pdf-resources'),
    );
    final inspected = await backend.inspect(
      _inspect(CancellationController().token),
      resourceReader: _Reader(),
    );
    final reference = _reference((inspected as PdfInspectSuccess).pages.first);
    for (final dimension in [400, 800, 1600, 3200, 4096]) {
      final watch = Stopwatch()..start();
      var last = 0, maxGap = 0, ticks = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final now = watch.elapsedMicroseconds;
        if (now - last > maxGap) maxGap = now - last;
        last = now;
        ticks++;
      });
      ui.Image? image;
      try {
        final result = await backend.render(
          _render(reference, CancellationController().token, dimension),
          resourceReader: _Reader(),
        );
        expect(result, isA<PdfRenderSuccess>());
        final output = (result as PdfRenderSuccess).output;
        final renderUs = watch.elapsedMicroseconds;
        expect(output.rgbaBytes, isA<Uint8List>());
        expect(() => output.rgbaBytes[0] = 1, throwsUnsupportedError);
        // This is the same native image preparation used by Canvas. The typed
        // immutable buffer avoids the old Dart-side full-image copy.
        image = await preparePdfRasterImage(
          output,
          CancellationController().token,
        );
        final displayUs = watch.elapsedMicroseconds;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(image!.width, dimension);
        expect(image.height, dimension);
        expect(ticks, greaterThan(3));
        expect(
          maxGap,
          lessThan(100000),
          reason: 'full handoff target below 100 ms on the reviewed host',
        );
        final readback = (await image.toByteData())!.buffer.asUint8List();
        expect(readback, orderedEquals(output.rgbaBytes));
        // ignore: avoid_print
        print(
          'LINUX_RASTER_HANDOFF ${jsonEncode({'dimension': dimension, 'render_us': renderUs, 'display_us': displayUs, 'max_gap_us': maxGap, 'ticks': ticks})}',
        );
      } finally {
        heartbeat.cancel();
        image?.dispose();
      }
    }
  }, skip: !host);
}

final class _Reader implements PdfResourceReader {
  int calls = 0;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    calls++;
    return GeometryReader(_bytes).read(
      identity: identity,
      limits: limits,
      cancellationToken: cancellationToken,
    );
  }
}

final class _ControlledBackend implements PdfBackend {
  _ControlledBackend(this.stage, this.supervisor);
  final Directory stage;
  final LinuxPdfSupervisor supervisor;
  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    try {
      await supervisor.operate(
        runtime: stage,
        source: _bytes,
        token: request.cancellationToken,
      );
    } on Object {
      /* Output is rejected only after confirmed cleanup. */
    }
    return const PdfBackendUnavailable();
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async => const PdfRenderFailure(PdfRenderFailureReason.backendUnavailable);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
