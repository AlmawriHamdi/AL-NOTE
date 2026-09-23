// SPDX-License-Identifier: GPL-3.0-or-later
// Worker-only native extraction. Never imported by application composition.
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as native;
import 'package:pdfrx_engine/pdfrx_engine.dart' as pdf;

enum ExtractionRejection { unsupported, limitExceeded, failed }

final class ExtractionRejected implements Exception {
  const ExtractionRejected(this.reason);
  final ExtractionRejection reason;
  @override
  String toString() => 'ExtractionRejected(${reason.name})';
}

const maximumExtractionResponseBytes = 2 * 1024 * 1024;
const maximumExtractionGlyphs = 8192;
const maximumExtractionLinks = 256;
const maximumExtractionAnnotations = 4096;
const maximumExtractionUriBytes = 2048;

int _limit(Object? value, int maximum) {
  if (value is! int || value <= 0 || value > maximum) {
    throw const ExtractionRejected(ExtractionRejection.limitExceeded);
  }
  return value;
}

List<double> _bounds(double left, double bottom, double right, double top) {
  final values = [left, bottom, right, top];
  if (values.any((v) => !v.isFinite || v.abs() > 1000000) ||
      right < left ||
      top < bottom) {
    throw const ExtractionRejected(ExtractionRejection.unsupported);
  }
  return values;
}

bool _safeHttp(String value) {
  if (value.isEmpty ||
      value.codeUnits.any((v) => v <= 32 || v == 127 || v == 92))
    return false;
  if (RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(value)) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.host.contains('%');
}

/// Counts before allocating result collections and URI buffers. PDFium's own
/// parse/text-page allocations remain inside the existing cgroup/deadline.
Future<Map<String, Object>> extractPage(
  pdf.PdfDocument document,
  Map<String, dynamic> request,
) {
  final pageIndex = request['page'];
  final pageLimit = _limit(request['maximumPages'], 1000);
  final glyphLimit = _limit(request['maximumGlyphs'], maximumExtractionGlyphs);
  final linkLimit = _limit(request['maximumLinks'], maximumExtractionLinks);
  final annotationLimit = _limit(
    request['maximumOperations'],
    maximumExtractionAnnotations,
  );
  if (pageIndex is! int ||
      pageIndex < 0 ||
      pageIndex >= document.pages.length ||
      document.pages.length > pageLimit ||
      request['allowHttp'] is! bool) {
    throw const ExtractionRejected(ExtractionRejection.limitExceeded);
  }
  final operation = request['operation'];
  if (operation != 'text' && operation != 'links') {
    throw const ExtractionRejected(ExtractionRejection.unsupported);
  }
  return document.useNativeDocumentHandle((address) {
    final engine = native.PDFium(DynamicLibrary.open('/runtime/libpdfium.so'));
    final doc = native.FPDF_DOCUMENT.fromAddress(address);
    final page = engine.FPDF_LoadPage(doc, pageIndex);
    if (page == nullptr)
      throw const ExtractionRejected(ExtractionRejection.failed);
    try {
      return using((arena) {
        final records = <Object>[];
        var remainingBytes = maximumExtractionResponseBytes - 1024;
        void append(Object record) {
          // Each individual record is already bounded (four numbers and at most
          // one length-checked URI). Bound the aggregate before retaining it.
          remainingBytes -= utf8.encode(jsonEncode(record)).length + 1;
          if (remainingBytes < 0) {
            throw const ExtractionRejected(ExtractionRejection.limitExceeded);
          }
          records.add(record);
        }

        if (operation == 'text') {
          final text = engine.FPDFText_LoadPage(page);
          if (text == nullptr)
            throw const ExtractionRejected(ExtractionRejection.failed);
          try {
            final count = engine.FPDFText_CountChars(text);
            if (count < 0)
              throw const ExtractionRejected(ExtractionRejection.failed);
            if (count > glyphLimit * 2)
              throw const ExtractionRejected(ExtractionRejection.limitExceeded);
            final box = arena<Double>(4);
            for (var index = 0; index < count; index++) {
              var scalar = engine.FPDFText_GetUnicode(text, index);
              if (scalar <= 0 ||
                  scalar > 0x10ffff ||
                  engine.FPDFText_HasUnicodeMapError(text, index) != 0) {
                throw const ExtractionRejected(ExtractionRejection.unsupported);
              }
              if (engine.FPDFText_GetCharBox(
                    text,
                    index,
                    box,
                    box + 2,
                    box + 1,
                    box + 3,
                  ) ==
                  0) {
                throw const ExtractionRejected(ExtractionRejection.unsupported);
              }
              final bounds = _bounds(box[0], box[1], box[2], box[3]);
              // Generated separators may have no physical glyph. Preserve this
              // explicitly; regional projection decides whether it can be used.
              final generated = engine.FPDFText_IsGenerated(text, index);
              if (generated < 0)
                throw const ExtractionRejected(ExtractionRejection.unsupported);
              // PDFium's ToUnicode mappings expose UTF-16 code units even on
              // this native backend. Combine a valid pair before emitting the
              // backend-neutral Unicode scalar; malformed pairs reject.
              if (scalar >= 0xd800 && scalar <= 0xdbff) {
                if (++index >= count)
                  throw const ExtractionRejected(
                    ExtractionRejection.unsupported,
                  );
                final low = engine.FPDFText_GetUnicode(text, index);
                if (low < 0xdc00 ||
                    low > 0xdfff ||
                    engine.FPDFText_HasUnicodeMapError(text, index) != 0 ||
                    engine.FPDFText_IsGenerated(text, index) != generated ||
                    engine.FPDFText_GetCharBox(
                          text,
                          index,
                          box,
                          box + 2,
                          box + 1,
                          box + 3,
                        ) ==
                        0) {
                  throw const ExtractionRejected(
                    ExtractionRejection.unsupported,
                  );
                }
                final secondBounds = _bounds(box[0], box[1], box[2], box[3]);
                for (var coordinate = 0; coordinate < 4; coordinate++) {
                  if (secondBounds[coordinate] != bounds[coordinate]) {
                    throw const ExtractionRejected(
                      ExtractionRejection.unsupported,
                    );
                  }
                }
                scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
              } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
                throw const ExtractionRejected(ExtractionRejection.unsupported);
              }
              if (records.length >= glyphLimit)
                throw const ExtractionRejected(
                  ExtractionRejection.limitExceeded,
                );
              if (generated == 1 && !const {9, 10, 13, 32}.contains(scalar)) {
                throw const ExtractionRejected(ExtractionRejection.unsupported);
              }
              append([scalar, generated == 1 ? null : bounds]);
            }
          } finally {
            engine.FPDFText_ClosePage(text);
          }
        } else {
          final annotations = engine.FPDFPage_GetAnnotCount(page);
          if (annotations < 0)
            throw const ExtractionRejected(ExtractionRejection.failed);
          if (annotations > annotationLimit)
            throw const ExtractionRejected(ExtractionRejection.limitExceeded);
          final position = arena<Int>();
          final linkPointer = arena<native.FPDF_LINK>();
          final box = arena<native.FS_RECTF>();
          while (engine.FPDFLink_Enumerate(page, position, linkPointer) != 0) {
            if (records.length >= linkLimit || position.value > annotations) {
              throw const ExtractionRejected(ExtractionRejection.limitExceeded);
            }
            final link = linkPointer.value;
            if (link == nullptr ||
                engine.FPDFLink_GetAnnotRect(link, box) == 0) {
              throw const ExtractionRejected(ExtractionRejection.unsupported);
            }
            final bounds = _bounds(
              box.ref.left,
              box.ref.bottom,
              box.ref.right,
              box.ref.top,
            );
            if (bounds[0] == bounds[2] || bounds[1] == bounds[3]) {
              throw const ExtractionRejected(ExtractionRejection.unsupported);
            }
            final action = engine.FPDFLink_GetAction(link);
            var destination = engine.FPDFLink_GetDest(doc, link);
            String? uri;
            if (action != nullptr) {
              switch (engine.FPDFAction_GetType(action)) {
                case native.PDFACTION_GOTO:
                  destination = engine.FPDFAction_GetDest(doc, action);
                case native.PDFACTION_URI:
                  if (request['allowHttp'] != true)
                    throw const ExtractionRejected(
                      ExtractionRejection.unsupported,
                    );
                  final length = engine.FPDFAction_GetURIPath(
                    doc,
                    action,
                    nullptr,
                    0,
                  );
                  if (length < 2 || length > maximumExtractionUriBytes + 1) {
                    throw const ExtractionRejected(
                      ExtractionRejection.limitExceeded,
                    );
                  }
                  // Free each URI before the next link; no growing native arena.
                  final buffer = calloc<Uint8>(length);
                  try {
                    if (engine.FPDFAction_GetURIPath(
                              doc,
                              action,
                              buffer.cast(),
                              length,
                            ) !=
                            length ||
                        buffer[length - 1] != 0) {
                      throw const ExtractionRejected(
                        ExtractionRejection.unsupported,
                      );
                    }
                    uri = utf8.decode(buffer.asTypedList(length - 1));
                    if (!_safeHttp(uri))
                      throw const ExtractionRejected(
                        ExtractionRejection.unsupported,
                      );
                  } finally {
                    calloc.free(buffer);
                  }
                default:
                  throw const ExtractionRejected(
                    ExtractionRejection.unsupported,
                  );
              }
            }
            if (uri != null) {
              append({'bounds': bounds, 'kind': 'http', 'uri': uri});
            } else {
              if (destination == nullptr)
                throw const ExtractionRejected(ExtractionRejection.unsupported);
              final target = engine.FPDFDest_GetDestPageIndex(doc, destination);
              if (target < 0 || target >= document.pages.length) {
                throw const ExtractionRejected(ExtractionRejection.unsupported);
              }
              append({
                'bounds': bounds,
                'kind': 'internal',
                'destination': target,
              });
            }
          }
        }
        return <String, Object>{
          'operation': operation as String,
          'pageIndex': pageIndex,
          'pageCount': document.pages.length,
          'complete': true,
          'count': records.length,
          'records': records,
        };
      });
    } finally {
      engine.FPDF_ClosePage(page);
    }
  });
}
