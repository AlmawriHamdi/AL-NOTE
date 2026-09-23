// SPDX-License-Identifier: GPL-3.0-or-later
part of '../widget_test.dart';

void _pdfLinuxIntegrationChecks() {
  if (!Platform.isLinux ||
      !(const bool.fromEnvironment('ALNOTE_LINUX_INTEGRATION_TEST') ||
          (linuxPrivatePdfTestEnabled &&
              const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_HOST_TEST'))))
    return;
  for (final missing in [false, true]) {
    testWidgets('Linux integrated open with live draft missing=$missing', (
      tester,
    ) async {
      final backend = _TrackedLinuxBackend(
        createLinuxIsolatedPdfBackend(
          bundle: Directory(
            missing
                ? 'build/missing-linux-pdf-package'
                : 'build/linux-pdf-resources',
          ),
        ),
      );
      final generator = _PdfCallbackUuidGenerator();
      final runtime = _runtime(
        uuidGenerator: generator,
        pdfProcessingLimits: _linuxIntegrationProcessingLimits(),
        pdfBackend: backend,
        localPdfOpenWorkflow: LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(
            host: _WidgetPdfPicker(
              File('test/fixtures/phase8/linux-integration/ordinary.pdf')
                  .readAsBytesSync(),
            ),
          ),
          backend: backend,
          modelLimits: _widgetPdfModelLimits(),
          processingLimits: _linuxIntegrationProcessingLimits(),
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
        'retained or committed draft',
      );
      if (missing) {
        // Preserve an actual saved notebook and selected existing object through
        // rejection, matching the independent auditor's stronger reproducer.
        await _commitInlineText(tester);
        await tester.pump();
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
        await tester.ensureVisible(find.text('Save in memory'));
        await tester.tap(find.text('Save in memory'));
        await tester.pumpAndSettle();
        expect(_canvasPainter(tester).savedBytes, isNotEmpty);
        await tester.tap(find.text('selection'));
        await tester.pump();
        final select = await tester.startGesture(
          _textObjectCenterGlobal(tester, runtime, object),
          kind: PointerDeviceKind.mouse,
        );
        await select.up();
        await tester.pump();
        expect(_canvasPainter(tester).selectionFrame, isNotNull);
        await tester.tap(find.byKey(const Key('edit-selected-text')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('text-object-editor')),
          'changed retained draft',
        );
      }
      final before = runtime.initialCoordinator.snapshot;
      final history = runtime.initialCoordinator.retainedHistoryCount;
      final saved = _canvasPainter(tester).savedBytes;
      final selection = _canvasPainter(tester).selectionFrame;
      final uuids = generator.calls;
      var publications = 0;
      _ok(runtime.initialCoordinator.addListener((_) => publications++));
      final watch = Stopwatch()..start();
      await tester.ensureVisible(find.byKey(const Key('open-pdf')));
      await tester.tap(find.byKey(const Key('open-pdf')));
      await _waitLinuxPdf(tester, () => backend.inspections == 1);
      await tester.pumpAndSettle();
      if (missing) {
        _expectPdfSnapshotUnchanged(
          runtime.initialCoordinator.snapshot,
          before,
        );
        expect(runtime.initialCoordinator.retainedHistoryCount, history);
        expect(_canvasPainter(tester).savedBytes, same(saved));
        expect(_canvasPainter(tester).selectionFrame, selection);
        expect(generator.calls, uuids);
        expect(publications, 0);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('text-object-editor')))
              .controller!
              .text,
          'changed retained draft',
        );
      } else {
        await _waitLinuxPdf(
          tester,
          () => _documentPainter(tester).hasRenderedPdfPage,
        );
        expect(find.text('Page 1 of 3'), findsOneWidget);
        expect(find.byKey(const Key('text-object-editor')), findsNothing);
        expect(
          publications,
          1,
          reason: 'intended draft commits once before replacement',
        );
        expect(runtime.initialCoordinator.retainedHistoryCount, history + 1);
        expect(_canvasPainter(tester).savedBytes, isNull);
        // ignore: avoid_print
        print('LINUX_CANVAS_OPEN_FIRST_IMAGE_MS ${watch.elapsedMilliseconds}');
        final rounds = <int>[];
        for (var i = 0; i < 3; i++) {
          final round = Stopwatch()..start();
          await tester.tap(find.byKey(const Key('next-page')));
          await tester.pump();
          await tester.tap(find.text('Zoom In'));
          await tester.pump();
          await tester.tap(find.byKey(const Key('previous-page')));
          await tester.pump();
          await tester.tap(find.byKey(const Key('next-page')));
          await tester.pump();
          await _waitLinuxPdf(
            tester,
            () => _documentPainter(tester).hasRenderedPdfPage,
          );
          rounds.add(round.elapsedMilliseconds);
          if (i == 1) {
            await tester.tap(find.byKey(const Key('previous-page')));
            await tester.pump();
            await _waitLinuxPdf(
              tester,
              () => _documentPainter(tester).hasRenderedPdfPage,
            );
          }
        }
        expect(backend.maximumInspections, 1);
        expect(backend.lastSuccessfulPage, 2);
        // ignore: avoid_print
        print('LINUX_CANVAS_NAVIGATION_ZOOM_MS $rounds');
        await tester.ensureVisible(find.text('Save in memory'));
        await tester.tap(find.text('Save in memory'));
        await tester.pumpAndSettle();
        expect(_canvasPainter(tester).savedBytes, isNotNull);
        await tester.tap(find.text('Reopen saved'));
        await tester.pump();
        await _waitLinuxPdf(
          tester,
          () => _documentPainter(tester).hasRenderedPdfPage,
        );
        expect(find.text('Page 1 of 3'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Linux integrated in-flight disposal cancels publication and reaps',
    (tester) async {
      final backend = _TrackedLinuxBackend(
        createLinuxIsolatedPdfBackend(
          bundle: Directory('build/linux-pdf-resources'),
        ),
      );
      final runtime = _runtime(
        pdfBackend: backend,
        pdfProcessingLimits: _linuxIntegrationProcessingLimits(),
        localPdfOpenWorkflow: LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(
            host: _WidgetPdfPicker(
              File('test/fixtures/phase8/linux-integration/heavy.pdf')
                  .readAsBytesSync(),
            ),
          ),
          backend: backend,
          modelLimits: _widgetPdfModelLimits(),
          processingLimits: _linuxIntegrationProcessingLimits(),
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.ensureVisible(find.byKey(const Key('open-pdf')));
      await tester.tap(find.byKey(const Key('open-pdf')));
      expect(
        PdfFixtureAdmission.permits(
          File('test/fixtures/phase8/linux-integration/heavy.pdf')
              .readAsBytesSync(),
          CancellationController().token,
        ),
        const bool.fromEnvironment('ALNOTE_LINUX_INTEGRATION_TEST'),
      );
      await _waitLinuxPdf(tester, () => backend.inspections == 1);
      expect(backend.lastInspection, isA<PdfInspectSuccess>());
      await _waitLinuxPdf(tester, () => backend.renderTokens.isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(backend.renderTokens.every((token) => token.isCancelled), isTrue);
      await _waitLinuxPdf(tester, () => backend.activeRenders == 0);
      expect(backend.renderSuccesses, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

final class _TrackedLinuxBackend
    implements PdfBackend, PdfAdmissionProvider, PdfLifecycleProvider {
  _TrackedLinuxBackend(this.delegate);
  final PdfBackend delegate;
  @override
  PdfAdmissionPolicy get admissionPolicy => pdfAdmissionFor(delegate);
  @override
  PdfBackendLifecycle get lifecycle =>
      (delegate as PdfLifecycleProvider).lifecycle;
  int inspections = 0;
  PdfInspectOutcome? lastInspection;
  int activeInspections = 0;
  int maximumInspections = 0;
  int activeRenders = 0;
  int renderSuccesses = 0;
  int? lastSuccessfulPage;
  final renderTokens = <CancellationToken>[];
  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    activeInspections++;
    maximumInspections = math.max(maximumInspections, activeInspections);
    try {
      return lastInspection = await delegate.inspect(
        request,
        resourceReader: resourceReader,
      );
    } finally {
      activeInspections--;
      inspections++;
    }
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    renderTokens.add(request.cancellationToken);
    activeRenders++;
    try {
      final result = await delegate.render(
        request,
        resourceReader: resourceReader,
      );
      if (result is PdfRenderSuccess) {
        renderSuccesses++;
        lastSuccessfulPage = request.reference.pageIndex;
      }
      return result;
    } finally {
      activeRenders--;
    }
  }

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => delegate.extractText(request, resourceReader: resourceReader);
  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => delegate.extractLinks(request, resourceReader: resourceReader);
}

PdfProcessingLimits _linuxIntegrationProcessingLimits() => _ok(
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

Future<void> _waitLinuxPdf(WidgetTester tester, bool Function() done) async {
  final elapsed = Stopwatch()..start();
  while (!done() && elapsed.elapsed < const Duration(seconds: 35)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    done(),
    isTrue,
    reason: 'Real Linux operation including staging and reap',
  );
}
