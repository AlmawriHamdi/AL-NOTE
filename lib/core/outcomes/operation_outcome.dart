// SPDX-License-Identifier: GPL-3.0-or-later

/// The terminal outcome of an operation.
///
/// Cancellation is represented independently from both completion and failure.
sealed class OperationOutcome<T, F> {
  /// Creates an outcome for use by the sealed outcome variants.
  const OperationOutcome();

  /// Reduces this outcome by handling every terminal variant.
  R fold<R>({
    required R Function(T value) onCompleted,
    required R Function(F failure) onFailed,
    required R Function(String? reason) onCancelled,
  });
}

/// An operation that completed successfully with [value].
final class Completed<T, F> extends OperationOutcome<T, F> {
  /// Creates a completed outcome.
  const Completed(this.value);

  /// The completed value.
  final T value;

  @override
  R fold<R>({
    required R Function(T value) onCompleted,
    required R Function(F failure) onFailed,
    required R Function(String? reason) onCancelled,
  }) => onCompleted(value);
}

/// An operation that terminated with [failure].
final class Failed<T, F> extends OperationOutcome<T, F> {
  /// Creates a failed outcome.
  const Failed(this.failure);

  /// The failure that terminated the operation.
  final F failure;

  @override
  R fold<R>({
    required R Function(T value) onCompleted,
    required R Function(F failure) onFailed,
    required R Function(String? reason) onCancelled,
  }) => onFailed(failure);
}

/// An operation that was cancelled for an optional [reason].
final class Cancelled<T, F> extends OperationOutcome<T, F> {
  /// Creates a cancelled outcome.
  const Cancelled([this.reason]);

  /// The first reason supplied when cancellation was requested.
  final String? reason;

  @override
  R fold<R>({
    required R Function(T value) onCompleted,
    required R Function(F failure) onFailed,
    required R Function(String? reason) onCancelled,
  }) => onCancelled(reason);
}
