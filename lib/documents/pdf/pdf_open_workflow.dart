// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../layers/document_layer.dart';
import '../model/document_root.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';
import '../resources/resources.dart';
import 'pdf_admission_policy.dart';
import 'pdf_backend.dart';
import 'pdf_file_selection.dart';
import 'pdf_model.dart';
import 'src/pdf_source_preparation.dart';

/// Fixed user-workflow rejection classes for local PDF opening.
enum LocalPdfOpenFailureReason {
  unavailable,
  passwordRequired,
  unsupportedEncryption,
  unsupported,
  failed,
  corrupt,
  quarantined,
  limitExceeded,
  backendUnavailable,
  busy,
  invalidDocument,
}

/// Closed, redaction-safe result of preparing a local PDF document.
sealed class LocalPdfOpenOutcome {
  const LocalPdfOpenOutcome();

  @override
  String toString() => runtimeType.toString();
}

/// Ordinary picker, operation, or stale-completion cancellation.
final class LocalPdfOpenCancelled extends LocalPdfOpenOutcome {
  const LocalPdfOpenCancelled();
}

/// Fully prepared state that may be published atomically by the caller.
final class LocalPdfOpenSuccess extends LocalPdfOpenOutcome {
  LocalPdfOpenSuccess._({required this.root, required this.resource});

  /// Complete immutable standalone PDF document.
  final StandalonePdfDocument root;

  /// The one shared immutable source resource.
  final DocumentResourceSnapshot resource;

  @override
  String toString() =>
      'LocalPdfOpenSuccess(pages: ${root.pages.length}, resource: redacted)';
}

/// Fixed failure without selected-file or backend exception evidence.
final class LocalPdfOpenFailure extends LocalPdfOpenOutcome {
  const LocalPdfOpenFailure(this.reason);

  final LocalPdfOpenFailureReason reason;

  @override
  String toString() => 'LocalPdfOpenFailure(${reason.name})';
}

/// Selects, inspects, and completely prepares one standalone PDF document.
///
/// No caller state is touched. Identifiers are deterministically derived from
/// the immutable source digest after successful inspection, so every rejected
/// path also leaves the caller's UUID generator untouched.
final class LocalPdfOpenWorkflow {
  const LocalPdfOpenWorkflow({
    required LocalPdfFileSelector selector,
    required PdfBackend backend,
    required PdfModelLimits modelLimits,
    required PdfProcessingLimits processingLimits,
  }) : _selector = selector,
       _backend = backend,
       _modelLimits = modelLimits,
       _processingLimits = processingLimits;

  final LocalPdfFileSelector _selector;
  final PdfBackend _backend;
  final PdfModelLimits _modelLimits;
  final PdfProcessingLimits _processingLimits;

  /// Prepares an open operation and rejects any completion no longer current.
  Future<LocalPdfOpenOutcome> open({
    required CancellationToken cancellationToken,
    required bool Function() stillCurrent,
  }) async {
    if (!_current(cancellationToken, stillCurrent)) {
      return const LocalPdfOpenCancelled();
    }
    final selected = await _selector.select(
      maximumEncodedBytes: _processingLimits.maximumEncodedBytes,
      cancellationToken: cancellationToken,
    );
    if (!_current(cancellationToken, stillCurrent) ||
        selected is LocalPdfSelectionCancelled) {
      return const LocalPdfOpenCancelled();
    }
    if (selected is LocalPdfSelectionFailure) {
      return LocalPdfOpenFailure(
        selected.reason == LocalPdfSelectionFailureReason.resourceLimit
            ? LocalPdfOpenFailureReason.limitExceeded
            : LocalPdfOpenFailureReason.unavailable,
      );
    }
    final bytes = (selected as LocalPdfSelectionSuccess).bytes;
    final admission = pdfAdmissionFor(_backend);
    if (!admission.permits(bytes, cancellationToken)) {
      return _current(cancellationToken, stillCurrent)
          ? const LocalPdfOpenFailure(LocalPdfOpenFailureReason.quarantined)
          : const LocalPdfOpenCancelled();
    }
    if (!_current(cancellationToken, stillCurrent))
      return const LocalPdfOpenCancelled();
    CapturedResourceBytes captured;
    try {
      captured = admission.ordinaryInputEnabled
          ? await preparePdfSource(
              bytes,
              _processingLimits.maximumEncodedBytes,
              cancellationToken,
            )
          : CapturedResourceBytes.captureSmall(bytes);
    } on Object {
      return _current(cancellationToken, stillCurrent)
          ? const LocalPdfOpenFailure(LocalPdfOpenFailureReason.unavailable)
          : const LocalPdfOpenCancelled();
    }
    if (!_current(cancellationToken, stillCurrent))
      return const LocalPdfOpenCancelled();
    final resourceIdentity = ResourceIdentity.fromUuid(
      _derivedUuid(captured.digest, 0x10000000),
    );
    final reader = _SelectedPdfReader(resourceIdentity, captured);
    final inspection = await _backend.inspect(
      PdfInspectRequest(
        resourceIdentity: resourceIdentity,
        trust: admission.trust,
        modelLimits: _modelLimits,
        limits: _processingLimits,
        cancellationToken: cancellationToken,
      ),
      resourceReader: reader,
    );
    if (!_current(cancellationToken, stillCurrent) ||
        inspection is PdfInspectionCancelled) {
      return const LocalPdfOpenCancelled();
    }
    if (inspection is! PdfInspectSuccess) {
      return LocalPdfOpenFailure(_inspectionFailure(inspection));
    }

    final built = _build(
      inspection: inspection,
      digest: captured.digest,
      resourceIdentity: resourceIdentity,
      captured: captured,
    );
    if (!_current(cancellationToken, stillCurrent)) {
      return const LocalPdfOpenCancelled();
    }
    return built;
  }

  LocalPdfOpenOutcome _build({
    required PdfInspectSuccess inspection,
    required Sha256Digest digest,
    required ResourceIdentity resourceIdentity,
    required CapturedResourceBytes captured,
  }) {
    try {
      final resource = DocumentResource.fromCaptured(
        identity: resourceIdentity,
        mediaType: pdfResourceMediaType,
        role: pdfSourceResourceRole,
        schemaVersion: pdfPageReferenceSchemaVersion,
        captured: captured,
      );
      final catalog = ResourceCatalog.create(<ResourceCatalogEntry>[
        ResourceCatalogEntry(resourceIdentity),
      ]);
      if (catalog is! Ok<ResourceCatalog, StructuredFailure>) {
        return const LocalPdfOpenFailure(
          LocalPdfOpenFailureReason.invalidDocument,
        );
      }

      final pages = <DocumentPage>[];
      for (final inspected in inspection.pages) {
        final reference = PdfPageReference.create(
          resourceIdentity: resourceIdentity,
          pageIndex: inspected.pageIndex,
          boxKind: inspected.boxKind,
          sourceBox: inspected.sourceBox,
          rotation: inspected.rotation,
          displayedWidth: inspected.displayedWidth,
          displayedHeight: inspected.displayedHeight,
          limits: _modelLimits,
        );
        final sourceLayer = reference is Ok<PdfPageReference, StructuredFailure>
            ? PdfSourceLayer.create(
                id: LayerId.fromUuid(
                  _derivedUuid(digest, 0x40000000 + inspected.pageIndex),
                ),
                envelopeVersion: pdfPageReferenceSchemaVersion,
                name: 'PDF source',
                visible: true,
                opacity: 1,
                reference: reference.value,
                limits: _modelLimits,
              )
            : null;
        final contentLayer = ContentLayer.create(
          id: LayerId.fromUuid(
            _derivedUuid(digest, 0x50000000 + inspected.pageIndex),
          ),
          envelopeVersion: pdfPageReferenceSchemaVersion,
          typeSchemaVersion: pdfPageReferenceSchemaVersion,
          name: 'Notes',
          visible: true,
          locked: false,
          opacity: 1,
          objects: const [],
          typeData: PreservedMap.empty(),
          extensionData: PreservedMap.empty(),
        );
        final size = Size2.create(
          width: inspected.displayedWidth,
          height: inspected.displayedHeight,
        );
        if (sourceLayer is! Ok<PdfSourceLayer, StructuredFailure> ||
            contentLayer is! Ok<ContentLayer, StructuredFailure> ||
            size is! Ok<Size2, StructuredFailure>) {
          return const LocalPdfOpenFailure(
            LocalPdfOpenFailureReason.invalidDocument,
          );
        }
        final page = DocumentPage.create(
          id: PageId.fromUuid(
            _derivedUuid(digest, 0x30000000 + inspected.pageIndex),
          ),
          name: 'Page ${inspected.pageIndex + 1}',
          size: size.value,
          layers: <DocumentLayer>[sourceLayer.value, contentLayer.value],
          extensionData: PreservedMap.empty(),
        );
        if (page is! Ok<DocumentPage, StructuredFailure>) {
          return const LocalPdfOpenFailure(
            LocalPdfOpenFailureReason.invalidDocument,
          );
        }
        pages.add(page.value);
      }
      final root = StandalonePdfDocument.create(
        id: DocumentId.fromUuid(_derivedUuid(digest, 0x20000000)),
        schemaVersion: pdfPageReferenceSchemaVersion,
        title: 'Imported PDF',
        resources: catalog.value,
        extensionData: PreservedMap.empty(),
        pages: pages,
        source: ResourceReference(resourceIdentity),
      );
      if (root is! Ok<StandalonePdfDocument, StructuredFailure>) {
        return const LocalPdfOpenFailure(
          LocalPdfOpenFailureReason.invalidDocument,
        );
      }
      return LocalPdfOpenSuccess._(
        root: root.value,
        resource: DocumentResourceSnapshot(resource),
      );
    } on Object {
      return const LocalPdfOpenFailure(
        LocalPdfOpenFailureReason.invalidDocument,
      );
    }
  }
}

final class _SelectedPdfReader implements PdfResourceReader {
  const _SelectedPdfReader(this.identity, this._captured);

  final ResourceIdentity identity;
  final CapturedResourceBytes _captured;

  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async {
    if (identity != this.identity) {
      return Err<PdfResourceBytes, StructuredFailure>(
        _failure('resource_unavailable'),
      );
    }
    return PdfResourceBytes.fromCaptured(
      identity: identity,
      captured: _captured,
      limits: limits,
      cancellationToken: cancellationToken,
    );
  }
}

bool _current(CancellationToken token, bool Function() stillCurrent) {
  if (token.isCancelled) return false;
  try {
    return stillCurrent();
  } on Object {
    return false;
  }
}

LocalPdfOpenFailureReason _inspectionFailure(PdfInspectOutcome outcome) =>
    switch (outcome) {
      PdfPasswordRequired() => LocalPdfOpenFailureReason.passwordRequired,
      PdfUnsupportedEncryption() =>
        LocalPdfOpenFailureReason.unsupportedEncryption,
      PdfUnsupported() => LocalPdfOpenFailureReason.unsupported,
      PdfInspectionFailed() => LocalPdfOpenFailureReason.failed,
      PdfCorrupt() => LocalPdfOpenFailureReason.corrupt,
      PdfMissing() => LocalPdfOpenFailureReason.unavailable,
      PdfQuarantined() => LocalPdfOpenFailureReason.quarantined,
      PdfInspectionLimitExceeded() => LocalPdfOpenFailureReason.limitExceeded,
      PdfBackendBusy() => LocalPdfOpenFailureReason.busy,
      PdfBackendUnavailable() => LocalPdfOpenFailureReason.backendUnavailable,
      PdfInspectionCancelled() => LocalPdfOpenFailureReason.unavailable,
      PdfInspectSuccess() => LocalPdfOpenFailureReason.invalidDocument,
    };

UuidIdentifier _derivedUuid(Sha256Digest digest, int discriminator) {
  final bytes = List<int>.of(digest.bytes.take(16));
  for (var index = 0; index < 4; index += 1) {
    bytes[12 + index] ^= (discriminator >> ((3 - index) * 8)) & 0xff;
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final text = StringBuffer();
  for (var index = 0; index < bytes.length; index += 1) {
    if (index == 4 || index == 6 || index == 8 || index == 10) text.write('-');
    text.write(bytes[index].toRadixString(16).padLeft(2, '0'));
  }
  final parsed = UuidIdentifier.parse(text.toString());
  if (parsed is! Ok<UuidIdentifier, StructuredFailure>) {
    throw StateError('Unable to derive bounded document identity.');
  }
  return parsed.value;
}

StructuredFailure _failure(String suffix) => StructuredFailure(
  code: 'documents.pdf.open.$suffix',
  category: FailureCategory.resource,
  retryDisposition: RetryDisposition.never,
  message: 'The selected PDF resource is unavailable.',
);
