// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import '../../core/outcomes/cancellation.dart';
import '../model/preserved_data.dart';

/// Maximum content chunk, including platform-to-Dart transfer, per operation.
const localPdfReadChunkBytes = 64 * 1024;

/// Handle with no public path, URI, name, MIME declaration, or package type.
abstract interface class LocalPdfFileHandle {
  /// Content reads enforce the budget before allocation. At most one bounded
  /// chunk may be in flight. A one-byte probe distinguishes exact EOF/overflow.
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  });
}

abstract interface class LocalPdfPickerHost {
  /// Selects exactly one candidate, or null on cancellation. Unsafe platforms
  /// must reject before invoking a picker that reads/copies content eagerly.
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  });
}

enum LocalPdfSelectionFailureReason { unavailable, resourceLimit }

final class LocalPdfReadLimitException implements Exception {
  const LocalPdfReadLimitException();
  @override
  String toString() => 'LocalPdfReadLimitException';
}

final class LocalPdfRouteUnavailableException implements Exception {
  const LocalPdfRouteUnavailableException();
  @override
  String toString() => 'LocalPdfRouteUnavailableException';
}

sealed class LocalPdfSelectionOutcome {
  const LocalPdfSelectionOutcome();
  @override
  String toString() => runtimeType.toString();
}

final class LocalPdfSelectionCancelled extends LocalPdfSelectionOutcome {
  const LocalPdfSelectionCancelled();
}

final class LocalPdfSelectionSuccess extends LocalPdfSelectionOutcome {
  LocalPdfSelectionSuccess._(Uint8List bytes)
    : bytes = bytes.asUnmodifiableView();

  /// Immutable packed bytes. No mutable backing is exposed to a caller.
  final List<int> bytes;
  @override
  String toString() => 'LocalPdfSelectionSuccess(redacted)';
}

final class LocalPdfSelectionFailure extends LocalPdfSelectionOutcome {
  const LocalPdfSelectionFailure(this.reason);
  final LocalPdfSelectionFailureReason reason;
  @override
  String toString() => 'LocalPdfSelectionFailure(${reason.name})';
}

/// Single-flight, bounded capture. Caller-owned output can outlive this object;
/// the selector does not retain old results. Admission happens separately.
final class LocalPdfFileSelector {
  LocalPdfFileSelector({required LocalPdfPickerHost host}) : _host = host;
  final LocalPdfPickerHost _host;
  bool _busy = false;

  Future<LocalPdfSelectionOutcome> select({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) async {
    if (_busy)
      return const LocalPdfSelectionFailure(
        LocalPdfSelectionFailureReason.unavailable,
      );
    _busy = true;
    try {
      return await _select(maximumEncodedBytes, cancellationToken);
    } finally {
      _busy = false;
    }
  }

  Future<LocalPdfSelectionOutcome> _select(
    int maximumEncodedBytes,
    CancellationToken cancellationToken,
  ) async {
    if (cancellationToken.isCancelled)
      return const LocalPdfSelectionCancelled();
    if (maximumEncodedBytes <= 0 ||
        maximumEncodedBytes > maximumWebSafeInteger) {
      return const LocalPdfSelectionFailure(
        LocalPdfSelectionFailureReason.resourceLimit,
      );
    }
    StreamIterator<List<int>>? iterator;
    void cancelRead(String? _) {
      final active = iterator;
      if (active != null) unawaited(active.cancel().catchError((Object _) {}));
    }

    try {
      final handle = await _host.selectOnePdf(
        cancellationToken: cancellationToken,
      );
      if (cancellationToken.isCancelled || handle == null) {
        return const LocalPdfSelectionCancelled();
      }
      final stream = handle.openRead(
        maximumEncodedBytes: maximumEncodedBytes,
        cancellationToken: cancellationToken,
      );
      final active = StreamIterator<List<int>>(stream);
      iterator = active;
      cancellationToken.addListener(cancelRead);
      final captured = _PackedCapture(maximumEncodedBytes);
      while (await active.moveNext()) {
        if (cancellationToken.isCancelled)
          return const LocalPdfSelectionCancelled();
        final chunk = active.current;
        final chunkLength = chunk.length;
        if (chunkLength < 0 ||
            chunkLength > maximumEncodedBytes - captured.length ||
            chunkLength > localPdfReadChunkBytes) {
          return const LocalPdfSelectionFailure(
            LocalPdfSelectionFailureReason.resourceLimit,
          );
        }
        // Empty deliveries consume no retained chunk objects.
        if (chunkLength == 0) continue;
        final owned = Uint8List(chunkLength);
        for (var index = 0; index < chunkLength; index++) {
          final value = chunk[index];
          if (value < 0 || value > 255) {
            return const LocalPdfSelectionFailure(
              LocalPdfSelectionFailureReason.unavailable,
            );
          }
          owned[index] = value;
        }
        captured.add(owned);
      }
      if (cancellationToken.isCancelled)
        return const LocalPdfSelectionCancelled();
      if (captured.isEmpty) {
        return const LocalPdfSelectionFailure(
          LocalPdfSelectionFailureReason.unavailable,
        );
      }
      return LocalPdfSelectionSuccess._(captured.takeBytes());
    } on LocalPdfReadLimitException {
      return cancellationToken.isCancelled
          ? const LocalPdfSelectionCancelled()
          : const LocalPdfSelectionFailure(
              LocalPdfSelectionFailureReason.resourceLimit,
            );
    } on Object {
      return cancellationToken.isCancelled
          ? const LocalPdfSelectionCancelled()
          : const LocalPdfSelectionFailure(
              LocalPdfSelectionFailureReason.unavailable,
            );
    } finally {
      cancellationToken.removeListener(cancelRead);
      try {
        await iterator?.cancel();
      } on Object {
        // Cleanup must not expose host exceptions or replace fixed outcomes.
      }
    }
  }
}

// Coalesce short host deliveries into fixed blocks so even a one-byte stream
// retains at most ceil(B / C) block objects, rather than B chunk objects.
final class _PackedCapture {
  _PackedCapture(this.limit);
  final int limit;
  final BytesBuilder _blocks = BytesBuilder(copy: false);
  Uint8List? _block;
  int _used = 0;
  int length = 0;
  bool get isEmpty => length == 0;

  void add(Uint8List bytes) {
    for (final byte in bytes) {
      if (_block == null) {
        final remaining = limit - length;
        _block = Uint8List(
          remaining < localPdfReadChunkBytes
              ? remaining
              : localPdfReadChunkBytes,
        );
        _used = 0;
      }
      _block![_used++] = byte;
      length++;
      if (_used == _block!.length) {
        _blocks.add(_block!);
        _block = null;
      }
    }
  }

  Uint8List takeBytes() {
    final block = _block;
    if (block != null && _used > 0) {
      _blocks.add(Uint8List.sublistView(block, 0, _used));
    }
    _block = null;
    return _blocks.takeBytes();
  }
}
