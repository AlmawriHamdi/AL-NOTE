// SPDX-License-Identifier: GPL-3.0-or-later

/// Supplies the current time in UTC.
abstract interface class Clock {
  /// Returns the current UTC date and time.
  DateTime nowUtc();
}
