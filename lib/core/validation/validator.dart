// SPDX-License-Identifier: GPL-3.0-or-later

import 'validation_report.dart';

/// Validates values of type [T] without throwing for validation findings.
abstract interface class Validator<T> {
  /// Returns a deterministic report for [value].
  ValidationReport validate(T value);
}
