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

  /// Fixed-label representation containing no document or pointer data.
  String toSafeText() =>
      'phase6_diag seq=$sequence gesture=$gestureOrdinal '
      'stage=${stage.name} cancel=${cancellationReason.name} '
      'segments=$pointerSegments compositions=$sceneCompositions '
      'repaints=$repaints micros=$elapsedMicros';
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
  }) {
    if (!enabled ||
        pointerSegments < 0 ||
        sceneCompositions < 0 ||
        repaints < 0 ||
        elapsedMicros < 0) {
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
