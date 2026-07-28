// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/drawing/selection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase3_test_support.dart';

void main() {
  group('command contracts', () {
    test('editing capabilities default closed and participate in equality', () {
      const conservative = ObjectTypeCapabilities(
        hasIntrinsicGeometry: true,
        discoversResourceReferences: false,
        supportsScopedDuplication: false,
      );
      const editable = ObjectTypeCapabilities(
        hasIntrinsicGeometry: true,
        discoversResourceReferences: false,
        supportsScopedDuplication: false,
        selectable: true,
      );
      expect(conservative.selectable, isFalse);
      expect(conservative.movable, isFalse);
      expect(conservative.resizable, isFalse);
      expect(conservative.rotatable, isFalse);
      expect(conservative, isNot(editable));
      expect(conservative.hashCode, isNot(editable.hashCode));
    });

    test('replacement request captures ordered inputs defensively', () {
      final targets = [ObjectId.fromUuid(testUuid(1))];
      final replacements = [testObject()];
      final request = commandValue(
        AtomicObjectReplacementRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: phase3Metadata(),
          preconditions: RevisionPreconditions(),
          targetIds: targets,
          replacements: replacements,
          changeCategories: _appearanceChange,
        ),
      );
      targets.add(ObjectId.fromUuid(testUuid(2)));
      replacements.clear();
      expect(request.targetIds, hasLength(1));
      expect(request.replacements, hasLength(1));
      expect(
        () => request.targetIds.add(testObject(id: 3).id),
        throwsUnsupportedError,
      );
    });

    test('requests reject duplicates and identity mismatch', () {
      final target = ObjectId.fromUuid(testUuid(1));
      expect(
        AtomicObjectReplacementRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: phase3Metadata(),
          preconditions: RevisionPreconditions(),
          targetIds: [target, target],
          replacements: [testObject(), testObject()],
          changeCategories: _appearanceChange,
        ),
        isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );
      expect(
        AtomicObjectReplacementRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: phase3Metadata(),
          preconditions: RevisionPreconditions(),
          targetIds: [target],
          replacements: [testObject(id: 2)],
          changeCategories: _appearanceChange,
        ),
        isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );
    });

    test('diagnostics redact descriptions and payload values', () {
      final request = commandValue(
        AtomicObjectReplacementRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: phase3Metadata(description: 'private words'),
          preconditions: RevisionPreconditions(),
          targetIds: [ObjectId.fromUuid(testUuid(1))],
          replacements: [
            testObject(payload: const PreservedString('private payload')),
          ],
          changeCategories: _appearanceChange,
        ),
      );
      expect(request.toString(), isNot(contains('private')));
      expect(request.metadata.toString(), isNot(contains('private')));
      expect(
        SelectionFailure(
          'drawing.selection.failure',
          FailureCategory.validation,
        ).toString(),
        isNot(contains('payload')),
      );
    });

    test('revision mismatches are typed and deterministically ordered', () {
      final root = phase3Notebook();
      final revisions = DocumentRevisionSnapshot.initial(root);
      final one = Revision.create(1) as Ok<Revision, StructuredFailure>;
      final evidence = revisions.mismatches(
        RevisionPreconditions(
          objects: {
            root.pages.single.layers.single.objects.last.id: one.value,
            root.pages.single.layers.single.objects.first.id: one.value,
          },
        ),
      );
      expect(evidence, hasLength(2));
      expect(
        (evidence.first.subject as ObjectRevisionSubject).id,
        ObjectId.fromUuid(testUuid(1)),
      );
      expect(
        (evidence.last.subject as ObjectRevisionSubject).id,
        ObjectId.fromUuid(testUuid(2)),
      );
      expect(evidence.first.expected.value, 1);
      expect(evidence.first.actual!.value, 0);
    });

    test('all stale subjects are closed, typed, and kind ordered', () {
      final root = phase3Notebook();
      final snapshot = DocumentRevisionSnapshot.initial(root);
      final one = modelValue(Revision.create(1));
      final section = root.sections.single;
      final page = root.pages.single;
      final layer = page.layers.single;
      final object = layer.objects.first;
      final evidence = snapshot.mismatches(
        RevisionPreconditions(
          document: one,
          sections: {section.id: one},
          pages: {page.id: one},
          layers: {layer.id: one},
          layerMembership: {layer.id: one},
          objects: {object.id: one},
          resourceCatalog: one,
        ),
      );
      expect(evidence.map((value) => value.subject.runtimeType), [
        DocumentRevisionSubject,
        SectionRevisionSubject,
        PageRevisionSubject,
        LayerRevisionSubject,
        LayerMembershipRevisionSubject,
        ObjectRevisionSubject,
        ResourceCatalogRevisionSubject,
      ]);
      expect(evidence.join(' '), isNot(contains('payload')));
    });

    test('a missing subject is stale even when zero was expected', () {
      final snapshot = DocumentRevisionSnapshot.initial(phase3Notebook());
      final zero = modelValue(Revision.create(0));
      final missing = ObjectId.fromUuid(testUuid(999));
      final evidence = snapshot.mismatches(
        RevisionPreconditions(objects: {missing: zero}),
      );
      expect(evidence, hasLength(1));
      expect(evidence.single.subject, ObjectRevisionSubject(missing));
      expect(evidence.single.actual, isNull);
    });

    test('revision advancement detects overflow atomically', () {
      final root = phase3Notebook();
      final initial = DocumentRevisionSnapshot.initial(root);
      final maximum = modelValue(Revision.create(Revision.maximumValue));
      final target = root.pages.single.layers.single.objects.first.id;
      final nearOverflow = DocumentRevisionSnapshot.fromValues(
        documentId: root.id,
        document: maximum,
        sections: initial.sections,
        pages: initial.pages,
        layers: initial.layers,
        layerMembership: initial.layerMembership,
        objects: initial.objects,
        resourceCatalog: initial.resourceCatalog,
      );
      expect(
        nearOverflow.advanceObjects([target]),
        isA<Err<DocumentRevisionSnapshot, StructuredFailure>>(),
      );
      expect(nearOverflow.document, maximum);
      expect(nearOverflow.objects[target]!.value, 0);
    });

    test('request variants enforce fixed semantic families', () {
      final wrong = phase3Metadata(family: 'alnote.commands.wrong.family');
      expect(
        AtomicObjectReplacementRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: wrong,
          preconditions: RevisionPreconditions(),
          targetIds: [ObjectId.fromUuid(testUuid(1))],
          replacements: [testObject()],
          changeCategories: _appearanceChange,
        ),
        isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );
      final offset = modelValue(Vector2.create(x: 1, y: 0));
      expect(
        AtomicWholeObjectTransformRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: phase3Metadata(),
          preconditions: RevisionPreconditions(),
          pageId: PageId.fromUuid(testUuid(20)),
          targetIds: [ObjectId.fromUuid(testUuid(1))],
          operation: TranslationTransformOperation2D(offset),
        ),
        isA<Err<AtomicWholeObjectTransformRequest, StructuredFailure>>(),
      );
    });

    test('replacement coalescing requires exactly its one typed Object', () {
      final first = ObjectId.fromUuid(testUuid(1));
      final second = ObjectId.fromUuid(testUuid(2));
      final metadata = phase3Metadata(
        coalescing: CommandCoalescing(
          mergeKey: commandValue(CoalescingMergeKey.parse('alnote.merge.edit')),
          sessionId: CoalescingSessionId.fromUuid(testUuid(300)),
          logicalTarget: LogicalCoalescingTarget.object(first),
        ),
      );
      expect(
        AtomicObjectReplacementRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: metadata,
          preconditions: RevisionPreconditions(),
          targetIds: [second],
          replacements: [testObject(id: 2)],
          changeCategories: _appearanceChange,
        ),
        isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );
      expect(
        AtomicObjectReplacementRequest.create(
          documentId: DocumentId.fromUuid(testUuid(40)),
          metadata: metadata,
          preconditions: RevisionPreconditions(),
          targetIds: [first, second],
          replacements: [testObject(), testObject(id: 2)],
          changeCategories: _appearanceChange,
        ),
        isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );
    });
  });
}

const _appearanceChange = ObjectReplacementChangeCategories(
  appearance: true,
  text: false,
  metadata: false,
);
