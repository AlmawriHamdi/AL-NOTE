// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';

/// The largest exactly representable integer in Web number semantics.
const int maximumWebSafeInteger = 9007199254740991;

/// Portable immutable data preserved without interpretation or execution.
sealed class PreservedData {
  const PreservedData();
}

/// The preserved null value.
final class PreservedNull extends PreservedData {
  /// The single null value.
  const PreservedNull();

  @override
  bool operator ==(Object other) => other is PreservedNull;

  @override
  int get hashCode => Object.hash(PreservedNull, 0);

  @override
  String toString() => 'PreservedNull';
}

/// An immutable preserved Boolean.
final class PreservedBoolean extends PreservedData {
  /// Creates a preserved Boolean.
  const PreservedBoolean(this.value);

  /// The preserved value.
  final bool value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreservedBoolean && other.value == value;

  @override
  int get hashCode => Object.hash(PreservedBoolean, value);

  @override
  String toString() => 'PreservedBoolean';
}

/// An immutable preserved Web-safe integer.
final class PreservedInteger extends PreservedData {
  const PreservedInteger._(this.value);

  /// Creates a preserved integer when [value] is Web-safe.
  static Result<PreservedInteger, StructuredFailure> create(int value) {
    if (value < -maximumWebSafeInteger || value > maximumWebSafeInteger) {
      return Err<PreservedInteger, StructuredFailure>(
        _preservedFailure(
          'documents.preserved_data.integer_out_of_range',
          'A preserved integer must be within the Web-safe range.',
        ),
      );
    }
    return Ok<PreservedInteger, StructuredFailure>(PreservedInteger._(value));
  }

  /// The preserved Web-safe value.
  final int value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreservedInteger && other.value == value;

  @override
  int get hashCode => Object.hash(PreservedInteger, value);

  @override
  String toString() => 'PreservedInteger';
}

/// An immutable preserved finite double.
final class PreservedDouble extends PreservedData {
  const PreservedDouble._(this.value);

  /// Creates a preserved double when [value] is finite.
  static Result<PreservedDouble, StructuredFailure> create(double value) {
    if (!value.isFinite) {
      return Err<PreservedDouble, StructuredFailure>(
        _preservedFailure(
          'documents.preserved_data.non_finite_double',
          'A preserved double must be finite.',
        ),
      );
    }
    return Ok<PreservedDouble, StructuredFailure>(PreservedDouble._(value));
  }

  /// The preserved finite value.
  final double value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreservedDouble && other.value == value;

  @override
  int get hashCode => Object.hash(PreservedDouble, value);

  @override
  String toString() => 'PreservedDouble';
}

/// An immutable preserved string.
final class PreservedString extends PreservedData {
  /// Creates a preserved string.
  const PreservedString(this.value);

  /// The preserved value.
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreservedString && other.value == value;

  @override
  int get hashCode => Object.hash(PreservedString, value);

  @override
  String toString() => 'PreservedString';
}

/// An immutable ordered list of preserved values.
final class PreservedList extends PreservedData {
  /// Defensively copies [values] in their authoritative order.
  PreservedList(Iterable<PreservedData> values)
    : values = List<PreservedData>.unmodifiable(values);

  /// The unmodifiable preserved values.
  final List<PreservedData> values;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! PreservedList || other.values.length != values.length) {
      return false;
    }
    for (var index = 0; index < values.length; index += 1) {
      if (values[index] != other.values[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(PreservedList, Object.hashAll(values));

  @override
  String toString() => 'PreservedList(length: ${values.length})';
}

/// An immutable deterministically ordered string-keyed preserved map.
final class PreservedMap extends PreservedData {
  /// Defensively copies [values] and orders entries by key.
  PreservedMap(Map<String, PreservedData> values)
    : values = UnmodifiableMapView<String, PreservedData>(
        SplayTreeMap<String, PreservedData>.of(values),
      );

  /// Creates an empty preserved map.
  PreservedMap.empty() : this(<String, PreservedData>{});

  /// The unmodifiable key-sorted preserved entries.
  final Map<String, PreservedData> values;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! PreservedMap || other.values.length != values.length) {
      return false;
    }
    final leftEntries = values.entries.toList(growable: false);
    final rightEntries = other.values.entries.toList(growable: false);
    for (var index = 0; index < leftEntries.length; index += 1) {
      if (leftEntries[index].key != rightEntries[index].key ||
          leftEntries[index].value != rightEntries[index].value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    PreservedMap,
    Object.hashAll(
      values.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  @override
  String toString() => 'PreservedMap(length: ${values.length})';
}

/// Validates preserved unknown evidence incrementally under cumulative limits.
///
/// An entry beyond a boundary ceiling is detected with `moveNext` but its key
/// and value are never read. Accepted strings are scanned as UTF-16 evidence;
/// collection or string length metadata is not used to approve them.
bool preservedUnknownDataAllowed({
  required PreservedMap root,
  required int maximumFieldsPerBoundary,
  required int maximumNodes,
  required int maximumDepth,
  required int maximumStringCodeUnits,
}) {
  if (maximumFieldsPerBoundary < 0 ||
      maximumNodes <= 0 ||
      maximumDepth <= 0 ||
      maximumStringCodeUnits <= 0) {
    return false;
  }
  var nodes = 0;
  var remainingCodeUnits = maximumStringCodeUnits;
  final pending = <(PreservedData, int)>[(root, 1)];
  try {
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (current.$2 > maximumDepth) return false;
      switch (current.$1) {
        case PreservedMap(:final values):
          var boundary = 0;
          final iterator = values.entries.iterator;
          while (iterator.moveNext()) {
            if (boundary >= maximumFieldsPerBoundary ||
                nodes >= maximumNodes ||
                current.$2 >= maximumDepth) {
              return false;
            }
            final entry = iterator.current;
            final remaining = _consumeUtf16(entry.key, remainingCodeUnits);
            if (remaining == null) return false;
            remainingCodeUnits = remaining;
            boundary += 1;
            nodes += 1;
            pending.add((entry.value, current.$2 + 1));
          }
        case PreservedList(:final values):
          var boundary = 0;
          final iterator = values.iterator;
          while (iterator.moveNext()) {
            if (boundary >= maximumFieldsPerBoundary ||
                nodes >= maximumNodes ||
                current.$2 >= maximumDepth) {
              return false;
            }
            boundary += 1;
            nodes += 1;
            pending.add((iterator.current, current.$2 + 1));
          }
        case PreservedString(:final value):
          final remaining = _consumeUtf16(value, remainingCodeUnits);
          if (remaining == null) return false;
          remainingCodeUnits = remaining;
        default:
          break;
      }
    }
  } on Object {
    return false;
  }
  return true;
}

int? _consumeUtf16(String value, int remaining) {
  var index = 0;
  while (index < value.length) {
    if (remaining <= 0) return null;
    final unit = value.codeUnitAt(index);
    remaining -= 1;
    index += 1;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index >= value.length || remaining <= 0) return null;
      final low = value.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return null;
      remaining -= 1;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return null;
    }
  }
  return remaining;
}

StructuredFailure _preservedFailure(String code, String message) =>
    StructuredFailure(
      code: code,
      category: FailureCategory.validation,
      retryDisposition: RetryDisposition.never,
      message: message,
    );
