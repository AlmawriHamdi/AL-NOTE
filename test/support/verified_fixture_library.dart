// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<String> verifiedFixtureLibrary({String? modulePath}) async {
  final manifest = jsonDecode(
    await File('tool/pdf_fixture_resources.json').readAsString(),
  ) as Map<String, dynamic>;
  final targets = manifest['targets'] as Map<String, dynamic>;
  final record = targets[Platform.operatingSystem] as Map<String, dynamic>?;
  if (record == null) {
    throw UnsupportedError(
      'No reviewed fixture library for this test platform',
    );
  }
  final configured =
      modulePath ?? Platform.environment['ALNOTE_PDF_FIXTURE_LIBRARY'];
  final file = File(configured ?? 'build/pdf-fixture/${record['filename']}');
  final expectedLength = record['bytes'] as int;
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type != FileSystemEntityType.file ||
      expectedLength <= 0 ||
      expectedLength > 32 * 1024 * 1024 ||
      await file.length() != expectedLength) {
    throw StateError(
      'Missing or invalid PDF fixture library. Run '
      'python3 tool/provision_pdf_fixture.py; SDK discovery is disabled.',
    );
  }
  var length = 0;
  final digest = await sha256
      .bind(
        file.openRead().map((chunk) {
          length += chunk.length;
          if (length > expectedLength) {
            throw StateError('PDF fixture library exceeded its pinned length');
          }
          return chunk;
        }),
      )
      .single;
  if (length != expectedLength || digest.toString() != record['sha256']) {
    throw StateError('PDF fixture library digest mismatch');
  }
  return file.absolute.path;
}
