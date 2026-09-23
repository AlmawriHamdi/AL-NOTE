// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart' show ResourceIdentity;
import 'package:al_note/documents/pdf.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_backend.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_extraction.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_resources.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdf_extraction_fixture.dart';
import '../support/pdf_geometry_checks.dart';

final _enabled =
    Platform.isLinux &&
    linuxPrivatePdfTestEnabled &&
    const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_HOST_TEST');

PdfProcessingLimits extractionLimits({
  int glyphs = 8192,
  int links = 256,
  int operations = 4096,
}) => geometryOk(
  PdfProcessingLimits.create(
    maximumEncodedBytes: 50000000,
    maximumPageCount: 1000,
    maximumRenderDimension: 4096,
    maximumRenderPixels: 16777216,
    maximumExtractedGlyphs: glyphs,
    maximumLinks: links,
    maximumOperations: operations,
  ),
);

void main() {
  _behaviorChecks();
  _transportChecks();
  for (final rotation in PdfPageRotation.values) {
    test(
      'HOST extraction Unicode and exact glyph geometry rotation ${rotation.degrees}',
      () async {
        final backend = createLinuxIsolatedPdfBackend(
          bundle: Directory('build/linux-pdf-resources'),
        );
        final reader = GeometryReader(
          extractionFixture(rotation: rotation.degrees),
        );
        final limits = extractionLimits();
        final inspection = await backend.inspect(
          PdfInspectRequest(
            resourceIdentity: geometryIdentity,
            trust: PdfInputTrust.untrusted,
            modelLimits: geometryModelLimits,
            limits: limits,
            cancellationToken: CancellationController().token,
          ),
          resourceReader: reader,
        );
        expect(inspection, isA<PdfInspectSuccess>());
        final page = (inspection as PdfInspectSuccess).pages.first;
        final reference = geometryOk(
          PdfPageReference.create(
            resourceIdentity: geometryIdentity,
            pageIndex: page.pageIndex,
            boxKind: page.boxKind,
            sourceBox: page.sourceBox,
            rotation: page.rotation,
            displayedWidth: page.displayedWidth,
            displayedHeight: page.displayedHeight,
            limits: geometryModelLimits,
          ),
        );
        final extracted = await backend.extractText(
          PdfTextExtractRequest(
            reference: reference,
            trust: PdfInputTrust.untrusted,
            region: PdfPageClip.full,
            limits: limits,
            cancellationToken: CancellationController().token,
          ),
          resourceReader: reader,
        );
        expect(extracted, isA<Ok<PdfExtractedText, StructuredFailure>>());
        final text =
            (extracted as Ok<PdfExtractedText, StructuredFailure>).value;
        expect(text.text, 'Ω😀');
        expect(text.glyphs, hasLength(2));
        final expected = switch (rotation) {
          PdfPageRotation.degrees0 => [10.0, 36.0, 20.0, 50.0],
          PdfPageRotation.degrees90 => [10.0, 10.0, 24.0, 20.0],
          PdfPageRotation.degrees180 => [30.0, 10.0, 40.0, 24.0],
          PdfPageRotation.degrees270 => [36.0, 30.0, 50.0, 40.0],
        };
        final b = text.glyphs!.first.bounds!;
        final actual = [b.left, b.top, b.right, b.bottom];
        for (var i = 0; i < 4; i++) {
          expect(actual[i], closeTo(expected[i], .00001));
        }
      },
      skip: !_enabled,
    );
  }
}

Future<
  ({PdfBackend backend, PdfPageReference reference, GeometryReader reader})
>
_prepare(List<int> bytes) async {
  final backend = createLinuxIsolatedPdfBackend(
    bundle: Directory('build/linux-pdf-resources'),
  );
  final reader = GeometryReader(bytes);
  final inspected = await backend.inspect(
    PdfInspectRequest(
      resourceIdentity: geometryIdentity,
      trust: PdfInputTrust.untrusted,
      modelLimits: geometryModelLimits,
      limits: extractionLimits(),
      cancellationToken: CancellationController().token,
    ),
    resourceReader: reader,
  );
  expect(inspected, isA<PdfInspectSuccess>());
  final page = (inspected as PdfInspectSuccess).pages.first;
  final reference = geometryOk(
    PdfPageReference.create(
      resourceIdentity: geometryIdentity,
      pageIndex: page.pageIndex,
      boxKind: page.boxKind,
      sourceBox: page.sourceBox,
      rotation: page.rotation,
      displayedWidth: page.displayedWidth,
      displayedHeight: page.displayedHeight,
      limits: geometryModelLimits,
    ),
  );
  return (backend: backend, reference: reference, reader: reader);
}

PdfTextExtractRequest _textRequest(
  PdfPageReference reference, {
  PdfProcessingLimits? limits,
  PdfPageClip? region,
  CancellationToken? token,
}) => PdfTextExtractRequest(
  reference: reference,
  trust: PdfInputTrust.untrusted,
  region: region ?? PdfPageClip.full,
  limits: limits ?? extractionLimits(),
  cancellationToken: token ?? CancellationController().token,
);

PdfLinkExtractRequest _linkRequest(
  PdfPageReference reference, {
  PdfProcessingLimits? limits,
  PdfPageClip? region,
  bool allowHttp = false,
  CancellationToken? token,
}) => PdfLinkExtractRequest(
  reference: reference,
  trust: PdfInputTrust.untrusted,
  region: region ?? PdfPageClip.full,
  limits: limits ?? extractionLimits(),
  allowExternalHttpMetadata: allowHttp,
  cancellationToken: token ?? CancellationController().token,
);

void _behaviorChecks() {
  group('HOST extraction behavior', () {
    test('negative source origin and partial region preserve exact scalar geometry', () async {
      final host = await _prepare(extractionFixture(negativeOrigin: true));
      final result = await host.backend.extractText(
        _textRequest(
          host.reference,
          region: geometryOk(
            PdfPageClip.create(left: 0, top: 0, right: .3, bottom: 1),
          ),
        ),
        resourceReader: host.reader,
      );
      expect(result, isA<Ok<PdfExtractedText, StructuredFailure>>());
      final text = (result as Ok<PdfExtractedText, StructuredFailure>).value;
      expect(text.text, 'Ω');
      final b = text.glyphs!.single.bounds!;
      expect([b.left, b.top, b.right, b.bottom], [10, 36, 15, 50]);
    });
    for (final scanned in [false, true]) {
      test(
        'complete empty embedded-text projection, image-only $scanned',
        () async {
          final host = await _prepare(
            extractionFixture(scanned: scanned, text: ''),
          );
          final result = await host.backend.extractText(
            _textRequest(host.reference),
            resourceReader: host.reader,
          );
          expect(result, isA<Ok<PdfExtractedText, StructuredFailure>>());
          final text =
              (result as Ok<PdfExtractedText, StructuredFailure>).value;
          expect(text.text, isEmpty);
          expect(text.glyphs, isEmpty);
        },
      );
    }
    test(
      'exact scalar limit includes surrogate pairs without publishing a prefix',
      () async {
        final host = await _prepare(extractionFixture());
        final exact = await host.backend.extractText(
          _textRequest(host.reference, limits: extractionLimits(glyphs: 2)),
          resourceReader: host.reader,
        );
        expect(exact, isA<Ok<PdfExtractedText, StructuredFailure>>());
        expect(
          (exact as Ok<PdfExtractedText, StructuredFailure>).value.text,
          'Ω😀',
        );
        final exceeded = await host.backend.extractText(
          _textRequest(host.reference, limits: extractionLimits(glyphs: 1)),
          resourceReader: host.reader,
        );
        expect(exceeded, isA<Err<PdfExtractedText, StructuredFailure>>());
        expect(
          (exceeded as Err<PdfExtractedText, StructuredFailure>).error.code,
          endsWith('.limit_exceeded'),
        );
      },
    );
    test('internal destinations and explicitly permitted HTTP classifications are inert', () async {
      final host = await _prepare(
        extractionFixture(
          links: [
            '/Dest [4 0 R /Fit]',
            '/A << /S /URI /URI (https://example.invalid/path?q=secret) >>',
          ],
        ),
      );
      final denied = await host.backend.extractLinks(
        _linkRequest(host.reference),
        resourceReader: host.reader,
      );
      expect(denied, isA<Err<PdfSafeLinks, StructuredFailure>>());
      expect(
        (denied as Err<PdfSafeLinks, StructuredFailure>).error.code,
        endsWith('.unsupported'),
      );
      final result = await host.backend.extractLinks(
        _linkRequest(
          host.reference,
          allowHttp: true,
          limits: extractionLimits(links: 2),
        ),
        resourceReader: host.reader,
      );
      expect(result, isA<Ok<PdfSafeLinks, StructuredFailure>>());
      final links = (result as Ok<PdfSafeLinks, StructuredFailure>).value;
      expect(links.links.map((v) => v.kind), [
        PdfSafeLinkKind.internalPage,
        PdfSafeLinkKind.externalReference,
      ]);
      expect(links.links.first.destinationPageIndex, 1);
      final b = links.links.first.bounds;
      expect([b.left, b.top, b.right, b.bottom], [10, 36, 20, 50]);
      expect(links.toString(), isNot(contains('secret')));
      expect(
        links.links.last.toString(),
        'PdfSafeLinkMetadata(externalReference)',
      );
      expect(links.links.clear, throwsUnsupportedError);
      for (final limits in [
        extractionLimits(links: 1),
        extractionLimits(operations: 1),
      ]) {
        final exceeded = await host.backend.extractLinks(
          _linkRequest(host.reference, allowHttp: true, limits: limits),
          resourceReader: host.reader,
        );
        expect(exceeded, isA<Err<PdfSafeLinks, StructuredFailure>>());
        expect(
          (exceeded as Err<PdfSafeLinks, StructuredFailure>).error.code,
          endsWith('.limit_exceeded'),
        );
      }
    });
    for (final entry in <(String, String)>[
      ('file-uri', '/A << /S /URI /URI (file:///tmp/private) >>'),
      ('javascript-uri', '/A << /S /URI /URI (javascript:run) >>'),
      ('custom-uri', '/A << /S /URI /URI (custom:run) >>'),
      ('malformed-http', '/A << /S /URI /URI (https://) >>'),
      ('launch', '/A << /S /Launch /F (private) >>'),
      ('javascript', '/A << /S /JavaScript /JS (private) >>'),
      ('remote-goto', '/A << /S /GoToR /F (private) /D [0 /Fit] >>'),
      ('bad-destination', '/A << /S /GoTo /D [99 /Fit] >>'),
      ('missing-action', ''),
    ]) {
      test('reject forbidden/malformed annotation ${entry.$1}', () async {
        final host = await _prepare(extractionFixture(links: [entry.$2]));
        final result = await host.backend.extractLinks(
          _linkRequest(host.reference, allowHttp: true),
          resourceReader: host.reader,
        );
        expect(result, isA<Err<PdfSafeLinks, StructuredFailure>>());
        final failure = (result as Err<PdfSafeLinks, StructuredFailure>).error;
        expect(failure.code, endsWith('.unsupported'));
        expect(failure.toString(), isNot(contains('private')));
      });
    }
    test('URI byte limits reject before native buffer allocation', () async {
      for (final length in [2048, 2049]) {
        const prefix = 'https://example.invalid/';
        final uri = prefix + 'a' * (length - prefix.length);
        final host = await _prepare(
          extractionFixture(links: ['/A << /S /URI /URI ($uri) >>']),
        );
        final result = await host.backend.extractLinks(
          _linkRequest(host.reference, allowHttp: true),
          resourceReader: host.reader,
        );
        if (length == 2048) {
          expect(result, isA<Ok<PdfSafeLinks, StructuredFailure>>());
        } else {
          expect(result, isA<Err<PdfSafeLinks, StructuredFailure>>());
          expect(
            (result as Err<PdfSafeLinks, StructuredFailure>).error.code,
            endsWith('.limit_exceeded'),
          );
        }
      }
    });
    test('cancellation preserves ownership, rejects competing extraction, then recovers', () async {
      final host = await _prepare(extractionFixture());
      final slow = _DeferredReader(host.reader);
      final cancellation = CancellationController();
      final old = host.backend.extractText(
        _textRequest(host.reference, token: cancellation.token),
        resourceReader: slow,
      );
      await slow.started.future;
      final pendingReader = _CountingReader(host.reader);
      final busy = await host.backend.extractLinks(
        _linkRequest(host.reference),
        resourceReader: pendingReader,
      );
      expect(busy, isA<Err<PdfSafeLinks, StructuredFailure>>());
      expect(
        (busy as Err<PdfSafeLinks, StructuredFailure>).error.code,
        endsWith('.busy'),
      );
      expect(pendingReader.calls, 0);
      final obsoleteReader = _CountingReader(host.reader);
      final latestReader = _CountingReader(host.reader);
      PdfRenderRequest renderRequest(int size) => geometryOk(
        PdfRenderRequest.create(
          reference: host.reference,
          trust: PdfInputTrust.untrusted,
          region: PdfPageClip.full,
          pixelWidth: size,
          pixelHeight: size,
          includeSafeNativeAppearances: false,
          limits: extractionLimits(),
          cancellationToken: CancellationController().token,
        ),
      );
      final obsolete = host.backend.render(
        renderRequest(40),
        resourceReader: obsoleteReader,
      );
      final latest = host.backend.render(
        renderRequest(80),
        resourceReader: latestReader,
      );
      cancellation.cancel();
      slow.release.complete();
      final cancelled = await old;
      expect(cancelled, isA<Err<PdfExtractedText, StructuredFailure>>());
      expect(
        (cancelled as Err<PdfExtractedText, StructuredFailure>).error.code,
        endsWith('.cancelled'),
      );
      expect(await obsolete, isA<PdfRenderFailure>());
      expect(obsoleteReader.calls, 0);
      final rendered = await latest;
      expect(rendered, isA<PdfRenderSuccess>());
      expect(latestReader.calls, 1);
      for (var attempt = 0; attempt < 3; attempt++) {
        final token = CancellationController()..cancel();
        final rejected = await host.backend.extractText(
          _textRequest(host.reference, token: token.token),
          resourceReader: pendingReader,
        );
        expect(rejected, isA<Err<PdfExtractedText, StructuredFailure>>());
      }
      expect(pendingReader.calls, 0);
      final recovered = await host.backend.extractText(
        _textRequest(host.reference),
        resourceReader: host.reader,
      );
      expect(recovered, isA<Ok<PdfExtractedText, StructuredFailure>>());
    });
  }, skip: !_enabled);
}

final class _DeferredReader implements PdfResourceReader {
  _DeferredReader(this.delegate);
  final PdfResourceReader delegate;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async {
    started.complete();
    await release.future;
    return delegate.read(
      identity: identity,
      limits: limits,
      cancellationToken: cancellationToken,
    );
  }
}

final class _CountingReader implements PdfResourceReader {
  _CountingReader(this.delegate);
  final PdfResourceReader delegate;
  int calls = 0;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    calls++;
    return delegate.read(
      identity: identity,
      limits: limits,
      cancellationToken: cancellationToken,
    );
  }
}

void _transportChecks() {
  test('HOST extraction hostile output and surviving descendants are discarded and reaped', () async {
    final stage = await LinuxPdfResources(
      Directory('build/linux-pdf-resources'),
    ).stage(CancellationController().token);
    addTearDown(() => stage.deleteSync(recursive: true));
    File('${stage.path}/worker').deleteSync();
    File('build/linux-pdf-tools/protocol-worker')
        .copySync('${stage.path}/worker');
    const request = LinuxPdfExtractionRequest(
      operation: LinuxPdfExtractionOperation.text,
      pageIndex: 0,
      maximumPages: 1000,
      maximumGlyphs: 8192,
      maximumLinks: 256,
      maximumOperations: 4096,
    );
    const response = <String, Object>{
      'version': 1,
      'id': 1,
      'status': 'ok',
      'operation': 'text',
      'pageIndex': 0,
      'pageCount': 1,
      'complete': true,
      'count': 1,
      'records': [
        [
          65,
          [0, 0, 1, 1],
        ],
      ],
      'page': {
        'kind': 'resolvedBounds',
        'bounds': [0, 0, 1, 1],
        'rotation': 0,
        'width': 1,
        'height': 1,
      },
    };
    Uint8List frame(Object value) {
      final bytes = utf8.encode(jsonEncode(value));
      return Uint8List.fromList([
        ...(ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List(),
        ...bytes,
      ]);
    }

    for (final (name, bytes, mode) in <(String, List<int>, int)>[
      ('float-count', frame({...response, 'count': 1.0}), 6),
      ('forged-completeness', frame({...response, 'complete': false}), 6),
      (
        'surrogate',
        frame({
          ...response,
          'records': [
            [
              0xd800,
              [0, 0, 1, 1],
            ],
          ],
        }),
        6,
      ),
      (
        'unpositioned',
        frame({
          ...response,
          'records': [
            [65, null],
          ],
        }),
        6,
      ),
      ('truncated', frame(response).sublist(0, 40), 0),
      ('oversized', [255, 255, 255, 255], 6),
      ('extra', [...frame(response), ...frame(response)], 6),
      ('crash', frame(response), 11),
      ('nonzero', frame(response), 1),
      ('short-input', frame(response), 3),
      ('cancel-descendant', frame(response), 6),
    ]) {
      File('${stage.path}/response').writeAsBytesSync(bytes);
      File('${stage.path}/mode').writeAsStringSync('$mode');
      final controller = CancellationController();
      final timer = name == 'cancel-descendant'
          ? Timer(const Duration(milliseconds: 250), controller.cancel)
          : null;
      try {
        await expectLater(
          const LinuxPdfSupervisor().operate(
            runtime: stage,
            source: name == 'short-input' ? Uint8List(1000000) : [1, 2, 3],
            token: controller.token,
            extraction: request,
          ),
          throwsFormatException,
          reason: name,
        );
      } finally {
        timer?.cancel();
      }
      await _expectCleanup(name);
    }
    File('${stage.path}/response').writeAsBytesSync(frame(response));
    File('${stage.path}/mode').writeAsStringSync('0');
    final recovered = await const LinuxPdfSupervisor().operate(
      runtime: stage,
      source: [1, 2, 3],
      token: CancellationController().token,
      extraction: request,
    );
    expect(recovered, hasLength(2));
    await _expectCleanup('valid recovery');
  }, skip: !_enabled);
  test(
    'HOST real native extraction repeated cancellation reaps before recovery',
    () async {
      final source = File('test/fixtures/phase8/linux-integration/heavy.pdf')
          .readAsBytesSync();
      final stage = await LinuxPdfResources(
        Directory('build/linux-pdf-resources'),
      ).stage(CancellationController().token);
      addTearDown(() => stage.deleteSync(recursive: true));
      const request = LinuxPdfExtractionRequest(
        operation: LinuxPdfExtractionOperation.text,
        pageIndex: 0,
        maximumPages: 1000,
        maximumGlyphs: 8192,
        maximumLinks: 256,
        maximumOperations: 4096,
      );
      for (var i = 0; i < 3; i++) {
        final controller = CancellationController();
        final timer = Timer(
          const Duration(milliseconds: 200),
          controller.cancel,
        );
        try {
          await expectLater(
            const LinuxPdfSupervisor().operate(
              runtime: stage,
              source: source,
              token: controller.token,
              extraction: request,
            ),
            throwsFormatException,
          );
        } finally {
          timer.cancel();
        }
        await _expectCleanup('native cancellation');
      }
      final result = await const LinuxPdfSupervisor().operate(
        runtime: stage,
        source: extractionFixture(),
        token: CancellationController().token,
        extraction: request,
      );
      expect((result[1] as Map)['count'], 2);
      await _expectCleanup('native recovery');
    },
    skip: !_enabled,
  );
}

Future<void> _expectCleanup(String reason) async {
  final units = await Process.run('/usr/bin/systemctl', [
    '--user',
    'list-units',
    '--state=running',
    '--no-legend',
    '--plain',
    'alnote-pdf-*.service',
  ]);
  expect(units.exitCode, 0);
  expect(units.stdout.toString().trim(), isEmpty, reason: reason);
  expect(LinuxPdfSupervisor.cleanupUnconfirmed, isFalse);
}
