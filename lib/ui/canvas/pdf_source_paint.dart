// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

/// Paints only the PDF source group; annotations are painted by their own layers.
void paintPdfSource(
  Canvas canvas,
  Rect clip, {
  required Image? image,
  required bool placeholder,
  required bool visible,
  required double opacity,
}) {
  if (!visible || opacity <= 0 || (image == null && !placeholder)) return;
  // Group alpha also applies once to overlapping placeholder lines/background.
  if (opacity < 1)
    canvas.saveLayer(
      clip,
      Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
    );
  if (image != null) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      clip,
      Paint()..filterQuality = FilterQuality.medium,
    );
  } else {
    canvas.drawRect(clip, Paint()..color = const Color(0xffeef1f4));
    final line = Paint()
      ..color = const Color(0xff9ca3af)
      ..strokeWidth = 2;
    canvas.drawLine(clip.topLeft, clip.bottomRight, line);
    canvas.drawLine(clip.topRight, clip.bottomLeft, line);
  }
  if (opacity < 1) canvas.restore();
}
