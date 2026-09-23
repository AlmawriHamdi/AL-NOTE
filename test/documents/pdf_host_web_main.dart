// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:js_interop';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/pdf.dart';
import 'package:flutter/widgets.dart';

@JS('configureHostCase')
external void _configure(String mode, int actualLength, int reportedLength);
@JS('registerHostCancellation')
external void _registerCancel(JSFunction callback);
@JS('hostCaseStats')
external JSString _stats();
@JS('reportHostReading')
external void _report(JSString result);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final rows = <Map<String, Object>>[];
  try {
    for (final spec in [
      ('empty', 0, -1, 4, 'unavailable'),
      ('exact', 4, -1, 4, 'success'),
      ('over', 5, -1, 4, 'resourceLimit'),
      ('falseLow', 5, 1, 4, 'resourceLimit'),
      ('falseHigh', 4, 5, 4, 'resourceLimit'),
      ('short', 10, 1, 10, 'success'),
      ('chunks', 131072, -1, 131072, 'success'),
      ('throwing', 4, -1, 4, 'unavailable'),
      ('cancelRead', 4, -1, 4, 'cancelled'),
      ('pickerCancel', 4, -1, 4, 'cancelled'),
      ('tokenPickerCancel', 4, -1, 4, 'cancelled'),
    ]) {
      _configure(spec.$1, spec.$2, spec.$3);
      final cancellation = CancellationController();
      _registerCancel(cancellation.cancel.toJS);
      final result =
          await LocalPdfFileSelector(host: createPlatformLocalPdfPickerHost())
              .select(
                maximumEncodedBytes: spec.$4,
                cancellationToken: cancellation.token,
              );
      final kind = switch (result) {
        LocalPdfSelectionSuccess() => 'success',
        LocalPdfSelectionCancelled() => 'cancelled',
        LocalPdfSelectionFailure(:final reason) => reason.name,
      };
      final stats = jsonDecode(_stats().toDart) as Map<String, dynamic>;
      if (kind != spec.$5 ||
          stats['urls'] != 0 ||
          stats['remainingInputs'] != 0 ||
          stats['multiple'] != false) {
        throw StateError('${spec.$1}: $kind / $stats');
      }
      if (result is LocalPdfSelectionSuccess &&
          result.bytes.length != spec.$2) {
        throw StateError('Actual delivery was not captured exactly');
      }
      final reads = stats['reads'] as List<dynamic>;
      if ((spec.$1 == 'over' || spec.$1 == 'falseHigh') && reads.isNotEmpty) {
        throw StateError('Oversize metadata materialized before rejection');
      }
      if (spec.$1 == 'cancelRead' && stats['aborts'] != 1) {
        throw StateError('Active reader was not aborted exactly once');
      }
      rows.add({'case': spec.$1, 'outcome': kind, 'stats': stats});
    }
    _report(jsonEncode({'pass': true, 'cases': rows}).toJS);
  } on Object catch (error) {
    _report(
      jsonEncode({'pass': false, 'error': error.toString(), 'cases': rows})
          .toJS,
    );
  }
  runApp(const SizedBox());
}
