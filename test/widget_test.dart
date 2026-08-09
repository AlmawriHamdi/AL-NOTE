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
        maximumTools: 3,
        maximumActions: 3,
        maximumBindings: 7,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    expect(exactGenerator.calls, 5);
    for (final limits in [
      (rendering: 0, hits: 1, tools: 3, actions: 3, bindings: 7),
      (rendering: 1, hits: 0, tools: 3, actions: 3, bindings: 7),
      (rendering: 1, hits: 1, tools: 2, actions: 3, bindings: 7),
      (rendering: 1, hits: 1, tools: 3, actions: 2, bindings: 7),
      (rendering: 1, hits: 1, tools: 3, actions: 3, bindings: 6),
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
    diagnosticTrace:
        diagnosticTrace ??
        _ok(Phase6DiagnosticTrace.create(enabled: true, capacity: 64)),
    reopenGateway: reopenGateway,
    debugClipboard: debugClipboard,
    nativePictureObserver: nativePictureObserver,
  );
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
