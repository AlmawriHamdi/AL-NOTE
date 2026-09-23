// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../support/pdf_geometry_checks.dart';

void main() {
  setUpAll(() async {
    // Avoid platform-channel temp-directory lookup in the headless native
    // test host. Web ignores this native-only cache setting.
    pdfrx.Pdfrx.cacheDirectoryPath = '.';
    await pdfrx.pdfrxFlutterInitialize();
  });

  test('marked native geometry, exact reopen mapping and rejection', () async {
    final results = await checkMarkedPdfGeometry();
    expect(results, hasLength(40));
    // Full results are also emitted by the real-browser parity harness.
    // ignore: avoid_print
    print('MARKED_NATIVE ${jsonEncode(results)}');
  });

  test('adapter accepts only exact binary32 extent rounding', () async {
    final actual = pdfrx.PdfrxEntryFunctions.instance;
    final endpoints = Float32List.fromList([10.1, 20.2, 210.3, 120.4]);
    final width = endpoints[2] - endpoints[0];
    final height = endpoints[3] - endpoints[1];
    final rounded = Float32List.fromList([width, height]);
    try {
      for (final delta in [0.0, 0.0000152587890625, 1.0, 50.0]) {
        final document = _EvidenceDocument(
          pdfrx.PdfPageBoxEvidence(
            kind: pdfrx.PdfPageBoxKind.resolvedBounds,
            left: endpoints[0],
            bottom: endpoints[1],
            right: endpoints[2],
            top: endpoints[3],
            rotation: pdfrx.PdfPageRotation.none,
            displayedWidth: rounded[0] + delta,
            displayedHeight: rounded[1],
          ),
        );
        pdfrx.PdfrxEntryFunctions.instance = _EvidenceEntry(document);
        final outcome = await createTrustedDevelopmentPdfBackend().inspect(
          PdfInspectRequest(
            resourceIdentity: geometryIdentity,
            trust: PdfInputTrust.trustedDevelopmentFixture,
            modelLimits: geometryModelLimits,
            limits: geometryProcessingLimits,
            cancellationToken: CancellationController().token,
          ),
          resourceReader: GeometryReader(markedPdf(geometryCases.first, 0)),
        );
        if (delta == 0) {
          expect(outcome, isA<PdfInspectSuccess>());
          final page = (outcome as PdfInspectSuccess).pages.single;
          expect(page.displayedWidth, width);
          expect(page.displayedHeight, height);
          // Receiving contracts retain exact equality, including sub-ULP errors.
          expect(
            PdfPageReference.create(
              resourceIdentity: geometryIdentity,
              pageIndex: 0,
              boxKind: page.boxKind,
              sourceBox: page.sourceBox,
              rotation: page.rotation,
              displayedWidth: rounded[0],
              displayedHeight: rounded[1],
              limits: geometryModelLimits,
            ),
            isA<Err<PdfPageReference, StructuredFailure>>(),
          );
        } else {
          expect(outcome, isA<PdfCorrupt>());
        }
        expect(document.disposals, 1);
      }
    } finally {
      pdfrx.PdfrxEntryFunctions.instance = actual;
    }
  });

  test('patched pdfrx exposes exact effective boxes and rotations', () async {
    final document = await pdfrx.PdfDocument.openData(
      _pdf(<_PageSpec>[
        const _PageSpec(mediaBox: '0 0 612 792', cropBox: '10 20 210 120'),
        const _PageSpec(
          mediaBox: '-100 -200 500 600',
          cropBox: '-40 -30 160 70',
          rotation: 90,
        ),
        const _PageSpec(mediaBox: '5 7 205 107', rotation: 180),
        const _PageSpec(
          mediaBox: '-5 -7 195 93',
          cropBox: '90 50 10 20',
          rotation: 270,
        ),
      ]),
      sourceName: 'bounded-test-fixture',
    );
    try {
      expect(document.pages, hasLength(4));
      _expectPage(
        document.pages[0],
        kind: pdfrx.PdfPageBoxKind.resolvedBounds,
        box: const <double>[10, 20, 210, 120],
        rotation: pdfrx.PdfPageRotation.none,
      );
      _expectPage(
        document.pages[1],
        kind: pdfrx.PdfPageBoxKind.resolvedBounds,
        box: const <double>[-40, -30, 160, 70],
        rotation: pdfrx.PdfPageRotation.clockwise90,
      );
      _expectPage(
        document.pages[2],
        kind: pdfrx.PdfPageBoxKind.resolvedBounds,
        box: const <double>[5, 7, 205, 107],
        rotation: pdfrx.PdfPageRotation.clockwise180,
      );
      _expectPage(
        document.pages[3],
        kind: pdfrx.PdfPageBoxKind.resolvedBounds,
        box: const <double>[10, 20, 90, 50],
        rotation: pdfrx.PdfPageRotation.clockwise270,
      );
    } finally {
      await document.dispose();
    }
  });

  test(
    'reversed CropBox is normalized and disjoint boxes fail closed',
    () async {
      final validFallback = await pdfrx.PdfDocument.openData(
        _pdf(const <_PageSpec>[
          _PageSpec(mediaBox: '0 0 200 100', cropBox: '20 20 10 10'),
        ]),
        sourceName: 'fallback-fixture',
      );
      try {
        expect(
          validFallback.pages.single.effectivePageBox!.kind,
          pdfrx.PdfPageBoxKind.resolvedBounds,
        );
      } finally {
        await validFallback.dispose();
      }

      await expectLater(
        pdfrx.PdfDocument.openData(
          _pdf(const <_PageSpec>[
            _PageSpec(mediaBox: '0 0 100 100', cropBox: '200 200 300 300'),
          ]),
          sourceName: 'invalid-box-fixture',
        ),
        throwsA(anything),
      );
    },
  );

  test(
    'public evidence rejects nonfinite, empty, and invalid display data',
    () {
      pdfrx.PdfPageBoxEvidence create({
        double left = 0,
        double bottom = 0,
        double right = 1,
        double top = 1,
        double width = 1,
        double height = 1,
      }) => pdfrx.PdfPageBoxEvidence(
        kind: pdfrx.PdfPageBoxKind.resolvedBounds,
        left: left,
        bottom: bottom,
        right: right,
        top: top,
        rotation: pdfrx.PdfPageRotation.none,
        displayedWidth: width,
        displayedHeight: height,
      );

      for (final attempt in <pdfrx.PdfPageBoxEvidence Function()>[
        () => create(left: double.nan),
        () => create(bottom: double.negativeInfinity),
        () => create(right: double.infinity),
        () => create(top: double.nan),
        () => create(right: 0),
        () => create(top: 0),
        () => create(width: 0),
        () => create(height: double.infinity),
      ]) {
        expect(attempt, throwsA(isA<pdfrx.PdfPageBoxException>()));
      }
      expect(create().toString(), 'PdfPageBoxEvidence(validated: true)');
      expect(
        const pdfrx.PdfPageBoxException().toString(),
        'PdfPageBoxException(invalid page box)',
      );
    },
  );

  test('private AL NOTE adapter consumes exact evidence and renders', () async {
    final bytes = _pdf(const <_PageSpec>[
      _PageSpec(
        mediaBox: '-100 -200 500 600',
        cropBox: '-40 -30 160 70',
        rotation: 90,
      ),
    ]);
    final identity = ResourceIdentity.fromUuid(
      _ok(UuidIdentifier.parse('00000000-0000-4000-8000-000000000901')),
    );
    final reader = _MemoryReader(identity, bytes);
    final backend = createTrustedDevelopmentPdfBackend();
    final cancellation = CancellationController();
    final inspected = await backend.inspect(
      PdfInspectRequest(
        resourceIdentity: identity,
        trust: PdfInputTrust.trustedDevelopmentFixture,
        modelLimits: _modelLimits,
        limits: _processingLimits,
        cancellationToken: cancellation.token,
      ),
      resourceReader: reader,
    );

    expect(inspected, isA<PdfInspectSuccess>());
    final page = (inspected as PdfInspectSuccess).pages.single;
    expect(page.boxKind, PdfPageBoxKind.resolvedBounds);
    expect(page.sourceBox.left, -40);
    expect(page.sourceBox.bottom, -30);
    expect(page.sourceBox.right, 160);
    expect(page.sourceBox.top, 70);
    expect(page.rotation, PdfPageRotation.degrees90);
    expect(page.displayedWidth, 100);
    expect(page.displayedHeight, 200);

    final reference = _ok(
      PdfPageReference.create(
        resourceIdentity: identity,
        pageIndex: page.pageIndex,
        // Legacy saved kind remains renderable with exactly matching geometry.
        boxKind: PdfPageBoxKind.cropBox,
        sourceBox: page.sourceBox,
        rotation: page.rotation,
        displayedWidth: page.displayedWidth,
        displayedHeight: page.displayedHeight,
        limits: _modelLimits,
      ),
    );
    final renderRequest = _ok(
      PdfRenderRequest.create(
        reference: reference,
        trust: PdfInputTrust.trustedDevelopmentFixture,
        region: PdfPageClip.full,
        pixelWidth: 32,
        pixelHeight: 16,
        includeSafeNativeAppearances: false,
        limits: _processingLimits,
        cancellationToken: cancellation.token,
      ),
    );
    final rendered = await backend.render(
      renderRequest,
      resourceReader: reader,
    );
    expect(rendered, isA<PdfRenderSuccess>());
    final output = (rendered as PdfRenderSuccess).output;
    expect(output.rgbaBytes, hasLength(32 * 16 * 4));
    expect(output.rgbaBytes.every((value) => value == 255), isTrue);
    expect(reader.calls, 2);
  });

  test(
    'private adapter quarantines before reading and fails redaction-safe',
    () async {
      final bytes = _pdf(const <_PageSpec>[_PageSpec(mediaBox: '0 0 200 100')]);
      final identity = ResourceIdentity.fromUuid(
        _ok(UuidIdentifier.parse('00000000-0000-4000-8000-000000000902')),
      );
      final reader = _MemoryReader(identity, bytes);
      final backend = createTrustedDevelopmentPdfBackend();
      final outcome = await backend.inspect(
        PdfInspectRequest(
          resourceIdentity: identity,
          trust: PdfInputTrust.untrusted,
          modelLimits: _modelLimits,
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
        resourceReader: reader,
      );
      expect(outcome, isA<PdfQuarantined>());
      expect(reader.calls, 0);
      expect(outcome.toString(), isNot(contains('000000000902')));
      expect(outcome.toString(), isNot(contains('%PDF')));
    },
  );

  test(
    'private adapter classifies malformed bytes without leaking them',
    () async {
      final identity = ResourceIdentity.fromUuid(
        _ok(UuidIdentifier.parse('00000000-0000-4000-8000-000000000903')),
      );
      final outcome = await createTrustedDevelopmentPdfBackend().inspect(
        PdfInspectRequest(
          resourceIdentity: identity,
          trust: PdfInputTrust.trustedDevelopmentFixture,
          modelLimits: _modelLimits,
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
        resourceReader: _MemoryReader(
          identity,
          latin1.encode('%PDF-1.7\n1 0 obj\n<< /Type /Catalog'),
        ),
      );
      expect(outcome, isA<PdfCorrupt>());
      expect(outcome.toString(), isNot(contains('1, 2, 3')));
    },
  );

  test('private adapter enforces page and geometry ceilings exactly', () async {
    PdfProcessingLimits processingLimits(int pageCount) => _ok(
      PdfProcessingLimits.create(
        maximumEncodedBytes: 1024 * 1024,
        maximumPageCount: pageCount,
        maximumRenderDimension: 1024,
        maximumRenderPixels: 1024 * 1024,
        maximumExtractedGlyphs: 4096,
        maximumLinks: 128,
        maximumOperations: 128,
      ),
    );
    PdfModelLimits modelLimits(double dimension) => _ok(
      PdfModelLimits.create(
        maximumPageCount: 16,
        maximumCoordinateMagnitude: 10000,
        maximumPageDimension: dimension,
        maximumPageArea: 100000000,
        maximumUnknownFields: 16,
        maximumUnknownNodes: 256,
        maximumNestingDepth: 8,
        maximumUnknownStringCodeUnits: 4096,
      ),
    );
    Future<PdfInspectOutcome> inspect({
      required List<_PageSpec> pages,
      required PdfModelLimits models,
      required PdfProcessingLimits processing,
      required int discriminator,
    }) {
      final identity = ResourceIdentity.fromUuid(
        _ok(
          UuidIdentifier.parse(
            '00000000-0000-4000-8000-${discriminator.toString().padLeft(12, '0')}',
          ),
        ),
      );
      return createTrustedDevelopmentPdfBackend().inspect(
        PdfInspectRequest(
          resourceIdentity: identity,
          trust: PdfInputTrust.trustedDevelopmentFixture,
          modelLimits: models,
          limits: processing,
          cancellationToken: CancellationController().token,
        ),
        resourceReader: _MemoryReader(identity, _pdf(pages)),
      );
    }

    expect(
      await inspect(
        pages: const <_PageSpec>[
          _PageSpec(mediaBox: '0 0 200 100'),
          _PageSpec(mediaBox: '0 0 200 100'),
        ],
        models: modelLimits(200),
        processing: processingLimits(1),
        discriminator: 904,
      ),
      isA<PdfInspectionLimitExceeded>(),
    );
    expect(
      await inspect(
        pages: const <_PageSpec>[_PageSpec(mediaBox: '0 0 200 100')],
        models: modelLimits(199),
        processing: processingLimits(1),
        discriminator: 905,
      ),
      isA<PdfInspectionLimitExceeded>(),
    );
    final exact = await inspect(
      pages: const <_PageSpec>[_PageSpec(mediaBox: '0 0 200 100')],
      models: modelLimits(200),
      processing: processingLimits(1),
      discriminator: 906,
    );
    expect(exact, isA<PdfInspectSuccess>());
    expect((exact as PdfInspectSuccess).pages.single.displayedWidth, 200);
  });

  test(
    'local open workflow atomically builds shared multipage source',
    () async {
      final bytes = _pdf(const <_PageSpec>[
        _PageSpec(mediaBox: '0 0 200 100', cropBox: '10 20 190 90'),
        _PageSpec(mediaBox: '-20 -40 280 160', rotation: 270),
      ]);
      final workflow = LocalPdfOpenWorkflow(
        selector: LocalPdfFileSelector(host: _Picker(_Handle(bytes))),
        backend: createTrustedDevelopmentPdfBackend(),
        modelLimits: _modelLimits,
        processingLimits: _processingLimits,
      );

      final outcome = await workflow.open(
        cancellationToken: CancellationController().token,
        stillCurrent: () => true,
      );

      expect(outcome, isA<LocalPdfOpenSuccess>());
      final opened = outcome as LocalPdfOpenSuccess;
      expect(opened.root.pages, hasLength(2));
      expect(opened.root.resources.entries, hasLength(1));
      expect(opened.root.source.identity, opened.resource.identity);
      expect(opened.resource.bytes, bytes);
      expect(opened.root.pages[0].size.width, 180);
      expect(opened.root.pages[0].size.height, 70);
      expect(opened.root.pages[1].size.width, 200);
      expect(opened.root.pages[1].size.height, 300);
      for (var index = 0; index < opened.root.pages.length; index += 1) {
        final page = opened.root.pages[index];
        expect(page.layers, hasLength(2));
        expect(page.layers.first, isA<PdfSourceLayer>());
        expect(page.layers.last, isA<ContentLayer>());
        final source = page.layers.first as PdfSourceLayer;
        expect(source.locked, isTrue);
        expect(source.reference.pageIndex, index);
        expect(source.reference.resourceIdentity, opened.resource.identity);
      }
      expect(outcome.toString(), isNot(contains('%PDF')));
    },
  );
}

final PdfModelLimits _modelLimits = _ok(
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

final PdfProcessingLimits _processingLimits = _ok(
  PdfProcessingLimits.create(
    maximumEncodedBytes: 1024 * 1024,
    maximumPageCount: 16,
    maximumRenderDimension: 1024,
    maximumRenderPixels: 1024 * 1024,
    maximumExtractedGlyphs: 4096,
    maximumLinks: 128,
    maximumOperations: 128,
  ),
);

void _expectPage(
  pdfrx.PdfPage page, {
  required pdfrx.PdfPageBoxKind kind,
  required List<double> box,
  required pdfrx.PdfPageRotation rotation,
}) {
  final evidence = page.effectivePageBox;
  expect(page.isLoaded, isTrue);
  expect(evidence, isNotNull);
  expect(evidence!.kind, kind);
  expect(<double>[
    evidence.left,
    evidence.bottom,
    evidence.right,
    evidence.top,
  ], box);
  expect(evidence.rotation, rotation);
  expect(evidence.displayedWidth, page.width);
  expect(evidence.displayedHeight, page.height);
}

final class _PageSpec {
  const _PageSpec({required this.mediaBox, this.cropBox, this.rotation = 0});

  final String mediaBox;
  final String? cropBox;
  final int rotation;
}

Uint8List _pdf(List<_PageSpec> pages) {
  final contentObject = pages.length + 3;
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count ${pages.length} /Kids '
        '[${[for (var index = 0; index < pages.length; index += 1) '${index + 3} 0 R'].join(' ')}] >>',
    for (var index = 0; index < pages.length; index += 1)
      '<< /Type /Page /Parent 2 0 R '
          '/MediaBox [${pages[index].mediaBox}] '
          '${pages[index].cropBox == null ? '' : '/CropBox [${pages[index].cropBox}] '}'
          '${pages[index].rotation == 0 ? '' : '/Rotate ${pages[index].rotation} '}'
          '/Resources <<>> /Contents $contentObject 0 R >>',
    '<< /Length 0 >>\nstream\n\nendstream',
  ];

  final bytes = BytesBuilder(copy: false);
  void write(String value) => bytes.add(latin1.encode(value));
  write('%PDF-1.7\n%\u00e2\u00e3\u00cf\u00d3\n');
  final offsets = <int>[0];
  for (var index = 0; index < objects.length; index += 1) {
    offsets.add(bytes.length);
    write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = bytes.length;
  write('xref\n0 ${objects.length + 1}\n');
  write('0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return bytes.takeBytes();
}

T _ok<T>(Result<T, StructuredFailure> result) =>
    (result as Ok<T, StructuredFailure>).value;

final class _MemoryReader implements PdfResourceReader {
  _MemoryReader(this.identity, this.bytes);

  final ResourceIdentity identity;
  final List<int> bytes;
  int calls = 0;

  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async {
    calls += 1;
    return PdfResourceBytes.capture(
      identity: this.identity,
      bytes: bytes,
      limits: limits,
      cancellationToken: cancellationToken,
    );
  }
}

final class _Picker implements LocalPdfPickerHost {
  const _Picker(this.handle);

  final LocalPdfFileHandle? handle;

  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => handle;
}

final class _Handle implements LocalPdfFileHandle {
  const _Handle(this.bytes);

  final List<int> bytes;

  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) => Stream<List<int>>.value(bytes);
}

// Controlled boundary evidence: no PDF parser mocking is used in marked tests.
final class _EvidenceEntry implements pdfrx.PdfrxEntryFunctions {
  _EvidenceEntry(this.document);
  final _EvidenceDocument document;
  @override
  Future<pdfrx.PdfDocument> openData(
    Uint8List data, {
    pdfrx.PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    String? sourceName,
    bool allowDataOwnershipTransfer = false,
    bool useProgressiveLoading = false,
    void Function()? onDispose,
  }) async => document;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _EvidenceDocument extends pdfrx.PdfDocument {
  _EvidenceDocument(this.evidence) : super(sourceName: 'controlled-evidence');
  final pdfrx.PdfPageBoxEvidence evidence;
  int disposals = 0;
  @override
  bool get isEncrypted => false;
  @override
  List<pdfrx.PdfPage> get pages => [_EvidencePage(evidence)];
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _EvidencePage implements pdfrx.PdfPage {
  _EvidencePage(this.effectivePageBox);
  @override
  final pdfrx.PdfPageBoxEvidence effectivePageBox;
  @override
  bool get isLoaded => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
