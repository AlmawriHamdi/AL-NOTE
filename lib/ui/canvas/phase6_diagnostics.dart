// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';

/// Closed debug-only Phase 6 diagnostic stages.
enum Phase6DiagnosticStage {
  gestureStarted,
  cursorRepaintRequested,
  cursorRepaintCompleted,
  sceneComposition,
  repaintScheduled,
  penTerminal,
  penTerminalNormalization,
  penRequestConstruction,
  penCoordinatorPreparation,
  penHistoryAccounting,
  penPublicationObservers,
  penSelectionReconciliation,
  penCommittedSceneUpdate,
  penFirstCommittedPaint,
  penPointerUpReady,
  textTransformPreview,
  selectionHoverSummary,
  selectionTransformPreview,
  eraserTerminal,
  gestureCancelled,
}

/// Closed redaction-safe reasons for abandoning one active gesture.
enum Phase6DiagnosticCancellationReason {
  none,
  explicitUserRequest,
  pointerCancelled,
  focusLost,
  lifecycleSuspended,
  inputRejected,
  disposed,
}

/// One immutable numeric-only Phase 6 diagnostic event.
final class Phase6DiagnosticEvent {
  const Phase6DiagnosticEvent._({
    required this.sequence,
    required this.gestureOrdinal,
    required this.stage,
    required this.cancellationReason,
    required this.pointerSegments,
    required this.sceneCompositions,
    required this.repaints,
    required this.elapsedMicros,
    required this.rawPoints,
    required this.authoritativeSamples,
    required this.visualUpdates,
    required this.pendingWork,
    required this.layoutRequests,
    required this.cacheHits,
    required this.transformRequests,
    required this.acceptedTargets,
    required this.rejectedTargets,
    required this.commandOperations,
    required this.terminalDisposition,
    required this.geometryResolutions,
    required this.frozenReplays,
    required this.maximumActivePaintPrimitives,
    required this.maximumRetainedResources,
    required this.parentRebuilds,
    required this.compactions,
    required this.previewPaints,
    required this.shiftKeyDownEvents,
    required this.shiftKeyUpEvents,
    required this.shiftPointerUpdates,
    required this.snappedPreviewUpdates,
    required this.finalSnapDisposition,
    required this.committedChunksRetained,
    required this.committedChunksRebuilt,
    required this.unchangedObjectsReplayed,
    required this.newObjectsRendered,
    required this.committedPrimitivesPainted,
    required this.nativeResourcesCreated,
    required this.nativeResourcesDisposed,
    required this.firstCommittedPaintInvocations,
    required this.handwritingTargetCount,
    required this.shapeTargetCount,
    required this.textTargetCount,
    required this.hoverZoneCode,
    required this.cursorCode,
    required this.transformModeCode,
    required this.failureStageCode,
    required this.unwrappedAngleTransitions,
    required this.identitySectorEntries,
    required this.identitySectorExits,
    required this.branchCutCrossings,
    required this.rendererPreparations,
    required this.handwritingGeometryPreparations,
    required this.selectedContentPictureCreations,
    required this.perTargetPrimitiveRebuilds,
    required this.unrelatedCommittedContentReplays,
    required this.terminalPublications,
  });

  /// Monotonic event sequence within this trace.
  final int sequence;

  /// Non-sensitive process-local gesture ordinal.
  final int gestureOrdinal;

  /// Closed diagnostic stage.
  final Phase6DiagnosticStage stage;

  /// Closed cancellation reason, or [Phase6DiagnosticCancellationReason.none].
  final Phase6DiagnosticCancellationReason cancellationReason;

  /// Bounded pointer-segment count.
  final int pointerSegments;

  /// Bounded scene-composition count.
  final int sceneCompositions;

  /// Bounded repaint count.
  final int repaints;

  /// Debug-only elapsed microseconds for this bounded stage.
  final int elapsedMicros;

  final int rawPoints;
  final int authoritativeSamples;
  final int visualUpdates;
  final int pendingWork;
  final int layoutRequests;
  final int cacheHits;
  final int transformRequests;
  final int acceptedTargets;
  final int rejectedTargets;
  final int commandOperations;
  final int terminalDisposition;
  final int geometryResolutions;
  final int frozenReplays;
  final int maximumActivePaintPrimitives;
  final int maximumRetainedResources;
  final int parentRebuilds;
  final int compactions;
  final int previewPaints;
  final int shiftKeyDownEvents;
  final int shiftKeyUpEvents;
  final int shiftPointerUpdates;
  final int snappedPreviewUpdates;
  final int finalSnapDisposition;
  final int committedChunksRetained;
  final int committedChunksRebuilt;
  final int unchangedObjectsReplayed;
  final int newObjectsRendered;
  final int committedPrimitivesPainted;
  final int nativeResourcesCreated;
  final int nativeResourcesDisposed;
  final int firstCommittedPaintInvocations;
  final int handwritingTargetCount;
  final int shapeTargetCount;
  final int textTargetCount;
  final int hoverZoneCode;
  final int cursorCode;
  final int transformModeCode;
  final int failureStageCode;
  final int unwrappedAngleTransitions;
  final int identitySectorEntries;
  final int identitySectorExits;
  final int branchCutCrossings;
  final int rendererPreparations;
  final int handwritingGeometryPreparations;
  final int selectedContentPictureCreations;
  final int perTargetPrimitiveRebuilds;
  final int unrelatedCommittedContentReplays;
  final int terminalPublications;

  /// Fixed-label representation containing no document or pointer data.
  String toSafeText() =>
      'phase6_diag seq=$sequence gesture=$gestureOrdinal '
      'stage=${stage.name} cancel=${cancellationReason.name} '
      'segments=$pointerSegments compositions=$sceneCompositions '
      'repaints=$repaints micros=$elapsedMicros raw=$rawPoints '
      'samples=$authoritativeSamples visual=$visualUpdates pending=$pendingWork '
      'layouts=$layoutRequests hits=$cacheHits transforms=$transformRequests '
      'accepted=$acceptedTargets rejected=$rejectedTargets '
      'operations=$commandOperations terminal=$terminalDisposition '
      'geometry=$geometryResolutions frozenReplays=$frozenReplays '
      'activePaint=$maximumActivePaintPrimitives '
      'retained=$maximumRetainedResources parentBuilds=$parentRebuilds '
      'compactions=$compactions previewPaints=$previewPaints '
      'shiftDown=$shiftKeyDownEvents shiftUp=$shiftKeyUpEvents '
      'shiftPointers=$shiftPointerUpdates snapped=$snappedPreviewUpdates '
      'finalSnap=$finalSnapDisposition chunksRetained=$committedChunksRetained '
      'chunksRebuilt=$committedChunksRebuilt '
      'unchangedReplay=$unchangedObjectsReplayed '
      'newRendered=$newObjectsRendered '
      'committedPainted=$committedPrimitivesPainted '
      'nativeCreated=$nativeResourcesCreated '
      'nativeDisposed=$nativeResourcesDisposed '
      'firstPaints=$firstCommittedPaintInvocations '
      'handwritingTargets=$handwritingTargetCount '
      'shapeTargets=$shapeTargetCount textTargets=$textTargetCount '
      'hoverZone=$hoverZoneCode cursor=$cursorCode '
      'transformMode=$transformModeCode failureStage=$failureStageCode '
      'angleTransitions=$unwrappedAngleTransitions '
      'identityEntries=$identitySectorEntries identityExits=$identitySectorExits '
      'branchCrossings=$branchCutCrossings '
      'rendererPreparations=$rendererPreparations '
      'handwritingPreparations=$handwritingGeometryPreparations '
      'selectionPictures=$selectedContentPictureCreations '
      'framePrimitiveRebuilds=$perTargetPrimitiveRebuilds '
      'unrelatedReplays=$unrelatedCommittedContentReplays '
      'publications=$terminalPublications';
}

/// Small injected ring buffer for bounded, redaction-safe diagnostics.
final class Phase6DiagnosticTrace {
  Phase6DiagnosticTrace._({
    required this.enabled,
    required this.capacity,
    required this.emitToDebugOutput,
  });

  /// Creates a trace with an explicit capacity no larger than 64 events.
  static Result<Phase6DiagnosticTrace, StructuredFailure> create({
    required bool enabled,
    required int capacity,
    bool emitToDebugOutput = false,
  }) {
    if (capacity <= 0 || capacity > 64) {
      return Err(_failure());
    }
    return Ok(
      Phase6DiagnosticTrace._(
        enabled: enabled,
        capacity: capacity,
        emitToDebugOutput: emitToDebugOutput,
      ),
    );
  }

  /// Whether event recording is enabled.
  final bool enabled;

  /// Maximum retained event count.
  final int capacity;

  /// Whether safe text is also emitted to Flutter debug output.
  final bool emitToDebugOutput;

  final List<Phase6DiagnosticEvent> _events = [];
  int _sequence = 0;
  int _gestureOrdinal = 0;

  /// Current immutable events in deterministic oldest-to-newest order.
  List<Phase6DiagnosticEvent> get events => List.unmodifiable(_events);

  /// Starts a new diagnostic gesture and returns its numeric ordinal.
  int beginGesture() {
    if (!enabled) return 0;
    _gestureOrdinal += 1;
    record(stage: Phase6DiagnosticStage.gestureStarted);
    return _gestureOrdinal;
  }

  /// Appends one bounded numeric event, or does nothing when disabled.
  void record({
    required Phase6DiagnosticStage stage,
    Phase6DiagnosticCancellationReason cancellationReason =
        Phase6DiagnosticCancellationReason.none,
    int pointerSegments = 0,
    int sceneCompositions = 0,
    int repaints = 0,
    int elapsedMicros = 0,
    int rawPoints = 0,
    int authoritativeSamples = 0,
    int visualUpdates = 0,
    int pendingWork = 0,
    int layoutRequests = 0,
    int cacheHits = 0,
    int transformRequests = 0,
    int acceptedTargets = 0,
    int rejectedTargets = 0,
    int commandOperations = 0,
    int terminalDisposition = 0,
    int geometryResolutions = 0,
    int frozenReplays = 0,
    int maximumActivePaintPrimitives = 0,
    int maximumRetainedResources = 0,
    int parentRebuilds = 0,
    int compactions = 0,
    int previewPaints = 0,
    int shiftKeyDownEvents = 0,
    int shiftKeyUpEvents = 0,
    int shiftPointerUpdates = 0,
    int snappedPreviewUpdates = 0,
    int finalSnapDisposition = 0,
    int committedChunksRetained = 0,
    int committedChunksRebuilt = 0,
    int unchangedObjectsReplayed = 0,
    int newObjectsRendered = 0,
    int committedPrimitivesPainted = 0,
    int nativeResourcesCreated = 0,
    int nativeResourcesDisposed = 0,
    int firstCommittedPaintInvocations = 0,
    int handwritingTargetCount = 0,
    int shapeTargetCount = 0,
    int textTargetCount = 0,
    int hoverZoneCode = 0,
    int cursorCode = 0,
    int transformModeCode = 0,
    int failureStageCode = 0,
    int unwrappedAngleTransitions = 0,
    int identitySectorEntries = 0,
    int identitySectorExits = 0,
    int branchCutCrossings = 0,
    int rendererPreparations = 0,
    int handwritingGeometryPreparations = 0,
    int selectedContentPictureCreations = 0,
    int perTargetPrimitiveRebuilds = 0,
    int unrelatedCommittedContentReplays = 0,
    int terminalPublications = 0,
  }) {
    if (!enabled ||
        pointerSegments < 0 ||
        sceneCompositions < 0 ||
        repaints < 0 ||
        elapsedMicros < 0 ||
        rawPoints < 0 ||
        authoritativeSamples < 0 ||
        visualUpdates < 0 ||
        pendingWork < 0 ||
        layoutRequests < 0 ||
        cacheHits < 0 ||
        transformRequests < 0 ||
        acceptedTargets < 0 ||
        rejectedTargets < 0 ||
        commandOperations < 0 ||
        terminalDisposition < 0 ||
        geometryResolutions < 0 ||
        frozenReplays < 0 ||
        maximumActivePaintPrimitives < 0 ||
        maximumRetainedResources < 0 ||
        parentRebuilds < 0 ||
        compactions < 0 ||
        previewPaints < 0 ||
        shiftKeyDownEvents < 0 ||
        shiftKeyUpEvents < 0 ||
        shiftPointerUpdates < 0 ||
        snappedPreviewUpdates < 0 ||
        finalSnapDisposition < 0 ||
        committedChunksRetained < 0 ||
        committedChunksRebuilt < 0 ||
        unchangedObjectsReplayed < 0 ||
        newObjectsRendered < 0 ||
        committedPrimitivesPainted < 0 ||
        nativeResourcesCreated < 0 ||
        nativeResourcesDisposed < 0 ||
        firstCommittedPaintInvocations < 0 ||
        handwritingTargetCount < 0 ||
        shapeTargetCount < 0 ||
        textTargetCount < 0 ||
        hoverZoneCode < 0 ||
        cursorCode < 0 ||
        transformModeCode < 0 ||
        failureStageCode < 0 ||
        unwrappedAngleTransitions < 0 ||
        identitySectorEntries < 0 ||
        identitySectorExits < 0 ||
        branchCutCrossings < 0 ||
        rendererPreparations < 0 ||
        handwritingGeometryPreparations < 0 ||
        selectedContentPictureCreations < 0 ||
        perTargetPrimitiveRebuilds < 0 ||
        unrelatedCommittedContentReplays < 0 ||
        terminalPublications < 0) {
      return;
    }
    _sequence += 1;
    final event = Phase6DiagnosticEvent._(
      sequence: _sequence,
      gestureOrdinal: _gestureOrdinal,
      stage: stage,
      cancellationReason: cancellationReason,
      pointerSegments: pointerSegments,
      sceneCompositions: sceneCompositions,
      repaints: repaints,
      elapsedMicros: elapsedMicros,
      rawPoints: rawPoints,
      authoritativeSamples: authoritativeSamples,
      visualUpdates: visualUpdates,
      pendingWork: pendingWork,
      layoutRequests: layoutRequests,
      cacheHits: cacheHits,
      transformRequests: transformRequests,
      acceptedTargets: acceptedTargets,
      rejectedTargets: rejectedTargets,
      commandOperations: commandOperations,
      terminalDisposition: terminalDisposition,
      geometryResolutions: geometryResolutions,
      frozenReplays: frozenReplays,
      maximumActivePaintPrimitives: maximumActivePaintPrimitives,
      maximumRetainedResources: maximumRetainedResources,
      parentRebuilds: parentRebuilds,
      compactions: compactions,
      previewPaints: previewPaints,
      shiftKeyDownEvents: shiftKeyDownEvents,
      shiftKeyUpEvents: shiftKeyUpEvents,
      shiftPointerUpdates: shiftPointerUpdates,
      snappedPreviewUpdates: snappedPreviewUpdates,
      finalSnapDisposition: finalSnapDisposition,
      committedChunksRetained: committedChunksRetained,
      committedChunksRebuilt: committedChunksRebuilt,
      unchangedObjectsReplayed: unchangedObjectsReplayed,
      newObjectsRendered: newObjectsRendered,
      committedPrimitivesPainted: committedPrimitivesPainted,
      nativeResourcesCreated: nativeResourcesCreated,
      nativeResourcesDisposed: nativeResourcesDisposed,
      firstCommittedPaintInvocations: firstCommittedPaintInvocations,
      handwritingTargetCount: handwritingTargetCount,
      shapeTargetCount: shapeTargetCount,
      textTargetCount: textTargetCount,
      hoverZoneCode: hoverZoneCode,
      cursorCode: cursorCode,
      transformModeCode: transformModeCode,
      failureStageCode: failureStageCode,
      unwrappedAngleTransitions: unwrappedAngleTransitions,
      identitySectorEntries: identitySectorEntries,
      identitySectorExits: identitySectorExits,
      branchCutCrossings: branchCutCrossings,
      rendererPreparations: rendererPreparations,
      handwritingGeometryPreparations: handwritingGeometryPreparations,
      selectedContentPictureCreations: selectedContentPictureCreations,
      perTargetPrimitiveRebuilds: perTargetPrimitiveRebuilds,
      unrelatedCommittedContentReplays: unrelatedCommittedContentReplays,
      terminalPublications: terminalPublications,
    );
    if (_events.length == capacity) _events.removeAt(0);
    _events.add(event);
    if (emitToDebugOutput) debugPrint(event.toSafeText());
  }

  /// Returns bounded newline-delimited safe text for debug clipboard export.
  String copyText() => _events.map((event) => event.toSafeText()).join('\n');
}

StructuredFailure _failure() => StructuredFailure(
  code: 'ui.canvas.diagnostics.invalid_configuration',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Canvas diagnostics configuration is invalid.',
);
