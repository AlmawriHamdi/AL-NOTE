// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/uuid_sequence_generator.dart';

void main() {
  group('immutable replacement', () {
    late DocumentReplacement replacement;

    setUp(() {
      replacement = DocumentReplacement(DocumentValidator(testRegistry()));
    });

    test('replaces Object and retains unaffected Object identity', () {
      final target = testObject(id: 300);
      final unaffected = testObject(id: 301);
      final layer = testContentLayer(
        objects: <ObjectEnvelope>[target, unaffected],
      );
      final changed = testObject(
        id: 300,
        payload: const PreservedString('changed'),
      );
      final result = modelValue<DocumentLayer>(
        replacement.replaceObjectInLayer(
          layer: layer,
          targetId: target.id,
          replacement: changed,
        ),
      );

      expect(result.objects, <ObjectEnvelope>[changed, unaffected]);
      expect(result.objects[1], same(unaffected));
      expect(layer.objects, <ObjectEnvelope>[target, unaffected]);
    });

    test('replaces Layer, Page, and Section atomically', () {
      final layer = testContentLayer(id: 310);
      final page = testPage(id: 311, layers: <DocumentLayer>[layer]);
      final section = testSection(id: 312, pages: <DocumentPage>[page]);
      final notebook = testNotebook(
        id: 313,
        sections: <DocumentSection>[section],
      );
      final changedLayer = testContentLayer(id: 310, visible: false);
      final changedPage = modelValue<DocumentPage>(
        replacement.replaceLayerInPage(
          page: page,
          targetId: layer.id,
          replacement: changedLayer,
        ),
      );
      final changedSection = modelValue<DocumentSection>(
        replacement.replacePageInSection(
          section: section,
          targetId: page.id,
          replacement: changedPage,
        ),
      );
      final changedRoot = modelValue<NotebookDocument>(
        replacement.replaceSectionInNotebook(
          notebook: notebook,
          targetId: section.id,
          replacement: changedSection,
        ),
      );

      expect(
        changedRoot.sections.single.pages.single.layers.single.visible,
        isFalse,
      );
      expect(
        notebook.sections.single.pages.single.layers.single.visible,
        isTrue,
      );
    });

    test('replaces Page in all three root forms', () {
      final page = testPage(id: 320);
      final changed = testPage(
        id: 320,
        name: 'changed',
        layers: <DocumentLayer>[testContentLayer(id: 321)],
      );
      final pageRoot = modelValue<StandalonePageDocument>(
        StandalonePageDocument.create(
          id: DocumentId.fromUuid(testUuid(322)),
          schemaVersion: testSchemaVersion,
          title: 'private',
          resources: emptyResourceCatalog(),
          extensionData: PreservedMap.empty(),
          page: page,
        ),
      );
      final resource = ResourceIdentity.fromUuid(testUuid(323));
      final pdfRoot = modelValue<StandalonePdfDocument>(
        StandalonePdfDocument.create(
          id: DocumentId.fromUuid(testUuid(324)),
          schemaVersion: testSchemaVersion,
          title: 'private',
          resources: modelValue<ResourceCatalog>(
            ResourceCatalog.create(<ResourceCatalogEntry>[
              ResourceCatalogEntry(resource),
            ]),
          ),
          extensionData: PreservedMap.empty(),
          pages: <DocumentPage>[page],
          source: ResourceReference(resource),
        ),
      );
      final notebook = testNotebook(
        id: 325,
        sections: <DocumentSection>[
          testSection(id: 326, pages: <DocumentPage>[page]),
        ],
      );

      for (final root in <DocumentRoot>[pageRoot, pdfRoot, notebook]) {
        final result = modelValue<DocumentRoot>(
          replacement.replacePageInRoot(
            root: root,
            targetId: page.id,
            replacement: changed,
          ),
        );
        expect(result.pages.single, changed);
      }
    });

    test('rejects missing targets and identity mismatches without changes', () {
      final layer = testContentLayer(objects: <ObjectEnvelope>[testObject()]);
      final originalObjects = layer.objects;

      expect(
        replacement.replaceObjectInLayer(
          layer: layer,
          targetId: ObjectId.fromUuid(testUuid(330)),
          replacement: testObject(id: 330),
        ),
        isA<Err<DocumentLayer, StructuredFailure>>(),
      );
      expect(
        replacement.replaceObjectInLayer(
          layer: layer,
          targetId: layer.objects.single.id,
          replacement: testObject(id: 331),
        ),
        isA<Err<DocumentLayer, StructuredFailure>>(),
      );
      expect(layer.objects, same(originalObjects));
    });

    test('rejects known-invalid payload replacement candidates', () {
      final source = testObject(id: 335);
      final layer = testContentLayer(objects: <ObjectEnvelope>[source]);
      final invalid = testObject(
        id: 335,
        payload: const PreservedString('invalid'),
      );

      expect(
        replacement.replaceObjectInLayer(
          layer: layer,
          targetId: source.id,
          replacement: invalid,
        ),
        isA<Err<DocumentLayer, StructuredFailure>>(),
      );
      expect(layer.objects.single, same(source));
    });

    test('rejects a Layer replacement that removes final content role', () {
      final content = testContentLayer(id: 340);
      final page = testPage(layers: <DocumentLayer>[content]);
      final sourceRole = testUnknownLayer(
        id: 340,
        role: LayerCoreRole.backgroundSource,
      );

      expect(
        replacement.replaceLayerInPage(
          page: page,
          targetId: content.id,
          replacement: sourceRole,
        ),
        isA<Err<DocumentPage, StructuredFailure>>(),
      );
      expect(page.layers.single, same(content));
    });

    test(
      'complete root replacement retains Document identity and validates',
      () {
        final current = testNotebook(id: 350);
        final candidate = testNotebook(id: 350, title: 'new title');
        expect(
          modelValue<DocumentRoot>(
            replacement.replaceDocumentRoot(
              current: current,
              replacement: candidate,
            ),
          ),
          candidate,
        );
        expect(
          replacement.replaceDocumentRoot(
            current: current,
            replacement: testNotebook(id: 351),
          ),
          isA<Err<DocumentRoot, StructuredFailure>>(),
        );
      },
    );
  });

  group('safe deterministic duplication', () {
    test('identity scope defensively copies typed collections', () {
      final objectIds = <ObjectId>[ObjectId.fromUuid(testUuid(380))];
      final scope = DocumentIdentityScope(objectIds: objectIds);
      objectIds.clear();

      expect(scope.objectIds, <ObjectId>{ObjectId.fromUuid(testUuid(380))});
      expect(scope.objectIds.clear, throwsUnsupportedError);
    });

    test('Object duplication rejects its source identity', () {
      final source = testObject(id: 381);
      final result = DocumentDuplicator(
        uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
          source.id.uuid,
        ]),
        objectRegistry: testRegistry(),
      ).duplicateObject(source, destinationScope: DocumentIdentityScope());

      expect(result, isA<Err<ObjectEnvelope, StructuredFailure>>());
      expect(
        (result as Err<ObjectEnvelope, StructuredFailure>).error.code,
        'documents.duplication.identity_collision',
      );
      expect(source.id, ObjectId.fromUuid(testUuid(381)));
    });

    test('Layer duplication rejects repeated generated Object identities', () {
      final first = testObject(id: 382);
      final second = testObject(id: 383);
      final source = testContentLayer(
        id: 384,
        objects: <ObjectEnvelope>[first, second],
      );
      final repeated = testUuid(386);
      final result = DocumentDuplicator(
        uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
          testUuid(385),
          repeated,
          repeated,
        ]),
        objectRegistry: testRegistry(),
      ).duplicateLayer(source, destinationScope: DocumentIdentityScope());

      expect(result, isA<Err<DocumentLayer, StructuredFailure>>());
      expect(
        (result as Err<DocumentLayer, StructuredFailure>).error.code,
        'documents.duplication.identity_collision',
      );
      expect(source.objects, <ObjectEnvelope>[first, second]);
    });

    test('generated identity cannot collide with destination document', () {
      final source = testObject(id: 387);
      final existing = testObject(id: 388);
      final destination = testNotebook(
        id: 389,
        sections: <DocumentSection>[
          testSection(
            id: 390,
            pages: <DocumentPage>[
              testPage(
                id: 391,
                layers: <DocumentLayer>[
                  testContentLayer(
                    id: 392,
                    objects: <ObjectEnvelope>[source, existing],
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final result =
          DocumentDuplicator(
            uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
              existing.id.uuid,
            ]),
            objectRegistry: testRegistry(),
          ).duplicateObject(
            source,
            destinationScope: DocumentIdentityScope.fromDocument(destination),
          );

      expect(result, isA<Err<ObjectEnvelope, StructuredFailure>>());
      expect(
        (result as Err<ObjectEnvelope, StructuredFailure>).error.code,
        'documents.duplication.identity_collision',
      );
      expect(destination.pages.single.layers.single.objects, <ObjectEnvelope>[
        source,
        existing,
      ]);
    });

    test('whole-document duplication rejects the source Document ID', () {
      final source = testNotebook(id: 393);
      final result = DocumentDuplicator(
        uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
          source.id.uuid,
        ]),
        objectRegistry: testRegistry(),
      ).duplicateDocument(source);

      expect(result, isA<Err<DocumentRoot, StructuredFailure>>());
      expect(
        (result as Err<DocumentRoot, StructuredFailure>).error.code,
        'documents.duplication.identity_collision',
      );
      expect(source.id, DocumentId.fromUuid(testUuid(393)));
    });

    test('complete destination scope permits fresh deterministic IDs', () {
      final first = testObject(id: 394);
      final second = testObject(id: 395);
      final source = testContentLayer(
        id: 396,
        objects: <ObjectEnvelope>[first, second],
      );
      final destination = testNotebook(
        id: 397,
        sections: <DocumentSection>[
          testSection(
            id: 398,
            pages: <DocumentPage>[
              testPage(id: 399, layers: <DocumentLayer>[source]),
            ],
          ),
        ],
      );
      final result = modelValue<DocumentLayer>(
        DocumentDuplicator(
          uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
            testUuid(600),
            testUuid(601),
            testUuid(602),
          ]),
          objectRegistry: testRegistry(),
        ).duplicateLayer(
          source,
          destinationScope: DocumentIdentityScope.fromDocument(destination),
        ),
      );

      expect(result.id, LayerId.fromUuid(testUuid(600)));
      expect(result.objects.map((object) => object.id), <ObjectId>[
        ObjectId.fromUuid(testUuid(601)),
        ObjectId.fromUuid(testUuid(602)),
      ]);
      expect(source.objects, <ObjectEnvelope>[first, second]);
    });

    test('Object duplication allocates a new deterministic identity', () {
      final generator = UuidSequenceGenerator.fromValues(<UuidIdentifier>[
        testUuid(400),
      ]);
      final duplicator = DocumentDuplicator(
        uuidGenerator: generator,
        objectRegistry: testRegistry(),
      );
      final source = testObject(id: 401);
      final result = modelValue<ObjectEnvelope>(
        duplicator.duplicateObject(
          source,
          destinationScope: DocumentIdentityScope(),
        ),
      );

      expect(result.id, ObjectId.fromUuid(testUuid(400)));
      expect(result.payload, source.payload);
      expect(source.id, ObjectId.fromUuid(testUuid(401)));
    });

    test('Layer duplication remaps all Object IDs in relative order', () {
      final first = testObject(id: 410);
      final second = testObject(id: 411);
      final definition = TestObjectTypeDefinition(referencedObjectId: first.id);
      final generator = UuidSequenceGenerator.fromValues(<UuidIdentifier>[
        testUuid(412),
        testUuid(413),
        testUuid(414),
      ]);
      final duplicator = DocumentDuplicator(
        uuidGenerator: generator,
        objectRegistry: testRegistry(<ObjectTypeDefinition>[definition]),
      );
      final result = modelValue<DocumentLayer>(
        duplicator.duplicateLayer(
          testContentLayer(id: 415, objects: <ObjectEnvelope>[first, second]),
          destinationScope: DocumentIdentityScope(),
        ),
      );

      expect(result.id, LayerId.fromUuid(testUuid(412)));
      expect(result.objects.map((object) => object.id), <ObjectId>[
        ObjectId.fromUuid(testUuid(413)),
        ObjectId.fromUuid(testUuid(414)),
      ]);
      for (final object in result.objects) {
        expect(object.payload, PreservedString(testUuid(413).value));
      }
    });

    test('Page and Section duplication allocate depth-first stable IDs', () {
      final source = testSection(
        id: 420,
        pages: <DocumentPage>[
          testPage(
            id: 421,
            layers: <DocumentLayer>[
              testContentLayer(
                id: 422,
                objects: <ObjectEnvelope>[testObject(id: 423)],
              ),
            ],
          ),
        ],
      );
      final generator = UuidSequenceGenerator.fromValues(<UuidIdentifier>[
        testUuid(424),
        testUuid(425),
        testUuid(426),
        testUuid(427),
      ]);
      final duplicated = modelValue<DocumentSection>(
        DocumentDuplicator(
          uuidGenerator: generator,
          objectRegistry: testRegistry(),
        ).duplicateSection(source, destinationScope: DocumentIdentityScope()),
      );

      expect(duplicated.id, SectionId.fromUuid(testUuid(424)));
      expect(duplicated.pages.single.id, PageId.fromUuid(testUuid(425)));
      expect(
        duplicated.pages.single.layers.single.id,
        LayerId.fromUuid(testUuid(426)),
      );
      expect(
        duplicated.pages.single.layers.single.objects.single.id,
        ObjectId.fromUuid(testUuid(427)),
      );
      expect(source.id, SectionId.fromUuid(testUuid(420)));
    });

    test(
      'unknown scoped payload and unknown Layer duplication fail closed',
      () {
        final generator = UuidSequenceGenerator.fromValues(<UuidIdentifier>[
          testUuid(430),
          testUuid(431),
        ]);
        final duplicator = DocumentDuplicator(
          uuidGenerator: generator,
          objectRegistry: testRegistry(),
        );
        final unknownObject = testObject(
          typeKey: testObjectTypeKey('example.unknown.object'),
        );
        final unknownLayer = testUnknownLayer(
          objects: <ObjectEnvelope>[unknownObject],
        );

        expect(
          duplicator.duplicateObject(
            unknownObject,
            destinationScope: DocumentIdentityScope(),
          ),
          isA<Err<ObjectEnvelope, StructuredFailure>>(),
        );
        expect(
          duplicator.duplicateLayer(
            unknownLayer,
            destinationScope: DocumentIdentityScope(),
          ),
          isA<Err<DocumentLayer, StructuredFailure>>(),
        );
        expect(unknownLayer.objects.single, same(unknownObject));
      },
    );

    test('handler and UUID failures return no partial duplicate', () {
      final source = testObject(id: 440);
      final handlerFailure = DocumentDuplicator(
        uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
          testUuid(441),
        ]),
        objectRegistry: testRegistry(<ObjectTypeDefinition>[
          TestObjectTypeDefinition(failDuplication: true),
        ]),
      );
      final generatorFailure = DocumentDuplicator(
        uuidGenerator: UuidSequenceGenerator(const []),
        objectRegistry: testRegistry(),
      );

      expect(
        handlerFailure.duplicateObject(
          source,
          destinationScope: DocumentIdentityScope(),
        ),
        isA<Err<ObjectEnvelope, StructuredFailure>>(),
      );
      expect(
        generatorFailure.duplicateObject(
          source,
          destinationScope: DocumentIdentityScope(),
        ),
        isA<Err<ObjectEnvelope, StructuredFailure>>(),
      );
      expect(source.id, ObjectId.fromUuid(testUuid(440)));
    });

    test(
      'whole-document copy changes only Document ID and shares resources',
      () {
        final resourceId = ResourceIdentity.fromUuid(testUuid(450));
        final catalog = modelValue<ResourceCatalog>(
          ResourceCatalog.create(<ResourceCatalogEntry>[
            ResourceCatalogEntry(resourceId),
          ]),
        );
        final unknown = testObject(
          typeKey: testObjectTypeKey('example.unknown.object'),
        );
        final source = testNotebook(
          id: 451,
          resources: catalog,
          sections: <DocumentSection>[
            testSection(
              pages: <DocumentPage>[
                testPage(
                  layers: <DocumentLayer>[
                    testUnknownLayer(objects: <ObjectEnvelope>[unknown]),
                  ],
                ),
              ],
            ),
          ],
        );
        final copy =
            modelValue<DocumentRoot>(
                  DocumentDuplicator(
                    uuidGenerator: UuidSequenceGenerator.fromValues(
                      <UuidIdentifier>[testUuid(452)],
                    ),
                    objectRegistry: testRegistry(),
                  ).duplicateDocument(source),
                )
                as NotebookDocument;

        expect(copy.id, DocumentId.fromUuid(testUuid(452)));
        expect(copy.sections, source.sections);
        expect(copy.sections.single, same(source.sections.single));
        expect(copy.resources, same(source.resources));
        expect(copy.resources.contains(resourceId), isTrue);
        expect(
          copy.sections.single.pages.single.layers.single.objects.single,
          unknown,
        );
      },
    );
  });
}
