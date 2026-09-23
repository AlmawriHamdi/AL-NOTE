// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

import '../../../core/outcomes/cancellation.dart';
import '../pdf_file_selection.dart';
import 'local_pdf_picker_android.dart';
import 'local_pdf_picker_stub.dart'
    if (dart.library.io) 'local_pdf_picker_io.dart'
    if (dart.library.js_interop) 'local_pdf_picker_web.dart'
    as platform;

/// Android uses the app-owned bounded SAF channel; desktop/Web keep their
/// existing bounded hosts. No route invokes Android's eager picker plugin.
LocalPdfPickerHost createPlatformLocalPdfPickerHost() =>
    !platformLocalPdfOpeningAvailable
    ? const _UnavailableHost()
    : !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? createAndroidPdfPickerHost()
    : platform.createHost();

bool get platformLocalPdfOpeningAvailable =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.android;

String get platformLocalPdfOpeningStatus => platformLocalPdfOpeningAvailable
    ? 'Only reviewed development PDF fixtures; arbitrary PDFs stay quarantined'
    : 'PDF fixture opening unavailable: bounded platform reading is not implemented';

final class _UnavailableHost implements LocalPdfPickerHost {
  const _UnavailableHost();
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async => throw const LocalPdfRouteUnavailableException();
}
