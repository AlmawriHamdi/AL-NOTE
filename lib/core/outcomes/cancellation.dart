// SPDX-License-Identifier: GPL-3.0-or-later

/// A callback invoked synchronously when cancellation is first requested.
typedef CancellationListener = void Function(String? reason);

/// An observable, read-only cancellation signal.
abstract interface class CancellationToken {
  /// Whether cancellation has been requested.
  bool get isCancelled;

  /// The first cancellation reason, or `null` when absent or not cancelled.
  String? get reason;

  /// Adds a synchronous cancellation [listener].
  ///
  /// A listener added after cancellation is invoked immediately with the
  /// winning reason.
  void addListener(CancellationListener listener);

  /// Removes a previously added cancellation [listener].
  void removeListener(CancellationListener listener);
}

/// Owns and triggers an idempotent [CancellationToken].
final class CancellationController {
  /// Creates a controller whose token is not cancelled.
  CancellationController() : _token = _MutableCancellationToken();

  final _MutableCancellationToken _token;

  /// The read-only cancellation token controlled by this instance.
  CancellationToken get token => _token;

  /// Requests cancellation and returns whether this call won.
  ///
  /// Only the first call changes the token or notifies listeners. Its [reason]
  /// remains observable for the token's lifetime.
  bool cancel([String? reason]) => _token.cancel(reason);
}

final class _MutableCancellationToken implements CancellationToken {
  final List<CancellationListener> _listeners = <CancellationListener>[];
  bool _isCancelled = false;
  String? _reason;

  @override
  bool get isCancelled => _isCancelled;

  @override
  String? get reason => _reason;

  @override
  void addListener(CancellationListener listener) {
    if (_isCancelled) {
      listener(_reason);
      return;
    }
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  bool cancel(String? reason) {
    if (_isCancelled) {
      return false;
    }
    _isCancelled = true;
    _reason = reason;
    final listeners = List<CancellationListener>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener(reason);
    }
    return true;
  }

  @override
  void removeListener(CancellationListener listener) {
    _listeners.remove(listener);
  }
}
