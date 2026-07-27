// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase3_test_support.dart';
import '../../support/uuid_sequence_generator.dart';

AtomicObjectReplacementRequest replacementRequest(
  DocumentCoordinatorSnapshot snapshot,
  ObjectId target,
  String payload, {
  CommandMetadata? metadata,
}) {
  final source = snapshot.root.pages
      .expand((page) => page.layers)
      .expand((layer) => layer.objects)
      .singleWhere((object) => object.id == target);
  return commandValue(
    AtomicObjectReplacementRequest.create(
      documentId: snapshot.root.id,
      metadata: metadata ?? phase3Metadata(),
      preconditions: objectPreconditions(snapshot, target),
      targetIds: [target],
      replacements: [replacementObject(source, payload)],
      changeCategories: _appearanceChange,
    ),
  );
}

AtomicWholeObjectTransformRequest transformRequest(
  DocumentCoordinatorSnapshot snapshot,
  TransformOperation2D operation, {
  Iterable<ObjectId>? targets,
}) {
  final page = snapshot.root.pages.single;
  final ids = List<ObjectId>.of(
    targets ?? [page.layers.first.objects.first.id],
  );
  final memberships = <LayerId, Revision>{};
  for (final layer in page.layers) {
    if (layer.objects.any((object) => ids.contains(object.id))) {
      memberships[layer.id] = snapshot.revisions.layerMembership[layer.id]!;
    }
  }
  return commandValue(
    AtomicWholeObjectTransformRequest.create(
      documentId: snapshot.root.id,
      metadata: phase3Metadata(family: 'alnote.commands.object.transform'),
      preconditions: RevisionPreconditions(
        pages: {page.id: snapshot.revisions.pages[page.id]!},
        layerMembership: memberships,
        objects: {for (final id in ids) id: snapshot.revisions.objects[id]!},
      ),
      pageId: page.id,
      targetIds: ids,
      operation: operation,
    ),
  );
}

DocumentMutationCoordinator customCoordinator({
  required UuidGenerator uuidGenerator,
  required HistoryRetainedCostEstimator estimator,
  NotebookDocument? root,
  ObjectRegistry? registry,
  int historyCount = 10,
  int historyBytes = 10000,
}) =>
    (DocumentMutationCoordinator.create(
              initialRoot: root ?? phase3Notebook(),
              validator: DocumentValidator(registry ?? editableTestRegistry()),
              uuidGenerator: uuidGenerator,
              historyLimits: commandValue(
                HistoryLimits.create(
                  maximumRetainedCommandCount: historyCount,
                  maximumEstimatedRetainedBytes: historyBytes,
                ),
              ),
              retainedCostEstimator: estimator,
            )
            as Ok<DocumentMutationCoordinator, CommandFailure>)
        .value;

void expectPersistentStateUnchanged(
  DocumentMutationCoordinator coordinator,
  DocumentCoordinatorSnapshot before,
  int historyCount,
) {
  final after = coordinator.snapshot;
  expect(after.root, before.root);
  expect(after.revisions, before.revisions);
  expect(after.currentContentIdentity, before.currentContentIdentity);
  expect(after.savedContentIdentity, before.savedContentIdentity);
  expect(after.isDirty, before.isDirty);
  expect(coordinator.retainedHistoryCount, historyCount);
}

void main() {
  group('DocumentMutationCoordinator', () {
    test('publishes atomically with scoped revisions and one notification', () {
      final coordinator = phase3Coordinator();
      final before = coordinator.snapshot;
      final target = before.root.pages.single.layers.single.objects.first.id;
      final changes = <CommittedChange>[];
      coordinator.addListener(changes.add);
      final result = coordinator.execute(
        replacementRequest(before, target, 'after'),
      );
      expect(result, isA<Ok<CommandCommit, CommandFailure>>());
      final after = coordinator.snapshot;
      expect(after.revisions.document.value, 1);
      expect(after.revisions.objects[target]!.value, 1);
      expect(after.revisions.pages.values.single.value, 0);
      expect(after.revisions.layers.values.single.value, 0);
      expect(after.revisions.layerMembership.values.single.value, 0);
      expect(changes, hasLength(1));
      expect(changes.single.replacedObjectIds, [target]);
      expect(coordinator.retainedHistoryCount, 1);
    });

    test('unrelated Object edit does not stale an Object-scoped request', () {
      final coordinator = phase3Coordinator();
      final initial = coordinator.snapshot;
      final objects = initial.root.pages.single.layers.single.objects;
      final secondPrepared = replacementRequest(
        initial,
        objects.last.id,
        'second',
      );
      expect(
        coordinator.execute(
          replacementRequest(initial, objects.first.id, 'first'),
        ),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      expect(
        coordinator.execute(secondPrepared),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      expect(coordinator.snapshot.revisions.document.value, 2);
    });

    test('stale request returns exact evidence and changes nothing', () {
      final coordinator = phase3Coordinator();
      final initial = coordinator.snapshot;
      final target = initial.root.pages.single.layers.single.objects.first.id;
      final stale = replacementRequest(initial, target, 'stale');
      coordinator.execute(replacementRequest(initial, target, 'fresh'));
      final beforeFailure = coordinator.snapshot;
      final result =
          coordinator.execute(stale) as Err<CommandCommit, CommandFailure>;
      expect(result.error.code, 'documents.commands.stale_revision');
      expect(
        result.error.staleEvidence.single.subject,
        isA<ObjectRevisionSubject>(),
      );
      expect(coordinator.snapshot.root, beforeFailure.root);
      expect(
        coordinator.snapshot.revisions.document,
        beforeFailure.revisions.document,
      );
    });

    test(
      'wrong document and missing preconditions fail without publication',
      () {
        final coordinator = phase3Coordinator();
        final initial = coordinator.snapshot;
        final source = initial.root.pages.single.layers.single.objects.first;
        final request = commandValue(
          AtomicObjectReplacementRequest.create(
            documentId: DocumentId.fromUuid(testUuid(999)),
            metadata: phase3Metadata(),
            preconditions: RevisionPreconditions(),
            targetIds: [source.id],
            replacements: [replacementObject(source, 'bad')],
            changeCategories: _appearanceChange,
          ),
        );
        expect(
          coordinator.execute(request),
          isA<Err<CommandCommit, CommandFailure>>(),
        );
        expect(coordinator.snapshot.root, initial.root);
        expect(coordinator.retainedHistoryCount, 0);
      },
    );

    test('hidden and locked targets fail closed', () {
      for (final root in [
        phase3Notebook(first: testObject(visible: false)),
        phase3Notebook(first: testObject(locked: true)),
        phase3Notebook(layerVisible: false),
        phase3Notebook(layerLocked: true),
      ]) {
        final coordinator = phase3Coordinator(root: root);
        final snapshot = coordinator.snapshot;
        final target =
            snapshot.root.pages.single.layers.single.objects.first.id;
        expect(
          coordinator.execute(replacementRequest(snapshot, target, 'bad')),
          isA<Err<CommandCommit, CommandFailure>>(),
        );
        expect(coordinator.snapshot.root, snapshot.root);
      }
    });

    test(
      'observer snapshot behavior, exceptions, and reentrancy are contained',
      () {
        final coordinator = phase3Coordinator();
        final initial = coordinator.snapshot;
        final target = initial.root.pages.single.layers.single.objects.first.id;
        final calls = <String>[];
        late CommittedChangeListener second;
        second = (_) => calls.add('second');
        coordinator.addListener((_) {
          calls.add('first');
          coordinator.addListener(second);
          final reentrant = coordinator.execute(
            replacementRequest(coordinator.snapshot, target, 'reentrant'),
          );
          expect(
            (reentrant as Err).error.toString(),
            contains('reentrant_mutation'),
          );
          throw StateError('private observer exception');
        });
        final first =
            coordinator.execute(replacementRequest(initial, target, 'one'))
                as Ok<CommandCommit, CommandFailure>;
        expect(first.value.observerFailureCount, 1);
        expect(calls, ['first']);
        final current = coordinator.snapshot;
        coordinator.execute(replacementRequest(current, target, 'two'));
        expect(calls, ['first', 'first', 'second']);
      },
    );

    test('Undo and Redo restore roots and content identities exactly', () {
      final coordinator = phase3Coordinator();
      final initial = coordinator.snapshot;
      final target = initial.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(initial, target, 'changed'));
      final edited = coordinator.snapshot;
      expect(edited.isDirty, isTrue);
      expect(coordinator.undo(), isA<Ok<CommandCommit, CommandFailure>>());
      expect(coordinator.snapshot.root, initial.root);
      expect(
        coordinator.snapshot.currentContentIdentity,
        initial.currentContentIdentity,
      );
      expect(coordinator.snapshot.isDirty, isFalse);
      expect(coordinator.redo(), isA<Ok<CommandCommit, CommandFailure>>());
      expect(coordinator.snapshot.root, edited.root);
      expect(
        coordinator.snapshot.currentContentIdentity,
        edited.currentContentIdentity,
      );
      expect(coordinator.snapshot.revisions.document.value, 3);
    });

    test('new command after Undo discards Redo tail', () {
      final coordinator = phase3Coordinator();
      var snapshot = coordinator.snapshot;
      final objects = snapshot.root.pages.single.layers.single.objects;
      coordinator.execute(
        replacementRequest(snapshot, objects.first.id, 'one'),
      );
      snapshot = coordinator.snapshot;
      coordinator.execute(replacementRequest(snapshot, objects.last.id, 'two'));
      coordinator.undo();
      snapshot = coordinator.snapshot;
      coordinator.execute(
        replacementRequest(snapshot, objects.last.id, 'branch'),
      );
      expect(coordinator.snapshot.canRedo, isFalse);
      expect(coordinator.retainedHistoryCount, 2);
    });

    test('save capture acknowledgement handles editing during save', () {
      final coordinator = phase3Coordinator();
      final initialCapture = coordinator.captureForSave();
      coordinator.acknowledgeSave(initialCapture);
      expect(coordinator.snapshot.isDirty, isFalse);
      final initial = coordinator.snapshot;
      final target = initial.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(initial, target, 'one'));
      final inFlight = coordinator.captureForSave();
      final next = coordinator.snapshot;
      coordinator.execute(replacementRequest(next, target, 'two'));
      coordinator.acknowledgeSave(inFlight);
      expect(coordinator.snapshot.isDirty, isTrue);
      final savedBeforeFailure = coordinator.snapshot.savedContentIdentity;
      coordinator.acknowledgeSaveFailure(coordinator.captureForSave());
      expect(coordinator.snapshot.savedContentIdentity, savedBeforeFailure);
    });

    test(
      'explicit semantic coalescing succeeds and boundary separates entries',
      () {
        final coordinator = phase3Coordinator();
        final coalescing = CommandCoalescing(
          mergeKey: commandValue(
            CoalescingMergeKey.parse('alnote.merge.typing'),
          ),
          sessionId: CoalescingSessionId.fromUuid(testUuid(300)),
          logicalTarget: LogicalCoalescingTarget.object(
            ObjectId.fromUuid(testUuid(1)),
          ),
        );
        var snapshot = coordinator.snapshot;
        final originalIdentity = snapshot.currentContentIdentity;
        final target =
            snapshot.root.pages.single.layers.single.objects.first.id;
        coordinator.execute(
          replacementRequest(
            snapshot,
            target,
            'a',
            metadata: phase3Metadata(coalescing: coalescing),
          ),
        );
        snapshot = coordinator.snapshot;
        coordinator.execute(
          replacementRequest(
            snapshot,
            target,
            'ab',
            metadata: phase3Metadata(coalescing: coalescing),
          ),
        );
        final latestCoalescedIdentity =
            coordinator.snapshot.currentContentIdentity;
        expect(coordinator.retainedHistoryCount, 1);
        coordinator.undo();
        expect(coordinator.snapshot.root, phase3Notebook());
        expect(coordinator.snapshot.currentContentIdentity, originalIdentity);
        coordinator.redo();
        expect(
          coordinator.snapshot.currentContentIdentity,
          latestCoalescedIdentity,
        );
        coordinator.establishCoalescingBoundary(CoalescingBoundary.focusChange);
        snapshot = coordinator.snapshot;
        coordinator.execute(
          replacementRequest(
            snapshot,
            target,
            'abc',
            metadata: phase3Metadata(coalescing: coalescing),
          ),
        );
        expect(coordinator.retainedHistoryCount, 2);
      },
    );

    test(
      'oversized entry rejects before publication and oldest entries evict',
      () {
        final oversized = phase3Coordinator(
          historyBytes: 50,
          estimatedEntryBytes: 51,
        );
        final first = oversized.snapshot;
        final target = first.root.pages.single.layers.single.objects.first.id;
        expect(
          oversized.execute(replacementRequest(first, target, 'bad')),
          isA<Err<CommandCommit, CommandFailure>>(),
        );
        expect(oversized.snapshot.root, first.root);

        final bounded = phase3Coordinator(historyCount: 2);
        var snapshot = bounded.snapshot;
        final boundedTarget =
            snapshot.root.pages.single.layers.single.objects.first.id;
        for (final payload in ['a', 'b', 'c']) {
          bounded.execute(replacementRequest(snapshot, boundedTarget, payload));
          snapshot = bounded.snapshot;
        }
        expect(bounded.retainedHistoryCount, 2);
        expect(bounded.undo(), isA<Ok<CommandCommit, CommandFailure>>());
        expect(bounded.undo(), isA<Ok<CommandCommit, CommandFailure>>());
        expect(bounded.undo(), isA<Err<CommandCommit, CommandFailure>>());
      },
    );

    test('retained descriptions use exact checked UTF-8 history cost', () {
      void expectRejected({
        required int estimatorBytes,
        required int limit,
        required String description,
        required String code,
      }) {
        final coordinator = customCoordinator(
          uuidGenerator: UuidSequenceGenerator.fromValues([
            testUuid(100),
            testUuid(101),
          ]),
          estimator: FixedHistoryCostEstimator(estimatorBytes),
          historyBytes: limit,
        );
        final before = coordinator.snapshot;
        final target = before.root.pages.single.layers.single.objects.first.id;
        final result = coordinator.execute(
          replacementRequest(
            before,
            target,
            'changed',
            metadata: phase3Metadata(description: description),
          ),
        );
        final failure = (result as Err<CommandCommit, CommandFailure>).error;
        expect(failure.code, code);
        expect(failure.toString(), isNot(contains(description)));
        expectPersistentStateUnchanged(coordinator, before, 0);
      }

      expectRejected(
        estimatorBytes: 0,
        limit: 3,
        description: 'four',
        code: 'documents.commands.history_limit_exceeded',
      );
      expectRejected(
        estimatorBytes: 0,
        limit: 3,
        description: 'éé',
        code: 'documents.commands.history_limit_exceeded',
      );
      expectRejected(
        estimatorBytes: 3,
        limit: 4,
        description: 'é',
        code: 'documents.commands.history_limit_exceeded',
      );
      expectRejected(
        estimatorBytes: Revision.maximumValue,
        limit: Revision.maximumValue,
        description: 'x',
        code: 'documents.commands.history_cost_overflow',
      );

      final exact = customCoordinator(
        uuidGenerator: UuidSequenceGenerator.fromValues([
          testUuid(100),
          testUuid(101),
        ]),
        estimator: FixedHistoryCostEstimator(3),
        historyBytes: 5,
      );
      final exactBefore = exact.snapshot;
      final exactTarget =
          exactBefore.root.pages.single.layers.single.objects.first.id;
      expect(
        exact.execute(
          replacementRequest(
            exactBefore,
            exactTarget,
            'changed',
            metadata: phase3Metadata(description: 'é'),
          ),
        ),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      expect(exact.estimatedRetainedHistoryBytes, 5);
    });

    test('coalescing retains only the latest description cost', () {
      final coordinator = phase3Coordinator(
        historyBytes: 4,
        estimatedEntryBytes: 0,
      );
      final target =
          coordinator.snapshot.root.pages.single.layers.single.objects.first.id;
      final coalescing = CommandCoalescing(
        mergeKey: commandValue(
          CoalescingMergeKey.parse('alnote.merge.description'),
        ),
        sessionId: CoalescingSessionId.fromUuid(testUuid(390)),
        logicalTarget: LogicalCoalescingTarget.object(target),
      );
      for (final edit in [('one', 'a'), ('two', '🙂')]) {
        final before = coordinator.snapshot;
        expect(
          coordinator.execute(
            replacementRequest(
              before,
              target,
              edit.$1,
              metadata: phase3Metadata(
                description: edit.$2,
                coalescing: coalescing,
              ),
            ),
          ),
          isA<Ok<CommandCommit, CommandFailure>>(),
        );
      }
      expect(coordinator.retainedHistoryCount, 1);
      expect(coordinator.estimatedRetainedHistoryBytes, 4);
    });

    test('history baseline reset disables prior Undo', () {
      final coordinator = phase3Coordinator();
      final initial = coordinator.snapshot;
      final target = initial.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(initial, target, 'one'));
      expect(coordinator.snapshot.canUndo, isTrue);
      expect(
        coordinator.resetHistoryBaseline(),
        isA<Ok<void, CommandFailure>>(),
      );
      expect(coordinator.retainedHistoryCount, 0);
      expect(coordinator.snapshot.canUndo, isFalse);
      expect(coordinator.snapshot.canRedo, isFalse);
    });

    test('every required explicit boundary prevents coalescing', () {
      for (final boundary in CoalescingBoundary.values) {
        final coordinator = phase3Coordinator();
        final coalescing = CommandCoalescing(
          mergeKey: commandValue(CoalescingMergeKey.parse('alnote.merge.edit')),
          sessionId: CoalescingSessionId.fromUuid(testUuid(301)),
          logicalTarget: LogicalCoalescingTarget.object(
            ObjectId.fromUuid(testUuid(1)),
          ),
        );
        var snapshot = coordinator.snapshot;
        final target =
            snapshot.root.pages.single.layers.single.objects.first.id;
        coordinator.execute(
          replacementRequest(
            snapshot,
            target,
            'one',
            metadata: phase3Metadata(coalescing: coalescing),
          ),
        );
        coordinator.establishCoalescingBoundary(boundary);
        snapshot = coordinator.snapshot;
        coordinator.execute(
          replacementRequest(
            snapshot,
            target,
            'two',
            metadata: phase3Metadata(coalescing: coalescing),
          ),
        );
        expect(coordinator.retainedHistoryCount, 2, reason: '$boundary');
      }
    });

    test('every observer is attempted after one throws', () {
      final coordinator = phase3Coordinator();
      final calls = <int>[];
      coordinator
        ..addListener((_) {
          calls.add(1);
          throw StateError('not exposed');
        })
        ..addListener((_) => calls.add(2));
      final snapshot = coordinator.snapshot;
      final target = snapshot.root.pages.single.layers.single.objects.first.id;
      final result =
          coordinator.execute(replacementRequest(snapshot, target, 'x'))
              as Ok<CommandCommit, CommandFailure>;
      expect(calls, [1, 2]);
      expect(result.value.observerFailureCount, 1);
    });

    test('different Objects cannot share one coalescing Undo unit', () {
      final coordinator = phase3Coordinator();
      final initial = coordinator.snapshot;
      final objects = initial.root.pages.single.layers.single.objects;
      final coalescingA = CommandCoalescing(
        mergeKey: commandValue(CoalescingMergeKey.parse('alnote.merge.edit')),
        sessionId: CoalescingSessionId.fromUuid(testUuid(350)),
        logicalTarget: LogicalCoalescingTarget.object(objects.first.id),
      );
      coordinator.execute(
        replacementRequest(
          initial,
          objects.first.id,
          'a',
          metadata: phase3Metadata(coalescing: coalescingA),
        ),
      );
      final afterA = coordinator.snapshot;
      final bWithSpoofedTarget = AtomicObjectReplacementRequest.create(
        documentId: afterA.root.id,
        metadata: phase3Metadata(coalescing: coalescingA),
        preconditions: objectPreconditions(afterA, objects.last.id),
        targetIds: [objects.last.id],
        replacements: [
          replacementObject(
            afterA.root.pages.single.layers.single.objects.last,
            'b',
          ),
        ],
        changeCategories: _appearanceChange,
      );
      expect(
        bWithSpoofedTarget,
        isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );
      expectPersistentStateUnchanged(coordinator, afterA, 1);

      final coalescingB = CommandCoalescing(
        mergeKey: coalescingA.mergeKey,
        sessionId: coalescingA.sessionId,
        logicalTarget: LogicalCoalescingTarget.object(objects.last.id),
      );
      coordinator.execute(
        replacementRequest(
          afterA,
          objects.last.id,
          'b',
          metadata: phase3Metadata(coalescing: coalescingB),
        ),
      );
      expect(coordinator.retainedHistoryCount, 2);
      coordinator.undo();
      expect(
        coordinator
            .snapshot
            .root
            .pages
            .single
            .layers
            .single
            .objects
            .first
            .payload,
        const PreservedString('a'),
      );
    });

    test('content identity collisions never publish or appear clean', () {
      final generator = UuidSequenceGenerator.fromValues([
        testUuid(100),
        testUuid(100),
      ]);
      final coordinator = customCoordinator(
        uuidGenerator: generator,
        estimator: FixedHistoryCostEstimator(1),
      );
      final before = coordinator.snapshot;
      var notifications = 0;
      coordinator.addListener((_) => notifications += 1);
      final target = before.root.pages.single.layers.single.objects.first.id;
      final result = coordinator.execute(
        replacementRequest(before, target, 'changed'),
      );
      expect(
        (result as Err<CommandCommit, CommandFailure>).error.code,
        'documents.commands.content_identity_collision',
      );
      expectPersistentStateUnchanged(coordinator, before, 0);
      expect(coordinator.snapshot.isDirty, isFalse);
      expect(notifications, 0);
    });

    test('issued identities remain reserved after history eviction', () {
      final coordinator = customCoordinator(
        uuidGenerator: UuidSequenceGenerator.fromValues([
          testUuid(100),
          testUuid(101),
          testUuid(102),
          testUuid(101),
        ]),
        estimator: FixedHistoryCostEstimator(1),
        historyCount: 1,
      );
      var snapshot = coordinator.snapshot;
      final target = snapshot.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(snapshot, target, 'one'));
      snapshot = coordinator.snapshot;
      coordinator.execute(replacementRequest(snapshot, target, 'two'));
      final beforeCollision = coordinator.snapshot;
      expect(coordinator.retainedHistoryCount, 1);
      final result = coordinator.execute(
        replacementRequest(beforeCollision, target, 'three'),
      );
      expect(
        (result as Err<CommandCommit, CommandFailure>).error.code,
        'documents.commands.content_identity_collision',
      );
      expectPersistentStateUnchanged(coordinator, beforeCollision, 1);
    });

    test('identity and zero-effect commands have no side effects', () {
      final generator = UuidSequenceGenerator.fromValues([
        testUuid(100),
        testUuid(101),
        testUuid(102),
        testUuid(103),
      ]);
      final estimator = _CountingEstimator(1);
      final coordinator = customCoordinator(
        uuidGenerator: generator,
        estimator: estimator,
      );
      final initial = coordinator.snapshot;
      var notifications = 0;
      coordinator.addListener((_) => notifications += 1);
      final target = initial.root.pages.single.layers.single.objects.first.id;
      expect(
        AtomicWholeObjectTransformRequest.create(
          documentId: initial.root.id,
          metadata: phase3Metadata(family: 'alnote.commands.object.transform'),
          preconditions: objectPreconditions(initial, target),
          pageId: initial.root.pages.single.id,
          targetIds: [target],
          operation: const IdentityTransformOperation2D(),
        ),
        isA<Err<AtomicWholeObjectTransformRequest, StructuredFailure>>(),
      );
      for (final operation in <TransformOperation2D>[
        TranslationTransformOperation2D(modelValue(Vector2.create(x: 0, y: 0))),
        modelValue(
          RotationTransformOperation2D.create(
            radians: 0,
            pivot: modelValue(Point2.create(x: 5, y: 5)),
          ),
        ),
        modelValue(
          ScaleTransformOperation2D.create(
            scaleX: 1,
            scaleY: 1,
            pivot: modelValue(Point2.create(x: 5, y: 5)),
          ),
        ),
      ]) {
        final result = coordinator.execute(
          transformRequest(initial, operation),
        );
        expect(
          (result as Err<CommandCommit, CommandFailure>).error.code,
          'documents.commands.no_change',
        );
        expectPersistentStateUnchanged(coordinator, initial, 0);
      }
      final equalReplacement = coordinator.execute(
        commandValue(
          AtomicObjectReplacementRequest.create(
            documentId: initial.root.id,
            metadata: phase3Metadata(),
            preconditions: objectPreconditions(initial, target),
            targetIds: [target],
            replacements: [
              initial.root.pages.single.layers.single.objects.first,
            ],
            changeCategories: _appearanceChange,
          ),
        ),
      );
      expect(
        (equalReplacement as Err<CommandCommit, CommandFailure>).error.code,
        'documents.commands.no_change',
      );
      expectPersistentStateUnchanged(coordinator, initial, 0);
      expect(generator.remaining, 3);
      expect(estimator.calls, 0);
      expect(notifications, 0);
    });

    test('interactive replacement preserves every common envelope field', () {
      final coordinator = phase3Coordinator();
      final initial = coordinator.snapshot;
      final source = initial.root.pages.single.layers.single.objects.first;
      final two = modelValue(SchemaVersion.create(2));
      final translated = modelValue(
        source.transform.then(
          modelValue(
            AffineTransform2D.fromOperation(
              TranslationTransformOperation2D(
                modelValue(Vector2.create(x: 1, y: 0)),
              ),
            ),
          ),
        ),
      );
      final changed = <ObjectEnvelope>[
        _copyObject(source, typeKey: testObjectTypeKey('example.other.object')),
        _copyObject(source, envelopeVersion: two),
        _copyObject(source, typeSchemaVersion: two),
        _copyObject(source, transform: translated),
        _copyObject(source, visible: false),
        _copyObject(source, locked: true),
        _copyObject(
          source,
          extensionData: PreservedMap({
            'changed': const PreservedBoolean(true),
          }),
        ),
      ];
      for (final replacement in changed) {
        final result = coordinator.execute(
          commandValue(
            AtomicObjectReplacementRequest.create(
              documentId: initial.root.id,
              metadata: phase3Metadata(),
              preconditions: objectPreconditions(initial, source.id),
              targetIds: [source.id],
              replacements: [replacement],
              changeCategories: _appearanceChange,
            ),
          ),
        );
        expect(result, isA<Err<CommandCommit, CommandFailure>>());
        expectPersistentStateUnchanged(coordinator, initial, 0);
      }
    });

    test('resource eligibility and committed flags are authoritative', () {
      final resource = ResourceIdentity.fromUuid(testUuid(700));
      final registry = testRegistry([_PayloadAwareDefinition(resource)]);
      final catalog = modelValue(
        ResourceCatalog.create([ResourceCatalogEntry(resource)]),
      );
      final root = phase3Notebook(resources: catalog);
      final coordinator = phase3Coordinator(root: root, registry: registry);
      final before = coordinator.snapshot;
      final target = before.root.pages.single.layers.single.objects.first.id;
      final source = before.root.pages.single.layers.single.objects.first;
      final request = commandValue(
        AtomicObjectReplacementRequest.create(
          documentId: before.root.id,
          metadata: phase3Metadata(),
          preconditions: objectPreconditions(before, target),
          targetIds: [target],
          replacements: [replacementObject(source, 'needs-resource')],
          changeCategories: const ObjectReplacementChangeCategories(
            appearance: false,
            text: true,
            metadata: true,
          ),
        ),
      );
      final commit =
          coordinator.execute(request) as Ok<CommandCommit, CommandFailure>;
      expect(commit.value.change.flags.geometry, isFalse);
      expect(commit.value.change.flags.appearance, isFalse);
      expect(commit.value.change.flags.text, isTrue);
      expect(commit.value.change.flags.metadata, isTrue);
      expect(commit.value.change.flags.resources, isTrue);
      expect(commit.value.change.addedResourceReferences, [resource]);

      final missingRoot = phase3Notebook();
      final missingCoordinator = phase3Coordinator(
        root: missingRoot,
        registry: registry,
      );
      final missingBefore = missingCoordinator.snapshot;
      final missingSource =
          missingBefore.root.pages.single.layers.single.objects.first;
      final missingResult = missingCoordinator.execute(
        commandValue(
          AtomicObjectReplacementRequest.create(
            documentId: missingBefore.root.id,
            metadata: phase3Metadata(),
            preconditions: objectPreconditions(missingBefore, missingSource.id),
            targetIds: [missingSource.id],
            replacements: [replacementObject(missingSource, 'needs-resource')],
            changeCategories: _appearanceChange,
          ),
        ),
      );
      expect(
        (missingResult as Err<CommandCommit, CommandFailure>).error.code,
        'documents.commands.missing_resource',
      );
      expectPersistentStateUnchanged(missingCoordinator, missingBefore, 0);

      final geometryBefore = coordinator.snapshot;
      final geometrySource =
          geometryBefore.root.pages.single.layers.single.objects.first;
      final geometryCommit =
          coordinator.execute(
                commandValue(
                  AtomicObjectReplacementRequest.create(
                    documentId: geometryBefore.root.id,
                    metadata: phase3Metadata(),
                    preconditions: objectPreconditions(
                      geometryBefore,
                      geometrySource.id,
                    ),
                    targetIds: [geometrySource.id],
                    replacements: [replacementObject(geometrySource, 'large')],
                    changeCategories: const ObjectReplacementChangeCategories(
                      appearance: false,
                      text: false,
                      metadata: false,
                    ),
                  ),
                ),
              )
              as Ok<CommandCommit, CommandFailure>;
      expect(geometryCommit.value.change.flags.geometry, isTrue);
      expect(geometryCommit.value.change.flags.appearance, isFalse);
    });

    test('per-Object geometry detects unchanged aggregate bounds', () {
      final registry = testRegistry([_VariableGeometryDefinition()]);
      final coordinator = phase3Coordinator(
        root: phase3Notebook(
          first: testObject(payload: const PreservedString('small')),
          second: testObject(id: 2, payload: const PreservedString('large')),
        ),
        registry: registry,
      );
      final before = coordinator.snapshot;
      final layer = before.root.pages.single.layers.single;
      final first = layer.objects.first;
      final second = layer.objects.last;
      final result = coordinator.execute(
        commandValue(
          AtomicObjectReplacementRequest.create(
            documentId: before.root.id,
            metadata: phase3Metadata(),
            preconditions: RevisionPreconditions(
              layerMembership: {
                layer.id: before.revisions.layerMembership[layer.id]!,
              },
              objects: {
                first.id: before.revisions.objects[first.id]!,
                second.id: before.revisions.objects[second.id]!,
              },
            ),
            targetIds: [first.id, second.id],
            replacements: [
              replacementObject(first, 'large'),
              replacementObject(second, 'small'),
            ],
            changeCategories: _noDeclaredChange,
          ),
        ),
      );
      final change = (result as Ok<CommandCommit, CommandFailure>).value.change;
      expect(change.oldBounds, change.newBounds);
      expect(change.flags.geometry, isTrue);
      expect(change.movedObjectIds, [first.id, second.id]);
      expect(change.movedObjectIds.clear, throwsUnsupportedError);
    });

    test('coalescing derives forward and reversed net per-Object geometry', () {
      for (final scenario in <(String, bool)>[
        ('small', false),
        ('large', true),
      ]) {
        final registry = testRegistry([_VariableGeometryDefinition()]);
        final coordinator = phase3Coordinator(
          root: phase3Notebook(
            first: testObject(payload: const PreservedString('small')),
          ),
          registry: registry,
        );
        final target = coordinator
            .snapshot
            .root
            .pages
            .single
            .layers
            .single
            .objects
            .first
            .id;
        final coalescing = CommandCoalescing(
          mergeKey: commandValue(
            CoalescingMergeKey.parse('alnote.merge.geometry'),
          ),
          sessionId: CoalescingSessionId.fromUuid(
            testUuid(scenario.$2 ? 392 : 391),
          ),
          logicalTarget: LogicalCoalescingTarget.object(target),
        );
        for (final payload in ['medium', scenario.$1]) {
          final editBefore = coordinator.snapshot;
          final source =
              editBefore.root.pages.single.layers.single.objects.first;
          expect(
            coordinator.execute(
              commandValue(
                AtomicObjectReplacementRequest.create(
                  documentId: editBefore.root.id,
                  metadata: phase3Metadata(coalescing: coalescing),
                  preconditions: objectPreconditions(editBefore, target),
                  targetIds: [target],
                  replacements: [replacementObject(source, payload)],
                  changeCategories: _noDeclaredChange,
                ),
              ),
            ),
            isA<Ok<CommandCommit, CommandFailure>>(),
          );
        }
        expect(coordinator.retainedHistoryCount, 1);
        final undo = coordinator.undo() as Ok<CommandCommit, CommandFailure>;
        final redo = coordinator.redo() as Ok<CommandCommit, CommandFailure>;
        for (final change in [undo.value.change, redo.value.change]) {
          expect(change.flags.geometry, scenario.$2);
          expect(change.movedObjectIds, scenario.$2 ? [target] : isEmpty);
        }
        if (scenario.$2) {
          expect(undo.value.change.oldBounds!.right, 30);
          expect(undo.value.change.newBounds!.right, 10);
          expect(redo.value.change.oldBounds!.right, 10);
          expect(redo.value.change.newBounds!.right, 30);
        } else {
          expect(undo.value.change.oldBounds, undo.value.change.newBounds);
          expect(redo.value.change.oldBounds, redo.value.change.newBounds);
        }
      }
    });

    test('Registry geometry failure is atomic and redaction-safe', () {
      final coordinator = phase3Coordinator(
        root: phase3Notebook(
          first: testObject(payload: const PreservedString('small')),
        ),
        registry: testRegistry([_VariableGeometryDefinition()]),
      );
      final before = coordinator.snapshot;
      final source = before.root.pages.single.layers.single.objects.first;
      var notifications = 0;
      coordinator.addListener((_) => notifications += 1);
      final result = coordinator.execute(
        commandValue(
          AtomicObjectReplacementRequest.create(
            documentId: before.root.id,
            metadata: phase3Metadata(description: 'sensitive geometry edit'),
            preconditions: objectPreconditions(before, source.id),
            targetIds: [source.id],
            replacements: [
              replacementObject(source, 'secret-geometry-failure'),
            ],
            changeCategories: _noDeclaredChange,
          ),
        ),
      );
      final failure = (result as Err<CommandCommit, CommandFailure>).error;
      expect(failure.code, 'documents.commands.invalid_replacement');
      expect(failure.toString(), isNot(contains('secret')));
      expect(failure.toString(), isNot(contains('sensitive')));
      expectPersistentStateUnchanged(coordinator, before, 0);
      expect(notifications, 0);
    });

    test(
      'unclassified payload changes reject while derived-only changes commit',
      () {
        final resource = ResourceIdentity.fromUuid(testUuid(702));
        final registry = testRegistry([_PayloadAwareDefinition(resource)]);
        final catalog = modelValue(
          ResourceCatalog.create([ResourceCatalogEntry(resource)]),
        );
        final generator = UuidSequenceGenerator.fromValues([
          testUuid(100),
          testUuid(101),
        ]);
        final estimator = _CountingEstimator(1);
        final rejected = customCoordinator(
          root: phase3Notebook(resources: catalog),
          registry: registry,
          uuidGenerator: generator,
          estimator: estimator,
        );
        final before = rejected.snapshot;
        final source = before.root.pages.single.layers.single.objects.first;
        var notifications = 0;
        rejected.addListener((_) => notifications += 1);
        final result = rejected.execute(
          commandValue(
            AtomicObjectReplacementRequest.create(
              documentId: before.root.id,
              metadata: phase3Metadata(),
              preconditions: objectPreconditions(before, source.id),
              targetIds: [source.id],
              replacements: [replacementObject(source, 'unclassified')],
              changeCategories: _noDeclaredChange,
            ),
          ),
        );
        expect(
          (result as Err<CommandCommit, CommandFailure>).error.code,
          'documents.commands.unclassified_payload_change',
        );
        expectPersistentStateUnchanged(rejected, before, 0);
        expect(generator.remaining, 1);
        expect(estimator.calls, 0);
        expect(notifications, 0);

        final geometryOnly = phase3Coordinator(
          root: phase3Notebook(resources: catalog),
          registry: registry,
        );
        final geometryBefore = geometryOnly.snapshot;
        final geometrySource =
            geometryBefore.root.pages.single.layers.single.objects.first;
        final geometryCommit =
            geometryOnly.execute(
                  commandValue(
                    AtomicObjectReplacementRequest.create(
                      documentId: geometryBefore.root.id,
                      metadata: phase3Metadata(),
                      preconditions: objectPreconditions(
                        geometryBefore,
                        geometrySource.id,
                      ),
                      targetIds: [geometrySource.id],
                      replacements: [
                        replacementObject(geometrySource, 'large'),
                      ],
                      changeCategories: _noDeclaredChange,
                    ),
                  ),
                )
                as Ok<CommandCommit, CommandFailure>;
        expect(geometryCommit.value.change.flags.geometry, isTrue);
        expect(geometryCommit.value.change.flags.resources, isFalse);

        final resourceOnly = phase3Coordinator(
          root: phase3Notebook(resources: catalog),
          registry: registry,
        );
        final resourceBefore = resourceOnly.snapshot;
        final resourceSource =
            resourceBefore.root.pages.single.layers.single.objects.first;
        final resourceCommit =
            resourceOnly.execute(
                  commandValue(
                    AtomicObjectReplacementRequest.create(
                      documentId: resourceBefore.root.id,
                      metadata: phase3Metadata(),
                      preconditions: objectPreconditions(
                        resourceBefore,
                        resourceSource.id,
                      ),
                      targetIds: [resourceSource.id],
                      replacements: [
                        replacementObject(resourceSource, 'needs-resource'),
                      ],
                      changeCategories: _noDeclaredChange,
                    ),
                  ),
                )
                as Ok<CommandCommit, CommandFailure>;
        expect(resourceCommit.value.change.flags.geometry, isFalse);
        expect(resourceCommit.value.change.flags.resources, isTrue);
        expect(resourceCommit.value.change.addedResourceReferences, [resource]);
      },
    );

    test('coalescing reports only net resource-reference changes', () {
      final resource = ResourceIdentity.fromUuid(testUuid(703));
      final registry = testRegistry([_PayloadAwareDefinition(resource)]);
      final catalog = modelValue(
        ResourceCatalog.create([ResourceCatalogEntry(resource)]),
      );
      for (final scenario in <(String, String, String)>[
        ('payload', 'needs-resource', 'plain-after-add'),
        ('needs-resource', 'plain-after-remove', 'needs-resource-restored'),
      ]) {
        final coordinator = phase3Coordinator(
          root: phase3Notebook(
            resources: catalog,
            first: testObject(payload: PreservedString(scenario.$1)),
          ),
          registry: registry,
        );
        final target = coordinator
            .snapshot
            .root
            .pages
            .single
            .layers
            .single
            .objects
            .first
            .id;
        final coalescing = CommandCoalescing(
          mergeKey: commandValue(
            CoalescingMergeKey.parse('alnote.merge.resource'),
          ),
          sessionId: CoalescingSessionId.fromUuid(testUuid(360)),
          logicalTarget: LogicalCoalescingTarget.object(target),
        );
        for (final payload in [scenario.$2, scenario.$3]) {
          final snapshot = coordinator.snapshot;
          final source = snapshot.root.pages.single.layers.single.objects.first;
          expect(
            coordinator.execute(
              commandValue(
                AtomicObjectReplacementRequest.create(
                  documentId: snapshot.root.id,
                  metadata: phase3Metadata(coalescing: coalescing),
                  preconditions: objectPreconditions(snapshot, target),
                  targetIds: [target],
                  replacements: [replacementObject(source, payload)],
                  changeCategories: _noDeclaredChange,
                ),
              ),
            ),
            isA<Ok<CommandCommit, CommandFailure>>(),
          );
        }
        expect(coordinator.retainedHistoryCount, 1);
        final undo = coordinator.undo() as Ok<CommandCommit, CommandFailure>;
        expect(undo.value.change.addedResourceReferences, isEmpty);
        expect(undo.value.change.removedResourceReferences, isEmpty);
        expect(undo.value.change.flags.resources, isFalse);
        final redo = coordinator.redo() as Ok<CommandCommit, CommandFailure>;
        expect(redo.value.change.addedResourceReferences, isEmpty);
        expect(redo.value.change.removedResourceReferences, isEmpty);
        expect(redo.value.change.flags.resources, isFalse);
      }
    });

    test('Undo and Redo reverse a coalesced net resource addition', () {
      final resource = ResourceIdentity.fromUuid(testUuid(704));
      final registry = testRegistry([_PayloadAwareDefinition(resource)]);
      final catalog = modelValue(
        ResourceCatalog.create([ResourceCatalogEntry(resource)]),
      );
      final coordinator = phase3Coordinator(
        root: phase3Notebook(resources: catalog),
        registry: registry,
      );
      final target =
          coordinator.snapshot.root.pages.single.layers.single.objects.first.id;
      final coalescing = CommandCoalescing(
        mergeKey: commandValue(
          CoalescingMergeKey.parse('alnote.merge.resource'),
        ),
        sessionId: CoalescingSessionId.fromUuid(testUuid(361)),
        logicalTarget: LogicalCoalescingTarget.object(target),
      );
      for (final edit in <(String, ObjectReplacementChangeCategories)>[
        ('needs-resource', _noDeclaredChange),
        (
          'needs-resource-updated',
          const ObjectReplacementChangeCategories(
            appearance: false,
            text: true,
            metadata: false,
          ),
        ),
      ]) {
        final snapshot = coordinator.snapshot;
        final source = snapshot.root.pages.single.layers.single.objects.first;
        coordinator.execute(
          commandValue(
            AtomicObjectReplacementRequest.create(
              documentId: snapshot.root.id,
              metadata: phase3Metadata(coalescing: coalescing),
              preconditions: objectPreconditions(snapshot, target),
              targetIds: [target],
              replacements: [replacementObject(source, edit.$1)],
              changeCategories: edit.$2,
            ),
          ),
        );
      }
      final undo = coordinator.undo() as Ok<CommandCommit, CommandFailure>;
      expect(undo.value.change.addedResourceReferences, isEmpty);
      expect(undo.value.change.removedResourceReferences, [resource]);
      expect(undo.value.change.flags.resources, isTrue);
      final redo = coordinator.redo() as Ok<CommandCommit, CommandFailure>;
      expect(redo.value.change.addedResourceReferences, [resource]);
      expect(redo.value.change.removedResourceReferences, isEmpty);
      expect(redo.value.change.flags.resources, isTrue);
    });

    test(
      'existing missing resources and Registry failures are not editable',
      () {
        final resource = ResourceIdentity.fromUuid(testUuid(701));
        for (final definition in [
          _PayloadAwareDefinition(resource),
          TestObjectTypeDefinition(
            capabilities: const ObjectTypeCapabilities(
              hasIntrinsicGeometry: true,
              discoversResourceReferences: false,
              supportsScopedDuplication: true,
              selectable: true,
            ),
            failGeometry: true,
          ),
          TestObjectTypeDefinition(
            capabilities: const ObjectTypeCapabilities(
              hasIntrinsicGeometry: true,
              discoversResourceReferences: true,
              supportsScopedDuplication: true,
              selectable: true,
            ),
            failResourceDiscovery: true,
          ),
        ]) {
          final root = definition is _PayloadAwareDefinition
              ? phase3Notebook(
                  first: testObject(
                    payload: const PreservedString('needs-resource'),
                  ),
                )
              : phase3Notebook();
          final registry = testRegistry([definition]);
          final coordinator = phase3Coordinator(root: root, registry: registry);
          final before = coordinator.snapshot;
          final target =
              before.root.pages.single.layers.single.objects.first.id;
          final result = coordinator.execute(
            replacementRequest(before, target, 'changed'),
          );
          expect(result, isA<Err<CommandCommit, CommandFailure>>());
          expectPersistentStateUnchanged(coordinator, before, 0);
        }
      },
    );

    test('estimator failures, limits, and sum overflow stay distinct', () {
      for (final estimator in <HistoryRetainedCostEstimator>[
        _FailingEstimator(),
        _ThrowingEstimator(),
      ]) {
        final coordinator = customCoordinator(
          uuidGenerator: UuidSequenceGenerator.fromValues([
            testUuid(100),
            testUuid(101),
          ]),
          estimator: estimator,
        );
        final before = coordinator.snapshot;
        final target = before.root.pages.single.layers.single.objects.first.id;
        final result =
            coordinator.execute(
                  replacementRequest(before, target, 'secret payload'),
                )
                as Err<CommandCommit, CommandFailure>;
        expect(
          result.error.code,
          'documents.commands.history_cost_estimation_failed',
        );
        expect(result.error.toString(), isNot(contains('secret')));
        expectPersistentStateUnchanged(coordinator, before, 0);
      }

      final limited = phase3Coordinator(
        historyBytes: 1,
        estimatedEntryBytes: 2,
      );
      final limitedBefore = limited.snapshot;
      final limitedTarget =
          limitedBefore.root.pages.single.layers.single.objects.first.id;
      final limitedResult =
          limited.execute(
                replacementRequest(limitedBefore, limitedTarget, 'changed'),
              )
              as Err<CommandCommit, CommandFailure>;
      expect(
        limitedResult.error.code,
        'documents.commands.history_limit_exceeded',
      );
      expectPersistentStateUnchanged(limited, limitedBefore, 0);

      final overflow = customCoordinator(
        uuidGenerator: UuidSequenceGenerator.fromValues([
          testUuid(100),
          testUuid(101),
          testUuid(102),
        ]),
        estimator: _SequenceEstimator([Revision.maximumValue - 1, 0]),
        historyBytes: Revision.maximumValue,
      );
      var overflowSnapshot = overflow.snapshot;
      final overflowTarget =
          overflowSnapshot.root.pages.single.layers.single.objects.first.id;
      overflow.execute(
        replacementRequest(
          overflowSnapshot,
          overflowTarget,
          'one',
          metadata: phase3Metadata(description: 'a'),
        ),
      );
      overflowSnapshot = overflow.snapshot;
      final overflowResult =
          overflow.execute(
                replacementRequest(
                  overflowSnapshot,
                  overflowTarget,
                  'two',
                  metadata: phase3Metadata(description: 'a'),
                ),
              )
              as Err<CommandCommit, CommandFailure>;
      expect(
        overflowResult.error.code,
        'documents.commands.history_cost_overflow',
      );
      expectPersistentStateUnchanged(overflow, overflowSnapshot, 1);
    });

    test('foreign save captures fail and valid acknowledgements are exact', () {
      final first = phase3Coordinator();
      final second = phase3Coordinator();
      final foreign = second.captureForSave();
      final before = first.snapshot;
      expect(first.acknowledgeSave(foreign), isA<Err<void, CommandFailure>>());
      expect(
        first.acknowledgeSaveFailure(foreign),
        isA<Err<void, CommandFailure>>(),
      );
      expectPersistentStateUnchanged(first, before, 0);

      final capture = first.captureForSave();
      final target = before.root.pages.single.layers.single.objects.first.id;
      first.execute(replacementRequest(before, target, 'later'));
      expect(first.acknowledgeSave(capture), isA<Ok<void, CommandFailure>>());
      expect(first.snapshot.savedContentIdentity, capture.contentIdentity);
      expect(first.snapshot.isDirty, isTrue);
      final saved = first.snapshot.savedContentIdentity;
      expect(
        first.acknowledgeSaveFailure(first.captureForSave()),
        isA<Ok<void, CommandFailure>>(),
      );
      expect(first.snapshot.savedContentIdentity, saved);
    });

    test('Undo and Redo advance scoped revisions monotonically', () {
      final coordinator = phase3Coordinator();
      final initial = coordinator.snapshot;
      final target = initial.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(initial, target, 'changed'));
      final edited = coordinator.snapshot;
      coordinator.undo();
      final undone = coordinator.snapshot;
      coordinator.redo();
      final redone = coordinator.snapshot;
      expect(
        [
          edited.revisions.document.value,
          undone.revisions.document.value,
          redone.revisions.document.value,
        ],
        [1, 2, 3],
      );
      expect(
        [
          edited.revisions.objects[target]!.value,
          undone.revisions.objects[target]!.value,
          redone.revisions.objects[target]!.value,
        ],
        [1, 2, 3],
      );
      expect(redone.revisions.pages.values.single.value, 0);
      expect(redone.revisions.layers.values.single.value, 0);
    });

    test('Redo uses stored roots without Registry or UUID callbacks', () {
      var geometryCalls = 0;
      final registry = testRegistry([
        TestObjectTypeDefinition(
          capabilities: const ObjectTypeCapabilities(
            hasIntrinsicGeometry: true,
            discoversResourceReferences: false,
            supportsScopedDuplication: true,
            selectable: true,
            movable: true,
            resizable: true,
            rotatable: true,
          ),
          onGeometry: () => geometryCalls += 1,
        ),
      ]);
      final generator = UuidSequenceGenerator.fromValues([
        testUuid(100),
        testUuid(101),
        testUuid(102),
      ]);
      final coordinator = customCoordinator(
        uuidGenerator: generator,
        estimator: FixedHistoryCostEstimator(1),
        registry: registry,
      );
      final initial = coordinator.snapshot;
      final target = initial.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(initial, target, 'changed'));
      coordinator.undo();
      final callsBeforeRedo = geometryCalls;
      final remainingBeforeRedo = generator.remaining;
      coordinator.redo();
      expect(geometryCalls, callsBeforeRedo);
      expect(generator.remaining, remainingBeforeRedo);
    });

    test('unknown opaque Objects survive commit, Undo, and Redo', () {
      final unknown = testObject(
        id: 2,
        typeKey: testObjectTypeKey('example.unknown.opaque'),
        payload: const PreservedString('opaque secret'),
      );
      final coordinator = phase3Coordinator(
        root: phase3Notebook(second: unknown),
      );
      final initial = coordinator.snapshot;
      final target = initial.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(initial, target, 'changed'));
      expect(
        coordinator.snapshot.root.pages.single.layers.single.objects.last,
        unknown,
      );
      coordinator.undo();
      expect(
        coordinator.snapshot.root.pages.single.layers.single.objects.last,
        unknown,
      );
      coordinator.redo();
      expect(
        coordinator.snapshot.root.pages.single.layers.single.objects.last,
        unknown,
      );
    });

    test('observer removals use notification snapshot semantics', () {
      final coordinator = phase3Coordinator();
      final calls = <String>[];
      late CommittedChangeListener second;
      second = (_) => calls.add('second');
      coordinator
        ..addListener((_) {
          calls.add('first');
          coordinator.removeListener(second);
        })
        ..addListener(second);
      var snapshot = coordinator.snapshot;
      final target = snapshot.root.pages.single.layers.single.objects.first.id;
      coordinator.execute(replacementRequest(snapshot, target, 'one'));
      snapshot = coordinator.snapshot;
      coordinator.execute(replacementRequest(snapshot, target, 'two'));
      expect(calls, ['first', 'second', 'first']);
    });

    test('move, resize, and rotate capabilities deny independently', () {
      final operations = <(ObjectTypeCapabilities, TransformOperation2D)>[
        (
          const ObjectTypeCapabilities(
            hasIntrinsicGeometry: true,
            discoversResourceReferences: false,
            supportsScopedDuplication: true,
            selectable: true,
            resizable: true,
            rotatable: true,
          ),
          TranslationTransformOperation2D(
            modelValue(Vector2.create(x: 1, y: 0)),
          ),
        ),
        (
          const ObjectTypeCapabilities(
            hasIntrinsicGeometry: true,
            discoversResourceReferences: false,
            supportsScopedDuplication: true,
            selectable: true,
            movable: true,
            rotatable: true,
          ),
          modelValue(
            ScaleTransformOperation2D.create(
              scaleX: 2,
              scaleY: 2,
              pivot: modelValue(Point2.create(x: 0, y: 0)),
            ),
          ),
        ),
        (
          const ObjectTypeCapabilities(
            hasIntrinsicGeometry: true,
            discoversResourceReferences: false,
            supportsScopedDuplication: true,
            selectable: true,
            movable: true,
            resizable: true,
          ),
          modelValue(
            RotationTransformOperation2D.create(
              radians: 0.25,
              pivot: modelValue(Point2.create(x: 0, y: 0)),
            ),
          ),
        ),
      ];
      for (final entry in operations) {
        final registry = testRegistry([
          TestObjectTypeDefinition(capabilities: entry.$1),
        ]);
        final coordinator = phase3Coordinator(registry: registry);
        final before = coordinator.snapshot;
        final result = coordinator.execute(transformRequest(before, entry.$2));
        expect(
          (result as Err<CommandCommit, CommandFailure>).error.code,
          'documents.commands.transform_capability_denied',
        );
        expectPersistentStateUnchanged(coordinator, before, 0);
      }
    });
  });
}

const _appearanceChange = ObjectReplacementChangeCategories(
  appearance: true,
  text: false,
  metadata: false,
);

const _noDeclaredChange = ObjectReplacementChangeCategories(
  appearance: false,
  text: false,
  metadata: false,
);

ObjectEnvelope _copyObject(
  ObjectEnvelope source, {
  ObjectTypeKey? typeKey,
  SchemaVersion? envelopeVersion,
  SchemaVersion? typeSchemaVersion,
  AffineTransform2D? transform,
  bool? visible,
  bool? locked,
  PreservedMap? extensionData,
}) => modelValue(
  ObjectEnvelope.create(
    id: source.id,
    typeKey: typeKey ?? source.typeKey,
    envelopeVersion: envelopeVersion ?? source.envelopeVersion,
    typeSchemaVersion: typeSchemaVersion ?? source.typeSchemaVersion,
    transform: transform ?? source.transform,
    visible: visible ?? source.visible,
    locked: locked ?? source.locked,
    payload: const PreservedString('replacement'),
    extensionData: extensionData ?? source.extensionData,
  ),
);

final class _CountingEstimator implements HistoryRetainedCostEstimator {
  _CountingEstimator(this.bytes);
  final int bytes;
  int calls = 0;

  @override
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  ) {
    calls += 1;
    return HistoryRetainedCost.create(bytes);
  }
}

final class _FailingEstimator implements HistoryRetainedCostEstimator {
  @override
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  ) => Err(
    StructuredFailure(
      code: 'secret.estimator.failure',
      category: FailureCategory.dependency,
      retryDisposition: RetryDisposition.never,
      message: 'secret estimator and payload details',
    ),
  );
}

final class _ThrowingEstimator implements HistoryRetainedCostEstimator {
  @override
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  ) => throw StateError('secret estimator exception');
}

final class _SequenceEstimator implements HistoryRetainedCostEstimator {
  _SequenceEstimator(this.values);
  final List<int> values;
  var _index = 0;

  @override
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  ) => HistoryRetainedCost.create(values[_index++]);
}

final class _PayloadAwareDefinition implements ObjectTypeDefinition {
  _PayloadAwareDefinition(this.resource);

  final ResourceIdentity resource;
  @override
  ObjectTypeKey get typeKey => testObjectTypeKey();
  @override
  List<SchemaVersion> get supportedSchemaVersions => [testSchemaVersion];
  @override
  ObjectTypeCapabilities get capabilities => const ObjectTypeCapabilities(
    hasIntrinsicGeometry: true,
    discoversResourceReferences: true,
    supportsScopedDuplication: true,
    selectable: true,
    movable: true,
    resizable: true,
    rotatable: true,
  );
  @override
  List<ObjectPayloadMigrationContract> get migrations => const [];

  @override
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => ValidationReport(const []);

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    final large = payload is PreservedString && payload.value == 'large';
    return Rect2.fromEdges(
      left: 0,
      top: 0,
      right: large ? 20 : 10,
      bottom: large ? 40 : 20,
    );
  }

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => Ok(
    payload is PreservedString && payload.value.startsWith('needs-resource')
        ? [ResourceReference(resource)]
        : const [],
  );

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => Ok(payload);
}

final class _VariableGeometryDefinition implements ObjectTypeDefinition {
  @override
  ObjectTypeKey get typeKey => testObjectTypeKey();
  @override
  List<SchemaVersion> get supportedSchemaVersions => [testSchemaVersion];
  @override
  ObjectTypeCapabilities get capabilities => const ObjectTypeCapabilities(
    hasIntrinsicGeometry: true,
    discoversResourceReferences: false,
    supportsScopedDuplication: true,
    selectable: true,
    movable: true,
    resizable: true,
    rotatable: true,
  );
  @override
  List<ObjectPayloadMigrationContract> get migrations => const [];

  @override
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => ValidationReport(const []);

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    if (payload case PreservedString(value: 'secret-geometry-failure')) {
      throw StateError('sensitive Registry geometry exception');
    }
    final extent = switch (payload) {
      PreservedString(value: 'medium') => 20.0,
      PreservedString(value: 'large') => 30.0,
      _ => 10.0,
    };
    return Rect2.fromEdges(left: 0, top: 0, right: extent, bottom: extent);
  }

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => const Ok([]);

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => Ok(payload);
}
