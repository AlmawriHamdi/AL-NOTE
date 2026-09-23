// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui';

import '../../documents/pdf/pdf_model.dart';
import 'pdf_source_paint.dart';

/// Paints the existing normalized crop rebased to Object-local (0, 0).
/// The caller applies the common Object transform and Page clipping.
void paintPdfPageObject(
  Canvas canvas,
  PdfPageObjectPayload payload, {
  required Image? image,
  required double opacity,
}) {
  final target = Rect.fromLTWH(
    0,
    0,
    payload.bounds.width,
    payload.bounds.height,
  );
  if (image == null) {
    paintPdfSource(
      canvas,
      target,
      image: null,
      placeholder: true,
      visible: true,
      opacity: opacity,
    );
    return;
  }
  final clip = payload.clip;
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(
      clip.left * image.width,
      clip.top * image.height,
      clip.width * image.width,
      clip.height * image.height,
    ),
    target,
    Paint()
      ..color = Color.fromRGBO(255, 255, 255, opacity)
      ..filterQuality = FilterQuality.medium,
  );
}
