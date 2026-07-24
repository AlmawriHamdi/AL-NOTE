// SPDX-License-Identifier: GPL-3.0-or-later

import 'validation_issue.dart';

/// An immutable deterministically ordered collection of validation issues.
///
/// Issues are ordered by path, then with errors before warnings, and finally by
/// stable issue code. This ordering is independent of input collection order.
final class ValidationReport {
  /// Creates a report by defensively copying and ordering [issues].
  factory ValidationReport(Iterable<ValidationIssue> issues) {
    final ordered = List<ValidationIssue>.of(issues)..sort(_compareIssues);
    final immutableIssues = List<ValidationIssue>.unmodifiable(ordered);
    return ValidationReport._(
      issues: immutableIssues,
      errors: List<ValidationIssue>.unmodifiable(
        immutableIssues.where(
          (issue) => issue.severity == ValidationSeverity.error,
        ),
      ),
      warnings: List<ValidationIssue>.unmodifiable(
        immutableIssues.where(
          (issue) => issue.severity == ValidationSeverity.warning,
        ),
      ),
    );
  }

  const ValidationReport._({
    required List<ValidationIssue> issues,
    required List<ValidationIssue> errors,
    required List<ValidationIssue> warnings,
  }) : _issues = issues,
       _errors = errors,
       _warnings = warnings;

  final List<ValidationIssue> _issues;
  final List<ValidationIssue> _errors;
  final List<ValidationIssue> _warnings;

  /// Every issue in deterministic order.
  List<ValidationIssue> get issues => _issues;

  /// Every error in deterministic order.
  List<ValidationIssue> get errors => _errors;

  /// Every warning in deterministic order.
  List<ValidationIssue> get warnings => _warnings;

  /// Whether the report contains no errors.
  bool get isValid => _errors.isEmpty;

  /// Whether the report contains at least one warning.
  bool get hasWarnings => _warnings.isNotEmpty;

  static int _compareIssues(ValidationIssue left, ValidationIssue right) {
    final pathComparison = left.path.compareTo(right.path);
    if (pathComparison != 0) {
      return pathComparison;
    }
    final severityComparison = left.severity.index.compareTo(
      right.severity.index,
    );
    if (severityComparison != 0) {
      return severityComparison;
    }
    return left.code.compareTo(right.code);
  }
}
