// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';
import 'dart:typed_data';

import '../../core/geometry/geometry_values.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';
import '../resources/resource_records.dart';
import 'pdf_model.dart';

/// Requested processing mode, not admission authority. The development backend
/// independently verifies exact immutable bytes against its compiled fixture
/// policy; setting this enum cannot make selected or serialized input trusted.
enum PdfInputTrust { trustedDevelopmentFixture, untrusted }

/// Explicit portable ceilings for every PDF backend call.
final class PdfProcessingLimits {
  const PdfProcessingLimits._({
    required this.maximumEncodedBytes,
    required this.maximumPageCount,
    required this.maximumRenderDimension,
    required this.maximumRenderPixels,
    required this.maximumExtractedGlyphs,
    required this.maximumLinks,
    required this.maximumOperations,
  });

  static Result<PdfProcessingLimits, StructuredFailure> create({
    required int maximumEncodedBytes,
    required int maximumPageCount,
    required int maximumRenderDimension,
    required int maximumRenderPixels,
    required int maximumExtractedGlyphs,
    required int maximumLinks,
    required int maximumOperations,
  }) {
    final values = <int>[
      maximumEncodedBytes,
      maximumPageCount,
      maximumRenderDimension,
      maximumRenderPixels,
      maximumExtractedGlyphs,
      maximumLinks,
      maximumOperations,
    ];
    if (values.any((value) => value <= 0 || value > maximumWebSafeInteger) ||
        maximumRenderDimension >
            maximumWebSafeInteger ~/ maximumRenderDimension ||
        maximumRenderPixels > maximumRenderDimension * maximumRenderDimension) {
      return Err<PdfProcessingLimits, StructuredFailure>(
        _backendFailure('invalid_limits'),
      );
    }
    return Ok<PdfProcessingLimits, StructuredFailure>(
      PdfProcessingLimits._(
        maximumEncodedBytes: maximumEncodedBytes,
        maximumPageCount: maximumPageCount,
        maximumRenderDimension: maximumRenderDimension,
        maximumRenderPixels: maximumRenderPixels,
        maximumExtractedGlyphs: maximumExtractedGlyphs,
        maximumLinks: maximumLinks,
        maximumOperations: maximumOperations,
      ),
    );
  }

  final int maximumEncodedBytes;
  final int maximumPageCount;
  final int maximumRenderDimension;
  final int maximumRenderPixels;
  final int maximumExtractedGlyphs;
  final int maximumLinks;
  final int maximumOperations;

  @override
  String toString() => 'PdfProcessingLimits(validated: true)';
}

/// Immutable bounded source bytes delivered through AL NOTE resource access.
final class PdfResourceBytes {
  PdfResourceBytes._({required this.identity, required List<int> bytes})
    : bytes = UnmodifiableListView<int>(bytes);

  PdfResourceBytes._immutable({required this.identity, required this.bytes});

  /// Shares bytes only from an opaque, internally verified resource capture.
  static Result<PdfResourceBytes, StructuredFailure> fromCaptured({
    required ResourceIdentity identity,
    required CapturedResourceBytes captured,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) => _fromImmutable(identity, captured.bytes, limits, cancellationToken);

  /// Resource snapshots can only be constructed from immutable resources.
  static Result<PdfResourceBytes, StructuredFailure> fromSnapshot({
    required DocumentResourceSnapshot resource,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) => _fromImmutable(
    resource.identity,
    resource.bytes,
    limits,
    cancellationToken,
  );

  static Result<PdfResourceBytes, StructuredFailure> _fromImmutable(
    ResourceIdentity identity,
    List<int> bytes,
    PdfProcessingLimits limits,
    CancellationToken token,
  ) {
    if (token.isCancelled ||
        bytes.isEmpty ||
        bytes.length > limits.maximumEncodedBytes) {
      return Err(
        _backendFailure(token.isCancelled ? 'cancelled' : 'resource_limit'),
      );
    }
    return Ok(PdfResourceBytes._immutable(identity: identity, bytes: bytes));
  }

  static Result<PdfResourceBytes, StructuredFailure> capture({
    required ResourceIdentity identity,
    required Iterable<int> bytes,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Err<PdfResourceBytes, StructuredFailure>(
        _backendFailure('cancelled'),
      );
    }
    final captured = <int>[];
    try {
      final iterator = bytes.iterator;
      while (iterator.moveNext()) {
        if (cancellationToken.isCancelled) {
          return Err<PdfResourceBytes, StructuredFailure>(
            _backendFailure('cancelled'),
          );
        }
        final value = iterator.current;
        if (value < 0 ||
            value > 255 ||
            captured.length >= limits.maximumEncodedBytes) {
          return Err<PdfResourceBytes, StructuredFailure>(
            _backendFailure('resource_limit'),
          );
        }
        captured.add(value);
      }
    } on Object {
      return Err<PdfResourceBytes, StructuredFailure>(
        _backendFailure('resource_unavailable'),
      );
    }
    if (captured.isEmpty || cancellationToken.isCancelled) {
      return Err<PdfResourceBytes, StructuredFailure>(
        _backendFailure(captured.isEmpty ? 'resource_empty' : 'cancelled'),
      );
    }
    return Ok<PdfResourceBytes, StructuredFailure>(
      PdfResourceBytes._(identity: identity, bytes: captured),
    );
  }

  final ResourceIdentity identity;
  final List<int> bytes;

  @override
  String toString() => 'PdfResourceBytes(redacted)';
}

abstract interface class PdfResourceReader {
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  });
}

/// Stable non-persistent backend identity for cache compatibility.
final class PdfBackendIdentity {
  const PdfBackendIdentity._(this.value);

  static Result<PdfBackendIdentity, StructuredFailure> parse(String value) {
    if (value.length > 127 || !RegExp(r'^[a-z][a-z0-9_.-]*$').hasMatch(value)) {
      return Err<PdfBackendIdentity, StructuredFailure>(
        _backendFailure('invalid_backend_identity'),
      );
    }
    return Ok<PdfBackendIdentity, StructuredFailure>(
      PdfBackendIdentity._(value),
    );
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfBackendIdentity && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'PdfBackendIdentity(redacted)';
}

/// Immutable inspection request with explicit trust, limits, and cancellation.
final class PdfInspectRequest {
  const PdfInspectRequest({
    required this.resourceIdentity,
    required this.trust,
    required this.modelLimits,
    required this.limits,
    required this.cancellationToken,
  });

  final ResourceIdentity resourceIdentity;
  final PdfInputTrust trust;
  final PdfModelLimits modelLimits;
  final PdfProcessingLimits limits;
  final CancellationToken cancellationToken;

  @override
  String toString() => 'PdfInspectRequest(redacted)';
}

/// One validated backend-reported Page candidate.
final class PdfInspectedPage {
  const PdfInspectedPage._({
    required this.pageIndex,
    required this.boxKind,
    required this.sourceBox,
    required this.rotation,
    required this.displayedWidth,
    required this.displayedHeight,
  });

  static Result<PdfInspectedPage, StructuredFailure> create({
    required int pageIndex,
    required PdfPageBoxKind boxKind,
    required PdfSourceBox sourceBox,
    required PdfPageRotation rotation,
    required double displayedWidth,
    required double displayedHeight,
    required PdfModelLimits limits,
  }) {
    final probe = PdfPageReference.create(
      resourceIdentity: _probeResourceIdentity,
      pageIndex: pageIndex,
      boxKind: boxKind,
      sourceBox: sourceBox,
      rotation: rotation,
      displayedWidth: displayedWidth,
      displayedHeight: displayedHeight,
      limits: limits,
    );
    if (probe is! Ok<PdfPageReference, StructuredFailure>) {
      return Err<PdfInspectedPage, StructuredFailure>(
        _backendFailure('invalid_page_evidence'),
      );
    }
    return Ok<PdfInspectedPage, StructuredFailure>(
      PdfInspectedPage._(
        pageIndex: pageIndex,
        boxKind: boxKind,
        sourceBox: sourceBox,
        rotation: rotation,
        displayedWidth: displayedWidth,
        displayedHeight: displayedHeight,
      ),
    );
  }

  final int pageIndex;
  final PdfPageBoxKind boxKind;
  final PdfSourceBox sourceBox;
  final PdfPageRotation rotation;
  final double displayedWidth;
  final double displayedHeight;

  /// Revalidates complete nested Page evidence under receiving model limits.
  Result<PdfInspectedPage, StructuredFailure> validatedFor(
    PdfModelLimits limits,
  ) => PdfInspectedPage.create(
    pageIndex: pageIndex,
    boxKind: boxKind,
    sourceBox: sourceBox,
    rotation: rotation,
    displayedWidth: displayedWidth,
    displayedHeight: displayedHeight,
    limits: limits,
  );

  @override
  String toString() => 'PdfInspectedPage(pageIndex: $pageIndex)';
}

/// Closed redaction-safe inspection result family.
sealed class PdfInspectOutcome {
  const PdfInspectOutcome();

  @override
  String toString() => runtimeType.toString();
}

final class PdfInspectSuccess extends PdfInspectOutcome {
  PdfInspectSuccess._({required this.backendIdentity, required this.pages});

  static PdfInspectOutcome capture({
    required PdfBackendIdentity backendIdentity,
    required Iterable<PdfInspectedPage> pages,
    required PdfModelLimits modelLimits,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) return const PdfInspectionCancelled();
    final captured = <PdfInspectedPage>[];
    try {
      final iterator = pages.iterator;
      while (iterator.moveNext()) {
        if (cancellationToken.isCancelled) {
          return const PdfInspectionCancelled();
        }
        if (captured.length >= limits.maximumPageCount) {
          return const PdfInspectionLimitExceeded();
        }
        final checkedPage = iterator.current.validatedFor(modelLimits);
        if (checkedPage is! Ok<PdfInspectedPage, StructuredFailure>) {
          return const PdfInspectionLimitExceeded();
        }
        final page = checkedPage.value;
        if (page.pageIndex != captured.length) return const PdfCorrupt();
        captured.add(page);
      }
    } on Object {
      return const PdfCorrupt();
    }
    if (cancellationToken.isCancelled) return const PdfInspectionCancelled();
    if (captured.isEmpty) return const PdfCorrupt();
    return PdfInspectSuccess._(
      backendIdentity: backendIdentity,
      pages: List<PdfInspectedPage>.unmodifiable(captured),
    );
  }

  final PdfBackendIdentity backendIdentity;
  final List<PdfInspectedPage> pages;

  @override
  String toString() => 'PdfInspectSuccess(pages: ${pages.length})';
}

final class PdfPasswordRequired extends PdfInspectOutcome {
  const PdfPasswordRequired();
}

final class PdfUnsupportedEncryption extends PdfInspectOutcome {
  const PdfUnsupportedEncryption();
}

/// Processing failed without evidence establishing a specific document cause.
final class PdfInspectionFailed extends PdfInspectOutcome {
  const PdfInspectionFailed();
}

final class PdfUnsupported extends PdfInspectOutcome {
  const PdfUnsupported();
}

final class PdfCorrupt extends PdfInspectOutcome {
  const PdfCorrupt();
}

final class PdfMissing extends PdfInspectOutcome {
  const PdfMissing();
}

final class PdfQuarantined extends PdfInspectOutcome {
  const PdfQuarantined();
}

final class PdfInspectionCancelled extends PdfInspectOutcome {
  const PdfInspectionCancelled();
}

final class PdfInspectionLimitExceeded extends PdfInspectOutcome {
  const PdfInspectionLimitExceeded();
}

/// An existing operation still owns the isolated backend.
final class PdfBackendBusy extends PdfInspectOutcome {
  const PdfBackendBusy();
}

final class PdfBackendUnavailable extends PdfInspectOutcome {
  const PdfBackendUnavailable();
}

/// Backend-neutral request to render one validated Page region.
final class PdfRenderRequest {
  const PdfRenderRequest._({
    required this.reference,
    required this.trust,
    required this.region,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.includeSafeNativeAppearances,
    required this.limits,
    required this.cancellationToken,
  });

  static Result<PdfRenderRequest, StructuredFailure> create({
    required PdfPageReference reference,
    required PdfInputTrust trust,
    required PdfPageClip region,
    required int pixelWidth,
    required int pixelHeight,
    required bool includeSafeNativeAppearances,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled ||
        !_integerProductWithin(
          pixelWidth,
          pixelHeight,
          limits.maximumRenderPixels,
        ) ||
        pixelWidth > limits.maximumRenderDimension ||
        pixelHeight > limits.maximumRenderDimension) {
      return Err<PdfRenderRequest, StructuredFailure>(
        _backendFailure(
          cancellationToken.isCancelled ? 'cancelled' : 'render_limit',
        ),
      );
    }
    return Ok<PdfRenderRequest, StructuredFailure>(
      PdfRenderRequest._(
        reference: reference,
        trust: trust,
        region: region,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        includeSafeNativeAppearances: includeSafeNativeAppearances,
        limits: limits,
        cancellationToken: cancellationToken,
      ),
    );
  }

  final PdfPageReference reference;
  final PdfInputTrust trust;
  final PdfPageClip region;
  final int pixelWidth;
  final int pixelHeight;
  final bool includeSafeNativeAppearances;
  final PdfProcessingLimits limits;
  final CancellationToken cancellationToken;

  @override
  String toString() => 'PdfRenderRequest(redacted)';
}

/// Immutable premultiplied RGBA render output.
final class PdfRenderOutput {
  PdfRenderOutput._({
    required this.backendIdentity,
    required this.region,
    required this.pixelWidth,
    required this.pixelHeight,
    required List<int> rgbaBytes,
  }) : rgbaBytes = rgbaBytes is Uint8List
           ? rgbaBytes.asUnmodifiableView()
           : UnmodifiableListView<int>(rgbaBytes);

  static Result<PdfRenderOutput, StructuredFailure> capture({
    required PdfBackendIdentity backendIdentity,
    required PdfPageClip region,
    required int pixelWidth,
    required int pixelHeight,
    required Iterable<int> rgbaBytes,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled ||
        !_integerProductWithin(
          pixelWidth,
          pixelHeight,
          limits.maximumRenderPixels,
        ) ||
        pixelWidth > limits.maximumRenderDimension ||
        pixelHeight > limits.maximumRenderDimension) {
      return Err<PdfRenderOutput, StructuredFailure>(
        _backendFailure(
          cancellationToken.isCancelled ? 'cancelled' : 'render_limit',
        ),
      );
    }
    final pixels = pixelWidth * pixelHeight;
    if (pixels > maximumWebSafeInteger ~/ 4) {
      return Err<PdfRenderOutput, StructuredFailure>(
        _backendFailure('render_limit'),
      );
    }
    final expected = pixels * 4;
    // Typed bytes are intrinsically in range. Capture once into private storage;
    // the Linux caller performs this bounded copy on its operation isolate.
    if (rgbaBytes is Uint8List) {
      if (rgbaBytes.length != expected) {
        return Err<PdfRenderOutput, StructuredFailure>(
          _backendFailure('invalid_render_output'),
        );
      }
      return Ok<PdfRenderOutput, StructuredFailure>(
        PdfRenderOutput._(
          backendIdentity: backendIdentity,
          region: region,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
          rgbaBytes: Uint8List.fromList(rgbaBytes),
        ),
      );
    }
    final captured = <int>[];
    try {
      final iterator = rgbaBytes.iterator;
      while (iterator.moveNext()) {
        if (cancellationToken.isCancelled) {
          return Err<PdfRenderOutput, StructuredFailure>(
            _backendFailure('cancelled'),
          );
        }
        final value = iterator.current;
        if (value < 0 || value > 255 || captured.length >= expected) {
          return Err<PdfRenderOutput, StructuredFailure>(
            _backendFailure('invalid_render_output'),
          );
        }
        captured.add(value);
      }
    } on Object {
      return Err<PdfRenderOutput, StructuredFailure>(
        _backendFailure('invalid_render_output'),
      );
    }
    if (cancellationToken.isCancelled || captured.length != expected) {
      return Err<PdfRenderOutput, StructuredFailure>(
        _backendFailure(
          cancellationToken.isCancelled ? 'cancelled' : 'invalid_render_output',
        ),
      );
    }
    return Ok<PdfRenderOutput, StructuredFailure>(
      PdfRenderOutput._(
        backendIdentity: backendIdentity,
        region: region,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        rgbaBytes: captured,
      ),
    );
  }

  final PdfBackendIdentity backendIdentity;
  final PdfPageClip region;
  final int pixelWidth;
  final int pixelHeight;
  final List<int> rgbaBytes;

  @override
  String toString() => 'PdfRenderOutput(redacted)';
}

enum PdfRenderFailureReason {
  failed,
  missing,
  corrupt,
  quarantined,
  cancelled,
  limitExceeded,
  backendUnavailable,
}

sealed class PdfRenderOutcome {
  const PdfRenderOutcome();
}

final class PdfRenderSuccess extends PdfRenderOutcome {
  const PdfRenderSuccess(this.output);
  final PdfRenderOutput output;
}

final class PdfRenderFailure extends PdfRenderOutcome {
  const PdfRenderFailure(this.reason);
  final PdfRenderFailureReason reason;

  @override
  String toString() => 'PdfRenderFailure(${reason.name})';
}

/// Bounded backend-neutral text extraction request.
final class PdfTextExtractRequest {
  const PdfTextExtractRequest({
    required this.reference,
    required this.trust,
    required this.region,
    required this.limits,
    required this.cancellationToken,
  });

  final PdfPageReference reference;
  final PdfInputTrust trust;
  final PdfPageClip region;
  final PdfProcessingLimits limits;
  final CancellationToken cancellationToken;

  @override
  String toString() => 'PdfTextExtractRequest(redacted)';
}

/// One Unicode scalar and its derived displayed-PDF-local geometry. Bounds may
/// be absent for engine-generated separators, never fabricated from neighbors.
final class PdfTextGlyph {
  const PdfTextGlyph({
    required this.unicodeScalar,
    required this.sourceCharacterIndex,
    required this.bounds,
  });

  final int unicodeScalar;

  /// Unicode-scalar position in the full page projection, before region filtering.
  final int sourceCharacterIndex;
  final Rect2? bounds;

  @override
  String toString() => 'PdfTextGlyph(redacted)';
}

final class PdfExtractedText {
  const PdfExtractedText._(this.text, [this.glyphs]);

  /// Captures a complete bounded projection of the requested region. A failure
  /// publishes no prefix. Reading order remains the engine's advisory order.
  static Result<PdfExtractedText, StructuredFailure> captureGlyphs({
    required Iterable<PdfTextGlyph> glyphs,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) return Err(_backendFailure('cancelled'));
    final captured = <PdfTextGlyph>[];
    final text = StringBuffer();
    var previous = -1;
    try {
      for (final glyph in glyphs) {
        if (cancellationToken.isCancelled) {
          return Err(_backendFailure('cancelled'));
        }
        if (captured.length >= limits.maximumExtractedGlyphs) {
          return Err(_backendFailure('text_limit'));
        }
        final scalar = glyph.unicodeScalar;
        if (scalar <= 0 ||
            scalar > 0x10ffff ||
            scalar >= 0xd800 && scalar <= 0xdfff ||
            glyph.bounds == null && !const {9, 10, 13, 32}.contains(scalar) ||
            glyph.sourceCharacterIndex <= previous ||
            glyph.sourceCharacterIndex >= limits.maximumExtractedGlyphs) {
          return Err(_backendFailure('invalid_text_output'));
        }
        previous = glyph.sourceCharacterIndex;
        captured.add(glyph);
        text.writeCharCode(scalar);
      }
    } on Object {
      return Err(_backendFailure('invalid_text_output'));
    }
    if (cancellationToken.isCancelled) return Err(_backendFailure('cancelled'));
    return Ok(PdfExtractedText._(text.toString(), List.unmodifiable(captured)));
  }

  static Result<PdfExtractedText, StructuredFailure> capture({
    required String text,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Err<PdfExtractedText, StructuredFailure>(
        _backendFailure('cancelled'),
      );
    }
    var count = 0;
    try {
      for (final _ in text.runes) {
        if (cancellationToken.isCancelled ||
            count >= limits.maximumExtractedGlyphs) {
          return Err<PdfExtractedText, StructuredFailure>(
            _backendFailure(
              cancellationToken.isCancelled ? 'cancelled' : 'text_limit',
            ),
          );
        }
        count += 1;
      }
    } on Object {
      return Err<PdfExtractedText, StructuredFailure>(
        _backendFailure('invalid_text_output'),
      );
    }
    if (cancellationToken.isCancelled) {
      return Err<PdfExtractedText, StructuredFailure>(
        _backendFailure('cancelled'),
      );
    }
    return Ok<PdfExtractedText, StructuredFailure>(PdfExtractedText._(text));
  }

  final String text;

  /// Ordered scalar geometry when supplied by an operational adapter. Null
  /// distinguishes the older text-only contract from a verified empty page.
  final List<PdfTextGlyph>? glyphs;

  @override
  String toString() => 'PdfExtractedText(redacted)';
}

enum PdfSafeLinkKind { internalPage, externalReference }

/// Safe link geometry and classification; external targets are never exposed.
final class PdfSafeLinkMetadata {
  const PdfSafeLinkMetadata._({
    required this.bounds,
    required this.kind,
    required this.destinationPageIndex,
  });

  static Result<PdfSafeLinkMetadata, StructuredFailure> create({
    required Rect2 bounds,
    required PdfSafeLinkKind kind,
    int? destinationPageIndex,
    required PdfProcessingLimits limits,
  }) {
    if (bounds.width <= 0 ||
        bounds.height <= 0 ||
        (kind == PdfSafeLinkKind.internalPage) !=
            (destinationPageIndex != null) ||
        (destinationPageIndex != null &&
            (destinationPageIndex < 0 ||
                destinationPageIndex >= limits.maximumPageCount))) {
      return Err<PdfSafeLinkMetadata, StructuredFailure>(
        _backendFailure('invalid_link_output'),
      );
    }
    return Ok<PdfSafeLinkMetadata, StructuredFailure>(
      PdfSafeLinkMetadata._(
        bounds: bounds,
        kind: kind,
        destinationPageIndex: destinationPageIndex,
      ),
    );
  }

  final Rect2 bounds;
  final PdfSafeLinkKind kind;
  final int? destinationPageIndex;

  /// Revalidates complete link metadata under receiving processing limits.
  Result<PdfSafeLinkMetadata, StructuredFailure> validatedFor(
    PdfProcessingLimits limits,
  ) => PdfSafeLinkMetadata.create(
    bounds: bounds,
    kind: kind,
    destinationPageIndex: destinationPageIndex,
    limits: limits,
  );

  @override
  String toString() => 'PdfSafeLinkMetadata(${kind.name})';
}

/// Bounded backend-neutral safe-link extraction request.
final class PdfLinkExtractRequest {
  const PdfLinkExtractRequest({
    required this.reference,
    required this.trust,
    required this.region,
    required this.limits,
    required this.cancellationToken,
    this.allowExternalHttpMetadata = false,
  });

  final PdfPageReference reference;
  final PdfInputTrust trust;
  final PdfPageClip region;
  final PdfProcessingLimits limits;
  final CancellationToken cancellationToken;

  /// Explicit permission for inert HTTP(S) classification only. Targets remain
  /// unexposed; this never authorizes activation, network access or export.
  final bool allowExternalHttpMetadata;

  @override
  String toString() => 'PdfLinkExtractRequest(redacted)';
}

/// Immutable bounded safe-link output.
final class PdfSafeLinks {
  PdfSafeLinks._(List<PdfSafeLinkMetadata> links)
    : links = List<PdfSafeLinkMetadata>.unmodifiable(links);

  static Result<PdfSafeLinks, StructuredFailure> capture({
    required Iterable<PdfSafeLinkMetadata> links,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) {
    if (cancellationToken.isCancelled) {
      return Err<PdfSafeLinks, StructuredFailure>(_backendFailure('cancelled'));
    }
    final captured = <PdfSafeLinkMetadata>[];
    try {
      final iterator = links.iterator;
      while (iterator.moveNext()) {
        if (cancellationToken.isCancelled) {
          return Err<PdfSafeLinks, StructuredFailure>(
            _backendFailure('cancelled'),
          );
        }
        if (captured.length >= limits.maximumLinks) {
          return Err<PdfSafeLinks, StructuredFailure>(
            _backendFailure('link_limit'),
          );
        }
        final checkedLink = iterator.current.validatedFor(limits);
        if (checkedLink is! Ok<PdfSafeLinkMetadata, StructuredFailure>) {
          return Err<PdfSafeLinks, StructuredFailure>(
            _backendFailure('invalid_link_output'),
          );
        }
        captured.add(checkedLink.value);
      }
    } on Object {
      return Err<PdfSafeLinks, StructuredFailure>(
        _backendFailure('invalid_link_output'),
      );
    }
    if (cancellationToken.isCancelled) {
      return Err<PdfSafeLinks, StructuredFailure>(_backendFailure('cancelled'));
    }
    return Ok<PdfSafeLinks, StructuredFailure>(PdfSafeLinks._(captured));
  }

  final List<PdfSafeLinkMetadata> links;

  @override
  String toString() => 'PdfSafeLinks(count: ${links.length})';
}

/// Stable inert placeholder evidence for a preserved PDF reference.
enum PdfPlaceholderReason { missing, corrupt, quarantined, backendUnavailable }

final class PdfPagePlaceholder {
  const PdfPagePlaceholder({required this.reference, required this.reason});

  final PdfPageReference reference;
  final PdfPlaceholderReason reason;

  Rect2 get bounds => (Rect2.fromEdges(
    left: 0,
    top: 0,
    right: reference.displayedWidth,
    bottom: reference.displayedHeight,
  ) as Ok<Rect2, StructuredFailure>).value;

  @override
  String toString() => 'PdfPagePlaceholder(${reason.name})';
}

/// Replaceable PDF parsing, rendering, and extraction capability.
abstract interface class PdfBackend {
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  });

  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  });

  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  });

  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  });
}

/// Provisional backend that never supplies bytes to the unreviewed engine.
final class QuarantinedPdfBackend implements PdfBackend {
  const QuarantinedPdfBackend();

  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    if (request.cancellationToken.isCancelled) {
      return const PdfInspectionCancelled();
    }
    return request.trust == PdfInputTrust.untrusted
        ? const PdfQuarantined()
        : const PdfBackendUnavailable();
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async => PdfRenderFailure(
    request.cancellationToken.isCancelled
        ? PdfRenderFailureReason.cancelled
        : request.trust == PdfInputTrust.untrusted
        ? PdfRenderFailureReason.quarantined
        : PdfRenderFailureReason.backendUnavailable,
  );

  @override
  Future<Result<PdfExtractedText, StructuredFailure>> extractText(
    PdfTextExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfExtractedText, StructuredFailure>(
    _backendFailure(
      request.cancellationToken.isCancelled
          ? 'cancelled'
          : request.trust == PdfInputTrust.untrusted
          ? 'quarantined'
          : 'backend_unavailable',
    ),
  );

  @override
  Future<Result<PdfSafeLinks, StructuredFailure>> extractLinks(
    PdfLinkExtractRequest request, {
    required PdfResourceReader resourceReader,
  }) async => Err<PdfSafeLinks, StructuredFailure>(
    _backendFailure(
      request.cancellationToken.isCancelled
          ? 'cancelled'
          : request.trust == PdfInputTrust.untrusted
          ? 'quarantined'
          : 'backend_unavailable',
    ),
  );
}

bool _integerProductWithin(int left, int right, int maximum) {
  if (left <= 0 ||
      right <= 0 ||
      maximum <= 0 ||
      left > maximumWebSafeInteger ||
      right > maximumWebSafeInteger ||
      maximum > maximumWebSafeInteger) {
    return false;
  }
  return left <= maximum ~/ right;
}

final ResourceIdentity _probeResourceIdentity = ResourceIdentity.fromUuid(
  (UuidIdentifier.parse(
    '00000000-0000-4000-8000-000000000000',
  ) as Ok<UuidIdentifier, StructuredFailure>).value,
);

StructuredFailure _backendFailure(String suffix) => StructuredFailure(
  code: 'documents.pdf.backend.$suffix',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'The PDF backend could not satisfy the bounded request.',
);
