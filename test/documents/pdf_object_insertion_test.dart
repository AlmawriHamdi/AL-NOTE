// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/pdf/pdf_object_insertion.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/pdf_geometry_checks.dart';
import '../support/phase3_test_support.dart';
import '../support/uuid_sequence_generator.dart';
import 'pdf_notebook_import_test.dart' as fixture;

void main() {
  test('PDF Object insertion is ordered, fitted, immutable and one exact history entry', () async {
    final coordinator = destination();
    final before = coordinator.snapshot;
    final opened = await fixture.source();
    final request = await plan(coordinator, opened, '3,1-2,1');
    expect(coordinator.snapshot.root, same(before.root));
    expect(request.additions, hasLength(3));
    expect(request.resourceAdditions.single.bytes, same(opened.resource.bytes));
    for (var i = 0; i < 3; i++) {
      final object = request.additions[i].object;
      final payload = fixture.value(
        PdfPageObjectPayload.decode(
          object.payload,
          limits: geometryModelLimits,
        ),
      );
      final reference =
          (opened.root.pages[i].layers.first as PdfSourceLayer).reference;
      expect(payload.reference, reference);
      expect(payload.clip, PdfPageClip.full);
      expect(object.transform.storageCoefficients[4], 48 + 16 * i);
      final end = fixture.value(
        object.transform.applyToPoint(payload.bounds.bottomRight),
      );
      expect(end.x, lessThan(600));
      expect(end.y, lessThan(800));
    }
    var events = 0;
    coordinator.addListener((_) => events++);
    expect(
      coordinator.execute(request),
      isA<Ok<CommandCommit, CommandFailure>>(),
    );
    final after = coordinator.snapshot;
    expect(events, 1);
    expect(coordinator.retainedHistoryCount, 1);
    expect(after.root.pages, hasLength(1));
    expect(
      after.root.pages.single.layers.single.objects,
      request.additions.map((a) => a.object),
    );
    expect(after.resources.single.bytes, same(opened.resource.bytes));
    coordinator.undo();
    expect(coordinator.snapshot.root, same(before.root));
    expect(coordinator.snapshot.resources, isEmpty);
    coordinator.redo();
    expect(coordinator.snapshot.root, same(after.root));
    expect(
      coordinator.snapshot.resources.single.bytes,
      same(opened.resource.bytes),
    );
    final repeated = await plan(
      coordinator,
      await fixture.source(),
      '2',
      seed: 3000,
    );
    expect(repeated.resourceAdditions, isEmpty);
    expect(
      coordinator.execute(repeated),
      isA<Ok<CommandCommit, CommandFailure>>(),
    );
    expect(
      coordinator.snapshot.resources.single.bytes,
      same(opened.resource.bytes),
    );
  });

  test('PDF Object preparation rejects selection, ceilings, UUID conflicts and cancellation', () async {
    final coordinator = destination();
    final opened = await fixture.source();
    final before = coordinator.snapshot;
    Future<Result<AtomicObjectCollectionEditRequest, StructuredFailure>>
    attempt({
      String selection = 'all',
      int maximum = 10,
      UuidGenerator? generator,
      CancellationController? cancellation,
    }) => preparePdfObjectInsertion(
      opened: opened,
      destination: before,
      pageId: before.root.pages.single.id,
      layerId: before.root.pages.single.layers.single.id,
      selection: selection,
      modelLimits: geometryModelLimits,
      maximumOperations: maximum,
      uuidGenerator:
          generator ??
          UuidSequenceGenerator.fromValues([
            for (var i = 1000; i < 1020; i++) testUuid(i),
          ]),
      cancellationToken: (cancellation ?? CancellationController()).token,
    );
    for (final selection in ['', '0', '4', '2-1']) {
      expect(
        await attempt(selection: selection),
        isA<Err<AtomicObjectCollectionEditRequest, StructuredFailure>>(),
      );
    }
    expect(
      await attempt(maximum: 3),
      isA<Err<AtomicObjectCollectionEditRequest, StructuredFailure>>(),
    );
    expect(
      await attempt(
        generator: UuidSequenceGenerator.fromValues([before.root.id.uuid]),
      ),
      isA<Err<AtomicObjectCollectionEditRequest, StructuredFailure>>(),
    );
    final cancellation = CancellationController();
    expect(
      await attempt(
        generator: fixture.CancelUuid(cancellation),
        cancellation: cancellation,
      ),
      isA<Err<AtomicObjectCollectionEditRequest, StructuredFailure>>(),
    );
    expect(coordinator.snapshot.root, same(before.root));
    expect(
      coordinator.snapshot.currentContentIdentity,
      before.currentContentIdentity,
    );
    expect(coordinator.retainedHistoryCount, 0);
  });

  test('PDF Object stale/cancelled/history rejection never publishes resources or Objects', () async {
    final opened = await fixture.source();
    final coordinator = destination();
    final first = await plan(coordinator, opened, '1');
    final stale = await plan(coordinator, opened, '2', seed: 3000);
    coordinator.execute(first);
    final before = coordinator.snapshot;
    var notifications = 0;
    coordinator.addListener((_) => notifications++);
    expect(
      coordinator.execute(stale),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    final current = await plan(coordinator, opened, '2', seed: 4000);
    expect(
      coordinator.execute(current, stillCurrent: () => false),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    expect(coordinator.snapshot.root, same(before.root));
    expect(
      coordinator.snapshot.currentContentIdentity,
      before.currentContentIdentity,
    );
    expect(notifications, 0);
    final limited = destination(historyBytes: 1);
    final limitedBefore = limited.snapshot;
    expect(
      limited.execute(await plan(limited, opened, '1')),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    expect(limited.snapshot.root, same(limitedBefore.root));
    expect(limited.snapshot.resources, isEmpty);
  });

  test('PDF Object insertion rejects conflicting bytes under an existing resource identity', () async {
    final opened = await fixture.source();
    final coordinator = destination();
    coordinator.execute(await plan(coordinator, opened, '1'));
    final before = coordinator.snapshot;
    final resource = opened.resource;
    final changed = DocumentResourceSnapshot(
      fixture.value(
        DocumentResource.capture(
          identity: resource.identity,
          mediaType: resource.mediaType,
          role: resource.role,
          schemaVersion: resource.schemaVersion,
          bytes: [1, 2, 3],
        ),
      ),
    );
    final conflicting = fixture.value(
      DocumentCoordinatorSnapshot.create(
        root: before.root,
        resources: [changed],
        maximumResources: 1,
        revisions: before.revisions,
        currentContentIdentity: before.currentContentIdentity,
        savedContentIdentity: before.savedContentIdentity,
        canUndo: before.canUndo,
        canRedo: before.canRedo,
        historyTraversalEnabled: before.historyTraversalEnabled,
      ),
    );
    final result = await preparePdfObjectInsertion(
      opened: opened,
      destination: conflicting,
      pageId: before.root.pages.single.id,
      layerId: before.root.pages.single.layers.single.id,
      selection: '1',
      modelLimits: geometryModelLimits,
      maximumOperations: 10,
      uuidGenerator: UuidSequenceGenerator.fromValues([]),
      cancellationToken: CancellationController().token,
    );
    expect(
      (result as Err<AtomicObjectCollectionEditRequest, StructuredFailure>)
          .error
          .code,
      'documents.pdf.insertion.resource_identity_collision',
    );
    expect(coordinator.snapshot.root, same(before.root));
    expect(coordinator.snapshot.resources.single.bytes, same(resource.bytes));
  });

  for (final flags in [(false, false), (true, true)]) {
    test('PDF Object insertion rejects ineligible layer $flags', () async {
      final coordinator = destination(visible: flags.$1, locked: flags.$2);
      final before = coordinator.snapshot;
      final result = await preparePdfObjectInsertion(
        opened: await fixture.source(),
        destination: before,
        pageId: before.root.pages.single.id,
        layerId: before.root.pages.single.layers.single.id,
        selection: '1',
        modelLimits: geometryModelLimits,
        maximumOperations: 10,
        uuidGenerator: UuidSequenceGenerator.fromValues([]),
        cancellationToken: CancellationController().token,
      );
      expect(
        result,
        isA<Err<AtomicObjectCollectionEditRequest, StructuredFailure>>(),
      );
      expect(coordinator.snapshot.root, same(before.root));
    });
  }
}

DocumentMutationCoordinator destination({
  int historyBytes = 100000,
  bool visible = true,
  bool locked = false,
}) => phase3Coordinator(
  historyBytes: historyBytes,
  root: testNotebook(
    sections: [
      testSection(
        pages: [
          testPage(
            layers: [
              testContentLayer(objects: [], visible: visible, locked: locked),
            ],
          ),
        ],
      ),
    ],
  ),
  registry: testRegistry([PdfPageObjectTypeDefinition(geometryModelLimits)]),
);

Future<AtomicObjectCollectionEditRequest> plan(
  DocumentMutationCoordinator coordinator,
  LocalPdfOpenSuccess opened,
  String selection, {
  int seed = 1000,
}) async => fixture.value(
  await preparePdfObjectInsertion(
    opened: opened,
    destination: coordinator.snapshot,
    pageId: coordinator.snapshot.root.pages.single.id,
    layerId: coordinator.snapshot.root.pages.single.layers.single.id,
    selection: selection,
    modelLimits: geometryModelLimits,
    maximumOperations: 10,
    uuidGenerator: UuidSequenceGenerator.fromValues([
      for (var i = seed; i < seed + 20; i++) testUuid(i),
    ]),
    cancellationToken: CancellationController().token,
  ),
);
