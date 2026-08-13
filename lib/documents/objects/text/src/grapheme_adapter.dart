// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:characters/characters.dart';

/// Returns Unicode-scalar offsets at every extended grapheme boundary.
List<int> graphemeScalarBoundaries(String source, int maximumScalars) {
  if (maximumScalars < 0) throw ArgumentError.value(maximumScalars);
  final result = <int>[0];
  var offset = 0;
  for (final cluster in source.characters) {
    var clusterScalars = 0;
    for (final _ in cluster.runes) {
      clusterScalars += 1;
      if (offset + clusterScalars > maximumScalars) {
        throw StateError('Text scalar limit exceeded.');
      }
    }
    offset += clusterScalars;
    result.add(offset);
  }
  return List<int>.unmodifiable(result);
}
