// SPDX-License-Identifier: GPL-3.0-or-later
part of '../widget_test.dart';

void _pdfNotebookImportChecks() {
  for (final selection in ['all', '2', '2,1-2']) {
    testWidgets(
      'Notebook PDF import $selection preserves notes, history and in-memory save',
      (tester) async {
        final runtime = _notebookImportRuntime();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final origin = tester.getCenter(canvas);
        final stroke = await tester.startGesture(
          origin,
          kind: PointerDeviceKind.stylus,
        );
        await stroke.moveBy(const Offset(25, 20));
        await stroke.up();
        await tester.pumpAndSettle();
        final before = runtime.initialCoordinator.snapshot;
        final history = runtime.initialCoordinator.retainedHistoryCount;
        await _startNotebookImport(tester);
        await tester.enterText(
          find.byKey(const Key('pdf-import-pages')),
          selection,
        );
        await tester.tap(find.byKey(const Key('confirm-pdf-import')));
        await tester.pumpAndSettle();
        final after = runtime.initialCoordinator.snapshot;
        final count = selection == '2' ? 1 : 2;
        expect(after.root.pages, hasLength(before.root.pages.length + count));
        expect(after.root.pages.first, same(before.root.pages.first));
        expect(runtime.initialCoordinator.retainedHistoryCount, history + 1);
        expect(after.resources, hasLength(1));
        expect(find.text('Page 1 of ${count + 1}'), findsOneWidget);
        await tester.ensureVisible(find.text('Undo'));
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(runtime.initialCoordinator.snapshot.root, same(before.root));
        await tester.tap(find.text('Redo'));
        await tester.pumpAndSettle();
        expect(runtime.initialCoordinator.snapshot.root, same(after.root));
        await tester.ensureVisible(find.byKey(const Key('next-page')));
        await tester.tap(find.byKey(const Key('next-page')));
        await tester.pumpAndSettle();
        await _waitPdf(
          tester,
          () => _documentPainter(tester).hasRenderedPdfPage,
        );
        final annotation = await tester.startGesture(
          tester.getCenter(canvas),
          kind: PointerDeviceKind.stylus,
        );
        await annotation.moveBy(const Offset(20, 15));
        await annotation.up();
        await tester.pumpAndSettle();
        final annotated = runtime.initialCoordinator.snapshot.root;
        expect(annotated.pages[1].layers.last.objects, isNotEmpty);
        await tester.ensureVisible(find.text('Save in memory'));
        await tester.tap(find.text('Save in memory'));
        await tester.pumpAndSettle();
        final bytes = _canvasPainter(tester).savedBytes;
        expect(bytes, isNotEmpty);
        await tester.ensureVisible(find.text('Reopen saved'));
        await tester.tap(find.text('Reopen saved'));
        await tester.pumpAndSettle();
        expect(_canvasPainter(tester).currentRoot, annotated);
        expect(_canvasPainter(tester).savedBytes, same(bytes));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final draft in ['', 'live notebook draft']) {
    testWidgets('Notebook PDF import retains live draft "$draft" and editor', (
      tester,
    ) async {
      final runtime = _notebookImportRuntime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await _notebookImportDraft(tester, draft);
      final before = runtime.initialCoordinator.snapshot;
      await _startNotebookImport(tester);
      await tester.tap(find.byKey(const Key('confirm-pdf-import')));
      await tester.pumpAndSettle();
      expect(
        runtime.initialCoordinator.snapshot.root.pages.first,
        same(before.root.pages.first),
      );
      expect(runtime.initialCoordinator.retainedHistoryCount, 1);
      expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        draft,
      );
      expect(
        runtime.initialCoordinator.snapshot.savedContentIdentity,
        before.savedContentIdentity,
      );
      final imported = runtime.initialCoordinator.snapshot.root;
      await tester.ensureVisible(find.text('Undo'));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
      await tester.tap(find.text('Redo'));
      await tester.pumpAndSettle();
      expect(runtime.initialCoordinator.snapshot.root, same(imported));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        draft,
      );
    });
  }

  testWidgets(
    'Notebook PDF import invalid selection and cancellation retain draft and state',
    (tester) async {
      final runtime = _notebookImportRuntime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await _notebookImportDraft(tester, 'retained draft');
      final before = runtime.initialCoordinator.snapshot;
      await _startNotebookImport(tester);
      await tester.enterText(
        find.byKey(const Key('pdf-import-pages')),
        '0,3-9999',
      );
      await tester.tap(find.byKey(const Key('confirm-pdf-import')));
      await tester.pump();
      expect(find.textContaining('Use all or page numbers'), findsOneWidget);
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      _expectPdfSnapshotUnchanged(runtime.initialCoordinator.snapshot, before);
      expect(runtime.initialCoordinator.retainedHistoryCount, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        'retained draft',
      );
    },
  );

  for (final action in ['cancel', 'dispose', 'failure', 'unapproved']) {
    testWidgets(
      'Notebook PDF import $action during source preparation changes nothing',
      (tester) async {
        final picker = _PendingWidgetPdfPicker();
        final backend = _WidgetPdfBackend(
          _widgetPdfModelLimits(),
          inspectionFailure: action == 'failure' ? const PdfCorrupt() : null,
        );
        final runtime = _notebookImportRuntime(
          backend: backend,
          picker: picker,
        );
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await _notebookImportDraft(tester, 'retained');
        final before = runtime.initialCoordinator.snapshot;
        await tester.ensureVisible(find.byKey(const Key('import-pdf-pages')));
        await tester.tap(find.byKey(const Key('import-pdf-pages')));
        await tester.pump();
        if (action == 'cancel') {
          await tester.ensureVisible(
            find.byKey(const Key('cancel-pdf-import')),
          );
          await tester.tap(find.byKey(const Key('cancel-pdf-import')));
        }
        if (action == 'dispose')
          await tester.pumpWidget(const SizedBox.shrink());
        picker.done.complete(
          _WidgetPdfHandle(
            action == 'unapproved'
                ? File('test/fixtures/phase8/linux-integration/ordinary.pdf')
                      .readAsBytesSync()
                : markedPdf(geometryCases.first, 0),
          ),
        );
        await tester.pumpAndSettle();
        _expectPdfSnapshotUnchanged(
          runtime.initialCoordinator.snapshot,
          before,
        );
        expect(runtime.initialCoordinator.retainedHistoryCount, 0);
        expect(find.byKey(const Key('pdf-import-pages')), findsNothing);
        if (action != 'dispose')
          expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final dispose in [false, true]) {
    testWidgets(
      'Notebook PDF import delayed backend cancellation dispose=$dispose',
      (tester) async {
        final backend = _PendingNotebookInspection();
        final runtime = _notebookImportRuntime(backend: backend);
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await _notebookImportDraft(tester, 'pending inspection draft');
        final before = runtime.initialCoordinator.snapshot;
        await tester.ensureVisible(find.byKey(const Key('import-pdf-pages')));
        await tester.tap(find.byKey(const Key('import-pdf-pages')));
        await tester.pumpAndSettle();
        await _waitPdf(tester, () => backend.token != null);
        if (dispose) {
          await tester.pumpWidget(const SizedBox.shrink());
        } else {
          await tester.ensureVisible(
            find.byKey(const Key('cancel-pdf-import')),
          );
          await tester.tap(find.byKey(const Key('cancel-pdf-import')));
        }
        expect(backend.token!.isCancelled, isTrue);
        backend.release.complete();
        await tester.pumpAndSettle();
        _expectPdfSnapshotUnchanged(
          runtime.initialCoordinator.snapshot,
          before,
        );
        expect(runtime.initialCoordinator.retainedHistoryCount, 0);
        expect(find.byKey(const Key('pdf-import-pages')), findsNothing);
        if (!dispose)
          expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Notebook PDF import disposal closes the page-selection route', (
    tester,
  ) async {
    final runtime = _notebookImportRuntime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final before = runtime.initialCoordinator.snapshot;
    await _startNotebookImport(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    _expectPdfSnapshotUnchanged(runtime.initialCoordinator.snapshot, before);
    expect(runtime.initialCoordinator.retainedHistoryCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Notebook PDF import preserves current Selection', (
    tester,
  ) async {
    final runtime = _notebookImportRuntime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final origin = tester.getCenter(
      find.bySemanticsLabel('Handwriting canvas'),
    );
    final stroke = await tester.startGesture(
      origin,
      kind: PointerDeviceKind.stylus,
    );
    await stroke.moveBy(const Offset(30, 20));
    await stroke.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final select = await tester.startGesture(
      origin + const Offset(15, 10),
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pumpAndSettle();
    final selected = _canvasPainter(tester).selectionFrame;
    expect(selected, isNotNull);
    final before = runtime.initialCoordinator.snapshot.root.pages.first;
    await _startNotebookImport(tester);
    await tester.tap(find.byKey(const Key('confirm-pdf-import')));
    await tester.pumpAndSettle();
    final retained = _canvasPainter(tester).selectionFrame;
    expect(retained, isNotNull);
    expect(retained!.viewCorners, selected!.viewCorners);
    expect(retained.rotationCenter, selected.rotationCenter);
    expect(runtime.initialCoordinator.snapshot.root.pages.first, same(before));
  });

  testWidgets(
    'Notebook PDF import Undo from an imported page reconciles navigation',
    (tester) async {
      final runtime = _notebookImportRuntime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final before = runtime.initialCoordinator.snapshot.root;
      await _startNotebookImport(tester);
      await tester.tap(find.byKey(const Key('confirm-pdf-import')));
      await tester.pumpAndSettle();
      final imported = runtime.initialCoordinator.snapshot.root;
      await tester.ensureVisible(find.byKey(const Key('next-page')));
      await tester.tap(find.byKey(const Key('next-page')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('next-page')));
      await tester.pumpAndSettle();
      await _waitPdf(tester, () => _documentPainter(tester).hasRenderedPdfPage);
      await tester.ensureVisible(find.text('Undo'));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      expect(find.text('Page 1 of 1'), findsOneWidget);
      expect(_documentPainter(tester).hasRenderedPdfPage, isFalse);
      await tester.tap(find.text('Redo'));
      await tester.pumpAndSettle();
      expect(runtime.initialCoordinator.snapshot.root, same(imported));
      expect(find.text('Page 1 of 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Notebook PDF import rejects intervening document edit', (
    tester,
  ) async {
    final runtime = _notebookImportRuntime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await _notebookImportDraft(tester, 'external commit');
    final save = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Save in memory'))
        .onPressed!;
    await _startNotebookImport(tester);
    save(); // Established Save commits the draft while the import dialog is open.
    final external = runtime.initialCoordinator.snapshot;
    await tester.tap(find.byKey(const Key('confirm-pdf-import')));
    await tester.pumpAndSettle();
    expect(runtime.initialCoordinator.snapshot.root, same(external.root));
    expect(runtime.initialCoordinator.snapshot.resources, isEmpty);
    expect(runtime.initialCoordinator.retainedHistoryCount, 1);
    expect(find.textContaining('destination changed'), findsOneWidget);
  });

  for (final withDraft in [false, true]) {
    for (final action in ['save', 'reopen', 'throw', 'dispose']) {
      testWidgets(
        'Notebook PDF import synchronous observer $action draft=$withDraft sees complete publication',
        (tester) async {
          final runtime = _notebookImportRuntime();
          await tester.pumpWidget(AlNoteApp(runtime: runtime));
          await tester.ensureVisible(find.text('Save in memory'));
          await tester.tap(find.text('Save in memory'));
          await tester.pumpAndSettle();
          final before = runtime.initialCoordinator.snapshot.root;
          if (withDraft) await _notebookImportDraft(tester, 'observer draft');
          final save = tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Save in memory'),
              )
              .onPressed!;
          final reopen = tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Reopen saved'),
              )
              .onPressed!;
          final state = tester.state(
            find.byType(Phase6Canvas),
          ) as Phase6CanvasPublicationEvidence;
          DocumentRoot? observed;
          Result<CommandCommit, CommandFailure>? nested;
          runtime.initialCoordinator.addListener((change) {
            if (change.family.value != 'alnote.commands.pdf.import_pages')
              return;
            observed = state.activePublicationRoot;
            nested = runtime.initialCoordinator.undo();
            switch (action) {
              case 'save':
                save();
              case 'reopen':
                reopen();
              case 'throw':
                throw StateError('observer');
              case 'dispose':
                tester.binding.attachRootWidget(
                  View(view: tester.view, child: const SizedBox.shrink()),
                );
                tester.binding.buildOwner!.buildScope(
                  tester.binding.rootElement!,
                );
                tester.binding.buildOwner!.finalizeTree();
            }
          });
          await _startNotebookImport(tester);
          await tester.tap(find.byKey(const Key('confirm-pdf-import')));
          await tester.pumpAndSettle();
          expect(observed!.pages, hasLength(3));
          expect(nested, isA<Err<CommandCommit, CommandFailure>>());
          if (action == 'reopen')
            expect(_canvasPainter(tester).currentRoot, before);
          if (action == 'save') {
            expect(
              _canvasPainter(tester).savedRoot,
              withDraft ? before : observed,
            );
          }
          if (withDraft && (action == 'save' || action == 'throw')) {
            expect(state.hasPublicationDraft, isTrue);
            expect(
              tester
                  .widget<TextField>(
                    find.byKey(const Key('text-object-editor')),
                  )
                  .controller!
                  .text,
              'observer draft',
            );
            expect(runtime.initialCoordinator.retainedHistoryCount, 1);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  if (Platform.isLinux &&
      linuxPrivatePdfTestEnabled &&
      const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_HOST_TEST')) {
    testWidgets(
      'private Linux notebook PDF import real worker annotation and recovery',
      (tester) async {
        final backend = _TrackedLinuxBackend(
          createLinuxIsolatedPdfBackend(
            bundle: Directory('build/linux-pdf-resources'),
          ),
        );
        final runtime = _notebookImportRuntime(
          backend: backend,
          picker: _WidgetPdfPicker(
            File('test/fixtures/phase8/linux-integration/ordinary.pdf')
                .readAsBytesSync(),
          ),
          processing: _linuxIntegrationProcessingLimits(),
        );
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        final before = runtime.initialCoordinator.snapshot.root;
        await tester.ensureVisible(find.byKey(const Key('import-pdf-pages')));
        await tester.tap(find.byKey(const Key('import-pdf-pages')));
        await tester.pump();
        await _waitLinuxPdf(
          tester,
          () => find.byKey(const Key('pdf-import-pages')).evaluate().isNotEmpty,
        );
        await tester.enterText(
          find.byKey(const Key('pdf-import-pages')),
          '3,1',
        );
        await tester.tap(find.byKey(const Key('confirm-pdf-import')));
        await tester.pumpAndSettle();
        final imported = runtime.initialCoordinator.snapshot.root;
        expect(imported.pages, hasLength(3));
        expect(imported.pages.first, same(before.pages.first));
        expect(
          imported.pages
              .skip(1)
              .map(
                (p) => (p.layers.first as PdfSourceLayer).reference.pageIndex,
              ),
          [0, 2],
        );
        await tester.ensureVisible(find.text('Undo'));
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(runtime.initialCoordinator.snapshot.root, same(before));
        await tester.tap(find.text('Redo'));
        await tester.pumpAndSettle();
        expect(runtime.initialCoordinator.snapshot.root, same(imported));
        await tester.ensureVisible(find.byKey(const Key('next-page')));
        await tester.tap(find.byKey(const Key('next-page')));
        await tester.pump();
        await _waitLinuxPdf(
          tester,
          () => _documentPainter(tester).hasRenderedPdfPage,
        );
        final stroke = await tester.startGesture(
          tester.getCenter(find.bySemanticsLabel('Handwriting canvas')),
          kind: PointerDeviceKind.stylus,
        );
        await stroke.moveBy(const Offset(20, 10));
        await stroke.up();
        await tester.pumpAndSettle();
        final annotated = runtime.initialCoordinator.snapshot.root;
        expect(annotated.pages[1].layers.last.objects, isNotEmpty);
        await tester.ensureVisible(find.text('Save in memory'));
        await tester.tap(find.text('Save in memory'));
        await tester.pumpAndSettle();
        expect(_canvasPainter(tester).savedBytes, isNotEmpty);
        await tester.ensureVisible(find.text('Reopen saved'));
        await tester.tap(find.text('Reopen saved'));
        await tester.pumpAndSettle();
        expect(_canvasPainter(tester).currentRoot, annotated);
        await tester.ensureVisible(find.byKey(const Key('next-page')));
        await tester.tap(find.byKey(const Key('next-page')));
        await tester.pump();
        await _waitLinuxPdf(
          tester,
          () => _documentPainter(tester).hasRenderedPdfPage,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await _waitLinuxPdf(
          tester,
          () => backend.activeRenders == 0 && backend.activeInspections == 0,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Phase6CanvasRuntime _notebookImportRuntime({
  PdfBackend? backend,
  LocalPdfPickerHost? picker,
  PdfProcessingLimits? processing,
}) {
  backend ??= _WidgetPdfBackend(_widgetPdfModelLimits());
  processing ??= _widgetPdfProcessingLimits();
  return _runtime(
    pdfBackend: backend,
    pdfProcessingLimits: processing,
    localPdfOpenWorkflow: LocalPdfOpenWorkflow(
      selector: LocalPdfFileSelector(
        host: picker ?? _WidgetPdfPicker(markedPdf(geometryCases.first, 0)),
      ),
      backend: backend,
      modelLimits: _widgetPdfModelLimits(),
      processingLimits: processing,
    ),
  );
}

Future<void> _startNotebookImport(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('import-pdf-pages')));
  await tester.tap(find.byKey(const Key('import-pdf-pages')));
  await tester.pumpAndSettle();
  await _waitPdf(
    tester,
    () => find.byKey(const Key('pdf-import-pages')).evaluate().isNotEmpty,
  );
}

Future<void> _notebookImportDraft(WidgetTester tester, String text) async {
  await tester.tap(find.text('text'));
  await tester.pump();
  final gesture = await tester.startGesture(
    tester.getCenter(find.bySemanticsLabel('Handwriting canvas')),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pump();
  await tester.enterText(find.byKey(const Key('text-object-editor')), text);
}

final class _PendingNotebookInspection implements PdfBackend {
  final release = Completer<void>();
  CancellationToken? token;
  final delegate = _WidgetPdfBackend(_widgetPdfModelLimits());
  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    token = request.cancellationToken;
    final result = await delegate.inspect(
      request,
      resourceReader: resourceReader,
    );
    await release.future;
    return result; // Deliberately ignores late cancellation; workflow must reject.
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) => delegate.render(request, resourceReader: resourceReader);
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
