// SPDX-License-Identifier: GPL-3.0-or-later

import '../../../core/geometry/affine_transform_2d.dart';
import '../../../core/geometry/geometry_values.dart';
import '../../../core/identity/uuid_identifier.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../../core/versioning/schema_version.dart';
import '../../layers/document_layer.dart';
import '../../model/document_root.dart';
import '../../model/identifiers.dart';
import '../../model/preserved_data.dart';
import '../../objects/object_envelope.dart';
import '../../resources/resources.dart';
import '../contracts.dart';

/// Encodes authoritative model values as deterministic preserved JSON values.
final class RecordEncoder {
  /// Encodes the root record with authoritative ordered references.
  PreservedMap document(DocumentRoot root) {
    final values = Map<String, PreservedData>.of(root.extensionData.values)
      ..addAll(<String, PreservedData>{
        'documentId': PreservedString(root.id.uuid.value),
        'form': PreservedString(_form(root).name),
        'schemaVersion': _integer(root.schemaVersion.value),
        'title': PreservedString(root.title),
      });
    switch (root) {
      case NotebookDocument(:final sections):
        values['sectionIds'] = PreservedList(
          sections.map((section) => PreservedString(section.id.uuid.value)),
        );
      case StandalonePageDocument(:final page):
        values['pageId'] = PreservedString(page.id.uuid.value);
      case StandalonePdfDocument(:final pages, :final source):
        values
          ..['pageIds'] = PreservedList(
            pages.map((page) => PreservedString(page.id.uuid.value)),
          )
          ..['sourceResourceId'] = PreservedString(source.identity.uuid.value);
    }
    return PreservedMap(values);
  }

  /// Encodes one Section record.
  PreservedMap section(DocumentSection section) {
    final values = Map<String, PreservedData>.of(section.extensionData.values)
      ..addAll(<String, PreservedData>{
        'id': PreservedString(section.id.uuid.value),
        'name': PreservedString(section.name),
        'pageIds': PreservedList(
          section.pages.map((page) => PreservedString(page.id.uuid.value)),
        ),
        'schemaVersion': _integer(1),
      });
    return PreservedMap(values);
  }

  /// Encodes one complete Page with ordered Layers and Objects.
  PreservedMap page(DocumentPage page) {
    final values = Map<String, PreservedData>.of(page.extensionData.values)
      ..addAll(<String, PreservedData>{
        'id': PreservedString(page.id.uuid.value),
        'layers': PreservedList(page.layers.map(layer)),
        'name': PreservedString(page.name),
        'schemaVersion': _integer(1),
        'size': PreservedList(<PreservedData>[
          _double(page.size.width),
          _double(page.size.height),
        ]),
      });
    return PreservedMap(values);
  }

  /// Encodes a Layer envelope without interpreting unknown Layer data.
  PreservedMap layer(DocumentLayer layer) {
    final values = Map<String, PreservedData>.of(layer.extensionData.values)
      ..addAll(<String, PreservedData>{
        'envelopeVersion': _integer(layer.envelopeVersion.value),
        'id': PreservedString(layer.id.uuid.value),
        'locked': PreservedBoolean(layer.locked),
        'name': PreservedString(layer.name),
        'objects': PreservedList(layer.objects.map(object)),
        'opacity': _double(layer.opacity),
        'role': PreservedString(layer.role.name),
        'type': PreservedString(layer.typeKey.value),
        'typeData': layer.typeData,
        'typeSchemaVersion': _integer(layer.typeSchemaVersion.value),
        'visible': PreservedBoolean(layer.visible),
      });
    return PreservedMap(values);
  }

  /// Encodes an Object envelope and exact affine coefficients.
  PreservedMap object(ObjectEnvelope object) {
    final values = Map<String, PreservedData>.of(object.extensionData.values)
      ..addAll(<String, PreservedData>{
        'envelopeVersion': _integer(object.envelopeVersion.value),
        'id': PreservedString(object.id.uuid.value),
        'locked': PreservedBoolean(object.locked),
        'payload': object.payload,
        'transform': PreservedList(
          object.transform.storageCoefficients.map(_double),
        ),
        'type': PreservedString(object.typeKey.value),
        'typeSchemaVersion': _integer(object.typeSchemaVersion.value),
        'visible': PreservedBoolean(object.visible),
      });
    return PreservedMap(values);
  }
}

/// Decodes typed records while preserving every unknown field structurally.
final class RecordDecoder {
  /// Creates a decoder constrained by validated caller-supplied limits.
  const RecordDecoder(this.limits);

  final AlnoteStorageLimits limits;

  /// Decodes the document root after referenced records are independently read.
  Result<DocumentRoot, StructuredFailure> document({
    required PreservedData record,
    required Map<String, DocumentSection> sections,
    required Map<String, DocumentPage> pages,
    required ResourceCatalog resources,
  }) {
    try {
      final map = _map(record);
      final schemaVersion = _schema(_integerValue(map, 'schemaVersion'));
      final documentId = DocumentId.fromUuid(_uuid(_string(map, 'documentId')));
      final title = _string(map, 'title');
      final form = _string(map, 'form');
      final extension = _unknown(map, const <String>{
        'documentId',
        'form',
        'schemaVersion',
        'title',
        'sectionIds',
        'pageId',
        'pageIds',
        'sourceResourceId',
      });
      switch (form) {
        case 'notebook':
          final ordered =
              _strings(
                    map,
                    'sectionIds',
                    maximum: limits['alnote.storage.section_count'],
                    dimension: 'section_count',
                  )
                  .map((id) => sections[id] ?? (throw const _RecordRejected()))
                  .toList(growable: false);
          if (ordered.length != sections.length) throw const _RecordRejected();
          return NotebookDocument.create(
            id: documentId,
            schemaVersion: schemaVersion,
            title: title,
            resources: resources,
            extensionData: extension,
            sections: ordered,
          );
        case 'standalonePage':
          final page = pages[_string(map, 'pageId')];
          if (page == null || pages.length != 1) throw const _RecordRejected();
          return StandalonePageDocument.create(
            id: documentId,
            schemaVersion: schemaVersion,
            title: title,
            resources: resources,
            extensionData: extension,
            page: page,
          );
        case 'standalonePdf':
          final ordered =
              _strings(
                    map,
                    'pageIds',
                    maximum: limits['alnote.storage.page_count'],
                    dimension: 'page_count',
                  )
                  .map((id) => pages[id] ?? (throw const _RecordRejected()))
                  .toList(growable: false);
          if (ordered.length != pages.length) throw const _RecordRejected();
          return StandalonePdfDocument.create(
            id: documentId,
            schemaVersion: schemaVersion,
            title: title,
            resources: resources,
            extensionData: extension,
            pages: ordered,
            source: ResourceReference(
              ResourceIdentity.fromUuid(
                _uuid(_string(map, 'sourceResourceId')),
              ),
            ),
          );
        default:
          throw const _RecordRejected();
      }
    } on _RecordRejected catch (rejected) {
      return Err<DocumentRoot, StructuredFailure>(
        _recordFailure(rejected.dimension),
      );
    }
  }

  /// Decodes one Section by resolving ordered Page identities.
  Result<DocumentSection, StructuredFailure> section(
    PreservedData record,
    Map<String, DocumentPage> pages,
  ) {
    try {
      final map = _map(record);
      if (_integerValue(map, 'schemaVersion') != 1)
        throw const _RecordRejected();
      final ordered =
          _strings(
                map,
                'pageIds',
                maximum: limits['alnote.storage.page_count'],
                dimension: 'page_count',
              )
              .map((id) => pages[id] ?? (throw const _RecordRejected()))
              .toList(growable: false);
      return DocumentSection.create(
        id: SectionId.fromUuid(_uuid(_string(map, 'id'))),
        name: _string(map, 'name'),
        pages: ordered,
        extensionData: _unknown(map, const <String>{
          'id',
          'name',
          'pageIds',
          'schemaVersion',
        }),
      );
    } on _RecordRejected catch (rejected) {
      return Err<DocumentSection, StructuredFailure>(
        _recordFailure(rejected.dimension),
      );
    }
  }

  /// Decodes one complete Page record.
  Result<DocumentPage, StructuredFailure> page(
    PreservedData record, {
    int? maximumLayers,
    int? maximumObjects,
  }) {
    try {
      final map = _map(record);
      if (_integerValue(map, 'schemaVersion') != 1)
        throw const _RecordRejected();
      final size = _list(map, 'size');
      if (size.length != 2) throw const _RecordRejected();
      final layerBudget = maximumLayers ?? limits['alnote.storage.layer_count'];
      final objectBudget =
          maximumObjects ?? limits['alnote.storage.object_count'];
      if (layerBudget < 0 || objectBudget < 0) {
        throw const _RecordRejected();
      }
      final layerValues = _list(map, 'layers');
      if (layerValues.length > layerBudget) {
        throw const _RecordRejected('layer_count');
      }
      var remainingObjects = objectBudget;
      for (final value in layerValues) {
        final objectValues = _list(_map(value), 'objects');
        if (objectValues.length > remainingObjects) {
          throw const _RecordRejected('object_count');
        }
        remainingObjects -= objectValues.length;
      }
      final layers = layerValues.map(_layer).toList(growable: false);
      return DocumentPage.create(
        id: PageId.fromUuid(_uuid(_string(map, 'id'))),
        name: _string(map, 'name'),
        size: Size2.create(width: _number(size[0]), height: _number(size[1]))
            .fold(
              onOk: (value) => value,
              onErr: (_) => throw const _RecordRejected(),
            ),
        layers: layers,
        extensionData: _unknown(map, const <String>{
          'id',
          'layers',
          'name',
          'schemaVersion',
          'size',
        }),
      );
    } on _RecordRejected catch (rejected) {
      return Err<DocumentPage, StructuredFailure>(
        _recordFailure(rejected.dimension),
      );
    }
  }

  DocumentLayer _layer(PreservedData value) {
    final map = _map(value);
    final id = LayerId.fromUuid(_uuid(_string(map, 'id')));
    final type = LayerTypeKey.parse(
      _string(map, 'type'),
    ).fold(onOk: (value) => value, onErr: (_) => throw const _RecordRejected());
    final envelopeVersion = _schema(_integerValue(map, 'envelopeVersion'));
    final typeVersion = _schema(_integerValue(map, 'typeSchemaVersion'));
    final role = switch (_string(map, 'role')) {
      'content' => LayerCoreRole.content,
      'backgroundSource' => LayerCoreRole.backgroundSource,
      'pdfSource' => LayerCoreRole.pdfSource,
      _ => throw const _RecordRejected(),
    };
    final objects = _list(map, 'objects').map(_object).toList(growable: false);
    final arguments = (
      id: id,
      envelopeVersion: envelopeVersion,
      typeSchemaVersion: typeVersion,
      name: _string(map, 'name'),
      visible: _boolean(map, 'visible'),
      locked: _boolean(map, 'locked'),
      opacity: _number(_required(map, 'opacity')),
      objects: objects,
      typeData: _required(map, 'typeData'),
      extensionData: _unknown(map, const <String>{
        'envelopeVersion',
        'id',
        'locked',
        'name',
        'objects',
        'opacity',
        'role',
        'type',
        'typeData',
        'typeSchemaVersion',
        'visible',
      }),
    );
    if (type == LayerTypeKey.content && role == LayerCoreRole.content) {
      return ContentLayer.create(
        id: arguments.id,
        envelopeVersion: arguments.envelopeVersion,
        typeSchemaVersion: arguments.typeSchemaVersion,
        name: arguments.name,
        visible: arguments.visible,
        locked: arguments.locked,
        opacity: arguments.opacity,
        objects: arguments.objects,
        typeData: arguments.typeData,
        extensionData: arguments.extensionData,
      ).fold(
        onOk: (value) => value,
        onErr: (_) => throw const _RecordRejected(),
      );
    }
    return UnknownLayer.create(
      id: arguments.id,
      typeKey: type,
      envelopeVersion: arguments.envelopeVersion,
      typeSchemaVersion: arguments.typeSchemaVersion,
      name: arguments.name,
      role: role,
      visible: arguments.visible,
      locked: arguments.locked,
      opacity: arguments.opacity,
      objects: arguments.objects,
      typeData: arguments.typeData,
      extensionData: arguments.extensionData,
    ).fold(onOk: (value) => value, onErr: (_) => throw const _RecordRejected());
  }

  ObjectEnvelope _object(PreservedData value) {
    final map = _map(value);
    final coefficients = _list(
      map,
      'transform',
    ).map(_number).toList(growable: false);
    final transform = AffineTransform2D.restoreFromStorage(
      coefficients,
    ).fold(onOk: (value) => value, onErr: (_) => throw const _RecordRejected());
    return ObjectEnvelope.create(
      id: ObjectId.fromUuid(_uuid(_string(map, 'id'))),
      typeKey: ObjectTypeKey.parse(_string(map, 'type')).fold(
        onOk: (value) => value,
        onErr: (_) => throw const _RecordRejected(),
      ),
      envelopeVersion: _schema(_integerValue(map, 'envelopeVersion')),
      typeSchemaVersion: _schema(_integerValue(map, 'typeSchemaVersion')),
      transform: transform,
      visible: _boolean(map, 'visible'),
      locked: _boolean(map, 'locked'),
      payload: _required(map, 'payload'),
      extensionData: _unknown(map, const <String>{
        'envelopeVersion',
        'id',
        'locked',
        'payload',
        'transform',
        'type',
        'typeSchemaVersion',
        'visible',
      }),
    ).fold(onOk: (value) => value, onErr: (_) => throw const _RecordRejected());
  }
}

AlnoteDocumentForm _form(DocumentRoot root) => switch (root) {
  NotebookDocument() => AlnoteDocumentForm.notebook,
  StandalonePageDocument() => AlnoteDocumentForm.standalonePage,
  StandalonePdfDocument() => AlnoteDocumentForm.standalonePdf,
};

PreservedInteger _integer(int value) => PreservedInteger.create(value).fold(
  onOk: (result) => result,
  onErr: (_) => throw StateError('Invalid trusted integer.'),
);

PreservedDouble _double(double value) => PreservedDouble.create(value).fold(
  onOk: (result) => result,
  onErr: (_) => throw StateError('Invalid trusted double.'),
);

Map<String, PreservedData> _map(PreservedData value) {
  if (value is! PreservedMap) throw const _RecordRejected();
  return value.values;
}

PreservedData _required(Map<String, PreservedData> map, String key) =>
    map[key] ?? (throw const _RecordRejected());

String _string(Map<String, PreservedData> map, String key) {
  final value = _required(map, key);
  if (value is! PreservedString) throw const _RecordRejected();
  return value.value;
}

bool _boolean(Map<String, PreservedData> map, String key) {
  final value = _required(map, key);
  if (value is! PreservedBoolean) throw const _RecordRejected();
  return value.value;
}

int _integerValue(Map<String, PreservedData> map, String key) {
  final value = _required(map, key);
  if (value is! PreservedInteger) throw const _RecordRejected();
  return value.value;
}

List<PreservedData> _list(Map<String, PreservedData> map, String key) {
  final value = _required(map, key);
  if (value is! PreservedList) throw const _RecordRejected();
  return value.values;
}

List<String> _strings(
  Map<String, PreservedData> map,
  String key, {
  required int maximum,
  required String dimension,
}) {
  final values = _list(map, key);
  if (values.length > maximum) throw _RecordRejected(dimension);
  return values
      .map((value) {
        if (value is! PreservedString) throw const _RecordRejected();
        return value.value;
      })
      .toList(growable: false);
}

double _number(PreservedData value) => switch (value) {
  PreservedDouble(:final value) => value,
  PreservedInteger(:final value) => value.toDouble(),
  _ => throw const _RecordRejected(),
};

UuidIdentifier _uuid(String value) => UuidIdentifier.parse(
  value,
).fold(onOk: (result) => result, onErr: (_) => throw const _RecordRejected());

SchemaVersion _schema(int value) => SchemaVersion.create(
  value,
).fold(onOk: (result) => result, onErr: (_) => throw const _RecordRejected());

PreservedMap _unknown(Map<String, PreservedData> map, Set<String> known) =>
    PreservedMap(<String, PreservedData>{
      for (final entry in map.entries)
        if (!known.contains(entry.key)) entry.key: entry.value,
    });

StructuredFailure _recordFailure(String dimension) => storageFailure(
  dimension,
  dimension == 'record_type'
      ? 'A structured record does not satisfy the required schema.'
      : 'A structured record exceeds a caller-supplied semantic ceiling.',
);

final class _RecordRejected implements Exception {
  const _RecordRejected([this.dimension = 'record_type']);
  final String dimension;
}
