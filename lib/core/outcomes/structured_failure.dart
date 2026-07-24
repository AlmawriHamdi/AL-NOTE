// SPDX-License-Identifier: GPL-3.0-or-later

/// A broad classification for a structured failure.
enum FailureCategory {
  /// Input did not satisfy a contract.
  validation,

  /// Existing state prevented the requested operation.
  state,

  /// A required dependency could not perform its work.
  dependency,

  /// A platform capability was unavailable or failed.
  platform,

  /// A required resource was unavailable or exhausted.
  resource,

  /// The failure could not be classified more specifically.
  unknown,
}

/// Describes whether and under what conditions an operation may be retried.
enum RetryDisposition {
  /// Retrying the same request is not expected to succeed.
  never,

  /// Retrying may succeed without user intervention.
  retryable,

  /// Retrying requires corrective user action first.
  afterUserAction,
}

/// An immutable failure with a stable machine-readable code.
final class StructuredFailure {
  /// Creates a structured failure.
  ///
  /// The [code] must be a lowercase, dot-separated namespace with at least two
  /// segments. Each segment must start with a letter and may then contain
  /// lowercase letters, digits, or underscores.
  factory StructuredFailure({
    required String code,
    required FailureCategory category,
    required RetryDisposition retryDisposition,
    required String message,
  }) {
    if (!_codePattern.hasMatch(code)) {
      throw ArgumentError.value(
        code,
        'code',
        'must be a stable namespaced code',
      );
    }
    return StructuredFailure._(
      code: code,
      category: category,
      retryDisposition: retryDisposition,
      message: message,
    );
  }

  const StructuredFailure._({
    required this.code,
    required this.category,
    required this.retryDisposition,
    required this.message,
  });

  static final RegExp _codePattern = RegExp(
    r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$',
  );

  /// The stable lowercase namespaced machine-readable code.
  final String code;

  /// The broad failure category.
  final FailureCategory category;

  /// Whether retrying may be appropriate.
  final RetryDisposition retryDisposition;

  /// A non-localized diagnostic description.
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StructuredFailure &&
          other.code == code &&
          other.category == category &&
          other.retryDisposition == retryDisposition &&
          other.message == message;

  @override
  int get hashCode => Object.hash(code, category, retryDisposition, message);

  @override
  String toString() => 'StructuredFailure($code: $message)';
}
