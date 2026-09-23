// SPDX-License-Identifier: GPL-3.0-or-later
import '../../../core/outcomes/cancellation.dart';
import '../../resources/resource_records.dart';
import 'pdf_source_preparation_stub.dart'
    if (dart.library.io) 'pdf_source_preparation_io.dart'
    as platform;

Future<CapturedResourceBytes> preparePdfSource(
  List<int> bytes,
  int maximumBytes,
  CancellationToken token,
) => platform.preparePdfSource(bytes, maximumBytes, token);
