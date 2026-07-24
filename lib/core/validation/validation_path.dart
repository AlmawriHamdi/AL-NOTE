// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// An immutable structural path to a validated field or component.
final class ValidationPath implements Comparable<ValidationPath> {
  ValidationPath._(List<String> segments)
    : _segments = List<String>.unmodifiable(segments);

  static final RegExp _segmentPattern = RegExp(r'^[a-z][a-z0-9_]*$');

  final List<String> _segments;

  /// Creates a path from safe structural [segments].
  ///
  /// Empty input represents the root. Segments are copied immediately and may
  /// contain only lowercase field-name characters; rejected values and display
  /// text therefore cannot be embedded in a path.
  static Result<ValidationPath, StructuredFailure> fromSegments(
    Iterable<String> segments,
  ) {
    final copiedSegments = List<String>.of(segments);
    if (copiedSegments.any((segment) => !_segmentPattern.hasMatch(segment))) {
      return Err<ValidationPath, StructuredFailure>(
        StructuredFailure(
          code: 'core.validation.invalid_path',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'A validation path contains an invalid structural segment.',
        ),
      );
    }
    return Ok<ValidationPath, StructuredFailure>(
      ValidationPath._(copiedSegments),
    );
  }

  /// The unmodifiable structural path segments.
  List<String> get segments => _segments;

  /// Returns a path extended with one safe structural [segment].
  Result<ValidationPath, StructuredFailure> child(String segment) =>
      fromSegments(<String>[..._segments, segment]);

  @override
  int compareTo(ValidationPath other) {
    final sharedLength = _segments.length < other._segments.length
        ? _segments.length
        : other._segments.length;
    for (var index = 0; index < sharedLength; index += 1) {
      final comparison = _segments[index].compareTo(other._segments[index]);
      if (comparison != 0) {
        return comparison;
      }
    }
    return _segments.length.compareTo(other._segments.length);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! ValidationPath ||
        other._segments.length != _segments.length) {
      return false;
    }
    for (var index = 0; index < _segments.length; index += 1) {
      if (_segments[index] != other._segments[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_segments);

  @override
  String toString() => _segments.join('.');
}
