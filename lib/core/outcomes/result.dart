// SPDX-License-Identifier: GPL-3.0-or-later

/// The result of an operation that either succeeds with [T] or fails with [E].
sealed class Result<T, E> {
  /// Creates a result for use by the sealed result variants.
  const Result();

  /// Transforms a successful value while preserving an error unchanged.
  Result<R, E> map<R>(R Function(T value) transform);

  /// Transforms an error while preserving a successful value unchanged.
  Result<T, F> mapError<F>(F Function(E error) transform);

  /// Reduces this result by handling both possible variants.
  R fold<R>({
    required R Function(T value) onOk,
    required R Function(E error) onErr,
  });
}

/// A successful [Result] containing [value].
final class Ok<T, E> extends Result<T, E> {
  /// Creates a successful result.
  const Ok(this.value);

  /// The successful value.
  final T value;

  @override
  Result<R, E> map<R>(R Function(T value) transform) =>
      Ok<R, E>(transform(value));

  @override
  Result<T, F> mapError<F>(F Function(E error) transform) => Ok<T, F>(value);

  @override
  R fold<R>({
    required R Function(T value) onOk,
    required R Function(E error) onErr,
  }) => onOk(value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Ok<T, E> && other.value == value;

  @override
  int get hashCode => Object.hash(Ok, value);

  @override
  String toString() => 'Ok($value)';
}

/// A failed [Result] containing [error].
final class Err<T, E> extends Result<T, E> {
  /// Creates a failed result.
  const Err(this.error);

  /// The error value.
  final E error;

  @override
  Result<R, E> map<R>(R Function(T value) transform) => Err<R, E>(error);

  @override
  Result<T, F> mapError<F>(F Function(E error) transform) =>
      Err<T, F>(transform(error));

  @override
  R fold<R>({
    required R Function(T value) onOk,
    required R Function(E error) onErr,
  }) => onErr(error);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Err<T, E> && other.error == error;

  @override
  int get hashCode => Object.hash(Err, error);

  @override
  String toString() => 'Err($error)';
}
