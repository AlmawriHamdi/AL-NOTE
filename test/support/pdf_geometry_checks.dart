// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';

/// Shared native / real-browser regression. All input is generated here; the
/// asymmetric red (10 x 20) and blue (20 x 10) marks have known source centers.
Future<List<Map<String, Object>>> checkMarkedPdfGeometry() async {
  final results = <Map<String, Object>>[];
  final backend = createTrustedDevelopmentPdfBackend();
  for (final spec in geometryCases) {
    for (final rotation in PdfPageRotation.values) {
      final reader = GeometryReader(markedPdf(spec, rotation.degrees));
      final inspected = await backend.inspect(
        PdfInspectRequest(
          resourceIdentity: geometryIdentity,
          trust: PdfInputTrust.trustedDevelopmentFixture,
          modelLimits: geometryModelLimits,
          limits: geometryProcessingLimits,
          cancellationToken: CancellationController().token,
        ),
        resourceReader: reader,
      );
      final label = '${spec.name}/${rotation.degrees}';
      if (spec.bounds == null) {
        _check(inspected is PdfCorrupt, '$label must reject');
        results.add({'case': label, 'rejected': true});
        continue;
      }
      _check(inspected is PdfInspectSuccess, '$label inspect: $inspected');
      final page = (inspected as PdfInspectSuccess).pages.single;
      final expected = Float32List.fromList(spec.bounds!);
      _check(
        page.boxKind == PdfPageBoxKind.resolvedBounds,
        '$label provenance',
      );
      _check(page.rotation == rotation, '$label inherited rotation');
      _check(
        page.sourceBox.left == expected[0] &&
            page.sourceBox.bottom == expected[1] &&
            page.sourceBox.right == expected[2] &&
            page.sourceBox.top == expected[3],
        '$label resolved rectangle',
      );
      final original = geometryOk(
        PdfPageReference.create(
          resourceIdentity: geometryIdentity,
          pageIndex: 0,
          boxKind: page.boxKind,
          sourceBox: page.sourceBox,
          rotation: page.rotation,
          displayedWidth: page.displayedWidth,
          displayedHeight: page.displayedHeight,
          limits: geometryModelLimits,
        ),
      );
      // Render using a reopened reference, exercising exact saved matching.
      final reference = geometryOk(
        PdfPageReference.decode(original.encode(), limits: geometryModelLimits),
      );
      _check(reference == original, '$label codec');
      final coordinates = PdfPageCoordinates(reference);
      final width = (page.displayedWidth * 2).round();
      final height = (page.displayedHeight * 2).round();
      final request = geometryOk(
        PdfRenderRequest.create(
          reference: reference,
          trust: PdfInputTrust.trustedDevelopmentFixture,
          region: PdfPageClip.full,
          pixelWidth: width,
          pixelHeight: height,
          includeSafeNativeAppearances: false,
          limits: geometryProcessingLimits,
          cancellationToken: CancellationController().token,
        ),
      );
      final rendered = await backend.render(request, resourceReader: reader);
      _check(rendered is PdfRenderSuccess, '$label render: $rendered');
      final pixels = (rendered as PdfRenderSuccess).output.rgbaBytes;
      final centroids = <List<double>>[];
      for (final mark in [0, 1]) {
        final source = geometryOk(
          Point2.create(x: mark == 0 ? 25 : 80, y: mark == 0 ? 40 : 65),
        );
        final local = geometryOk(coordinates.sourceToLocal(source));
        final inverse = geometryOk(coordinates.localToSource(local));
        _check(inverse == source, '$label inverse');
        final predictedX = local.x * width / reference.displayedWidth;
        final predictedY = local.y * height / reference.displayedHeight;
        var count = 0;
        var sumX = 0.0;
        var sumY = 0.0;
        for (var y = 0; y < height; y++) {
          for (var x = 0; x < width; x++) {
            final offset = (y * width + x) * 4;
            if (pixels[offset + (mark == 0 ? 0 : 2)] > 240 &&
                pixels[offset + (mark == 0 ? 2 : 0)] < 10 &&
                pixels[offset + 1] < 10) {
              count++;
              sumX += x + 0.5;
              sumY += y + 0.5;
            }
          }
        }
        _check(count > 100, '$label visible mark $mark');
        final x = sumX / count;
        final y = sumY / count;
        // Raster-edge quantization only: this is a pixel assertion, never a
        // tolerance for model/evidence acceptance. Both centers must agree.
        _check(
          (x - predictedX).abs() <= 0.6 && (y - predictedY).abs() <= 0.6,
          '$label pixel alignment $mark',
        );
        centroids.add([x, y, predictedX, predictedY]);
      }
      // A translated rectangle with identical extents must never match on
      // reopen. This guards against dimension-only/tolerant rectangle checks.
      final shifted = geometryOk(
        PdfSourceBox.create(
          left: page.sourceBox.left + 1,
          bottom: page.sourceBox.bottom,
          right: page.sourceBox.right + 1,
          top: page.sourceBox.top,
          limits: geometryModelLimits,
        ),
      );
      final wrongReference = geometryOk(
        PdfPageReference.create(
          resourceIdentity: geometryIdentity,
          pageIndex: 0,
          boxKind: page.boxKind,
          sourceBox: shifted,
          rotation: rotation,
          displayedWidth: page.displayedWidth,
          displayedHeight: page.displayedHeight,
          limits: geometryModelLimits,
        ),
      );
      final wrongRequest = geometryOk(
        PdfRenderRequest.create(
          reference: wrongReference,
          trust: PdfInputTrust.trustedDevelopmentFixture,
          region: PdfPageClip.full,
          pixelWidth: width,
          pixelHeight: height,
          includeSafeNativeAppearances: false,
          limits: geometryProcessingLimits,
          cancellationToken: CancellationController().token,
        ),
      );
      _check(
        await backend.render(wrongRequest, resourceReader: reader)
            is PdfRenderFailure,
        '$label translated box rejection',
      );
      results.add({'case': label, 'centroidsActualExpected': centroids});
    }
  }
  return results;
}

void _check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

T geometryOk<T>(Result<T, StructuredFailure> value) =>
    (value as Ok<T, StructuredFailure>).value;

final geometryIdentity = ResourceIdentity.fromUuid(
  geometryOk(UuidIdentifier.parse('00000000-0000-4000-8000-000000000980')),
);
final geometryModelLimits = geometryOk(
  PdfModelLimits.create(
    maximumPageCount: 16,
    maximumCoordinateMagnitude: 10000,
    maximumPageDimension: 10000,
    maximumPageArea: 100000000,
    maximumUnknownFields: 16,
    maximumUnknownNodes: 256,
    maximumNestingDepth: 8,
    maximumUnknownStringCodeUnits: 4096,
  ),
);
final geometryProcessingLimits = geometryOk(
  PdfProcessingLimits.create(
    maximumEncodedBytes: 1024 * 1024,
    maximumPageCount: 16,
    maximumRenderDimension: 2048,
    maximumRenderPixels: 4 * 1024 * 1024,
    maximumExtractedGlyphs: 4096,
    maximumLinks: 128,
    maximumOperations: 128,
  ),
);

final class GeometryReader implements PdfResourceReader {
  GeometryReader(this.bytes);
  final List<int> bytes;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async => PdfResourceBytes.capture(
    identity: identity,
    bytes: bytes,
    limits: limits,
    cancellationToken: cancellationToken,
  );
}

final class GeometryCase {
  const GeometryCase(
    this.name,
    this.media,
    this.crop,
    this.bounds, {
    this.inherited = false,
  });
  final String name;
  final String media;
  final String? crop;
  final List<double>? bounds;
  final bool inherited;
}

const geometryCases = [
  GeometryCase('contained', '0 0 200 100', '10 20 110 90', [10, 20, 110, 90]),
  GeometryCase('overlap', '0 0 200 100', '-50 -20 150 80', [0, 0, 150, 80]),
  GeometryCase('oversized', '0 0 200 100', '-50 -20 250 180', [0, 0, 200, 100]),
  GeometryCase('reversed', '0 0 200 100', '90 80 10 20', [10, 20, 90, 80]),
  GeometryCase('reversedMedia', '200 100 0 0', null, [0, 0, 200, 100]),
  GeometryCase('inherited', '-100 -200 500 600', '-40 -30 160 70', [
    -40,
    -30,
    160,
    70,
  ], inherited: true),
  GeometryCase('inheritedMedia', '-100 -200 500 600', null, [
    -100,
    -200,
    500,
    600,
  ], inherited: true),
  GeometryCase('negative', '-100 -200 500 600', '-40 -30 160 70', [
    -40,
    -30,
    160,
    70,
  ]),
  GeometryCase('fractional', '0 0 612 792', '10.1 20.2 210.3 120.4', [
    10.1,
    20.2,
    210.3,
    120.4,
  ]),
  GeometryCase('disjoint', '0 0 200 100', '300 300 400 400', null),
];

/// Controlled PDF writer, never a parser. Offsets are calculated from bytes.
Uint8List markedPdf(GeometryCase spec, int rotation) {
  const marks = '1 0 0 rg 20 30 10 20 re f\n0 0 1 rg 70 60 20 10 re f\n';
  final attrs =
      '/MediaBox [${spec.media}] '
      '${spec.crop == null ? '' : '/CropBox [${spec.crop}] '}'
      '/Rotate $rotation';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count 1 /Kids [3 0 R] ${spec.inherited ? attrs : ''} >>',
    '<< /Type /Page /Parent 2 0 R ${spec.inherited ? '' : attrs} '
        '/Resources <<>> /Contents 4 0 R >>',
    '<< /Length ${marks.length} >>\nstream\n${marks}endstream',
  ];
  final bytes = BytesBuilder(copy: false);
  void write(String text) => bytes.add(latin1.encode(text));
  write('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(bytes.length);
    write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = bytes.length;
  write('xref\n0 5\n0000000000 65535 f \n');
  for (final offset in offsets) {
    write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  write('trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return bytes.takeBytes();
}
