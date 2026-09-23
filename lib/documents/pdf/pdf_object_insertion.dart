// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import '../../core/primitives.dart';
import '../commands.dart';
import '../document_model.dart';
import 'pdf_notebook_import.dart';

/// Prepares independent PDF page Objects without changing the destination.
/// Source bytes are shared immutably; only common transforms own placement.
Future<Result<AtomicObjectCollectionEditRequest, StructuredFailure>>
preparePdfObjectInsertion({
  required LocalPdfOpenSuccess opened,
  required DocumentCoordinatorSnapshot destination,
  required PageId pageId,
  required LayerId layerId,
  required String selection,
  required PdfModelLimits modelLimits,
  required int maximumOperations,
  required UuidGenerator uuidGenerator,
  required CancellationToken cancellationToken,
}) async {
  try {
    final root = destination.root;
    final page = root.pages.where((page) => page.id == pageId).firstOrNull;
    final layer = page?.layers
        .where((layer) => layer.id == layerId)
        .firstOrNull;
    if (root is! NotebookDocument ||
        page == null ||
        layer is! ContentLayer ||
        !layer.visible ||
        layer.locked ||
        cancellationToken.isCancelled)
      return Err(_failure('unavailable'));
    final selected = parsePdfPageSelection(selection, opened.root.pages.length);
    if (selected is! Ok<List<int>, StructuredFailure>)
      return Err(_failure('invalid_selection'));
    final resource = opened.resource;
    final existing = destination.resources
        .where((item) => item.identity == resource.identity)
        .firstOrNull;
    if (existing == null && root.resources.contains(resource.identity) ||
        existing != null &&
            (existing.digest != resource.digest ||
                existing.decodedByteLength != resource.decodedByteLength ||
                existing.mediaType != resource.mediaType ||
                existing.role != resource.role ||
                existing.schemaVersion != resource.schemaVersion ||
                existing.packagePath != resource.packagePath))
      return Err(_failure('resource_identity_collision'));
    if (selected.value.length + (existing == null ? 1 : 0) > maximumOperations)
      return Err(_failure('operation_limit'));
    final used = <UuidIdentifier>{
      root.id.uuid,
      for (final section in root.sections) section.id.uuid,
      for (final page in root.pages) page.id.uuid,
      for (final page in root.pages)
        for (final layer in page.layers) layer.id.uuid,
      for (final page in root.pages)
        for (final layer in page.layers)
          for (final object in layer.objects) object.id.uuid,
      for (final entry in root.resources.entries) entry.identity.uuid,
      resource.identity.uuid,
    };
    UuidIdentifier next() {
      if (cancellationToken.isCancelled) throw const FormatException();
      final result = uuidGenerator.generateV4();
      if (result is! Ok<UuidIdentifier, StructuredFailure> ||
          cancellationToken.isCancelled ||
          !used.add(result.value))
        throw const FormatException();
      return result.value;
    }

    T value<T>(Result<T, StructuredFailure> result) =>
        (result as Ok<T, StructuredFailure>).value;
    final additions = <ObjectCollectionAddition>[];
    // Keep every initial Object inside the Page. The bounded diagonal spread
    // remains deterministic for large selections as well as a single page.
    final spread = math.min(page.size.width, page.size.height) * .12;
    final step = selected.value.length <= 1
        ? 0.0
        : math.min(16.0, spread / (selected.value.length - 1));
    final origin = value(Point2.create(x: 0, y: 0));
    for (final index in selected.value) {
      if (cancellationToken.isCancelled) return Err(_failure('cancelled'));
      final source = opened.root.pages[index].layers
          .whereType<PdfSourceLayer>()
          .single;
      final payload = value(
        PdfPageObjectPayload.create(
          reference: source.reference,
          clip: PdfPageClip.full,
          limits: modelLimits,
        ),
      );
      final scale = math.min(
        page.size.width * .72 / payload.bounds.width,
        page.size.height * .72 / payload.bounds.height,
      );
      final scaled = value(
        AffineTransform2D.fromOperation(
          value(
            ScaleTransformOperation2D.create(
              scaleX: scale,
              scaleY: scale,
              pivot: origin,
            ),
          ),
        ),
      );
      final offset = step * additions.length;
      final translated = value(
        AffineTransform2D.fromOperation(
          TranslationTransformOperation2D(
            value(
              Vector2.create(
                x: page.size.width * .08 + offset,
                y: page.size.height * .08 + offset,
              ),
            ),
          ),
        ),
      );
      final object = value(
        ObjectEnvelope.create(
          id: ObjectId.fromUuid(next()),
          typeKey: pdfPageObjectTypeKey,
          envelopeVersion: value(SchemaVersion.create(1)),
          typeSchemaVersion: pdfPageObjectSchemaVersion,
          transform: value(scaled.then(translated)),
          visible: true,
          locked: false,
          payload: payload.encode(),
          extensionData: PreservedMap.empty(),
        ),
      );
      additions.add(ObjectCollectionAddition(layerId: layerId, object: object));
      if (additions.length % 32 == 0) await Future<void>.delayed(Duration.zero);
    }
    if (cancellationToken.isCancelled) return Err(_failure('cancelled'));
    return AtomicObjectCollectionEditRequest.create(
      documentId: root.id,
      metadata: CommandMetadata(
        family: CommandFamily.objectCollectionEdit,
        correlationId: CommandCorrelationId.fromUuid(next()),
        description: 'Insert PDF pages',
      ),
      preconditions: RevisionPreconditions(
        pages: {pageId: destination.revisions.pages[pageId]!},
        layers: {layerId: destination.revisions.layers[layerId]!},
        layerMembership: {
          layerId: destination.revisions.layerMembership[layerId]!,
        },
        resourceCatalog: destination.revisions.resourceCatalog,
      ),
      pageId: pageId,
      additions: additions,
      resourceAdditions: [if (existing == null) resource],
      maximumOperations: maximumOperations,
    );
  } on Object {
    return Err(_failure('preparation_failed'));
  }
}

StructuredFailure _failure(String reason) => StructuredFailure(
  code: 'documents.pdf.insertion.$reason',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'PDF page Objects could not be prepared.',
);
