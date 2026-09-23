// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/identity/namespaced_identifier.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/validation/validation_issue.dart';
import '../../core/validation/validation_path.dart';
import '../../core/validation/validation_report.dart';
import '../../core/versioning/schema_version.dart';
import '../model/identifiers.dart';
import '../model/identity_remapping.dart';
import '../model/preserved_data.dart';
import '../objects/object_envelope.dart';
import '../objects/object_registry.dart';
import '../resources/resources.dart';

/// Permanent built-in movable PDF Page Object type key.
final ObjectTypeKey pdfPageObjectTypeKey = ObjectTypeKey.fromIdentifier(
  _trustedTypeIdentifier('alnote.pdf.page'),
);

/// Supported shared PDF page-reference schema.
final SchemaVersion pdfPageReferenceSchemaVersion = _schemaOne();

/// Supported movable PDF Page Object payload schema.
final SchemaVersion pdfPageObjectSchemaVersion = _schemaOne();

/// Canonical immutable source-PDF media type.
final ResourceMediaType pdfResourceMediaType = _trustedMediaType(
  'application/pdf',
);

/// Canonical role for an immutable original PDF resource.
final ResourceRole pdfSourceResourceRole = _trustedResourceRole(
  'alnote.resource.pdf_source',
);

/// Explicit portable ceilings for persistent PDF model data.
final class PdfModelLimits {
  const PdfModelLimits._({
    required this.maximumPageCount,
    required this.maximumCoordinateMagnitude,
    required this.maximumPageDimension,
    required this.maximumPageArea,
    required this.maximumUnknownFields,
    required this.maximumUnknownNodes,
    required this.maximumNestingDepth,
    required this.maximumUnknownStringCodeUnits,
  });

  /// Conservative portable ceilings used while reopening built-in PDF Layers.
  ///
  /// Runtime-specific limits may be tighter. These bounds exist so Storage can
  /// reject malformed built-in Layer data without depending on a PDF backend.
  static const PdfModelLimits portableStorage = PdfModelLimits._(
    maximumPageCount: 10000,
    maximumCoordinateMagnitude: 1000000,
    maximumPageDimension: 1000000,
    maximumPageArea: 1000000000000,
    maximumUnknownFields: 256,
    maximumUnknownNodes: 100000,
    maximumNestingDepth: 32,
    maximumUnknownStringCodeUnits: 1000000,
  );

  /// Creates positive Web-safe and finite model ceilings.
  static Result<PdfModelLimits, StructuredFailure> create({
    required int maximumPageCount,
    required double maximumCoordinateMagnitude,
    required double maximumPageDimension,
    required double maximumPageArea,
    required int maximumUnknownFields,
    required int maximumUnknownNodes,
    required int maximumNestingDepth,
    required int maximumUnknownStringCodeUnits,
  }) {
    final integerValues = <int>[
      maximumPageCount,
      maximumUnknownFields,
      maximumUnknownNodes,
      maximumNestingDepth,
      maximumUnknownStringCodeUnits,
    ];
    if (integerValues.any(
          (value) => value <= 0 || value > maximumWebSafeInteger,
        ) ||
        !maximumCoordinateMagnitude.isFinite ||
        maximumCoordinateMagnitude <= 0 ||
        !maximumPageDimension.isFinite ||
        maximumPageDimension <= 0 ||
        !maximumPageArea.isFinite ||
        maximumPageArea <= 0) {
      return Err<PdfModelLimits, StructuredFailure>(_failure('invalid_limits'));
    }
    return Ok<PdfModelLimits, StructuredFailure>(
      PdfModelLimits._(
        maximumPageCount: maximumPageCount,
        maximumCoordinateMagnitude: maximumCoordinateMagnitude,
        maximumPageDimension: maximumPageDimension,
        maximumPageArea: maximumPageArea,
        maximumUnknownFields: maximumUnknownFields,
        maximumUnknownNodes: maximumUnknownNodes,
        maximumNestingDepth: maximumNestingDepth,
        maximumUnknownStringCodeUnits: maximumUnknownStringCodeUnits,
      ),
    );
  }

  /// Maximum source Pages in one PDF.
  final int maximumPageCount;

  /// Maximum absolute source-user-space coordinate.
  final double maximumCoordinateMagnitude;

  /// Maximum displayed or source-box dimension in PDF points.
  final double maximumPageDimension;

  /// Maximum checked Page area in square PDF points.
  final double maximumPageArea;

  /// Maximum unknown fields at one preserved boundary.
  final int maximumUnknownFields;

  /// Maximum cumulative unknown-data nodes.
  final int maximumUnknownNodes;

  /// Maximum unknown-data nesting depth.
  final int maximumNestingDepth;

  /// Maximum cumulative unknown string code units.
  final int maximumUnknownStringCodeUnits;
}

/// Persisted PDF bounds classification. Resolved bounds carry no raw-box
/// provenance; the named box kinds retain their legacy meaning.
enum PdfPageBoxKind {
  cropBox('cropBox'),
  mediaBox('mediaBox'),
  resolvedBounds('resolvedBounds'),
  trimBox('trimBox'),
  bleedBox('bleedBox'),
  artBox('artBox');

  const PdfPageBoxKind(this.wireName);

  /// Stable serialized name.
  final String wireName;
}

/// Effective normalized clockwise Page rotation.
enum PdfPageRotation {
  degrees0(0),
  degrees90(90),
  degrees180(180),
  degrees270(270);

  const PdfPageRotation(this.degrees);

  /// Stable clockwise degree value.
  final int degrees;

  /// Whether displayed width and height exchange axes.
  bool get swapsDimensions => this == degrees90 || this == degrees270;
}

/// A resolved nonempty PDF box in source user space.
final class PdfSourceBox {
  const PdfSourceBox._({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  /// Creates a bounded, finite, nonempty source box.
  static Result<PdfSourceBox, StructuredFailure> create({
    required double left,
    required double bottom,
    required double right,
    required double top,
    required PdfModelLimits limits,
  }) {
    final coordinates = <double>[left, bottom, right, top];
    if (coordinates.any(
          (value) =>
              !value.isFinite ||
              value.abs() > limits.maximumCoordinateMagnitude,
        ) ||
        right <= left ||
        top <= bottom) {
      return Err<PdfSourceBox, StructuredFailure>(
        _failure('invalid_source_box'),
      );
    }
    final width = right - left;
    final height = top - bottom;
    final area = width * height;
    if (!width.isFinite ||
        !height.isFinite ||
        !area.isFinite ||
        area <= 0 ||
        width > limits.maximumPageDimension ||
        height > limits.maximumPageDimension ||
        area > limits.maximumPageArea) {
      return Err<PdfSourceBox, StructuredFailure>(_failure('source_box_limit'));
    }
    return Ok<PdfSourceBox, StructuredFailure>(
      PdfSourceBox._(left: left, bottom: bottom, right: right, top: top),
    );
  }

  /// Left source-user-space coordinate.
  final double left;

  /// Bottom source-user-space coordinate.
  final double bottom;

  /// Right source-user-space coordinate.
  final double right;

  /// Top source-user-space coordinate.
  final double top;

  /// Source-box width in PDF points.
  double get width => right - left;

  /// Source-box height in PDF points.
  double get height => top - bottom;

  /// Revalidates the complete box under the receiving limit provenance.
  Result<PdfSourceBox, StructuredFailure> validatedFor(PdfModelLimits limits) =>
      PdfSourceBox.create(
        left: left,
        bottom: bottom,
        right: right,
        top: top,
        limits: limits,
      );

  PreservedMap _encode() => PreservedMap(<String, PreservedData>{
    'left': _double(left),
    'bottom': _double(bottom),
    'right': _double(right),
    'top': _double(top),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfSourceBox &&
          other.left == left &&
          other.bottom == bottom &&
          other.right == right &&
          other.top == top;

  @override
  int get hashCode => Object.hash(left, bottom, right, top);

  @override
  String toString() => 'PdfSourceBox(validated: true)';
}

/// A nonempty normalized PDF Page clipping rectangle.
final class PdfPageClip {
  const PdfPageClip._({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// Creates a nonempty clip whose edges lie in `[0, 1]`.
  static Result<PdfPageClip, StructuredFailure> create({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    if (<double>[left, top, right, bottom].any((value) => !value.isFinite) ||
        left < 0 ||
        top < 0 ||
        right > 1 ||
        bottom > 1 ||
        right <= left ||
        bottom <= top) {
      return Err<PdfPageClip, StructuredFailure>(_failure('invalid_clip'));
    }
    return Ok<PdfPageClip, StructuredFailure>(
      PdfPageClip._(left: left, top: top, right: right, bottom: bottom),
    );
  }

  /// Full Page clip.
  static PdfPageClip get full =>
      const PdfPageClip._(left: 0, top: 0, right: 1, bottom: 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  PreservedMap _encode() => PreservedMap(<String, PreservedData>{
    'left': _double(left),
    'top': _double(top),
    'right': _double(right),
    'bottom': _double(bottom),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfPageClip &&
          other.left == left &&
          other.top == top &&
          other.right == right &&
          other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// Immutable, backend-neutral reference to one resolved PDF source Page.
final class PdfPageReference {
  const PdfPageReference._({
    required this.resourceIdentity,
    required this.pageIndex,
    required this.boxKind,
    required this.sourceBox,
    required this.rotation,
    required this.displayedWidth,
    required this.displayedHeight,
    required this.unknownFields,
  });

  /// Creates a schema-1 reference and verifies resolved dimensions.
  static Result<PdfPageReference, StructuredFailure> create({
    required ResourceIdentity resourceIdentity,
    required int pageIndex,
    required PdfPageBoxKind boxKind,
    required PdfSourceBox sourceBox,
    required PdfPageRotation rotation,
    required double displayedWidth,
    required double displayedHeight,
    required PdfModelLimits limits,
    PreservedMap? unknownFields,
  }) {
    final checkedBox = sourceBox.validatedFor(limits);
    if (checkedBox is! Ok<PdfSourceBox, StructuredFailure>) {
      return Err<PdfPageReference, StructuredFailure>(
        _failure('invalid_page_reference'),
      );
    }
    final validatedBox = checkedBox.value;
    final expectedWidth = rotation.swapsDimensions
        ? validatedBox.height
        : validatedBox.width;
    final expectedHeight = rotation.swapsDimensions
        ? validatedBox.width
        : validatedBox.height;
    final areaAllowed = _productWithin(
      displayedWidth,
      displayedHeight,
      limits.maximumPageArea,
    );
    final unknown = unknownFields ?? PreservedMap.empty();
    if (pageIndex < 0 ||
        pageIndex >= limits.maximumPageCount ||
        (boxKind != PdfPageBoxKind.cropBox &&
            boxKind != PdfPageBoxKind.mediaBox &&
            boxKind != PdfPageBoxKind.resolvedBounds) ||
        !displayedWidth.isFinite ||
        !displayedHeight.isFinite ||
        displayedWidth <= 0 ||
        displayedHeight <= 0 ||
        displayedWidth > limits.maximumPageDimension ||
        displayedHeight > limits.maximumPageDimension ||
        !areaAllowed ||
        displayedWidth != expectedWidth ||
        displayedHeight != expectedHeight ||
        _containsAnyKey(unknown, _pageReferenceKeys) ||
        !_unknownAllowed(unknown, limits)) {
      return Err<PdfPageReference, StructuredFailure>(
        _failure('invalid_page_reference'),
      );
    }
    return Ok<PdfPageReference, StructuredFailure>(
      PdfPageReference._(
        resourceIdentity: resourceIdentity,
        pageIndex: pageIndex,
        boxKind: boxKind,
        sourceBox: validatedBox,
        rotation: rotation,
        displayedWidth: displayedWidth,
        displayedHeight: displayedHeight,
        unknownFields: unknown,
      ),
    );
  }

  final ResourceIdentity resourceIdentity;
  final int pageIndex;
  final PdfPageBoxKind boxKind;
  final PdfSourceBox sourceBox;
  final PdfPageRotation rotation;
  final double displayedWidth;
  final double displayedHeight;
  final PreservedMap unknownFields;

  /// Revalidates this reference and every nested value under new limits.
  Result<PdfPageReference, StructuredFailure> validatedFor(
    PdfModelLimits limits,
  ) => PdfPageReference.create(
    resourceIdentity: resourceIdentity,
    pageIndex: pageIndex,
    boxKind: boxKind,
    sourceBox: sourceBox,
    rotation: rotation,
    displayedWidth: displayedWidth,
    displayedHeight: displayedHeight,
    limits: limits,
    unknownFields: unknownFields,
  );

  /// Deterministically encodes the shared reference.
  PreservedMap encode() => PreservedMap(<String, PreservedData>{
    ...unknownFields.values,
    'referenceSchemaVersion': _integer(pdfPageReferenceSchemaVersion.value),
    'resourceId': PreservedString(resourceIdentity.uuid.value),
    'pageIndex': _integer(pageIndex),
    'boxKind': PreservedString(boxKind.wireName),
    'sourceBox': sourceBox._encode(),
    'rotationDegrees': _integer(rotation.degrees),
    'displayedWidth': _double(displayedWidth),
    'displayedHeight': _double(displayedHeight),
  });

  /// Decodes one schema-1 shared reference under explicit limits.
  static Result<PdfPageReference, StructuredFailure> decode(
    PreservedData data, {
    required PdfModelLimits limits,
  }) {
    if (data is! PreservedMap) {
      return Err<PdfPageReference, StructuredFailure>(
        _failure('invalid_page_reference'),
      );
    }
    final version = data.values['referenceSchemaVersion'];
    final resource = data.values['resourceId'];
    final page = data.values['pageIndex'];
    final kind = data.values['boxKind'];
    final box = data.values['sourceBox'];
    final rotationValue = data.values['rotationDegrees'];
    final width = _number(data.values['displayedWidth']);
    final height = _number(data.values['displayedHeight']);
    if (version is! PreservedInteger ||
        version.value != pdfPageReferenceSchemaVersion.value ||
        resource is! PreservedString ||
        page is! PreservedInteger ||
        kind is! PreservedString ||
        box is! PreservedMap ||
        rotationValue is! PreservedInteger ||
        width == null ||
        height == null) {
      return Err<PdfPageReference, StructuredFailure>(
        _failure('invalid_page_reference'),
      );
    }
    final uuid = UuidIdentifier.parse(resource.value);
    final boxKind = PdfPageBoxKind.values
        .where((value) => value.wireName == kind.value)
        .firstOrNull;
    final rotation = PdfPageRotation.values
        .where((value) => value.degrees == rotationValue.value)
        .firstOrNull;
    final sourceBox = PdfSourceBox.create(
      left: _number(box.values['left']) ?? double.nan,
      bottom: _number(box.values['bottom']) ?? double.nan,
      right: _number(box.values['right']) ?? double.nan,
      top: _number(box.values['top']) ?? double.nan,
      limits: limits,
    );
    if (uuid is! Ok<UuidIdentifier, StructuredFailure> ||
        boxKind == null ||
        rotation == null ||
        sourceBox is! Ok<PdfSourceBox, StructuredFailure>) {
      return Err<PdfPageReference, StructuredFailure>(
        _failure('invalid_page_reference'),
      );
    }
    return create(
      resourceIdentity: ResourceIdentity.fromUuid(uuid.value),
      pageIndex: page.value,
      boxKind: boxKind,
      sourceBox: sourceBox.value,
      rotation: rotation,
      displayedWidth: width,
      displayedHeight: height,
      limits: limits,
      unknownFields: _unknown(data, _pageReferenceKeys),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfPageReference &&
          other.resourceIdentity == resourceIdentity &&
          other.pageIndex == pageIndex &&
          other.boxKind == boxKind &&
          other.sourceBox == sourceBox &&
          other.rotation == rotation &&
          other.displayedWidth == displayedWidth &&
          other.displayedHeight == displayedHeight &&
          other.unknownFields == unknownFields;

  @override
  int get hashCode => Object.hash(
    resourceIdentity,
    pageIndex,
    boxKind,
    sourceBox,
    rotation,
    displayedWidth,
    displayedHeight,
    unknownFields,
  );

  @override
  String toString() => 'PdfPageReference(pageIndex: $pageIndex)';
}

const Set<String> _pageReferenceKeys = <String>{
  'referenceSchemaVersion',
  'resourceId',
  'pageIndex',
  'boxKind',
  'sourceBox',
  'rotationDegrees',
  'displayedWidth',
  'displayedHeight',
};

/// Deterministic conversion between PDF bottom-left source space and AL NOTE
/// top-left local space for one persisted Page reference.
final class PdfPageCoordinates {
  const PdfPageCoordinates(this.reference);

  final PdfPageReference reference;

  /// Maps a source-space point into displayed top-left local coordinates.
  Result<Point2, StructuredFailure> sourceToLocal(Point2 source) {
    final box = reference.sourceBox;
    if (source.x < box.left ||
        source.x > box.right ||
        source.y < box.bottom ||
        source.y > box.top) {
      return Err<Point2, StructuredFailure>(_failure('coordinate_outside'));
    }
    final u = source.x - box.left;
    final v = source.y - box.bottom;
    final (x, y) = switch (reference.rotation) {
      PdfPageRotation.degrees0 => (u, box.height - v),
      PdfPageRotation.degrees90 => (v, u),
      PdfPageRotation.degrees180 => (box.width - u, v),
      PdfPageRotation.degrees270 => (box.height - v, box.width - u),
    };
    return _boundedPoint(x, y);
  }

  /// Maps a displayed top-left local point back into PDF source space.
  Result<Point2, StructuredFailure> localToSource(Point2 local) {
    if (local.x < 0 ||
        local.y < 0 ||
        local.x > reference.displayedWidth ||
        local.y > reference.displayedHeight) {
      return Err<Point2, StructuredFailure>(_failure('coordinate_outside'));
    }
    final box = reference.sourceBox;
    final (x, y) = switch (reference.rotation) {
      PdfPageRotation.degrees0 => (box.left + local.x, box.top - local.y),
      PdfPageRotation.degrees90 => (box.left + local.y, box.bottom + local.x),
      PdfPageRotation.degrees180 => (box.right - local.x, box.bottom + local.y),
      PdfPageRotation.degrees270 => (box.right - local.y, box.top - local.x),
    };
    return _boundedPoint(x, y);
  }

  /// Maps a source rectangle to its displayed axis-aligned local rectangle.
  Result<Rect2, StructuredFailure> sourceRectToLocal(Rect2 source) =>
      _mapRectangle(source, sourceToLocal);

  /// Maps a displayed local rectangle to its source-space bounding rectangle.
  Result<Rect2, StructuredFailure> localRectToSource(Rect2 local) =>
      _mapRectangle(local, localToSource);

  /// Resolves normalized clipping to a local rectangle with a top-left origin.
  Result<Rect2, StructuredFailure> clipToLocalRect(PdfPageClip clip) {
    final left = reference.displayedWidth * clip.left;
    final top = reference.displayedHeight * clip.top;
    final right = reference.displayedWidth * clip.right;
    final bottom = reference.displayedHeight * clip.bottom;
    if (<double>[left, top, right, bottom].any((value) => !value.isFinite)) {
      return Err<Rect2, StructuredFailure>(_failure('coordinate_overflow'));
    }
    return Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom);
  }

  Result<Rect2, StructuredFailure> _mapRectangle(
    Rect2 rectangle,
    Result<Point2, StructuredFailure> Function(Point2) mapper,
  ) {
    final corners = <Point2>[
      _point(rectangle.left, rectangle.top),
      _point(rectangle.right, rectangle.top),
      _point(rectangle.right, rectangle.bottom),
      _point(rectangle.left, rectangle.bottom),
    ];
    final mapped = <Point2>[];
    for (final corner in corners) {
      final result = mapper(corner);
      if (result is! Ok<Point2, StructuredFailure>) {
        return Err<Rect2, StructuredFailure>(_failure('coordinate_outside'));
      }
      mapped.add(result.value);
    }
    final xs = mapped.map((value) => value.x);
    final ys = mapped.map((value) => value.y);
    return Rect2.fromEdges(
      left: xs.reduce((left, right) => left < right ? left : right),
      top: ys.reduce((left, right) => left < right ? left : right),
      right: xs.reduce((left, right) => left > right ? left : right),
      bottom: ys.reduce((left, right) => left > right ? left : right),
    );
  }

  Result<Point2, StructuredFailure> _boundedPoint(double x, double y) =>
      x.isFinite && y.isFinite
      ? Point2.create(x: x, y: y)
      : Err<Point2, StructuredFailure>(_failure('coordinate_overflow'));

  Point2 _point(double x, double y) =>
      (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;

  @override
  String toString() => 'PdfPageCoordinates(validated: true)';
}

/// Immutable schema-1 movable PDF Page Object payload.
final class PdfPageObjectPayload {
  const PdfPageObjectPayload._({
    required this.reference,
    required this.clip,
    required this.unknownFields,
  });

  /// Creates one validated movable PDF Page payload.
  static Result<PdfPageObjectPayload, StructuredFailure> create({
    required PdfPageReference reference,
    required PdfPageClip clip,
    required PdfModelLimits limits,
    PreservedMap? unknownFields,
  }) {
    final checkedReference = reference.validatedFor(limits);
    if (checkedReference is! Ok<PdfPageReference, StructuredFailure>) {
      return Err<PdfPageObjectPayload, StructuredFailure>(
        _failure('invalid_object_payload'),
      );
    }
    final validatedReference = checkedReference.value;
    final unknown = unknownFields ?? PreservedMap.empty();
    final width = validatedReference.displayedWidth * clip.width;
    final height = validatedReference.displayedHeight * clip.height;
    final areaAllowed = _productWithin(width, height, limits.maximumPageArea);
    if (!width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0 ||
        width > limits.maximumPageDimension ||
        height > limits.maximumPageDimension ||
        !areaAllowed ||
        _containsAnyKey(unknown, _pageObjectKeys) ||
        !_unknownAllowed(unknown, limits)) {
      return Err<PdfPageObjectPayload, StructuredFailure>(
        _failure('invalid_object_payload'),
      );
    }
    return Ok<PdfPageObjectPayload, StructuredFailure>(
      PdfPageObjectPayload._(
        reference: validatedReference,
        clip: clip,
        unknownFields: unknown,
      ),
    );
  }

  final PdfPageReference reference;
  final PdfPageClip clip;
  final PreservedMap unknownFields;

  /// Local displayed bounds before the common Object transform.
  Rect2 get bounds => _rect(
    0,
    0,
    reference.displayedWidth * clip.width,
    reference.displayedHeight * clip.height,
  );

  /// Deterministically encodes the payload.
  PreservedMap encode() => PreservedMap(<String, PreservedData>{
    ...unknownFields.values,
    'reference': reference.encode(),
    'clip': clip._encode(),
  });

  /// Decodes a schema-1 payload under explicit limits.
  static Result<PdfPageObjectPayload, StructuredFailure> decode(
    PreservedData data, {
    required PdfModelLimits limits,
  }) {
    if (data is! PreservedMap) {
      return Err<PdfPageObjectPayload, StructuredFailure>(
        _failure('invalid_object_payload'),
      );
    }
    final reference = PdfPageReference.decode(
      data.values['reference'] ?? const PreservedNull(),
      limits: limits,
    );
    final clipData = data.values['clip'];
    if (reference is! Ok<PdfPageReference, StructuredFailure> ||
        clipData is! PreservedMap) {
      return Err<PdfPageObjectPayload, StructuredFailure>(
        _failure('invalid_object_payload'),
      );
    }
    final clip = PdfPageClip.create(
      left: _number(clipData.values['left']) ?? double.nan,
      top: _number(clipData.values['top']) ?? double.nan,
      right: _number(clipData.values['right']) ?? double.nan,
      bottom: _number(clipData.values['bottom']) ?? double.nan,
    );
    if (clip is! Ok<PdfPageClip, StructuredFailure>) {
      return Err<PdfPageObjectPayload, StructuredFailure>(
        _failure('invalid_object_payload'),
      );
    }
    return create(
      reference: reference.value,
      clip: clip.value,
      limits: limits,
      unknownFields: _unknown(data, _pageObjectKeys),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfPageObjectPayload &&
          other.reference == reference &&
          other.clip == clip &&
          other.unknownFields == unknownFields;

  @override
  int get hashCode => Object.hash(reference, clip, unknownFields);

  @override
  String toString() => 'PdfPageObjectPayload(validated: true)';
}

const Set<String> _pageObjectKeys = <String>{'reference', 'clip'};

/// Registry definition for `alnote.pdf.page` schema 1.
final class PdfPageObjectTypeDefinition
    implements ObjectTypeDefinition, ObjectPayloadChangeClassifier {
  /// Creates a definition with explicit PDF model ceilings.
  const PdfPageObjectTypeDefinition(this.limits);

  final PdfModelLimits limits;

  @override
  ObjectTypeKey get typeKey => pdfPageObjectTypeKey;

  @override
  List<SchemaVersion> get supportedSchemaVersions =>
      List<SchemaVersion>.unmodifiable(<SchemaVersion>[
        pdfPageObjectSchemaVersion,
      ]);

  @override
  ObjectTypeCapabilities get capabilities => const ObjectTypeCapabilities(
    hasIntrinsicGeometry: true,
    discoversResourceReferences: true,
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
      schemaVersion == pdfPageObjectSchemaVersion &&
          PdfPageObjectPayload.decode(payload, limits: limits) is Ok
      ? ValidationReport(const <ValidationIssue>[])
      : ValidationReport(<ValidationIssue>[_invalidIssue()]);

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => schemaVersion != pdfPageObjectSchemaVersion
      ? Err<Rect2, StructuredFailure>(_failure('unsupported_schema'))
      : PdfPageObjectPayload.decode(
          payload,
          limits: limits,
        ).map((value) => value.bounds);

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => schemaVersion != pdfPageObjectSchemaVersion
      ? Err<List<ResourceReference>, StructuredFailure>(
          _failure('unsupported_schema'),
        )
      : PdfPageObjectPayload.decode(payload, limits: limits).map(
          (value) => List<ResourceReference>.unmodifiable(<ResourceReference>[
            ResourceReference(value.reference.resourceIdentity),
          ]),
        );

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => schemaVersion != pdfPageObjectSchemaVersion
      ? Err<PreservedData, StructuredFailure>(_failure('unsupported_schema'))
      : PdfPageObjectPayload.decode(
          payload,
          limits: limits,
        ).map((value) => value.encode());

  @override
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != pdfPageObjectSchemaVersion) {
      return Err<ObjectPayloadChangeSemantics, StructuredFailure>(
        _failure('unsupported_schema'),
      );
    }
    final oldValue = PdfPageObjectPayload.decode(before, limits: limits);
    final newValue = PdfPageObjectPayload.decode(after, limits: limits);
    if (oldValue is! Ok<PdfPageObjectPayload, StructuredFailure> ||
        newValue is! Ok<PdfPageObjectPayload, StructuredFailure>) {
      return Err<ObjectPayloadChangeSemantics, StructuredFailure>(
        _failure('invalid_object_payload'),
      );
    }
    final prior = oldValue.value;
    final next = newValue.value;
    return Ok<ObjectPayloadChangeSemantics, StructuredFailure>(
      ObjectPayloadChangeSemantics(
        geometry:
            prior.reference.displayedWidth != next.reference.displayedWidth ||
            prior.reference.displayedHeight != next.reference.displayedHeight ||
            prior.clip != next.clip,
        appearance: prior.reference != next.reference,
        text: false,
        metadata: prior.unknownFields != next.unknownFields,
      ),
    );
  }
}

bool _unknownAllowed(PreservedMap value, PdfModelLimits limits) =>
    preservedUnknownDataAllowed(
      root: value,
      maximumFieldsPerBoundary: limits.maximumUnknownFields,
      maximumNodes: limits.maximumUnknownNodes,
      maximumDepth: limits.maximumNestingDepth,
      maximumStringCodeUnits: limits.maximumUnknownStringCodeUnits,
    );

bool _containsAnyKey(PreservedMap value, Set<String> reserved) {
  try {
    return value.values.keys.any(reserved.contains);
  } on Object {
    return true;
  }
}

bool _productWithin(double left, double right, double maximum) {
  if (!left.isFinite ||
      !right.isFinite ||
      !maximum.isFinite ||
      left <= 0 ||
      right <= 0 ||
      maximum <= 0) {
    return false;
  }
  return left <= maximum / right;
}

PreservedMap _unknown(PreservedMap map, Set<String> known) =>
    PreservedMap(<String, PreservedData>{
      for (final entry in map.values.entries)
        if (!known.contains(entry.key)) entry.key: entry.value,
    });

double? _number(PreservedData? value) => switch (value) {
  PreservedDouble(:final value) => value,
  PreservedInteger(:final value) => value.toDouble(),
  _ => null,
};

PreservedInteger _integer(int value) => (PreservedInteger.create(
  value,
) as Ok<PreservedInteger, StructuredFailure>).value;

PreservedDouble _double(double value) => (PreservedDouble.create(
  value,
) as Ok<PreservedDouble, StructuredFailure>).value;

Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    ) as Ok<Rect2, StructuredFailure>).value;

NamespacedIdentifier _trustedTypeIdentifier(String value) =>
    (NamespacedIdentifier.parse(
      value,
    ) as Ok<NamespacedIdentifier, StructuredFailure>).value;

ResourceMediaType _trustedMediaType(String value) => (ResourceMediaType.parse(
  value,
) as Ok<ResourceMediaType, StructuredFailure>).value;

ResourceRole _trustedResourceRole(String value) =>
    (ResourceRole.parse(value) as Ok<ResourceRole, StructuredFailure>).value;

SchemaVersion _schemaOne() =>
    (SchemaVersion.create(1) as Ok<SchemaVersion, StructuredFailure>).value;

ValidationIssue _invalidIssue() =>
    ValidationIssue.create(
      code: ValidationIssueCode.invalid,
      severity: ValidationSeverity.error,
      path:
          ValidationPath.fromSegments(const <ValidationPathSegment>[
            ValidationPathSegment.input,
            ValidationPathSegment.payload,
          ]).fold(
            onOk: (value) => value,
            onErr: (_) => throw StateError('Invalid trusted validation path.'),
          ),
    ).fold(
      onOk: (value) => value,
      onErr: (_) => throw StateError('Invalid trusted validation issue.'),
    );

StructuredFailure _failure(String suffix) => StructuredFailure(
  code: 'documents.pdf.$suffix',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'PDF data does not satisfy the required bounded contract.',
);
