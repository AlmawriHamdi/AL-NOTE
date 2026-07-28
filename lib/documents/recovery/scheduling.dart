// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/time/clock.dart';

/// Fully injected Recovery timing and threshold policy with exact units.
final class RecoverySchedulingPolicy {
  const RecoverySchedulingPolicy._({
    required this.quietPeriodMilliseconds,
    required this.maximumDirtyAgeMilliseconds,
    required this.checkpointPeriodMilliseconds,
    required this.maximumJournalTransactions,
    required this.maximumJournalBytes,
    required this.largeChangeBytes,
  });

  /// Creates validated positive scheduling thresholds without defaults.
  static Result<RecoverySchedulingPolicy, StructuredFailure> create({
    required int quietPeriodMilliseconds,
    required int maximumDirtyAgeMilliseconds,
    required int checkpointPeriodMilliseconds,
    required int maximumJournalTransactions,
    required int maximumJournalBytes,
    required int largeChangeBytes,
  }) {
    final values = [
      quietPeriodMilliseconds,
      maximumDirtyAgeMilliseconds,
      checkpointPeriodMilliseconds,
      maximumJournalTransactions,
      maximumJournalBytes,
      largeChangeBytes,
    ];
    return values.every((value) => value > 0 && value <= 9007199254740991)
        ? Ok(
            RecoverySchedulingPolicy._(
              quietPeriodMilliseconds: quietPeriodMilliseconds,
              maximumDirtyAgeMilliseconds: maximumDirtyAgeMilliseconds,
              checkpointPeriodMilliseconds: checkpointPeriodMilliseconds,
              maximumJournalTransactions: maximumJournalTransactions,
              maximumJournalBytes: maximumJournalBytes,
              largeChangeBytes: largeChangeBytes,
            ),
          )
        : Err(_failure('invalid_policy'));
  }

  final int quietPeriodMilliseconds;
  final int maximumDirtyAgeMilliseconds;
  final int checkpointPeriodMilliseconds;
  final int maximumJournalTransactions;
  final int maximumJournalBytes;
  final int largeChangeBytes;
}

/// Closed reasons that can request Recovery publication.
enum RecoveryScheduleReason {
  quietPeriod,
  maximumDirtyAge,
  periodicCheckpoint,
  journalThreshold,
  largeChange,
  lifecycleFlush,
  explicitFlush,
}

/// Cancellable task returned by the injected deterministic task source.
abstract interface class ScheduledTask {
  /// Cancels future callback delivery idempotently.
  void cancel();
}

/// Portable scheduling boundary; production core creates no timers itself.
abstract interface class RecoveryTaskSource {
  /// Schedules one callback after [delay] using adapter-owned time mechanics.
  ScheduledTask schedule(Duration delay, void Function() task);
}

/// Receives a scheduling trigger; `checkpoint` requires a complete checkpoint.
typedef RecoveryScheduleTrigger =
    void Function(RecoveryScheduleReason reason, bool checkpoint);

/// Observable state of Recovery scheduling and trigger delivery.
enum RecoverySchedulingStatus { current, pending, delayed, failed, disposed }

/// Deterministic coordinator for every accepted Recovery scheduling trigger.
final class RecoverySchedulingCoordinator {
  RecoverySchedulingCoordinator({
    required this.policy,
    required this.clock,
    required this.taskSource,
    required this.trigger,
  });

  final RecoverySchedulingPolicy policy;
  final Clock clock;
  final RecoveryTaskSource taskSource;
  final RecoveryScheduleTrigger trigger;
  ScheduledTask? _quietTask;
  ScheduledTask? _maximumAgeTask;
  ScheduledTask? _periodicTask;
  DateTime? _firstDirtyUtc;
  int _journalTransactions = 0;
  int _journalBytes = 0;
  bool _disposed = false;
  bool _mutating = false;
  RecoverySchedulingStatus _status = RecoverySchedulingStatus.current;
  RecoverySchedulingStatus get status => _status;

  /// UTC time at which the current dirty interval began, when pending.
  DateTime? get firstDirtyUtc => _firstDirtyUtc;

  /// Records one committed persistent transition and schedules all applicable
  /// triggers without sleeping or reading wall-clock ordering.
  Result<void, StructuredFailure> committed({required int encodedDeltaBytes}) {
    if (_disposed) return Err(_failure('disposed'));
    if (_mutating) return Err(_failure('reentrant_operation'));
    if (encodedDeltaBytes < 0 || encodedDeltaBytes > 9007199254740991) {
      return Err(_failure('invalid_delta_size'));
    }
    if (_journalTransactions == 9007199254740991 ||
        _journalBytes > 9007199254740991 - encodedDeltaBytes) {
      return Err(_failure('counter_overflow'));
    }
    final previousTransactions = _journalTransactions;
    final previousBytes = _journalBytes;
    final previousDirty = _firstDirtyUtc;
    final previousQuiet = _quietTask;
    final previousMaximumAge = _maximumAgeTask;
    final previousPeriodic = _periodicTask;
    final nextTransactions = previousTransactions + 1;
    final nextBytes = previousBytes + encodedDeltaBytes;
    DateTime? dirty = previousDirty;
    ScheduledTask? quiet, maximumAge, periodic;
    var quietDelivered = false;
    var maximumDelivered = false;
    var periodicDelivered = false;
    _mutating = true;
    try {
      dirty ??= clock.nowUtc();
      if (!dirty.isUtc) throw StateError('non_utc_clock');
      late ScheduledTask quietValue;
      quietValue = taskSource.schedule(
        Duration(milliseconds: policy.quietPeriodMilliseconds),
        () {
          if (_mutating) {
            quietDelivered = true;
            return;
          }
          _fire(
            quietValue,
            RecoveryScheduleReason.quietPeriod,
            checkpoint: false,
          );
        },
      );
      quiet = quietValue;
      if (previousMaximumAge == null) {
        late ScheduledTask maximumValue;
        maximumValue = taskSource.schedule(
          Duration(milliseconds: policy.maximumDirtyAgeMilliseconds),
          () {
            if (_mutating) {
              maximumDelivered = true;
              return;
            }
            _fire(
              maximumValue,
              RecoveryScheduleReason.maximumDirtyAge,
              checkpoint: false,
            );
          },
        );
        maximumAge = maximumValue;
      }
      if (previousPeriodic == null) {
        late ScheduledTask periodicValue;
        periodicValue = taskSource.schedule(
          Duration(milliseconds: policy.checkpointPeriodMilliseconds),
          () {
            if (_mutating) {
              periodicDelivered = true;
              return;
            }
            _fire(
              periodicValue,
              RecoveryScheduleReason.periodicCheckpoint,
              checkpoint: true,
            );
          },
        );
        periodic = periodicValue;
      }
      if (_disposed) {
        _cancelAll([quiet, maximumAge, periodic]);
        _mutating = false;
        return Err(_failure('disposed'));
      }
      _journalTransactions = nextTransactions;
      _journalBytes = nextBytes;
      _firstDirtyUtc = dirty;
      _quietTask = quiet;
      _maximumAgeTask = previousMaximumAge ?? maximumAge;
      _periodicTask = previousPeriodic ?? periodic;
      _status = RecoverySchedulingStatus.pending;
      final reason = encodedDeltaBytes >= policy.largeChangeBytes
          ? RecoveryScheduleReason.largeChange
          : nextTransactions >= policy.maximumJournalTransactions ||
                nextBytes >= policy.maximumJournalBytes
          ? RecoveryScheduleReason.journalThreshold
          : null;
      if (reason != null) trigger(reason, true);
      if (_disposed) {
        _mutating = false;
        return Err(_failure('disposed'));
      }
    } on Object {
      if (!_disposed) {
        _journalTransactions = previousTransactions;
        _journalBytes = previousBytes;
        _firstDirtyUtc = previousDirty;
        _quietTask = previousQuiet;
        _maximumAgeTask = previousMaximumAge;
        _periodicTask = previousPeriodic;
        _status = RecoverySchedulingStatus.failed;
      }
      _cancelAll([quiet, maximumAge, periodic]);
      _mutating = false;
      return Err(_failure('scheduling_failure'));
    }
    _mutating = false;
    var cancellationFailed = false;
    if (previousQuiet != null && !identical(previousQuiet, quiet)) {
      cancellationFailed = _cancelAll([previousQuiet]);
    }
    if (_disposed) return Err(_failure('disposed'));
    var deliveredFailure = false;
    if (quietDelivered &&
        _fire(quiet, RecoveryScheduleReason.quietPeriod, checkpoint: false)
            is Err<void, StructuredFailure>) {
      deliveredFailure = true;
    }
    if (maximumDelivered &&
        _fire(
              maximumAge,
              RecoveryScheduleReason.maximumDirtyAge,
              checkpoint: false,
            )
            is Err<void, StructuredFailure>) {
      deliveredFailure = true;
    }
    if (periodicDelivered &&
        _fire(
              periodic,
              RecoveryScheduleReason.periodicCheckpoint,
              checkpoint: true,
            )
            is Err<void, StructuredFailure>) {
      deliveredFailure = true;
    }
    if (_disposed) return Err(_failure('disposed'));
    if (deliveredFailure) return Err(_failure('trigger_failure'));
    if (cancellationFailed) {
      _status = RecoverySchedulingStatus.failed;
      return Err(_failure('task_cancellation_failure'));
    }
    return const Ok(null);
  }

  /// Requests a best-effort lifecycle flush immediately.
  Result<void, StructuredFailure> lifecycleFlush() => _mutating
      ? Err(_failure('reentrant_operation'))
      : _emit(RecoveryScheduleReason.lifecycleFlush, false);

  /// Requests an explicit flush immediately.
  Result<void, StructuredFailure> explicitFlush() => _mutating
      ? Err(_failure('reentrant_operation'))
      : _emit(RecoveryScheduleReason.explicitFlush, false);

  /// Records a durable boundary and resets dirty/journal scheduling facts.
  ///
  /// Cancellation failures are redacted and returned after every obsolete task
  /// reference has been made identity-inert.
  Result<void, StructuredFailure> durableBoundary({required bool checkpoint}) {
    if (_disposed) return Err(_failure('disposed'));
    if (_mutating) return Err(_failure('reentrant_operation'));
    _firstDirtyUtc = null;
    final quiet = _quietTask;
    final maximumAge = _maximumAgeTask;
    final periodic = checkpoint ? _periodicTask : null;
    _quietTask = null;
    _maximumAgeTask = null;
    if (checkpoint) {
      _journalTransactions = 0;
      _journalBytes = 0;
      _periodicTask = null;
    }
    _status = RecoverySchedulingStatus.current;
    final failed = _cancelAll([quiet, maximumAge, periodic]);
    return failed ? Err(_failure('task_cancellation_failure')) : const Ok(null);
  }

  /// Cancels scheduled callbacks idempotently.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _status = RecoverySchedulingStatus.disposed;
    for (final task in [_quietTask, _maximumAgeTask, _periodicTask]) {
      try {
        task?.cancel();
      } on Object {
        // Disposal is terminal; references below are made identity-inert.
      }
    }
    _quietTask = null;
    _maximumAgeTask = null;
    _periodicTask = null;
  }

  Result<void, StructuredFailure> _emit(
    RecoveryScheduleReason reason,
    bool checkpoint,
  ) {
    if (_disposed) return Err(_failure('disposed'));
    if (_mutating) return Err(_failure('reentrant_operation'));
    _mutating = true;
    try {
      trigger(reason, checkpoint);
      if (_disposed) return Err(_failure('disposed'));
      return const Ok(null);
    } on Object {
      if (!_disposed) _status = RecoverySchedulingStatus.failed;
      return Err(_failure('trigger_failure'));
    } finally {
      _mutating = false;
    }
  }

  Result<void, StructuredFailure> _fire(
    ScheduledTask? task,
    RecoveryScheduleReason reason, {
    required bool checkpoint,
  }) {
    if (_disposed) return Err(_failure('disposed'));
    if (task == null) return const Ok(null);
    final current = switch (reason) {
      RecoveryScheduleReason.quietPeriod => _quietTask,
      RecoveryScheduleReason.maximumDirtyAge => _maximumAgeTask,
      RecoveryScheduleReason.periodicCheckpoint => _periodicTask,
      _ => null,
    };
    if (!identical(current, task)) return const Ok(null);
    switch (reason) {
      case RecoveryScheduleReason.quietPeriod:
        _quietTask = null;
      case RecoveryScheduleReason.maximumDirtyAge:
        _maximumAgeTask = null;
      case RecoveryScheduleReason.periodicCheckpoint:
        _periodicTask = null;
      case RecoveryScheduleReason.journalThreshold:
      case RecoveryScheduleReason.largeChange:
      case RecoveryScheduleReason.lifecycleFlush:
      case RecoveryScheduleReason.explicitFlush:
        return const Ok(null);
    }
    return _emit(reason, checkpoint);
  }

  bool _cancelAll(Iterable<ScheduledTask?> tasks) {
    var failed = false;
    for (final task in tasks) {
      try {
        task?.cancel();
      } on Object {
        failed = true;
      }
    }
    return failed;
  }
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.recovery.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Recovery scheduling policy is invalid.',
);
