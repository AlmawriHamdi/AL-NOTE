// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/files/src/record_codec.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase4_test_support.dart';

void main() {
  group('trusted migration orchestration', () {
    test('plans and applies adjacent steps deterministically', () {
      final input = PreservedMap(<String, PreservedData>{
        'version': _integer(1),
        'unknown': const PreservedString('retained'),
      });
      final registry = _registry(<AlnoteMigrationStep>[
        AlnoteMigrationStep(
          scope: AlnoteMigrationScope.documentRoot,
          sourceVersion: 2,
          targetVersion: 3,
          handler: (value) =>
              Ok<PreservedData, StructuredFailure>(_replaceVersion(value, 3)),
        ),
        AlnoteMigrationStep(
          scope: AlnoteMigrationScope.documentRoot,
          sourceVersion: 1,
          targetVersion: 2,
          handler: (value) =>
              Ok<PreservedData, StructuredFailure>(_replaceVersion(value, 2)),
        ),
      ]);
      final plan =
          (registry.plan(
                    scope: AlnoteMigrationScope.documentRoot,
                    sourceVersion: 1,
                    targetVersion: 3,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;

      expect(plan.steps.map((step) => step.sourceVersion), <int>[1, 2]);
      final outcome =
          plan.apply(
                input,
                limits: phase4Limits(),
                cancellationToken: CancellationController().token,
              )
              as Completed<AlnoteMigrationResult, StructuredFailure>;
      final result = outcome.value.value as PreservedMap;
      expect((result.values['version']! as PreservedInteger).value, 3);
      expect(result.values['unknown'], const PreservedString('retained'));
      expect((input.values['version']! as PreservedInteger).value, 1);
      expect(outcome.value.evidence.stepCount, 2);
    });

    test('rejects duplicate, nonadjacent, gap, and reverse transitions', () {
      const step = AlnoteMigrationStep(
        scope: AlnoteMigrationScope.package,
        sourceVersion: 1,
        targetVersion: 2,
        handler: Ok<PreservedData, StructuredFailure>.new,
      );
      expect(
        AlnoteMigrationRegistry.create(<AlnoteMigrationStep>[step, step]),
        isA<Err<AlnoteMigrationRegistry, StructuredFailure>>(),
      );
      expect(
        AlnoteMigrationRegistry.create(<AlnoteMigrationStep>[
          const AlnoteMigrationStep(
            scope: AlnoteMigrationScope.package,
            sourceVersion: 1,
            targetVersion: 3,
            handler: Ok<PreservedData, StructuredFailure>.new,
          ),
        ]),
        isA<Err<AlnoteMigrationRegistry, StructuredFailure>>(),
      );
      final registry = _registry(<AlnoteMigrationStep>[step]);
      expect(
        registry.plan(
          scope: AlnoteMigrationScope.package,
          sourceVersion: 1,
          targetVersion: 3,
        ),
        isA<Err<AlnoteMigrationPlan, StructuredFailure>>(),
      );
      expect(
        registry.plan(
          scope: AlnoteMigrationScope.package,
          sourceVersion: 2,
          targetVersion: 1,
        ),
        isA<Err<AlnoteMigrationPlan, StructuredFailure>>(),
      );
    });

    for (final throws in <bool>[false, true]) {
      test('redacts handler ${throws ? 'exceptions' : 'failures'}', () {
        const secret = 'secret handler payload';
        final plan =
            (_registry(<AlnoteMigrationStep>[
                      AlnoteMigrationStep(
                        scope: AlnoteMigrationScope.package,
                        sourceVersion: 1,
                        targetVersion: 2,
                        handler: (value) {
                          if (throws) throw StateError(secret);
                          return Err<PreservedData, StructuredFailure>(
                            StructuredFailure(
                              code: 'test.migration.secret',
                              category: FailureCategory.dependency,
                              retryDisposition: RetryDisposition.never,
                              message: secret,
                            ),
                          );
                        },
                      ),
                    ]).plan(
                      scope: AlnoteMigrationScope.package,
                      sourceVersion: 1,
                      targetVersion: 2,
                    )
                    as Ok<AlnoteMigrationPlan, StructuredFailure>)
                .value;
        final outcome =
            plan.apply(
                  const PreservedString(secret),
                  limits: phase4Limits(),
                  cancellationToken: CancellationController().token,
                )
                as Failed<AlnoteMigrationResult, StructuredFailure>;
        expect(outcome.failure.code, 'documents.migration.handler');
        expect(outcome.failure.toString(), isNot(contains(secret)));
      });
    }

    test('enforces step and expansion ceilings', () {
      final plan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.package,
                      sourceVersion: 1,
                      targetVersion: 2,
                      handler: (_) =>
                          const Ok<PreservedData, StructuredFailure>(
                            PreservedString('expanded'),
                          ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.package,
                    sourceVersion: 1,
                    targetVersion: 2,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      expect(
        plan.apply(
          const PreservedString('x'),
          limits: phase4Limits(
            overrides: const <String, int>{'alnote.storage.migration_steps': 0},
          ),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<AlnoteMigrationResult, StructuredFailure>>(),
      );
      expect(
        plan.apply(
          const PreservedString('x'),
          limits: phase4Limits(
            overrides: const <String, int>{
              'alnote.storage.migration_expansion_bytes': 0,
            },
          ),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<AlnoteMigrationResult, StructuredFailure>>(),
      );
    });

    test('binds a complete candidate to the declared package transition', () {
      const secret = 'secret candidate builder exception';
      final plan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.package,
                      sourceVersion: 1,
                      targetVersion: 2,
                      handler: (_) => Ok<PreservedData, StructuredFailure>(
                        _packageRecord(2),
                      ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.package,
                    sourceVersion: 1,
                    targetVersion: 2,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      final original = _snapshot();
      final versionTwo =
          (AlnotePackageVersion.create(2)
                  as Ok<AlnotePackageVersion, StructuredFailure>)
              .value;
      final migratedSnapshot =
          (AlnotePackageSnapshot.create(
                    version: versionTwo,
                    document: original.document,
                    resources: original.resources,
                    preservation: original.preservation,
                  )
                  as Ok<AlnotePackageSnapshot, StructuredFailure>)
              .value;
      final completed = plan.applyToPackage(
        _packageRecord(1),
        original: original,
        buildCandidate: (_, _) =>
            Ok<AlnotePackageSnapshot, StructuredFailure>(migratedSnapshot),
        objectRegistry: testRegistry(),
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(
        completed,
        isA<Completed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );
      expect(original.document, testNotebook());

      final unchanged = plan.applyToPackage(
        _packageRecord(1),
        original: original,
        buildCandidate: (_, _) =>
            Ok<AlnotePackageSnapshot, StructuredFailure>(original),
        objectRegistry: testRegistry(),
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(
        unchanged,
        isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );

      final invalidObject = testObject(
        payload: const PreservedString('invalid'),
      );
      final invalidDocument = testNotebook(
        sections: <DocumentSection>[
          testSection(
            pages: <DocumentPage>[
              testPage(
                layers: <DocumentLayer>[
                  testContentLayer(objects: <ObjectEnvelope>[invalidObject]),
                ],
              ),
            ],
          ),
        ],
      );
      final invalidSnapshot =
          (AlnotePackageSnapshot.create(
                    document: invalidDocument,
                    resources: const <DocumentResourceSnapshot>[],
                  )
                  as Ok<AlnotePackageSnapshot, StructuredFailure>)
              .value;
      final invalid = plan.applyToPackage(
        _packageRecord(1),
        original: original,
        buildCandidate: (_, _) =>
            Ok<AlnotePackageSnapshot, StructuredFailure>(invalidSnapshot),
        objectRegistry: testRegistry(),
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(
        invalid,
        isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );

      final thrown =
          plan.applyToPackage(
                _packageRecord(1),
                original: original,
                buildCandidate: (_, _) => throw StateError(secret),
                objectRegistry: testRegistry(),
                limits: phase4Limits(),
                cancellationToken: CancellationController().token,
              )
              as Failed<AlnotePackageMigrationResult, StructuredFailure>;
      expect(thrown.failure.code, 'documents.migration.candidate');
      expect(thrown.failure.toString(), isNot(contains(secret)));
    });

    test('rejects source mismatch and unrelated identity substitution', () {
      final plan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.package,
                      sourceVersion: 1,
                      targetVersion: 2,
                      handler: (_) => Ok<PreservedData, StructuredFailure>(
                        _packageRecord(2),
                      ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.package,
                    sourceVersion: 1,
                    targetVersion: 2,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      final versionTwo = _schemaPackageVersion(2);
      final wrongSource = _snapshot(version: versionTwo);
      expect(
        plan.applyToPackage(
          _packageRecord(2),
          original: wrongSource,
          buildCandidate: (_, _) =>
              Ok<AlnotePackageSnapshot, StructuredFailure>(wrongSource),
          objectRegistry: testRegistry(),
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );

      final original = _snapshot();
      for (final document in <DocumentRoot>[
        testNotebook(id: 41),
        testNotebook(
          sections: <DocumentSection>[
            testSection(pages: <DocumentPage>[testPage(id: 21)]),
          ],
        ),
      ]) {
        final candidate = _snapshot(document: document, version: versionTwo);
        expect(
          plan.applyToPackage(
            _packageRecord(1),
            original: original,
            buildCandidate: (_, _) =>
                Ok<AlnotePackageSnapshot, StructuredFailure>(candidate),
            objectRegistry: testRegistry(),
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          ),
          isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
        );
      }
    });

    test('validates document-root and typed Object target transitions', () {
      final schemaTwo =
          (SchemaVersion.create(2) as Ok<SchemaVersion, StructuredFailure>)
              .value;
      final original = _snapshot();
      final sourceDocument = original.document as NotebookDocument;
      final migratedDocument = modelValue<NotebookDocument>(
        NotebookDocument.create(
          id: sourceDocument.id,
          schemaVersion: schemaTwo,
          title: sourceDocument.title,
          resources: sourceDocument.resources,
          extensionData: sourceDocument.extensionData,
          sections: sourceDocument.sections,
        ),
      );
      final documentCandidate = _snapshot(document: migratedDocument);
      final documentPlan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.documentRoot,
                      sourceVersion: 1,
                      targetVersion: 2,
                      handler: (_) => Ok<PreservedData, StructuredFailure>(
                        RecordEncoder().document(migratedDocument),
                      ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.documentRoot,
                    sourceVersion: 1,
                    targetVersion: 2,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      expect(
        documentPlan.applyToPackage(
          RecordEncoder().document(original.document),
          original: original,
          buildCandidate: (_, _) =>
              Ok<AlnotePackageSnapshot, StructuredFailure>(documentCandidate),
          objectRegistry: testRegistry(),
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
        ),
        isA<Completed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );

      final objectType = testObjectTypeKey();
      final sourceObject = testObject(typeKey: objectType);
      final targetObject = testObject(
        typeKey: objectType,
        schemaVersion: schemaTwo,
        payload: const PreservedString('migrated'),
      );
      DocumentRoot withObject(ObjectEnvelope object) => testNotebook(
        sections: <DocumentSection>[
          testSection(
            pages: <DocumentPage>[
              testPage(
                layers: <DocumentLayer>[
                  testContentLayer(objects: <ObjectEnvelope>[object]),
                ],
              ),
            ],
          ),
        ],
      );
      final objectOriginal = _snapshot(document: withObject(sourceObject));
      final objectCandidate = _snapshot(document: withObject(targetObject));
      final objectPlan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.objectPayload,
                      sourceVersion: 1,
                      targetVersion: 2,
                      objectType: objectType,
                      handler: (_) =>
                          const Ok<PreservedData, StructuredFailure>(
                            PreservedString('migrated'),
                          ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.objectPayload,
                    sourceVersion: 1,
                    targetVersion: 2,
                    objectType: objectType,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      final target = AlnoteObjectMigrationTarget(
        objectType: objectType,
        objectId: sourceObject.id,
        sourceSchemaVersion: testSchemaVersion,
        targetSchemaVersion: schemaTwo,
      );
      final registry = testRegistry(<ObjectTypeDefinition>[
        TestObjectTypeDefinition(
          typeKey: objectType,
          supportedSchemaVersions: <SchemaVersion>[
            testSchemaVersion,
            schemaTwo,
          ],
        ),
      ]);
      expect(
        objectPlan.applyToPackage(
          sourceObject.payload,
          original: objectOriginal,
          buildCandidate: (_, _) =>
              Ok<AlnotePackageSnapshot, StructuredFailure>(objectCandidate),
          objectRegistry: registry,
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
          objectTarget: target,
        ),
        isA<Completed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );
      expect(
        objectPlan.applyToPackage(
          sourceObject.payload,
          original: objectOriginal,
          buildCandidate: (_, _) =>
              Ok<AlnotePackageSnapshot, StructuredFailure>(objectCandidate),
          objectRegistry: registry,
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
          objectTarget: AlnoteObjectMigrationTarget(
            objectType: testObjectTypeKey('example.wrong.object'),
            objectId: sourceObject.id,
            sourceSchemaVersion: testSchemaVersion,
            targetSchemaVersion: schemaTwo,
          ),
        ),
        isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );
      expect(objectPlan.objectType, objectType);
      expect(objectPlan.steps.single.objectType, objectType);
    });

    test('Object migration rejects handler mismatch and unrelated changes', () {
      final schemaTwo = _schemaVersion(2);
      final objectType = testObjectTypeKey();
      final original = _snapshot(document: _objectMigrationDocument());
      final target = AlnoteObjectMigrationTarget(
        objectType: objectType,
        objectId: ObjectId.fromUuid(testUuid(1)),
        sourceSchemaVersion: testSchemaVersion,
        targetSchemaVersion: schemaTwo,
      );
      final plan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.objectPayload,
                      sourceVersion: 1,
                      targetVersion: 2,
                      objectType: objectType,
                      handler: (_) =>
                          const Ok<PreservedData, StructuredFailure>(
                            PreservedString('migrated'),
                          ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.objectPayload,
                    sourceVersion: 1,
                    targetVersion: 2,
                    objectType: objectType,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      final registry = testRegistry(<ObjectTypeDefinition>[
        TestObjectTypeDefinition(
          typeKey: objectType,
          supportedSchemaVersions: <SchemaVersion>[
            testSchemaVersion,
            schemaTwo,
          ],
        ),
      ]);
      final changedSize = modelValue<Size2>(
        Size2.create(width: 601, height: 800),
      );
      final changedTransform =
          (AffineTransform2D.restoreFromStorage(<double>[1, 0, 0, 1, 1, 0])
                  as Ok<AffineTransform2D, StructuredFailure>)
              .value;
      final changedExtension = PreservedMap(<String, PreservedData>{
        'future': const PreservedString('changed'),
      });
      final candidates = <DocumentRoot>[
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('wrong-handler-output'),
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          nonTargetPayload: const PreservedString('changed-non-target'),
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          title: 'Changed title',
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          documentExtensionData: changedExtension,
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          pageName: 'Changed page',
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          pageSize: changedSize,
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          layerName: 'Changed layer',
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          targetTransform: changedTransform,
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          targetVisible: false,
        ),
        _objectMigrationDocument(
          targetSchemaVersion: schemaTwo,
          targetPayload: const PreservedString('migrated'),
          targetLocked: true,
        ),
      ];
      for (final document in candidates) {
        expect(
          plan.applyToPackage(
            const PreservedString('payload'),
            original: original,
            buildCandidate: (_, _) =>
                Ok<AlnotePackageSnapshot, StructuredFailure>(
                  _snapshot(document: document),
                ),
            objectRegistry: registry,
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
            objectTarget: target,
          ),
          isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
        );
      }
      expect(original.document, _objectMigrationDocument());
    });

    test('document-root migration cannot mutate descendant records', () {
      final schemaTwo = _schemaVersion(2);
      final original = _snapshot(document: _objectMigrationDocument());
      final changedChildren = <DocumentRoot>[
        _objectMigrationDocument(
          documentSchemaVersion: schemaTwo,
          pageName: 'Changed page',
        ),
        _objectMigrationDocument(
          documentSchemaVersion: schemaTwo,
          layerName: 'Changed layer',
        ),
        _objectMigrationDocument(
          documentSchemaVersion: schemaTwo,
          nonTargetPayload: const PreservedString('Changed object'),
        ),
      ];
      final migratedRoot = RecordEncoder().document(changedChildren.first);
      final plan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.documentRoot,
                      sourceVersion: 1,
                      targetVersion: 2,
                      handler: (_) =>
                          Ok<PreservedData, StructuredFailure>(migratedRoot),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.documentRoot,
                    sourceVersion: 1,
                    targetVersion: 2,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      for (final document in changedChildren) {
        expect(
          plan.applyToPackage(
            RecordEncoder().document(original.document),
            original: original,
            buildCandidate: (_, _) =>
                Ok<AlnotePackageSnapshot, StructuredFailure>(
                  _snapshot(document: document),
                ),
            objectRegistry: testRegistry(),
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          ),
          isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
        );
      }
    });

    test('package migration cannot mutate document content', () {
      final plan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.package,
                      sourceVersion: 1,
                      targetVersion: 2,
                      handler: (_) => Ok<PreservedData, StructuredFailure>(
                        _packageRecord(2),
                      ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.package,
                    sourceVersion: 1,
                    targetVersion: 2,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      final original = _snapshot();
      final candidate = _snapshot(
        version: _schemaPackageVersion(2),
        document: testNotebook(title: 'Unrelated document change'),
      );
      expect(
        plan.applyToPackage(
          _packageRecord(1),
          original: original,
          buildCandidate: (_, _) =>
              Ok<AlnotePackageSnapshot, StructuredFailure>(candidate),
          objectRegistry: testRegistry(),
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );
    });

    test('cancellation and preservation mismatch publish no candidate', () {
      final plan =
          (_registry(<AlnoteMigrationStep>[
                    AlnoteMigrationStep(
                      scope: AlnoteMigrationScope.package,
                      sourceVersion: 1,
                      targetVersion: 2,
                      handler: (_) => Ok<PreservedData, StructuredFailure>(
                        _packageRecord(2),
                      ),
                    ),
                  ]).plan(
                    scope: AlnoteMigrationScope.package,
                    sourceVersion: 1,
                    targetVersion: 2,
                  )
                  as Ok<AlnoteMigrationPlan, StructuredFailure>)
              .value;
      final preservation =
          (AlnotePackagePreservation.create(
                    optionalFeatures: const <String>['future_feature'],
                    entryCatalogFields: <String, PreservedMap>{
                      'mimetype': PreservedMap(<String, PreservedData>{
                        'future': const PreservedString('retained'),
                      }),
                    },
                  )
                  as Ok<AlnotePackagePreservation, StructuredFailure>)
              .value;
      final original =
          (AlnotePackageSnapshot.create(
                    document: testNotebook(),
                    resources: const <DocumentResourceSnapshot>[],
                    preservation: preservation,
                  )
                  as Ok<AlnotePackageSnapshot, StructuredFailure>)
              .value;
      final wrongPreservation = _snapshot(version: _schemaPackageVersion(2));
      expect(
        plan.applyToPackage(
          _packageRecord(1),
          original: original,
          buildCandidate: (_, _) =>
              Ok<AlnotePackageSnapshot, StructuredFailure>(wrongPreservation),
          objectRegistry: testRegistry(),
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );

      final changedNestedPreservation =
          (AlnotePackagePreservation.create(
                    optionalFeatures: const <String>['future_feature'],
                    entryCatalogFields: <String, PreservedMap>{
                      'mimetype': PreservedMap(<String, PreservedData>{
                        'future': const PreservedString('changed'),
                      }),
                    },
                  )
                  as Ok<AlnotePackagePreservation, StructuredFailure>)
              .value;
      final changedNestedCandidate =
          (AlnotePackageSnapshot.create(
                    version: _schemaPackageVersion(2),
                    document: original.document,
                    resources: original.resources,
                    preservation: changedNestedPreservation,
                  )
                  as Ok<AlnotePackageSnapshot, StructuredFailure>)
              .value;
      expect(
        plan.applyToPackage(
          _packageRecord(1),
          original: original,
          buildCandidate: (_, _) =>
              Ok<AlnotePackageSnapshot, StructuredFailure>(
                changedNestedCandidate,
              ),
          objectRegistry: testRegistry(),
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<AlnotePackageMigrationResult, StructuredFailure>>(),
      );

      var built = false;
      final controller = CancellationController()..cancel('cancelled');
      final cancelled = plan.applyToPackage(
        _packageRecord(1),
        original: original,
        buildCandidate: (_, _) {
          built = true;
          return Ok<AlnotePackageSnapshot, StructuredFailure>(
            wrongPreservation,
          );
        },
        objectRegistry: testRegistry(),
        limits: phase4Limits(),
        cancellationToken: controller.token,
      );
      expect(
        cancelled,
        isA<Cancelled<AlnotePackageMigrationResult, StructuredFailure>>(),
      );
      expect(built, isFalse);
    });
  });

  group('complete replacement Save', () {
    test(
      'validates staged output then commits one complete generation',
      () async {
        var captures = 0;
        final snapshot = _snapshot();
        final registry = testRegistry();
        final destination = InMemoryReplacementDestination(
          generation: const <int>[9, 9],
        );
        final outcome =
            await AlnoteSaveCoordinator(
              captureSnapshot: () {
                captures += 1;
                return snapshot;
              },
              codec: AlnotePackageCodec(objectRegistry: registry),
              reader: AlnotePackageReader(objectRegistry: registry),
            ).save(
              destination: destination,
              expectedFingerprint: null,
              limits: phase4Limits(),
              cancellationToken: CancellationController().token,
            );

        expect(
          outcome,
          isA<Completed<AlnoteSaveEvidence, StructuredFailure>>(),
        );
        expect(captures, 1);
        expect(destination.committed, isTrue);
        expect(destination.aborted, isFalse);
        expect(destination.generation, isNot(<int>[9, 9]));
        final evidence =
            (outcome as Completed<AlnoteSaveEvidence, StructuredFailure>).value;
        expect(evidence.flush.flushed, isTrue);
        expect(evidence.flush.durable, isTrue);
        expect(evidence.replacement.atomic, isTrue);
      },
    );

    for (final fault in ReplacementFault.values.where(
      (value) => value != ReplacementFault.none,
    )) {
      test(
        '${fault.name} retains prior generation and cleans staging',
        () async {
          final destination = InMemoryReplacementDestination(
            generation: const <int>[7, 7, 7],
            fault: fault,
          );
          final outcome = await _coordinator().save(
            destination: destination,
            expectedFingerprint: null,
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          );

          expect(outcome, isA<Failed<AlnoteSaveEvidence, StructuredFailure>>());
          expect(destination.generation, <int>[7, 7, 7]);
          expect(destination.committed, isFalse);
          expect(destination.aborted, isTrue);
        },
      );
    }

    test('fingerprint conflict forbids blind overwrite', () async {
      final destination = InMemoryReplacementDestination(
        generation: const <int>[6],
        reportedFingerprint: const PackageFingerprint(byteLength: 1),
      );
      final outcome = await _coordinator().save(
        destination: destination,
        expectedFingerprint: const PackageFingerprint(byteLength: 2),
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<Failed<AlnoteSaveEvidence, StructuredFailure>>());
      expect(destination.generation, <int>[6]);
      expect(destination.aborted, isTrue);
    });

    test('conditional commit rejects a change after the precheck', () async {
      const expected = PackageFingerprint(byteLength: 1);
      final destination = InMemoryReplacementDestination(
        generation: const <int>[6],
        reportedFingerprint: expected,
        beforeConditionalCommit: (destination) {
          destination.reportedFingerprint = const PackageFingerprint(
            byteLength: 2,
          );
        },
      );
      final outcome = await _coordinator().save(
        destination: destination,
        expectedFingerprint: expected,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<Failed<AlnoteSaveEvidence, StructuredFailure>>());
      expect(destination.generation, <int>[6]);
      expect(destination.committed, isFalse);
      expect(destination.aborted, isTrue);
    });

    test('conditional Save As rejects a destination that appears', () async {
      final destination = InMemoryReplacementDestination(
        generation: const <int>[4],
        beforeConditionalCommit: (destination) {
          destination.reportedFingerprint = const PackageFingerprint(
            byteLength: 4,
          );
        },
      );
      final outcome = await _coordinator().save(
        destination: destination,
        expectedFingerprint: null,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<Failed<AlnoteSaveEvidence, StructuredFailure>>());
      expect(destination.generation, <int>[4]);
      expect(destination.committed, isFalse);
    });

    test(
      'cancellation after successful publication remains completed',
      () async {
        final controller = CancellationController();
        final destination = InMemoryReplacementDestination(
          afterSuccessfulCommit: (_) => controller.cancel('late-secret'),
        );
        final outcome = await _coordinator().save(
          destination: destination,
          expectedFingerprint: null,
          limits: phase4Limits(),
          cancellationToken: controller.token,
        );
        expect(
          outcome,
          isA<Completed<AlnoteSaveEvidence, StructuredFailure>>(),
        );
        expect(destination.committed, isTrue);
      },
    );

    test('snapshot capture exceptions are coordinator-redacted', () async {
      const secret = 'snapshot-secret';
      final registry = testRegistry();
      final outcome =
          await AlnoteSaveCoordinator(
            captureSnapshot: () => throw StateError(secret),
            codec: AlnotePackageCodec(objectRegistry: registry),
            reader: AlnotePackageReader(objectRegistry: registry),
          ).save(
            destination: InMemoryReplacementDestination(),
            expectedFingerprint: null,
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          );
      expect(outcome, isA<Failed<AlnoteSaveEvidence, StructuredFailure>>());
      expect(outcome.toString(), isNot(contains(secret)));
    });

    for (final boundary in <SaveAdapterBoundary>[
      SaveAdapterBoundary.beginStaging,
      SaveAdapterBoundary.write,
      SaveAdapterBoundary.flush,
      SaveAdapterBoundary.readBack,
      SaveAdapterBoundary.fingerprint,
      SaveAdapterBoundary.commit,
    ]) {
      for (final throws in <bool>[false, true]) {
        test(
          '${boundary.name} ${throws ? 'exception' : 'failure'} is contained and redacted',
          () async {
            const secret = 'destination-adapter-secret';
            final destination = InMemoryReplacementDestination(
              generation: const <int>[8],
              hostile: secret,
              failAt: throws ? null : boundary,
              throwAt: throws ? boundary : null,
            );
            final outcome = await _coordinator().save(
              destination: destination,
              expectedFingerprint: null,
              limits: phase4Limits(),
              cancellationToken: CancellationController().token,
            );
            expect(
              outcome,
              isA<Failed<AlnoteSaveEvidence, StructuredFailure>>(),
            );
            expect(outcome.toString(), isNot(contains(secret)));
            expect(destination.generation, <int>[8]);
          },
        );
      }
    }

    test(
      'flush getter and false flush evidence fail before publication',
      () async {
        for (final destination in <InMemoryReplacementDestination>[
          InMemoryReplacementDestination(
            generation: const <int>[3],
            throwAt: SaveAdapterBoundary.supportsFlush,
          ),
          InMemoryReplacementDestination(
            generation: const <int>[3],
            flushEvidenceFlushed: false,
          ),
        ]) {
          final outcome = await _coordinator().save(
            destination: destination,
            expectedFingerprint: null,
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          );
          expect(outcome, isA<Failed<AlnoteSaveEvidence, StructuredFailure>>());
          expect(destination.generation, <int>[3]);
          expect(destination.aborted, isTrue);
        }
      },
    );

    test(
      'abort failure and exception never override the primary failure',
      () async {
        const secret = 'abort-secret';
        for (final throws in <bool>[false, true]) {
          final destination = InMemoryReplacementDestination(
            generation: const <int>[2],
            fault: ReplacementFault.shortWrite,
            hostile: secret,
            failAt: throws ? null : SaveAdapterBoundary.abort,
            throwAt: throws ? SaveAdapterBoundary.abort : null,
          );
          final outcome = await _coordinator().save(
            destination: destination,
            expectedFingerprint: null,
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          );
          final failure =
              outcome as Failed<AlnoteSaveEvidence, StructuredFailure>;
          expect(failure.failure.code, 'documents.save.short_write');
          expect(failure.toString(), isNot(contains(secret)));
          expect(destination.generation, <int>[2]);
        }
      },
    );

    test('oversized staged read-back is bounded and rejected', () async {
      final destination = InMemoryReplacementDestination(
        generation: const <int>[1],
        oversizedReadBack: true,
      );
      final outcome = await _coordinator().save(
        destination: destination,
        expectedFingerprint: null,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<Failed<AlnoteSaveEvidence, StructuredFailure>>());
      expect(destination.generation, <int>[1]);
      expect(destination.aborted, isTrue);
    });

    test('mutable staged read-back is copied before validation', () async {
      final destination = InMemoryReplacementDestination(
        returnMutableReadBack: true,
      );
      final outcome = await _coordinator().save(
        destination: destination,
        expectedFingerprint: null,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<Completed<AlnoteSaveEvidence, StructuredFailure>>());
      final committed = List<int>.of(destination.generation);
      destination.lastReadBack![0] ^= 1;
      expect(destination.generation, committed);
    });

    test('cancellation is separate and never stages publication', () async {
      final controller = CancellationController()..cancel('test');
      final destination = InMemoryReplacementDestination(
        generation: const <int>[5],
      );
      final outcome = await _coordinator().save(
        destination: destination,
        expectedFingerprint: null,
        limits: phase4Limits(),
        cancellationToken: controller.token,
      );
      expect(outcome, isA<Cancelled<AlnoteSaveEvidence, StructuredFailure>>());
      expect(destination.generation, <int>[5]);
      expect(destination.committed, isFalse);
    });

    test('never overstates flush or durability evidence', () async {
      final destination = InMemoryReplacementDestination(
        flushSupported: false,
        durable: false,
        atomic: false,
      );
      final outcome =
          await _coordinator().save(
                destination: destination,
                expectedFingerprint: null,
                limits: phase4Limits(),
                cancellationToken: CancellationController().token,
              )
              as Completed<AlnoteSaveEvidence, StructuredFailure>;
      expect(outcome.value.flush.flushed, isFalse);
      expect(outcome.value.flush.durable, isFalse);
      expect(outcome.value.replacement.atomic, isFalse);
      expect(outcome.value.replacement.durable, isFalse);
    });
  });
}

AlnoteMigrationRegistry _registry(Iterable<AlnoteMigrationStep> steps) =>
    (AlnoteMigrationRegistry.create(steps)
            as Ok<AlnoteMigrationRegistry, StructuredFailure>)
        .value;

PreservedMap _replaceVersion(PreservedData source, int version) {
  final map = source as PreservedMap;
  return PreservedMap(<String, PreservedData>{
    ...map.values,
    'version': _integer(version),
  });
}

PreservedInteger _integer(int value) =>
    (PreservedInteger.create(value) as Ok<PreservedInteger, StructuredFailure>)
        .value;

AlnotePackageSnapshot _snapshot({
  DocumentRoot? document,
  AlnotePackageVersion version = AlnotePackageVersion.version1,
}) =>
    (AlnotePackageSnapshot.create(
              version: version,
              document: document ?? testNotebook(),
              resources: const <DocumentResourceSnapshot>[],
            )
            as Ok<AlnotePackageSnapshot, StructuredFailure>)
        .value;

AlnotePackageVersion _schemaPackageVersion(int value) =>
    (AlnotePackageVersion.create(value)
            as Ok<AlnotePackageVersion, StructuredFailure>)
        .value;

SchemaVersion _schemaVersion(int value) =>
    (SchemaVersion.create(value) as Ok<SchemaVersion, StructuredFailure>).value;

NotebookDocument _objectMigrationDocument({
  SchemaVersion? documentSchemaVersion,
  SchemaVersion? targetSchemaVersion,
  PreservedData targetPayload = const PreservedString('payload'),
  PreservedData nonTargetPayload = const PreservedString('other-payload'),
  String title = 'Notebook',
  PreservedMap? documentExtensionData,
  String pageName = 'Page',
  Size2? pageSize,
  String layerName = 'Layer',
  AffineTransform2D? targetTransform,
  bool targetVisible = true,
  bool targetLocked = false,
}) {
  final target = testObject(
    schemaVersion: targetSchemaVersion,
    payload: targetPayload,
    transform: targetTransform,
    visible: targetVisible,
    locked: targetLocked,
  );
  final nonTarget = testObject(id: 2, payload: nonTargetPayload);
  final layer = testContentLayer(
    name: layerName,
    objects: <ObjectEnvelope>[target, nonTarget],
  );
  final page = modelValue<DocumentPage>(
    DocumentPage.create(
      id: PageId.fromUuid(testUuid(20)),
      name: pageName,
      size: pageSize ?? testPageSize,
      layers: <DocumentLayer>[layer],
      extensionData: PreservedMap.empty(),
    ),
  );
  final section = testSection(pages: <DocumentPage>[page]);
  return modelValue<NotebookDocument>(
    NotebookDocument.create(
      id: DocumentId.fromUuid(testUuid(40)),
      schemaVersion: documentSchemaVersion ?? testSchemaVersion,
      title: title,
      resources: emptyResourceCatalog(),
      extensionData: documentExtensionData ?? PreservedMap.empty(),
      sections: <DocumentSection>[section],
    ),
  );
}

PreservedMap _packageRecord(int version) =>
    PreservedMap(<String, PreservedData>{'packageVersion': _integer(version)});

AlnoteSaveCoordinator _coordinator() {
  final registry = testRegistry();
  return AlnoteSaveCoordinator(
    captureSnapshot: _snapshot,
    codec: AlnotePackageCodec(objectRegistry: registry),
    reader: AlnotePackageReader(objectRegistry: registry),
  );
}
