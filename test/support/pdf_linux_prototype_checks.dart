// SPDX-License-Identifier: GPL-3.0-or-later
part of '../widget_test.dart';

void _pdfLinuxPrototypeChecks() {
  if (!const bool.fromEnvironment('ALNOTE_LINUX_PDF_PROTOTYPE')) return;
  for (final failure in [
    'malformed',
    'timeout',
    'cancelled',
    'missing',
    'limits',
    'short-input',
    'integer-metadata',
    'oversized-coordinate',
  ]) {
    testWidgets('PDF isolated Linux failure retains Canvas state $failure', (
      tester,
    ) async {
      final generator = _PdfCallbackUuidGenerator();
      final backend = _LinuxPrototypeFailureBackend(failure);
      final runtime = _runtime(
        uuidGenerator: generator,
        pdfProcessingLimits: _widgetPdfProcessingLimits(),
        pdfBackend: backend,
        localPdfOpenWorkflow: LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(
            host: _WidgetPdfPicker(markedPdf(geometryCases.first, 0)),
          ),
          backend: backend,
          modelLimits: _widgetPdfModelLimits(),
          processingLimits: _widgetPdfProcessingLimits(),
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('text'));
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.bySemanticsLabel('Handwriting canvas')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'saved original',
      );
      await _commitInlineText(tester);
      await tester.pump();
      await tester.ensureVisible(find.text('Save in memory'));
      await tester.tap(find.text('Save in memory'));
      await tester.pumpAndSettle();
      final object = runtime
          .initialCoordinator
          .snapshot
          .root
          .pages
          .single
          .layers
          .whereType<ContentLayer>()
          .single
          .objects
          .single;
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        _textObjectCenterGlobal(tester, runtime, object),
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'retained live draft',
      );
      final before = runtime.initialCoordinator.snapshot;
      final history = runtime.initialCoordinator.retainedHistoryCount;
      final saved = _canvasPainter(tester).savedBytes;
      final selection = _canvasPainter(tester).selectionFrame;
      final primitives = _canvasPainter(tester).selectionPrimitiveCount;
      final uuids = generator.calls;
      var publications = 0;
      _ok(runtime.initialCoordinator.addListener((_) => publications++));
      expect(saved, isNotNull);
      await tester.ensureVisible(find.byKey(const Key('open-pdf')));
      await tester.tap(find.byKey(const Key('open-pdf')));
      await _waitPdf(tester, () => backend.completed.isCompleted);
      await tester.pumpAndSettle();
      expect(backend.workerExit, 0, reason: backend.diagnostic);
      expect(backend.diagnostic, contains('"ok": false'));
      _expectPdfSnapshotUnchanged(runtime.initialCoordinator.snapshot, before);
      expect(runtime.initialCoordinator.retainedHistoryCount, history);
      expect(_canvasPainter(tester).savedBytes, same(saved));
      expect(_canvasPainter(tester).selectionFrame, selection);
      expect(_canvasPainter(tester).selectionPrimitiveCount, primitives);
      expect(generator.calls, uuids);
      expect(publications, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        'retained live draft',
      );
      expect(tester.takeException(), isNull);
    });
  }
}

final class _LinuxPrototypeFailureBackend implements PdfBackend {
  _LinuxPrototypeFailureBackend(this.failure);
  final String failure;
  final completed = Completer<void>();
  int? workerExit;
  String diagnostic = '';

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    try {
      // The test process runs in Distrobox; containment is created on Bazzite.
      // The helper only accepts fixed, generated/admitted failure controls.
      final result = await Process.run('/usr/bin/distrobox-host-exec', [
        '/usr/bin/python3',
        '${Directory.current.path}/tool/linux_pdf/check_failure.py',
        failure,
      ]);
      workerExit = result.exitCode;
      diagnostic = '${result.stdout}\n${result.stderr}';
      return const PdfCorrupt();
    } finally {
      completed.complete();
    }
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async => const PdfRenderFailure(PdfRenderFailureReason.backendUnavailable);

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => const QuarantinedPdfBackend().extractText(
    request,
    resourceReader: resourceReader,
  );

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => const QuarantinedPdfBackend().extractLinks(
    request,
    resourceReader: resourceReader,
  );
}
