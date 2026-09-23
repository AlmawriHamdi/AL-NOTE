// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'support/verified_fixture_library.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (!kIsWeb) {
    // Configure only; individual tests retain ownership of native initialization.
    pdfrx.Pdfrx.pdfiumModulePath = await verifiedFixtureLibrary();
  }
  await testMain();
}
