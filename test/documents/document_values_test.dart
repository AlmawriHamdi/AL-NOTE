// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/uuid_sequence_generator.dart';

void main() {
  group('identities and preserved data', () {
    test('identity types are distinct and use injected generation', () {
      final uuid = testUuid(100);
      final values = <Object>{
        DocumentId.fromUuid(uuid),
        SectionId.fromUuid(uuid),
        PageId.fromUuid(uuid),
        LayerId.fromUuid(uuid),
        ObjectId.fromUuid(uuid),
        ResourceIdentity.fromUuid(uuid),
      };
      expect(values, hasLength(6));

      final generator = UuidSequenceGenerator.fromValues(<UuidIdentifier>[
        testUuid(101),
        testUuid(102),
      ]);
      expect(
        modelValue<DocumentId>(DocumentId.generate(generator)).uuid,
        testUuid(101),
      );
      expect(
        modelValue<ObjectId>(ObjectId.generate(generator)).uuid,
        testUuid(102),
      );
      expect(generator.remaining, 0);
    });

    test('preserved numeric factories fail structurally at unsafe bounds', () {
      expect(
        PreservedInteger.create(maximumWebSafeInteger),
        isA<Ok<PreservedInteger, StructuredFailure>>(),
      );
      expect(
        PreservedInteger.create(maximumWebSafeInteger + 1),
        isA<Err<PreservedInteger, StructuredFailure>>(),
      );
      for (final value in <double>[double.nan, double.infinity]) {
        expect(
          PreservedDouble.create(value),
          isA<Err<PreservedDouble, StructuredFailure>>(),
        );
      }
    });

    test('preserved collections are deep immutable and deterministic', () {
      final nestedSource = <PreservedData>[const PreservedString('secret')];
      final nested = PreservedList(nestedSource);
      final mapSource = <String, PreservedData>{'z': nested, 'a': nested};
      final first = PreservedMap(mapSource);
      final second = PreservedMap(<String, PreservedData>{
        'a': PreservedList(<PreservedData>[const PreservedString('secret')]),
        'z': PreservedList(<PreservedData>[const PreservedString('secret')]),
      });
      nestedSource.clear();
      mapSource.clear();

      expect(first.values.keys, <String>['a', 'z']);
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.values.clear, throwsUnsupportedError);
      expect(nested.values.clear, throwsUnsupportedError);
      expect(first.toString(), isNot(contains('secret')));
      expect(nested.toString(), isNot(contains('secret')));
    });
  });

  group('Object, Layer, and Page values', () {
    test('Object envelope has value equality without payload diagnostics', () {
      final first = testObject(payload: const PreservedString('private'));
      final second = testObject(payload: const PreservedString('private'));

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.toString(), isNot(contains('private')));
    });

    test('Layer defensively copies objects and computes effective state', () {
      final object = testObject();
      final source = <ObjectEnvelope>[object];
      final layer = testContentLayer(
        visible: false,
        locked: true,
        objects: source,
      );
      source.clear();

      expect(layer.objects, <ObjectEnvelope>[object]);
      expect(layer.objects.clear, throwsUnsupportedError);
      expect(layer.isObjectEffectivelyVisible(object), isFalse);
      expect(layer.isObjectEffectivelyLocked(object), isTrue);
    });

    test('Layer opacity accepts boundaries and rejects invalid values', () {
      for (final opacity in <double>[0, 1]) {
        expect(
          ContentLayer.create(
            id: LayerId.fromUuid(testUuid(110 + opacity.toInt())),
            envelopeVersion: testSchemaVersion,
            typeSchemaVersion: testSchemaVersion,
            name: 'private',
            visible: true,
            locked: false,
            opacity: opacity,
            objects: const <ObjectEnvelope>[],
            typeData: PreservedMap.empty(),
            extensionData: PreservedMap.empty(),
          ),
          isA<Ok<ContentLayer, StructuredFailure>>(),
        );
      }
      for (final opacity in <double>[-0.1, 1.1, double.nan]) {
        expect(
          ContentLayer.create(
            id: LayerId.fromUuid(testUuid(115)),
            envelopeVersion: testSchemaVersion,
            typeSchemaVersion: testSchemaVersion,
            name: 'private',
            visible: true,
            locked: false,
            opacity: opacity,
            objects: const <ObjectEnvelope>[],
            typeData: PreservedMap.empty(),
            extensionData: PreservedMap.empty(),
          ),
          isA<Err<ContentLayer, StructuredFailure>>(),
        );
      }
    });

    test('Page enforces minimum content and canonical source ordering', () {
      final background = testUnknownLayer(
        id: 120,
        role: LayerCoreRole.backgroundSource,
      );
      final pdf = testUnknownLayer(id: 121, role: LayerCoreRole.pdfSource);
      final content = testContentLayer(id: 122);

      expect(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(123)),
          name: 'private',
          size: testPageSize,
          layers: <DocumentLayer>[background, pdf, content],
          extensionData: PreservedMap.empty(),
        ),
        isA<Ok<DocumentPage, StructuredFailure>>(),
      );
      expect(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(124)),
          name: 'private',
          size: testPageSize,
          layers: <DocumentLayer>[content, background],
          extensionData: PreservedMap.empty(),
        ),
        isA<Err<DocumentPage, StructuredFailure>>(),
      );
      expect(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(125)),
          name: 'private',
          size: testPageSize,
          layers: <DocumentLayer>[background],
          extensionData: PreservedMap.empty(),
        ),
        isA<Err<DocumentPage, StructuredFailure>>(),
      );
      expect(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(126)),
          name: 'private',
          size: testPageSize,
          layers: <DocumentLayer>[
            background,
            testUnknownLayer(id: 127, role: LayerCoreRole.backgroundSource),
            content,
          ],
          extensionData: PreservedMap.empty(),
        ),
        isA<Err<DocumentPage, StructuredFailure>>(),
      );
    });

    test('Page rejects duplicate Layer and Object identities', () {
      final object = testObject(id: 130);
      final first = testContentLayer(
        id: 131,
        objects: <ObjectEnvelope>[object],
      );
      final duplicateObjectLayer = testContentLayer(
        id: 132,
        objects: <ObjectEnvelope>[object],
      );

      expect(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(133)),
          name: 'private',
          size: testPageSize,
          layers: <DocumentLayer>[first, duplicateObjectLayer],
          extensionData: PreservedMap.empty(),
        ),
        isA<Err<DocumentPage, StructuredFailure>>(),
      );
      expect(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(134)),
          name: 'private',
          size: testPageSize,
          layers: <DocumentLayer>[first, first],
          extensionData: PreservedMap.empty(),
        ),
        isA<Err<DocumentPage, StructuredFailure>>(),
      );
    });

    test('unknown content-role Layer satisfies the minimum invariant', () {
      final unknown = testUnknownLayer();
      final page = testPage(layers: <DocumentLayer>[unknown]);
      expect(page.layers.single, same(unknown));
    });
  });

  group('document forms and in-memory reconstruction', () {
    test('Notebook reconstructs exactly through public factories', () {
      final object = testObject(
        payload: PreservedMap(<String, PreservedData>{
          'unknown': const PreservedString('value'),
        }),
      );
      final layer = testUnknownLayer(objects: <ObjectEnvelope>[object]);
      final page = testPage(layers: <DocumentLayer>[layer]);
      final section = testSection(pages: <DocumentPage>[page]);
      final original = testNotebook(sections: <DocumentSection>[section]);
      final rebuilt = _reconstructDocument(original) as NotebookDocument;

      expect(rebuilt, original);
      expect(rebuilt.hashCode, original.hashCode);
      expect(
        rebuilt.sections.single.pages.single.layers.single,
        isNot(same(layer)),
      );
    });

    test('Standalone Page reconstructs without a synthetic Section', () {
      final page = testPage();
      final original = modelValue<StandalonePageDocument>(
        StandalonePageDocument.create(
          id: DocumentId.fromUuid(testUuid(140)),
          schemaVersion: testSchemaVersion,
          title: 'Sensitive title',
          resources: emptyResourceCatalog(),
          extensionData: PreservedMap.empty(),
          page: page,
        ),
      );
      final rebuilt = _reconstructDocument(original) as StandalonePageDocument;

      expect(rebuilt, original);
      expect(rebuilt.pages, <DocumentPage>[page]);
      expect(rebuilt.page, isNot(same(page)));
      expect(rebuilt.toString(), isNot(contains('Sensitive title')));
    });

    test('Standalone PDF preserves Pages and generic source reference', () {
      final resourceId = ResourceIdentity.fromUuid(testUuid(150));
      final catalog = modelValue<ResourceCatalog>(
        ResourceCatalog.create(<ResourceCatalogEntry>[
          ResourceCatalogEntry(resourceId),
        ]),
      );
      final original = modelValue<StandalonePdfDocument>(
        StandalonePdfDocument.create(
          id: DocumentId.fromUuid(testUuid(151)),
          schemaVersion: testSchemaVersion,
          title: 'Sensitive PDF',
          resources: catalog,
          extensionData: PreservedMap.empty(),
          pages: <DocumentPage>[testPage()],
          source: ResourceReference(resourceId),
        ),
      );
      final rebuilt = _reconstructDocument(original) as StandalonePdfDocument;

      expect(rebuilt, original);
      expect(rebuilt.source, ResourceReference(resourceId));
      expect(rebuilt.pages.single, isNot(same(original.pages.single)));
      expect(rebuilt.toString(), isNot(contains('Sensitive PDF')));
    });

    test('all document collection inputs are defensive and unmodifiable', () {
      final pageSource = <DocumentPage>[testPage()];
      final section = testSection(pages: pageSource);
      pageSource.clear();
      final sectionSource = <DocumentSection>[section];
      final notebook = testNotebook(sections: sectionSource);
      sectionSource.clear();

      expect(section.pages, hasLength(1));
      expect(notebook.sections, hasLength(1));
      expect(section.pages.clear, throwsUnsupportedError);
      expect(notebook.sections.clear, throwsUnsupportedError);
    });

    test('resource catalogs reject duplicates and sort deterministically', () {
      final low = ResourceIdentity.fromUuid(testUuid(160));
      final high = ResourceIdentity.fromUuid(testUuid(161));
      final source = <ResourceCatalogEntry>[
        ResourceCatalogEntry(high),
        ResourceCatalogEntry(low),
      ];
      final catalog = modelValue<ResourceCatalog>(
        ResourceCatalog.create(source),
      );
      source.clear();

      expect(catalog.entries.map((entry) => entry.identity), <ResourceIdentity>[
        low,
        high,
      ]);
      expect(catalog.entries.clear, throwsUnsupportedError);
      expect(
        ResourceCatalog.create(<ResourceCatalogEntry>[
          ResourceCatalogEntry(low),
          ResourceCatalogEntry(low),
        ]),
        isA<Err<ResourceCatalog, StructuredFailure>>(),
      );
    });

    test('titles and names never enter failures or debug strings', () {
      const secret = 'super-sensitive-title';
      final invalid =
          DocumentPage.create(
                id: PageId.fromUuid(testUuid(170)),
                name: secret,
                size: modelValue<Size2>(Size2.create(width: 0, height: 1)),
                layers: <DocumentLayer>[testContentLayer(name: secret)],
                extensionData: PreservedMap.empty(),
              )
              as Err<DocumentPage, StructuredFailure>;

      expect(invalid.error.toString(), isNot(contains(secret)));
      expect(testNotebook(title: secret).toString(), isNot(contains(secret)));
      expect(testSection(name: secret).toString(), isNot(contains(secret)));
      expect(
        testContentLayer(name: secret).toString(),
        isNot(contains(secret)),
      );
    });
  });
}

DocumentRoot _reconstructDocument(DocumentRoot source) {
  final resources = modelValue<ResourceCatalog>(
    ResourceCatalog.create(
      source.resources.entries.map(
        (entry) => ResourceCatalogEntry(entry.identity),
      ),
    ),
  );
  switch (source) {
    case NotebookDocument():
      return modelValue<NotebookDocument>(
        NotebookDocument.create(
          id: source.id,
          schemaVersion: source.schemaVersion,
          title: source.title,
          resources: resources,
          extensionData: _reconstructMap(source.extensionData),
          sections: source.sections.map(_reconstructSection),
        ),
      );
    case StandalonePageDocument():
      return modelValue<StandalonePageDocument>(
        StandalonePageDocument.create(
          id: source.id,
          schemaVersion: source.schemaVersion,
          title: source.title,
          resources: resources,
          extensionData: _reconstructMap(source.extensionData),
          page: _reconstructPage(source.page),
        ),
      );
    case StandalonePdfDocument():
      return modelValue<StandalonePdfDocument>(
        StandalonePdfDocument.create(
          id: source.id,
          schemaVersion: source.schemaVersion,
          title: source.title,
          resources: resources,
          extensionData: _reconstructMap(source.extensionData),
          pages: source.pages.map(_reconstructPage),
          source: ResourceReference(source.source.identity),
        ),
      );
  }
}

DocumentSection _reconstructSection(DocumentSection source) =>
    modelValue<DocumentSection>(
      DocumentSection.create(
        id: source.id,
        name: source.name,
        pages: source.pages.map(_reconstructPage),
        extensionData: _reconstructMap(source.extensionData),
      ),
    );

DocumentPage _reconstructPage(DocumentPage source) => modelValue<DocumentPage>(
  DocumentPage.create(
    id: source.id,
    name: source.name,
    size: modelValue<Size2>(
      Size2.create(width: source.size.width, height: source.size.height),
    ),
    layers: source.layers.map(_reconstructLayer),
    extensionData: _reconstructMap(source.extensionData),
  ),
);

DocumentLayer _reconstructLayer(DocumentLayer source) {
  final objects = source.objects.map(_reconstructObject);
  switch (source) {
    case ContentLayer():
      return modelValue<ContentLayer>(
        ContentLayer.create(
          id: source.id,
          envelopeVersion: source.envelopeVersion,
          typeSchemaVersion: source.typeSchemaVersion,
          name: source.name,
          visible: source.visible,
          locked: source.locked,
          opacity: source.opacity,
          objects: objects,
          typeData: _reconstructData(source.typeData),
          extensionData: _reconstructMap(source.extensionData),
        ),
      );
    case UnknownLayer():
      return modelValue<UnknownLayer>(
        UnknownLayer.create(
          id: source.id,
          typeKey: source.typeKey,
          envelopeVersion: source.envelopeVersion,
          typeSchemaVersion: source.typeSchemaVersion,
          name: source.name,
          role: source.role,
          visible: source.visible,
          locked: source.locked,
          opacity: source.opacity,
          objects: objects,
          typeData: _reconstructData(source.typeData),
          extensionData: _reconstructMap(source.extensionData),
        ),
      );
  }
}

ObjectEnvelope _reconstructObject(ObjectEnvelope source) =>
    modelValue<ObjectEnvelope>(
      ObjectEnvelope.create(
        id: source.id,
        typeKey: source.typeKey,
        envelopeVersion: source.envelopeVersion,
        typeSchemaVersion: source.typeSchemaVersion,
        transform: source.transform,
        visible: source.visible,
        locked: source.locked,
        payload: _reconstructData(source.payload),
        extensionData: _reconstructMap(source.extensionData),
      ),
    );

PreservedMap _reconstructMap(PreservedMap source) => PreservedMap(
  source.values.map(
    (key, value) =>
        MapEntry<String, PreservedData>(key, _reconstructData(value)),
  ),
);

PreservedData _reconstructData(PreservedData source) => switch (source) {
  PreservedNull() => const PreservedNull(),
  PreservedBoolean(:final value) => PreservedBoolean(value),
  PreservedInteger(:final value) => modelValue<PreservedInteger>(
    PreservedInteger.create(value),
  ),
  PreservedDouble(:final value) => modelValue<PreservedDouble>(
    PreservedDouble.create(value),
  ),
  PreservedString(:final value) => PreservedString(value),
  PreservedList(:final values) => PreservedList(values.map(_reconstructData)),
  PreservedMap() => _reconstructMap(source),
};
