// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/outcomes/cancellation.dart';
import '../../documents/pdf/pdf_backend.dart';

/// Final engine image preparation. Linux transfers private immutable typed
/// pixels from its operation isolate, so this handoff needs no Dart raster copy.
Future<ui.Image?> preparePdfRasterImage(
  PdfRenderOutput output,
  CancellationToken token,
) async {
  if (token.isCancelled) return null;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    final bytes = output.rgbaBytes;
    buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    if (token.isCancelled) return null;
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: output.pixelWidth,
      height: output.pixelHeight,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    codec = await descriptor.instantiateCodec();
    if (token.isCancelled) return null;
    image = (await codec.getNextFrame()).image;
    if (token.isCancelled) {
      image.dispose();
      return null;
    }
    return image;
  } on Object {
    image?.dispose();
    return null;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
