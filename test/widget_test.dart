// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;
import 'package:al_note/app/al_note_app.dart';
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
import 'support/phase3_test_support.dart';
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
    final WidgetTester tester,
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

  testWidgets('Canvas disposal releases Pen pictures and stale callbacks', (
    WidgetTester tester,
  ) async {
    final observer = _CountingPictureObserver();
    final runtime = _runtime(nativePictureObserver: observer);
    await tester.pumpWidget(AlNoteApp(runtime: runtime));
    final canvas = find.bySemanticsLabel('Handwriting canvas');
    final start = tester.getCenter(canvas) - const Offset(160, 0);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    for (var index = 1; index <= 220; index += 1) {
      await gesture.moveTo(start + Offset(index.toDouble(), 0));
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
    expect(
      tester.widget<Text>(find.byKey(const Key('canvas-status'))).data,
      'Stroke selected',
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
      'Stroke selected',
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
      await tester.enterText(
        find.byKey(const Key('text-object-editor')),
        'Cafe\u0301 👩‍💻 مرحبا',
      );
      await tester.tap(find.text('Bold'));
      await tester.tap(find.text('Add'));
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

      await tester.tap(find.text('selection'));
      await tester.pump();
      final selectText = await tester.startGesture(
        center,
        kind: PointerDeviceKind.mouse,
      );
      await selectText.up();
      await tester.pump();
      expect(find.byKey(const Key('edit-selected-text')), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-selected-text')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('text-object-editor')), '');
      await tester.tap(find.text('Save'));
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
      await tester.tap(find.text('Add'));
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
        maximumRenderingDefinitions: 4,
        maximumHitTestingDefinitions: 4,
        maximumTools: 5,
        maximumActions: 5,
        maximumBindings: 11,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    expect(exactGenerator.calls, 5);
    for (final limits in [
      (rendering: 3, hits: 4, tools: 5, actions: 5, bindings: 11),
      (rendering: 4, hits: 3, tools: 5, actions: 5, bindings: 11),
      (rendering: 4, hits: 4, tools: 4, actions: 5, bindings: 11),
      (rendering: 4, hits: 4, tools: 5, actions: 4, bindings: 11),
      (rendering: 4, hits: 4, tools: 5, actions: 5, bindings: 10),
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
  int storageCeiling = 10000000,
  int maximumPenSamples = 10000,
  int maximumEraserPoints = 10000,
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
    debugClipboard: debugClipboard,
    nativePictureObserver: nativePictureObserver,
    diagnosticTrace: _ok(
      Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
    ),
    reopenGateway: reopenGateway,
    penOpacity: penOpacity,
  ),
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
  int storageCeiling = 10000000,
  int maximumPenSamples = 10000,
  int maximumHandwritingSamples = 10000,
  int maximumEraserPoints = 10000,
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
      find.byKey(const Key('phase6-canvas-paint')),
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

final class _RuntimeCountingUuidGenerator implements UuidGenerator {
  int calls = 0;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    calls += 1;
    return Ok(testUuid(5000 + calls));
  }
}

T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;
