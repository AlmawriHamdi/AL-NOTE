// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';
import 'dart:convert';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase4_test_support.dart';

void main() {
  group('caller path policy and exact ZIP ownership', () {
    test('missing and wrongly united path policy fail closed', () {
      for (final limits in <ResourceLimitSnapshot>[
        _pathPolicyLimits(omit: true),
        _pathPolicyLimits(unit: ResourceLimitUnit.bytes),
      ]) {
        final outcome = AlnotePackageReader(objectRegistry: testRegistry())
            .openBytes(
              _canonicalPackage(),
              limits: limits,
              cancellationToken: CancellationController().token,
            );
        expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
      }
    });

    test('caller segment ceiling applies at and beyond the exact boundary', () {
      final codec = AlnotePackageCodec(objectRegistry: testRegistry());
      final limits = phase4Limits(
        overrides: const <String, int>{'alnote.storage.entry_path_segments': 4},
      );
      final accepted = codec.encode(
        _extensionSnapshot('extensions/example/a/b'),
        limits: limits,
      );
      expect(accepted, isA<Ok<List<int>, StructuredFailure>>());
      expect(
        codec.encode(
          _extensionSnapshot('extensions/example/a/b/c'),
          limits: limits,
        ),
        isA<Err<List<int>, StructuredFailure>>(),
      );
      final encodedWithLargerPolicy =
          codec.encode(
                _extensionSnapshot('extensions/example/a/b/c'),
                limits: phase4Limits(),
              )
              as Ok<List<int>, StructuredFailure>;
      expect(
        AlnotePackageReader(objectRegistry: testRegistry()).openBytes(
          encodedWithLargerPolicy.value,
          limits: limits,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<OpenedAlnotePackage, StructuredFailure>>(),
      );
    });

    test('rejects prefix, inter-entry gap, and local-area trailer bytes', () {
      const hostile = 'hidden-local-secret';
      for (final mutation in <List<int> Function(List<int>, List<int>)>[
        _prependHiddenBytes,
        _insertInterEntryGap,
        _insertBeforeCentralDirectory,
      ]) {
        final bytes = mutation(_canonicalPackage(), ascii.encode(hostile));
        _expectRedactedOpenFailure(bytes, const <String>[hostile]);
      }
    });
  });

  group('nested manifest catalog preservation', () {
    test('round-trips nested unknown entry and resource fields inertly', () {
      const hostile = 'catalog-hostile-secret';
      final source = _rewritePackage(_catalogPackage(), (manifest, _) {
        for (final item in manifest['entries']! as List<Object?>) {
          final entry = item! as Map<String, Object?>;
          entry['future'] = <String, Object?>{
            'list': <Object?>[
              '雪',
              hostile,
              <Object?>[1, true],
            ],
          };
        }
        for (final item in manifest['resources']! as List<Object?>) {
          final resource = item! as Map<String, Object?>;
          resource['futureResource'] = <String, Object?>{
            'unicode': 'résumé 📚',
            'items': <Object?>[false, 7],
          };
        }
      }, repairCatalog: false);
      final opened =
          _open(source) as Completed<OpenedAlnotePackage, StructuredFailure>;
      final materialized =
          opened.value.materializeSnapshot(
                cancellationToken: CancellationController().token,
              )
              as Completed<AlnotePackageSnapshot, StructuredFailure>;
      final preservation = materialized.value.preservation;
      expect(
        preservation.entryCatalogFields.keys,
        containsAll(<String>[
          'mimetype',
          'document.json',
          'sections/00000000-0000-4000-8000-000000000030.json',
          'pages/00000000-0000-4000-8000-000000000020.json',
          'extensions/example/data.bin',
        ]),
      );
      expect(preservation.resourceCatalogFields, hasLength(1));
      expect(preservation.toString(), isNot(contains(hostile)));

      final saved =
          AlnotePackageCodec(
                objectRegistry: testRegistry(),
              ).encode(materialized.value, limits: phase4Limits())
              as Ok<List<int>, StructuredFailure>;
      final reopened =
          _open(saved.value)
              as Completed<OpenedAlnotePackage, StructuredFailure>;
      expect(
        reopened.value.preservation.entryCatalogFields,
        preservation.entryCatalogFields,
      );
      expect(
        reopened.value.preservation.resourceCatalogFields,
        preservation.resourceCatalogFields,
      );
    });

    test('known catalog fields safely override conflicting preserved keys', () {
      const hostile = 'hostile-known-override';
      final preservation =
          (AlnotePackagePreservation.create(
                    entryCatalogFields: <String, PreservedMap>{
                      'mimetype': PreservedMap(<String, PreservedData>{
                        'path': const PreservedString(hostile),
                        'schemaVersion': const PreservedString(hostile),
                        'future': const PreservedString('retained'),
                      }),
                    },
                  )
                  as Ok<AlnotePackagePreservation, StructuredFailure>)
              .value;
      final snapshot =
          (AlnotePackageSnapshot.create(
                    document: testNotebook(),
                    resources: const <DocumentResourceSnapshot>[],
                    preservation: preservation,
                  )
                  as Ok<AlnotePackageSnapshot, StructuredFailure>)
              .value;
      final encoded =
          AlnotePackageCodec(
                objectRegistry: testRegistry(),
              ).encode(snapshot, limits: phase4Limits())
              as Ok<List<int>, StructuredFailure>;
      final opened =
          _open(encoded.value)
              as Completed<OpenedAlnotePackage, StructuredFailure>;
      expect(
        opened.value.manifest.entries
            .singleWhere((entry) => entry.path == 'mimetype')
            .schemaVersion
            .value,
        1,
      );
      expect(
        opened.value.preservation.entryCatalogFields['mimetype']!.values,
        <String, PreservedData>{'future': const PreservedString('retained')},
      );
      expect(opened.toString(), isNot(contains(hostile)));
    });

    test('catalog preservation inputs are copied and immutable', () {
      final source = <String, PreservedMap>{
        'mimetype': PreservedMap(<String, PreservedData>{
          'future': const PreservedString('value'),
        }),
      };
      final preservation =
          (AlnotePackagePreservation.create(entryCatalogFields: source)
                  as Ok<AlnotePackagePreservation, StructuredFailure>)
              .value;
      source.clear();
      expect(preservation.entryCatalogFields, hasLength(1));
      expect(preservation.entryCatalogFields.clear, throwsUnsupportedError);
      expect(
        preservation.entryCatalogFields['mimetype']!.values.clear,
        throwsUnsupportedError,
      );
    });

    test('hostile unknown values never enter rejection diagnostics', () {
      const hostile = 'nested-catalog-diagnostic-secret';
      final bytes = _rewritePackage(_canonicalPackage(), (manifest, _) {
        final document =
            (manifest['entries']! as List<Object?>).singleWhere(
                  (item) =>
                      (item! as Map<String, Object?>)['path'] ==
                      'document.json',
                )!
                as Map<String, Object?>;
        document
          ..['future'] = <String, Object?>{'secret': hostile}
          ..['schemaVersion'] = 2;
      }, repairCatalog: false);
      _expectRedactedOpenFailure(bytes, const <String>[hostile]);
    });
  });

  group('forward-compatible catalog and authoritative records', () {
    for (final features in <List<String>>[
      <String>['bad!'],
      <String>['duplicate', 'duplicate'],
      <String>['Uppercase'],
    ]) {
      test('rejects malformed or duplicate feature declarations', () {
        const hostile = 'hostile-feature-secret';
        final bytes = _rewritePackage(_canonicalPackage(), (manifest, _) {
          manifest['optionalFeatures'] = <Object?>[...features, hostile];
        }, repairCatalog: false);
        _expectRedactedOpenFailure(bytes, <String>[hostile, ...features]);
      });
    }

    test('rejects unsupported required features inertly', () {
      const hostile = 'future_required_secret';
      final bytes = _rewritePackage(_canonicalPackage(), (manifest, _) {
        manifest['requiredFeatures'] = <Object?>[hostile];
      }, repairCatalog: false);
      _expectRedactedOpenFailure(bytes, const <String>[hostile]);
    });

    test('rejects malformed and duplicate extension namespaces', () {
      const hostile = 'hostile-namespace-secret';
      final bytes = _rewritePackage(_canonicalPackage(), (manifest, _) {
        manifest['extensionNamespaces'] = <Object?>[hostile, hostile];
      }, repairCatalog: false);
      _expectRedactedOpenFailure(bytes, const <String>[hostile]);
    });

    test(
      'rejects undeclared extension entries without disclosing metadata',
      () {
        const hostile = 'application/extension-secret';
        final bytes = _rewritePackage(_extensionPackage(hostile), (
          manifest,
          _,
        ) {
          manifest['extensionNamespaces'] = <Object?>[];
        }, repairCatalog: false);
        _expectRedactedOpenFailure(bytes, const <String>[hostile]);
      },
    );

    test('rejects duplicate conflicting extension catalog metadata', () {
      const hostile = 'application/conflicting-secret';
      final bytes = _rewritePackage(_extensionPackage('application/example'), (
        manifest,
        _,
      ) {
        final catalog = manifest['entries']! as List<Object?>;
        final original = Map<String, Object?>.of(
          catalog.singleWhere(
                (item) =>
                    (item! as Map<String, Object?>)['path'] ==
                    'extensions/example/data.bin',
              )!
              as Map<String, Object?>,
        )..['mediaType'] = hostile;
        catalog.add(original);
      }, repairCatalog: false);
      _expectRedactedOpenFailure(bytes, const <String>[hostile]);
    });

    test('rejects malformed UUID-looking Page and Section paths', () {
      for (final original in <String>[
        'pages/00000000-0000-4000-8000-000000000020.json',
        'sections/00000000-0000-4000-8000-000000000030.json',
      ]) {
        const malformed = '11111111-1111-1111-1111-11111111111z';
        final renamed = '${original.split('/').first}/$malformed.json';
        final bytes = _rewritePackage(_canonicalPackage(), (manifest, entries) {
          entries[renamed] = entries.remove(original)!;
          final catalog = manifest['entries']! as List<Object?>;
          (catalog.singleWhere(
                    (item) =>
                        (item! as Map<String, Object?>)['path'] == original,
                  )!
                  as Map<String, Object?>)['path'] =
              renamed;
        }, repairCatalog: false);
        _expectRedactedOpenFailure(bytes, const <String>[malformed]);
      }
    });

    test('rejects Section/path identity mismatch eagerly', () {
      const path = 'sections/00000000-0000-4000-8000-000000000030.json';
      final bytes = _rewritePackage(_canonicalPackage(), (_, entries) {
        final section = _jsonMap(entries[path]!);
        section['id'] = testUuid(31).value;
        entries[path] = utf8.encode(jsonEncode(section));
      });
      _expectRedactedOpenFailure(bytes, <String>[testUuid(31).value]);
    });

    test('rejects Page/path identity mismatch during lazy loading', () {
      const path = 'pages/00000000-0000-4000-8000-000000000020.json';
      final bytes = _rewritePackage(_canonicalPackage(), (_, entries) {
        final page = _jsonMap(entries[path]!);
        page['id'] = testUuid(21).value;
        entries[path] = utf8.encode(jsonEncode(page));
      });
      final opened =
          _open(bytes) as Completed<OpenedAlnotePackage, StructuredFailure>;
      final outcome = opened.value.pageHandles.single.load(
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<Failed<DocumentPage, StructuredFailure>>());
      expect(outcome.toString(), isNot(contains(testUuid(21).value)));
    });

    test('rejects self-consistent malformed root and Section records', () {
      for (final mutation in <({String path, String key, Object? value})>[
        (path: 'document.json', key: 'title', value: <Object?>['not-a-string']),
        (
          path: 'sections/00000000-0000-4000-8000-000000000030.json',
          key: 'pageIds',
          value: <Object?>[7],
        ),
      ]) {
        final bytes = _rewritePackage(_canonicalPackage(), (_, entries) {
          final record = _jsonMap(entries[mutation.path]!);
          record[mutation.key] = mutation.value;
          entries[mutation.path] = utf8.encode(jsonEncode(record));
        });
        _expectRedactedOpenFailure(bytes, const <String>['not-a-string']);
      }
    });

    test('rejects an unreferenced Notebook Page', () {
      const sectionPath = 'sections/00000000-0000-4000-8000-000000000030.json';
      final bytes = _rewritePackage(_canonicalPackage(), (_, entries) {
        final section = _jsonMap(entries[sectionPath]!);
        section['pageIds'] = <Object?>[];
        entries[sectionPath] = utf8.encode(jsonEncode(section));
      });
      _expectRedactedOpenFailure(bytes, const <String>[]);
    });

    test('standalone form rejects ignored Section records', () {
      final bytes = _rewritePackage(_canonicalPackage(), (manifest, entries) {
        manifest['documentForm'] = 'standalonePage';
        final root = _jsonMap(entries['document.json']!);
        root
          ..['form'] = 'standalonePage'
          ..remove('sectionIds')
          ..['pageId'] = testUuid(20).value;
        entries['document.json'] = utf8.encode(jsonEncode(root));
      });
      _expectRedactedOpenFailure(bytes, const <String>[]);
    });

    test('rejects wrong known media and schema metadata', () {
      for (final field in <String>['mediaType', 'schemaVersion']) {
        const hostile = 'application/hostile-secret';
        final bytes = _rewritePackage(_canonicalPackage(), (manifest, _) {
          final entry =
              (manifest['entries']! as List<Object?>).singleWhere(
                    (item) =>
                        (item! as Map<String, Object?>)['path'] ==
                        'document.json',
                  )!
                  as Map<String, Object?>;
          entry[field] = field == 'mediaType' ? hostile : 2;
        }, repairCatalog: false);
        _expectRedactedOpenFailure(bytes, const <String>[hostile]);
      }
    });

    test('independently rejects incorrect mimetype manifest metadata', () {
      const hostileDigest =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final bytes = _rewritePackage(_canonicalPackage(), (manifest, _) {
        final entry =
            (manifest['entries']! as List<Object?>).singleWhere(
                  (item) =>
                      (item! as Map<String, Object?>)['path'] == 'mimetype',
                )!
                as Map<String, Object?>;
        entry
          ..['decodedByteLength'] = 1
          ..['sha256'] = hostileDigest;
      }, repairCatalog: false);
      _expectRedactedOpenFailure(bytes, const <String>[hostileDigest]);
    });
  });

  group('hostile ZIP and byte boundaries', () {
    test('reconciles local and central CRC and sizes', () {
      final valid = _canonicalPackage();
      final local = _findSignatures(valid, const <int>[
        0x50,
        0x4b,
        0x03,
        0x04,
      ]).first;
      for (final offset in <int>[14, 18, 22]) {
        final mutated = List<int>.of(valid);
        mutated[local + offset] ^= 1;
        _expectRedactedOpenFailure(mutated, const <String>[]);
      }
    });

    test('rejects data-descriptor ambiguity', () {
      final bytes = List<int>.of(_canonicalPackage());
      final local = _findSignatures(bytes, const <int>[
        0x50,
        0x4b,
        0x03,
        0x04,
      ]).first;
      final central = _findSignatures(bytes, const <int>[
        0x50,
        0x4b,
        0x01,
        0x02,
      ]).first;
      _setUint16(bytes, local + 6, _uint16(bytes, local + 6) | 8);
      _setUint16(bytes, central + 8, _uint16(bytes, central + 8) | 8);
      _expectRedactedOpenFailure(bytes, const <String>[]);
    });

    test('rejects aliased local ranges and data reaching central metadata', () {
      final valid = _canonicalPackage();
      final centrals = _findSignatures(valid, const <int>[
        0x50,
        0x4b,
        0x01,
        0x02,
      ]);
      final aliased = List<int>.of(valid);
      _setUint32(
        aliased,
        centrals[1] + 42,
        _uint32(aliased, centrals.first + 42),
      );
      _expectRedactedOpenFailure(aliased, const <String>[]);

      final extending = List<int>.of(valid);
      final local = _uint32(extending, centrals.first + 42);
      final centralOffset = _uint32(
        extending,
        _findSignatures(extending, const <int>[0x50, 0x4b, 0x05, 0x06]).single +
            16,
      );
      _setUint32(extending, local + 18, centralOffset);
      _setUint32(extending, centrals.first + 20, centralOffset);
      _expectRedactedOpenFailure(extending, const <String>[]);
    });

    test('rejects archive/entry comments and unsupported extras', () {
      const hostile = 'zip-comment-secret';
      for (final entryComment in <bool>[false, true]) {
        final archive = ZipDecoder().decodeBytes(_canonicalPackage());
        if (entryComment) {
          archive.files.first.comment = hostile;
        } else {
          archive.comment = hostile;
        }
        final bytes = ZipEncoder().encodeBytes(
          archive,
          modified: DateTime.utc(1980),
        );
        _expectRedactedOpenFailure(bytes, const <String>[hostile]);
      }
      final extra = _addUnsupportedCentralExtra(_canonicalPackage());
      _expectRedactedOpenFailure(extra, const <String>[]);
    });

    test('rejects reserved components and excessive path segments', () {
      for (final path in <String>[
        'extensions/example/con.txt',
        'extensions/example/${List<String>.filled(maximumAlnotePathSegments, 'a').join('/')}',
      ]) {
        final archive = Archive()
          ..add(ArchiveFile.noCompress(path, 1, <int>[0]));
        final bytes = ZipEncoder().encodeBytes(
          archive,
          modified: DateTime.utc(1980),
        );
        _expectRedactedOpenFailure(bytes, <String>[path]);
      }
    });

    test('rejects invalid byte integers and throwing iterables safely', () {
      const hostile = 'iterator-secret';
      for (final source in <Iterable<int>>[
        <int>[-1],
        <int>[256],
        _ThrowingIterable(hostile),
      ]) {
        final outcome = AlnotePackageReader(objectRegistry: testRegistry())
            .openBytes(
              source,
              limits: phase4Limits(),
              cancellationToken: CancellationController().token,
            );
        expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
        expect(outcome.toString(), isNot(contains(hostile)));
      }
    });

    test('oversized iterable stops immediately at the package limit', () {
      final source = _CountingIterable();
      final outcome = AlnotePackageReader(objectRegistry: testRegistry())
          .openBytes(
            source,
            limits: phase4Limits(
              overrides: const <String, int>{'alnote.storage.package_bytes': 5},
            ),
            cancellationToken: CancellationController().token,
          );
      expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
      expect(source.observed, 6);
    });

    test('throwing PackageByteSource is contained and redacted', () async {
      const hostile = 'source-secret';
      final outcome = await AlnotePackageReader(objectRegistry: testRegistry())
          .open(
            _ThrowingSource(hostile),
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          );
      expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
      expect(outcome.toString(), isNot(contains(hostile)));
    });

    test('source output above its authorized maximum is rejected', () async {
      final outcome = await AlnotePackageReader(objectRegistry: testRegistry())
          .open(
            _OversizedSource(),
            limits: phase4Limits(
              overrides: const <String, int>{'alnote.storage.package_bytes': 5},
            ),
            cancellationToken: CancellationController().token,
          );
      expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
    });
  });
}

List<int> _canonicalPackage() {
  final snapshot =
      (AlnotePackageSnapshot.create(
                document: testNotebook(),
                resources: const <DocumentResourceSnapshot>[],
              )
              as Ok<AlnotePackageSnapshot, StructuredFailure>)
          .value;
  return (AlnotePackageCodec(
            objectRegistry: testRegistry(),
          ).encode(snapshot, limits: phase4Limits())
          as Ok<List<int>, StructuredFailure>)
      .value;
}

List<int> _extensionPackage(String mediaType) {
  final opaque =
      (AlnoteOpaqueEntry.create(
                path: 'extensions/example/data.bin',
                mediaType:
                    (ResourceMediaType.parse(mediaType)
                            as Ok<ResourceMediaType, StructuredFailure>)
                        .value,
                schemaVersion: testSchemaVersion,
                bytes: const <int>[1, 2, 3],
              )
              as Ok<AlnoteOpaqueEntry, StructuredFailure>)
          .value;
  final preservation =
      (AlnotePackagePreservation.create(
                extensionNamespaces: const <String>['example'],
                opaqueEntries: <AlnoteOpaqueEntry>[opaque],
              )
              as Ok<AlnotePackagePreservation, StructuredFailure>)
          .value;
  final snapshot =
      (AlnotePackageSnapshot.create(
                document: testNotebook(),
                resources: const <DocumentResourceSnapshot>[],
                preservation: preservation,
              )
              as Ok<AlnotePackageSnapshot, StructuredFailure>)
          .value;
  return (AlnotePackageCodec(
            objectRegistry: testRegistry(),
          ).encode(snapshot, limits: phase4Limits())
          as Ok<List<int>, StructuredFailure>)
      .value;
}

ResourceLimitSnapshot _pathPolicyLimits({
  bool omit = false,
  ResourceLimitUnit unit = ResourceLimitUnit.count,
}) {
  const pathKey = 'alnote.storage.entry_path_segments';
  final limits = <({ResourceLimitKey key, ResourceLimitCeiling ceiling})>[];
  for (final requirement in alnoteStorageLimitRequirements.entries) {
    if (omit && requirement.key == pathKey) continue;
    final key =
        (ResourceLimitKey.parse(requirement.key)
                as Ok<ResourceLimitKey, StructuredFailure>)
            .value;
    final ceiling =
        (ResourceLimitCeiling.create(
                  value: requirement.value == ResourceLimitUnit.ratio
                      ? 1000
                      : 1000000,
                  unit: requirement.key == pathKey ? unit : requirement.value,
                )
                as Ok<ResourceLimitCeiling, StructuredFailure>)
            .value;
    limits.add((key: key, ceiling: ceiling));
  }
  return (ResourceLimitSnapshot.create(limits)
          as Ok<ResourceLimitSnapshot, StructuredFailure>)
      .value;
}

AlnotePackageSnapshot _extensionSnapshot(String path) {
  final opaque =
      (AlnoteOpaqueEntry.create(
                path: path,
                mediaType:
                    (ResourceMediaType.parse('application/example')
                            as Ok<ResourceMediaType, StructuredFailure>)
                        .value,
                schemaVersion: testSchemaVersion,
                bytes: const <int>[1, 2, 3],
              )
              as Ok<AlnoteOpaqueEntry, StructuredFailure>)
          .value;
  final preservation =
      (AlnotePackagePreservation.create(
                extensionNamespaces: const <String>['example'],
                opaqueEntries: <AlnoteOpaqueEntry>[opaque],
              )
              as Ok<AlnotePackagePreservation, StructuredFailure>)
          .value;
  return (AlnotePackageSnapshot.create(
            document: testNotebook(),
            resources: const <DocumentResourceSnapshot>[],
            preservation: preservation,
          )
          as Ok<AlnotePackageSnapshot, StructuredFailure>)
      .value;
}

List<int> _catalogPackage() {
  final identity = ResourceIdentity.fromUuid(testUuid(70));
  final catalog =
      (ResourceCatalog.create(<ResourceCatalogEntry>[
                ResourceCatalogEntry(identity),
              ])
              as Ok<ResourceCatalog, StructuredFailure>)
          .value;
  final resource =
      (DocumentResource.capture(
                identity: identity,
                mediaType:
                    (ResourceMediaType.parse('image/png')
                            as Ok<ResourceMediaType, StructuredFailure>)
                        .value,
                role:
                    (ResourceRole.parse('alnote.resource.image')
                            as Ok<ResourceRole, StructuredFailure>)
                        .value,
                schemaVersion: testSchemaVersion,
                bytes: const <int>[7, 8, 9],
              )
              as Ok<DocumentResource, StructuredFailure>)
          .value;
  final opaque =
      (AlnoteOpaqueEntry.create(
                path: 'extensions/example/data.bin',
                mediaType:
                    (ResourceMediaType.parse('application/example')
                            as Ok<ResourceMediaType, StructuredFailure>)
                        .value,
                schemaVersion: testSchemaVersion,
                bytes: const <int>[1, 2, 3],
              )
              as Ok<AlnoteOpaqueEntry, StructuredFailure>)
          .value;
  final preservation =
      (AlnotePackagePreservation.create(
                extensionNamespaces: const <String>['example'],
                opaqueEntries: <AlnoteOpaqueEntry>[opaque],
              )
              as Ok<AlnotePackagePreservation, StructuredFailure>)
          .value;
  final snapshot =
      (AlnotePackageSnapshot.create(
                document: testNotebook(resources: catalog),
                resources: <DocumentResourceSnapshot>[
                  DocumentResourceSnapshot(resource),
                ],
                preservation: preservation,
              )
              as Ok<AlnotePackageSnapshot, StructuredFailure>)
          .value;
  return (AlnotePackageCodec(
            objectRegistry: testRegistry(),
          ).encode(snapshot, limits: phase4Limits())
          as Ok<List<int>, StructuredFailure>)
      .value;
}

List<int> _prependHiddenBytes(List<int> source, List<int> hidden) {
  final bytes = <int>[...hidden, ...source];
  for (final central in _findSignatures(bytes, const <int>[
    0x50,
    0x4b,
    0x01,
    0x02,
  ])) {
    _setUint32(
      bytes,
      central + 42,
      _uint32(bytes, central + 42) + hidden.length,
    );
  }
  final eocd = _findSignatures(bytes, const <int>[
    0x50,
    0x4b,
    0x05,
    0x06,
  ]).single;
  _setUint32(bytes, eocd + 16, _uint32(bytes, eocd + 16) + hidden.length);
  return bytes;
}

List<int> _insertInterEntryGap(List<int> source, List<int> hidden) {
  final locals = _findSignatures(source, const <int>[0x50, 0x4b, 0x03, 0x04]);
  final insertion = locals[1];
  final bytes = List<int>.of(source)..insertAll(insertion, hidden);
  for (final central in _findSignatures(bytes, const <int>[
    0x50,
    0x4b,
    0x01,
    0x02,
  ])) {
    final localOffset = _uint32(bytes, central + 42);
    if (localOffset >= insertion) {
      _setUint32(bytes, central + 42, localOffset + hidden.length);
    }
  }
  final eocd = _findSignatures(bytes, const <int>[
    0x50,
    0x4b,
    0x05,
    0x06,
  ]).single;
  _setUint32(bytes, eocd + 16, _uint32(bytes, eocd + 16) + hidden.length);
  return bytes;
}

List<int> _insertBeforeCentralDirectory(List<int> source, List<int> hidden) {
  final sourceEocd = _findSignatures(source, const <int>[
    0x50,
    0x4b,
    0x05,
    0x06,
  ]).single;
  final centralOffset = _uint32(source, sourceEocd + 16);
  final bytes = List<int>.of(source)..insertAll(centralOffset, hidden);
  final eocd = _findSignatures(bytes, const <int>[
    0x50,
    0x4b,
    0x05,
    0x06,
  ]).single;
  _setUint32(bytes, eocd + 16, centralOffset + hidden.length);
  return bytes;
}

OperationOutcome<OpenedAlnotePackage, StructuredFailure> _open(
  List<int> bytes,
) => AlnotePackageReader(objectRegistry: testRegistry()).openBytes(
  bytes,
  limits: phase4Limits(),
  cancellationToken: CancellationController().token,
);

void _expectRedactedOpenFailure(List<int> bytes, List<String> hostile) {
  final outcome = _open(bytes);
  expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
  for (final value in hostile) {
    expect(outcome.toString(), isNot(contains(value)));
  }
}

List<int> _rewritePackage(
  List<int> source,
  void Function(
    Map<String, Object?> manifest,
    LinkedHashMap<String, List<int>> entries,
  )
  mutation, {
  bool repairCatalog = true,
}) {
  final decoded = ZipDecoder().decodeBytes(source);
  final entries = LinkedHashMap<String, List<int>>.fromEntries(
    decoded.files.map(
      (entry) => MapEntry<String, List<int>>(
        entry.name,
        List<int>.of(entry.readBytes()!),
      ),
    ),
  );
  final manifest = _jsonMap(entries['manifest.json']!);
  mutation(manifest, entries);
  if (repairCatalog) {
    for (final item in manifest['entries']! as List<Object?>) {
      final entry = item! as Map<String, Object?>;
      final bytes = entries[entry['path']! as String];
      if (bytes == null) continue;
      entry
        ..['decodedByteLength'] = bytes.length
        ..['sha256'] = _digest(bytes);
    }
  }
  entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.add(
      ArchiveFile.noCompress(entry.key, entry.value.length, entry.value),
    );
  }
  return ZipEncoder().encodeBytes(archive, modified: DateTime.utc(1980));
}

Map<String, Object?> _jsonMap(List<int> bytes) =>
    (jsonDecode(utf8.decode(bytes))! as Map<String, Object?>);

String _digest(List<int> bytes) =>
    (Sha256Digest.calculate(bytes) as Ok<Sha256Digest, StructuredFailure>)
        .value
        .hexadecimal;

List<int> _findSignatures(List<int> bytes, List<int> signature) {
  final matches = <int>[];
  for (var index = 0; index <= bytes.length - signature.length; index += 1) {
    var matchesAtIndex = true;
    for (var offset = 0; offset < signature.length; offset += 1) {
      if (bytes[index + offset] != signature[offset]) {
        matchesAtIndex = false;
        break;
      }
    }
    if (matchesAtIndex) matches.add(index);
  }
  return matches;
}

int _uint16(List<int> bytes, int offset) =>
    bytes[offset] | bytes[offset + 1] << 8;

int _uint32(List<int> bytes, int offset) =>
    bytes[offset] |
    bytes[offset + 1] << 8 |
    bytes[offset + 2] << 16 |
    bytes[offset + 3] << 24;

void _setUint16(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = value >> 8 & 0xff;
}

void _setUint32(List<int> bytes, int offset, int value) {
  for (var index = 0; index < 4; index += 1) {
    bytes[offset + index] = value >> (index * 8) & 0xff;
  }
}

List<int> _addUnsupportedCentralExtra(List<int> source) {
  final bytes = List<int>.of(source);
  final central = _findSignatures(bytes, const <int>[
    0x50,
    0x4b,
    0x01,
    0x02,
  ]).first;
  final nameLength = _uint16(bytes, central + 28);
  final insertion = central + 46 + nameLength;
  bytes.insertAll(insertion, const <int>[0x34, 0x12, 0, 0]);
  _setUint16(bytes, central + 30, 4);
  final eocd = _findSignatures(bytes, const <int>[
    0x50,
    0x4b,
    0x05,
    0x06,
  ]).single;
  _setUint32(bytes, eocd + 12, _uint32(bytes, eocd + 12) + 4);
  return bytes;
}

final class _ThrowingIterable extends Iterable<int> {
  _ThrowingIterable(this.hostile);
  final String hostile;

  @override
  Iterator<int> get iterator => throw StateError(hostile);
}

final class _CountingIterable extends Iterable<int> {
  var observed = 0;

  @override
  Iterator<int> get iterator => _CountingIterator(this);
}

final class _CountingIterator implements Iterator<int> {
  _CountingIterator(this.owner);
  final _CountingIterable owner;
  var _current = 0;

  @override
  int get current => _current;

  @override
  bool moveNext() {
    owner.observed += 1;
    _current = owner.observed & 0xff;
    return true;
  }
}

final class _ThrowingSource implements PackageByteSource {
  _ThrowingSource(this.hostile);
  final String hostile;

  @override
  Future<OperationOutcome<List<int>, StructuredFailure>> readAll({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) => throw StateError(hostile);
}

final class _OversizedSource implements PackageByteSource {
  @override
  Future<OperationOutcome<List<int>, StructuredFailure>> readAll({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) async => Completed<List<int>, StructuredFailure>(
    List<int>.filled(maximumBytes + 1, 0),
  );
}
