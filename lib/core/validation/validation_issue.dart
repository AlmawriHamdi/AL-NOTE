// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import 'validation_path.dart';

/// The severity of a validation issue.
enum ValidationSeverity {
  /// An error that invalidates a validation report.
  error,

  /// A warning that does not invalidate a validation report.
  warning,
}

/// An immutable redaction-safe validation issue.
///
/// Issues contain only a stable code, severity, and structural path. They
/// intentionally provide no field for rejected values, sensitive data,
/// arbitrary payloads, messages, or diagnostic metadata.
final class ValidationIssue {
  const ValidationIssue._({
    required this.code,
    required this.severity,
    required this.path,
  });

  static final RegExp _codePattern = RegExp(
    r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$',
  );

  /// Creates a redaction-safe issue with a stable lowercase namespaced [code].
  static Result<ValidationIssue, StructuredFailure> create({
    required String code,
    required ValidationSeverity severity,
    required ValidationPath path,
  }) {
    if (!_codePattern.hasMatch(code)) {
      return Err<ValidationIssue, StructuredFailure>(
        StructuredFailure(
          code: 'core.validation.invalid_issue_code',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'A validation issue code must be lowercase and namespaced.',
        ),
      );
    }
    return Ok<ValidationIssue, StructuredFailure>(
      ValidationIssue._(code: code, severity: severity, path: path),
    );
  }

  /// The stable lowercase namespaced issue code.
  final String code;

  /// The issue severity.
  final ValidationSeverity severity;

  /// The safe structural location of the issue.
  final ValidationPath path;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ValidationIssue &&
          other.code == code &&
          other.severity == severity &&
          other.path == path;

  @override
  int get hashCode => Object.hash(code, severity, path);

  @override
  String toString() => '${severity.name}:$code@$path';
}
