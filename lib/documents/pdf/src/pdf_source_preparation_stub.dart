// SPDX-License-Identifier: GPL-3.0-or-later
import '../../../core/outcomes/cancellation.dart';
import '../../resources/resource_records.dart';

Future<CapturedResourceBytes> preparePdfSource(
  List<int> bytes,
  int maximumBytes,
  CancellationToken token,
) => CapturedResourceBytes.capture(
  bytes,
  maximumBytes: maximumBytes,
  cancellationToken: token,
);
