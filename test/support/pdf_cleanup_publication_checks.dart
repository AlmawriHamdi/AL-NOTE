// SPDX-License-Identifier: GPL-3.0-or-later
part of '../widget_test.dart';

void _pdfCleanupPublicationChecks() {
  for (final selection in [false, true]) {
    for (final nativeHook in [false, true]) {
      for (final action
          in nativeHook
              ? ['reopen', 'save', 'dispose', 'throw']
              : ['reopen', 'save', 'dispose', 'throw', 'repaint']) {
        testWidgets(
          'PDF cleanup publication selection=$selection action=$action nativeHook=$nativeHook',
          (tester) async {
            await tester.runAsync(() async {
              pdfrx.Pdfrx.cacheDirectoryPath = '.';
              await pdfrx.pdfrxFlutterInitialize();
            });
            final observer = _CleanupPictureObserver();
            final picker = _FollowupPdfPicker();
            final backend = createTrustedDevelopmentPdfBackend();
            final runtime = _runtime(
              nativePictureObserver: observer,
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
            final state = tester.state(find.byType(Phase6Canvas));
            final evidence = state as Phase6CanvasPublicationEvidence;
            final saved = evidence.activePublicationSavedRoot;
            final savedBytes = evidence.activePublicationSavedBytes;
            final reopen = tester
                .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Reopen saved'),
                )
                .onPressed!;
            final save = tester
                .widget<TextButton>(
                  find.widgetWithText(TextButton, 'Save in memory'),
                )
                .onPressed!;
            final open = tester
                .widget<TextButton>(find.byKey(const Key('open-pdf')))
                .onPressed!;
            final center = tester.getCenter(
              find.bySemanticsLabel('Handwriting canvas'),
            );
            final ownedPictures = <ui.Picture>{};
            final oldCreateHook = ui.Picture.onCreate;
            ui.Picture? lastCreated;
            if (nativeHook) {
              ui.Picture.onCreate = (picture) {
                oldCreateHook?.call(picture);
                lastCreated = picture;
              };
              observer.onCreated = () => ownedPictures.add(lastCreated!);
              addTearDown(() => ui.Picture.onCreate = oldCreateHook);
            }
            var gesture = await tester.startGesture(
              center - const Offset(160, 0),
              kind: PointerDeviceKind.mouse,
            );
            for (var i = 1; i <= 600; i++) {
              await gesture.moveTo(
                center -
                    const Offset(160, 0) +
                    Offset((i % 300).toDouble(), i.isEven ? 2 : -2),
              );
            }
            await tester.pump();
            if (selection) {
              await gesture.up();
              await tester.pumpAndSettle();
              await tester.tap(find.text('selection'));
              await tester.pump();
              final select = await tester.startGesture(
                center,
                kind: PointerDeviceKind.mouse,
              );
              await select.up();
              await tester.pump();
              final frame = _canvasPainter(tester).selectionFrame!;
              final origin = tester.getTopLeft(
                find.byKey(const Key('phase6-canvas-listener')),
              );
              gesture = await tester.startGesture(
                origin + Offset(frame.rotationCenter.x, frame.rotationCenter.y),
                kind: PointerDeviceKind.mouse,
              );
              await gesture.moveBy(const Offset(22, 15));
              await tester.pump();
            }
            expect(observer.created - observer.disposed, greaterThan(0));
            final retained = observer.created - observer.disposed;
            final disposedBefore = observer.disposed;
            final historyBefore =
                runtime.initialCoordinator.retainedHistoryCount;
            final events = <String>[];
            final seen = <({DocumentRoot root, DocumentRoot? saved})>[];
            void record(String name) {
              events.add(name);
              seen.add((
                root: evidence.activePublicationRoot,
                saved: evidence.activePublicationSavedRoot,
              ));
            }

            void act() {
              if (action == 'reopen' || action == 'repaint') reopen();
              if (action == 'save') save();
              if (action == 'dispose') {
                tester.binding.attachRootWidget(
                  View(view: tester.view, child: const SizedBox.shrink()),
                );
                tester.binding.buildOwner!.buildScope(
                  tester.binding.rootElement!,
                );
                tester.binding.buildOwner!.finalizeTree();
                reopen();
                save(); // Closing/disposed actions are inert.
              }
              if (action == 'throw')
                throw StateError('controlled cleanup observer');
            }

            observer.once = () {
              record('picture');
              if (!nativeHook && action != 'repaint') act();
            };
            final oldNativeHook = ui.Picture.onDispose;
            var nativeCalled = false;
            DocumentRoot? nativeRoot;
            DocumentRoot? nativeSaved;
            final nativePictures = <ui.Picture>[];
            if (nativeHook) {
              ui.Picture.onDispose = (picture) {
                oldNativeHook?.call(picture);
                if (!ownedPictures.contains(picture)) return;
                nativePictures.add(picture);
                if (nativeCalled) return;
                nativeCalled = true;
                nativeRoot = evidence.activePublicationRoot;
                nativeSaved = evidence.activePublicationSavedRoot;
                act();
              };
              addTearDown(() => ui.Picture.onDispose = oldNativeHook);
            }
            var repaintAction = false;
            void repaint() {
              record('repaint');
              if (action == 'repaint' && !repaintAction) {
                repaintAction = true;
                act();
              }
            }

            final signals = evidence.publicationRepaintSignals;
            for (final signal in signals) {
              signal.addListener(repaint);
            }
            open();
            await tester.pump();
            List<String>? atCancellation;
            picker.token!.addListener((_) {
              record('cancel');
              atCancellation = List.of(events);
            });
            picker.done.complete(
              _WidgetPdfHandle(
                File('test/fixtures/phase8/admitted/blank-workflow.pdf')
                    .readAsBytesSync(),
              ),
            );
            for (var i = 0; i < 100 && !events.contains('cancel'); i++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)),
              );
              await tester.pumpAndSettle();
            }
            if (!nativeHook) {
              expect(events.first, 'picture');
              expect(seen.first.root, isA<StandalonePdfDocument>());
              expect(seen.first.saved, isNull);
            }
            final repaintCount = action == 'dispose'
                ? 0
                : (selection ? 1 : 2) +
                      (action == 'reopen' || action == 'repaint' ? 1 : 0);
            expect(
              atCancellation,
              nativeHook && action == 'reopen'
                  ? [
                      'repaint',
                      'picture',
                      ...List.filled(repaintCount - 1, 'repaint'),
                      'cancel',
                    ]
                  : [
                      'picture',
                      ...List.filled(repaintCount, 'repaint'),
                      'cancel',
                    ],
            );
            expect(events.where((e) => e == 'picture'), hasLength(1));
            expect(observer.disposed - disposedBefore, retained);
            expect(observer.disposed, observer.created);
            expect(
              runtime.initialCoordinator.retainedHistoryCount,
              historyBefore,
            );
            if (action == 'dispose') {
              expect(state.mounted, isFalse);
              expect(events, [
                'picture',
                'cancel',
              ]); // Repaints cancelled after disposal.
            } else {
              expect(events, contains('repaint'));
              if (action == 'reopen' || action == 'repaint') {
                expect(evidence.activePublicationRoot, saved);
                expect(evidence.activePublicationSavedRoot, saved);
                expect(evidence.activePublicationSavedBytes, savedBytes);
              } else {
                expect(
                  evidence.activePublicationRoot,
                  isA<StandalonePdfDocument>(),
                );
                expect(
                  evidence.activePublicationSavedRoot,
                  action == 'save' ? evidence.activePublicationRoot : null,
                );
              }
              for (final signal in signals) {
                signal.removeListener(repaint);
              }
              await gesture.cancel();
            }
            await tester.pumpAndSettle();
            if (nativeHook) {
              expect(nativeCalled, isTrue);
              expect(nativeRoot, isA<StandalonePdfDocument>());
              expect(nativeSaved, isNull);
              expect(nativePictures.toSet(), hasLength(nativePictures.length));
              for (final picture in nativePictures) {
                expect(picture.debugDisposed, isTrue);
              }
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  for (final action in ['reopen', 'save', 'dispose', 'throw']) {
    testWidgets('PDF native image cleanup publication action=$action', (
      tester,
    ) async {
      final backend = _WidgetPdfBackend(_widgetPdfModelLimits());
      final runtime = _runtime(
        pdfBackend: backend,
        pdfProcessingLimits: _widgetPdfProcessingLimits(),
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
      await _waitPdf(tester, () => _documentPainter(tester).hasRenderedPdfPage);
      await tester.tap(find.text('Save in memory'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(Phase6Canvas));
      final evidence = state as Phase6CanvasPublicationEvidence;
      final saved = evidence.activePublicationSavedRoot;
      final savedBytes = evidence.activePublicationSavedBytes;
      final reopen = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Reopen saved'))
          .onPressed!;
      final save = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Save in memory'))
          .onPressed!;
      final oldHook = ui.Image.onDispose;
      var called = 0;
      ui.Image? disposed;
      DocumentRoot? seenRoot;
      DocumentRoot? seenSaved;
      List<int>? seenBytes;
      ui.Image.onDispose = (image) {
        oldHook?.call(image);
        if (called > 0) return;
        called++;
        disposed = image;
        seenRoot = evidence.activePublicationRoot;
        seenSaved = evidence.activePublicationSavedRoot;
        seenBytes = evidence.activePublicationSavedBytes;
        if (action == 'reopen') reopen();
        if (action == 'save') save();
        if (action == 'dispose') {
          tester.binding.attachRootWidget(
            View(view: tester.view, child: const SizedBox.shrink()),
          );
          tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
          tester.binding.buildOwner!.finalizeTree();
        }
        if (action == 'throw')
          throw StateError('controlled native image observer');
      };
      addTearDown(() => ui.Image.onDispose = oldHook);
      reopen();
      expect(called, 1);
      expect(seenRoot, saved);
      expect(seenSaved, saved);
      expect(seenBytes, savedBytes);
      expect(disposed!.debugDisposed, isTrue);
      expect(state.mounted, action != 'dispose');
      if (action != 'dispose') {
        expect(evidence.activePublicationRoot, saved);
        expect(evidence.activePublicationSavedRoot, saved);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

final class _CleanupPictureObserver implements Phase6NativePictureObserver {
  int created = 0;
  int disposed = 0;
  VoidCallback? once;
  VoidCallback? onCreated;
  @override
  void pictureCreated() {
    created++;
    onCreated?.call();
  }

  @override
  void pictureDisposed() {
    disposed++;
    final callback = once;
    once = null;
    callback?.call();
  }
}
