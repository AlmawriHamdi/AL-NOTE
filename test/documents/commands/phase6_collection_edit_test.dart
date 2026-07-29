// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase3_test_support.dart';
import '../../support/phase4_test_support.dart';
import '../../support/uuid_sequence_generator.dart';

final _limits = _ok(
  HandwritingLimits.create(
    maximumStrokes: 8,
    maximumSamplesPerStroke: 16,
    maximumUnknownFields: 8,
    maximumNestingDepth: 8,
    maximumCoordinateMagnitude: 10000,
    maximumStrokeWidth: 100,
    maximumAbsoluteTilt: 2,
    maximumAbsoluteOrientation: 7,
  ),
);

void main() {
  test(
    'collection insertion publishes once and undo redo restore exact roots',
    () {
      final coordinator = _coordinator();
      final before = coordinator.snapshot.root;
      final page = before.pages.single, layer = page.layers.single;
      final request = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: before.id,
          pageId: page.id,
          metadata: _metadata(800),
          preconditions: RevisionPreconditions(
            pages: {page.id: coordinator.snapshot.revisions.pages[page.id]!},
            layerMembership: {
              layer.id:
                  coordinator.snapshot.revisions.layerMembership[layer.id]!,
            },
          ),
          additions: [
            ObjectCollectionAddition(layerId: layer.id, object: _object()),
          ],
          maximumOperations: 4,
        ),
      );
      final commit = coordinator.execute(request);
      expect(commit, isA<Ok<CommandCommit, CommandFailure>>());
      final after = coordinator.snapshot.root;
      expect(after.pages.single.layers.single.objects, hasLength(1));
      expect(coordinator.undo(), isA<Ok<CommandCommit, CommandFailure>>());
      expect(coordinator.snapshot.root, before);
      expect(coordinator.redo(), isA<Ok<CommandCommit, CommandFailure>>());
      expect(coordinator.snapshot.root, after);
    },
  );

  test('handwriting saves deterministically and reopens with exact root', () {
    final coordinator = _coordinator();
    final root = coordinator.snapshot.root;
    final page = root.pages.single, layer = page.layers.single;
    final request = _ok(
      AtomicObjectCollectionEditRequest.create(
        documentId: root.id,
        pageId: page.id,
        metadata: _metadata(801),
        preconditions: RevisionPreconditions(
          pages: {page.id: coordinator.snapshot.revisions.pages[page.id]!},
          layerMembership: {
            layer.id: coordinator.snapshot.revisions.layerMembership[layer.id]!,
          },
        ),
        additions: [
          ObjectCollectionAddition(layerId: layer.id, object: _object()),
        ],
        maximumOperations: 4,
      ),
    );
    coordinator.execute(request);
    final authoritative = coordinator.snapshot.root;
    final registry = _registry();
    final package = _ok(
      AlnotePackageSnapshot.create(
        document: authoritative,
        resources: const [],
      ),
    );
    final codec = AlnotePackageCodec(objectRegistry: registry);
    final first = _ok(codec.encode(package, limits: phase4Limits()));
    final second = _ok(codec.encode(package, limits: phase4Limits()));
    expect(first, second);
    final opened = AlnotePackageReader(objectRegistry: registry).openBytes(
      first,
      limits: phase4Limits(),
      cancellationToken: CancellationController().token,
    );
    expect(opened, isA<Completed<OpenedAlnotePackage, StructuredFailure>>());
    final reopened =
        (opened as Completed<OpenedAlnotePackage, StructuredFailure>).value
            .materializeDocument(
              cancellationToken: CancellationController().token,
            );
    expect(reopened, isA<Completed<DocumentRoot, StructuredFailure>>());
    expect(
      (reopened as Completed<DocumentRoot, StructuredFailure>).value,
      authoritative,
    );
  });

  test(
    'collection capture uses one total budget and skips rejected tail current',
    () {
      final root = testNotebook();
      final page = root.pages.single;
      final layer = page.layers.single;
      final removalTail = _TailIterable<ObjectId>([
        ObjectId.fromUuid(testUuid(900)),
      ]);
      final result = AtomicObjectCollectionEditRequest.create(
        documentId: root.id,
        pageId: page.id,
        metadata: _metadata(899),
        preconditions: RevisionPreconditions(),
        additions: [
          ObjectCollectionAddition(layerId: layer.id, object: _object()),
        ],
        removals: removalTail,
        maximumOperations: 1,
      );
      expect(result, isA<Err<Object?, Object?>>());
      expect(removalTail.rejectedCurrentRead, isFalse);
    },
  );

  test(
    'removed Object generations are ABA-safe and retired IDs cannot be reused',
    () {
      final coordinator = _coordinator();
      final page = coordinator.snapshot.root.pages.single;
      final layer = page.layers.single;
      final object = _object();
      final add = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: coordinator.snapshot.root.id,
          pageId: page.id,
          metadata: _metadata(901),
          preconditions: RevisionPreconditions(
            pages: {page.id: coordinator.snapshot.revisions.pages[page.id]!},
            layerMembership: {
              layer.id:
                  coordinator.snapshot.revisions.layerMembership[layer.id]!,
            },
          ),
          additions: [
            ObjectCollectionAddition(layerId: layer.id, object: object),
          ],
          maximumOperations: 2,
        ),
      );
      expect(coordinator.execute(add), isA<Ok<Object?, Object?>>());
      final beforeRemoval = coordinator.snapshot;
      final remove = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: beforeRemoval.root.id,
          pageId: page.id,
          metadata: _metadata(902),
          preconditions: RevisionPreconditions(
            pages: {page.id: beforeRemoval.revisions.pages[page.id]!},
            objects: {object.id: beforeRemoval.revisions.objects[object.id]!},
            layerMembership: {
              layer.id: beforeRemoval.revisions.layerMembership[layer.id]!,
            },
          ),
          removals: [object.id],
          maximumOperations: 2,
        ),
      );
      expect(coordinator.execute(remove), isA<Ok<Object?, Object?>>());
      expect(coordinator.undo(), isA<Ok<Object?, Object?>>());
      final restoredRevision =
          coordinator.snapshot.revisions.objects[object.id]!;
      expect(
        restoredRevision.value,
        greaterThan(beforeRemoval.revisions.objects[object.id]!.value),
      );
      expect(coordinator.execute(remove), isA<Err<Object?, Object?>>());
      expect(coordinator.redo(), isA<Ok<Object?, Object?>>());
      final retiredReuse = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: coordinator.snapshot.root.id,
          pageId: page.id,
          metadata: _metadata(903),
          preconditions: RevisionPreconditions(
            pages: {page.id: coordinator.snapshot.revisions.pages[page.id]!},
            layerMembership: {
              layer.id:
                  coordinator.snapshot.revisions.layerMembership[layer.id]!,
            },
          ),
          additions: [
            ObjectCollectionAddition(layerId: layer.id, object: object),
          ],
          maximumOperations: 2,
        ),
      );
      expect(coordinator.execute(retiredReuse), isA<Err<Object?, Object?>>());
    },
  );
}

DocumentMutationCoordinator _coordinator() {
  final registry = _registry();
  final generator = UuidSequenceGenerator.fromValues([
    for (var i = 500; i < 550; i++) testUuid(i),
  ]);
  return (DocumentMutationCoordinator.create(
            initialRoot: testNotebook(
              sections: [
                testSection(
                  pages: [
                    testPage(layers: [testContentLayer()]),
                  ],
                ),
              ],
            ),
            validator: DocumentValidator(registry),
            uuidGenerator: generator,
            historyLimits: _ok(
              HistoryLimits.create(
                maximumRetainedCommandCount: 10,
                maximumEstimatedRetainedBytes: 100000,
              ),
            ),
            retainedCostEstimator: FixedHistoryCostEstimator(100),
            maximumListeners: 4,
          )
          as Ok<DocumentMutationCoordinator, CommandFailure>)
      .value;
}

ObjectRegistry _registry() =>
    _ok(ObjectRegistry.create([HandwritingObjectTypeDefinition(_limits)]));
CommandMetadata _metadata(int id) => CommandMetadata(
  family: CommandFamily.objectCollectionEdit,
  correlationId: CommandCorrelationId.fromUuid(testUuid(id)),
  description: 'Phase 6 edit',
);
ObjectEnvelope _object() {
  final style = _ok(
    StrokeStyle.create(
      argb: 0xff123456,
      opacity: 1,
      baseWidth: 3,
      pressureInfluence: .5,
      minimumPressureFactor: .2,
      limits: _limits,
    ),
  );
  final sample = _ok(
    StrokeSample.create(
      position: _ok(Point2.create(x: 10, y: 20)),
      timeMicros: 0,
      limits: _limits,
      unknownFields: PreservedMap({'future': const PreservedString('sample')}),
    ),
  );
  final stroke = _ok(
    HandwritingStroke.create(
      id: StrokeId.fromUuid(testUuid(701)),
      samples: [sample],
      style: style,
      limits: _limits,
    ),
  );
  final payload = _ok(
    HandwritingPayload.create(
      strokes: [stroke],
      limits: _limits,
      unknownFields: PreservedMap({'future': const PreservedString('payload')}),
    ),
  );
  return testObject(
    id: 700,
    typeKey: handwritingObjectTypeKey,
    schemaVersion: handwritingSchemaVersion,
    payload: payload.encode(),
  );
}

T _ok<T, E>(Result<T, E> result) => (result as Ok<T, E>).value;

final class _TailIterable<T> extends Iterable<T> {
  _TailIterable(this.values);
  final List<T> values;
  bool rejectedCurrentRead = false;
  @override
  Iterator<T> get iterator => _TailIterator<T>(this);
}

final class _TailIterator<T> implements Iterator<T> {
  _TailIterator(this.owner);
  final _TailIterable<T> owner;
  var index = -1;
  @override
  bool moveNext() {
    index += 1;
    return index <= owner.values.length;
  }

  @override
  T get current {
    if (index >= owner.values.length) {
      owner.rejectedCurrentRead = true;
      throw StateError('rejected current');
    }
    return owner.values[index];
  }
}
