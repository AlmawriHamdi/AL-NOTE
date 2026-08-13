// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../../core/geometry/geometry_values.dart';
import '../../../core/identity/namespaced_identifier.dart';
import '../../../core/identity/uuid_identifier.dart';
import '../../../core/outcomes/cancellation.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../../core/validation/validation_issue.dart';
import '../../../core/validation/validation_path.dart';
import '../../../core/validation/validation_report.dart';
import '../../../core/versioning/revision.dart';
import '../../../core/versioning/schema_version.dart';
import '../../model/identifiers.dart';
import '../../model/identity_remapping.dart';
import '../../model/preserved_data.dart';
import '../../resources/resources.dart';
import '../object_envelope.dart';
import '../object_registry.dart';

/// Permanent built-in Image Object type key.
final ObjectTypeKey imageObjectTypeKey = ObjectTypeKey.fromIdentifier(
  _trustedTypeIdentifier(),
);

/// Supported built-in Image payload schema.
final SchemaVersion imageSchemaVersion = _schemaOne();

/// Supported encoded image formats.
enum ImageFormat { png, jpeg }

/// Eight explicit EXIF-compatible source-orientation cases.
enum ImageOrientation {
  normal(1, false),
  mirrorHorizontal(2, false),
  rotate180(3, false),
  mirrorVertical(4, false),
  mirrorHorizontalRotate270(5, true),
  rotate90(6, true),
  mirrorHorizontalRotate90(7, true),
  rotate270(8, true);

  const ImageOrientation(this.exifValue, this.swapsDimensions);

  /// EXIF orientation integer.
  final int exifValue;

  /// Whether oriented width and height exchange axes.
  final bool swapsDimensions;
}

/// Portable rendering intent without engine types.
enum ImageRenderingIntent { auto, crispEdges, smooth }

/// Explicit image ingestion, metadata, and decode ceilings.
final class ImageLimits {
  const ImageLimits._({
    required this.maximumEncodedBytes,
    required this.maximumHeaderBytes,
    required this.maximumMarkers,
    required this.maximumPixelDimension,
    required this.maximumPixelCount,
    required this.maximumAlternativeTextScalars,
    required this.maximumUnknownFields,
    required this.maximumUnknownNodes,
    required this.maximumNestingDepth,
    required this.maximumUnknownStringCodeUnits,
    required this.maximumDocumentDimension,
  });

  /// Creates positive Web-safe image ceilings.
  static Result<ImageLimits, StructuredFailure> create({
    required int maximumEncodedBytes,
    required int maximumHeaderBytes,
    required int maximumMarkers,
    required int maximumPixelDimension,
    required int maximumPixelCount,
    required int maximumAlternativeTextScalars,
    required int maximumUnknownFields,
    required int maximumUnknownNodes,
    required int maximumNestingDepth,
    required int maximumUnknownStringCodeUnits,
    required double maximumDocumentDimension,
  }) {
    final values = <int>[
      maximumEncodedBytes,
      maximumHeaderBytes,
      maximumMarkers,
      maximumPixelDimension,
      maximumPixelCount,
      maximumAlternativeTextScalars,
      maximumUnknownFields,
      maximumUnknownNodes,
      maximumNestingDepth,
      maximumUnknownStringCodeUnits,
    ];
    if (values.any((value) => value < 0 || value > maximumWebSafeInteger) ||
        maximumEncodedBytes == 0 ||
        maximumHeaderBytes < 33 ||
        maximumHeaderBytes > maximumEncodedBytes ||
        maximumMarkers == 0 ||
        maximumPixelDimension == 0 ||
        maximumPixelCount == 0 ||
        maximumUnknownNodes == 0 ||
        maximumNestingDepth == 0 ||
        maximumUnknownStringCodeUnits == 0 ||
        !maximumDocumentDimension.isFinite ||
        maximumDocumentDimension <= 0) {
      return Err(_failure('invalid_limits'));
    }
    return Ok(
      ImageLimits._(
        maximumEncodedBytes: maximumEncodedBytes,
        maximumHeaderBytes: maximumHeaderBytes,
        maximumMarkers: maximumMarkers,
        maximumPixelDimension: maximumPixelDimension,
        maximumPixelCount: maximumPixelCount,
        maximumAlternativeTextScalars: maximumAlternativeTextScalars,
        maximumUnknownFields: maximumUnknownFields,
        maximumUnknownNodes: maximumUnknownNodes,
        maximumNestingDepth: maximumNestingDepth,
        maximumUnknownStringCodeUnits: maximumUnknownStringCodeUnits,
        maximumDocumentDimension: maximumDocumentDimension,
      ),
    );
  }

  /// Maximum caller-supplied encoded bytes.
  final int maximumEncodedBytes;

  /// Maximum bytes inspected by preflight.
  final int maximumHeaderBytes;

  /// Maximum JPEG markers visited.
  final int maximumMarkers;

  /// Maximum encoded width or height.
  final int maximumPixelDimension;

  /// Maximum checked width multiplied by height.
  final int maximumPixelCount;

  /// Maximum Unicode scalar values in alternative text.
  final int maximumAlternativeTextScalars;

  /// Maximum unknown fields at one boundary.
  final int maximumUnknownFields;

  /// Maximum unknown-data nodes.
  final int maximumUnknownNodes;

  /// Maximum unknown-data nesting depth.
  final int maximumNestingDepth;

  /// Maximum cumulative UTF-16 code units in unknown keys and strings.
  final int maximumUnknownStringCodeUnits;

  /// Maximum oriented intrinsic document dimension.
  final double maximumDocumentDimension;
}

/// Immutable normalized crop rectangle in oriented-source coordinates.
final class ImageCropRect {
  const ImageCropRect._(this.left, this.top, this.right, this.bottom);

  /// Creates a nonempty crop whose edges lie in `[0, 1]`.
  static Result<ImageCropRect, StructuredFailure> create({
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
      return Err(_failure('invalid_crop'));
    }
    return Ok(ImageCropRect._(left, top, right, bottom));
  }

  /// Full-source crop.
  static ImageCropRect get full => const ImageCropRect._(0, 0, 1, 1);

  /// Normalized left edge.
  final double left;

  /// Normalized top edge.
  final double top;

  /// Normalized right edge.
  final double right;

  /// Normalized bottom edge.
  final double bottom;

  /// Normalized crop width.
  double get width => right - left;

  /// Normalized crop height.
  double get height => bottom - top;
}

/// Immutable schema-1 Image Object payload.
final class ImagePayload {
  const ImagePayload._({
    required this.resourceIdentity,
    required this.encodedPixelWidth,
    required this.encodedPixelHeight,
    required this.intrinsicWidth,
    required this.intrinsicHeight,
    required this.orientation,
    required this.crop,
    required this.renderingIntent,
    required this.alternativeText,
    required this.unknownFields,
  });

  /// Creates a validated persistent Image payload.
  static Result<ImagePayload, StructuredFailure> create({
    required ResourceIdentity resourceIdentity,
    required int encodedPixelWidth,
    required int encodedPixelHeight,
    required double intrinsicWidth,
    required double intrinsicHeight,
    required ImageOrientation orientation,
    required ImageCropRect crop,
    required ImageRenderingIntent renderingIntent,
    required ImageLimits limits,
    String? alternativeText,
    PreservedMap? unknownFields,
  }) {
    final pixels = _checkedProduct(encodedPixelWidth, encodedPixelHeight);
    final unknown = unknownFields ?? PreservedMap.empty();
    if (encodedPixelWidth <= 0 ||
        encodedPixelHeight <= 0 ||
        encodedPixelWidth > limits.maximumPixelDimension ||
        encodedPixelHeight > limits.maximumPixelDimension ||
        pixels == null ||
        pixels > limits.maximumPixelCount ||
        !intrinsicWidth.isFinite ||
        !intrinsicHeight.isFinite ||
        intrinsicWidth <= 0 ||
        intrinsicHeight <= 0 ||
        intrinsicWidth > limits.maximumDocumentDimension ||
        intrinsicHeight > limits.maximumDocumentDimension ||
        (alternativeText != null &&
            (_containsUnpairedSurrogate(alternativeText) ||
                alternativeText.runes.length >
                    limits.maximumAlternativeTextScalars)) ||
        !_unknownAllowed(unknown, limits)) {
      return Err(_failure('invalid_payload'));
    }
    return Ok(
      ImagePayload._(
        resourceIdentity: resourceIdentity,
        encodedPixelWidth: encodedPixelWidth,
        encodedPixelHeight: encodedPixelHeight,
        intrinsicWidth: intrinsicWidth,
        intrinsicHeight: intrinsicHeight,
        orientation: orientation,
        crop: crop,
        renderingIntent: renderingIntent,
        alternativeText: alternativeText,
        unknownFields: unknown,
      ),
    );
  }

  /// Immutable generic document resource identity.
  final ResourceIdentity resourceIdentity;

  /// Verified encoded pixel width.
  final int encodedPixelWidth;

  /// Verified encoded pixel height.
  final int encodedPixelHeight;

  /// Oriented intrinsic document width.
  final double intrinsicWidth;

  /// Oriented intrinsic document height.
  final double intrinsicHeight;

  /// Display orientation applied exactly once.
  final ImageOrientation orientation;

  /// Nondestructive normalized oriented-source crop.
  final ImageCropRect crop;

  /// Rendering intent.
  final ImageRenderingIntent renderingIntent;

  /// Optional bounded user-authored alternative text.
  final String? alternativeText;

  /// Preserved safe unknown fields.
  final PreservedMap unknownFields;

  /// Local displayed bounds after crop, before common transform.
  Rect2 get bounds =>
      _rect(0, 0, intrinsicWidth * crop.width, intrinsicHeight * crop.height);

  /// Redaction-safe accessibility projection.
  String? get accessibilityAlternativeText => alternativeText;

  /// Encodes deterministically with exact unknown-field restoration.
  PreservedMap encode() => PreservedMap(<String, PreservedData>{
    ...unknownFields.values,
    'resourceId': PreservedString(resourceIdentity.uuid.value),
    'encodedPixelWidth': _integer(encodedPixelWidth),
    'encodedPixelHeight': _integer(encodedPixelHeight),
    'intrinsicWidth': _double(intrinsicWidth),
    'intrinsicHeight': _double(intrinsicHeight),
    'orientation': _integer(orientation.exifValue),
    'crop': PreservedMap({
      'left': _double(crop.left),
      'top': _double(crop.top),
      'right': _double(crop.right),
      'bottom': _double(crop.bottom),
    }),
    'renderingIntent': PreservedString(renderingIntent.name),
    if (alternativeText != null)
      'alternativeText': PreservedString(alternativeText!),
  });

  /// Decodes schema-1 preserved data using explicit limits.
  static Result<ImagePayload, StructuredFailure> decode(
    PreservedData data, {
    required ImageLimits limits,
  }) {
    if (data is! PreservedMap) return Err(_failure('invalid_payload'));
    final idValue = data.values['resourceId'];
    final widthValue = data.values['encodedPixelWidth'];
    final heightValue = data.values['encodedPixelHeight'];
    final intrinsicWidth = _number(data.values['intrinsicWidth']);
    final intrinsicHeight = _number(data.values['intrinsicHeight']);
    final orientationValue = data.values['orientation'];
    final intentValue = data.values['renderingIntent'];
    final altValue = data.values['alternativeText'];
    final cropValue = data.values['crop'];
    if (idValue is! PreservedString ||
        widthValue is! PreservedInteger ||
        heightValue is! PreservedInteger ||
        intrinsicWidth == null ||
        intrinsicHeight == null ||
        orientationValue is! PreservedInteger ||
        intentValue is! PreservedString ||
        altValue != null && altValue is! PreservedString ||
        cropValue is! PreservedMap) {
      return Err(_failure('invalid_payload'));
    }
    final uuid = UuidIdentifier.parse(idValue.value);
    final orientation = ImageOrientation.values
        .where((value) => value.exifValue == orientationValue.value)
        .firstOrNull;
    final intent = ImageRenderingIntent.values
        .where((value) => value.name == intentValue.value)
        .firstOrNull;
    final crop = ImageCropRect.create(
      left: _number(cropValue.values['left']) ?? double.nan,
      top: _number(cropValue.values['top']) ?? double.nan,
      right: _number(cropValue.values['right']) ?? double.nan,
      bottom: _number(cropValue.values['bottom']) ?? double.nan,
    );
    if (uuid is! Ok<UuidIdentifier, StructuredFailure> ||
        orientation == null ||
        intent == null ||
        crop is! Ok<ImageCropRect, StructuredFailure>) {
      return Err(_failure('invalid_payload'));
    }
    return create(
      resourceIdentity: ResourceIdentity.fromUuid(uuid.value),
      encodedPixelWidth: widthValue.value,
      encodedPixelHeight: heightValue.value,
      intrinsicWidth: intrinsicWidth,
      intrinsicHeight: intrinsicHeight,
      orientation: orientation,
      crop: crop.value,
      renderingIntent: intent,
      alternativeText: (altValue as PreservedString?)?.value,
      limits: limits,
      unknownFields: _unknown(data, const {
        'resourceId',
        'encodedPixelWidth',
        'encodedPixelHeight',
        'intrinsicWidth',
        'intrinsicHeight',
        'orientation',
        'crop',
        'renderingIntent',
        'alternativeText',
      }),
    );
  }
}

/// Built-in Registry definition for `alnote.image` schema 1.
final class ImageObjectTypeDefinition
    implements ObjectTypeDefinition, ObjectPayloadChangeClassifier {
  /// Creates a definition with explicit image limits.
  const ImageObjectTypeDefinition(this.limits);

  /// Image validation ceilings.
  final ImageLimits limits;

  @override
  ObjectTypeKey get typeKey => imageObjectTypeKey;
  @override
  List<SchemaVersion> get supportedSchemaVersions =>
      List<SchemaVersion>.unmodifiable([imageSchemaVersion]);
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
      schemaVersion == imageSchemaVersion &&
          ImagePayload.decode(payload, limits: limits) is Ok
      ? ValidationReport(const [])
      : ValidationReport([_invalidIssue()]);

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => schemaVersion != imageSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : ImagePayload.decode(
          payload,
          limits: limits,
        ).map((value) => value.bounds);

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => schemaVersion != imageSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : ImagePayload.decode(payload, limits: limits).map(
          (value) => List<ResourceReference>.unmodifiable([
            ResourceReference(value.resourceIdentity),
          ]),
        );

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => schemaVersion != imageSchemaVersion
      ? Err(_failure('unsupported_schema'))
      : ImagePayload.decode(
          payload,
          limits: limits,
        ).map((value) => value.encode());

  @override
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    if (schemaVersion != imageSchemaVersion)
      return Err(_failure('unsupported_schema'));
    final oldValue = ImagePayload.decode(before, limits: limits);
    final newValue = ImagePayload.decode(after, limits: limits);
    if (oldValue is! Ok<ImagePayload, StructuredFailure> ||
        newValue is! Ok<ImagePayload, StructuredFailure>)
      return Err(_failure('invalid_payload'));
    final a = oldValue.value, b = newValue.value;
    return Ok(
      ObjectPayloadChangeSemantics(
        geometry:
            a.intrinsicWidth != b.intrinsicWidth ||
            a.intrinsicHeight != b.intrinsicHeight ||
            !_sameCrop(a.crop, b.crop),
        appearance:
            a.resourceIdentity != b.resourceIdentity ||
            a.orientation != b.orientation ||
            a.renderingIntent != b.renderingIntent,
        text: a.alternativeText != b.alternativeText,
        metadata: a.unknownFields != b.unknownFields,
      ),
    );
  }
}

/// Safe bounded header-preflight result; no pixels are decoded.
final class ImagePreflightResult {
  const ImagePreflightResult({
    required this.format,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.orientation,
    required this.horizontalDpi,
    required this.verticalDpi,
  });

  /// Detected encoded format.
  final ImageFormat format;

  /// Verified encoded width.
  final int pixelWidth;

  /// Verified encoded height.
  final int pixelHeight;

  /// Bounded metadata orientation or normal.
  final ImageOrientation orientation;

  /// Trustworthy positive bounded horizontal resolution, if present.
  final double? horizontalDpi;

  /// Trustworthy positive bounded vertical resolution, if present.
  final double? verticalDpi;
}

/// Bounded PNG/JPEG header and metadata preflight that never decodes pixels.
final class ImageHeaderPreflight {
  /// Creates a preflight with explicit limits.
  const ImageHeaderPreflight(this.limits);

  /// Preflight ceilings.
  final ImageLimits limits;

  /// Validates bytes, declared MIME, dimensions, and bounded metadata.
  Result<ImagePreflightResult, StructuredFailure> inspect({
    required Iterable<int> encodedBytes,
    required ResourceMediaType mediaType,
  }) {
    final captured = _captureBytes(encodedBytes, limits.maximumEncodedBytes);
    if (captured is! Ok<List<int>, StructuredFailure>)
      return Err(_failure('invalid_bytes'));
    final bytes = captured.value;
    if (_isPng(bytes)) {
      if (mediaType.value != 'image/png')
        return Err(_failure('format_mismatch'));
      return _png(bytes);
    }
    if (_isJpeg(bytes)) {
      if (mediaType.value != 'image/jpeg')
        return Err(_failure('format_mismatch'));
      return _jpeg(bytes);
    }
    return Err(_failure('unsupported_format'));
  }

  Result<ImagePreflightResult, StructuredFailure> _png(List<int> bytes) {
    if (bytes.length < 33 ||
        _u32be(bytes, 8) != 13 ||
        _ascii(bytes, 12, 16) != 'IHDR' ||
        bytes[24] != 8 ||
        !const <int>{0, 2, 3, 4, 6}.contains(bytes[25]) ||
        bytes[26] != 0 ||
        bytes[27] != 0 ||
        bytes[28] > 1 ||
        _u32be(bytes, 29) != _crc32(bytes, 12, 29)) {
      return Err(_failure('malformed_header'));
    }
    final width = _u32be(bytes, 16), height = _u32be(bytes, 20);
    if (!_dimensionsAllowed(width, height, limits))
      return Err(_failure('image_limit'));
    double? xDpi, yDpi;
    var offset = 33, visited = 1;
    while (offset < bytes.length && offset < limits.maximumHeaderBytes) {
      if (++visited > limits.maximumMarkers)
        return Err(_failure('metadata_limit'));
      if (offset + 8 > bytes.length) return Err(_failure('malformed_header'));
      final length = _u32be(bytes, offset);
      if (length > limits.maximumHeaderBytes ||
          length > maximumWebSafeInteger - offset - 12 ||
          offset + 12 + length > bytes.length) {
        return Err(_failure('malformed_header'));
      }
      if (offset + 12 + length > limits.maximumHeaderBytes) {
        return Err(_failure('metadata_limit'));
      }
      final type = _ascii(bytes, offset + 4, offset + 8);
      if (_u32be(bytes, offset + 8 + length) !=
          _crc32(bytes, offset + 4, offset + 8 + length)) {
        return Err(_failure('malformed_header'));
      }
      if (type == 'pHYs' && length == 9 && bytes[offset + 16] == 1) {
        final x = _u32be(bytes, offset + 8), y = _u32be(bytes, offset + 12);
        if (x > 0 && y > 0) {
          xDpi = x * 0.0254;
          yDpi = y * 0.0254;
        }
      }
      if (type == 'IDAT' || type == 'IEND') break;
      offset += length + 12;
    }
    return Ok(
      ImagePreflightResult(
        format: ImageFormat.png,
        pixelWidth: width,
        pixelHeight: height,
        orientation: ImageOrientation.normal,
        horizontalDpi: xDpi,
        verticalDpi: yDpi,
      ),
    );
  }

  Result<ImagePreflightResult, StructuredFailure> _jpeg(List<int> bytes) {
    var offset = 2, markers = 0, orientation = ImageOrientation.normal;
    int? width, height;
    double? xDpi, yDpi;
    while (offset < bytes.length && offset < limits.maximumHeaderBytes) {
      if (++markers > limits.maximumMarkers)
        return Err(_failure('metadata_limit'));
      if (bytes[offset] != 0xff) return Err(_failure('malformed_header'));
      while (offset < bytes.length && bytes[offset] == 0xff) offset += 1;
      if (offset >= bytes.length) return Err(_failure('malformed_header'));
      final marker = bytes[offset++];
      if (marker == 0xd9) break;
      if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd7) continue;
      if (offset + 2 > bytes.length) return Err(_failure('malformed_header'));
      final length = _u16be(bytes, offset);
      if (length < 2 ||
          length > limits.maximumHeaderBytes ||
          offset + length > bytes.length ||
          offset + length > limits.maximumHeaderBytes) {
        return Err(_failure('malformed_header'));
      }
      final payload = offset + 2;
      if (_isSof(marker)) {
        if (length < 11) return Err(_failure('malformed_header'));
        final components = bytes[payload + 5];
        if (components == 0 || components > 4 || length != 8 + components * 3) {
          return Err(_failure('malformed_header'));
        }
        final nextHeight = _u16be(bytes, payload + 1);
        final nextWidth = _u16be(bytes, payload + 3);
        if (width != null && (width != nextWidth || height != nextHeight)) {
          return Err(_failure('malformed_header'));
        }
        height = nextHeight;
        width = nextWidth;
      } else if (marker == 0xe0 &&
          length >= 7 &&
          _ascii(bytes, payload, payload + 5) == 'JFIF\u0000') {
        if (length < 16) return Err(_failure('malformed_header'));
        final unit = bytes[payload + 7],
            x = _u16be(bytes, payload + 8),
            y = _u16be(bytes, payload + 10);
        if (x > 0 && y > 0 && (unit == 1 || unit == 2)) {
          final factor = unit == 1 ? 1.0 : 2.54;
          xDpi = x * factor;
          yDpi = y * factor;
        }
      } else if (marker == 0xe1 &&
          length >= 8 &&
          _ascii(bytes, payload, payload + 6) == 'Exif\u0000\u0000') {
        final parsed = _exifOrientation(bytes, payload + 6, offset + length);
        if (parsed is! Ok<ImageOrientation?, StructuredFailure>) {
          return Err(_failure('malformed_header'));
        }
        orientation = parsed.value ?? orientation;
      }
      offset += length;
      if (marker == 0xda) break;
    }
    if (width == null ||
        height == null ||
        !_dimensionsAllowed(width, height, limits)) {
      return Err(_failure('image_limit'));
    }
    return Ok(
      ImagePreflightResult(
        format: ImageFormat.jpeg,
        pixelWidth: width,
        pixelHeight: height,
        orientation: orientation,
        horizontalDpi: xDpi,
        verticalDpi: yDpi,
      ),
    );
  }
}

/// Calculates oriented document size using trusted resolution or 96 DPI.
Result<Size2, StructuredFailure> imageDefaultDocumentSize({
  required ImagePreflightResult preflight,
  required ImageLimits limits,
  double fallbackDpi = 96,
}) {
  final xDpi = preflight.horizontalDpi ?? fallbackDpi;
  final yDpi = preflight.verticalDpi ?? fallbackDpi;
  if (!xDpi.isFinite || !yDpi.isFinite || xDpi <= 0 || yDpi <= 0) {
    return Err(_failure('invalid_resolution'));
  }
  var width = preflight.pixelWidth * 72 / xDpi;
  var height = preflight.pixelHeight * 72 / yDpi;
  if (preflight.orientation.swapsDimensions) {
    final value = width;
    width = height;
    height = value;
  }
  if (width > limits.maximumDocumentDimension ||
      height > limits.maximumDocumentDimension) {
    return Err(_failure('document_size_limit'));
  }
  return Size2.create(width: width, height: height);
}

/// Aspect-ratio-preserving fit-down result that never automatically upscales.
Result<Size2, StructuredFailure> fitImageDown({
  required Size2 intrinsic,
  required Size2 available,
}) {
  if (intrinsic.isEmpty || available.isEmpty)
    return Err(_failure('invalid_placement'));
  final scale = math.min(
    1,
    math.min(
      available.width / intrinsic.width,
      available.height / intrinsic.height,
    ),
  );
  return Size2.create(
    width: intrinsic.width * scale,
    height: intrinsic.height * scale,
  );
}

/// Portable bounded decode request; orientation is separate and applied once.
final class ImageDecodeRequest {
  const ImageDecodeRequest._({
    required this.resourceIdentity,
    required this.encodedBytes,
    required this.format,
    required this.encodedPixelWidth,
    required this.encodedPixelHeight,
    required this.maximumDecodedPixels,
    required this.cancellationToken,
  });

  /// Safely creates a bounded immutable decode request.
  static Result<ImageDecodeRequest, StructuredFailure> create({
    required ResourceIdentity resourceIdentity,
    required Iterable<int> encodedBytes,
    required ImageFormat format,
    required int encodedPixelWidth,
    required int encodedPixelHeight,
    required int maximumEncodedBytes,
    required int maximumDecodedPixels,
    required CancellationToken cancellationToken,
  }) {
    final captured = _captureBytes(encodedBytes, maximumEncodedBytes);
    final pixels = _checkedProduct(encodedPixelWidth, encodedPixelHeight);
    if (captured is! Ok<List<int>, StructuredFailure> ||
        format == ImageFormat.png && !_isPng(captured.value) ||
        format == ImageFormat.jpeg && !_isJpeg(captured.value) ||
        encodedPixelWidth <= 0 ||
        encodedPixelHeight <= 0 ||
        maximumDecodedPixels <= 0 ||
        maximumDecodedPixels > maximumWebSafeInteger ||
        pixels == null ||
        pixels > maximumDecodedPixels) {
      return Err(_failure('invalid_decode_request'));
    }
    return Ok(
      ImageDecodeRequest._(
        resourceIdentity: resourceIdentity,
        encodedBytes: captured.value,
        format: format,
        encodedPixelWidth: encodedPixelWidth,
        encodedPixelHeight: encodedPixelHeight,
        maximumDecodedPixels: maximumDecodedPixels,
        cancellationToken: cancellationToken,
      ),
    );
  }

  /// Resource cache identity.
  final ResourceIdentity resourceIdentity;

  /// Immutable caller-prevalidated encoded bytes.
  final List<int> encodedBytes;

  /// Verified format.
  final ImageFormat format;

  /// Verified encoded width.
  final int encodedPixelWidth;

  /// Verified encoded height.
  final int encodedPixelHeight;

  /// Maximum accepted decoded pixels.
  final int maximumDecodedPixels;

  /// Cooperative cancellation signal.
  final CancellationToken cancellationToken;
}

/// Disposable decoded-image handle owned by an adapter, never an engine type.
abstract interface class DecodedImageHandle {
  /// Decoded pixel width.
  int get pixelWidth;

  /// Decoded pixel height.
  int get pixelHeight;

  /// Deterministically releases engine resources.
  void dispose();
}

/// AL NOTE-owned portable image-decoder boundary.
abstract interface class ImageDecoder {
  /// Decodes after preflight and returns only an AL NOTE-owned handle.
  Future<Result<DecodedImageHandle, StructuredFailure>> decode(
    ImageDecodeRequest request,
  );
}

/// Deterministic cache identity including all decode-affecting inputs.
final class ImageDecodeCacheKey {
  /// Creates a key.
  const ImageDecodeCacheKey({
    required this.resourceIdentity,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  /// Immutable resource identity.
  final ResourceIdentity resourceIdentity;

  /// Requested/verified width.
  final int pixelWidth;

  /// Requested/verified height.
  final int pixelHeight;
  @override
  bool operator ==(Object other) =>
      other is ImageDecodeCacheKey &&
      other.resourceIdentity == resourceIdentity &&
      other.pixelWidth == pixelWidth &&
      other.pixelHeight == pixelHeight;
  @override
  int get hashCode => Object.hash(resourceIdentity, pixelWidth, pixelHeight);
}

/// Bounded least-recently-used cache that disposes evicted engine resources.
final class DecodedImageCache {
  DecodedImageCache._({
    required this.maximumEntries,
    required this.maximumPixels,
  });

  /// Creates a cache with positive Web-safe entry and pixel ceilings.
  static Result<DecodedImageCache, StructuredFailure> create({
    required int maximumEntries,
    required int maximumPixels,
  }) {
    if (maximumEntries <= 0 ||
        maximumEntries > maximumWebSafeInteger ||
        maximumPixels <= 0 ||
        maximumPixels > maximumWebSafeInteger) {
      return Err(_failure('invalid_cache_configuration'));
    }
    return Ok(
      DecodedImageCache._(
        maximumEntries: maximumEntries,
        maximumPixels: maximumPixels,
      ),
    );
  }

  /// Maximum retained handles.
  final int maximumEntries;

  /// Maximum total retained decoded pixels.
  final int maximumPixels;
  final Map<ImageDecodeCacheKey, _DecodedCacheEntry> _values = {};
  int _pixels = 0;

  /// Retrieves and promotes one handle.
  DecodedImageHandle? get(ImageDecodeCacheKey key) {
    try {
      final value = _values.remove(key);
      if (value != null) _values[key] = value;
      return value?.handle;
    } on Object {
      return null;
    }
  }

  /// Inserts a validated handle and disposes replacements and evictions.
  Result<void, StructuredFailure> put(
    ImageDecodeCacheKey key,
    DecodedImageHandle value,
  ) {
    int? pixels;
    try {
      final width = value.pixelWidth;
      final height = value.pixelHeight;
      pixels = _checkedProduct(width, height);
      if (pixels == null ||
          pixels > maximumPixels ||
          width != key.pixelWidth ||
          height != key.pixelHeight) {
        _safeDispose(value);
        return Err(_failure('cache_limit'));
      }
    } on Object {
      _safeDispose(value);
      return Err(_failure('cache_handle_unavailable'));
    }
    try {
      final prior = _values.remove(key);
      if (prior != null) {
        _pixels -= prior.pixels;
        _safeDispose(prior.handle);
      }
      _values[key] = _DecodedCacheEntry(value, pixels);
      _pixels += pixels;
      while (_values.length > maximumEntries || _pixels > maximumPixels) {
        final first = _values.entries.first;
        _values.remove(first.key);
        _pixels -= first.value.pixels;
        _safeDispose(first.value.handle);
      }
    } on Object {
      _values.remove(key);
      _safeDispose(value);
      return Err(_failure('cache_unavailable'));
    }
    return const Ok(null);
  }

  /// Disposes all retained handles.
  void clear() {
    for (final value in _values.values) _safeDispose(value.handle);
    _values.clear();
    _pixels = 0;
  }
}

final class _DecodedCacheEntry {
  const _DecodedCacheEntry(this.handle, this.pixels);
  final DecodedImageHandle handle;
  final int pixels;
}

/// Fully validated resource-plus-payload image insertion preparation.
final class PreparedImageInsertion {
  const PreparedImageInsertion._({
    required this.resource,
    required this.payload,
  });

  /// Exact original encoded resource bytes and metadata.
  final DocumentResource resource;

  /// Validated schema-1 Image payload.
  final ImagePayload payload;
}

/// AL NOTE-owned image insertion preparation boundary for caller-supplied bytes.
final class ImageInsertionPreparer {
  /// Creates a preparer with explicit limits.
  const ImageInsertionPreparer(this.limits);

  /// Image limits.
  final ImageLimits limits;

  /// Validates bytes and constructs resource plus payload before publication.
  Result<PreparedImageInsertion, StructuredFailure> prepare({
    required ResourceIdentity resourceIdentity,
    required ResourceMediaType mediaType,
    required ResourceRole resourceRole,
    required Iterable<int> encodedBytes,
    String? alternativeText,
  }) {
    final bytes = _captureBytes(encodedBytes, limits.maximumEncodedBytes);
    if (bytes is! Ok<List<int>, StructuredFailure>)
      return Err(_failure('invalid_bytes'));
    final preflight = ImageHeaderPreflight(
      limits,
    ).inspect(encodedBytes: bytes.value, mediaType: mediaType);
    if (preflight is Err<ImagePreflightResult, StructuredFailure>) {
      return Err(preflight.error);
    }
    final inspected =
        (preflight as Ok<ImagePreflightResult, StructuredFailure>).value;
    final size = imageDefaultDocumentSize(preflight: inspected, limits: limits);
    if (size is Err<Size2, StructuredFailure>) return Err(size.error);
    final documentSize = (size as Ok<Size2, StructuredFailure>).value;
    final resource = DocumentResource.capture(
      identity: resourceIdentity,
      mediaType: mediaType,
      role: resourceRole,
      schemaVersion: imageSchemaVersion,
      bytes: bytes.value,
    );
    if (resource is Err<DocumentResource, StructuredFailure>) {
      return Err(resource.error);
    }
    final capturedResource =
        (resource as Ok<DocumentResource, StructuredFailure>).value;
    final payload = ImagePayload.create(
      resourceIdentity: resourceIdentity,
      encodedPixelWidth: inspected.pixelWidth,
      encodedPixelHeight: inspected.pixelHeight,
      intrinsicWidth: documentSize.width,
      intrinsicHeight: documentSize.height,
      orientation: inspected.orientation,
      crop: ImageCropRect.full,
      renderingIntent: ImageRenderingIntent.auto,
      alternativeText: alternativeText,
      limits: limits,
    );
    if (payload is Err<ImagePayload, StructuredFailure>) {
      return Err(payload.error);
    }
    final capturedPayload =
        (payload as Ok<ImagePayload, StructuredFailure>).value;
    return Ok(
      PreparedImageInsertion._(
        resource: capturedResource,
        payload: capturedPayload,
      ),
    );
  }
}

/// Atomic publication request carrying fully built Image resource and Object.
final class ImageAtomicPublicationRequest {
  const ImageAtomicPublicationRequest._({
    required this.preparation,
    required this.object,
    required this.limits,
    required this.expectedDocumentRevision,
    required this.cancellationToken,
  });

  /// Revalidates complete resource, payload, Object, and revision evidence.
  static Result<ImageAtomicPublicationRequest, StructuredFailure> create({
    required PreparedImageInsertion preparation,
    required ObjectEnvelope object,
    required ImageLimits limits,
    required Revision expectedDocumentRevision,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Err(_failure('publication_cancelled'));
    }
    final preflight = ImageHeaderPreflight(limits).inspect(
      encodedBytes: preparation.resource.bytes,
      mediaType: preparation.resource.mediaType,
    );
    final payload = ImagePayload.decode(
      preparation.payload.encode(),
      limits: limits,
    );
    final objectPayload =
        object.typeKey == imageObjectTypeKey &&
            object.typeSchemaVersion == imageSchemaVersion
        ? ImagePayload.decode(object.payload, limits: limits)
        : null;
    if (preparation.resource.schemaVersion != imageSchemaVersion ||
        preflight is! Ok<ImagePreflightResult, StructuredFailure> ||
        payload is! Ok<ImagePayload, StructuredFailure> ||
        objectPayload is! Ok<ImagePayload, StructuredFailure> ||
        payload.value.resourceIdentity != preparation.resource.identity ||
        payload.value.encodedPixelWidth != preflight.value.pixelWidth ||
        payload.value.encodedPixelHeight != preflight.value.pixelHeight ||
        payload.value.orientation != preflight.value.orientation ||
        objectPayload.value.encode() != payload.value.encode()) {
      return Err(_failure('invalid_publication_evidence'));
    }
    return Ok(
      ImageAtomicPublicationRequest._(
        preparation: preparation,
        object: object,
        limits: limits,
        expectedDocumentRevision: expectedDocumentRevision,
        cancellationToken: cancellationToken,
      ),
    );
  }

  /// Fully validated resource and payload.
  final PreparedImageInsertion preparation;

  /// Fully validated Object envelope referring to that resource.
  final ObjectEnvelope object;

  /// Limits used to revalidate the final payload at publication time.
  final ImageLimits limits;

  /// Expected authoritative revision.
  final Revision expectedDocumentRevision;

  /// Cancellation signal checked before atomic publication.
  final CancellationToken cancellationToken;
}

/// Presentation-neutral all-or-nothing resource-plus-Object publication port.
abstract interface class ImageAtomicPublisher {
  /// Publishes both candidates or neither; failures must leave no resource or Object.
  Result<void, StructuredFailure> publish(
    ImageAtomicPublicationRequest request,
  );
}

/// Validates encoded pixels before one all-or-nothing Image publication.
final class ImageInsertionPublicationService {
  /// Creates the service from AL NOTE-owned decode and publication boundaries.
  const ImageInsertionPublicationService({
    required this.decoder,
    required this.publisher,
  });

  /// Decoder used only for bounded verification before publication.
  final ImageDecoder decoder;

  /// Atomic persistent publication boundary.
  final ImageAtomicPublisher publisher;

  /// Decodes, validates, disposes, and publishes, or leaves state unchanged.
  Future<Result<void, StructuredFailure>> publish(
    ImageAtomicPublicationRequest request,
  ) async {
    final revalidated = ImageAtomicPublicationRequest.create(
      preparation: request.preparation,
      object: request.object,
      limits: request.limits,
      expectedDocumentRevision: request.expectedDocumentRevision,
      cancellationToken: request.cancellationToken,
    );
    if (revalidated is! Ok<ImageAtomicPublicationRequest, StructuredFailure>) {
      return Err(_failure('invalid_publication_evidence'));
    }
    final validRequest = revalidated.value;
    final resource = validRequest.preparation.resource;
    final format = switch (resource.mediaType.value) {
      'image/png' => ImageFormat.png,
      'image/jpeg' => ImageFormat.jpeg,
      _ => null,
    };
    if (format == null) return Err(_failure('unsupported_media_type'));
    final decodeRequest = ImageDecodeRequest.create(
      resourceIdentity: resource.identity,
      encodedBytes: resource.bytes,
      format: format,
      encodedPixelWidth: validRequest.preparation.payload.encodedPixelWidth,
      encodedPixelHeight: validRequest.preparation.payload.encodedPixelHeight,
      maximumEncodedBytes: validRequest.limits.maximumEncodedBytes,
      maximumDecodedPixels: validRequest.limits.maximumPixelCount,
      cancellationToken: validRequest.cancellationToken,
    );
    if (decodeRequest is! Ok<ImageDecodeRequest, StructuredFailure>) {
      return Err(_failure('decode_validation_failed'));
    }
    Result<DecodedImageHandle, StructuredFailure> decoded;
    try {
      decoded = await decoder.decode(decodeRequest.value);
    } on Object {
      return Err(_failure('decode_unavailable'));
    }
    if (decoded is! Ok<DecodedImageHandle, StructuredFailure>) {
      return Err(_failure('decode_unavailable'));
    }
    try {
      int width;
      int height;
      try {
        width = decoded.value.pixelWidth;
        height = decoded.value.pixelHeight;
      } on Object {
        return Err(_failure('decode_validation_failed'));
      }
      if (validRequest.cancellationToken.isCancelled ||
          width != validRequest.preparation.payload.encodedPixelWidth ||
          height != validRequest.preparation.payload.encodedPixelHeight) {
        return Err(_failure('decode_validation_failed'));
      }
      try {
        return publisher.publish(validRequest);
      } on Object {
        return Err(_failure('publication_unavailable'));
      }
    } finally {
      try {
        decoded.value.dispose();
      } on Object {
        // Cleanup failures never expose engine details or alter publication.
      }
    }
  }
}

Result<ImageOrientation?, StructuredFailure> _exifOrientation(
  List<int> bytes,
  int tiff,
  int end,
) {
  if (tiff + 8 > end) return Err(_failure('malformed_header'));
  final little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
  final big = bytes[tiff] == 0x4d && bytes[tiff + 1] == 0x4d;
  if (!little && !big) return Err(_failure('malformed_header'));
  int u16(int at) =>
      little ? bytes[at] | bytes[at + 1] << 8 : _u16be(bytes, at);
  int u32(int at) => little
      ? bytes[at] |
            bytes[at + 1] << 8 |
            bytes[at + 2] << 16 |
            bytes[at + 3] << 24
      : _u32be(bytes, at);
  if (u16(tiff + 2) != 42) return Err(_failure('malformed_header'));
  final ifd = tiff + u32(tiff + 4);
  if (ifd < tiff || ifd + 2 > end) {
    return Err(_failure('malformed_header'));
  }
  final count = u16(ifd);
  if (count > 64 || ifd + 2 + count * 12 > end) {
    return Err(_failure('malformed_header'));
  }
  for (var index = 0; index < count; index++) {
    final entry = ifd + 2 + index * 12;
    if (u16(entry) == 0x0112 && u16(entry + 2) == 3 && u32(entry + 4) == 1) {
      final value = u16(entry + 8);
      final orientation = ImageOrientation.values
          .where((item) => item.exifValue == value)
          .firstOrNull;
      return orientation == null
          ? Err(_failure('malformed_header'))
          : Ok(orientation);
    }
  }
  return const Ok(null);
}

bool _isPng(List<int> bytes) =>
    bytes.length >= 8 &&
    _bytesAt(bytes, 0, const [137, 80, 78, 71, 13, 10, 26, 10]);
bool _isJpeg(List<int> bytes) =>
    bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;
bool _isSof(int marker) => const <int>{
  0xc0,
  0xc1,
  0xc2,
  0xc3,
  0xc5,
  0xc6,
  0xc7,
  0xc9,
  0xca,
  0xcb,
  0xcd,
  0xce,
  0xcf,
}.contains(marker);
bool _bytesAt(List<int> source, int offset, List<int> expected) {
  if (offset < 0 || offset + expected.length > source.length) return false;
  for (var index = 0; index < expected.length; index++)
    if (source[offset + index] != expected[index]) return false;
  return true;
}

String _ascii(List<int> bytes, int start, int end) =>
    start < 0 || end > bytes.length || end < start
    ? ''
    : String.fromCharCodes(bytes.sublist(start, end));
int _u16be(List<int> bytes, int offset) =>
    bytes[offset] << 8 | bytes[offset + 1];
int _u32be(List<int> bytes, int offset) =>
    bytes[offset] * 0x1000000 +
    bytes[offset + 1] * 0x10000 +
    bytes[offset + 2] * 0x100 +
    bytes[offset + 3];
int _crc32(List<int> bytes, int start, int end) {
  var crc = 0xffffffff;
  for (var offset = start; offset < end; offset++) {
    crc ^= bytes[offset];
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

int? _checkedProduct(int left, int right) {
  if (left < 0 ||
      right < 0 ||
      left > maximumWebSafeInteger ||
      right > maximumWebSafeInteger)
    return null;
  if (left != 0 && right > maximumWebSafeInteger ~/ left) return null;
  return left * right;
}

bool _dimensionsAllowed(int width, int height, ImageLimits limits) {
  final pixels = _checkedProduct(width, height);
  return width > 0 &&
      height > 0 &&
      width <= limits.maximumPixelDimension &&
      height <= limits.maximumPixelDimension &&
      pixels != null &&
      pixels <= limits.maximumPixelCount;
}

Result<List<int>, StructuredFailure> _captureBytes(
  Iterable<int> source,
  int maximum,
) {
  final values = <int>[];
  try {
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (values.length >= maximum ||
          iterator.current < 0 ||
          iterator.current > 255) {
        return Err(_failure('encoded_byte_limit'));
      }
      values.add(iterator.current);
    }
  } on Object {
    return Err(_failure('invalid_iterable'));
  }
  return Ok(List<int>.unmodifiable(values));
}

void _safeDispose(DecodedImageHandle value) {
  try {
    value.dispose();
  } on Object {
    /* isolated */
  }
}

bool _sameCrop(ImageCropRect a, ImageCropRect b) =>
    a.left == b.left &&
    a.top == b.top &&
    a.right == b.right &&
    a.bottom == b.bottom;
bool _unknownAllowed(PreservedMap value, ImageLimits limits) {
  return preservedUnknownDataAllowed(
    root: value,
    maximumFieldsPerBoundary: limits.maximumUnknownFields,
    maximumNodes: limits.maximumUnknownNodes,
    maximumDepth: limits.maximumNestingDepth,
    maximumStringCodeUnits: limits.maximumUnknownStringCodeUnits,
  );
}

bool _containsUnpairedSurrogate(String text) {
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++index >= text.length) return true;
      final low = text.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return true;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return true;
    }
  }
  return false;
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
    (ObjectTypeKey.parse('alnote.image')
            as Ok<ObjectTypeKey, StructuredFailure>)
        .value
        .identifier;
StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.image.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Image data is invalid or unavailable.',
);
