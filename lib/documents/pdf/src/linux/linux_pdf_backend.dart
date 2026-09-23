// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../../core/primitives.dart';
import '../../../model/identifiers.dart';
import '../../pdf_admission_policy.dart';
import '../../pdf_backend.dart';
import '../../pdf_fixture_admission.dart';
import '../../pdf_model.dart';
import '../pdf_operation_scheduler.dart';
import 'linux_pdf_extraction.dart';
import 'linux_pdf_isolate.dart';
import 'linux_pdf_protocol.dart';
import 'linux_pdf_resources.dart';
import 'linux_pdf_supervisor.dart';

/// The same production admission and bounded scheduling guard surrounds Linux.
/// Tests may supply a relocated bundle, never a replacement trusted manifest.
enum LinuxPdfAvailability { available, busy, cleanupUnconfirmed, unavailable }

/// Diagnostic lifecycle evidence; document data cannot modify admission state.
final class LinuxPdfBackendStatus {
  LinuxPdfAvailability get availability => _availability;
  LinuxPdfAvailability _availability = LinuxPdfAvailability.available;
  final lifecycle = PdfBackendLifecycle();
  void _set(LinuxPdfAvailability value) {
    _availability = value;
    lifecycle.update(switch (value) {
      LinuxPdfAvailability.available => PdfBackendAvailability.available,
      LinuxPdfAvailability.busy => PdfBackendAvailability.busy,
      LinuxPdfAvailability.cleanupUnconfirmed =>
        PdfBackendAvailability.cleanupPending,
      LinuxPdfAvailability.unavailable => PdfBackendAvailability.unavailable,
    });
  }
}

/// Compile-time opt-in has no effect in profile/release or on other platforms.
bool get linuxPrivatePdfTestEnabled =>
    Platform.isLinux &&
    Abi.current() == Abi.linuxX64 &&
    !const bool.fromEnvironment('dart.vm.product') &&
    !const bool.fromEnvironment('dart.vm.profile') &&
    const bool.fromEnvironment('ALNOTE_LINUX_PRIVATE_PDF_TEST');

PdfBackend createLinuxIsolatedPdfBackend({
  Directory? bundle,
  LinuxPdfBackendStatus? status,
}) {
  final privateInput = linuxPrivatePdfTestEnabled;
  final lifecycleStatus = status ?? LinuxPdfBackendStatus();
  final delegate = _LinuxPdfBackend(
    LinuxPdfResources(bundle ?? LinuxPdfResources.installedBundle),
    lifecycleStatus,
    privateInput,
  );
  return _LinuxApplicationBackend(
    privateInput ? delegate : DevelopmentFixturePdfBackend(delegate: delegate),
    privateInput
        ? const _PrivateLinuxAdmission()
        : const FixturePdfAdmissionPolicy(),
    lifecycleStatus.lifecycle,
  );
}

// This capability is constructed exclusively alongside the isolated backend.
final class _PrivateLinuxAdmission implements PdfAdmissionPolicy {
  const _PrivateLinuxAdmission();
  @override
  bool get ordinaryInputEnabled => true;
  @override
  PdfInputTrust get trust => PdfInputTrust.untrusted;
  @override
  bool permits(List<int> bytes, CancellationToken token) =>
      !token.isCancelled && bytes.isNotEmpty && bytes.length <= 50000000;
}

final class _LinuxApplicationBackend
    implements PdfBackend, PdfAdmissionProvider, PdfLifecycleProvider {
  _LinuxApplicationBackend(
    this._delegate,
    this.admissionPolicy,
    this.lifecycle,
  );
  @override
  final PdfBackendLifecycle lifecycle;
  final PdfBackend _delegate;
  @override
  final PdfAdmissionPolicy admissionPolicy;
  final _scheduler = PdfOperationScheduler();

  Future<PdfResourceBytes?> _admit(
    ResourceIdentity identity,
    PdfProcessingLimits limits,
    CancellationToken token,
    PdfResourceReader reader,
  ) async {
    final bounded = PdfProcessingLimits.create(
      maximumEncodedBytes: limits.maximumEncodedBytes < 50000000
          ? limits.maximumEncodedBytes
          : 50000000,
      maximumPageCount: limits.maximumPageCount,
      maximumRenderDimension: limits.maximumRenderDimension,
      maximumRenderPixels: limits.maximumRenderPixels,
      maximumExtractedGlyphs: limits.maximumExtractedGlyphs,
      maximumLinks: limits.maximumLinks,
      maximumOperations: limits.maximumOperations,
    );
    if (bounded is! Ok<PdfProcessingLimits, StructuredFailure>) return null;
    final read = await reader.read(
      identity: identity,
      limits: bounded.value,
      cancellationToken: token,
    );
    return read is Ok<PdfResourceBytes, StructuredFailure> &&
            read.value.identity == identity &&
            read.value.bytes.length <= bounded.value.maximumEncodedBytes &&
            admissionPolicy.permits(read.value.bytes, token)
        ? read.value
        : null;
  }

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    if (!admissionPolicy.ordinaryInputEnabled)
      return _delegate.inspect(request, resourceReader: resourceReader);
    final token = request.cancellationToken;
    if (token.isCancelled) return const PdfInspectionCancelled();
    if (request.trust != PdfInputTrust.untrusted) return const PdfQuarantined();
    if (!_scheduler.acquireInspection()) return const PdfBackendBusy();
    try {
      final source = await _admit(
        request.resourceIdentity,
        request.limits,
        token,
        resourceReader,
      );
      if (token.isCancelled) return const PdfInspectionCancelled();
      if (source == null) return const PdfQuarantined();
      final result = await _delegate.inspect(
        request,
        resourceReader: _PrivateSourceReader(source),
      );
      return token.isCancelled ? const PdfInspectionCancelled() : result;
    } on Object {
      return token.isCancelled
          ? const PdfInspectionCancelled()
          : const PdfBackendUnavailable();
    } finally {
      _scheduler.release();
    }
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    if (!admissionPolicy.ordinaryInputEnabled)
      return _delegate.render(request, resourceReader: resourceReader);
    final token = request.cancellationToken;
    if (token.isCancelled)
      return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
    if (request.trust != PdfInputTrust.untrusted)
      return const PdfRenderFailure(PdfRenderFailureReason.quarantined);
    if (!await _scheduler.acquireRender(token))
      return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
    try {
      final source = await _admit(
        request.reference.resourceIdentity,
        request.limits,
        token,
        resourceReader,
      );
      if (token.isCancelled)
        return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
      if (source == null)
        return const PdfRenderFailure(PdfRenderFailureReason.quarantined);
      final result = await _delegate.render(
        request,
        resourceReader: _PrivateSourceReader(source),
      );
      return token.isCancelled
          ? const PdfRenderFailure(PdfRenderFailureReason.cancelled)
          : result;
    } on Object {
      return PdfRenderFailure(
        token.isCancelled
            ? PdfRenderFailureReason.cancelled
            : PdfRenderFailureReason.backendUnavailable,
      );
    } finally {
      _scheduler.release();
    }
  }

  Future<Result<T, StructuredFailure>> _extract<T>(
    ResourceIdentity identity,
    PdfInputTrust trust,
    PdfProcessingLimits limits,
    CancellationToken token,
    PdfResourceReader reader,
    Future<Result<T, StructuredFailure>> Function(PdfResourceReader) invoke,
  ) async {
    if (token.isCancelled) return Err(_extractionFailure('cancelled'));
    if (!admissionPolicy.ordinaryInputEnabled ||
        trust != PdfInputTrust.untrusted) {
      return Err(_extractionFailure('quarantined'));
    }
    // Extraction never displaces the existing latest render interest. A busy
    // request retains no source, queue entry or worker; callers own retry policy.
    if (!_scheduler.acquireInspection()) return Err(_extractionFailure('busy'));
    try {
      final source = await _admit(identity, limits, token, reader);
      if (token.isCancelled) return Err(_extractionFailure('cancelled'));
      if (source == null) return Err(_extractionFailure('quarantined'));
      final result = await invoke(_PrivateSourceReader(source));
      return token.isCancelled ? Err(_extractionFailure('cancelled')) : result;
    } on Object {
      return Err(
        _extractionFailure(token.isCancelled ? 'cancelled' : 'failed'),
      );
    } finally {
      _scheduler.release();
    }
  }

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => _extract(
    request.reference.resourceIdentity,
    request.trust,
    request.limits,
    request.cancellationToken,
    resourceReader,
    (reader) => _delegate.extractText(request, resourceReader: reader),
  );

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => _extract(
    request.reference.resourceIdentity,
    request.trust,
    request.limits,
    request.cancellationToken,
    resourceReader,
    (reader) => _delegate.extractLinks(request, resourceReader: reader),
  );
}

final class _PrivateSourceReader implements PdfResourceReader {
  const _PrivateSourceReader(this.source);
  final PdfResourceBytes source;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async =>
      identity == source.identity &&
          source.bytes.length <= limits.maximumEncodedBytes &&
          !cancellationToken.isCancelled
      ? Ok(source)
      : Err(
          StructuredFailure(
            code: 'documents.pdf.source.unavailable',
            category: FailureCategory.resource,
            retryDisposition: RetryDisposition.never,
            message: 'The PDF source is unavailable.',
          ),
        );
}

final class _LinuxPdfBackend implements PdfBackend {
  _LinuxPdfBackend(this.resources, this.status, this.privateInput);
  final bool privateInput;
  final LinuxPdfBackendStatus status;
  LinuxPdfResources resources;
  static final _identity = (PdfBackendIdentity.parse(
    'alnote.linux.pdfium-8044-v1',
  ) as Ok<PdfBackendIdentity, StructuredFailure>).value;

  Future<PdfResourceBytes?> _read(
    ResourceIdentity identity,
    PdfProcessingLimits limits,
    CancellationToken token,
    PdfResourceReader reader,
  ) async {
    final result = await reader.read(
      identity: identity,
      limits: limits,
      cancellationToken: token,
    );
    return result is Ok<PdfResourceBytes, StructuredFailure> &&
            result.value.identity == identity &&
            result.value.bytes.length <= limits.maximumEncodedBytes &&
            !token.isCancelled
        ? result.value
        : null;
  }

  Future<List<Object>> _operate(
    PdfResourceBytes source,
    CancellationToken token, {
    bool render = false,
    int page = 0,
    int width = 400,
    int height = 300,
    PdfProcessingLimits? limits,
    LinuxPdfExtractionRequest? extraction,
    PdfPageReference? reference,
    PdfPageClip? region,
  }) async {
    final prepared = resources;
    final sourceBytes = source.bytes;
    final Object bytes = sourceBytes is Uint8List
        ? TransferableTypedData.fromList([sourceBytes])
        : sourceBytes;
    status._set(LinuxPdfAvailability.busy);
    try {
      final result = await runLinuxPdfTask(
        _operationTask(
          prepared,
          bytes,
          render,
          page,
          width,
          height,
          limits,
          extraction,
          reference,
          region ?? PdfPageClip.full,
        ),
        token,
        onCleanupState: (unconfirmed) {
          status._set(
            unconfirmed
                ? LinuxPdfAvailability.cleanupUnconfirmed
                : LinuxPdfAvailability.busy,
          );
        },
      );
      resources = result.$1;
      if (result.$2 == null) {
        if (result.$3 == true) throw const _Unavailable();
        if (result.$3 is LinuxPdfRejection)
          throw LinuxPdfRejected(result.$3 as LinuxPdfRejection);
        throw const FormatException('operation rejected');
      }
      return result.$2!;
    } finally {
      status._set(LinuxPdfAvailability.available);
    }
  }

  static Future<(LinuxPdfResources, List<Object>?, Object?)> Function(
    CancellationToken,
  )
  _operationTask(
    LinuxPdfResources resources,
    Object source,
    bool render,
    int page,
    int width,
    int height,
    PdfProcessingLimits? limits,
    LinuxPdfExtractionRequest? extraction,
    PdfPageReference? reference,
    PdfPageClip region,
  ) =>
      (token) => _operateIsolated(
        resources,
        source is TransferableTypedData
            ? source.materialize().asUint8List()
            : source as List<int>,
        token,
        render,
        page,
        width,
        height,
        limits,
        extraction,
        reference,
        region,
      );

  static Future<(LinuxPdfResources, List<Object>?, Object?)> _operateIsolated(
    LinuxPdfResources resources,
    List<int> source,
    CancellationToken token,
    bool render,
    int page,
    int width,
    int height,
    PdfProcessingLimits? limits,
    LinuxPdfExtractionRequest? extraction,
    PdfPageReference? reference,
    PdfPageClip region,
  ) async {
    Directory? stage;
    try {
      stage = await resources.stageLocally(token);
      final frames = await const LinuxPdfSupervisor().operate(
        runtime: stage,
        source: source,
        token: token,
        render: render,
        page: page,
        width: width,
        height: height,
        extraction: extraction,
      );
      if (extraction != null) {
        frames[1] = projectLinuxPdfExtraction(
          response: frames[1] as Map<String, dynamic>,
          operation: extraction,
          reference: reference!,
          region: region,
          limits: limits!,
          token: token,
        );
      }
      if (render) {
        final output = PdfRenderOutput.capture(
          backendIdentity: _identity,
          region: PdfPageClip.full,
          pixelWidth: width,
          pixelHeight: height,
          rgbaBytes: frames[2] as Uint8List,
          limits: limits!,
          cancellationToken: token,
        );
        if (output is! Ok<PdfRenderOutput, StructuredFailure>) {
          throw const FormatException('raster capture');
        }
        frames[2] = output.value;
      }
      return (resources, frames, false);
    } on LinuxPdfExtractionUnsupported {
      return (resources, null, LinuxPdfRejection.unsupported);
    } on LinuxPdfRejected catch (error) {
      return (resources, null, error.reason);
    } on LinuxPdfIsolationUnavailable {
      return (resources, null, true);
    } on Object {
      return (resources, null, stage == null);
    } finally {
      // Supervisor completion certifies service cleanup and launcher reap even
      // during cancellation/controller failure. The guard owns the slot until
      // this isolate transfers its result after private staging deletion.
      if (stage != null) await stage.delete(recursive: true);
    }
  }

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    final token = request.cancellationToken;
    if (token.isCancelled) return const PdfInspectionCancelled();
    if (request.trust == PdfInputTrust.untrusted && !privateInput)
      return const PdfQuarantined();
    try {
      final source = await _read(
        request.resourceIdentity,
        request.limits,
        token,
        resourceReader,
      );
      if (source == null)
        return token.isCancelled
            ? const PdfInspectionCancelled()
            : const PdfMissing();
      final frames = await _operate(source, token);
      final candidates = (frames[1] as Map<String, dynamic>)['pages'] as List;
      if (candidates.length > request.limits.maximumPageCount ||
          candidates.length > request.limits.maximumOperations ||
          candidates.length > request.modelLimits.maximumPageCount) {
        return const PdfInspectionLimitExceeded();
      }
      final pages = <PdfInspectedPage>[];
      for (var i = 0; i < candidates.length; i++) {
        final page = candidates[i] as Map<String, dynamic>;
        final bounds = page['bounds'] as List;
        final box = PdfSourceBox.create(
          left: (bounds[0] as num).toDouble(),
          bottom: (bounds[1] as num).toDouble(),
          right: (bounds[2] as num).toDouble(),
          top: (bounds[3] as num).toDouble(),
          limits: request.modelLimits,
        );
        if (box is! Ok<PdfSourceBox, StructuredFailure>)
          return const PdfInspectionLimitExceeded();
        final inspected = PdfInspectedPage.create(
          pageIndex: i,
          boxKind: PdfPageBoxKind.resolvedBounds,
          sourceBox: box.value,
          rotation: _rotation(page['rotation'] as int),
          displayedWidth: (page['width'] as num).toDouble(),
          displayedHeight: (page['height'] as num).toDouble(),
          limits: request.modelLimits,
        );
        if (inspected is! Ok<PdfInspectedPage, StructuredFailure>)
          return const PdfInspectionLimitExceeded();
        pages.add(inspected.value);
      }
      return PdfInspectSuccess.capture(
        backendIdentity: _identity,
        pages: pages,
        modelLimits: request.modelLimits,
        limits: request.limits,
        cancellationToken: token,
      );
    } on LinuxPdfRejected catch (error) {
      if (token.isCancelled) return const PdfInspectionCancelled();
      return switch (error.reason) {
        LinuxPdfRejection.passwordRequired => const PdfPasswordRequired(),
        LinuxPdfRejection.unsupported => const PdfUnsupported(),
        LinuxPdfRejection.limitExceeded => const PdfInspectionLimitExceeded(),
        LinuxPdfRejection.failed => const PdfInspectionFailed(),
      };
    } on _Unavailable {
      status._set(LinuxPdfAvailability.unavailable);
      return token.isCancelled
          ? const PdfInspectionCancelled()
          : const PdfBackendUnavailable();
    } on Object {
      return token.isCancelled
          ? const PdfInspectionCancelled()
          : const PdfInspectionFailed();
    }
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    final token = request.cancellationToken;
    if (token.isCancelled)
      return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
    if (request.trust == PdfInputTrust.untrusted && !privateInput)
      return const PdfRenderFailure(PdfRenderFailureReason.quarantined);
    if (request.region != PdfPageClip.full ||
        request.pixelWidth > 4096 ||
        request.pixelHeight > 4096) {
      return const PdfRenderFailure(PdfRenderFailureReason.limitExceeded);
    }
    try {
      final source = await _read(
        request.reference.resourceIdentity,
        request.limits,
        token,
        resourceReader,
      );
      if (source == null)
        return PdfRenderFailure(
          token.isCancelled
              ? PdfRenderFailureReason.cancelled
              : PdfRenderFailureReason.missing,
        );
      final frames = await _operate(
        source,
        token,
        render: true,
        page: request.reference.pageIndex,
        width: request.pixelWidth,
        height: request.pixelHeight,
        limits: request.limits,
      );
      final page =
          (frames[1] as Map<String, dynamic>)['page'] as Map<String, dynamic>;
      final bounds = page['bounds'] as List;
      final reference = request.reference;
      if (bounds[0] != reference.sourceBox.left ||
          bounds[1] != reference.sourceBox.bottom ||
          bounds[2] != reference.sourceBox.right ||
          bounds[3] != reference.sourceBox.top ||
          page['width'] != reference.displayedWidth ||
          page['height'] != reference.displayedHeight ||
          _rotation(page['rotation'] as int) != reference.rotation) {
        return const PdfRenderFailure(PdfRenderFailureReason.corrupt);
      }
      if (token.isCancelled) {
        return const PdfRenderFailure(PdfRenderFailureReason.cancelled);
      }
      return PdfRenderSuccess(frames[2] as PdfRenderOutput);
    } on LinuxPdfRejected catch (error) {
      return PdfRenderFailure(
        token.isCancelled
            ? PdfRenderFailureReason.cancelled
            : error.reason == LinuxPdfRejection.limitExceeded
            ? PdfRenderFailureReason.limitExceeded
            : PdfRenderFailureReason.failed,
      );
    } on _Unavailable {
      status._set(LinuxPdfAvailability.unavailable);
      return PdfRenderFailure(
        token.isCancelled
            ? PdfRenderFailureReason.cancelled
            : PdfRenderFailureReason.backendUnavailable,
      );
    } on Object {
      return PdfRenderFailure(
        token.isCancelled
            ? PdfRenderFailureReason.cancelled
            : PdfRenderFailureReason.failed,
      );
    }
  }

  static PdfPageRotation _rotation(int value) => switch (value) {
    0 => PdfPageRotation.degrees0,
    90 => PdfPageRotation.degrees90,
    180 => PdfPageRotation.degrees180,
    270 => PdfPageRotation.degrees270,
    _ => throw const FormatException('rotation'),
  };

  Future<Result<T, StructuredFailure>> _extract<T>(
    PdfPageReference reference,
    PdfInputTrust trust,
    PdfPageClip region,
    PdfProcessingLimits limits,
    CancellationToken token,
    PdfResourceReader reader,
    LinuxPdfExtractionOperation operation, {
    bool allowHttp = false,
  }) async {
    if (token.isCancelled) return Err(_extractionFailure('cancelled'));
    if (!privateInput || trust != PdfInputTrust.untrusted)
      return Err(_extractionFailure('quarantined'));
    final extraction = LinuxPdfExtractionRequest(
      operation: operation,
      pageIndex: reference.pageIndex,
      maximumPages: math.min(1000, limits.maximumPageCount),
      maximumGlyphs: math.min(
        linuxPdfExtractionGlyphs,
        limits.maximumExtractedGlyphs,
      ),
      maximumLinks: math.min(linuxPdfExtractionLinks, limits.maximumLinks),
      maximumOperations: math.min(
        linuxPdfExtractionAnnotations,
        limits.maximumOperations,
      ),
      allowHttp: allowHttp,
    );
    try {
      extraction.validate();
      final source = await _read(
        reference.resourceIdentity,
        limits,
        token,
        reader,
      );
      if (source == null)
        return Err(
          _extractionFailure(token.isCancelled ? 'cancelled' : 'missing'),
        );
      final frames = await _operate(
        source,
        token,
        limits: limits,
        extraction: extraction,
        reference: reference,
        region: region,
      );
      if (token.isCancelled) return Err(_extractionFailure('cancelled'));
      return Ok(frames[1] as T);
    } on LinuxPdfRejected catch (error) {
      return Err(
        _extractionFailure(token.isCancelled ? 'cancelled' : error.reason.name),
      );
    } on _Unavailable {
      status._set(LinuxPdfAvailability.unavailable);
      return Err(
        _extractionFailure(token.isCancelled ? 'cancelled' : 'unavailable'),
      );
    } on Object {
      return Err(
        _extractionFailure(token.isCancelled ? 'cancelled' : 'failed'),
      );
    }
  }

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => _extract(
    request.reference,
    request.trust,
    request.region,
    request.limits,
    request.cancellationToken,
    resourceReader,
    LinuxPdfExtractionOperation.text,
  );

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) => _extract(
    request.reference,
    request.trust,
    request.region,
    request.limits,
    request.cancellationToken,
    resourceReader,
    LinuxPdfExtractionOperation.links,
    allowHttp: request.allowExternalHttpMetadata,
  );
}

final class _Unavailable implements Exception {
  const _Unavailable();
}

StructuredFailure _extractionFailure(String reason) => StructuredFailure(
  code:
      'documents.pdf.extraction.${switch (reason) {
        'limitExceeded' => 'limit_exceeded',
        'passwordRequired' => 'password_required',
        _ => reason,
      }}',
  category: reason == 'limitExceeded'
      ? FailureCategory.resource
      : FailureCategory.dependency,
  retryDisposition: reason == 'busy'
      ? RetryDisposition.retryable
      : RetryDisposition.never,
  message: 'The PDF extraction request could not be completed.',
);
