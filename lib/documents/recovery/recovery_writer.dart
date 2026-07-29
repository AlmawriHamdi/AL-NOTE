// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import 'contracts.dart';

/// Immutable committed boundary captured while editing continues.
final class RecoveryBoundary<T> {
  const RecoveryBoundary._({
    required this.state,
    required this.requiresCheckpoint,
    required this.nonDroppableTransitions,
  });
  final T state;
  final bool requiresCheckpoint;
  final int nonDroppableTransitions;

  /// Creates a boundary with a positive Web-safe transition count.
  static Result<RecoveryBoundary<T>, StructuredFailure> create<T>({
    required T state,
    required bool requiresCheckpoint,
    required int nonDroppableTransitions,
  }) =>
      nonDroppableTransitions > 0 && nonDroppableTransitions <= 9007199254740991
      ? Ok(
          RecoveryBoundary._(
            state: state,
            requiresCheckpoint: requiresCheckpoint,
            nonDroppableTransitions: nonDroppableTransitions,
          ),
        )
      : Err(_failure('invalid_boundary'));
}

/// Publishes one exact captured Recovery boundary.
typedef RecoveryBoundaryPublisher<T> =
    Future<OperationOutcome<void, StructuredFailure>> Function(
      RecoveryBoundary<T> boundary,
      CancellationToken cancellationToken,
    );

/// Observes post-transition Recovery status.
typedef RecoveryStatusListener = void Function(RecoveryStatus status);

/// Deterministic flush completion distinct from Recovery status.
enum RecoveryFlushDisposition { completed, delayed, failed }

/// Serializes writes and retains one newest safely coalesced pending boundary.
final class RecoveryWriter<T> {
  RecoveryWriter({
    required this.publisher,
    required this.maximumRetryAttempts,
    required this.maximumListeners,
  });
  final RecoveryBoundaryPublisher<T> publisher;
  final int maximumRetryAttempts;
  final int maximumListeners;
  final List<RecoveryStatusListener> _listeners = [];
  _PendingBoundary<T>? _pending;
  bool _active = false;
  RecoveryStatus _status = RecoveryStatus.current;
  Completer<RecoveryFlushDisposition>? _idle;

  /// Current per-document protection status.
  RecoveryStatus get status => _status;

  /// Adds a listener using snapshot mutation and exception isolation semantics.
  Result<void, StructuredFailure> addListener(RecoveryStatusListener listener) {
    if (_listeners.contains(listener)) return const Ok(null);
    if (maximumListeners < 0 ||
        maximumListeners > 9007199254740991 ||
        _listeners.length >= maximumListeners) {
      return Err(_failure('listener_limit'));
    }
    _listeners.add(listener);
    return const Ok(null);
  }

  /// Removes a listener from later status notifications.
  void removeListener(RecoveryStatusListener listener) =>
      _listeners.remove(listener);

  /// Schedules a boundary with its own cancellation context.
  Result<void, StructuredFailure> schedule(
    RecoveryBoundary<T> boundary, {
    required CancellationToken cancellationToken,
  }) {
    if (maximumRetryAttempts < 0) return Err(_failure('invalid_retry_limit'));
    final prior = _pending;
    if (prior == null) {
      _pending = _PendingBoundary(boundary, cancellationToken);
    } else {
      if (prior.boundary.nonDroppableTransitions >
          9007199254740991 - boundary.nonDroppableTransitions) {
        return Err(_failure('coalescing_overflow'));
      }
      final transitions =
          prior.boundary.nonDroppableTransitions +
          boundary.nonDroppableTransitions;
      final coalesced = RecoveryBoundary<T>._(
        state: boundary.state,
        requiresCheckpoint:
            prior.boundary.requiresCheckpoint ||
            boundary.requiresCheckpoint ||
            transitions > 1,
        nonDroppableTransitions: transitions,
      );
      _pending = _PendingBoundary(coalesced, cancellationToken);
    }
    _setStatus(RecoveryStatus.pending);
    _idle ??= Completer<RecoveryFlushDisposition>();
    if (!_active) unawaited(_drain());
    return const Ok(null);
  }

  /// Completes when current pending work becomes durable or deterministically
  /// stops as delayed/failed. It never waits for future boundaries.
  Future<RecoveryFlushDisposition> flush() {
    if (!_active) {
      return Future.value(
        _status == RecoveryStatus.current
            ? RecoveryFlushDisposition.completed
            : _status == RecoveryStatus.failed
            ? RecoveryFlushDisposition.failed
            : RecoveryFlushDisposition.delayed,
      );
    }
    return (_idle ??= Completer<RecoveryFlushDisposition>()).future;
  }

  /// Explicitly retries the retained newest boundary with fresh cancellation.
  Result<void, StructuredFailure> retry({
    required CancellationToken cancellationToken,
  }) {
    if (_active) return Err(_failure('writer_active'));
    final pending = _pending;
    if (pending == null) return Err(_failure('nothing_pending'));
    _pending = _PendingBoundary(pending.boundary, cancellationToken);
    _idle = Completer<RecoveryFlushDisposition>();
    _setStatus(RecoveryStatus.pending);
    unawaited(_drain());
    return const Ok(null);
  }

  Future<void> _drain() async {
    if (_active) return;
    _active = true;
    RecoveryFlushDisposition disposition = RecoveryFlushDisposition.completed;
    while (_pending != null) {
      final pending = _pending!;
      if (pending.token.isCancelled) {
        _setStatus(RecoveryStatus.delayed);
        disposition = RecoveryFlushDisposition.delayed;
        break;
      }
      var attempt = 0;
      OperationOutcome<void, StructuredFailure>? result;
      while (attempt <= maximumRetryAttempts && !pending.token.isCancelled) {
        attempt += 1;
        try {
          result = await publisher(pending.boundary, pending.token);
        } on Object {
          result = Failed(_failure('writer_failure'));
        }
        if (result is Completed<void, StructuredFailure> ||
            result is Cancelled<void, StructuredFailure>) {
          break;
        }
        if (result is Failed<void, StructuredFailure> &&
            result.failure.retryDisposition != RetryDisposition.retryable) {
          break;
        }
      }
      if (result is Completed<void, StructuredFailure>) {
        if (identical(_pending, pending)) _pending = null;
        _setStatus(
          _pending == null ? RecoveryStatus.current : RecoveryStatus.pending,
        );
        continue;
      }
      if (result is Cancelled<void, StructuredFailure> ||
          pending.token.isCancelled) {
        _setStatus(RecoveryStatus.delayed);
        disposition = RecoveryFlushDisposition.delayed;
      } else {
        _setStatus(RecoveryStatus.failed);
        disposition = RecoveryFlushDisposition.failed;
      }
      break;
    }
    _active = false;
    final completer = _idle;
    _idle = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(disposition);
    }
  }

  void _setStatus(RecoveryStatus value) {
    if (_status == value) return;
    _status = value;
    for (final listener in List<RecoveryStatusListener>.of(_listeners)) {
      try {
        listener(value);
      } on Object {
        // Listener exceptions never change Recovery state.
      }
    }
  }
}

final class _PendingBoundary<T> {
  const _PendingBoundary(this.boundary, this.token);
  final RecoveryBoundary<T> boundary;
  final CancellationToken token;
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.recovery.$leaf',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.retryable,
  message: 'The Recovery writer boundary failed.',
);
