// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import 'package:al_note/core/primitives.dart';

/// A deterministic UUID generator that consumes an ordered result sequence.
final class UuidSequenceGenerator implements UuidGenerator {
  /// Creates a generator from ordered [results].
  UuidSequenceGenerator(
    Iterable<Result<UuidIdentifier, StructuredFailure>> results,
  ) : _results = Queue<Result<UuidIdentifier, StructuredFailure>>.of(results);

  /// Creates a generator that succeeds with each UUID in [values].
  factory UuidSequenceGenerator.fromValues(Iterable<UuidIdentifier> values) =>
      UuidSequenceGenerator(
        values.map(Ok<UuidIdentifier, StructuredFailure>.new),
      );

  final Queue<Result<UuidIdentifier, StructuredFailure>> _results;

  /// The number of unconsumed deterministic results.
  int get remaining => _results.length;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    if (_results.isEmpty) {
      return Err<UuidIdentifier, StructuredFailure>(
        StructuredFailure(
          code: 'test.identity.uuid_sequence_exhausted',
          category: FailureCategory.state,
          retryDisposition: RetryDisposition.never,
          message: 'The deterministic UUID sequence is exhausted.',
        ),
      );
    }
    return _results.removeFirst();
  }
}
