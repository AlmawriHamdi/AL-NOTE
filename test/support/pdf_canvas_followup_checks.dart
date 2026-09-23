// SPDX-License-Identifier: GPL-3.0-or-later

part of '../widget_test.dart';

void _pdfFollowupChecks() {
  testWidgets('PDF production guard recovers latest navigation and zoom', (
    tester,
  ) async {
    await tester.runAsync(() async {
      pdfrx.Pdfrx.cacheDirectoryPath = '.';
      await pdfrx.pdfrxFlutterInitialize();
    });
    final actual = pdfrx.PdfrxEntryFunctions.instance;
    final entry = _DelayedPdfEntry(actual);
    pdfrx.PdfrxEntryFunctions.instance = entry;
    addTearDown(() {
      if (!entry.release.isCompleted) entry.release.complete();
      pdfrx.PdfrxEntryFunctions.instance = actual;
    });
    final backend = createTrustedDevelopmentPdfBackend();
    final runtime = _runtime(
      pdfProcessingLimits: _widgetPdfProcessingLimits(),
      pdfBackend: backend,
      localPdfOpenWorkflow: LocalPdfOpenWorkflow(
        selector: LocalPdfFileSelector(
          host: _WidgetPdfPicker(
            File('test/fixtures/phase8/admitted/blank-workflow.pdf')
                .readAsBytesSync(),
          ),
        ),
        backend: backend,
        modelLimits: _widgetPdfModelLimits(),
        processingLimits: _widgetPdfProcessingLimits(),
      ),
    );
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.ensureVisible(find.byKey(const Key('open-pdf')));
    await tester.tap(find.byKey(const Key('open-pdf')));
    await _waitPdf(tester, () => entry.oldLoaded);
    expect(entry.calls, 2);
    // Repeated navigation cancels and supersedes waiting requests while the
    // cancelled old native load remains physically active.
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.byKey(const Key('next-page')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('previous-page')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const Key('next-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zoom In'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(entry.calls, 2, reason: 'No waiting request starts parsing/copies');
    expect(_documentPainter(tester).hasRenderedPdfPage, isFalse);
    entry.release.complete();
    // No more user actions. Only completion and Flutter frames drive recovery.
    await _waitPdf(tester, () => _documentPainter(tester).hasRenderedPdfPage);
    expect(entry.calls, 3, reason: 'Only the latest page reaches PDFium');
    expect(entry.maximumActive, 1);
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(_documentPainter(tester).displaysPdfPlaceholder, isFalse);
  });

  for (final dispose in [false, true]) {
    testWidgets('PDF waiting render disposal=$dispose cancels obsolete work', (
      tester,
    ) async {
      final delegate = _DelayedCanvasPdfBackend(
        _WidgetPdfBackend(_widgetPdfModelLimits()),
      );
      addTearDown(() {
        if (!delegate.release.isCompleted) delegate.release.complete();
        if (!delegate.latestRelease.isCompleted)
          delegate.latestRelease.complete();
      });
      final backend = DevelopmentFixturePdfBackend(delegate: delegate);
      final runtime = _runtime(
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
      await tester.ensureVisible(find.byKey(const Key('open-pdf')));
      await tester.tap(find.byKey(const Key('open-pdf')));
      await tester.pumpAndSettle();
      await _waitPdf(tester, () => delegate.requests.isNotEmpty);
      expect(delegate.requests.length, 1);
      await tester.tap(find.byKey(const Key('next-page')));
      await tester.pumpAndSettle();
      expect(delegate.requests.single.cancellationToken.isCancelled, isTrue);
      if (dispose) await tester.pumpWidget(const SizedBox.shrink());
      delegate.release.complete();
      if (dispose) {
        await tester.pumpAndSettle();
        expect(delegate.requests.length, 1);
        expect(tester.takeException(), isNull);
      } else {
        await _waitPdf(tester, () => delegate.requests.length == 2);
        expect(delegate.oldWasSuccess, isTrue);
        expect(
          _documentPainter(tester).hasRenderedPdfPage,
          isFalse,
          reason:
              'Cancelled old success must not publish while latest is delayed',
        );
        delegate.latestRelease.complete();
        await _waitPdf(
          tester,
          () => _documentPainter(tester).hasRenderedPdfPage,
        );
        expect(delegate.requests.map((r) => r.reference.pageIndex), [0, 1]);
        expect(delegate.maximumActive, 1);
        // A delegate ignoring cancellation returned a valid old image; it was
        // never published as the current image, even while latest was waiting.
        expect(delegate.oldCompletedWithCancelledToken, isTrue);
      }
    });
  }

  testWidgets('PDF permanent guarded failure stays cached across zoom', (
    tester,
  ) async {
    final delegate = _PermanentCanvasPdfFailure(
      _WidgetPdfBackend(_widgetPdfModelLimits()),
    );
    final backend = DevelopmentFixturePdfBackend(delegate: delegate);
    final runtime = _runtime(
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
    await tester.ensureVisible(find.byKey(const Key('open-pdf')));
    await tester.tap(find.byKey(const Key('open-pdf')));
    await _waitPdf(tester, () => delegate.renders == 1);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('Zoom In'));
      await tester.pumpAndSettle();
    }
    expect(delegate.renders, 1);
    expect(_documentPainter(tester).hasRenderedPdfPage, isFalse);
    expect(_documentPainter(tester).displaysPdfPlaceholder, isTrue);
  });

  for (final scenario in [
    'success',
    'productionSuccess',
    'unchanged',
    'empty',
    'draftValidation',
    'replacementPreparation',
    'cancelled',
    'disposed',
    'externalEdit',
    'editDuringPreparation',
    'editDuringDraftValidation',
    'historyFailure',
    'draftIdentityFailure',
    'existingSuccess',
    'existingDraftValidation',
    'existingReplacementPreparation',
  ]) {
    testWidgets('PDF admitted live draft atomicity $scenario', (tester) async {
      final generator = _PdfCallbackUuidGenerator();
      if (scenario == 'productionSuccess') {
        await tester.runAsync(() async {
          pdfrx.Pdfrx.cacheDirectoryPath = '.';
          await pdfrx.pdfrxFlutterInitialize();
        });
      }
      final backend = scenario == 'productionSuccess'
          ? createTrustedDevelopmentPdfBackend()
          : DevelopmentFixturePdfBackend(
              delegate: _WidgetPdfBackend(_widgetPdfModelLimits()),
            );
      final picker = _FollowupPdfPicker();
      final runtime = _runtime(
        uuidGenerator: generator,
        maximumEstimatedRetainedHistoryBytes: scenario == 'historyFailure'
            ? 1
            : 10000000,
        pdfProcessingLimits: _widgetPdfProcessingLimits(),
        pdfBackend: backend,
        localPdfOpenWorkflow: LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(host: picker),
          backend: backend,
          modelLimits: _widgetPdfModelLimits(),
          processingLimits: _widgetPdfProcessingLimits(),
        ),
      );
      final engine = _SwitchablePdfDraftLayout(runtime.textLayoutEngine);
      await tester.pumpWidget(
        MaterialApp(
          home: Phase6Canvas(
            runtime: runtime,
            textLayoutEngineOverride: engine,
          ),
        ),
      );
      await tester.tap(find.text('text'));
      await tester.pump();
      final create = await tester.startGesture(
        tester.getCenter(find.bySemanticsLabel('Handwriting canvas')),
        kind: PointerDeviceKind.mouse,
      );
      await create.up();
      await tester.pump();
      final text = scenario == 'empty' ? '' : 'admitted fixture live draft';
      await tester.enterText(find.byKey(const Key('text-object-editor')), text);
      if (scenario == 'unchanged' || scenario.startsWith('existing')) {
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
        if (scenario.startsWith('existing')) {
          await tester.enterText(
            find.byKey(const Key('text-object-editor')),
            '$text changed',
          );
        }
      }
      var before = runtime.initialCoordinator.snapshot;
      var history = runtime.initialCoordinator.retainedHistoryCount;
      final savedBytes = _canvasPainter(tester).savedBytes;
      final selection = _canvasPainter(tester).selectionFrame;
      final selectionCount = _canvasPainter(tester).selectionPrimitiveCount;
      final calls = generator.calls;
      var notifications = 0;
      _ok(runtime.initialCoordinator.addListener((_) => notifications++));
      await tester.ensureVisible(find.byKey(const Key('open-pdf')));
      await tester.tap(find.byKey(const Key('open-pdf')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      if (scenario == 'externalEdit') {
        _insertPdfInterveningObject(runtime);
        before = runtime.initialCoordinator.snapshot;
        history = runtime.initialCoordinator.retainedHistoryCount;
        notifications = 0;
      }
      if (scenario == 'draftValidation' ||
          scenario == 'existingDraftValidation')
        engine.fail = true;
      if (scenario == 'replacementPreparation' ||
          scenario == 'existingReplacementPreparation')
        generator.throwAt = calls + 1;
      if (scenario == 'draftIdentityFailure') generator.throwAt = calls + 4;
      if (scenario == 'editDuringPreparation') {
        generator.once = () => _insertPdfInterveningObject(runtime);
      }
      if (scenario == 'editDuringDraftValidation') {
        generator.once = () =>
            engine.once = () => _insertPdfInterveningObject(runtime);
      }
      if (scenario == 'disposed') {
        await tester.pumpWidget(const SizedBox.shrink());
        expect(picker.token!.isCancelled, isTrue);
        picker.done.complete(
          _WidgetPdfHandle(markedPdf(geometryCases.first, 0)),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
        _expectPdfSnapshotUnchanged(
          runtime.initialCoordinator.snapshot,
          before,
        );
        expect(notifications, 0);
        expect(generator.calls, calls);
        expect(tester.takeException(), isNull);
        return;
      }
      picker.done.complete(
        scenario == 'cancelled'
            ? null
            : _WidgetPdfHandle(
                scenario == 'productionSuccess'
                    ? File('test/fixtures/phase8/admitted/blank-workflow.pdf')
                          .readAsBytesSync()
                    : markedPdf(geometryCases.first, 0),
              ),
      );
      await tester.pumpAndSettle();
      await _waitPdf(
        tester,
        () =>
            tester.widget<Text>(find.byKey(const Key('canvas-status'))).data !=
            'Opening PDF…',
      );
      final succeeds = [
        'success',
        'productionSuccess',
        'existingSuccess',
        'unchanged',
        'empty',
      ].contains(scenario);
      final commits =
          scenario == 'success' ||
          scenario == 'productionSuccess' ||
          scenario == 'existingSuccess';
      if (succeeds) {
        expect(
          _canvasPainter(tester).currentRoot,
          isA<StandalonePdfDocument>(),
        );
        expect(find.byKey(const Key('text-object-editor')), findsNothing);
        expect(_canvasPainter(tester).selectionPrimitiveCount, 0);
        expect(_canvasPainter(tester).selectionFrame, isNull);
        expect(notifications, commits ? 1 : 0);
        expect(
          runtime.initialCoordinator.retainedHistoryCount,
          history + (commits ? 1 : 0),
        );
        expect(
          generator.calls - calls,
          scenario == 'success' || scenario == 'productionSuccess'
              ? 4
              : scenario == 'existingSuccess'
              ? 3
              : 1,
        );
        if (commits) {
          final committed = runtime.initialCoordinator.snapshot;
          expect(
            committed.currentContentIdentity,
            isNot(before.currentContentIdentity),
          );
          expect(committed.canUndo, isTrue);
          final object = committed.root.pages.single.layers
              .whereType<ContentLayer>()
              .single
              .objects
              .single;
          expect(
            _ok(TextPayload.decode(object.payload, limits: runtime.textLimits))
                .paragraphs
                .single
                .runs
                .single
                .text,
            scenario == 'existingSuccess' ? '$text changed' : text,
          );
          expect(
            runtime.initialCoordinator.undo(),
            isA<Ok<CommandCommit, CommandFailure>>(),
          );
          expect(runtime.initialCoordinator.snapshot.root, same(before.root));
          expect(
            runtime.initialCoordinator.redo(),
            isA<Ok<CommandCommit, CommandFailure>>(),
          );
          expect(
            runtime.initialCoordinator.snapshot.root,
            same(committed.root),
          );
        } else {
          _expectPdfSnapshotUnchanged(
            runtime.initialCoordinator.snapshot,
            before,
          );
        }
      } else {
        if (scenario == 'editDuringPreparation' ||
            scenario == 'editDuringDraftValidation') {
          expect(notifications, 1);
          expect(runtime.initialCoordinator.retainedHistoryCount, history + 1);
          expect(
            _objectCount(runtime),
            1,
            reason: 'External edit only, draft not committed',
          );
        } else {
          _expectPdfSnapshotUnchanged(
            runtime.initialCoordinator.snapshot,
            before,
          );
          expect(runtime.initialCoordinator.retainedHistoryCount, history);
          expect(notifications, 0);
        }
        expect(
          _canvasPainter(tester).currentRoot,
          same(runtime.initialCoordinator.snapshot.root),
        );
        expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('text-object-editor')))
              .controller!
              .text,
          scenario.startsWith('existing') ? '$text changed' : text,
        );
        expect(_canvasPainter(tester).selectionFrame, selection);
        expect(_canvasPainter(tester).selectionPrimitiveCount, selectionCount);
        expect(_canvasPainter(tester).savedBytes, savedBytes);
        if (scenario == 'cancelled') expect(generator.calls, calls);
        if (scenario == 'editDuringDraftValidation')
          expect(generator.calls, calls + 5);
        if (scenario == 'historyFailure' || scenario == 'draftIdentityFailure')
          expect(generator.calls, calls + 4);
        if (scenario == 'existingReplacementPreparation') {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          expect(
            find.byKey(const Key('edit-selected-text')),
            findsOneWidget,
            reason: 'Rejected replacement retained the original Selection for Escape',
          );
        }
        if (scenario == 'draftValidation' ||
            scenario == 'replacementPreparation' ||
            scenario == 'existingDraftValidation' ||
            scenario == 'existingReplacementPreparation')
          expect(generator.calls, calls + 1);
      }
    });
  }
}

void _expectPdfSnapshotUnchanged(
  DocumentCoordinatorSnapshot after,
  DocumentCoordinatorSnapshot before,
) {
  expect(after.root, same(before.root));
  expect(after.currentContentIdentity, before.currentContentIdentity);
  expect(after.savedContentIdentity, before.savedContentIdentity);
  expect(after.resources, before.resources);
  expect(after.revisions, before.revisions);
  expect(after.canUndo, before.canUndo);
  expect(after.canRedo, before.canRedo);
  expect(after.isDirty, before.isDirty);
}

void _insertPdfInterveningObject(Phase6CanvasRuntime runtime) {
  final snapshot = runtime.initialCoordinator.snapshot;
  final page = snapshot.root.pages.single;
  final layer = page.layers.whereType<ContentLayer>().single;
  _ok(
    runtime.initialCoordinator.execute(
      _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: snapshot.root.id,
          pageId: page.id,
          metadata: phase3Metadata(
            family: 'alnote.commands.object.collection_edit',
            correlation: 9898,
          ),
          preconditions: RevisionPreconditions(
            pages: {page.id: snapshot.revisions.pages[page.id]!},
            layerMembership: {
              layer.id: snapshot.revisions.layerMembership[layer.id]!,
            },
          ),
          additions: [
            ObjectCollectionAddition(
              layerId: layer.id,
              object: testObject(
                id: 9899,
                typeKey: textObjectTypeKey,
                schemaVersion: textSchemaVersion,
                payload: _pdfInterveningPayload(runtime.textLimits).encode(),
              ),
            ),
          ],
          maximumOperations: runtime.maximumCommandOperations,
        ),
      ),
    ),
  );
}

TextPayload _pdfInterveningPayload(TextLimits limits) =>
    _widgetAlignedSimpleText(
      limits,
      horizontal: TextAlignment.start,
      vertical: TextVerticalAlignment.top,
    );

Future<void> _waitPdf(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }
  expect(
    done(),
    isTrue,
    reason: 'Bounded wait for native completion and image decode',
  );
}

final class _FollowupPdfPicker implements LocalPdfPickerHost {
  final done = Completer<LocalPdfFileHandle?>();
  CancellationToken? token;
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) {
    token = cancellationToken;
    return done.future;
  }
}

final class _PdfCallbackUuidGenerator implements UuidGenerator {
  int calls = 0;
  int? throwAt;
  void Function()? once;
  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    final call = ++calls;
    if (throwAt == call) throw StateError('controlled identity failure');
    if (once != null) {
      final callback = once!;
      once = null;
      callback();
    }
    return Ok(testUuid(5000 + call));
  }
}

final class _SwitchablePdfDraftLayout implements TextLayoutEngine {
  _SwitchablePdfDraftLayout(this.delegate);
  final TextLayoutEngine delegate;
  bool fail = false;
  void Function()? once;
  @override
  Result<TextLayoutSnapshot, StructuredFailure> layout(
    TextLayoutRequest request,
  ) {
    final callback = once;
    once = null;
    callback?.call();
    return fail
        ? Err(
            StructuredFailure(
              code: 'test.layout.failure',
              category: FailureCategory.validation,
              retryDisposition: RetryDisposition.never,
              message: 'Controlled layout failure',
            ),
          )
        : delegate.layout(request);
  }
}

final class _DelayedPdfEntry implements pdfrx.PdfrxEntryFunctions {
  _DelayedPdfEntry(this.actual);
  final pdfrx.PdfrxEntryFunctions actual;
  final release = Completer<void>();
  int calls = 0;
  int active = 0;
  int maximumActive = 0;
  bool oldLoaded = false;
  @override
  Future<pdfrx.PdfDocument> openData(
    Uint8List data, {
    pdfrx.PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    String? sourceName,
    bool allowDataOwnershipTransfer = false,
    bool useProgressiveLoading = false,
    void Function()? onDispose,
  }) async {
    final call = ++calls;
    active++;
    maximumActive = math.max(maximumActive, active);
    try {
      final doc = await actual.openData(
        data,
        passwordProvider: passwordProvider,
        firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
        sourceName: sourceName,
        allowDataOwnershipTransfer: allowDataOwnershipTransfer,
        useProgressiveLoading: useProgressiveLoading,
        onDispose: onDispose,
      );
      if (call == 2) {
        oldLoaded = true;
        await release.future;
      }
      return doc;
    } finally {
      active--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _DelayedCanvasPdfBackend implements PdfBackend {
  _DelayedCanvasPdfBackend(this.delegate);
  final PdfBackend delegate;
  final release = Completer<void>();
  final latestRelease = Completer<void>();
  bool oldWasSuccess = false;
  final requests = <PdfRenderRequest>[];
  int active = 0;
  int maximumActive = 0;
  bool oldCompletedWithCancelledToken = false;
  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest r, {
    required PdfResourceReader resourceReader,
  }) => delegate.inspect(r, resourceReader: resourceReader);
  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest r, {
    required PdfResourceReader resourceReader,
  }) async {
    requests.add(r);
    active++;
    maximumActive = math.max(maximumActive, active);
    try {
      if (requests.length == 1) {
        // Capture a successful image before cancellation, then deliberately
        // return it after cancellation to exercise the guard's final gate.
        final outcome = await delegate.render(
          r,
          resourceReader: resourceReader,
        );
        oldWasSuccess = outcome is PdfRenderSuccess;
        await release.future;
        oldCompletedWithCancelledToken = r.cancellationToken.isCancelled;
        return outcome;
      }
      await latestRelease.future;
      return await delegate.render(r, resourceReader: resourceReader);
    } finally {
      active--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _PermanentCanvasPdfFailure implements PdfBackend {
  _PermanentCanvasPdfFailure(this.delegate);
  final PdfBackend delegate;
  int renders = 0;
  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest r, {
    required PdfResourceReader resourceReader,
  }) => delegate.inspect(r, resourceReader: resourceReader);
  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest r, {
    required PdfResourceReader resourceReader,
  }) async {
    renders++;
    return const PdfRenderFailure(PdfRenderFailureReason.limitExceeded);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
