// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:uuid/data.dart';
import 'package:uuid/rng.dart';
import 'package:uuid/uuid.dart';

/// Generates a v4 UUID through the package's explicitly injected RNG option.
///
/// This adapter is intentionally not exported from the AL NOTE public barrel.
String generateUuidV4FromBytes(List<int> bytes) {
  final injectedRng = LegacyRNG(
    () => Uint8List.fromList(bytes),
    const <Symbol, dynamic>{},
    const <dynamic>[],
  );
  return const Uuid().v4(config: V4Options(null, injectedRng));
}
