// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/app/al_note_app.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:al_note/documents/objects/image.dart';
import 'package:al_note/documents/objects/shape.dart';
import 'package:al_note/documents/objects/text.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/renderer.dart';
import 'package:al_note/ui/canvas/phase6_canvas_runtime.dart';
import 'package:al_note/ui/canvas/phase6_diagnostics.dart';
import 'package:flutter/foundation.dart';
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
    maximumUnknownNodes: 100000,
    maximumCoordinateMagnitude: 1000000,
    maximumStrokeWidth: 1000,
    maximumAbsoluteTilt: 1.5707963267948966,
    maximumAbsoluteOrientation: 6.283185307179586,
  ).fold<HandwritingLimits?>(onOk: (value) => value, onErr: (_) => null);
  final geometry = StrokeGeometryLimits.create(
    maximumElements: 20000,
    maximumVertices: 400000,
    ellipseVertexCount: 16,
    maximumContainmentChecks: 1000000,
  ).fold<StrokeGeometryLimits?>(onOk: (value) => value, onErr: (_) => null);
  final shape = ShapeLimits.create(
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
  ).fold<ShapeLimits?>(onOk: (value) => value, onErr: (_) => null);
  final image = ImageLimits.create(
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
  ).fold<ImageLimits?>(onOk: (value) => value, onErr: (_) => null);
  final shapeInteraction = ShapeInteractionLimits.create(
    maximumChecks: 1000000,
  ).fold<ShapeInteractionLimits?>(onOk: (value) => value, onErr: (_) => null);
  final text = TextLimits.create(
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
  ).fold<TextLimits?>(onOk: (value) => value, onErr: (_) => null);
  final rendering = RenderingLimits.create(
    maximumPrimitives: 400000,
    maximumPointsPerPrimitive: 10000,
    maximumDamageRegions: 400000,
    maximumPreviewOverlays: 20000,
    maximumSelectionOverlays: 20000,
  ).fold<RenderingLimits?>(onOk: (value) => value, onErr: (_) => null);
  final history = HistoryLimits.create(
    maximumRetainedCommandCount: 100,
    maximumEstimatedRetainedBytes: 10000000,
  ).fold<HistoryLimits?>(onOk: (value) => value, onErr: (_) => null);
  final storage = _productionStorageLimits();
  final diagnostics = Phase6DiagnosticTrace.create(
    enabled: kDebugMode,
    capacity: 64,
    emitToDebugOutput: kDebugMode,
  ).fold<Phase6DiagnosticTrace?>(onOk: (value) => value, onErr: (_) => null);
  final penStyle = handwriting == null
      ? null
      : StrokeStyle.create(
          argb: 0xff17324d,
          opacity: 1,
          baseWidth: 3,
          pressureInfluence: .65,
          minimumPressureFactor: .2,
          limits: handwriting,
        ).fold<StrokeStyle?>(onOk: (value) => value, onErr: (_) => null);
  if (handwriting == null ||
      shape == null ||
      shapeInteraction == null ||
      image == null ||
      text == null ||
      geometry == null ||
      rendering == null ||
      history == null ||
      storage == null ||
      diagnostics == null ||
      penStyle == null) {
    runApp(const AlNoteInitializationFailureApp());
    return;
  }
  final runtime = Phase6CanvasRuntime.create(
    uuidGenerator: uuid,
    handwritingLimits: handwriting,
    shapeLimits: shape,
    shapeInteractionLimits: shapeInteraction,
    imageLimits: image,
    textLimits: text,
    penStyle: penStyle,
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
    diagnosticTrace: diagnostics,
    debugClipboard: const Phase6SystemDebugClipboard(),
    nativePictureObserver: const Phase6NoopNativePictureObserver(),
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
