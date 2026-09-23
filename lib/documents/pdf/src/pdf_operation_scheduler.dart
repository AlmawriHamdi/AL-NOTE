// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import '../../../core/outcomes/cancellation.dart';

/// One active operation and one latest render interest. Ownership ends only
/// when the caller releases after all backend cleanup has completed.
final class PdfOperationScheduler {
  bool acquireInspection() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  bool _busy = false;
  _PendingRender? _pendingRender;

  // Availability and registration are synchronous. Completion reserves the
  // operation for the latest waiter before waking it, so a new caller cannot
  // steal the slot between notification and resumption. Waiting owns no source
  // capture or parser work. Supersession/cancellation removes its listener.
  Future<bool> acquireRender(CancellationToken token) {
    if (token.isCancelled) return Future.value(false);
    if (!_busy) {
      _busy = true;
      return Future.value(true);
    }
    _pendingRender?.finish(false);
    final pending = _PendingRender(token);
    _pendingRender = pending;
    pending.listen(() {
      if (identical(_pendingRender, pending)) _pendingRender = null;
      pending.finish(false);
    });
    return pending.ready.future;
  }

  void release() {
    final pending = _pendingRender;
    _pendingRender = null;
    _busy = pending != null;
    pending?.finish(true);
  }
}

final class _PendingRender {
  _PendingRender(this.token);
  final CancellationToken token;
  final ready = Completer<bool>();
  CancellationListener? _listener;

  void listen(void Function() cancel) {
    final listener = (String? _) => cancel();
    _listener = listener;
    token.addListener(listener);
  }

  void finish(bool acquired) {
    if (ready.isCompleted) return;
    final listener = _listener;
    _listener = null;
    if (listener != null) token.removeListener(listener);
    ready.complete(acquired);
  }
}
