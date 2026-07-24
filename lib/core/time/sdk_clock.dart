// SPDX-License-Identifier: GPL-3.0-or-later

import 'clock.dart';

/// A production [Clock] backed by the Dart SDK system clock.
final class SdkClock implements Clock {
  /// Creates an SDK-backed clock.
  const SdkClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}
