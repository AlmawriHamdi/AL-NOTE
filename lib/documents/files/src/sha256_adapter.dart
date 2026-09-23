// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:crypto/crypto.dart' as crypto;

/// Private replaceable SHA-256 package adapter.
List<int> calculateSha256(Iterable<int> source) =>
    List<int>.unmodifiable(crypto.sha256.convert(List<int>.of(source)).bytes);

/// Synchronous hashing of already captured, caller-owned bytes. The caller must
/// keep them stable for this call. Avoids a second full executable-resource copy
/// while retaining the existing single private dependency boundary.
List<int> calculateCapturedSha256(List<int> capturedBytes) =>
    List<int>.unmodifiable(crypto.sha256.convert(capturedBytes).bytes);

/// Bounded incremental hashing for cancellable background resource preparation.
/// The private captured buffer stays stable until the returned digest completes.
Future<List<int>> calculateCapturedSha256Cooperatively(
  List<int> bytes,
  void Function() checkCancellation,
) async {
  final output = _DigestSink();
  final input = crypto.sha256.startChunkedConversion(output);
  for (var offset = 0; offset < bytes.length; offset += 65536) {
    checkCancellation();
    final end = offset + 65536 < bytes.length ? offset + 65536 : bytes.length;
    input.add(bytes.sublist(offset, end));
    await Future<void>.delayed(Duration.zero);
  }
  checkCancellation();
  input.close();
  return output.value!.bytes;
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
