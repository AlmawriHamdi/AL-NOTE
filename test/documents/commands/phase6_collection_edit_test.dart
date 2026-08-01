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
    maximumUnknownNodes: 1024,
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

  test(
    'collection replacements publish only authoritative change evidence',
    () {
      final coordinator = _coordinator();
      final initial = coordinator.snapshot;
      final page = initial.root.pages.single, layer = page.layers.single;
      final object = _object();
      final add = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: initial.root.id,
          metadata: _metadata(910),
          preconditions: RevisionPreconditions(
            pages: {page.id: initial.revisions.pages[page.id]!},
            layerMembership: {
              layer.id: initial.revisions.layerMembership[layer.id]!,
            },
          ),
          pageId: page.id,
          additions: [
            ObjectCollectionAddition(layerId: layer.id, object: object),
          ],
          maximumOperations: 1,
        ),
      );
      expect(coordinator.execute(add), isA<Ok<Object?, Object?>>());

      final beforeAppearance = coordinator.snapshot;
      final appearance = _replacement(object, argb: 0xffabcdef);
      final appearanceRequest = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: beforeAppearance.root.id,
          metadata: _metadata(911),
          preconditions: RevisionPreconditions(
            pages: {page.id: beforeAppearance.revisions.pages[page.id]!},
            objects: {
              object.id: beforeAppearance.revisions.objects[object.id]!,
            },
            layerMembership: {
              layer.id: beforeAppearance.revisions.layerMembership[layer.id]!,
            },
          ),
          pageId: page.id,
          replacements: [appearance],
          replacementChangeCategories: const ObjectReplacementChangeCategories(
            appearance: true,
            text: false,
            metadata: false,
          ),
          maximumOperations: 1,
        ),
      );
      final committed = _ok(coordinator.execute(appearanceRequest));
      expect(committed.change.flags.geometry, isFalse);
      expect(committed.change.flags.appearance, isTrue);
      expect(committed.change.flags.metadata, isFalse);
      expect(coordinator.undo(), isA<Ok<Object?, Object?>>());
      expect(coordinator.redo(), isA<Ok<Object?, Object?>>());

      final beforeGeometry = coordinator.snapshot;
      final geometry = _replacement(appearance, x: 8);
      final falseClaim = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: beforeGeometry.root.id,
          metadata: _metadata(912),
          preconditions: RevisionPreconditions(
            pages: {page.id: beforeGeometry.revisions.pages[page.id]!},
            objects: {object.id: beforeGeometry.revisions.objects[object.id]!},
            layerMembership: {
              layer.id: beforeGeometry.revisions.layerMembership[layer.id]!,
            },
          ),
          pageId: page.id,
          replacements: [geometry],
          maximumOperations: 1,
        ),
      );
      expect(coordinator.execute(falseClaim), isA<Err<Object?, Object?>>());
      expect(coordinator.snapshot.root, beforeGeometry.root);
    },
  );

  test('classifier errors and exceptions are redacted before side effects', () {
    for (final mode in _HostileClassifierMode.values) {
      final generator = _CountingUuidGenerator();
      final estimator = _CountingHistoryEstimator();
      final object = _object();
      final root = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [object]),
                ],
              ),
            ],
          ),
        ],
      );
      final registry = _ok(
        ObjectRegistry.create([_HostileClassifierDefinition(mode)]),
      );
      final coordinator = _ok(
        DocumentMutationCoordinator.create(
          initialRoot: root,
          validator: DocumentValidator(registry),
          uuidGenerator: generator,
          historyLimits: _ok(
            HistoryLimits.create(
              maximumRetainedCommandCount: 10,
              maximumEstimatedRetainedBytes: 100000,
            ),
          ),
          retainedCostEstimator: estimator,
          maximumListeners: 2,
        ),
      );
      var notifications = 0;
      _ok(coordinator.addListener((_) => notifications += 1));
      final before = coordinator.snapshot;
      final page = root.pages.single, layer = page.layers.single;
      final request = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: root.id,
          metadata: _metadata(920 + mode.index),
          preconditions: RevisionPreconditions(
            pages: {page.id: before.revisions.pages[page.id]!},
            objects: {object.id: before.revisions.objects[object.id]!},
            layerMembership: {
              layer.id: before.revisions.layerMembership[layer.id]!,
            },
          ),
          pageId: page.id,
          replacements: [_replacement(object, argb: 0xffabcdef)],
          replacementChangeCategories: const ObjectReplacementChangeCategories(
            appearance: true,
            text: false,
            metadata: false,
          ),
          maximumOperations: 1,
        ),
      );
      final callsBefore = generator.calls;
      final result = coordinator.execute(request);
      expect(result, isA<Err<CommandCommit, CommandFailure>>());
      final failure = (result as Err<CommandCommit, CommandFailure>).error;
      expect(failure.code, 'documents.commands.change_evidence_unavailable');
      expect(failure.toString(), isNot(contains('classifier-secret')));
      expect(identical(coordinator.snapshot.root, before.root), isTrue);
      expect(coordinator.snapshot.revisions, before.revisions);
      expect(coordinator.retainedHistoryCount, 0);
      expect(generator.calls, callsBefore);
      expect(estimator.calls, 0);
      expect(notifications, 0);
    }
  });
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

ObjectEnvelope _replacement(ObjectEnvelope source, {int? argb, double? x}) {
  final payload = _ok(
    HandwritingPayload.decode(source.payload, limits: _limits),
  );
  final oldStroke = payload.strokes.single;
  final style = _ok(
    StrokeStyle.create(
      argb: argb ?? oldStroke.style.argb,
      opacity: oldStroke.style.opacity,
      baseWidth: oldStroke.style.baseWidth,
      pressureInfluence: oldStroke.style.pressureInfluence,
      minimumPressureFactor: oldStroke.style.minimumPressureFactor,
      limits: _limits,
      unknownFields: oldStroke.style.unknownFields,
    ),
  );
  final samples = oldStroke.samples
      .map(
        (sample) => _ok(
          StrokeSample.create(
            position: _ok(
              Point2.create(x: x ?? sample.position.x, y: sample.position.y),
            ),
            timeMicros: sample.timeMicros,
            limits: _limits,
            pressure: sample.pressure,
            tilt: sample.tilt,
            orientation: sample.orientation,
            unknownFields: sample.unknownFields,
          ),
        ),
      )
      .toList();
  final stroke = _ok(
    HandwritingStroke.create(
      id: oldStroke.id,
      samples: samples,
      style: style,
      limits: _limits,
      unknownFields: oldStroke.unknownFields,
    ),
  );
  final replacementPayload = _ok(
    HandwritingPayload.create(
      strokes: [stroke],
      limits: _limits,
      unknownFields: payload.unknownFields,
    ),
  );
  return _ok(
    ObjectEnvelope.create(
      id: source.id,
      typeKey: source.typeKey,
      envelopeVersion: source.envelopeVersion,
      typeSchemaVersion: source.typeSchemaVersion,
      transform: source.transform,
      visible: source.visible,
      locked: source.locked,
      payload: replacementPayload.encode(),
      extensionData: source.extensionData,
    ),
  );
}

T _ok<T, E>(Result<T, E> result) => (result as Ok<T, E>).value;

enum _HostileClassifierMode { returnedError, thrownException }

final class _HostileClassifierDefinition
    implements ObjectTypeDefinition, ObjectPayloadChangeClassifier {
  _HostileClassifierDefinition(this.mode);
  final _HostileClassifierMode mode;
  final HandwritingObjectTypeDefinition _delegate =
      HandwritingObjectTypeDefinition(_limits);

  @override
  ObjectTypeKey get typeKey => _delegate.typeKey;
  @override
  List<SchemaVersion> get supportedSchemaVersions =>
      _delegate.supportedSchemaVersions;
  @override
  ObjectTypeCapabilities get capabilities => _delegate.capabilities;
  @override
  List<ObjectPayloadMigrationContract> get migrations => _delegate.migrations;
  @override
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => _delegate.validatePayload(payload, schemaVersion);
  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => _delegate.intrinsicGeometry(payload, schemaVersion);
  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => _delegate.resourceReferences(payload, schemaVersion);
  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => _delegate.duplicatePayload(payload, schemaVersion, remapping);
  @override
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) => switch (mode) {
    _HostileClassifierMode.returnedError => Err(
      StructuredFailure(
        code: 'hostile.classifier_failure',
        category: FailureCategory.dependency,
        retryDisposition: RetryDisposition.never,
        message: 'classifier-secret-returned',
      ),
    ),
    _HostileClassifierMode.thrownException => throw StateError(
      'classifier-secret-thrown',
    ),
  };
}

final class _CountingUuidGenerator implements UuidGenerator {
  int calls = 0;
  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    calls += 1;
    return Ok(testUuid(6000 + calls));
  }
}

final class _CountingHistoryEstimator implements HistoryRetainedCostEstimator {
  int calls = 0;
  @override
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  ) {
    calls += 1;
    return HistoryRetainedCost.create(100);
  }
}

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
