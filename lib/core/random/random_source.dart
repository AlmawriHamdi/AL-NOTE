// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// Supplies random bytes without exposing a platform-specific generator.
abstract interface class RandomSource {
  /// Returns exactly [length] random bytes or a structured failure.
  Result<List<int>, StructuredFailure> nextBytes(int length);
}
