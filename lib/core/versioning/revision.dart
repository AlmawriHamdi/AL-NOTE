// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// A nonnegative, Web-safe monotonically ordered revision.
final class Revision implements Comparable<Revision> {
  const Revision._(this.value);

  /// The largest integer that is represented exactly on all supported Web
  /// runtimes.
  static const int maximumValue = 9007199254740991;

  /// Creates a revision between zero and [maximumValue], inclusive.
  static Result<Revision, StructuredFailure> create(int value) {
    if (value < 0 || value > maximumValue) {
      return Err<Revision, StructuredFailure>(
        StructuredFailure(
          code: 'core.versioning.invalid_revision',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'Revision must be a nonnegative Web-safe integer.',
        ),
      );
    }
    return Ok<Revision, StructuredFailure>(Revision._(value));
  }

  /// The nonnegative Web-safe integer revision.
  final int value;

  /// Returns the next revision or a structured overflow failure.
  Result<Revision, StructuredFailure> increment() {
    if (value == maximumValue) {
      return Err<Revision, StructuredFailure>(
        StructuredFailure(
          code: 'core.versioning.revision_overflow',
          category: FailureCategory.resource,
          retryDisposition: RetryDisposition.never,
          message: 'The maximum Web-safe revision cannot be incremented.',
        ),
      );
    }
    return Ok<Revision, StructuredFailure>(Revision._(value + 1));
  }

  @override
  int compareTo(Revision other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Revision && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value.toString();
}
