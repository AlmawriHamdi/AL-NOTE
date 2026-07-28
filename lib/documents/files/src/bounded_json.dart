// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../model/preserved_data.dart';
import '../contracts.dart';

/// Private bounded strict JSON parser and canonical encoder.
final class BoundedJsonCodec {
  /// Creates the codec with explicit caller-policy ceilings.
  const BoundedJsonCodec({
    required this.maximumBytes,
    required this.maximumDepth,
    required this.maximumValues,
    required this.maximumStringCodeUnits,
  });

  final int maximumBytes;
  final int maximumDepth;
  final int maximumValues;
  final int maximumStringCodeUnits;

  /// Parses strict UTF-8 JSON into immutable preservation values.
  Result<PreservedData, StructuredFailure> decode(List<int> bytes) {
    try {
      if (bytes.length > maximumBytes ||
          bytes.any((byte) => byte < 0 || byte > 255) ||
          bytes.isNotEmpty &&
              bytes.length >= 3 &&
              bytes[0] == 0xef &&
              bytes[1] == 0xbb &&
              bytes[2] == 0xbf) {
        return Err<PreservedData, StructuredFailure>(
          _jsonFailure('json_bytes'),
        );
      }
      final text = utf8.decode(bytes, allowMalformed: false);
      final parser = _Parser(
        text,
        maximumDepth: maximumDepth,
        maximumValues: maximumValues,
        maximumStringCodeUnits: maximumStringCodeUnits,
      );
      return Ok<PreservedData, StructuredFailure>(parser.parse());
    } on _JsonRejected catch (rejected) {
      return Err<PreservedData, StructuredFailure>(
        _jsonFailure(rejected.dimension),
      );
    } on FormatException {
      return Err<PreservedData, StructuredFailure>(_jsonFailure('json_syntax'));
    } on Object {
      return Err<PreservedData, StructuredFailure>(_jsonFailure('json_syntax'));
    }
  }

  /// Encodes immutable preserved data as canonical strict UTF-8 JSON.
  Result<List<int>, StructuredFailure> encode(PreservedData value) {
    try {
      final buffer = _BoundedOutput(maximumBytes);
      _writeValue(value, buffer, 0, _EncodingState());
      final bytes = utf8.encode(buffer.toString());
      return Ok<List<int>, StructuredFailure>(List<int>.unmodifiable(bytes));
    } on _JsonRejected catch (rejected) {
      return Err<List<int>, StructuredFailure>(
        _jsonFailure(rejected.dimension),
      );
    } on Object {
      return Err<List<int>, StructuredFailure>(_jsonFailure('json_syntax'));
    }
  }

  void _writeValue(
    PreservedData value,
    _BoundedOutput output,
    int depth,
    _EncodingState state,
  ) {
    state.valueCount += 1;
    if (state.valueCount > maximumValues) {
      throw const _JsonRejected('json_values');
    }
    if (depth > maximumDepth) throw const _JsonRejected('json_depth');
    switch (value) {
      case PreservedNull():
        output.write('null');
      case PreservedBoolean(:final value):
        output.write(value ? 'true' : 'false');
      case PreservedInteger(:final value):
        if (value < -maximumWebSafeInteger || value > maximumWebSafeInteger) {
          throw const _JsonRejected('json_number');
        }
        output.write(value);
      case PreservedDouble(:final value):
        if (!value.isFinite) throw const _JsonRejected('json_number');
        output.write(jsonEncode(value));
      case PreservedString(:final value):
        if (value.length > maximumStringCodeUnits ||
            _hasUnpairedSurrogate(value)) {
          throw const _JsonRejected('string_code_units');
        }
        _writeJsonString(value, output);
      case PreservedList(:final values):
        output.write('[');
        for (var index = 0; index < values.length; index += 1) {
          if (index != 0) output.write(',');
          _writeValue(values[index], output, depth + 1, state);
        }
        output.write(']');
      case PreservedMap(:final values):
        output.write('{');
        var first = true;
        for (final entry in values.entries) {
          if (entry.key.length > maximumStringCodeUnits ||
              _hasUnpairedSurrogate(entry.key)) {
            throw const _JsonRejected('string_code_units');
          }
          if (!first) output.write(',');
          first = false;
          _writeJsonString(entry.key, output);
          output.write(':');
          _writeValue(entry.value, output, depth + 1, state);
        }
        output.write('}');
    }
  }

  void _writeJsonString(String value, _BoundedOutput output) {
    output.write('"');
    for (var index = 0; index < value.length; index += 1) {
      final code = value.codeUnitAt(index);
      switch (code) {
        case 0x22:
          output.write(r'\"');
        case 0x5c:
          output.write(r'\\');
        case 0x08:
          output.write(r'\b');
        case 0x0c:
          output.write(r'\f');
        case 0x0a:
          output.write(r'\n');
        case 0x0d:
          output.write(r'\r');
        case 0x09:
          output.write(r'\t');
        default:
          if (code < 0x20) {
            output.write('\\u${code.toRadixString(16).padLeft(4, '0')}');
          } else if (_isHighSurrogate(code)) {
            output.write(
              String.fromCharCodes(<int>[code, value.codeUnitAt(++index)]),
            );
          } else {
            output.writeCharCode(code);
          }
      }
    }
    output.write('"');
  }
}

final class _Parser {
  _Parser(
    this.source, {
    required this.maximumDepth,
    required this.maximumValues,
    required this.maximumStringCodeUnits,
  });

  final String source;
  final int maximumDepth;
  final int maximumValues;
  final int maximumStringCodeUnits;
  var offset = 0;
  var valueCount = 0;

  PreservedData parse() {
    _skipWhitespace();
    final result = _value(0);
    _skipWhitespace();
    if (offset != source.length) throw const _JsonRejected('json_syntax');
    return result;
  }

  PreservedData _value(int depth) {
    valueCount += 1;
    if (valueCount > maximumValues) throw const _JsonRejected('json_values');
    if (depth > maximumDepth) throw const _JsonRejected('json_depth');
    if (offset >= source.length) throw const _JsonRejected('json_syntax');
    return switch (source.codeUnitAt(offset)) {
      0x6e => _literal('null', const PreservedNull()),
      0x74 => _literal('true', const PreservedBoolean(true)),
      0x66 => _literal('false', const PreservedBoolean(false)),
      0x22 => PreservedString(_string()),
      0x5b => _array(depth),
      0x7b => _object(depth),
      _ => _number(),
    };
  }

  PreservedData _literal(String text, PreservedData value) {
    if (!source.startsWith(text, offset)) {
      throw const _JsonRejected('json_syntax');
    }
    offset += text.length;
    return value;
  }

  PreservedList _array(int depth) {
    offset += 1;
    _skipWhitespace();
    final values = <PreservedData>[];
    if (_consume(0x5d)) return PreservedList(values);
    while (true) {
      values.add(_value(depth + 1));
      _skipWhitespace();
      if (_consume(0x5d)) return PreservedList(values);
      _expect(0x2c);
      _skipWhitespace();
    }
  }

  PreservedMap _object(int depth) {
    offset += 1;
    _skipWhitespace();
    final values = <String, PreservedData>{};
    if (_consume(0x7d)) return PreservedMap(values);
    while (true) {
      if (offset >= source.length || source.codeUnitAt(offset) != 0x22) {
        throw const _JsonRejected('json_syntax');
      }
      final key = _string();
      if (values.containsKey(key))
        throw const _JsonRejected('json_duplicate_key');
      _skipWhitespace();
      _expect(0x3a);
      _skipWhitespace();
      values[key] = _value(depth + 1);
      _skipWhitespace();
      if (_consume(0x7d)) return PreservedMap(values);
      _expect(0x2c);
      _skipWhitespace();
    }
  }

  String _string() {
    _expect(0x22);
    final output = StringBuffer();
    while (offset < source.length) {
      final code = source.codeUnitAt(offset++);
      if (code == 0x22) {
        final value = output.toString();
        if (value.length > maximumStringCodeUnits) {
          throw const _JsonRejected('string_code_units');
        }
        return value;
      }
      if (code < 0x20) throw const _JsonRejected('json_syntax');
      if (code != 0x5c) {
        if (_isLowSurrogate(code)) throw const _JsonRejected('json_surrogate');
        if (_isHighSurrogate(code)) {
          if (offset >= source.length ||
              !_isLowSurrogate(source.codeUnitAt(offset))) {
            throw const _JsonRejected('json_surrogate');
          }
          output
            ..writeCharCode(code)
            ..writeCharCode(source.codeUnitAt(offset++));
        } else {
          output.writeCharCode(code);
        }
        if (output.length > maximumStringCodeUnits) {
          throw const _JsonRejected('string_code_units');
        }
        continue;
      }
      if (offset >= source.length) throw const _JsonRejected('json_syntax');
      final escaped = source.codeUnitAt(offset++);
      switch (escaped) {
        case 0x22:
        case 0x5c:
        case 0x2f:
          output.writeCharCode(escaped);
        case 0x62:
          output.writeCharCode(0x08);
        case 0x66:
          output.writeCharCode(0x0c);
        case 0x6e:
          output.writeCharCode(0x0a);
        case 0x72:
          output.writeCharCode(0x0d);
        case 0x74:
          output.writeCharCode(0x09);
        case 0x75:
          final first = _hexCodeUnit();
          if (_isHighSurrogate(first)) {
            if (offset + 2 > source.length ||
                source.codeUnitAt(offset) != 0x5c ||
                source.codeUnitAt(offset + 1) != 0x75) {
              throw const _JsonRejected('json_surrogate');
            }
            offset += 2;
            final second = _hexCodeUnit();
            if (!_isLowSurrogate(second)) {
              throw const _JsonRejected('json_surrogate');
            }
            output
              ..writeCharCode(first)
              ..writeCharCode(second);
          } else if (_isLowSurrogate(first)) {
            throw const _JsonRejected('json_surrogate');
          } else {
            output.writeCharCode(first);
          }
        default:
          throw const _JsonRejected('json_syntax');
      }
      if (output.length > maximumStringCodeUnits) {
        throw const _JsonRejected('string_code_units');
      }
    }
    throw const _JsonRejected('json_syntax');
  }

  int _hexCodeUnit() {
    if (offset + 4 > source.length) throw const _JsonRejected('json_syntax');
    final text = source.substring(offset, offset + 4);
    if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(text)) {
      throw const _JsonRejected('json_syntax');
    }
    offset += 4;
    return int.parse(text, radix: 16);
  }

  PreservedData _number() {
    final start = offset;
    if (_consume(0x2d) && offset >= source.length) {
      throw const _JsonRejected('json_number');
    }
    if (_consume(0x30)) {
      if (offset < source.length && _isDigit(source.codeUnitAt(offset))) {
        throw const _JsonRejected('json_number');
      }
    } else {
      _digits(required: true);
    }
    var isDouble = false;
    if (_consume(0x2e)) {
      isDouble = true;
      _digits(required: true);
    }
    if (offset < source.length &&
        (source.codeUnitAt(offset) == 0x65 ||
            source.codeUnitAt(offset) == 0x45)) {
      isDouble = true;
      offset += 1;
      if (offset < source.length &&
          (source.codeUnitAt(offset) == 0x2b ||
              source.codeUnitAt(offset) == 0x2d)) {
        offset += 1;
      }
      _digits(required: true);
    }
    final text = source.substring(start, offset);
    if (isDouble) {
      final value = double.tryParse(text);
      if (value == null || !value.isFinite)
        throw const _JsonRejected('json_number');
      return PreservedDouble.create(value).fold(
        onOk: (result) => result,
        onErr: (_) => throw const _JsonRejected('json_number'),
      );
    }
    final value = int.tryParse(text);
    if (value == null || value.abs() > maximumWebSafeInteger) {
      throw const _JsonRejected('json_number');
    }
    return PreservedInteger.create(value).fold(
      onOk: (result) => result,
      onErr: (_) => throw const _JsonRejected('json_number'),
    );
  }

  void _digits({required bool required}) {
    final start = offset;
    while (offset < source.length && _isDigit(source.codeUnitAt(offset))) {
      offset += 1;
    }
    if (required && start == offset) throw const _JsonRejected('json_number');
  }

  void _skipWhitespace() {
    while (offset < source.length) {
      final code = source.codeUnitAt(offset);
      if (code != 0x20 && code != 0x09 && code != 0x0a && code != 0x0d) return;
      offset += 1;
    }
  }

  bool _consume(int code) {
    if (offset < source.length && source.codeUnitAt(offset) == code) {
      offset += 1;
      return true;
    }
    return false;
  }

  void _expect(int code) {
    if (!_consume(code)) throw const _JsonRejected('json_syntax');
  }
}

final class _EncodingState {
  var valueCount = 0;
}

final class _BoundedOutput {
  _BoundedOutput(this.maximumBytes);

  final int maximumBytes;
  final StringBuffer _buffer = StringBuffer();
  var _byteLength = 0;

  void write(Object? value) {
    final text = value.toString();
    _byteLength += utf8.encode(text).length;
    if (_byteLength > maximumBytes) throw const _JsonRejected('json_bytes');
    _buffer.write(text);
  }

  void writeCharCode(int code) => write(String.fromCharCode(code));

  @override
  String toString() => _buffer.toString();
}

final class _JsonRejected implements Exception {
  const _JsonRejected(this.dimension);
  final String dimension;
}

StructuredFailure _jsonFailure(String dimension) => storageFailure(
  dimension,
  'JSON input violates a required storage policy dimension.',
);

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;
bool _isHighSurrogate(int code) => code >= 0xd800 && code <= 0xdbff;
bool _isLowSurrogate(int code) => code >= 0xdc00 && code <= 0xdfff;

bool _hasUnpairedSurrogate(String value) {
  for (var index = 0; index < value.length; index += 1) {
    final code = value.codeUnitAt(index);
    if (_isHighSurrogate(code)) {
      if (index + 1 >= value.length ||
          !_isLowSurrogate(value.codeUnitAt(index + 1))) {
        return true;
      }
      index += 1;
    } else if (_isLowSurrogate(code)) {
      return true;
    }
  }
  return false;
}
