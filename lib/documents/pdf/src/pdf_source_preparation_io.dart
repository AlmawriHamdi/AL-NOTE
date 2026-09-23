// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:isolate';
import 'dart:typed_data';

import '../../../core/outcomes/cancellation.dart';
import '../../resources/resource_records.dart';
import 'linux/linux_pdf_isolate.dart';

Future<CapturedResourceBytes> preparePdfSource(
  List<int> bytes,
  int maximumBytes,
  CancellationToken token,
) async {
  if (token.isCancelled || maximumBytes <= 0) {
    throw const FormatException('source preparation unavailable');
  }
  final int sourceLength;
  try {
    sourceLength = bytes.length;
  } on Object {
    throw const FormatException('source preparation unavailable');
  }
  if (sourceLength <= 0 || sourceLength > maximumBytes || token.isCancelled) {
    throw const FormatException('source preparation unavailable');
  }
  // Typed input is handed off as exactly the validated prefix. Generic Lists
  // are independently captured in the isolate with this length as their ceiling;
  // a changed getter there cannot enlarge the originally admitted capture.
  final Object source;
  try {
    source = bytes is Uint8List
        ? TransferableTypedData.fromList([
            Uint8List.view(bytes.buffer, bytes.offsetInBytes, sourceLength),
          ])
        : bytes;
  } on Object {
    throw const FormatException('source preparation unavailable');
  }
  return await runLinuxPdfTask(_captureTask(source, sourceLength), token);
}

// A separate closure factory captures no workflow, backend or UI state.
Future<CapturedResourceBytes> Function(CancellationToken) _captureTask(
  Object source,
  int maximumBytes,
) =>
    (token) => CapturedResourceBytes.capture(
      source is TransferableTypedData
          ? source.materialize().asUint8List()
          : source as List<int>,
      maximumBytes: maximumBytes,
      cancellationToken: token,
    );
