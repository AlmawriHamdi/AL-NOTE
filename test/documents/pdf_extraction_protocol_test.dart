// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/pdf.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_extraction.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdf_geometry_checks.dart';

final _limits = geometryOk(
  PdfProcessingLimits.create(
    maximumEncodedBytes: 50000000,
    maximumPageCount: 1000,
    maximumRenderDimension: 4096,
    maximumRenderPixels: 16777216,
    maximumExtractedGlyphs: 8192,
    maximumLinks: 256,
    maximumOperations: 4096,
  ),
);

LinuxPdfExtractionRequest _request({
  bool links = false,
  bool allowHttp = false,
  int glyphs = 8192,
  int linkLimit = 256,
}) => LinuxPdfExtractionRequest(
  operation: links
      ? LinuxPdfExtractionOperation.links
      : LinuxPdfExtractionOperation.text,
  pageIndex: 0,
  maximumPages: 1000,
  maximumGlyphs: glyphs,
  maximumLinks: linkLimit,
  maximumOperations: 4096,
  allowHttp: allowHttp,
);

Map<String, Object> _response({
  bool links = false,
  List<Object>? records,
  int rotation = 0,
}) => {
  'version': 1,
  'id': 1,
  'status': 'ok',
  'operation': links ? 'links' : 'text',
  'pageIndex': 0,
  'pageCount': 2,
  'complete': true,
  'page': {
    'kind': 'resolvedBounds',
    'bounds': [20, 40, 70, 100],
    'rotation': rotation,
    'width': rotation % 180 == 0 ? 50 : 60,
    'height': rotation % 180 == 0 ? 60 : 50,
  },
  'count': records?.length ?? 0,
  'records': records ?? <Object>[],
};

Uint8List _frame(Object value) {
  final bytes = utf8.encode(jsonEncode(value));
  return Uint8List.fromList([
    ...(ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List(),
    ...bytes,
  ]);
}

LinuxPdfFrames _decoder(LinuxPdfExtractionRequest request) => LinuxPdfFrames(
  width: 1,
  height: 1,
  render: false,
  extraction: request,
  onReady: () {},
)..add(_frame({'ready': true}));

void main() {
  test(
    'unpositioned separators are explicit and other unpositioned text rejects',
    () {
      for (final scalar in [9, 10, 13, 32]) {
        _decoder(_request())
          ..add(
            _frame(
              _response(
                records: [
                  [scalar, null],
                ],
              ),
            ),
          )
          ..finish();
      }
      expect(
        () => _decoder(_request()).add(
          _frame(
            _response(
              records: [
                [65, null],
              ],
            ),
          ),
        ),
        throwsFormatException,
      );
    },
  );
  test('every closed rejection survives extraction framing', () {
    for (final reason in LinuxPdfRejection.values) {
      final decoder = _decoder(_request())
        ..add(
          _frame({
            'version': 1,
            'id': 1,
            'status': 'rejected',
            'reason': reason.name,
          }),
        )
        ..finish();
      expect(decoder.rejection, reason);
      decoder.discard();
      expect(decoder.frames, isEmpty);
    }
  });
  test(
    'glyph capture owns its result, rejects invalid and cancelled iterables',
    () {
      const glyph = PdfTextGlyph(
        unicodeScalar: 65,
        sourceCharacterIndex: 0,
        bounds: null,
      );
      final cancel = CancellationController()..cancel();
      expect(
        PdfExtractedText.captureGlyphs(
          glyphs: const [],
          limits: _limits,
          cancellationToken: cancel.token,
        ),
        isA<Err<PdfExtractedText, StructuredFailure>>(),
      );
      expect(
        PdfExtractedText.captureGlyphs(
          glyphs: [glyph],
          limits: _limits,
          cancellationToken: CancellationController().token,
        ),
        isA<Err<PdfExtractedText, StructuredFailure>>(),
      );
      const separator = PdfTextGlyph(
        unicodeScalar: 32,
        sourceCharacterIndex: 0,
        bounds: null,
      );
      final input = [separator];
      final result = geometryOk(
        PdfExtractedText.captureGlyphs(
          glyphs: input,
          limits: _limits,
          cancellationToken: CancellationController().token,
        ),
      );
      input.clear();
      expect(result.text, ' ');
      expect(result.glyphs, [separator]);
      expect(() => result.glyphs!.clear(), throwsUnsupportedError);
      expect(
        PdfExtractedText.captureGlyphs(
          glyphs: [separator, separator],
          limits: _limits,
          cancellationToken: CancellationController().token,
        ),
        isA<Err<PdfExtractedText, StructuredFailure>>(),
      );
    },
  );
  test('extraction framing handles fragmentation and empty complete pages', () {
    for (final links in [false, true]) {
      final decoder = _decoder(_request(links: links));
      for (final byte in _frame(_response(links: links))) {
        decoder.add([byte]);
      }
      decoder.finish();
      expect(decoder.frames, hasLength(2));
      expect(() => decoder.add([0]), throwsFormatException);
    }
  });
  test(
    'extraction rejects truncation and oversized frames before payload capture',
    () {
      final decoder = _decoder(_request());
      expect(
        () => decoder.add(
          (ByteData(4)..setUint32(0, linuxPdfExtractionResponseBytes + 1))
              .buffer
              .asUint8List(),
        ),
        throwsFormatException,
      );
      final incomplete = _decoder(_request())
        ..add(_frame(_response()).sublist(0, 15));
      expect(incomplete.finish, throwsFormatException);
      incomplete.discard();
      expect(incomplete.frames, isEmpty);
    },
  );
  test(
    'extraction exact integer fields, completeness and response identity',
    () {
      for (final key in ['version', 'id', 'pageIndex', 'pageCount', 'count']) {
        for (final invalid in [true, false, 0.0, 1.0, -1, '1', null]) {
          expect(
            () =>
                _decoder(_request())
                    .add(_frame({..._response(), key: invalid})),
            throwsFormatException,
            reason: '$key / $invalid',
          );
        }
      }
      for (final change in [
        {'complete': false},
        {'complete': 1},
        {'complete': 'true'},
        {'operation': 'links'},
        {'pageIndex': 1},
        {'count': 1},
        {'extra': 'secret'},
      ]) {
        expect(
          () => _decoder(_request()).add(_frame({..._response(), ...change})),
          throwsFormatException,
        );
      }
    },
  );
  test('glyph scalars, geometry and exact receiving counts are independently checked', () {
    const bounds = [30, 50, 40, 64];
    final exact = _response(
      records: [
        [0x3a9, bounds],
        [0x1f600, bounds],
      ],
    );
    _decoder(_request(glyphs: 2))
      ..add(_frame(exact))
      ..finish();
    expect(
      () => _decoder(_request(glyphs: 1)).add(_frame(exact)),
      throwsFormatException,
    );
    for (final scalar in [0, -1, 0xd800, 0xdfff, 0x110000, true, 65.0, 'A']) {
      expect(
        () => _decoder(_request()).add(
          _frame(
            _response(
              records: [
                [scalar, bounds],
              ],
            ),
          ),
        ),
        throwsFormatException,
      );
    }
    for (final badBounds in [
      <Object>[],
      [1, 2, 3],
      [30, 50, 20, 64],
      [1, 2, true, 4],
      [1, 2, 1000001, 4],
    ]) {
      expect(
        () => _decoder(_request()).add(
          _frame(
            _response(
              records: [
                [65, badBounds],
              ],
            ),
          ),
        ),
        throwsFormatException,
      );
    }
    final huge = '1${List.filled(400, '0').join()}';
    final payload = utf8.encode(
      jsonEncode(
        _response(
          records: [
            [65, bounds],
          ],
        ),
      ).replaceFirst('[30,50,40,64]', '[30,50,$huge,64]'),
    );
    expect(
      () => _decoder(_request()).add(
        Uint8List.fromList([
          ...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(),
          ...payload,
        ]),
      ),
      throwsFormatException,
    );
  });
  test('links require explicit HTTP metadata policy and real document destination range', () {
    final internal = {
      'kind': 'internal',
      'bounds': [30, 50, 40, 64],
      'destination': 1,
    };
    final http = {
      'kind': 'http',
      'bounds': [30, 50, 40, 64],
      'uri': 'https://example.invalid/path?q=private',
    };
    _decoder(_request(links: true, allowHttp: true))
      ..add(_frame(_response(links: true, records: [internal, http])))
      ..finish();
    expect(
      () =>
          _decoder(_request(links: true))
              .add(_frame(_response(links: true, records: [http]))),
      throwsFormatException,
    );
    expect(
      () =>
          _decoder(_request(links: true, allowHttp: true, linkLimit: 1))
              .add(_frame(_response(links: true, records: [internal, http]))),
      throwsFormatException,
    );
    for (final target in [-1, 2, 1.0, true, null]) {
      expect(
        () => _decoder(_request(links: true)).add(
          _frame(
            _response(
              links: true,
              records: [
                {...internal, 'destination': target},
              ],
            ),
          ),
        ),
        throwsFormatException,
      );
    }
    for (final uri in [
      'file:///tmp/secret',
      'javascript:alert(1)',
      'custom:run',
      'https://',
      'https://user:pass@example.invalid',
      'https://example.invalid/%zz',
      'https://example.invalid/\\x',
      'https://example.invalid/\n',
      'https://${'a' * 2048}.invalid',
    ]) {
      expect(
        () => _decoder(_request(links: true, allowHttp: true)).add(
          _frame(
            _response(
              links: true,
              records: [
                {...http, 'uri': uri},
              ],
            ),
          ),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => _decoder(_request(links: true)).add(
        _frame(
          _response(
            links: true,
            records: [
              {...internal, 'kind': 'launch'},
            ],
          ),
        ),
      ),
      throwsFormatException,
    );
  });
  for (final rotation in PdfPageRotation.values) {
    test(
      'extraction uses authoritative source mapping at ${rotation.degrees} with Unicode geometry',
      () {
        final reference = geometryOk(
          PdfPageReference.create(
            resourceIdentity: geometryIdentity,
            pageIndex: 0,
            boxKind: PdfPageBoxKind.resolvedBounds,
            sourceBox: geometryOk(
              PdfSourceBox.create(
                left: 20,
                bottom: 40,
                right: 70,
                top: 100,
                limits: geometryModelLimits,
              ),
            ),
            rotation: rotation,
            displayedWidth: rotation.index.isEven ? 50 : 60,
            displayedHeight: rotation.index.isEven ? 60 : 50,
            limits: geometryModelLimits,
          ),
        );
        final response = _response(
          rotation: rotation.degrees,
          records: [
            [
              0x3a9,
              [30, 50, 40, 64],
            ],
            [
              0x1f600,
              [40, 50, 50, 64],
            ],
          ],
        );
        final decoder = _decoder(_request())..add(_frame(response));
        decoder.finish();
        final text = projectLinuxPdfExtraction(
          response: decoder.frames[1] as Map<String, dynamic>,
          operation: _request(),
          reference: reference,
          region: PdfPageClip.full,
          limits: _limits,
          token: CancellationController().token,
        ) as PdfExtractedText;
        expect(text.text, 'Ω😀');
        final expected = switch (rotation) {
          PdfPageRotation.degrees0 => [10.0, 36.0, 20.0, 50.0],
          PdfPageRotation.degrees90 => [10.0, 10.0, 24.0, 20.0],
          PdfPageRotation.degrees180 => [30.0, 10.0, 40.0, 24.0],
          PdfPageRotation.degrees270 => [36.0, 30.0, 50.0, 40.0],
        };
        final box = text.glyphs!.first.bounds!;
        expect([box.left, box.top, box.right, box.bottom], expected);
        expect(text.glyphs!.map((g) => g.sourceCharacterIndex), [0, 1]);
        expect(text.toString(), isNot(contains('Ω')));
        expect(text.glyphs!.first.toString(), 'PdfTextGlyph(redacted)');
        expect(() => text.glyphs!.clear(), throwsUnsupportedError);
        expect(
          () => projectLinuxPdfExtraction(
            response: {
              ...response,
              'page': {
                ...response['page'] as Map<String, Object>,
                'rotation': (rotation.degrees + 90) % 360,
              },
            },
            operation: _request(),
            reference: reference,
            region: PdfPageClip.full,
            limits: _limits,
            token: CancellationController().token,
          ),
          throwsFormatException,
        );
        expect(
          () => projectLinuxPdfExtraction(
            response: response,
            operation: _request(),
            reference: reference,
            region: PdfPageClip.full,
            limits: _limits,
            token: (CancellationController()..cancel()).token,
          ),
          throwsFormatException,
        );
        final separator = _response(
          rotation: rotation.degrees,
          records: [
            [32, null],
          ],
        );
        expect(
          () => projectLinuxPdfExtraction(
            response: separator,
            operation: _request(),
            reference: reference,
            region: geometryOk(
              PdfPageClip.create(left: 0, top: 0, right: .5, bottom: 1),
            ),
            limits: _limits,
            token: CancellationController().token,
          ),
          throwsA(isA<LinuxPdfExtractionUnsupported>()),
        );
      },
    );
  }
}
