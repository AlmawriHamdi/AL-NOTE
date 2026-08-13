// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../documents/objects/image.dart';

/// Flutter/Skia decoder kept behind AL NOTE-owned portable contracts.
final class FlutterImageDecoder implements ImageDecoder {
  /// Creates the stateless decoder adapter.
  const FlutterImageDecoder();

  @override
  Future<Result<DecodedImageHandle, StructuredFailure>> decode(
    ImageDecodeRequest request,
  ) async {
    final decoded = await _decodeImage(request);
    return decoded.map<DecodedImageHandle>(_FlutterDecodedImageHandle.new);
  }

  /// Decodes one paintable UI-owned image without exposing it to portable APIs.
  Future<Result<FlutterDecodedImage, StructuredFailure>> decodeForPainting(
    ImageDecodeRequest request,
  ) async {
    final decoded = await _decodeImage(request);
    return decoded.map<FlutterDecodedImage>(FlutterDecodedImage._);
  }

  Future<Result<ui.Image, StructuredFailure>> _decodeImage(
    ImageDecodeRequest request,
  ) async {
    if (request.cancellationToken.isCancelled ||
        request.encodedBytes.isEmpty ||
        request.maximumDecodedPixels <= 0) {
      return Err(_failure('decode_cancelled_or_invalid'));
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(
        Uint8List.fromList(request.encodedBytes),
      );
      if (request.cancellationToken.isCancelled) {
        return Err(_failure('decode_cancelled_or_invalid'));
      }
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != request.encodedPixelWidth ||
          descriptor.height != request.encodedPixelHeight ||
          !_pixelsAllowed(
            descriptor.width,
            descriptor.height,
            request.maximumDecodedPixels,
          )) {
        return Err(_failure('decoded_dimension_mismatch'));
      }
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final frameImage = frame.image;
      decoded = frameImage;
      if (request.cancellationToken.isCancelled ||
          frameImage.width != request.encodedPixelWidth ||
          frameImage.height != request.encodedPixelHeight ||
          !_pixelsAllowed(
            frameImage.width,
            frameImage.height,
            request.maximumDecodedPixels,
          )) {
        return Err(_failure('decoded_dimension_mismatch'));
      }
      final result = frameImage;
      decoded = null;
      return Ok(result);
    } on Object {
      return Err(_failure('decode_unavailable'));
    } finally {
      try {
        decoded?.dispose();
      } on Object {
        // Cleanup exceptions never disclose engine details.
      }
      try {
        codec?.dispose();
      } on Object {
        // Cleanup exceptions never disclose engine details.
      }
      try {
        descriptor?.dispose();
      } on Object {
        // Cleanup exceptions never disclose engine details.
      }
      try {
        buffer?.dispose();
      } on Object {
        // Cleanup exceptions never disclose engine details.
      }
    }
  }
}

/// UI-owned decoded image that paints orientation and crop exactly once.
final class FlutterDecodedImage {
  FlutterDecodedImage._(this._image);

  ui.Image? _image;

  /// Decoded encoded-source width.
  int get pixelWidth => _image?.width ?? 0;

  /// Decoded encoded-source height.
  int get pixelHeight => _image?.height ?? 0;

  /// Paints the encoded source through its persistent orientation and crop.
  void paint(
    ui.Canvas canvas,
    ui.Rect destination,
    ImagePayload payload, {
    required double opacity,
  }) {
    final image = _image;
    if (image == null || destination.isEmpty) return;
    final crop = payload.crop;
    final cropWidth = crop.right - crop.left;
    final cropHeight = crop.bottom - crop.top;
    if (cropWidth <= 0 || cropHeight <= 0) return;
    final sx = destination.width / cropWidth;
    final sy = destination.height / cropHeight;
    final oriented = _orientationTransform(
      payload.orientation,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.save();
    canvas.clipRect(destination);
    canvas.translate(
      destination.left - crop.left * sx,
      destination.top - crop.top * sy,
    );
    canvas.scale(sx, sy);
    canvas.transform(oriented);
    canvas.drawImage(
      image,
      ui.Offset.zero,
      ui.Paint()
        ..filterQuality = switch (payload.renderingIntent) {
          ImageRenderingIntent.crispEdges => ui.FilterQuality.none,
          ImageRenderingIntent.auto => ui.FilterQuality.low,
          ImageRenderingIntent.smooth => ui.FilterQuality.high,
        }
        ..color = ui.Color.fromRGBO(255, 255, 255, opacity)
        ..colorFilter = ui.ColorFilter.mode(
          ui.Color.fromRGBO(255, 255, 255, opacity),
          ui.BlendMode.modulate,
        ),
    );
    canvas.restore();
  }

  /// Deterministically releases the engine image.
  void dispose() {
    final image = _image;
    _image = null;
    image?.dispose();
  }
}

final class _FlutterDecodedImageHandle implements DecodedImageHandle {
  _FlutterDecodedImageHandle(this._image);
  ui.Image? _image;

  @override
  int get pixelWidth => _image?.width ?? 0;

  @override
  int get pixelHeight => _image?.height ?? 0;

  @override
  void dispose() {
    final image = _image;
    _image = null;
    image?.dispose();
  }
}

Float64List _orientationTransform(
  ImageOrientation orientation,
  double width,
  double height,
) {
  final (a, b, c, d, tx, ty) = switch (orientation) {
    ImageOrientation.normal => (1.0 / width, 0.0, 0.0, 1.0 / height, 0.0, 0.0),
    ImageOrientation.mirrorHorizontal => (
      -1.0 / width,
      0.0,
      0.0,
      1.0 / height,
      1.0,
      0.0,
    ),
    ImageOrientation.rotate180 => (
      -1.0 / width,
      0.0,
      0.0,
      -1.0 / height,
      1.0,
      1.0,
    ),
    ImageOrientation.mirrorVertical => (
      1.0 / width,
      0.0,
      0.0,
      -1.0 / height,
      0.0,
      1.0,
    ),
    ImageOrientation.mirrorHorizontalRotate270 => (
      0.0,
      1.0 / width,
      1.0 / height,
      0.0,
      0.0,
      0.0,
    ),
    ImageOrientation.rotate90 => (
      0.0,
      1.0 / width,
      -1.0 / height,
      0.0,
      1.0,
      0.0,
    ),
    ImageOrientation.mirrorHorizontalRotate90 => (
      0.0,
      -1.0 / width,
      -1.0 / height,
      0.0,
      1.0,
      1.0,
    ),
    ImageOrientation.rotate270 => (
      0.0,
      -1.0 / width,
      1.0 / height,
      0.0,
      0.0,
      1.0,
    ),
  };
  return Float64List.fromList([
    a,
    b,
    0,
    0,
    c,
    d,
    0,
    0,
    0,
    0,
    1,
    0,
    tx,
    ty,
    0,
    1,
  ]);
}

bool _pixelsAllowed(int width, int height, int maximum) =>
    width > 0 &&
    height > 0 &&
    width <= maximum &&
    height <= maximum &&
    width <= maximum ~/ height;

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'ui.image_decoder.$leaf',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'Image decoding is invalid or unavailable.',
);
