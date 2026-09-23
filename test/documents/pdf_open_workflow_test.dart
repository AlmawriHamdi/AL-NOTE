// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdf_geometry_checks.dart';

final PdfModelLimits _modelLimits = _ok(
  PdfModelLimits.create(
    maximumPageCount: 8,
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
    maximumEncodedBytes: 1024,
    maximumPageCount: 8,
    maximumRenderDimension: 512,
    maximumRenderPixels: 262144,
    maximumExtractedGlyphs: 1024,
    maximumLinks: 64,
    maximumOperations: 64,
  ),
);

void main() {
  group('atomic local PDF open workflow', () {
    test('stale backend completion is cancelled without publication', () async {
      final backend = _DelayedBackend();
      final workflow = _workflow(backend);
      var current = true;
      final operation = workflow.open(
        cancellationToken: CancellationController().token,
        stillCurrent: () => current,
      );
      await backend.entered.future;
      current = false;
      backend.completeSuccess();

      final outcome = await operation;

      expect(outcome, isA<LocalPdfOpenCancelled>());
      expect(outcome.toString(), isNot(contains('%PDF')));
    });

    test('mid-inspection cancellation publishes no prepared state', () async {
      final backend = _DelayedBackend();
      final workflow = _workflow(backend);
      final cancellation = CancellationController();
      final operation = workflow.open(
        cancellationToken: cancellation.token,
        stillCurrent: () => true,
      );
      await backend.entered.future;
      cancellation.cancel('secret selected path');
      backend.completeSuccess();

      final outcome = await operation;

      expect(outcome, isA<LocalPdfOpenCancelled>());
      expect(outcome.toString(), isNot(contains('secret')));
    });

    test(
      'stale selection never reaches admission or backend inspection',
      () async {
        final host = _PendingPicker();
        final backend = _DelayedBackend();
        var current = true;
        final operation =
            LocalPdfOpenWorkflow(
              selector: LocalPdfFileSelector(host: host),
              backend: backend,
              modelLimits: _modelLimits,
              processingLimits: _processingLimits,
            ).open(
              cancellationToken: CancellationController().token,
              stillCurrent: () => current,
            );
        current = false;
        host.done.complete(_Handle(markedPdf(geometryCases.first, 0)));
        expect(await operation, isA<LocalPdfOpenCancelled>());
        expect(backend.entered.isCompleted, isFalse);
      },
    );

    test('fixed backend outcomes remain redaction-safe and unbuilt', () async {
      for (final outcome in <PdfInspectOutcome>[
        const PdfPasswordRequired(),
        const PdfUnsupportedEncryption(),
        const PdfUnsupported(),
        const PdfInspectionFailed(),
        const PdfCorrupt(),
        const PdfMissing(),
        const PdfQuarantined(),
        const PdfInspectionLimitExceeded(),
        const PdfBackendUnavailable(),
        const PdfBackendBusy(),
      ]) {
        final backend = _ImmediateBackend(outcome);
        final result = await _workflow(backend).open(
          cancellationToken: CancellationController().token,
          stillCurrent: () => true,
        );
        expect(result, isA<LocalPdfOpenFailure>());
        expect(result, isNot(isA<LocalPdfOpenSuccess>()));
        expect(result.toString(), isNot(contains('%PDF')));
        expect(result.toString(), isNot(contains('password-value')));
      }
    });
  });
}

LocalPdfOpenWorkflow _workflow(PdfBackend backend) => LocalPdfOpenWorkflow(
  selector: LocalPdfFileSelector(
    host: _Picker(markedPdf(geometryCases.first, 0)),
  ),
  backend: backend,
  modelLimits: _modelLimits,
  processingLimits: _processingLimits,
);

final class _Picker implements LocalPdfPickerHost {
  const _Picker(this.bytes);

  final List<int> bytes;

  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => _Handle(bytes);
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

final class _DelayedBackend extends _BackendBase {
  final Completer<void> entered = Completer<void>();
  final Completer<PdfInspectOutcome> _completion =
      Completer<PdfInspectOutcome>();
  PdfInspectRequest? _request;

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) {
    _request = request;
    entered.complete();
    return _completion.future;
  }

  void completeSuccess() {
    _completion.complete(_success(_request!));
  }
}

final class _ImmediateBackend extends _BackendBase {
  _ImmediateBackend(this.outcome);

  final PdfInspectOutcome outcome;

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async => outcome;
}

abstract base class _BackendBase implements PdfBackend {
  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async => const PdfRenderFailure(PdfRenderFailureReason.backendUnavailable);

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfExtractedText, StructuredFailure>(_failure());

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfSafeLinks, StructuredFailure>(_failure());
}

PdfInspectOutcome _success(PdfInspectRequest request) {
  final box = _ok(
    PdfSourceBox.create(
      left: 0,
      bottom: 0,
      right: 200,
      top: 100,
      limits: _modelLimits,
    ),
  );
  final page = _ok(
    PdfInspectedPage.create(
      pageIndex: 0,
      boxKind: PdfPageBoxKind.mediaBox,
      sourceBox: box,
      rotation: PdfPageRotation.degrees0,
      displayedWidth: 200,
      displayedHeight: 100,
      limits: _modelLimits,
    ),
  );
  return PdfInspectSuccess.capture(
    backendIdentity: _ok(PdfBackendIdentity.parse('test.delayed')),
    pages: <PdfInspectedPage>[page],
    modelLimits: _modelLimits,
    limits: request.limits,
    cancellationToken: CancellationController().token,
  );
}

StructuredFailure _failure() => StructuredFailure(
  code: 'test.pdf.unavailable',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'Unavailable.',
);

T _ok<T>(Result<T, StructuredFailure> result) =>
    (result as Ok<T, StructuredFailure>).value;

final class _PendingPicker implements LocalPdfPickerHost {
  final done = Completer<LocalPdfFileHandle?>();
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) => done.future;
}
