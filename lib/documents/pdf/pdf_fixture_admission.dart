// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/primitives.dart';
import '../model/identifiers.dart';
import '../resources/resource_records.dart';
import 'pdf_backend.dart';
import 'src/linux_integration_test_gate_stub.dart'
    if (dart.library.io) 'src/linux_integration_test_gate_io.dart';
import 'src/pdf_operation_scheduler.dart';
import 'src/reviewed_pdf_fixture_digests.dart';

/// Process-local policy, never read from document fields or selection metadata.
/// A digest proves membership in the reviewed fixture corpus, not PDF safety.
/// Callers supply immutable captured bytes. No admission cache or enrollment API
/// exists: every inspect/render checks the exact immutable bytes again.
abstract final class PdfFixtureAdmission {
  // These two generated fixtures are solely for the explicit Linux integration
  // test build. Shipped and product builds retain the exact approved registry.
  static int get maximumAdmittedBytes =>
      linuxIntegrationTestEnabled ? 46751 : maximumReviewedPdfFixtureBytes;

  static bool permits(List<int> immutableBytes, CancellationToken token) {
    if (token.isCancelled ||
        immutableBytes.isEmpty ||
        immutableBytes.length > maximumAdmittedBytes)
      return false;
    final digest = Sha256Digest.calculate(immutableBytes);
    return digest is Ok<Sha256Digest, StructuredFailure> &&
        (reviewedPdfFixtureDigests.contains(digest.value.hexadecimal) ||
            (linuxIntegrationTestEnabled &&
                const {
                  'd84471e20a0e087529e6ef4ab84a24bb56dcf9b96caab28ef0eae85ef64cd7ac',
                  'b030997ef3a8c05f6e3242c6c7068708089c7d14568fe2438ba93238cfea3d36',
                }.contains(digest.value.hexadecimal))) &&
        !token.isCancelled;
  }
}

/// Enforces admission before a parser backend can inspect or render. Caller
/// trust flags express intent only; they cannot grant admission. A single
/// operation per instance bounds concurrent source/bridge copies in app use.
final class DevelopmentFixturePdfBackend implements PdfBackend {
  DevelopmentFixturePdfBackend({required PdfBackend delegate})
    : _delegate = delegate;
  final PdfBackend _delegate;
  final _scheduler = PdfOperationScheduler();

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    if (request.cancellationToken.isCancelled)
      return const PdfInspectionCancelled();
    if (request.trust == PdfInputTrust.untrusted) return const PdfQuarantined();
    if (!_scheduler.acquireInspection()) return const PdfBackendUnavailable();
    try {
      final resource = await _admit(
        request.resourceIdentity,
        request.limits,
        request.cancellationToken,
        resourceReader,
      );
      if (request.cancellationToken.isCancelled)
        return const PdfInspectionCancelled();
      if (resource == null) return const PdfQuarantined();
      final result = await _delegate.inspect(
        request,
        resourceReader: _AdmittedReader(resource),
      );
      return request.cancellationToken.isCancelled
          ? const PdfInspectionCancelled()
          : result;
    } on Object {
      return request.cancellationToken.isCancelled
          ? const PdfInspectionCancelled()
          : const PdfQuarantined();
    } finally {
      _scheduler.release();
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
    if (request.trust == PdfInputTrust.untrusted) {
      return const PdfRenderFailure(PdfRenderFailureReason.quarantined);
    }
    // Contention is transient: retain only the latest render interest instead
    // of returning a permanent render failure to the Canvas cache.
    if (!await _scheduler.acquireRender(request.cancellationToken)) {
      return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
    }
    try {
      if (request.cancellationToken.isCancelled) {
        return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
      }
      final resource = await _admit(
        request.reference.resourceIdentity,
        request.limits,
        request.cancellationToken,
        resourceReader,
      );
      if (request.cancellationToken.isCancelled) {
        return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
      }
      if (resource == null) {
        return const PdfRenderFailure(PdfRenderFailureReason.quarantined);
      }
      final result = await _delegate.render(
        request,
        resourceReader: _AdmittedReader(resource),
      );
      return request.cancellationToken.isCancelled
          ? const PdfRenderFailure(PdfRenderFailureReason.cancelled)
          : result;
    } on Object {
      return PdfRenderFailure(
        request.cancellationToken.isCancelled
            ? PdfRenderFailureReason.cancelled
            : PdfRenderFailureReason.quarantined,
      );
    } finally {
      _scheduler.release();
    }
  }

  Future<PdfResourceBytes?> _admit(
    ResourceIdentity identity,
    PdfProcessingLimits limits,
    CancellationToken token,
    PdfResourceReader reader,
  ) async {
    final bounded = PdfProcessingLimits.create(
      maximumEncodedBytes:
          limits.maximumEncodedBytes < PdfFixtureAdmission.maximumAdmittedBytes
          ? limits.maximumEncodedBytes
          : PdfFixtureAdmission.maximumAdmittedBytes,
      maximumPageCount: limits.maximumPageCount,
      maximumRenderDimension: limits.maximumRenderDimension,
      maximumRenderPixels: limits.maximumRenderPixels,
      maximumExtractedGlyphs: limits.maximumExtractedGlyphs,
      maximumLinks: limits.maximumLinks,
      maximumOperations: limits.maximumOperations,
    );
    if (bounded is! Ok<PdfProcessingLimits, StructuredFailure>) return null;
    final captured = await reader.read(
      identity: identity,
      limits: bounded.value,
      cancellationToken: token,
    );
    if (captured is! Ok<PdfResourceBytes, StructuredFailure> ||
        captured.value.identity != identity ||
        captured.value.bytes.length > bounded.value.maximumEncodedBytes ||
        !PdfFixtureAdmission.permits(captured.value.bytes, token))
      return null;
    return captured.value;
  }

  // Extraction remains unavailable and never forwards to a parser.
  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => const QuarantinedPdfBackend().extractText(
    request,
    resourceReader: resourceReader,
  );

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => const QuarantinedPdfBackend().extractLinks(
    request,
    resourceReader: resourceReader,
  );
}

final class _AdmittedReader implements PdfResourceReader {
  const _AdmittedReader(this.resource);
  final PdfResourceBytes resource;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async =>
      identity == resource.identity &&
          resource.bytes.length <= limits.maximumEncodedBytes &&
          !cancellationToken.isCancelled
      ? Ok<PdfResourceBytes, StructuredFailure>(resource)
      : Err<PdfResourceBytes, StructuredFailure>(
          StructuredFailure(
            code: 'documents.pdf.admission.unavailable',
            category: FailureCategory.resource,
            retryDisposition: RetryDisposition.never,
            message: 'The PDF fixture is unavailable.',
          ),
        );
}
