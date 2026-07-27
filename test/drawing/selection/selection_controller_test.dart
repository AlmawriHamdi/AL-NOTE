// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/drawing/selection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase3_test_support.dart';

final class BoundaryRecorder implements CoalescingBoundarySink {
  final List<CoalescingBoundary> boundaries = [];
  @override
  Result<void, StructuredFailure> establishCoalescingBoundary(
    CoalescingBoundary boundary,
  ) {
    boundaries.add(boundary);
    return const Ok(null);
  }
}

final class ControlledBoundarySink implements CoalescingBoundarySink {
  bool fail = false;
  bool throwFailure = false;

  @override
  Result<void, StructuredFailure> establishCoalescingBoundary(
    CoalescingBoundary boundary,
  ) {
    if (throwFailure) throw StateError('secret boundary exception');
    if (fail) {
      return Err(
        StructuredFailure(
          code: 'secret.boundary.failure',
          category: FailureCategory.dependency,
          retryDisposition: RetryDisposition.never,
          message: 'secret boundary message',
        ),
      );
    }
    return const Ok(null);
  }
}

SelectionTarget target(PageId page, int object) => SelectionTarget.wholeObject(
  pageId: page,
  objectId: ObjectId.fromUuid(testUuid(object)),
);

void main() {
  group('temporary Selection', () {
    test(
      'replace, add, remove, toggle, and clear are ordered and monotonic',
      () {
        final root = phase3Notebook();
        final page = root.pages.single.id;
        final barriers = BoundaryRecorder();
        final controller = SelectionController(
          objectRegistry: editableTestRegistry(),
          coalescingBoundarySink: barriers,
        );
        expect(
          controller.replace(root: root, targets: [target(page, 1)]),
          isA<Ok<SelectionState, SelectionFailure>>(),
        );
        expect(controller.state.revision.value, 1);
        controller.add(root: root, targets: [target(page, 2)]);
        expect(controller.state.targets.map((value) => value.objectId), [
          ObjectId.fromUuid(testUuid(1)),
          ObjectId.fromUuid(testUuid(2)),
        ]);
        controller.remove(root: root, targets: [target(page, 1)]);
        expect(controller.state.primaryTarget, target(page, 2));
        controller.toggle(
          root: root,
          targets: [target(page, 1), target(page, 2)],
        );
        expect(controller.state.targets, [target(page, 1)]);
        controller.clear();
        expect(controller.state.isEmpty, isTrue);
        expect(controller.state.revision.value, 5);
        expect(barriers.boundaries, hasLength(5));
      },
    );

    test('no-op changes do not increment revision or create barriers', () {
      final root = phase3Notebook();
      final page = root.pages.single.id;
      final barriers = BoundaryRecorder();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: barriers,
      );
      controller.replace(root: root, targets: [target(page, 1)]);
      final revision = controller.state.revision;
      controller.replace(root: root, targets: [target(page, 1)]);
      expect(controller.state.revision, revision);
      expect(barriers.boundaries, hasLength(1));
    });

    test('rejects duplicate, cross-Page, and invalid primary inputs', () {
      final root = phase3Notebook();
      final page = root.pages.single.id;
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: BoundaryRecorder(),
      );
      expect(
        controller.replace(
          root: root,
          targets: [target(page, 1), target(page, 1)],
        ),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
      expect(
        controller.replace(
          root: root,
          targets: [target(page, 1), target(PageId.fromUuid(testUuid(999)), 2)],
        ),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
      expect(
        controller.replace(
          root: root,
          targets: [target(page, 1)],
          primaryTarget: target(page, 2),
        ),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
      expect(controller.state.isEmpty, isTrue);
    });

    test('hidden, locked, unknown, and incapable Objects fail closed', () {
      final conservative = testRegistry();
      for (final pair in <(NotebookDocument, ObjectRegistry)>[
        (
          phase3Notebook(first: testObject(visible: false)),
          editableTestRegistry(),
        ),
        (
          phase3Notebook(first: testObject(locked: true)),
          editableTestRegistry(),
        ),
        (phase3Notebook(), conservative),
        (
          phase3Notebook(
            first: testObject(
              typeKey: testObjectTypeKey('unknown.object.type'),
            ),
          ),
          editableTestRegistry(),
        ),
      ]) {
        final controller = SelectionController(
          objectRegistry: pair.$2,
          coalescingBoundarySink: BoundaryRecorder(),
        );
        expect(
          controller.replace(
            root: pair.$1,
            targets: [target(pair.$1.pages.single.id, 1)],
          ),
          isA<Err<SelectionState, SelectionFailure>>(),
        );
      }
    });

    test('reconciliation removes deletion and retains same-ID replacement', () {
      final root = phase3Notebook();
      final page = root.pages.single.id;
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: BoundaryRecorder(),
      );
      controller.replace(
        root: root,
        targets: [target(page, 1), target(page, 2)],
      );
      final replacementRoot = phase3Notebook(
        first: testObject(payload: const PreservedString('replacement')),
        second: testObject(id: 2, visible: false),
      );
      controller.reconcile(replacementRoot);
      expect(controller.state.targets, [target(page, 1)]);
      expect(controller.state.transformPreview, isNull);
    });

    test('unsupported sub-target behavior fails closed', () {
      final root = phase3Notebook();
      final page = root.pages.single.id;
      final kind = commandValue(
        SelectionSubTargetKind.parse('alnote.stroke.part'),
      );
      final subTarget =
          (SelectionTarget.subTarget(
                    pageId: page,
                    objectId: ObjectId.fromUuid(testUuid(1)),
                    kind: kind,
                    id: SelectionSubTargetId.fromUuid(testUuid(500)),
                  )
                  as Ok<SelectionTarget, StructuredFailure>)
              .value;
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: BoundaryRecorder(),
      );
      expect(
        controller.replace(root: root, targets: [subTarget]),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
    });

    test('selection revision overflow changes nothing', () {
      final maximum =
          (Revision.create(Revision.maximumValue)
                  as Ok<Revision, StructuredFailure>)
              .value;
      final root = phase3Notebook();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: BoundaryRecorder(),
        initialRevision: maximum,
      );
      expect(
        controller.replace(
          root: root,
          targets: [target(root.pages.single.id, 1)],
        ),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
      expect(controller.state.isEmpty, isTrue);
      expect(controller.state.revision, maximum);
    });

    test('public SelectionState factory rejects invalid derived states', () {
      final root = phase3Notebook();
      final page = root.pages.single.id;
      final zero = modelValue(Revision.create(0));
      final bounds = modelValue(
        Rect2.fromEdges(left: 0, top: 0, right: 1, bottom: 1),
      );
      final selected = target(page, 1);
      final layer = root.pages.single.layers.single.id;
      final invalid = <Result<SelectionState, SelectionFailure>>[
        SelectionState.create(
          activePageId: page,
          targets: [selected, selected],
          primaryTarget: selected,
          revision: zero,
          operationMode: SelectionOperationMode.wholeObject,
          layerMembership: {selected.objectId: layer},
          aggregateBounds: bounds,
          transformPreview: null,
        ),
        SelectionState.create(
          activePageId: null,
          targets: [selected],
          primaryTarget: selected,
          revision: zero,
          operationMode: SelectionOperationMode.wholeObject,
          layerMembership: {selected.objectId: layer},
          aggregateBounds: bounds,
          transformPreview: null,
        ),
        SelectionState.create(
          activePageId: page,
          targets: [selected],
          primaryTarget: target(page, 2),
          revision: zero,
          operationMode: SelectionOperationMode.wholeObject,
          layerMembership: {selected.objectId: layer},
          aggregateBounds: bounds,
          transformPreview: null,
        ),
        SelectionState.create(
          activePageId: page,
          targets: [selected],
          primaryTarget: selected,
          revision: zero,
          operationMode: SelectionOperationMode.wholeObject,
          layerMembership: const {},
          aggregateBounds: bounds,
          transformPreview: null,
        ),
      ];
      expect(
        invalid,
        everyElement(isA<Err<SelectionState, SelectionFailure>>()),
      );
      final targets = [selected];
      final memberships = {selected.objectId: layer};
      final valid =
          SelectionState.create(
                activePageId: page,
                targets: targets,
                primaryTarget: selected,
                revision: zero,
                operationMode: SelectionOperationMode.wholeObject,
                layerMembership: memberships,
                aggregateBounds: bounds,
                transformPreview: null,
              )
              as Ok<SelectionState, SelectionFailure>;
      targets.clear();
      memberships.clear();
      expect(valid.value.targets, [selected]);
      expect(valid.value.layerMembership, {selected.objectId: layer});
      expect(valid.value.targets.clear, throwsUnsupportedError);
      expect(valid.value.layerMembership.clear, throwsUnsupportedError);
      final empty = SelectionState.empty(zero);
      expect(empty.isEmpty, isTrue);
      expect(empty.aggregateBounds, isNull);
    });

    test('boundary exceptions keep every Selection mutation atomic', () {
      for (final operation in <String>[
        'replace',
        'add',
        'remove',
        'toggle',
        'clear',
        'reconcile',
      ]) {
        final root = phase3Notebook();
        final page = root.pages.single.id;
        final sink = ControlledBoundarySink();
        final controller = SelectionController(
          objectRegistry: editableTestRegistry(),
          coalescingBoundarySink: sink,
        );
        if (operation != 'replace') {
          controller.replace(
            root: root,
            targets: operation == 'remove' || operation == 'reconcile'
                ? [target(page, 1), target(page, 2)]
                : [target(page, 1)],
          );
        }
        final before = controller.state;
        sink.throwFailure = true;
        final result = switch (operation) {
          'replace' => controller.replace(
            root: root,
            targets: [target(page, 1)],
          ),
          'add' => controller.add(root: root, targets: [target(page, 2)]),
          'remove' => controller.remove(root: root, targets: [target(page, 1)]),
          'toggle' => controller.toggle(root: root, targets: [target(page, 2)]),
          'clear' => controller.clear(),
          'reconcile' => controller.reconcile(
            phase3Notebook(second: testObject(id: 2, visible: false)),
          ),
          _ => throw StateError('unreachable'),
        };
        final failure = (result as Err<SelectionState, SelectionFailure>).error;
        expect(failure.code, 'drawing.selection.coalescing_boundary_failed');
        expect(failure.toString(), isNot(contains('secret')));
        expect(identical(controller.state, before), isTrue, reason: operation);
        expect(controller.state.revision, before.revision, reason: operation);
      }
    });

    test('returned boundary failure also preserves prior Selection', () {
      final root = phase3Notebook();
      final sink = ControlledBoundarySink()..fail = true;
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: sink,
      );
      final before = controller.state;
      final result = controller.replace(
        root: root,
        targets: [target(root.pages.single.id, 1)],
      );
      expect(result, isA<Err<SelectionState, SelectionFailure>>());
      expect(identical(controller.state, before), isTrue);
    });

    test('reconciliation clears previews and removed Pages atomically', () {
      final coordinator = phase3Coordinator();
      final sink = ControlledBoundarySink();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: sink,
      );
      final page = coordinator.snapshot.root.pages.single.id;
      controller.replace(
        root: coordinator.snapshot.root,
        targets: [target(page, 1)],
      );
      controller.beginTransform(
        document: coordinator.snapshot,
        operation: TranslationTransformOperation2D(
          modelValue(Vector2.create(x: 1, y: 0)),
        ),
      );
      expect(controller.state.transformPreview, isNotNull);
      final previewState = controller.state;
      sink.fail = true;
      expect(
        controller.reconcile(coordinator.snapshot.root),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
      expect(identical(controller.state, previewState), isTrue);
      expect(
        controller.state.transformPreview,
        same(previewState.transformPreview),
      );
      sink.fail = false;
      controller.reconcile(coordinator.snapshot.root);
      expect(controller.state.transformPreview, isNull);

      final withoutPage = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                id: 21,
                layers: [
                  testContentLayer(objects: [testObject(), testObject(id: 2)]),
                ],
              ),
            ],
          ),
        ],
      );
      controller.reconcile(withoutPage);
      expect(controller.state.isEmpty, isTrue);
      expect(controller.state.activePageId, isNull);
    });

    test('reconciliation refreshes derived Layer membership', () {
      final original = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [testObject()]),
                  testContentLayer(id: 11, objects: [testObject(id: 2)]),
                ],
              ),
            ],
          ),
        ],
      );
      final moved = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(),
                  testContentLayer(
                    id: 11,
                    objects: [testObject(id: 2), testObject()],
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: BoundaryRecorder(),
      );
      final page = original.pages.single.id;
      controller.replace(root: original, targets: [target(page, 1)]);
      expect(
        controller.state.layerMembership[ObjectId.fromUuid(testUuid(1))],
        LayerId.fromUuid(testUuid(10)),
      );
      controller.reconcile(moved);
      expect(
        controller.state.layerMembership[ObjectId.fromUuid(testUuid(1))],
        LayerId.fromUuid(testUuid(11)),
      );
    });

    test('zero-area intrinsic geometry remains selectable', () {
      for (final geometry in <Rect2>[
        modelValue(Rect2.fromEdges(left: 5, top: 5, right: 5, bottom: 20)),
        modelValue(Rect2.fromEdges(left: 5, top: 5, right: 20, bottom: 5)),
        modelValue(Rect2.fromEdges(left: 5, top: 5, right: 5, bottom: 5)),
      ]) {
        final registry = testRegistry([
          TestObjectTypeDefinition(
            geometry: geometry,
            capabilities: const ObjectTypeCapabilities(
              hasIntrinsicGeometry: true,
              discoversResourceReferences: false,
              supportsScopedDuplication: true,
              selectable: true,
              movable: true,
              resizable: true,
              rotatable: true,
            ),
          ),
        ]);
        final root = phase3Notebook();
        final controller = SelectionController(
          objectRegistry: registry,
          coalescingBoundarySink: BoundaryRecorder(),
        );
        expect(
          controller.replace(
            root: root,
            targets: [target(root.pages.single.id, 1)],
          ),
          isA<Ok<SelectionState, SelectionFailure>>(),
        );
      }
    });

    test('point geometry uses inclusive Page-edge intersection', () {
      final point = modelValue(
        Rect2.fromEdges(left: 0, top: 0, right: 0, bottom: 0),
      );
      final registry = testRegistry([
        TestObjectTypeDefinition(
          geometry: point,
          capabilities: const ObjectTypeCapabilities(
            hasIntrinsicGeometry: true,
            discoversResourceReferences: false,
            supportsScopedDuplication: true,
            selectable: true,
            movable: true,
            resizable: true,
            rotatable: true,
          ),
        ),
      ]);
      for (final position in <(double, double, bool)>[
        (600, 800, true),
        (600.1, 800, false),
        (600, 800.1, false),
      ]) {
        final transform = modelValue(
          AffineTransform2D.fromOperation(
            TranslationTransformOperation2D(
              modelValue(Vector2.create(x: position.$1, y: position.$2)),
            ),
          ),
        );
        final root = phase3Notebook(first: testObject(transform: transform));
        final controller = SelectionController(
          objectRegistry: registry,
          coalescingBoundarySink: BoundaryRecorder(),
        );
        final selection = controller.replace(
          root: root,
          targets: [target(root.pages.single.id, 1)],
        );
        final coordinator = phase3Coordinator(root: root, registry: registry);
        final snapshot = coordinator.snapshot;
        final source = snapshot.root.pages.single.layers.single.objects.first;
        final edit = coordinator.execute(
          commandValue(
            AtomicObjectReplacementRequest.create(
              documentId: snapshot.root.id,
              metadata: phase3Metadata(),
              preconditions: objectPreconditions(snapshot, source.id),
              targetIds: [source.id],
              replacements: [replacementObject(source, 'changed')],
              changeCategories: _appearanceChange,
            ),
          ),
        );
        if (position.$3) {
          expect(selection, isA<Ok<SelectionState, SelectionFailure>>());
          expect(edit, isA<Ok<CommandCommit, CommandFailure>>());
        } else {
          expect(selection, isA<Err<SelectionState, SelectionFailure>>());
          expect(edit, isA<Err<CommandCommit, CommandFailure>>());
        }
      }
    });

    test('preview and coordinator share inclusive Page reachability', () {
      for (final offset in <(double, bool)>[
        (595, true),
        (600, true),
        (601, false),
      ]) {
        final coordinator = phase3Coordinator();
        final controller = SelectionController(
          objectRegistry: editableTestRegistry(),
          coalescingBoundarySink: coordinator,
        );
        final snapshot = coordinator.snapshot;
        controller.replace(
          root: snapshot.root,
          targets: [target(snapshot.root.pages.single.id, 1)],
        );
        final operation = TranslationTransformOperation2D(
          modelValue(Vector2.create(x: offset.$1, y: 0)),
        );
        final preview = controller.beginTransform(
          document: snapshot,
          operation: operation,
        );
        final command = coordinator.execute(
          transformRequestForSelectionTest(snapshot, operation),
        );
        if (offset.$2) {
          expect(preview, isA<Ok<SelectionState, SelectionFailure>>());
          expect(command, isA<Ok<CommandCommit, CommandFailure>>());
        } else {
          expect(preview, isA<Err<SelectionState, SelectionFailure>>());
          expect(command, isA<Err<CommandCommit, CommandFailure>>());
        }
      }
    });

    test('Registry geometry and resource failures reject Selection', () {
      for (final definition in [
        TestObjectTypeDefinition(
          failGeometry: true,
          capabilities: const ObjectTypeCapabilities(
            hasIntrinsicGeometry: true,
            discoversResourceReferences: false,
            supportsScopedDuplication: true,
            selectable: true,
          ),
        ),
        TestObjectTypeDefinition(
          failResourceDiscovery: true,
          capabilities: const ObjectTypeCapabilities(
            hasIntrinsicGeometry: true,
            discoversResourceReferences: true,
            supportsScopedDuplication: true,
            selectable: true,
          ),
        ),
      ]) {
        final root = phase3Notebook();
        final controller = SelectionController(
          objectRegistry: testRegistry([definition]),
          coalescingBoundarySink: BoundaryRecorder(),
        );
        expect(
          controller.replace(
            root: root,
            targets: [target(root.pages.single.id, 1)],
          ),
          isA<Err<SelectionState, SelectionFailure>>(),
        );
        expect(controller.state.isEmpty, isTrue);
      }
    });
  });

  group('whole-Object transform preview', () {
    test('translation preview is immutable and commits as one publication', () {
      final coordinator = phase3Coordinator();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: coordinator,
      );
      final page = coordinator.snapshot.root.pages.single.id;
      controller.replace(
        root: coordinator.snapshot.root,
        targets: [target(page, 1), target(page, 2)],
      );
      final offset =
          (Vector2.create(x: 5, y: 7) as Ok<Vector2, StructuredFailure>).value;
      expect(
        controller.beginTransform(
          document: coordinator.snapshot,
          operation: TranslationTransformOperation2D(offset),
        ),
        isA<Ok<SelectionState, SelectionFailure>>(),
      );
      final preview = controller.state.transformPreview!;
      expect(coordinator.snapshot.revisions.document.value, 0);
      expect(preview.oldBounds.left, 0);
      expect(preview.newBounds.left, 5);
      expect(preview.candidateObjects.clear, throwsUnsupportedError);
      var notifications = 0;
      coordinator.addListener((_) => notifications += 1);
      final request = commandValue(
        preview.commandRequest(
          phase3Metadata(family: 'alnote.commands.object.transform'),
        ),
      );
      final result = coordinator.execute(request);
      expect(result, isA<Ok<CommandCommit, CommandFailure>>());
      final change = (result as Ok<CommandCommit, CommandFailure>).value.change;
      expect(change.flags.geometry, isTrue);
      expect(change.flags.appearance, isFalse);
      expect(change.flags.text, isFalse);
      expect(change.flags.metadata, isFalse);
      expect(notifications, 1);
      expect(coordinator.retainedHistoryCount, 1);
      final transformed =
          coordinator.snapshot.root.pages.single.layers.single.objects;
      expect(transformed.first.payload, const PreservedString('payload'));
      expect(coordinator.undo(), isA<Ok<CommandCommit, CommandFailure>>());
      expect(coordinator.redo(), isA<Ok<CommandCommit, CommandFailure>>());
    });

    test('rotation and strictly positive scale preview successfully', () {
      final coordinator = phase3Coordinator();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: coordinator,
      );
      final page = coordinator.snapshot.root.pages.single.id;
      controller.replace(
        root: coordinator.snapshot.root,
        targets: [target(page, 1)],
      );
      final pivot =
          (Point2.create(x: 5, y: 10) as Ok<Point2, StructuredFailure>).value;
      final rotation = commandValue(
        RotationTransformOperation2D.create(radians: 0.5, pivot: pivot),
      );
      expect(
        controller.beginTransform(
          document: coordinator.snapshot,
          operation: rotation,
        ),
        isA<Ok<SelectionState, SelectionFailure>>(),
      );
      final scale = commandValue(
        ScaleTransformOperation2D.create(scaleX: 2, scaleY: 3, pivot: pivot),
      );
      expect(
        controller.updateTransform(coordinator.snapshot, scale),
        isA<Ok<SelectionState, SelectionFailure>>(),
      );
    });

    test(
      'partial overflow is accepted and complete unreachability is rejected',
      () {
        final coordinator = phase3Coordinator();
        final controller = SelectionController(
          objectRegistry: editableTestRegistry(),
          coalescingBoundarySink: coordinator,
        );
        final page = coordinator.snapshot.root.pages.single.id;
        controller.replace(
          root: coordinator.snapshot.root,
          targets: [target(page, 1)],
        );
        final partial =
            (Vector2.create(x: -5, y: 0) as Ok<Vector2, StructuredFailure>)
                .value;
        expect(
          controller.beginTransform(
            document: coordinator.snapshot,
            operation: TranslationTransformOperation2D(partial),
          ),
          isA<Ok<SelectionState, SelectionFailure>>(),
        );
        final validPreview = controller.state.transformPreview;
        final unreachable =
            (Vector2.create(x: 1000, y: 0) as Ok<Vector2, StructuredFailure>)
                .value;
        expect(
          controller.updateTransform(
            coordinator.snapshot,
            TranslationTransformOperation2D(unreachable),
          ),
          isA<Err<SelectionState, SelectionFailure>>(),
        );
        expect(controller.state.transformPreview, same(validPreview));
        controller.cancelTransform();
        expect(controller.state.transformPreview, isNull);
        expect(coordinator.snapshot.revisions.document.value, 0);
      },
    );

    test('stale preview rejects the entire commit', () {
      final coordinator = phase3Coordinator();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: coordinator,
      );
      final initial = coordinator.snapshot;
      final page = initial.root.pages.single.id;
      final object = initial.root.pages.single.layers.single.objects.first;
      controller.replace(root: initial.root, targets: [target(page, 1)]);
      final offset =
          (Vector2.create(x: 1, y: 0) as Ok<Vector2, StructuredFailure>).value;
      controller.beginTransform(
        document: initial,
        operation: TranslationTransformOperation2D(offset),
      );
      final previewRequest = commandValue(
        controller.state.transformPreview!.commandRequest(
          phase3Metadata(family: 'alnote.commands.object.transform'),
        ),
      );
      final edit = commandValue(
        AtomicObjectReplacementRequest.create(
          documentId: initial.root.id,
          metadata: phase3Metadata(),
          preconditions: objectPreconditions(initial, object.id),
          targetIds: [object.id],
          replacements: [replacementObject(object, 'intervening')],
          changeCategories: _appearanceChange,
        ),
      );
      coordinator.execute(edit);
      final beforeFailure = coordinator.snapshot;
      expect(
        coordinator.execute(previewRequest),
        isA<Err<CommandCommit, CommandFailure>>(),
      );
      expect(coordinator.snapshot.root, beforeFailure.root);
    });

    test('unrelated Object edit does not stale a transform preview', () {
      final coordinator = phase3Coordinator();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: coordinator,
      );
      final initial = coordinator.snapshot;
      final page = initial.root.pages.single.id;
      final objects = initial.root.pages.single.layers.single.objects;
      controller.replace(root: initial.root, targets: [target(page, 1)]);
      final offset =
          (Vector2.create(x: 1, y: 0) as Ok<Vector2, StructuredFailure>).value;
      controller.beginTransform(
        document: initial,
        operation: TranslationTransformOperation2D(offset),
      );
      final previewRequest = commandValue(
        controller.state.transformPreview!.commandRequest(
          phase3Metadata(family: 'alnote.commands.object.transform'),
        ),
      );
      final unrelatedEdit = commandValue(
        AtomicObjectReplacementRequest.create(
          documentId: initial.root.id,
          metadata: phase3Metadata(),
          preconditions: objectPreconditions(initial, objects.last.id),
          targetIds: [objects.last.id],
          replacements: [replacementObject(objects.last, 'unrelated')],
          changeCategories: _appearanceChange,
        ),
      );
      coordinator.execute(unrelatedEdit);
      expect(
        coordinator.execute(previewRequest),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
    });

    test('same-Page multi-Layer transform preserves membership and order', () {
      final root = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [testObject()]),
                  testContentLayer(id: 11, objects: [testObject(id: 2)]),
                ],
              ),
            ],
          ),
        ],
      );
      final coordinator = phase3Coordinator(root: root);
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: coordinator,
      );
      final page = root.pages.single.id;
      controller.replace(
        root: root,
        targets: [target(page, 1), target(page, 2)],
      );
      final offset =
          (Vector2.create(x: 2, y: 3) as Ok<Vector2, StructuredFailure>).value;
      controller.beginTransform(
        document: coordinator.snapshot,
        operation: TranslationTransformOperation2D(offset),
      );
      final request = commandValue(
        controller.state.transformPreview!.commandRequest(
          phase3Metadata(family: 'alnote.commands.object.transform'),
        ),
      );
      coordinator.execute(request);
      final layers = coordinator.snapshot.root.pages.single.layers;
      expect(layers.map((layer) => layer.id), [
        LayerId.fromUuid(testUuid(10)),
        LayerId.fromUuid(testUuid(11)),
      ]);
      expect(layers.first.objects.single.id, ObjectId.fromUuid(testUuid(1)));
      expect(layers.last.objects.single.id, ObjectId.fromUuid(testUuid(2)));
    });

    test('transform requests reject coalescing metadata', () {
      final coordinator = phase3Coordinator();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: coordinator,
      );
      final coalescing = CommandCoalescing(
        mergeKey: commandValue(
          CoalescingMergeKey.parse('alnote.merge.transform'),
        ),
        sessionId: CoalescingSessionId.fromUuid(testUuid(302)),
        logicalTarget: LogicalCoalescingTarget.object(
          ObjectId.fromUuid(testUuid(1)),
        ),
      );
      final snapshot = coordinator.snapshot;
      final page = snapshot.root.pages.single.id;
      controller.replace(
        root: snapshot.root,
        targets: [target(page, 1), target(page, 2)],
      );
      final offset =
          (Vector2.create(x: 1, y: 0) as Ok<Vector2, StructuredFailure>).value;
      controller.beginTransform(
        document: snapshot,
        operation: TranslationTransformOperation2D(offset),
      );
      expect(
        controller.state.transformPreview!.commandRequest(
          phase3Metadata(
            family: 'alnote.commands.object.transform',
            coalescing: coalescing,
          ),
        ),
        isA<Err<AtomicWholeObjectTransformRequest, StructuredFailure>>(),
      );
      expect(coordinator.retainedHistoryCount, 0);
    });

    test('public preview factory rejects mismatched maps and transforms', () {
      final coordinator = phase3Coordinator();
      final controller = SelectionController(
        objectRegistry: editableTestRegistry(),
        coalescingBoundarySink: coordinator,
      );
      final snapshot = coordinator.snapshot;
      final page = snapshot.root.pages.single.id;
      controller.replace(root: snapshot.root, targets: [target(page, 1)]);
      controller.beginTransform(
        document: snapshot,
        operation: TranslationTransformOperation2D(
          modelValue(Vector2.create(x: 1, y: 0)),
        ),
      );
      final valid = controller.state.transformPreview!;
      expect(
        WholeObjectTransformPreview.create(
          documentId: valid.documentId,
          pageId: valid.pageId,
          targetIds: [valid.targetIds.single, valid.targetIds.single],
          operation: valid.operation,
          baseObjects: valid.baseObjects,
          candidateObjects: valid.candidateObjects,
          preconditions: valid.preconditions,
          oldBounds: valid.oldBounds,
          newBounds: valid.newBounds,
        ),
        isA<Err<WholeObjectTransformPreview, SelectionFailure>>(),
      );
      expect(
        WholeObjectTransformPreview.create(
          documentId: valid.documentId,
          pageId: valid.pageId,
          targetIds: valid.targetIds,
          operation: valid.operation,
          baseObjects: valid.baseObjects,
          candidateObjects: valid.candidateObjects,
          preconditions: RevisionPreconditions(),
          oldBounds: valid.oldBounds,
          newBounds: valid.newBounds,
        ),
        isA<Err<WholeObjectTransformPreview, SelectionFailure>>(),
      );
      expect(
        SelectionState.create(
          activePageId: valid.pageId,
          targets: [target(valid.pageId, 2)],
          primaryTarget: target(valid.pageId, 2),
          revision: modelValue(Revision.create(1)),
          operationMode: SelectionOperationMode.wholeObject,
          layerMembership: {
            ObjectId.fromUuid(testUuid(2)):
                snapshot.root.pages.single.layers.single.id,
          },
          aggregateBounds: valid.oldBounds,
          transformPreview: valid,
        ),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
      final subTarget = commandValue(
        SelectionTarget.subTarget(
          pageId: valid.pageId,
          objectId: valid.targetIds.single,
          kind: commandValue(
            SelectionSubTargetKind.parse('alnote.selection.test_part'),
          ),
          id: SelectionSubTargetId.fromUuid(testUuid(800)),
        ),
      );
      final priorState = controller.state;
      expect(
        SelectionState.create(
          activePageId: valid.pageId,
          targets: [subTarget],
          primaryTarget: subTarget,
          revision: priorState.revision,
          operationMode: SelectionOperationMode.wholeObject,
          layerMembership: const {},
          aggregateBounds: valid.oldBounds,
          transformPreview: valid,
        ),
        isA<Err<SelectionState, SelectionFailure>>(),
      );
      expect(identical(controller.state, priorState), isTrue);
      expect(
        WholeObjectTransformPreview.create(
          documentId: valid.documentId,
          pageId: valid.pageId,
          targetIds: valid.targetIds,
          operation: valid.operation,
          baseObjects: valid.baseObjects,
          candidateObjects: valid.baseObjects,
          preconditions: valid.preconditions,
          oldBounds: valid.oldBounds,
          newBounds: valid.newBounds,
        ),
        isA<Err<WholeObjectTransformPreview, SelectionFailure>>(),
      );
      expect(
        () => valid.targetIds.add(ObjectId.fromUuid(testUuid(999))),
        throwsUnsupportedError,
      );
      expect(valid.baseObjects.clear, throwsUnsupportedError);
      expect(valid.candidateObjects.clear, throwsUnsupportedError);
    });
  });
}

AtomicWholeObjectTransformRequest transformRequestForSelectionTest(
  DocumentCoordinatorSnapshot snapshot,
  TransformOperation2D operation,
) {
  final page = snapshot.root.pages.single;
  final object = page.layers.single.objects.first;
  final layer = page.layers.single;
  return commandValue(
    AtomicWholeObjectTransformRequest.create(
      documentId: snapshot.root.id,
      metadata: phase3Metadata(family: 'alnote.commands.object.transform'),
      preconditions: RevisionPreconditions(
        pages: {page.id: snapshot.revisions.pages[page.id]!},
        layerMembership: {
          layer.id: snapshot.revisions.layerMembership[layer.id]!,
        },
        objects: {object.id: snapshot.revisions.objects[object.id]!},
      ),
      pageId: page.id,
      targetIds: [object.id],
      operation: operation,
    ),
  );
}

const _appearanceChange = ObjectReplacementChangeCategories(
  appearance: true,
  text: false,
  metadata: false,
);
