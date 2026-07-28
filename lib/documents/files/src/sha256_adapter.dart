// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:crypto/crypto.dart' as crypto;

/// Private replaceable SHA-256 package adapter.
List<int> calculateSha256(Iterable<int> source) =>
    List<int>.unmodifiable(crypto.sha256.convert(List<int>.of(source)).bytes);
