// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';

/// A deterministic clock whose UTC value can be changed by tests.
final class ControllableClock implements Clock {
  /// Creates a clock at [initialTime], normalized to UTC.
  ControllableClock(DateTime initialTime) : _current = initialTime.toUtc();

  DateTime _current;

  @override
  DateTime nowUtc() => _current;

  /// Advances the clock by [duration].
  void advance(Duration duration) {
    _current = _current.add(duration);
  }

  /// Sets the clock to [time], normalized to UTC.
  void setTime(DateTime time) {
    _current = time.toUtc();
  }
}
