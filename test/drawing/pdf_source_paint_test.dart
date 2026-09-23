// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui';

import 'package:al_note/ui/canvas/pdf_source_paint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final placeholder in [false, true]) {
    for (final style in [(true, 1.0), (true, 0.5), (true, 0.0), (false, 1.0)]) {
      testWidgets('PDF source pixels placeholder=$placeholder style=$style', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final sourceRecorder = PictureRecorder();
          Canvas(sourceRecorder)
              .drawColor(const Color(0xffff0000), BlendMode.src);
          final sourcePicture = sourceRecorder.endRecording();
          final source = await sourcePicture.toImage(40, 40);
          sourcePicture.dispose();
          final recorder = PictureRecorder();
          final canvas = Canvas(recorder);
          const clip = Rect.fromLTWH(0, 0, 40, 40);
          canvas.drawColor(const Color(0xffffffff), BlendMode.src);
          paintPdfSource(
            canvas,
            clip,
            image: placeholder ? null : source,
            placeholder: placeholder,
            visible: style.$1,
            opacity: style.$2,
          );
          // An independently opaque annotation must remain opaque in every case.
          canvas.drawRect(
            const Rect.fromLTWH(2, 2, 4, 4),
            Paint()..color = const Color(0xff0000ff),
          );
          final picture = recorder.endRecording();
          final result = await picture.toImage(40, 40);
          final data = (await result.toByteData())!.buffer.asUint8List();
          List<int> pixel(int x, int y) =>
              data.sublist((y * 40 + x) * 4, (y * 40 + x) * 4 + 4);
          expect(pixel(3, 3), [0, 0, 255, 255]);
          final alpha = style.$1 ? (style.$2 * 255).round() / 255 : 0.0;
          final base = placeholder ? [238, 241, 244] : [255, 0, 0];
          for (var c = 0; c < 3; c++) {
            expect(pixel(10, 20)[c], closeTo(255 + (base[c] - 255) * alpha, 1));
          }
          // Intersection receives group opacity once, not once per line.
          if (placeholder)
            for (var c = 0; c < 3; c++) {
              expect(
                pixel(20, 20)[c],
                closeTo(255 + ([156, 163, 175][c] - 255) * alpha, 1),
              );
            }
          result.dispose();
          picture.dispose();
          source.dispose();
        });
      });
    }
  }
}
