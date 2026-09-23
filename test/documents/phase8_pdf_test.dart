// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/phase3_test_support.dart';
import '../support/phase4_test_support.dart';
import '../support/uuid_sequence_generator.dart';

final PdfModelLimits _modelLimits = _ok(
  PdfModelLimits.create(
    maximumPageCount: 1000,
    maximumCoordinateMagnitude: 100000,
    maximumPageDimension: 10000,
    maximumPageArea: 100000000,
    maximumUnknownFields: 16,
    maximumUnknownNodes: 256,
    maximumNestingDepth: 8,
    maximumUnknownStringCodeUnits: 4096,
  ),
);

final PdfProcessingLimits _processingLimits = _ok(
  PdfProcessingLimits.create(
    maximumEncodedBytes: 1024,
    maximumPageCount: 1000,
    maximumRenderDimension: 256,
    maximumRenderPixels: 65536,
    maximumExtractedGlyphs: 10000,
    maximumLinks: 1000,
    maximumOperations: 100000,
  ),
);

void main() {
  group('Phase 8 dependency boundary', () {
    test('pdfrx is exact, local-patched, and private to one adapter', () {
      final manifest = File('pubspec.yaml').readAsStringSync();
      final lock = File('pubspec.lock').readAsStringSync();
      final review = File('docs/dependency-review/README.md')
          .readAsStringSync();
      expect(manifest, contains('pdfrx: 2.4.8'));
      expect(manifest, isNot(contains('pdfrx: ^')));
      expect(manifest, contains('path: third_party/pdfrx-2.4.8'));
      expect(manifest, contains('path: third_party/pdfrx_engine-0.4.7'));
      expect(lock, contains('version: "2.4.8"'));
      expect(
        review,
        contains(
          '85a87117ae6358e0ef2cc90d4db9f5e689eabbd7f19ab98c97164584d0be4a4a',
        ),
      );
      final imports = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where(
            (file) =>
                file.readAsStringSync().contains("package:pdfrx/") ||
                file.readAsStringSync().contains("package:pdfrx_engine/") ||
                file.readAsStringSync().contains("package:pdfium_"),
          )
          .toList(growable: false);
      expect(imports, hasLength(1));
      expect(
        imports.single.path.replaceAll('\\', '/'),
        endsWith('lib/documents/pdf/src/pdfrx_pdf_backend_adapter.dart'),
      );
    });
  });

  group('PDF persistent model', () {
    test('page reference round-trips exact resolved evidence', () {
      final unknown = PreservedMap(<String, PreservedData>{
        'future': const PreservedString('preserved'),
      });
      final reference = _reference(
        rotation: PdfPageRotation.degrees90,
        unknownFields: unknown,
      );

      final decoded = _ok(
        PdfPageReference.decode(reference.encode(), limits: _modelLimits),
      );

      expect(decoded, reference);
      expect(decoded.displayedWidth, 792);
      expect(decoded.displayedHeight, 612);
      expect(decoded.unknownFields, unknown);
      expect(decoded.toString(), isNot(contains(testUuid(800).value)));
    });

    test('page reference rejects drift, limits, and malformed geometry', () {
      final box = _box();
      expect(
        PdfPageReference.create(
          resourceIdentity: ResourceIdentity.fromUuid(testUuid(800)),
          pageIndex: 1000,
          boxKind: PdfPageBoxKind.cropBox,
          sourceBox: box,
          rotation: PdfPageRotation.degrees0,
          displayedWidth: 612,
          displayedHeight: 792,
          limits: _modelLimits,
        ),
        isA<Err<PdfPageReference, StructuredFailure>>(),
      );
      expect(
        PdfPageReference.create(
          resourceIdentity: ResourceIdentity.fromUuid(testUuid(800)),
          pageIndex: 0,
          boxKind: PdfPageBoxKind.cropBox,
          sourceBox: box,
          rotation: PdfPageRotation.degrees90,
          displayedWidth: 612,
          displayedHeight: 792,
          limits: _modelLimits,
        ),
        isA<Err<PdfPageReference, StructuredFailure>>(),
      );
      expect(
        PdfSourceBox.create(
          left: 0,
          bottom: 0,
          right: double.infinity,
          top: 1,
          limits: _modelLimits,
        ),
        isA<Err<PdfSourceBox, StructuredFailure>>(),
      );
      expect(
        PdfSourceBox.create(
          left: 0,
          bottom: 0,
          right: 5e-324,
          top: 5e-324,
          limits: _modelLimits,
        ),
        isA<Err<PdfSourceBox, StructuredFailure>>(),
      );
    });

    test('movable Page Object exposes geometry and one resource', () {
      final payload = _ok(
        PdfPageObjectPayload.create(
          reference: _reference(),
          clip: _ok(
            PdfPageClip.create(left: .25, top: .25, right: .75, bottom: .75),
          ),
          limits: _modelLimits,
          unknownFields: PreservedMap(<String, PreservedData>{
            'future': const PreservedBoolean(true),
          }),
        ),
      );
      final definition = PdfPageObjectTypeDefinition(_modelLimits);
      final envelope = testObject(
        id: 801,
        typeKey: pdfPageObjectTypeKey,
        schemaVersion: pdfPageObjectSchemaVersion,
        payload: payload.encode(),
      );
      final resolution =
          ObjectRegistry.create(<ObjectTypeDefinition>[definition]).fold(
            onOk: (value) => value.resolve(envelope),
            onErr: (_) => throw StateError('Registry failed.'),
          );

      expect(resolution, isA<SupportedObjectResolution>());
      expect(
        _ok(
          definition.intrinsicGeometry(
            envelope.payload,
            envelope.typeSchemaVersion,
          ),
        ),
        Rect2.fromEdges(left: 0, top: 0, right: 306, bottom: 396).fold(
          onOk: (value) => value,
          onErr: (_) => throw StateError('Rectangle failed.'),
        ),
      );
      expect(
        _ok(
          definition.resourceReferences(
            envelope.payload,
            envelope.typeSchemaVersion,
          ),
        ).single.identity,
        payload.reference.resourceIdentity,
      );
      expect(
        _ok(
          definition.duplicatePayload(
            envelope.payload,
            envelope.typeSchemaVersion,
            IdentityRemapping(),
          ),
        ),
        envelope.payload,
      );
    });

    test('missing PDF resource is preserved as a placeholder', () {
      final payload = _ok(
        PdfPageObjectPayload.create(
          reference: _reference(),
          clip: PdfPageClip.full,
          limits: _modelLimits,
        ),
      );
      final envelope = testObject(
        id: 802,
        typeKey: pdfPageObjectTypeKey,
        schemaVersion: pdfPageObjectSchemaVersion,
        payload: payload.encode(),
      );
      final document = testNotebook(
        sections: <DocumentSection>[
          testSection(
            pages: <DocumentPage>[
              testPage(
                layers: <DocumentLayer>[
                  testContentLayer(objects: <ObjectEnvelope>[envelope]),
                ],
              ),
            ],
          ),
        ],
      );
      final registry = _ok(
        ObjectRegistry.create(<ObjectTypeDefinition>[
          PdfPageObjectTypeDefinition(_modelLimits),
        ]),
      );

      final validation = DocumentValidator(registry)
          .validateWithPlaceholders(document);

      expect(validation.report.isValid, isTrue);
      expect(
        validation.report.warnings.single.code,
        ValidationIssueCode.missingResource,
      );
      expect(
        validation.placeholders.single,
        ResourcePlaceholderDescriptor(
          reason: PlaceholderReason.missingResource,
          resourceIdentity: payload.reference.resourceIdentity,
        ),
      );
    });
  });

  group('PDF receiving-limit provenance', () {
    final permissiveModelLimits = _ok(
      PdfModelLimits.create(
        maximumPageCount: 100,
        maximumCoordinateMagnitude: 2000,
        maximumPageDimension: 10,
        maximumPageArea: 100,
        maximumUnknownFields: 16,
        maximumUnknownNodes: 256,
        maximumNestingDepth: 8,
        maximumUnknownStringCodeUnits: 4096,
      ),
    );
    final strictModelLimits = _ok(
      PdfModelLimits.create(
        maximumPageCount: 2,
        maximumCoordinateMagnitude: 100,
        maximumPageDimension: 10,
        maximumPageArea: 100,
        maximumUnknownFields: 16,
        maximumUnknownNodes: 256,
        maximumNestingDepth: 8,
        maximumUnknownStringCodeUnits: 4096,
      ),
    );
    final permissiveProcessingLimits = _ok(
      PdfProcessingLimits.create(
        maximumEncodedBytes: 1024,
        maximumPageCount: 100,
        maximumRenderDimension: 10,
        maximumRenderPixels: 100,
        maximumExtractedGlyphs: 100,
        maximumLinks: 10,
        maximumOperations: 100,
      ),
    );
    final strictProcessingLimits = _ok(
      PdfProcessingLimits.create(
        maximumEncodedBytes: 1024,
        maximumPageCount: 2,
        maximumRenderDimension: 10,
        maximumRenderPixels: 100,
        maximumExtractedGlyphs: 100,
        maximumLinks: 10,
        maximumOperations: 100,
      ),
    );

    test('nested values are revalidated under receiving limits', () {
      final permissiveBox = _ok(
        PdfSourceBox.create(
          left: 1000,
          bottom: -1000,
          right: 1010,
          top: -990,
          limits: permissiveModelLimits,
        ),
      );
      final strictReferenceAttempt = PdfPageReference.create(
        resourceIdentity: ResourceIdentity.fromUuid(testUuid(851)),
        pageIndex: 0,
        boxKind: PdfPageBoxKind.cropBox,
        sourceBox: permissiveBox,
        rotation: PdfPageRotation.degrees0,
        displayedWidth: 10,
        displayedHeight: 10,
        limits: strictModelLimits,
      );
      expect(
        strictReferenceAttempt,
        isA<Err<PdfPageReference, StructuredFailure>>(),
      );
      expect(strictReferenceAttempt.toString(), isNot(contains('1000')));

      final permissiveReference = _ok(
        PdfPageReference.create(
          resourceIdentity: ResourceIdentity.fromUuid(testUuid(851)),
          pageIndex: 0,
          boxKind: PdfPageBoxKind.cropBox,
          sourceBox: permissiveBox,
          rotation: PdfPageRotation.degrees0,
          displayedWidth: 10,
          displayedHeight: 10,
          limits: permissiveModelLimits,
        ),
      );
      final encodedBefore = permissiveReference.encode();
      final layerAttempt = PdfSourceLayer.create(
        id: LayerId.fromUuid(testUuid(852)),
        envelopeVersion: testSchemaVersion,
        name: 'Strict source',
        visible: true,
        opacity: 1,
        reference: permissiveReference,
        limits: strictModelLimits,
      );
      final objectAttempt = PdfPageObjectPayload.create(
        reference: permissiveReference,
        clip: PdfPageClip.full,
        limits: strictModelLimits,
      );
      expect(layerAttempt, isA<Err<PdfSourceLayer, StructuredFailure>>());
      expect(
        objectAttempt,
        isA<Err<PdfPageObjectPayload, StructuredFailure>>(),
      );
      expect(permissiveReference.encode(), encodedBefore);
      expect(layerAttempt.toString(), isNot(contains(testUuid(851).value)));
      expect(objectAttempt.toString(), isNot(contains(testUuid(851).value)));

      final permissivePage = _ok(
        PdfInspectedPage.create(
          pageIndex: 0,
          boxKind: PdfPageBoxKind.cropBox,
          sourceBox: permissiveBox,
          rotation: PdfPageRotation.degrees0,
          displayedWidth: 10,
          displayedHeight: 10,
          limits: permissiveModelLimits,
        ),
      );
      final inspectionAttempt = PdfInspectSuccess.capture(
        backendIdentity: _ok(PdfBackendIdentity.parse('strict.backend')),
        pages: <PdfInspectedPage>[permissivePage],
        modelLimits: strictModelLimits,
        limits: strictProcessingLimits,
        cancellationToken: CancellationController().token,
      );
      expect(inspectionAttempt, isA<PdfInspectionLimitExceeded>());
      expect(inspectionAttempt.toString(), isNot(contains('1000')));

      final permissiveLink = _ok(
        PdfSafeLinkMetadata.create(
          bounds: _rect(0, 0, 1, 1),
          kind: PdfSafeLinkKind.internalPage,
          destinationPageIndex: 99,
          limits: permissiveProcessingLimits,
        ),
      );
      final linksAttempt = PdfSafeLinks.capture(
        links: <PdfSafeLinkMetadata>[permissiveLink],
        limits: strictProcessingLimits,
        cancellationToken: CancellationController().token,
      );
      expect(linksAttempt, isA<Err<PdfSafeLinks, StructuredFailure>>());
      expect(linksAttempt.toString(), isNot(contains('99')));
    });

    test('exact strict boundaries succeed and round-trip', () {
      final boundaryBox = _ok(
        PdfSourceBox.create(
          left: 90,
          bottom: -100,
          right: 100,
          top: -90,
          limits: strictModelLimits,
        ),
      );
      final reference = _ok(
        PdfPageReference.create(
          resourceIdentity: ResourceIdentity.fromUuid(testUuid(853)),
          pageIndex: 1,
          boxKind: PdfPageBoxKind.mediaBox,
          sourceBox: boundaryBox,
          rotation: PdfPageRotation.degrees270,
          displayedWidth: 10,
          displayedHeight: 10,
          limits: strictModelLimits,
        ),
      );
      expect(
        _ok(
          PdfPageReference.decode(
            reference.encode(),
            limits: strictModelLimits,
          ),
        ),
        reference,
      );
      expect(
        PdfSourceLayer.create(
          id: LayerId.fromUuid(testUuid(854)),
          envelopeVersion: testSchemaVersion,
          name: 'Boundary source',
          visible: true,
          opacity: 1,
          reference: reference,
          limits: strictModelLimits,
        ),
        isA<Ok<PdfSourceLayer, StructuredFailure>>(),
      );
      expect(
        PdfPageObjectPayload.create(
          reference: reference,
          clip: PdfPageClip.full,
          limits: strictModelLimits,
        ),
        isA<Ok<PdfPageObjectPayload, StructuredFailure>>(),
      );
      final inspected = _ok(
        PdfInspectedPage.create(
          pageIndex: 0,
          boxKind: PdfPageBoxKind.mediaBox,
          sourceBox: boundaryBox,
          rotation: PdfPageRotation.degrees270,
          displayedWidth: 10,
          displayedHeight: 10,
          limits: strictModelLimits,
        ),
      );
      expect(
        PdfInspectSuccess.capture(
          backendIdentity: _ok(PdfBackendIdentity.parse('strict.backend')),
          pages: <PdfInspectedPage>[inspected],
          modelLimits: strictModelLimits,
          limits: strictProcessingLimits,
          cancellationToken: CancellationController().token,
        ),
        isA<PdfInspectSuccess>(),
      );
      final boundaryLink = _ok(
        PdfSafeLinkMetadata.create(
          bounds: _rect(0, 0, 1, 1),
          kind: PdfSafeLinkKind.internalPage,
          destinationPageIndex: 1,
          limits: strictProcessingLimits,
        ),
      );
      final links = _ok(
        PdfSafeLinks.capture(
          links: <PdfSafeLinkMetadata>[boundaryLink],
          limits: strictProcessingLimits,
          cancellationToken: CancellationController().token,
        ),
      );
      expect(links.links.single.destinationPageIndex, 1);
    });
  });

  group('PDF backend-neutral boundaries', () {
    test('resource bytes are bounded, copied, and immutable', () {
      final original = <int>[0x25, 0x50, 0x44, 0x46];
      final captured = _ok(
        PdfResourceBytes.capture(
          identity: ResourceIdentity.fromUuid(testUuid(810)),
          bytes: original,
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
      );
      original[0] = 0;
      expect(captured.bytes, <int>[0x25, 0x50, 0x44, 0x46]);
      expect(() => captured.bytes.add(0), throwsUnsupportedError);
      expect(
        PdfResourceBytes.capture(
          identity: ResourceIdentity.fromUuid(testUuid(810)),
          bytes: _ThrowingBytes(),
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
        isA<Err<PdfResourceBytes, StructuredFailure>>(),
      );
    });

    test('render requests and output enforce exact pixel ceilings', () {
      final request = _ok(
        PdfRenderRequest.create(
          reference: _reference(),
          trust: PdfInputTrust.trustedDevelopmentFixture,
          region: PdfPageClip.full,
          pixelWidth: 2,
          pixelHeight: 2,
          includeSafeNativeAppearances: true,
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
      );
      final identity = _ok(PdfBackendIdentity.parse('alnote.pdfrx.dev'));
      final output = _ok(
        PdfRenderOutput.capture(
          backendIdentity: identity,
          region: request.region,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaBytes: List<int>.filled(16, 255),
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
      );
      expect(output.rgbaBytes, hasLength(16));
      expect(() => output.rgbaBytes[0] = 0, throwsUnsupportedError);
      expect(
        PdfRenderOutput.capture(
          backendIdentity: identity,
          region: request.region,
          pixelWidth: 2,
          pixelHeight: 2,
          rgbaBytes: List<int>.filled(15, 255),
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
        isA<Err<PdfRenderOutput, StructuredFailure>>(),
      );
      expect(
        PdfRenderRequest.create(
          reference: _reference(),
          trust: PdfInputTrust.trustedDevelopmentFixture,
          region: PdfPageClip.full,
          pixelWidth: 257,
          pixelHeight: 1,
          includeSafeNativeAppearances: true,
          limits: _processingLimits,
          cancellationToken: CancellationController().token,
        ),
        isA<Err<PdfRenderRequest, StructuredFailure>>(),
      );
    });

    test('inspection success snapshots ordered Page evidence', () {
      final pages = <PdfInspectedPage>[
        _ok(
          PdfInspectedPage.create(
            pageIndex: 0,
            boxKind: PdfPageBoxKind.cropBox,
            sourceBox: _box(),
            rotation: PdfPageRotation.degrees0,
            displayedWidth: 612,
            displayedHeight: 792,
            limits: _modelLimits,
          ),
        ),
      ];
      final success = PdfInspectSuccess.capture(
        backendIdentity: _ok(PdfBackendIdentity.parse('fake.backend')),
        pages: pages,
        modelLimits: _modelLimits,
        limits: _processingLimits,
        cancellationToken: CancellationController().token,
      );
      pages.clear();
      expect(success, isA<PdfInspectSuccess>());
      final inspected = success as PdfInspectSuccess;
      expect(inspected.pages, hasLength(1));
      expect(inspected.pages.clear, throwsUnsupportedError);
      expect(const PdfPasswordRequired(), isA<PdfInspectOutcome>());
      expect(const PdfInspectionCancelled(), isA<PdfInspectOutcome>());
    });
  });

  group('PDF coordinates and persistent adversarial bounds', () {
    for (final rotation in PdfPageRotation.values) {
      test('${rotation.degrees} degree points and rectangles round-trip', () {
        final box = _ok(
          PdfSourceBox.create(
            left: -20,
            bottom: 30,
            right: 80,
            top: 230,
            limits: _modelLimits,
          ),
        );
        final reference = _reference(rotation: rotation, sourceBox: box);
        final coordinates = PdfPageCoordinates(reference);
        final source = _point(5, 75);
        final local = _ok(coordinates.sourceToLocal(source));
        expect(_ok(coordinates.localToSource(local)), source);

        final sourceRect = _rect(-10, 40, 40, 90);
        final localRect = _ok(coordinates.sourceRectToLocal(sourceRect));
        expect(_ok(coordinates.localRectToSource(localRect)), sourceRect);
        expect(
          _ok(coordinates.clipToLocalRect(PdfPageClip.full)),
          _rect(0, 0, reference.displayedWidth, reference.displayedHeight),
        );
      });
    }

    test(
      'box selection, collisions, malformed wire data, and bounds reject',
      () {
        expect(
          PdfPageReference.create(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(800)),
            pageIndex: 0,
            boxKind: PdfPageBoxKind.trimBox,
            sourceBox: _box(),
            rotation: PdfPageRotation.degrees0,
            displayedWidth: 612,
            displayedHeight: 792,
            limits: _modelLimits,
          ),
          isA<Err<PdfPageReference, StructuredFailure>>(),
        );
        expect(
          PdfPageReference.create(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(800)),
            pageIndex: 0,
            boxKind: PdfPageBoxKind.mediaBox,
            sourceBox: _box(),
            rotation: PdfPageRotation.degrees0,
            displayedWidth: 612,
            displayedHeight: 792,
            limits: _modelLimits,
          ),
          isA<Ok<PdfPageReference, StructuredFailure>>(),
        );
        expect(
          PdfPageReference.create(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(800)),
            pageIndex: 0,
            boxKind: PdfPageBoxKind.cropBox,
            sourceBox: _box(),
            rotation: PdfPageRotation.degrees0,
            displayedWidth: 612,
            displayedHeight: 792,
            limits: _modelLimits,
            unknownFields: PreservedMap(<String, PreservedData>{
              'pageIndex': _integer(7),
            }),
          ),
          isA<Err<PdfPageReference, StructuredFailure>>(),
        );
        final encoded =
            Map<String, PreservedData>.of(_reference().encode().values)
              ..['resourceId'] = const PreservedString('secret-invalid-uuid')
              ..['boxKind'] = const PreservedString('secret-box')
              ..['rotationDegrees'] = _integer(45);
        final failure = PdfPageReference.decode(
          PreservedMap(encoded),
          limits: _modelLimits,
        );
        expect(failure, isA<Err<PdfPageReference, StructuredFailure>>());
        expect(failure.toString(), isNot(contains('secret')));
        expect(
          PdfPageCoordinates(_reference()).localToSource(_point(-1, 0)),
          isA<Err<Point2, StructuredFailure>>(),
        );
      },
    );

    test('movable PDF Object has exact commit, Undo, and Redo roots', () {
      final payload = _ok(
        PdfPageObjectPayload.create(
          reference: _reference(),
          clip: PdfPageClip.full,
          limits: _modelLimits,
        ),
      );
      final object = testObject(
        id: 835,
        typeKey: pdfPageObjectTypeKey,
        schemaVersion: pdfPageObjectSchemaVersion,
        payload: payload.encode(),
      );
      final page = _ok(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(836)),
          name: 'Movable PDF',
          size: _size(1000, 1000),
          layers: <DocumentLayer>[
            testContentLayer(id: 837, objects: <ObjectEnvelope>[object]),
          ],
          extensionData: PreservedMap.empty(),
        ),
      );
      final notebook = _ok(
        NotebookDocument.create(
          id: DocumentId.fromUuid(testUuid(838)),
          schemaVersion: testSchemaVersion,
          title: 'PDF Object',
          resources: _ok(
            ResourceCatalog.create(<ResourceCatalogEntry>[
              ResourceCatalogEntry(_reference().resourceIdentity),
            ]),
          ),
          extensionData: PreservedMap.empty(),
          sections: <DocumentSection>[
            _ok(
              DocumentSection.create(
                id: SectionId.fromUuid(testUuid(839)),
                name: 'Section',
                pages: <DocumentPage>[page],
                extensionData: PreservedMap.empty(),
              ),
            ),
          ],
        ),
      );
      final registry = _ok(
        ObjectRegistry.create(<ObjectTypeDefinition>[
          PdfPageObjectTypeDefinition(_modelLimits),
        ]),
      );
      final coordinator = phase3Coordinator(root: notebook, registry: registry);
      final before = coordinator.snapshot.root;
      final snapshot = coordinator.snapshot;
      final layer = page.layers.single;
      final request = _ok(
        AtomicWholeObjectTransformRequest.create(
          documentId: notebook.id,
          metadata: phase3Metadata(family: 'alnote.commands.object.transform'),
          preconditions: RevisionPreconditions(
            pages: <PageId, Revision>{
              page.id: snapshot.revisions.pages[page.id]!,
            },
            layerMembership: <LayerId, Revision>{
              layer.id: snapshot.revisions.layerMembership[layer.id]!,
            },
            objects: <ObjectId, Revision>{
              object.id: snapshot.revisions.objects[object.id]!,
            },
          ),
          pageId: page.id,
          targetIds: <ObjectId>[object.id],
          operation: TranslationTransformOperation2D(_vector(10, 12)),
        ),
      );
      expect(
        coordinator.execute(request),
        isA<Ok<CommandCommit, CommandFailure>>(),
      );
      final committed = coordinator.snapshot.root;
      expect(committed, isNot(before));
      expect(coordinator.undo(), isA<Ok<CommandCommit, CommandFailure>>());
      expect(coordinator.snapshot.root, before);
      expect(coordinator.redo(), isA<Ok<CommandCommit, CommandFailure>>());
      expect(coordinator.snapshot.root, committed);
    });
  });

  group('built-in PDF source Layer and persistence', () {
    test(
      'source Layer is unique, ordered, locked, empty, and Page-filling',
      () {
        final source = _sourceLayer();
        expect(source.typeKey.value, 'alnote.pdf.source');
        expect(source.role, LayerCoreRole.pdfSource);
        expect(source.locked, isTrue);
        expect(source.objects, isEmpty);
        expect(
          source.withObjects(<ObjectEnvelope>[testObject()]),
          isA<Err<DocumentLayer, StructuredFailure>>(),
        );
        expect(
          DocumentPage.create(
            id: PageId.fromUuid(testUuid(821)),
            name: 'PDF Page',
            size: _size(612, 792),
            layers: <DocumentLayer>[source, testContentLayer(id: 822)],
            extensionData: PreservedMap.empty(),
          ),
          isA<Ok<DocumentPage, StructuredFailure>>(),
        );
        expect(
          DocumentPage.create(
            id: PageId.fromUuid(testUuid(823)),
            name: 'Wrong order',
            size: _size(612, 792),
            layers: <DocumentLayer>[testContentLayer(id: 824), source],
            extensionData: PreservedMap.empty(),
          ),
          isA<Err<DocumentPage, StructuredFailure>>(),
        );
        expect(
          DocumentPage.create(
            id: PageId.fromUuid(testUuid(825)),
            name: 'Wrong size',
            size: _size(600, 800),
            layers: <DocumentLayer>[source, testContentLayer(id: 826)],
            extensionData: PreservedMap.empty(),
          ),
          isA<Err<DocumentPage, StructuredFailure>>(),
        );
      },
    );

    for (final boxKind in [
      PdfPageBoxKind.cropBox,
      PdfPageBoxKind.resolvedBounds,
    ]) {
      test(
        '${boxKind.wireName} source shares resource through duplication and Save/Reopen',
        () {
          final resource = _pdfResource();
          final catalog = _ok(
            ResourceCatalog.create(<ResourceCatalogEntry>[
              ResourceCatalogEntry(resource.identity),
            ]),
          );
          final source = _sourceLayer(
            boxKind: boxKind,
            extensionData: PreservedMap(<String, PreservedData>{
              'futureLayer': const PreservedBoolean(true),
            }),
          );
          final payload = _ok(
            PdfPageObjectPayload.create(
              reference: _reference(boxKind: boxKind),
              clip: PdfPageClip.full,
              limits: _modelLimits,
            ),
          );
          final object = testObject(
            id: 827,
            typeKey: pdfPageObjectTypeKey,
            schemaVersion: pdfPageObjectSchemaVersion,
            payload: payload.encode(),
          );
          final page = _ok(
            DocumentPage.create(
              id: PageId.fromUuid(testUuid(828)),
              name: 'PDF Page',
              size: _size(612, 792),
              layers: <DocumentLayer>[
                source,
                testContentLayer(id: 829, objects: <ObjectEnvelope>[object]),
              ],
              extensionData: PreservedMap.empty(),
            ),
          );
          final document = _ok(
            StandalonePdfDocument.create(
              id: DocumentId.fromUuid(testUuid(830)),
              schemaVersion: testSchemaVersion,
              title: 'PDF document',
              resources: catalog,
              extensionData: PreservedMap.empty(),
              pages: <DocumentPage>[page],
              source: ResourceReference(resource.identity),
            ),
          );
          final registry = _ok(
            ObjectRegistry.create(<ObjectTypeDefinition>[
              PdfPageObjectTypeDefinition(_modelLimits),
            ]),
          );
          final validation = DocumentValidator(registry)
              .validateWithPlaceholders(document);
          expect(validation.report.isValid, isTrue);
          expect(validation.placeholders, isEmpty);

          final duplicated = _ok(
            DocumentDuplicator(
              uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
                testUuid(831),
              ]),
              objectRegistry: registry,
            ).duplicateLayer(source, destinationScope: DocumentIdentityScope()),
          ) as PdfSourceLayer;
          expect(duplicated.id, LayerId.fromUuid(testUuid(831)));
          expect(duplicated.reference, same(source.reference));
          expect(duplicated.reference.resourceIdentity, resource.identity);

          final snapshot = _ok(
            AlnotePackageSnapshot.create(
              document: document,
              resources: <DocumentResourceSnapshot>[
                DocumentResourceSnapshot(resource),
              ],
            ),
          );
          final bytes = _ok(
            AlnotePackageCodec(objectRegistry: registry)
                .encode(snapshot, limits: phase4Limits()),
          );
          final opened = AlnotePackageReader(objectRegistry: registry)
              .openBytes(
                bytes,
                limits: phase4Limits(),
                cancellationToken: CancellationController().token,
              );
          expect(
            opened,
            isA<Completed<OpenedAlnotePackage, StructuredFailure>>(),
          );
          final root =
              (opened as Completed<OpenedAlnotePackage, StructuredFailure>)
                  .value
                  .materializeDocument(
                    cancellationToken: CancellationController().token,
                  );
          expect(root, isA<Completed<DocumentRoot, StructuredFailure>>());
          expect(
            (root as Completed<DocumentRoot, StructuredFailure>).value,
            document,
          );
        },
      );
    }

    test('annotated PDF page and section duplication remap annotations and round-trip', () {
      final resource = _pdfResource();
      final catalog = _ok(
        ResourceCatalog.create([ResourceCatalogEntry(resource.identity)]),
      );
      final annotation = testObject(id: 900);
      final registry = testRegistry([
        TestObjectTypeDefinition(referencedObjectId: annotation.id),
      ]);
      final source = _sourceLayer();
      DocumentPage pdfPage({
        required int id,
        required List<DocumentLayer> layers,
      }) => _ok(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(id)),
          name: 'PDF',
          size: _size(612, 792),
          layers: layers,
          extensionData: PreservedMap.empty(),
        ),
      );
      final page = pdfPage(
        id: 901,
        layers: [
          source,
          testContentLayer(id: 902, objects: [annotation]),
        ],
      );
      final other = pdfPage(
        id: 903,
        layers: [
          source.withIdentity(LayerId.fromUuid(testUuid(904))),
          testContentLayer(id: 905, objects: [testObject(id: 906)]),
        ],
      );
      final section = testSection(id: 907, pages: [page, other]);
      final original = testNotebook(resources: catalog, sections: [section]);
      final scope = DocumentIdentityScope.fromDocument(original);
      final duplicator = DocumentDuplicator(
        uuidGenerator: UuidSequenceGenerator.fromValues(
          List.generate(30, (i) => testUuid(1000 + i)),
        ),
        objectRegistry: registry,
      );
      final pageCopy = _ok(
        duplicator.duplicatePage(page, destinationScope: scope),
      );
      final sectionCopy = _ok(
        duplicator.duplicateSection(section, destinationScope: scope),
      );
      expect(pageCopy.id, isNot(page.id));
      expect(sectionCopy.id, isNot(section.id));
      final oldIds = <Object>{
        section.id,
        for (final p in section.pages) ...[
          p.id,
          for (final l in p.layers) ...[l.id, ...l.objects.map((o) => o.id)],
        ],
      };
      final newIds = <Object>[];
      for (final pages in [
        [pageCopy],
        sectionCopy.pages,
      ]) {
        final target = pages.first.layers.last.objects.single.id;
        for (final copy in pages) {
          final pdf = copy.layers.first as PdfSourceLayer;
          expect(pdf.reference, same(source.reference));
          expect(pdf.reference.resourceIdentity, resource.identity);
          expect(pdf.objects, isEmpty);
          expect(pdf.locked, source.locked);
          expect(pdf.visible, source.visible);
          expect(pdf.opacity, source.opacity);
          expect(pdf.typeSchemaVersion, source.typeSchemaVersion);
          expect(pdf.extensionData, source.extensionData);
          final remapped = copy.layers.last.objects.single;
          expect(remapped.payload, PreservedString(target.uuid.value));
          newIds.addAll([
            copy.id,
            ...copy.layers.map((l) => l.id),
            remapped.id,
          ]);
        }
      }
      expect(newIds.toSet(), hasLength(newIds.length));
      expect(newIds.where(oldIds.contains), isEmpty);
      expect(page.layers.last.objects.single, same(annotation));
      expect(annotation.payload, const PreservedString('payload'));
      expect(original.sections.single, same(section));
      final duplicatedRoot = testNotebook(
        resources: catalog,
        sections: [
          section,
          sectionCopy,
          testSection(id: 1200, pages: [pageCopy]),
        ],
      );
      expect(
        DocumentValidator(registry)
            .validateWithPlaceholders(duplicatedRoot)
            .report
            .isValid,
        isTrue,
      );
      final snapshot = _ok(
        AlnotePackageSnapshot.create(
          document: duplicatedRoot,
          resources: [DocumentResourceSnapshot(resource)],
        ),
      );
      final bytes = _ok(
        AlnotePackageCodec(objectRegistry: registry)
            .encode(snapshot, limits: phase4Limits()),
      );
      final opened = AlnotePackageReader(objectRegistry: registry).openBytes(
        bytes,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      ) as Completed<OpenedAlnotePackage, StructuredFailure>;
      final materialized = opened.value.materializeDocument(
        cancellationToken: CancellationController().token,
      ) as Completed<DocumentRoot, StructuredFailure>;
      expect(materialized.value, duplicatedRoot);
      expect(materialized.value.resources.entries, hasLength(1));
    });

    test(
      'unsupported source schema stays inert and corrupt schema one rejects',
      () {
        final futureSchema = _ok(SchemaVersion.create(2));
        final futureData = PreservedMap(<String, PreservedData>{
          'futureSecret': const PreservedString('preserve-without-reading'),
        });
        final unknown = _ok(
          UnknownLayer.create(
            id: LayerId.fromUuid(testUuid(840)),
            typeKey: LayerTypeKey.pdfSource,
            envelopeVersion: testSchemaVersion,
            typeSchemaVersion: futureSchema,
            name: 'Future source',
            role: LayerCoreRole.pdfSource,
            visible: true,
            locked: true,
            opacity: 1,
            objects: const <ObjectEnvelope>[],
            typeData: futureData,
            extensionData: PreservedMap.empty(),
          ),
        );
        final page = _ok(
          DocumentPage.create(
            id: PageId.fromUuid(testUuid(841)),
            name: 'Future PDF Page',
            size: _size(612, 792),
            layers: <DocumentLayer>[unknown, testContentLayer(id: 842)],
            extensionData: PreservedMap.empty(),
          ),
        );
        final document = _ok(
          NotebookDocument.create(
            id: DocumentId.fromUuid(testUuid(843)),
            schemaVersion: testSchemaVersion,
            title: 'Future PDF',
            resources: emptyResourceCatalog(),
            extensionData: PreservedMap.empty(),
            sections: <DocumentSection>[
              _ok(
                DocumentSection.create(
                  id: SectionId.fromUuid(testUuid(844)),
                  name: 'Section',
                  pages: <DocumentPage>[page],
                  extensionData: PreservedMap.empty(),
                ),
              ),
            ],
          ),
        );
        final registry = _ok(
          ObjectRegistry.create(<ObjectTypeDefinition>[
            PdfPageObjectTypeDefinition(_modelLimits),
          ]),
        );
        final snapshot = _ok(
          AlnotePackageSnapshot.create(
            document: document,
            resources: const <DocumentResourceSnapshot>[],
          ),
        );
        final bytes = _ok(
          AlnotePackageCodec(objectRegistry: registry)
              .encode(snapshot, limits: phase4Limits()),
        );
        final opened = AlnotePackageReader(objectRegistry: registry).openBytes(
          bytes,
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
        );
        final materialized =
            (opened as Completed<OpenedAlnotePackage, StructuredFailure>).value
                .materializeDocument(
                  cancellationToken: CancellationController().token,
                );
        final reopened =
            (materialized as Completed<DocumentRoot, StructuredFailure>).value;
        final reopenedLayer = reopened.pages.single.layers.first;
        expect(reopenedLayer, isA<UnknownLayer>());
        expect(reopenedLayer, unknown);
        expect(reopenedLayer.typeData, futureData);

        final corrupt = PdfSourceLayer.reopen(
          id: LayerId.fromUuid(testUuid(845)),
          envelopeVersion: testSchemaVersion,
          typeSchemaVersion: pdfPageReferenceSchemaVersion,
          name: 'Corrupt',
          visible: true,
          locked: true,
          opacity: 1,
          objects: const <ObjectEnvelope>[],
          typeData: PreservedMap(<String, PreservedData>{
            'password': const PreservedString('never-leak-this'),
          }),
          extensionData: PreservedMap.empty(),
          limits: _modelLimits,
        );
        expect(corrupt, isA<Err<PdfSourceLayer, StructuredFailure>>());
        expect(corrupt.toString(), isNot(contains('never-leak-this')));
      },
    );

    test('standalone PDF rejects a mismatched movable Object resource', () {
      final otherReference = _ok(
        PdfPageReference.create(
          resourceIdentity: ResourceIdentity.fromUuid(testUuid(846)),
          pageIndex: 0,
          boxKind: PdfPageBoxKind.cropBox,
          sourceBox: _box(),
          rotation: PdfPageRotation.degrees0,
          displayedWidth: 612,
          displayedHeight: 792,
          limits: _modelLimits,
        ),
      );
      final payload = _ok(
        PdfPageObjectPayload.create(
          reference: otherReference,
          clip: PdfPageClip.full,
          limits: _modelLimits,
        ),
      );
      final page = _ok(
        DocumentPage.create(
          id: PageId.fromUuid(testUuid(847)),
          name: 'Mismatch',
          size: _size(612, 792),
          layers: <DocumentLayer>[
            _sourceLayer(),
            testContentLayer(
              id: 848,
              objects: <ObjectEnvelope>[
                testObject(
                  id: 849,
                  typeKey: pdfPageObjectTypeKey,
                  schemaVersion: pdfPageObjectSchemaVersion,
                  payload: payload.encode(),
                ),
              ],
            ),
          ],
          extensionData: PreservedMap.empty(),
        ),
      );
      expect(
        StandalonePdfDocument.create(
          id: DocumentId.fromUuid(testUuid(850)),
          schemaVersion: testSchemaVersion,
          title: 'Mismatch',
          resources: emptyResourceCatalog(),
          extensionData: PreservedMap.empty(),
          pages: <DocumentPage>[page],
          source: ResourceReference(_reference().resourceIdentity),
        ),
        isA<Err<StandalonePdfDocument, StructuredFailure>>(),
      );
    });
  });

  group('backend cancellation, quarantine, and redaction', () {
    test('cancellation is checked before, during, and after capture', () {
      final before = CancellationController()..cancel('secret-password');
      expect(
        PdfResourceBytes.capture(
          identity: ResourceIdentity.fromUuid(testUuid(840)),
          bytes: <int>[1],
          limits: _processingLimits,
          cancellationToken: before.token,
        ).toString(),
        isNot(contains('secret-password')),
      );
      final during = CancellationController();
      expect(
        PdfResourceBytes.capture(
          identity: ResourceIdentity.fromUuid(testUuid(840)),
          bytes: _CancellingBytes(during, cancelOnTerminal: false),
          limits: _processingLimits,
          cancellationToken: during.token,
        ),
        isA<Err<PdfResourceBytes, StructuredFailure>>(),
      );
      final after = CancellationController();
      expect(
        PdfResourceBytes.capture(
          identity: ResourceIdentity.fromUuid(testUuid(840)),
          bytes: _CancellingBytes(after, cancelOnTerminal: true),
          limits: _processingLimits,
          cancellationToken: after.token,
        ),
        isA<Err<PdfResourceBytes, StructuredFailure>>(),
      );
    });

    test('inspection is bounded and hostile iterables cannot leak', () {
      final page = _ok(
        PdfInspectedPage.create(
          pageIndex: 0,
          boxKind: PdfPageBoxKind.cropBox,
          sourceBox: _box(),
          rotation: PdfPageRotation.degrees0,
          displayedWidth: 612,
          displayedHeight: 792,
          limits: _modelLimits,
        ),
      );
      final outcome = PdfInspectSuccess.capture(
        backendIdentity: _ok(PdfBackendIdentity.parse('fixed.backend')),
        pages: _ThrowingPages(page),
        modelLimits: _modelLimits,
        limits: _processingLimits,
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<PdfCorrupt>());
      expect(outcome.toString(), isNot(contains('private')));
      expect(
        const PdfPasswordRequired().toString(),
        isNot(contains('password')),
      );
    });

    test(
      'quarantined backend rejects untrusted bytes before resource access',
      () async {
        final reader = _CountingPdfReader();
        const backend = QuarantinedPdfBackend();
        final outcome = await const QuarantinedPdfBackend().inspect(
          PdfInspectRequest(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(841)),
            trust: PdfInputTrust.untrusted,
            modelLimits: _modelLimits,
            limits: _processingLimits,
            cancellationToken: CancellationController().token,
          ),
          resourceReader: reader,
        );
        expect(outcome, isA<PdfQuarantined>());
        final renderRequest = _ok(
          PdfRenderRequest.create(
            reference: _reference(),
            trust: PdfInputTrust.untrusted,
            region: PdfPageClip.full,
            pixelWidth: 1,
            pixelHeight: 1,
            includeSafeNativeAppearances: false,
            limits: _processingLimits,
            cancellationToken: CancellationController().token,
          ),
        );
        final rendered = await backend.render(
          renderRequest,
          resourceReader: reader,
        );
        expect(
          (rendered as PdfRenderFailure).reason,
          PdfRenderFailureReason.quarantined,
        );
        expect(reader.calls, 0);
      },
    );

    test(
      'RGBA, text, links, and placeholders remain bounded and immutable',
      () {
        final huge = _ok(
          PdfProcessingLimits.create(
            maximumEncodedBytes: 1,
            maximumPageCount: 1,
            maximumRenderDimension: 94906265,
            maximumRenderPixels: 9007199136250225,
            maximumExtractedGlyphs: 1,
            maximumLinks: 1,
            maximumOperations: 1,
          ),
        );
        expect(
          PdfRenderRequest.create(
            reference: _reference(),
            trust: PdfInputTrust.trustedDevelopmentFixture,
            region: PdfPageClip.full,
            pixelWidth: maximumWebSafeInteger,
            pixelHeight: 2,
            includeSafeNativeAppearances: false,
            limits: huge,
            cancellationToken: CancellationController().token,
          ),
          isA<Err<PdfRenderRequest, StructuredFailure>>(),
        );
        expect(
          PdfExtractedText.capture(
            text: 'ab',
            limits: huge,
            cancellationToken: CancellationController().token,
          ),
          isA<Err<PdfExtractedText, StructuredFailure>>(),
        );
        final link = _ok(
          PdfSafeLinkMetadata.create(
            bounds: _rect(0, 0, 1, 1),
            kind: PdfSafeLinkKind.externalReference,
            limits: huge,
          ),
        );
        final links = _ok(
          PdfSafeLinks.capture(
            links: <PdfSafeLinkMetadata>[link],
            limits: huge,
            cancellationToken: CancellationController().token,
          ),
        );
        expect(links.links.clear, throwsUnsupportedError);
        for (final reason in PdfPlaceholderReason.values) {
          final placeholder = PdfPagePlaceholder(
            reference: _reference(),
            reason: reason,
          );
          expect(placeholder.bounds, _rect(0, 0, 612, 792));
          expect(placeholder.toString(), isNot(contains(testUuid(800).value)));
        }
      },
    );
  });
}

PdfSourceBox _box() => _ok(
  PdfSourceBox.create(
    left: 0,
    bottom: 0,
    right: 612,
    top: 792,
    limits: _modelLimits,
  ),
);

PdfPageReference _reference({
  PdfPageBoxKind boxKind = PdfPageBoxKind.cropBox,
  PdfPageRotation rotation = PdfPageRotation.degrees0,
  PdfSourceBox? sourceBox,
  PreservedMap? unknownFields,
}) => _ok(
  PdfPageReference.create(
    resourceIdentity: ResourceIdentity.fromUuid(testUuid(800)),
    pageIndex: 3,
    boxKind: boxKind,
    sourceBox: sourceBox ?? _box(),
    rotation: rotation,
    displayedWidth: rotation.swapsDimensions
        ? (sourceBox ?? _box()).height
        : (sourceBox ?? _box()).width,
    displayedHeight: rotation.swapsDimensions
        ? (sourceBox ?? _box()).width
        : (sourceBox ?? _box()).height,
    limits: _modelLimits,
    unknownFields: unknownFields,
  ),
);

PdfSourceLayer _sourceLayer({
  PreservedMap? extensionData,
  PdfPageBoxKind boxKind = PdfPageBoxKind.cropBox,
}) => _ok(
  PdfSourceLayer.create(
    id: LayerId.fromUuid(testUuid(820)),
    envelopeVersion: testSchemaVersion,
    name: 'PDF source',
    visible: true,
    opacity: 1,
    reference: _reference(
      boxKind: boxKind,
      unknownFields: PreservedMap(<String, PreservedData>{
        'futureReference': const PreservedBoolean(true),
      }),
    ),
    limits: _modelLimits,
    extensionData: extensionData,
  ),
);

DocumentResource _pdfResource() => _ok(
  DocumentResource.capture(
    identity: ResourceIdentity.fromUuid(testUuid(800)),
    mediaType: pdfResourceMediaType,
    role: pdfSourceResourceRole,
    schemaVersion: testSchemaVersion,
    bytes: const <int>[0x25, 0x50, 0x44, 0x46],
  ),
);

Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));

Rect2 _rect(double left, double top, double right, double bottom) =>
    _ok(Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom));

Size2 _size(double width, double height) =>
    _ok(Size2.create(width: width, height: height));

Vector2 _vector(double x, double y) => _ok(Vector2.create(x: x, y: y));

PreservedInteger _integer(int value) => _ok(PreservedInteger.create(value));

T _ok<T>(Result<T, StructuredFailure> result) =>
    (result as Ok<T, StructuredFailure>).value;

final class _ThrowingBytes extends Iterable<int> {
  @override
  Iterator<int> get iterator => _ThrowingByteIterator();
}

final class _ThrowingByteIterator implements Iterator<int> {
  var _moved = false;

  @override
  int get current => 0x25;

  @override
  bool moveNext() {
    if (_moved) throw StateError('private PDF bytes');
    _moved = true;
    return true;
  }
}

final class _CancellingBytes extends Iterable<int> {
  _CancellingBytes(this.controller, {required this.cancelOnTerminal});

  final CancellationController controller;
  final bool cancelOnTerminal;

  @override
  Iterator<int> get iterator =>
      _CancellingByteIterator(controller, cancelOnTerminal: cancelOnTerminal);
}

final class _CancellingByteIterator implements Iterator<int> {
  _CancellingByteIterator(this.controller, {required this.cancelOnTerminal});

  final CancellationController controller;
  final bool cancelOnTerminal;
  var moves = 0;

  @override
  int get current => 0x25;

  @override
  bool moveNext() {
    moves += 1;
    if (moves == 1) {
      if (!cancelOnTerminal) controller.cancel('private-during');
      return true;
    }
    if (cancelOnTerminal) controller.cancel('private-after');
    return false;
  }
}

final class _ThrowingPages extends Iterable<PdfInspectedPage> {
  _ThrowingPages(this.page);
  final PdfInspectedPage page;

  @override
  Iterator<PdfInspectedPage> get iterator => _ThrowingPageIterator(page);
}

final class _ThrowingPageIterator implements Iterator<PdfInspectedPage> {
  _ThrowingPageIterator(this.page);
  final PdfInspectedPage page;
  var moved = false;

  @override
  PdfInspectedPage get current => page;

  @override
  bool moveNext() {
    if (moved) throw StateError('private inspected text');
    moved = true;
    return true;
  }
}

final class _CountingPdfReader implements PdfResourceReader {
  var calls = 0;

  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async {
    calls += 1;
    return Err<PdfResourceBytes, StructuredFailure>(
      StructuredFailure(
        code: 'test.reader.unavailable',
        category: FailureCategory.dependency,
        retryDisposition: RetryDisposition.never,
        message: 'Unavailable.',
      ),
    );
  }
}
