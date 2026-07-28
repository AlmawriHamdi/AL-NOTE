// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/document_model_test_support.dart';
import '../../support/phase4_test_support.dart';

void main() {
  group('canonical version-1 package', () {
    test('is byte-identical and uses exact canonical ZIP metadata', () {
      final codec = AlnotePackageCodec(objectRegistry: testRegistry());
      final snapshot = _snapshot(testNotebook());

      final first = _encode(codec, snapshot);
      final second = _encode(codec, snapshot);

      expect(second, first);
      final archive = ZipDecoder().decodeBytes(first);
      expect(archive.files.map((entry) => entry.name), <String>[
        'mimetype',
        'manifest.json',
        'document.json',
        'sections/00000000-0000-4000-8000-000000000030.json',
        'pages/00000000-0000-4000-8000-000000000020.json',
      ]);
      expect(archive.files.first.content, alnotePackageMediaType.codeUnits);
      for (final entry in archive.files) {
        expect(entry.compression, CompressionType.none);
        expect(entry.unixPermissions, 0x1a4);
        expect(entry.isFile, isTrue);
        expect(entry.isSymbolicLink, isFalse);
        expect(entry.comment, isNull);
        expect(entry.lastModDateTime, DateTime.utc(1980));
      }
    });

    test('matches the reviewed canonical .alnote golden fixture', () {
      final bytes = _encode(
        AlnotePackageCodec(objectRegistry: testRegistry()),
        _snapshot(testNotebook()),
      );
      final fixture = File(
        'test/fixtures/phase4/canonical_notebook.alnote',
      ).readAsBytesSync();

      expect(fixture, hasLength(2335));
      expect(
        (Sha256Digest.calculate(fixture) as Ok<Sha256Digest, StructuredFailure>)
            .value
            .hexadecimal,
        'c1bfede8112e4151095cfec4006fb22ef29a7fc431c6eab47c33ed840c84f786',
      );
      expect(bytes, fixture);
    });

    test('round-trips a Notebook with lazy Page publication', () {
      final registry = testRegistry();
      final bytes = _encode(
        AlnotePackageCodec(objectRegistry: registry),
        _snapshot(testNotebook()),
      );
      final opened = AlnotePackageReader(objectRegistry: registry).openBytes(
        bytes,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );

      expect(opened, isA<Completed<OpenedAlnotePackage, StructuredFailure>>());
      final package =
          (opened as Completed<OpenedAlnotePackage, StructuredFailure>).value;
      expect(package.evidence.lazy, isTrue);
      expect(package.pageHandles, hasLength(1));
      expect(package.resourceHandles, isEmpty);
      final materialized = package.materializeDocument(
        cancellationToken: CancellationController().token,
      );
      expect(materialized, isA<Completed<DocumentRoot, StructuredFailure>>());
      expect(
        (materialized as Completed<DocumentRoot, StructuredFailure>).value,
        testNotebook(),
      );
    });

    test('does not interpret corrupt Page bytes until the lazy Page load', () {
      final registry = testRegistry();
      final bytes = _encode(
        AlnotePackageCodec(objectRegistry: registry),
        _snapshot(testNotebook()),
      );
      final corrupt = _corruptStoredEntry(
        bytes,
        'pages/00000000-0000-4000-8000-000000000020.json',
      );

      final opened = AlnotePackageReader(objectRegistry: registry).openBytes(
        corrupt,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );

      expect(opened, isA<Completed<OpenedAlnotePackage, StructuredFailure>>());
      final package =
          (opened as Completed<OpenedAlnotePackage, StructuredFailure>).value;
      final failed = package.pageHandles.single.load(
        cancellationToken: CancellationController().token,
      );
      expect(failed, isA<Failed<DocumentPage, StructuredFailure>>());
      expect(failed.toString(), isNot(contains('pages/')));
    });

    test('reads and verifies the manifest and root eagerly', () {
      final registry = testRegistry();
      final bytes = _encode(
        AlnotePackageCodec(objectRegistry: registry),
        _snapshot(testNotebook()),
      );
      final corrupt = _corruptStoredEntry(bytes, 'document.json');

      expect(
        AlnotePackageReader(objectRegistry: registry).openBytes(
          corrupt,
          limits: phase4Limits(),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<OpenedAlnotePackage, StructuredFailure>>(),
      );
    });

    test('preserves unknown records and safe extension bytes inertly', () {
      final unknownObject = testObject(
        typeKey: testObjectTypeKey('example.unknown.object'),
        payload: PreservedMap(<String, PreservedData>{
          'future': const PreservedString('data'),
        }),
        extensionData: PreservedMap(<String, PreservedData>{
          'futureEnvelope': const PreservedBoolean(true),
        }),
      );
      final document = testNotebook(
        extensionData: PreservedMap(<String, PreservedData>{
          'futureRoot': _preservedInteger(4),
        }),
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
      final snapshot =
          (AlnotePackageSnapshot.create(
                    document: document,
                    resources: const <DocumentResourceSnapshot>[],
                    preservation:
                        (AlnotePackagePreservation.create(
                                  unknownManifestFields:
                                      PreservedMap(<String, PreservedData>{
                                        'futureManifest': const PreservedString(
                                          'value',
                                        ),
                                      }),
                                  optionalFeatures: const <String>[
                                    'future_feature',
                                  ],
                                  extensionNamespaces: const <String>[
                                    'example',
                                  ],
                                  opaqueEntries: <AlnoteOpaqueEntry>[
                                    (AlnoteOpaqueEntry.create(
                                              path:
                                                  'extensions/example/data.bin',
                                              mediaType: _media(
                                                'application/example',
                                              ),
                                              schemaVersion: testSchemaVersion,
                                              bytes: <int>[4, 5, 6],
                                            )
                                            as Ok<
                                              AlnoteOpaqueEntry,
                                              StructuredFailure
                                            >)
                                        .value,
                                  ],
                                )
                                as Ok<
                                  AlnotePackagePreservation,
                                  StructuredFailure
                                >)
                            .value,
                  )
                  as Ok<AlnotePackageSnapshot, StructuredFailure>)
              .value;
      final registry = testRegistry();
      final first = _encode(
        AlnotePackageCodec(objectRegistry: registry),
        snapshot,
      );
      final opened =
          AlnotePackageReader(objectRegistry: registry).openBytes(
                first,
                limits: phase4Limits(),
                cancellationToken: CancellationController().token,
              )
              as Completed<OpenedAlnotePackage, StructuredFailure>;
      final materialized =
          opened.value.materializeSnapshot(
                cancellationToken: CancellationController().token,
              )
              as Completed<AlnotePackageSnapshot, StructuredFailure>;
      final second = _encode(
        AlnotePackageCodec(objectRegistry: registry),
        materialized.value,
      );

      expect(materialized.value.document, document);
      expect(materialized.value.preservation.opaqueEntries.single.bytes, <int>[
        4,
        5,
        6,
      ]);
      expect(materialized.value.preservation.optionalFeatures, <String>[
        'future_feature',
      ]);
      expect(
        materialized.value.preservation.optionalFeatures.clear,
        throwsUnsupportedError,
      );
      expect(materialized.value.preservation.extensionNamespaces, <String>[
        'example',
      ]);
      expect(
        materialized.value.preservation.extensionNamespaces.clear,
        throwsUnsupportedError,
      );
      expect(
        materialized.value.preservation.opaqueEntries.single.mediaType.value,
        'application/example',
      );
      expect(
        materialized.value.preservation.opaqueEntries.single.schemaVersion,
        testSchemaVersion,
      );
      expect(second, first);
    });

    test('round-trips Standalone Page and Standalone PDF forms', () {
      final registry = testRegistry();
      final pageDocument = modelValue<StandalonePageDocument>(
        StandalonePageDocument.create(
          id: DocumentId.fromUuid(testUuid(41)),
          schemaVersion: testSchemaVersion,
          title: 'Page',
          resources: emptyResourceCatalog(),
          extensionData: PreservedMap.empty(),
          page: testPage(),
        ),
      );
      final pdfResourceId = ResourceIdentity.fromUuid(testUuid(50));
      final catalog = modelValue<ResourceCatalog>(
        ResourceCatalog.create(<ResourceCatalogEntry>[
          ResourceCatalogEntry(pdfResourceId),
        ]),
      );
      final pdfDocument = modelValue<StandalonePdfDocument>(
        StandalonePdfDocument.create(
          id: DocumentId.fromUuid(testUuid(42)),
          schemaVersion: testSchemaVersion,
          title: 'PDF',
          resources: catalog,
          extensionData: PreservedMap.empty(),
          pages: <DocumentPage>[testPage()],
          source: ResourceReference(pdfResourceId),
        ),
      );
      final mediaType = _media('application/pdf');
      final role = _role('alnote.resource.pdf');
      final resource =
          (DocumentResource.capture(
                    identity: pdfResourceId,
                    mediaType: mediaType,
                    role: role,
                    schemaVersion: testSchemaVersion,
                    bytes: <int>[1, 2, 3, 4],
                  )
                  as Ok<DocumentResource, StructuredFailure>)
              .value;

      for (final snapshot in <AlnotePackageSnapshot>[
        _snapshot(pageDocument),
        _snapshot(pdfDocument, resources: <DocumentResource>[resource]),
      ]) {
        final bytes = _encode(
          AlnotePackageCodec(objectRegistry: registry),
          snapshot,
        );
        final opened =
            AlnotePackageReader(objectRegistry: registry).openBytes(
                  bytes,
                  limits: phase4Limits(),
                  cancellationToken: CancellationController().token,
                )
                as Completed<OpenedAlnotePackage, StructuredFailure>;
        final result = opened.value.materializeSnapshot(
          cancellationToken: CancellationController().token,
        );
        expect(
          result,
          isA<Completed<AlnotePackageSnapshot, StructuredFailure>>(),
        );
        expect(
          (result as Completed<AlnotePackageSnapshot, StructuredFailure>)
              .value
              .document,
          snapshot.document,
        );
      }
    });

    test(
      'resources deduplicate shared digest paths but retain logical IDs',
      () {
        final firstId = ResourceIdentity.fromUuid(testUuid(51));
        final secondId = ResourceIdentity.fromUuid(testUuid(52));
        final catalog = modelValue<ResourceCatalog>(
          ResourceCatalog.create(<ResourceCatalogEntry>[
            ResourceCatalogEntry(firstId),
            ResourceCatalogEntry(secondId),
          ]),
        );
        final document = testNotebook(resources: catalog);
        DocumentResource resource(ResourceIdentity id) =>
            (DocumentResource.capture(
                      identity: id,
                      mediaType: _media('image/png'),
                      role: _role('alnote.resource.image'),
                      schemaVersion: testSchemaVersion,
                      bytes: <int>[7, 8, 9],
                    )
                    as Ok<DocumentResource, StructuredFailure>)
                .value;
        final bytes = _encode(
          AlnotePackageCodec(objectRegistry: testRegistry()),
          _snapshot(
            document,
            resources: <DocumentResource>[
              resource(firstId),
              resource(secondId),
            ],
          ),
        );
        final archive = ZipDecoder().decodeBytes(bytes);
        expect(
          archive.files.where((entry) => entry.name.startsWith('resources/')),
          hasLength(1),
        );
        final opened =
            AlnotePackageReader(objectRegistry: testRegistry()).openBytes(
                  bytes,
                  limits: phase4Limits(),
                  cancellationToken: CancellationController().token,
                )
                as Completed<OpenedAlnotePackage, StructuredFailure>;
        expect(opened.value.resourceHandles, hasLength(2));
        for (final handle in opened.value.resourceHandles) {
          expect(
            handle.load(cancellationToken: CancellationController().token),
            isA<Completed<DocumentResource, StructuredFailure>>(),
          );
        }
      },
    );

    test('cancellation never publishes a partial root', () {
      final controller = CancellationController()..cancel('test');
      final outcome = AlnotePackageCodec(objectRegistry: testRegistry())
          .encodeOperation(
            _snapshot(testNotebook()),
            limits: phase4Limits(),
            cancellationToken: controller.token,
          );
      expect(outcome, isA<Cancelled<List<int>, StructuredFailure>>());
    });
  });

  group('hostile ZIP rejection', () {
    for (final name in <String>[
      '../escape',
      '/absolute',
      r'c:\drive',
      r'pages\bad.json',
      'Pages/upper.json',
      'extensions/ns/../escape',
      'extensions/ns/nonascii-é',
    ]) {
      test('rejects unsafe path shape ${name.codeUnits.length}', () {
        final archive = Archive()
          ..add(ArchiveFile.noCompress(name, 1, <int>[0]));
        final bytes = ZipEncoder().encodeBytes(
          archive,
          modified: DateTime.utc(1980),
        );
        final outcome = AlnotePackageReader(objectRegistry: testRegistry())
            .openBytes(
              bytes,
              limits: phase4Limits(),
              cancellationToken: CancellationController().token,
            );
        expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
        expect(outcome.toString(), isNot(contains(name)));
      });
    }

    test('rejects truncation and ZIP64 marker before decoding', () {
      final valid = _encode(
        AlnotePackageCodec(objectRegistry: testRegistry()),
        _snapshot(testNotebook()),
      );
      final truncated = valid.sublist(0, valid.length - 8);
      final zip64 = List<int>.of(valid);
      final eocd = _findSignature(zip64, <int>[0x50, 0x4b, 0x05, 0x06]);
      zip64[eocd + 10] = 0xff;
      zip64[eocd + 11] = 0xff;
      for (final bytes in <List<int>>[truncated, zip64]) {
        expect(
          AlnotePackageReader(objectRegistry: testRegistry()).openBytes(
            bytes,
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          ),
          isA<Failed<OpenedAlnotePackage, StructuredFailure>>(),
        );
      }
    });

    test(
      'rejects encryption, unsupported compression, and multi-disk flags',
      () {
        final valid = _encode(
          AlnotePackageCodec(objectRegistry: testRegistry()),
          _snapshot(testNotebook()),
        );
        final local = _findSignature(valid, <int>[0x50, 0x4b, 0x03, 0x04]);
        final central = _findSignature(valid, <int>[0x50, 0x4b, 0x01, 0x02]);
        final eocd = _findSignature(valid, <int>[0x50, 0x4b, 0x05, 0x06]);
        final encrypted = List<int>.of(valid)
          ..[local + 6] |= 1
          ..[central + 8] |= 1;
        final unsupported = List<int>.of(valid)
          ..[local + 8] = 12
          ..[local + 9] = 0
          ..[central + 10] = 12
          ..[central + 11] = 0;
        final multiDisk = List<int>.of(valid)
          ..[eocd + 4] = 1
          ..[eocd + 5] = 0;

        for (final bytes in <List<int>>[encrypted, unsupported, multiDisk]) {
          expect(
            AlnotePackageReader(objectRegistry: testRegistry()).openBytes(
              bytes,
              limits: phase4Limits(),
              cancellationToken: CancellationController().token,
            ),
            isA<Failed<OpenedAlnotePackage, StructuredFailure>>(),
          );
        }
      },
    );

    test('rejects symlinks and special entry metadata', () {
      final archive = Archive();
      final link = ArchiveFile.noCompress(
        'document.json',
        14,
        'private-target'.codeUnits,
      )..mode = 0xa1ff;
      archive.add(link);
      final bytes = ZipEncoder().encodeBytes(
        archive,
        modified: DateTime.utc(1980),
      );

      final outcome = AlnotePackageReader(objectRegistry: testRegistry())
          .openBytes(
            bytes,
            limits: phase4Limits(),
            cancellationToken: CancellationController().token,
          );
      expect(outcome, isA<Failed<OpenedAlnotePackage, StructuredFailure>>());
      expect(outcome.toString(), isNot(contains('private-target')));
    });

    test('preflights decoded-size, ratio, and entry-count limits', () {
      final archive = Archive()
        ..add(ArchiveFile.bytes('mimetype', List<int>.filled(10000, 0)))
        ..add(ArchiveFile.bytes('manifest.json', <int>[0]));
      final bytes = ZipEncoder().encodeBytes(
        archive,
        modified: DateTime.utc(1980),
      );
      final reader = AlnotePackageReader(objectRegistry: testRegistry());
      for (final limits in <ResourceLimitSnapshot>[
        phase4Limits(
          overrides: const <String, int>{
            'alnote.storage.entry_decoded_bytes': 100,
          },
        ),
        phase4Limits(
          overrides: const <String, int>{'alnote.storage.compression_ratio': 1},
        ),
        phase4Limits(
          overrides: const <String, int>{'alnote.storage.entry_count': 1},
        ),
      ]) {
        expect(
          reader.openBytes(
            bytes,
            limits: limits,
            cancellationToken: CancellationController().token,
          ),
          isA<Failed<OpenedAlnotePackage, StructuredFailure>>(),
        );
      }
    });
  });
}

AlnotePackageSnapshot _snapshot(
  DocumentRoot document, {
  Iterable<DocumentResource> resources = const <DocumentResource>[],
}) =>
    (AlnotePackageSnapshot.create(
              document: document,
              resources: resources.map(DocumentResourceSnapshot.new),
            )
            as Ok<AlnotePackageSnapshot, StructuredFailure>)
        .value;

List<int> _encode(AlnotePackageCodec codec, AlnotePackageSnapshot snapshot) =>
    (codec.encode(snapshot, limits: phase4Limits())
            as Ok<List<int>, StructuredFailure>)
        .value;

ResourceMediaType _media(String value) =>
    (ResourceMediaType.parse(value) as Ok<ResourceMediaType, StructuredFailure>)
        .value;

ResourceRole _role(String value) =>
    (ResourceRole.parse(value) as Ok<ResourceRole, StructuredFailure>).value;

int _findSignature(List<int> bytes, List<int> signature) {
  for (var index = bytes.length - signature.length; index >= 0; index -= 1) {
    if (bytes
        .sublist(index, index + signature.length)
        .asMap()
        .entries
        .every((entry) => entry.value == signature[entry.key])) {
      return index;
    }
  }
  throw StateError('signature missing');
}

List<int> _corruptStoredEntry(List<int> source, String target) {
  final bytes = List<int>.of(source);
  var cursor = 0;
  while (cursor + 30 <= bytes.length &&
      bytes[cursor] == 0x50 &&
      bytes[cursor + 1] == 0x4b &&
      bytes[cursor + 2] == 0x03 &&
      bytes[cursor + 3] == 0x04) {
    int uint16(int offset) => bytes[offset] | bytes[offset + 1] << 8;
    int uint32(int offset) =>
        bytes[offset] |
        bytes[offset + 1] << 8 |
        bytes[offset + 2] << 16 |
        bytes[offset + 3] << 24;
    final compressed = uint32(cursor + 18);
    final nameLength = uint16(cursor + 26);
    final extraLength = uint16(cursor + 28);
    final name = String.fromCharCodes(
      bytes.sublist(cursor + 30, cursor + 30 + nameLength),
    );
    final dataOffset = cursor + 30 + nameLength + extraLength;
    if (name == target) {
      bytes[dataOffset] ^= 1;
      return bytes;
    }
    cursor = dataOffset + compressed;
  }
  throw StateError('target entry missing');
}

PreservedInteger _preservedInteger(int value) =>
    (PreservedInteger.create(value) as Ok<PreservedInteger, StructuredFailure>)
        .value;
