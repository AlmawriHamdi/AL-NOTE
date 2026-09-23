// SPDX-License-Identifier: GPL-3.0-or-later
part of '../widget_test.dart';

void _pdfObjectInsertionChecks() {
  _pdfObjectPageClipChecks();
  for (final selection in ['1', '2,1,2']) {
    testWidgets(
      'PDF Objects insert $selection render, transform and round-trip in memory',
      (tester) async {
        final backend = _WidgetPdfBackend(
          _widgetPdfModelLimits(),
          rgbaColor: [255, 0, 0, 255],
        );
        final runtime = _notebookImportRuntime(backend: backend);
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        final before = runtime.initialCoordinator.snapshot;
        await _insertPdfObjects(tester, selection: selection);
        final count = selection == '1' ? 1 : 2;
        await _waitPdf(
          tester,
          () => _documentPainter(tester).renderedPdfRasterCount == count,
        );
        final inserted = runtime.initialCoordinator.snapshot;
        final objects = inserted.root.pages.single.layers.single.objects;
        expect(objects, hasLength(count));
        expect(inserted.resources, hasLength(1));
        expect(runtime.initialCoordinator.retainedHistoryCount, 1);
        expect(backend.renderedPageIndexes, count == 1 ? [0] : [0, 1]);
        expect(
          _documentPainter(tester).retainedPdfRasterPixels,
          lessThanOrEqualTo(runtime.pdfProcessingLimits!.maximumRenderPixels),
        );
        await tester.ensureVisible(find.text('Undo'));
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(runtime.initialCoordinator.snapshot.root, same(before.root));
        expect(runtime.initialCoordinator.snapshot.resources, isEmpty);
        await tester.tap(find.text('Redo'));
        await tester.pumpAndSettle();
        expect(runtime.initialCoordinator.snapshot.root, same(inserted.root));
        await _waitPdf(
          tester,
          () => _documentPainter(tester).renderedPdfRasterCount == count,
        );
        // Select all inserted pages with the existing marquee and manipulate the
        // common transforms. The payload and authoritative PDF boxes stay exact.
        await tester.ensureVisible(find.text('Fit Page'));
        await tester.tap(find.text('Fit Page'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('selection'));
        await tester.pump();
        final origin = tester.getTopLeft(
          find.byKey(const Key('phase6-canvas-listener')),
        );
        final clip = _canvasPainter(tester).pageClip!;
        final marquee = await tester.startGesture(
          origin + Offset(clip.left + 2, clip.top + 2),
          kind: PointerDeviceKind.mouse,
        );
        await marquee.moveTo(origin + Offset(clip.right - 2, clip.bottom - 2));
        await marquee.up();
        await tester.pump();
        expect(find.text('$count Objects selected'), findsOneWidget);
        for (final operation in ['move', 'resize', 'rotate']) {
          final frame = _canvasPainter(tester).selectionFrame!;
          final corners = frame.viewCorners;
          final center = Offset(
            (corners[0].x + corners[2].x) / 2,
            (corners[0].y + corners[2].y) / 2,
          );
          final start = switch (operation) {
            'resize' => Offset(corners[2].x, corners[2].y),
            'rotate' => Offset(frame.rotationCenter.x, frame.rotationCenter.y),
            _ => center,
          };
          final gesture = await tester.startGesture(
            origin + start,
            kind: PointerDeviceKind.mouse,
          );
          await gesture.moveBy(
            operation == 'rotate' ? const Offset(32, 32) : const Offset(12, 10),
          );
          await gesture.up();
          await tester.pump();
          final transformed = runtime.initialCoordinator.snapshot.root;
          final changed = transformed.pages.single.layers.single.objects;
          for (var i = 0; i < count; i++) {
            expect(changed[i].payload, objects[i].payload);
            expect(changed[i].id, objects[i].id);
            expect(
              changed[i].transform,
              isNot(objects[i].transform),
              reason: operation,
            );
          }
          await tester.tap(find.text('Undo'));
          await tester.pump();
          expect(runtime.initialCoordinator.snapshot.root, same(inserted.root));
          await tester.tap(find.text('Redo'));
          await tester.pump();
          expect(runtime.initialCoordinator.snapshot.root, same(transformed));
          await tester.tap(find.text('Undo'));
          await tester.pump();
        }
        await tester.ensureVisible(find.text('Save in memory'));
        await tester.tap(find.text('Save in memory'));
        await tester.pumpAndSettle();
        expect(_canvasPainter(tester).savedRoot, inserted.root);
        await tester.tap(find.text('Reopen saved'));
        await tester.pumpAndSettle();
        expect(_canvasPainter(tester).currentRoot, inserted.root);
        await _waitPdf(
          tester,
          () => _documentPainter(tester).renderedPdfRasterCount == count,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final text in ['', 'live draft']) {
    testWidgets(
      'PDF Objects retain draft "$text" through insertion Undo and Redo',
      (tester) async {
        final runtime = _notebookImportRuntime();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await _notebookImportDraft(tester, text);
        final before = runtime.initialCoordinator.snapshot;
        await _insertPdfObjects(tester);
        final inserted = runtime.initialCoordinator.snapshot;
        for (final action in ['Undo', 'Redo']) {
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('text-object-editor')))
                .controller!
                .text,
            text,
          );
          await tester.ensureVisible(find.text(action));
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
          expect(
            runtime.initialCoordinator.snapshot.root,
            same(action == 'Undo' ? before.root : inserted.root),
          );
        }
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('text-object-editor')))
              .controller!
              .text,
          text,
        );
        expect(runtime.initialCoordinator.retainedHistoryCount, 1);
      },
    );
  }

  for (final action in ['cancel', 'dispose', 'failure', 'unapproved', 'edit']) {
    testWidgets(
      'PDF Objects reject $action during preparation without partial publication',
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
        var before = runtime.initialCoordinator.snapshot;
        await tester.ensureVisible(find.byKey(const Key('insert-pdf-page')));
        await tester.tap(find.byKey(const Key('insert-pdf-page')));
        await tester.pump();
        if (action == 'cancel') {
          await tester.ensureVisible(
            find.byKey(const Key('cancel-pdf-import')),
          );
          await tester.tap(find.byKey(const Key('cancel-pdf-import')));
        }
        if (action == 'dispose')
          await tester.pumpWidget(const SizedBox.shrink());
        if (action == 'edit') {
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Save in memory'),
              )
              .onPressed!();
          before = runtime.initialCoordinator.snapshot;
        }
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
        expect(find.byKey(const Key('pdf-object-pages')), findsNothing);
        if (action != 'dispose' && action != 'edit')
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('text-object-editor')))
                .controller!
                .text,
            'retained',
          );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final withDraft in [false, true]) {
    for (final action in ['save', 'reopen', 'throw', 'dispose']) {
      testWidgets(
        'PDF Objects synchronous observer $action draft=$withDraft sees complete publication',
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
            if (change.family != CommandFamily.objectCollectionEdit) return;
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
          await _startPdfObjects(tester);
          await tester.tap(find.byKey(const Key('confirm-pdf-insertion')));
          await tester.pumpAndSettle();
          expect(observed!.pages.single.layers.single.objects, hasLength(2));
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

  for (final dispose in [false, true]) {
    testWidgets(
      'PDF Objects superseded raster disposal=$dispose retains one active request',
      (tester) async {
        final delegate = _DelayedCanvasPdfBackend(
          _WidgetPdfBackend(_widgetPdfModelLimits()),
        );
        addTearDown(() {
          if (!delegate.release.isCompleted) delegate.release.complete();
          if (!delegate.latestRelease.isCompleted)
            delegate.latestRelease.complete();
        });
        final backend = DevelopmentFixturePdfBackend(delegate: delegate);
        final runtime = _notebookImportRuntime(backend: backend);
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await _insertPdfObjects(tester);
        await _waitPdf(tester, () => delegate.requests.isNotEmpty);
        final inserted = runtime.initialCoordinator.snapshot.root;
        for (var i = 0; i < 5; i++) {
          await tester.ensureVisible(find.text('Undo'));
          await tester.tap(find.text('Undo'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Redo'));
          await tester.pumpAndSettle();
        }
        expect(delegate.requests, hasLength(1));
        expect(delegate.requests.single.cancellationToken.isCancelled, isTrue);
        expect(_documentPainter(tester).renderedPdfRasterCount, 0);
        if (dispose) await tester.pumpWidget(const SizedBox.shrink());
        delegate.release.complete();
        if (!dispose) {
          await _waitPdf(tester, () => delegate.requests.length == 2);
          expect(
            _documentPainter(tester).renderedPdfRasterCount,
            0,
            reason: 'Cancelled old pixels must not publish',
          );
          delegate.latestRelease.complete();
          await _waitPdf(
            tester,
            () => _documentPainter(tester).renderedPdfRasterCount == 2,
          );
          expect(runtime.initialCoordinator.snapshot.root, same(inserted));
          expect(delegate.requests.map((r) => r.reference.pageIndex), [
            0,
            0,
            1,
          ]);
        } else {
          await tester.pumpAndSettle();
          expect(delegate.requests, hasLength(1));
        }
        expect(delegate.maximumActive, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'PDF Objects failed raster remains editable placeholder with exact Whole Eraser Undo',
    (tester) async {
      final failure = _PermanentCanvasPdfFailure(
        _WidgetPdfBackend(_widgetPdfModelLimits()),
      );
      final runtime = _notebookImportRuntime(
        backend: DevelopmentFixturePdfBackend(delegate: failure),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await _insertPdfObjects(tester, selection: '1');
      final inserted = runtime.initialCoordinator.snapshot.root;
      await tester.ensureVisible(find.text('Zoom In'));
      await tester.tap(find.text('Zoom In'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Fit Page'));
      await tester.tap(find.text('Fit Page'));
      await tester.pumpAndSettle();
      expect(failure.renders, 1);
      expect(_documentPainter(tester).renderedPdfRasterCount, 0);
      await tester.tap(find.text('wholeEraser'));
      await tester.pump();
      final center = _pdfObjectCenter(
        tester,
        inserted.pages.single.layers.single.objects.single,
      );
      final erase = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await erase.moveBy(const Offset(4, 4));
      await erase.up();
      await tester.pumpAndSettle();
      expect(
        runtime
            .initialCoordinator
            .snapshot
            .root
            .pages
            .single
            .layers
            .single
            .objects,
        isEmpty,
      );
      await tester.ensureVisible(find.text('Undo'));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(runtime.initialCoordinator.snapshot.root, same(inserted));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'PDF Objects apply layer opacity, Object/layer visibility and locked Whole Eraser eligibility',
    (tester) async {
      final gateway = _PdfObjectStyleGateway();
      final backend = _WidgetPdfBackend(
        _widgetPdfModelLimits(),
        rgbaColor: [255, 0, 0, 255],
      );
      final runtime = _runtime(
        reopenGateway: gateway,
        pdfBackend: backend,
        pdfProcessingLimits: _widgetPdfProcessingLimits(),
        localPdfOpenWorkflow: LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(
            host: _WidgetPdfPicker(markedPdf(geometryCases.first, 0)),
          ),
          backend: backend,
          modelLimits: _widgetPdfModelLimits(),
          processingLimits: _widgetPdfProcessingLimits(),
        ),
      );
      gateway.runtime = runtime;
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await _insertPdfObjects(tester, selection: '1');
      await _waitPdf(
        tester,
        () => _documentPainter(tester).renderedPdfRasterCount == 1,
      );
      await tester.ensureVisible(find.text('Save in memory'));
      await tester.tap(find.text('Save in memory'));
      await tester.pumpAndSettle();
      for (final style in [
        (true, 1.0, true, false, false),
        (true, .5, true, false, false),
        (false, 1.0, true, false, false),
        (true, 1.0, false, false, false),
        (true, 1.0, true, true, false),
        (true, 1.0, true, false, true),
      ]) {
        gateway.style = style;
        await tester.ensureVisible(find.text('Reopen saved'));
        await tester.tap(find.text('Reopen saved'));
        await tester.pumpAndSettle();
        final visible = style.$1 && style.$3;
        if (visible)
          await _waitPdf(
            tester,
            () => _documentPainter(tester).renderedPdfRasterCount == 1,
          );
        final root = _canvasPainter(tester).currentRoot;
        final object = root.pages.single.layers.single.objects.single;
        final center = _pdfObjectCenter(tester, object);
        final image = await _canvasImage(tester);
        final point = center - image.origin;
        final i = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        expect(image.bytes[i], 255);
        expect(
          image.bytes[i + 1],
          closeTo(visible ? (255 * (1 - style.$2)).round() : 255, 1),
        );
        expect(image.bytes[i + 2], image.bytes[i + 1]);
        await tester.tap(find.text('wholeEraser'));
        await tester.pump();
        final erase = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
        );
        await erase.moveBy(const Offset(4, 4));
        await erase.up();
        await tester.pumpAndSettle();
        final editable = visible && !style.$4 && !style.$5;
        expect(
          _canvasPainter(tester).currentRoot.pages.single.layers.single.objects,
          editable ? isEmpty : [object],
        );
        if (editable) {
          await tester.ensureVisible(find.text('Undo'));
          await tester.tap(find.text('Undo'));
          await tester.pumpAndSettle();
          expect(_canvasPainter(tester).currentRoot, same(root));
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  if (Platform.isLinux &&
      linuxPrivatePdfTestEnabled &&
      const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_HOST_TEST')) {
    testWidgets('private Linux PDF Objects real worker pixels and disposal', (
      tester,
    ) async {
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
      await tester.ensureVisible(find.byKey(const Key('insert-pdf-page')));
      await tester.tap(find.byKey(const Key('insert-pdf-page')));
      await tester.pump();
      await _waitLinuxPdf(
        tester,
        () => find.byKey(const Key('pdf-object-pages')).evaluate().isNotEmpty,
      );
      await tester.enterText(find.byKey(const Key('pdf-object-pages')), '1');
      await tester.tap(find.byKey(const Key('confirm-pdf-insertion')));
      await tester.pumpAndSettle();
      await _waitLinuxPdf(
        tester,
        () => _documentPainter(tester).renderedPdfRasterCount == 1,
      );
      await tester.ensureVisible(find.text('Fit Page'));
      await tester.tap(find.text('Fit Page'));
      await tester.pumpAndSettle();
      final root = runtime.initialCoordinator.snapshot.root;
      final object = root.pages.single.layers.single.objects.single;
      final payload = _ok(
        PdfPageObjectPayload.decode(
          object.payload,
          limits: _widgetPdfModelLimits(),
        ),
      );
      expect(payload.reference.displayedWidth, 612);
      expect(payload.reference.displayedHeight, 792);
      // Extraction is derived only: preserve authoritative state, UUID-bearing
      // nodes, history and observers while using the actual isolated worker.
      final coordinator = runtime.initialCoordinator;
      final beforeExtraction = coordinator.snapshot;
      final historyBeforeExtraction = coordinator.retainedHistoryCount;
      var extractionPublications = 0;
      void observeExtraction(CommittedChange _) => extractionPublications++;
      _ok(coordinator.addListener(observeExtraction));
      final extracted = await tester.runAsync(
        () => backend.extractText(
          PdfTextExtractRequest(
            reference: payload.reference,
            trust: PdfInputTrust.untrusted,
            region: PdfPageClip.full,
            limits: _linuxIntegrationProcessingLimits(),
            cancellationToken: CancellationController().token,
          ),
          resourceReader: GeometryReader(
            File('test/fixtures/phase8/linux-integration/ordinary.pdf')
                .readAsBytesSync(),
          ),
        ),
      );
      expect(extracted, isA<Ok<PdfExtractedText, StructuredFailure>>());
      expect(coordinator.snapshot.root, same(beforeExtraction.root));
      expect(
        coordinator.snapshot.currentContentIdentity,
        beforeExtraction.currentContentIdentity,
      );
      expect(
        coordinator.snapshot.savedContentIdentity,
        beforeExtraction.savedContentIdentity,
      );
      expect(coordinator.snapshot.canUndo, beforeExtraction.canUndo);
      expect(coordinator.snapshot.canRedo, beforeExtraction.canRedo);
      expect(coordinator.snapshot.resources, beforeExtraction.resources);
      expect(coordinator.snapshot.root, same(root));
      expect(coordinator.retainedHistoryCount, historyBeforeExtraction);
      expect(extractionPublications, 0);
      coordinator.removeListener(observeExtraction);
      final image = await _canvasImage(tester);
      final red = <Offset>[], blue = <Offset>[];
      for (var y = 0; y < image.height; y++)
        for (var x = 0; x < image.width; x++) {
          final i = (y * image.width + x) * 4;
          if (image.bytes[i] > 220 &&
              image.bytes[i + 1] < 30 &&
              image.bytes[i + 2] < 30)
            red.add(Offset(x.toDouble(), y.toDouble()));
          if (image.bytes[i] < 30 &&
              image.bytes[i + 1] < 30 &&
              image.bytes[i + 2] > 220)
            blue.add(Offset(x.toDouble(), y.toDouble()));
        }
      final clip = _canvasPainter(tester).pageClip!;
      final origin =
          tester.getTopLeft(find.byKey(const Key('phase6-canvas-listener'))) -
          image.origin;
      for (final mark in [(red, 25.0, 752.0), (blue, 80.0, 727.0)]) {
        expect(mark.$1, isNotEmpty);
        final transformed = _ok(
          object.transform.applyToPoint(
            _ok(Point2.create(x: mark.$2, y: mark.$3)),
          ),
        );
        final expected =
            origin +
            Offset(
              clip.left +
                  transformed.x * clip.width / root.pages.single.size.width,
              clip.top +
                  transformed.y * clip.height / root.pages.single.size.height,
            );
        final actual =
            mark.$1.reduce((a, b) => a + b) / mark.$1.length.toDouble();
        expect((actual - expected).distance, lessThan(2));
      }
      await tester.ensureVisible(find.text('Save in memory'));
      await tester.tap(find.text('Save in memory'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reopen saved'));
      await tester.pumpAndSettle();
      await _waitLinuxPdf(
        tester,
        () => _documentPainter(tester).renderedPdfRasterCount == 1,
      );
      expect(_canvasPainter(tester).currentRoot, root);
      await tester.pumpWidget(const SizedBox.shrink());
      await _waitLinuxPdf(
        tester,
        () => backend.activeRenders == 0 && backend.activeInspections == 0,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'PDF Objects preserve existing Selection and invalid selection retains a live draft',
    (tester) async {
      final runtime = _notebookImportRuntime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final center = tester.getCenter(
        find.bySemanticsLabel('Handwriting canvas'),
      );
      final pen = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await pen.moveBy(const Offset(20, 10));
      await pen.up();
      await tester.pump();
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      final selected = _canvasPainter(tester).selectionFrame!;
      await _insertPdfObjects(tester);
      expect(
        _canvasPainter(tester).selectionFrame!.viewCorners,
        selected.viewCorners,
      );
      await _notebookImportDraft(tester, 'do not commit');
      final before = runtime.initialCoordinator.snapshot;
      final history = runtime.initialCoordinator.retainedHistoryCount;
      await _startPdfObjects(tester);
      await tester.enterText(find.byKey(const Key('pdf-object-pages')), '0');
      await tester.tap(find.byKey(const Key('confirm-pdf-insertion')));
      await tester.pump();
      expect(find.textContaining('Use all or page numbers'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      _expectPdfSnapshotUnchanged(runtime.initialCoordinator.snapshot, before);
      expect(runtime.initialCoordinator.retainedHistoryCount, history);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        'do not commit',
      );
    },
  );
  testWidgets(
    'PDF Objects share rasters and divide a hard aggregate pixel budget',
    (tester) async {
      final backend = _WidgetPdfBackend(_widgetPdfModelLimits());
      final limits = _ok(
        PdfProcessingLimits.create(
          maximumEncodedBytes: 1024,
          maximumPageCount: 16,
          maximumRenderDimension: 128,
          maximumRenderPixels: 900,
          maximumExtractedGlyphs: 1024,
          maximumLinks: 64,
          maximumOperations: 128,
        ),
      );
      final runtime = _notebookImportRuntime(
        backend: backend,
        processing: limits,
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await _insertPdfObjects(tester);
      await _waitPdf(
        tester,
        () => _documentPainter(tester).renderedPdfRasterCount == 2,
      );
      final bytes = runtime.initialCoordinator.snapshot.resources.single.bytes;
      expect(
        _documentPainter(tester).retainedPdfRasterPixels,
        inInclusiveRange(1, 900),
      );
      expect(backend.renderedPageIndexes, [0, 1]);
      await _insertPdfObjects(tester);
      await tester.pumpAndSettle();
      expect(
        runtime
            .initialCoordinator
            .snapshot
            .root
            .pages
            .single
            .layers
            .single
            .objects,
        hasLength(4),
      );
      expect(
        runtime.initialCoordinator.snapshot.resources.single.bytes,
        same(bytes),
      );
      expect(
        backend.renderedPageIndexes,
        [0, 1],
        reason: 'Repeated references reuse verified byte identity and native images',
      );
      expect(
        _documentPainter(tester).retainedPdfRasterPixels,
        inInclusiveRange(1, 900),
      );
    },
  );
  testWidgets(
    'PDF Objects reject unknown destination layers and leave unsupported content inert',
    (tester) async {
      final gateway = _PdfObjectStyleGateway();
      final backend = _WidgetPdfBackend(_widgetPdfModelLimits());
      final runtime = _runtime(
        reopenGateway: gateway,
        pdfBackend: backend,
        pdfProcessingLimits: _widgetPdfProcessingLimits(),
        localPdfOpenWorkflow: LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(
            host: _WidgetPdfPicker(markedPdf(geometryCases.first, 0)),
          ),
          backend: backend,
          modelLimits: _widgetPdfModelLimits(),
          processingLimits: _widgetPdfProcessingLimits(),
        ),
      );
      gateway.runtime = runtime;
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await _insertPdfObjects(tester, selection: '1');
      await _waitPdf(
        tester,
        () => _documentPainter(tester).renderedPdfRasterCount == 1,
      );
      await tester.ensureVisible(find.text('Save in memory'));
      await tester.tap(find.text('Save in memory'));
      await tester.pumpAndSettle();
      for (final unknownLayer in [true, false]) {
        gateway.unknownLayer = unknownLayer;
        gateway.unsupportedSchema = !unknownLayer;
        gateway.style = (true, 1.0, true, false, false);
        final renders = backend.renderedPageIndexes.length;
        await tester.tap(find.text('Reopen saved'));
        await tester.pumpAndSettle();
        expect(backend.renderedPageIndexes.length, renders);
        expect(_documentPainter(tester).renderedPdfRasterCount, 0);
        if (unknownLayer)
          expect(
            tester
                .widget<TextButton>(find.byKey(const Key('insert-pdf-page')))
                .onPressed,
            isNull,
          );
        expect(
          _canvasPainter(tester).currentRoot.pages.single.layers.single.objects,
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}

Future<void> _insertPdfObjects(
  WidgetTester tester, {
  String selection = 'all',
}) async {
  await _startPdfObjects(tester);
  await tester.enterText(find.byKey(const Key('pdf-object-pages')), selection);
  await tester.tap(find.byKey(const Key('confirm-pdf-insertion')));
  await tester.pumpAndSettle();
}

Future<void> _startPdfObjects(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('insert-pdf-page')));
  await tester.tap(find.byKey(const Key('insert-pdf-page')));
  await tester.pumpAndSettle();
  await _waitPdf(
    tester,
    () => find.byKey(const Key('pdf-object-pages')).evaluate().isNotEmpty,
  );
}

Offset _pdfObjectCenter(WidgetTester tester, ObjectEnvelope object) {
  final payload = _ok(
    PdfPageObjectPayload.decode(
      object.payload,
      limits: _widgetPdfModelLimits(),
    ),
  );
  final local = _ok(
    Point2.create(x: payload.bounds.width / 2, y: payload.bounds.height / 2),
  );
  final point = _ok(object.transform.applyToPoint(local));
  final painter = _canvasPainter(tester);
  final page = painter.currentRoot.pages.first;
  final clip = painter.pageClip!;
  return tester.getTopLeft(find.byKey(const Key('phase6-canvas-listener'))) +
      Offset(
        clip.left + point.x * clip.width / page.size.width,
        clip.top + point.y * clip.height / page.size.height,
      );
}

final class _PdfObjectStyleGateway implements Phase6ReopenGateway {
  late Phase6CanvasRuntime runtime;
  bool unknownLayer = false;
  bool unsupportedSchema = false;
  (bool, double, bool, bool, bool)? style;
  final delegate = _runtime().reopenGateway;
  @override
  Phase6ReopenOutcome reopen({
    required List<int> bytes,
    required DocumentRoot savedRoot,
  }) {
    final opened = delegate.reopen(
      bytes: bytes,
      savedRoot: savedRoot,
    ) as Phase6ReopenSuccess;
    final change = style;
    if (change == null) return opened;
    final root = opened.root as NotebookDocument;
    final page = root.pages.single;
    final layer = page.layers.single as ContentLayer;
    final object = layer.objects.single;
    final updatedObject = _ok(
      ObjectEnvelope.create(
        id: object.id,
        typeKey: object.typeKey,
        envelopeVersion: object.envelopeVersion,
        typeSchemaVersion: unsupportedSchema
            ? _ok(SchemaVersion.create(2))
            : object.typeSchemaVersion,
        transform: object.transform,
        visible: change.$3,
        locked: change.$4,
        payload: object.payload,
        extensionData: object.extensionData,
      ),
    );
    final updatedLayer = unknownLayer
        ? testUnknownLayer(objects: [updatedObject])
        : _ok(
            ContentLayer.create(
              id: layer.id,
              envelopeVersion: layer.envelopeVersion,
              typeSchemaVersion: layer.typeSchemaVersion,
              name: layer.name,
              visible: change.$1,
              locked: change.$5,
              opacity: change.$2,
              objects: [updatedObject],
              typeData: layer.typeData,
              extensionData: layer.extensionData,
            ),
          );
    final updatedPage = _ok(
      DocumentPage.create(
        id: page.id,
        name: page.name,
        size: page.size,
        layers: [updatedLayer],
        extensionData: page.extensionData,
      ),
    );
    final section = root.sections.single;
    final updatedSection = _ok(
      DocumentSection.create(
        id: section.id,
        name: section.name,
        pages: [updatedPage],
        extensionData: section.extensionData,
      ),
    );
    final updatedRoot = _ok(
      NotebookDocument.create(
        id: root.id,
        schemaVersion: root.schemaVersion,
        title: root.title,
        resources: root.resources,
        extensionData: root.extensionData,
        sections: [updatedSection],
      ),
    );
    final coordinator = runtime.createCoordinator(
      updatedRoot,
      resources: opened.coordinator.snapshot.resources,
    ) as Ok<DocumentMutationCoordinator, CommandFailure>;
    return Phase6ReopenSuccess(
      root: updatedRoot,
      coordinator: coordinator.value,
    );
  }
}

void _pdfObjectPageClipChecks() {
  if (Platform.isLinux &&
      linuxPrivatePdfTestEnabled &&
      const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_HOST_TEST')) {
    testWidgets(
      'private Linux PDF Page clip real worker margin misses and crossing erasure',
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
        await tester.ensureVisible(find.byKey(const Key('insert-pdf-page')));
        await tester.tap(find.byKey(const Key('insert-pdf-page')));
        await tester.pump();
        await _waitLinuxPdf(
          tester,
          () => find.byKey(const Key('pdf-object-pages')).evaluate().isNotEmpty,
        );
        await tester.enterText(find.byKey(const Key('pdf-object-pages')), '1');
        await tester.tap(find.byKey(const Key('confirm-pdf-insertion')));
        await tester.pumpAndSettle();
        await _waitLinuxPdf(
          tester,
          () => _documentPainter(tester).renderedPdfRasterCount == 1,
        );
        final coordinator = runtime.initialCoordinator;
        _movePdfToRightPageEdge(coordinator, fullyClipped: false);
        await tester.ensureVisible(find.text('Fit Page'));
        await tester.tap(find.text('Fit Page'));
        await tester.pumpAndSettle();
        final before = coordinator.snapshot;
        final y = _pdfObjectMiddleY(
          before.root.pages.single.layers.single.objects.single,
        );
        final outside = _pdfPageScreenPoint(
          tester,
          before.root.pages.single.size.width + 25,
          y,
        );
        final image = await _canvasImage(tester);
        final pixel = outside - image.origin;
        final offset = (pixel.dy.floor() * image.width + pixel.dx.floor()) * 4;
        expect(image.bytes.sublist(offset, offset + 4), [217, 221, 226, 255]);
        final history = coordinator.retainedHistoryCount;
        var publications = 0;
        coordinator.addListener((_) => publications++);
        for (final tool in ['selection', 'marquee', 'wholeEraser']) {
          await tester.tap(find.text(tool == 'marquee' ? 'selection' : tool));
          await tester.pump();
          final gesture = await tester.startGesture(
            outside,
            kind: PointerDeviceKind.mouse,
          );
          if (tool != 'selection')
            await gesture.moveBy(
              tool == 'marquee' ? const Offset(15, 15) : const Offset(1, 1),
            );
          await gesture.up();
          await tester.pumpAndSettle();
          expect(_canvasPainter(tester).selectionFrame, isNull);
          expect(coordinator.snapshot.root, same(before.root));
          expect(
            coordinator.snapshot.currentContentIdentity,
            before.currentContentIdentity,
          );
          expect(coordinator.snapshot.revisions, before.revisions);
          expect(coordinator.retainedHistoryCount, history);
          expect(publications, 0);
        }
        final erase = await tester.startGesture(
          outside,
          kind: PointerDeviceKind.mouse,
        );
        await erase.moveTo(
          _pdfPageScreenPoint(
            tester,
            before.root.pages.single.size.width - 10,
            y,
          ),
        );
        await erase.up();
        await tester.pumpAndSettle();
        expect(
          coordinator.snapshot.root.pages.single.layers.single.objects,
          isEmpty,
        );
        expect(publications, 1);
        await tester.ensureVisible(find.text('Undo'));
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(coordinator.snapshot.root, same(before.root));
        await tester.pumpWidget(const SizedBox.shrink());
        await _waitLinuxPdf(
          tester,
          () => backend.activeRenders == 0 && backend.activeInspections == 0,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final fullyClipped in [false, true]) {
    for (final tool in ['selection', 'marquee', 'wholeEraser']) {
      testWidgets(
        'PDF Page clip gray-margin $tool misses, fully $fullyClipped',
        (tester) async {
          final runtime = _notebookImportRuntime();
          await tester.pumpWidget(AlNoteApp(runtime: runtime));
          await _insertPdfObjects(tester, selection: '1');
          _movePdfToRightPageEdge(
            runtime.initialCoordinator,
            fullyClipped: fullyClipped,
          );
          await tester.ensureVisible(find.text('Fit Page'));
          await tester.tap(find.text('Fit Page'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(tool == 'marquee' ? 'selection' : tool));
          await tester.pump();
          final coordinator = runtime.initialCoordinator;
          final before = coordinator.snapshot;
          final history = coordinator.retainedHistoryCount;
          final saved = _canvasPainter(tester).savedRoot;
          final savedBytes = _canvasPainter(tester).savedBytes;
          var publications = 0;
          coordinator.addListener((_) => publications++);
          final y = _pdfObjectMiddleY(
            before.root.pages.single.layers.single.objects.single,
          );
          final start = _pdfPageScreenPoint(
            tester,
            before.root.pages.single.size.width + 25,
            y,
          );
          expect(
            start.dx,
            greaterThan(
              tester
                      .getTopLeft(
                        find.byKey(const Key('phase6-canvas-listener')),
                      )
                      .dx +
                  _canvasPainter(tester).pageClip!.right,
            ),
          );
          final gesture = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          if (tool == 'marquee') {
            await gesture.moveBy(const Offset(15, 15));
          } else if (tool == 'wholeEraser') {
            await gesture.moveBy(const Offset(1, 1));
          }
          await gesture.up();
          await tester.pumpAndSettle();
          expect(_canvasPainter(tester).selectionFrame, isNull);
          expect(coordinator.snapshot.root, same(before.root));
          expect(
            coordinator.snapshot.currentContentIdentity,
            before.currentContentIdentity,
          );
          expect(coordinator.snapshot.revisions, before.revisions);
          expect(coordinator.snapshot.resources, before.resources);
          expect(coordinator.retainedHistoryCount, history);
          expect(publications, 0);
          expect(_canvasPainter(tester).savedRoot, same(saved));
          expect(_canvasPainter(tester).savedBytes, same(savedBytes));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final action in ['move', 'resize', 'wholeEraser']) {
    testWidgets(
      'PDF Page clip visible $action retains full handles and exact history',
      (tester) async {
        final runtime = _notebookImportRuntime();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await _insertPdfObjects(tester, selection: '1');
        final coordinator = runtime.initialCoordinator;
        _movePdfToRightPageEdge(coordinator, fullyClipped: false);
        await tester.ensureVisible(find.text('Fit Page'));
        await tester.tap(find.text('Fit Page'));
        await tester.pumpAndSettle();
        final before = coordinator.snapshot;
        final object = before.root.pages.single.layers.single.objects.single;
        final history = coordinator.retainedHistoryCount;
        final y = _pdfObjectMiddleY(object);
        final visible = _pdfPageScreenPoint(
          tester,
          before.root.pages.single.size.width - 10,
          y,
        );
        var publications = 0;
        coordinator.addListener((_) => publications++);
        await tester.tap(
          find.text(action == 'wholeEraser' ? action : 'selection'),
        );
        await tester.pump();
        if (action != 'wholeEraser') {
          final select = await tester.startGesture(
            visible,
            kind: PointerDeviceKind.mouse,
          );
          await select.up();
          await tester.pump();
          final frame = _canvasPainter(tester).selectionFrame!;
          expect(
            frame.viewCorners[1].x,
            greaterThan(_canvasPainter(tester).pageClip!.right),
          );
          final payload = _ok(
            PdfPageObjectPayload.decode(
              object.payload,
              limits: _widgetPdfModelLimits(),
            ),
          );
          final expectedWidth =
              payload.bounds.width *
              object.transform.storageCoefficients[0] *
              _canvasPainter(tester).pageClip!.width /
              before.root.pages.single.size.width;
          expect(
            frame.viewCorners[1].x - frame.viewCorners[0].x,
            closeTo(expectedWidth, .00001),
          );
          final origin = tester.getTopLeft(
            find.byKey(const Key('phase6-canvas-listener')),
          );
          final start = action == 'move'
              ? visible
              : origin + Offset(frame.viewCorners[0].x, frame.viewCorners[0].y);
          final gesture = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          await gesture.moveBy(const Offset(-12, 10));
          await gesture.up();
        } else {
          // Starts in the margin and crosses into the visible sliver; no clamping.
          final outside = _pdfPageScreenPoint(
            tester,
            before.root.pages.single.size.width + 40,
            y,
          );
          final gesture = await tester.startGesture(
            outside,
            kind: PointerDeviceKind.mouse,
          );
          await gesture.moveTo(visible);
          await gesture.up();
        }
        await tester.pumpAndSettle();
        final after = coordinator.snapshot;
        expect(after.root, isNot(same(before.root)));
        expect(coordinator.retainedHistoryCount, history + 1);
        expect(publications, 1);
        expect(after.resources, before.resources);
        if (action == 'wholeEraser') {
          expect(after.root.pages.single.layers.single.objects, isEmpty);
        } else {
          final changed = after.root.pages.single.layers.single.objects.single;
          expect(changed.id, object.id);
          expect(changed.payload, object.payload);
          expect(changed.transform, isNot(object.transform));
        }
        await tester.ensureVisible(find.text('Undo'));
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(coordinator.snapshot.root, same(before.root));
        expect(
          coordinator.snapshot.currentContentIdentity,
          before.currentContentIdentity,
        );
        await tester.tap(find.text('Redo'));
        await tester.pumpAndSettle();
        expect(coordinator.snapshot.root, same(after.root));
        expect(
          coordinator.snapshot.currentContentIdentity,
          after.currentContentIdentity,
        );
        expect(publications, 3);
        expect(coordinator.retainedHistoryCount, history + 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

// Zero visible area at the exact edge remains reachable by the existing
// transform contract; wholly beyond-Page geometry is covered by domain tests.
void _movePdfToRightPageEdge(
  DocumentMutationCoordinator coordinator, {
  required bool fullyClipped,
}) {
  final snapshot = coordinator.snapshot;
  final page = snapshot.root.pages.single;
  final layer = page.layers.single;
  final object = layer.objects.single;
  final request = _ok(
    AtomicWholeObjectTransformRequest.create(
      documentId: snapshot.root.id,
      metadata: CommandMetadata(
        family: CommandFamily.wholeObjectTransform,
        correlationId: CommandCorrelationId.fromUuid(testUuid(98765)),
        description: 'Place PDF at destination Page edge',
      ),
      preconditions: RevisionPreconditions(
        pages: {page.id: snapshot.revisions.pages[page.id]!},
        layerMembership: {
          layer.id: snapshot.revisions.layerMembership[layer.id]!,
        },
        objects: {object.id: snapshot.revisions.objects[object.id]!},
      ),
      pageId: page.id,
      targetIds: [object.id],
      operation: TranslationTransformOperation2D(
        _ok(
          Vector2.create(
            x:
                page.size.width +
                (fullyClipped ? 0 : -20) -
                object.transform.storageCoefficients[4],
            y: 0,
          ),
        ),
      ),
    ),
  );
  expect(
    coordinator.execute(request),
    isA<Ok<CommandCommit, CommandFailure>>(),
  );
}

double _pdfObjectMiddleY(ObjectEnvelope object) {
  final payload = _ok(
    PdfPageObjectPayload.decode(
      object.payload,
      limits: _widgetPdfModelLimits(),
    ),
  );
  return _ok(
    object.transform.applyToPoint(
      _ok(
        Point2.create(
          x: payload.bounds.width / 2,
          y: payload.bounds.height / 2,
        ),
      ),
    ),
  ).y;
}

Offset _pdfPageScreenPoint(WidgetTester tester, double x, double y) {
  final painter = _canvasPainter(tester);
  final page = painter.currentRoot.pages.single;
  final clip = painter.pageClip!;
  final origin = tester.getTopLeft(
    find.byKey(const Key('phase6-canvas-listener')),
  );
  return origin +
      Offset(
        clip.left + x * clip.width / page.size.width,
        clip.top + y * clip.height / page.size.height,
      );
}
