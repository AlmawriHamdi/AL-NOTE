// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../support/verified_fixture_library.dart';

void main() {
  test('fixture bootstrap uses the verified explicit library', () async {
    expect(pdfrx.Pdfrx.pdfiumModulePath, await verifiedFixtureLibrary());
    expect(pdfrx.Pdfrx.pdfiumModulePath, isNot(contains('artifacts/engine')));
  });

  test('missing corrupt wrong and symlinked fixtures reject without changing initialization', () async {
    final directory = Directory.systemTemp.createTempSync(
      'fixture-rejections-',
    );
    final configured = pdfrx.Pdfrx.pdfiumModulePath;
    try {
      final missing = '${directory.path}/missing';
      await expectLater(
        verifiedFixtureLibrary(modulePath: missing),
        throwsStateError,
      );
      final wrong = File('${directory.path}/wrong')
        ..writeAsStringSync('not PDFium');
      await expectLater(
        verifiedFixtureLibrary(modulePath: wrong.path),
        throwsStateError,
      );
      final corrupt = await File(configured!).copy('${directory.path}/corrupt');
      final bytes = corrupt.readAsBytesSync();
      bytes[0] ^= 1;
      corrupt.writeAsBytesSync(bytes);
      await expectLater(
        verifiedFixtureLibrary(modulePath: corrupt.path),
        throwsStateError,
      );
      // Unix symlinks do not require the Windows developer-mode privilege.
      if (Platform.isLinux) {
        final link = Link('${directory.path}/linked')..createSync(configured);
        await expectLater(
          verifiedFixtureLibrary(modulePath: link.path),
          throwsStateError,
        );
      }
      expect(pdfrx.Pdfrx.pdfiumModulePath, configured);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}
