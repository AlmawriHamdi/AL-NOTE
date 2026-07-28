// SPDX-License-Identifier: GPL-3.0-or-later

import '../../../core/identity/uuid_identifier.dart';
import '../../../core/outcomes/result.dart';
import '../../../core/outcomes/structured_failure.dart';
import '../../../core/versioning/schema_version.dart';
import '../../model/preserved_data.dart';
import '../../resources/resource_records.dart';
import '../contracts.dart';

/// Converts manifests to and from preservation-capable JSON values.
final class ManifestCodec {
  /// Encodes every known field while re-emitting unknown fields structurally.
  PreservedMap encode(AlnoteManifest manifest) {
    final values = Map<String, PreservedData>.of(manifest.unknownFields.values)
      ..addAll(<String, PreservedData>{
        'documentForm': PreservedString(manifest.documentForm.name),
        'documentId': PreservedString(manifest.documentId),
        'documentSchemaVersion': _integer(manifest.documentSchemaVersion.value),
        'entries': PreservedList(manifest.entries.map(_entry)),
        'entryPoint': PreservedString(manifest.entryPoint),
        'extensionNamespaces': _strings(manifest.extensionNamespaces),
        'optionalFeatures': _strings(manifest.optionalFeatures),
        'packageVersion': _integer(manifest.packageVersion.value),
        'requiredFeatures': _strings(manifest.requiredFeatures),
        'resources': PreservedList(manifest.resources.map(_resource)),
      });
    return PreservedMap(values);
  }

  /// Decodes and validates manifest catalogs and compatibility features.
  Result<AlnoteManifest, StructuredFailure> decode(PreservedData source) {
    try {
      final map = _map(source);
      final packageVersion =
          AlnotePackageVersion.create(_int(map, 'packageVersion')).fold(
            onOk: (value) => value,
            onErr: (_) => throw const _ManifestRejected('version'),
          );
      if (packageVersion != AlnotePackageVersion.version1) {
        throw const _ManifestRejected('version');
      }
      final requiredFeatures = _stringList(map, 'requiredFeatures');
      final optionalFeatures = _stringList(map, 'optionalFeatures');
      final namespaces = _stringList(map, 'extensionNamespaces');
      if (!_canonicalIdentifiers(requiredFeatures) ||
          !_canonicalIdentifiers(optionalFeatures) ||
          !_canonicalIdentifiers(namespaces)) {
        throw const _ManifestRejected('feature_catalog');
      }
      if (requiredFeatures.isNotEmpty) {
        throw const _ManifestRejected('required_feature');
      }
      final entries = _list(map, 'entries').map(_decodeEntry).toList();
      final resources = _list(map, 'resources').map(_decodeResource).toList();
      if (_hasDuplicates(entries.map((entry) => entry.path)) ||
          _hasDuplicates(resources.map((entry) => entry.identity)) ||
          !_isStrictlySorted(entries.map((entry) => entry.path)) ||
          !_isStrictlySorted(resources.map((entry) => entry.identity))) {
        throw const _ManifestRejected('manifest_catalog');
      }
      final form = switch (_string(map, 'documentForm')) {
        'notebook' => AlnoteDocumentForm.notebook,
        'standalonePage' => AlnoteDocumentForm.standalonePage,
        'standalonePdf' => AlnoteDocumentForm.standalonePdf,
        _ => throw const _ManifestRejected('record_type'),
      };
      final documentId = _string(map, 'documentId');
      final parsedDocumentId = UuidIdentifier.parse(documentId);
      if (parsedDocumentId is! Ok<UuidIdentifier, StructuredFailure> ||
          parsedDocumentId.value.value != documentId) {
        throw const _ManifestRejected('identity');
      }
      return Ok<AlnoteManifest, StructuredFailure>(
        AlnoteManifest(
          packageVersion: packageVersion,
          documentSchemaVersion: _schema(_int(map, 'documentSchemaVersion')),
          documentForm: form,
          documentId: documentId,
          entryPoint: _string(map, 'entryPoint'),
          requiredFeatures: requiredFeatures,
          optionalFeatures: optionalFeatures,
          entries: entries,
          resources: resources,
          extensionNamespaces: namespaces,
          unknownFields: PreservedMap(<String, PreservedData>{
            for (final entry in map.entries)
              if (!_knownFields.contains(entry.key)) entry.key: entry.value,
          }),
        ),
      );
    } on _ManifestRejected catch (rejected) {
      return Err<AlnoteManifest, StructuredFailure>(
        storageFailure(
          rejected.dimension,
          'The package manifest does not satisfy the required contract.',
        ),
      );
    }
  }

  PreservedMap _entry(AlnoteManifestEntry entry) => PreservedMap(
    Map<String, PreservedData>.of(entry.unknownFields.values)
      ..addAll(<String, PreservedData>{
        'decodedByteLength': _integer(entry.decodedByteLength),
        'mediaType': PreservedString(entry.mediaType.value),
        'path': PreservedString(entry.path),
        'schemaVersion': _integer(entry.schemaVersion.value),
        'sha256': PreservedString(entry.digest.hexadecimal),
      }),
  );

  PreservedMap _resource(AlnoteResourceEntry entry) => PreservedMap(
    Map<String, PreservedData>.of(entry.unknownFields.values)
      ..addAll(<String, PreservedData>{
        'decodedByteLength': _integer(entry.decodedByteLength),
        'identity': PreservedString(entry.identity),
        'mediaType': PreservedString(entry.mediaType.value),
        'path': PreservedString(entry.path),
        'role': PreservedString(entry.role.value),
        'schemaVersion': _integer(entry.schemaVersion.value),
        'sha256': PreservedString(entry.digest.hexadecimal),
      }),
  );

  AlnoteManifestEntry _decodeEntry(PreservedData source) {
    final map = _map(source);
    final length = _int(map, 'decodedByteLength');
    if (length < 0) throw const _ManifestRejected('entry_decoded_bytes');
    return AlnoteManifestEntry(
      path: _string(map, 'path'),
      mediaType: _mediaType(_string(map, 'mediaType')),
      decodedByteLength: length,
      digest: _digest(_string(map, 'sha256')),
      schemaVersion: _schema(_int(map, 'schemaVersion')),
      unknownFields: _unknown(map, _entryFields),
    );
  }

  AlnoteResourceEntry _decodeResource(PreservedData source) {
    final map = _map(source);
    final length = _int(map, 'decodedByteLength');
    if (length < 0) throw const _ManifestRejected('entry_decoded_bytes');
    return AlnoteResourceEntry(
      identity: _string(map, 'identity'),
      path: _string(map, 'path'),
      mediaType: _mediaType(_string(map, 'mediaType')),
      decodedByteLength: length,
      digest: _digest(_string(map, 'sha256')),
      role: ResourceRole.parse(_string(map, 'role')).fold(
        onOk: (value) => value,
        onErr: (_) => throw const _ManifestRejected('resource_catalog'),
      ),
      schemaVersion: _schema(_int(map, 'schemaVersion')),
      unknownFields: _unknown(map, _resourceFields),
    );
  }
}

const Set<String> _knownFields = <String>{
  'documentForm',
  'documentId',
  'documentSchemaVersion',
  'entries',
  'entryPoint',
  'extensionNamespaces',
  'optionalFeatures',
  'packageVersion',
  'requiredFeatures',
  'resources',
};

const Set<String> _entryFields = <String>{
  'decodedByteLength',
  'mediaType',
  'path',
  'schemaVersion',
  'sha256',
};

const Set<String> _resourceFields = <String>{
  'decodedByteLength',
  'identity',
  'mediaType',
  'path',
  'role',
  'schemaVersion',
  'sha256',
};

PreservedInteger _integer(int value) => PreservedInteger.create(value).fold(
  onOk: (result) => result,
  onErr: (_) => throw StateError('Invalid trusted manifest integer.'),
);

PreservedList _strings(Iterable<String> values) =>
    PreservedList(values.map(PreservedString.new));

Map<String, PreservedData> _map(PreservedData value) {
  if (value is! PreservedMap) throw const _ManifestRejected('record_type');
  return value.values;
}

PreservedData _required(Map<String, PreservedData> map, String key) =>
    map[key] ?? (throw const _ManifestRejected('record_type'));

String _string(Map<String, PreservedData> map, String key) {
  final value = _required(map, key);
  if (value is! PreservedString) throw const _ManifestRejected('record_type');
  return value.value;
}

int _int(Map<String, PreservedData> map, String key) {
  final value = _required(map, key);
  if (value is! PreservedInteger) throw const _ManifestRejected('record_type');
  return value.value;
}

List<PreservedData> _list(Map<String, PreservedData> map, String key) {
  final value = _required(map, key);
  if (value is! PreservedList) throw const _ManifestRejected('record_type');
  return value.values;
}

List<String> _stringList(Map<String, PreservedData> map, String key) =>
    _list(map, key)
        .map((value) {
          if (value is! PreservedString)
            throw const _ManifestRejected('record_type');
          return value.value;
        })
        .toList(growable: false);

SchemaVersion _schema(int value) => SchemaVersion.create(value).fold(
  onOk: (result) => result,
  onErr: (_) => throw const _ManifestRejected('version'),
);

Sha256Digest _digest(String value) => Sha256Digest.parse(value).fold(
  onOk: (result) => result,
  onErr: (_) => throw const _ManifestRejected('entry_integrity'),
);

ResourceMediaType _mediaType(String value) =>
    ResourceMediaType.parse(value).fold(
      onOk: (result) => result,
      onErr: (_) => throw const _ManifestRejected('manifest_catalog'),
    );

bool _hasDuplicates(Iterable<String> values) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) return true;
  }
  return false;
}

bool _canonicalIdentifiers(List<String> values) =>
    values.every(isAlnoteOwnedIdentifier) && _isStrictlySorted(values);

bool _isStrictlySorted(Iterable<String> values) {
  String? prior;
  for (final value in values) {
    if (prior != null && prior.compareTo(value) >= 0) return false;
    prior = value;
  }
  return true;
}

PreservedMap _unknown(Map<String, PreservedData> map, Set<String> known) =>
    PreservedMap(<String, PreservedData>{
      for (final entry in map.entries)
        if (!known.contains(entry.key)) entry.key: entry.value,
    });

final class _ManifestRejected implements Exception {
  const _ManifestRejected(this.dimension);
  final String dimension;
}
