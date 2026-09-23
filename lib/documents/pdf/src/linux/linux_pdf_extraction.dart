// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:math' as math;

import '../../../../core/primitives.dart';
import '../../pdf_backend.dart';
import '../../pdf_model.dart';

/// Parent-owned extraction protocol ceilings, independent of worker validation.
const linuxPdfExtractionResponseBytes = 2 * 1024 * 1024;
const linuxPdfExtractionGlyphs = 8192;
const linuxPdfExtractionLinks = 256;
const linuxPdfExtractionAnnotations = 4096;
const linuxPdfExtractionUriBytes = 2048;

enum LinuxPdfExtractionOperation { text, links }

/// An app-owned request, never populated from worker metadata.
final class LinuxPdfExtractionRequest {
  const LinuxPdfExtractionRequest({
    required this.operation,
    required this.pageIndex,
    required this.maximumPages,
    required this.maximumGlyphs,
    required this.maximumLinks,
    required this.maximumOperations,
    this.allowHttp = false,
  });
  final LinuxPdfExtractionOperation operation;
  final int pageIndex;
  final int maximumPages;
  final int maximumGlyphs;
  final int maximumLinks;
  final int maximumOperations;
  final bool allowHttp;

  void validate() {
    if (pageIndex < 0 ||
        pageIndex >= maximumPages ||
        maximumPages <= 0 ||
        maximumPages > 1000 ||
        maximumGlyphs <= 0 ||
        maximumGlyphs > linuxPdfExtractionGlyphs ||
        maximumLinks <= 0 ||
        maximumLinks > linuxPdfExtractionLinks ||
        maximumOperations <= 0 ||
        maximumOperations > linuxPdfExtractionAnnotations) {
      throw const FormatException('extraction limits');
    }
  }

  Map<String, Object> toProtocol() => {
    'operation': operation.name,
    'page': pageIndex,
    'maximumPages': maximumPages,
    'maximumGlyphs': maximumGlyphs,
    'maximumLinks': maximumLinks,
    'maximumOperations': maximumOperations,
    'allowHttp': allowHttp,
  };

  /// Independently validates complete structural output before publication.
  /// Semantic PDF interpretation remains engine-owned, never app parsing.
  void validateResponse(Map<String, dynamic> response) {
    validate();
    final pageCount = response['pageCount'];
    final count = response['count'];
    final records = response['records'];
    if (response.keys.toSet().difference(const {
          'version',
          'id',
          'status',
          'operation',
          'page',
          'pageIndex',
          'pageCount',
          'complete',
          'count',
          'records',
        }).isNotEmpty ||
        response['operation'] != operation.name ||
        response['pageIndex'] is! int ||
        response['pageIndex'] != pageIndex ||
        pageCount is! int ||
        pageCount <= pageIndex ||
        pageCount > maximumPages ||
        response['complete'] != true ||
        count is! int ||
        count < 0 ||
        count >
            (operation == LinuxPdfExtractionOperation.text
                ? maximumGlyphs
                : maximumLinks) ||
        records is! List ||
        records.length != count) {
      throw const FormatException('extraction metadata');
    }
    for (final record in records) {
      if (operation == LinuxPdfExtractionOperation.text) {
        if (record is! List || record.length != 2)
          throw const FormatException('glyph');
        final scalar = record[0];
        if (scalar is! int ||
            scalar <= 0 ||
            scalar > 0x10ffff ||
            scalar >= 0xd800 && scalar <= 0xdfff)
          throw const FormatException('unicode scalar');
        if (record[1] != null) {
          extractionBounds(record[1], allowEmpty: true);
        } else if (!const {9, 10, 13, 32}.contains(scalar)) {
          throw const FormatException('unpositioned glyph');
        }
      } else {
        if (record is! Map<String, dynamic>)
          throw const FormatException('link');
        extractionBounds(record['bounds'], allowEmpty: false);
        if (record['kind'] == 'internal') {
          final destination = record['destination'];
          if (record.length != 3 ||
              destination is! int ||
              destination < 0 ||
              destination >= pageCount) {
            throw const FormatException('internal destination');
          }
        } else if (record['kind'] == 'http') {
          if (!allowHttp ||
              record.length != 3 ||
              !isSafePdfHttpMetadata(record['uri'])) {
            throw const FormatException('external metadata');
          }
        } else {
          throw const FormatException('link action');
        }
      }
    }
  }

  @override
  String toString() => 'LinuxPdfExtractionRequest(redacted)';
}

/// Reject numeric overflow before converting any untrusted coordinate.
List<double> extractionBounds(Object? value, {required bool allowEmpty}) {
  if (value is! List || value.length != 4)
    throw const FormatException('extraction bounds');
  for (final coordinate in value) {
    if (coordinate is! num ||
        !coordinate.isFinite ||
        coordinate.abs() > 1000000) {
      throw const FormatException('extraction coordinate');
    }
  }
  final bounds = value.cast<num>().map((v) => v.toDouble()).toList();
  if (bounds[0] > bounds[2] ||
      bounds[1] > bounds[3] ||
      !allowEmpty && (bounds[0] == bounds[2] || bounds[1] == bounds[3])) {
    throw const FormatException('extraction rectangle');
  }
  return bounds;
}

/// Classification only: no target escapes the adapter. This is not an activation
/// permission or a network capability. Invalid or ambiguous URIs fail closed.
bool isSafePdfHttpMetadata(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > linuxPdfExtractionUriBytes ||
      value.codeUnits.any((v) => v <= 32 || v == 127 || v == 92) ||
      RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(value) ||
      utf8.encode(value).length > linuxPdfExtractionUriBytes)
    return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.hasAuthority &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.host.contains('%');
}

final class LinuxPdfExtractionUnsupported implements Exception {
  const LinuxPdfExtractionUnsupported();
}

/// Runs in the parent operation isolate after wire validation and worker reap.
/// Uses the same authoritative mapper as rendering/Object coordinate contracts.
Object projectLinuxPdfExtraction({
  required Map<String, dynamic> response,
  required LinuxPdfExtractionRequest operation,
  required PdfPageReference reference,
  required PdfPageClip region,
  required PdfProcessingLimits limits,
  required CancellationToken token,
}) {
  final geometry = response['page'] as Map<String, dynamic>;
  final raw = geometry['bounds'] as List;
  final source = reference.sourceBox;
  if (raw[0] != source.left ||
      raw[1] != source.bottom ||
      raw[2] != source.right ||
      raw[3] != source.top ||
      geometry['width'] != reference.displayedWidth ||
      geometry['height'] != reference.displayedHeight ||
      geometry['rotation'] != reference.rotation.index * 90) {
    throw const FormatException('extraction reference mismatch');
  }
  final coordinates = PdfPageCoordinates(reference);
  final regionBounds = _value(coordinates.clipToLocalRect(region));
  Rect2? project(Object rawBounds, {required bool allowEmpty}) {
    final b = extractionBounds(rawBounds, allowEmpty: allowEmpty);
    final left = math.max(source.left, b[0]);
    final bottom = math.max(source.bottom, b[1]);
    final right = math.min(source.right, b[2]);
    final top = math.min(source.top, b[3]);
    if (right < left || top < bottom) return null;
    final local = _value(
      coordinates.sourceRectToLocal(
        _value(
          Rect2.fromEdges(left: left, top: bottom, right: right, bottom: top),
        ),
      ),
    );
    final x1 = math.max(local.left, regionBounds.left);
    final y1 = math.max(local.top, regionBounds.top);
    final x2 = math.min(local.right, regionBounds.right);
    final y2 = math.min(local.bottom, regionBounds.bottom);
    if (x2 < x1 || y2 < y1 || !allowEmpty && (x1 == x2 || y1 == y2))
      return null;
    return _value(Rect2.fromEdges(left: x1, top: y1, right: x2, bottom: y2));
  }

  final records = response['records'] as List;
  if (operation.operation == LinuxPdfExtractionOperation.text) {
    final glyphs = <PdfTextGlyph>[];
    for (var index = 0; index < records.length; index++) {
      if (token.isCancelled) throw const FormatException('cancelled');
      final record = records[index] as List;
      final box = record[1];
      if (box == null && region != PdfPageClip.full) {
        // A separator without geometry cannot be assigned honestly to a crop.
        throw const LinuxPdfExtractionUnsupported();
      }
      final bounds = box == null
          ? null
          : project(box as Object, allowEmpty: true);
      if (box != null && bounds == null) continue;
      glyphs.add(
        PdfTextGlyph(
          unicodeScalar: record[0] as int,
          sourceCharacterIndex: index,
          bounds: bounds,
        ),
      );
    }
    return _value(
      PdfExtractedText.captureGlyphs(
        glyphs: glyphs,
        limits: limits,
        cancellationToken: token,
      ),
    );
  }
  final links = <PdfSafeLinkMetadata>[];
  for (final rawLink in records) {
    if (token.isCancelled) throw const FormatException('cancelled');
    final link = rawLink as Map<String, dynamic>;
    final bounds = project(link['bounds'] as Object, allowEmpty: false);
    if (bounds == null) continue;
    links.add(
      _value(
        PdfSafeLinkMetadata.create(
          bounds: bounds,
          kind: link['kind'] == 'internal'
              ? PdfSafeLinkKind.internalPage
              : PdfSafeLinkKind.externalReference,
          destinationPageIndex: link['destination'] as int?,
          limits: limits,
        ),
      ),
    );
  }
  return _value(
    PdfSafeLinks.capture(
      links: links,
      limits: limits,
      cancellationToken: token,
    ),
  );
}

T _value<T>(Result<T, StructuredFailure> result) {
  if (result is Ok<T, StructuredFailure>) return result.value;
  throw const FormatException('extraction projection');
}
