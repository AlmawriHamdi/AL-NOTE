// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// An immutable canonical RFC 9562 UUID identifier.
final class UuidIdentifier {
  const UuidIdentifier._(this.value);

  static final RegExp _canonicalPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static const String _nil = '00000000-0000-0000-0000-000000000000';
  static const String _max = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

  /// Parses a canonical hyphenated UUID and normalizes hex digits to lowercase.
  ///
  /// Nil and max UUID values are rejected.
  static Result<UuidIdentifier, StructuredFailure> parse(String source) {
    final normalized = source.toLowerCase();
    if (!_canonicalPattern.hasMatch(source) ||
        normalized == _nil ||
        normalized == _max) {
      return Err<UuidIdentifier, StructuredFailure>(
        StructuredFailure(
          code: 'core.identity.invalid_uuid',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'The UUID identifier is not a supported canonical UUID.',
        ),
      );
    }
    return Ok<UuidIdentifier, StructuredFailure>(UuidIdentifier._(normalized));
  }

  /// The canonical lowercase hyphenated UUID text.
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UuidIdentifier && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
