// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/pdf/pdf_notebook_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/pdf_geometry_checks.dart';
import '../support/phase3_test_support.dart';
import '../support/uuid_sequence_generator.dart';

void main() {
  test('PDF import selections are bounded, validated and source ordered', () {
    expect(value(parsePdfPageSelection('all', 5)), [0, 1, 2, 3, 4]);
    expect(value(parsePdfPageSelection(' 5, 2-3, 2, 1 ', 5)), [0, 1, 2, 4]);
    for (final input in [
      '',
      '0',
      '-1',
      '2-1',
      '1-6',
      '6',
      '1,,2',
      '1.0',
      'all,1',
      '1-2-3',
      '9' * 8193,
    ]) {
      expect(
        parsePdfPageSelection(input, 5),
        isA<Err<List<int>, StructuredFailure>>(),
        reason: input.substring(0, input.length.clamp(0, 20)),
      );
    }
    expect(
      parsePdfPageSelection('all', 1001),
      isA<Err<List<int>, StructuredFailure>>(),
    );
    expect(
      parsePdfPageSelection('all', 0),
      isA<Err<List<int>, StructuredFailure>>(),
    );
  });

  for (final selected in ['all', '3,1-2,1', '2']) {
    test(
      'PDF import $selected preserves notes and geometry with atomic history',
      () async {
        final opened = await source();
        final coordinator = phase3Coordinator(historyBytes: 100000);
        final before = coordinator.snapshot;
        final request = await plan(opened, before, selected);
        var observations = 0;
        coordinator.addListener((change) {
          observations++;
          expect(change.flags.structure, isTrue);
          expect(
            coordinator.snapshot.root.resources.entries,
            hasLength(observations == 2 ? 0 : 1),
          );
        });
        expect(
          coordinator.execute(request),
          isA<Ok<CommandCommit, CommandFailure>>(),
        );
        final after = coordinator.snapshot;
        expect(after.root, isA<NotebookDocument>());
        expect(after.root.pages.first, same(before.root.pages.first));
        expect(after.resources, hasLength(1));
        expect(after.resources.single.bytes, same(opened.resource.bytes));
        expect(coordinator.retainedHistoryCount, 1);
        for (final page in after.root.pages.skip(1)) {
          final layer = page.layers.first as PdfSourceLayer;
          final original = opened.root.pages[layer.reference.pageIndex];
          expect(
            layer.reference,
            same((original.layers.first as PdfSourceLayer).reference),
          );
          expect(page.size, original.size);
          expect(layer.locked, isTrue);
          expect(page.layers.last.locked, isFalse);
          expect(page.layers.last.objects, isEmpty);
          expect(after.revisions.pages.containsKey(page.id), isTrue);
          expect(after.revisions.layers.containsKey(layer.id), isTrue);
        }
        expect(coordinator.undo(), isA<Ok<CommandCommit, CommandFailure>>());
        expect(coordinator.snapshot.root, same(before.root));
        expect(coordinator.snapshot.resources, isEmpty);
        expect(
          coordinator.snapshot.revisions.pages.keys,
          before.revisions.pages.keys,
        );
        expect(coordinator.redo(), isA<Ok<CommandCommit, CommandFailure>>());
        expect(coordinator.snapshot.root, same(after.root));
        expect(
          coordinator.snapshot.resources.single,
          same(after.resources.single),
        );
        expect(
          coordinator.snapshot.revisions.pages[after.root.pages.last.id],
          isNot(after.revisions.pages[after.root.pages.last.id]),
        );
        expect(observations, 3);
      },
    );
  }

  test('PDF import reuses resource but generates independent page and layer identities', () async {
    final opened = await source();
    final coordinator = phase3Coordinator(historyBytes: 100000);
    final first = await plan(opened, coordinator.snapshot, 'all');
    expect(
      coordinator.execute(first),
      isA<Ok<CommandCommit, CommandFailure>>(),
    );
    final second = await plan(opened, coordinator.snapshot, '2', seed: 5000);
    expect(
      coordinator.execute(second),
      isA<Ok<CommandCommit, CommandFailure>>(),
    );
    final root = coordinator.snapshot.root;
    expect(root.pages, hasLength(5));
    expect(
      (root.pages[1].layers.first as PdfSourceLayer).reference.pageIndex,
      1,
    );
    expect(root.resources.entries, hasLength(1));
    expect(
      coordinator.snapshot.resources.single.bytes,
      same(opened.resource.bytes),
    );
    expect(root.pages.map((p) => p.id).toSet(), hasLength(5));
    final layers = root.pages.expand((p) => p.layers).toList();
    expect(layers.map((l) => l.id).toSet(), hasLength(layers.length));
    coordinator.undo();
    expect(coordinator.snapshot.resources, hasLength(1));
    coordinator.undo();
    expect(coordinator.snapshot.resources, isEmpty);
  });

  test('PDF import rejects stale destination and final cancellation without publication', () async {
    final opened = await source();
    final coordinator = phase3Coordinator(historyBytes: 100000);
    final first = await plan(opened, coordinator.snapshot, '1');
    final stale = await plan(opened, coordinator.snapshot, '2', seed: 5000);
    coordinator.execute(first);
    final before = coordinator.snapshot;
    var notifications = 0;
    coordinator.addListener((_) => notifications++);
    expect(
      coordinator.execute(stale),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    final current = await plan(opened, coordinator.snapshot, '2', seed: 7000);
    expect(
      coordinator.execute(current, stillCurrent: () => false),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    expect(coordinator.snapshot.root, same(before.root));
    expect(
      coordinator.snapshot.currentContentIdentity,
      before.currentContentIdentity,
    );
    expect(coordinator.retainedHistoryCount, 1);
    expect(notifications, 0);
  });

  test('PDF import capacity rejection and UUID failure preserve authoritative state', () async {
    final opened = await source();
    final coordinator = phase3Coordinator(historyBytes: 1);
    final before = coordinator.snapshot;
    final request = await plan(opened, before, 'all');
    expect(
      coordinator.execute(request),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    expect(coordinator.snapshot.root, same(before.root));
    expect(coordinator.snapshot.resources, isEmpty);
    expect(coordinator.retainedHistoryCount, 0);
    final failed = await prepareNotebookPdfImport(
      opened: opened,
      destination: before,
      afterPageId: before.root.pages.first.id,
      selection: 'all',
      uuidGenerator: UuidSequenceGenerator.fromValues([before.root.id.uuid]),
      cancellationToken: CancellationController().token,
    );
    expect(failed, isA<Err<ImportPdfPagesRequest, StructuredFailure>>());
  });

  test(
    'PDF import cancellation during identity preparation publishes nothing',
    () async {
      final opened = await source();
      final coordinator = phase3Coordinator(historyBytes: 100000);
      final token = CancellationController();
      final result = await prepareNotebookPdfImport(
        opened: opened,
        destination: coordinator.snapshot,
        afterPageId: coordinator.snapshot.root.pages.first.id,
        selection: 'all',
        uuidGenerator: CancelUuid(token),
        cancellationToken: token.token,
      );
      expect(result, isA<Err<ImportPdfPagesRequest, StructuredFailure>>());
      expect(coordinator.retainedHistoryCount, 0);
      expect(coordinator.snapshot.resources, isEmpty);
    },
  );

  test(
    'PDF import uses the selected section and preserves both neighboring pages',
    () async {
      final opened = await source();
      final first = testSection(
        pages: [
          testPage(layers: [testContentLayer()]),
        ],
      );
      final left = testPage(
        id: 21,
        layers: [
          testContentLayer(id: 11, objects: [testObject(id: 5)]),
        ],
      );
      final right = testPage(id: 22, layers: [testContentLayer(id: 12)]);
      final second = testSection(id: 31, pages: [left, right]);
      final root = testNotebook(sections: [first, second]);
      final coordinator = phase3Coordinator(root: root, historyBytes: 100000);
      final request = value(
        await prepareNotebookPdfImport(
          opened: opened,
          destination: coordinator.snapshot,
          afterPageId: left.id,
          selection: '3,1',
          uuidGenerator: UuidSequenceGenerator.fromValues([
            for (var i = 1000; i < 1020; i++) testUuid(i),
          ]),
          cancellationToken: CancellationController().token,
        ),
      );
      expect(
        coordinator.execute(request),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      final after = coordinator.snapshot.root as NotebookDocument;
      expect(after.sections.first, same(first));
      expect(after.sections[1].pages.first, same(left));
      expect(after.sections[1].pages.last, same(right));
      expect(
        after.sections[1].pages
            .skip(1)
            .take(2)
            .map((p) => (p.layers.first as PdfSourceLayer).reference.pageIndex),
        [0, 2],
      );
      coordinator.undo();
      expect(coordinator.snapshot.root, same(root));
    },
  );

  test('PDF import destination and request page capacity reject before publication', () async {
    final opened = await source();
    final root = testNotebook(
      sections: [
        testSection(
          pages: [
            for (var i = 0; i < ImportPdfPagesRequest.maximumNotebookPages; i++)
              testPage(
                id: 10000 + i,
                layers: [testContentLayer(id: 30000 + i)],
              ),
          ],
        ),
      ],
    );
    final coordinator = phase3Coordinator(root: root, historyBytes: 100000);
    final prepared = await prepareNotebookPdfImport(
      opened: opened,
      destination: coordinator.snapshot,
      afterPageId: root.pages.first.id,
      selection: '1',
      uuidGenerator: UuidSequenceGenerator.fromValues([]),
      cancellationToken: CancellationController().token,
    );
    expect(prepared, isA<Err<ImportPdfPagesRequest, StructuredFailure>>());
    expect(coordinator.snapshot.root, same(root));
    expect(coordinator.retainedHistoryCount, 0);
    final small = phase3Coordinator(historyBytes: 100000);
    final valid = await plan(opened, small.snapshot, '1');
    final oversized = ImportPdfPagesRequest(
      documentId: valid.documentId,
      metadata: valid.metadata,
      preconditions: valid.preconditions,
      sectionId: valid.sectionId,
      afterPageId: valid.afterPageId,
      pages: List.filled(1001, valid.pages.single),
      resource: valid.resource,
    );
    expect(small.execute(oversized), isA<Err<CommandCommit, CommandFailure>>());
    expect(small.retainedHistoryCount, 0);
    expect(small.snapshot.resources, isEmpty);
  });

  test(
    'PDF import retired page identities cannot be reused after Undo',
    () async {
      final opened = await source();
      final coordinator = phase3Coordinator(historyBytes: 100000);
      final original = await plan(opened, coordinator.snapshot, '1');
      coordinator.execute(original);
      coordinator.undo();
      final attempt = ImportPdfPagesRequest(
        documentId: original.documentId,
        metadata: original.metadata,
        preconditions: RevisionPreconditions(
          sections: {
            original.sectionId:
                coordinator.snapshot.revisions.sections[original.sectionId]!,
          },
          pages: {
            original.afterPageId:
                coordinator.snapshot.revisions.pages[original.afterPageId]!,
          },
          resourceCatalog: coordinator.snapshot.revisions.resourceCatalog,
        ),
        sectionId: original.sectionId,
        afterPageId: original.afterPageId,
        pages: original.pages,
        resource: original.resource,
      );
      expect(
        coordinator.execute(attempt),
        isA<Err<CommandCommit, CommandFailure>>(),
      );
      expect(coordinator.snapshot.canRedo, isTrue);
      expect(coordinator.redo(), isA<Ok<CommandCommit, CommandFailure>>());
    },
  );

  test(
    'PDF import companion state precedes observers and reentry rejects',
    () async {
      final opened = await source();
      final coordinator = phase3Coordinator(historyBytes: 100000);
      final request = await plan(opened, coordinator.snapshot, '1');
      var companion = false;
      Result<CommandCommit, CommandFailure>? nested;
      coordinator.addListener((_) {
        expect(companion, isTrue);
        expect(coordinator.snapshot.root.pages, hasLength(2));
        nested = coordinator.undo();
        throw StateError('observer');
      });
      final result = coordinator.execute(
        request,
        publishCompanionState: () => companion = true,
      );
      expect(result, isA<Ok<CommandCommit, CommandFailure>>());
      expect(
        (result as Ok<CommandCommit, CommandFailure>)
            .value
            .observerFailureCount,
        1,
      );
      expect(nested, isA<Err<CommandCommit, CommandFailure>>());
      expect(coordinator.snapshot.root.pages, hasLength(2));
    },
  );
}

T value<T>(Result<T, StructuredFailure> result) =>
    (result as Ok<T, StructuredFailure>).value;
Future<ImportPdfPagesRequest> plan(
  LocalPdfOpenSuccess opened,
  DocumentCoordinatorSnapshot destination,
  String selection, {
  int seed = 1000,
}) async => value(
  await prepareNotebookPdfImport(
    opened: opened,
    destination: destination,
    afterPageId: destination.root.pages.first.id,
    selection: selection,
    uuidGenerator: UuidSequenceGenerator.fromValues([
      for (var i = seed; i < seed + 20; i++) testUuid(i),
    ]),
    cancellationToken: CancellationController().token,
  ),
);

Future<LocalPdfOpenSuccess> source() async =>
    await LocalPdfOpenWorkflow(
          selector: LocalPdfFileSelector(host: Picker()),
          backend: Backend(),
          modelLimits: geometryModelLimits,
          processingLimits: geometryProcessingLimits,
        ).open(
          cancellationToken: CancellationController().token,
          stillCurrent: () => true,
        )
        as LocalPdfOpenSuccess;

final class Picker implements LocalPdfPickerHost {
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => Handle();
}

final class Handle implements LocalPdfFileHandle {
  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) => Stream.value(markedPdf(geometryCases.first, 0));
}

final class Backend implements PdfBackend {
  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async => PdfInspectSuccess.capture(
    backendIdentity: value(PdfBackendIdentity.parse('test.import')),
    pages: [
      for (var i = 0; i < 3; i++)
        value(
          PdfInspectedPage.create(
            pageIndex: i,
            boxKind: PdfPageBoxKind.resolvedBounds,
            sourceBox: value(
              PdfSourceBox.create(
                left: -10,
                bottom: 20,
                right: 190,
                top: 120,
                limits: geometryModelLimits,
              ),
            ),
            rotation: PdfPageRotation.degrees90,
            displayedWidth: 100,
            displayedHeight: 200,
            limits: geometryModelLimits,
          ),
        ),
    ],
    modelLimits: geometryModelLimits,
    limits: request.limits,
    cancellationToken: request.cancellationToken,
  );
  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) => const QuarantinedPdfBackend().render(
    request,
    resourceReader: resourceReader,
  );
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

final class CancelUuid implements UuidGenerator {
  CancelUuid(this.controller);
  final CancellationController controller;
  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    controller.cancel();
    return Ok(testUuid(1000));
  }
}
