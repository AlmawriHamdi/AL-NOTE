// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import 'validation_report.dart';

/// An immutable invalid report paired with stable structured-failure metadata.
final class ValidationFailure {
  const ValidationFailure._({required this.metadata, required this.report});

  /// Creates a validation failure when [report] contains at least one error.
  ///
  /// The supplied [metadata] instance and all of its stable fields are
  /// preserved unchanged.
  static Result<ValidationFailure, StructuredFailure> create({
    required StructuredFailure metadata,
    required ValidationReport report,
  }) {
    if (report.isValid) {
      return Err<ValidationFailure, StructuredFailure>(
        StructuredFailure(
          code: 'core.validation.failure_requires_error',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'A validation failure requires an error issue.',
        ),
      );
    }
    return Ok<ValidationFailure, StructuredFailure>(
      ValidationFailure._(metadata: metadata, report: report),
    );
  }

  /// The preserved stable structured-failure metadata.
  final StructuredFailure metadata;

  /// The invalid validation report.
  final ValidationReport report;
}
