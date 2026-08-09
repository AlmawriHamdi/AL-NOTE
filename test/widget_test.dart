// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;

import 'package:al_note/app/al_note_app.dart';
import 'package:al_note/core/interaction.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/renderer.dart';
import 'package:al_note/ui/canvas/phase6_canvas.dart';
import 'package:al_note/ui/canvas/phase6_canvas_runtime.dart';
import 'package:al_note/ui/canvas/phase6_diagnostics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/document_model_test_support.dart';
import 'support/uuid_sequence_generator.dart';

/// Verifies the accessible Phase 6 Canvas shell and pointer route.
void main() {
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
    await tester.tap(find.text('partialEraser'));
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
    expect(copied, contains('phase6_cursor_summary'));
    expect(copied, contains('phase6_publication_summary'));

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

  testWidgets(
    'rapid Partial Eraser input paints only the newest cursor frame',
    (WidgetTester tester) async {
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
      );
      final runtime = _ok(
        _runtimeResult(
          diagnosticTrace: trace,
          maximumEraserBatchClassificationChecks: 64,
          maximumEraserBatchRootIsolationAdvances: 64,
          maximumEraserBatchFeatureTransitions: 2048,
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      for (var index = 0; index < 9; index += 1) {
        final stroke = await tester.startGesture(
          center + Offset(-80, -40 + index * 10),
          kind: PointerDeviceKind.mouse,
        );
        await stroke.moveBy(const Offset(160, 0));
        await stroke.up();
        await tester.pump();
      }
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final topLeft = tester.getTopLeft(canvas);
      final documentRevision =
          runtime.initialCoordinator.snapshot.revisions.document;
      final gesture = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      Offset latest = center;
      for (var index = 0; index < 877; index += 1) {
        latest =
            center + Offset((index % 80).toDouble(), index.isEven ? 3 : -3);
        await gesture.moveTo(latest);
      }
      expect(_canvasPainter(tester).partialSegmentCount, 0);
      expect(_canvasPainter(tester).eraserPathLength, 0);

      await tester.pump();
      final cursorPaint = tester.widget<CustomPaint>(
        find.byKey(const Key('phase6-eraser-cursor')),
      );
      final cursor = cursorPaint.painter! as Phase6EraserCursorEvidence;
      expect(
        cursor.cursorPosition,
        _ok(
          ViewPoint.create(
            x: latest.dx - topLeft.dx,
            y: latest.dy - topLeft.dy,
          ),
        ),
      );
      final cursorEvent = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.cursorRepaintCompleted,
      );
      expect(cursorEvent.rawPointerEvents, 878);
      expect(cursorEvent.cursorRepaintRequests, 878);
      expect(cursorEvent.cursorRepaints, 1);
      expect(cursorEvent.processingBatches, 0);
      final visualPaint = tester.widget<CustomPaint>(
        find.byKey(const Key('phase6-visual-eraser')),
      );
      final visual = visualPaint.painter! as Phase6VisualEraserEvidence;
      expect(visual.visualSegmentCount, 878);
      expect(visual.visualChunkCount, lessThanOrEqualTo(16));
      final visualEvent = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.visualPreviewCompleted,
      );
      expect(visualEvent.visualPathSegments, 878);
      expect(visualEvent.visualPreviewRequests, 878);
      expect(visualEvent.visualPreviewRepaints, 1);
      expect(visualEvent.processingBatches, 0);
      expect(visualEvent.exactProcessingBacklog, 878);
      expect(visualEvent.candidateObjects, 9);
      expect(visualEvent.pointerMoveExactClassifications, 0);
      expect(visualEvent.classifications, 0);
      expect(visualEvent.classificationChecks, 0);

      await gesture.up();
      await tester.pump();
      expect(find.text('Finishing partial erase'), findsOneWidget);
      var exactFrames = 0;
      while (find.text('Finishing partial erase').evaluate().isNotEmpty &&
          exactFrames < 5000) {
        await _pumpCooperativeTask(tester);
        exactFrames += 1;
        final batches = trace.events.where(
          (event) =>
              event.stage == Phase6DiagnosticStage.intervalClassification,
        );
        if (batches.isNotEmpty) {
          expect(batches.last.predicateStepsPerFrame, lessThanOrEqualTo(64));
          expect(
            batches.last.rootIsolationStepsPerFrame,
            lessThanOrEqualTo(64),
          );
          expect(batches.last.callbackWork, lessThanOrEqualTo(2224));
        }
      }
      expect(exactFrames, greaterThan(1));
      expect(exactFrames, lessThan(600));
      expect(find.text('Stroke partially erased'), findsOneWidget);
      expect(
        runtime.initialCoordinator.snapshot.revisions.document.value,
        documentRevision.value + 1,
      );
      final terminal = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.terminalSummary,
      );
      expect(exactFrames, lessThanOrEqualTo(terminal.classificationChecks));
      expect(terminal.maximumCallbackWork, greaterThan(2));
      final cleared = tester.widget<CustomPaint>(
        find.byKey(const Key('phase6-eraser-cursor')),
      );
      expect(
        (cleared.painter! as Phase6EraserCursorEvidence).cursorPosition,
        isNull,
      );
    },
  );

  testWidgets('Partial Eraser admits the exact ceiling before visual append', (
    WidgetTester tester,
  ) async {
    final ids = _RuntimeCountingUuidGenerator();
    final observer = _CountingPictureObserver();
    final runtime = _runtime(
      uuidGenerator: ids,
      maximumEraserPoints: 193,
      maximumEraserVisualPictures: 2,
      nativePictureObserver: observer,
    );
    final initialCalls = ids.calls;
    final initialRevision =
        runtime.initialCoordinator.snapshot.revisions.document;
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    await tester.tap(find.text('partialEraser'));
    await tester.pump();
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final gesture = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 0; index < 192; index += 1) {
      await gesture.moveBy(const Offset(.25, 0));
    }
    await tester.pump();
    final visual =
        tester
                .widget<CustomPaint>(
                  find.byKey(const Key('phase6-visual-eraser')),
                )
                .painter!
            as Phase6VisualEraserEvidence;
    expect(visual.visualSegmentCount, 193);
    expect(visual.visualChunkCount, 2);
    final createdAtCeiling = observer.created;

    await gesture.moveBy(const Offset(.25, 0));
    await tester.pump();
    expect(find.text('Partial erase rejected'), findsOneWidget);
    expect(find.byKey(const Key('phase6-visual-eraser')), findsNothing);
    expect(observer.created, createdAtCeiling);
    expect(observer.created, observer.disposed);
    expect(ids.calls, initialCalls);
    expect(
      runtime.initialCoordinator.snapshot.revisions.document,
      initialRevision,
    );
    await gesture.cancel();
  });

  testWidgets(
    '51-point four-Object finalization consumes practical bounded slices',
    (WidgetTester tester) async {
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
      );
      final runtime = _ok(
        _runtimeResult(
          diagnosticTrace: trace,
          maximumEraserBatchClassificationChecks: 64,
          maximumEraserBatchRootIsolationAdvances: 64,
          maximumEraserBatchFeatureTransitions: 2048,
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      for (var object = 0; object < 4; object += 1) {
        final pen = await tester.startGesture(
          center + Offset(-75, object * 30),
          kind: PointerDeviceKind.mouse,
        );
        for (var segment = 0; segment < 15; segment += 1) {
          await pen.moveBy(const Offset(10, 0));
        }
        await pen.up();
        await tester.pump();
      }
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final erase = await tester.startGesture(
        center - const Offset(75, 0),
        kind: PointerDeviceKind.mouse,
      );
      for (var point = 0; point < 15; point += 1) {
        await erase.moveBy(const Offset(10, 0));
      }
      for (var point = 15; point < 50; point += 1) {
        await erase.moveBy(const Offset(0, -3));
      }
      await tester.pump();
      final moveEvidence = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.visualPreviewCompleted,
      );
      expect(moveEvidence.visualPathSegments, 51);
      expect(moveEvidence.candidateObjects, 4);
      expect(moveEvidence.pointerMoveExactClassifications, 0);
      expect(moveEvidence.classificationChecks, 0);

      await erase.up();
      await tester.pump();
      var callbacks = 0;
      var lastSequence = -1;
      var maximumWork = 0;
      while (find.text('Finishing partial erase').evaluate().isNotEmpty &&
          callbacks < 100) {
        expect(
          find.byKey(const Key('phase6-visual-eraser')).evaluate().isNotEmpty ||
              find
                  .byKey(const Key('phase6-terminal-eraser-preview'))
                  .evaluate()
                  .isNotEmpty,
          isTrue,
        );
        await _pumpCooperativeTask(tester);
        final batches = trace.events.where(
          (event) =>
              event.stage == Phase6DiagnosticStage.intervalClassification &&
              event.sequence > lastSequence,
        );
        if (batches.isNotEmpty) {
          final batch = batches.last;
          lastSequence = batch.sequence;
          callbacks += 1;
          maximumWork = math.max(maximumWork, batch.callbackWork);
          expect(batch.predicateStepsPerFrame, lessThanOrEqualTo(64));
          expect(batch.rootIsolationStepsPerFrame, lessThanOrEqualTo(64));
          expect(batch.callbackWork, lessThanOrEqualTo(2224));
        }
      }
      expect(find.text('Stroke partially erased'), findsOneWidget);
      expect(callbacks, greaterThan(0));
      expect(callbacks, lessThan(100));
      expect(maximumWork, greaterThan(2));
      final terminal = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.terminalSummary,
      );
      expect(terminal.classifications, inInclusiveRange(10, 120));
      expect(terminal.exactFinalizationFrames, lessThan(64));
      expect(terminal.candidateResumptions, lessThan(64));
      expect(terminal.classificationChecks, lessThanOrEqualTo(2000000));
      expect(terminal.terminalMaterializations, 1);
      expect(terminal.publications, 1);
      expect(terminal.maximumCallbackWork, lessThanOrEqualTo(2224));
      expect(
        terminal.totalCallbackWork,
        greaterThan(terminal.maximumCallbackWork),
      );
    },
  );

  testWidgets(
    'Undo queued during Partial finalization targets the new history entry',
    (WidgetTester tester) async {
      final ids = _RuntimeCountingUuidGenerator();
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
      );
      final runtime = _ok(
        _runtimeResult(
          uuidGenerator: ids,
          diagnosticTrace: trace,
          maximumEraserBatchCandidateSegments: 1,
          maximumEraserBatchClassifications: 1,
          maximumEraserBatchClassificationChecks: 1,
          maximumEraserBatchRootIsolationAdvances: 1,
          maximumEraserBatchFeatureTransitions: 32,
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final pen = await tester.startGesture(
        center - const Offset(80, 0),
        kind: PointerDeviceKind.mouse,
      );
      await pen.moveBy(const Offset(160, 0));
      await pen.up();
      await tester.pump();
      final preEraseRoot = runtime.initialCoordinator.snapshot.root;
      final historyBefore = runtime.initialCoordinator.retainedHistoryCount;

      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final erase = await tester.startGesture(
        center - const Offset(0, 20),
        kind: PointerDeviceKind.mouse,
      );
      await erase.moveBy(const Offset(0, 40));
      await erase.up();
      await tester.pump();
      expect(find.text('Finishing partial erase'), findsOneWidget);

      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(find.text('Undo queued after partial erase'), findsOneWidget);
      expect(runtime.initialCoordinator.snapshot.root, same(preEraseRoot));
      final queuedRecorded = trace.events.any(
        (event) =>
            event.stage ==
                Phase6DiagnosticStage.historyRequestDuringFinalization &&
            event.historyDisposition ==
                Phase6DiagnosticHistoryDisposition.queued,
      );

      var frames = 0;
      while (find
              .text('Partial erase completed and undone')
              .evaluate()
              .isEmpty &&
          frames < 1000) {
        await _pumpCooperativeTask(tester);
        frames += 1;
      }
      expect(frames, lessThan(1000));
      expect(runtime.initialCoordinator.snapshot.root, same(preEraseRoot));
      expect(
        runtime.initialCoordinator.retainedHistoryCount,
        historyBefore + 1,
      );
      expect(runtime.initialCoordinator.snapshot.canRedo, isTrue);
      final callsAfterFinalization = ids.calls;

      await tester.tap(find.byTooltip('Redo'));
      await tester.pump();
      expect(find.text('Redone'), findsOneWidget);
      final postEraseRoot = runtime.initialCoordinator.snapshot.root;
      expect(postEraseRoot, isNot(same(preEraseRoot)));
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(preEraseRoot));
      await tester.tap(find.byTooltip('Redo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(postEraseRoot));
      expect(ids.calls, callsAfterFinalization);

      final executed = trace.events.where(
        (event) =>
            event.stage == Phase6DiagnosticStage.historyRequestExecuted &&
            event.historyDisposition ==
                Phase6DiagnosticHistoryDisposition.executed,
      );
      expect(queuedRecorded, isTrue);
      expect(executed, isNotEmpty);
      expect(executed.last.terminalMaterializations, 1);
      expect(executed.last.publications, 1);
      expect(executed.last.historyDepthAfterPublication, historyBefore + 1);
    },
  );

  testWidgets(
    '208-point multi-Object Partial finalizes with analytic bounded work',
    (WidgetTester tester) async {
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
      );
      final runtime = _ok(
        _runtimeResult(
          diagnosticTrace: trace,
          maximumEraserBatchClassificationChecks: 64,
          maximumEraserBatchRootIsolationAdvances: 64,
          maximumEraserBatchFeatureTransitions: 2048,
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      for (var object = 0; object < 10; object += 1) {
        final pen = await tester.startGesture(
          center + Offset(-90, -45 + object * 10),
          kind: PointerDeviceKind.mouse,
        );
        await pen.moveBy(const Offset(180, 0));
        await pen.up();
        await tester.pump();
      }
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot.root;
      final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
      final erase = await tester.startGesture(
        center - const Offset(85, 5),
        kind: PointerDeviceKind.mouse,
      );
      for (var point = 1; point < 208; point += 1) {
        await erase.moveTo(
          center + Offset(-85 + point * .8, point.isEven ? -5 : 5),
        );
      }
      await tester.pump();
      expect(
        trace.events
            .lastWhere(
              (event) =>
                  event.stage == Phase6DiagnosticStage.visualPreviewCompleted,
            )
            .pointerMoveExactClassifications,
        0,
      );
      await erase.up();
      await tester.pump();
      var callbacks = 0;
      while (find.text('Finishing partial erase').evaluate().isNotEmpty &&
          callbacks < 100) {
        expect(
          find.byKey(const Key('phase6-visual-eraser')).evaluate().isNotEmpty ||
              find
                  .byKey(const Key('phase6-terminal-eraser-preview'))
                  .evaluate()
                  .isNotEmpty,
          isTrue,
        );
        await _pumpCooperativeTask(tester);
        callbacks += 1;
      }
      await tester.pump();
      expect(find.text('Stroke partially erased'), findsOneWidget);
      final terminal = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.terminalSummary,
      );
      expect(callbacks, lessThan(100));
      expect(terminal.exactFinalizationFrames, lessThan(100));
      expect(terminal.candidateResumptions, lessThan(100));
      expect(terminal.classifications, inInclusiveRange(200, 700));
      expect(terminal.aggregateFeatureTransitions, lessThan(50000));
      expect(terminal.maximumCallbackWork, lessThanOrEqualTo(2224));
      expect(terminal.ordinaryAnalyticClassifications, greaterThan(0));
      expect(
        terminal.exactFallbackClassifications,
        lessThan(terminal.ordinaryAnalyticClassifications),
      );
      expect(terminal.exactFallbackExhaustions, 0);
      expect(terminal.terminalMaterializations, 1);
      expect(terminal.publications, 1);
      expect(
        runtime.initialCoordinator.retainedHistoryCount,
        historyBefore + 1,
      );
      final after = runtime.initialCoordinator.snapshot.root;
      expect(after, isNot(same(before)));

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(after));
    },
  );

  testWidgets(
    'Ctrl+Z and controls share the Partial finalization history gate',
    (WidgetTester tester) async {
      final runtime = _runtime(
        maximumEraserBatchCandidateSegments: 1,
        maximumEraserBatchClassifications: 1,
        maximumEraserBatchClassificationChecks: 1,
        maximumEraserBatchRootIsolationAdvances: 1,
        maximumEraserBatchFeatureTransitions: 32,
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final pen = await tester.startGesture(
        center - const Offset(60, 0),
        kind: PointerDeviceKind.mouse,
      );
      await pen.moveBy(const Offset(120, 0));
      await pen.up();
      await tester.pump();
      final preEraseRoot = runtime.initialCoordinator.snapshot.root;

      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final erase = await tester.startGesture(
        center - const Offset(0, 16),
        kind: PointerDeviceKind.mouse,
      );
      await erase.moveBy(const Offset(0, 32));
      await erase.up();
      await tester.pump();
      expect(find.text('Finishing partial erase'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Undo'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Redo'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Save in memory'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widgetList<ChoiceChip>(find.byType(ChoiceChip))
            .every((chip) => chip.onSelected == null),
        isTrue,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Undo queued after partial erase'), findsOneWidget);
      expect(runtime.initialCoordinator.snapshot.root, same(preEraseRoot));

      final competing = await tester.startGesture(
        center + const Offset(30, 30),
        kind: PointerDeviceKind.mouse,
      );
      await competing.moveBy(const Offset(20, 0));
      await competing.up();
      var frames = 0;
      while (find
              .text('Partial erase completed and undone')
              .evaluate()
              .isEmpty &&
          frames < 1000) {
        await _pumpCooperativeTask(tester);
        frames += 1;
      }
      expect(frames, lessThan(1000));
      expect(runtime.initialCoordinator.snapshot.root, same(preEraseRoot));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Redone'), findsOneWidget);
      expect(
        runtime.initialCoordinator.snapshot.root,
        isNot(same(preEraseRoot)),
      );
    },
  );

  testWidgets(
    '701-point active Partial scheduler amortizes exact backlog after paint',
    (WidgetTester tester) async {
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
      );
      final runtime = _ok(
        _runtimeResult(
          diagnosticTrace: trace,
          maximumEraserBatchClassificationChecks: 64,
          maximumEraserBatchRootIsolationAdvances: 64,
          maximumEraserBatchFeatureTransitions: 2048,
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final probe = await tester.startGesture(
        center - const Offset(80, 0),
        kind: PointerDeviceKind.mouse,
      );
      await probe.moveTo(center + const Offset(80, 0));
      await probe.up();
      await tester.pump();
      final probeObject = runtime
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
      final probeStroke = _ok(
        HandwritingPayload.decode(
          probeObject.payload,
          limits: runtime.handwritingLimits,
        ),
      ).strokes.single;
      final anchor = _ok(
        Point2.create(
          x:
              (probeStroke.samples.first.position.x +
                  probeStroke.samples.last.position.x) /
              2,
          y:
              (probeStroke.samples.first.position.y +
                  probeStroke.samples.last.position.y) /
              2,
        ),
      );
      _seedPartialSchedulerDocument(
        runtime,
        anchor: anchor,
        removal: probeObject.id,
      );
      await tester.pump();
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot.root;
      final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
      final erase = await tester.startGesture(
        center - const Offset(95, 120),
        kind: PointerDeviceKind.mouse,
      );
      Offset pointOffset(int point) {
        final progress = point % 175;
        final sweep = point ~/ 175;
        final x = -95.0 + progress * 1.08;
        final y =
            [-120.0, -80.0, -20.0, 20.0][sweep] + (point % 4 == 0 ? .75 : 0);
        return Offset(x, y);
      }

      for (var point = 1; point <= 4; point += 1) {
        await erase.moveTo(center + pointOffset(point));
      }
      expect(
        trace.events.where(
          (event) =>
              event.stage == Phase6DiagnosticStage.intervalClassification,
        ),
        isEmpty,
      );
      await tester.pump();
      final firstVisual = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.visualPreviewCompleted,
      );
      final firstActiveExact = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.intervalClassification,
      );
      expect(firstVisual.sequence, lessThan(firstActiveExact.sequence));

      for (var point = 5; point < 700; point += 1) {
        await erase.moveTo(center + pointOffset(point));
        if (point % 4 == 0) await tester.pump();
      }
      final active = trace.events.last;
      expect(active.pointerMoveExactClassifications, 0);
      expect(active.activeExactCallbacks, greaterThan(0));
      expect(active.activeExactWork, greaterThan(0));
      expect(active.authoritativeExactPoints, lessThan(active.rawVisualPoints));
      expect(active.exactProcessingBacklog, lessThan(80));

      await erase.up();
      await tester.pump();
      var finalizationCallbacks = 0;
      while (find.text('Finishing partial erase').evaluate().isNotEmpty &&
          finalizationCallbacks < 80) {
        await _pumpCooperativeTask(tester);
        finalizationCallbacks += 1;
      }
      expect(find.text('Stroke partially erased'), findsOneWidget);
      final terminal = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.terminalSummary,
      );
      expect(terminal.rawVisualPoints, 701);
      expect(terminal.authoritativeExactPoints, lessThan(701));
      expect(terminal.activeExactCallbacks, greaterThan(0));
      expect(
        terminal.activeExactWork,
        greaterThan(terminal.postReleaseExactWork),
      );
      expect(terminal.backlogAtPointerUp, lessThan(80));
      expect(terminal.exactFinalizationFrames, lessThan(80));
      expect(terminal.candidateResumptions, lessThan(160));
      expect(terminal.classifications, inInclusiveRange(400, 650));
      expect(terminal.maximumCallbackWork, lessThanOrEqualTo(2224));
      expect(terminal.terminalMaterializations, 1);
      expect(terminal.publications, 1);
      expect(
        runtime.initialCoordinator.retainedHistoryCount,
        historyBefore + 1,
      );
      final after = runtime.initialCoordinator.snapshot.root;

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(after));
    },
  );

  testWidgets(
    'continuous Partial drains through cooperative tasks without frame gating',
    (WidgetTester tester) async {
      final scheduler = _ManualCooperativeTaskScheduler();
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
      );
      final runtime = _ok(
        _runtimeResult(
          diagnosticTrace: trace,
          cooperativeTaskScheduler: scheduler,
          maximumEraserBatchClassificationChecks: 64,
          maximumEraserBatchRootIsolationAdvances: 64,
          maximumEraserBatchFeatureTransitions: 2048,
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final probe = await tester.startGesture(
        center - const Offset(80, 0),
        kind: PointerDeviceKind.mouse,
      );
      await probe.moveTo(center + const Offset(80, 0));
      await probe.up();
      await tester.pump();
      final probeObject = runtime
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
      final probeStroke = _ok(
        HandwritingPayload.decode(
          probeObject.payload,
          limits: runtime.handwritingLimits,
        ),
      ).strokes.single;
      final anchor = _ok(
        Point2.create(
          x:
              (probeStroke.samples.first.position.x +
                  probeStroke.samples.last.position.x) /
              2,
          y:
              (probeStroke.samples.first.position.y +
                  probeStroke.samples.last.position.y) /
              2,
        ),
      );
      _seedContinuousPartialSchedulerDocument(
        runtime,
        anchor: anchor,
        removal: probeObject.id,
      );
      await tester.pump();
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot.root;

      Offset pointOffset(int point) {
        final progress = point % 112;
        final sweep = point ~/ 112;
        return Offset(
          -100 + progress * 1.8,
          [-58.5, -22.5, 13.5, 49.5][sweep] +
              switch (point % 4) {
                0 => .45,
                2 => -.45,
                _ => 0,
              },
        );
      }

      final erase = await tester.startGesture(
        center + pointOffset(0),
        kind: PointerDeviceKind.mouse,
      );
      for (var point = 1; point <= 4; point += 1) {
        await erase.moveTo(center + pointOffset(point));
      }
      expect(
        trace.events.where(
          (event) =>
              event.stage == Phase6DiagnosticStage.intervalClassification,
        ),
        isEmpty,
      );
      await tester.pump();
      final firstVisual = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.visualPreviewCompleted,
      );
      final firstExact = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.intervalClassification,
      );
      expect(firstVisual.sequence, lessThan(firstExact.sequence));
      for (var point = 5; point < 447; point += 1) {
        await erase.moveTo(center + pointOffset(point));
        if (point % 8 == 0) await tester.pump();
      }
      expect(trace.events.last.pointerMoveExactClassifications, 0);
      await erase.up();
      expect(scheduler.pendingTaskCount, 0);
      await tester.pump();
      expect(find.text('Finishing partial erase'), findsOneWidget);
      expect(find.byKey(const Key('phase6-visual-eraser')), findsOneWidget);
      expect(scheduler.pendingTaskCount, 1);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.text('Undo queued after partial erase'), findsOneWidget);
      expect(runtime.initialCoordinator.snapshot.root, same(before));

      var cooperativeTasks = 0;
      while (scheduler.pendingTaskCount > 0 && cooperativeTasks < 120) {
        scheduler.runNext();
        cooperativeTasks += 1;
        await tester.pump();
      }
      await tester.pump();
      expect(cooperativeTasks, lessThan(120));
      expect(find.text('Partial erase completed and undone'), findsOneWidget);
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      final terminal = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.terminalSummary,
      );
      expect(terminal.rawVisualPoints, 448);
      expect(terminal.authoritativeExactPoints, inInclusiveRange(300, 448));
      expect(terminal.pointerMoveExactClassifications, 0);
      expect(terminal.postReleaseAnimationFrameWaits, 1);
      expect(terminal.postReleaseCooperativeTasks, cooperativeTasks);
      expect(terminal.postReleaseCooperativeTasks, lessThan(120));
      expect(terminal.postReleaseEventLoopYields, cooperativeTasks);
      expect(terminal.candidateResumptions, lessThan(180));
      expect(terminal.classifications, inInclusiveRange(500, 1500));
      expect(terminal.indexPreparations, 15);
      expect(terminal.candidateIndexScans, greaterThan(0));
      expect(terminal.replayedExactWork, 0);
      expect(terminal.maximumCallbackWork, lessThanOrEqualTo(2224));
      expect(terminal.terminalMaterializations, 1);
      expect(terminal.publications, 1);
      await tester.tap(find.text('Redo'));
      await tester.pump();
      final after = runtime.initialCoordinator.snapshot.root;
      expect(after, isNot(same(before)));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(before));
      await tester.tap(find.text('Redo'));
      await tester.pump();
      expect(runtime.initialCoordinator.snapshot.root, same(after));

      final beforeCancellation = runtime.initialCoordinator.snapshot.root;
      final historyBeforeCancellation =
          runtime.initialCoordinator.retainedHistoryCount;
      final cancelled = await tester.startGesture(
        center + pointOffset(0),
        kind: PointerDeviceKind.mouse,
      );
      for (var point = 1; point < 447; point += 1) {
        await cancelled.moveTo(center + pointOffset(point));
      }
      await cancelled.up();
      await tester.pump();
      expect(scheduler.pendingTaskCount, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      scheduler.runAll();
      await tester.pump();
      expect(
        runtime.initialCoordinator.snapshot.root,
        same(beforeCancellation),
      );
      expect(
        runtime.initialCoordinator.retainedHistoryCount,
        historyBeforeCancellation,
      );
      expect(scheduler.pendingTaskCount, 0);
    },
  );

  testWidgets(
    'terminal cancellation and disposal invalidate stale Partial callbacks',
    (WidgetTester tester) async {
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
      );
      final runtime = _ok(
        _runtimeResult(
          diagnosticTrace: trace,
          maximumEraserBatchCandidateSegments: 1,
          maximumEraserBatchClassifications: 1,
          maximumEraserBatchClassificationChecks: 1,
          maximumEraserBatchRootIsolationAdvances: 1,
          maximumEraserBatchFeatureTransitions: 32,
        ),
      );
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      final pen = await tester.startGesture(
        center - const Offset(50, 0),
        kind: PointerDeviceKind.mouse,
      );
      await pen.moveBy(const Offset(100, 0));
      await pen.up();
      await tester.pump();
      final before = runtime.initialCoordinator.snapshot;
      final historyBefore = runtime.initialCoordinator.retainedHistoryCount;
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final erase = await tester.startGesture(
        center - const Offset(0, 12),
        kind: PointerDeviceKind.mouse,
      );
      await erase.moveBy(const Offset(0, 24));
      await erase.up();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Cancelled'), findsOneWidget);
      for (var frame = 0; frame < 200; frame += 1) {
        await tester.pump();
      }
      expect(runtime.initialCoordinator.snapshot.root, same(before.root));
      expect(runtime.initialCoordinator.retainedHistoryCount, historyBefore);
      final cancelled = trace.events.lastWhere(
        (event) => event.stage == Phase6DiagnosticStage.gestureCancelled,
      );
      expect(
        cancelled.cancellationReason,
        Phase6DiagnosticCancellationReason.explicitUserRequest,
      );
      expect(cancelled.terminalMaterializations, 0);
      expect(cancelled.publications, 0);

      final disposalRuntime = _runtime(
        maximumEraserBatchCandidateSegments: 1,
        maximumEraserBatchClassifications: 1,
        maximumEraserBatchClassificationChecks: 1,
        maximumEraserBatchRootIsolationAdvances: 1,
        maximumEraserBatchFeatureTransitions: 32,
      );
      await tester.pumpWidget(AlNoteApp(runtime: disposalRuntime));
      final disposalCanvas = find.bySemanticsLabel('Handwriting canvas');
      final disposalCenter = tester.getCenter(disposalCanvas);
      final disposalPen = await tester.startGesture(
        disposalCenter - const Offset(50, 0),
        kind: PointerDeviceKind.mouse,
      );
      await disposalPen.moveBy(const Offset(100, 0));
      await disposalPen.up();
      await tester.pump();
      final disposalBefore = disposalRuntime.initialCoordinator.snapshot;
      final disposalHistory =
          disposalRuntime.initialCoordinator.retainedHistoryCount;
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final disposalErase = await tester.startGesture(
        disposalCenter - const Offset(0, 12),
        kind: PointerDeviceKind.mouse,
      );
      await disposalErase.moveBy(const Offset(0, 24));
      await disposalErase.up();
      await tester.pumpWidget(const SizedBox.shrink());
      for (var frame = 0; frame < 200; frame += 1) {
        await tester.pump();
      }
      expect(
        disposalRuntime.initialCoordinator.snapshot.root,
        same(disposalBefore.root),
      );
      expect(
        disposalRuntime.initialCoordinator.retainedHistoryCount,
        disposalHistory,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Canvas disposal releases Pen and Partial Eraser pictures', (
    WidgetTester tester,
  ) async {
    final penObserver = _CountingPictureObserver();
    final penRuntime = _runtime(nativePictureObserver: penObserver);
    await tester.pumpWidget(AlNoteApp(runtime: penRuntime));
    var canvas = find.bySemanticsLabel('Handwriting canvas');
    final pen = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 0; index < 180; index += 1) {
      await pen.moveBy(const Offset(1, 0));
    }
    expect(penObserver.created, greaterThan(penObserver.disposed));
    final penRevision =
        penRuntime.initialCoordinator.snapshot.revisions.document;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(penObserver.created, penObserver.disposed);
    expect(
      penRuntime.initialCoordinator.snapshot.revisions.document,
      penRevision,
    );
    expect(tester.takeException(), isNull);

    final eraserObserver = _CountingPictureObserver();
    final eraserRuntime = _runtime(nativePictureObserver: eraserObserver);
    await tester.pumpWidget(AlNoteApp(runtime: eraserRuntime));
    await tester.tap(find.text('partialEraser'));
    await tester.pump();
    canvas = find.bySemanticsLabel('Handwriting canvas');
    final eraser = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 0; index < 130; index += 1) {
      await eraser.moveBy(const Offset(.5, 0));
    }
    expect(eraserObserver.created, greaterThan(eraserObserver.disposed));
    final eraserRevision =
        eraserRuntime.initialCoordinator.snapshot.revisions.document;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(eraserObserver.created, eraserObserver.disposed);
    expect(
      eraserRuntime.initialCoordinator.snapshot.revisions.document,
      eraserRevision,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders Phase 6 controls and commits pointer handwriting', (
    final WidgetTester tester,
  ) async {
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.text('AL NOTE'), findsOneWidget);
    expect(find.text('pen'), findsOneWidget);
    expect(find.text('wholeEraser'), findsOneWidget);
    expect(find.text('partialEraser'), findsOneWidget);
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
      find.text('Stroke selected'),
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

  testWidgets('partial Eraser is reachable through a real gesture', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final draw = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await draw.moveBy(const Offset(80, 0));
    await draw.up();
    await tester.pump();
    await tester.tap(find.text('partialEraser'));
    await tester.pump();
    final erase = await tester.startGesture(
      center + const Offset(40, -20),
      kind: PointerDeviceKind.mouse,
    );
    await erase.moveBy(const Offset(0, 20));
    await erase.moveBy(const Offset(20, 0));
    await erase.moveBy(const Offset(0, 20));
    await tester.pumpAndSettle();
    expect(_canvasPainterDescription(tester), contains('eraserPath: 4'));
    final beforeCommit = runtime.initialCoordinator.snapshot.revisions.document;
    await erase.up();
    await tester.pumpAndSettle();
    expect(find.text('Stroke partially erased'), findsOneWidget);
    expect(_handwritingStrokeCount(runtime), 2);
    expect(
      runtime.initialCoordinator.snapshot.revisions.document.value,
      beforeCommit.value + 1,
    );
  });

  testWidgets('Escape cancels partial erase and releases pointer ownership', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    await tester.tap(find.text('partialEraser'));
    await tester.pumpAndSettle();
    final partial = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
    await partial.cancel();

    await tester.tap(find.text('selection'));
    await tester.pump();
    final next = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await next.up();
    await tester.pump();
    expect(find.text('Selection cleared'), findsOneWidget);
  });

  testWidgets('Escape cancels Pen and the next Pen gesture commits', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(AlNoteApp(runtime: _runtime()));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final cancelled = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.moveBy(const Offset(5, 0));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
    await cancelled.cancel();

    final next = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await next.moveBy(const Offset(20, 0));
    await next.up();
    await tester.pump();
    expect(find.text('Stroke committed'), findsOneWidget);
  });

  testWidgets('Pen and partial Eraser publish live transient feedback', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final blank = await _canvasBytes(tester);
    final pen = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await pen.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(await _canvasBytes(tester), isNot(equals(blank)));
    expect(_canvasPainterDescription(tester), contains('eraserPath: 0'));
    await pen.cancel();
    await tester.pump();
    expect(await _canvasBytes(tester), equals(blank));

    await tester.tap(find.text('partialEraser'));
    await tester.pump();
    final revision = runtime.initialCoordinator.snapshot.revisions.document;
    final erase = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 0; index < 20; index += 1) {
      await erase.moveBy(const Offset(1, 0));
    }
    await tester.pumpAndSettle();
    expect(await _canvasBytes(tester), isNot(equals(blank)));
    expect(
      _canvasPainterDescription(tester),
      contains('previews: 0, eraserPath: 21'),
      reason: 'the survivor overlay is separate from the Eraser cursor',
    );
    expect(
      _canvasPainterDescription(tester),
      contains('partialSegments: 0'),
      reason: 'persistent interval classification starts only after Pointer Up',
    );
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
    await erase.cancel();
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
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
        for (var index = 1; index <= 100; index += 1) {
          await pen.moveTo(
            start + Offset(index.toDouble(), index.isEven ? 2 : -2),
          );
        }
        await tester.pump();
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

  testWidgets('partial Eraser gap is transparent before Pointer Up', (
    WidgetTester tester,
  ) async {
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final localCenter = center - tester.getTopLeft(canvas);
    final blankCenter = await _canvasPixel(tester, localCenter);

    final pen = await tester.startGesture(
      center - const Offset(60, 0),
      kind: PointerDeviceKind.mouse,
    );
    await pen.moveBy(const Offset(120, 0));
    await pen.up();
    await tester.pump();
    final committed = await _canvasBytes(tester);
    expect(await _canvasPixel(tester, localCenter), isNot(blankCenter));

    await tester.tap(find.text('partialEraser'));
    await tester.pump();
    final eraser = await tester.startGesture(
      center - const Offset(0, 30),
      kind: PointerDeviceKind.mouse,
    );
    await eraser.moveBy(const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(
      await _canvasPixel(tester, localCenter),
      blankCenter,
      reason: 'the predicted gap exposes the real paper pixel, not a cover',
    );
    expect(_canvasPainterDescription(tester), contains('previews: 0'));
    await eraser.cancel();
    await tester.pump();
    expect(await _canvasBytes(tester), committed);
  });

  testWidgets('immediate transparent preview matches the drained committed result', (
    WidgetTester tester,
  ) async {
    final trace = _ok(
      Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
    );
    final runtime = _ok(
      _runtimeResult(
        diagnosticTrace: trace,
        maximumEraserBatchCandidateSegments: 8,
        maximumEraserBatchClassifications: 8,
        maximumEraserBatchClassificationChecks:
            StrokeGeometryResolver.maximumPreparedClassificationChecks * 8,
        maximumEraserBatchRootIsolationAdvances: 256,
        maximumEraserBatchFeatureTransitions: 4096,
      ),
    );
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final center = tester.getCenter(canvas);
    final pen = await tester.startGesture(
      center - const Offset(90, 0),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 180; index += 1) {
      await pen.moveBy(const Offset(1, 0));
    }
    await pen.up();
    await tester.pump();

    await tester.tap(find.text('partialEraser'));
    await tester.pump();
    final eraser = await tester.startGesture(
      center - const Offset(70, 0),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 140; index += 1) {
      await eraser.moveBy(const Offset(1, 0));
    }
    await eraser.up();
    await tester.pump();
    expect(find.text('Finishing partial erase'), findsOneWidget);
    final visual =
        tester
                .widget<CustomPaint>(
                  find.byKey(const Key('phase6-visual-eraser')),
                )
                .painter!
            as Phase6VisualEraserEvidence;
    expect(visual.visualSegmentCount, 142);
    expect(visual.visualChunkCount, 1);
    expect(visual.compositedObjectLayerCount, 1);
    var drainFrames = 0;
    while (find
            .byKey(const Key('phase6-visual-eraser'))
            .evaluate()
            .isNotEmpty &&
        drainFrames < 400) {
      await _pumpCooperativeTask(tester);
      drainFrames += 1;
    }
    expect(drainFrames, greaterThanOrEqualTo(1));
    expect(find.byKey(const Key('phase6-visual-eraser')), findsNothing);
    final previewClip = _canvasPainter(tester).pageClip;
    final preview = await _canvasBytes(tester);
    await tester.pump();
    expect(find.text('Stroke partially erased'), findsOneWidget);
    expect(_canvasPainter(tester).pageClip, previewClip);
    final committed = await _canvasBytes(tester);
    expect(committed, hasLength(preview.length));
    var maximumChannelDelta = 0;
    var maximumDeltaIndex = 0;
    for (var index = 0; index < preview.length; index += 1) {
      final delta = (preview[index] - committed[index]).abs();
      if (delta > maximumChannelDelta) {
        maximumChannelDelta = delta;
        maximumDeltaIndex = index;
      }
    }
    expect(
      maximumChannelDelta,
      lessThanOrEqualTo(1),
      reason:
          'maximum index $maximumDeltaIndex at '
          '${(maximumDeltaIndex ~/ 4) % tester.getSize(find.byKey(const Key('phase6-canvas-paint'))).width.toInt()},'
          '${(maximumDeltaIndex ~/ 4) ~/ tester.getSize(find.byKey(const Key('phase6-canvas-paint'))).width.toInt()} preview '
          '${preview.sublist(maximumDeltaIndex & ~3, (maximumDeltaIndex & ~3) + 4)} '
          'committed '
          '${committed.sublist(maximumDeltaIndex & ~3, (maximumDeltaIndex & ~3) + 4)}',
    );
    expect(
      trace.events
          .where(
            (event) => event.stage == Phase6DiagnosticStage.commandPublication,
          )
          .length,
      1,
    );
    expect(
      trace.copyText(),
      allOf(
        contains('phase6_visual_summary'),
        contains('phase6_classification_summary'),
        contains('phase6_publication_summary'),
      ),
    );
  });

  testWidgets(
    'visual mask composites multiple translucent Objects independently',
    (WidgetTester tester) async {
      final runtime = _runtime(penOpacity: .45);
      await tester.pumpWidget(AlNoteApp(runtime: runtime));
      tester.widget<Slider>(find.byKey(const Key('zoom-slider'))).onChanged!(2);
      await tester.pump();
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      final center = tester.getCenter(canvas);
      for (final y in [-24.0, 0.0, 24.0]) {
        final pen = await tester.startGesture(
          center + Offset(-70, y),
          kind: PointerDeviceKind.mouse,
        );
        await pen.moveBy(const Offset(140, 0));
        await pen.up();
        await tester.pump();
      }
      final committed = await _canvasBytes(tester);
      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final eraser = await tester.startGesture(
        center - const Offset(0, 45),
        kind: PointerDeviceKind.mouse,
      );
      await eraser.moveBy(const Offset(0, 90));
      await tester.pump();
      final visual =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const Key('phase6-visual-eraser')),
                  )
                  .painter!
              as Phase6VisualEraserEvidence;
      expect(visual.visualSegmentCount, 2);
      expect(visual.compositedObjectLayerCount, 3);
      expect(await _canvasBytes(tester), isNot(equals(committed)));
      await eraser.cancel();
      await tester.pump();
      expect(await _canvasBytes(tester), committed);
      expect(_objectCount(runtime), 3);
    },
  );

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
    expect(find.text('30 strokes selected'), findsOneWidget);
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

  testWidgets('pen and partial input ceilings cancel without wedging routing', (
    WidgetTester tester,
  ) async {
    for (final configuration in [
      (tool: 'pen', pen: 1, eraser: 10000, status: 'Stroke rejected'),
      (
        tool: 'partialEraser',
        pen: 10000,
        eraser: 1,
        status: 'Partial erase rejected',
      ),
    ]) {
      await tester.pumpWidget(
        AlNoteApp(
          runtime: _runtime(
            maximumPenSamples: configuration.pen,
            maximumEraserPoints: configuration.eraser,
          ),
        ),
      );
      final canvas = find.bySemanticsLabel('Handwriting canvas');
      if (configuration.tool != 'pen') {
        await tester.tap(find.text(configuration.tool));
        await tester.pump();
      }
      final limited = await tester.startGesture(
        tester.getCenter(canvas),
        kind: PointerDeviceKind.mouse,
      );
      await limited.moveBy(const Offset(5, 0));
      await tester.pumpAndSettle();
      expect(find.text(configuration.status), findsOneWidget);
      await limited.up();

      await tester.tap(find.text('selection'));
      await tester.pump();
      final next = await tester.startGesture(
        tester.getCenter(canvas),
        kind: PointerDeviceKind.mouse,
      );
      await next.up();
      await tester.pump();
      expect(find.text('Selection cleared'), findsOneWidget);
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
      AlnotePackageCodec(
        objectRegistry: roomy.objectRegistry,
      ).encode(emptySnapshot, limits: roomy.storageLimits),
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
    expect(find.text('2 strokes selected'), findsOneWidget);
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
      find.text('Stroke selected'),
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
    final runtime = _runtime();
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final start = tester.getCenter(canvas) - const Offset(180, 0);
    final pen = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    for (var index = 1; index <= 360; index += 1) {
      await pen.moveTo(start + Offset(index.toDouble(), index.isEven ? 1 : -1));
      if (index % 60 == 0) {
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

    await tester.tap(find.text('partialEraser'));
    await tester.pump();
    final partial = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 240; index += 1) {
      await partial.moveBy(Offset(0, index.isEven ? 1 : -1));
    }
    final beforePartialCommit =
        runtime.initialCoordinator.snapshot.revisions.document;
    await partial.up();
    await tester.pump();
    expect(find.text('Finishing partial erase'), findsOneWidget);
    final cursorPaint = tester.widget<CustomPaint>(
      find.byKey(const Key('phase6-eraser-cursor')),
    );
    expect(
      (cursorPaint.painter! as Phase6EraserCursorEvidence).cursorPosition,
      isNull,
    );
    await tester.pumpAndSettle();
    final partialEvidence = _canvasPainter(tester);
    expect(partialEvidence.previewPrimitiveCount, lessThanOrEqualTo(192));
    expect(find.text('Stroke partially erased'), findsOneWidget);
    expect(
      runtime.initialCoordinator.snapshot.revisions.document.value,
      beforePartialCommit.value + 1,
    );
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();

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
  });

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

      await tester.tap(find.text('partialEraser'));
      await tester.pump();
      final partial = await tester.startGesture(
        center - const Offset(0, 24),
        kind: PointerDeviceKind.mouse,
      );
      final localCenter = center - tester.getTopLeft(canvas);
      final committedPixel = await _canvasPixel(tester, localCenter);
      await partial.moveTo(center + const Offset(0, 24));
      await tester.pumpAndSettle();
      final previewPixel = await _canvasPixel(tester, localCenter);
      expect(previewPixel, isNot(equals(committedPixel)));
      expect(previewPixel.first, greaterThan(committedPixel.first));
      await partial.up();
      await tester.pumpAndSettle();
      expect(find.text('Stroke partially erased'), findsOneWidget);
      final terminalPixel = await _canvasPixel(tester, localCenter);
      expect(terminalPixel, isNot(equals(committedPixel)));
      expect(terminalPixel.first, greaterThanOrEqualTo(previewPixel.first));
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
      await tester.pump();
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
    final select = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await select.up();
    await tester.pump();
    expect(find.text('Stroke selected'), findsOneWidget);
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

  test('runtime registry ceilings are injected and exact boundaries pass', () {
    final exactGenerator = _RuntimeCountingUuidGenerator();
    expect(
      _runtimeResult(
        uuidGenerator: exactGenerator,
        maximumRenderingDefinitions: 1,
        maximumHitTestingDefinitions: 1,
        maximumTools: 4,
        maximumActions: 4,
        maximumBindings: 9,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    expect(exactGenerator.calls, 5);
    for (final limits in [
      (rendering: 0, hits: 1, tools: 4, actions: 4, bindings: 9),
      (rendering: 1, hits: 0, tools: 4, actions: 4, bindings: 9),
      (rendering: 1, hits: 1, tools: 3, actions: 4, bindings: 9),
      (rendering: 1, hits: 1, tools: 4, actions: 3, bindings: 9),
      (rendering: 1, hits: 1, tools: 4, actions: 4, bindings: 8),
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
    final invalidSlice = _RuntimeCountingUuidGenerator();
    expect(
      _runtimeResult(
        uuidGenerator: invalidSlice,
        maximumEraserExactSliceMicros: 0,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(invalidSlice.calls, 0);
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

Phase6CanvasRuntime _runtime({
  UuidGenerator? uuidGenerator,
  int storageCeiling = 10000000,
  int maximumPenSamples = 10000,
  int maximumEraserPoints = 10000,
  int maximumEraserClassificationChecks = 2000000,
  int maximumEraserBatchCandidateSegments = 32,
  int maximumEraserBatchClassifications = 16,
  int maximumEraserBatchClassificationChecks = 512,
  int maximumEraserBatchRootIsolationAdvances = 8,
  int maximumEraserBatchFeatureTransitions = 128,
  int maximumEraserExactSliceMicros = 1000000,
  int maximumEraserActiveExactSliceMicros = 1000000,
  Phase6CooperativeTaskScheduler cooperativeTaskScheduler =
      const Phase6EventLoopTaskScheduler(),
  int? maximumEraserVisualPictures,
  Phase6DebugClipboard debugClipboard = const _SuccessfulClipboard(),
  Phase6NativePictureObserver nativePictureObserver =
      const Phase6NoopNativePictureObserver(),
  Phase6ReopenGateway? reopenGateway,
  double penOpacity = 1,
}) => _ok(
  _runtimeResult(
    uuidGenerator: uuidGenerator,
    storageCeiling: storageCeiling,
    maximumPenSamples: maximumPenSamples,
    maximumEraserPoints: maximumEraserPoints,
    maximumEraserClassificationChecks: maximumEraserClassificationChecks,
    maximumEraserBatchCandidateSegments: maximumEraserBatchCandidateSegments,
    maximumEraserBatchClassifications: maximumEraserBatchClassifications,
    maximumEraserBatchClassificationChecks:
        maximumEraserBatchClassificationChecks,
    maximumEraserBatchRootIsolationAdvances:
        maximumEraserBatchRootIsolationAdvances,
    maximumEraserBatchFeatureTransitions: maximumEraserBatchFeatureTransitions,
    maximumEraserExactSliceMicros: maximumEraserExactSliceMicros,
    maximumEraserActiveExactSliceMicros: maximumEraserActiveExactSliceMicros,
    cooperativeTaskScheduler: cooperativeTaskScheduler,
    maximumEraserVisualPictures: maximumEraserVisualPictures,
    debugClipboard: debugClipboard,
    nativePictureObserver: nativePictureObserver,
    diagnosticTrace: _ok(
      Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
    ),
    reopenGateway: reopenGateway,
    penOpacity: penOpacity,
  ),
);

Result<Phase6CanvasRuntime, StructuredFailure> _runtimeResult({
  UuidGenerator? uuidGenerator,
  int storageCeiling = 10000000,
  int maximumPenSamples = 10000,
  int maximumHandwritingSamples = 10000,
  int maximumEraserPoints = 10000,
  int maximumEraserClassificationChecks = 2000000,
  int maximumEraserBatchCandidateSegments = 32,
  int maximumEraserBatchClassifications = 16,
  int maximumEraserBatchClassificationChecks = 512,
  int maximumEraserBatchRootIsolationAdvances = 8,
  int maximumEraserBatchFeatureTransitions = 128,
  int maximumEraserExactSliceMicros = 1000000,
  int maximumEraserActiveExactSliceMicros = 1000000,
  Phase6CooperativeTaskScheduler cooperativeTaskScheduler =
      const Phase6EventLoopTaskScheduler(),
  int? maximumEraserVisualPictures,
  int maximumRenderingDefinitions = 16,
  int maximumHitTestingDefinitions = 16,
  int maximumTools = 16,
  int maximumActions = 16,
  int maximumBindings = 32,
  int maximumPointsPerPrimitive = 32,
  int ellipseVertexCount = 16,
  int maximumGeometryElements = 20000,
  int maximumGeometryVertices = 400000,
  Phase6DiagnosticTrace? diagnosticTrace,
  Phase6DebugClipboard debugClipboard = const _SuccessfulClipboard(),
  Phase6NativePictureObserver nativePictureObserver =
      const Phase6NoopNativePictureObserver(),
  Phase6ReopenGateway? reopenGateway,
  double penOpacity = 1,
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
        maximumPrimitives: 400000,
        maximumPointsPerPrimitive: maximumPointsPerPrimitive,
        maximumDamageRegions: 400000,
        maximumPreviewOverlays: 20000,
        maximumSelectionOverlays: 20000,
      ),
    ),
    historyLimits: _ok(
      HistoryLimits.create(
        maximumRetainedCommandCount: 100,
        maximumEstimatedRetainedBytes: 10000000,
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
    maximumCommandOperations: 64,
    maximumListeners: 16,
    maximumPenSamples: maximumPenSamples,
    maximumEraserPoints: maximumEraserPoints,
    maximumEraserIntersections: 20000,
    maximumEraserFragments: 10000,
    maximumEraserOutputSamples: 200000,
    maximumEraserClassificationChecks: maximumEraserClassificationChecks,
    maximumEraserBatchCandidateSegments: maximumEraserBatchCandidateSegments,
    maximumEraserBatchClassifications: maximumEraserBatchClassifications,
    maximumEraserBatchClassificationChecks:
        maximumEraserBatchClassificationChecks,
    maximumEraserBatchRootIsolationAdvances:
        maximumEraserBatchRootIsolationAdvances,
    maximumEraserBatchFeatureTransitions: maximumEraserBatchFeatureTransitions,
    maximumEraserExactSliceMicros: maximumEraserExactSliceMicros,
    maximumEraserActiveExactSliceMicros: maximumEraserActiveExactSliceMicros,
    cooperativeTaskScheduler: cooperativeTaskScheduler,
    maximumEraserVisualPictures:
        maximumEraserVisualPictures ?? math.min(16, maximumEraserPoints),
    diagnosticTrace:
        diagnosticTrace ??
        _ok(Phase6DiagnosticTrace.create(enabled: true, capacity: 64)),
    reopenGateway: reopenGateway,
    debugClipboard: debugClipboard,
    nativePictureObserver: nativePictureObserver,
  );
}

Future<void> _pumpCooperativeTask(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
}

Future<Uint8List> _canvasBytes(WidgetTester tester) async {
  late Uint8List result;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('phase6-canvas-paint')),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData();
    result = data!.buffer.asUint8List();
    image.dispose();
  });
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

Future<List<int>> _canvasPixel(
  WidgetTester tester,
  Offset localPosition,
) async {
  late List<int> result;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('phase6-canvas-paint')),
    );
    final image = await boundary.toImage();
    final data = await image.toByteData();
    final bytes = data!.buffer.asUint8List();
    final x = localPosition.dx.floor().clamp(0, image.width - 1);
    final y = localPosition.dy.floor().clamp(0, image.height - 1);
    final offset = (y * image.width + x) * 4;
    result = bytes.sublist(offset, offset + 4);
    image.dispose();
  });
  return result;
}

String _canvasPainterDescription(WidgetTester tester) => tester
    .widget<CustomPaint>(find.byKey(const Key('phase6-overlay-paint')))
    .painter
    .toString();

Phase6CanvasPersistenceEvidence _canvasPainter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(find.byKey(const Key('phase6-overlay-paint')))
            .painter
        as Phase6CanvasPersistenceEvidence;

int _objectCount(Phase6CanvasRuntime runtime) => runtime
    .initialCoordinator
    .snapshot
    .root
    .pages
    .expand((page) => page.layers)
    .expand((layer) => layer.objects)
    .length;

int _handwritingStrokeCount(Phase6CanvasRuntime runtime) {
  final object = runtime.initialCoordinator.snapshot.root.pages.single.layers
      .expand((layer) => layer.objects)
      .single;
  return _ok(
    HandwritingPayload.decode(
      object.payload,
      limits: runtime.handwritingLimits,
    ),
  ).strokes.length;
}

void _seedPartialSchedulerDocument(
  Phase6CanvasRuntime runtime, {
  required Point2 anchor,
  required ObjectId removal,
}) {
  final snapshot = runtime.initialCoordinator.snapshot;
  final page = snapshot.root.pages.single;
  final layer = page.layers.single;
  final additions = <ObjectCollectionAddition>[];
  var strokeOrdinal = 0;
  for (var objectOrdinal = 0; objectOrdinal < 6; objectOrdinal += 1) {
    final strokes = <HandwritingStroke>[];
    final strokeCount = objectOrdinal < 3 ? 3 : 2;
    for (var withinObject = 0; withinObject < strokeCount; withinObject += 1) {
      final y = anchor.y - 63 + strokeOrdinal * 9;
      final samples = [
        _ok(
          StrokeSample.create(
            position: _ok(Point2.create(x: anchor.x - 100, y: y)),
            timeMicros: 0,
            limits: runtime.handwritingLimits,
          ),
        ),
        _ok(
          StrokeSample.create(
            position: _ok(Point2.create(x: anchor.x + 100, y: y + .25)),
            timeMicros: 1,
            limits: runtime.handwritingLimits,
          ),
        ),
      ];
      strokes.add(
        _ok(
          HandwritingStroke.create(
            id: StrokeId.fromUuid(testUuid(7100 + strokeOrdinal)),
            samples: samples,
            style: runtime.penStyle,
            limits: runtime.handwritingLimits,
          ),
        ),
      );
      strokeOrdinal += 1;
    }
    final payload = _ok(
      HandwritingPayload.create(
        strokes: strokes,
        limits: runtime.handwritingLimits,
      ),
    );
    additions.add(
      ObjectCollectionAddition(
        layerId: layer.id,
        object: testObject(
          id: 7000 + objectOrdinal,
          typeKey: handwritingObjectTypeKey,
          schemaVersion: handwritingSchemaVersion,
          payload: payload.encode(),
        ),
      ),
    );
  }
  final request = _ok(
    AtomicObjectCollectionEditRequest.create(
      documentId: snapshot.root.id,
      metadata: CommandMetadata(
        family: CommandFamily.objectCollectionEdit,
        correlationId: CommandCorrelationId.fromUuid(testUuid(7200)),
        description: 'Seed active Partial scheduler',
      ),
      preconditions: RevisionPreconditions(
        pages: {page.id: snapshot.revisions.pages[page.id]!},
        layerMembership: {
          layer.id: snapshot.revisions.layerMembership[layer.id]!,
        },
        objects: {removal: snapshot.revisions.objects[removal]!},
      ),
      pageId: page.id,
      additions: additions,
      removals: [removal],
      maximumOperations: 7,
    ),
  );
  final committed = runtime.initialCoordinator.execute(request);
  if (committed is! Ok<CommandCommit, CommandFailure>) {
    throw StateError(committed.toString());
  }
}

void _seedContinuousPartialSchedulerDocument(
  Phase6CanvasRuntime runtime, {
  required Point2 anchor,
  required ObjectId removal,
}) {
  final snapshot = runtime.initialCoordinator.snapshot;
  final page = snapshot.root.pages.single;
  final layer = page.layers.single;
  final additions = <ObjectCollectionAddition>[];
  var strokeOrdinal = 0;
  for (var objectOrdinal = 0; objectOrdinal < 6; objectOrdinal += 1) {
    final strokes = <HandwritingStroke>[];
    final strokeCount = objectOrdinal < 3 ? 3 : 2;
    for (var withinObject = 0; withinObject < strokeCount; withinObject += 1) {
      final y = anchor.y - 63 + strokeOrdinal * 9;
      final samples = strokeOrdinal == 0
          ? List.generate(
              31,
              (sample) => _ok(
                StrokeSample.create(
                  position: _ok(
                    Point2.create(x: anchor.x - 105 + sample * 7, y: y),
                  ),
                  timeMicros: sample,
                  limits: runtime.handwritingLimits,
                ),
              ),
            )
          : [
              _ok(
                StrokeSample.create(
                  position: _ok(Point2.create(x: anchor.x - 105, y: y)),
                  timeMicros: 0,
                  limits: runtime.handwritingLimits,
                ),
              ),
              _ok(
                StrokeSample.create(
                  position: _ok(Point2.create(x: anchor.x + 105, y: y + .25)),
                  timeMicros: 1,
                  limits: runtime.handwritingLimits,
                ),
              ),
            ];
      strokes.add(
        _ok(
          HandwritingStroke.create(
            id: StrokeId.fromUuid(testUuid(8100 + strokeOrdinal)),
            samples: samples,
            style: runtime.penStyle,
            limits: runtime.handwritingLimits,
          ),
        ),
      );
      strokeOrdinal += 1;
    }
    additions.add(
      ObjectCollectionAddition(
        layerId: layer.id,
        object: testObject(
          id: 8000 + objectOrdinal,
          typeKey: handwritingObjectTypeKey,
          schemaVersion: handwritingSchemaVersion,
          payload: _ok(
            HandwritingPayload.create(
              strokes: strokes,
              limits: runtime.handwritingLimits,
            ),
          ).encode(),
        ),
      ),
    );
  }
  final request = _ok(
    AtomicObjectCollectionEditRequest.create(
      documentId: snapshot.root.id,
      metadata: CommandMetadata(
        family: CommandFamily.objectCollectionEdit,
        correlationId: CommandCorrelationId.fromUuid(testUuid(8200)),
        description: 'Seed continuous Partial scheduler',
      ),
      preconditions: RevisionPreconditions(
        pages: {page.id: snapshot.revisions.pages[page.id]!},
        layerMembership: {
          layer.id: snapshot.revisions.layerMembership[layer.id]!,
        },
        objects: {removal: snapshot.revisions.objects[removal]!},
      ),
      pageId: page.id,
      additions: additions,
      removals: [removal],
      maximumOperations: 7,
    ),
  );
  final committed = runtime.initialCoordinator.execute(request);
  if (committed is! Ok<CommandCommit, CommandFailure>) {
    throw StateError(committed.toString());
  }
}

final class _ManualCooperativeTaskScheduler
    implements Phase6CooperativeTaskScheduler {
  final List<_ManualCooperativeTask> _pending = [];

  int get pendingTaskCount => _pending.length;

  @override
  Result<Phase6CooperativeTaskHandle, StructuredFailure> schedule(
    void Function() task,
  ) {
    final scheduled = _ManualCooperativeTask(this, task);
    _pending.add(scheduled);
    return Ok(scheduled);
  }

  void runNext() {
    final scheduled = _pending.removeAt(0);
    scheduled.run();
  }

  void runAll() {
    while (_pending.isNotEmpty) {
      runNext();
    }
  }
}

final class _ManualCooperativeTask implements Phase6CooperativeTaskHandle {
  _ManualCooperativeTask(this._owner, this._task);

  final _ManualCooperativeTaskScheduler _owner;
  void Function()? _task;

  void run() {
    final task = _task;
    _task = null;
    task?.call();
  }

  @override
  void cancel() {
    _task = null;
    _owner._pending.remove(this);
  }
}

final class _FailingReopenGateway implements Phase6ReopenGateway {
  const _FailingReopenGateway(this.stage);
  final Phase6ReopenFailureStage stage;

  @override
  Phase6ReopenOutcome reopen({
    required List<int> bytes,
    required DocumentRoot savedRoot,
  }) => Phase6ReopenFailure(stage);
}

final class _RuntimeCountingUuidGenerator implements UuidGenerator {
  int calls = 0;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    calls += 1;
    return Ok(testUuid(5000 + calls));
  }
}

T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;
