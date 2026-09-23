// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'linux_pdf_extraction.dart';

/// Closed worker outcomes. No exception text or source evidence crosses here.
enum LinuxPdfRejection { passwordRequired, unsupported, limitExceeded, failed }

final class LinuxPdfRejected implements Exception {
  const LinuxPdfRejected(this.reason);
  final LinuxPdfRejection reason;
  @override
  String toString() => 'LinuxPdfRejected(${reason.name})';
}

final class LinuxPdfIsolationUnavailable implements Exception {
  const LinuxPdfIsolationUnavailable();
}

/// Bounded framing independent of stream chunk boundaries. At most one current
/// payload plus the three fixed response frames is retained.
final class LinuxPdfFrames {
  LinuxPdfFrames({
    required this.width,
    required this.height,
    required this.render,
    required this.onReady,
    this.extraction,
  });
  final int width;
  final int height;
  final bool render;
  final void Function() onReady;
  final LinuxPdfExtractionRequest? extraction;
  final frames = <Object>[];
  final _header = Uint8List(4);
  int _headerUsed = 0;
  Uint8List? _payload;
  int _used = 0;
  int _total = 0;
  LinuxPdfRejection? rejection;
  int get _expectedFrames => render && rejection == null ? 3 : 2;

  /// Drop all private raster storage while retaining only cleanup ownership.
  void discard() {
    frames.clear();
    rejection = null;
    _payload = null;
    _headerUsed = 0;
    _used = 0;
  }

  void add(List<int> chunk) {
    _total += chunk.length;
    if (_total >
        (extraction == null
            ? 2 * 256 * 1024 + 12 + width * height * 4
            : 256 * 1024 + linuxPdfExtractionResponseBytes + 8)) {
      throw const FormatException('total output limit');
    }
    var offset = 0;
    while (offset < chunk.length) {
      if (frames.length >= _expectedFrames) {
        throw const FormatException('excess output');
      }
      if (_payload == null) {
        while (_headerUsed < 4 && offset < chunk.length) {
          _header[_headerUsed++] = chunk[offset++];
        }
        if (_headerUsed < 4) return;
        final length = ByteData.sublistView(_header).getUint32(0);
        final maximum = frames.length == 2
            ? width * height * 4
            : frames.length == 1 && extraction != null
            ? linuxPdfExtractionResponseBytes
            : 256 * 1024;
        if (length <= 0 || length > maximum) {
          throw const FormatException('frame length');
        }
        _payload = Uint8List(length);
        _used = 0;
      }
      final payload = _payload!;
      final count = (chunk.length - offset).clamp(0, payload.length - _used);
      payload.setRange(_used, _used + count, chunk, offset);
      _used += count;
      offset += count;
      if (_used == payload.length) {
        _payload = null;
        _headerUsed = 0;
        if (frames.length < 2) {
          final value = jsonDecode(utf8.decode(payload));
          if (value is! Map<String, dynamic>)
            throw const FormatException('metadata');
          for (final name in [
            'initialization_us',
            'inspection_us',
            'render_us',
          ]) {
            if (value.containsKey(name) &&
                (value[name] is! int || (value[name] as int) < 0)) {
              throw const FormatException('integer timing');
            }
          }
          if (frames.isEmpty) {
            if (value['ready'] != true)
              throw const FormatException('not ready');
            frames.add(value);
            onReady();
          } else {
            if (value['version'] is! int ||
                value['version'] != 1 ||
                value['id'] is! int ||
                value['id'] != 1) {
              throw const FormatException('response identity');
            }
            if (value['status'] == 'rejected') {
              final reason = value['reason'];
              final matches = LinuxPdfRejection.values.where(
                (v) => v.name == reason,
              );
              if (matches.length != 1 ||
                  value.keys.any(
                    (key) => !const {
                      'version',
                      'id',
                      'status',
                      'reason',
                    }.contains(key),
                  )) {
                throw const FormatException('rejection metadata');
              }
              rejection = matches.single;
              frames.add(value);
              continue;
            }
            if (value['status'] != 'ok')
              throw const FormatException('response status');
            if (extraction != null) {
              geometry(value['page']);
              extraction!.validateResponse(value);
            } else if (render) {
              geometry(value['page']);
              for (final entry in {
                'width': width,
                'height': height,
                'bytes': width * height * 4,
              }.entries) {
                if (value[entry.key] is! int ||
                    value[entry.key] != entry.value) {
                  throw const FormatException('raster metadata');
                }
              }
            } else {
              final pages = value['pages'];
              if (pages is! List || pages.isEmpty || pages.length > 1000) {
                throw const FormatException('page limit');
              }
              for (final page in pages) {
                geometry(page);
              }
            }
            frames.add(value);
          }
        } else {
          if (payload.length != width * height * 4)
            throw const FormatException('raster length');
          frames.add(payload);
        }
      }
    }
  }

  void finish() {
    if (_headerUsed != 0 ||
        _payload != null ||
        frames.length != _expectedFrames) {
      throw const FormatException('incomplete output');
    }
  }

  static Map<String, dynamic> geometry(Object? object) {
    if (object is! Map<String, dynamic> || object['kind'] != 'resolvedBounds') {
      throw const FormatException('geometry');
    }
    final bounds = object['bounds'];
    if (bounds is! List || bounds.length != 4)
      throw const FormatException('bounds');
    for (final value in [...bounds, object['width'], object['height']]) {
      // A huge JSON integer may decode to infinity on Dart. Bound before any
      // toDouble/toInt conversion; bool is not num, integral float is not int.
      if (value is! num || value.abs() > 2000000 || !value.isFinite) {
        throw const FormatException('coordinates');
      }
    }
    final rotation = object['rotation'];
    if (rotation is! int || ![0, 90, 180, 270].contains(rotation)) {
      throw const FormatException('rotation');
    }
    final width = (bounds[2] as num) - (bounds[0] as num);
    final height = (bounds[3] as num) - (bounds[1] as num);
    final swap = rotation == 90 || rotation == 270;
    if (width <= 0 ||
        height <= 0 ||
        object['width'] != (swap ? height : width) ||
        object['height'] != (swap ? width : height)) {
      throw const FormatException('exact geometry');
    }
    return object;
  }
}
