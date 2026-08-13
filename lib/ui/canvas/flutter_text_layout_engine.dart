// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;
import 'dart:ui' as ui show TextPosition;

import 'package:flutter/material.dart' hide TextPosition, TextRange;

import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../documents/objects/text.dart';

/// Flutter `TextPainter` adapter behind the portable AL NOTE layout contract.
final class FlutterTextLayoutEngine implements TextLayoutEngine {
  /// Creates an adapter with explicit output ceilings.
  const FlutterTextLayoutEngine(this.limits);

  /// Persistent and derived layout ceilings.
  final TextLimits limits;

  @override
  Result<TextLayoutSnapshot, StructuredFailure> layout(
    TextLayoutRequest request,
  ) {
    final painters = <TextPainter>[];
    try {
      final validated = TextPayload.decode(
        request.payload.encode(),
        limits: limits,
      );
      if (validated is! Ok<TextPayload, StructuredFailure> ||
          !_validRequestedRange(validated.value, request.range, limits)) {
        return Err(_failure('invalid_request'));
      }
      final payload = validated.value;
      final lines = <TextLayoutLine>[];
      final carets = <TextCaretStop>[];
      final rangeGeometry = <Rect2>[];
      final maximumWidth = math.max<double>(
        0,
        payload.intrinsicWidth - payload.padding.left - payload.padding.right,
      );
      var paragraphTop = payload.padding.top;
      for (
        var paragraphIndex = 0;
        paragraphIndex < payload.paragraphs.length;
        paragraphIndex++
      ) {
        final paragraph = payload.paragraphs[paragraphIndex];
        final mapping = _graphemeMapping(
          paragraph.logicalText,
          paragraphIndex,
          limits,
        );
        if (mapping == null ||
            mapping.length > limits.maximumCaretStops - carets.length) {
          return Err(_failure('caret_limit'));
        }
        final painter = TextPainter(
          text: TextSpan(
            children: [
              for (final run in paragraph.runs)
                TextSpan(
                  text: run.text,
                  style: _style(
                    run.style,
                    lineHeight: paragraph.style.lineHeight,
                    languageHint: paragraph.style.languageHint,
                  ),
                ),
            ],
          ),
          textDirection: _direction(paragraph),
          textAlign: _alignment(paragraph.style.alignment),
          locale: _locale(paragraph.style.languageHint),
        )..layout(maxWidth: maximumWidth);
        painters.add(painter);
        final metrics = painter.computeLineMetrics();
        if (metrics.length > limits.maximumLayoutLines - lines.length) {
          return Err(_failure('line_limit'));
        }
        var priorUtf16 = 0;
        for (final metric in metrics) {
          final boundary = painter.getLineBoundary(
            ui.TextPosition(offset: priorUtf16),
          );
          priorUtf16 = boundary.end;
          final start = _logicalPosition(mapping, boundary.start);
          final end = _logicalPosition(mapping, boundary.end);
          final range = start == null || end == null
              ? null
              : TextRange.create(start, end);
          final bounds = _rect(
            metric.left + payload.padding.left,
            paragraphTop + metric.baseline - metric.ascent,
            metric.left + metric.width + payload.padding.left,
            paragraphTop + metric.baseline + metric.descent,
          );
          if (range is! Ok<TextRange, StructuredFailure> || bounds == null) {
            return Err(_failure('line_unavailable'));
          }
          final line = TextLayoutLine.create(
            bounds: bounds,
            fragments: [
              TextLayoutFragment(
                range: range.value,
                logicalBounds: bounds,
                visualBounds: bounds,
              ),
            ],
            maximumFragments: limits.maximumLayoutFragments,
          );
          if (line is! Ok<TextLayoutLine, StructuredFailure>) {
            return Err(_failure('fragment_limit'));
          }
          lines.add(line.value);
        }
        for (final entry in mapping) {
          final offset = painter.getOffsetForCaret(
            ui.TextPosition(offset: entry.utf16Offset),
            Rect.zero,
          );
          final bounds = _rect(
            offset.dx + payload.padding.left,
            paragraphTop + offset.dy,
            offset.dx + payload.padding.left,
            paragraphTop + offset.dy + painter.preferredLineHeight,
          );
          if (bounds == null) return Err(_failure('caret_unavailable'));
          carets.add(TextCaretStop(position: entry.position, bounds: bounds));
        }
        final requestedRange = request.range;
        if (requestedRange != null &&
            paragraphIndex >= requestedRange.start.paragraphIndex &&
            paragraphIndex <= requestedRange.end.paragraphIndex) {
          final startScalar =
              paragraphIndex == requestedRange.start.paragraphIndex
              ? requestedRange.start.scalarOffset
              : 0;
          final endScalar = paragraphIndex == requestedRange.end.paragraphIndex
              ? requestedRange.end.scalarOffset
              : paragraph.scalarLength;
          final start = _utf16Offset(
            mapping,
            _position(paragraphIndex, startScalar),
          );
          final end = _utf16Offset(
            mapping,
            _position(paragraphIndex, endScalar),
          );
          if (start == null || end == null) {
            return Err(_failure('range_unavailable'));
          }
          final boxes = painter.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end),
          );
          if (boxes.length >
              limits.maximumRangeRectangles - rangeGeometry.length) {
            return Err(_failure('range_limit'));
          }
          for (final box in boxes) {
            final bounds = _rect(
              box.left + payload.padding.left,
              paragraphTop + box.top,
              box.right + payload.padding.left,
              paragraphTop + box.bottom,
            );
            if (bounds == null) return Err(_failure('range_unavailable'));
            rangeGeometry.add(bounds);
          }
        }
        paragraphTop += painter.height;
      }
      final derivedHeight = paragraphTop + payload.padding.bottom;
      final height = payload.intrinsicHeight ?? derivedHeight;
      final logical = _rect(0, 0, payload.intrinsicWidth, height);
      if (logical == null) return Err(_failure('bounds_unavailable'));
      final diagnostics = <TextFontSubstitutionDiagnostic>[];
      for (final family in _fontRequests(payload)) {
        final maximumDiagnostics = _boundedProduct(
          limits.maximumRunsPerParagraph,
          limits.maximumParagraphs,
        );
        if (diagnostics.length >= maximumDiagnostics) {
          return Err(_failure('diagnostic_limit'));
        }
        diagnostics.add(
          TextFontSubstitutionDiagnostic(requestSatisfied: family == null),
        );
      }
      return TextLayoutSnapshot.create(
        lines: lines,
        caretStops: carets,
        rangeGeometry: rangeGeometry,
        fontDiagnostics: diagnostics,
        logicalBounds: logical,
        visualBounds: logical,
        overflowed: payload.intrinsicHeight != null && derivedHeight > height,
        limits: limits,
      );
    } on Object {
      return Err(_failure('layout_unavailable'));
    } finally {
      for (final painter in painters) {
        painter.dispose();
      }
    }
  }
}

typedef _ScalarMapEntry = ({TextPosition position, int utf16Offset});

List<_ScalarMapEntry>? _graphemeMapping(
  String text,
  int paragraphIndex,
  TextLimits limits,
) {
  final boundaries = const TextGraphemeBoundaryService().boundaries(
    text,
    maximumScalars: limits.maximumTotalScalars,
  );
  if (boundaries is! Ok<List<int>, StructuredFailure>) return null;
  final wanted = boundaries.value.toSet();
  final result = <_ScalarMapEntry>[];
  var scalar = 0;
  var utf16 = 0;
  if (wanted.contains(0)) {
    result.add((position: _position(paragraphIndex, 0), utf16Offset: 0));
  }
  for (final rune in text.runes) {
    utf16 += rune > 0xffff ? 2 : 1;
    scalar += 1;
    if (wanted.contains(scalar)) {
      if (result.length >= limits.maximumCaretStops) return null;
      result.add((
        position: _position(paragraphIndex, scalar),
        utf16Offset: utf16,
      ));
    }
  }
  return List<_ScalarMapEntry>.unmodifiable(result);
}

bool _validRequestedRange(
  TextPayload payload,
  TextRange? range,
  TextLimits limits,
) {
  if (range == null) return true;
  if (range.start.paragraphIndex >= payload.paragraphs.length ||
      range.end.paragraphIndex >= payload.paragraphs.length) {
    return false;
  }
  for (final position in [range.start, range.end]) {
    final paragraph = payload.paragraphs[position.paragraphIndex];
    if (position.scalarOffset > paragraph.scalarLength) return false;
    final boundary = const TextGraphemeBoundaryService().isBoundary(
      paragraph.logicalText,
      position.scalarOffset,
      maximumScalars: limits.maximumTotalScalars,
    );
    if (boundary is! Ok<bool, StructuredFailure> || !boundary.value) {
      return false;
    }
  }
  return true;
}

TextPosition? _logicalPosition(List<_ScalarMapEntry> mapping, int utf16) {
  _ScalarMapEntry? prior;
  for (final entry in mapping) {
    if (entry.utf16Offset == utf16) return entry.position;
    if (entry.utf16Offset > utf16) return prior?.position;
    prior = entry;
  }
  return prior?.position;
}

int? _utf16Offset(List<_ScalarMapEntry> mapping, TextPosition position) {
  for (final entry in mapping) {
    if (entry.position == position) return entry.utf16Offset;
  }
  return null;
}

TextDirection _direction(TextParagraph paragraph) {
  if (paragraph.style.direction == TextParagraphDirection.rtl) {
    return TextDirection.rtl;
  }
  if (paragraph.style.direction == TextParagraphDirection.ltr) {
    return TextDirection.ltr;
  }
  for (final rune in paragraph.logicalText.runes) {
    if (rune >= 0x0590 && rune <= 0x08ff ||
        rune >= 0xfb1d && rune <= 0xfdff ||
        rune >= 0xfe70 && rune <= 0xfeff) {
      return TextDirection.rtl;
    }
    if (rune >= 0x0041 && rune <= 0x005a || rune >= 0x0061 && rune <= 0x007a) {
      return TextDirection.ltr;
    }
  }
  return TextDirection.ltr;
}

TextAlign _alignment(TextAlignment alignment) => switch (alignment) {
  TextAlignment.left => TextAlign.left,
  TextAlignment.center => TextAlign.center,
  TextAlignment.right => TextAlign.right,
  TextAlignment.justified => TextAlign.justify,
  TextAlignment.start => TextAlign.start,
  TextAlignment.end => TextAlign.end,
};

Locale? _locale(String? languageHint) {
  if (languageHint == null) return null;
  final parts = languageHint.split('-');
  if (parts.isEmpty) return null;
  String? script;
  String? country;
  for (final part in parts.skip(1)) {
    if (part.length == 4 && script == null) {
      script = part;
    } else if ((part.length == 2 || part.length == 3) && country == null) {
      country = part;
    }
  }
  return Locale.fromSubtags(
    languageCode: parts.first,
    scriptCode: script,
    countryCode: country,
  );
}

Iterable<String?> _fontRequests(TextPayload payload) sync* {
  yield payload.defaultCharacterStyle.preferredFontFamily;
  for (final paragraph in payload.paragraphs) {
    for (final run in paragraph.runs) {
      yield run.style.preferredFontFamily;
    }
  }
}

TextStyle _style(
  TextCharacterStyle style, {
  required double lineHeight,
  required String? languageHint,
}) => TextStyle(
  fontFamily: style.preferredFontFamily,
  fontSize: style.fontSize,
  fontWeight: FontWeight.values[((style.weight / 100).round() - 1).clamp(0, 8)],
  fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
  decoration: TextDecoration.combine([
    if (style.underline) TextDecoration.underline,
    if (style.strikethrough) TextDecoration.lineThrough,
  ]),
  color: Color(style.argb),
  height: lineHeight,
  locale: _locale(languageHint),
);

int _boundedProduct(int left, int right) {
  const maximumWebSafeInteger = 9007199254740991;
  if (left == 0 || right == 0) return 0;
  if (right > maximumWebSafeInteger ~/ left) return maximumWebSafeInteger;
  return left * right;
}

TextPosition _position(int paragraph, int scalar) =>
    (TextPosition.create(paragraphIndex: paragraph, scalarOffset: scalar)
            as Ok<TextPosition, StructuredFailure>)
        .value;

Rect2? _rect(double left, double top, double right, double bottom) =>
    Rect2.fromEdges(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'ui.text_layout.$leaf',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'Text layout is invalid or unavailable.',
);
