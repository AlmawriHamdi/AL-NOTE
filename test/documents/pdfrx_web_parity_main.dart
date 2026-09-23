// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../support/pdf_geometry_checks.dart';

@JS('reportPdfParity')
external void _report(JSString result);

@JS('beginPdfBridgeFailures')
external void _beginBridgeFailures();

@JS('endPdfBridgeFailures')
external JSString _endBridgeFailures();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Map<String, Object> result;
  try {
    await pdfrx.pdfrxFlutterInitialize();
    final rows = await checkMarkedPdfGeometry();
    _beginBridgeFailures();
    var rejected = 0;
    for (var i = 0; i < 4; i++) {
      try {
        final document = await pdfrx.PdfDocument.openData(
          markedPdf(geometryCases.first, 0),
          sourceName: 'controlled-bridge',
        );
        await document.dispose();
      } on pdfrx.PdfPageBoxException {
        rejected++;
      }
    }
    final bridge =
        jsonDecode(_endBridgeFailures().toDart) as Map<String, dynamic>;
    if (rejected != 4 || bridge['opens'] != 4 || bridge['closes'] != 4) {
      throw StateError('Bridge initialization cleanup: $bridge / $rejected');
    }
    result = {'pass': true, 'cases': rows, 'bridgeCleanup': bridge};
  } on Object catch (error) {
    result = {'pass': false, 'error': error.toString()};
  }
  final text = jsonEncode(result);
  debugPrint(text);
  _report(text.toJS);
  runApp(MaterialApp(home: Scaffold(body: Text(text))));
}
