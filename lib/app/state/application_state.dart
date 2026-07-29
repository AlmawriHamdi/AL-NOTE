// SPDX-License-Identifier: GPL-3.0-or-later

part of '../../documents/sessions.dart';

/// Immutable application-level Session and View ownership snapshot.
final class ApplicationStateSnapshot {
  ApplicationStateSnapshot._({
    required Map<SessionId, SessionSnapshot> sessions,
    required Map<ViewId, SessionId> viewSessions,
    required this.focusedView,
  }) : sessions = UnmodifiableMapView(Map.of(sessions)),
       viewSessions = UnmodifiableMapView(Map.of(viewSessions));
  final Map<SessionId, SessionSnapshot> sessions;
  final Map<ViewId, SessionId> viewSessions;
  final ViewId? focusedView;
}

/// Receives one complete accepted Application State snapshot.
typedef ApplicationStateListener =
    void Function(ApplicationStateSnapshot snapshot);

/// Receives one accepted platform lifecycle event.
typedef ApplicationLifecycleListener =
    void Function(PlatformLifecycleEvent event);

/// Instance-owned logical Session and view registry.
final class ApplicationState {
  ApplicationState._(
    this.sourceRegistry,
    this._sourceAccess,
    this.maximumListeners,
    this.maximumLifecycleListeners,
  );

  /// Creates the sole Application coordinator for one source registry.
  static Result<ApplicationState, StructuredFailure> create({
    required CanonicalSourceRegistry sourceRegistry,
    required int maximumListeners,
    required int maximumLifecycleListeners,
  }) => sourceRegistry._createApplicationState(
    maximumListeners: maximumListeners,
    maximumLifecycleListeners: maximumLifecycleListeners,
  );

  /// Shared cross-Session canonical source coordinator.
  final CanonicalSourceRegistry sourceRegistry;
  final _CanonicalSourceApplicationAccess _sourceAccess;
  final int maximumListeners;
  final int maximumLifecycleListeners;
  final Map<SessionId, DocumentSession> _sessions = {};
  final Map<ViewId, SessionId> _views = {};
  final Map<SessionId, SessionListener> _sessionListeners = {};
  final Set<SessionId> _controlledSessionMutations = {};
  final List<ApplicationStateListener> _listeners = [];
  final List<ApplicationLifecycleListener> _lifecycleListeners = [];
  ViewId? _focusedView;
  ApplicationStateSnapshot get snapshot => ApplicationStateSnapshot._(
    sessions: {
      for (final entry in _sessions.entries) entry.key: entry.value.snapshot,
    },
    viewSessions: _views,
    focusedView: _focusedView,
  );

  /// Adds one snapshot listener. Notification uses a listener snapshot;
  /// mutation affects later notifications, reentrancy is allowed, and listener
  /// exceptions are isolated.
  Result<void, StructuredFailure> addListener(
    ApplicationStateListener listener,
  ) {
    if (_listeners.contains(listener)) return const Ok(null);
    if (_listeners.length >= maximumListeners) {
      return Err(_applicationFailure('listener_limit'));
    }
    _listeners.add(listener);
    return const Ok(null);
  }

  void removeListener(ApplicationStateListener listener) =>
      _listeners.remove(listener);
  Result<void, StructuredFailure> addLifecycleListener(
    ApplicationLifecycleListener listener,
  ) {
    if (_lifecycleListeners.contains(listener)) return const Ok(null);
    if (_lifecycleListeners.length >= maximumLifecycleListeners) {
      return Err(_applicationFailure('lifecycle_listener_limit'));
    }
    _lifecycleListeners.add(listener);
    return const Ok(null);
  }

  void removeLifecycleListener(ApplicationLifecycleListener listener) =>
      _lifecycleListeners.remove(listener);

  Result<DocumentSession, StructuredFailure> registerSession(
    DocumentSession session, {
    required int maximumSessions,
  }) {
    if (!_webSafeNonnegative(maximumSessions)) {
      return Err(_applicationFailure('invalid_session_limit'));
    }
    if (!identical(session.sourceRegistry, sourceRegistry)) {
      return Err(_applicationFailure('source_registry_mismatch'));
    }
    final binding = session.snapshot.sourceBinding;
    if (session.isCanonicalSourceOwner && binding != null) {
      final existing = sourceRegistry.ownerOf(binding.sourceIdentity);
      if (existing != null) {
        final existingSession = _sessions[existing];
        if (existing != session.id && existingSession == null) {
          return Err(_applicationFailure('source_map_inconsistent'));
        }
        if (existing != session.id) return Ok(existingSession!);
      }
    }
    if (_sessions.containsKey(session.id)) {
      return Err(_applicationFailure('duplicate_session'));
    }
    final begun = sourceRegistry._beginRegistration(_sourceAccess, session);
    if (begun is Err<SessionRegistrationAttempt, StructuredFailure>) {
      return Err(_applicationFailure('registration_rejected'));
    }
    final attempt =
        (begun as Ok<SessionRegistrationAttempt, StructuredFailure>).value;
    if (_sessions.length >= maximumSessions) {
      sourceRegistry._completeRegistration(
        _sourceAccess,
        session,
        attempt,
        accepted: false,
      );
      return Err(_applicationFailure('session_limit'));
    }
    void listener(SessionSnapshot snapshot) {
      if (_controlledSessionMutations.contains(snapshot.id)) return;
      final currentBinding = snapshot.sourceBinding;
      if (session.isCanonicalSourceOwner &&
          currentBinding != null &&
          sourceRegistry.ownerOf(currentBinding.sourceIdentity) !=
              snapshot.id) {
        return;
      }
      _notify();
    }

    final observed = session.addListener(listener);
    if (observed is Err<void, StructuredFailure>) {
      sourceRegistry._completeRegistration(
        _sourceAccess,
        session,
        attempt,
        accepted: false,
      );
      return Err(_applicationFailure('session_listener_limit'));
    }
    _sessions[session.id] = session;
    _sessionListeners[session.id] = listener;
    final completed = sourceRegistry._completeRegistration(
      _sourceAccess,
      session,
      attempt,
      accepted: true,
    );
    if (completed is Err<void, StructuredFailure>) {
      session.removeListener(listener);
      _sessionListeners.remove(session.id);
      _sessions.remove(session.id);
      return Err(_applicationFailure('registration_rejected'));
    }
    _notify();
    return Ok(session);
  }

  Result<void, StructuredFailure> attachView({
    required ViewId view,
    required SessionId session,
    required int maximumViewsPerSession,
  }) {
    if (_views.containsKey(view)) {
      return Err(_applicationFailure('duplicate_view'));
    }
    final target = _sessions[session];
    if (target == null) return Err(_applicationFailure('unknown_session'));
    _controlledSessionMutations.add(session);
    final attached = target.attachView(
      view,
      maximumViews: maximumViewsPerSession,
    );
    _controlledSessionMutations.remove(session);
    if (attached is Err<void, StructuredFailure>) return attached;
    _views[view] = session;
    _notify();
    return const Ok(null);
  }

  Result<void, StructuredFailure> focus(ViewId? view) {
    if (view != null && !_views.containsKey(view))
      return Err(_applicationFailure('unknown_view'));
    _focusedView = view;
    _notify();
    return const Ok(null);
  }

  Result<void, StructuredFailure> detachView(ViewId view) {
    final sessionId = _views[view];
    if (sessionId == null) return Err(_applicationFailure('unknown_view'));
    final session = _sessions[sessionId];
    if (session == null) return Err(_applicationFailure('unknown_session'));
    _controlledSessionMutations.add(sessionId);
    final detached = session.detachView(view);
    _controlledSessionMutations.remove(sessionId);
    if (detached is Err<void, StructuredFailure>) return detached;
    _views.remove(view);
    if (_focusedView == view) _focusedView = null;
    _notify();
    return const Ok(null);
  }

  Result<void, StructuredFailure> removeClosedSession(SessionId id) {
    final session = _sessions[id];
    if (session == null) return Err(_applicationFailure('unknown_session'));
    final state = session.snapshot;
    if (state.lifecycle != SessionLifecycle.closed) {
      return Err(_applicationFailure('session_not_closed'));
    }
    if (state.isDirty && session.closeResolution != CloseResolution.discard) {
      return Err(_applicationFailure('dirty_session'));
    }
    if (state.views.isNotEmpty) {
      return Err(_applicationFailure('views_attached'));
    }
    _sessions.remove(id);
    final listener = _sessionListeners.remove(id);
    if (listener != null) session.removeListener(listener);
    _notify();
    return const Ok(null);
  }

  /// Returns the live coordinator object through a controlled lookup.
  DocumentSession? session(SessionId id) => _sessions[id];

  /// Looks up an already-open canonical Session before constructing another.
  DocumentSession? sessionForSource(NormalizedSourceIdentity source) {
    final owner = sourceRegistry.ownerOf(source);
    return owner == null ? null : _sessions[owner];
  }

  void distributeLifecycle(PlatformLifecycleEvent event) {
    for (final listener in List<ApplicationLifecycleListener>.of(
      _lifecycleListeners,
    )) {
      try {
        listener(event);
      } on Object {
        /* isolated */
      }
    }
  }

  void _notify() {
    final current = snapshot;
    for (final listener in List<ApplicationStateListener>.of(_listeners)) {
      try {
        listener(current);
      } on Object {
        /* isolated */
      }
    }
  }
}

StructuredFailure _applicationFailure(String leaf) => StructuredFailure(
  code: 'app.state.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The Application State operation was rejected.',
);
