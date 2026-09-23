// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/pdf/pdf_admission_policy.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_backend.dart';
import 'package:al_note/documents/pdf/src/pdf_source_preparation.dart';
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
final _modelLimits = geometryOk(
  PdfModelLimits.create(
    maximumPageCount: 1000,
    maximumCoordinateMagnitude: 1000000,
    maximumPageDimension: 1000000,
    maximumPageArea: 1000000000000,
    maximumUnknownFields: 16,
    maximumUnknownNodes: 256,
    maximumNestingDepth: 8,
    maximumUnknownStringCodeUnits: 4096,
  ),
);
Directory get _bundle => Directory(
  const String.fromEnvironment(
    'ALNOTE_PDF_TEST_BUNDLE',
    defaultValue: 'build/linux-pdf-resources',
  ),
);

final class _Picker implements LocalPdfPickerHost, LocalPdfFileHandle {
  _Picker(this.bytes);
  final Uint8List bytes;
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => this;
  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) async* {
    for (var start = 0; start < bytes.length; start += 65536) {
      if (cancellationToken.isCancelled) return;
      yield Uint8List.sublistView(
        bytes,
        start,
        (start + 65536).clamp(0, bytes.length),
      );
      await Future<void>.delayed(Duration.zero);
    }
  }
}

final class _Reader implements PdfResourceReader {
  _Reader(this.resource);
  final DocumentResourceSnapshot resource;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async {
    if (identity != resource.identity) throw StateError('identity mismatch');
    return PdfResourceBytes.fromSnapshot(
      resource: resource,
      limits: limits,
      cancellationToken: cancellationToken,
    );
  }
}

LocalPdfOpenWorkflow _workflow(PdfBackend backend, Uint8List bytes) =>
    LocalPdfOpenWorkflow(
      selector: LocalPdfFileSelector(host: _Picker(bytes)),
      backend: backend,
      modelLimits: _modelLimits,
      processingLimits: _limits,
    );
Uint8List _fixture(String name) =>
    File('test/fixtures/phase8/linux-private/$name.pdf').readAsBytesSync();

Future<void> _noWorkers() async {
  final result = await Process.run('/usr/bin/systemctl', [
    '--user',
    'list-units',
    '--all',
    '--no-legend',
    'alnote-pdf-*.service',
  ]);
  expect(result.exitCode, 0);
  expect(result.stdout.toString().trim(), isEmpty);
}

void main() {
  final host =
      linuxPrivatePdfTestEnabled &&
      const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_HOST_TEST');
  test('private Linux ordinary text scanned mixed open render and exact source reuse', () async {
    final backend = createLinuxIsolatedPdfBackend(bundle: _bundle);
    final measurements = <Object>[];
    for (final name in ['text', 'scanned', 'mixed']) {
      final bytes = _fixture(name);
      expect(
        PdfFixtureAdmission.permits(bytes, CancellationController().token),
        isFalse,
      );
      final watch = Stopwatch()..start();
      final opened = await _workflow(backend, bytes).open(
        cancellationToken: CancellationController().token,
        stillCurrent: () => true,
      );
      expect(opened, isA<LocalPdfOpenSuccess>());
      final success = opened as LocalPdfOpenSuccess;
      final source = success.root.pages.single.layers
          .whereType<PdfSourceLayer>()
          .single
          .reference;
      final output = await backend.render(
        geometryOk(
          PdfRenderRequest.create(
            reference: source,
            trust: pdfAdmissionFor(backend).trust,
            region: PdfPageClip.full,
            pixelWidth: 400,
            pixelHeight: 300,
            includeSafeNativeAppearances: false,
            limits: _limits,
            cancellationToken: CancellationController().token,
          ),
        ),
        resourceReader: _Reader(success.resource),
      );
      expect(output, isA<PdfRenderSuccess>());
      final image = await preparePdfRasterImage(
        (output as PdfRenderSuccess).output,
        CancellationController().token,
      );
      expect(image, isNotNull);
      image!.dispose();
      expect(output.output.rgbaBytes.toSet().length, greaterThan(2));
      expect(success.resource.bytes, bytes);
      measurements.add({
        'fixture': name,
        'open_render_image_ms': watch.elapsedMilliseconds,
      });
      await _noWorkers();
    }
    // ignore: avoid_print
    print('PRIVATE_ORDINARY_END_TO_END ${jsonEncode(measurements)}');
  }, skip: !host);

  test('private Linux known failures are redacted and valid recovery follows each rejection', () async {
    final backend = createLinuxIsolatedPdfBackend(bundle: _bundle);
    for (final entry in <(Uint8List, LocalPdfOpenFailureReason)>[
      (_fixture('password'), LocalPdfOpenFailureReason.passwordRequired),
      (
        _fixture('encrypted-empty-password'),
        LocalPdfOpenFailureReason.unsupported,
      ),
      (_fixture('too-many-pages'), LocalPdfOpenFailureReason.limitExceeded),
      (
        Uint8List.fromList('%PDF-malformed private source'.codeUnits),
        LocalPdfOpenFailureReason.failed,
      ),
    ]) {
      final result = await _workflow(backend, entry.$1).open(
        cancellationToken: CancellationController().token,
        stillCurrent: () => true,
      );
      expect(
        result,
        isA<LocalPdfOpenFailure>().having((r) => r.reason, 'reason', entry.$2),
      );
      expect(result.toString(), isNot(contains('private source')));
      await _noWorkers();
      final recovered = await _workflow(backend, _fixture('text')).open(
        cancellationToken: CancellationController().token,
        stillCurrent: () => true,
      );
      expect(recovered, isA<LocalPdfOpenSuccess>());
      await _noWorkers();
    }
  }, skip: !host);

  test('private Linux cancelled and stale ordinary opening never publishes and recovers', () async {
    final backend = createLinuxIsolatedPdfBackend(bundle: _bundle);
    final bytes = Uint8List(50000000)..setAll(0, _fixture('text'));
    bytes.fillRange(_fixture('text').length, bytes.length, 32);
    for (final cancel in [false, true]) {
      final token = CancellationController();
      var current = true;
      final pending = _workflow(
        backend,
        bytes,
      ).open(cancellationToken: token.token, stillCurrent: () => current);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      current = false;
      if (cancel) token.cancel();
      expect(await pending, isA<LocalPdfOpenCancelled>());
      await _noWorkers();
    }
    expect(
      await _workflow(backend, _fixture('mixed')).open(
        cancellationToken: CancellationController().token,
        stillCurrent: () => true,
      ),
      isA<LocalPdfOpenSuccess>(),
    );
    await _noWorkers();
  }, skip: !host);

  test(
    'private Linux near-limit source heartbeat cancellation and memory evidence',
    () async {
      final source = Uint8List(50000000)..setAll(0, _fixture('text'));
      // Trailing PDF whitespace permits exact 50 MB without larger parser content.
      source.fillRange(_fixture('text').length, source.length, 32);
      final backend = createLinuxIsolatedPdfBackend(bundle: _bundle);
      final watch = Stopwatch()..start();
      var previous = 0;
      var maximumGapUs = 0;
      var peakRss = ProcessInfo.currentRss;
      var ticks = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = watch.elapsedMicroseconds;
        final gap = now - previous;
        if (gap > maximumGapUs) maximumGapUs = gap;
        previous = now;
        ticks++;
        if (ProcessInfo.currentRss > peakRss) peakRss = ProcessInfo.currentRss;
      });
      try {
        final opened = await _workflow(backend, source).open(
          cancellationToken: CancellationController().token,
          stillCurrent: () => true,
        );
        expect(opened, isA<LocalPdfOpenSuccess>());
        final openMs = watch.elapsedMilliseconds;
        final success = opened as LocalPdfOpenSuccess;
        final reference = success.root.pages.single.layers
            .whereType<PdfSourceLayer>()
            .single
            .reference;
        final rendered = await backend.render(
          geometryOk(
            PdfRenderRequest.create(
              reference: reference,
              trust: PdfInputTrust.untrusted,
              region: PdfPageClip.full,
              pixelWidth: 400,
              pixelHeight: 300,
              includeSafeNativeAppearances: false,
              limits: _limits,
              cancellationToken: CancellationController().token,
            ),
          ),
          resourceReader: _Reader(success.resource),
        );
        expect(rendered, isA<PdfRenderSuccess>());
        final image = await preparePdfRasterImage(
          (rendered as PdfRenderSuccess).output,
          CancellationController().token,
        );
        expect(image, isNotNull);
        image!.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 2));
        expect(ticks, greaterThan(10));
        // Honest evidence, not a smooth-frame or whole-process memory guarantee.
        // ignore: avoid_print
        print(
          'PRIVATE_NEAR_LIMIT ${jsonEncode({'bytes': source.length, 'open_ms': openMs, 'open_render_image_ms': watch.elapsedMilliseconds, 'max_gap_us': maximumGapUs, 'heartbeat_ticks': ticks, 'sampled_parent_peak_rss_bytes': peakRss, 'parent_max_rss_bytes': ProcessInfo.maxRss})}',
        );
      } finally {
        heartbeat.cancel();
      }
      for (var i = 0; i < 3; i++) {
        final cancellation = CancellationController();
        final pending = preparePdfSource(
          source,
          source.length,
          cancellation.token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final cancelWatch = Stopwatch()..start();
        cancellation.cancel();
        await expectLater(pending, throwsFormatException);
        // ignore: avoid_print
        print(
          'PRIVATE_NEAR_LIMIT_CANCEL_MS ${cancelWatch.elapsedMilliseconds}',
        );
      }
      expect(
        await _workflow(backend, _fixture('text')).open(
          cancellationToken: CancellationController().token,
          stillCurrent: () => true,
        ),
        isA<LocalPdfOpenSuccess>(),
      );
      await _noWorkers();
    },
    skip: !host,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
