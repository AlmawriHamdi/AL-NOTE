// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../../core/outcomes/cancellation.dart';
import '../pdf_file_selection.dart';

/// App-owned channel, deliberately separate from the eager file-selector plugin.
LocalPdfPickerHost createAndroidPdfPickerHost() => _AndroidPicker();

const _channel = MethodChannel('alnote/pdf_fixture_reader');
const _maximumNativeBytes = 50000000;

final class _AndroidPicker implements LocalPdfPickerHost {
  _AndroidFile? _active;
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async {
    if (_active != null) throw const LocalPdfRouteUnavailableException();
    if (cancellationToken.isCancelled) return null;
    final random = Random.secure();
    final hex = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final owner =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final file = _AndroidFile(owner, cancellationToken, () => _active = null);
    _active = file;
    cancellationToken.addListener(file.cancel);
    try {
      final session = await _channel.invokeMethod<Object?>('select', {
        'owner': owner,
      });
      if (cancellationToken.isCancelled || session == null) {
        await file.close();
        return null;
      }
      if (session is! String ||
          !RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
              .hasMatch(session)) {
        throw const LocalPdfRouteUnavailableException();
      }
      file.session = session;
      return file;
    } on Object {
      await file.close();
      if (cancellationToken.isCancelled) return null;
      throw const LocalPdfRouteUnavailableException();
    }
  }
}

final class _AndroidFile implements LocalPdfFileHandle {
  _AndroidFile(this.owner, this.selectionToken, this.release);
  final String owner;
  final CancellationToken selectionToken;
  final void Function() release;
  String? session;
  bool _started = false;
  Future<void>? _closing;

  void cancel(String? _) {
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    selectionToken.removeListener(cancel);
    try {
      await _channel.invokeMethod<void>('close', {'owner': owner});
    } on Object {
      /* Already EOF/stale/disposed. Never expose platform details. */
    } finally {
      release();
    }
  }

  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) async* {
    if (_started || _closing != null || session == null)
      throw const LocalPdfRouteUnavailableException();
    _started = true;
    cancellationToken.addListener(cancel);
    try {
      if (maximumEncodedBytes <= 0 || maximumEncodedBytes > _maximumNativeBytes)
        throw const LocalPdfReadLimitException();
      var total = 0;
      var sequence = 0;
      while (!cancellationToken.isCancelled &&
          !selectionToken.isCancelled &&
          _closing == null) {
        Object? value;
        try {
          value = await _channel.invokeMethod<Object?>('read', {
            'owner': owner,
            'session': session,
            'budget': maximumEncodedBytes,
            'sequence': sequence++,
          });
        } on PlatformException catch (error) {
          if (error.code == 'limit') throw const LocalPdfReadLimitException();
          if (cancellationToken.isCancelled || selectionToken.isCancelled)
            return;
          throw const LocalPdfRouteUnavailableException();
        }
        if (cancellationToken.isCancelled ||
            selectionToken.isCancelled ||
            _closing != null)
          return;
        if (value is! Uint8List)
          throw const LocalPdfRouteUnavailableException();
        if (value.length > localPdfReadChunkBytes ||
            value.length > maximumEncodedBytes - total)
          throw const LocalPdfReadLimitException();
        if (value.isEmpty) return;
        total += value.length;
        yield value;
      }
    } finally {
      cancellationToken.removeListener(cancel);
      await close();
    }
  }
}
