// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../../core/outcomes/cancellation.dart';
import '../pdf_file_selection.dart';

LocalPdfPickerHost createHost() => _DesktopPicker();

final class _DesktopPicker implements LocalPdfPickerHost {
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async {
    // These audited desktop plugins return paths, without reading/copying PDF
    // content. Never invoke the Android picker (it preloads and copies to disk).
    if (!Platform.isLinux && !Platform.isWindows) {
      throw const LocalPdfRouteUnavailableException();
    }
    if (cancellationToken.isCancelled) return null;
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Development PDF fixture', extensions: ['pdf']),
      ],
    );
    if (file == null || cancellationToken.isCancelled) return null;
    return _DesktopFile(file.path);
  }
}

final class _DesktopFile implements LocalPdfFileHandle {
  const _DesktopFile(this.path);
  final String path;
  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) async* {
    if (cancellationToken.isCancelled) return;
    final file = await File(path).open();
    try {
      var total = 0;
      while (!cancellationToken.isCancelled) {
        final remainingWithProbe = maximumEncodedBytes - total + 1;
        final count = remainingWithProbe < localPdfReadChunkBytes
            ? remainingWithProbe
            : localPdfReadChunkBytes;
        if (count <= 0) throw const LocalPdfReadLimitException();
        final bytes = await file.read(count);
        if (cancellationToken.isCancelled) return;
        if (bytes.length > maximumEncodedBytes - total) {
          throw const LocalPdfReadLimitException();
        }
        if (bytes.isEmpty) return;
        total += bytes.length;
        yield bytes;
      }
    } finally {
      await file.close();
    }
  }
}
