// SPDX-License-Identifier: GPL-3.0-or-later

import '../../../core/geometry/geometry_values.dart';
import '../../../core/identity/namespaced_identifier.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../../core/validation/validation_issue.dart';
import '../../../core/validation/validation_path.dart';
import '../../../core/validation/validation_report.dart';
import '../../../core/versioning/revision.dart';
import '../../../core/versioning/schema_version.dart';
import '../../model/identity_remapping.dart';
import '../../model/preserved_data.dart';
import '../../resources/resources.dart';
import '../object_envelope.dart';
import '../object_registry.dart';
import 'src/grapheme_adapter.dart';

/// Permanent built-in Text Object type key.
final ObjectTypeKey textObjectTypeKey = ObjectTypeKey.fromIdentifier(
  _trustedTypeIdentifier(),
);

/// Supported built-in Text payload schema.
final SchemaVersion textSchemaVersion = _schemaOne();

/// Generic fallback request stored without physical-font claims.
enum TextGenericFontFamily {
  sansSerif,
  serif,
  monospace,
  cursive,
  fantasy,
  systemUi,
}

/// Paragraph alignment request.
enum TextAlignment { left, center, right, justified, start, end }

/// Paragraph base-direction request.
enum TextParagraphDirection { automatic, ltr, rtl }

/// Persistent text-box sizing mode.
enum TextBoxMode { autoSize, fixedWidthAutoHeight, fixedWidthFixedHeight }

/// Text-box vertical alignment.
enum TextVerticalAlignment { top, center, bottom }

/// Fixed-height overflow behavior.
enum TextOverflowPolicy { clip, visible }

/// Explicit Text model, editing, clipboard, and layout limits.
final class TextLimits {
  const TextLimits._({
    required this.maximumParagraphs,
    required this.maximumRunsPerParagraph,
    required this.maximumScalarsPerRun,
    required this.maximumTotalScalars,
    required this.maximumFontFamilyScalars,
    required this.maximumLanguageHintScalars,
    required this.maximumUnknownFields,
    required this.maximumUnknownNodes,
    required this.maximumNestingDepth,
    required this.maximumUnknownStringCodeUnits,
    required this.maximumFontSize,
    required this.maximumBoxDimension,
    required this.maximumPadding,
    required this.maximumLayoutLines,
    required this.maximumLayoutFragments,
    required this.maximumCaretStops,
    required this.maximumRangeRectangles,
    required this.maximumPendingEdits,
  });

  /// Creates positive Web-safe and finite Text ceilings.
  static Result<TextLimits, StructuredFailure> create({
    required int maximumParagraphs,
    required int maximumRunsPerParagraph,
    required int maximumScalarsPerRun,
    required int maximumTotalScalars,
    required int maximumFontFamilyScalars,
    required int maximumLanguageHintScalars,
    required int maximumUnknownFields,
    required int maximumUnknownNodes,
    required int maximumNestingDepth,
    required int maximumUnknownStringCodeUnits,
    required double maximumFontSize,
    required double maximumBoxDimension,
    required double maximumPadding,
    required int maximumLayoutLines,
    required int maximumLayoutFragments,
    required int maximumCaretStops,
    required int maximumRangeRectangles,
    required int maximumPendingEdits,
  }) {
    final counts = <int>[
      maximumParagraphs,
      maximumRunsPerParagraph,
      maximumScalarsPerRun,
      maximumTotalScalars,
      maximumFontFamilyScalars,
      maximumLanguageHintScalars,
      maximumUnknownFields,
      maximumUnknownNodes,
      maximumNestingDepth,
      maximumUnknownStringCodeUnits,
      maximumLayoutLines,
      maximumLayoutFragments,
      maximumCaretStops,
      maximumRangeRectangles,
      maximumPendingEdits,
    ];
    if (counts.any((value) => value < 0 || value > maximumWebSafeInteger) ||
        maximumParagraphs == 0 ||
        maximumRunsPerParagraph == 0 ||
        maximumTotalScalars == 0 ||
        maximumUnknownNodes == 0 ||
        maximumNestingDepth == 0 ||
        maximumUnknownStringCodeUnits == 0 ||
        maximumLayoutLines == 0 ||
        maximumLayoutFragments == 0 ||
        maximumCaretStops == 0 ||
        !_positive(maximumFontSize) ||
        !_positive(maximumBoxDimension) ||
        !_nonnegative(maximumPadding)) {
      return Err(_failure('invalid_limits'));
    }
    return Ok(
      TextLimits._(
        maximumParagraphs: maximumParagraphs,
        maximumRunsPerParagraph: maximumRunsPerParagraph,
        maximumScalarsPerRun: maximumScalarsPerRun,
        maximumTotalScalars: maximumTotalScalars,
        maximumFontFamilyScalars: maximumFontFamilyScalars,
        maximumLanguageHintScalars: maximumLanguageHintScalars,
        maximumUnknownFields: maximumUnknownFields,
        maximumUnknownNodes: maximumUnknownNodes,
        maximumNestingDepth: maximumNestingDepth,
        maximumUnknownStringCodeUnits: maximumUnknownStringCodeUnits,
        maximumFontSize: maximumFontSize,
        maximumBoxDimension: maximumBoxDimension,
        maximumPadding: maximumPadding,
        maximumLayoutLines: maximumLayoutLines,
        maximumLayoutFragments: maximumLayoutFragments,
        maximumCaretStops: maximumCaretStops,
        maximumRangeRectangles: maximumRangeRectangles,
        maximumPendingEdits: maximumPendingEdits,
      ),
    );
  }

  /// Maximum paragraphs.
  final int maximumParagraphs;

  /// Maximum runs in one paragraph.
  final int maximumRunsPerParagraph;

  /// Maximum Unicode scalars in one run.
  final int maximumScalarsPerRun;

  /// Maximum Unicode scalars in the complete payload.
  final int maximumTotalScalars;

  /// Maximum font request scalars.
  final int maximumFontFamilyScalars;

  /// Maximum BCP 47 hint scalars.
  final int maximumLanguageHintScalars;

  /// Maximum unknown fields at one boundary.
  final int maximumUnknownFields;

  /// Maximum unknown graph nodes.
  final int maximumUnknownNodes;

  /// Maximum unknown graph depth.
  final int maximumNestingDepth;

  /// Maximum cumulative UTF-16 code units in unknown keys and strings.
  final int maximumUnknownStringCodeUnits;

  /// Maximum positive font size.
  final double maximumFontSize;

  /// Maximum text-box dimension.
  final double maximumBoxDimension;

  /// Maximum padding edge.
  final double maximumPadding;

  /// Maximum layout lines returned by an adapter.
  final int maximumLayoutLines;

  /// Maximum layout fragments returned by an adapter.
  final int maximumLayoutFragments;

  /// Maximum caret stops returned by an adapter.
  final int maximumCaretStops;

  /// Maximum range rectangles returned by an adapter.
  final int maximumRangeRectangles;

  /// Maximum draft edits retained before a flush barrier.
  final int maximumPendingEdits;
}

/// Immutable persistent character style request.
final class TextCharacterStyle {
  const TextCharacterStyle._({
    required this.preferredFontFamily,
    required this.genericFontFamily,
    required this.fontSize,
    required this.weight,
    required this.italic,
    required this.underline,
    required this.strikethrough,
    required this.argb,
    required this.unknownFields,
  });

  /// Creates a validated character style.
  static Result<TextCharacterStyle, StructuredFailure> create({
    required TextGenericFontFamily genericFontFamily,
    required double fontSize,
    required int weight,
    required bool italic,
    required bool underline,
    required bool strikethrough,
    required int argb,
    required TextLimits limits,
    String? preferredFontFamily,
    PreservedMap? unknownFields,
  }) {
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_positive(fontSize) ||
        fontSize > limits.maximumFontSize ||
        weight < 1 ||
        weight > 1000 ||
        argb < 0 ||
        argb > 0xffffffff ||
        (preferredFontFamily != null &&
            (_containsUnpairedSurrogate(preferredFontFamily) ||
                preferredFontFamily.runes.length >
                    limits.maximumFontFamilyScalars ||
                preferredFontFamily.trim().isEmpty)) ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_character_style'));
    }
    return Ok(
      TextCharacterStyle._(
        preferredFontFamily: preferredFontFamily,
        genericFontFamily: genericFontFamily,
        fontSize: fontSize,
        weight: weight,
        italic: italic,
        underline: underline,
        strikethrough: strikethrough,
        argb: argb,
        unknownFields: unknown,
      ),
    );
  }

  /// Preferred logical font-family request, if any.
  final String? preferredFontFamily;

  /// Required generic fallback category.
  final TextGenericFontFamily genericFontFamily;

  /// Positive font size.
  final double fontSize;

  /// Numeric weight from 1 through 1000.
  final int weight;

  /// Italic request.
  final bool italic;

  /// Underline request.
  final bool underline;

  /// Strikethrough request.
  final bool strikethrough;

  /// Packed ARGB text color.
  final int argb;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;
}

/// Immutable persistent paragraph style.
final class TextParagraphStyle {
  const TextParagraphStyle._({
    required this.alignment,
    required this.direction,
    required this.lineHeight,
    required this.languageHint,
    required this.unknownFields,
  });

  /// Creates a validated paragraph style.
  static Result<TextParagraphStyle, StructuredFailure> create({
    required TextAlignment alignment,
    required TextParagraphDirection direction,
    required double lineHeight,
    required TextLimits limits,
    String? languageHint,
    PreservedMap? unknownFields,
  }) {
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_positive(lineHeight) ||
        (languageHint != null &&
            (_containsUnpairedSurrogate(languageHint) ||
                languageHint.runes.length > limits.maximumLanguageHintScalars ||
                !_bcp47.hasMatch(languageHint))) ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_paragraph_style'));
    }
    return Ok(
      TextParagraphStyle._(
        alignment: alignment,
        direction: direction,
        lineHeight: lineHeight,
        languageHint: languageHint,
        unknownFields: unknown,
      ),
    );
  }

  /// Logical alignment.
  final TextAlignment alignment;

  /// Base-direction request.
  final TextParagraphDirection direction;

  /// Positive line-height multiplier.
  final double lineHeight;

  /// Optional bounded BCP 47 language hint.
  final String? languageHint;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;
}

/// Immutable four-edge text-box padding.
final class TextPadding {
  const TextPadding._(this.left, this.top, this.right, this.bottom);

  /// Creates finite nonnegative bounded padding.
  static Result<TextPadding, StructuredFailure> create({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required TextLimits limits,
  }) {
    final values = <double>[left, top, right, bottom];
    if (values.any(
      (value) => !_nonnegative(value) || value > limits.maximumPadding,
    )) {
      return Err(_failure('invalid_padding'));
    }
    return Ok(TextPadding._(left, top, right, bottom));
  }

  /// Left edge.
  final double left;

  /// Top edge.
  final double top;

  /// Right edge.
  final double right;

  /// Bottom edge.
  final double bottom;
}

/// One immutable logical Unicode styled run.
final class TextRun {
  const TextRun._(this.text, this.style, this.unknownFields);

  /// Creates a run without changing Unicode normalization.
  static Result<TextRun, StructuredFailure> create({
    required String text,
    required TextCharacterStyle style,
    required TextLimits limits,
    PreservedMap? unknownFields,
  }) {
    final unknown = unknownFields ?? PreservedMap.empty();
    final validatedStyle = _revalidateCharacterStyle(style, limits);
    if (validatedStyle is! Ok<TextCharacterStyle, StructuredFailure> ||
        text.runes.length > limits.maximumScalarsPerRun ||
        _containsUnpairedSurrogate(text) ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_run'));
    }
    return Ok(TextRun._(text, validatedStyle.value, unknown));
  }

  /// Original logical Unicode text, with normalization preserved.
  final String text;

  /// Character style request.
  final TextCharacterStyle style;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;

  /// Number of Unicode scalar values.
  int get scalarLength => text.runes.length;
}

/// One ordered paragraph with an explicit boundary.
final class TextParagraph {
  TextParagraph._(List<TextRun> runs, this.style, this.unknownFields)
    : runs = List<TextRun>.unmodifiable(runs);

  /// Safely captures a paragraph; an empty run list represents an empty paragraph.
  static Result<TextParagraph, StructuredFailure> create({
    required Iterable<TextRun> runs,
    required TextParagraphStyle style,
    required TextLimits limits,
    PreservedMap? unknownFields,
  }) {
    final captured = _capture(
      runs,
      limits.maximumRunsPerParagraph,
      'run_limit',
    );
    if (captured is Err<List<TextRun>, StructuredFailure>) {
      return Err(captured.error);
    }
    final values = (captured as Ok<List<TextRun>, StructuredFailure>).value;
    final unknown = unknownFields ?? PreservedMap.empty();
    final validatedStyle = _revalidateParagraphStyle(style, limits);
    final validatedRuns = <TextRun>[];
    for (final run in values) {
      final validated = TextRun.create(
        text: run.text,
        style: run.style,
        limits: limits,
        unknownFields: run.unknownFields,
      );
      if (validated is! Ok<TextRun, StructuredFailure>) {
        return Err(_failure('invalid_paragraph'));
      }
      validatedRuns.add(validated.value);
    }
    if (validatedStyle is! Ok<TextParagraphStyle, StructuredFailure> ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_paragraph'));
    }
    return Ok(TextParagraph._(validatedRuns, validatedStyle.value, unknown));
  }

  /// Ordered styled runs.
  final List<TextRun> runs;

  /// Paragraph style.
  final TextParagraphStyle style;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;

  /// Logical text without a synthetic paragraph separator.
  String get logicalText => runs.map((run) => run.text).join();

  /// Unicode scalar count.
  int get scalarLength => runs.fold(0, (sum, run) => sum + run.scalarLength);
}

/// Immutable schema-1 Text Object payload.
final class TextPayload {
  TextPayload._({
    required List<TextParagraph> paragraphs,
    required this.defaultCharacterStyle,
    required this.defaultParagraphStyle,
    required this.boxMode,
    required this.intrinsicWidth,
    required this.intrinsicHeight,
    required this.padding,
    required this.verticalAlignment,
    required this.overflowPolicy,
    required this.unknownFields,
  }) : paragraphs = List<TextParagraph>.unmodifiable(paragraphs);

  /// Safely creates a persistent Text payload.
  static Result<TextPayload, StructuredFailure> create({
    required Iterable<TextParagraph> paragraphs,
    required TextCharacterStyle defaultCharacterStyle,
    required TextParagraphStyle defaultParagraphStyle,
    required TextBoxMode boxMode,
    required double intrinsicWidth,
    required double? intrinsicHeight,
    required TextPadding padding,
    required TextVerticalAlignment verticalAlignment,
    required TextOverflowPolicy overflowPolicy,
    required TextLimits limits,
    PreservedMap? unknownFields,
  }) {
    final captured = _capture(
      paragraphs,
      limits.maximumParagraphs,
      'paragraph_limit',
    );
    if (captured is Err<List<TextParagraph>, StructuredFailure>) {
      return Err(captured.error);
    }
    final values =
        (captured as Ok<List<TextParagraph>, StructuredFailure>).value;
    final validatedDefaultCharacter = _revalidateCharacterStyle(
      defaultCharacterStyle,
      limits,
    );
    final validatedDefaultParagraph = _revalidateParagraphStyle(
      defaultParagraphStyle,
      limits,
    );
    final validatedPadding = TextPadding.create(
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
      limits: limits,
    );
    if (validatedDefaultCharacter
            is! Ok<TextCharacterStyle, StructuredFailure> ||
        validatedDefaultParagraph
            is! Ok<TextParagraphStyle, StructuredFailure> ||
        validatedPadding is! Ok<TextPadding, StructuredFailure>) {
      return Err(_failure('invalid_payload'));
    }
    final validatedParagraphs = <TextParagraph>[];
    var total = 0;
    for (final paragraph in values) {
      final validated = TextParagraph.create(
        runs: paragraph.runs,
        style: paragraph.style,
        limits: limits,
        unknownFields: paragraph.unknownFields,
      );
      if (validated is! Ok<TextParagraph, StructuredFailure> ||
          total > limits.maximumTotalScalars - validated.value.scalarLength) {
        return Err(_failure('text_limit'));
      }
      total += validated.value.scalarLength;
      validatedParagraphs.add(validated.value);
    }
    final unknown = unknownFields ?? PreservedMap.empty();
    final heightRequired = boxMode == TextBoxMode.fixedWidthFixedHeight;
    if (values.isEmpty ||
        !_positive(intrinsicWidth) ||
        intrinsicWidth > limits.maximumBoxDimension ||
        (heightRequired && intrinsicHeight == null) ||
        (intrinsicHeight != null &&
            (!_positive(intrinsicHeight) ||
                intrinsicHeight > limits.maximumBoxDimension)) ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_payload'));
    }
    return Ok(
      TextPayload._(
        paragraphs: validatedParagraphs,
        defaultCharacterStyle: validatedDefaultCharacter.value,
        defaultParagraphStyle: validatedDefaultParagraph.value,
        boxMode: boxMode,
        intrinsicWidth: intrinsicWidth,
        intrinsicHeight: intrinsicHeight,
        padding: validatedPadding.value,
        verticalAlignment: verticalAlignment,
        overflowPolicy: overflowPolicy,
        unknownFields: unknown,
      ),
    );
  }

  /// Ordered paragraphs with explicit boundaries.
  final List<TextParagraph> paragraphs;

  /// Default character style.
  final TextCharacterStyle defaultCharacterStyle;

  /// Default paragraph style.
  final TextParagraphStyle defaultParagraphStyle;

  /// Text-box sizing mode.
  final TextBoxMode boxMode;

  /// Positive intrinsic or fixed width.
  final double intrinsicWidth;

  /// Optional fixed height.
  final double? intrinsicHeight;

  /// Box padding.
  final TextPadding padding;

  /// Vertical alignment.
  final TextVerticalAlignment verticalAlignment;

  /// Overflow policy.
  final TextOverflowPolicy overflowPolicy;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;

  /// Bounded logical projection for future Search and accessibility.
  String get logicalText =>
      paragraphs.map((paragraph) => paragraph.logicalText).join('\n');

  /// Conservative local text-box bounds; adapters derive exact auto height.
  Rect2 get bounds => _rect(
    0,
    0,
    intrinsicWidth,
    intrinsicHeight ??
        padding.top +
            padding.bottom +
            paragraphs.length *
                defaultCharacterStyle.fontSize *
                defaultParagraphStyle.lineHeight,
  );

  /// Encodes deterministically and preserves original Unicode exactly.
  PreservedMap encode() => PreservedMap(<String, PreservedData>{
    ...unknownFields.values,
    'paragraphs': PreservedList(paragraphs.map(_encodeParagraph)),
    'defaultCharacterStyle': _encodeCharacterStyle(defaultCharacterStyle),
    'defaultParagraphStyle': _encodeParagraphStyle(defaultParagraphStyle),
    'boxMode': PreservedString(boxMode.name),
    'intrinsicWidth': _double(intrinsicWidth),
    if (intrinsicHeight != null) 'intrinsicHeight': _double(intrinsicHeight!),
    'padding': _encodePadding(padding),
    'verticalAlignment': PreservedString(verticalAlignment.name),
    'overflowPolicy': PreservedString(overflowPolicy.name),
  });

  /// Decodes schema-1 preserved Text data.
  static Result<TextPayload, StructuredFailure> decode(
    PreservedData data, {
    required TextLimits limits,
  }) {
    if (data is! PreservedMap) return Err(_failure('invalid_payload'));
    final paragraphsData = data.values['paragraphs'];
    final defaultCharacter = _decodeCharacterStyle(
      data.values['defaultCharacterStyle'],
      limits,
    );
    final defaultParagraph = _decodeParagraphStyle(
      data.values['defaultParagraphStyle'],
      limits,
    );
    final boxMode = _enumByName(TextBoxMode.values, data.values['boxMode']);
    final width = _number(data.values['intrinsicWidth']);
    final height = data.values.containsKey('intrinsicHeight')
        ? _number(data.values['intrinsicHeight']) ?? double.nan
        : null;
    final padding = _decodePadding(data.values['padding'], limits);
    final vertical = _enumByName(
      TextVerticalAlignment.values,
      data.values['verticalAlignment'],
    );
    final overflow = _enumByName(
      TextOverflowPolicy.values,
      data.values['overflowPolicy'],
    );
    if (paragraphsData is! PreservedList ||
        paragraphsData.values.length > limits.maximumParagraphs ||
        defaultCharacter is! Ok<TextCharacterStyle, StructuredFailure> ||
        defaultParagraph is! Ok<TextParagraphStyle, StructuredFailure> ||
        boxMode == null ||
        width == null ||
        padding == null ||
        vertical == null ||
        overflow == null) {
      return Err(_failure('invalid_payload'));
    }
    final paragraphs = <TextParagraph>[];
    for (final value in paragraphsData.values) {
      final decoded = _decodeParagraph(value, limits);
      if (decoded is! Ok<TextParagraph, StructuredFailure>)
        return Err(_failure('invalid_payload'));
      paragraphs.add(decoded.value);
    }
    return create(
      paragraphs: paragraphs,
      defaultCharacterStyle: defaultCharacter.value,
      defaultParagraphStyle: defaultParagraph.value,
      boxMode: boxMode,
      intrinsicWidth: width,
      intrinsicHeight: height,
      padding: padding,
      verticalAlignment: vertical,
      overflowPolicy: overflow,
      limits: limits,
      unknownFields: _unknown(data, const {
        'paragraphs',
        'defaultCharacterStyle',
        'defaultParagraphStyle',
        'boxMode',
        'intrinsicWidth',
        'intrinsicHeight',
        'padding',
        'verticalAlignment',
        'overflowPolicy',
      }),
    );
  }
}

/// Built-in Registry definition for `alnote.text` schema 1.
final class TextObjectTypeDefinition
    implements ObjectTypeDefinition, ObjectPayloadChangeClassifier {
  /// Creates a definition with explicit Text limits.
  const TextObjectTypeDefinition(this.limits);

  /// Text validation ceilings.
  final TextLimits limits;
  @override
  ObjectTypeKey get typeKey => textObjectTypeKey;
  @override
  List<SchemaVersion> get supportedSchemaVersions =>
      List<SchemaVersion>.unmodifiable([textSchemaVersion]);
  @override
  ObjectTypeCapabilities get capabilities => const ObjectTypeCapabilities(
    hasIntrinsicGeometry: true,
    discoversResourceReferences: false,
    supportsScopedDuplication: true,
    selectable: true,
    movable: true,
    resizable: true,
    rotatable: true,
  );
  @override
  List<ObjectPayloadMigrationContract> get migrations => const [];
  @override
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) =>
      schemaVersion == textSchemaVersion &&
          TextPayload.decode(payload, limits: limits) is Ok
      ? ValidationReport(const [])
      : ValidationReport([_invalidIssue()]);
  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => schemaVersion != textSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : TextPayload.decode(
          payload,
          limits: limits,
        ).map((value) => value.bounds);
  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => schemaVersion != textSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : TextPayload.decode(
          payload,
          limits: limits,
        ).map((_) => List<ResourceReference>.unmodifiable(const []));
  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => schemaVersion != textSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : TextPayload.decode(
          payload,
          limits: limits,
        ).map((value) => value.encode());
  @override
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != textSchemaVersion)
      return Err(_failure('unsupported_schema'));
    final a = TextPayload.decode(before, limits: limits);
    final b = TextPayload.decode(after, limits: limits);
    if (a is! Ok<TextPayload, StructuredFailure> ||
        b is! Ok<TextPayload, StructuredFailure>) {
      return Err(_failure('invalid_payload'));
    }
    return Ok(
      ObjectPayloadChangeSemantics(
        geometry:
            a.value.boxMode != b.value.boxMode ||
            a.value.intrinsicWidth != b.value.intrinsicWidth ||
            a.value.intrinsicHeight != b.value.intrinsicHeight ||
            _encodePadding(a.value.padding) != _encodePadding(b.value.padding),
        appearance:
            _appearanceProjection(a.value) != _appearanceProjection(b.value),
        text: a.value.logicalText != b.value.logicalText,
        metadata: a.value.unknownFields != b.value.unknownFields,
      ),
    );
  }
}

/// Persistent position using paragraph and Unicode-scalar boundaries only.
final class TextPosition implements Comparable<TextPosition> {
  /// Creates a nonnegative Web-safe logical position.
  static Result<TextPosition, StructuredFailure> create({
    required int paragraphIndex,
    required int scalarOffset,
  }) {
    if (paragraphIndex < 0 ||
        scalarOffset < 0 ||
        paragraphIndex > maximumWebSafeInteger ||
        scalarOffset > maximumWebSafeInteger) {
      return Err(_failure('invalid_position'));
    }
    return Ok(TextPosition._(paragraphIndex, scalarOffset));
  }

  // ignore: sort_constructors_first
  const TextPosition._(this.paragraphIndex, this.scalarOffset);

  /// Zero-based paragraph index.
  final int paragraphIndex;

  /// Unicode-scalar boundary within the paragraph.
  final int scalarOffset;
  @override
  int compareTo(TextPosition other) => paragraphIndex == other.paragraphIndex
      ? scalarOffset.compareTo(other.scalarOffset)
      : paragraphIndex.compareTo(other.paragraphIndex);
  @override
  bool operator ==(Object other) =>
      other is TextPosition &&
      other.paragraphIndex == paragraphIndex &&
      other.scalarOffset == scalarOffset;
  @override
  int get hashCode => Object.hash(paragraphIndex, scalarOffset);
}

/// Immutable normalized logical Text range.
final class TextRange {
  /// Creates a range whose start does not follow its end.
  static Result<TextRange, StructuredFailure> create(
    TextPosition start,
    TextPosition end,
  ) => start.compareTo(end) > 0
      ? Err(_failure('invalid_range'))
      : Ok(TextRange._(start, end));
  // ignore: sort_constructors_first
  const TextRange._(this.start, this.end);

  /// Inclusive start boundary.
  final TextPosition start;

  /// Exclusive end boundary.
  final TextPosition end;

  /// Whether the range is a caret.
  bool get isCollapsed => start == end;
}

/// AL NOTE-owned grapheme boundary service; package types remain private.
final class TextGraphemeBoundaryService {
  /// Creates a stateless service.
  const TextGraphemeBoundaryService();

  /// Returns immutable Unicode-scalar grapheme boundaries under a caller ceiling.
  Result<List<int>, StructuredFailure> boundaries(
    String text, {
    required int maximumScalars,
  }) {
    if (_containsUnpairedSurrogate(text)) {
      return Err(_failure('invalid_unicode'));
    }
    try {
      return Ok(graphemeScalarBoundaries(text, maximumScalars));
    } on Object {
      return Err(_failure('grapheme_unavailable'));
    }
  }

  /// Whether [scalarOffset] is a valid extended-grapheme boundary.
  Result<bool, StructuredFailure> isBoundary(
    String text,
    int scalarOffset, {
    required int maximumScalars,
  }) => boundaries(
    text,
    maximumScalars: maximumScalars,
  ).map((values) => values.contains(scalarOffset));

  /// Replaces a grapheme-aligned Unicode-scalar range without normalization.
  Result<String, StructuredFailure> replace({
    required String text,
    required int startScalar,
    required int endScalar,
    required String replacement,
    required int maximumScalars,
  }) {
    if (_containsUnpairedSurrogate(replacement)) {
      return Err(_failure('invalid_unicode'));
    }
    final originalBoundaries = boundaries(text, maximumScalars: maximumScalars);
    if (originalBoundaries is! Ok<List<int>, StructuredFailure> ||
        startScalar < 0 ||
        endScalar < startScalar ||
        !originalBoundaries.value.contains(startScalar) ||
        !originalBoundaries.value.contains(endScalar)) {
      return Err(_failure('invalid_grapheme_range'));
    }
    final replacementRunes = replacement.runes.toList(growable: false);
    final originalRunes = text.runes.toList(growable: false);
    final retained = originalRunes.length - (endScalar - startScalar);
    if (replacementRunes.length > maximumScalars - retained) {
      return Err(_failure('text_limit'));
    }
    return Ok(
      String.fromCharCodes([
        ...originalRunes.take(startScalar),
        ...replacementRunes,
        ...originalRunes.skip(endScalar),
      ]),
    );
  }
}

/// Immutable caret stop returned by a portable layout adapter.
final class TextCaretStop {
  /// Creates a caret stop.
  const TextCaretStop({required this.position, required this.bounds});

  /// Logical scalar position.
  final TextPosition position;

  /// Local caret geometry.
  final Rect2 bounds;
}

/// Immutable laid-out Text fragment.
final class TextLayoutFragment {
  /// Creates a fragment without glyph or UTF-16 persistence.
  const TextLayoutFragment({
    required this.range,
    required this.logicalBounds,
    required this.visualBounds,
  });

  /// Logical text range.
  final TextRange range;

  /// Local logical bounds.
  final Rect2 logicalBounds;

  /// Local visual bounds.
  final Rect2 visualBounds;
}

/// Immutable laid-out Text line.
final class TextLayoutLine {
  TextLayoutLine._({
    required this.bounds,
    required List<TextLayoutFragment> fragments,
  }) : fragments = List<TextLayoutFragment>.unmodifiable(fragments);

  /// Incrementally captures one line under an explicit fragment ceiling.
  static Result<TextLayoutLine, StructuredFailure> create({
    required Rect2 bounds,
    required Iterable<TextLayoutFragment> fragments,
    required int maximumFragments,
  }) {
    final captured = _capture(
      fragments,
      maximumFragments,
      'layout_fragment_limit',
    );
    if (captured is! Ok<List<TextLayoutFragment>, StructuredFailure>) {
      return Err(_failure('invalid_layout_line'));
    }
    return Ok(TextLayoutLine._(bounds: bounds, fragments: captured.value));
  }

  /// Local line bounds.
  final Rect2 bounds;

  /// Ordered visual fragments.
  final List<TextLayoutFragment> fragments;
}

/// Redaction-safe physical-font substitution evidence.
final class TextFontSubstitutionDiagnostic {
  /// Creates evidence without exposing user font names.
  const TextFontSubstitutionDiagnostic({required this.requestSatisfied});

  /// Whether the adapter proved the request was satisfied.
  final bool requestSatisfied;
}

/// Immutable bounded portable layout output.
final class TextLayoutSnapshot {
  TextLayoutSnapshot._({
    required List<TextLayoutLine> lines,
    required List<TextCaretStop> caretStops,
    required List<Rect2> rangeGeometry,
    required List<TextFontSubstitutionDiagnostic> fontDiagnostics,
    required this.logicalBounds,
    required this.visualBounds,
    required this.overflowed,
  }) : lines = List.unmodifiable(lines),
       caretStops = List.unmodifiable(caretStops),
       rangeGeometry = List.unmodifiable(rangeGeometry),
       fontDiagnostics = List.unmodifiable(fontDiagnostics);

  /// Safely captures bounded layout output.
  static Result<TextLayoutSnapshot, StructuredFailure> create({
    required Iterable<TextLayoutLine> lines,
    required Iterable<TextCaretStop> caretStops,
    required Iterable<Rect2> rangeGeometry,
    required Iterable<TextFontSubstitutionDiagnostic> fontDiagnostics,
    required Rect2 logicalBounds,
    required Rect2 visualBounds,
    required bool overflowed,
    required TextLimits limits,
  }) {
    final lineValues = _capture(
      lines,
      limits.maximumLayoutLines,
      'layout_line_limit',
    );
    final caretValues = _capture(
      caretStops,
      limits.maximumCaretStops,
      'caret_limit',
    );
    final rangeValues = _capture(
      rangeGeometry,
      limits.maximumRangeRectangles,
      'range_geometry_limit',
    );
    final diagnosticValues = _capture(
      fontDiagnostics,
      _boundedProduct(limits.maximumRunsPerParagraph, limits.maximumParagraphs),
      'diagnostic_limit',
    );
    if (lineValues is! Ok<List<TextLayoutLine>, StructuredFailure> ||
        caretValues is! Ok<List<TextCaretStop>, StructuredFailure> ||
        rangeValues is! Ok<List<Rect2>, StructuredFailure> ||
        diagnosticValues
            is! Ok<List<TextFontSubstitutionDiagnostic>, StructuredFailure> ||
        !_fragmentTotalWithinLimit(
          lineValues.value,
          limits.maximumLayoutFragments,
        )) {
      return Err(_failure('invalid_layout'));
    }
    return Ok(
      TextLayoutSnapshot._(
        lines: lineValues.value,
        caretStops: caretValues.value,
        rangeGeometry: rangeValues.value,
        fontDiagnostics: diagnosticValues.value,
        logicalBounds: logicalBounds,
        visualBounds: visualBounds,
        overflowed: overflowed,
      ),
    );
  }

  /// Ordered visual lines.
  final List<TextLayoutLine> lines;

  /// Logical caret stops.
  final List<TextCaretStop> caretStops;

  /// Requested range geometry.
  final List<Rect2> rangeGeometry;

  /// Redaction-safe font substitution evidence.
  final List<TextFontSubstitutionDiagnostic> fontDiagnostics;

  /// Complete logical bounds.
  final Rect2 logicalBounds;

  /// Complete painted bounds.
  final Rect2 visualBounds;

  /// Whether fixed bounds overflowed.
  final bool overflowed;

  /// Maps a local point to the nearest logical scalar position.
  TextPosition? positionForPoint(Point2 point) {
    if (caretStops.isEmpty) return null;
    TextCaretStop best = caretStops.first;
    var distance = _distanceSquared(point, best.bounds);
    for (final stop in caretStops.skip(1)) {
      final next = _distanceSquared(point, stop.bounds);
      if (next < distance) {
        best = stop;
        distance = next;
      }
    }
    return best.position;
  }
}

bool _fragmentTotalWithinLimit(List<TextLayoutLine> lines, int maximum) {
  var total = 0;
  for (final line in lines) {
    final count = line.fragments.length;
    if (count > maximum - total) return false;
    total += count;
  }
  return true;
}

int _boundedProduct(int left, int right) {
  if (left == 0 || right == 0) return 0;
  if (right > maximumWebSafeInteger ~/ left) return maximumWebSafeInteger;
  return left * right;
}

/// Portable engine-independent Text layout request.
final class TextLayoutRequest {
  /// Creates a layout request.
  const TextLayoutRequest({required this.payload, this.range});

  /// Validated Text payload.
  final TextPayload payload;

  /// Optional range for which geometry is requested.
  final TextRange? range;
}

/// AL NOTE-owned portable text layout engine boundary.
abstract interface class TextLayoutEngine {
  /// Lays out logical text with bounded immutable output.
  Result<TextLayoutSnapshot, StructuredFailure> layout(
    TextLayoutRequest request,
  );
}

/// Temporary IME composition evidence; never enters persistent storage directly.
final class TextComposition {
  const TextComposition._({required this.range, required this.text});

  /// Creates bounded well-formed temporary composition evidence.
  static Result<TextComposition, StructuredFailure> create({
    required TextRange range,
    required String text,
    required TextLimits limits,
  }) {
    if (!_validReplacement(text, limits)) {
      return Err(_failure('invalid_composition'));
    }
    return Ok(TextComposition._(range: range, text: text));
  }

  /// Draft range replaced by the platform composition.
  final TextRange range;

  /// Temporary platform composition text.
  final String text;
}

/// Semantic edit kinds used to determine safe history coalescing.
enum TextEditKind {
  insertion,
  backwardDeletion,
  forwardDeletion,
  paste,
  formatting,
}

/// Events that terminate a text history coalescing group.
enum TextHistoryBarrier {
  operationKindChange,
  deleteDirectionChange,
  paste,
  formatting,
  objectSwitch,
  caretMovement,
  selectionChange,
  focusChange,
  compositionBoundary,
  save,
  editorClosure,
}

/// Closed semantic coalescing policy for consecutive scalar-position edits.
final class TextHistoryCoalescingPolicy {
  const TextHistoryCoalescingPolicy._();

  /// Whether two consecutive edits may share one history entry.
  static bool mayCoalesce({
    required PendingTextEdit previous,
    required PendingTextEdit next,
    TextHistoryBarrier? barrier,
  }) {
    if (barrier != null ||
        previous.kind != next.kind ||
        previous.range.start.paragraphIndex !=
            next.range.start.paragraphIndex) {
      return false;
    }
    switch (previous.kind) {
      case TextEditKind.insertion:
        if (!previous.range.isCollapsed || !next.range.isCollapsed) {
          return false;
        }
        return next.range.start.scalarOffset ==
            previous.range.start.scalarOffset +
                previous.replacement.runes.length;
      case TextEditKind.backwardDeletion:
        return next.range.end == previous.range.start;
      case TextEditKind.forwardDeletion:
        return next.range.start == previous.range.start;
      case TextEditKind.paste:
      case TextEditKind.formatting:
        return false;
    }
  }
}

/// One bounded pending Text edit without UTF-16 indexes.
final class PendingTextEdit {
  const PendingTextEdit._({
    required this.kind,
    required this.range,
    required this.replacement,
  });

  /// Creates a bounded scalar-position edit with well-formed Unicode.
  static Result<PendingTextEdit, StructuredFailure> create({
    required TextEditKind kind,
    required TextRange range,
    required String replacement,
    required TextLimits limits,
  }) {
    if (!_validReplacement(replacement, limits)) {
      return Err(_failure('invalid_pending_edit'));
    }
    return Ok(
      PendingTextEdit._(kind: kind, range: range, replacement: replacement),
    );
  }

  /// Semantic edit kind.
  final TextEditKind kind;

  /// Logical scalar range.
  final TextRange range;

  /// Replacement logical Unicode text.
  final String replacement;
}

/// Mutable temporary editor session; persistent commits remain Command-owned.
final class TextEditorSession {
  TextEditorSession._({
    required this.object,
    required TextPayload draft,
    required this.baseObjectRevision,
    required TextRange selection,
    required TextCharacterStyle typingStyle,
    required this.limits,
    this.layoutSnapshot,
  }) : _draft = draft,
       _selection = selection,
       _typingStyle = typingStyle;

  /// Creates a session only from a fully validated authoritative draft.
  static Result<TextEditorSession, StructuredFailure> create({
    required ObjectEnvelope object,
    required TextPayload draft,
    required Revision baseObjectRevision,
    required TextRange selection,
    required TextCharacterStyle typingStyle,
    required TextLimits limits,
    TextLayoutSnapshot? layoutSnapshot,
  }) {
    final validatedDraft = TextPayload.decode(draft.encode(), limits: limits);
    final validatedObject =
        object.typeKey == textObjectTypeKey &&
            object.typeSchemaVersion == textSchemaVersion
        ? TextPayload.decode(object.payload, limits: limits)
        : null;
    final validatedTyping = _revalidateCharacterStyle(typingStyle, limits);
    if (validatedDraft is! Ok<TextPayload, StructuredFailure> ||
        validatedObject is! Ok<TextPayload, StructuredFailure> ||
        validatedObject.value.encode() != validatedDraft.value.encode() ||
        validatedTyping is! Ok<TextCharacterStyle, StructuredFailure> ||
        !_validDraftRange(validatedDraft.value, selection, limits)) {
      return Err(_failure('invalid_editor_session'));
    }
    return Ok(
      TextEditorSession._(
        object: object,
        draft: validatedDraft.value,
        baseObjectRevision: baseObjectRevision,
        selection: selection,
        typingStyle: validatedTyping.value,
        limits: limits,
        layoutSnapshot: layoutSnapshot,
      ),
    );
  }

  /// Edited Object envelope.
  final ObjectEnvelope object;

  /// Temporary bounded draft retained after stale rejection.
  final TextPayload _draft;

  /// Current validated temporary draft.
  TextPayload get draft => _draft;

  /// Revision on which the session is based.
  final Revision baseObjectRevision;

  /// Temporary caret/range selection.
  final TextRange _selection;

  /// Current validated grapheme-aligned selection.
  TextRange get selection => _selection;

  /// Temporary typing style.
  final TextCharacterStyle _typingStyle;

  /// Current validated typing style.
  TextCharacterStyle get typingStyle => _typingStyle;

  /// Most recent derived layout.
  TextLayoutSnapshot? layoutSnapshot;

  /// Session limits.
  final TextLimits limits;

  /// Temporary unconfirmed IME composition.
  TextComposition? composition;
  final List<PendingTextEdit> _pending = [];

  /// Immutable pending edit batch.
  List<PendingTextEdit> get pendingEdits => List.unmodifiable(_pending);

  /// Adds a bounded noncomposition edit.
  Result<void, StructuredFailure> addPending(PendingTextEdit edit) {
    if (_pending.length >= limits.maximumPendingEdits ||
        !_validDraftRange(_draft, edit.range, limits) ||
        !_validPendingAggregate(_draft, [..._pending, edit], limits)) {
      return Err(_failure('pending_edit_limit'));
    }
    _pending.add(edit);
    return const Ok<void, StructuredFailure>(null);
  }

  /// Starts or updates temporary IME composition without persistence.
  Result<void, StructuredFailure> updateComposition(TextComposition value) {
    if (!_validDraftRange(_draft, value.range, limits) ||
        !_validReplacement(value.text, limits)) {
      return Err(_failure('composition_limit'));
    }
    composition = value;
    return const Ok<void, StructuredFailure>(null);
  }

  /// Cancels temporary composition.
  void cancelComposition() => composition = null;

  /// Converts platform-confirmed composition to a pending insertion.
  Result<void, StructuredFailure> confirmComposition() {
    final value = composition;
    if (value == null) return Err(_failure('missing_composition'));
    final pending = PendingTextEdit.create(
      kind: TextEditKind.insertion,
      range: value.range,
      replacement: value.text,
      limits: limits,
    );
    if (pending is! Ok<PendingTextEdit, StructuredFailure>) {
      return Err(_failure('invalid_pending_edit'));
    }
    final result = addPending(pending.value);
    if (result is Ok<void, StructuredFailure>) composition = null;
    return result;
  }
}

bool _validDraftRange(TextPayload draft, TextRange range, TextLimits limits) {
  if (range.start.paragraphIndex >= draft.paragraphs.length ||
      range.end.paragraphIndex >= draft.paragraphs.length) {
    return false;
  }
  const boundaries = TextGraphemeBoundaryService();
  for (final position in <TextPosition>[range.start, range.end]) {
    final paragraph = draft.paragraphs[position.paragraphIndex];
    if (position.scalarOffset > paragraph.scalarLength) return false;
    final aligned = boundaries.isBoundary(
      paragraph.logicalText,
      position.scalarOffset,
      maximumScalars: limits.maximumTotalScalars,
    );
    if (aligned is! Ok<bool, StructuredFailure> || !aligned.value) {
      return false;
    }
  }
  return true;
}

bool _validReplacement(String value, TextLimits limits) {
  if (_containsUnpairedSurrogate(value)) return false;
  var segmentScalars = 0;
  var totalScalars = 0;
  for (final rune in value.runes) {
    if (rune == 0x0a) {
      if (segmentScalars > limits.maximumScalarsPerRun) return false;
      segmentScalars = 0;
      continue;
    }
    segmentScalars += 1;
    totalScalars += 1;
    if (segmentScalars > limits.maximumScalarsPerRun ||
        totalScalars > limits.maximumTotalScalars) {
      return false;
    }
  }
  return segmentScalars <= limits.maximumScalarsPerRun;
}

bool _validPendingAggregate(
  TextPayload draft,
  List<PendingTextEdit> edits,
  TextLimits limits,
) {
  var total = 0;
  for (final paragraph in draft.paragraphs) {
    if (paragraph.scalarLength > limits.maximumTotalScalars - total) {
      return false;
    }
    total += paragraph.scalarLength;
  }
  var paragraphs = draft.paragraphs.length;
  final addedRuns = <int, int>{};
  for (final edit in edits) {
    if (!_validDraftRange(draft, edit.range, limits) ||
        !_validReplacement(edit.replacement, limits)) {
      return false;
    }
    final removed = _rangeScalarLength(draft, edit.range);
    if (removed == null) return false;
    var inserted = 0;
    var separators = 0;
    for (final rune in edit.replacement.runes) {
      if (rune == 0x0a) {
        separators += 1;
      } else {
        inserted += 1;
      }
    }
    final removedParagraphBoundaries =
        edit.range.end.paragraphIndex - edit.range.start.paragraphIndex;
    paragraphs += separators - removedParagraphBoundaries;
    if (paragraphs <= 0 || paragraphs > limits.maximumParagraphs) return false;
    final nextTotal = total - removed + inserted;
    if (nextTotal < 0 || nextTotal > limits.maximumTotalScalars) return false;
    total = nextTotal;
    if (edit.replacement.isNotEmpty) {
      final paragraphIndex = edit.range.start.paragraphIndex;
      final additions = (addedRuns[paragraphIndex] ?? 0) + separators + 1;
      if (draft.paragraphs[paragraphIndex].runs.length + additions >
          limits.maximumRunsPerParagraph) {
        return false;
      }
      addedRuns[paragraphIndex] = additions;
    }
  }
  return true;
}

int? _rangeScalarLength(TextPayload draft, TextRange range) {
  if (range.start.paragraphIndex == range.end.paragraphIndex) {
    return range.end.scalarOffset - range.start.scalarOffset;
  }
  var total =
      draft.paragraphs[range.start.paragraphIndex].scalarLength -
      range.start.scalarOffset +
      range.end.scalarOffset;
  for (
    var index = range.start.paragraphIndex + 1;
    index < range.end.paragraphIndex;
    index++
  ) {
    total += draft.paragraphs[index].scalarLength;
    if (total > maximumWebSafeInteger) return null;
  }
  return total;
}

/// Fixed stale-commit recovery choices, with no automatic merge or rebase.
enum StaleTextDraftRecovery { keepDraft, discardDraft, copyPlainText }

/// Presentation-neutral stale draft evidence.
final class StaleTextDraftEvidence {
  /// Creates fixed recovery evidence.
  const StaleTextDraftEvidence({
    required this.baseRevision,
    required this.currentRevision,
  });

  /// Draft base revision.
  final Revision baseRevision;

  /// Current authoritative revision, or null when the Object was removed.
  final Revision? currentRevision;

  /// Closed recovery choices.
  List<StaleTextDraftRecovery> get choices =>
      List.unmodifiable(StaleTextDraftRecovery.values);
}

/// Supported constrained clipboard input kinds.
enum TextClipboardKind {
  plainText,
  internalRichText,
  unsupportedExternalRichText,
}

/// Immutable sanitized clipboard output.
sealed class SanitizedTextClipboard {
  const SanitizedTextClipboard();
}

/// Sanitized bounded logical plain text.
final class SanitizedPlainTextClipboard extends SanitizedTextClipboard {
  /// Creates output.
  const SanitizedPlainTextClipboard(this.text);

  /// Original logical text.
  final String text;
}

/// Sanitized constrained AL NOTE rich Text payload.
final class SanitizedRichTextClipboard extends SanitizedTextClipboard {
  /// Creates output.
  const SanitizedRichTextClipboard(this.payload);

  /// Validated constrained payload.
  final TextPayload payload;
}

/// Bounded clipboard sanitizer that never parses HTML or activates links.
final class TextClipboardSanitizer {
  /// Creates a sanitizer with explicit limits.
  const TextClipboardSanitizer(this.limits);

  /// Text limits.
  final TextLimits limits;

  /// Sanitizes plain, internal-rich, or reduced external-rich input.
  Result<SanitizedTextClipboard, StructuredFailure> sanitize({
    required TextClipboardKind kind,
    String? plainText,
    PreservedData? internalRichText,
    String? callerProvidedFallback,
  }) {
    switch (kind) {
      case TextClipboardKind.internalRichText:
        if (internalRichText == null) return Err(_failure('clipboard_invalid'));
        final payload = TextPayload.decode(internalRichText, limits: limits);
        return payload is Ok<TextPayload, StructuredFailure>
            ? Ok(SanitizedRichTextClipboard(payload.value))
            : Err(_failure('clipboard_invalid'));
      case TextClipboardKind.plainText:
        return _plain(plainText);
      case TextClipboardKind.unsupportedExternalRichText:
        return _plain(callerProvidedFallback);
    }
  }

  Result<SanitizedTextClipboard, StructuredFailure> _plain(String? value) {
    if (value == null ||
        value.runes.length > limits.maximumTotalScalars ||
        _containsUnpairedSurrogate(value))
      return Err(_failure('clipboard_invalid'));
    return Ok(SanitizedPlainTextClipboard(value));
  }
}

PreservedMap _encodeCharacterStyle(TextCharacterStyle value) => PreservedMap({
  ...value.unknownFields.values,
  if (value.preferredFontFamily != null)
    'preferredFontFamily': PreservedString(value.preferredFontFamily!),
  'genericFontFamily': PreservedString(value.genericFontFamily.name),
  'fontSize': _double(value.fontSize),
  'weight': _integer(value.weight),
  'italic': PreservedBoolean(value.italic),
  'underline': PreservedBoolean(value.underline),
  'strikethrough': PreservedBoolean(value.strikethrough),
  'argb': _integer(value.argb),
});

Result<TextCharacterStyle, StructuredFailure> _decodeCharacterStyle(
  PreservedData? data,
  TextLimits limits,
) {
  if (data is! PreservedMap) return Err(_failure('invalid_character_style'));
  final preferred = data.values['preferredFontFamily'];
  final generic = _enumByName(
    TextGenericFontFamily.values,
    data.values['genericFontFamily'],
  );
  final size = _number(data.values['fontSize']);
  final weight = data.values['weight'], italic = data.values['italic'];
  final underline = data.values['underline'],
      strike = data.values['strikethrough'];
  final argb = data.values['argb'];
  if (preferred != null && preferred is! PreservedString ||
      generic == null ||
      size == null ||
      weight is! PreservedInteger ||
      italic is! PreservedBoolean ||
      underline is! PreservedBoolean ||
      strike is! PreservedBoolean ||
      argb is! PreservedInteger) {
    return Err(_failure('invalid_character_style'));
  }
  return TextCharacterStyle.create(
    preferredFontFamily: (preferred as PreservedString?)?.value,
    genericFontFamily: generic,
    fontSize: size,
    weight: weight.value,
    italic: italic.value,
    underline: underline.value,
    strikethrough: strike.value,
    argb: argb.value,
    limits: limits,
    unknownFields: _unknown(data, const {
      'preferredFontFamily',
      'genericFontFamily',
      'fontSize',
      'weight',
      'italic',
      'underline',
      'strikethrough',
      'argb',
    }),
  );
}

PreservedMap _encodeParagraphStyle(TextParagraphStyle value) => PreservedMap({
  ...value.unknownFields.values,
  'alignment': PreservedString(value.alignment.name),
  'direction': PreservedString(value.direction.name),
  'lineHeight': _double(value.lineHeight),
  if (value.languageHint != null)
    'languageHint': PreservedString(value.languageHint!),
});

Result<TextParagraphStyle, StructuredFailure> _decodeParagraphStyle(
  PreservedData? data,
  TextLimits limits,
) {
  if (data is! PreservedMap) return Err(_failure('invalid_paragraph_style'));
  final alignment = _enumByName(TextAlignment.values, data.values['alignment']);
  final direction = _enumByName(
    TextParagraphDirection.values,
    data.values['direction'],
  );
  final lineHeight = _number(data.values['lineHeight']);
  final language = data.values['languageHint'];
  if (alignment == null ||
      direction == null ||
      lineHeight == null ||
      language != null && language is! PreservedString)
    return Err(_failure('invalid_paragraph_style'));
  return TextParagraphStyle.create(
    alignment: alignment,
    direction: direction,
    lineHeight: lineHeight,
    languageHint: (language as PreservedString?)?.value,
    limits: limits,
    unknownFields: _unknown(data, const {
      'alignment',
      'direction',
      'lineHeight',
      'languageHint',
    }),
  );
}

PreservedMap _encodeParagraph(TextParagraph value) => PreservedMap({
  ...value.unknownFields.values,
  'runs': PreservedList(
    value.runs.map(
      (run) => PreservedMap({
        ...run.unknownFields.values,
        'text': PreservedString(run.text),
        'style': _encodeCharacterStyle(run.style),
      }),
    ),
  ),
  'style': _encodeParagraphStyle(value.style),
});

Result<TextParagraph, StructuredFailure> _decodeParagraph(
  PreservedData data,
  TextLimits limits,
) {
  if (data is! PreservedMap || data.values['runs'] is! PreservedList)
    return Err(_failure('invalid_paragraph'));
  final runsData = data.values['runs']! as PreservedList;
  if (runsData.values.length > limits.maximumRunsPerParagraph)
    return Err(_failure('run_limit'));
  final style = _decodeParagraphStyle(data.values['style'], limits);
  if (style is Err<TextParagraphStyle, StructuredFailure>) {
    return Err(style.error);
  }
  final paragraphStyle =
      (style as Ok<TextParagraphStyle, StructuredFailure>).value;
  final runs = <TextRun>[];
  for (final item in runsData.values) {
    if (item is! PreservedMap || item.values['text'] is! PreservedString)
      return Err(_failure('invalid_run'));
    final runStyle = _decodeCharacterStyle(item.values['style'], limits);
    if (runStyle is Err<TextCharacterStyle, StructuredFailure>) {
      return Err(runStyle.error);
    }
    final characterStyle =
        (runStyle as Ok<TextCharacterStyle, StructuredFailure>).value;
    final run = TextRun.create(
      text: (item.values['text']! as PreservedString).value,
      style: characterStyle,
      limits: limits,
      unknownFields: _unknown(item, const {'text', 'style'}),
    );
    if (run is Err<TextRun, StructuredFailure>) return Err(run.error);
    runs.add((run as Ok<TextRun, StructuredFailure>).value);
  }
  return TextParagraph.create(
    runs: runs,
    style: paragraphStyle,
    limits: limits,
    unknownFields: _unknown(data, const {'runs', 'style'}),
  );
}

PreservedMap _encodePadding(TextPadding value) => PreservedMap({
  'left': _double(value.left),
  'top': _double(value.top),
  'right': _double(value.right),
  'bottom': _double(value.bottom),
});
TextPadding? _decodePadding(PreservedData? data, TextLimits limits) {
  if (data is! PreservedMap) return null;
  return TextPadding.create(
    left: _number(data.values['left']) ?? double.nan,
    top: _number(data.values['top']) ?? double.nan,
    right: _number(data.values['right']) ?? double.nan,
    bottom: _number(data.values['bottom']) ?? double.nan,
    limits: limits,
  ).fold<TextPadding?>(onOk: (value) => value, onErr: (_) => null);
}

PreservedData _appearanceProjection(TextPayload value) => PreservedList([
  _encodeCharacterStyle(value.defaultCharacterStyle),
  _encodeParagraphStyle(value.defaultParagraphStyle),
  for (final paragraph in value.paragraphs) ...[
    _encodeParagraphStyle(paragraph.style),
    for (final run in paragraph.runs) _encodeCharacterStyle(run.style),
  ],
]);
T? _enumByName<T extends Enum>(Iterable<T> values, PreservedData? source) {
  if (source is! PreservedString) return null;
  for (final value in values) if (value.name == source.value) return value;
  return null;
}

bool _containsUnpairedSurrogate(String text) {
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= text.length) return true;
      final low = text.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return true;
    } else if (unit >= 0xdc00 && unit <= 0xdfff)
      return true;
  }
  return false;
}

Result<TextCharacterStyle, StructuredFailure> _revalidateCharacterStyle(
  TextCharacterStyle value,
  TextLimits limits,
) => TextCharacterStyle.create(
  preferredFontFamily: value.preferredFontFamily,
  genericFontFamily: value.genericFontFamily,
  fontSize: value.fontSize,
  weight: value.weight,
  italic: value.italic,
  underline: value.underline,
  strikethrough: value.strikethrough,
  argb: value.argb,
  limits: limits,
  unknownFields: value.unknownFields,
);

Result<TextParagraphStyle, StructuredFailure> _revalidateParagraphStyle(
  TextParagraphStyle value,
  TextLimits limits,
) => TextParagraphStyle.create(
  alignment: value.alignment,
  direction: value.direction,
  lineHeight: value.lineHeight,
  languageHint: value.languageHint,
  limits: limits,
  unknownFields: value.unknownFields,
);

bool _unknownAllowed(PreservedMap value, TextLimits limits) {
  return preservedUnknownDataAllowed(
    root: value,
    maximumFieldsPerBoundary: limits.maximumUnknownFields,
    maximumNodes: limits.maximumUnknownNodes,
    maximumDepth: limits.maximumNestingDepth,
    maximumStringCodeUnits: limits.maximumUnknownStringCodeUnits,
  );
}

Result<List<T>, StructuredFailure> _capture<T>(
  Iterable<T> source,
  int maximum,
  String leaf,
) {
  final result = <T>[];
  try {
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (result.length >= maximum) return Err(_failure(leaf));
      result.add(iterator.current);
    }
  } on Object {
    return Err(_failure('invalid_iterable'));
  }
  return Ok(List<T>.unmodifiable(result));
}

PreservedMap _unknown(PreservedMap source, Set<String> known) => PreservedMap(
  Map.fromEntries(
    source.values.entries.where((entry) => !known.contains(entry.key)),
  ),
);
double? _number(PreservedData? value) => switch (value) {
  PreservedDouble(:final value) => value,
  PreservedInteger(:final value) => value.toDouble(),
  _ => null,
};
PreservedDouble _double(double value) =>
    (PreservedDouble.create(value) as Ok<PreservedDouble, StructuredFailure>)
        .value;
PreservedInteger _integer(int value) =>
    (PreservedInteger.create(value) as Ok<PreservedInteger, StructuredFailure>)
        .value;
Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
            as Ok<Rect2, StructuredFailure>)
        .value;
double _distanceSquared(Point2 point, Rect2 rect) {
  final dx = point.x < rect.left
      ? rect.left - point.x
      : point.x > rect.right
      ? point.x - rect.right
      : 0.0;
  final dy = point.y < rect.top
      ? rect.top - point.y
      : point.y > rect.bottom
      ? point.y - rect.bottom
      : 0.0;
  return dx * dx + dy * dy;
}

bool _positive(double value) => value.isFinite && value > 0;
bool _nonnegative(double value) => value.isFinite && value >= 0;
final RegExp _bcp47 = RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$');
ValidationIssue _invalidIssue() =>
    (ValidationIssue.create(
              code: ValidationIssueCode.invalidObjectPayload,
              severity: ValidationSeverity.error,
              path:
                  (ValidationPath.fromSegments(const <ValidationPathSegment>[])
                          as Ok<ValidationPath, StructuredFailure>)
                      .value,
            )
            as Ok<ValidationIssue, StructuredFailure>)
        .value;
SchemaVersion _schemaOne() =>
    (SchemaVersion.create(1) as Ok<SchemaVersion, StructuredFailure>).value;
NamespacedIdentifier _trustedTypeIdentifier() =>
    (ObjectTypeKey.parse('alnote.text') as Ok<ObjectTypeKey, StructuredFailure>)
        .value
        .identifier;
StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.text.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Text data is invalid or unavailable.',
);
