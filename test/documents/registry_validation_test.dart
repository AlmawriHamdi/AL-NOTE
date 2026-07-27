// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/uuid_sequence_generator.dart';

void main() {
  group('Object Registry', () {
    test('construction rejects duplicate keys and copies inputs', () {
      final definition = TestObjectTypeDefinition();
      final source = <ObjectTypeDefinition>[definition];
      final registry = testRegistry(source);
      source.clear();

      expect(registry.definitions, hasLength(1));
      expect(registry.definitions.clear, throwsUnsupportedError);
      expect(
        ObjectRegistry.create(<ObjectTypeDefinition>[definition, definition]),
        isA<Err<ObjectRegistry, StructuredFailure>>(),
      );
    });

    for (final getter in _MetadataGetter.values) {
      test('${getter.name} metadata failure is contained and redacted', () {
        const secret = 'secret metadata getter explosion';
        late Result<ObjectRegistry, StructuredFailure> result;

        expect(() {
          result = ObjectRegistry.create(<ObjectTypeDefinition>[
            _AdversarialMetadataDefinition(
              throwingGetter: getter,
              secret: secret,
            ),
          ]);
        }, returnsNormally);

        final failure =
            (result as Err<ObjectRegistry, StructuredFailure>).error;
        expect(failure.code, 'documents.objects.definition_metadata_failure');
        expect(failure.category, FailureCategory.dependency);
        expect(failure.retryDisposition, RetryDisposition.never);
        for (final diagnostic in <String>[
          failure.code,
          failure.message,
          failure.toString(),
          result.toString(),
        ]) {
          expect(diagnostic, isNot(contains(secret)));
          expect(diagnostic, isNot(contains(getter.name)));
        }
      });
    }

    test('captured collection metadata cannot change Registry behavior', () {
      final versionTwo = modelValue<SchemaVersion>(SchemaVersion.create(2));
      final supportedVersions = <SchemaVersion>[testSchemaVersion];
      final migrations = <ObjectPayloadMigrationContract>[
        ObjectPayloadMigrationContract(
          fromSchemaVersion: testSchemaVersion,
          toSchemaVersion: versionTwo,
        ),
      ];
      final definition = _AdversarialMetadataDefinition(
        supportedSchemaVersions: supportedVersions,
        migrations: migrations,
      );
      final registry = modelValue<ObjectRegistry>(
        ObjectRegistry.create(<ObjectTypeDefinition>[definition]),
      );
      final captured = registry.definitions.values.single;

      supportedVersions
        ..clear()
        ..add(versionTwo);
      migrations.clear();

      expect(captured.supportedSchemaVersions, <SchemaVersion>[
        testSchemaVersion,
      ]);
      expect(captured.supportedSchemaVersions.clear, throwsUnsupportedError);
      expect(captured.migrations, <ObjectPayloadMigrationContract>[
        ObjectPayloadMigrationContract(
          fromSchemaVersion: testSchemaVersion,
          toSchemaVersion: versionTwo,
        ),
      ]);
      expect(captured.migrations.clear, throwsUnsupportedError);
      expect(registry.resolve(testObject()), isA<SupportedObjectResolution>());
      expect(
        registry.resolve(testObject(schemaVersion: versionTwo)),
        isA<UnsupportedObjectSchemaResolution>(),
      );
    });

    test('captured metadata is never reread by public model operations', () {
      const secret = 'secret late metadata access';
      final definition = _AdversarialMetadataDefinition(
        throwAfterFirstRead: true,
        secret: secret,
      );
      final registry = modelValue<ObjectRegistry>(
        ObjectRegistry.create(<ObjectTypeDefinition>[definition]),
      );
      final object = testObject(id: 180);
      final document = _documentWithObject(object);
      final validator = DocumentValidator(registry);
      final layer = document.pages.single.layers.single;
      final replacement = testObject(
        id: 180,
        payload: const PreservedString('replacement'),
      );

      expect(registry.resolve(object), isA<SupportedObjectResolution>());
      final validation = validator.validateWithPlaceholders(document);
      expect(validation.report.issues, isEmpty);
      expect(validation.placeholders, isEmpty);
      expect(
        DocumentReplacement(validator).replaceObjectInLayer(
          layer: layer,
          targetId: object.id,
          replacement: replacement,
        ),
        isA<Ok<DocumentLayer, StructuredFailure>>(),
      );
      expect(
        DocumentDuplicator(
          uuidGenerator: UuidSequenceGenerator.fromValues(<UuidIdentifier>[
            testUuid(181),
          ]),
          objectRegistry: registry,
        ).duplicateObject(object, destinationScope: DocumentIdentityScope()),
        isA<Ok<ObjectEnvelope, StructuredFailure>>(),
      );
      expect(definition.metadataReads, <_MetadataGetter, int>{
        for (final getter in _MetadataGetter.values) getter: 1,
      });
      expect(registry.toString(), isNot(contains(secret)));
      expect(validation.toString(), isNot(contains(secret)));
    });

    test('distinguishes supported, unsupported, invalid, and unknown', () {
      final registry = testRegistry();
      final supported = testObject();
      final unsupported = testObject(
        schemaVersion: modelValue<SchemaVersion>(SchemaVersion.create(2)),
      );
      final invalid = testObject(payload: const PreservedString('invalid'));
      final unknown = testObject(
        typeKey: testObjectTypeKey('example.unknown.object'),
      );

      expect(registry.resolve(supported), isA<SupportedObjectResolution>());
      expect(
        registry.resolve(unsupported),
        isA<UnsupportedObjectSchemaResolution>(),
      );
      expect(registry.resolve(invalid), isA<InvalidObjectPayloadResolution>());
      expect(registry.resolve(unknown), isA<UnknownObjectTypeResolution>());
    });

    test('exposes immutable capabilities, geometry, and references', () {
      final resourceId = ResourceIdentity.fromUuid(testUuid(200));
      final versionTwo = modelValue<SchemaVersion>(SchemaVersion.create(2));
      final definition = TestObjectTypeDefinition(
        migrations: <ObjectPayloadMigrationContract>[
          ObjectPayloadMigrationContract(
            fromSchemaVersion: testSchemaVersion,
            toSchemaVersion: versionTwo,
          ),
        ],
        references: <ResourceReference>[ResourceReference(resourceId)],
      );
      final envelope = testObject();
      final resolution =
          testRegistry(<ObjectTypeDefinition>[definition]).resolve(envelope)
              as SupportedObjectResolution;

      expect(
        resolution.definition.capabilities,
        const ObjectTypeCapabilities(
          hasIntrinsicGeometry: true,
          discoversResourceReferences: true,
          supportsScopedDuplication: true,
        ),
      );
      final geometry = modelValue<Rect2>(
        definition.intrinsicGeometry(
          envelope.payload,
          envelope.typeSchemaVersion,
        ),
      );
      expect(geometry.width, 10);
      expect(geometry.height, 20);
      final references = modelValue<List<ResourceReference>>(
        definition.resourceReferences(
          envelope.payload,
          envelope.typeSchemaVersion,
        ),
      );
      expect(references, <ResourceReference>[ResourceReference(resourceId)]);
      expect(references.clear, throwsUnsupportedError);
      expect(definition.migrations, <ObjectPayloadMigrationContract>[
        ObjectPayloadMigrationContract(
          fromSchemaVersion: testSchemaVersion,
          toSchemaVersion: versionTwo,
        ),
      ]);
      expect(definition.migrations.clear, throwsUnsupportedError);
    });

    test('unexpected definition behavior resolves as unavailable', () {
      const secret = 'secret payload validation exception';
      final definition = TestObjectTypeDefinition(
        validationExceptionMessage: secret,
      );
      final registry = testRegistry(<ObjectTypeDefinition>[definition]);
      expect(
        registry.resolve(testObject()),
        isA<UnavailableObjectBehaviorResolution>(),
      );
      final validation = DocumentValidator(
        registry,
      ).validateWithPlaceholders(_documentWithObject(testObject()));
      expect(validation.report.warnings, hasLength(1));
      expect(
        validation.report.warnings.single.code,
        ValidationIssueCode.unavailableBehavior,
      );
      expect(validation.placeholders, hasLength(1));
      expect(
        validation.placeholders.single,
        isA<ObjectPlaceholderDescriptor>(),
      );
      expect(
        validation.report.warnings.single.toString(),
        isNot(contains(secret)),
      );
      expect(
        validation.placeholders.single.toString(),
        isNot(contains(secret)),
      );
      expect(validation.toString(), isNot(contains(secret)));
    });
  });

  group('Document validation and placeholders', () {
    test('declared intrinsic geometry is invoked successfully', () {
      var geometryCalls = 0;
      final definition = TestObjectTypeDefinition(
        capabilities: const ObjectTypeCapabilities(
          hasIntrinsicGeometry: true,
          discoversResourceReferences: false,
          supportsScopedDuplication: true,
        ),
        onGeometry: () {
          geometryCalls += 1;
        },
      );
      final result = DocumentValidator(
        testRegistry(<ObjectTypeDefinition>[definition]),
      ).validateWithPlaceholders(_documentWithObject(testObject()));

      expect(geometryCalls, 1);
      expect(result.report.issues, isEmpty);
      expect(result.placeholders, isEmpty);
    });

    test('geometry Err becomes unavailable warning and placeholder', () {
      final definition = TestObjectTypeDefinition(
        capabilities: const ObjectTypeCapabilities(
          hasIntrinsicGeometry: true,
          discoversResourceReferences: false,
          supportsScopedDuplication: true,
        ),
        failGeometry: true,
      );
      final result = DocumentValidator(
        testRegistry(<ObjectTypeDefinition>[definition]),
      ).validateWithPlaceholders(_documentWithObject(testObject()));

      expect(result.report.isValid, isTrue);
      expect(
        result.report.warnings.single.code,
        ValidationIssueCode.unavailableBehavior,
      );
      expect(result.placeholders.single, isA<ObjectPlaceholderDescriptor>());
    });

    test('geometry exception becomes unavailable warning and placeholder', () {
      final definition = TestObjectTypeDefinition(
        capabilities: const ObjectTypeCapabilities(
          hasIntrinsicGeometry: true,
          discoversResourceReferences: false,
          supportsScopedDuplication: true,
        ),
        throwGeometry: true,
      );
      final result = DocumentValidator(
        testRegistry(<ObjectTypeDefinition>[definition]),
      ).validateWithPlaceholders(_documentWithObject(testObject()));

      expect(result.report.isValid, isTrue);
      expect(
        result.report.warnings.single.code,
        ValidationIssueCode.unavailableBehavior,
      );
      expect(result.placeholders.single, isA<ObjectPlaceholderDescriptor>());
    });

    test('undeclared geometry and resource behaviors are not invoked', () {
      var geometryCalls = 0;
      var resourceCalls = 0;
      final definition = TestObjectTypeDefinition(
        capabilities: const ObjectTypeCapabilities(
          hasIntrinsicGeometry: false,
          discoversResourceReferences: false,
          supportsScopedDuplication: true,
        ),
        onGeometry: () {
          geometryCalls += 1;
        },
        onResourceDiscovery: () {
          resourceCalls += 1;
        },
      );
      final result = DocumentValidator(
        testRegistry(<ObjectTypeDefinition>[definition]),
      ).validateWithPlaceholders(_documentWithObject(testObject()));

      expect(geometryCalls, 0);
      expect(resourceCalls, 0);
      expect(result.report.issues, isEmpty);
      expect(result.placeholders, isEmpty);
    });

    test('required resource exception becomes unavailable evidence', () {
      final definition = TestObjectTypeDefinition(
        capabilities: const ObjectTypeCapabilities(
          hasIntrinsicGeometry: false,
          discoversResourceReferences: true,
          supportsScopedDuplication: true,
        ),
        throwResourceDiscovery: true,
      );
      final result = DocumentValidator(
        testRegistry(<ObjectTypeDefinition>[definition]),
      ).validateWithPlaceholders(_documentWithObject(testObject()));

      expect(result.report.isValid, isTrue);
      expect(
        result.report.warnings.single.code,
        ValidationIssueCode.unavailableBehavior,
      );
      expect(result.placeholders.single, isA<ObjectPlaceholderDescriptor>());
    });

    test('multiple required failures produce one safe evidence pair', () {
      const secret = 'sensitive-payload-value';
      var geometryCalls = 0;
      var resourceCalls = 0;
      final definition = TestObjectTypeDefinition(
        failGeometry: true,
        failResourceDiscovery: true,
        onGeometry: () {
          geometryCalls += 1;
        },
        onResourceDiscovery: () {
          resourceCalls += 1;
        },
      );
      final object = testObject(payload: const PreservedString(secret));
      final result = DocumentValidator(
        testRegistry(<ObjectTypeDefinition>[definition]),
      ).validateWithPlaceholders(_documentWithObject(object));

      expect(geometryCalls, 1);
      expect(resourceCalls, 1);
      expect(result.report.warnings, hasLength(1));
      expect(
        result.report.warnings.single.code,
        ValidationIssueCode.unavailableBehavior,
      );
      expect(result.placeholders, hasLength(1));
      expect(result.report.warnings.single.toString(), isNot(contains(secret)));
      expect(result.placeholders.single.toString(), isNot(contains(secret)));
      expect(result.toString(), isNot(contains(secret)));
      final failure =
          definition.intrinsicGeometry(object.payload, object.typeSchemaVersion)
              as Err<Rect2, StructuredFailure>;
      expect(failure.error.toString(), isNot(contains(secret)));
    });

    test(
      'unknown Object and Layer remain valid warnings and inert evidence',
      () {
        const secret = 'payload-secret';
        final object = testObject(
          typeKey: testObjectTypeKey('example.unknown.object'),
          payload: const PreservedString(secret),
        );
        final layer = testUnknownLayer(
          name: 'sensitive-layer-name',
          objects: <ObjectEnvelope>[object],
          typeData: const PreservedString(secret),
        );
        final document = testNotebook(
          title: 'sensitive-title',
          sections: <DocumentSection>[
            testSection(
              pages: <DocumentPage>[
                testPage(layers: <DocumentLayer>[layer]),
              ],
            ),
          ],
        );
        final result = DocumentValidator(
          testRegistry(),
        ).validateWithPlaceholders(document);

        expect(result.report.isValid, isTrue);
        expect(
          result.report.issues.map((issue) => issue.code),
          containsAll(<ValidationIssueCode>[
            ValidationIssueCode.unknownLayerType,
            ValidationIssueCode.unknownObjectType,
          ]),
        );
        expect(result.placeholders, hasLength(2));
        expect(
          result.placeholders,
          containsAll(<PlaceholderDescriptor>[
            LayerPlaceholderDescriptor(
              reason: PlaceholderReason.unknownLayerType,
              layerId: layer.id,
              typeKey: layer.typeKey,
            ),
            ObjectPlaceholderDescriptor(
              reason: PlaceholderReason.unknownObjectType,
              objectId: object.id,
              typeKey: object.typeKey,
            ),
          ]),
        );
        expect(result.toString(), isNot(contains(secret)));
        for (final issue in result.report.issues) {
          expect(issue.toString(), isNot(contains(secret)));
          expect(issue.toString(), isNot(contains('sensitive')));
        }
      },
    );

    test('unsupported schema warns while invalid known payload errors', () {
      final unsupported = testObject(
        id: 210,
        schemaVersion: modelValue<SchemaVersion>(SchemaVersion.create(2)),
      );
      final unsupportedDocument = testNotebook(
        sections: <DocumentSection>[
          testSection(
            pages: <DocumentPage>[
              testPage(
                layers: <DocumentLayer>[
                  testContentLayer(objects: <ObjectEnvelope>[unsupported]),
                ],
              ),
            ],
          ),
        ],
      );
      final validator = DocumentValidator(testRegistry());
      final unsupportedResult = validator.validateWithPlaceholders(
        unsupportedDocument,
      );
      expect(unsupportedResult.report.isValid, isTrue);
      expect(
        unsupportedResult.report.warnings.single.code,
        ValidationIssueCode.unsupportedObjectSchema,
      );
      expect(
        unsupportedResult.placeholders.single,
        isA<ObjectPlaceholderDescriptor>(),
      );

      final invalid = testObject(
        id: 211,
        payload: const PreservedString('invalid'),
      );
      final invalidDocument = testNotebook(
        sections: <DocumentSection>[
          testSection(
            pages: <DocumentPage>[
              testPage(
                layers: <DocumentLayer>[
                  testContentLayer(objects: <ObjectEnvelope>[invalid]),
                ],
              ),
            ],
          ),
        ],
      );
      final invalidReport = validator.validate(invalidDocument);
      expect(invalidReport.isValid, isFalse);
      expect(
        invalidReport.errors.map((issue) => issue.code),
        contains(ValidationIssueCode.invalidObjectPayload),
      );
    });

    test(
      'missing resource preserves references and produces safe evidence',
      () {
        final resourceId = ResourceIdentity.fromUuid(testUuid(220));
        final definition = TestObjectTypeDefinition(
          references: <ResourceReference>[ResourceReference(resourceId)],
        );
        final object = testObject();
        final document = testNotebook(
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
        final result = DocumentValidator(
          testRegistry(<ObjectTypeDefinition>[definition]),
        ).validateWithPlaceholders(document);

        expect(result.report.isValid, isTrue);
        expect(
          result.report.warnings.single.code,
          ValidationIssueCode.missingResource,
        );
        expect(
          result.placeholders.single,
          ResourcePlaceholderDescriptor(
            reason: PlaceholderReason.missingResource,
            resourceIdentity: resourceId,
          ),
        );
        expect(
          modelValue<List<ResourceReference>>(
            definition.resourceReferences(
              object.payload,
              object.typeSchemaVersion,
            ),
          ).single.identity,
          resourceId,
        );
      },
    );

    test('available PDF source has no placeholder; missing source does', () {
      final resourceId = ResourceIdentity.fromUuid(testUuid(230));
      final availableCatalog = modelValue<ResourceCatalog>(
        ResourceCatalog.create(<ResourceCatalogEntry>[
          ResourceCatalogEntry(resourceId),
        ]),
      );
      StandalonePdfDocument create(ResourceCatalog catalog) =>
          modelValue<StandalonePdfDocument>(
            StandalonePdfDocument.create(
              id: DocumentId.fromUuid(testUuid(231)),
              schemaVersion: testSchemaVersion,
              title: 'private',
              resources: catalog,
              extensionData: PreservedMap.empty(),
              pages: <DocumentPage>[testPage()],
              source: ResourceReference(resourceId),
            ),
          );
      final validator = DocumentValidator(testRegistry());

      expect(
        validator
            .validateWithPlaceholders(create(availableCatalog))
            .placeholders,
        isEmpty,
      );
      final missing = validator.validateWithPlaceholders(
        create(emptyResourceCatalog()),
      );
      expect(missing.report.isValid, isTrue);
      expect(missing.placeholders.single, isA<ResourcePlaceholderDescriptor>());
    });

    test('issue order is deterministic across repeated validation', () {
      final unknownObject = testObject(
        typeKey: testObjectTypeKey('example.unknown.object'),
      );
      final document = testNotebook(
        sections: <DocumentSection>[
          testSection(
            pages: <DocumentPage>[
              testPage(
                layers: <DocumentLayer>[
                  testUnknownLayer(objects: <ObjectEnvelope>[unknownObject]),
                ],
              ),
            ],
          ),
        ],
      );
      final validator = DocumentValidator(testRegistry());

      expect(
        validator.validate(document).issues,
        validator.validate(document).issues,
      );
    });

    test('trusted validation boundaries accept only closed enum values', () {
      for (final segment in ValidationPathSegment.values) {
        expect(
          ValidationPathSegment.parseTrusted(segment.trustedName),
          Ok<ValidationPathSegment, StructuredFailure>(segment),
        );
      }
      for (final code in ValidationIssueCode.values) {
        expect(
          ValidationIssueCode.parseTrusted(code.stableCode),
          Ok<ValidationIssueCode, StructuredFailure>(code),
        );
      }
      expect(
        ValidationPathSegment.parseTrusted('private-title'),
        isA<Err<ValidationPathSegment, StructuredFailure>>(),
      );
      expect(
        ValidationIssueCode.parseTrusted('documents.validation.private'),
        isA<Err<ValidationIssueCode, StructuredFailure>>(),
      );
    });
  });
}

NotebookDocument _documentWithObject(ObjectEnvelope object) => testNotebook(
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

enum _MetadataGetter {
  typeKey,
  supportedSchemaVersions,
  capabilities,
  migrations,
}

final class _AdversarialMetadataDefinition implements ObjectTypeDefinition {
  _AdversarialMetadataDefinition({
    this.throwingGetter,
    this.throwAfterFirstRead = false,
    this.secret = 'secret definition metadata',
    ObjectTypeKey? typeKey,
    List<SchemaVersion>? supportedSchemaVersions,
    ObjectTypeCapabilities capabilities = const ObjectTypeCapabilities(
      hasIntrinsicGeometry: false,
      discoversResourceReferences: false,
      supportsScopedDuplication: true,
    ),
    List<ObjectPayloadMigrationContract>? migrations,
  }) : _typeKey = typeKey ?? testObjectTypeKey(),
       _supportedSchemaVersions =
           supportedSchemaVersions ?? <SchemaVersion>[testSchemaVersion],
       _capabilities = capabilities,
       _migrations = migrations ?? <ObjectPayloadMigrationContract>[];

  final _MetadataGetter? throwingGetter;
  final bool throwAfterFirstRead;
  final String secret;
  final ObjectTypeKey _typeKey;
  final List<SchemaVersion> _supportedSchemaVersions;
  final ObjectTypeCapabilities _capabilities;
  final List<ObjectPayloadMigrationContract> _migrations;
  final Map<_MetadataGetter, int> _metadataReads = <_MetadataGetter, int>{};

  Map<_MetadataGetter, int> get metadataReads =>
      Map<_MetadataGetter, int>.unmodifiable(_metadataReads);

  @override
  ObjectTypeKey get typeKey => _read(_MetadataGetter.typeKey, _typeKey);

  @override
  List<SchemaVersion> get supportedSchemaVersions =>
      _read(_MetadataGetter.supportedSchemaVersions, _supportedSchemaVersions);

  @override
  ObjectTypeCapabilities get capabilities =>
      _read(_MetadataGetter.capabilities, _capabilities);

  @override
  List<ObjectPayloadMigrationContract> get migrations =>
      _read(_MetadataGetter.migrations, _migrations);

  T _read<T>(_MetadataGetter getter, T value) {
    final priorReads = _metadataReads[getter] ?? 0;
    _metadataReads[getter] = priorReads + 1;
    if (throwingGetter == getter || throwAfterFirstRead && priorReads > 0) {
      throw StateError('$secret: ${getter.name}');
    }
    return value;
  }

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => Ok<PreservedData, StructuredFailure>(payload);

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => Rect2.fromEdges(left: 0, top: 0, right: 1, bottom: 1);

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => const Ok<List<ResourceReference>, StructuredFailure>(
    <ResourceReference>[],
  );

  @override
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => ValidationReport(const <ValidationIssue>[]);
}
