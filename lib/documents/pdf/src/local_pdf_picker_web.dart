// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../../../core/outcomes/cancellation.dart';
import '../pdf_file_selection.dart';

// Minimal standard browser APIs; no package, XFile/URL hydration, or whole-file
// FileReader. Browser-owned File/Blob storage stays distinct from byte buffers.
@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external _Input createElement(String tag);
  external _Body get body;
}

extension type _Body(JSObject _) implements JSObject {
  external void appendChild(_Input input);
}

extension type _Input(JSObject _) implements JSObject {
  external set type(String value);
  external set accept(String value);
  external set multiple(bool value);
  external set hidden(bool value);
  external _Files? get files;
  external void click();
  external void remove();
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _Files(JSObject _) implements JSObject {
  external int get length;
  external _Blob? item(int index);
}

extension type _Blob(JSObject _) implements JSObject {
  external int get size;
  external _Blob slice(int start, int end);
}

@JS('FileReader')
extension type _Reader._(JSObject _) implements JSObject {
  external factory _Reader();
  external JSArrayBuffer? get result;
  external int get readyState;
  external void readAsArrayBuffer(_Blob blob);
  external void abort();
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

LocalPdfPickerHost createHost() => _WebPicker();

final class _WebPicker implements LocalPdfPickerHost {
  @override
  Future<LocalPdfFileHandle?> selectOnePdf({
    required CancellationToken cancellationToken,
  }) async {
    if (cancellationToken.isCancelled) return null;
    final input = _document.createElement('input')
      ..type = 'file'
      ..accept = '.pdf,application/pdf'
      ..multiple = false
      ..hidden = true;
    final done = Completer<LocalPdfFileHandle?>();
    void cancel(String? _) {
      if (!done.isCompleted) done.complete(null);
    }

    final change = ((JSAny? _) {
      if (done.isCompleted) return;
      final files = input.files;
      done.complete(
        files != null && files.length == 1 ? _WebFile(files.item(0)!) : null,
      );
    }).toJS;
    final cancelled = ((JSAny? _) => cancel(null)).toJS;
    final failed = ((JSAny? _) {
      if (!done.isCompleted)
        done.completeError(StateError('File selection unavailable'));
    }).toJS;
    try {
      input.addEventListener('change', change);
      input.addEventListener('cancel', cancelled);
      input.addEventListener('error', failed);
      cancellationToken.addListener(cancel);
      _document.body.appendChild(input);
      if (!cancellationToken.isCancelled) input.click();
      return await done.future;
    } finally {
      cancellationToken.removeListener(cancel);
      input.removeEventListener('change', change);
      input.removeEventListener('cancel', cancelled);
      input.removeEventListener('error', failed);
      input.remove();
    }
  }
}

final class _WebFile implements LocalPdfFileHandle {
  const _WebFile(this.blob);
  final _Blob blob;

  @override
  Stream<List<int>> openRead({
    required int maximumEncodedBytes,
    required CancellationToken cancellationToken,
  }) async* {
    if (cancellationToken.isCancelled) return;
    // Metadata can only reject early, never grant admission or stop actual byte
    // counting. A falsely small size cannot hide data from the slice loop.
    if (blob.size > maximumEncodedBytes)
      throw const LocalPdfReadLimitException();
    var offset = 0;
    while (!cancellationToken.isCancelled) {
      final remainingWithProbe = maximumEncodedBytes - offset + 1;
      final count = remainingWithProbe < localPdfReadChunkBytes
          ? remainingWithProbe
          : localPdfReadChunkBytes;
      if (count <= 0) throw const LocalPdfReadLimitException();
      final slice = blob.slice(offset, offset + count);
      final bytes = await _readSlice(slice, cancellationToken);
      if (cancellationToken.isCancelled) return;
      if (bytes.length > count || bytes.length > maximumEncodedBytes - offset) {
        throw const LocalPdfReadLimitException();
      }
      if (bytes.isEmpty) return;
      offset += bytes.length;
      yield bytes;
    }
  }

  Future<Uint8List> _readSlice(_Blob slice, CancellationToken token) async {
    final reader = _Reader();
    final done = Completer<Uint8List>();
    final loaded = ((JSAny? _) {
      if (!done.isCompleted) {
        final result = reader.result;
        if (result == null) {
          done.completeError(StateError('File read unavailable'));
        } else {
          done.complete(result.toDart.asUint8List());
        }
      }
    }).toJS;
    final failed = ((JSAny? _) {
      if (!done.isCompleted)
        done.completeError(StateError('File read unavailable'));
    }).toJS;
    void cancel(String? _) {
      if (!done.isCompleted) done.complete(Uint8List(0));
      if (reader.readyState == 1) reader.abort();
    }

    try {
      reader.addEventListener('load', loaded);
      reader.addEventListener('error', failed);
      reader.addEventListener('abort', failed);
      token.addListener(cancel);
      if (!token.isCancelled) reader.readAsArrayBuffer(slice);
      return await done.future;
    } finally {
      token.removeListener(cancel);
      reader.removeEventListener('load', loaded);
      reader.removeEventListener('error', failed);
      reader.removeEventListener('abort', failed);
      if (reader.readyState == 1) reader.abort();
    }
  }
}
