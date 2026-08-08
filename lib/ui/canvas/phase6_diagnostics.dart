// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';

/// Closed debug-only Phase 6 diagnostic stages.
enum Phase6DiagnosticStage {
  gestureStarted,
  cursorRepaintRequested,
  cursorRepaintCompleted,
  visualPreviewCompleted,
  partialPrepareEntered,
  partialPrepareCompleted,
  partialMoveEntered,
  partialMoveCompleted,
  partialMoveFailed,
  candidateIndexQuery,
  intervalClassification,
  temporaryGeometryCreation,
  intervalMerge,
  survivorEvidenceRebuild,
  previewPrimitiveCreation,
  partialTerminalEntered,
  partialTerminalCompleted,
  partialTerminalFailed,
  terminalMaterialization,
  uuidAllocation,
  commandPublication,
  pointerUpToPublication,
  terminalSummary,
  sceneComposition,
  repaintScheduled,
  gestureCancelled,
}

/// Closed redaction-safe diagnostic failure categories.
enum Phase6DiagnosticFailure { none, workLimit, geometry, preview, terminal }

/// One immutable numeric-only Phase 6 diagnostic event.
final class Phase6DiagnosticEvent {
  const Phase6DiagnosticEvent._({
    required this.sequence,
    required this.gestureOrdinal,
    required this.stage,
    required this.failure,
    required this.pointerSegments,
    required this.candidateObjects,
    required this.candidateStrokes,
    required this.candidateSourceSegments,
    required this.spatialElements,
    required this.classifications,
    required this.geometryResolutions,
    required this.classificationChecks,
    required this.maximumSearchDepth,
    required this.maximumPendingIntervals,
    required this.intervalMerges,
    required this.survivorRanges,
    required this.previewPrimitives,
    required this.terminalPasses,
    required this.fragments,
    required this.uuidAllocations,
    required this.sceneCompositions,
    required this.repaints,
    required this.elapsedMicros,
    required this.eventBacklog,
    required this.processedBatchSize,
    required this.workBudgetUsed,
    required this.workBudgetRemaining,
    required this.rawPointerEvents,
    required this.cursorRepaintRequests,
    required this.cursorRepaints,
    required this.processingBatches,
    required this.survivorCompositions,
    required this.maximumBacklog,
    required this.candidateResumptions,
    required this.visualPathSegments,
    required this.visualPathChunks,
    required this.visualPreviewRequests,
    required this.visualPreviewRepaints,
    required this.visualObjectLayers,
    required this.maximumVisualBacklog,
    required this.exactProcessingBacklog,
  });

  final int sequence;

  /// Non-sensitive process-local gesture ordinal.
  final int gestureOrdinal;
  final Phase6DiagnosticStage stage;
  final Phase6DiagnosticFailure failure;
  final int pointerSegments;
  final int candidateObjects;
  final int candidateStrokes;
  final int candidateSourceSegments;
  final int spatialElements;
  final int classifications;
  final int geometryResolutions;
  final int classificationChecks;
  final int maximumSearchDepth;
  final int maximumPendingIntervals;
  final int intervalMerges;
  final int survivorRanges;
  final int previewPrimitives;
  final int terminalPasses;
  final int fragments;
  final int uuidAllocations;
  final int sceneCompositions;
  final int repaints;

  /// Debug-only elapsed microseconds for this bounded stage invocation.
  final int elapsedMicros;

  /// Pending accepted UI events when this stage completed.
  final int eventBacklog;

  /// Pointer points processed by this bounded invocation.
  final int processedBatchSize;

  /// Aggregate deterministic work units consumed by the gesture.
  final int workBudgetUsed;

  /// Remaining deterministic work units for the gesture.
  final int workBudgetRemaining;

  /// Raw owned pointer events received for the gesture.
  final int rawPointerEvents;

  /// Coalescible cursor repaint requests received.
  final int cursorRepaintRequests;

  /// Cursor frames actually painted.
  final int cursorRepaints;

  /// Survivor-processing batches completed.
  final int processingBatches;

  /// Survivor-preview compositions completed.
  final int survivorCompositions;

  /// Maximum pending pointer backlog observed.
  final int maximumBacklog;

  /// Partially processed candidate continuations.
  final int candidateResumptions;

  /// View-local swept capsules accepted without exact geometry work.
  final int visualPathSegments;

  /// Frozen stable mask chunks retained by the visual layer.
  final int visualPathChunks;

  /// Coalescible visual-preview repaint requests.
  final int visualPreviewRequests;

  /// Visual-preview frames actually painted.
  final int visualPreviewRepaints;

  /// Eligible Object layers composited by the latest visual frame.
  final int visualObjectLayers;

  /// Maximum visual segments accumulated between display frames.
  final int maximumVisualBacklog;

  /// Exact pointer points waiting for bounded processing.
  final int exactProcessingBacklog;

  /// Fixed-label representation containing no document or pointer data.
  String toSafeText() =>
      'phase6_diag seq=$sequence gesture=$gestureOrdinal '
      'stage=${stage.name} failure=${failure.name} micros=$elapsedMicros '
      'backlog=$eventBacklog batch=$processedBatchSize '
      'budgetUsed=$workBudgetUsed budgetRemaining=$workBudgetRemaining '
      'rawPointers=$rawPointerEvents cursorRequests=$cursorRepaintRequests '
      'cursorRepaints=$cursorRepaints batches=$processingBatches '
      'survivorCompositions=$survivorCompositions maxBacklog=$maximumBacklog '
      'candidateResumptions=$candidateResumptions '
      'visualSegments=$visualPathSegments visualChunks=$visualPathChunks '
      'visualRequests=$visualPreviewRequests '
      'visualRepaints=$visualPreviewRepaints '
      'visualLayers=$visualObjectLayers '
      'maxVisualBacklog=$maximumVisualBacklog '
      'exactBacklog=$exactProcessingBacklog '
      'segments=$pointerSegments objects=$candidateObjects '
      'strokes=$candidateStrokes sourceSegments=$candidateSourceSegments '
      'spatial=$spatialElements classifications=$classifications '
      'geometry=$geometryResolutions checks=$classificationChecks '
      'depth=$maximumSearchDepth pending=$maximumPendingIntervals '
      'merges=$intervalMerges survivors=$survivorRanges '
      'previews=$previewPrimitives terminal=$terminalPasses '
      'fragments=$fragments uuids=$uuidAllocations '
      'compositions=$sceneCompositions repaints=$repaints';
}

/// Small injected ring buffer for bounded debug/test Phase 6 diagnostics.
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

  final bool enabled;
  final int capacity;
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
    Phase6DiagnosticFailure failure = Phase6DiagnosticFailure.none,
    int pointerSegments = 0,
    int candidateObjects = 0,
    int candidateStrokes = 0,
    int candidateSourceSegments = 0,
    int spatialElements = 0,
    int classifications = 0,
    int geometryResolutions = 0,
    int classificationChecks = 0,
    int maximumSearchDepth = 0,
    int maximumPendingIntervals = 0,
    int intervalMerges = 0,
    int survivorRanges = 0,
    int previewPrimitives = 0,
    int terminalPasses = 0,
    int fragments = 0,
    int uuidAllocations = 0,
    int sceneCompositions = 0,
    int repaints = 0,
    int elapsedMicros = 0,
    int eventBacklog = 0,
    int processedBatchSize = 0,
    int workBudgetUsed = 0,
    int workBudgetRemaining = 0,
    int rawPointerEvents = 0,
    int cursorRepaintRequests = 0,
    int cursorRepaints = 0,
    int processingBatches = 0,
    int survivorCompositions = 0,
    int maximumBacklog = 0,
    int candidateResumptions = 0,
    int visualPathSegments = 0,
    int visualPathChunks = 0,
    int visualPreviewRequests = 0,
    int visualPreviewRepaints = 0,
    int visualObjectLayers = 0,
    int maximumVisualBacklog = 0,
    int exactProcessingBacklog = 0,
  }) {
    if (!enabled) return;
    final counts = [
      pointerSegments,
      candidateObjects,
      candidateStrokes,
      candidateSourceSegments,
      spatialElements,
      classifications,
      geometryResolutions,
      classificationChecks,
      maximumSearchDepth,
      maximumPendingIntervals,
      intervalMerges,
      survivorRanges,
      previewPrimitives,
      terminalPasses,
      fragments,
      uuidAllocations,
      sceneCompositions,
      repaints,
      elapsedMicros,
      eventBacklog,
      processedBatchSize,
      workBudgetUsed,
      workBudgetRemaining,
      rawPointerEvents,
      cursorRepaintRequests,
      cursorRepaints,
      processingBatches,
      survivorCompositions,
      maximumBacklog,
      candidateResumptions,
      visualPathSegments,
      visualPathChunks,
      visualPreviewRequests,
      visualPreviewRepaints,
      visualObjectLayers,
      maximumVisualBacklog,
      exactProcessingBacklog,
    ];
    if (counts.any((value) => value < 0 || value > Revision.maximumValue)) {
      return;
    }
    final event = Phase6DiagnosticEvent._(
      sequence: _sequence++,
      gestureOrdinal: _gestureOrdinal,
      stage: stage,
      failure: failure,
      pointerSegments: pointerSegments,
      candidateObjects: candidateObjects,
      candidateStrokes: candidateStrokes,
      candidateSourceSegments: candidateSourceSegments,
      spatialElements: spatialElements,
      classifications: classifications,
      geometryResolutions: geometryResolutions,
      classificationChecks: classificationChecks,
      maximumSearchDepth: maximumSearchDepth,
      maximumPendingIntervals: maximumPendingIntervals,
      intervalMerges: intervalMerges,
      survivorRanges: survivorRanges,
      previewPrimitives: previewPrimitives,
      terminalPasses: terminalPasses,
      fragments: fragments,
      uuidAllocations: uuidAllocations,
      sceneCompositions: sceneCompositions,
      repaints: repaints,
      elapsedMicros: elapsedMicros,
      eventBacklog: eventBacklog,
      processedBatchSize: processedBatchSize,
      workBudgetUsed: workBudgetUsed,
      workBudgetRemaining: workBudgetRemaining,
      rawPointerEvents: rawPointerEvents,
      cursorRepaintRequests: cursorRepaintRequests,
      cursorRepaints: cursorRepaints,
      processingBatches: processingBatches,
      survivorCompositions: survivorCompositions,
      maximumBacklog: maximumBacklog,
      candidateResumptions: candidateResumptions,
      visualPathSegments: visualPathSegments,
      visualPathChunks: visualPathChunks,
      visualPreviewRequests: visualPreviewRequests,
      visualPreviewRepaints: visualPreviewRepaints,
      visualObjectLayers: visualObjectLayers,
      maximumVisualBacklog: maximumVisualBacklog,
      exactProcessingBacklog: exactProcessingBacklog,
    );
    if (_events.length == capacity) _events.removeAt(0);
    _events.add(event);
    if (emitToDebugOutput &&
        kDebugMode &&
        (stage == Phase6DiagnosticStage.gestureStarted ||
            elapsedMicros >= 16000 ||
            failure != Phase6DiagnosticFailure.none ||
            stage == Phase6DiagnosticStage.terminalSummary)) {
      debugPrint(event.toSafeText());
    }
  }

  /// Bounded copyable redaction-safe text for the debug Canvas control.
  String copyText() {
    if (!enabled || _events.isEmpty) return '';
    final gesture = _gestureOrdinal;
    final current = _events.where((event) => event.gestureOrdinal == gesture);
    final totals = <Phase6DiagnosticStage, (int, int, int)>{};
    for (final event in current) {
      final prior = totals[event.stage] ?? (0, 0, 0);
      totals[event.stage] = (
        prior.$1 + event.elapsedMicros,
        math.max(prior.$2, event.elapsedMicros),
        prior.$3 + 1,
      );
    }
    Phase6DiagnosticStage? dominant;
    var dominantMicros = -1;
    for (final entry in totals.entries) {
      if (entry.value.$1 > dominantMicros) {
        dominant = entry.key;
        dominantMicros = entry.value.$1;
      }
    }
    final summary = dominant == null
        ? ''
        : 'phase6_summary gesture=$gesture dominant=${dominant.name} '
              'totalMicros=$dominantMicros maxMicros=${totals[dominant]!.$2} '
              'invocations=${totals[dominant]!.$3}';
    String stageSummary(String label, Phase6DiagnosticStage stage) {
      final evidence = totals[stage] ?? (0, 0, 0);
      return 'phase6_${label}_summary gesture=$gesture '
          'totalMicros=${evidence.$1} maxMicros=${evidence.$2} '
          'invocations=${evidence.$3}';
    }

    return [
      ..._events.map((event) => event.toSafeText()),
      stageSummary('cursor', Phase6DiagnosticStage.cursorRepaintCompleted),
      stageSummary('visual', Phase6DiagnosticStage.visualPreviewCompleted),
      stageSummary(
        'classification',
        Phase6DiagnosticStage.intervalClassification,
      ),
      stageSummary(
        'terminal_materialization',
        Phase6DiagnosticStage.terminalMaterialization,
      ),
      stageSummary('publication', Phase6DiagnosticStage.commandPublication),
      summary,
    ].where((value) => value.isNotEmpty).join('\n');
  }
}

StructuredFailure _failure() => StructuredFailure(
  code: 'ui.canvas.invalid_diagnostic_trace',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'The diagnostic trace configuration is invalid.',
);
