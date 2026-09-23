// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../../core/outcomes/cancellation.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../model/identifiers.dart';
import '../pdf_backend.dart';
import '../pdf_fixture_admission.dart';
import '../pdf_model.dart';

/// Creates the replaceable trusted-development PDF backend.
///
/// The concrete adapter and every pdfrx-owned value remain private to this
/// library. Ordinary untrusted input is rejected before resource access.
PdfBackend createTrustedDevelopmentPdfBackend() =>
    DevelopmentFixturePdfBackend(delegate: _PdfrxPdfBackend());

final class _PdfrxPdfBackend implements PdfBackend {
  static final PdfBackendIdentity _identity = (PdfBackendIdentity.parse(
    'alnote.pdfrx.local-2.4.8',
  ) as Ok<PdfBackendIdentity, StructuredFailure>).value;

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    if (request.cancellationToken.isCancelled) {
      return const PdfInspectionCancelled();
    }
    if (request.trust != PdfInputTrust.trustedDevelopmentFixture) {
      return const PdfQuarantined();
    }

    final resource = await _readResource(
      identity: request.resourceIdentity,
      limits: request.limits,
      cancellationToken: request.cancellationToken,
      resourceReader: resourceReader,
    );
    if (resource == null) {
      return request.cancellationToken.isCancelled
          ? const PdfInspectionCancelled()
          : const PdfMissing();
    }

    final transientBytes = Uint8List.fromList(resource.bytes);
    pdfrx.PdfDocument? document;
    try {
      await pdfrx.pdfrxFlutterInitialize();
      if (request.cancellationToken.isCancelled) {
        return const PdfInspectionCancelled();
      }
      document = await pdfrx.PdfDocument.openData(
        transientBytes,
        sourceName: 'alnote-local-pdf',
        passwordProvider: () => null,
      );
      if (request.cancellationToken.isCancelled) {
        return const PdfInspectionCancelled();
      }
      if (document.isEncrypted) return const PdfUnsupportedEncryption();
      if (document.pages.isEmpty ||
          document.pages.length > request.limits.maximumPageCount ||
          document.pages.length > request.modelLimits.maximumPageCount) {
        return const PdfInspectionLimitExceeded();
      }

      final pages = <PdfInspectedPage>[];
      var operations = 0;
      for (var index = 0; index < document.pages.length; index += 1) {
        operations += 1;
        if (request.cancellationToken.isCancelled) {
          return const PdfInspectionCancelled();
        }
        if (operations > request.limits.maximumOperations) {
          return const PdfInspectionLimitExceeded();
        }
        final page = document.pages[index];
        final evidence = page.effectivePageBox;
        if (!page.isLoaded || evidence == null) return const PdfCorrupt();
        final dimensions = _resolvedDimensions(evidence);
        if (dimensions == null) return const PdfCorrupt();
        final sourceBox = PdfSourceBox.create(
          left: evidence.left,
          bottom: evidence.bottom,
          right: evidence.right,
          top: evidence.top,
          limits: request.modelLimits,
        );
        if (sourceBox is! Ok<PdfSourceBox, StructuredFailure>) {
          return const PdfInspectionLimitExceeded();
        }
        final inspected = PdfInspectedPage.create(
          pageIndex: index,
          boxKind: switch (evidence.kind) {
            pdfrx.PdfPageBoxKind.cropBox => PdfPageBoxKind.cropBox,
            pdfrx.PdfPageBoxKind.mediaBox => PdfPageBoxKind.mediaBox,
            pdfrx.PdfPageBoxKind.resolvedBounds =>
              PdfPageBoxKind.resolvedBounds,
          },
          sourceBox: sourceBox.value,
          rotation: _rotation(evidence.rotation),
          displayedWidth: dimensions.width,
          displayedHeight: dimensions.height,
          limits: request.modelLimits,
        );
        if (inspected is! Ok<PdfInspectedPage, StructuredFailure>) {
          return const PdfInspectionLimitExceeded();
        }
        pages.add(inspected.value);
      }
      return PdfInspectSuccess.capture(
        backendIdentity: _identity,
        pages: pages,
        modelLimits: request.modelLimits,
        limits: request.limits,
        cancellationToken: request.cancellationToken,
      );
    } on pdfrx.PdfPasswordException {
      return const PdfPasswordRequired();
    } on Object {
      return request.cancellationToken.isCancelled
          ? const PdfInspectionCancelled()
          : const PdfCorrupt();
    } finally {
      try {
        await document?.dispose();
      } on Object {
        // Disposal details are never published or allowed to replace outcomes.
      }
      transientBytes.fillRange(0, transientBytes.length, 0);
    }
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    if (request.cancellationToken.isCancelled) {
      return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
    }
    if (request.trust != PdfInputTrust.trustedDevelopmentFixture) {
      return const PdfRenderFailure(PdfRenderFailureReason.quarantined);
    }
    final resource = await _readResource(
      identity: request.reference.resourceIdentity,
      limits: request.limits,
      cancellationToken: request.cancellationToken,
      resourceReader: resourceReader,
    );
    if (resource == null) {
      return PdfRenderFailure(
        request.cancellationToken.isCancelled
            ? PdfRenderFailureReason.cancelled
            : PdfRenderFailureReason.missing,
      );
    }

    final transientBytes = Uint8List.fromList(resource.bytes);
    pdfrx.PdfDocument? document;
    pdfrx.PdfImage? image;
    pdfrx.PdfPageRenderCancellationToken? renderCancellation;
    void cancelRender(String? _) => renderCancellation?.cancel();
    try {
      await pdfrx.pdfrxFlutterInitialize();
      document = await pdfrx.PdfDocument.openData(
        transientBytes,
        sourceName: 'alnote-local-pdf',
        passwordProvider: () => null,
      );
      if (request.cancellationToken.isCancelled) {
        return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
      }
      if (document.isEncrypted ||
          request.reference.pageIndex >= document.pages.length) {
        return const PdfRenderFailure(PdfRenderFailureReason.corrupt);
      }
      final page = document.pages[request.reference.pageIndex];
      if (!_matchesReference(page, request.reference)) {
        return const PdfRenderFailure(PdfRenderFailureReason.corrupt);
      }

      final fullWidth = request.pixelWidth / request.region.width;
      final fullHeight = request.pixelHeight / request.region.height;
      if (!fullWidth.isFinite ||
          !fullHeight.isFinite ||
          fullWidth <= 0 ||
          fullHeight <= 0 ||
          fullWidth > request.limits.maximumRenderDimension ||
          fullHeight > request.limits.maximumRenderDimension) {
        return const PdfRenderFailure(PdfRenderFailureReason.limitExceeded);
      }
      renderCancellation = page.createCancellationToken();
      request.cancellationToken.addListener(cancelRender);
      image = await page.render(
        x: (request.region.left * fullWidth).round(),
        y: (request.region.top * fullHeight).round(),
        width: request.pixelWidth,
        height: request.pixelHeight,
        fullWidth: fullWidth,
        fullHeight: fullHeight,
        backgroundColor: 0xffffffff,
        annotationRenderingMode: pdfrx.PdfAnnotationRenderingMode.none,
        cancellationToken: renderCancellation,
      );
      if (request.cancellationToken.isCancelled) {
        return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
      }
      if (image == null ||
          image.width != request.pixelWidth ||
          image.height != request.pixelHeight) {
        return const PdfRenderFailure(PdfRenderFailureReason.corrupt);
      }
      final bgra = image.pixels;
      final rgba = Uint8List(bgra.length);
      for (var offset = 0; offset < bgra.length; offset += 4) {
        rgba[offset] = bgra[offset + 2];
        rgba[offset + 1] = bgra[offset + 1];
        rgba[offset + 2] = bgra[offset];
        rgba[offset + 3] = bgra[offset + 3];
      }
      final captured = PdfRenderOutput.capture(
        backendIdentity: _identity,
        region: request.region,
        pixelWidth: request.pixelWidth,
        pixelHeight: request.pixelHeight,
        rgbaBytes: rgba,
        limits: request.limits,
        cancellationToken: request.cancellationToken,
      );
      return captured is Ok<PdfRenderOutput, StructuredFailure>
          ? PdfRenderSuccess(captured.value)
          : const PdfRenderFailure(PdfRenderFailureReason.corrupt);
    } on Object {
      return PdfRenderFailure(
        request.cancellationToken.isCancelled
            ? PdfRenderFailureReason.cancelled
            : PdfRenderFailureReason.corrupt,
      );
    } finally {
      request.cancellationToken.removeListener(cancelRender);
      image?.dispose();
      try {
        await document?.dispose();
      } on Object {
        // Disposal details are never published or allowed to replace outcomes.
      }
      transientBytes.fillRange(0, transientBytes.length, 0);
    }
  }

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfExtractedText, StructuredFailure>(
    _fixedFailure(
      request.cancellationToken.isCancelled
          ? 'cancelled'
          : request.trust == PdfInputTrust.untrusted
          ? 'quarantined'
          : 'unavailable',
    ),
  );

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfSafeLinks, StructuredFailure>(
    _fixedFailure(
      request.cancellationToken.isCancelled
          ? 'cancelled'
          : request.trust == PdfInputTrust.untrusted
          ? 'quarantined'
          : 'unavailable',
    ),
  );

  Future<PdfResourceBytes?> _readResource({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
    required PdfResourceReader resourceReader,
  }) async {
    try {
      final result = await resourceReader.read(
        identity: identity,
        limits: limits,
        cancellationToken: cancellationToken,
      );
      if (result is! Ok<PdfResourceBytes, StructuredFailure> ||
          result.value.identity != identity ||
          cancellationToken.isCancelled) {
        return null;
      }
      return result.value;
    } on Object {
      return null;
    }
  }

  static PdfPageRotation _rotation(pdfrx.PdfPageRotation rotation) =>
      switch (rotation) {
        pdfrx.PdfPageRotation.none => PdfPageRotation.degrees0,
        pdfrx.PdfPageRotation.clockwise90 => PdfPageRotation.degrees90,
        pdfrx.PdfPageRotation.clockwise180 => PdfPageRotation.degrees180,
        pdfrx.PdfPageRotation.clockwise270 => PdfPageRotation.degrees270,
      };

  // PDFium stores endpoints and subtracts them in binary32. Reproduce that
  // single rounding operation exactly; no relative/coordinate-scale epsilon.
  // This permits at most half an ULP of the extent, never a different rectangle.
  // Persist endpoints unchanged and their double differences so saved forward /
  // inverse mapping and receiving-limit validation remain internally exact.
  static ({double width, double height})? _resolvedDimensions(
    pdfrx.PdfPageBoxEvidence evidence,
  ) {
    final swaps = _rotation(evidence.rotation).swapsDimensions;
    final width = swaps
        ? evidence.top - evidence.bottom
        : evidence.right - evidence.left;
    final height = swaps
        ? evidence.right - evidence.left
        : evidence.top - evidence.bottom;
    final rounded = Float32List.fromList([width, height]);
    if (!width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0 ||
        rounded[0] != evidence.displayedWidth ||
        rounded[1] != evidence.displayedHeight) {
      return null;
    }
    return (width: width, height: height);
  }

  static bool _matchesReference(
    pdfrx.PdfPage page,
    PdfPageReference reference,
  ) {
    final evidence = page.effectivePageBox;
    final dimensions = evidence == null ? null : _resolvedDimensions(evidence);
    return page.isLoaded &&
        evidence != null &&
        dimensions != null &&
        page.pageNumber == reference.pageIndex + 1 &&
        evidence.left == reference.sourceBox.left &&
        evidence.bottom == reference.sourceBox.bottom &&
        evidence.right == reference.sourceBox.right &&
        evidence.top == reference.sourceBox.top &&
        dimensions.width == reference.displayedWidth &&
        dimensions.height == reference.displayedHeight &&
        _rotation(evidence.rotation) == reference.rotation &&
        switch (evidence.kind) {
          pdfrx.PdfPageBoxKind.cropBox =>
            reference.boxKind == PdfPageBoxKind.cropBox,
          pdfrx.PdfPageBoxKind.mediaBox =>
            reference.boxKind == PdfPageBoxKind.mediaBox,
          pdfrx.PdfPageBoxKind.resolvedBounds =>
            // Legacy named references remain renderable only when every saved
            // coordinate/dimension above matches. This corroborates geometry,
            // not the old raw-box provenance claim.
            reference.boxKind == PdfPageBoxKind.resolvedBounds ||
                reference.boxKind == PdfPageBoxKind.cropBox ||
                reference.boxKind == PdfPageBoxKind.mediaBox,
        };
  }
}

StructuredFailure _fixedFailure(String suffix) => StructuredFailure(
  code: 'documents.pdf.adapter.$suffix',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'The PDF operation is unavailable.',
);
