// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:al_note/app/al_note_app.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:al_note/documents/pdf/pdf_admission_policy.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_backend.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/renderer.dart';
import 'package:al_note/drawing/viewport.dart';
import 'package:al_note/ui/canvas/phase6_canvas.dart';
import 'package:al_note/ui/canvas/phase6_canvas_runtime.dart';
import 'package:al_note/ui/canvas/phase6_diagnostics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'support/document_model_test_support.dart';
import 'support/pdf_geometry_checks.dart';
import 'support/phase3_test_support.dart';
import 'support/uuid_sequence_generator.dart';

part 'support/pdf_canvas_followup_checks.dart';
part 'support/pdf_notebook_import_checks.dart';
part 'support/pdf_object_insertion_checks.dart';
part 'support/pdf_observer_atomicity_checks.dart';
part 'support/pdf_cleanup_publication_checks.dart';
part 'support/pdf_source_style_checks.dart';
part 'support/pdf_linux_prototype_checks.dart';
part 'support/pdf_linux_integration_checks.dart';

/// Verifies the accessible Phase 6 Canvas shell and pointer route.
void main() {
  _pdfFollowupChecks();
  _pdfNotebookImportChecks();
  _pdfObjectInsertionChecks();
  _pdfObserverChecks();
  _pdfCleanupPublicationChecks();
  _pdfSourceStyleChecks();
  _pdfLinuxPrototypeChecks();
  _pdfLinuxIntegrationChecks();
  testWidgets('debug Diagnostics exposes only the bounded Phase 6 trace', (
    WidgetTester tester,
  ) async {
    final trace = _ok(
      Phase6DiagnosticTrace.create(enabled: true, capacity: 16),
    );
    await tester.pumpWidget(
      AlNoteApp(runtime: _ok(_runtimeResult(diagnosticTrace: trace))),
    );
    expect(find.byKey(const Key('phase6-diagnostics-copy')), findsOneWidget);
    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final gesture = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(1, 0));
    await gesture.cancel();
    await tester.pump();
    expect(trace.events, isNotEmpty);
    expect(
      trace.events.map((event) => event.stage),
      contains(Phase6DiagnosticStage.cursorRepaintRequested),
    );
    final diagnostics = find.byKey(const Key('phase6-diagnostics-copy'));
    await tester.ensureVisible(diagnostics);
    await tester.tap(diagnostics);
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics copied'), findsOneWidget);
    final copied = trace.copyText();
    expect(copied, isNot(contains('00000000-')));
    expect(copied, contains('phase6_diag'));
    expect(copied, isNot(contains('secret')));

    final disabled = _ok(
      Phase6DiagnosticTrace.create(enabled: false, capacity: 16),
    );
    await tester.pumpWidget(
      AlNoteApp(runtime: _ok(_runtimeResult(diagnosticTrace: disabled))),
    );
    expect(find.byKey(const Key('phase6-diagnostics-copy')), findsNothing);
  });

  testWidgets('diagnostics clipboard failures are awaited and redacted', (
    WidgetTester tester,
  ) async {
    for (final clipboard in <Phase6DebugClipboard>[
      const _StructuredFailingClipboard(),
      const _SynchronouslyThrowingClipboard(),
      const _AsynchronouslyThrowingClipboard(),
    ]) {
      await tester.pumpWidget(
        AlNoteApp(runtime: _runtime(debugClipboard: clipboard)),
      );
      final diagnostics = find.byKey(const Key('phase6-diagnostics-copy'));
      await tester.ensureVisible(diagnostics);
      await tester.tap(diagnostics);
      await tester.pumpAndSettle();
      expect(find.text('Diagnostics copy failed'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('pending diagnostics copy cannot update a disposed Canvas', (
    WidgetTester tester,
  ) async {
    final clipboard = _PendingClipboard();
    await tester.pumpWidget(
      AlNoteApp(runtime: _runtime(debugClipboard: clipboard)),
    );
    final diagnostics = find.byKey(const Key('phase6-diagnostics-copy'));
    await tester.ensureVisible(diagnostics);
    await tester.tap(diagnostics);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    clipboard.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders Phase 6 controls and commits pointer handwriting', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('AL NOTE'), findsOneWidget);
    expect(find.text('pen'), findsOneWidget);
    expect(find.text('wholeEraser'), findsOneWidget);
    expect(find.text('partialEraser'), findsNothing);
    expect(find.text('selection'), findsOneWidget);
    expect(find.text('Save in memory'), findsOneWidget);
    expect(find.text('Reopen saved'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Redo'), findsOneWidget);
    expect(find.text('Zoom In'), findsOneWidget);
    expect(find.text('Zoom Out'), findsOneWidget);
    expect(find.text('100%'), findsWidgets);

    final canvas = find.bySemanticsLabel('Handwriting canvas');
    expect(canvas, findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 10));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Stroke committed'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Undo'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'Open PDF publishes all pages atomically and paints beneath annotations',
    (tester) async {
      final modelLimits = _widgetPdfModelLimits();
      final processingLimits = _widgetPdfProcessingLimits();
      final backend = _WidgetPdfBackend(modelLimits);
      final workflow = LocalPdfOpenWorkflow(
        selector: LocalPdfFileSelector(
          host: _WidgetPdfPicker(markedPdf(geometryCases.first, 0)),
        ),
        backend: backend,
        modelLimits: modelLimits,
        processingLimits: processingLimits,
      );
      final runtime = _runtime(
        pdfProcessingLimits: processingLimits,
        pdfBackend: backend,
        localPdfOpenWorkflow: workflow,
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));

      final openPdf = find.byKey(const Key('open-pdf'));
      await tester.ensureVisible(openPdf);
      await tester.tap(openPdf);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        isNot('Opening PDF…'),
      );
      final root = _canvasPainter(tester).currentRoot;
      expect(root, isA<StandalonePdfDocument>());
      expect(root.pages, hasLength(2));
      expect(root.resources.entries, hasLength(1));
      expect(backend.renderedPageIndexes, contains(0));
      expect(_documentPainter(tester).hasRenderedPdfPage, isTrue);
      expect(_documentPainter(tester).displaysPdfPlaceholder, isFalse);
      expect(find.text('Page 1 of 2'), findsOneWidget);
      expect(root.pages.first.layers.first, isA<PdfSourceLayer>());
      expect(root.pages.first.layers.last, isA<ContentLayer>());

      await tester.tap(find.byKey(const Key('next-page')));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page 2 of 2'), findsOneWidget);
      expect(_documentPainter(tester).hasRenderedPdfPage, isTrue);
      expect(backend.renderedPageIndexes, containsAll(<int>[0, 1]));

      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final pen = await tester.startGesture(
        center,
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveBy(const Offset(24, 24));
      await pen.up();
      await tester.pumpAndSettle();
      final afterInk = _canvasPainter(tester).currentRoot;
      expect(
        afterInk.pages[0].layers.whereType<ContentLayer>().single.objects,
        isEmpty,
      );
      expect(
        afterInk.pages[1].layers.whereType<ContentLayer>().single.objects,
        hasLength(1),
      );
      expect(_documentPainter(tester).hasRenderedPdfPage, isTrue);

      await tester.tap(find.text('Save in memory'));
      await tester.pumpAndSettle();
      final saved = _canvasPainter(tester).savedRoot;
      await tester.tap(find.text('Reopen saved'));
      await tester.pumpAndSettle();
      expect(_canvasPainter(tester).currentRoot, saved);
      expect(_canvasPainter(tester).currentRoot.pages, hasLength(2));
      expect(find.text('Page 1 of 2'), findsOneWidget);
    },
  );

  for (final rejection in <(bool, PdfInspectOutcome, String)>[
    (
      false,
      const PdfBackendBusy(),
      'PDF processing is busy. Try opening again when it finishes.',
    ),
    (false, const PdfCorrupt(), 'This PDF could not be opened.'),
    (
      true,
      const PdfCorrupt(),
      'Not an approved development fixture; PDF remains quarantined',
    ),
    (false, const PdfInspectionFailed(), 'This PDF could not be opened.'),
    (
      false,
      const PdfPasswordRequired(),
      'This PDF requires a password. Password-protected PDFs are not supported in this test build.',
    ),
    (
      false,
      const PdfUnsupported(),
      'This PDF uses features not supported in this test build.',
    ),
    (
      false,
      const PdfInspectionLimitExceeded(),
      'This PDF exceeds the supported size or processing limits.',
    ),
    (
      false,
      const PdfBackendUnavailable(),
      'PDF opening is unavailable because Linux isolation could not be started or verified.',
    ),
  ]) {
    final unapproved = rejection.$1;
    testWidgets(
      '$unapproved ${rejection.$2} rejected PDF open leaves the live document untouched',
      (tester) async {
        final modelLimits = _widgetPdfModelLimits();
        final processingLimits = _widgetPdfProcessingLimits();
        final backend = _WidgetPdfBackend(
          modelLimits,
          inspectionFailure: rejection.$2,
        );
        final generator = _RuntimeCountingUuidGenerator();
        final runtime = _runtime(
          uuidGenerator: generator,
          pdfProcessingLimits: processingLimits,
          pdfBackend: backend,
          localPdfOpenWorkflow: LocalPdfOpenWorkflow(
            selector: LocalPdfFileSelector(
              host: _WidgetPdfPicker(
                unapproved
                    ? <int>[37, 80, 68, 70]
                    : markedPdf(geometryCases.first, 0),
              ),
            ),
            backend: backend,
            modelLimits: modelLimits,
            processingLimits: processingLimits,
          ),
        );
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        final before = runtime.initialCoordinator.snapshot;
        final uuidCalls = generator.calls;
        final selection = _canvasPainter(tester).selectionFrame;

        final openPdf = find.byKey(const Key('open-pdf'));
        await tester.ensureVisible(openPdf);
        await tester.tap(openPdf);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();

        final after = runtime.initialCoordinator.snapshot;
        expect(after.root, same(before.root));
        expect(after.revisions, before.revisions);
        expect(after.canUndo, before.canUndo);
        expect(after.canRedo, before.canRedo);
        expect(after.isDirty, before.isDirty);
        expect(generator.calls, uuidCalls);
        expect(_canvasPainter(tester).selectionFrame, selection);
        expect(backend.inspections, unapproved ? 0 : 1);
        expect(backend.renderedPageIndexes, isEmpty);
        expect(_canvasPainter(tester).currentRoot, same(before.root));
        expect(
          tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
          rejection.$3,
        );
        expect(find.textContaining('%PDF'), findsNothing);
      },
    );
  }

  testWidgets(
    'unapproved picker preserves inline draft through lifecycle changes',
    (tester) async {
      final generator = _RuntimeCountingUuidGenerator();
      final backend = _WidgetPdfBackend(_widgetPdfModelLimits());
      final picker = _PendingWidgetPdfPicker();
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
        'uncommitted draft',
      );
      final before = runtime.initialCoordinator.snapshot;
      final calls = generator.calls;
      await tester.ensureVisible(find.byKey(const Key('open-pdf')));
      await tester.tap(find.byKey(const Key('open-pdf')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      picker.done.complete(const _WidgetPdfHandle([37, 80, 68, 70]));
      await tester.pumpAndSettle();
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(generator.calls, calls);
      expect(backend.inspections, 0);
      expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        'uncommitted draft',
      );
    },
  );

  testWidgets(
    'PDF cleanup lifecycle blocks opening and retains the live editor through disposal',
    (tester) async {
      final backend = _WidgetPdfBackend(_widgetPdfModelLimits());
      final runtime = _runtime(
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
        'retained cleanup draft',
      );
      final before = runtime.initialCoordinator.snapshot;
      final history = runtime.initialCoordinator.retainedHistoryCount;
      var publications = 0;
      _ok(runtime.initialCoordinator.addListener((_) => publications++));
      backend.lifecycle.update(PdfBackendAvailability.cleanupPending);
      await tester.pump();
      expect(
        find.text(
          'PDF processing is unavailable while the previous worker is being stopped.',
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextButton>(find.byKey(const Key('open-pdf'))).onPressed,
        isNull,
      );
      _expectPdfSnapshotUnchanged(runtime.initialCoordinator.snapshot, before);
      expect(runtime.initialCoordinator.retainedHistoryCount, history);
      expect(publications, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        'retained cleanup draft',
      );
      backend.lifecycle.update(PdfBackendAvailability.available);
      await tester.pump();
      expect(
        tester.widget<TextButton>(find.byKey(const Key('open-pdf'))).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      backend.lifecycle.update(PdfBackendAvailability.cleanupPending);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unavailable saved PDF rendering shows a stable placeholder', (
    tester,
  ) async {
    final modelLimits = _widgetPdfModelLimits();
    final processingLimits = _widgetPdfProcessingLimits();
    final backend = _WidgetPdfBackend(modelLimits, failRender: true);
    final runtime = _runtime(
      pdfProcessingLimits: processingLimits,
      pdfBackend: backend,
      localPdfOpenWorkflow: LocalPdfOpenWorkflow(
        selector: LocalPdfFileSelector(
          host: _WidgetPdfPicker(markedPdf(geometryCases.first, 0)),
        ),
        backend: backend,
        modelLimits: modelLimits,
        processingLimits: processingLimits,
      ),
    );
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final openPdf = find.byKey(const Key('open-pdf'));
    await tester.ensureVisible(openPdf);
    await tester.tap(openPdf);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(_canvasPainter(tester).currentRoot, isA<StandalonePdfDocument>());
    expect(_documentPainter(tester).hasRenderedPdfPage, isFalse);
    expect(_documentPainter(tester).displaysPdfPlaceholder, isTrue);
    expect(find.text('This page could not be rendered.'), findsOneWidget);

    await tester.tap(find.text('Save in memory'));
    await tester.pumpAndSettle();
    final saved = _canvasPainter(tester).savedRoot;
    await tester.tap(find.text('Reopen saved'));
    await tester.pumpAndSettle();
    expect(_canvasPainter(tester).currentRoot, saved);
    expect(_documentPainter(tester).displaysPdfPlaceholder, isTrue);
  });

  testWidgets('Canvas disposal releases Pen pictures and stale callbacks', (
    WidgetTester tester,
  ) async {
    final observer = _CountingPictureObserver();
    final runtime = _runtime(
      uuidGenerator: _RuntimeCountingUuidGenerator(),
      nativePictureObserver: observer,
    );
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final start = tester.getCenter(canvas) - const Offset(160, 0);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 600; index += 1) {
      await gesture.moveTo(
        start + Offset((index % 300).toDouble(), index.isEven ? 2 : -2),
      );
    }
    await tester.pump();
    expect(observer.created, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(observer.disposed, observer.created);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selects, whole-erases, undoes, redoes, saves, and reopens', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final gesture = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 10));
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('selection'));
    await tester.pump();
    final selectionTap = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await selectionTap.up();
    await tester.pump();
    expect(
      find.text('Object selected'),
      findsOneWidget,
      reason: tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
    );

    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    final eraseTap = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await eraseTap.up();
    await tester.pump();
    expect(find.text('Stroke erased'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Undone'), findsOneWidget);
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    expect(find.text('Redone'), findsOneWidget);

    await tester.tap(find.text('Save in memory'));
    await tester.pump();
    expect(find.textContaining('Saved in memory'), findsOneWidget);
    await tester.tap(find.text('Reopen saved'));
    await tester.pump();
    expect(find.text('Reopened in-memory save'), findsOneWidget);
  });

  testWidgets('Escape cancels Pen and the next Pen gesture commits', (
    WidgetTester tester,
  ) async {
    final observer = _CountingPictureObserver();
    final runtime = _runtime(nativePictureObserver: observer);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final before = runtime.initialCoordinator.snapshot.root;
    final cancelled = await tester.startGesture(
      tester.getCenter(canvas) - const Offset(150, 0),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 600; index += 1) {
      await cancelled.moveTo(
        tester.getCenter(canvas) +
            Offset(-150 + (index % 300), index.isEven ? 2 : -2),
      );
    }
    await tester.pump();
    expect(observer.created, greaterThan(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
    await cancelled.cancel();
    expect(runtime.initialCoordinator.snapshot.root, same(before));
    expect(observer.disposed, observer.created);

    final next = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await next.moveBy(const Offset(20, 0));
    await next.up();
    await tester.pump();
    expect(find.text('Stroke committed'), findsOneWidget);
  });

  testWidgets('Pen cursor is exact, paper-only, repaint-only, and isolated', (
    WidgetTester tester,
  ) async {
    final generator = _RuntimeCountingUuidGenerator();
    final runtime = _runtime(uuidGenerator: generator);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final listener = find.byKey(const Key('phase6-canvas-listener'));
    final origin = tester.getTopLeft(listener);
    final center = tester.getCenter(canvas);
    final before = runtime.initialCoordinator.snapshot;
    final history = runtime.initialCoordinator.retainedHistoryCount;
    final uuidCalls = generator.calls;
    const device = 803;
    await _addTestMouse(tester, center, device);
    await _moveTestMouse(tester, center + const Offset(17, 9), device);
    final hoverEvidence = _penCursor(tester);
    expect(
      hoverEvidence.cursorPosition!.x,
      closeTo(center.dx + 17 - origin.dx, 1e-9),
    );
    expect(
      hoverEvidence.cursorPosition!.y,
      closeTo(center.dy + 9 - origin.dy, 1e-9),
    );
    expect(hoverEvidence.updateCount, greaterThan(0));
    expect(
      tester
          .widget<MouseRegion>(find.byKey(const Key('phase6-pen-paper-region')))
          .cursor,
      SystemMouseCursors.none,
    );
    expect(runtime.initialCoordinator.snapshot.root, same(before.root));
    expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
    expect(runtime.initialCoordinator.retainedHistoryCount, history);
    expect(generator.calls, uuidCalls);

    await _moveTestMouse(tester, origin + const Offset(2, 2), device);
    expect(_penCursor(tester).cursorPosition, isNull);
    await _removeTestMouse(tester, device);

    final pen = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final accepted = center + const Offset(23, 11);
    await pen.moveTo(accepted);
    expect(
      _penCursor(tester).cursorPosition!.x,
      closeTo(accepted.dx - origin.dx, 1e-9),
    );
    expect(
      _penCursor(tester).cursorPosition!.y,
      closeTo(accepted.dy - origin.dy, 1e-9),
    );
    expect(_penPreview(tester).previewedSampleCount, 2);
    await pen.up();
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    expect(find.byKey(const Key('phase6-pen-cursor')), findsNothing);
    expect(
      tester
          .widget<MouseRegion>(
            find.byKey(const Key('phase6-canvas-mouse-region')),
          )
          .cursor,
      SystemMouseCursors.basic,
    );
  });

  testWidgets(
    'Pen preview pixels equal committed pixels across chunks and opacity',
    (WidgetTester tester) async {
      for (final opacity in [1.0, .45]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          AlNoteApp(runtime: _runtime(penOpacity: opacity)),
        );
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final start = tester.getCenter(canvas) - const Offset(100, 40);
        final pen = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        for (var index = 1; index <= 450; index += 1) {
          final row = index ~/ 180;
          final withinRow = index % 180;
          final x = row.isEven ? withinRow : 180 - withinRow;
          await pen.moveTo(start + Offset(x.toDouble(), row * 12.0));
        }
        await tester.pump();
        expect(_penPreview(tester).frozenChunkCount, greaterThan(0));
        final preview = await _canvasBytes(tester);
        await pen.up();
        await tester.pump();
        final committed = await _canvasBytes(tester);
        expect(committed, hasLength(preview.length));
        var maximumChannelDelta = 0;
        for (var index = 0; index < preview.length; index += 1) {
          maximumChannelDelta = math.max(
            maximumChannelDelta,
            (preview[index] - committed[index]).abs(),
          );
        }
        expect(
          maximumChannelDelta,
          lessThanOrEqualTo(1),
          reason:
              'release must not visibly change resolved Pen pixels at '
              '$opacity',
        );
      }
    },
  );

  testWidgets('repeated long Pen strokes compact and release every layer', (
    WidgetTester tester,
  ) async {
    final observer = _CountingPictureObserver();
    final runtime = _runtime(
      uuidGenerator: _RuntimeCountingUuidGenerator(),
      nativePictureObserver: observer,
    );
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    for (var stroke = 0; stroke < 3; stroke += 1) {
      final start = center + Offset(-170, -25 + stroke * 25);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      for (var index = 1; index <= 800; index += 1) {
        await gesture.moveTo(
          start + Offset((index % 340).toDouble(), index.isEven ? 1 : -1),
        );
        if (index % 200 == 0) await tester.pump();
      }
      expect(_penPreview(tester).activePrimitiveCount, lessThanOrEqualTo(192));
      expect(_penPreview(tester).frozenChunkCount, lessThanOrEqualTo(8));
      await gesture.up();
      await tester.pump();
      final event = runtime.diagnosticTrace.events.lastWhere(
        (value) => value.stage == Phase6DiagnosticStage.penTerminal,
      );
      expect(event.authoritativeSamples, 801);
      expect(event.compactions, greaterThan(0));
      expect(event.maximumRetainedResources, lessThanOrEqualTo(8));
      expect(observer.disposed, observer.created);
      expect(_objectCount(runtime), stroke + 1);
    }
  });

  testWidgets('one marquee selects many separate handwriting Objects', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    for (var index = 0; index < 30; index += 1) {
      final y = center.dy - 70 + index * 4.5;
      final pen = await tester.startGesture(
        Offset(center.dx - 80, y),
        kind: PointerDeviceKind.mouse,
      );
      await pen.moveBy(const Offset(160, 0));
      await pen.up();
    }
    await tester.pump();
    expect(_objectCount(runtime), 30);
    await tester.tap(find.text('selection'));
    await tester.pump();
    final marquee = await tester.startGesture(
      Offset(center.dx - 100, center.dy - 90),
      kind: PointerDeviceKind.mouse,
    );
    await marquee.moveTo(Offset(center.dx + 100, center.dy + 90));
    await marquee.up();
    await tester.pump();
    expect(find.text('30 Objects selected'), findsOneWidget);
    final frame = _canvasPainter(tester).selectionFrame!;
    expect(frame.isSingleText, isFalse);
    expect(_canvasPainter(tester).selectionPrimitiveCount, 3);
  });

  testWidgets('multi-Object Selection rotates from its circular handle', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('shape'));
    await tester.pump();
    await tester.tap(find.text('Fill'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    for (final offset in const [
      Offset(-90, -35),
      Offset(0, 0),
      Offset(90, 35),
    ]) {
      final create = await tester.startGesture(
        center + offset - const Offset(15, 12),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(30, 24));
      await create.up();
    }
    await tester.pump();
    expect(_objectCount(runtime), 3);
    await tester.tap(find.text('selection'));
    await tester.pump();
    final single = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await single.up();
    await tester.pump();
    expect(find.text('Object selected'), findsOneWidget);
    expect(
      _canvasPainter(tester).selectionPrimitiveCount,
      3,
      reason: 'Shape has no visible resize handles',
    );
    final marquee = await tester.startGesture(
      center - const Offset(130, 70),
      kind: PointerDeviceKind.mouse,
    );
    await marquee.moveTo(center + const Offset(130, 70));
    await marquee.up();
    await tester.pump();
    final frame = _canvasPainter(tester).selectionFrame!;
    expect(frame.isSingleText, isFalse);
    expect(
      _canvasPainter(tester).selectionPrimitiveCount,
      3,
      reason: 'outline, connector, and circular rotation handle only',
    );
    final before = runtime.initialCoordinator.snapshot.root;
    final origin = tester.getTopLeft(
      find.byKey(const Key('phase6-canvas-listener')),
    );
    final rotate = await tester.startGesture(
      origin + Offset(frame.rotationCenter.x, frame.rotationCenter.y),
      kind: PointerDeviceKind.mouse,
    );
    await rotate.moveBy(const Offset(2, 0));
    await tester.pump();
    expect(
      find.text('Rotating selection'),
      findsOneWidget,
      reason: tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
    );
    expect(runtime.initialCoordinator.snapshot.root, same(before));
    expect(_objectCount(runtime), 3);
    expect(_canvasPainter(tester).previewPrimitiveCount, greaterThan(0));
    await rotate.up();
    await tester.pump();
    expect(find.text('Selection transformed'), findsOneWidget);
    expect(runtime.initialCoordinator.snapshot.root, isNot(before));
  });

  testWidgets(
    '100 handwriting mixed Objects bound 180 frame-paced transforms',
    (WidgetTester tester) async {
      final pictureObserver = _CountingPictureObserver();
      final runtime = _runtime(
        maximumCommandOperations: 128,
        maximumEstimatedRetainedHistoryBytes: 100000000,
        nativePictureObserver: pictureObserver,
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);

      final handwriting = await tester.startGesture(
        center - const Offset(150, 50),
        kind: PointerDeviceKind.mouse,
      );
      for (var index = 1; index <= 40; index += 1) {
        await handwriting.moveTo(
          center + Offset(-50 + index * 2.5, -50 + math.sin(index / 8) * 12),
        );
      }
      await handwriting.up();
      for (var stroke = 0; stroke < 2; stroke += 1) {
        final longStroke = await tester.startGesture(
          center + Offset(-150, 10 + stroke * 25),
          kind: PointerDeviceKind.mouse,
        );
        for (var index = 1; index <= 300; index += 1) {
          await longStroke.moveTo(
            center +
                Offset(
                  -150 + index.toDouble(),
                  10 + stroke * 25 + math.sin(index / 9) * 5,
                ),
          );
        }
        await longStroke.up();
      }
      await tester.pump();

      await tester.tap(find.text('shape'));
      await tester.pump();
      final shape = await tester.startGesture(
        center - const Offset(10, 10),
        kind: PointerDeviceKind.mouse,
      );
      await shape.moveBy(const Offset(20, 20));
      await shape.up();
      await tester.tap(find.text('text'));
      await tester.pump();
      final text = await tester.startGesture(
        center + const Offset(80, -10),
        kind: PointerDeviceKind.mouse,
      );
      await text.moveBy(const Offset(24, 20));
      await text.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'mixed',
      );
      await _commitInlineText(tester);
      await tester.pump();

      final snapshot = runtime.initialCoordinator.snapshot;
      final page = snapshot.root.pages.single;
      final layer = page.layers.whereType<ContentLayer>().single;
      final handwritingSource = layer.objects.firstWhere(
        (object) => object.typeKey == handwritingObjectTypeKey,
      );
      final additions = <ObjectCollectionAddition>[];
      for (var index = 0; index < 97; index += 1) {
        final source = handwritingSource;
        final clone = _ok(
          ObjectEnvelope.create(
            id: ObjectId.fromUuid(testUuid(6000 + index)),
            typeKey: source.typeKey,
            envelopeVersion: source.envelopeVersion,
            typeSchemaVersion: source.typeSchemaVersion,
            transform: source.transform,
            visible: source.visible,
            locked: source.locked,
            payload: source.payload,
            extensionData: source.extensionData,
          ),
        );
        additions.add(
          ObjectCollectionAddition(layerId: layer.id, object: clone),
        );
      }
      final seeded = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: snapshot.root.id,
          pageId: page.id,
          metadata: phase3Metadata(
            family: 'alnote.commands.object.collection_edit',
            correlation: 7999,
          ),
          preconditions: RevisionPreconditions(
            pages: {page.id: snapshot.revisions.pages[page.id]!},
            layerMembership: {
              layer.id: snapshot.revisions.layerMembership[layer.id]!,
            },
          ),
          additions: additions,
          maximumOperations: 128,
        ),
      );
      expect(
        runtime.initialCoordinator.execute(seeded),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      await tester.pump();
      expect(_objectCount(runtime), 102);

      await tester.tap(find.text('selection'));
      await tester.pump();
      final marquee = await tester.startGesture(
        tester.getTopLeft(canvas) + const Offset(20, 20),
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveTo(
        tester.getBottomRight(canvas) - const Offset(20, 20),
      );
      await marquee.up();
      await tester.pump();
      expect(find.text('102 Objects selected'), findsOneWidget);
      final origin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );
      for (final mode in ['move', 'resize', 'rotate']) {
        final frame = _canvasPainter(tester).selectionFrame!;
        final corners = frame.viewCorners;
        final start = switch (mode) {
          'move' => Offset(
            corners.map((point) => point.x).reduce((a, b) => a + b) / 4,
            corners.map((point) => point.y).reduce((a, b) => a + b) / 4,
          ),
          'resize' => Offset(corners[0].x, corners[0].y),
          _ => Offset(frame.rotationCenter.x, frame.rotationCenter.y),
        };
        final before = runtime.initialCoordinator.snapshot.root;
        final picturesCreatedBefore = pictureObserver.created;
        final picturesDisposedBefore = pictureObserver.disposed;
        if (mode == 'rotate') {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        }
        final gesture = await tester.startGesture(
          origin + start,
          kind: PointerDeviceKind.mouse,
        );
        final pivot = Offset(
          corners.map((point) => point.x).reduce((a, b) => a + b) / 4,
          corners.map((point) => point.y).reduce((a, b) => a + b) / 4,
        );
        final rotationVector = start - pivot;
        for (var index = 0; index < 180; index += 1) {
          if (mode == 'rotate') {
            final radians = (index + 1) * math.pi / 360;
            await gesture.moveTo(
              origin +
                  pivot +
                  Offset(
                    rotationVector.dx * math.cos(radians) -
                        rotationVector.dy * math.sin(radians),
                    rotationVector.dx * math.sin(radians) +
                        rotationVector.dy * math.cos(radians),
                  ),
            );
          } else {
            await gesture.moveBy(
              mode == 'move'
                  ? const Offset(0.2, 0.1)
                  : const Offset(-0.2, -0.1),
            );
          }
          await tester.pump();
        }
        await gesture.up();
        if (mode == 'rotate') {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        }
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
          'Selection transformed',
          reason: mode,
        );
        final event = runtime.diagnosticTrace.events.lastWhere(
          (value) =>
              value.stage == Phase6DiagnosticStage.selectionTransformPreview,
        );
        expect(event.rawPoints, 180, reason: mode);
        expect(event.visualUpdates, 180, reason: mode);
        expect(event.geometryResolutions, 102, reason: mode);
        expect(event.handwritingGeometryPreparations, 100, reason: mode);
        expect(event.layoutRequests, 1, reason: mode);
        expect(event.commandOperations, 102, reason: mode);
        expect(event.rendererPreparations, 102, reason: mode);
        expect(event.selectedContentPictureCreations, 1, reason: mode);
        expect(event.sceneCompositions, 362, reason: mode);
        expect(event.perTargetPrimitiveRebuilds, 0, reason: mode);
        expect(event.unrelatedCommittedContentReplays, 0, reason: mode);
        expect(event.repaints, mode == 'rotate' ? 7 : 180, reason: mode);
        expect(event.maximumRetainedResources, 1, reason: mode);
        expect(event.handwritingTargetCount, 100, reason: mode);
        expect(event.shapeTargetCount, 1, reason: mode);
        expect(event.textTargetCount, 1, reason: mode);
        expect(event.terminalDisposition, 1, reason: mode);
        expect(event.terminalPublications, 1, reason: mode);
        expect(pictureObserver.created - picturesCreatedBefore, 1);
        expect(pictureObserver.disposed - picturesDisposedBefore, 1);
        final after = runtime.initialCoordinator.snapshot.root;
        expect(after, isNot(same(before)), reason: mode);
        await tester.tap(find.text('Undo'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(before));
        await tester.tap(find.text('Redo'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(after));
      }
    },
  );

  testWidgets(
    'left and right Shift snap rotation and release restores free angle',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();
      await tester.tap(find.text('Fill'));
      await tester.pump();
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final create = await tester.startGesture(
        center - const Offset(30, 20),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(60, 40));
      await create.up();
      await tester.pump();
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();

      double objectAngle() {
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
        final coefficients = object.transform.storageCoefficients;
        return math.atan2(coefficients[2], coefficients[0]);
      }

      Offset rotatedHandle(double radians) {
        final frame = _canvasPainter(tester).selectionFrame!;
        final pivot = Offset(
          frame.viewCorners.map((point) => point.x).reduce((a, b) => a + b) / 4,
          frame.viewCorners.map((point) => point.y).reduce((a, b) => a + b) / 4,
        );
        final start = Offset(frame.rotationCenter.x, frame.rotationCenter.y);
        final vector = start - pivot;
        return pivot +
            Offset(
              vector.dx * math.cos(radians) - vector.dy * math.sin(radians),
              vector.dx * math.sin(radians) + vector.dy * math.cos(radians),
            );
      }

      Future<void> snapped(LogicalKeyboardKey shiftKey) async {
        final beforeAngle = objectAngle();
        final frame = _canvasPainter(tester).selectionFrame!;
        final origin = tester.getTopLeft(
          find.byKey(const Key('phase6-canvas-listener')),
        );
        final rotate = await tester.startGesture(
          origin + Offset(frame.rotationCenter.x, frame.rotationCenter.y),
          kind: PointerDeviceKind.mouse,
        );
        await tester.sendKeyDownEvent(shiftKey);
        await rotate.moveTo(origin + rotatedHandle(20 * math.pi / 180));
        await rotate.up();
        await tester.sendKeyUpEvent(shiftKey);
        await tester.pump();
        expect(objectAngle() - beforeAngle, closeTo(math.pi / 12, 1e-9));
      }

      await snapped(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await snapped(LogicalKeyboardKey.shiftRight);
      await tester.tap(find.text('Undo'));
      await tester.pump();

      final beforeHeldAngle = objectAngle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      var heldFrame = _canvasPainter(tester).selectionFrame!;
      final heldOrigin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );
      final heldRotate = await tester.startGesture(
        heldOrigin +
            Offset(heldFrame.rotationCenter.x, heldFrame.rotationCenter.y),
        kind: PointerDeviceKind.mouse,
      );
      await heldRotate.moveTo(heldOrigin + rotatedHandle(20 * math.pi / 180));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      heldFrame = _canvasPainter(tester).selectionFrame!;
      expect(
        math.atan2(
          heldFrame.viewCorners[1].y - heldFrame.viewCorners[0].y,
          heldFrame.viewCorners[1].x - heldFrame.viewCorners[0].x,
        ),
        closeTo(math.pi / 12, 1e-8),
      );
      await heldRotate.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftRight);
      await tester.pump();
      expect(objectAngle() - beforeHeldAngle, closeTo(math.pi / 12, 1e-9));
      await tester.tap(find.text('Undo'));
      await tester.pump();

      final beforeFreeAngle = objectAngle();
      final frame = _canvasPainter(tester).selectionFrame!;
      final freePivot = Offset(
        frame.viewCorners.map((point) => point.x).reduce((a, b) => a + b) / 4,
        frame.viewCorners.map((point) => point.y).reduce((a, b) => a + b) / 4,
      );
      final freeStart = Offset(frame.rotationCenter.x, frame.rotationCenter.y);
      final freeVector = freeStart - freePivot;
      Offset freeTarget(double radians) =>
          freePivot +
          Offset(
            freeVector.dx * math.cos(radians) -
                freeVector.dy * math.sin(radians),
            freeVector.dx * math.sin(radians) +
                freeVector.dy * math.cos(radians),
          );
      final origin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );
      final rotate = await tester.startGesture(
        origin + Offset(frame.rotationCenter.x, frame.rotationCenter.y),
        kind: PointerDeviceKind.mouse,
      );
      await rotate.moveTo(origin + freeTarget(20 * math.pi / 180));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      double previewAngle() {
        final preview = _canvasPainter(tester).selectionFrame!;
        return math.atan2(
          preview.viewCorners[1].y - preview.viewCorners[0].y,
          preview.viewCorners[1].x - preview.viewCorners[0].x,
        );
      }

      expect(previewAngle(), closeTo(math.pi / 12, 1e-8));
      await rotate.moveTo(origin + freeTarget(31 * math.pi / 180));
      await tester.pump();
      expect(previewAngle(), closeTo(math.pi / 6, 1e-8));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(previewAngle(), closeTo(31 * math.pi / 180, 1e-8));
      await rotate.moveTo(origin + freeTarget(37 * math.pi / 180));
      await rotate.up();
      await tester.pump();
      expect(
        objectAngle() - beforeFreeAngle,
        closeTo(37 * math.pi / 180, 1e-9),
      );
      final shiftEvidence = runtime.diagnosticTrace.events.lastWhere(
        (event) =>
            event.stage == Phase6DiagnosticStage.selectionTransformPreview,
      );
      expect(shiftEvidence.shiftKeyDownEvents, 1);
      expect(shiftEvidence.shiftKeyUpEvents, 1);
      expect(shiftEvidence.shiftPointerUpdates, greaterThan(0));
      expect(shiftEvidence.snappedPreviewUpdates, greaterThanOrEqualTo(2));
      expect(shiftEvidence.finalSnapDisposition, 2);
    },
  );

  testWidgets(
    'Shift rotation crosses identity sectors and unwraps multiple turns',
    (WidgetTester tester) async {
      for (final objectCount in [1, 2]) {
        final generator = _RuntimeCountingUuidGenerator();
        final pictureObserver = _CountingPictureObserver();
        final runtime = _runtime(
          uuidGenerator: generator,
          nativePictureObserver: pictureObserver,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await tester.tap(find.text('shape'));
        await tester.pump();
        await tester.tap(find.text('Fill'));
        await tester.pump();
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final center = tester.getCenter(canvas);
        for (var index = 0; index < objectCount; index += 1) {
          final objectCenter = center + Offset((index * 2 - 1) * 35.0, 0);
          final create = await tester.startGesture(
            objectCenter - const Offset(16, 12),
            kind: PointerDeviceKind.mouse,
          );
          await create.moveBy(const Offset(32, 24));
          await create.up();
        }
        await tester.pump();
        await tester.tap(find.text('selection'));
        await tester.pump();
        if (objectCount == 1) {
          final select = await tester.startGesture(
            center - const Offset(35, 0),
            kind: PointerDeviceKind.mouse,
          );
          await select.up();
        } else {
          final marquee = await tester.startGesture(
            center - const Offset(80, 45),
            kind: PointerDeviceKind.mouse,
          );
          await marquee.moveTo(center + const Offset(80, 45));
          await marquee.up();
        }
        await tester.pump();
        final frame = _canvasPainter(tester).selectionFrame!;
        final origin = tester.getTopLeft(
          find.byKey(const Key('phase6-canvas-listener')),
        );
        final pivot = Offset(
          frame.viewCorners.map((point) => point.x).reduce((a, b) => a + b) / 4,
          frame.viewCorners.map((point) => point.y).reduce((a, b) => a + b) / 4,
        );
        final start = Offset(frame.rotationCenter.x, frame.rotationCenter.y);
        final vector = start - pivot;
        Offset target(double degrees) {
          final radians = degrees * math.pi / 180;
          return origin +
              pivot +
              Offset(
                vector.dx * math.cos(radians) - vector.dy * math.sin(radians),
                vector.dx * math.sin(radians) + vector.dy * math.cos(radians),
              );
        }

        final before = runtime.initialCoordinator.snapshot;
        final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
        final uuidBefore = generator.calls;
        var observerNotifications = 0;
        _ok(
          runtime.initialCoordinator.addListener((_) {
            observerNotifications += 1;
          }),
        );
        final baselinePixels = await _canvasBytes(tester);
        final createdBefore = pictureObserver.created;
        final disposedBefore = pictureObserver.disposed;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        final rotate = await tester.startGesture(
          origin + start,
          kind: PointerDeviceKind.mouse,
        );
        await rotate.moveTo(target(2));
        await tester.pump();
        expect(await _canvasBytes(tester), baselinePixels);
        await rotate.moveTo(target(20));
        await tester.pump();
        expect(await _canvasBytes(tester), isNot(baselinePixels));
        await rotate.moveTo(target(2));
        await tester.pump();
        expect(await _canvasBytes(tester), baselinePixels);
        for (var degrees = 5; degrees <= 720; degrees += 5) {
          await rotate.moveTo(target(degrees.toDouble()));
          await tester.pump();
          if (degrees == 360 || degrees == 720) {
            expect(await _canvasBytes(tester), baselinePixels);
          }
        }
        for (var degrees = 725; degrees <= 740; degrees += 5) {
          await rotate.moveTo(target(degrees.toDouble()));
          await tester.pump();
        }
        for (var degrees = 735; degrees >= 720; degrees -= 5) {
          await rotate.moveTo(target(degrees.toDouble()));
          await tester.pump();
        }
        expect(await _canvasBytes(tester), baselinePixels);
        await rotate.up();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(find.text('Selection unchanged'), findsOneWidget);
        expect(runtime.initialCoordinator.snapshot.root, same(before.root));
        expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
        expect(runtime.initialCoordinator.retainedHistoryCount, historyBefore);
        expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
        expect(generator.calls, uuidBefore);
        expect(observerNotifications, 0);
        expect(pictureObserver.created - createdBefore, 1);
        expect(pictureObserver.disposed - disposedBefore, 1);
        final evidence = runtime.diagnosticTrace.events.lastWhere(
          (event) =>
              event.stage == Phase6DiagnosticStage.selectionTransformPreview,
        );
        expect(evidence.terminalDisposition, 3);
        expect(evidence.terminalPublications, 0);
        expect(evidence.unwrappedAngleTransitions, greaterThan(140));
        expect(evidence.identitySectorEntries, greaterThanOrEqualTo(4));
        expect(evidence.identitySectorExits, greaterThanOrEqualTo(3));
        expect(evidence.branchCutCrossings, greaterThanOrEqualTo(2));
        expect(evidence.snappedPreviewUpdates, greaterThan(140));
      }
    },
  );

  testWidgets(
    'held Shift coalesces and terminal-flushes Text handwriting and mixed rotation',
    (WidgetTester tester) async {
      for (final targetKind in ['text', 'handwriting', 'mixed']) {
        final runtime = _runtime();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final center = tester.getCenter(canvas);
        Offset selectionPoint = center;
        if (targetKind == 'handwriting' || targetKind == 'mixed') {
          final draw = await tester.startGesture(
            center - const Offset(75, 40),
            kind: PointerDeviceKind.mouse,
          );
          await draw.moveTo(center + const Offset(5, -40));
          await draw.moveTo(center + const Offset(5, 40));
          await draw.moveTo(center - const Offset(75, -40));
          await draw.up();
          await tester.pump();
          selectionPoint = center + const Offset(-35, -40);
        }
        if (targetKind == 'mixed') {
          await tester.tap(find.text('shape'));
          await tester.pump();
          await tester.tap(find.text('Fill'));
          await tester.pump();
          final shape = await tester.startGesture(
            center - const Offset(15, 15),
            kind: PointerDeviceKind.mouse,
          );
          await shape.moveBy(const Offset(30, 30));
          await shape.up();
          await tester.pump();
        }
        if (targetKind == 'text' || targetKind == 'mixed') {
          await tester.tap(find.text('text'));
          await tester.pump();
          final create = await tester.startGesture(
            center + const Offset(35, -25),
            kind: PointerDeviceKind.mouse,
          );
          await create.moveBy(const Offset(100, 50));
          await create.up();
          await tester.pump();
          await tester.enterText(
            find.byKey(const Key('text-object-editor')),
            'snap target',
          );
          await _commitInlineText(tester);
          await tester.pump();
          if (targetKind == 'text') {
            selectionPoint = _textObjectCenterGlobal(
              tester,
              runtime,
              runtime.initialCoordinator.snapshot.root.pages.single.layers
                  .whereType<ContentLayer>()
                  .single
                  .objects
                  .single,
            );
          }
        }
        await tester.tap(find.text('selection'));
        await tester.pump();
        if (targetKind == 'mixed') {
          final marquee = await tester.startGesture(
            tester.getTopLeft(canvas) + const Offset(20, 20),
            kind: PointerDeviceKind.mouse,
          );
          await marquee.moveTo(
            tester.getBottomRight(canvas) - const Offset(20, 20),
          );
          await marquee.up();
        } else {
          final select = await tester.startGesture(
            selectionPoint,
            kind: PointerDeviceKind.mouse,
          );
          await select.up();
        }
        await tester.pump();
        final frameEvidence = _canvasPainter(tester).selectionFrame;
        expect(frameEvidence, isNotNull, reason: '$targetKind frame');
        final frame = frameEvidence!;
        final pivot = Offset(
          frame.viewCorners.map((point) => point.x).reduce((a, b) => a + b) / 4,
          frame.viewCorners.map((point) => point.y).reduce((a, b) => a + b) / 4,
        );
        final handle = Offset(frame.rotationCenter.x, frame.rotationCenter.y);
        final vector = handle - pivot;
        Offset target(double radians) =>
            pivot +
            Offset(
              vector.dx * math.cos(radians) - vector.dy * math.sin(radians),
              vector.dx * math.sin(radians) + vector.dy * math.cos(radians),
            );
        final origin = tester.getTopLeft(
          find.byKey(const Key('phase6-canvas-listener')),
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        final rotate = await tester.startGesture(
          origin + handle,
          kind: PointerDeviceKind.mouse,
        );
        for (var index = 0; index < 120; index += 1) {
          final degrees = 5 + 29 * index / 119;
          await rotate.moveTo(origin + target(degrees * math.pi / 180));
        }
        await rotate.up();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        final objects = runtime
            .initialCoordinator
            .snapshot
            .root
            .pages
            .single
            .layers
            .whereType<ContentLayer>()
            .single
            .objects;
        for (final object in objects) {
          final coefficients = object.transform.storageCoefficients;
          expect(
            math.atan2(coefficients[2], coefficients[0]),
            closeTo(math.pi / 6, 1e-9),
            reason: '$targetKind ${object.typeKey}',
          );
        }
        final evidence = runtime.diagnosticTrace.events.lastWhere(
          (event) =>
              event.stage == Phase6DiagnosticStage.selectionTransformPreview,
        );
        expect(
          evidence.rawPoints,
          inInclusiveRange(120, 121),
          reason: targetKind,
        );
        expect(
          evidence.visualUpdates,
          lessThanOrEqualTo(2),
          reason: targetKind,
        );
        expect(
          evidence.shiftPointerUpdates,
          inInclusiveRange(120, 121),
          reason: targetKind,
        );
        expect(
          evidence.snappedPreviewUpdates,
          greaterThan(0),
          reason: targetKind,
        );
        expect(evidence.finalSnapDisposition, 1, reason: targetKind);
        expect(evidence.terminalDisposition, 1, reason: targetKind);
      }
    },
  );

  testWidgets('Selection rotation focus loss cancels and clears Shift state', (
    WidgetTester tester,
  ) async {
    final pictureObserver = _CountingPictureObserver();
    final runtime = _runtime(nativePictureObserver: pictureObserver);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('shape'));
    await tester.pump();
    await tester.tap(find.text('Fill'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final create = await tester.startGesture(
      center - const Offset(35, 25),
      kind: PointerDeviceKind.mouse,
    );
    await create.moveBy(const Offset(70, 50));
    await create.up();
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final select = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    final before = runtime.initialCoordinator.snapshot;
    final frame = _canvasPainter(tester).selectionFrame!;
    final createdBefore = pictureObserver.created;
    final disposedBefore = pictureObserver.disposed;
    final origin = tester.getTopLeft(
      find.byKey(const Key('phase6-canvas-listener')),
    );
    final rotate = await tester.startGesture(
      origin + Offset(frame.rotationCenter.x, frame.rotationCenter.y),
      kind: PointerDeviceKind.mouse,
    );
    await rotate.moveBy(const Offset(20, 8));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.tap(find.byKey(const Key('zoom-input')));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await rotate.cancel();
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, same(before.root));
    expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
    expect(find.text('Gesture cancelled'), findsOneWidget);
    expect(pictureObserver.created - createdBefore, 1);
    expect(pictureObserver.disposed - disposedBefore, 1);

    await tester.tap(canvas);
    await tester.pump();
    final nextFrame = _canvasPainter(tester).selectionFrame!;
    final next = await tester.startGesture(
      origin + Offset(nextFrame.rotationCenter.x, nextFrame.rotationCenter.y),
      kind: PointerDeviceKind.mouse,
    );
    await next.moveBy(const Offset(17, 9));
    await tester.pump();
    final preview = _canvasPainter(tester).selectionFrame!;
    final angle = math.atan2(
      preview.viewCorners[1].y - preview.viewCorners[0].y,
      preview.viewCorners[1].x - preview.viewCorners[0].x,
    );
    final snappedSteps = angle / (math.pi / 12);
    expect((snappedSteps - snappedSteps.round()).abs(), greaterThan(1e-3));
    await next.cancel();
    await tester.pump();
    expect(pictureObserver.created - createdBefore, 2);
    expect(pictureObserver.disposed - disposedBefore, 2);
  });

  testWidgets('whole Eraser drag is one atomic sparse sweep with undo redo', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    for (final y in [-25.0, 25.0]) {
      final draw = await tester.startGesture(
        center + Offset(-60, y),
        kind: PointerDeviceKind.mouse,
      );
      await draw.moveBy(const Offset(120, 0));
      await draw.up();
      await tester.pump();
    }
    expect(_objectCount(runtime), 2);
    final committedPixels = await _canvasBytes(tester);
    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    final erase = await tester.startGesture(
      center + const Offset(0, -60),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 0; index < 12; index += 1) {
      await erase.moveBy(const Offset(0, 10));
    }
    await tester.pump();
    expect(_objectCount(runtime), 2);
    expect(_canvasPainterDescription(tester), contains('eraserPath: 13'));
    expect(_canvasPainterDescription(tester), contains('wholeSegments: 13'));
    expect(await _canvasBytes(tester), isNot(equals(committedPixels)));
    final beforeCommit = runtime.initialCoordinator.snapshot.revisions.document;
    await erase.up();
    await tester.pump();
    expect(_objectCount(runtime), 0);
    expect(
      runtime.initialCoordinator.snapshot.revisions.document.value,
      beforeCommit.value + 1,
    );
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(_objectCount(runtime), 2);
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    expect(_objectCount(runtime), 0);
  });

  testWidgets('whole Eraser predictive hiding cancels without publication', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final pen = await tester.startGesture(
      center + const Offset(-40, 0),
      kind: PointerDeviceKind.mouse,
    );
    await pen.moveBy(const Offset(80, 0));
    await pen.up();
    await tester.pump();
    final committed = await _canvasBytes(tester);
    final revision = runtime.initialCoordinator.snapshot.revisions.document;
    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    final eraser = await tester.startGesture(
      center + const Offset(0, -10),
      kind: PointerDeviceKind.mouse,
    );
    await eraser.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(await _canvasBytes(tester), isNot(equals(committed)));
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(await _canvasBytes(tester), equals(committed));
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
    await eraser.cancel();
  });

  testWidgets('malformed owned pointer events release routing fail-closed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final listener = tester.widget<Listener>(
      find.byKey(const Key('phase6-canvas-listener')),
    );
    listener.onPointerDown!(
      const PointerDownEvent(pointer: 40, position: Offset(double.nan, 0)),
    );
    final active = await tester.startGesture(
      tester.getCenter(canvas),
      pointer: 41,
      kind: PointerDeviceKind.mouse,
    );
    listener.onPointerMove!(
      const PointerMoveEvent(pointer: 42, position: Offset(double.nan, 0)),
    );
    await active.moveBy(const Offset(10, 0));
    listener.onPointerUp!(
      const PointerUpEvent(pointer: 41, position: Offset(double.nan, 0)),
    );
    await tester.pump();
    expect(find.text('Gesture rejected'), findsOneWidget);
    await active.cancel();
    final next = await tester.startGesture(
      tester.getCenter(canvas),
      pointer: 43,
      kind: PointerDeviceKind.mouse,
    );
    await next.moveBy(const Offset(20, 0));
    await next.up();
    await tester.pump();
    expect(find.text('Stroke committed'), findsOneWidget);

    for (final phase in ['move', 'cancel']) {
      final pointer = phase == 'move' ? 44 : 45;
      final owned = await tester.startGesture(
        tester.getCenter(canvas),
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
      );
      if (phase == 'move') {
        listener.onPointerMove!(
          PointerMoveEvent(
            pointer: pointer,
            position: const Offset(double.nan, 0),
          ),
        );
      } else {
        listener.onPointerCancel!(
          PointerCancelEvent(
            pointer: pointer,
            position: const Offset(double.nan, 0),
          ),
        );
      }
      await tester.pump();
      expect(find.text('Gesture rejected'), findsOneWidget);
      await owned.cancel();
    }
  });

  testWidgets('failed save remains dirty and can later save', (
    WidgetTester tester,
  ) async {
    final roomy = _runtime();
    final emptySnapshot = _ok(
      AlnotePackageSnapshot.create(
        document: roomy.initialRoot,
        resources: const [],
      ),
    );
    final emptyBytes = _ok(
      AlnotePackageCodec(objectRegistry: roomy.objectRegistry)
          .encode(emptySnapshot, limits: roomy.storageLimits),
    );
    final runtime = _runtime(storageCeiling: emptyBytes.length);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final draw = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await draw.moveBy(const Offset(20, 0));
    await draw.up();
    await tester.pumpAndSettle();
    expect(runtime.initialCoordinator.snapshot.isDirty, isTrue);

    await tester.tap(find.text('Save in memory'));
    await tester.pump();
    expect(find.text('Save failed'), findsOneWidget);
    expect(runtime.initialCoordinator.snapshot.isDirty, isTrue);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    await tester.tap(find.text('Save in memory'));
    await tester.pump();
    expect(find.textContaining('Saved in memory'), findsOneWidget);
    expect(runtime.initialCoordinator.snapshot.isDirty, isFalse);
  });

  testWidgets('drag Selection is live, ordered, atomic, and cancellable', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    for (final y in [-24.0, 24.0]) {
      final pen = await tester.startGesture(
        center + Offset(-45, y),
        kind: PointerDeviceKind.mouse,
      );
      await pen.moveBy(const Offset(90, 0));
      await pen.up();
      await tester.pump();
    }
    final revision = runtime.initialCoordinator.snapshot.revisions.document;
    final history = runtime.initialCoordinator.snapshot.canUndo;
    await tester.tap(find.text('selection'));
    await tester.pump();
    final beforeMarquee = await _canvasBytes(tester);
    final marquee = await tester.startGesture(
      center + const Offset(-70, -45),
      kind: PointerDeviceKind.mouse,
    );
    await marquee.moveTo(center + const Offset(70, 45));
    await tester.pump();
    expect(await _canvasBytes(tester), isNot(equals(beforeMarquee)));
    await marquee.up();
    await tester.pump();
    expect(find.text('2 Objects selected'), findsOneWidget);
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
    expect(runtime.initialCoordinator.snapshot.canUndo, history);

    final selected = await _canvasBytes(tester);
    final cancelled = await tester.startGesture(
      center + const Offset(80, 60),
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.moveBy(const Offset(30, 30));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(await _canvasBytes(tester), equals(selected));
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
    await cancelled.cancel();

    final clear = await tester.startGesture(
      center + const Offset(120, 80),
      kind: PointerDeviceKind.mouse,
    );
    await clear.moveBy(const Offset(30, 30));
    await clear.up();
    await tester.pump();
    expect(find.text('Selection cleared'), findsOneWidget);
  });

  testWidgets('zoom controls stay protected and aligned across resizing', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(520, 650));
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));
    await tester.pump();
    final toolbar = find.byKey(const Key('canvas-toolbar'));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    expect(
      tester.getBottomLeft(toolbar).dy,
      lessThanOrEqualTo(tester.getTopLeft(canvas).dy),
    );
    expect(find.text('Zoom In'), findsOneWidget);
    expect(find.text('Zoom Out'), findsOneWidget);

    tester.widget<Slider>(find.byKey(const Key('zoom-slider'))).onChanged!(8);
    await tester.pump();
    expect(find.byKey(const Key('zoom-percentage')), findsOneWidget);
    expect(find.text('800%'), findsWidgets);
    expect(find.text('Undo').hitTestable(), findsOneWidget);
    expect(find.text('Redo'), findsOneWidget);

    final atMaximum = tester.getCenter(canvas);
    final pen = await tester.startGesture(
      atMaximum,
      kind: PointerDeviceKind.mouse,
    );
    await pen.moveBy(const Offset(20, 0));
    await pen.up();
    await tester.pump();
    expect(find.text('Stroke committed'), findsOneWidget);
    await tester.tap(find.text('selection'));
    await tester.pump();
    final select = await tester.startGesture(
      atMaximum,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    expect(
      find.text('Object selected'),
      findsOneWidget,
      reason: tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
    );

    tester.widget<Slider>(find.byKey(const Key('zoom-slider'))).onChanged!(.25);
    await tester.pump();
    expect(find.text('25%'), findsWidgets);
    expect(find.text('Undo').hitTestable(), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(900, 700));
    await tester.pump();
    await tester.tap(find.byKey(const Key('zoom-reset')));
    await tester.pump();
    expect(find.text('100%'), findsWidgets);
    expect(
      tester.getBottomLeft(toolbar).dy,
      lessThanOrEqualTo(tester.getTopLeft(canvas).dy),
    );
    expect(tester.getRect(canvas).right, lessThanOrEqualTo(900));
  });

  testWidgets('realistic in-memory Save and Reopen cycles restore pixels', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final reopenFinder = find.widgetWithText(TextButton, 'Reopen saved');
    expect(tester.widget<TextButton>(reopenFinder).onPressed, isNull);
    for (final y in [-35.0, 0.0, 35.0]) {
      final pen = await tester.startGesture(
        center + Offset(-50, y),
        kind: PointerDeviceKind.mouse,
      );
      await pen.moveBy(const Offset(100, 0));
      await pen.up();
      await tester.pump();
    }
    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    final eraser = await tester.startGesture(
      center + const Offset(0, -8),
      kind: PointerDeviceKind.mouse,
    );
    await eraser.moveBy(const Offset(0, 16));
    await eraser.up();
    await tester.pump();
    expect(find.text('Stroke erased'), findsOneWidget);

    await tester.tap(find.text('Save in memory'));
    await tester.pump();
    expect(find.textContaining('Saved in memory'), findsOneWidget);
    expect(tester.widget<TextButton>(reopenFinder).onPressed, isNotNull);
    final savedEvidence = _canvasPainter(tester);
    final savedBytes = List<int>.of(savedEvidence.savedBytes as List<int>);
    final savedRoot = savedEvidence.savedRoot as DocumentRoot;
    final opened = AlnotePackageReader(objectRegistry: runtime.objectRegistry)
        .openBytes(
          savedBytes,
          limits: runtime.storageLimits,
          cancellationToken: CancellationController().token,
        );
    expect(opened, isA<Completed<OpenedAlnotePackage, StructuredFailure>>());
    final decoded =
        (opened as Completed<OpenedAlnotePackage, StructuredFailure>).value
            .materializeDocument(
              cancellationToken: CancellationController().token,
            );
    expect(decoded, isA<Completed<DocumentRoot, StructuredFailure>>());
    final decodedRoot =
        (decoded as Completed<DocumentRoot, StructuredFailure>).value;
    expect(decodedRoot, savedRoot);
    final savedPixels = await _canvasBytes(tester);

    await tester.tap(find.text('pen'));
    await tester.pump();
    final later = await tester.startGesture(
      center + const Offset(-30, 70),
      kind: PointerDeviceKind.mouse,
    );
    await later.moveBy(const Offset(60, 0));
    await later.up();
    await tester.pump();
    expect(await _canvasBytes(tester), isNot(equals(savedPixels)));

    await tester.tap(find.text('Reopen saved'));
    await tester.pump();
    expect(find.text('Reopened in-memory save'), findsOneWidget);
    final reopenedEvidence = _canvasPainter(tester);
    expect(reopenedEvidence.currentRoot, decodedRoot);
    expect(
      identical(
        reopenedEvidence.currentRoot,
        reopenedEvidence.reopenedMaterializedRoot,
      ),
      isTrue,
    );
    expect(await _canvasBytes(tester), equals(savedPixels));
    await tester.tap(find.text('Save in memory'));
    await tester.pump();
    await tester.tap(find.text('Reopen saved'));
    await tester.pump();
    expect(find.text('Reopened in-memory save'), findsOneWidget);
  });

  testWidgets('long Pen and Erasers keep bounded live work before terminal', (
    WidgetTester tester,
  ) async {
    final observer = _CountingPictureObserver();
    final runtime = _runtime(
      uuidGenerator: _RuntimeCountingUuidGenerator(),
      nativePictureObserver: observer,
    );
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final canvasCenter = tester.getCenter(canvas);
    for (var index = 0; index < 250; index += 1) {
      final existing = await tester.startGesture(
        canvasCenter +
            Offset(-150 + (index % 100) * 3, -105 + (index ~/ 100) * 6),
        kind: PointerDeviceKind.mouse,
      );
      await existing.moveBy(const Offset(3, 3));
      await existing.up();
      if (index % 50 == 49) await tester.pump();
    }
    await tester.pump();
    expect(_objectCount(runtime), 250);
    final start = tester.getCenter(canvas) - const Offset(180, 0);
    final pen = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(_penPreview(tester).previewedSampleCount, 1);
    final penClip = _canvasPainter(tester).pageClip!;
    final listenerOrigin = tester.getTopLeft(
      find.byKey(const Key('phase6-canvas-listener')),
    );
    final penZoom =
        penClip.width /
        runtime.initialCoordinator.snapshot.root.pages.single.size.width;
    for (var index = 1; index <= 2000; index += 1) {
      final acceptedView =
          start + Offset((index % 360).toDouble(), index.isEven ? 1 : -1);
      await pen.moveTo(acceptedView);
      final immediate = _penPreview(tester);
      expect(immediate.previewedSampleCount, index + 1);
      final latest = immediate.latestAcceptedSampleCenter!;
      expect(
        latest.x,
        closeTo(
          (acceptedView.dx - listenerOrigin.dx - penClip.left) / penZoom,
          1e-7,
        ),
      );
      expect(
        latest.y,
        closeTo(
          (acceptedView.dy - listenerOrigin.dy - penClip.top) / penZoom,
          1e-7,
        ),
      );
      final tailBounds = immediate.latestPrimitiveBounds!;
      final acceptedLocal = acceptedView - listenerOrigin;
      expect(
        acceptedLocal.dx,
        inInclusiveRange(tailBounds.left, tailBounds.right),
      );
      expect(
        acceptedLocal.dy,
        inInclusiveRange(tailBounds.top, tailBounds.bottom),
      );
      expect(immediate.activePrimitiveCount, lessThanOrEqualTo(192));
      expect(immediate.frozenChunkCount, lessThanOrEqualTo(8));
      if (index % 250 == 0) {
        await tester.pump();
        expect(
          _canvasPainter(tester).previewPrimitiveCount,
          lessThanOrEqualTo(192),
        );
        expect(find.text('Drawing'), findsOneWidget);
      }
    }
    await pen.up();
    await tester.pump();
    expect(find.text('Stroke committed'), findsOneWidget);
    await tester.pump();
    final penEvent = runtime.diagnosticTrace.events.lastWhere(
      (value) => value.stage == Phase6DiagnosticStage.penTerminal,
    );
    expect(penEvent.rawPoints, 2002);
    expect(penEvent.authoritativeSamples, 2001);
    expect(penEvent.visualUpdates, 2002);
    expect(penEvent.repaints, 2001);
    expect(penEvent.pendingWork, 0);
    expect(penEvent.sceneCompositions, 0);
    expect(penEvent.geometryResolutions, 2001);
    expect(penEvent.maximumActivePaintPrimitives, lessThanOrEqualTo(192));
    expect(penEvent.maximumRetainedResources, lessThanOrEqualTo(8));
    expect(penEvent.compactions, greaterThan(0));
    expect(penEvent.frozenReplays, lessThan(80));
    expect(penEvent.previewPaints, lessThan(20));
    expect(penEvent.parentRebuilds, lessThanOrEqualTo(2));
    expect(penEvent.terminalDisposition, 1);
    for (final stage in const [
      Phase6DiagnosticStage.penTerminalNormalization,
      Phase6DiagnosticStage.penRequestConstruction,
      Phase6DiagnosticStage.penCoordinatorPreparation,
      Phase6DiagnosticStage.penHistoryAccounting,
      Phase6DiagnosticStage.penPublicationObservers,
      Phase6DiagnosticStage.penSelectionReconciliation,
      Phase6DiagnosticStage.penCommittedSceneUpdate,
      Phase6DiagnosticStage.penFirstCommittedPaint,
      Phase6DiagnosticStage.penPointerUpReady,
    ]) {
      expect(
        runtime.diagnosticTrace.events.any((event) => event.stage == stage),
        isTrue,
        reason: stage.name,
      );
    }
    final sceneUpdate = runtime.diagnosticTrace.events.lastWhere(
      (event) => event.stage == Phase6DiagnosticStage.penCommittedSceneUpdate,
    );
    expect(sceneUpdate.cacheHits, 250);
    expect(sceneUpdate.geometryResolutions, 1);
    final firstCommittedPaint = runtime.diagnosticTrace.events.lastWhere(
      (event) => event.stage == Phase6DiagnosticStage.penFirstCommittedPaint,
    );
    expect(firstCommittedPaint.committedChunksRetained, greaterThan(0));
    expect(firstCommittedPaint.committedChunksRebuilt, 1);
    expect(firstCommittedPaint.unchangedObjectsReplayed, 0);
    expect(firstCommittedPaint.newObjectsRendered, 1);
    expect(firstCommittedPaint.committedPrimitivesPainted, greaterThan(0));
    expect(firstCommittedPaint.firstCommittedPaintInvocations, 1);
    expect(
      firstCommittedPaint.nativeResourcesCreated -
          firstCommittedPaint.nativeResourcesDisposed,
      inInclusiveRange(0, 8),
    );
    expect(observer.disposed, observer.created);
    expect(_objectCount(runtime), 251);

    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    final whole = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 180; index += 1) {
      await whole.moveBy(Offset(0, index.isEven ? 1 : -1));
    }
    await tester.pump();
    final wholeEvidence = _canvasPainter(tester);
    expect(wholeEvidence.previewPrimitiveCount, lessThanOrEqualTo(1));
    expect(wholeEvidence.eraserPathLength, 181);
    expect(wholeEvidence.wholeSegmentCount, 181);
    expect(wholeEvidence.wholeGeometryChecks, lessThan(256));
    await whole.up();
    await tester.pump();
    expect(find.text('Stroke erased'), findsOneWidget);
    final eraserEvent = runtime.diagnosticTrace.events.lastWhere(
      (value) => value.stage == Phase6DiagnosticStage.eraserTerminal,
    );
    expect(eraserEvent.acceptedTargets, 1);
    expect(eraserEvent.rejectedTargets, 0);
    expect(eraserEvent.commandOperations, 1);
    expect(eraserEvent.terminalDisposition, 1);
  });

  testWidgets(
    'Whole Eraser saturation keeps preview and applies bounded subset',
    (WidgetTester tester) async {
      final runtime = _runtime(maximumCommandOperations: 2);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      for (final dx in const [-100.0, 0.0, 100.0]) {
        final pen = await tester.startGesture(
          center + Offset(dx, -15),
          kind: PointerDeviceKind.mouse,
        );
        await pen.moveBy(const Offset(0, 30));
        await pen.up();
        await tester.pump();
      }
      expect(_objectCount(runtime), 3);
      final before = runtime.initialCoordinator.snapshot.root;
      await tester.tap(find.text('wholeEraser'));
      await tester.pump();
      final erase = await tester.startGesture(
        center - const Offset(120, 0),
        kind: PointerDeviceKind.mouse,
      );
      await erase.moveTo(center + const Offset(120, 0));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      expect(_canvasPainter(tester).previewPrimitiveCount, greaterThan(0));
      await erase.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      expect(_canvasPainter(tester).previewPrimitiveCount, greaterThan(0));
      await erase.up();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        'Eraser limit reached; accepted erasures applied',
      );
      expect(_objectCount(runtime), 1);
      final after = runtime.initialCoordinator.snapshot.root;
      final event = runtime.diagnosticTrace.events.lastWhere(
        (value) => value.stage == Phase6DiagnosticStage.eraserTerminal,
      );
      expect(event.acceptedTargets, 2);
      expect(event.rejectedTargets, greaterThan(0));
      expect(event.commandOperations, 2);
      expect(event.terminalDisposition, 3);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, before);
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, after);
    },
  );

  testWidgets('fitted paper stays centered through resize zoom save reopen', (
    WidgetTester tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');

    void expectCentered() {
      final clip = _canvasPainter(tester).pageClip!;
      final size = tester.getSize(canvas);
      expect((clip.left + clip.right) / 2, closeTo(size.width / 2, .01));
      expect((clip.top + clip.bottom) / 2, closeTo(size.height / 2, .01));
    }

    expectCentered();
    tester.widget<Slider>(find.byKey(const Key('zoom-slider'))).onChanged!(.5);
    await tester.pump();
    expectCentered();
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    await tester.pump();
    expectCentered();
    await tester.tap(find.text('Save in memory'));
    await tester.pump();
    await tester.tap(find.text('Reopen saved'));
    await tester.pump();
    expect(find.text('Reopened in-memory save'), findsOneWidget);
    expectCentered();
    await tester.tap(find.byKey(const Key('zoom-reset')));
    await tester.pump();
    expectCentered();
  });

  testWidgets('tool options and view navigation stay outside document state', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final toolbar = find.byKey(const Key('canvas-toolbar'));
    final options = find.byKey(const Key('canvas-tool-options'));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    expect(
      tester.getBottomLeft(toolbar).dy,
      lessThanOrEqualTo(tester.getTopLeft(options).dy),
    );
    expect(
      tester.getBottomLeft(options).dy,
      lessThanOrEqualTo(tester.getTopLeft(canvas).dy),
    );
    await tester.tap(find.text('shape'));
    await tester.pump();
    expect(find.byKey(const Key('shape-kind-control')), findsOneWidget);
    await tester.tap(find.text('pen'));
    await tester.pump();
    expect(find.byKey(const Key('shape-kind-control')), findsNothing);

    final beforeRoot = runtime.initialCoordinator.snapshot.root;
    final beforeClip = _canvasPainter(tester).pageClip!;
    final center = tester.getCenter(canvas);
    final pan = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await pan.moveBy(const Offset(40, 25));
    await pan.up();
    await tester.pump();
    final afterPanClip = _canvasPainter(tester).pageClip!;
    expect(afterPanClip, isNot(beforeClip));
    expect(runtime.initialCoordinator.snapshot.root, same(beforeRoot));
    expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, -120)),
    );
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(
      tester.widget<Text>(find.byKey(const Key('zoom-percentage'))).data,
      isNot('100%'),
    );
    expect(runtime.initialCoordinator.snapshot.root, same(beforeRoot));
  });

  testWidgets('coalesced wheel navigation exactly preserves event order', (
    WidgetTester tester,
  ) async {
    Future<(Rect2, String)> run({required bool pumpEach}) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);

      Future<void> signal(
        PointerScrollEvent event, {
        required bool zoom,
      }) async {
        if (zoom) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        }
        await tester.sendEventToBinding(event);
        if (zoom) {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        }
        if (pumpEach) await tester.pump();
      }

      await signal(
        PointerScrollEvent(
          position: center - const Offset(55, 35),
          scrollDelta: const Offset(0, -120),
        ),
        zoom: true,
      );
      await signal(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(24, -13),
        ),
        zoom: false,
      );
      await signal(
        PointerScrollEvent(
          position: center + const Offset(80, 45),
          scrollDelta: const Offset(0, 70),
        ),
        zoom: true,
      );
      await signal(
        const PointerScrollEvent(
          position: Offset(double.nan, 1),
          scrollDelta: Offset(double.nan, 0),
        ),
        zoom: false,
      );
      await signal(
        PointerScrollEvent(
          position: center + const Offset(10, -20),
          scrollDelta: const Offset(0, -1e308),
        ),
        zoom: true,
      );
      if (!pumpEach) await tester.pump();
      expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);
      return (
        _canvasPainter(tester).pageClip!,
        tester.widget<Text>(find.byKey(const Key('zoom-percentage'))).data!,
      );
    }

    final sequential = await run(pumpEach: true);
    final coalesced = await run(pumpEach: false);
    expect(coalesced.$1, sequential.$1);
    expect(coalesced.$2, sequential.$2);

    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final center = tester.getCenter(
      find.bySemanticsLabel('Handwriting canvas'),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(20, 10)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);
  });

  testWidgets(
    'long edited handwriting round-trips twice through real package controls',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final pen = await tester.startGesture(
        center - const Offset(160, 0),
        kind: PointerDeviceKind.mouse,
      );
      for (var index = 1; index <= 320; index += 1) {
        await pen.moveTo(center + Offset(index - 160, index.isEven ? 1 : -1));
      }
      await pen.up();
      await tester.pump();
      expect(find.text('Stroke committed'), findsOneWidget);

      await tester.tap(find.text('wholeEraser'));
      await tester.pump();
      final eraser = await tester.startGesture(
        center - const Offset(0, 24),
        kind: PointerDeviceKind.mouse,
      );
      await eraser.moveTo(center + const Offset(0, 24));
      await eraser.up();
      await tester.pumpAndSettle();
      expect(find.text('Stroke erased'), findsOneWidget);
      final editedRoot = _canvasPainter(tester).currentRoot;

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.text('Undone'), findsOneWidget);
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(find.text('Redone'), findsOneWidget);
      expect(_canvasPainter(tester).currentRoot, editedRoot);

      for (var cycle = 0; cycle < 2; cycle += 1) {
        await tester.tap(find.text('Save in memory'));
        await tester.pump();
        expect(find.textContaining('Saved in memory'), findsOneWidget);
        final saved = _canvasPainter(tester).savedRoot!;
        final reopen = find.widgetWithText(TextButton, 'Reopen saved');
        expect(tester.widget<TextButton>(reopen).onPressed, isNotNull);
        await tester.tap(find.text('pen'));
        await tester.pump();
        final extra = await tester.startGesture(
          center + Offset(-30, 50 + cycle * 12),
          kind: PointerDeviceKind.mouse,
        );
        await extra.moveBy(const Offset(60, 0));
        await extra.up();
        await tester.pump();
        expect(_canvasPainter(tester).currentRoot, isNot(saved));
        await tester.tap(find.text('Reopen saved'));
        await tester.pump();
        expect(find.text('Reopened in-memory save'), findsOneWidget);
        expect(_canvasPainter(tester).currentRoot, saved);
        expect(
          identical(
            _canvasPainter(tester).currentRoot,
            _canvasPainter(tester).reopenedMaterializedRoot,
          ),
          isTrue,
        );
      }
    },
  );

  testWidgets('every Reopen failure stage is fixed and preserves state', (
    WidgetTester tester,
  ) async {
    for (final stage in Phase6ReopenFailureStage.values) {
      final runtime = _runtime(reopenGateway: _FailingReopenGateway(stage));
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final first = await tester.startGesture(
        tester.getCenter(canvas),
        kind: PointerDeviceKind.mouse,
      );
      await first.moveBy(const Offset(20, 0));
      await first.up();
      await tester.pump();
      await tester.tap(find.text('Save in memory'));
      await tester.pump();
      final savedBytes = _canvasPainter(tester).savedBytes;
      final savedRoot = _canvasPainter(tester).savedRoot;
      final second = await tester.startGesture(
        tester.getCenter(canvas) + const Offset(0, 30),
        kind: PointerDeviceKind.mouse,
      );
      await second.moveBy(const Offset(20, 0));
      await second.up();
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot;
      final currentRoot = _canvasPainter(tester).currentRoot;
      await tester.tap(find.text('Reopen saved'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          stage == Phase6ReopenFailureStage.materialization
              ? 'Reopen failed (materialization)'
              : 'Reopen failed (${stage.name})',
        ),
        findsOneWidget,
      );
      expect(_canvasPainter(tester).currentRoot, same(currentRoot));
      expect(_canvasPainter(tester).savedBytes, same(savedBytes));
      expect(_canvasPainter(tester).savedRoot, same(savedRoot));
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.canRedo, before.canRedo);
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
    }
  });

  testWidgets('leaving Selection clears outlines without document history', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final pen = await tester.startGesture(
      center - const Offset(20, 0),
      kind: PointerDeviceKind.mouse,
    );
    await pen.moveBy(const Offset(40, 0));
    await pen.up();
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final selectedCenter = tester.getCenter(canvas);
    final select = await tester.startGesture(
      selectedCenter,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Object selected',
    );
    final selectedPixels = await _canvasBytes(tester);
    final before = runtime.initialCoordinator.snapshot;

    await tester.tap(find.text('pen'));
    await tester.pump();
    expect(await _canvasBytes(tester), isNot(equals(selectedPixels)));
    expect(runtime.initialCoordinator.snapshot.root, same(before.root));
    expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
    expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
    expect(runtime.initialCoordinator.snapshot.canRedo, before.canRedo);

    await tester.tap(find.text('selection'));
    await tester.pump();
    final active = await tester.startGesture(
      center - const Offset(40, 20),
      kind: PointerDeviceKind.mouse,
    );
    await active.moveBy(const Offset(80, 40));
    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    await active.cancel();
    expect(runtime.initialCoordinator.snapshot.root, same(before.root));
    expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
  });

  testWidgets('Shape tool creates, selects, whole-erases, undoes and redoes', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('shape'));
    await tester.pump();
    expect(find.byKey(const Key('shape-kind-control')), findsOneWidget);
    expect(find.byKey(const Key('shape-color-control')), findsOneWidget);
    await tester.tap(find.text('Fill'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final shapeGesture = await tester.startGesture(
      center - const Offset(40, 30),
      kind: PointerDeviceKind.mouse,
    );
    await shapeGesture.moveBy(const Offset(80, 60));
    await shapeGesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Shape created',
    );
    var objects = runtime.initialCoordinator.snapshot.root.pages.single.layers
        .whereType<ContentLayer>()
        .single
        .objects;
    expect(objects, hasLength(1));
    expect(objects.single.typeKey, shapeObjectTypeKey);

    await tester.tap(find.text('selection'));
    await tester.pump();
    final selectedCenter = tester.getCenter(canvas);
    final selectShape = await tester.startGesture(
      selectedCenter,
      kind: PointerDeviceKind.mouse,
    );
    await selectShape.up();
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Object selected',
    );

    await tester.tap(find.text('wholeEraser'));
    await tester.pump();
    final eraseShape = await tester.startGesture(
      selectedCenter - const Offset(5, 0),
      kind: PointerDeviceKind.mouse,
    );
    await eraseShape.moveBy(const Offset(10, 0));
    await eraseShape.up();
    await tester.pump();
    objects = runtime.initialCoordinator.snapshot.root.pages.single.layers
        .whereType<ContentLayer>()
        .single
        .objects;
    expect(objects, isEmpty);
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(
      runtime.initialCoordinator.snapshot.root.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects
          .single
          .typeKey,
      shapeObjectTypeKey,
    );
    await tester.tap(find.text('Redo'));
    await tester.pump();
    expect(
      runtime.initialCoordinator.snapshot.root.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects,
      isEmpty,
    );
  });

  testWidgets('Selection move previews and publishes one exact transform', (
    WidgetTester tester,
  ) async {
    final generator = _RuntimeCountingUuidGenerator();
    final runtime = _runtime(uuidGenerator: generator);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('shape'));
    await tester.pump();
    await tester.tap(find.text('Fill'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final create = await tester.startGesture(
      center - const Offset(40, 30),
      kind: PointerDeviceKind.mouse,
    );
    await create.moveBy(const Offset(80, 60));
    await create.up();
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final transformCenter = tester.getCenter(canvas);
    final select = await tester.startGesture(
      transformCenter,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    final before = runtime.initialCoordinator.snapshot.root;
    final uuidCalls = generator.calls;
    final move = await tester.startGesture(
      transformCenter,
      kind: PointerDeviceKind.mouse,
    );
    await move.moveBy(const Offset(30, 20));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, same(before));
    await move.up();
    await tester.pump();
    final after = runtime.initialCoordinator.snapshot.root;
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Selection transformed',
    );
    expect(after, isNot(same(before)));
    expect(
      generator.calls,
      uuidCalls + 1,
      reason: 'only the coordinator content identity is allocated',
    );
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, same(before));
    await tester.tap(find.text('Redo'));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, same(after));
  });

  testWidgets(
    'Selection toolbar transforms are atomic repeatable and undo exactly',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();
      await tester.tap(find.text('Fill'));
      await tester.pump();
      final center = tester.getCenter(
        find.bySemanticsLabel('Handwriting canvas'),
      );
      final create = await tester.startGesture(
        center - const Offset(35, 25),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(70, 50));
      await create.up();
      await tester.pump();
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();

      for (final label in [
        'Left',
        'Right',
        'Right',
        'Up',
        'Down',
        'Grow',
        'Rotate',
      ]) {
        final before = runtime.initialCoordinator.snapshot;
        final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
        await tester.tap(find.text(label));
        await tester.pump();
        final after = runtime.initialCoordinator.snapshot;
        expect(after.root, isNot(same(before.root)), reason: label);
        expect(
          after.revisions.document.value,
          before.revisions.document.value + 1,
          reason: label,
        );
        expect(
          runtime.initialCoordinator.retainedHistoryCount,
          historyBefore + 1,
          reason: label,
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
          'Selection transformed',
          reason: label,
        );
        await tester.tap(find.text('Undo'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(before.root));
        await tester.tap(find.text('Redo'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(after.root));
      }
    },
  );

  testWidgets(
    'every Selection toolbar command supports Text handwriting and mixed targets',
    (WidgetTester tester) async {
      for (final targetKind in ['text', 'handwriting', 'mixed']) {
        final generator = _RuntimeCountingUuidGenerator();
        final runtime = _runtime(uuidGenerator: generator);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final center = tester.getCenter(canvas);

        if (targetKind == 'handwriting' || targetKind == 'mixed') {
          final pen = await tester.startGesture(
            center - const Offset(90, 45),
            kind: PointerDeviceKind.mouse,
          );
          await pen.moveBy(const Offset(60, 0));
          await pen.up();
          await tester.pump();
        }
        if (targetKind == 'mixed') {
          await tester.tap(find.text('shape'));
          await tester.pump();
          await tester.tap(find.text('Fill'));
          await tester.pump();
          final shape = await tester.startGesture(
            center - const Offset(20, 15),
            kind: PointerDeviceKind.mouse,
          );
          await shape.moveBy(const Offset(40, 30));
          await shape.up();
          await tester.pump();
        }
        if (targetKind == 'text' || targetKind == 'mixed') {
          await tester.tap(find.text('text'));
          await tester.pump();
          final text = await tester.startGesture(
            center + const Offset(45, -20),
            kind: PointerDeviceKind.mouse,
          );
          await text.moveBy(const Offset(90, 40));
          await text.up();
          await tester.pump();
          await tester.enterText(
            find.byKey(const Key('text-object-editor')),
            'toolbar',
          );
          await _commitInlineText(tester);
          await tester.pump();
        }

        await tester.tap(find.text('selection'));
        await tester.pump();
        if (targetKind == 'mixed') {
          final marquee = await tester.startGesture(
            tester.getTopLeft(canvas) + const Offset(20, 20),
            kind: PointerDeviceKind.mouse,
          );
          await marquee.moveTo(
            tester.getBottomRight(canvas) - const Offset(20, 20),
          );
          await marquee.up();
        } else {
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
          final selectionPoint = targetKind == 'text'
              ? _textObjectCenterGlobal(tester, runtime, object)
              : center - const Offset(60, 45);
          final select = await tester.startGesture(
            selectionPoint,
            kind: PointerDeviceKind.mouse,
          );
          await select.up();
        }
        await tester.pump();
        expect(
          _canvasPainter(tester).selectionFrame,
          isNotNull,
          reason: targetKind,
        );

        final uuidCalls = generator.calls;
        for (final label in ['Left', 'Right', 'Up', 'Down', 'Grow', 'Rotate']) {
          final before = runtime.initialCoordinator.snapshot;
          final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
          await tester.tap(find.text(label));
          await tester.pump();
          final after = runtime.initialCoordinator.snapshot;
          expect(
            after.root,
            isNot(same(before.root)),
            reason: '$targetKind $label',
          );
          expect(
            after.revisions.document.value,
            before.revisions.document.value + 1,
            reason: '$targetKind $label',
          );
          expect(
            runtime.initialCoordinator.retainedHistoryCount,
            historyBefore + 1,
            reason: '$targetKind $label',
          );
        }
        expect(generator.calls, uuidCalls + 6, reason: targetKind);
      }
    },
  );

  testWidgets('Selection corner resize and rotation handles publish', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('shape'));
    await tester.pump();
    await tester.tap(find.text('Fill'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final create = await tester.startGesture(
      center - const Offset(40, 30),
      kind: PointerDeviceKind.mouse,
    );
    await create.moveBy(const Offset(80, 60));
    await create.up();
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final selectionCenter = tester.getCenter(canvas);
    final select = await tester.startGesture(
      selectionCenter,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    final objectBefore = runtime
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
    final listenerOrigin = tester.getTopLeft(
      find.byKey(const Key('phase6-canvas-listener')),
    );
    var frame = _canvasPainter(tester).selectionFrame!;
    expect(frame.viewCorners, hasLength(4));
    expect(frame.rotationRadius, 7);
    expect(
      math.sqrt(
        math.pow(frame.rotationCenter.x - frame.rotationConnectorStart.x, 2) +
            math.pow(
              frame.rotationCenter.y - frame.rotationConnectorStart.y,
              2,
            ),
      ),
      closeTo(28, 1e-8),
    );
    final missedRotation = await tester.startGesture(
      listenerOrigin +
          Offset(
            frame.rotationCenter.x + frame.rotationRadius + 6,
            frame.rotationCenter.y,
          ),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(find.text('Rotating selection'), findsNothing);
    await missedRotation.cancel();
    await tester.pump();

    final resize = await tester.startGesture(
      listenerOrigin + Offset(frame.viewCorners[2].x, frame.viewCorners[2].y),
      kind: PointerDeviceKind.mouse,
    );
    await resize.moveBy(const Offset(20, 15));
    await resize.up();
    await tester.pump();
    final resized = runtime.initialCoordinator.snapshot.root.pages.single.layers
        .whereType<ContentLayer>()
        .single
        .objects
        .single;
    expect(resized.transform, isNot(objectBefore.transform));
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Selection transformed',
    );

    await tester.tap(find.text('Undo'));
    await tester.pump();
    frame = _canvasPainter(tester).selectionFrame!;
    final rotate = await tester.startGesture(
      listenerOrigin + Offset(frame.rotationCenter.x, frame.rotationCenter.y),
      kind: PointerDeviceKind.mouse,
    );
    await rotate.moveBy(const Offset(58, 58));
    await rotate.up();
    await tester.pump();
    final rotated = runtime.initialCoordinator.snapshot.root.pages.single.layers
        .whereType<ContentLayer>()
        .single
        .objects
        .single;
    expect(rotated.transform, isNot(objectBefore.transform));
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Selection transformed',
    );
  });

  testWidgets(
    'all eight Selection resize zones preserve their exact opposite anchors',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();
      await tester.tap(find.text('Fill'));
      await tester.pump();
      final center = tester.getCenter(
        find.bySemanticsLabel('Handwriting canvas'),
      );
      final create = await tester.startGesture(
        center - const Offset(60, 45),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(120, 90));
      await create.up();
      await tester.pump();
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      final origin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );
      Offset midpoint(Offset first, Offset second) => (first + second) / 2;

      for (var zone = 0; zone < 8; zone += 1) {
        final frame = _canvasPainter(tester).selectionFrame!;
        final corners = frame.viewCorners
            .map((point) => Offset(point.x, point.y))
            .toList(growable: false);
        final starts = [
          corners[0],
          midpoint(corners[0], corners[1]),
          corners[1],
          midpoint(corners[1], corners[2]),
          corners[2],
          midpoint(corners[3], corners[2]),
          corners[3],
          midpoint(corners[0], corners[3]),
        ];
        final opposites = [
          corners[2],
          midpoint(corners[3], corners[2]),
          corners[3],
          midpoint(corners[0], corners[3]),
          corners[0],
          midpoint(corners[0], corners[1]),
          corners[1],
          midpoint(corners[1], corners[2]),
        ];
        final direction = starts[zone] - opposites[zone];
        final delta = direction / direction.distance * 14;
        final before = runtime.initialCoordinator.snapshot;
        final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
        final resize = await tester.startGesture(
          origin + starts[zone],
          kind: PointerDeviceKind.mouse,
        );
        await resize.moveBy(delta);
        await resize.up();
        await tester.pump();
        expect(
          runtime.initialCoordinator.snapshot.root,
          isNot(same(before.root)),
          reason: 'zone $zone',
        );
        expect(
          runtime.initialCoordinator.retainedHistoryCount,
          historyBefore + 1,
          reason: 'zone $zone',
        );
        final resizedCorners = _canvasPainter(tester)
            .selectionFrame!
            .viewCorners
            .map((point) => Offset(point.x, point.y))
            .toList(growable: false);
        final retained = [
          resizedCorners[2],
          midpoint(resizedCorners[3], resizedCorners[2]),
          resizedCorners[3],
          midpoint(resizedCorners[0], resizedCorners[3]),
          resizedCorners[0],
          midpoint(resizedCorners[0], resizedCorners[1]),
          resizedCorners[1],
          midpoint(resizedCorners[1], resizedCorners[2]),
        ][zone];
        expect(retained.dx, closeTo(opposites[zone].dx, 1e-8));
        expect(retained.dy, closeTo(opposites[zone].dy, 1e-8));
      }
    },
  );

  testWidgets(
    'Text handwriting and rotated Shape share all eight cursor resize zones',
    (WidgetTester tester) async {
      for (final scenario in [
        (kind: 'text', rotate: false),
        (kind: 'handwriting', rotate: false),
        (kind: 'shape', rotate: true),
      ]) {
        final runtime = _runtime();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final center = tester.getCenter(canvas);
        Offset selectionPoint = center;
        if (scenario.kind == 'text') {
          await tester.tap(find.text('text'));
          await tester.pump();
          final create = await tester.startGesture(
            center - const Offset(90, 45),
            kind: PointerDeviceKind.mouse,
          );
          await create.moveBy(const Offset(180, 90));
          await create.up();
          await tester.pump();
          await tester.enterText(
            find.byKey(const Key('text-object-editor')),
            'selection resize frame',
          );
          await _commitInlineText(tester);
          await tester.pump();
          selectionPoint = _textObjectCenterGlobal(
            tester,
            runtime,
            runtime.initialCoordinator.snapshot.root.pages.single.layers
                .whereType<ContentLayer>()
                .single
                .objects
                .single,
          );
        } else if (scenario.kind == 'handwriting') {
          final draw = await tester.startGesture(
            center - const Offset(70, 45),
            kind: PointerDeviceKind.mouse,
          );
          await draw.moveTo(center + const Offset(70, -45));
          await draw.moveTo(center + const Offset(70, 45));
          await draw.moveTo(center - const Offset(70, -45));
          await draw.up();
          await tester.pump();
          selectionPoint = center + const Offset(0, -45);
        } else {
          await tester.tap(find.text('shape'));
          await tester.pump();
          await tester.tap(find.text('Fill'));
          await tester.pump();
          final create = await tester.startGesture(
            center - const Offset(70, 45),
            kind: PointerDeviceKind.mouse,
          );
          await create.moveBy(const Offset(140, 90));
          await create.up();
          await tester.pump();
        }
        await tester.tap(find.text('selection'));
        await tester.pump();
        final select = await tester.startGesture(
          selectionPoint,
          kind: PointerDeviceKind.mouse,
        );
        await select.up();
        await tester.pump();
        if (scenario.rotate) {
          for (var turn = 0; turn < 3; turn += 1) {
            await tester.tap(find.text('Rotate'));
            await tester.pump();
          }
        }
        final origin = tester.getTopLeft(
          find.byKey(const Key('phase6-canvas-listener')),
        );
        final hoverDevice = 1200 + scenario.kind.length;
        await _addTestMouse(tester, origin + const Offset(2, 2), hoverDevice);
        Offset midpoint(Offset first, Offset second) => (first + second) / 2;
        if (scenario.rotate) {
          final rotated = _canvasPainter(tester).selectionFrame!.viewCorners;
          await _moveTestMouse(
            tester,
            origin +
                midpoint(
                  Offset(rotated[1].x, rotated[1].y),
                  Offset(rotated[2].x, rotated[2].y),
                ),
            hoverDevice,
          );
          await tester.pump();
          expect(
            tester
                .widget<MouseRegion>(
                  find.byKey(const Key('phase6-canvas-mouse-region')),
                )
                .cursor,
            SystemMouseCursors.resizeUpLeftDownRight,
          );
        }
        for (var zone = 0; zone < 8; zone += 1) {
          final frameEvidence = _canvasPainter(tester).selectionFrame;
          expect(
            frameEvidence,
            isNotNull,
            reason: '${scenario.kind} zone $zone frame',
          );
          final frame = frameEvidence!;
          final corners = frame.viewCorners
              .map((point) => Offset(point.x, point.y))
              .toList(growable: false);
          final starts = [
            corners[0],
            midpoint(corners[0], corners[1]),
            corners[1],
            midpoint(corners[1], corners[2]),
            corners[2],
            midpoint(corners[3], corners[2]),
            corners[3],
            midpoint(corners[0], corners[3]),
          ];
          final opposites = [
            corners[2],
            midpoint(corners[3], corners[2]),
            corners[3],
            midpoint(corners[0], corners[3]),
            corners[0],
            midpoint(corners[0], corners[1]),
            corners[1],
            midpoint(corners[1], corners[2]),
          ];
          await _moveTestMouse(tester, origin + starts[zone], hoverDevice);
          await tester.pump();
          expect(
            tester
                .widget<MouseRegion>(
                  find.byKey(const Key('phase6-canvas-mouse-region')),
                )
                .cursor,
            isNot(SystemMouseCursors.basic),
            reason: '${scenario.kind} zone $zone',
          );
          final direction = starts[zone] - opposites[zone];
          final delta = direction / direction.distance * 12;
          final before = runtime.initialCoordinator.snapshot.root;
          final resize = await tester.startGesture(
            origin + starts[zone],
            kind: PointerDeviceKind.mouse,
          );
          await resize.moveBy(delta);
          await resize.up();
          await tester.pump();
          expect(
            runtime.initialCoordinator.snapshot.root,
            isNot(same(before)),
            reason: '${scenario.kind} zone $zone',
          );
          final resized = _canvasPainter(tester).selectionFrame!.viewCorners
              .map((point) => Offset(point.x, point.y))
              .toList(growable: false);
          final retained = [
            resized[2],
            midpoint(resized[3], resized[2]),
            resized[3],
            midpoint(resized[0], resized[3]),
            resized[0],
            midpoint(resized[0], resized[1]),
            resized[1],
            midpoint(resized[1], resized[2]),
          ][zone];
          expect(
            retained.dx,
            closeTo(opposites[zone].dx, 1e-7),
            reason: '${scenario.kind} zone $zone x',
          );
          expect(
            retained.dy,
            closeTo(opposites[zone].dy, 1e-7),
            reason: '${scenario.kind} zone $zone y',
          );
        }
        await _moveTestMouse(tester, origin + const Offset(2, 2), hoverDevice);
        await tester.pump();
        expect(
          tester
              .widget<MouseRegion>(
                find.byKey(const Key('phase6-canvas-mouse-region')),
              )
              .cursor,
          SystemMouseCursors.basic,
          reason: scenario.kind,
        );
        await _removeTestMouse(tester, hoverDevice);
      }
    },
  );

  testWidgets(
    'tiny Selection overlap prefers a corner and grows with finite scale',
    (WidgetTester tester) async {
      final runtime = _runtime(minimumInteractiveSelectionExtentViewPixels: 24);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();
      await tester.tap(find.text('Fill'));
      await tester.pump();
      final center = tester.getCenter(
        find.bySemanticsLabel('Handwriting canvas'),
      );
      final create = await tester.startGesture(
        center - const Offset(2, 2),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(4, 4));
      await create.up();
      await tester.pump();
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      final frame = _canvasPainter(tester).selectionFrame!;
      final overlap = Offset(
        frame.viewCorners.map((point) => point.x).reduce((a, b) => a + b) / 4,
        frame.viewCorners.map((point) => point.y).reduce((a, b) => a + b) / 4,
      );
      final origin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );
      const hoverDevice = 1299;
      await _addTestMouse(tester, origin + const Offset(2, 2), hoverDevice);
      await _moveTestMouse(tester, origin + overlap, hoverDevice);
      await tester.pump();
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const Key('phase6-canvas-mouse-region')),
            )
            .cursor,
        SystemMouseCursors.resizeUpLeftDownRight,
      );
      final fixed = frame.viewCorners[2];
      final resize = await tester.startGesture(
        origin + overlap,
        kind: PointerDeviceKind.mouse,
      );
      await resize.moveBy(const Offset(-30, -30));
      await resize.up();
      await tester.pump();
      expect(find.text('Selection transformed'), findsOneWidget);
      final after = _canvasPainter(tester).selectionFrame!;
      expect(after.viewCorners[2].x, closeTo(fixed.x, 1e-8));
      expect(after.viewCorners[2].y, closeTo(fixed.y, 1e-8));
      expect(
        (after.viewCorners[1].x - after.viewCorners[0].x).abs(),
        greaterThanOrEqualTo(24),
      );
      await _removeTestMouse(tester, hoverDevice);
    },
  );

  testWidgets(
    'Selection resize enforces the injected view minimum after repeats and zoom',
    (WidgetTester tester) async {
      final runtime = _runtime(minimumInteractiveSelectionExtentViewPixels: 36);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      await tester.tap(find.text('shape'));
      await tester.pump();
      final create = await tester.startGesture(
        center - const Offset(70, 45),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(140, 90));
      await create.up();
      await tester.pump();
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        center - const Offset(0, 44),
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      final origin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );

      double width() {
        final corners = _canvasPainter(tester).selectionFrame!.viewCorners;
        return math.sqrt(
          math.pow(corners[1].x - corners[0].x, 2) +
              math.pow(corners[1].y - corners[0].y, 2),
        );
      }

      Offset rightHandle() {
        final corners = _canvasPainter(tester).selectionFrame!.viewCorners;
        return origin +
            Offset(
              (corners[1].x + corners[2].x) / 2,
              (corners[1].y + corners[2].y) / 2,
            );
      }

      Offset inward(double amount) {
        final corners = _canvasPainter(tester).selectionFrame!.viewCorners;
        final dx = corners[1].x - corners[0].x;
        final dy = corners[1].y - corners[0].y;
        final length = math.sqrt(dx * dx + dy * dy);
        return Offset(-dx / length * amount, -dy / length * amount);
      }

      Future<void> shrinkToMinimum() async {
        final resize = await tester.startGesture(
          rightHandle(),
          kind: PointerDeviceKind.mouse,
        );
        await resize.moveBy(inward(1000));
        await resize.up();
        await tester.pump();
        expect(width(), closeTo(36, 1e-7));
      }

      await shrinkToMinimum();
      final atMinimum = runtime.initialCoordinator.snapshot;
      final directionChangesBefore = runtime.initialCoordinator.snapshot.root;
      final outwardAxis = -inward(1);
      final directionChanges = await tester.startGesture(
        rightHandle(),
        kind: PointerDeviceKind.mouse,
      );
      await directionChanges.moveBy(outwardAxis * 80);
      await tester.pump();
      expect(width(), greaterThan(36));
      await directionChanges.moveBy(-outwardAxis * 200);
      await tester.pump();
      expect(width(), closeTo(36, 1e-7));
      await directionChanges.moveBy(outwardAxis * 260);
      await tester.pump();
      final terminalPreviewWidth = width();
      expect(terminalPreviewWidth, greaterThan(36));
      await directionChanges.up();
      await tester.pump();
      expect(width(), closeTo(terminalPreviewWidth, 1e-7));
      expect(
        runtime.initialCoordinator.snapshot.root,
        isNot(same(directionChangesBefore)),
      );
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(atMinimum.root));
      final restoredMinimum = runtime.initialCoordinator.snapshot;
      await shrinkToMinimum();
      expect(
        runtime.initialCoordinator.snapshot.root,
        same(restoredMinimum.root),
      );
      expect(
        runtime.initialCoordinator.snapshot.revisions,
        restoredMinimum.revisions,
      );
      final unchangedEvidence = runtime.diagnosticTrace.events.lastWhere(
        (event) =>
            event.stage == Phase6DiagnosticStage.selectionTransformPreview,
      );
      expect(unchangedEvidence.terminalDisposition, 3);
      expect(unchangedEvidence.failureStageCode, 0);
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(width(), greaterThan(36));
      await shrinkToMinimum();
      await tester.tap(find.text('Rotate'));
      await tester.pump();
      expect(width(), closeTo(36, 1e-7));
      const hoverDevice = 991;
      await _addTestMouse(tester, center, hoverDevice);
      await _moveTestMouse(tester, rightHandle(), hoverDevice);
      await tester.pump();
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const Key('phase6-canvas-mouse-region')),
            )
            .cursor,
        isNot(SystemMouseCursors.basic),
      );
      await _removeTestMouse(tester, hoverDevice);
      await shrinkToMinimum();
    },
  );

  testWidgets(
    'Shape previews use authoritative kind style and color geometry',
    (WidgetTester tester) async {
      Future<void> configure({
        required ShapeKind kind,
        required bool stroke,
        required bool fill,
        required String color,
      }) async {
        await tester.tap(find.byKey(const Key('shape-kind-control')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(kind.name).last);
        await tester.pump();
        final strokeChip = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, 'Stroke'),
        );
        if (strokeChip.selected != stroke) {
          await tester.tap(find.widgetWithText(FilterChip, 'Stroke'));
          await tester.pump();
        }
        final fillChip = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, 'Fill'),
        );
        if (fillChip.selected != fill) {
          await tester.tap(find.widgetWithText(FilterChip, 'Fill'));
          await tester.pump();
        }
        await tester.tap(find.byKey(const Key('shape-color-control')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(color).last);
        await tester.pump();
      }

      for (final entry in <(ShapeKind, bool, bool, String, List<int>)>[
        (ShapeKind.line, true, false, 'Navy', const [23, 50, 77]),
        (ShapeKind.rectangle, true, false, 'Black', const [17, 17, 17]),
        (ShapeKind.ellipse, true, false, 'Red', const [180, 35, 24]),
        (ShapeKind.rectangle, false, true, 'Navy', const [23, 50, 77]),
        (ShapeKind.rectangle, true, true, 'Red', const [180, 35, 24]),
      ]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final generator = _RuntimeCountingUuidGenerator();
        final runtime = _runtime(uuidGenerator: generator);
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await tester.tap(find.text('shape'));
        await tester.pump();
        await configure(
          kind: entry.$1,
          stroke: entry.$2,
          fill: entry.$3,
          color: entry.$4,
        );
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final center = tester.getCenter(canvas);
        final start = center - const Offset(60, 40);
        final end = center + const Offset(60, 40);
        final before = await _canvasImage(tester);
        final documentBefore = runtime.initialCoordinator.snapshot;
        final uuidCallsBeforeGesture = generator.calls;
        final gesture = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(end);
        await tester.pump();
        final preview = await _canvasImage(tester);

        expect(generator.calls, uuidCallsBeforeGesture);
        expect(
          runtime.initialCoordinator.snapshot.root,
          same(documentBefore.root),
        );
        expect(
          runtime.initialCoordinator.snapshot.revisions,
          documentBefore.revisions,
        );
        expect(
          runtime.initialCoordinator.snapshot.canUndo,
          documentBefore.canUndo,
        );
        expect(
          _changedNear(before, preview, center, radius: 4),
          entry.$1 == ShapeKind.line || entry.$3,
        );
        if (entry.$1 == ShapeKind.line) {
          expect(
            _changedNear(
              before,
              preview,
              center + const Offset(0, -40),
              radius: 4,
            ),
            isFalse,
            reason: 'line preview must not draw rectangular top edge',
          );
        } else if (entry.$1 == ShapeKind.rectangle) {
          expect(
            _changedNear(
              before,
              preview,
              center + const Offset(0, -40),
              radius: 4,
            ),
            isTrue,
          );
        } else {
          expect(
            _changedNear(
              before,
              preview,
              center + const Offset(0, -40),
              radius: 4,
            ),
            isTrue,
          );
          expect(
            _changedNear(before, preview, start, radius: 4),
            isFalse,
            reason: 'ellipse preview must not draw rectangular corner',
          );
        }
        final coloredPoint = entry.$3
            ? center
            : entry.$1 == ShapeKind.line
            ? center
            : center + const Offset(0, -40);
        expect(
          _nearestChangedRgb(before, preview, coloredPoint, radius: 5),
          entry.$5,
        );
        await gesture.cancel();
        await tester.pump();
        expect(await _canvasBytes(tester), before.bytes);
        expect(generator.calls, uuidCallsBeforeGesture);
        expect(
          runtime.initialCoordinator.snapshot.root,
          same(documentBefore.root),
        );
        expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);
      }
    },
  );

  testWidgets(
    'Shape preview equals committed pixels under zoom and move is nonpersistent',
    (WidgetTester tester) async {
      final generator = _RuntimeCountingUuidGenerator();
      final runtime = _runtime(uuidGenerator: generator);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();
      await tester.tap(find.text('Fill'));
      await tester.pump();
      tester.widget<Slider>(find.byKey(const Key('zoom-slider'))).onChanged!(2);
      await tester.pump();
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final before = runtime.initialCoordinator.snapshot;
      final uuidCallsBeforeGesture = generator.calls;
      final gesture = await tester.startGesture(
        center - const Offset(50, 35),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(100, 70));
      await tester.pump();
      final preview = await _canvasBytes(tester);
      expect(generator.calls, uuidCallsBeforeGesture);
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);

      await gesture.up();
      await tester.pump();
      final committed = await _canvasBytes(tester);
      var maximumDelta = 0;
      for (var index = 0; index < preview.length; index++) {
        maximumDelta = math.max(
          maximumDelta,
          (preview[index] - committed[index]).abs(),
        );
      }
      expect(maximumDelta, lessThanOrEqualTo(1));
      expect(generator.calls, uuidCallsBeforeGesture + 3);
      expect(
        runtime.initialCoordinator.snapshot.root.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects,
        hasLength(1),
      );
      expect(runtime.initialCoordinator.snapshot.canUndo, isTrue);
      _ok(runtime.initialCoordinator.undo());
      expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);
      expect(
        runtime.initialCoordinator.snapshot.root.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects,
        isEmpty,
      );
    },
  );

  testWidgets(
    'Line selection forces stroke, disables fill, and remains equivalent',
    (WidgetTester tester) async {
      final generator = _RuntimeCountingUuidGenerator();
      final runtime = _runtime(uuidGenerator: generator);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();

      await tester.tap(find.byKey(const Key('shape-stroke-control')));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-stroke-control')))
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-fill-control')))
            .selected,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('shape-kind-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('line').last);
      await tester.pump();
      final lineStroke = tester.widget<FilterChip>(
        find.byKey(const Key('shape-stroke-control')),
      );
      final lineFill = tester.widget<FilterChip>(
        find.byKey(const Key('shape-fill-control')),
      );
      expect(lineStroke.selected, isTrue);
      expect(lineStroke.onSelected, isNull);
      expect(lineFill.selected, isFalse);
      expect(lineFill.onSelected, isNull);
      expect(find.byTooltip('Lines require a visible stroke'), findsOneWidget);
      expect(find.byTooltip('Fill is unavailable for lines'), findsOneWidget);

      await tester.tap(find.byKey(const Key('shape-kind-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ellipse').last);
      await tester.pump();
      await tester.tap(find.byKey(const Key('shape-fill-control')));
      await tester.tap(find.byKey(const Key('shape-stroke-control')));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-stroke-control')))
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-fill-control')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('shape-kind-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('line').last);
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-stroke-control')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-fill-control')))
            .selected,
        isFalse,
      );

      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final beforeImage = await _canvasImage(tester);
      final beforeDocument = runtime.initialCoordinator.snapshot;
      final uuidCallsBeforeGesture = generator.calls;
      final gesture = await tester.startGesture(
        center - const Offset(55, 35),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(110, 70));
      await tester.pump();
      final preview = await _canvasImage(tester);
      expect(_changedNear(beforeImage, preview, center, radius: 4), isTrue);
      expect(generator.calls, uuidCallsBeforeGesture);
      expect(
        runtime.initialCoordinator.snapshot.root,
        same(beforeDocument.root),
      );
      expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);

      await gesture.up();
      await tester.pump();
      final committed = await _canvasImage(tester);
      var maximumDelta = 0;
      for (var index = 0; index < preview.bytes.length; index += 1) {
        maximumDelta = math.max(
          maximumDelta,
          (preview.bytes[index] - committed.bytes[index]).abs(),
        );
      }
      expect(maximumDelta, lessThanOrEqualTo(1));
      expect(generator.calls, uuidCallsBeforeGesture + 3);
      final objects = runtime
          .initialCoordinator
          .snapshot
          .root
          .pages
          .single
          .layers
          .whereType<ContentLayer>()
          .single
          .objects;
      expect(objects, hasLength(1));
      final payload = _ok(
        ShapePayload.decode(
          objects.single.payload,
          limits: runtime.shapeLimits,
        ),
      );
      expect(payload.geometry.kind, ShapeKind.line);
      expect(payload.style.strokeEnabled, isTrue);
      expect(payload.style.fillEnabled, isFalse);

      await tester.tap(find.byKey(const Key('shape-kind-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('rectangle').last);
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-stroke-control')))
            .onSelected,
        isNotNull,
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-fill-control')))
            .onSelected,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('shape-fill-control')));
      await tester.tap(find.byKey(const Key('shape-stroke-control')));
      await tester.pump();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-stroke-control')))
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('shape-fill-control')))
            .selected,
        isTrue,
      );
      _ok(runtime.initialCoordinator.undo());
      expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);
    },
  );

  testWidgets('Stale invalid line controls publish no invisible object', (
    WidgetTester tester,
  ) async {
    final generator = _RuntimeCountingUuidGenerator();
    final runtime = _runtime(uuidGenerator: generator);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('shape'));
    await tester.pump();
    final staleStrokeCallback = tester
        .widget<FilterChip>(find.byKey(const Key('shape-stroke-control')))
        .onSelected!;
    await tester.tap(find.byKey(const Key('shape-kind-control')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('line').last);
    await tester.pump();

    staleStrokeCallback(false);
    await tester.pump();
    expect(
      tester
          .widget<FilterChip>(find.byKey(const Key('shape-stroke-control')))
          .selected,
      isFalse,
    );
    expect(
      tester
          .widget<FilterChip>(find.byKey(const Key('shape-fill-control')))
          .selected,
      isTrue,
    );
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final beforeImage = await _canvasBytes(tester);
    final beforeDocument = runtime.initialCoordinator.snapshot;
    final uuidCallsBeforeGesture = generator.calls;
    final gesture = await tester.startGesture(
      center - const Offset(45, 25),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(90, 50));
    await tester.pump();
    expect(await _canvasBytes(tester), beforeImage);
    expect(generator.calls, uuidCallsBeforeGesture);
    expect(runtime.initialCoordinator.snapshot.root, same(beforeDocument.root));
    expect(
      runtime.initialCoordinator.snapshot.revisions,
      beforeDocument.revisions,
    );
    expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);

    await gesture.up();
    await tester.pump();
    expect(generator.calls, uuidCallsBeforeGesture);
    expect(runtime.initialCoordinator.snapshot.root, same(beforeDocument.root));
    expect(
      runtime.initialCoordinator.snapshot.revisions,
      beforeDocument.revisions,
    );
    expect(runtime.initialCoordinator.snapshot.canUndo, isFalse);
    expect(
      runtime.initialCoordinator.snapshot.root.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects,
      isEmpty,
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Shape rejected',
    );
  });

  testWidgets(
    'Text tool uses editor overlay and empty cancellation publishes nothing',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('text'));
      await tester.pump();
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final textGesture = await tester.startGesture(
        center - const Offset(70, 35),
        kind: PointerDeviceKind.mouse,
      );
      await textGesture.moveBy(const Offset(140, 70));
      await textGesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        'Creating text box',
      );
      expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
      expect(
        find.byKey(const Key('inline-text-dashed-boundary')),
        findsOneWidget,
      );
      expect(find.text('Text'), findsNothing);
      expect(find.text('Add'), findsNothing);
      expect(find.text('Save'), findsNothing);
      expect(find.text('Cancel'), findsNothing);
      expect(
        tester
            .widget<Material>(
              find.byKey(const Key('inline-text-editor-surface')),
            )
            .type,
        MaterialType.transparency,
      );
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'Cafe\u0301 👩‍💻 مرحبا',
      );
      await tester.tap(find.text('Bold'));
      await _commitInlineText(tester);
      await tester.pumpAndSettle();
      final objects = runtime
          .initialCoordinator
          .snapshot
          .root
          .pages
          .single
          .layers
          .whereType<ContentLayer>()
          .single
          .objects;
      expect(objects, hasLength(1));
      expect(objects.single.typeKey, textObjectTypeKey);
      final payload = _ok(
        TextPayload.decode(objects.single.payload, limits: runtime.textLimits),
      );
      expect(payload.logicalText, 'Cafe\u0301 👩‍💻 مرحبا');
      expect(payload.defaultCharacterStyle.weight, 700);
      final committedCenter = _textObjectCenterGlobal(
        tester,
        runtime,
        objects.single,
      );

      await tester.tap(find.text('selection'));
      await tester.pump();
      final selectText = await tester.startGesture(
        committedCenter,
        kind: PointerDeviceKind.mouse,
      );
      await selectText.up();
      await tester.pump();
      expect(find.byKey(const Key('edit-selected-text')), findsOneWidget);
      expect(_canvasPainter(tester).selectionPrimitiveCount, 3);
      final beforeEditorOpen = runtime.initialCoordinator.snapshot;
      final historyBeforeEditorOpen =
          runtime.initialCoordinator.retainedHistoryCount;
      for (var click = 0; click < 2; click += 1) {
        final doubleClick = await tester.startGesture(
          committedCenter,
          kind: PointerDeviceKind.mouse,
        );
        await doubleClick.up();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
      expect(find.byKey(const Key('edit-selected-text')), findsNothing);
      expect(_canvasPainter(tester).selectionPrimitiveCount, 0);
      expect(
        runtime.initialCoordinator.snapshot.root,
        same(beforeEditorOpen.root),
      );
      expect(
        runtime.initialCoordinator.snapshot.revisions,
        beforeEditorOpen.revisions,
      );
      expect(
        runtime.initialCoordinator.retainedHistoryCount,
        historyBeforeEditorOpen,
      );
      await tester.enterText(find.byKey(const Key('text-object-editor')), '');
      await _commitInlineText(tester);
      await tester.pumpAndSettle();
      var edited = _ok(
        TextPayload.decode(
          runtime.initialCoordinator.snapshot.root.pages.single.layers
              .whereType<ContentLayer>()
              .single
              .objects
              .single
              .payload,
          limits: runtime.textLimits,
        ),
      );
      expect(edited.logicalText, isEmpty);
      expect(
        runtime.initialCoordinator.snapshot.root.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects,
        hasLength(1),
      );
      await tester.tap(find.text('Undo'));
      await tester.pump();
      edited = _ok(
        TextPayload.decode(
          runtime.initialCoordinator.snapshot.root.pages.single.layers
              .whereType<ContentLayer>()
              .single
              .objects
              .single
              .payload,
          limits: runtime.textLimits,
        ),
      );
      expect(edited.logicalText, payload.logicalText);
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(
        _ok(
          TextPayload.decode(
            runtime.initialCoordinator.snapshot.root.pages.single.layers
                .whereType<ContentLayer>()
                .single
                .objects
                .single
                .payload,
            limits: runtime.textLimits,
          ),
        ).logicalText,
        isEmpty,
      );

      final reselect = await tester.startGesture(
        _textObjectCenterGlobal(
          tester,
          runtime,
          runtime.initialCoordinator.snapshot.root.pages.single.layers
              .whereType<ContentLayer>()
              .single
              .objects
              .single,
        ),
        kind: PointerDeviceKind.mouse,
      );
      await reselect.up();
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'lifecycle flush',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(find.byKey(const Key('text-object-editor')), findsNothing);
      expect(
        _ok(
          TextPayload.decode(
            runtime.initialCoordinator.snapshot.root.pages.single.layers
                .whereType<ContentLayer>()
                .single
                .objects
                .single
                .payload,
            limits: runtime.textLimits,
          ),
        ).logicalText,
        'lifecycle flush',
      );

      await tester.tap(find.text('text'));
      await tester.pump();
      final emptyText = await tester.startGesture(
        center + const Offset(100, 100),
        kind: PointerDeviceKind.mouse,
      );
      await emptyText.up();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        runtime.initialCoordinator.snapshot.root.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects,
        hasLength(1),
      );
    },
  );

  testWidgets(
    'short Text commit fits intrinsic selection hit and editor bounds',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final boxTopLeft = center - const Offset(110, 70);
      await tester.tap(find.text('text'));
      await tester.pump();
      final create = await tester.startGesture(
        boxTopLeft,
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(220, 140));
      await create.up();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('text-object-editor')), 'Hi');
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
      final payload = _ok(
        TextPayload.decode(object.payload, limits: runtime.textLimits),
      );
      expect(payload.intrinsicWidth, lessThan(100));
      expect(payload.intrinsicHeight, lessThan(80));
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        boxTopLeft + const Offset(14, 14),
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      final frame = _canvasPainter(tester).selectionFrame!;
      final visualWidth = math.sqrt(
        math.pow(frame.viewCorners[1].x - frame.viewCorners[0].x, 2) +
            math.pow(frame.viewCorners[1].y - frame.viewCorners[0].y, 2),
      );
      final visualHeight = math.sqrt(
        math.pow(frame.viewCorners[3].x - frame.viewCorners[0].x, 2) +
            math.pow(frame.viewCorners[3].y - frame.viewCorners[0].y, 2),
      );
      expect(visualWidth, closeTo(payload.intrinsicWidth, 1e-8));
      expect(visualHeight, closeTo(payload.intrinsicHeight!, 1e-8));
      final rootBeforeEditor = runtime.initialCoordinator.snapshot.root;
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const Key('inline-text-editor-overlay'))),
        Size(payload.intrinsicWidth, payload.intrinsicHeight!),
      );
      expect(runtime.initialCoordinator.snapshot.root, same(rootBeforeEditor));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(rootBeforeEditor));
    },
  );

  testWidgets(
    'Text fit preserves multiline wrapping alignment style and whitespace',
    (WidgetTester tester) async {
      double pointDistance(Point2 first, Point2 second) => math.sqrt(
        math.pow(second.x - first.x, 2) + math.pow(second.y - first.y, 2),
      );
      for (final value in [
        (
          text: 'first line\nsecond line\n',
          alignment: TextAlignment.left,
          bold: false,
          italic: false,
          width: 260.0,
          height: 180.0,
        ),
        (
          text: 'alpha beta gamma delta epsilon zeta eta theta',
          alignment: TextAlignment.center,
          bold: true,
          italic: false,
          width: 150.0,
          height: 220.0,
        ),
        (
          text: '  leading and trailing   ',
          alignment: TextAlignment.right,
          bold: false,
          italic: true,
          width: 280.0,
          height: 140.0,
        ),
      ]) {
        final runtime = _runtime();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await tester.tap(find.text('text'));
        await tester.pump();
        if (value.alignment != TextAlignment.left) {
          await tester.tap(find.byKey(const Key('text-alignment-control')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(value.alignment.name).last);
          await tester.pump();
        }
        if (value.bold) {
          await tester.tap(find.text('Bold'));
          await tester.pump();
        }
        if (value.italic) {
          await tester.tap(find.text('Italic'));
          await tester.pump();
        }
        final center = tester.getCenter(
          find.bySemanticsLabel('Handwriting canvas'),
        );
        final create = await tester.startGesture(
          center - Offset(value.width / 2, value.height / 2),
          kind: PointerDeviceKind.mouse,
        );
        await create.moveBy(Offset(value.width, value.height));
        await create.up();
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('text-object-editor')),
          value.text,
        );
        await _commitInlineText(tester);
        await tester.pump();
        final fittedRoot = runtime.initialCoordinator.snapshot.root;
        final object = fittedRoot.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects
            .single;
        final payload = _ok(
          TextPayload.decode(object.payload, limits: runtime.textLimits),
        );
        expect(payload.logicalText, value.text);
        expect(payload.paragraphs, hasLength(value.text.split('\n').length));
        expect(payload.defaultParagraphStyle.alignment, value.alignment);
        expect(payload.defaultCharacterStyle.weight, value.bold ? 700 : 400);
        expect(payload.defaultCharacterStyle.italic, value.italic);
        expect(payload.intrinsicWidth, lessThanOrEqualTo(value.width));
        expect(payload.intrinsicHeight, isNotNull);
        expect(
          payload.intrinsicWidth < value.width ||
              payload.intrinsicHeight! < value.height,
          isTrue,
        );
        final fittedLayout = _ok(
          runtime.textLayoutEngine.layout(TextLayoutRequest(payload: payload)),
        );
        expect(fittedLayout.overflowed, isFalse);
        final paintedWidth = fittedLayout.lines.fold<double>(
          1,
          (width, line) => math.max(width, line.bounds.width),
        );
        expect(
          payload.intrinsicWidth,
          closeTo(
            math.min(
              value.width,
              payload.padding.left + paintedWidth + payload.padding.right + 1,
            ),
            1e-7,
          ),
        );
        final originalBox = _ok(
          TextPayload.create(
            paragraphs: payload.paragraphs,
            defaultCharacterStyle: payload.defaultCharacterStyle,
            defaultParagraphStyle: payload.defaultParagraphStyle,
            boxMode: payload.boxMode,
            intrinsicWidth: value.width,
            intrinsicHeight: math.max(value.height, payload.intrinsicHeight!),
            padding: payload.padding,
            verticalAlignment: payload.verticalAlignment,
            overflowPolicy: payload.overflowPolicy,
            limits: runtime.textLimits,
            unknownFields: payload.unknownFields,
          ),
        );
        final originalLayout = _ok(
          runtime.textLayoutEngine.layout(
            TextLayoutRequest(payload: originalBox),
          ),
        );
        expect(
          fittedLayout.lines.length,
          originalLayout.lines.length,
          reason: value.text,
        );
        for (var line = 0; line < fittedLayout.lines.length; line += 1) {
          expect(
            fittedLayout.lines[line].fragments
                .map((fragment) => (fragment.range.start, fragment.range.end))
                .toList(growable: false),
            originalLayout.lines[line].fragments
                .map((fragment) => (fragment.range.start, fragment.range.end))
                .toList(growable: false),
          );
        }

        await tester.tap(find.text('selection'));
        await tester.pump();
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final select = await tester.startGesture(
          tester.getTopLeft(canvas) + const Offset(30, 30),
          kind: PointerDeviceKind.mouse,
        );
        await select.moveTo(
          tester.getBottomRight(canvas) - const Offset(30, 30),
        );
        await select.up();
        await tester.pump();
        final frame = _canvasPainter(tester).selectionFrame!;
        expect(
          pointDistance(frame.viewCorners[0], frame.viewCorners[1]),
          closeTo(payload.intrinsicWidth, 1e-8),
        );
        expect(
          pointDistance(frame.viewCorners[0], frame.viewCorners[3]),
          closeTo(payload.intrinsicHeight!, 1e-8),
        );
        await tester.tap(find.byKey(const Key('edit-selected-text')));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const Key('inline-text-editor-overlay'))),
          Size(payload.intrinsicWidth, payload.intrinsicHeight!),
        );
        final historyBeforeUnchanged =
            runtime.initialCoordinator.retainedHistoryCount;
        await _commitInlineText(tester);
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(fittedRoot));
        expect(
          runtime.initialCoordinator.retainedHistoryCount,
          historyBeforeUnchanged,
        );
        await tester.tap(find.text('Undo'));
        await tester.pump();
        expect(_objectCount(runtime), 0);
        await tester.tap(find.text('Redo'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(fittedRoot));
        await tester.tap(find.text('Save in memory'));
        await tester.pump();
        await tester.tap(find.text('Reopen saved'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, fittedRoot);
      }
    },
  );

  testWidgets(
    'center and bottom aligned Text fits once with stable affine anchors',
    (WidgetTester tester) async {
      for (final scenario in [
        (
          horizontal: TextAlignment.center,
          vertical: TextVerticalAlignment.center,
          radians: 0.0,
        ),
        (
          horizontal: TextAlignment.right,
          vertical: TextVerticalAlignment.bottom,
          radians: .57,
        ),
      ]) {
        final generator = _RuntimeCountingUuidGenerator();
        final runtime = _runtime(uuidGenerator: generator);
        final root = runtime.initialCoordinator.snapshot.root;
        final page = root.pages.single;
        final layer = page.layers.whereType<ContentLayer>().single;
        final payload = _widgetAlignedSimpleText(
          runtime.textLimits,
          horizontal: scenario.horizontal,
          vertical: scenario.vertical,
        );
        final transform = _ok(
          AffineTransform2D.restoreFromStorage([
            math.cos(scenario.radians),
            math.sin(scenario.radians),
            -math.sin(scenario.radians),
            math.cos(scenario.radians),
            250,
            90,
          ]),
        );
        final object = testObject(
          id: 9320 + scenario.vertical.index,
          typeKey: textObjectTypeKey,
          schemaVersion: textSchemaVersion,
          payload: payload.encode(),
          transform: transform,
        );
        final seeded = _ok(
          AtomicObjectCollectionEditRequest.create(
            documentId: root.id,
            pageId: page.id,
            metadata: phase3Metadata(
              family: 'alnote.commands.object.collection_edit',
              correlation: 9320 + scenario.vertical.index,
            ),
            preconditions: RevisionPreconditions(
              pages: {
                page.id: runtime
                    .initialCoordinator
                    .snapshot
                    .revisions
                    .pages[page.id]!,
              },
              layerMembership: {
                layer.id: runtime
                    .initialCoordinator
                    .snapshot
                    .revisions
                    .layerMembership[layer.id]!,
              },
            ),
            additions: [
              ObjectCollectionAddition(layerId: layer.id, object: object),
            ],
            maximumOperations: runtime.maximumCommandOperations,
          ),
        );
        expect(
          runtime.initialCoordinator.execute(seeded),
          isA<Ok<CommandCommit, CommandFailure>>(),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(AlNoteApp(runtime: runtime));
        await tester.pump();
        await tester.tap(find.text('Save in memory'));
        await tester.pump();

        final beforeFit = runtime.initialCoordinator.snapshot;
        final beforeLayout = _ok(
          runtime.textLayoutEngine.layout(TextLayoutRequest(payload: payload)),
        );
        final hx = scenario.horizontal == TextAlignment.center ? .5 : 1.0;
        final vy = scenario.vertical == TextVerticalAlignment.center ? .5 : 1.0;
        final beforeLocalAnchor = _ok(
          Point2.create(
            x:
                beforeLayout.visualBounds.left +
                beforeLayout.visualBounds.width * hx,
            y:
                beforeLayout.visualBounds.top +
                beforeLayout.visualBounds.height * vy,
          ),
        );
        final beforePageAnchor = _ok(
          object.transform.applyToPoint(beforeLocalAnchor),
        );
        final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
        final uuidBefore = generator.calls;
        var observerCalls = 0;
        void observer(CommittedChange _) => observerCalls += 1;
        _ok(runtime.initialCoordinator.addListener(observer));

        await tester.tap(find.text('selection'));
        await tester.pump();
        final canvas = find.bySemanticsLabel('Handwriting canvas');
        final select = await tester.startGesture(
          tester.getTopLeft(canvas) + const Offset(30, 30),
          kind: PointerDeviceKind.mouse,
        );
        await select.moveTo(
          tester.getBottomRight(canvas) - const Offset(30, 30),
        );
        await select.up();
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit-selected-text')));
        await tester.pumpAndSettle();
        await _commitInlineText(tester);
        await tester.pump();

        final fittedSnapshot = runtime.initialCoordinator.snapshot;
        final fittedRoot = fittedSnapshot.root;
        final fittedObject = fittedRoot.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects
            .single;
        final fittedPayload = _ok(
          TextPayload.decode(fittedObject.payload, limits: runtime.textLimits),
        );
        final fittedAgain = _ok(
          TextObjectTypeDefinition(
            runtime.textLimits,
            runtime.textLayoutEngine,
          ).fitVisibleContent(fittedPayload),
        );
        expect(fittedPayload.intrinsicWidth, lessThan(payload.intrinsicWidth));
        expect(
          fittedPayload.intrinsicHeight,
          lessThan(payload.intrinsicHeight!),
        );
        expect(fittedAgain.encode(), fittedPayload.encode());
        final fittedLayout = _ok(
          runtime.textLayoutEngine.layout(
            TextLayoutRequest(payload: fittedPayload),
          ),
        );
        expect(fittedLayout.overflowed, isFalse);
        final afterLocalAnchor = _ok(
          Point2.create(
            x:
                fittedLayout.visualBounds.left +
                fittedLayout.visualBounds.width * hx,
            y:
                fittedLayout.visualBounds.top +
                fittedLayout.visualBounds.height * vy,
          ),
        );
        final afterPageAnchor = _ok(
          fittedObject.transform.applyToPoint(afterLocalAnchor),
        );
        expect(afterPageAnchor.x, closeTo(beforePageAnchor.x, 1e-8));
        expect(afterPageAnchor.y, closeTo(beforePageAnchor.y, 1e-8));
        expect(
          runtime.initialCoordinator.retainedHistoryCount,
          historyBefore + 1,
        );
        expect(generator.calls, uuidBefore + 2);
        expect(observerCalls, 1);

        await tester.tap(find.text('selection'));
        await tester.pump();
        final fittedLocalCenter = _ok(
          Point2.create(
            x:
                fittedLayout.visualBounds.left +
                fittedLayout.visualBounds.width / 2,
            y:
                fittedLayout.visualBounds.top +
                fittedLayout.visualBounds.height / 2,
          ),
        );
        final fittedPageCenter = _ok(
          fittedObject.transform.applyToPoint(fittedLocalCenter),
        );
        final pageClip = _canvasPainter(tester).pageClip!;
        final fittedHit =
            tester.getTopLeft(find.byKey(const Key('phase6-canvas-listener'))) +
            Offset(
              pageClip.left + fittedPageCenter.x,
              pageClip.top + fittedPageCenter.y,
            );
        expect(
          tester.getRect(canvas).contains(fittedHit),
          isTrue,
          reason: '$scenario $fittedHit ${tester.getRect(canvas)}',
        );
        final reselect = await tester.startGesture(
          fittedHit,
          kind: PointerDeviceKind.mouse,
        );
        await reselect.up();
        await tester.pump();
        expect(
          _canvasPainter(tester).selectionFrame,
          isNotNull,
          reason: '$scenario $fittedHit',
        );
        await tester.tap(find.byKey(const Key('edit-selected-text')));
        await tester.pumpAndSettle();
        final stableBefore = runtime.initialCoordinator.snapshot;
        final stableHistory = runtime.initialCoordinator.retainedHistoryCount;
        final stableUuid = generator.calls;
        await _commitInlineText(tester);
        await tester.pump();
        expect(
          runtime.initialCoordinator.snapshot.root,
          same(stableBefore.root),
        );
        expect(
          runtime.initialCoordinator.snapshot.revisions,
          stableBefore.revisions,
        );
        expect(
          runtime.initialCoordinator.snapshot.isDirty,
          stableBefore.isDirty,
        );
        expect(runtime.initialCoordinator.retainedHistoryCount, stableHistory);
        expect(generator.calls, stableUuid);
        expect(observerCalls, 1);

        await tester.tap(find.text('Undo'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(beforeFit.root));
        await tester.tap(find.text('Redo'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, same(fittedRoot));
        await tester.tap(find.text('Save in memory'));
        await tester.pump();
        await tester.tap(find.text('Reopen saved'));
        await tester.pump();
        expect(runtime.initialCoordinator.snapshot.root, fittedRoot);
        final reopenedPayload = _ok(
          TextPayload.decode(
            runtime.initialCoordinator.snapshot.root.pages.single.layers
                .whereType<ContentLayer>()
                .single
                .objects
                .single
                .payload,
            limits: runtime.textLimits,
          ),
        );
        expect(reopenedPayload.encode(), fittedPayload.encode());
        runtime.initialCoordinator.removeListener(observer);
      }
    },
  );

  testWidgets('inline Text follows zoom and Escape cancels IME draft', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('text'));
    await tester.pump();
    expect(find.byKey(const Key('text-font-size-control')), findsOneWidget);
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final create = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await create.up();
    await tester.pump();
    final editor = find.byKey(const Key('inline-text-editor-overlay'));
    expect(editor, findsOneWidget);
    final before = tester.getRect(editor);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'composing',
        selection: TextSelection.collapsed(offset: 9),
        composing: ui.TextRange(start: 0, end: 9),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Zoom In'));
    await tester.pump();
    expect(find.byKey(const Key('inline-text-editor-overlay')), findsOneWidget);
    expect(tester.getRect(editor), isNot(before));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('inline-text-editor-overlay')), findsNothing);
    expect(
      runtime.initialCoordinator.snapshot.root.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects,
      isEmpty,
    );
  });

  testWidgets(
    'active inline Text resizes from every border without publishing',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('text'));
      await tester.pump();
      final center = tester.getCenter(
        find.bySemanticsLabel('Handwriting canvas'),
      );
      final cases = <({Alignment alignment, Offset delta})>[
        (alignment: Alignment.topLeft, delta: const Offset(-12, -10)),
        (alignment: Alignment.topCenter, delta: const Offset(0, -10)),
        (alignment: Alignment.topRight, delta: const Offset(12, -10)),
        (alignment: Alignment.centerRight, delta: const Offset(12, 0)),
        (alignment: Alignment.bottomRight, delta: const Offset(12, 10)),
        (alignment: Alignment.bottomCenter, delta: const Offset(0, 10)),
        (alignment: Alignment.bottomLeft, delta: const Offset(-12, 10)),
        (alignment: Alignment.centerLeft, delta: const Offset(-12, 0)),
      ];
      for (final value in cases) {
        final create = await tester.startGesture(
          center - const Offset(60, 40),
          kind: PointerDeviceKind.mouse,
        );
        await create.moveBy(const Offset(120, 80));
        await create.up();
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('text-object-editor')),
          'alpha beta gamma delta epsilon',
        );
        final before = tester.getRect(
          find.byKey(const Key('inline-text-editor-overlay')),
        );
        final resize = await tester.startGesture(
          value.alignment.withinRect(before),
          kind: PointerDeviceKind.mouse,
        );
        await resize.moveBy(value.delta);
        await tester.pump();
        final after = tester.getRect(
          find.byKey(const Key('inline-text-editor-overlay')),
        );
        expect(_objectCount(runtime), 0);
        expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('text-object-editor')))
              .controller!
              .text,
          'alpha beta gamma delta epsilon',
        );
        if (value.alignment.x < 0) {
          expect(after.right, closeTo(before.right, .01));
        } else {
          expect(after.left, closeTo(before.left, .01));
        }
        if (value.alignment.y < 0) {
          expect(after.bottom, closeTo(before.bottom, .01));
        } else {
          expect(after.top, closeTo(before.top, .01));
        }
        await resize.up();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(_objectCount(runtime), 0);
      }
    },
  );

  testWidgets(
    'existing inline Text exclusively expands beyond every former edge',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      await tester.tap(find.text('text'));
      await tester.pump();
      final create = await tester.startGesture(
        center - const Offset(90, 45),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(180, 90));
      await create.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'original fitted text',
      );
      await _commitInlineText(tester);
      await tester.pump();
      final committedBeforeEdit = runtime.initialCoordinator.snapshot.root;
      await tester.tap(find.text('selection'));
      await tester.pump();
      final object = committedBeforeEdit.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects
          .single;
      final select = await tester.startGesture(
        _textObjectCenterGlobal(tester, runtime, object),
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      final formerFrame = _canvasPainter(tester).selectionFrame!;
      final formerLeft = formerFrame.viewCorners
          .map((value) => value.x)
          .reduce(math.min);
      final formerRight = formerFrame.viewCorners
          .map((value) => value.x)
          .reduce(math.max);
      final formerTop = formerFrame.viewCorners
          .map((value) => value.y)
          .reduce(math.min);
      final formerBottom = formerFrame.viewCorners
          .map((value) => value.y)
          .reduce(math.max);
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      expect(_canvasPainter(tester).selectionPrimitiveCount, 0);
      expect(_canvasPainter(tester).selectionFrame, isNull);
      expect(find.text('Left'), findsNothing);
      final listenerOrigin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );

      final cases = <({Alignment alignment, Offset delta})>[
        (alignment: Alignment.topLeft, delta: const Offset(-25, -25)),
        (alignment: Alignment.topCenter, delta: const Offset(0, -25)),
        (alignment: Alignment.topRight, delta: const Offset(25, -25)),
        (alignment: Alignment.centerRight, delta: const Offset(25, 0)),
        (alignment: Alignment.bottomRight, delta: const Offset(25, 25)),
        (alignment: Alignment.bottomCenter, delta: const Offset(0, 25)),
        (alignment: Alignment.bottomLeft, delta: const Offset(-25, 25)),
        (alignment: Alignment.centerLeft, delta: const Offset(-25, 0)),
      ];
      for (final value in cases) {
        final before = tester.getRect(
          find.byKey(const Key('inline-text-editor-overlay')),
        );
        final resize = await tester.startGesture(
          value.alignment.withinRect(before),
          kind: PointerDeviceKind.mouse,
        );
        await resize.moveBy(value.delta);
        await tester.pump();
        expect(_canvasPainter(tester).selectionPrimitiveCount, 0);
        expect(_canvasPainter(tester).selectionFrame, isNull);
        final after = tester.getRect(
          find.byKey(const Key('inline-text-editor-overlay')),
        );
        if (value.alignment.x < 0) {
          expect(after.left - listenerOrigin.dx, lessThan(formerLeft));
        } else if (value.alignment.x > 0) {
          expect(after.right - listenerOrigin.dx, greaterThan(formerRight));
        }
        if (value.alignment.y < 0) {
          expect(after.top - listenerOrigin.dy, lessThan(formerTop));
        } else if (value.alignment.y > 0) {
          expect(after.bottom - listenerOrigin.dy, greaterThan(formerBottom));
        }
        await resize.up();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(
          runtime.initialCoordinator.snapshot.root,
          same(committedBeforeEdit),
        );
        await tester.tap(find.byKey(const Key('edit-selected-text')));
        await tester.pump();
      }

      final captureStart = tester.getRect(
        find.byKey(const Key('inline-text-editor-overlay')),
      );
      final captured = await tester.startGesture(
        Alignment.centerRight.withinRect(captureStart),
        kind: PointerDeviceKind.mouse,
      );
      await captured.moveBy(Offset(-captureStart.width - 100, 0));
      await tester.pump();
      expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
      expect(_canvasPainter(tester).selectionFrame, isNull);
      await captured.moveTo(
        Offset(captureStart.right + 120, captureStart.center.dy),
      );
      await tester.pump();
      expect(
        tester
            .getRect(find.byKey(const Key('inline-text-editor-overlay')))
            .right,
        closeTo(captureStart.right + 120, 1),
      );
      await captured.up();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'original fitted text expanded with substantially more content',
      );
      final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byKey(const Key('text-object-editor')), findsNothing);
      expect(
        runtime.initialCoordinator.retainedHistoryCount,
        historyBefore + 1,
      );
      final committedAfterControl = runtime.initialCoordinator.snapshot.root;
      final updated = committedAfterControl.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects
          .single;
      final updatedPayload = _ok(
        TextPayload.decode(updated.payload, limits: runtime.textLimits),
      );
      await tester.tap(find.text('selection'));
      await tester.pump();
      final reselect = await tester.startGesture(
        _textObjectCenterGlobal(tester, runtime, updated),
        kind: PointerDeviceKind.mouse,
      );
      await reselect.up();
      await tester.pump();
      final committedFrame = _canvasPainter(tester).selectionFrame!;
      expect(
        committedFrame.viewCorners[1].x - committedFrame.viewCorners[0].x,
        closeTo(updatedPayload.intrinsicWidth, 1e-7),
      );
      expect(
        committedFrame.viewCorners[3].y - committedFrame.viewCorners[0].y,
        closeTo(updatedPayload.intrinsicHeight!, 1e-7),
      );

      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      final clickEditor = tester.getRect(
        find.byKey(const Key('inline-text-editor-overlay')),
      );
      final clickResize = await tester.startGesture(
        Alignment.centerRight.withinRect(clickEditor),
        kind: PointerDeviceKind.mouse,
      );
      await clickResize.moveBy(const Offset(45, 0));
      await clickResize.up();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        '${updatedPayload.logicalText} click away',
      );
      final clickAway = await tester.startGesture(
        listenerOrigin + const Offset(4, 4),
        kind: PointerDeviceKind.mouse,
      );
      await clickAway.up();
      await tester.pump();
      expect(find.byKey(const Key('text-object-editor')), findsNothing);
      final committedAfterClick = runtime.initialCoordinator.snapshot.root;
      expect(committedAfterClick, isNot(same(committedAfterControl)));

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, committedAfterControl);
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, committedAfterClick);
      await tester.tap(find.text('Save in memory'));
      await tester.pump();
      await tester.tap(find.text('Reopen saved'));
      await tester.pumpAndSettle();
      expect(runtime.initialCoordinator.snapshot.root, committedAfterClick);

      await tester.tap(find.text('selection'));
      await tester.pump();
      final reopenedCanvas = find.bySemanticsLabel('Handwriting canvas');
      final finalSelect = await tester.startGesture(
        tester.getTopLeft(reopenedCanvas) + const Offset(20, 20),
        kind: PointerDeviceKind.mouse,
      );
      await finalSelect.moveTo(
        tester.getBottomRight(reopenedCanvas) - const Offset(20, 20),
      );
      await finalSelect.up();
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      final rootBeforeCancel = runtime.initialCoordinator.snapshot.root;
      final cancelEditor = tester.getRect(
        find.byKey(const Key('inline-text-editor-overlay')),
      );
      final cancelResize = await tester.startGesture(
        Alignment.bottomRight.withinRect(cancelEditor),
        kind: PointerDeviceKind.mouse,
      );
      await cancelResize.moveBy(const Offset(80, 60));
      await cancelResize.up();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(rootBeforeCancel));
      expect(find.byKey(const Key('text-object-editor')), findsNothing);
    },
  );

  testWidgets(
    'editable fields retain tool letters and Text drag previews exact bounds',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('text'));
      await tester.pump();
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final start = center - const Offset(80, 40);
      final end = center + const Offset(80, 40);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(end);
      await tester.pump();
      expect(_objectCount(runtime), 0);
      expect(_canvasPainter(tester).previewPrimitiveCount, greaterThan(0));
      expect(find.byKey(const Key('inline-text-editor-overlay')), findsNothing);
      await gesture.up();
      await tester.pump();
      final editor = find.byKey(const Key('inline-text-editor-overlay'));
      expect(tester.getRect(editor), Rect.fromPoints(start, end));

      const letters = 'pPeEvVrRtT';
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        letters,
      );
      for (final key in const [
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyT,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        letters,
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '$letters\u3042',
          selection: TextSelection.collapsed(offset: letters.length + 1),
          composing: ui.TextRange(
            start: letters.length,
            end: letters.length + 1,
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        '$letters\u3042',
      );
      await _commitInlineText(tester);
      await tester.pump();
      expect(_objectCount(runtime), 1);

      await tester.tap(find.text('selection'));
      await tester.pump();
      final existingSelect = await tester.startGesture(
        tester.getCenter(canvas),
        kind: PointerDeviceKind.mouse,
      );
      await existingSelect.up();
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        letters,
      );
      for (final key in const [
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyT,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        letters,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_objectCount(runtime), 1);

      await tester.tap(find.byKey(const Key('zoom-input')));
      await tester.enterText(find.byKey(const Key('zoom-input')), letters);
      await tester.pump();
      for (final key in const [
        LogicalKeyboardKey.keyP,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.keyT,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('zoom-input')))
            .controller!
            .text,
        letters,
      );
      expect(_objectCount(runtime), 1);
    },
  );

  testWidgets(
    'Selection Text resize preserves payload and commits whole-Object scale',
    (WidgetTester tester) async {
      final runtime = _runtime();
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      await tester.tap(find.text('text'));
      await tester.pump();
      final create = await tester.startGesture(
        center - const Offset(70, 35),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(140, 70));
      await create.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'one two three',
      );
      await _commitInlineText(tester);
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot.root;
      CommittedChange? resizeChange;
      _ok(
        runtime.initialCoordinator.addListener((change) {
          resizeChange = change;
        }),
      );
      final source = before.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects
          .single;
      final beforePayload = _ok(
        TextPayload.decode(source.payload, limits: runtime.textLimits),
      );
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      expect(_canvasPainter(tester).selectionPrimitiveCount, 3);
      final frame = _canvasPainter(tester).selectionFrame!;
      expect(frame.isSingleText, isTrue);
      final clip = _canvasPainter(tester).pageClip!;
      final coefficients = source.transform.storageCoefficients;
      final listenerOrigin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );
      const hoverDevice = 801;
      await _addTestMouse(
        tester,
        listenerOrigin + const Offset(2, 2),
        hoverDevice,
      );
      final left = frame.viewCorners[0].x;
      final top = frame.viewCorners[0].y;
      final right = frame.viewCorners[1].x;
      final bottom = frame.viewCorners[2].y;
      expect(left, closeTo(clip.left + coefficients[4], 1e-8));
      expect(top, closeTo(clip.top + coefficients[5], 1e-8));
      expect(
        right,
        closeTo(
          clip.left + coefficients[4] + beforePayload.intrinsicWidth,
          1e-8,
        ),
      );
      expect(
        bottom,
        lessThanOrEqualTo(
          clip.top + coefficients[5] + beforePayload.intrinsicHeight!,
        ),
      );
      final rightHandle =
          listenerOrigin +
          Offset(right, (frame.viewCorners[1].y + frame.viewCorners[2].y) / 2);
      for (final value in <({Offset point, MouseCursor cursor})>[
        (
          point: Offset(left, top),
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
        ),
        (
          point: Offset((left + right) / 2, top),
          cursor: SystemMouseCursors.resizeUpDown,
        ),
        (
          point: Offset(right, top),
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
        ),
        (
          point: Offset(right, (top + bottom) / 2),
          cursor: SystemMouseCursors.resizeLeftRight,
        ),
        (
          point: Offset(right, bottom),
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
        ),
        (
          point: Offset((left + right) / 2, bottom),
          cursor: SystemMouseCursors.resizeUpDown,
        ),
        (
          point: Offset(left, bottom),
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
        ),
        (
          point: Offset(left, (top + bottom) / 2),
          cursor: SystemMouseCursors.resizeLeftRight,
        ),
      ]) {
        await _moveTestMouse(tester, listenerOrigin + value.point, hoverDevice);
        await tester.pump();
        expect(
          tester
              .widget<MouseRegion>(
                find.byKey(const Key('phase6-canvas-mouse-region')),
              )
              .cursor,
          value.cursor,
        );
      }
      await _moveTestMouse(
        tester,
        listenerOrigin + const Offset(2, 2),
        hoverDevice,
      );
      await tester.pump();
      expect(
        tester
            .widget<MouseRegion>(
              find.byKey(const Key('phase6-canvas-mouse-region')),
            )
            .cursor,
        SystemMouseCursors.basic,
      );
      await _removeTestMouse(tester, hoverDevice);
      final resize = await tester.startGesture(
        rightHandle,
        kind: PointerDeviceKind.mouse,
      );
      await resize.moveBy(const Offset(80, 0));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        'Resizing selection',
      );
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      final previewPixels = await _canvasBytes(tester);
      await resize.up();
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        'Selection transformed',
      );
      expect(await _canvasBytes(tester), previewPixels);
      final after = runtime.initialCoordinator.snapshot.root;
      final resized = after.pages.single.layers
          .whereType<ContentLayer>()
          .single
          .objects
          .single;
      final afterPayload = _ok(
        TextPayload.decode(resized.payload, limits: runtime.textLimits),
      );
      expect(resized.id, source.id);
      expect(resized.payload, source.payload);
      expect(afterPayload.encode(), beforePayload.encode());
      expect(resized.transform, isNot(source.transform));
      expect(resizeChange, isNotNull);
      expect(resizeChange!.family, CommandFamily.wholeObjectTransform);
      expect(resizeChange!.replacedObjectIds, {source.id});
      expect(resizeChange!.flags.geometry, isTrue);
      expect(resizeChange!.flags.text, isFalse);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, before);
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, after);

      final historyBeforeCancel =
          runtime.initialCoordinator.retainedHistoryCount;
      final canUndoBeforeCancel = runtime.initialCoordinator.snapshot.canUndo;
      final canRedoBeforeCancel = runtime.initialCoordinator.snapshot.canRedo;
      final currentFrame = _canvasPainter(tester).selectionFrame!;
      final currentTopRight = currentFrame.viewCorners[1];
      final currentBottomRight = currentFrame.viewCorners[2];
      final cancelHandle =
          listenerOrigin +
          Offset(
            (currentTopRight.x + currentBottomRight.x) / 2,
            (currentTopRight.y + currentBottomRight.y) / 2,
          );
      final cancelled = await tester.startGesture(
        cancelHandle,
        kind: PointerDeviceKind.mouse,
      );
      await cancelled.moveBy(const Offset(30, 0));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await cancelled.up();
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, after);
      expect(
        runtime.initialCoordinator.retainedHistoryCount,
        historyBeforeCancel,
      );
      expect(runtime.initialCoordinator.snapshot.canUndo, canUndoBeforeCancel);
      expect(runtime.initialCoordinator.snapshot.canRedo, canRedoBeforeCancel);
    },
  );

  testWidgets('Text Selection scales payload intact; editor alone reflows', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    await tester.tap(find.text('text'));
    await tester.pump();
    final create = await tester.startGesture(
      center - const Offset(80, 50),
      kind: PointerDeviceKind.mouse,
    );
    await create.moveBy(const Offset(160, 100));
    await create.up();
    await tester.pump();
    const content = 'alpha beta gamma delta epsilon zeta eta theta';
    await tester.enterText(
      find.byKey(const Key('text-object-editor')),
      content,
    );
    await _commitInlineText(tester);
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final select = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();

    ObjectEnvelope currentObject() => runtime
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
    TextPayload currentPayload() => _ok(
      TextPayload.decode(currentObject().payload, limits: runtime.textLimits),
    );
    Offset pageToGlobal(Point2 page) {
      final clip = _canvasPainter(tester).pageClip!;
      final origin = tester.getTopLeft(
        find.byKey(const Key('phase6-canvas-listener')),
      );
      return origin + Offset(clip.left + page.x, clip.top + page.y);
    }

    Offset handle(ObjectEnvelope object, Point2 local) =>
        pageToGlobal(_ok(object.transform.applyToPoint(local)));
    Offset selectionPoint(int index) {
      final point = _canvasPainter(tester).selectionFrame!.viewCorners[index];
      return tester.getTopLeft(
            find.byKey(const Key('phase6-canvas-listener')),
          ) +
          Offset(point.x, point.y);
    }

    Offset selectionEdge(int first, int second) =>
        (selectionPoint(first) + selectionPoint(second)) / 2;
    Point2 point(double x, double y) => _ok(Point2.create(x: x, y: y));

    var object = currentObject();
    var payload = currentPayload();
    final originalPayloadBytes = payload.encode();
    final beforeTopResize = runtime.initialCoordinator.snapshot.root;
    final fixedBottom = selectionEdge(2, 3);
    final top = await tester.startGesture(
      selectionEdge(0, 1),
      kind: PointerDeviceKind.mouse,
    );
    final topDelta = _ok(
      object.transform.applyToVector(_ok(Vector2.create(x: 0, y: 10))),
    );
    await top.moveBy(Offset(topDelta.x, topDelta.y));
    await top.up();
    await tester.pump();
    object = currentObject();
    payload = currentPayload();
    final retainedBottom = selectionEdge(2, 3);
    expect(payload.encode(), originalPayloadBytes);
    expect(retainedBottom.dx, closeTo(fixedBottom.dx, 1e-8));
    expect(retainedBottom.dy, closeTo(fixedBottom.dy, 1e-8));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, beforeTopResize);

    object = currentObject();
    payload = currentPayload();
    final bottom = await tester.startGesture(
      selectionEdge(2, 3),
      kind: PointerDeviceKind.mouse,
    );
    await bottom.moveBy(const Offset(0, 20));
    await bottom.up();
    await tester.pump();
    expect(currentPayload().encode(), originalPayloadBytes);
    expect(currentPayload().logicalText, content);

    object = currentObject();
    payload = currentPayload();
    final corner = await tester.startGesture(
      selectionPoint(2),
      kind: PointerDeviceKind.mouse,
    );
    await corner.moveBy(const Offset(30, 15));
    await corner.up();
    await tester.pump();
    expect(currentPayload().encode(), originalPayloadBytes);

    await tester.tap(find.text('Rotate'));
    await tester.pump();
    final rotated = currentObject();
    final coefficients = rotated.transform.storageCoefficients;
    final rotatedRightHandle = selectionEdge(1, 2);
    const rotatedHoverDevice = 802;
    await _addTestMouse(tester, center, rotatedHoverDevice);
    await _moveTestMouse(tester, rotatedRightHandle, rotatedHoverDevice);
    await tester.pump();
    expect(
      tester
          .widget<MouseRegion>(
            find.byKey(const Key('phase6-canvas-mouse-region')),
          )
          .cursor,
      SystemMouseCursors.resizeLeftRight,
    );
    await _removeTestMouse(tester, rotatedHoverDevice);
    final right = await tester.startGesture(
      rotatedRightHandle,
      kind: PointerDeviceKind.mouse,
    );
    final localDelta = _ok(
      rotated.transform.applyToVector(_ok(Vector2.create(x: 25, y: 0))),
    );
    await right.moveBy(Offset(localDelta.x, localDelta.y));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Resizing selection',
    );
    await right.up();
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Selection transformed',
    );
    object = currentObject();
    payload = currentPayload();
    expect(payload.encode(), originalPayloadBytes);
    expect(payload.logicalText, content);
    expect(
      object.transform.storageCoefficients.take(4),
      isNot(coefficients.take(4)),
    );
    expect(object.id, rotated.id);

    final rotationFrame = _canvasPainter(tester).selectionFrame!;
    expect(rotationFrame.isSingleText, isTrue);
    expect(
      math.sqrt(
        math.pow(
              rotationFrame.rotationCenter.x -
                  rotationFrame.rotationConnectorStart.x,
              2,
            ) +
            math.pow(
              rotationFrame.rotationCenter.y -
                  rotationFrame.rotationConnectorStart.y,
              2,
            ),
      ),
      closeTo(28, 1e-8),
    );
    final rootBeforeRotationPreview = runtime.initialCoordinator.snapshot.root;
    final listenerOrigin = tester.getTopLeft(
      find.byKey(const Key('phase6-canvas-listener')),
    );
    final rotateText = await tester.startGesture(
      listenerOrigin +
          Offset(
            rotationFrame.rotationCenter.x,
            rotationFrame.rotationCenter.y,
          ),
      kind: PointerDeviceKind.mouse,
    );
    await rotateText.moveBy(const Offset(20, 8));
    await tester.pump();
    expect(find.text('Rotating selection'), findsOneWidget);
    expect(
      runtime.initialCoordinator.snapshot.root,
      same(rootBeforeRotationPreview),
    );
    expect(_canvasPainter(tester).previewPrimitiveCount, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await rotateText.cancel();
    expect(
      runtime.initialCoordinator.snapshot.root,
      same(rootBeforeRotationPreview),
    );

    final fixedRight = selectionEdge(1, 2);
    final left = await tester.startGesture(
      selectionEdge(0, 3),
      kind: PointerDeviceKind.mouse,
    );
    final inward = _ok(
      object.transform.applyToVector(_ok(Vector2.create(x: 15, y: 0))),
    );
    await left.moveBy(Offset(inward.x, inward.y));
    await left.up();
    await tester.pump();
    object = currentObject();
    payload = currentPayload();
    final retainedRight = selectionEdge(1, 2);
    expect(payload.encode(), originalPayloadBytes);
    expect(retainedRight.dx, closeTo(fixedRight.dx, 1e-8));
    expect(retainedRight.dy, closeTo(fixedRight.dy, 1e-8));
    final selectionTransformCoefficients = object.transform.storageCoefficients;

    await tester.tap(find.byKey(const Key('edit-selected-text')));
    await tester.pump();
    expect(_canvasPainter(tester).selectionPrimitiveCount, 0);
    expect(_canvasPainter(tester).selectionFrame, isNull);
    expect(find.text('Left'), findsNothing);
    final editorTransform = tester
        .widget<Transform>(
          find.byKey(const Key('inline-text-editor-transform')),
        )
        .transform
        .storage;
    expect(
      editorTransform[0],
      closeTo(selectionTransformCoefficients[0], 1e-9),
    );
    expect(
      editorTransform[4],
      closeTo(selectionTransformCoefficients[1], 1e-9),
    );
    expect(
      editorTransform[1],
      closeTo(selectionTransformCoefficients[2], 1e-9),
    );
    expect(
      editorTransform[5],
      closeTo(selectionTransformCoefficients[3], 1e-9),
    );
    final beforeInlineCompletion = runtime.initialCoordinator.snapshot.root;
    final historyBeforeInlineCompletion =
        runtime.initialCoordinator.retainedHistoryCount;
    final widthBeforeInlineExpansion = payload.intrinsicWidth;
    await tester.enterText(
      find.byKey(const Key('text-object-editor')),
      '$content edited',
    );
    final fixedEditorBottomRight = _ok(
      object.transform.applyToPoint(
        point(payload.intrinsicWidth, payload.intrinsicHeight!),
      ),
    );
    final editorTopLeft = await tester.startGesture(
      handle(object, point(0, 0)),
      kind: PointerDeviceKind.mouse,
    );
    final editorDelta = _ok(
      object.transform.applyToVector(_ok(Vector2.create(x: -60, y: -60))),
    );
    await editorTopLeft.moveBy(Offset(editorDelta.x, editorDelta.y));
    await tester.pump();
    expect(
      runtime.initialCoordinator.snapshot.root,
      same(beforeInlineCompletion),
    );
    expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
    await editorTopLeft.up();
    await _commitInlineText(tester);
    object = currentObject();
    payload = currentPayload();
    expect(payload.logicalText, '$content edited');
    expect(payload.intrinsicWidth, greaterThan(widthBeforeInlineExpansion));
    expect(payload.intrinsicHeight, greaterThan(90));
    expect(
      object.transform.storageCoefficients.take(4),
      selectionTransformCoefficients.take(4),
    );
    final retainedEditorBottomRight = _ok(
      object.transform.applyToPoint(
        point(payload.intrinsicWidth, payload.intrinsicHeight!),
      ),
    );
    expect(
      retainedEditorBottomRight.x,
      closeTo(fixedEditorBottomRight.x, 1e-8),
    );
    expect(
      retainedEditorBottomRight.y,
      closeTo(fixedEditorBottomRight.y, 1e-8),
    );
    expect(
      runtime.initialCoordinator.retainedHistoryCount,
      historyBeforeInlineCompletion + 1,
    );
    final afterInlineCompletion = runtime.initialCoordinator.snapshot.root;
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, beforeInlineCompletion);
    await tester.tap(find.text('Redo'));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, afterInlineCompletion);

    final resizedRoot = runtime.initialCoordinator.snapshot.root;
    await tester.tap(find.text('Save in memory'));
    await tester.pump();
    await tester.tap(find.text('Reopen saved'));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, resizedRoot);
  });

  testWidgets('long Text move coalesces frames and reuses one local layout', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    await tester.tap(find.text('text'));
    await tester.pump();
    final create = await tester.startGesture(
      center - const Offset(70, 35),
      kind: PointerDeviceKind.mouse,
    );
    await create.moveBy(const Offset(140, 70));
    await create.up();
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('text-object-editor')),
      'cached layout movement',
    );
    await _commitInlineText(tester);
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final before = runtime.initialCoordinator.snapshot.root.pages.single.layers
        .whereType<ContentLayer>()
        .single
        .objects
        .single;
    final payload = _ok(
      TextPayload.decode(before.payload, limits: runtime.textLimits),
    );
    final pageCenter = _ok(
      before.transform.applyToPoint(
        _ok(
          Point2.create(
            x: payload.intrinsicWidth / 2,
            y: payload.intrinsicHeight! / 2,
          ),
        ),
      ),
    );
    final clip = _canvasPainter(tester).pageClip!;
    final objectCenter =
        tester.getTopLeft(find.byKey(const Key('phase6-canvas-listener'))) +
        Offset(clip.left + pageCenter.x, clip.top + pageCenter.y);
    final select = await tester.startGesture(
      objectCenter,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    final move = await tester.startGesture(
      objectCenter + const Offset(20, 10),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 120; index += 1) {
      await move.moveBy(const Offset(1, 0));
      if (index % 20 == 0) await tester.pump();
    }
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Moving selection',
    );
    await move.up();
    await tester.pump();
    final after = runtime.initialCoordinator.snapshot.root.pages.single.layers
        .whereType<ContentLayer>()
        .single
        .objects
        .single;
    expect(
      after.transform.storageCoefficients[4],
      closeTo(before.transform.storageCoefficients[4] + 120, .01),
    );
    final event = runtime.diagnosticTrace.events.lastWhere(
      (value) => value.stage == Phase6DiagnosticStage.selectionTransformPreview,
    );
    expect(event.transformRequests, 120);
    expect(event.layoutRequests, 1);
    expect(event.rendererPreparations, 1);
    expect(event.selectedContentPictureCreations, 1);
    expect(event.perTargetPrimitiveRebuilds, 0);
    expect(event.cacheHits, 0);
    expect(event.repaints, lessThanOrEqualTo(6));
    expect(event.terminalDisposition, 1);
  });

  testWidgets('failed editor preparation preserves Object and Selection', (
    WidgetTester tester,
  ) async {
    final generator = _RuntimeCountingUuidGenerator();
    final runtime = _runtime(uuidGenerator: generator);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    await tester.tap(find.text('text'));
    await tester.pump();
    final create = await tester.startGesture(
      center - const Offset(60, 30),
      kind: PointerDeviceKind.mouse,
    );
    await create.moveBy(const Offset(120, 60));
    await create.up();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('text-object-editor')), 'base');
    await _commitInlineText(tester);
    await tester.pump();
    final failure = _FailingTextLayoutEngine(throws: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Phase6Canvas(runtime: runtime, textLayoutEngineOverride: failure),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('selection'));
    await tester.pump();
    final object = runtime.initialCoordinator.snapshot.root.pages.single.layers
        .whereType<ContentLayer>()
        .single
        .objects
        .single;
    final payload = _ok(
      TextPayload.decode(object.payload, limits: runtime.textLimits),
    );
    final clip = _canvasPainter(tester).pageClip!;
    final origin = tester.getTopLeft(
      find.byKey(const Key('phase6-canvas-listener')),
    );
    Offset globalFor(Point2 local) {
      final page = _ok(object.transform.applyToPoint(local));
      return origin + Offset(clip.left + page.x, clip.top + page.y);
    }

    final select = await tester.startGesture(
      globalFor(
        _ok(
          Point2.create(
            x: payload.intrinsicWidth / 2,
            y: payload.intrinsicHeight! / 2,
          ),
        ),
      ),
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    final selectionBefore = _canvasPainter(tester).selectionFrame!;
    final before = runtime.initialCoordinator.snapshot;
    final history = runtime.initialCoordinator.retainedHistoryCount;
    final uuidCalls = generator.calls;
    expect(_canvasPainter(tester).selectionPrimitiveCount, 3);
    await tester.tap(find.byKey(const Key('edit-selected-text')));
    await tester.pump();
    expect(failure.calls, greaterThan(0));
    expect(find.byKey(const Key('text-object-editor')), findsNothing);
    expect(runtime.initialCoordinator.snapshot.root, same(before.root));
    expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
    expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
    expect(runtime.initialCoordinator.snapshot.canRedo, before.canRedo);
    expect(runtime.initialCoordinator.retainedHistoryCount, history);
    expect(generator.calls, uuidCalls);
    expect(_canvasPainter(tester).selectionPrimitiveCount, 3);
    expect(
      _canvasPainter(tester).selectionFrame!.viewCorners,
      selectionBefore.viewCorners,
    );
    expect(find.byKey(const Key('edit-selected-text')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      isNot(contains('SECRET')),
    );
  });

  testWidgets('Selection preview renderer failures cancel atomically', (
    WidgetTester tester,
  ) async {
    for (final mode in _PreviewFailureMode.values.where(
      (value) => value != _PreviewFailureMode.partial,
    )) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final generator = _RuntimeCountingUuidGenerator();
      final runtime = _runtime(
        uuidGenerator: generator,
        maximumPreviewOverlays: mode == _PreviewFailureMode.overLimit
            ? 2
            : 20000,
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();
      await tester.tap(find.text('Fill'));
      await tester.pump();
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final create = await tester.startGesture(
        center - const Offset(40, 30),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(80, 60));
      await create.up();
      await tester.pump();
      final baseRenderer =
          runtime.renderingRegistry.definitions[shapeObjectTypeKey]!;
      final definitions = runtime.renderingRegistry.definitions.values
          .where((value) => value.typeKey != shapeObjectTypeKey)
          .toList();
      if (mode != _PreviewFailureMode.missing) {
        definitions.add(_AdversarialPreviewRenderer(baseRenderer, mode));
      }
      final override = _ok(
        RenderingRegistry.create(definitions, maximumDefinitions: 16),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Phase6Canvas(
            runtime: runtime,
            renderingRegistryOverride: override,
          ),
        ),
      );
      await tester.tap(find.text('selection'));
      await tester.pump();
      final selectedCanvas = find.bySemanticsLabel('Handwriting canvas');
      final selectedCenter = tester.getCenter(selectedCanvas);
      final select = await tester.startGesture(
        selectedCenter,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot;
      final calls = generator.calls;
      final history = runtime.initialCoordinator.retainedHistoryCount;
      var observerCalls = 0;
      void observer(CommittedChange _) => observerCalls += 1;
      _ok(runtime.initialCoordinator.addListener(observer));
      final visibleBefore = await _canvasBytes(tester);
      final move = await tester.startGesture(
        selectedCenter,
        kind: PointerDeviceKind.mouse,
      );
      await move.moveBy(const Offset(35, 20));
      await tester.pump();
      await move.up();
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
      expect(generator.calls, calls);
      expect(runtime.initialCoordinator.retainedHistoryCount, history);
      expect(observerCalls, 0);
      expect(await _canvasBytes(tester), visibleBefore);
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        isNot(contains('SECRET')),
      );
      final pointerFailure = runtime.diagnosticTrace.events.lastWhere(
        (event) =>
            event.stage == Phase6DiagnosticStage.selectionTransformPreview,
      );
      expect(pointerFailure.terminalDisposition, 2);
      expect(pointerFailure.failureStageCode, 7);
      expect(pointerFailure.transformModeCode, 1);
      expect(pointerFailure.shapeTargetCount, 1);
      await tester.tap(find.text('Right'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
      expect(runtime.initialCoordinator.retainedHistoryCount, history);
      expect(generator.calls, calls);
      expect(observerCalls, 0);
      expect(await _canvasBytes(tester), visibleBefore);
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        isNot(contains('SECRET')),
      );
      expect(runtime.diagnosticTrace.copyText(), isNot(contains('SECRET')));
      expect(_canvasPainter(tester).toString(), isNot(contains('SECRET')));
      final toolbarFailure = runtime.diagnosticTrace.events.lastWhere(
        (event) =>
            event.stage == Phase6DiagnosticStage.selectionTransformPreview,
      );
      expect(toolbarFailure.terminalDisposition, 2);
      expect(toolbarFailure.failureStageCode, 7);
      expect(toolbarFailure.transformModeCode, 1);
      expect(toolbarFailure.shapeTargetCount, 1);
      runtime.initialCoordinator.removeListener(observer);
    }
  });

  testWidgets('multi-Object partial preview failure publishes nothing', (
    WidgetTester tester,
  ) async {
    final generator = _RuntimeCountingUuidGenerator();
    final runtime = _runtime(uuidGenerator: generator);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('shape'));
    await tester.pump();
    await tester.tap(find.text('Fill'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    for (final offset in const [Offset(-90, 0), Offset(90, 0)]) {
      final create = await tester.startGesture(
        center + offset - const Offset(30, 25),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(60, 50));
      await create.up();
      await tester.pump();
    }
    final baseRenderer =
        runtime.renderingRegistry.definitions[shapeObjectTypeKey]!;
    final adversary = _AdversarialPreviewRenderer(
      baseRenderer,
      _PreviewFailureMode.partial,
    );
    final override = _ok(
      RenderingRegistry.create([
        ...runtime.renderingRegistry.definitions.values.where(
          (value) => value.typeKey != shapeObjectTypeKey,
        ),
        adversary,
      ], maximumDefinitions: 16),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Phase6Canvas(
          runtime: runtime,
          renderingRegistryOverride: override,
        ),
      ),
    );
    await tester.tap(find.text('selection'));
    await tester.pump();
    final selectedCanvas = find.bySemanticsLabel('Handwriting canvas');
    final selectedCenter = tester.getCenter(selectedCanvas);
    final select = await tester.startGesture(
      selectedCenter - const Offset(150, 80),
      kind: PointerDeviceKind.mouse,
    );
    await select.moveTo(selectedCenter + const Offset(150, 80));
    await select.up();
    await tester.pump();
    final before = runtime.initialCoordinator.snapshot;
    final calls = generator.calls;
    final history = runtime.initialCoordinator.retainedHistoryCount;
    var observerCalls = 0;
    void observer(CommittedChange _) => observerCalls += 1;
    _ok(runtime.initialCoordinator.addListener(observer));
    final visibleBefore = await _canvasBytes(tester);
    final move = await tester.startGesture(
      selectedCenter,
      kind: PointerDeviceKind.mouse,
    );
    await move.moveBy(const Offset(25, 15));
    await tester.pump();
    expect(adversary.calls, 2);
    await move.up();
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, same(before.root));
    expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
    expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
    expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
    expect(generator.calls, calls);
    expect(runtime.initialCoordinator.retainedHistoryCount, history);
    expect(observerCalls, 0);
    expect(_objectCount(runtime), 2);
    expect(await _canvasBytes(tester), visibleBefore);
    await tester.tap(find.text('Right'));
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.root, same(before.root));
    expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
    expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
    expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
    expect(runtime.initialCoordinator.retainedHistoryCount, history);
    expect(generator.calls, calls);
    expect(observerCalls, 0);
    expect(_objectCount(runtime), 2);
    expect(await _canvasBytes(tester), visibleBefore);
    runtime.initialCoordinator.removeListener(observer);
  });

  testWidgets('complete Selection composition limits reject publication', (
    WidgetTester tester,
  ) async {
    final scenarios =
        <
          ({
            String name,
            int objects,
            bool selectAll,
            int previews,
            int primitives,
            int damage,
            int selections,
          })
        >[
          (
            name: 'aggregate previews',
            objects: 2,
            selectAll: true,
            previews: 3,
            primitives: 400000,
            damage: 400000,
            selections: 20000,
          ),
          (
            name: 'committed plus overlays',
            objects: 2,
            selectAll: false,
            previews: 20000,
            primitives: 4,
            damage: 400000,
            selections: 20000,
          ),
          (
            name: 'preview plus selection frame',
            objects: 1,
            selectAll: false,
            previews: 20000,
            primitives: 3,
            damage: 400000,
            selections: 20000,
          ),
          (
            name: 'aggregate damage',
            objects: 1,
            selectAll: false,
            previews: 20000,
            primitives: 400000,
            damage: 4,
            selections: 20000,
          ),
          (
            name: 'selection overlays',
            objects: 1,
            selectAll: false,
            previews: 20000,
            primitives: 400000,
            damage: 400000,
            selections: 2,
          ),
        ];
    for (final scenario in scenarios) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final generator = _RuntimeCountingUuidGenerator();
      final runtime = _runtime(
        uuidGenerator: generator,
        maximumPreviewOverlays: scenario.previews,
        maximumPrimitives: scenario.primitives,
        maximumDamageRegions: scenario.damage,
        maximumSelectionOverlays: scenario.selections,
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      await tester.tap(find.text('shape'));
      await tester.pump();
      await tester.tap(find.text('Fill'));
      await tester.pump();
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final offsets = scenario.objects == 1
          ? const [Offset.zero]
          : const [Offset(-90, 0), Offset(90, 0)];
      for (final offset in offsets) {
        final create = await tester.startGesture(
          center + offset - const Offset(30, 25),
          kind: PointerDeviceKind.mouse,
        );
        await create.moveBy(const Offset(60, 50));
        await create.up();
        await tester.pump();
      }
      await tester.tap(find.text('selection'));
      await tester.pump();
      final transformPoint = scenario.selectAll
          ? center
          : center + offsets.first;
      if (scenario.selectAll) {
        final select = await tester.startGesture(
          center - const Offset(150, 80),
          kind: PointerDeviceKind.mouse,
        );
        await select.moveTo(center + const Offset(150, 80));
        await select.up();
      } else {
        final select = await tester.startGesture(
          transformPoint,
          kind: PointerDeviceKind.mouse,
        );
        await select.up();
      }
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot;
      final calls = generator.calls;
      final history = runtime.initialCoordinator.retainedHistoryCount;
      var observerCalls = 0;
      void observer(CommittedChange _) => observerCalls += 1;
      _ok(runtime.initialCoordinator.addListener(observer));
      final visibleBefore = await _canvasBytes(tester);
      final move = await tester.startGesture(
        transformPoint,
        kind: PointerDeviceKind.mouse,
      );
      await move.moveBy(const Offset(30, 20));
      await tester.pump();
      await move.up();
      await tester.pump();
      expect(
        runtime.initialCoordinator.snapshot.root,
        same(before.root),
        reason: scenario.name,
      );
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
      expect(runtime.initialCoordinator.retainedHistoryCount, history);
      expect(generator.calls, calls);
      expect(observerCalls, 0);
      expect(_objectCount(runtime), scenario.objects);
      expect(await _canvasBytes(tester), visibleBefore, reason: scenario.name);
      await tester.tap(find.text('Right'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
      expect(runtime.initialCoordinator.retainedHistoryCount, history);
      expect(generator.calls, calls);
      expect(observerCalls, 0);
      expect(_objectCount(runtime), scenario.objects);
      expect(await _canvasBytes(tester), visibleBefore, reason: scenario.name);
      runtime.initialCoordinator.removeListener(observer);
    }
  });

  testWidgets(
    'unchanged inline Text closes losslessly before requested actions',
    (WidgetTester tester) async {
      final generator = _RuntimeCountingUuidGenerator();
      final runtime = _runtime(uuidGenerator: generator);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      await tester.tap(find.text('text'));
      await tester.pump();
      final create = await tester.startGesture(
        center - const Offset(60, 30),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(120, 60));
      await create.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'unchanged text',
      );
      await _commitInlineText(tester);
      await tester.pump();

      Future<void> openEditor() async {
        await tester.tap(find.text('selection'));
        await tester.pump();
        final select = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
        );
        await select.up();
        await tester.pump();
        await tester.tap(find.byKey(const Key('edit-selected-text')));
        await tester.pump();
        expect(
          find.byKey(const Key('inline-text-editor-overlay')),
          findsOneWidget,
        );
      }

      await openEditor();
      final before = runtime.initialCoordinator.snapshot;
      final uuidCalls = generator.calls;
      final retainedHistory = runtime.initialCoordinator.retainedHistoryCount;
      var observerCalls = 0;
      void observer(CommittedChange _) => observerCalls += 1;
      _ok(runtime.initialCoordinator.addListener(observer));
      await tester.tap(find.text('pen'));
      await tester.pump();
      expect(find.byKey(const Key('inline-text-editor-overlay')), findsNothing);
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
      expect(generator.calls, uuidCalls);
      expect(runtime.initialCoordinator.retainedHistoryCount, retainedHistory);
      expect(observerCalls, 0);

      await openEditor();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'temporary change',
      );
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'unchanged text',
      );
      await _commitInlineText(tester);
      await tester.pump();
      expect(find.byKey(const Key('inline-text-editor-overlay')), findsNothing);
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(generator.calls, uuidCalls);
      expect(runtime.initialCoordinator.retainedHistoryCount, retainedHistory);
      expect(observerCalls, 0);
      runtime.initialCoordinator.removeListener(observer);

      await openEditor();
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.byKey(const Key('inline-text-editor-overlay')), findsNothing);
      expect(_objectCount(runtime), 0);
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(_objectCount(runtime), 1);

      await tester.tap(find.text('text'));
      await tester.pump();
      final other = await tester.startGesture(
        center + const Offset(140, 100),
        kind: PointerDeviceKind.mouse,
      );
      await other.moveBy(const Offset(40, 30));
      await other.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'redo candidate',
      );
      await _commitInlineText(tester);
      await tester.pump();
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(_objectCount(runtime), 1);
      await openEditor();
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(find.byKey(const Key('inline-text-editor-overlay')), findsNothing);
      expect(_objectCount(runtime), 2);

      await openEditor();
      await tester.tap(find.text('Save in memory'));
      await tester.pump();
      expect(find.byKey(const Key('inline-text-editor-overlay')), findsNothing);
      expect(runtime.initialCoordinator.snapshot.isDirty, isFalse);
    },
  );

  testWidgets(
    'stale and thrown Text completion failures preserve secret draft',
    (WidgetTester tester) async {
      final generator = _ToggleRuntimeUuidGenerator();
      final runtime = _runtime(uuidGenerator: generator);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      await tester.tap(find.text('text'));
      await tester.pump();
      final create = await tester.startGesture(
        center - const Offset(60, 30),
        kind: PointerDeviceKind.mouse,
      );
      await create.moveBy(const Offset(120, 60));
      await create.up();
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'base',
      );
      await _commitInlineText(tester);
      await tester.pump();
      final committedCenter = _textObjectCenterGlobal(
        tester,
        runtime,
        runtime.initialCoordinator.snapshot.root.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects
            .single,
      );
      await tester.tap(find.text('selection'));
      await tester.pump();
      final select = await tester.startGesture(
        committedCenter,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      const secret = 'SECRET-draft-value';
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        secret,
      );
      generator.throwNow = true;
      final before = runtime.initialCoordinator.snapshot;
      final calls = generator.calls;
      await _commitInlineText(tester);
      await tester.pump();
      expect(
        find.byKey(const Key('inline-text-editor-overlay')),
        findsOneWidget,
      );
      expect(_canvasPainter(tester).selectionPrimitiveCount, 0);
      expect(_canvasPainter(tester).selectionFrame, isNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        secret,
      );
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
      expect(generator.calls, calls + 1);
      final status = tester
          .widget<Text>(find.byKey(const Key('canvas-status')))
          .data!;
      expect(status, isNot(contains(secret)));
      expect(status, 'Text rejected; editor remains open');

      final clickAway = await tester.startGesture(
        tester.getTopLeft(find.byKey(const Key('phase6-canvas-listener'))) +
            const Offset(10, 10),
        kind: PointerDeviceKind.mouse,
      );
      await clickAway.up();
      await tester.pump();
      expect(
        find.byKey(const Key('inline-text-editor-overlay')),
        findsOneWidget,
      );
      expect(_canvasPainter(tester).selectionPrimitiveCount, 0);
      expect(_canvasPainter(tester).selectionFrame, isNull);
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(_objectCount(runtime), 1);

      generator.throwNow = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      if (find.byKey(const Key('text-object-editor')).evaluate().isEmpty &&
          find.byKey(const Key('edit-selected-text')).evaluate().isEmpty) {
        final reselect = await tester.startGesture(
          committedCenter,
          kind: PointerDeviceKind.mouse,
        );
        await reselect.up();
        await tester.pump();
      }
      if (find.byKey(const Key('text-object-editor')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('edit-selected-text')));
        await tester.pump();
      }
      expect(find.byKey(const Key('text-object-editor')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'SECRET-stale-draft',
      );
      final staleBase = runtime.initialCoordinator.snapshot;
      final page = staleBase.root.pages.single;
      final layer = page.layers.whereType<ContentLayer>().single;
      final source = layer.objects.single;
      final membershipChange = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: staleBase.root.id,
          pageId: page.id,
          metadata: phase3Metadata(
            family: 'alnote.commands.object.collection_edit',
            correlation: 9898,
          ),
          preconditions: RevisionPreconditions(
            pages: {page.id: staleBase.revisions.pages[page.id]!},
            layerMembership: {
              layer.id: staleBase.revisions.layerMembership[layer.id]!,
            },
          ),
          additions: [
            ObjectCollectionAddition(
              layerId: layer.id,
              object: testObject(
                id: 9899,
                typeKey: source.typeKey,
                schemaVersion: source.typeSchemaVersion,
                payload: source.payload,
                transform: source.transform,
              ),
            ),
          ],
          maximumOperations: runtime.maximumCommandOperations,
        ),
      );
      expect(
        runtime.initialCoordinator.execute(membershipChange),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      final staleCurrent = runtime.initialCoordinator.snapshot;
      final staleCalls = generator.calls;
      await _commitInlineText(tester);
      await tester.pump();
      expect(
        find.byKey(const Key('inline-text-editor-overlay')),
        findsOneWidget,
      );
      expect(runtime.initialCoordinator.snapshot.root, same(staleCurrent.root));
      expect(
        runtime.initialCoordinator.snapshot.revisions,
        staleCurrent.revisions,
      );
      expect(generator.calls, staleCalls);
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        isNot(contains('SECRET')),
      );
    },
  );

  testWidgets('returned and thrown Text layout failures retain live drafts', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    await tester.tap(find.text('text'));
    await tester.pump();
    final create = await tester.startGesture(
      center - const Offset(60, 30),
      kind: PointerDeviceKind.mouse,
    );
    await create.moveBy(const Offset(120, 60));
    await create.up();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('text-object-editor')), 'base');
    await _commitInlineText(tester);
    await tester.pump();

    for (final throws in const [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final engine = _FailingTextLayoutEngine(
        throws: throws,
        delegate: runtime.textLayoutEngine,
        successfulCallsBeforeFailure: 1,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Phase6Canvas(
            runtime: runtime,
            textLayoutEngineOverride: engine,
          ),
        ),
      );
      await tester.tap(find.text('selection'));
      await tester.pump();
      final currentCenter = tester.getCenter(
        find.bySemanticsLabel('Handwriting canvas'),
      );
      final select = await tester.startGesture(
        currentCenter,
        kind: PointerDeviceKind.mouse,
      );
      await select.up();
      await tester.pump();
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pump();
      const secret = 'SECRET-layout-draft';
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        secret,
      );
      final before = runtime.initialCoordinator.snapshot;
      await _commitInlineText(tester);
      await tester.pump();
      expect(engine.calls, greaterThan(0));
      expect(
        find.byKey(const Key('inline-text-editor-overlay')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('text-object-editor')))
            .controller!
            .text,
        secret,
      );
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.snapshot.revisions, before.revisions);
      expect(runtime.initialCoordinator.snapshot.canUndo, before.canUndo);
      expect(runtime.initialCoordinator.snapshot.isDirty, before.isDirty);
      expect(
        tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
        isNot(contains('SECRET')),
      );
    }
  });

  testWidgets(
    'rich Text editing is rejected without lifecycle mutation',
    (WidgetTester tester) =>
        _verifyUnsupportedTextDialog(tester, _widgetRichText),
  );

  testWidgets(
    'embedded-newline Text is rejected without lifecycle publication',
    (WidgetTester tester) =>
        _verifyUnsupportedTextDialog(tester, _widgetEmbeddedNewlineText),
  );

  testWidgets(
    'style-unknown Text is rejected without lifecycle publication',
    (WidgetTester tester) =>
        _verifyUnsupportedTextDialog(tester, _widgetStyleUnknownText),
  );

  test('runtime registry ceilings are injected and exact boundaries pass', () {
    final exactGenerator = _RuntimeCountingUuidGenerator();
    expect(
      _runtimeResult(
        uuidGenerator: exactGenerator,
        maximumRenderingDefinitions: 5,
        maximumHitTestingDefinitions: 5,
        maximumTools: 5,
        maximumActions: 5,
        maximumBindings: 11,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    expect(exactGenerator.calls, 5);
    for (final limits in [
      (rendering: 4, hits: 5, tools: 5, actions: 5, bindings: 11),
      (rendering: 5, hits: 4, tools: 5, actions: 5, bindings: 11),
      (rendering: 5, hits: 5, tools: 4, actions: 5, bindings: 11),
      (rendering: 5, hits: 5, tools: 5, actions: 4, bindings: 11),
      (rendering: 5, hits: 5, tools: 5, actions: 5, bindings: 10),
    ]) {
      final generator = _RuntimeCountingUuidGenerator();
      expect(
        _runtimeResult(
          uuidGenerator: generator,
          maximumRenderingDefinitions: limits.rendering,
          maximumHitTestingDefinitions: limits.hits,
          maximumTools: limits.tools,
          maximumActions: limits.actions,
          maximumBindings: limits.bindings,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(generator.calls, 0);
    }
    final incoherent = _RuntimeCountingUuidGenerator();
    expect(
      _runtimeResult(uuidGenerator: incoherent, maximumPointsPerPrimitive: 8),
      isA<Err<Object?, Object?>>(),
    );
    expect(incoherent.calls, 0);

    final exactPreviewLayers = _RuntimeCountingUuidGenerator();
    expect(
      _runtimeResult(
        uuidGenerator: exactPreviewLayers,
        maximumPenPreviewLayers: 64,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    expect(exactPreviewLayers.calls, 5);
    for (final ceiling in [0, 65]) {
      final generator = _RuntimeCountingUuidGenerator();
      expect(
        _runtimeResult(
          uuidGenerator: generator,
          maximumPenPreviewLayers: ceiling,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(generator.calls, 0);
    }
  });

  test('runtime completes Pen geometry preflight before UUID generation', () {
    for (final configuration in [
      (pen: 10, handwriting: 9, elements: 19, vertices: 196),
      (pen: 10, handwriting: 10, elements: 18, vertices: 196),
      (pen: 10, handwriting: 10, elements: 19, vertices: 195),
      (
        pen: Revision.maximumValue,
        handwriting: Revision.maximumValue,
        elements: Revision.maximumValue,
        vertices: Revision.maximumValue,
      ),
    ]) {
      final generator = _RuntimeCountingUuidGenerator();
      expect(
        _runtimeResult(
          uuidGenerator: generator,
          maximumPenSamples: configuration.pen,
          maximumHandwritingSamples: configuration.handwriting,
          maximumGeometryElements: configuration.elements,
          maximumGeometryVertices: configuration.vertices,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(generator.calls, 0);
    }

    final exact = _RuntimeCountingUuidGenerator();
    expect(
      _runtimeResult(
        uuidGenerator: exact,
        maximumPenSamples: 10,
        maximumHandwritingSamples: 10,
        maximumGeometryElements: 19,
        maximumGeometryVertices: 196,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    expect(exact.calls, 5);
  });
}

Future<void> _commitInlineText(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> _addTestMouse(WidgetTester tester, Offset position, int device) =>
    tester.sendEventToBinding(
      PointerAddedEvent(
        kind: PointerDeviceKind.mouse,
        position: position,
        device: device,
      ),
    );

Future<void> _moveTestMouse(WidgetTester tester, Offset position, int device) =>
    tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        position: position,
        device: device,
      ),
    );

Future<void> _removeTestMouse(WidgetTester tester, int device) =>
    tester.sendEventToBinding(
      PointerRemovedEvent(kind: PointerDeviceKind.mouse, device: device),
    );

Future<void> _verifyUnsupportedTextDialog(
  WidgetTester tester,
  TextPayload Function(TextLimits) payloadBuilder,
) async {
  final generator = _RuntimeCountingUuidGenerator();
  final runtime = _runtime(uuidGenerator: generator);
  final root = runtime.initialCoordinator.snapshot.root;
  final page = root.pages.single;
  final layer = page.layers.whereType<ContentLayer>().single;
  final payload = payloadBuilder(runtime.textLimits);
  final object = testObject(
    id: 9090,
    typeKey: textObjectTypeKey,
    schemaVersion: textSchemaVersion,
    payload: payload.encode(),
    transform: _ok(
      AffineTransform2D.restoreFromStorage(const [1, 0, 0, 1, 360, 240]),
    ),
  );
  final seeded = _ok(
    AtomicObjectCollectionEditRequest.create(
      documentId: root.id,
      pageId: page.id,
      metadata: phase3Metadata(
        family: 'alnote.commands.object.collection_edit',
        correlation: 9091,
      ),
      preconditions: RevisionPreconditions(
        pages: {
          page.id:
              runtime.initialCoordinator.snapshot.revisions.pages[page.id]!,
        },
        layerMembership: {
          layer.id: runtime
              .initialCoordinator
              .snapshot
              .revisions
              .layerMembership[layer.id]!,
        },
      ),
      additions: [ObjectCollectionAddition(layerId: layer.id, object: object)],
      maximumOperations: runtime.maximumCommandOperations,
    ),
  );
  expect(
    runtime.initialCoordinator.execute(seeded),
    isA<Ok<CommandCommit, CommandFailure>>(),
  );
  await tester.pumpWidget(AlNoteApp(runtime: runtime));
  await tester.tap(find.text('Save in memory'));
  await tester.pumpAndSettle();
  final savedBytes = List<int>.of(_canvasPainter(tester).savedBytes!);
  final savedRoot = _canvasPainter(tester).savedRoot;
  await tester.tap(find.text('selection'));
  await tester.pump();
  final canvas = find.bySemanticsLabel('Handwriting canvas');
  final gesture = await tester.startGesture(
    tester.getTopLeft(canvas) + const Offset(40, 40),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveTo(tester.getBottomRight(canvas) - const Offset(40, 40));
  await gesture.up();
  await tester.pump();
  expect(find.byKey(const Key('edit-selected-text')), findsOneWidget);
  final before = runtime.initialCoordinator.snapshot;
  final encoded = payload.encode();
  final uuidCalls = generator.calls;
  await tester.tap(find.byKey(const Key('edit-selected-text')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('text-object-editor')), findsNothing);
  expect(find.text('Rich text editing unavailable'), findsOneWidget);
  expect(find.byKey(const Key('edit-selected-text')), findsOneWidget);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
  final after = runtime.initialCoordinator.snapshot;
  expect(after.root, same(before.root));
  expect(after.revisions, before.revisions);
  expect(after.canUndo, before.canUndo);
  expect(after.canRedo, before.canRedo);
  expect(generator.calls, uuidCalls);
  expect(_canvasPainter(tester).savedBytes, savedBytes);
  expect(_canvasPainter(tester).savedRoot, same(savedRoot));
  expect(
    _ok(
      TextPayload.decode(
        after.root.pages.single.layers
            .whereType<ContentLayer>()
            .single
            .objects
            .single
            .payload,
        limits: runtime.textLimits,
      ),
    ).encode(),
    encoded,
  );
}

Phase6CanvasRuntime _runtime({
  UuidGenerator? uuidGenerator,
  PdfProcessingLimits? pdfProcessingLimits,
  PdfBackend? pdfBackend,
  LocalPdfOpenWorkflow? localPdfOpenWorkflow,
  int storageCeiling = 10000000,
  int maximumPenSamples = 10000,
  int maximumPenPreviewLayers = 8,
  int maximumEraserPoints = 10000,
  int maximumCommandOperations = 64,
  int maximumEstimatedRetainedHistoryBytes = 10000000,
  Phase6DebugClipboard debugClipboard = const _SuccessfulClipboard(),
  Phase6NativePictureObserver nativePictureObserver =
      const Phase6NoopNativePictureObserver(),
  Phase6ReopenGateway? reopenGateway,
  double penOpacity = 1,
  int maximumPreviewOverlays = 20000,
  int maximumPrimitives = 400000,
  int maximumDamageRegions = 400000,
  int maximumSelectionOverlays = 20000,
  double minimumInteractiveSelectionExtentViewPixels = 32,
  double selectionHandleHitSizeViewPixels = 22,
  int maximumCommittedPaintChunks = 128,
  int maximumCommittedPaintChunkObjects = 16,
  int? maximumCommittedPaintChunkPrimitives,
}) => _ok(
  _runtimeResult(
    uuidGenerator: uuidGenerator,
    pdfProcessingLimits: pdfProcessingLimits,
    pdfBackend: pdfBackend,
    localPdfOpenWorkflow: localPdfOpenWorkflow,
    storageCeiling: storageCeiling,
    maximumPenSamples: maximumPenSamples,
    maximumPenPreviewLayers: maximumPenPreviewLayers,
    maximumEraserPoints: maximumEraserPoints,
    minimumInteractiveSelectionExtentViewPixels:
        minimumInteractiveSelectionExtentViewPixels,
    selectionHandleHitSizeViewPixels: selectionHandleHitSizeViewPixels,
    maximumCommittedPaintChunks: maximumCommittedPaintChunks,
    maximumCommittedPaintChunkObjects: maximumCommittedPaintChunkObjects,
    maximumCommittedPaintChunkPrimitives:
        maximumCommittedPaintChunkPrimitives ??
        math.min(20000, maximumPrimitives),
    maximumCommandOperations: maximumCommandOperations,
    maximumEstimatedRetainedHistoryBytes: maximumEstimatedRetainedHistoryBytes,
    debugClipboard: debugClipboard,
    nativePictureObserver: nativePictureObserver,
    diagnosticTrace: _ok(
      Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
    ),
    reopenGateway: reopenGateway,
    penOpacity: penOpacity,
    maximumPreviewOverlays: maximumPreviewOverlays,
    maximumPrimitives: maximumPrimitives,
    maximumDamageRegions: maximumDamageRegions,
    maximumSelectionOverlays: maximumSelectionOverlays,
  ),
);

PdfModelLimits _widgetPdfModelLimits() => _ok(
  PdfModelLimits.create(
    maximumPageCount: 10000,
    maximumCoordinateMagnitude: 1000000,
    maximumPageDimension: 1000000,
    maximumPageArea: 1000000000000,
    maximumUnknownFields: 256,
    maximumUnknownNodes: 100000,
    maximumNestingDepth: 32,
    maximumUnknownStringCodeUnits: 1000000,
  ),
);

PdfProcessingLimits _widgetPdfProcessingLimits() => _ok(
  PdfProcessingLimits.create(
    maximumEncodedBytes: 1024,
    maximumPageCount: 16,
    maximumRenderDimension: 1024,
    maximumRenderPixels: 1048576,
    maximumExtractedGlyphs: 1024,
    maximumLinks: 64,
    maximumOperations: 128,
  ),
);

final class _WidgetPdfPicker implements LocalPdfPickerHost {
  const _WidgetPdfPicker(this.bytes);

  final List<int> bytes;

  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => _WidgetPdfHandle(bytes);
}

final class _WidgetPdfHandle implements LocalPdfFileHandle {
  const _WidgetPdfHandle(this.bytes);

  final List<int> bytes;

  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) => Stream<List<int>>.value(bytes);
}

final class _WidgetPdfBackend implements PdfBackend, PdfLifecycleProvider {
  _WidgetPdfBackend(
    this.modelLimits, {
    this.inspectionFailure,
    this.failRender = false,
    this.rgbaColor = const [255, 255, 255, 255],
  });

  @override
  final lifecycle = PdfBackendLifecycle();
  int inspections = 0;
  final PdfModelLimits modelLimits;
  final PdfInspectOutcome? inspectionFailure;
  final bool failRender;
  final List<int> rgbaColor;
  final List<int> renderedPageIndexes = <int>[];

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    inspections++;
    final rejected = inspectionFailure;
    if (rejected != null) return rejected;
    final resource = await resourceReader.read(
      identity: request.resourceIdentity,
      limits: request.limits,
      cancellationToken: request.cancellationToken,
    );
    if (resource is! Ok<PdfResourceBytes, StructuredFailure>) {
      return const PdfMissing();
    }
    final identity = _ok(PdfBackendIdentity.parse('test.pdf.backend'));
    final firstBox = _ok(
      PdfSourceBox.create(
        left: 10,
        bottom: 20,
        right: 190,
        top: 90,
        limits: modelLimits,
      ),
    );
    final secondBox = _ok(
      PdfSourceBox.create(
        left: -20,
        bottom: -40,
        right: 280,
        top: 160,
        limits: modelLimits,
      ),
    );
    return PdfInspectSuccess.capture(
      backendIdentity: identity,
      pages: <PdfInspectedPage>[
        _ok(
          PdfInspectedPage.create(
            pageIndex: 0,
            boxKind: PdfPageBoxKind.cropBox,
            sourceBox: firstBox,
            rotation: PdfPageRotation.degrees0,
            displayedWidth: 180,
            displayedHeight: 70,
            limits: modelLimits,
          ),
        ),
        _ok(
          PdfInspectedPage.create(
            pageIndex: 1,
            boxKind: PdfPageBoxKind.mediaBox,
            sourceBox: secondBox,
            rotation: PdfPageRotation.degrees270,
            displayedWidth: 200,
            displayedHeight: 300,
            limits: modelLimits,
          ),
        ),
      ],
      modelLimits: modelLimits,
      limits: request.limits,
      cancellationToken: request.cancellationToken,
    );
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    if (failRender) {
      return const PdfRenderFailure(PdfRenderFailureReason.missing);
    }
    final resource = await resourceReader.read(
      identity: request.reference.resourceIdentity,
      limits: request.limits,
      cancellationToken: request.cancellationToken,
    );
    if (resource is! Ok<PdfResourceBytes, StructuredFailure>) {
      return const PdfRenderFailure(PdfRenderFailureReason.missing);
    }
    renderedPageIndexes.add(request.reference.pageIndex);
    final output = PdfRenderOutput.capture(
      backendIdentity: _ok(PdfBackendIdentity.parse('test.pdf.backend')),
      region: request.region,
      pixelWidth: request.pixelWidth,
      pixelHeight: request.pixelHeight,
      rgbaBytes: List<int>.generate(
        request.pixelWidth * request.pixelHeight * 4,
        (i) => rgbaColor[i % 4],
      ),
      limits: request.limits,
      cancellationToken: request.cancellationToken,
    );
    return output is Ok<PdfRenderOutput, StructuredFailure>
        ? PdfRenderSuccess(output.value)
        : const PdfRenderFailure(PdfRenderFailureReason.corrupt);
  }

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfExtractedText, StructuredFailure>(_widgetPdfFailure());

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfSafeLinks, StructuredFailure>(_widgetPdfFailure());
}

StructuredFailure _widgetPdfFailure() => StructuredFailure(
  code: 'test.pdf.unavailable',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'Unavailable.',
);

TextPayload _widgetRichText(TextLimits limits) {
  TextCharacterStyle style(double size, int color) => _ok(
    TextCharacterStyle.create(
      genericFontFamily: TextGenericFontFamily.sansSerif,
      fontSize: size,
      weight: 400,
      italic: false,
      underline: false,
      strikethrough: false,
      argb: color,
      limits: limits,
    ),
  );
  final first = style(18, 0xff000000);
  final second = style(28, 0xffff0000);
  final paragraphStyle = _ok(
    TextParagraphStyle.create(
      alignment: TextAlignment.left,
      direction: TextParagraphDirection.ltr,
      lineHeight: 1.2,
      limits: limits,
      unknownFields: PreservedMap({
        'styleFuture': const PreservedBoolean(true),
      }),
    ),
  );
  final paragraph = _ok(
    TextParagraph.create(
      runs: [
        _ok(TextRun.create(text: 'rich ', style: first, limits: limits)),
        _ok(
          TextRun.create(
            text: 'text',
            style: second,
            limits: limits,
            unknownFields: PreservedMap({
              'runFuture': const PreservedString('preserved'),
            }),
          ),
        ),
      ],
      style: paragraphStyle,
      limits: limits,
      unknownFields: PreservedMap({
        'paragraphFuture': const PreservedBoolean(true),
      }),
    ),
  );
  return _ok(
    TextPayload.create(
      paragraphs: [paragraph],
      defaultCharacterStyle: first,
      defaultParagraphStyle: paragraphStyle,
      boxMode: TextBoxMode.fixedWidthFixedHeight,
      intrinsicWidth: 120,
      intrinsicHeight: 120,
      padding: _ok(
        TextPadding.create(
          left: 4,
          top: 4,
          right: 4,
          bottom: 4,
          limits: limits,
        ),
      ),
      verticalAlignment: TextVerticalAlignment.top,
      overflowPolicy: TextOverflowPolicy.visible,
      limits: limits,
      unknownFields: PreservedMap({
        'payloadFuture': const PreservedBoolean(true),
      }),
    ),
  );
}

TextPayload _widgetAlignedSimpleText(
  TextLimits limits, {
  required TextAlignment horizontal,
  required TextVerticalAlignment vertical,
}) {
  final character = _ok(
    TextCharacterStyle.create(
      genericFontFamily: TextGenericFontFamily.sansSerif,
      fontSize: 22,
      weight: 400,
      italic: false,
      underline: false,
      strikethrough: false,
      argb: 0xff17324d,
      limits: limits,
    ),
  );
  final paragraphStyle = _ok(
    TextParagraphStyle.create(
      alignment: horizontal,
      direction: TextParagraphDirection.ltr,
      lineHeight: 1.2,
      limits: limits,
    ),
  );
  final paragraph = _ok(
    TextParagraph.create(
      runs: [
        _ok(
          TextRun.create(
            text: 'stable aligned text',
            style: character,
            limits: limits,
          ),
        ),
      ],
      style: paragraphStyle,
      limits: limits,
    ),
  );
  return _ok(
    TextPayload.create(
      paragraphs: [paragraph],
      defaultCharacterStyle: character,
      defaultParagraphStyle: paragraphStyle,
      boxMode: TextBoxMode.fixedWidthFixedHeight,
      intrinsicWidth: 360,
      intrinsicHeight: 240,
      padding: _ok(
        TextPadding.create(
          left: 6,
          top: 7,
          right: 8,
          bottom: 9,
          limits: limits,
        ),
      ),
      verticalAlignment: vertical,
      overflowPolicy: TextOverflowPolicy.clip,
      limits: limits,
    ),
  );
}

TextPayload _widgetEmbeddedNewlineText(TextLimits limits) {
  final style = _ok(
    TextCharacterStyle.create(
      genericFontFamily: TextGenericFontFamily.sansSerif,
      fontSize: 18,
      weight: 400,
      italic: false,
      underline: false,
      strikethrough: false,
      argb: 0xff000000,
      limits: limits,
    ),
  );
  final paragraphStyle = _ok(
    TextParagraphStyle.create(
      alignment: TextAlignment.left,
      direction: TextParagraphDirection.ltr,
      lineHeight: 1.2,
      limits: limits,
    ),
  );
  final paragraph = _ok(
    TextParagraph.create(
      runs: [_ok(TextRun.create(text: 'a\nb', style: style, limits: limits))],
      style: paragraphStyle,
      limits: limits,
    ),
  );
  return _ok(
    TextPayload.create(
      paragraphs: [paragraph],
      defaultCharacterStyle: style,
      defaultParagraphStyle: paragraphStyle,
      boxMode: TextBoxMode.fixedWidthFixedHeight,
      intrinsicWidth: 120,
      intrinsicHeight: 120,
      padding: _ok(
        TextPadding.create(
          left: 4,
          top: 4,
          right: 4,
          bottom: 4,
          limits: limits,
        ),
      ),
      verticalAlignment: TextVerticalAlignment.top,
      overflowPolicy: TextOverflowPolicy.visible,
      limits: limits,
    ),
  );
}

TextPayload _widgetStyleUnknownText(TextLimits limits) {
  final style = _ok(
    TextCharacterStyle.create(
      genericFontFamily: TextGenericFontFamily.sansSerif,
      fontSize: 18,
      weight: 400,
      italic: false,
      underline: false,
      strikethrough: false,
      argb: 0xff000000,
      limits: limits,
      unknownFields: PreservedMap({
        'styleFuture': const PreservedBoolean(true),
      }),
    ),
  );
  final paragraphStyle = _ok(
    TextParagraphStyle.create(
      alignment: TextAlignment.left,
      direction: TextParagraphDirection.ltr,
      lineHeight: 1.2,
      limits: limits,
    ),
  );
  final paragraph = _ok(
    TextParagraph.create(
      runs: [_ok(TextRun.create(text: 'simple', style: style, limits: limits))],
      style: paragraphStyle,
      limits: limits,
    ),
  );
  return _ok(
    TextPayload.create(
      paragraphs: [paragraph],
      defaultCharacterStyle: style,
      defaultParagraphStyle: paragraphStyle,
      boxMode: TextBoxMode.fixedWidthFixedHeight,
      intrinsicWidth: 120,
      intrinsicHeight: 120,
      padding: _ok(
        TextPadding.create(
          left: 4,
          top: 4,
          right: 4,
          bottom: 4,
          limits: limits,
        ),
      ),
      verticalAlignment: TextVerticalAlignment.top,
      overflowPolicy: TextOverflowPolicy.visible,
      limits: limits,
    ),
  );
}

Result<Phase6CanvasRuntime, StructuredFailure> _runtimeResult({
  UuidGenerator? uuidGenerator,
  PdfProcessingLimits? pdfProcessingLimits,
  PdfBackend? pdfBackend,
  LocalPdfOpenWorkflow? localPdfOpenWorkflow,
  int storageCeiling = 10000000,
  int maximumPenSamples = 10000,
  int maximumPenPreviewLayers = 8,
  int maximumHandwritingSamples = 10000,
  int maximumEraserPoints = 10000,
  int maximumCommandOperations = 64,
  int maximumEstimatedRetainedHistoryBytes = 10000000,
  int maximumRenderingDefinitions = 16,
  int maximumHitTestingDefinitions = 16,
  int maximumTools = 16,
  int maximumActions = 16,
  int maximumBindings = 32,
  int maximumPointsPerPrimitive = 10000,
  int ellipseVertexCount = 16,
  int maximumGeometryElements = 20000,
  int maximumGeometryVertices = 400000,
  Phase6DiagnosticTrace? diagnosticTrace,
  Phase6DebugClipboard debugClipboard = const _SuccessfulClipboard(),
  Phase6NativePictureObserver nativePictureObserver =
      const Phase6NoopNativePictureObserver(),
  Phase6ReopenGateway? reopenGateway,
  double penOpacity = 1,
  int maximumPreviewOverlays = 20000,
  int maximumPrimitives = 400000,
  int maximumDamageRegions = 400000,
  int maximumSelectionOverlays = 20000,
  double minimumInteractiveSelectionExtentViewPixels = 32,
  double selectionHandleHitSizeViewPixels = 22,
  int maximumCommittedPaintChunks = 128,
  int maximumCommittedPaintChunkObjects = 16,
  int? maximumCommittedPaintChunkPrimitives,
}) {
  final storageEntries =
      <({ResourceLimitKey key, ResourceLimitCeiling ceiling})>[];
  for (final requirement in alnoteStorageLimitRequirements.entries) {
    storageEntries.add((
      key: _ok(ResourceLimitKey.parse(requirement.key)),
      ceiling: _ok(
        ResourceLimitCeiling.create(
          value: storageCeiling,
          unit: requirement.value,
        ),
      ),
    ));
  }
  final handwritingLimits = _ok(
    HandwritingLimits.create(
      maximumStrokes: 1024,
      maximumSamplesPerStroke: maximumHandwritingSamples,
      maximumUnknownFields: 256,
      maximumNestingDepth: 32,
      maximumUnknownNodes: 100000,
      maximumCoordinateMagnitude: 1000000,
      maximumStrokeWidth: 1000,
      maximumAbsoluteTilt: 1.5707963267948966,
      maximumAbsoluteOrientation: 6.283185307179586,
    ),
  );
  return Phase6CanvasRuntime.create(
    uuidGenerator:
        uuidGenerator ??
        UuidSequenceGenerator.fromValues(
          List.generate(128, (index) => testUuid(1000 + index)),
        ),
    handwritingLimits: handwritingLimits,
    shapeLimits: _ok(
      ShapeLimits.create(
        maximumVertices: 10000,
        maximumDashValues: 64,
        maximumUnknownFields: 256,
        maximumUnknownNodes: 100000,
        maximumNestingDepth: 32,
        maximumUnknownStringCodeUnits: 1000000,
        maximumCoordinateMagnitude: 1000000,
        maximumStrokeWidth: 1000,
        maximumMiterLimit: 100,
        maximumCornerRadius: 1000000,
        maximumDerivedSegments: 10000,
      ),
    ),
    shapeInteractionLimits: _ok(
      ShapeInteractionLimits.create(maximumChecks: 1000000),
    ),
    imageLimits: _ok(
      ImageLimits.create(
        maximumEncodedBytes: 10000000,
        maximumHeaderBytes: 1048576,
        maximumMarkers: 4096,
        maximumPixelDimension: 32768,
        maximumPixelCount: 100000000,
        maximumAlternativeTextScalars: 4096,
        maximumUnknownFields: 256,
        maximumUnknownNodes: 100000,
        maximumNestingDepth: 32,
        maximumUnknownStringCodeUnits: 1000000,
        maximumDocumentDimension: 1000000,
      ),
    ),
    textLimits: _ok(
      TextLimits.create(
        maximumParagraphs: 10000,
        maximumRunsPerParagraph: 10000,
        maximumScalarsPerRun: 1000000,
        maximumTotalScalars: 1000000,
        maximumFontFamilyScalars: 256,
        maximumLanguageHintScalars: 64,
        maximumUnknownFields: 256,
        maximumUnknownNodes: 100000,
        maximumNestingDepth: 32,
        maximumUnknownStringCodeUnits: 1000000,
        maximumFontSize: 1000,
        maximumBoxDimension: 1000000,
        maximumPadding: 100000,
        maximumLayoutLines: 100000,
        maximumLayoutFragments: 100000,
        maximumCaretStops: 1000000,
        maximumRangeRectangles: 100000,
        maximumPendingEdits: 1024,
      ),
    ),
    pdfModelLimits: _ok(
      PdfModelLimits.create(
        maximumPageCount: 10000,
        maximumCoordinateMagnitude: 1000000,
        maximumPageDimension: 1000000,
        maximumPageArea: 1000000000000,
        maximumUnknownFields: 256,
        maximumUnknownNodes: 100000,
        maximumNestingDepth: 32,
        maximumUnknownStringCodeUnits: 1000000,
      ),
    ),
    pdfProcessingLimits: pdfProcessingLimits,
    pdfBackend: pdfBackend,
    localPdfOpenWorkflow: localPdfOpenWorkflow,
    penStyle: _ok(
      StrokeStyle.create(
        argb: 0xff17324d,
        opacity: penOpacity,
        baseWidth: 3,
        pressureInfluence: .65,
        minimumPressureFactor: .2,
        limits: handwritingLimits,
      ),
    ),
    geometryLimits: _ok(
      StrokeGeometryLimits.create(
        maximumElements: maximumGeometryElements,
        maximumVertices: maximumGeometryVertices,
        ellipseVertexCount: ellipseVertexCount,
        maximumContainmentChecks: 100000,
      ),
    ),
    renderingLimits: _ok(
      RenderingLimits.create(
        maximumPrimitives: maximumPrimitives,
        maximumPointsPerPrimitive: maximumPointsPerPrimitive,
        maximumDamageRegions: maximumDamageRegions,
        maximumPreviewOverlays: maximumPreviewOverlays,
        maximumSelectionOverlays: maximumSelectionOverlays,
      ),
    ),
    historyLimits: _ok(
      HistoryLimits.create(
        maximumRetainedCommandCount: 100,
        maximumEstimatedRetainedBytes: maximumEstimatedRetainedHistoryBytes,
      ),
    ),
    storageLimits: _ok(ResourceLimitSnapshot.create(storageEntries)),
    maximumHitResults: 10000,
    maximumLassoPoints: 10000,
    maximumRenderingDefinitions: maximumRenderingDefinitions,
    maximumHitTestingDefinitions: maximumHitTestingDefinitions,
    maximumHitBehaviorResults: 10000,
    maximumTools: maximumTools,
    maximumActions: maximumActions,
    maximumBindings: maximumBindings,
    maximumSelectionTargets: 1024,
    maximumCommandOperations: maximumCommandOperations,
    maximumListeners: 16,
    maximumPenSamples: maximumPenSamples,
    maximumPenPreviewLayers: maximumPenPreviewLayers,
    maximumEraserPoints: maximumEraserPoints,
    minimumInteractiveSelectionExtentViewPixels:
        minimumInteractiveSelectionExtentViewPixels,
    selectionHandleHitSizeViewPixels: selectionHandleHitSizeViewPixels,
    maximumCommittedPaintChunks: maximumCommittedPaintChunks,
    maximumCommittedPaintChunkObjects: maximumCommittedPaintChunkObjects,
    maximumCommittedPaintChunkPrimitives:
        maximumCommittedPaintChunkPrimitives ??
        math.min(20000, maximumPrimitives),
    diagnosticTrace:
        diagnosticTrace ??
        _ok(Phase6DiagnosticTrace.create(enabled: true, capacity: 64)),
    reopenGateway: reopenGateway,
    debugClipboard: debugClipboard,
    nativePictureObserver: nativePictureObserver,
  );
}

Future<Uint8List> _canvasBytes(WidgetTester tester) async {
  return (await _canvasImage(tester)).bytes;
}

typedef _CanvasImageEvidence = ({
  Uint8List bytes,
  int width,
  int height,
  Offset origin,
});

Future<_CanvasImageEvidence> _canvasImage(WidgetTester tester) async {
  late _CanvasImageEvidence result;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('phase6-document-paint')),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData();
    result = (
      bytes: Uint8List.fromList(data!.buffer.asUint8List()),
      width: image.width,
      height: image.height,
      origin: boundary.localToGlobal(Offset.zero),
    );
    image.dispose();
  });
  return result;
}

bool _changedNear(
  _CanvasImageEvidence before,
  _CanvasImageEvidence after,
  Offset globalPoint, {
  required int radius,
}) {
  final center = globalPoint - after.origin;
  final centerX = center.dx.round();
  final centerY = center.dy.round();
  for (var y = centerY - radius; y <= centerY + radius; y += 1) {
    for (var x = centerX - radius; x <= centerX + radius; x += 1) {
      if (x < 0 || y < 0 || x >= after.width || y >= after.height) continue;
      final offset = (y * after.width + x) * 4;
      for (var channel = 0; channel < 4; channel += 1) {
        if (before.bytes[offset + channel] != after.bytes[offset + channel]) {
          return true;
        }
      }
    }
  }
  return false;
}

List<int>? _nearestChangedRgb(
  _CanvasImageEvidence before,
  _CanvasImageEvidence after,
  Offset globalPoint, {
  required int radius,
}) {
  final center = globalPoint - after.origin;
  final centerX = center.dx.round();
  final centerY = center.dy.round();
  var greatestChange = -1;
  List<int>? result;
  for (var y = centerY - radius; y <= centerY + radius; y += 1) {
    for (var x = centerX - radius; x <= centerX + radius; x += 1) {
      if (x < 0 || y < 0 || x >= after.width || y >= after.height) continue;
      final offset = (y * after.width + x) * 4;
      var change = 0;
      for (var channel = 0; channel < 4; channel += 1) {
        change +=
            (before.bytes[offset + channel] - after.bytes[offset + channel])
                .abs();
      }
      if (change <= greatestChange || change == 0) continue;
      greatestChange = change;
      result = <int>[
        after.bytes[offset],
        after.bytes[offset + 1],
        after.bytes[offset + 2],
      ];
    }
  }
  return result;
}

final class _SuccessfulClipboard implements Phase6DebugClipboard {
  const _SuccessfulClipboard();

  @override
  Future<Result<void, StructuredFailure>> copyText(String text) async =>
      const Ok(null);
}

final class _StructuredFailingClipboard implements Phase6DebugClipboard {
  const _StructuredFailingClipboard();

  @override
  Future<Result<void, StructuredFailure>> copyText(String text) async =>
      Err(_clipboardFailure());
}

final class _SynchronouslyThrowingClipboard implements Phase6DebugClipboard {
  const _SynchronouslyThrowingClipboard();

  @override
  Future<Result<void, StructuredFailure>> copyText(String text) =>
      throw StateError('secret synchronous clipboard failure');
}

final class _AsynchronouslyThrowingClipboard implements Phase6DebugClipboard {
  const _AsynchronouslyThrowingClipboard();

  @override
  Future<Result<void, StructuredFailure>> copyText(String text) async {
    await Future<void>.value();
    throw StateError('secret asynchronous clipboard failure');
  }
}

final class _PendingClipboard implements Phase6DebugClipboard {
  final Completer<Result<void, StructuredFailure>> _completer = Completer();

  @override
  Future<Result<void, StructuredFailure>> copyText(String text) =>
      _completer.future;

  void complete() => _completer.complete(const Ok(null));
}

final class _CountingPictureObserver implements Phase6NativePictureObserver {
  int created = 0;
  int disposed = 0;

  @override
  void pictureCreated() => created += 1;

  @override
  void pictureDisposed() => disposed += 1;
}

StructuredFailure _clipboardFailure() => StructuredFailure(
  code: 'test.clipboard.unavailable',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Clipboard unavailable.',
);

String _canvasPainterDescription(WidgetTester tester) => tester
    .widget<CustomPaint>(find.byKey(const Key('phase6-overlay-paint')))
    .painter
    .toString();

Phase6CanvasPersistenceEvidence _canvasPainter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(find.byKey(const Key('phase6-overlay-paint')))
            .painter
        as Phase6CanvasPersistenceEvidence;

Phase6CanvasPersistenceEvidence _documentPainter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byKey(const Key('phase6-committed-paint')),
            )
            .painter
        as Phase6CanvasPersistenceEvidence;

Phase6PenPreviewEvidence _penPreview(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(find.byKey(const Key('phase6-pen-preview')))
            .painter
        as Phase6PenPreviewEvidence;

Phase6PenCursorEvidence _penCursor(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(find.byKey(const Key('phase6-pen-cursor')))
            .painter
        as Phase6PenCursorEvidence;

Offset _textObjectCenterGlobal(
  WidgetTester tester,
  Phase6CanvasRuntime runtime,
  ObjectEnvelope object,
) {
  final payload = _ok(
    TextPayload.decode(object.payload, limits: runtime.textLimits),
  );
  final pageCenter = _ok(
    object.transform.applyToPoint(
      _ok(
        Point2.create(
          x: payload.intrinsicWidth / 2,
          y: payload.intrinsicHeight! / 2,
        ),
      ),
    ),
  );
  final clip = _canvasPainter(tester).pageClip!;
  return tester.getTopLeft(find.byKey(const Key('phase6-canvas-listener'))) +
      Offset(clip.left + pageCenter.x, clip.top + pageCenter.y);
}

int _objectCount(Phase6CanvasRuntime runtime) => runtime
    .initialCoordinator
    .snapshot
    .root
    .pages
    .expand((page) => page.layers)
    .expand((layer) => layer.objects)
    .length;

final class _FailingReopenGateway implements Phase6ReopenGateway {
  const _FailingReopenGateway(this.stage);
  final Phase6ReopenFailureStage stage;

  @override
  Phase6ReopenOutcome reopen({
    required List<int> bytes,
    required DocumentRoot savedRoot,
  }) => Phase6ReopenFailure(stage);
}

enum _PreviewFailureMode {
  missing,
  returnedError,
  thrown,
  committedPlane,
  selectionPlane,
  overLimit,
  partial,
}

final class _FailingTextLayoutEngine implements TextLayoutEngine {
  _FailingTextLayoutEngine({
    required this.throws,
    this.delegate,
    this.successfulCallsBeforeFailure = 0,
  });
  final bool throws;
  final TextLayoutEngine? delegate;
  final int successfulCallsBeforeFailure;
  int calls = 0;

  @override
  Result<TextLayoutSnapshot, StructuredFailure> layout(
    TextLayoutRequest request,
  ) {
    calls += 1;
    if (calls <= successfulCallsBeforeFailure && delegate != null) {
      return delegate!.layout(request);
    }
    if (throws) throw StateError('SECRET-layout-error');
    return Err(
      StructuredFailure(
        code: 'test.text.layout_failure',
        category: FailureCategory.dependency,
        retryDisposition: RetryDisposition.never,
        message: 'SECRET-layout-error',
      ),
    );
  }
}

final class _AdversarialPreviewRenderer implements ObjectRenderingDefinition {
  _AdversarialPreviewRenderer(this.delegate, this.mode);

  final ObjectRenderingDefinition delegate;
  final _PreviewFailureMode mode;
  int calls = 0;

  @override
  ObjectTypeKey get typeKey => delegate.typeKey;

  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    calls += 1;
    if (mode == _PreviewFailureMode.thrown) {
      throw StateError('SECRET-renderer-error');
    }
    if (mode == _PreviewFailureMode.returnedError ||
        (mode == _PreviewFailureMode.partial && calls > 1)) {
      return Err(
        StructuredFailure(
          code: 'test.preview.failure',
          category: FailureCategory.dependency,
          retryDisposition: RetryDisposition.never,
          message: 'SECRET-renderer-error',
        ),
      );
    }
    final rendered = delegate.render(
      object: object,
      viewport: viewport,
      layerOpacity: layerOpacity,
      plane: plane,
      limits: limits,
    );
    final wrongPlane = switch (mode) {
      _PreviewFailureMode.committedPlane => RenderPlane.committed,
      _PreviewFailureMode.selectionPlane => RenderPlane.selection,
      _ => null,
    };
    if (wrongPlane != null &&
        rendered is Ok<List<ScenePrimitive>, StructuredFailure> &&
        rendered.value.isNotEmpty) {
      final malformed = PlaceholderPrimitive.create(
        plane: wrongPlane,
        bounds: rendered.value.first.bounds,
        opacity: 1,
      );
      return malformed is Ok<PlaceholderPrimitive, StructuredFailure>
          ? Ok([malformed.value])
          : Err(
              StructuredFailure(
                code: 'test.preview.malformed',
                category: FailureCategory.validation,
                retryDisposition: RetryDisposition.never,
                message: 'SECRET-renderer-error',
              ),
            );
    }
    if (mode != _PreviewFailureMode.overLimit ||
        rendered is! Ok<List<ScenePrimitive>, StructuredFailure> ||
        rendered.value.isEmpty) {
      return rendered;
    }
    return Ok(List.filled(3, rendered.value.first));
  }
}

final class _RuntimeCountingUuidGenerator implements UuidGenerator {
  int calls = 0;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    calls += 1;
    return Ok(testUuid(5000 + calls));
  }
}

final class _ToggleRuntimeUuidGenerator implements UuidGenerator {
  int calls = 0;
  bool throwNow = false;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    calls += 1;
    if (throwNow) throw StateError('SECRET-callback-error');
    return Ok(testUuid(7000 + calls));
  }
}

T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;

final class _PendingWidgetPdfPicker implements LocalPdfPickerHost {
  final done = Completer<LocalPdfFileHandle?>();
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) => done.future;
}
