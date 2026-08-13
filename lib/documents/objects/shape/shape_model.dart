// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../../core/geometry/geometry_values.dart';
import '../../../core/identity/namespaced_identifier.dart';
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
import 'shape_geometry.dart';

/// Permanent built-in Shape Object type key.
final ObjectTypeKey shapeObjectTypeKey = ObjectTypeKey.fromIdentifier(
  _trustedTypeIdentifier(),
);

/// Supported built-in Shape payload schema.
final SchemaVersion shapeSchemaVersion = _schemaOne();

/// Supported persistent shape geometry kinds.
enum ShapeKind { line, rectangle, ellipse, polygon, polyline }

/// Stroke endpoint cap behavior.
enum ShapeStrokeCap { butt, round, square }

/// Stroke corner join behavior.
enum ShapeStrokeJoin { miter, round, bevel }

/// Polygon fill winding rule.
enum ShapeFillRule { nonZero, evenOdd }

/// Supported endpoint decorations.
enum ShapeArrowhead { none, triangle, open, diamond, circle }

/// Explicit caller-injected Shape validation and derived-work limits.
final class ShapeLimits {
  const ShapeLimits._({
    required this.maximumVertices,
    required this.maximumDashValues,
    required this.maximumUnknownFields,
    required this.maximumUnknownNodes,
    required this.maximumNestingDepth,
    required this.maximumUnknownStringCodeUnits,
    required this.maximumCoordinateMagnitude,
    required this.maximumStrokeWidth,
    required this.maximumMiterLimit,
    required this.maximumCornerRadius,
    required this.maximumDerivedSegments,
  });

  /// Creates Web-safe, finite, positive Shape ceilings.
  static Result<ShapeLimits, StructuredFailure> create({
    required int maximumVertices,
    required int maximumDashValues,
    required int maximumUnknownFields,
    required int maximumUnknownNodes,
    required int maximumNestingDepth,
    required int maximumUnknownStringCodeUnits,
    required double maximumCoordinateMagnitude,
    required double maximumStrokeWidth,
    required double maximumMiterLimit,
    required double maximumCornerRadius,
    required int maximumDerivedSegments,
  }) {
    final counts = <int>[
      maximumVertices,
      maximumDashValues,
      maximumUnknownFields,
      maximumUnknownNodes,
      maximumNestingDepth,
      maximumUnknownStringCodeUnits,
      maximumDerivedSegments,
    ];
    if (maximumVertices < 3 ||
        counts.any((value) => value < 0 || value > maximumWebSafeInteger) ||
        maximumUnknownNodes == 0 ||
        maximumNestingDepth == 0 ||
        maximumUnknownStringCodeUnits == 0 ||
        maximumDerivedSegments == 0 ||
        maximumDerivedSegments < 16 ||
        maximumDerivedSegments < maximumVertices ||
        !_positive(maximumCoordinateMagnitude) ||
        !_positive(maximumStrokeWidth) ||
        !_positive(maximumMiterLimit) ||
        !_nonnegativeFinite(maximumCornerRadius)) {
      return Err(_failure('invalid_limits'));
    }
    return Ok(
      ShapeLimits._(
        maximumVertices: maximumVertices,
        maximumDashValues: maximumDashValues,
        maximumUnknownFields: maximumUnknownFields,
        maximumUnknownNodes: maximumUnknownNodes,
        maximumNestingDepth: maximumNestingDepth,
        maximumUnknownStringCodeUnits: maximumUnknownStringCodeUnits,
        maximumCoordinateMagnitude: maximumCoordinateMagnitude,
        maximumStrokeWidth: maximumStrokeWidth,
        maximumMiterLimit: maximumMiterLimit,
        maximumCornerRadius: maximumCornerRadius,
        maximumDerivedSegments: maximumDerivedSegments,
      ),
    );
  }

  /// Maximum polygon or polyline vertices.
  final int maximumVertices;

  /// Maximum stroke dash entries.
  final int maximumDashValues;

  /// Maximum unknown fields on each preserved boundary.
  final int maximumUnknownFields;

  /// Maximum nodes in an unknown-field graph.
  final int maximumUnknownNodes;

  /// Maximum unknown-field nesting depth.
  final int maximumNestingDepth;

  /// Maximum cumulative UTF-16 code units in unknown keys and strings.
  final int maximumUnknownStringCodeUnits;

  /// Maximum absolute local coordinate.
  final double maximumCoordinateMagnitude;

  /// Maximum positive stroke width.
  final double maximumStrokeWidth;

  /// Maximum positive miter limit.
  final double maximumMiterLimit;

  /// Maximum nonnegative rectangle corner radius.
  final double maximumCornerRadius;

  /// Maximum derived path segments per Shape.
  final int maximumDerivedSegments;
}

/// Immutable 8-bit-per-channel RGBA color.
final class ShapeColor {
  const ShapeColor._(this.red, this.green, this.blue, this.alpha);

  /// Creates a color from four channel integers in `[0, 255]`.
  static Result<ShapeColor, StructuredFailure> create({
    required int red,
    required int green,
    required int blue,
    required int alpha,
  }) {
    if (<int>[
      red,
      green,
      blue,
      alpha,
    ].any((value) => value < 0 || value > 255)) {
      return Err(_failure('invalid_color'));
    }
    return Ok(ShapeColor._(red, green, blue, alpha));
  }

  /// Red channel.
  final int red;

  /// Green channel.
  final int green;

  /// Blue channel.
  final int blue;

  /// Alpha channel.
  final int alpha;

  /// Portable packed ARGB representation used by rendering adapters.
  int get argb => alpha << 24 | red << 16 | green << 8 | blue;

  @override
  bool operator ==(Object other) =>
      other is ShapeColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue &&
      other.alpha == alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);

  @override
  String toString() => 'ShapeColor(redacted)';
}

/// Sealed immutable family of persistent local Shape geometry.
sealed class ShapeGeometry {
  const ShapeGeometry(this.unknownFields);

  /// Preserved fields unknown at this geometry boundary.
  final PreservedMap unknownFields;

  /// Persistent kind.
  ShapeKind get kind;

  /// Conservative local geometry bounds before common Object transform.
  Rect2 get bounds;
}

/// A persistent line segment.
final class ShapeLineGeometry extends ShapeGeometry {
  /// Creates a line after validating its finite bounded endpoints.
  static Result<ShapeLineGeometry, StructuredFailure> create({
    required Point2 start,
    required Point2 end,
    required ShapeLimits limits,
    PreservedMap? unknownFields,
  }) {
    if (!_pointAllowed(start, limits) || !_pointAllowed(end, limits)) {
      return Err(_failure('invalid_geometry'));
    }
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_unknownAllowed(unknown, limits))
      return Err(_failure('unknown_limit'));
    return Ok(ShapeLineGeometry._(start, end, unknown));
  }

  // ignore: sort_constructors_first
  const ShapeLineGeometry._(this.start, this.end, super.unknownFields);

  /// Local start point.
  final Point2 start;

  /// Local end point.
  final Point2 end;

  @override
  ShapeKind get kind => ShapeKind.line;

  @override
  Rect2 get bounds => _rect(
    math.min(start.x, end.x),
    math.min(start.y, end.y),
    math.max(start.x, end.x),
    math.max(start.y, end.y),
  );
}

/// A persistent normalized rectangle, optionally with uniform round corners.
final class ShapeRectangleGeometry extends ShapeGeometry {
  /// Creates normalized rectangle geometry.
  static Result<ShapeRectangleGeometry, StructuredFailure> create({
    required Rect2 bounds,
    required ShapeLimits limits,
    double cornerRadius = 0,
    PreservedMap? unknownFields,
  }) {
    final largestRadius = math.min(bounds.width, bounds.height) / 2;
    if (!_rectAllowed(bounds, limits) ||
        !_nonnegativeFinite(cornerRadius) ||
        cornerRadius > limits.maximumCornerRadius ||
        cornerRadius > largestRadius) {
      return Err(_failure('invalid_geometry'));
    }
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_unknownAllowed(unknown, limits))
      return Err(_failure('unknown_limit'));
    return Ok(ShapeRectangleGeometry._(bounds, cornerRadius, unknown));
  }

  // ignore: sort_constructors_first
  const ShapeRectangleGeometry._(
    this.localBounds,
    this.cornerRadius,
    super.unknownFields,
  );

  /// Normalized local bounds.
  final Rect2 localBounds;

  /// Uniform nonnegative corner radius.
  final double cornerRadius;

  @override
  ShapeKind get kind => ShapeKind.rectangle;

  @override
  Rect2 get bounds => localBounds;
}

/// Persistent ellipse geometry defined by local bounds.
final class ShapeEllipseGeometry extends ShapeGeometry {
  /// Creates bounded normalized ellipse geometry.
  static Result<ShapeEllipseGeometry, StructuredFailure> create({
    required Rect2 bounds,
    required ShapeLimits limits,
    PreservedMap? unknownFields,
  }) {
    if (!_rectAllowed(bounds, limits)) return Err(_failure('invalid_geometry'));
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_unknownAllowed(unknown, limits))
      return Err(_failure('unknown_limit'));
    return Ok(ShapeEllipseGeometry._(bounds, unknown));
  }

  // ignore: sort_constructors_first
  const ShapeEllipseGeometry._(this.localBounds, super.unknownFields);

  /// Normalized local bounds.
  final Rect2 localBounds;

  @override
  ShapeKind get kind => ShapeKind.ellipse;

  @override
  Rect2 get bounds => localBounds;
}

/// Persistent ordered polygon or polyline vertices without vertex identities.
final class ShapeVertexGeometry extends ShapeGeometry {
  /// Safely captures bounded vertices.
  static Result<ShapeVertexGeometry, StructuredFailure> create({
    required ShapeKind kind,
    required Iterable<Point2> vertices,
    required ShapeLimits limits,
    PreservedMap? unknownFields,
  }) {
    if (kind != ShapeKind.polygon && kind != ShapeKind.polyline) {
      return Err(_failure('invalid_kind'));
    }
    final captured = _capture(vertices, limits.maximumVertices, 'vertex_limit');
    if (captured is Err<List<Point2>, StructuredFailure>)
      return Err(captured.error);
    final values = (captured as Ok<List<Point2>, StructuredFailure>).value;
    final minimum = kind == ShapeKind.polygon ? 3 : 2;
    if (values.length < minimum ||
        values.any((point) => !_pointAllowed(point, limits))) {
      return Err(_failure('invalid_geometry'));
    }
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_unknownAllowed(unknown, limits))
      return Err(_failure('unknown_limit'));
    return Ok(ShapeVertexGeometry._(kind, values, unknown));
  }

  // ignore: sort_constructors_first
  ShapeVertexGeometry._(this.kind, List<Point2> vertices, super.unknownFields)
    : vertices = List<Point2>.unmodifiable(vertices);

  @override
  final ShapeKind kind;

  /// Ordered local vertices; schema 1 intentionally assigns no identities.
  final List<Point2> vertices;

  @override
  Rect2 get bounds => _pointBounds(vertices);
}

/// Immutable complete Shape appearance.
final class ShapeStyle {
  ShapeStyle._({
    required this.strokeEnabled,
    required this.strokeColor,
    required this.strokeWidth,
    required this.cap,
    required this.join,
    required this.miterLimit,
    required List<double> dashArray,
    required this.dashOffset,
    required this.fillEnabled,
    required this.fillColor,
    required this.fillRule,
    required this.opacity,
    required this.startArrowhead,
    required this.endArrowhead,
    required this.unknownFields,
  }) : dashArray = List<double>.unmodifiable(dashArray);

  /// Creates validated appearance with explicit limits.
  static Result<ShapeStyle, StructuredFailure> create({
    required bool strokeEnabled,
    required ShapeColor strokeColor,
    required double strokeWidth,
    required ShapeStrokeCap cap,
    required ShapeStrokeJoin join,
    required double miterLimit,
    required Iterable<double> dashArray,
    required double dashOffset,
    required bool fillEnabled,
    required ShapeColor fillColor,
    required ShapeFillRule fillRule,
    required double opacity,
    required ShapeArrowhead startArrowhead,
    required ShapeArrowhead endArrowhead,
    required ShapeLimits limits,
    PreservedMap? unknownFields,
  }) {
    final dashes = _capture(dashArray, limits.maximumDashValues, 'dash_limit');
    if (dashes is Err<List<double>, StructuredFailure>)
      return Err(dashes.error);
    final values = (dashes as Ok<List<double>, StructuredFailure>).value;
    final dashSum = values.fold<double>(0, (sum, value) => sum + value);
    final unknown = unknownFields ?? PreservedMap.empty();
    if (!_positive(strokeWidth) ||
        strokeWidth > limits.maximumStrokeWidth ||
        !_positive(miterLimit) ||
        miterLimit > limits.maximumMiterLimit ||
        !dashOffset.isFinite ||
        values.any((value) => !_positive(value)) ||
        !dashSum.isFinite ||
        !opacity.isFinite ||
        opacity < 0 ||
        opacity > 1 ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_style'));
    }
    return Ok(
      ShapeStyle._(
        strokeEnabled: strokeEnabled,
        strokeColor: strokeColor,
        strokeWidth: strokeWidth,
        cap: cap,
        join: join,
        miterLimit: miterLimit,
        dashArray: values,
        dashOffset: dashOffset,
        fillEnabled: fillEnabled,
        fillColor: fillColor,
        fillRule: fillRule,
        opacity: opacity,
        startArrowhead: startArrowhead,
        endArrowhead: endArrowhead,
        unknownFields: unknown,
      ),
    );
  }

  /// Whether a stroke is painted.
  final bool strokeEnabled;

  /// Stroke color.
  final ShapeColor strokeColor;

  /// Positive local stroke width.
  final double strokeWidth;

  /// Stroke cap.
  final ShapeStrokeCap cap;

  /// Stroke join.
  final ShapeStrokeJoin join;

  /// Positive miter limit.
  final double miterLimit;

  /// Positive alternating dash lengths.
  final List<double> dashArray;

  /// Finite phase into the dash pattern.
  final double dashOffset;

  /// Whether an eligible closed shape paints a fill.
  final bool fillEnabled;

  /// Solid fill color.
  final ShapeColor fillColor;

  /// Polygon winding rule.
  final ShapeFillRule fillRule;

  /// Shape-wide opacity in `[0, 1]`.
  final double opacity;

  /// Start endpoint decoration.
  final ShapeArrowhead startArrowhead;

  /// End endpoint decoration.
  final ShapeArrowhead endArrowhead;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;
}

/// Immutable schema-1 Shape Object payload.
final class ShapePayload {
  const ShapePayload._({
    required this.geometry,
    required this.style,
    required this.unknownFields,
  });

  /// Creates a validated Shape payload.
  static Result<ShapePayload, StructuredFailure> create({
    required ShapeGeometry geometry,
    required ShapeStyle style,
    required ShapeLimits limits,
    PreservedMap? unknownFields,
  }) {
    final unknown = unknownFields ?? PreservedMap.empty();
    final capturedGeometry = _captureGeometry(geometry, limits);
    final capturedStyle = _captureStyle(style, limits);
    if (capturedGeometry is! Ok<ShapeGeometry, StructuredFailure> ||
        capturedStyle is! Ok<ShapeStyle, StructuredFailure> ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_payload'));
    }
    return Ok(
      ShapePayload._(
        geometry: capturedGeometry.value,
        style: capturedStyle.value,
        unknownFields: unknown,
      ),
    );
  }

  /// Persistent geometry.
  final ShapeGeometry geometry;

  /// Persistent appearance.
  final ShapeStyle style;

  /// Preserved safe unknown payload fields.
  final PreservedMap unknownFields;

  /// Whether this kind is eligible to paint a fill.
  bool get paintsFill =>
      style.fillEnabled &&
      geometry.kind != ShapeKind.line &&
      geometry.kind != ShapeKind.polyline;

  /// Encodes deterministically while restoring unknown fields exactly.
  PreservedMap encode() => PreservedMap(<String, PreservedData>{
    ...unknownFields.values,
    'geometry': _encodeGeometry(geometry),
    'style': _encodeStyle(style),
  });

  /// Decodes schema-1 preserved data using explicit ceilings.
  static Result<ShapePayload, StructuredFailure> decode(
    PreservedData data, {
    required ShapeLimits limits,
  }) {
    if (data is! PreservedMap) return Err(_failure('invalid_payload'));
    final geometry = _decodeGeometry(data.values['geometry'], limits);
    final style = _decodeStyle(data.values['style'], limits);
    if (geometry is! Ok<ShapeGeometry, StructuredFailure> ||
        style is! Ok<ShapeStyle, StructuredFailure>) {
      return Err(_failure('invalid_payload'));
    }
    return create(
      geometry: geometry.value,
      style: style.value,
      limits: limits,
      unknownFields: _unknown(data, const {'geometry', 'style'}),
    );
  }
}

/// Built-in Registry definition for `alnote.shape` schema 1.
final class ShapeObjectTypeDefinition
    implements ObjectTypeDefinition, ObjectPayloadChangeClassifier {
  /// Creates a definition with explicit Shape limits.
  const ShapeObjectTypeDefinition(this.limits);

  /// Shape validation ceilings.
  final ShapeLimits limits;

  @override
  ObjectTypeKey get typeKey => shapeObjectTypeKey;

  @override
  List<SchemaVersion> get supportedSchemaVersions =>
      List<SchemaVersion>.unmodifiable([shapeSchemaVersion]);

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
      schemaVersion == shapeSchemaVersion &&
          ShapePayload.decode(payload, limits: limits) is Ok
      ? ValidationReport(const [])
      : ValidationReport([_invalidIssue()]);

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != shapeSchemaVersion) {
      return Err(_failure('unsupported_schema'));
    }
    final decoded = ShapePayload.decode(payload, limits: limits);
    if (decoded is! Ok<ShapePayload, StructuredFailure>) {
      return Err(_failure('invalid_payload'));
    }
    final derived = ShapeDerivedGeometry.derive(
      payload: decoded.value,
      shapeLimits: limits,
      curveSegments: shapeCurveSegmentsFor(limits),
    );
    return derived is Ok<ShapeDerivedGeometry, StructuredFailure>
        ? Ok(derived.value.localVisibleBounds)
        : Err(_failure('visible_geometry_unavailable'));
  }

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => schemaVersion != shapeSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : ShapePayload.decode(
          payload,
          limits: limits,
        ).map((_) => List<ResourceReference>.unmodifiable(const []));

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => schemaVersion != shapeSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : ShapePayload.decode(
          payload,
          limits: limits,
        ).map((value) => value.encode());

  @override
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != shapeSchemaVersion)
      return Err(_failure('unsupported_schema'));
    final oldValue = ShapePayload.decode(before, limits: limits);
    final newValue = ShapePayload.decode(after, limits: limits);
    if (oldValue is! Ok<ShapePayload, StructuredFailure> ||
        newValue is! Ok<ShapePayload, StructuredFailure>) {
      return Err(_failure('invalid_payload'));
    }
    return Ok(
      ObjectPayloadChangeSemantics(
        geometry:
            _encodeGeometry(oldValue.value.geometry) !=
            _encodeGeometry(newValue.value.geometry),
        appearance:
            _encodeStyle(oldValue.value.style) !=
            _encodeStyle(newValue.value.style),
        text: false,
        metadata: oldValue.value.unknownFields != newValue.value.unknownFields,
      ),
    );
  }
}

PreservedMap _encodeGeometry(ShapeGeometry geometry) {
  final base = <String, PreservedData>{
    ...geometry.unknownFields.values,
    'kind': PreservedString(geometry.kind.name),
  };
  switch (geometry) {
    case ShapeLineGeometry(:final start, :final end):
      base['start'] = _encodePoint(start);
      base['end'] = _encodePoint(end);
    case ShapeRectangleGeometry(:final localBounds, :final cornerRadius):
      base['bounds'] = _encodeRect(localBounds);
      base['cornerRadius'] = _double(cornerRadius);
    case ShapeEllipseGeometry(:final localBounds):
      base['bounds'] = _encodeRect(localBounds);
    case ShapeVertexGeometry(:final vertices):
      base['vertices'] = PreservedList(vertices.map(_encodePoint));
  }
  return PreservedMap(base);
}

Result<ShapeGeometry, StructuredFailure> _decodeGeometry(
  PreservedData? data,
  ShapeLimits limits,
) {
  if (data is! PreservedMap || data.values['kind'] is! PreservedString) {
    return Err(_failure('invalid_geometry'));
  }
  final kindName = (data.values['kind']! as PreservedString).value;
  final kind = ShapeKind.values
      .where((value) => value.name == kindName)
      .firstOrNull;
  if (kind == null) return Err(_failure('unknown_kind'));
  switch (kind) {
    case ShapeKind.line:
      final start = _decodePoint(data.values['start']);
      final end = _decodePoint(data.values['end']);
      if (start == null || end == null)
        return Err(_failure('invalid_geometry'));
      return ShapeLineGeometry.create(
        start: start,
        end: end,
        limits: limits,
        unknownFields: _unknown(data, const {'kind', 'start', 'end'}),
      );
    case ShapeKind.rectangle:
      final bounds = _decodeRect(data.values['bounds']);
      final radius = _number(data.values['cornerRadius']);
      if (bounds == null || radius == null)
        return Err(_failure('invalid_geometry'));
      return ShapeRectangleGeometry.create(
        bounds: bounds,
        cornerRadius: radius,
        limits: limits,
        unknownFields: _unknown(data, const {'kind', 'bounds', 'cornerRadius'}),
      );
    case ShapeKind.ellipse:
      final bounds = _decodeRect(data.values['bounds']);
      if (bounds == null) return Err(_failure('invalid_geometry'));
      return ShapeEllipseGeometry.create(
        bounds: bounds,
        limits: limits,
        unknownFields: _unknown(data, const {'kind', 'bounds'}),
      );
    case ShapeKind.polygon:
    case ShapeKind.polyline:
      final source = data.values['vertices'];
      if (source is! PreservedList ||
          source.values.length > limits.maximumVertices) {
        return Err(_failure('invalid_geometry'));
      }
      final vertices = <Point2>[];
      for (final value in source.values) {
        final point = _decodePoint(value);
        if (point == null) return Err(_failure('invalid_geometry'));
        vertices.add(point);
      }
      return ShapeVertexGeometry.create(
        kind: kind,
        vertices: vertices,
        limits: limits,
        unknownFields: _unknown(data, const {'kind', 'vertices'}),
      );
  }
}

PreservedMap _encodeStyle(ShapeStyle style) =>
    PreservedMap(<String, PreservedData>{
      ...style.unknownFields.values,
      'strokeEnabled': PreservedBoolean(style.strokeEnabled),
      'strokeColor': _encodeColor(style.strokeColor),
      'strokeWidth': _double(style.strokeWidth),
      'cap': PreservedString(style.cap.name),
      'join': PreservedString(style.join.name),
      'miterLimit': _double(style.miterLimit),
      'dashArray': PreservedList(style.dashArray.map(_double)),
      'dashOffset': _double(style.dashOffset),
      'fillEnabled': PreservedBoolean(style.fillEnabled),
      'fillColor': _encodeColor(style.fillColor),
      'fillRule': PreservedString(style.fillRule.name),
      'opacity': _double(style.opacity),
      'startArrowhead': PreservedString(style.startArrowhead.name),
      'endArrowhead': PreservedString(style.endArrowhead.name),
    });

Result<ShapeStyle, StructuredFailure> _decodeStyle(
  PreservedData? data,
  ShapeLimits limits,
) {
  if (data is! PreservedMap) return Err(_failure('invalid_style'));
  final strokeEnabled = data.values['strokeEnabled'];
  final fillEnabled = data.values['fillEnabled'];
  final strokeColor = _decodeColor(data.values['strokeColor']);
  final fillColor = _decodeColor(data.values['fillColor']);
  final width = _number(data.values['strokeWidth']);
  final miter = _number(data.values['miterLimit']);
  final offset = _number(data.values['dashOffset']);
  final opacity = _number(data.values['opacity']);
  final cap = _enumByName(ShapeStrokeCap.values, data.values['cap']);
  final join = _enumByName(ShapeStrokeJoin.values, data.values['join']);
  final fillRule = _enumByName(ShapeFillRule.values, data.values['fillRule']);
  final start = _enumByName(
    ShapeArrowhead.values,
    data.values['startArrowhead'],
  );
  final end = _enumByName(ShapeArrowhead.values, data.values['endArrowhead']);
  final dashData = data.values['dashArray'];
  if (strokeEnabled is! PreservedBoolean ||
      fillEnabled is! PreservedBoolean ||
      strokeColor == null ||
      fillColor == null ||
      width == null ||
      miter == null ||
      offset == null ||
      opacity == null ||
      cap == null ||
      join == null ||
      fillRule == null ||
      start == null ||
      end == null ||
      dashData is! PreservedList ||
      dashData.values.length > limits.maximumDashValues) {
    return Err(_failure('invalid_style'));
  }
  final dashes = <double>[];
  for (final value in dashData.values) {
    final number = _number(value);
    if (number == null) return Err(_failure('invalid_style'));
    dashes.add(number);
  }
  return ShapeStyle.create(
    strokeEnabled: strokeEnabled.value,
    strokeColor: strokeColor,
    strokeWidth: width,
    cap: cap,
    join: join,
    miterLimit: miter,
    dashArray: dashes,
    dashOffset: offset,
    fillEnabled: fillEnabled.value,
    fillColor: fillColor,
    fillRule: fillRule,
    opacity: opacity,
    startArrowhead: start,
    endArrowhead: end,
    limits: limits,
    unknownFields: _unknown(data, const {
      'strokeEnabled',
      'strokeColor',
      'strokeWidth',
      'cap',
      'join',
      'miterLimit',
      'dashArray',
      'dashOffset',
      'fillEnabled',
      'fillColor',
      'fillRule',
      'opacity',
      'startArrowhead',
      'endArrowhead',
    }),
  );
}

PreservedMap _encodePoint(Point2 point) =>
    PreservedMap({'x': _double(point.x), 'y': _double(point.y)});

Point2? _decodePoint(PreservedData? data) {
  if (data is! PreservedMap) return null;
  final x = _number(data.values['x']), y = _number(data.values['y']);
  if (x == null || y == null) return null;
  return Point2.create(
    x: x,
    y: y,
  ).fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
}

PreservedMap _encodeRect(Rect2 rect) => PreservedMap({
  'left': _double(rect.left),
  'top': _double(rect.top),
  'right': _double(rect.right),
  'bottom': _double(rect.bottom),
});

Rect2? _decodeRect(PreservedData? data) {
  if (data is! PreservedMap) return null;
  final left = _number(data.values['left']), top = _number(data.values['top']);
  final right = _number(data.values['right']),
      bottom = _number(data.values['bottom']);
  if (left == null || top == null || right == null || bottom == null)
    return null;
  return Rect2.fromEdges(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
}

PreservedMap _encodeColor(ShapeColor color) => PreservedMap({
  'r': _integer(color.red),
  'g': _integer(color.green),
  'b': _integer(color.blue),
  'a': _integer(color.alpha),
});

ShapeColor? _decodeColor(PreservedData? data) {
  if (data is! PreservedMap) return null;
  final r = data.values['r'], g = data.values['g'];
  final b = data.values['b'], a = data.values['a'];
  if (r is! PreservedInteger ||
      g is! PreservedInteger ||
      b is! PreservedInteger ||
      a is! PreservedInteger)
    return null;
  return ShapeColor.create(
    red: r.value,
    green: g.value,
    blue: b.value,
    alpha: a.value,
  ).fold<ShapeColor?>(onOk: (value) => value, onErr: (_) => null);
}

T? _enumByName<T extends Enum>(Iterable<T> values, PreservedData? source) {
  if (source is! PreservedString) return null;
  for (final value in values) if (value.name == source.value) return value;
  return null;
}

Result<ShapeGeometry, StructuredFailure> _captureGeometry(
  ShapeGeometry geometry,
  ShapeLimits limits,
) => switch (geometry) {
  ShapeLineGeometry(:final start, :final end, :final unknownFields) =>
    ShapeLineGeometry.create(
      start: start,
      end: end,
      limits: limits,
      unknownFields: unknownFields,
    ),
  ShapeRectangleGeometry(
    :final localBounds,
    :final cornerRadius,
    :final unknownFields,
  ) =>
    ShapeRectangleGeometry.create(
      bounds: localBounds,
      cornerRadius: cornerRadius,
      limits: limits,
      unknownFields: unknownFields,
    ),
  ShapeEllipseGeometry(:final localBounds, :final unknownFields) =>
    ShapeEllipseGeometry.create(
      bounds: localBounds,
      limits: limits,
      unknownFields: unknownFields,
    ),
  ShapeVertexGeometry(:final kind, :final vertices, :final unknownFields) =>
    ShapeVertexGeometry.create(
      kind: kind,
      vertices: vertices,
      limits: limits,
      unknownFields: unknownFields,
    ),
};

Result<ShapeStyle, StructuredFailure> _captureStyle(
  ShapeStyle style,
  ShapeLimits limits,
) => ShapeStyle.create(
  strokeEnabled: style.strokeEnabled,
  strokeColor: style.strokeColor,
  strokeWidth: style.strokeWidth,
  cap: style.cap,
  join: style.join,
  miterLimit: style.miterLimit,
  dashArray: style.dashArray,
  dashOffset: style.dashOffset,
  fillEnabled: style.fillEnabled,
  fillColor: style.fillColor,
  fillRule: style.fillRule,
  opacity: style.opacity,
  startArrowhead: style.startArrowhead,
  endArrowhead: style.endArrowhead,
  limits: limits,
  unknownFields: style.unknownFields,
);

bool _pointAllowed(Point2 point, ShapeLimits limits) =>
    point.x.abs() <= limits.maximumCoordinateMagnitude &&
    point.y.abs() <= limits.maximumCoordinateMagnitude;

bool _rectAllowed(Rect2 rect, ShapeLimits limits) =>
    rect.left.abs() <= limits.maximumCoordinateMagnitude &&
    rect.top.abs() <= limits.maximumCoordinateMagnitude &&
    rect.right.abs() <= limits.maximumCoordinateMagnitude &&
    rect.bottom.abs() <= limits.maximumCoordinateMagnitude;

bool _unknownAllowed(PreservedMap value, ShapeLimits limits) {
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
  final values = <T>[];
  try {
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (values.length >= maximum) return Err(_failure(leaf));
      values.add(iterator.current);
    }
  } on Object {
    return Err(_failure('invalid_iterable'));
  }
  return Ok(List<T>.unmodifiable(values));
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

Rect2 _pointBounds(List<Point2> values) {
  var left = values.first.x, right = left, top = values.first.y, bottom = top;
  for (final point in values.skip(1)) {
    left = math.min(left, point.x);
    right = math.max(right, point.x);
    top = math.min(top, point.y);
    bottom = math.max(bottom, point.y);
  }
  return _rect(left, top, right, bottom);
}

bool _positive(double value) => value.isFinite && value > 0;
bool _nonnegativeFinite(double value) => value.isFinite && value >= 0;

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
    (ObjectTypeKey.parse('alnote.shape')
            as Ok<ObjectTypeKey, StructuredFailure>)
        .value
        .identifier;

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.shape.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Shape data is invalid or unavailable.',
);
