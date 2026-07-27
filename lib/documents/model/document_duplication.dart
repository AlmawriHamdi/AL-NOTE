// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/identity/uuid_generator.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../layers/document_layer.dart';
import '../objects/object_envelope.dart';
import '../objects/object_registry.dart';
import 'document_identity_scope.dart';
import 'document_root.dart';
import 'identifiers.dart';
import 'identity_remapping.dart';

/// Deterministic atomic duplication using injected UUID and Object behavior.
final class DocumentDuplicator {
  /// Creates a duplicator with no global randomness or Registry.
  const DocumentDuplicator({
    required this.uuidGenerator,
    required this.objectRegistry,
  });

  /// The injected AL NOTE UUID generator.
  final UuidGenerator uuidGenerator;

  /// The immutable Object Registry used for interpreted payload remapping.
  final ObjectRegistry objectRegistry;

  /// Duplicates one Object with a new Object identity.
  Result<ObjectEnvelope, StructuredFailure> duplicateObject(
    ObjectEnvelope source, {
    required DocumentIdentityScope destinationScope,
  }) {
    final generated = ObjectId.generate(uuidGenerator);
    return generated.fold(
      onOk: (newId) {
        if (newId == source.id || destinationScope.objectIds.contains(newId)) {
          return Err<ObjectEnvelope, StructuredFailure>(_identityCollision());
        }
        return _duplicateObjectWithId(
          source,
          newId,
          IdentityRemapping(objects: <ObjectId, ObjectId>{source.id: newId}),
        );
      },
      onErr: Err<ObjectEnvelope, StructuredFailure>.new,
    );
  }

  /// Duplicates one built-in Layer with new Layer and contained Object IDs.
  Result<DocumentLayer, StructuredFailure> duplicateLayer(
    DocumentLayer source, {
    required DocumentIdentityScope destinationScope,
  }) {
    if (source is UnknownLayer) {
      return Err<DocumentLayer, StructuredFailure>(_unsupportedDuplication());
    }
    final layerIdResult = LayerId.generate(uuidGenerator);
    return layerIdResult.fold(
      onOk: (layerId) {
        if (layerId == source.id ||
            destinationScope.layerIds.contains(layerId)) {
          return Err<DocumentLayer, StructuredFailure>(_identityCollision());
        }
        final objectIdsResult = _allocateObjectIds(<DocumentLayer>[
          source,
        ], destinationScope);
        return objectIdsResult.fold(
          onOk: (objectIds) {
            final remapping = IdentityRemapping(
              layers: <LayerId, LayerId>{source.id: layerId},
              objects: objectIds,
            );
            return _duplicateLayerWithIds(
              source,
              layerId,
              objectIds,
              remapping,
            );
          },
          onErr: Err<DocumentLayer, StructuredFailure>.new,
        );
      },
      onErr: Err<DocumentLayer, StructuredFailure>.new,
    );
  }

  /// Duplicates one Page with new Page, Layer, and Object identities.
  Result<DocumentPage, StructuredFailure> duplicatePage(
    DocumentPage source, {
    required DocumentIdentityScope destinationScope,
  }) {
    if (source.layers.any((layer) => layer is UnknownLayer)) {
      return Err<DocumentPage, StructuredFailure>(_unsupportedDuplication());
    }
    final pageIdResult = PageId.generate(uuidGenerator);
    return pageIdResult.fold(
      onOk: (pageId) {
        if (pageId == source.id || destinationScope.pageIds.contains(pageId)) {
          return Err<DocumentPage, StructuredFailure>(_identityCollision());
        }
        final layerIdsResult = _allocateLayerIds(
          source.layers,
          destinationScope,
        );
        return layerIdsResult.fold(
          onOk: (layerIds) {
            final objectIdsResult = _allocateObjectIds(
              source.layers,
              destinationScope,
            );
            return objectIdsResult.fold(
              onOk: (objectIds) {
                final remapping = IdentityRemapping(
                  pages: <PageId, PageId>{source.id: pageId},
                  layers: layerIds,
                  objects: objectIds,
                );
                return _duplicatePageWithIds(
                  source,
                  pageId,
                  layerIds,
                  objectIds,
                  remapping,
                );
              },
              onErr: Err<DocumentPage, StructuredFailure>.new,
            );
          },
          onErr: Err<DocumentPage, StructuredFailure>.new,
        );
      },
      onErr: Err<DocumentPage, StructuredFailure>.new,
    );
  }

  /// Duplicates one Section and its complete Page/Layer/Object subtree.
  Result<DocumentSection, StructuredFailure> duplicateSection(
    DocumentSection source, {
    required DocumentIdentityScope destinationScope,
  }) {
    if (source.pages
        .expand((page) => page.layers)
        .any((layer) => layer is UnknownLayer)) {
      return Err<DocumentSection, StructuredFailure>(_unsupportedDuplication());
    }
    final sectionIdResult = SectionId.generate(uuidGenerator);
    return sectionIdResult.fold(
      onOk: (sectionId) {
        if (sectionId == source.id ||
            destinationScope.sectionIds.contains(sectionId)) {
          return Err<DocumentSection, StructuredFailure>(_identityCollision());
        }
        final pageIdsResult = _allocatePageIds(source.pages, destinationScope);
        return pageIdsResult.fold(
          onOk: (pageIds) {
            final allLayers = source.pages
                .expand((page) => page.layers)
                .toList(growable: false);
            final layerIdsResult = _allocateLayerIds(
              allLayers,
              destinationScope,
            );
            return layerIdsResult.fold(
              onOk: (layerIds) {
                final objectIdsResult = _allocateObjectIds(
                  allLayers,
                  destinationScope,
                );
                return objectIdsResult.fold(
                  onOk: (objectIds) {
                    final remapping = IdentityRemapping(
                      sections: <SectionId, SectionId>{source.id: sectionId},
                      pages: pageIds,
                      layers: layerIds,
                      objects: objectIds,
                    );
                    final pages = <DocumentPage>[];
                    for (final page in source.pages) {
                      final duplicated = _duplicatePageWithIds(
                        page,
                        pageIds[page.id]!,
                        layerIds,
                        objectIds,
                        remapping,
                      );
                      final failure = duplicated.fold<StructuredFailure?>(
                        onOk: (value) {
                          pages.add(value);
                          return null;
                        },
                        onErr: (error) => error,
                      );
                      if (failure != null) {
                        return Err<DocumentSection, StructuredFailure>(failure);
                      }
                    }
                    return DocumentSection.create(
                      id: sectionId,
                      name: source.name,
                      pages: pages,
                      extensionData: source.extensionData,
                    );
                  },
                  onErr: Err<DocumentSection, StructuredFailure>.new,
                );
              },
              onErr: Err<DocumentSection, StructuredFailure>.new,
            );
          },
          onErr: Err<DocumentSection, StructuredFailure>.new,
        );
      },
      onErr: Err<DocumentSection, StructuredFailure>.new,
    );
  }

  /// Creates an independent whole-document copy with a new Document identity.
  ///
  /// Internal entity and resource identities are deliberately preserved so
  /// opaque internal references remain coherent without guessing payloads.
  Result<DocumentRoot, StructuredFailure> duplicateDocument(
    DocumentRoot source,
  ) {
    final idResult = DocumentId.generate(uuidGenerator);
    return idResult.fold(
      onOk: (id) {
        if (id == source.id) {
          return Err<DocumentRoot, StructuredFailure>(_identityCollision());
        }
        switch (source) {
          case NotebookDocument():
            return NotebookDocument.create(
              id: id,
              schemaVersion: source.schemaVersion,
              title: source.title,
              resources: source.resources,
              extensionData: source.extensionData,
              sections: source.sections,
            );
          case StandalonePageDocument():
            return StandalonePageDocument.create(
              id: id,
              schemaVersion: source.schemaVersion,
              title: source.title,
              resources: source.resources,
              extensionData: source.extensionData,
              page: source.page,
            );
          case StandalonePdfDocument():
            return StandalonePdfDocument.create(
              id: id,
              schemaVersion: source.schemaVersion,
              title: source.title,
              resources: source.resources,
              extensionData: source.extensionData,
              pages: source.pages,
              source: source.source,
            );
        }
      },
      onErr: Err<DocumentRoot, StructuredFailure>.new,
    );
  }

  Result<ObjectEnvelope, StructuredFailure> _duplicateObjectWithId(
    ObjectEnvelope source,
    ObjectId newId,
    IdentityRemapping remapping,
  ) {
    final resolution = objectRegistry.resolve(source);
    if (resolution is UnavailableObjectBehaviorResolution) {
      return Err<ObjectEnvelope, StructuredFailure>(_behaviorFailure());
    }
    if (resolution is! SupportedObjectResolution ||
        !resolution.definition.capabilities.supportsScopedDuplication) {
      return Err<ObjectEnvelope, StructuredFailure>(_unsupportedDuplication());
    }
    try {
      final payloadResult = resolution.definition.duplicatePayload(
        source.payload,
        source.typeSchemaVersion,
        remapping,
      );
      return payloadResult.fold(
        onOk: (payload) => ObjectEnvelope.create(
          id: newId,
          typeKey: source.typeKey,
          envelopeVersion: source.envelopeVersion,
          typeSchemaVersion: source.typeSchemaVersion,
          transform: source.transform,
          visible: source.visible,
          locked: source.locked,
          payload: payload,
          extensionData: source.extensionData,
        ),
        onErr: (_) =>
            Err<ObjectEnvelope, StructuredFailure>(_behaviorFailure()),
      );
    } on Object {
      return Err<ObjectEnvelope, StructuredFailure>(_behaviorFailure());
    }
  }

  Result<DocumentLayer, StructuredFailure> _duplicateLayerWithIds(
    DocumentLayer source,
    LayerId newId,
    Map<ObjectId, ObjectId> objectIds,
    IdentityRemapping remapping,
  ) {
    if (source is! ContentLayer) {
      return Err<DocumentLayer, StructuredFailure>(_unsupportedDuplication());
    }
    final objects = <ObjectEnvelope>[];
    for (final object in source.objects) {
      final duplicated = _duplicateObjectWithId(
        object,
        objectIds[object.id]!,
        remapping,
      );
      final failure = duplicated.fold<StructuredFailure?>(
        onOk: (value) {
          objects.add(value);
          return null;
        },
        onErr: (error) => error,
      );
      if (failure != null) {
        return Err<DocumentLayer, StructuredFailure>(failure);
      }
    }
    return ContentLayer.create(
      id: newId,
      envelopeVersion: source.envelopeVersion,
      typeSchemaVersion: source.typeSchemaVersion,
      name: source.name,
      visible: source.visible,
      locked: source.locked,
      opacity: source.opacity,
      objects: objects,
      typeData: source.typeData,
      extensionData: source.extensionData,
    );
  }

  Result<DocumentPage, StructuredFailure> _duplicatePageWithIds(
    DocumentPage source,
    PageId newId,
    Map<LayerId, LayerId> layerIds,
    Map<ObjectId, ObjectId> objectIds,
    IdentityRemapping remapping,
  ) {
    final layers = <DocumentLayer>[];
    for (final layer in source.layers) {
      final duplicated = _duplicateLayerWithIds(
        layer,
        layerIds[layer.id]!,
        objectIds,
        remapping,
      );
      final failure = duplicated.fold<StructuredFailure?>(
        onOk: (value) {
          layers.add(value);
          return null;
        },
        onErr: (error) => error,
      );
      if (failure != null) {
        return Err<DocumentPage, StructuredFailure>(failure);
      }
    }
    return DocumentPage.create(
      id: newId,
      name: source.name,
      size: source.size,
      layers: layers,
      extensionData: source.extensionData,
    );
  }

  Result<Map<ObjectId, ObjectId>, StructuredFailure> _allocateObjectIds(
    Iterable<DocumentLayer> layers,
    DocumentIdentityScope destinationScope,
  ) {
    final sourceIds = <ObjectId>{
      for (final layer in layers)
        for (final object in layer.objects) object.id,
    };
    final allocatedIds = <ObjectId>{};
    final values = <ObjectId, ObjectId>{};
    for (final layer in layers) {
      for (final object in layer.objects) {
        final result = ObjectId.generate(uuidGenerator);
        final failure = result.fold<StructuredFailure?>(
          onOk: (value) {
            if (sourceIds.contains(value) ||
                destinationScope.objectIds.contains(value) ||
                !allocatedIds.add(value)) {
              return _identityCollision();
            }
            values[object.id] = value;
            return null;
          },
          onErr: (error) => error,
        );
        if (failure != null) {
          return Err<Map<ObjectId, ObjectId>, StructuredFailure>(failure);
        }
      }
    }
    return Ok<Map<ObjectId, ObjectId>, StructuredFailure>(
      Map<ObjectId, ObjectId>.unmodifiable(values),
    );
  }

  Result<Map<LayerId, LayerId>, StructuredFailure> _allocateLayerIds(
    Iterable<DocumentLayer> layers,
    DocumentIdentityScope destinationScope,
  ) {
    final copiedLayers = List<DocumentLayer>.of(layers);
    final sourceIds = copiedLayers.map((layer) => layer.id).toSet();
    final allocatedIds = <LayerId>{};
    final values = <LayerId, LayerId>{};
    for (final layer in copiedLayers) {
      final result = LayerId.generate(uuidGenerator);
      final failure = result.fold<StructuredFailure?>(
        onOk: (value) {
          if (sourceIds.contains(value) ||
              destinationScope.layerIds.contains(value) ||
              !allocatedIds.add(value)) {
            return _identityCollision();
          }
          values[layer.id] = value;
          return null;
        },
        onErr: (error) => error,
      );
      if (failure != null) {
        return Err<Map<LayerId, LayerId>, StructuredFailure>(failure);
      }
    }
    return Ok<Map<LayerId, LayerId>, StructuredFailure>(
      Map<LayerId, LayerId>.unmodifiable(values),
    );
  }

  Result<Map<PageId, PageId>, StructuredFailure> _allocatePageIds(
    Iterable<DocumentPage> pages,
    DocumentIdentityScope destinationScope,
  ) {
    final copiedPages = List<DocumentPage>.of(pages);
    final sourceIds = copiedPages.map((page) => page.id).toSet();
    final allocatedIds = <PageId>{};
    final values = <PageId, PageId>{};
    for (final page in copiedPages) {
      final result = PageId.generate(uuidGenerator);
      final failure = result.fold<StructuredFailure?>(
        onOk: (value) {
          if (sourceIds.contains(value) ||
              destinationScope.pageIds.contains(value) ||
              !allocatedIds.add(value)) {
            return _identityCollision();
          }
          values[page.id] = value;
          return null;
        },
        onErr: (error) => error,
      );
      if (failure != null) {
        return Err<Map<PageId, PageId>, StructuredFailure>(failure);
      }
    }
    return Ok<Map<PageId, PageId>, StructuredFailure>(
      Map<PageId, PageId>.unmodifiable(values),
    );
  }
}

StructuredFailure _unsupportedDuplication() => StructuredFailure(
  code: 'documents.duplication.unsupported_payload',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Scoped duplication requires supported payload behavior.',
);

StructuredFailure _behaviorFailure() => StructuredFailure(
  code: 'documents.duplication.behavior_failure',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'Required duplication behavior failed.',
);

StructuredFailure _identityCollision() => StructuredFailure(
  code: 'documents.duplication.identity_collision',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'A generated duplication identity is not fresh.',
);
