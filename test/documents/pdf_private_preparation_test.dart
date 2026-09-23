// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/pdf/pdf_admission_policy.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_backend.dart';
import 'package:al_note/documents/pdf/src/linux/linux_pdf_protocol.dart';
import 'package:al_note/documents/pdf/src/pdf_source_preparation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdf_geometry_checks.dart';

Uint8List _frame(Object value) {
  final bytes = utf8.encode(jsonEncode(value));
  return Uint8List.fromList([
    ...(ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List(),
    ...bytes,
  ]);
}

void main() {
  test('private admission is compiled Linux debug opt-in, never fixture enrollment', () {
    final backend = createLinuxIsolatedPdfBackend();
    final policy = pdfAdmissionFor(backend);
    final enabled =
        Platform.isLinux &&
        Abi.current() == Abi.linuxX64 &&
        !const bool.fromEnvironment('dart.vm.product') &&
        !const bool.fromEnvironment('dart.vm.profile') &&
        const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_PDF_TEST');
    expect(policy.ordinaryInputEnabled, enabled);
    expect(
      policy.trust,
      enabled
          ? PdfInputTrust.untrusted
          : PdfInputTrust.trustedDevelopmentFixture,
    );
    final ordinary = Uint8List.fromList('%PDF-ordinary-test'.codeUnits);
    final cancellation = CancellationController();
    expect(policy.permits(ordinary, cancellation.token), enabled);
    expect(PdfFixtureAdmission.permits(ordinary, cancellation.token), isFalse);
    cancellation.cancel();
    expect(policy.permits(ordinary, cancellation.token), isFalse);
  });

  test('private guard bounds before reading and retains ownership through cancellation', () async {
    final backend = createLinuxIsolatedPdfBackend(
      bundle: Directory('build/missing-private-test-package'),
    );
    final limits = geometryOk(
      PdfProcessingLimits.create(
        maximumEncodedBytes: 51000000,
        maximumPageCount: 1,
        maximumRenderDimension: 1,
        maximumRenderPixels: 1,
        maximumExtractedGlyphs: 1,
        maximumLinks: 1,
        maximumOperations: 1,
      ),
    );
    final token = CancellationController();
    final reader = _PendingReader();
    PdfInspectRequest request(CancellationToken token) => PdfInspectRequest(
      resourceIdentity: geometryIdentity,
      trust: PdfInputTrust.untrusted,
      modelLimits: geometryModelLimits,
      limits: limits,
      cancellationToken: token,
    );
    final first = backend.inspect(request(token.token), resourceReader: reader);
    expect(reader.maximumBytes, 50000000);
    token.cancel();
    final second = await backend.inspect(
      request(CancellationController().token),
      resourceReader: reader,
    );
    expect(second, isA<PdfBackendBusy>());
    expect(reader.reads, 1);
    reader.done.complete();
    expect(await first, isA<PdfInspectionCancelled>());
    expect(
      await backend.inspect(
        request(CancellationController().token),
        resourceReader: reader,
      ),
      isA<PdfQuarantined>(),
    );
    expect(reader.reads, 2);
  }, skip: !linuxPrivatePdfTestEnabled);

  test('rejection frames are closed, exact, complete and cannot carry raster output', () {
    for (final render in [false, true]) {
      for (final reason in LinuxPdfRejection.values) {
        final frames = LinuxPdfFrames(
          width: 1,
          height: 1,
          render: render,
          onReady: () {},
        );
        final wire = [
          ..._frame({'ready': true}),
          ..._frame({
            'version': 1,
            'id': 1,
            'status': 'rejected',
            'reason': reason.name,
          }),
        ];
        for (final byte in wire) {
          frames.add([byte]);
        }
        frames.finish();
        expect(frames.rejection, reason);
        expect(frames.frames, hasLength(2));
        expect(() => frames.add([0]), throwsFormatException);
        frames.discard();
        expect(frames.frames, isEmpty);
        expect(frames.rejection, isNull);
      }
      for (final bad in [
        {'reason': 'unknown'},
        {'reason': true},
        {'reason': 'failed', 'detail': 'secret'},
        {'id': 1.0},
        {'version': true},
      ]) {
        final frames = LinuxPdfFrames(
          width: 1,
          height: 1,
          render: render,
          onReady: () {},
        )..add(_frame({'ready': true}));
        expect(
          () => frames.add(
            _frame({
              'version': 1,
              'id': 1,
              'status': 'rejected',
              'reason': 'failed',
              ...bad,
            }),
          ),
          throwsFormatException,
        );
      }
    }
  });

  test(
    'prepared source owns immutable typed bytes, digest and snapshot identity',
    () async {
      final input = Uint8List.fromList(List.generate(200000, (i) => i % 256));
      final expected = (Sha256Digest.calculate(
        input,
      ) as Ok<Sha256Digest, StructuredFailure>).value;
      final captured = await preparePdfSource(
        input,
        input.length,
        CancellationController().token,
      );
      input.fillRange(0, input.length, 0);
      expect(captured.digest, expected);
      expect(captured.bytes[1], 1);
      expect(() => captured.bytes[0] = 3, throwsUnsupportedError);
      expect(
        () => captured.bytes.buffer.asUint8List()[0] = 3,
        throwsUnsupportedError,
      );
      final id = ResourceIdentity.fromUuid(
        (UuidIdentifier.parse(
          '00000000-0000-4000-8000-000000000001',
        ) as Ok<UuidIdentifier, StructuredFailure>).value,
      );
      final resource = DocumentResource.fromCaptured(
        identity: id,
        mediaType: pdfResourceMediaType,
        role: pdfSourceResourceRole,
        schemaVersion: pdfPageReferenceSchemaVersion,
        captured: captured,
      );
      final snapshot = DocumentResourceSnapshot(resource);
      expect(identical(snapshot.bytes, captured.bytes), isTrue);
      final limits = (PdfProcessingLimits.create(
        maximumEncodedBytes: 200000,
        maximumPageCount: 1,
        maximumRenderDimension: 1,
        maximumRenderPixels: 1,
        maximumExtractedGlyphs: 1,
        maximumLinks: 1,
        maximumOperations: 1,
      ) as Ok<PdfProcessingLimits, StructuredFailure>).value;
      final source = (PdfResourceBytes.fromSnapshot(
        resource: snapshot,
        limits: limits,
        cancellationToken: CancellationController().token,
      ) as Ok<PdfResourceBytes, StructuredFailure>).value;
      expect(identical(source.bytes, captured.bytes), isTrue);
      expect(resource.digest, expected);
      expect(resource.packagePath, endsWith(expected.hexadecimal));
    },
  );

  test(
    'background preparation rejects bounds, invalid octets and cancellation',
    () async {
      final token = CancellationController().token;
      await expectLater(
        preparePdfSource([0, 256], 2, token),
        throwsFormatException,
      );
      await expectLater(
        preparePdfSource([1, 2], 1, token),
        throwsFormatException,
      );
      await expectLater(preparePdfSource([], 1, token), throwsFormatException);
      final cancellation = CancellationController();
      final pending = preparePdfSource(
        Uint8List(50000000),
        50000000,
        cancellation.token,
      );
      final timer = Timer(const Duration(milliseconds: 5), cancellation.cancel);
      await expectLater(pending, throwsFormatException);
      timer.cancel();
      final recovered = await preparePdfSource([1, 2, 3], 3, token);
      expect(recovered.bytes, [1, 2, 3]);
    },
  );
}

final class _PendingReader implements PdfResourceReader {
  final done = Completer<void>();
  int reads = 0;
  int? maximumBytes;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async {
    reads++;
    maximumBytes = limits.maximumEncodedBytes;
    await done.future;
    return Err(
      StructuredFailure(
        code: 'test.unavailable',
        category: FailureCategory.resource,
        retryDisposition: RetryDisposition.never,
        message: 'Unavailable.',
      ),
    );
  }
}
