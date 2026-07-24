// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// A lowercase ASCII identifier composed of dot-separated namespace segments.
final class NamespacedIdentifier {
  const NamespacedIdentifier._(this.value);

  static final RegExp _pattern = RegExp(
    r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$',
  );

  /// Parses [source] as a namespaced identifier.
  ///
  /// Valid values contain 2–255 ASCII characters and at least two segments.
  /// Every segment starts with a lowercase letter and then contains only
  /// lowercase letters, digits, underscores, or hyphens.
  static Result<NamespacedIdentifier, StructuredFailure> parse(String source) {
    if (source.length < 2 ||
        source.length > 255 ||
        !_pattern.hasMatch(source)) {
      return Err<NamespacedIdentifier, StructuredFailure>(
        StructuredFailure(
          code: 'core.identity.invalid_namespaced_identifier',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'The namespaced identifier is not valid.',
        ),
      );
    }
    return Ok<NamespacedIdentifier, StructuredFailure>(
      NamespacedIdentifier._(source),
    );
  }

  /// The canonical namespaced identifier text.
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NamespacedIdentifier && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
