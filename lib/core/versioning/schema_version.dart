// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// A positive schema version.
final class SchemaVersion implements Comparable<SchemaVersion> {
  const SchemaVersion._(this.value);

  /// Creates a schema version when [value] is positive.
  static Result<SchemaVersion, StructuredFailure> create(int value) {
    if (value <= 0) {
      return Err<SchemaVersion, StructuredFailure>(
        StructuredFailure(
          code: 'core.versioning.invalid_schema_version',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'Schema versions must be positive.',
        ),
      );
    }
    return Ok<SchemaVersion, StructuredFailure>(SchemaVersion._(value));
  }

  /// The positive integer version.
  final int value;

  @override
  int compareTo(SchemaVersion other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SchemaVersion && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value.toString();
}
