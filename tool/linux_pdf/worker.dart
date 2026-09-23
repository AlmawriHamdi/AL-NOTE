// SPDX-License-Identifier: GPL-3.0-or-later
// Prototype executable only. Never imported by application composition.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfrx_engine/pdfrx_engine.dart' as pdf;

import 'extraction.dart';

enum _Rejection { passwordRequired, unsupported, limitExceeded, failed }

final class _Reject implements Exception {
  const _Reject(this.reason);
  final _Rejection reason;
}

const maximumInput = 50000000;
const maximumPages = 1000;
const maximumDimension = 4096;

final class _Input {
  final StreamIterator<List<int>> _chunks = StreamIterator(stdin);
  List<int> _chunk = const [];
  int _offset = 0;

  Future<Uint8List> read(int count) async {
    final output = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_offset == _chunk.length) {
        if (!await _chunks.moveNext()) throw const FormatException('EOF');
        _chunk = _chunks.current;
        _offset = 0;
      }
      final available = _chunk.length - _offset;
      final take = available < count - written ? available : count - written;
      output.setRange(written, written + take, _chunk, _offset);
      written += take;
      _offset += take;
    }
    return output;
  }

  Future<Uint8List> frame(int maximum) async {
    final length = ByteData.sublistView(await read(4)).getUint32(0);
    if (length == 0 || length > maximum) {
      throw const FormatException('input limit');
    }
    return read(length);
  }
}

Future<void> _frame(List<int> bytes) async {
  final header = ByteData(4)..setUint32(0, bytes.length);
  stdout.add(header.buffer.asUint8List());
  stdout.add(bytes);
  await stdout.flush();
}

Future<void> _json(Map<String, Object> value) {
  final bytes = utf8.encode(jsonEncode(value));
  if (bytes.length > maximumExtractionResponseBytes) {
    throw const _Reject(_Rejection.limitExceeded);
  }
  return _frame(bytes);
}

Map<String, Object> _geometry(pdf.PdfPage page) {
  final box = page.effectivePageBox;
  if (box == null || box.kind != pdf.PdfPageBoxKind.resolvedBounds) {
    throw const _Reject(_Rejection.unsupported);
  }
  final values = [box.left, box.bottom, box.right, box.top];
  if (values.any((v) => !v.isFinite || v.abs() > 1000000)) {
    throw const _Reject(_Rejection.unsupported);
  }
  final width = box.right - box.left;
  final height = box.top - box.bottom;
  if (width <= 0 || height <= 0) throw const _Reject(_Rejection.unsupported);
  final rotated = box.rotation.index.isOdd;
  final exactWidth = rotated ? height : width;
  final exactHeight = rotated ? width : height;
  final rounded = Float32List.fromList([exactWidth, exactHeight]);
  if (box.displayedWidth != rounded[0] || box.displayedHeight != rounded[1]) {
    throw const _Reject(_Rejection.unsupported);
  }
  return {
    'bounds': values,
    'rotation': box.rotation.index * 90,
    'width': exactWidth,
    'height': exactHeight,
    'kind': 'resolvedBounds',
  };
}

Future<void> main() async {
  pdf.PdfDocument? document;
  pdf.PdfImage? image;
  Uint8List? source;
  var initialized = false;
  var documentReleases = 0;
  int? requestId;
  var completeInput = false;
  final timer = Stopwatch()..start();
  try {
    final guard = DynamicLibrary.open('/runtime/libguard.so');
    final restrict = guard.lookupFunction<Int32 Function(), int Function()>(
      'alnote_restrict',
    );
    if (restrict() != 0) throw const FormatException('isolation');
    // Fixed path only; no environment/default native-asset resolution.
    pdf.Pdfrx.pdfiumModulePath = '/runtime/libpdfium.so';
    pdf.Pdfrx.cacheDirectoryPath = '/tmp';
    await pdf.pdfrxInitialize(tmpPath: '/tmp');
    initialized = true;
    await _json({
      'ready': true,
      'initialization_us': timer.elapsedMicroseconds,
    });
    final input = _Input();
    final header = jsonDecode(utf8.decode(await input.frame(1024)));
    if (header is! Map<String, dynamic> ||
        header['version'] is! int ||
        header['version'] != 1 ||
        !['inspect', 'render', 'text', 'links'].contains(header['operation'])) {
      throw const FormatException('request');
    }
    final Object? id = header['id'];
    if (id is! int || id < 0 || id > 2147483647) {
      throw const FormatException('request identity');
    }
    requestId = id;
    source = await input.frame(maximumInput);
    completeInput = true;
    final inspection = Stopwatch()..start();
    document = await pdf.PdfDocument.openData(
      source,
      sourceName: 'isolated-prototype',
      passwordProvider: () => null,
      onDispose: () => documentReleases++,
    );
    if (document.isEncrypted) throw const _Reject(_Rejection.unsupported);
    if (document.pages.isEmpty) throw const _Reject(_Rejection.failed);
    if (document.pages.length > maximumPages)
      throw const _Reject(_Rejection.limitExceeded);
    final pages = document.pages.map(_geometry).toList();
    final inspectionUs = inspection.elapsedMicroseconds;
    if (header['operation'] == 'inspect') {
      await _json({
        'version': 1,
        'id': id,
        'status': 'ok',
        'pages': pages,
        'inspection_us': inspectionUs,
      });
    } else if (header['operation'] == 'text' ||
        header['operation'] == 'links') {
      final extracted = await extractPage(document, header);
      await _json({
        'version': 1,
        'id': id,
        'status': 'ok',
        'page': pages[header['page'] as int],
        ...extracted,
      });
    } else {
      final page = header['page'];
      final width = header['width'];
      final height = header['height'];
      if (page is! int ||
          page < 0 ||
          page >= pages.length ||
          width is! int ||
          height is! int ||
          width <= 0 ||
          height <= 0 ||
          width > maximumDimension ||
          height > maximumDimension) {
        throw const _Reject(_Rejection.limitExceeded);
      }
      final rendering = Stopwatch()..start();
      image = await document.pages[page].render(
        width: width,
        height: height,
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xffffffff,
        annotationRenderingMode: pdf.PdfAnnotationRenderingMode.none,
      );
      if (image == null ||
          image.width != width ||
          image.height != height ||
          image.pixels.length != width * height * 4) {
        throw const FormatException('render output');
      }
      final rgba = Uint8List(width * height * 4);
      final bgra = image.pixels;
      for (var offset = 0; offset < rgba.length; offset += 4) {
        rgba[offset] = bgra[offset + 2];
        rgba[offset + 1] = bgra[offset + 1];
        rgba[offset + 2] = bgra[offset];
        rgba[offset + 3] = bgra[offset + 3];
      }
      await _json({
        'version': 1,
        'id': id,
        'status': 'ok',
        'page': pages[page],
        'width': width,
        'height': height,
        'bytes': rgba.length,
        'inspection_us': inspectionUs,
        'render_us': rendering.elapsedMicroseconds,
      });
      await _frame(rgba);
    }
  } on Object catch (error) {
    // Known reasons follow a fully received request. Abnormal exits never
    // publish a recognized outcome, even if a partial frame reached the parent.
    if (completeInput && requestId != null) {
      final reason = error is pdf.PdfPasswordException
          ? _Rejection.passwordRequired
          : error is _Reject
          ? error.reason
          : error is ExtractionRejected
          ? _Rejection.values.byName(error.reason.name)
          : _Rejection.failed;
      await _json({
        'version': 1,
        'id': requestId,
        'status': 'rejected',
        'reason': reason.name,
      });
    } else {
      exitCode = 1;
    }
  } finally {
    image?.dispose();
    await document?.dispose();
    if (document != null && documentReleases != 1) {
      throw StateError('document cleanup count');
    }
    if (initialized)
      await pdf.PdfrxEntryFunctions.instance.stopBackgroundWorker();
    source?.fillRange(0, source.length, 0);
  }
  // Exit only after document, image and engine cleanup have completed.
  exit(exitCode);
}
