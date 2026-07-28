// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Phase 4 dependency boundaries', () {
    test('lockfile has exact reviewed versions and checksums', () {
      final lockfile = File('pubspec.lock').readAsStringSync();
      for (final evidence in const <String>[
        'version: "4.0.9"',
        'a96e8b390886ee8abb49b7bd3ac8df6f451c621619f52a26e815fdcf568959ff',
        'version: "6.5.2"',
        'bc1bad54ad2b735816e31f8d4600cfde6c7839975085ddfbca48b6c9f7c4044e',
        'version: "2.2.0"',
        '6d7fd89431262d8f3125e81b50d3847a091d846eafcd4fdb88dd06f36d705a45',
        'version: "3.0.7"',
        'c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf',
      ]) {
        expect(lockfile, contains(evidence));
      }
    });

    test('package imports remain confined to their private adapters', () {
      final production = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      final imports = <String, List<String>>{};
      for (final file in production) {
        final source = file.readAsStringSync();
        for (final package in const <String>[
          'archive',
          'crypto',
          'posix',
          'ffi',
          'path',
        ]) {
          if (source.contains("import 'package:$package/")) {
            imports.putIfAbsent(package, () => <String>[]).add(file.path);
          }
        }
      }

      expect(imports['archive'], hasLength(1));
      expect(
        imports['archive']!.single,
        endsWithPath('lib/documents/files/src/archive_adapter.dart'),
      );
      expect(imports['crypto'], hasLength(1));
      expect(
        imports['crypto']!.single,
        endsWithPath('lib/documents/files/src/sha256_adapter.dart'),
      );
      expect(imports['posix'], isNull);
      expect(imports['ffi'], isNull);
      expect(imports['path'], isNull);
      expect(
        File('lib/documents/files/src/archive_adapter.dart').readAsStringSync(),
        contains("import 'package:archive/archive.dart';"),
      );
      expect(
        File('lib/documents/files/src/archive_adapter.dart').readAsStringSync(),
        isNot(contains('archive_io.dart')),
      );
    });

    test('portable production code has no platform-only imports', () {
      final files = Directory('lib/documents/files')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in files) {
        final source = file.readAsStringSync();
        expect(source, isNot(contains("import 'dart:io'")));
        expect(source, isNot(contains("import 'dart:ffi'")));
        expect(source, isNot(contains("import 'dart:html'")));
        expect(source, isNot(contains('package:flutter/')));
      }
    });

    test('public barrel exports only AL NOTE-owned contracts', () {
      final barrel = File('lib/documents/files.dart').readAsStringSync();
      expect(barrel, isNot(contains('package:archive')));
      expect(barrel, isNot(contains('package:crypto')));
      expect(barrel, isNot(contains('/src/')));
    });
  });
}

/// Matches a platform-native path by canonical trailing segments.
Matcher endsWithPath(String path) => predicate<String>(
  (value) => value.replaceAll('\\', '/').endsWith(path),
  'ends with $path',
);
