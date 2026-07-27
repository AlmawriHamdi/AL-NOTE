// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';

/// Parses a deterministic non-nil RFC 9562-shaped test UUID.
UuidIdentifier testUuid(int value) {
  final suffix = value.toString().padLeft(12, '0');
  return (UuidIdentifier.parse('00000000-0000-4000-8000-$suffix')
          as Ok<UuidIdentifier, StructuredFailure>)
      .value;
}

/// Returns schema version one.
SchemaVersion get testSchemaVersion =>
    (SchemaVersion.create(1) as Ok<SchemaVersion, StructuredFailure>).value;

/// Returns the identity affine transform.
AffineTransform2D get testTransform =>
    (AffineTransform2D.fromOperation(const IdentityTransformOperation2D())
            as Ok<AffineTransform2D, StructuredFailure>)
        .value;

/// Returns a strictly positive test Page size.
Size2 get testPageSize =>
    (Size2.create(width: 600, height: 800) as Ok<Size2, StructuredFailure>)
        .value;

/// Unwraps a successful model result.
T modelValue<T>(Result<T, StructuredFailure> result) =>
    (result as Ok<T, StructuredFailure>).value;

/// Creates a permanent test Object type key.
ObjectTypeKey testObjectTypeKey([String value = 'example.test.object']) =>
    modelValue<ObjectTypeKey>(ObjectTypeKey.parse(value));

/// Creates a permanent test unknown Layer type key.
LayerTypeKey testLayerTypeKey([String value = 'example.test.layer']) =>
    modelValue<LayerTypeKey>(LayerTypeKey.parse(value));

/// Creates a minimal Object envelope.
ObjectEnvelope testObject({
  int id = 1,
  ObjectTypeKey? typeKey,
  SchemaVersion? schemaVersion,
  PreservedData? payload,
  bool visible = true,
  bool locked = false,
  AffineTransform2D? transform,
  PreservedMap? extensionData,
}) => modelValue<ObjectEnvelope>(
  ObjectEnvelope.create(
    id: ObjectId.fromUuid(testUuid(id)),
    typeKey: typeKey ?? testObjectTypeKey(),
    envelopeVersion: testSchemaVersion,
    typeSchemaVersion: schemaVersion ?? testSchemaVersion,
    transform: transform ?? testTransform,
    visible: visible,
    locked: locked,
    payload: payload ?? const PreservedString('payload'),
    extensionData: extensionData ?? PreservedMap.empty(),
  ),
);

/// Creates a built-in content Layer.
ContentLayer testContentLayer({
  int id = 10,
  String name = 'Layer',
  double opacity = 1,
  bool visible = true,
  bool locked = false,
  Iterable<ObjectEnvelope> objects = const <ObjectEnvelope>[],
  PreservedData? typeData,
  PreservedMap? extensionData,
}) => modelValue<ContentLayer>(
  ContentLayer.create(
    id: LayerId.fromUuid(testUuid(id)),
    envelopeVersion: testSchemaVersion,
    typeSchemaVersion: testSchemaVersion,
    name: name,
    visible: visible,
    locked: locked,
    opacity: opacity,
    objects: objects,
    typeData: typeData ?? PreservedMap.empty(),
    extensionData: extensionData ?? PreservedMap.empty(),
  ),
);

/// Creates an inert unknown Layer.
UnknownLayer testUnknownLayer({
  int id = 11,
  String name = 'Unknown Layer',
  LayerCoreRole role = LayerCoreRole.content,
  Iterable<ObjectEnvelope> objects = const <ObjectEnvelope>[],
  LayerTypeKey? typeKey,
  PreservedData? typeData,
  PreservedMap? extensionData,
}) => modelValue<UnknownLayer>(
  UnknownLayer.create(
    id: LayerId.fromUuid(testUuid(id)),
    typeKey: typeKey ?? testLayerTypeKey(),
    envelopeVersion: testSchemaVersion,
    typeSchemaVersion: testSchemaVersion,
    name: name,
    role: role,
    visible: true,
    locked: false,
    opacity: 1,
    objects: objects,
    typeData: typeData ?? PreservedMap.empty(),
    extensionData: extensionData ?? PreservedMap.empty(),
  ),
);

/// Creates a valid Page.
DocumentPage testPage({
  int id = 20,
  String name = 'Page',
  Iterable<DocumentLayer>? layers,
  PreservedMap? extensionData,
}) => modelValue<DocumentPage>(
  DocumentPage.create(
    id: PageId.fromUuid(testUuid(id)),
    name: name,
    size: testPageSize,
    layers: layers ?? <DocumentLayer>[testContentLayer()],
    extensionData: extensionData ?? PreservedMap.empty(),
  ),
);

/// Creates a valid Section.
DocumentSection testSection({
  int id = 30,
  String name = 'Section',
  Iterable<DocumentPage>? pages,
  PreservedMap? extensionData,
}) => modelValue<DocumentSection>(
  DocumentSection.create(
    id: SectionId.fromUuid(testUuid(id)),
    name: name,
    pages: pages ?? <DocumentPage>[testPage()],
    extensionData: extensionData ?? PreservedMap.empty(),
  ),
);

/// Creates an immutable empty resource catalog.
ResourceCatalog emptyResourceCatalog() =>
    modelValue<ResourceCatalog>(ResourceCatalog.create(const []));

/// Creates a valid Notebook.
NotebookDocument testNotebook({
  int id = 40,
  String title = 'Notebook',
  Iterable<DocumentSection>? sections,
  ResourceCatalog? resources,
  PreservedMap? extensionData,
}) => modelValue<NotebookDocument>(
  NotebookDocument.create(
    id: DocumentId.fromUuid(testUuid(id)),
    schemaVersion: testSchemaVersion,
    title: title,
    resources: resources ?? emptyResourceCatalog(),
    extensionData: extensionData ?? PreservedMap.empty(),
    sections: sections ?? <DocumentSection>[testSection()],
  ),
);

/// A minimal immutable test-only Object type definition.
final class TestObjectTypeDefinition implements ObjectTypeDefinition {
  /// Creates deterministic test behavior.
  TestObjectTypeDefinition({
    ObjectTypeKey? typeKey,
    Iterable<SchemaVersion>? supportedSchemaVersions,
    Iterable<ObjectPayloadMigrationContract> migrations =
        const <ObjectPayloadMigrationContract>[],
    Iterable<ResourceReference> references = const <ResourceReference>[],
    ObjectTypeCapabilities? capabilities,
    this.referencedObjectId,
    this.failDuplication = false,
    this.duplicationFailure,
    this.throwDuringValidation = false,
    this.validationExceptionMessage,
    this.failGeometry = false,
    this.throwGeometry = false,
    this.failResourceDiscovery = false,
    this.throwResourceDiscovery = false,
    this.onGeometry,
    this.onResourceDiscovery,
    this.geometry,
  }) : typeKey = typeKey ?? testObjectTypeKey(),
       supportedSchemaVersions = List<SchemaVersion>.unmodifiable(
         supportedSchemaVersions ?? <SchemaVersion>[testSchemaVersion],
       ),
       migrations = List<ObjectPayloadMigrationContract>.unmodifiable(
         migrations,
       ),
       references = List<ResourceReference>.unmodifiable(references),
       capabilities =
           capabilities ??
           const ObjectTypeCapabilities(
             hasIntrinsicGeometry: true,
             discoversResourceReferences: true,
             supportsScopedDuplication: true,
           );

  @override
  final ObjectTypeKey typeKey;

  @override
  final List<SchemaVersion> supportedSchemaVersions;

  @override
  final List<ObjectPayloadMigrationContract> migrations;

  final List<ResourceReference> references;

  /// An optional declared Object reference remapped during duplication.
  final ObjectId? referencedObjectId;

  /// Whether duplication returns a structured handler failure.
  final bool failDuplication;

  /// An optional handler-owned duplication failure.
  final StructuredFailure? duplicationFailure;

  /// Whether validation simulates unavailable behavior.
  final bool throwDuringValidation;

  /// An optional message for an adversarial validation exception.
  final String? validationExceptionMessage;

  /// Whether intrinsic geometry returns a structured failure.
  final bool failGeometry;

  /// Whether intrinsic geometry throws.
  final bool throwGeometry;

  /// Whether resource discovery returns a structured failure.
  final bool failResourceDiscovery;

  /// Whether resource discovery throws.
  final bool throwResourceDiscovery;

  /// Optional observation invoked when geometry behavior is called.
  final void Function()? onGeometry;

  /// Optional observation invoked when resource behavior is called.
  final void Function()? onResourceDiscovery;

  /// Optional deterministic intrinsic geometry override.
  final Rect2? geometry;

  @override
  final ObjectTypeCapabilities capabilities;

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) {
    final suppliedFailure = duplicationFailure;
    if (suppliedFailure != null) {
      return Err<PreservedData, StructuredFailure>(suppliedFailure);
    }
    if (failDuplication) {
      return Err<PreservedData, StructuredFailure>(
        StructuredFailure(
          code: 'test.documents.duplication_failure',
          category: FailureCategory.dependency,
          retryDisposition: RetryDisposition.never,
          message: 'Test duplication failed.',
        ),
      );
    }
    final reference = referencedObjectId;
    if (reference != null) {
      return Ok<PreservedData, StructuredFailure>(
        PreservedString(remapping.objectOrSame(reference).uuid.value),
      );
    }
    return Ok<PreservedData, StructuredFailure>(payload);
  }

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    onGeometry?.call();
    if (throwGeometry) {
      throw StateError('test geometry unavailable');
    }
    if (failGeometry) {
      return Err<Rect2, StructuredFailure>(_testBehaviorFailure());
    }
    final suppliedGeometry = geometry;
    return suppliedGeometry == null
        ? Rect2.fromEdges(left: 0, top: 0, right: 10, bottom: 20)
        : Ok(suppliedGeometry);
  }

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    onResourceDiscovery?.call();
    if (throwResourceDiscovery) {
      throw StateError('test resource discovery unavailable');
    }
    if (failResourceDiscovery) {
      return Err<List<ResourceReference>, StructuredFailure>(
        _testBehaviorFailure(),
      );
    }
    return Ok<List<ResourceReference>, StructuredFailure>(
      List<ResourceReference>.unmodifiable(references),
    );
  }

  @override
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) {
    final suppliedExceptionMessage = validationExceptionMessage;
    if (suppliedExceptionMessage != null) {
      throw StateError(suppliedExceptionMessage);
    }
    if (throwDuringValidation) {
      throw StateError('test behavior unavailable');
    }
    if (payload == const PreservedString('invalid')) {
      final path = modelValue<ValidationPath>(
        ValidationPath.fromSegments(<ValidationPathSegment>[
          ValidationPathSegment.input,
          ValidationPathSegment.payload,
        ]),
      );
      final issue = modelValue<ValidationIssue>(
        ValidationIssue.create(
          code: ValidationIssueCode.invalid,
          severity: ValidationSeverity.error,
          path: path,
        ),
      );
      return ValidationReport(<ValidationIssue>[issue]);
    }
    return ValidationReport(const <ValidationIssue>[]);
  }
}

/// Creates an Object Registry containing the standard test definition.
ObjectRegistry testRegistry([Iterable<ObjectTypeDefinition>? definitions]) =>
    modelValue<ObjectRegistry>(
      ObjectRegistry.create(
        definitions ?? <ObjectTypeDefinition>[TestObjectTypeDefinition()],
      ),
    );

StructuredFailure _testBehaviorFailure() => StructuredFailure(
  code: 'test.documents.behavior_unavailable',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'Required test Object behavior is unavailable.',
);
