// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ValidationPath', () {
    test('defensively copies segments and exposes no mutable list', () {
      final source = <String>['document', 'title'];
      final path =
          (ValidationPath.fromSegments(source)
                  as Ok<ValidationPath, StructuredFailure>)
              .value;

      source
        ..clear()
        ..add('changed');

      expect(path.segments, <String>['document', 'title']);
      expect(() => path.segments.add('changed'), throwsUnsupportedError);
    });

    test('supports root and child paths with value equality', () {
      final root = _path(<String>[]);
      final child =
          (root.child('document') as Ok<ValidationPath, StructuredFailure>)
              .value;
      final nested =
          (child.child('title') as Ok<ValidationPath, StructuredFailure>).value;

      expect(root.segments, isEmpty);
      expect(nested, _path(<String>['document', 'title']));
      expect(nested.toString(), 'document.title');
      expect(nested.hashCode, _path(<String>['document', 'title']).hashCode);
    });

    test('rejects values and unsafe diagnostic text as path segments', () {
      for (final unsafe in <String>[
        'Title',
        'document.title',
        'user@example.com',
        '../secret',
        'contains space',
        '',
      ]) {
        expect(
          ValidationPath.fromSegments(<String>[unsafe]),
          isA<Err<ValidationPath, StructuredFailure>>(),
          reason: unsafe,
        );
      }
    });
  });

  group('ValidationIssue', () {
    test('contains only stable redaction-safe fields', () {
      final issue = _issue(
        code: 'document.title_missing',
        severity: ValidationSeverity.error,
        path: _path(<String>['document', 'title']),
      );

      expect(issue.code, 'document.title_missing');
      expect(issue.severity, ValidationSeverity.error);
      expect(issue.path.toString(), 'document.title');
      expect(issue.toString(), isNot(contains('rejected title')));
    });

    test('rejects unsafe or unstable issue codes', () {
      expect(
        ValidationIssue.create(
          code: 'Rejected value: secret@example.com',
          severity: ValidationSeverity.error,
          path: _path(<String>['document']),
        ),
        isA<Err<ValidationIssue, StructuredFailure>>(),
      );
    });
  });

  group('ValidationReport', () {
    test('orders issues by path, severity, and code deterministically', () {
      final documentPath = _path(<String>['document']);
      final titlePath = _path(<String>['document', 'title']);
      final titleWarning = _issue(
        code: 'document.title_warning',
        severity: ValidationSeverity.warning,
        path: titlePath,
      );
      final titleErrorB = _issue(
        code: 'document.title_required',
        severity: ValidationSeverity.error,
        path: titlePath,
      );
      final documentWarning = _issue(
        code: 'document.general_warning',
        severity: ValidationSeverity.warning,
        path: documentPath,
      );
      final titleErrorA = _issue(
        code: 'document.title_invalid',
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
        code: 'document.optional_warning',
        severity: ValidationSeverity.warning,
        path: _path(<String>['document']),
      );
      final error = _issue(
        code: 'document.required_error',
        severity: ValidationSeverity.error,
        path: _path(<String>['document']),
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
          code: 'document.warning',
          severity: ValidationSeverity.warning,
          path: _path(<String>['document']),
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
          code: 'document.required_error',
          severity: ValidationSeverity.error,
          path: _path(<String>['document']),
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
          code: 'document.warning',
          severity: ValidationSeverity.warning,
          path: _path(<String>['document']),
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
    expect(rejected.issues.single.code, 'input.value_required');
    expect(rejected.issues.single.toString(), isNot(contains('accepted')));
    expect(accepted.isValid, isTrue);
    expect(accepted.issues, isEmpty);
  });
}

ValidationPath _path(Iterable<String> segments) =>
    (ValidationPath.fromSegments(segments)
            as Ok<ValidationPath, StructuredFailure>)
        .value;

ValidationIssue _issue({
  required String code,
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
        code: 'input.value_required',
        severity: ValidationSeverity.error,
        path: _path(<String>['input', 'value']),
      ),
    ]);
  }
}
