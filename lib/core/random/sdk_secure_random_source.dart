// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math';

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import 'random_source.dart';

/// A production [RandomSource] backed by the Dart SDK secure random generator.
final class SdkSecureRandomSource implements RandomSource {
  /// Creates an SDK-backed secure random source.
  const SdkSecureRandomSource();

  @override
  Result<List<int>, StructuredFailure> nextBytes(int length) {
    if (length < 0) {
      return Err<List<int>, StructuredFailure>(
        StructuredFailure(
          code: 'core.random.invalid_length',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'Random byte length must be nonnegative.',
        ),
      );
    }

    try {
      final random = Random.secure();
      final bytes = List<int>.generate(
        length,
        (_) => random.nextInt(256),
        growable: false,
      );
      return Ok<List<int>, StructuredFailure>(List<int>.unmodifiable(bytes));
    } on Object {
      return Err<List<int>, StructuredFailure>(
        StructuredFailure(
          code: 'core.random.platform_failure',
          category: FailureCategory.platform,
          retryDisposition: RetryDisposition.retryable,
          message: 'The platform secure random source failed.',
        ),
      );
    }
  }
}
