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
  const FlutterTextLayoutEngine(
    this.limits, {
    this.painterFactory = const FlutterTextPainterFactory(),
  });

  /// Persistent and derived layout ceilings.
  final TextLimits limits;

  /// Shared Flutter-owned paragraph painter construction authority.
  final FlutterTextPainterFactory painterFactory;

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
      final paragraphLayouts = <TextParagraphLayout>[];
      final maximumWidth = math.max<double>(
        0,
        payload.intrinsicWidth - payload.padding.left - payload.padding.right,
      );
      final mappings = <List<_ScalarMapEntry>>[];
      var paintedHeight = 0.0;
      for (var index = 0; index < payload.paragraphs.length; index++) {
        final paragraph = payload.paragraphs[index];
        final mapping = _graphemeMapping(paragraph.logicalText, index, limits);
        if (mapping == null ||
            mapping.length > limits.maximumCaretStops - carets.length) {
          return Err(_failure('caret_limit'));
        }
        mappings.add(mapping);
        final painter = painterFactory.create(
          payload: payload,
          paragraph: paragraph,
          maximumWidth: maximumWidth,
          layerOpacity: 1,
        );
        painters.add(painter);
        final paragraphHeight = math.max(
          painter.height,
          painter.preferredLineHeight,
        );
        final nextHeight = paintedHeight + paragraphHeight;
        if (!paragraphHeight.isFinite ||
            paragraphHeight <= 0 ||
            !nextHeight.isFinite) {
          return Err(_failure('bounds_unavailable'));
        }
        paintedHeight = nextHeight;
      }
      final derivedHeight =
          payload.padding.top + paintedHeight + payload.padding.bottom;
      if (!derivedHeight.isFinite) return Err(_failure('bounds_unavailable'));
      final logicalHeight = payload.boxMode == TextBoxMode.fixedWidthFixedHeight
          ? payload.intrinsicHeight!
          : derivedHeight;
      final widestParagraph = painters.fold<double>(
        0,
        (width, painter) => math.max(width, painter.width),
      );
      final derivedWidth =
          payload.padding.left + widestParagraph + payload.padding.right;
      if (!derivedWidth.isFinite) return Err(_failure('bounds_unavailable'));
      final logicalWidth = payload.boxMode == TextBoxMode.autoSize
          ? derivedWidth
          : payload.intrinsicWidth;
      final logical = _rect(0, 0, logicalWidth, logicalHeight);
      if (logical == null) return Err(_failure('bounds_unavailable'));
      final availableHeight = math.max<double>(
        0,
        logicalHeight - payload.padding.top - payload.padding.bottom,
      );
      final alignmentSpace = math.max<double>(
        0,
        availableHeight - paintedHeight,
      );
      final alignmentOffset = switch (payload.verticalAlignment) {
        TextVerticalAlignment.top => 0.0,
        TextVerticalAlignment.center => alignmentSpace / 2,
        TextVerticalAlignment.bottom => alignmentSpace,
      };
      var paragraphTop = payload.padding.top + alignmentOffset;
      Rect2? paintedBounds;
      for (
        var paragraphIndex = 0;
        paragraphIndex < payload.paragraphs.length;
        paragraphIndex++
      ) {
        final paragraph = payload.paragraphs[paragraphIndex];
        final mapping = mappings[paragraphIndex];
        final painter = painters[paragraphIndex];
        final paragraphHeight = math.max(
          painter.height,
          painter.preferredLineHeight,
        );
        final origin = _point(payload.padding.left, paragraphTop);
        final paragraphBounds = _rect(
          payload.padding.left,
          paragraphTop,
          payload.padding.left + painter.width,
          paragraphTop + paragraphHeight,
        );
        if (origin == null || paragraphBounds == null) {
          return Err(_failure('bounds_unavailable'));
        }
        paragraphLayouts.add(
          TextParagraphLayout(
            paragraphIndex: paragraphIndex,
            origin: origin,
            bounds: paragraphBounds,
          ),
        );
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
          final rawBounds = _rect(
            metric.left + payload.padding.left,
            paragraphTop + metric.baseline - metric.ascent,
            metric.left + metric.width + payload.padding.left,
            paragraphTop + metric.baseline + metric.descent,
          );
          if (range is! Ok<TextRange, StructuredFailure> || rawBounds == null) {
            return Err(_failure('line_unavailable'));
          }
          final bounds = _visibleRect(rawBounds, logical, payload);
          if (bounds == null) continue;
          paintedBounds = _union(paintedBounds, bounds);
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
          final rawBounds = _rect(
            offset.dx + payload.padding.left,
            paragraphTop + offset.dy,
            offset.dx + payload.padding.left,
            paragraphTop + offset.dy + painter.preferredLineHeight,
          );
          if (rawBounds == null) return Err(_failure('caret_unavailable'));
          final bounds = _visibleRect(rawBounds, logical, payload);
          if (bounds == null) continue;
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
            final rawBounds = _rect(
              box.left + payload.padding.left,
              paragraphTop + box.top,
              box.right + payload.padding.left,
              paragraphTop + box.bottom,
            );
            if (rawBounds == null) return Err(_failure('range_unavailable'));
            final bounds = _visibleRect(rawBounds, logical, payload);
            if (bounds == null) continue;
            rangeGeometry.add(bounds);
          }
        }
        paragraphTop += paragraphHeight;
      }
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
        paragraphs: paragraphLayouts,
        lines: lines,
        caretStops: carets,
        rangeGeometry: rangeGeometry,
        fontDiagnostics: diagnostics,
        logicalBounds: logical,
        visualBounds: paintedBounds ?? logical,
        overflowed:
            payload.boxMode == TextBoxMode.fixedWidthFixedHeight &&
            derivedHeight > logicalHeight,
        limits: limits,
      );
    } on Object {
      return Err(_failure('layout_unavailable'));
    } finally {
      for (final painter in painters) {
        painterFactory.dispose(painter);
      }
    }
  }
}

/// One Flutter-owned authority for every geometry-affecting paragraph option.
class FlutterTextPainterFactory {
  /// Creates the stateless production factory.
  const FlutterTextPainterFactory({this.lifecycleObserver});

  /// Optional bounded test/diagnostic lifecycle accounting.
  final FlutterTextPainterLifecycleObserver? lifecycleObserver;

  /// Constructs and lays out one temporary paragraph painter.
  TextPainter create({
    required TextPayload payload,
    required TextParagraph paragraph,
    required double maximumWidth,
    required double layerOpacity,
  }) {
    if (!maximumWidth.isFinite ||
        maximumWidth < 0 ||
        !layerOpacity.isFinite ||
        layerOpacity < 0 ||
        layerOpacity > 1) {
      throw StateError('Invalid bounded TextPainter request.');
    }
    final painter = TextPainter(
      text: TextSpan(
        style: _style(
          payload.defaultCharacterStyle,
          lineHeight: paragraph.style.lineHeight,
          languageHint: paragraph.style.languageHint,
          layerOpacity: layerOpacity,
        ),
        children: [
          for (final run in paragraph.runs)
            TextSpan(
              text: run.text,
              style: _style(
                run.style,
                lineHeight: paragraph.style.lineHeight,
                languageHint: paragraph.style.languageHint,
                layerOpacity: layerOpacity,
              ),
            ),
        ],
      ),
      textDirection: _direction(paragraph),
      textAlign: _alignment(paragraph.style.alignment),
      locale: _locale(paragraph.style.languageHint),
      textWidthBasis: TextWidthBasis.longestLine,
    );
    try {
      _notifyCreated(painter);
      painter.layout(maxWidth: maximumWidth);
      return painter;
    } on Object {
      dispose(painter);
      rethrow;
    }
  }

  /// Disposes one factory-created painter exactly at its owning boundary.
  void dispose(TextPainter painter) {
    painter.dispose();
    try {
      lifecycleObserver?.disposed(painter);
    } on Object {
      // Diagnostic accounting cannot alter layout ownership.
    }
  }

  void _notifyCreated(TextPainter painter) {
    try {
      lifecycleObserver?.created(painter);
    } on Object {
      // Diagnostic accounting cannot alter layout ownership.
    }
  }
}

/// Flutter-only lifecycle evidence for temporary paragraph painters.
abstract interface class FlutterTextPainterLifecycleObserver {
  /// Records one newly constructed temporary painter.
  void created(TextPainter painter);

  /// Records one disposed temporary painter.
  void disposed(TextPainter painter);
}

typedef _ScalarMapEntry = ({TextPosition position, int utf16Offset});

Point2? _point(double x, double y) => Point2.create(
  x: x,
  y: y,
).fold<Point2?>(onOk: (value) => value, onErr: (_) => null);

Rect2? _visibleRect(Rect2 source, Rect2 logical, TextPayload payload) {
  if (payload.boxMode != TextBoxMode.fixedWidthFixedHeight ||
      payload.overflowPolicy == TextOverflowPolicy.visible) {
    return source;
  }
  final left = math.max(source.left, logical.left);
  final top = math.max(source.top, logical.top);
  final right = math.min(source.right, logical.right);
  final bottom = math.min(source.bottom, logical.bottom);
  if (right < left || bottom < top) return null;
  return _rect(left, top, right, bottom);
}

Rect2 _union(Rect2? first, Rect2 second) {
  if (first == null) return second;
  return _rect(
    math.min(first.left, second.left),
    math.min(first.top, second.top),
    math.max(first.right, second.right),
    math.max(first.bottom, second.bottom),
  )!;
}

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
  final language = parts.first;
  var index = 1;
  if (language.length <= 3) {
    var extlangCount = 0;
    while (index < parts.length &&
        extlangCount < 3 &&
        _asciiLetters(parts[index], 3)) {
      index += 1;
      extlangCount += 1;
    }
  }
  String? script;
  String? country;
  if (index < parts.length && _asciiLetters(parts[index], 4)) {
    script = parts[index];
    index += 1;
  }
  if (index < parts.length &&
      (_asciiLetters(parts[index], 2) || _asciiDigits(parts[index], 3))) {
    country = parts[index];
  }
  return Locale.fromSubtags(
    languageCode: language,
    scriptCode: script,
    countryCode: country,
  );
}

bool _asciiLetters(String value, int length) {
  if (value.length != length) return false;
  for (final unit in value.codeUnits) {
    if (!(unit >= 0x41 && unit <= 0x5a) && !(unit >= 0x61 && unit <= 0x7a)) {
      return false;
    }
  }
  return true;
}

bool _asciiDigits(String value, int length) {
  if (value.length != length) return false;
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
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
  required double layerOpacity,
}) => TextStyle(
  fontFamily: style.preferredFontFamily,
  fontFamilyFallback: [_genericFontFamily(style.genericFontFamily)],
  fontSize: style.fontSize,
  fontWeight: FontWeight.values[((style.weight / 100).round() - 1).clamp(0, 8)],
  fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
  decoration: TextDecoration.combine([
    if (style.underline) TextDecoration.underline,
    if (style.strikethrough) TextDecoration.lineThrough,
  ]),
  color: Color(
    style.argb,
  ).withValues(alpha: ((style.argb >>> 24 & 0xff) / 255) * layerOpacity),
  height: lineHeight,
  locale: _locale(languageHint),
);

String _genericFontFamily(TextGenericFontFamily family) => switch (family) {
  TextGenericFontFamily.sansSerif => 'sans-serif',
  TextGenericFontFamily.serif => 'serif',
  TextGenericFontFamily.monospace => 'monospace',
  TextGenericFontFamily.cursive => 'cursive',
  TextGenericFontFamily.fantasy => 'fantasy',
  TextGenericFontFamily.systemUi => 'system-ui',
};

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
