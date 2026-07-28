// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';

/// Advisory normalized platform lifecycle facts; final delivery is not guaranteed.
enum PlatformLifecycleKind {
  foreground,
  background,
  hidden,
  suspensionWarning,
  suspended,
  resume,
  memoryPressure,
  lowStorage,
  exitRequest,
  windowClosing,
  externalActivation,
  restorationOpportunity,
  safeMode,
}

/// Immutable advisory lifecycle event with a deterministic source sequence.
final class PlatformLifecycleEvent {
  const PlatformLifecycleEvent._({required this.kind, required this.sequence});
  static Result<PlatformLifecycleEvent, StructuredFailure> create({
    required PlatformLifecycleKind kind,
    required int sequence,
  }) => sequence >= 0 && sequence <= 9007199254740991
      ? Ok(PlatformLifecycleEvent._(kind: kind, sequence: sequence))
      : Err(
          StructuredFailure(
            code: 'platform.lifecycle.invalid_sequence',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'The lifecycle event is invalid.',
          ),
        );
  final PlatformLifecycleKind kind;
  final int sequence;
  @override
  String toString() => 'PlatformLifecycleEvent(${kind.name}, $sequence)';
}

/// Validates strictly monotonic adapter lifecycle publication.
final class PlatformLifecycleSequencer {
  int _last = -1;
  Result<PlatformLifecycleEvent, StructuredFailure> next({
    required PlatformLifecycleKind kind,
    required int sequence,
  }) {
    if (sequence <= _last) {
      return Err(
        StructuredFailure(
          code: 'platform.lifecycle.non_monotonic_sequence',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'The lifecycle event is invalid.',
        ),
      );
    }
    final value = PlatformLifecycleEvent.create(kind: kind, sequence: sequence);
    if (value is Ok<PlatformLifecycleEvent, StructuredFailure>)
      _last = sequence;
    return value;
  }
}

/// Portable lifecycle subscription. Consumers cannot rely on a final event.
abstract interface class PlatformLifecycleSource {
  Stream<PlatformLifecycleEvent> get events;
}
