// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ValidationPath', () {
    test('defensively copies segments and exposes no mutable list', () {
      final source = <ValidationPathSegment>[
        ValidationPathSegment.document,
        ValidationPathSegment.title,
      ];
      final path =
          (ValidationPath.fromSegments(source)
                  as Ok<ValidationPath, StructuredFailure>)
              .value;

      source
        ..clear()
        ..add(ValidationPathSegment.input);

      expect(path.segments, <ValidationPathSegment>[
        ValidationPathSegment.document,
        ValidationPathSegment.title,
      ]);
      expect(
        () => path.segments.add(ValidationPathSegment.input),
        throwsUnsupportedError,
      );
    });

    test('supports root and child paths with value equality', () {
      final root = _path(<ValidationPathSegment>[]);
      final child =
          (root.child(ValidationPathSegment.document)
                  as Ok<ValidationPath, StructuredFailure>)
              .value;
      final nested =
          (child.child(ValidationPathSegment.title)
                  as Ok<ValidationPath, StructuredFailure>)
              .value;

      expect(root.segments, isEmpty);
      expect(
        nested,
        _path(<ValidationPathSegment>[
          ValidationPathSegment.document,
          ValidationPathSegment.title,
        ]),
      );
      expect(nested.toString(), 'document.title');
      expect(
        nested.hashCode,
        _path(<ValidationPathSegment>[
          ValidationPathSegment.document,
          ValidationPathSegment.title,
        ]).hashCode,
      );
    });

    test('string conversion accepts only predefined trusted path tokens', () {
      expect(
        ValidationPathSegment.parseTrusted('document'),
        const Ok<ValidationPathSegment, StructuredFailure>(
          ValidationPathSegment.document,
        ),
      );

      final oversized = List<String>.filled(
        maximumValidationTokenLength + 1,
        'a',
      ).join();
      for (final untrusted in <String>['secret', 'password123', oversized]) {
        expect(
          ValidationPathSegment.parseTrusted(untrusted),
          isA<Err<ValidationPathSegment, StructuredFailure>>(),
          reason: untrusted,
        );
      }
    });

    test('rejects paths beyond the structural depth bound', () {
      expect(
        ValidationPath.fromSegments(
          List<ValidationPathSegment>.filled(
            maximumValidationPathSegments + 1,
            ValidationPathSegment.document,
          ),
        ),
        isA<Err<ValidationPath, StructuredFailure>>(),
      );
    });
  });

  group('ValidationIssue', () {
    test('contains only stable redaction-safe fields', () {
      final issue = _issue(
        code: ValidationIssueCode.required,
        severity: ValidationSeverity.error,
        path: _path(<ValidationPathSegment>[
          ValidationPathSegment.document,
          ValidationPathSegment.title,
        ]),
      );

      expect(issue.code, ValidationIssueCode.required);
      expect(issue.severity, ValidationSeverity.error);
      expect(issue.path.toString(), 'document.title');
      expect(issue.toString(), isNot(contains('rejected title')));
    });

    test('string conversion accepts only predefined trusted issue codes', () {
      expect(
        ValidationIssueCode.parseTrusted('core.validation.required'),
        const Ok<ValidationIssueCode, StructuredFailure>(
          ValidationIssueCode.required,
        ),
      );

      final oversized = List<String>.filled(
        maximumValidationIssueCodeLength + 1,
        'a',
      ).join();
      final issue = _issue(
        code: ValidationIssueCode.invalid,
        severity: ValidationSeverity.error,
        path: _path(<ValidationPathSegment>[ValidationPathSegment.document]),
      );
      for (final untrusted in <String>['secret', 'password123', oversized]) {
        expect(
          ValidationIssueCode.parseTrusted(untrusted),
          isA<Err<ValidationIssueCode, StructuredFailure>>(),
          reason: untrusted,
        );
        expect(issue.toString(), isNot(contains(untrusted)));
      }
    });
  });

  group('ValidationReport', () {
    test('orders issues by path, severity, and code deterministically', () {
      final documentPath = _path(<ValidationPathSegment>[
        ValidationPathSegment.document,
      ]);
      final titlePath = _path(<ValidationPathSegment>[
        ValidationPathSegment.document,
        ValidationPathSegment.title,
      ]);
      final titleWarning = _issue(
        code: ValidationIssueCode.warning,
        severity: ValidationSeverity.warning,
        path: titlePath,
      );
      final titleErrorB = _issue(
        code: ValidationIssueCode.required,
        severity: ValidationSeverity.error,
        path: titlePath,
      );
      final documentWarning = _issue(
        code: ValidationIssueCode.warning,
        severity: ValidationSeverity.warning,
        path: documentPath,
      );
      final titleErrorA = _issue(
        code: ValidationIssueCode.invalid,
        severity: ValidationSeverity.error,
        path: titlePath,
      );

      final first = ValidationReport(<ValidationIssue>[
        titleWarning,
        titleErrorB,
        documentWarning,
        titleErrorA,
      ]);
      final second = ValidationReport(<ValidationIssue>[
        titleErrorA,
        documentWarning,
        titleErrorB,
        titleWarning,
      ]);

      final expected = <ValidationIssue>[
        documentWarning,
        titleErrorA,
        titleErrorB,
        titleWarning,
      ];
      expect(first.issues, expected);
      expect(second.issues, expected);
    });

    test('warnings remain valid while errors invalidate', () {
      final warning = _issue(
        code: ValidationIssueCode.warning,
        severity: ValidationSeverity.warning,
        path: _path(<ValidationPathSegment>[ValidationPathSegment.document]),
      );
      final error = _issue(
        code: ValidationIssueCode.required,
        severity: ValidationSeverity.error,
        path: _path(<ValidationPathSegment>[ValidationPathSegment.document]),
      );

      final warningOnly = ValidationReport(<ValidationIssue>[warning]);
      final withError = ValidationReport(<ValidationIssue>[warning, error]);

      expect(warningOnly.isValid, isTrue);
      expect(warningOnly.hasWarnings, isTrue);
      expect(warningOnly.errors, isEmpty);
      expect(withError.isValid, isFalse);
      expect(withError.errors, <ValidationIssue>[error]);
      expect(withError.warnings, <ValidationIssue>[warning]);
    });

    test('defensively copies issue input and exposes immutable views', () {
      final source = <ValidationIssue>[
        _issue(
          code: ValidationIssueCode.warning,
          severity: ValidationSeverity.warning,
          path: _path(<ValidationPathSegment>[ValidationPathSegment.document]),
        ),
      ];
      final report = ValidationReport(source);

      source.clear();

      expect(report.issues, hasLength(1));
      expect(() => report.issues.clear(), throwsUnsupportedError);
      expect(() => report.warnings.clear(), throwsUnsupportedError);
      expect(
        () => report.errors.add(report.issues.single),
        throwsUnsupportedError,
      );
    });
  });

  group('ValidationFailure', () {
    test('preserves the supplied structured-failure metadata', () {
      final metadata = StructuredFailure(
        code: 'document.validation_failed',
        category: FailureCategory.validation,
        retryDisposition: RetryDisposition.never,
        message: 'Document validation failed.',
      );
      final report = ValidationReport(<ValidationIssue>[
        _issue(
          code: ValidationIssueCode.required,
          severity: ValidationSeverity.error,
          path: _path(<ValidationPathSegment>[ValidationPathSegment.document]),
        ),
      ]);

      final result = ValidationFailure.create(
        metadata: metadata,
        report: report,
      );
      final failure =
          (result as Ok<ValidationFailure, StructuredFailure>).value;

      expect(failure.metadata, same(metadata));
      expect(failure.metadata.code, 'document.validation_failed');
      expect(failure.report, same(report));
    });

    test('cannot be created from a warning-only valid report', () {
      final metadata = StructuredFailure(
        code: 'document.validation_failed',
        category: FailureCategory.validation,
        retryDisposition: RetryDisposition.never,
        message: 'Document validation failed.',
      );
      final report = ValidationReport(<ValidationIssue>[
        _issue(
          code: ValidationIssueCode.warning,
          severity: ValidationSeverity.warning,
          path: _path(<ValidationPathSegment>[ValidationPathSegment.document]),
        ),
      ]);

      expect(
        ValidationFailure.create(metadata: metadata, report: report),
        isA<Err<ValidationFailure, StructuredFailure>>(),
      );
    });
  });

  test('Validator returns deterministic reports without embedding values', () {
    final validator = _NonEmptyStringValidator();

    final rejected = validator.validate('');
    final accepted = validator.validate('accepted');

    expect(rejected.isValid, isFalse);
    expect(rejected.issues.single.code, ValidationIssueCode.required);
    expect(rejected.issues.single.code.stableCode, 'core.validation.required');
    expect(rejected.issues.single.toString(), isNot(contains('accepted')));
    expect(accepted.isValid, isTrue);
    expect(accepted.issues, isEmpty);
  });
}

ValidationPath _path(Iterable<ValidationPathSegment> segments) =>
    (ValidationPath.fromSegments(segments)
            as Ok<ValidationPath, StructuredFailure>)
        .value;

ValidationIssue _issue({
  required ValidationIssueCode code,
  required ValidationSeverity severity,
  required ValidationPath path,
}) =>
    (ValidationIssue.create(code: code, severity: severity, path: path)
            as Ok<ValidationIssue, StructuredFailure>)
        .value;

final class _NonEmptyStringValidator implements Validator<String> {
  @override
  ValidationReport validate(String value) {
    if (value.isNotEmpty) {
      return ValidationReport(<ValidationIssue>[]);
    }
    return ValidationReport(<ValidationIssue>[
      _issue(
        code: ValidationIssueCode.required,
        severity: ValidationSeverity.error,
        path: _path(<ValidationPathSegment>[
          ValidationPathSegment.input,
          ValidationPathSegment.value,
        ]),
      ),
    ]);
  }
}
