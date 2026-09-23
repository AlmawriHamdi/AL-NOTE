// SPDX-License-Identifier: GPL-3.0-or-later
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../commands.dart';
import '../layers/document_layer.dart';
import '../model/document_root.dart';
import '../model/identifiers.dart';
import 'pdf_open_workflow.dart';

/// One-based user selection, returned as unique zero-based indices in source order.
/// Empty text is invalid; `all` is the explicit default.
Result<List<int>, StructuredFailure> parsePdfPageSelection(
  String text,
  int sourcePageCount,
) {
  if (text.length > 8192 ||
      sourcePageCount <= 0 ||
      sourcePageCount > ImportPdfPagesRequest.maximumImportedPages) {
    return Err(_failure('selection_limit'));
  }
  final input = text.trim();
  if (input.toLowerCase() == 'all') {
    return Ok(List.unmodifiable(List.generate(sourcePageCount, (i) => i)));
  }
  final selected = <int>{};
  for (final part in input.split(',')) {
    final match = RegExp(r'^\s*([0-9]{1,4})\s*(?:-\s*([0-9]{1,4})\s*)?$')
        .firstMatch(part);
    if (match == null) return Err(_failure('invalid_selection'));
    final first = int.parse(match[1]!);
    final last = match[2] == null ? first : int.parse(match[2]!);
    if (first < 1 || last < first || last > sourcePageCount)
      return Err(_failure('invalid_selection'));
    for (var page = first; page <= last; page++) {
      selected.add(page - 1);
    }
  }
  if (selected.isEmpty) return Err(_failure('invalid_selection'));
  return Ok(List.unmodifiable(selected.toList()..sort()));
}

/// Prepares new identities and immutable page values only. Source acquisition
/// and inspection reuse LocalPdfOpenWorkflow, without installing its document.
Future<Result<ImportPdfPagesRequest, StructuredFailure>>
prepareNotebookPdfImport({
  required LocalPdfOpenSuccess opened,
  required DocumentCoordinatorSnapshot destination,
  required PageId afterPageId,
  required String selection,
  required UuidGenerator uuidGenerator,
  required CancellationToken cancellationToken,
}) async {
  try {
    final root = destination.root;
    if (root is! NotebookDocument || cancellationToken.isCancelled)
      return Err(_failure('unavailable'));
    final section = root.sections
        .where((s) => s.pages.any((p) => p.id == afterPageId))
        .firstOrNull;
    final chosen = parsePdfPageSelection(selection, opened.root.pages.length);
    if (section == null || chosen is! Ok<List<int>, StructuredFailure>)
      return Err(_failure('invalid_selection'));
    if (root.pages.length >
        ImportPdfPagesRequest.maximumNotebookPages - chosen.value.length) {
      return Err(_failure('page_limit'));
    }
    final used = <UuidIdentifier>{
      root.id.uuid,
      for (final s in root.sections) s.id.uuid,
      for (final p in root.pages) p.id.uuid,
      for (final p in root.pages)
        for (final l in p.layers) l.id.uuid,
      for (final p in root.pages)
        for (final l in p.layers)
          for (final o in l.objects) o.id.uuid,
      for (final r in root.resources.entries) r.identity.uuid,
      opened.resource.identity.uuid,
    };
    UuidIdentifier next() {
      if (cancellationToken.isCancelled) throw const FormatException();
      final value = uuidGenerator.generateV4();
      if (value is! Ok<UuidIdentifier, StructuredFailure> ||
          !used.add(value.value))
        throw const FormatException();
      return value.value;
    }

    final pages = <DocumentPage>[];
    for (final index in chosen.value) {
      if (cancellationToken.isCancelled) return Err(_failure('cancelled'));
      final original = opened.root.pages[index];
      final source = original.layers.first as PdfSourceLayer;
      final notes = original.layers.last as ContentLayer;
      final copiedNotes = ContentLayer.create(
        id: LayerId.fromUuid(next()),
        envelopeVersion: notes.envelopeVersion,
        typeSchemaVersion: notes.typeSchemaVersion,
        name: notes.name,
        visible: true,
        locked: false,
        opacity: 1,
        objects: const [],
        typeData: notes.typeData,
        extensionData: notes.extensionData,
      );
      if (copiedNotes is! Ok<ContentLayer, StructuredFailure>)
        return Err(_failure('invalid_page'));
      final page = DocumentPage.create(
        id: PageId.fromUuid(next()),
        name: original.name,
        size: original.size,
        layers: [
          source.withIdentity(LayerId.fromUuid(next())),
          copiedNotes.value,
        ],
        extensionData: original.extensionData,
      );
      if (page is! Ok<DocumentPage, StructuredFailure>)
        return Err(_failure('invalid_page'));
      pages.add(page.value);
      if (pages.length % 32 == 0) await Future<void>.delayed(Duration.zero);
    }
    if (cancellationToken.isCancelled) return Err(_failure('cancelled'));
    return Ok(
      ImportPdfPagesRequest(
        documentId: root.id,
        metadata: CommandMetadata(
          family: (CommandFamily.parse(
            'alnote.commands.pdf.import_pages',
          ) as Ok<CommandFamily, StructuredFailure>).value,
          correlationId: CommandCorrelationId.fromUuid(next()),
          description: 'Import PDF pages',
        ),
        preconditions: RevisionPreconditions(
          sections: {section.id: destination.revisions.sections[section.id]!},
          pages: {afterPageId: destination.revisions.pages[afterPageId]!},
          resourceCatalog: destination.revisions.resourceCatalog,
        ),
        sectionId: section.id,
        afterPageId: afterPageId,
        pages: pages,
        resource: opened.resource,
      ),
    );
  } on Object {
    return Err(_failure('preparation_failed'));
  }
}

StructuredFailure _failure(String reason) => StructuredFailure(
  code: 'documents.pdf.import.$reason',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'PDF page import could not be prepared.',
);
