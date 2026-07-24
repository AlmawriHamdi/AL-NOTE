// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import 'validation_path.dart';

/// The maximum accepted length of a trusted validation issue code.
const int maximumValidationIssueCodeLength = 128;

/// The severity of a validation issue.
enum ValidationSeverity {
  /// An error that invalidates a validation report.
  error,

  /// A warning that does not invalidate a validation report.
  warning,
}

/// An AL NOTE-owned stable code permitted on a validation issue.
///
/// The enum is deliberately closed: caller-controlled strings and rejected
/// values cannot become stored issue codes.
enum ValidationIssueCode {
  /// A required value is absent.
  required('core.validation.required'),

  /// A value is structurally invalid.
  invalid('core.validation.invalid'),

  /// A redaction-safe warning applies.
  warning('core.validation.warning'),

  /// An identity occurs more than once.
  duplicateIdentity('documents.validation.duplicate_identity'),

  /// A value has more than one structural owner.
  multipleOwnership('documents.validation.multiple_ownership'),

  /// A document structure violates a closed invariant.
  invalidStructure('documents.validation.invalid_structure'),

  /// Source-layer roles are not in canonical order.
  invalidLayerOrder('documents.validation.invalid_layer_order'),

  /// A source-layer role occurs too many times.
  invalidLayerRoleCount('documents.validation.invalid_layer_role_count'),

  /// A page has no content-role layer.
  missingContentLayer('documents.validation.missing_content_layer'),

  /// A known Object payload is invalid.
  invalidObjectPayload('documents.validation.invalid_object_payload'),

  /// An Object type is unknown and preserved inertly.
  unknownObjectType('documents.validation.unknown_object_type'),

  /// A known Object schema is unsupported and preserved inertly.
  unsupportedObjectSchema('documents.validation.unsupported_object_schema'),

  /// A Layer type is unknown and preserved inertly.
  unknownLayerType('documents.validation.unknown_layer_type'),

  /// A referenced logical resource is unavailable.
  missingResource('documents.validation.missing_resource'),

  /// Required registered behavior is unavailable.
  unavailableBehavior('documents.validation.unavailable_behavior');

  const ValidationIssueCode(this.stableCode);

  /// The stable lowercase namespaced representation of this code.
  final String stableCode;

  /// Resolves [source] only when it exactly names a predefined trusted code.
  ///
  /// The source is never retained. Inputs beyond
  /// [maximumValidationIssueCodeLength] are rejected before lookup.
  static Result<ValidationIssueCode, StructuredFailure> parseTrusted(
    String source,
  ) {
    if (source.length > maximumValidationIssueCodeLength) {
      return Err<ValidationIssueCode, StructuredFailure>(
        _invalidIssueCodeFailure(),
      );
    }
    for (final code in values) {
      if (code.stableCode == source) {
        return Ok<ValidationIssueCode, StructuredFailure>(code);
      }
    }
    return Err<ValidationIssueCode, StructuredFailure>(
      _invalidIssueCodeFailure(),
    );
  }
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

  /// Creates a redaction-safe issue with an AL NOTE-owned trusted [code].
  static Result<ValidationIssue, StructuredFailure> create({
    required ValidationIssueCode code,
    required ValidationSeverity severity,
    required ValidationPath path,
  }) => Ok<ValidationIssue, StructuredFailure>(
    ValidationIssue._(code: code, severity: severity, path: path),
  );

  /// The closed AL NOTE-owned issue code.
  final ValidationIssueCode code;

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
  String toString() => '${severity.name}:${code.stableCode}@$path';
}

StructuredFailure _invalidIssueCodeFailure() => StructuredFailure(
  code: 'core.validation.invalid_issue_code',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'A validation issue code must be a predefined trusted code.',
);
