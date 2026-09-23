// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/drawing/hit_testing.dart';
import 'package:al_note/ui/canvas/pdf_object_paint.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/pdf_geometry_checks.dart';

void main() {
  test('PDF Object hit testing uses the transformed clipped polygon, including Whole Eraser', () {
    final payload = pdfPayload();
    final rotate = value(
      AffineTransform2D.fromOperation(
        value(
          RotationTransformOperation2D.create(
            radians: math.pi / 4,
            pivot: point(0, 0),
          ),
        ),
      ),
    );
    final translate = value(
      AffineTransform2D.fromOperation(
        TranslationTransformOperation2D(value(Vector2.create(x: 100, y: 100))),
      ),
    );
    final object = value(
      ObjectEnvelope.create(
        id: ObjectId.fromUuid(testUuid(2)),
        typeKey: pdfPageObjectTypeKey,
        envelopeVersion: testSchemaVersion,
        typeSchemaVersion: pdfPageObjectSchemaVersion,
        transform: value(rotate.then(translate)),
        visible: true,
        locked: false,
        payload: payload.encode(),
        extensionData: PreservedMap.empty(),
      ),
    );
    final hits = PdfPageHitTestingDefinition(geometryModelLimits);
    final center = value(object.transform.applyToPoint(point(10, 20)));
    expect(
      value(
        hits.wholePoint(object: object, pagePosition: center, pageTolerance: 0),
      ),
      isTrue,
    );
    // Within the axis-aligned enclosing rectangle but outside the rotated PDF.
    expect(
      value(
        hits.wholePoint(
          object: object,
          pagePosition: point(113, 101),
          pageTolerance: 0,
        ),
      ),
      isFalse,
    );
    expect(
      value(
        hits.wholeRectangle(
          object: object,
          area: value(
            Rect2.fromEdges(left: 50, top: 50, right: 180, bottom: 180),
          ),
          mode: AreaHitMode.containment,
        ),
      ),
      isTrue,
    );
    expect(
      value(
        hits.wholeSweptSegment(
          object: object,
          start: point(50, 120),
          end: point(150, 120),
          radius: 0,
        ),
      ),
      isTrue,
    );
    expect(
      value(
        hits.wholeSweptSegment(
          object: object,
          start: point(140, 100),
          end: point(150, 110),
          radius: 0,
        ),
      ),
      isFalse,
    );
    expect(payload.reference.sourceBox.left, -10);
  });

  for (final opacity in [1.0, .5, 0.0]) {
    testWidgets('PDF Object exact cropped source pixels and opacity $opacity', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
        canvas.drawRect(
          const ui.Rect.fromLTWH(20, 0, 20, 40),
          ui.Paint()..color = const ui.Color(0xff0000ff),
        );
        final picture = recorder.endRecording();
        final source = await picture.toImage(40, 40);
        picture.dispose();
        final targetRecorder = ui.PictureRecorder();
        final target = ui.Canvas(targetRecorder);
        target.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
        target.translate(5, 5);
        // Model clip right half, local bounds 20 x 40: no red may survive.
        paintPdfPageObject(
          target,
          pdfPayload(),
          image: source,
          opacity: opacity,
        );
        final painted = targetRecorder.endRecording();
        final result = await painted.toImage(50, 50);
        final data = (await result.toByteData())!.buffer.asUint8List();
        List<int> pixel(int x, int y) =>
            data.sublist((y * 50 + x) * 4, (y * 50 + x) * 4 + 4);
        final faded = (255 * (1 - opacity)).round();
        expect(pixel(15, 25), [faded, faded, 255, 255]);
        expect(pixel(30, 25), [255, 255, 255, 255]);
        result.dispose();
        painted.dispose();
        source.dispose();
      });
    });
  }
}

T value<T>(Result<T, StructuredFailure> result) =>
    (result as Ok<T, StructuredFailure>).value;
Point2 point(double x, double y) => value(Point2.create(x: x, y: y));
PdfPageObjectPayload pdfPayload() => value(
  PdfPageObjectPayload.create(
    reference: value(
      PdfPageReference.create(
        resourceIdentity: geometryIdentity,
        pageIndex: 0,
        boxKind: PdfPageBoxKind.resolvedBounds,
        sourceBox: value(
          PdfSourceBox.create(
            left: -10,
            bottom: 20,
            right: 30,
            top: 60,
            limits: geometryModelLimits,
          ),
        ),
        rotation: PdfPageRotation.degrees0,
        displayedWidth: 40,
        displayedHeight: 40,
        limits: geometryModelLimits,
      ),
    ),
    clip: value(PdfPageClip.create(left: .5, top: 0, right: 1, bottom: 1)),
    limits: geometryModelLimits,
  ),
);
