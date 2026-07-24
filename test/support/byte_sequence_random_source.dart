// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import 'package:al_note/core/primitives.dart';

/// A deterministic random source that consumes a sequence of byte results.
final class ByteSequenceRandomSource implements RandomSource {
  /// Creates a source from ordered [results].
  ByteSequenceRandomSource(
    Iterable<Result<List<int>, StructuredFailure>> results,
  ) : _results = Queue<Result<List<int>, StructuredFailure>>.of(results);

  /// Creates a source that succeeds with each list in [values].
  factory ByteSequenceRandomSource.fromBytes(Iterable<List<int>> values) =>
      ByteSequenceRandomSource(
        values.map(
          (value) =>
              Ok<List<int>, StructuredFailure>(List<int>.unmodifiable(value)),
        ),
      );

  final Queue<Result<List<int>, StructuredFailure>> _results;

  /// The number of unconsumed deterministic results.
  int get remaining => _results.length;

  @override
  Result<List<int>, StructuredFailure> nextBytes(int length) {
    if (length < 0) {
      return Err<List<int>, StructuredFailure>(
        StructuredFailure(
          code: 'test.random.invalid_length',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'Requested random byte length must be nonnegative.',
        ),
      );
    }
    if (_results.isEmpty) {
      return Err<List<int>, StructuredFailure>(
        StructuredFailure(
          code: 'test.random.sequence_exhausted',
          category: FailureCategory.state,
          retryDisposition: RetryDisposition.never,
          message: 'The deterministic random sequence is exhausted.',
        ),
      );
    }

    final result = _results.removeFirst();
    return result.fold<Result<List<int>, StructuredFailure>>(
      onOk: (bytes) {
        if (bytes.length != length) {
          return Err<List<int>, StructuredFailure>(
            StructuredFailure(
              code: 'test.random.length_mismatch',
              category: FailureCategory.state,
              retryDisposition: RetryDisposition.never,
              message: 'The deterministic byte count does not match.',
            ),
          );
        }
        return Ok<List<int>, StructuredFailure>(List<int>.unmodifiable(bytes));
      },
      onErr: Err<List<int>, StructuredFailure>.new,
    );
  }
}
