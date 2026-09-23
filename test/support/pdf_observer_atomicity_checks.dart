// SPDX-License-Identifier: GPL-3.0-or-later

part of '../widget_test.dart';

void _pdfObserverChecks() {
  for (final action in [
    'reopen',
    'save',
    'save_then_reopen',
    'reopen_then_save',
    'disposal',
    'cancellation_listener',
  ]) {
    testWidgets('PDF compound observer ordering $action with actual PDFium', (
      tester,
    ) async {
      await tester.runAsync(() async {
        pdfrx.Pdfrx.cacheDirectoryPath = '.';
        await pdfrx.pdfrxFlutterInitialize();
      });
      final generator = _RuntimeCountingUuidGenerator();
      final picker = _FollowupPdfPicker();
      final backend = createTrustedDevelopmentPdfBackend();
      final runtime = _runtime(
        uuidGenerator: generator,
        pdfProcessingLimits: _widgetPdfProcessingLimits(),
        pdfBackend: backend,
        localPdfOpenWorkflow: LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(host: picker),
          backend: backend,
          modelLimits: _widgetPdfModelLimits(),
          processingLimits: _widgetPdfProcessingLimits(),
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('Save in memory'));
      await tester.pumpAndSettle();
      final before = runtime.initialCoordinator.snapshot;
      final saved = _canvasPainter(tester).savedRoot!;
      final savedBytes = _canvasPainter(tester).savedBytes!;
      final reopen = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Reopen saved'))
          .onPressed!;
      final save = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Save in memory'))
          .onPressed!;
      final choosePen = tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'pen'))
          .onSelected!;
      await tester.tap(find.text('text'));
      await tester.pump();
      final create = await tester.startGesture(
        tester.getCenter(find.bySemanticsLabel('Handwriting canvas')),
        kind: PointerDeviceKind.mouse,
      );
      await create.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'observer-boundary draft',
      );
      final state = tester.state(find.byType(Phase6Canvas));
      final evidence = state as Phase6CanvasPublicationEvidence;
      final events = <String>[];
      final snapshots =
          <({DocumentRoot root, DocumentRoot? saved, bool draft})>[];
      final blockedAttempts = <Result<CommandCommit, CommandFailure>>[];
      final listeners = <CommittedChangeListener>[];
      void record(String event) {
        events.add(event);
        snapshots.add((
          root: evidence.activePublicationRoot,
          saved: evidence.activePublicationSavedRoot,
          draft: evidence.hasPublicationDraft,
        ));
      }

      void listen(CommittedChangeListener listener) {
        listeners.add(listener);
        _ok(runtime.initialCoordinator.addListener(listener));
      }

      DocumentRoot? committedDraft;
      listen((_) {
        record('first');
        committedDraft = runtime.initialCoordinator.snapshot.root;
        blockedAttempts.add(runtime.initialCoordinator.undo());
        if (action == 'reopen' || action == 'reopen_then_save') reopen();
        if (action == 'save' || action == 'save_then_reopen') save();
        if (action == 'disposal') {
          // Synchronously detach/finalize the actual tree during listener
          // delivery; this is not a timer or an unawaited pumpWidget.
          tester.binding.attachRootWidget(
            View(view: tester.view, child: const SizedBox.shrink()),
          );
          tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
          tester.binding.buildOwner!.finalizeTree();
        }
        record('first-action');
        throw StateError('controlled observer failure');
      });
      listen((_) {
        record('second');
        blockedAttempts.add(runtime.initialCoordinator.redo());
        if (action == 'save_then_reopen') reopen();
        if (action == 'reopen_then_save') save();
        if (action == 'disposal') {
          reopen();
          save();
        }
        choosePen(true);
        record('second-action');
      });
      listen((_) {
        record('third');
      });
      await tester.ensureVisible(find.byKey(const Key('open-pdf')));
      await tester.tap(find.byKey(const Key('open-pdf')));
      await tester.pump();
      picker.token!.addListener((_) {
        record('cancel');
        if (action == 'cancellation_listener') {
          reopen();
          record('cancel-action');
          throw StateError('controlled cancellation-listener failure');
        }
      });
      final calls = generator.calls;
      picker.done.complete(
        _WidgetPdfHandle(
          File('test/fixtures/phase8/admitted/blank-workflow.pdf')
              .readAsBytesSync(),
        ),
      );
      for (var i = 0; i < 100 && !events.contains('third'); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      expect(
        events,
        action == 'cancellation_listener'
            ? [
                'cancel',
                'cancel-action',
                'first',
                'first-action',
                'second',
                'second-action',
                'third',
              ]
            : [
                'cancel',
                'first',
                'first-action',
                'second',
                'second-action',
                'third',
              ],
      );
      // The first externally callable notification already sees the completed
      // PDF owner, cleared save fields and a closed draft editor.
      expect(snapshots.first.root, isA<StandalonePdfDocument>());
      expect(snapshots.first.saved, isNull);
      expect(snapshots.first.draft, isFalse);
      expect(snapshots.every((snapshot) => !snapshot.draft), isTrue);
      expect(
        blockedAttempts,
        everyElement(isA<Err<CommandCommit, CommandFailure>>()),
      );
      expect(picker.token!.isCancelled, isTrue);
      expect(runtime.initialCoordinator.retainedHistoryCount, 1);
      expect(committedDraft, isNot(same(before.root)));
      final textObject = committedDraft!.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects
          .single;
      expect(
        _ok(TextPayload.decode(textObject.payload, limits: runtime.textLimits))
            .paragraphs
            .single
            .runs
            .single
            .text,
        'observer-boundary draft',
      );
      if (action == 'disposal') {
        expect(state.mounted, isFalse);
        expect(generator.calls - calls, 4);
      } else {
        final expectsNotebook = action != 'save';
        expect(
          evidence.activePublicationRoot,
          expectsNotebook ? saved : isA<StandalonePdfDocument>(),
        );
        expect(
          evidence.activePublicationSavedRoot,
          evidence.activePublicationRoot,
        );
        expect(evidence.activePublicationSavedBytes, isNotNull);
        if (expectsNotebook)
          expect(evidence.activePublicationSavedBytes, savedBytes);
        expect(
          tester
              .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'pen'))
              .selected,
          isTrue,
        );
        expect(generator.calls - calls, expectsNotebook ? 5 : 4);
      }
      // Later listeners observe prior synchronous actions, not a half-installed
      // transition. Returning from delivery must not change their result.
      expect(snapshots.last.root, evidence.activePublicationRoot);
      expect(snapshots.last.saved, evidence.activePublicationSavedRoot);
      for (final listener in listeners) {
        runtime.initialCoordinator.removeListener(listener);
      }
      expect(
        runtime.initialCoordinator.undo(),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(
        runtime.initialCoordinator.redo(),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      expect(runtime.initialCoordinator.snapshot.root, same(committedDraft));
      expect(events.where((event) => event == 'first').length, 1);
      expect(events.where((event) => event == 'second').length, 1);
      expect(events.where((event) => event == 'third').length, 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
