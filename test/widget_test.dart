// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/app/al_note_app.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/renderer.dart';
import 'package:al_note/ui/canvas/phase6_canvas_runtime.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/document_model_test_support.dart';
import 'support/uuid_sequence_generator.dart';

/// Verifies the accessible Phase 6 Canvas shell and pointer route.
void main() {
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
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Reopen'), findsOneWidget);

    final canvas = find.bySemanticsLabel('Handwriting canvas');
    expect(canvas, findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 10));
    await gesture.up();
    await tester.pump();
    expect(find.text('Stroke committed'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.undo))
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
    await tester.pump();

    await tester.tap(find.text('selection'));
    await tester.pump();
    final selectionTap = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await selectionTap.up();
    await tester.pump();
    expect(find.text('Stroke selected'), findsOneWidget);

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

    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.textContaining('Saved '), findsOneWidget);
    await tester.tap(find.text('Reopen'));
    await tester.pump();
    expect(find.text('Reopened identical content'), findsOneWidget);
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
    await tester.pump();
    expect(
      _canvasPainterDescription(tester),
      contains('previews: 1, eraserPath: 4'),
    );
    final beforeCommit = runtime.initialCoordinator.snapshot.revisions.document;
    await erase.up();
    await tester.pump();
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
    await tester.pump();
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
    await tester.pump();
    expect(await _canvasBytes(tester), isNot(equals(blank)));
    expect(
      _canvasPainterDescription(tester),
      contains('previews: 1, eraserPath: 21'),
    );
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
    await erase.cancel();
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.revisions.document, revision);
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
    expect(
      _canvasPainterDescription(tester),
      contains('previews: 1, eraserPath: 13'),
    );
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
      await tester.pump();
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
    await tester.pump();
    expect(runtime.initialCoordinator.snapshot.isDirty, isTrue);

    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Save failed'), findsOneWidget);
    expect(runtime.initialCoordinator.snapshot.isDirty, isTrue);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.textContaining('Saved '), findsOneWidget);
    expect(runtime.initialCoordinator.snapshot.isDirty, isFalse);
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
  int storageCeiling = 10000000,
  int maximumPenSamples = 10000,
  int maximumEraserPoints = 10000,
}) => _ok(
  _runtimeResult(
    storageCeiling: storageCeiling,
    maximumPenSamples: maximumPenSamples,
    maximumEraserPoints: maximumEraserPoints,
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
  return Phase6CanvasRuntime.create(
    uuidGenerator:
        uuidGenerator ??
        UuidSequenceGenerator.fromValues(
          List.generate(128, (index) => testUuid(1000 + index)),
        ),
    handwritingLimits: _ok(
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

String _canvasPainterDescription(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const Key('phase6-canvas-paint')),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter
    .toString();

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

final class _RuntimeCountingUuidGenerator implements UuidGenerator {
  int calls = 0;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    calls += 1;
    return Ok(testUuid(5000 + calls));
  }
}

T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;
