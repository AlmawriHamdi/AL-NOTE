// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// The maximum number of structural tokens in a validation path.
const int maximumValidationPathSegments = 64;

/// The maximum accepted length of a trusted validation token name.
const int maximumValidationTokenLength = 64;

/// An AL NOTE-owned structural token permitted in a validation path.
///
/// The enum is deliberately closed: rejected values and caller-provided text
/// cannot become stored path segments.
enum ValidationPathSegment {
  /// A document structure.
  document('document'),

  /// A document root structure.
  root('root'),

  /// A title field.
  title('title'),

  /// A schema-version field.
  schemaVersion('schema_version'),

  /// A sections collection.
  sections('sections'),

  /// A section structure.
  section('section'),

  /// A pages collection.
  pages('pages'),

  /// A page structure.
  page('page'),

  /// A page-size field.
  size('size'),

  /// A layers collection.
  layers('layers'),

  /// A layer structure.
  layer('layer'),

  /// An objects collection.
  objects('objects'),

  /// An object structure.
  object('object'),

  /// A resources collection.
  resources('resources'),

  /// A resource structure.
  resource('resource'),

  /// An identity field.
  identity('identity'),

  /// A stable type-key field.
  type('type'),

  /// A core-role field.
  role('role'),

  /// An opacity field.
  opacity('opacity'),

  /// A preserved payload field.
  payload('payload'),

  /// A logical-reference field.
  reference('reference'),

  /// An input structure.
  input('input'),

  /// A value field.
  value('value');

  const ValidationPathSegment(this.trustedName);

  /// The stable redaction-safe name of this structural token.
  final String trustedName;

  /// Resolves [source] only when it exactly names a predefined trusted token.
  ///
  /// The source is never retained. Inputs beyond
  /// [maximumValidationTokenLength] are rejected before lookup.
  static Result<ValidationPathSegment, StructuredFailure> parseTrusted(
    String source,
  ) {
    if (source.length > maximumValidationTokenLength) {
      return Err<ValidationPathSegment, StructuredFailure>(
        _invalidPathFailure(),
      );
    }
    for (final token in values) {
      if (token.trustedName == source) {
        return Ok<ValidationPathSegment, StructuredFailure>(token);
      }
    }
    return Err<ValidationPathSegment, StructuredFailure>(_invalidPathFailure());
  }
}

/// An immutable structural path to a validated field or component.
final class ValidationPath implements Comparable<ValidationPath> {
  ValidationPath._(List<ValidationPathSegment> segments)
    : _segments = List<ValidationPathSegment>.unmodifiable(segments);

  final List<ValidationPathSegment> _segments;

  /// Creates a path from AL NOTE-owned structural [segments].
  ///
  /// Empty input represents the root. Segments are copied immediately. Paths
  /// longer than [maximumValidationPathSegments] are rejected.
  static Result<ValidationPath, StructuredFailure> fromSegments(
    Iterable<ValidationPathSegment> segments,
  ) {
    final copiedSegments = List<ValidationPathSegment>.of(segments);
    if (copiedSegments.length > maximumValidationPathSegments) {
      return Err<ValidationPath, StructuredFailure>(_invalidPathFailure());
    }
    return Ok<ValidationPath, StructuredFailure>(
      ValidationPath._(copiedSegments),
    );
  }

  /// The unmodifiable structural path segments.
  List<ValidationPathSegment> get segments => _segments;

  /// Returns a path extended with one trusted structural [segment].
  Result<ValidationPath, StructuredFailure> child(
    ValidationPathSegment segment,
  ) => fromSegments(<ValidationPathSegment>[..._segments, segment]);

  @override
  int compareTo(ValidationPath other) {
    final sharedLength = _segments.length < other._segments.length
        ? _segments.length
        : other._segments.length;
    for (var index = 0; index < sharedLength; index += 1) {
      final comparison = _segments[index].trustedName.compareTo(
        other._segments[index].trustedName,
      );
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
  String toString() =>
      _segments.map((segment) => segment.trustedName).join('.');
}

StructuredFailure _invalidPathFailure() => StructuredFailure(
  code: 'core.validation.invalid_path',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'A validation path must contain only predefined structural tokens.',
);
