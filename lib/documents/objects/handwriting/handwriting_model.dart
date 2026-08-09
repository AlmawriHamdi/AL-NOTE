// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../../core/geometry/geometry_values.dart';
import '../../../core/identity/namespaced_identifier.dart';
import '../../../core/identity/uuid_generator.dart';
import '../../../core/identity/uuid_identifier.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../../core/validation/validation_issue.dart';
import '../../../core/validation/validation_path.dart';
import '../../../core/validation/validation_report.dart';
import '../../../core/versioning/schema_version.dart';
import '../../model/identity_remapping.dart';
import '../../model/preserved_data.dart';
import '../../resources/resources.dart';
import '../object_envelope.dart';
import '../object_registry.dart';

/// Permanent Object type key for payload schema version 1 handwriting.
final ObjectTypeKey handwritingObjectTypeKey = ObjectTypeKey.fromIdentifier(
  _trustedTypeIdentifier(),
);

/// The supported handwriting payload schema version.
final SchemaVersion handwritingSchemaVersion = _schemaOne();

/// Caller-injected ceilings for handwriting capture and decoding.
final class HandwritingLimits {
  const HandwritingLimits._({
    required this.maximumStrokes,
    required this.maximumSamplesPerStroke,
    required this.maximumUnknownFields,
    required this.maximumNestingDepth,
    required this.maximumUnknownNodes,
    required this.maximumCoordinateMagnitude,
    required this.maximumStrokeWidth,
    required this.maximumAbsoluteTilt,
    required this.maximumAbsoluteOrientation,
  });

  /// Creates explicit structural and numeric ceilings.
  static Result<HandwritingLimits, StructuredFailure> create({
    required int maximumStrokes,
    required int maximumSamplesPerStroke,
    required int maximumUnknownFields,
    required int maximumNestingDepth,
    required int maximumUnknownNodes,
    required double maximumCoordinateMagnitude,
    required double maximumStrokeWidth,
    required double maximumAbsoluteTilt,
    required double maximumAbsoluteOrientation,
  }) {
    if (maximumStrokes <= 0 ||
        maximumStrokes > maximumWebSafeInteger ||
        maximumSamplesPerStroke <= 0 ||
        maximumSamplesPerStroke > maximumWebSafeInteger ||
        maximumUnknownFields < 0 ||
        maximumUnknownFields > maximumWebSafeInteger ||
        maximumNestingDepth <= 0 ||
        maximumNestingDepth > maximumWebSafeInteger ||
        maximumUnknownNodes <= 0 ||
        maximumUnknownNodes > maximumWebSafeInteger ||
        !maximumCoordinateMagnitude.isFinite ||
        maximumCoordinateMagnitude <= 0 ||
        !maximumStrokeWidth.isFinite ||
        maximumStrokeWidth <= 0 ||
        !maximumAbsoluteTilt.isFinite ||
        maximumAbsoluteTilt < 0 ||
        !maximumAbsoluteOrientation.isFinite ||
        maximumAbsoluteOrientation < 0) {
      return Err(_failure('invalid_limits'));
    }
    return Ok(
      HandwritingLimits._(
        maximumStrokes: maximumStrokes,
        maximumSamplesPerStroke: maximumSamplesPerStroke,
        maximumUnknownFields: maximumUnknownFields,
        maximumNestingDepth: maximumNestingDepth,
        maximumUnknownNodes: maximumUnknownNodes,
        maximumCoordinateMagnitude: maximumCoordinateMagnitude,
        maximumStrokeWidth: maximumStrokeWidth,
        maximumAbsoluteTilt: maximumAbsoluteTilt,
        maximumAbsoluteOrientation: maximumAbsoluteOrientation,
      ),
    );
  }

  /// Maximum strokes in one payload.
  final int maximumStrokes;

  /// Maximum samples in one stroke.
  final int maximumSamplesPerStroke;

  /// Maximum preserved unknown fields at each boundary.
  final int maximumUnknownFields;

  /// Maximum preserved unknown-data nesting depth.
  final int maximumNestingDepth;

  /// Maximum scalar and container nodes in one preserved unknown-data graph.
  final int maximumUnknownNodes;

  /// Maximum absolute local coordinate magnitude.
  final double maximumCoordinateMagnitude;

  /// Maximum positive base and resolved stroke width.
  final double maximumStrokeWidth;

  /// Maximum absolute tilt evidence.
  final double maximumAbsoluteTilt;

  /// Maximum absolute orientation evidence.
  final double maximumAbsoluteOrientation;

  /// Whether every ceiling is positive and Web-safe.
  bool get isValid =>
      maximumStrokes > 0 &&
      maximumStrokes <= maximumWebSafeInteger &&
      maximumSamplesPerStroke > 0 &&
      maximumSamplesPerStroke <= maximumWebSafeInteger &&
      maximumUnknownFields >= 0 &&
      maximumUnknownFields <= maximumWebSafeInteger &&
      maximumNestingDepth > 0 &&
      maximumNestingDepth <= maximumWebSafeInteger &&
      maximumUnknownNodes > 0 &&
      maximumUnknownNodes <= maximumWebSafeInteger &&
      maximumCoordinateMagnitude.isFinite &&
      maximumCoordinateMagnitude > 0 &&
      maximumStrokeWidth.isFinite &&
      maximumStrokeWidth > 0 &&
      maximumAbsoluteTilt.isFinite &&
      maximumAbsoluteTilt >= 0 &&
      maximumAbsoluteOrientation.isFinite &&
      maximumAbsoluteOrientation >= 0;
}

/// Stable stroke-subtarget identity backed by an AL NOTE UUID.
final class StrokeId {
  /// Creates a stroke identity from a validated UUID.
  const StrokeId.fromUuid(this.uuid);

  /// Generates a stroke identity through an injected generator.
  static Result<StrokeId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(StrokeId.fromUuid);

  /// Wrapped canonical UUID.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) => other is StrokeId && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(StrokeId, uuid);

  @override
  String toString() => 'StrokeId(${uuid.value})';
}

/// One immutable normalized persistent local-coordinate sample.
final class StrokeSample {
  const StrokeSample._({
    required this.position,
    required this.timeMicros,
    required this.pressure,
    required this.tilt,
    required this.orientation,
    required this.unknownFields,
  });

  /// Creates a finite sample with Web-safe relative monotonic-time evidence.
  static Result<StrokeSample, StructuredFailure> create({
    required Point2 position,
    required int timeMicros,
    required HandwritingLimits limits,
    double? pressure,
    double? tilt,
    double? orientation,
    PreservedMap? unknownFields,
  }) {
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!limits.isValid ||
        position.x.abs() > limits.maximumCoordinateMagnitude ||
        position.y.abs() > limits.maximumCoordinateMagnitude ||
        timeMicros < 0 ||
        timeMicros > maximumWebSafeInteger ||
        (pressure != null &&
            (!pressure.isFinite || pressure < 0 || pressure > 1)) ||
        (tilt != null &&
            (!tilt.isFinite || tilt.abs() > limits.maximumAbsoluteTilt)) ||
        (orientation != null &&
            (!orientation.isFinite ||
                orientation.abs() > limits.maximumAbsoluteOrientation)) ||
        !_unknownDataAllowed(unknown, limits, 1)) {
      return Err(_failure('invalid_sample'));
    }
    return Ok(
      StrokeSample._(
        position: position,
        timeMicros: timeMicros,
        pressure: pressure,
        tilt: tilt,
        orientation: orientation,
        unknownFields: unknown,
      ),
    );
  }

  /// Local-coordinate position.
  final Point2 position;

  /// Nonnegative Web-safe time relative to the stroke start.
  final int timeMicros;

  /// Optional normalized pressure in `[0, 1]`.
  final double? pressure;

  /// Optional finite tilt evidence.
  final double? tilt;

  /// Optional finite orientation evidence.
  final double? orientation;

  /// Preserved safe fields unknown to this implementation.
  final PreservedMap unknownFields;

  @override
  bool operator ==(Object other) =>
      other is StrokeSample &&
      other.position == position &&
      other.timeMicros == timeMicros &&
      other.pressure == pressure &&
      other.tilt == tilt &&
      other.orientation == orientation &&
      other.unknownFields == unknownFields;

  @override
  int get hashCode => Object.hash(
    position,
    timeMicros,
    pressure,
    tilt,
    orientation,
    unknownFields,
  );
}

/// Fully resolved persistent stroke appearance and pressure behavior.
final class StrokeStyle {
  const StrokeStyle._({
    required this.argb,
    required this.opacity,
    required this.baseWidth,
    required this.pressureInfluence,
    required this.minimumPressureFactor,
    required this.unknownFields,
  });

  /// Creates a resolved style independent of runtime tool presets.
  static Result<StrokeStyle, StructuredFailure> create({
    required int argb,
    required double opacity,
    required double baseWidth,
    required double pressureInfluence,
    required double minimumPressureFactor,
    required HandwritingLimits limits,
    PreservedMap? unknownFields,
  }) {
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!limits.isValid ||
        argb < 0 ||
        argb > 0xffffffff ||
        !opacity.isFinite ||
        opacity < 0 ||
        opacity > 1 ||
        !baseWidth.isFinite ||
        baseWidth <= 0 ||
        baseWidth > limits.maximumStrokeWidth ||
        !pressureInfluence.isFinite ||
        pressureInfluence < 0 ||
        pressureInfluence > 1 ||
        !minimumPressureFactor.isFinite ||
        minimumPressureFactor < 0 ||
        minimumPressureFactor > 1 ||
        !_unknownDataAllowed(unknown, limits, 1)) {
      return Err(_failure('invalid_style'));
    }
    return Ok(
      StrokeStyle._(
        argb: argb,
        opacity: opacity,
        baseWidth: baseWidth,
        pressureInfluence: pressureInfluence,
        minimumPressureFactor: minimumPressureFactor,
        unknownFields: unknown,
      ),
    );
  }

  /// Resolved 32-bit ARGB color.
  final int argb;

  /// Resolved opacity in `[0, 1]`.
  final double opacity;

  /// Positive local-coordinate base width.
  final double baseWidth;

  /// Pressure contribution in `[0, 1]`.
  final double pressureInfluence;

  /// Minimum pressure width factor in `[0, 1]`.
  final double minimumPressureFactor;

  /// Preserved safe fields unknown to this implementation.
  final PreservedMap unknownFields;

  /// Returns the resolved width for optional normalized [pressure].
  double widthFor(double? pressure) {
    final p = pressure ?? 1;
    final pressureFactor =
        minimumPressureFactor + (1 - minimumPressureFactor) * p;
    return baseWidth *
        ((1 - pressureInfluence) + pressureInfluence * pressureFactor);
  }

  @override
  bool operator ==(Object other) =>
      other is StrokeStyle &&
      other.argb == argb &&
      other.opacity == opacity &&
      other.baseWidth == baseWidth &&
      other.pressureInfluence == pressureInfluence &&
      other.minimumPressureFactor == minimumPressureFactor &&
      other.unknownFields == unknownFields;

  @override
  int get hashCode => Object.hash(
    argb,
    opacity,
    baseWidth,
    pressureInfluence,
    minimumPressureFactor,
    unknownFields,
  );
}

/// One immutable ordered nonempty handwriting stroke.
final class HandwritingStroke {
  HandwritingStroke._({
    required this.id,
    required List<StrokeSample> samples,
    required this.style,
    required this.unknownFields,
  }) : samples = List.unmodifiable(samples);

  /// Safely captures a stroke without trusting iterable length or behavior.
  static Result<HandwritingStroke, StructuredFailure> create({
    required StrokeId id,
    required Iterable<StrokeSample> samples,
    required StrokeStyle style,
    required HandwritingLimits limits,
    PreservedMap? unknownFields,
  }) {
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!limits.isValid ||
        !_styleAllowed(style, limits) ||
        !_unknownDataAllowed(unknown, limits, 1)) {
      return Err(_failure('invalid_stroke'));
    }
    final captured = _capture(
      samples,
      limits.maximumSamplesPerStroke,
      'samples',
    );
    if (captured is Err<List<StrokeSample>, StructuredFailure>)
      return Err(captured.error);
    final values =
        (captured as Ok<List<StrokeSample>, StructuredFailure>).value;
    if (values.isEmpty) return Err(_failure('empty_stroke'));
    var prior = -1;
    for (final sample in values) {
      if (!_sampleAllowed(sample, limits) || sample.timeMicros < prior) {
        return Err(_failure('non_monotonic_time'));
      }
      prior = sample.timeMicros;
    }
    return Ok(
      HandwritingStroke._(
        id: id,
        samples: values,
        style: style,
        unknownFields: unknown,
      ),
    );
  }

  /// Stable subtarget identity.
  final StrokeId id;

  /// Ordered immutable samples.
  final List<StrokeSample> samples;

  /// Resolved persistent style.
  final StrokeStyle style;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;

  /// Visible local bounds including the maximum stroke radius.
  Rect2 get bounds {
    var left = samples.first.position.x;
    var top = samples.first.position.y;
    var right = left;
    var bottom = top;
    var radius = 0.0;
    for (final sample in samples) {
      left = math.min(left, sample.position.x);
      top = math.min(top, sample.position.y);
      right = math.max(right, sample.position.x);
      bottom = math.max(bottom, sample.position.y);
      radius = math.max(radius, style.widthFor(sample.pressure) / 2);
    }
    return _rect(left - radius, top - radius, right + radius, bottom + radius);
  }

  @override
  bool operator ==(Object other) =>
      other is HandwritingStroke &&
      other.id == id &&
      _listEquals(other.samples, samples) &&
      other.style == style &&
      other.unknownFields == unknownFields;

  @override
  int get hashCode =>
      Object.hash(id, Object.hashAll(samples), style, unknownFields);
}

/// Immutable ordered nonempty handwriting payload.
final class HandwritingPayload {
  HandwritingPayload._({
    required List<HandwritingStroke> strokes,
    required this.unknownFields,
  }) : strokes = List.unmodifiable(strokes);

  /// Safely captures a payload and enforces unique stroke identities.
  static Result<HandwritingPayload, StructuredFailure> create({
    required Iterable<HandwritingStroke> strokes,
    required HandwritingLimits limits,
    PreservedMap? unknownFields,
  }) {
    if (!limits.isValid) return Err(_failure('invalid_limits'));
    final captured = _capture(strokes, limits.maximumStrokes, 'strokes');
    if (captured is Err<List<HandwritingStroke>, StructuredFailure>)
      return Err(captured.error);
    final values =
        (captured as Ok<List<HandwritingStroke>, StructuredFailure>).value;
    if (values.isEmpty) return Err(_failure('empty_payload'));
    final ids = <StrokeId>{};
    for (final stroke in values) {
      if (!ids.add(stroke.id)) return Err(_failure('duplicate_stroke_id'));
      if (stroke.samples.length > limits.maximumSamplesPerStroke)
        return Err(_failure('samples_limit'));
      if (!_strokeAllowed(stroke, limits)) {
        return Err(_failure('invalid_stroke'));
      }
    }
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_unknownDataAllowed(unknown, limits, 1))
      return Err(_failure('unknown_data_limit'));
    return Ok(HandwritingPayload._(strokes: values, unknownFields: unknown));
  }

  /// Ordered immutable strokes.
  final List<HandwritingStroke> strokes;

  /// Preserved safe payload-level unknown fields.
  final PreservedMap unknownFields;

  /// Visible local bounds of every stroke.
  Rect2 get bounds {
    var value = strokes.first.bounds;
    for (final stroke in strokes.skip(1)) {
      final next = stroke.bounds;
      value = _rect(
        math.min(value.left, next.left),
        math.min(value.top, next.top),
        math.max(value.right, next.right),
        math.max(value.bottom, next.bottom),
      );
    }
    return value;
  }

  /// Encodes schema-1 data while reinserting preserved unknown fields.
  PreservedMap encode() => PreservedMap(<String, PreservedData>{
    ...unknownFields.values,
    'strokes': PreservedList(strokes.map(_encodeStroke)),
  });

  /// Decodes and validates schema-1 preserved data using caller ceilings.
  static Result<HandwritingPayload, StructuredFailure> decode(
    PreservedData data, {
    required HandwritingLimits limits,
  }) {
    if (!limits.isValid || data is! PreservedMap)
      return Err(_failure('invalid_payload'));
    final strokesData = data.values['strokes'];
    if (strokesData is! PreservedList ||
        strokesData.values.isEmpty ||
        strokesData.values.length > limits.maximumStrokes) {
      return Err(_failure('invalid_payload'));
    }
    final strokes = <HandwritingStroke>[];
    for (final value in strokesData.values) {
      final decoded = _decodeStroke(value, limits);
      if (decoded is Err<HandwritingStroke, StructuredFailure>)
        return Err(decoded.error);
      strokes.add((decoded as Ok<HandwritingStroke, StructuredFailure>).value);
    }
    return create(
      strokes: strokes,
      limits: limits,
      unknownFields: _unknown(data, const {'strokes'}),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HandwritingPayload &&
      _listEquals(other.strokes, strokes) &&
      other.unknownFields == unknownFields;

  @override
  int get hashCode => Object.hash(Object.hashAll(strokes), unknownFields);
}

/// Built-in Object Registry definition for handwriting schema 1.
final class HandwritingObjectTypeDefinition
    implements ObjectTypeDefinition, ObjectPayloadChangeClassifier {
  /// Creates a definition whose validation uses explicit caller ceilings.
  const HandwritingObjectTypeDefinition(this.limits);

  /// Decode and validation ceilings.
  final HandwritingLimits limits;

  @override
  ObjectTypeKey get typeKey => handwritingObjectTypeKey;

  @override
  List<SchemaVersion> get supportedSchemaVersions =>
      List.unmodifiable([handwritingSchemaVersion]);

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
  ) {
    if (schemaVersion != handwritingSchemaVersion ||
        HandwritingPayload.decode(payload, limits: limits) is Err) {
      return ValidationReport([_invalidIssue()]);
    }
    return ValidationReport(const []);
  }

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != handwritingSchemaVersion) {
      return Err(_failure('unsupported_schema'));
    }
    return HandwritingPayload.decode(
      payload,
      limits: limits,
    ).map((value) => value.bounds);
  }

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != handwritingSchemaVersion) {
      return Err(_failure('unsupported_schema'));
    }
    return HandwritingPayload.decode(
      payload,
      limits: limits,
    ).map((_) => List<ResourceReference>.unmodifiable(const []));
  }

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) {
    if (schemaVersion != handwritingSchemaVersion) {
      return Err(_failure('unsupported_schema'));
    }
    return HandwritingPayload.decode(
      payload,
      limits: limits,
    ).map((value) => value.encode());
  }

  @override
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != handwritingSchemaVersion) {
      return Err(_failure('unsupported_schema'));
    }
    final first = HandwritingPayload.decode(before, limits: limits);
    final second = HandwritingPayload.decode(after, limits: limits);
    if (first is! Ok<HandwritingPayload, StructuredFailure> ||
        second is! Ok<HandwritingPayload, StructuredFailure>) {
      return Err(_failure('invalid_payload'));
    }
    final oldValue = first.value, newValue = second.value;
    return Ok(
      ObjectPayloadChangeSemantics(
        geometry: !_sameGeometry(oldValue, newValue),
        appearance: !_sameAppearance(oldValue, newValue),
        text: false,
        metadata: !_sameMetadata(oldValue, newValue),
      ),
    );
  }
}

bool _sameStrokeStructure(HandwritingPayload a, HandwritingPayload b) {
  if (a.strokes.length != b.strokes.length) return false;
  for (var index = 0; index < a.strokes.length; index += 1) {
    if (a.strokes[index].id != b.strokes[index].id) return false;
  }
  return true;
}

bool _sameGeometry(HandwritingPayload a, HandwritingPayload b) {
  if (!_sameStrokeStructure(a, b)) return false;
  for (var strokeIndex = 0; strokeIndex < a.strokes.length; strokeIndex += 1) {
    final first = a.strokes[strokeIndex], second = b.strokes[strokeIndex];
    if (first.samples.length != second.samples.length ||
        first.style.baseWidth != second.style.baseWidth ||
        first.style.pressureInfluence != second.style.pressureInfluence ||
        first.style.minimumPressureFactor !=
            second.style.minimumPressureFactor) {
      return false;
    }
    for (
      var sampleIndex = 0;
      sampleIndex < first.samples.length;
      sampleIndex += 1
    ) {
      final oldSample = first.samples[sampleIndex];
      final newSample = second.samples[sampleIndex];
      if (oldSample.position != newSample.position ||
          oldSample.pressure != newSample.pressure) {
        return false;
      }
    }
  }
  return true;
}

bool _sameAppearance(HandwritingPayload a, HandwritingPayload b) {
  if (!_sameStrokeStructure(a, b)) return true;
  for (var index = 0; index < a.strokes.length; index += 1) {
    final first = a.strokes[index].style, second = b.strokes[index].style;
    if (first.argb != second.argb || first.opacity != second.opacity) {
      return false;
    }
  }
  return true;
}

bool _sameMetadata(HandwritingPayload a, HandwritingPayload b) {
  if (!_sameStrokeStructure(a, b) || a.unknownFields != b.unknownFields) {
    return false;
  }
  for (var strokeIndex = 0; strokeIndex < a.strokes.length; strokeIndex += 1) {
    final first = a.strokes[strokeIndex], second = b.strokes[strokeIndex];
    if (first.unknownFields != second.unknownFields ||
        first.style.unknownFields != second.style.unknownFields ||
        first.samples.length != second.samples.length) {
      return false;
    }
    for (
      var sampleIndex = 0;
      sampleIndex < first.samples.length;
      sampleIndex += 1
    ) {
      final oldSample = first.samples[sampleIndex];
      final newSample = second.samples[sampleIndex];
      if (oldSample.timeMicros != newSample.timeMicros ||
          oldSample.tilt != newSample.tilt ||
          oldSample.orientation != newSample.orientation ||
          oldSample.unknownFields != newSample.unknownFields) {
        return false;
      }
    }
  }
  return true;
}

PreservedMap _encodeStroke(HandwritingStroke value) =>
    PreservedMap(<String, PreservedData>{
      ...value.unknownFields.values,
      'id': PreservedString(value.id.uuid.value),
      'samples': PreservedList(value.samples.map(_encodeSample)),
      'style': _encodeStyle(value.style),
    });

PreservedMap _encodeSample(StrokeSample value) =>
    PreservedMap(<String, PreservedData>{
      ...value.unknownFields.values,
      'x': _double(value.position.x),
      'y': _double(value.position.y),
      'timeMicros': _integer(value.timeMicros),
      if (value.pressure != null) 'pressure': _double(value.pressure!),
      if (value.tilt != null) 'tilt': _double(value.tilt!),
      if (value.orientation != null) 'orientation': _double(value.orientation!),
    });

PreservedMap _encodeStyle(StrokeStyle value) =>
    PreservedMap(<String, PreservedData>{
      ...value.unknownFields.values,
      'argb': _integer(value.argb),
      'opacity': _double(value.opacity),
      'baseWidth': _double(value.baseWidth),
      'pressureInfluence': _double(value.pressureInfluence),
      'minimumPressureFactor': _double(value.minimumPressureFactor),
    });

Result<HandwritingStroke, StructuredFailure> _decodeStroke(
  PreservedData data,
  HandwritingLimits limits,
) {
  if (data is! PreservedMap) return Err(_failure('invalid_stroke'));
  final idValue = data.values['id'];
  final samplesValue = data.values['samples'];
  final styleValue = data.values['style'];
  if (idValue is! PreservedString ||
      samplesValue is! PreservedList ||
      styleValue is! PreservedMap ||
      samplesValue.values.isEmpty ||
      samplesValue.values.length > limits.maximumSamplesPerStroke)
    return Err(_failure('invalid_stroke'));
  final uuid = UuidIdentifier.parse(idValue.value);
  if (uuid is Err<UuidIdentifier, StructuredFailure>)
    return Err(_failure('invalid_stroke'));
  final style = _decodeStyle(styleValue, limits);
  if (style is Err<StrokeStyle, StructuredFailure>) return Err(style.error);
  final samples = <StrokeSample>[];
  for (final value in samplesValue.values) {
    final sample = _decodeSample(value, limits);
    if (sample is Err<StrokeSample, StructuredFailure>)
      return Err(sample.error);
    samples.add((sample as Ok<StrokeSample, StructuredFailure>).value);
  }
  return HandwritingStroke.create(
    id: StrokeId.fromUuid(
      (uuid as Ok<UuidIdentifier, StructuredFailure>).value,
    ),
    samples: samples,
    style: (style as Ok<StrokeStyle, StructuredFailure>).value,
    limits: limits,
    unknownFields: _unknown(data, const {'id', 'samples', 'style'}),
  );
}

Result<StrokeSample, StructuredFailure> _decodeSample(
  PreservedData data,
  HandwritingLimits limits,
) {
  if (data is! PreservedMap) return Err(_failure('invalid_sample'));
  final x = _number(data.values['x']);
  final y = _number(data.values['y']);
  final time = data.values['timeMicros'];
  if (x == null || y == null || time is! PreservedInteger)
    return Err(_failure('invalid_sample'));
  final point = Point2.create(x: x, y: y);
  if (point is Err<Point2, StructuredFailure>)
    return Err(_failure('invalid_sample'));
  return StrokeSample.create(
    position: (point as Ok<Point2, StructuredFailure>).value,
    timeMicros: time.value,
    limits: limits,
    pressure: _optionalNumber(data, 'pressure'),
    tilt: _optionalNumber(data, 'tilt'),
    orientation: _optionalNumber(data, 'orientation'),
    unknownFields: _unknown(data, const {
      'x',
      'y',
      'timeMicros',
      'pressure',
      'tilt',
      'orientation',
    }),
  );
}

Result<StrokeStyle, StructuredFailure> _decodeStyle(
  PreservedMap data,
  HandwritingLimits limits,
) {
  final argb = data.values['argb'];
  final opacity = _number(data.values['opacity']);
  final width = _number(data.values['baseWidth']);
  final influence = _number(data.values['pressureInfluence']);
  final minimum = _number(data.values['minimumPressureFactor']);
  if (argb is! PreservedInteger ||
      opacity == null ||
      width == null ||
      influence == null ||
      minimum == null)
    return Err(_failure('invalid_style'));
  return StrokeStyle.create(
    argb: argb.value,
    opacity: opacity,
    baseWidth: width,
    pressureInfluence: influence,
    minimumPressureFactor: minimum,
    limits: limits,
    unknownFields: _unknown(data, const {
      'argb',
      'opacity',
      'baseWidth',
      'pressureInfluence',
      'minimumPressureFactor',
    }),
  );
}

bool _sampleAllowed(StrokeSample sample, HandwritingLimits limits) =>
    sample.position.x.abs() <= limits.maximumCoordinateMagnitude &&
    sample.position.y.abs() <= limits.maximumCoordinateMagnitude &&
    sample.timeMicros >= 0 &&
    sample.timeMicros <= maximumWebSafeInteger &&
    (sample.pressure == null ||
        (sample.pressure!.isFinite &&
            sample.pressure! >= 0 &&
            sample.pressure! <= 1)) &&
    (sample.tilt == null ||
        (sample.tilt!.isFinite &&
            sample.tilt!.abs() <= limits.maximumAbsoluteTilt)) &&
    (sample.orientation == null ||
        (sample.orientation!.isFinite &&
            sample.orientation!.abs() <= limits.maximumAbsoluteOrientation)) &&
    _unknownDataAllowed(sample.unknownFields, limits, 1);

bool _styleAllowed(StrokeStyle style, HandwritingLimits limits) {
  final widths = <double>[
    style.widthFor(0),
    style.widthFor(1),
    style.baseWidth,
  ];
  return style.argb >= 0 &&
      style.argb <= 0xffffffff &&
      style.opacity.isFinite &&
      style.opacity >= 0 &&
      style.opacity <= 1 &&
      style.pressureInfluence.isFinite &&
      style.pressureInfluence >= 0 &&
      style.pressureInfluence <= 1 &&
      style.minimumPressureFactor.isFinite &&
      style.minimumPressureFactor >= 0 &&
      style.minimumPressureFactor <= 1 &&
      widths.every(
        (width) =>
            width.isFinite && width > 0 && width <= limits.maximumStrokeWidth,
      ) &&
      _unknownDataAllowed(style.unknownFields, limits, 1);
}

bool _strokeAllowed(HandwritingStroke stroke, HandwritingLimits limits) {
  if (!_styleAllowed(stroke.style, limits) ||
      !_unknownDataAllowed(stroke.unknownFields, limits, 1)) {
    return false;
  }
  var prior = -1;
  for (final sample in stroke.samples) {
    if (!_sampleAllowed(sample, limits) || sample.timeMicros < prior) {
      return false;
    }
    prior = sample.timeMicros;
    final radius = stroke.style.widthFor(sample.pressure) / 2;
    if (!(sample.position.x - radius).isFinite ||
        !(sample.position.x + radius).isFinite ||
        !(sample.position.y - radius).isFinite ||
        !(sample.position.y + radius).isFinite) {
      return false;
    }
  }
  return true;
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
double? _optionalNumber(PreservedMap data, String key) =>
    data.values.containsKey(key)
    ? _number(data.values[key]) ?? double.nan
    : null;
PreservedDouble _double(double value) =>
    (PreservedDouble.create(value) as Ok<PreservedDouble, StructuredFailure>)
        .value;
PreservedInteger _integer(int value) =>
    (PreservedInteger.create(value) as Ok<PreservedInteger, StructuredFailure>)
        .value;

Result<List<T>, StructuredFailure> _capture<T>(
  Iterable<T> source,
  int maximum,
  String leaf,
) {
  if (maximum < 0 || maximum > maximumWebSafeInteger)
    return Err(_failure('invalid_limits'));
  final values = <T>[];
  try {
    final iterator = source.iterator;
    while (true) {
      final hasNext = iterator.moveNext();
      if (!hasNext) break;
      if (values.length >= maximum) return Err(_failure('${leaf}_limit'));
      values.add(iterator.current);
    }
  } on Object {
    return Err(_failure('invalid_iterable'));
  }
  return Ok(List.unmodifiable(values));
}

bool _unknownDataAllowed(
  PreservedData value,
  HandwritingLimits limits,
  int depth,
) {
  final pending = <({PreservedData value, int depth})>[
    (value: value, depth: depth),
  ];
  var acceptedNodes = 1;
  try {
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (current.depth > limits.maximumNestingDepth) {
        return false;
      }
      Iterator<PreservedData>? children;
      switch (current.value) {
        case PreservedMap(:final values):
          children = values.entries.map((entry) => entry.value).iterator;
        case PreservedList(:final values):
          children = values.iterator;
        default:
          continue;
      }
      var childCount = 0;
      while (true) {
        final hasNext = children.moveNext();
        if (!hasNext) break;
        if (childCount >= limits.maximumUnknownFields ||
            acceptedNodes >= limits.maximumUnknownNodes ||
            current.depth >= limits.maximumNestingDepth) {
          return false;
        }
        final child = children.current;
        childCount += 1;
        acceptedNodes += 1;
        pending.add((value: child, depth: current.depth + 1));
      }
    }
  } on Object {
    return false;
  }
  return true;
}

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
Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
            as Ok<Rect2, StructuredFailure>)
        .value;
SchemaVersion _schemaOne() =>
    (SchemaVersion.create(1) as Ok<SchemaVersion, StructuredFailure>).value;

NamespacedIdentifier _trustedTypeIdentifier() {
  final parsed = ObjectTypeKey.parse('alnote.objects.handwriting');
  return (parsed as Ok<ObjectTypeKey, StructuredFailure>).value.identifier;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
  return true;
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.handwriting.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Handwriting data is invalid.',
);
