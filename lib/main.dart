// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/app/al_note_app.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/renderer.dart';
import 'package:al_note/ui/canvas/phase6_canvas_runtime.dart';
import 'package:flutter/widgets.dart';

/// Starts AL NOTE from explicit SDK-backed production dependencies.
void main() {
  const random = SdkSecureRandomSource();
  const uuid = Rfc9562UuidV4Generator(random);
  final handwriting = HandwritingLimits.create(
    maximumStrokes: 1024,
    maximumSamplesPerStroke: 10000,
    maximumUnknownFields: 256,
    maximumNestingDepth: 32,
    maximumCoordinateMagnitude: 1000000,
    maximumStrokeWidth: 1000,
    maximumAbsoluteTilt: 1.5707963267948966,
    maximumAbsoluteOrientation: 6.283185307179586,
  ).fold<HandwritingLimits?>(onOk: (value) => value, onErr: (_) => null);
  final geometry = StrokeGeometryLimits.create(
    maximumElements: 20000,
    maximumVertices: 400000,
    ellipseVertexCount: 16,
  ).fold<StrokeGeometryLimits?>(onOk: (value) => value, onErr: (_) => null);
  final rendering = RenderingLimits.create(
    maximumPrimitives: 400000,
    maximumPointsPerPrimitive: 32,
    maximumDamageRegions: 400000,
    maximumPreviewOverlays: 20000,
    maximumSelectionOverlays: 20000,
  ).fold<RenderingLimits?>(onOk: (value) => value, onErr: (_) => null);
  final history = HistoryLimits.create(
    maximumRetainedCommandCount: 100,
    maximumEstimatedRetainedBytes: 10000000,
  ).fold<HistoryLimits?>(onOk: (value) => value, onErr: (_) => null);
  final storage = _productionStorageLimits();
  if (handwriting == null ||
      geometry == null ||
      rendering == null ||
      history == null ||
      storage == null) {
    runApp(const AlNoteInitializationFailureApp());
    return;
  }
  final runtime = Phase6CanvasRuntime.create(
    uuidGenerator: uuid,
    handwritingLimits: handwriting,
    geometryLimits: geometry,
    renderingLimits: rendering,
    historyLimits: history,
    storageLimits: storage,
    maximumHitResults: 10000,
    maximumLassoPoints: 10000,
    maximumRenderingDefinitions: 16,
    maximumHitTestingDefinitions: 16,
    maximumHitBehaviorResults: 10000,
    maximumTools: 16,
    maximumActions: 16,
    maximumBindings: 32,
    maximumSelectionTargets: 1024,
    maximumCommandOperations: 64,
    maximumListeners: 16,
    maximumPenSamples: 10000,
    maximumEraserPoints: 10000,
    maximumEraserIntersections: 20000,
    maximumEraserFragments: 10000,
    maximumEraserOutputSamples: 200000,
  );
  runApp(
    runtime is Ok<Phase6CanvasRuntime, StructuredFailure>
        ? AlNoteApp(runtime: runtime.value)
        : const AlNoteInitializationFailureApp(),
  );
}

ResourceLimitSnapshot? _productionStorageLimits() {
  final entries = <({ResourceLimitKey key, ResourceLimitCeiling ceiling})>[];
  for (final requirement in alnoteStorageLimitRequirements.entries) {
    final key = ResourceLimitKey.parse(
      requirement.key,
    ).fold<ResourceLimitKey?>(onOk: (value) => value, onErr: (_) => null);
    final ceiling = ResourceLimitCeiling.create(
      value: 10000000,
      unit: requirement.value,
    ).fold<ResourceLimitCeiling?>(onOk: (value) => value, onErr: (_) => null);
    if (key == null || ceiling == null) return null;
    entries.add((key: key, ceiling: ceiling));
  }
  return ResourceLimitSnapshot.create(
    entries,
  ).fold<ResourceLimitSnapshot?>(onOk: (value) => value, onErr: (_) => null);
}
