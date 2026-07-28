// SPDX-License-Identifier: GPL-3.0-or-later

part of '../sessions.dart';

/// Receives a complete immutable Session snapshot after publication.
typedef SessionListener = void Function(SessionSnapshot snapshot);

/// Coordinates one logical document without replacing Commands or Storage.
final class DocumentSession {
  DocumentSession._({
    required this.id,
    required this.coordinator,
    required this.publisher,
    required this.uuidGenerator,
    required this.clock,
    required this.sourceRegistry,
    required _CanonicalSourceAccess sourceAccess,
    required StorageSourceBinding? sourceBinding,
    required SessionAccess access,
    required SessionFidelity fidelity,
    required bool canonicalSourceOwner,
  }) : _sourceAccess = sourceAccess,
       _sourceBinding = sourceBinding,
       _access = access,
       _fidelity = fidelity,
       _canonicalSourceOwner = canonicalSourceOwner,
       _revision = _zeroRevision();

  /// Creates a Session and atomically claims any canonical initial source.
  static Result<DocumentSession, StructuredFailure> create({
    required DocumentMutationCoordinator coordinator,
    required SessionPublisher publisher,
    required UuidGenerator uuidGenerator,
    required Clock clock,
    required CanonicalSourceRegistry sourceRegistry,
    StorageSourceBinding? sourceBinding,
    SessionAccess access = SessionAccess.editable,
    SessionFidelity fidelity = SessionFidelity.complete,
    bool explicitSeparateCopy = false,
  }) {
    final generated = SessionId.generate(uuidGenerator);
    if (generated is Err<SessionId, StructuredFailure>) {
      return Err(_failure('session_identity_generation'));
    }
    final id = (generated as Ok<SessionId, StructuredFailure>).value;
    final opened = sourceRegistry._openSession(id);
    if (opened is Err<_CanonicalSourceAccess, StructuredFailure>)
      return Err(opened.error);
    final sourceAccess =
        (opened as Ok<_CanonicalSourceAccess, StructuredFailure>).value;
    if (sourceBinding != null && !explicitSeparateCopy) {
      final claim = sourceRegistry._claimInitial(
        sourceAccess,
        sourceBinding.sourceIdentity,
      );
      if (claim is Err<void, StructuredFailure>) {
        sourceRegistry._releaseSession(sourceAccess);
        return Err(claim.error);
      }
    }
    final session = DocumentSession._(
      id: id,
      coordinator: coordinator,
      publisher: publisher,
      uuidGenerator: uuidGenerator,
      clock: clock,
      sourceRegistry: sourceRegistry,
      sourceAccess: sourceAccess,
      sourceBinding: sourceBinding,
      access: access,
      fidelity: fidelity,
      canonicalSourceOwner: sourceBinding != null && !explicitSeparateCopy,
    );
    coordinator.addListener((_) {
      session._invalidateCloseEvidence();
      session._notify();
    });
    return Ok(session);
  }

  /// Runtime-only Session identity.
  final SessionId id;

  /// Command-owned document coordinator shared by all views.
  final DocumentMutationCoordinator coordinator;

  /// Narrow canonical publication collaborator.
  final SessionPublisher publisher;

  /// UUID boundary used for operations and decision tokens.
  final UuidGenerator uuidGenerator;

  /// Injected UTC clock used for close freshness.
  final Clock clock;

  /// Cross-Session canonical-source reservation boundary.
  final CanonicalSourceRegistry sourceRegistry;
  final _CanonicalSourceAccess _sourceAccess;

  final Set<ViewId> _views = {};
  final List<SessionListener> _listeners = [];
  final Object _closeAuthority = Object();
  CloseDecisionRequest? _currentCloseDecision;
  CloseAuthorization? _currentCloseAuthorization;
  SessionRegistrationAttempt? _registrationAttempt;
  bool _registeredWithApplication = false;
  SessionLifecycle _lifecycle = SessionLifecycle.open;
  final SessionReadiness _readiness = SessionReadiness.ready;
  final SessionAccess _access;
  final SessionFidelity _fidelity;
  ExternalSourceState _externalSource = ExternalSourceState.unchanged;
  SessionRevision _revision;
  StorageSourceBinding? _sourceBinding;
  bool _canonicalSourceOwner;
  CloseResolution? _closeResolution;
  bool _publicationActive = false;
  int _queuedPublications = 0;
  Future<void> _publicationTail = Future<void>.value();

  /// Current immutable outward-facing Session state.
  SessionSnapshot get snapshot => SessionSnapshot(
    id: id,
    lifecycle: _lifecycle,
    readiness: _readiness,
    access: _access,
    fidelity: _fidelity,
    externalSource: _externalSource,
    revision: _revision,
    document: coordinator.snapshot,
    sourceBinding: _sourceBinding,
    views: _views,
  );

  /// Whether canonical publication is currently executing.
  bool get publicationActive => _publicationActive;

  /// Whether this Session currently owns its binding canonically.
  bool get isCanonicalSourceOwner => _canonicalSourceOwner;

  /// Resolution that authorized a completed close, when closed.
  CloseResolution? get closeResolution => _closeResolution;

  /// Adds a listener once.
  ///
  /// Notification snapshots listeners. Additions/removals affect later events,
  /// reentrancy is allowed, and listener exceptions are isolated.
  void addListener(SessionListener listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  /// Removes a listener from later notifications.
  void removeListener(SessionListener listener) => _listeners.remove(listener);

  /// Attaches one view after preflighting limits and Session revision.
  Result<void, StructuredFailure> attachView(
    ViewId view, {
    required int maximumViews,
  }) {
    if (_lifecycle != SessionLifecycle.open) return Err(_failure('not_open'));
    if (_views.contains(view)) return const Ok(null);
    if (maximumViews < 0 || _views.length >= maximumViews) {
      return Err(_failure('view_limit'));
    }
    return _mutate(() => _views.add(view));
  }

  /// Detaches one known view atomically.
  Result<void, StructuredFailure> detachView(ViewId view) {
    if (!_views.contains(view)) return Err(_failure('unknown_view'));
    return _mutate(() => _views.remove(view));
  }

  /// Publishes a distinct external-source fact atomically.
  Result<void, StructuredFailure> setExternalSourceState(
    ExternalSourceState state,
  ) {
    if (_externalSource == state) return const Ok(null);
    return _mutate(() => _externalSource = state);
  }

  /// Queues ordinary Save. Missing source binding fails before capture, UUID,
  /// reservation, or publisher invocation.
  Future<SessionSaveResult> save({
    required CancellationToken cancellationToken,
  }) {
    final binding = _sourceBinding;
    if (binding == null || !_canonicalSourceOwner) {
      return Future.value(
        SessionSaveResult(
          disposition: SessionSaveDisposition.failed,
          capturedIdentity: coordinator.snapshot.currentContentIdentity,
          failure: _failure('save_as_required'),
        ),
      );
    }
    return _enqueueSave(
      kind: SessionSaveKind.save,
      destinationIdentity: null,
      cancellationToken: cancellationToken,
    );
  }

  /// Queues Save As with cross-Session destination reservation.
  Future<SessionSaveResult> saveAs({
    required NormalizedSourceIdentity destinationIdentity,
    required CancellationToken cancellationToken,
  }) => _enqueueSave(
    kind: SessionSaveKind.saveAs,
    destinationIdentity: destinationIdentity,
    cancellationToken: cancellationToken,
  );

  Future<SessionSaveResult> _enqueueSave({
    required SessionSaveKind kind,
    required NormalizedSourceIdentity? destinationIdentity,
    required CancellationToken cancellationToken,
  }) {
    final capture = coordinator.captureForSave();
    final completer = Completer<SessionSaveResult>();
    _invalidateCloseEvidence();
    _queuedPublications += 1;
    _publicationTail = _publicationTail
        .then((_) async {
          if (cancellationToken.isCancelled) {
            _completeSave(completer, capture, SessionSaveDisposition.cancelled);
            return;
          }
          final bindingBefore = _sourceBinding;
          if (kind == SessionSaveKind.save &&
              (bindingBefore == null || !_canonicalSourceOwner)) {
            _completeSave(
              completer,
              capture,
              SessionSaveDisposition.failed,
              _failure('save_as_required'),
            );
            return;
          }
          final nextRevision = _revision.increment();
          if (nextRevision is Err<SessionRevision, StructuredFailure>) {
            _completeSave(
              completer,
              capture,
              SessionSaveDisposition.failed,
              nextRevision.error,
            );
            return;
          }
          final operation = SessionOperationId.generate(uuidGenerator);
          if (operation is Err<SessionOperationId, StructuredFailure>) {
            _completeSave(
              completer,
              capture,
              SessionSaveDisposition.failed,
              _failure('operation_identity_generation'),
            );
            return;
          }
          final operationId =
              (operation as Ok<SessionOperationId, StructuredFailure>).value;
          _CanonicalSourceReservation? reservation;
          if (kind == SessionSaveKind.saveAs) {
            final reserved = sourceRegistry._reserve(
              access: _sourceAccess,
              operationId: operationId,
              sourceIdentity: destinationIdentity!,
            );
            if (reserved
                is Err<_CanonicalSourceReservation, StructuredFailure>) {
              _completeSave(
                completer,
                capture,
                SessionSaveDisposition.conflicted,
                reserved.error,
              );
              return;
            }
            reservation =
                (reserved as Ok<_CanonicalSourceReservation, StructuredFailure>)
                    .value;
          }
          _publicationActive = true;
          final request = SessionPublicationRequest(
            sessionId: id,
            operationId: operationId,
            kind: kind,
            capture: capture,
            currentBinding: bindingBefore,
            destinationIdentity: destinationIdentity,
          );
          OperationOutcome<SessionPublicationEvidence, StructuredFailure>
          outcome;
          try {
            outcome = await publisher.publish(
              request,
              cancellationToken: cancellationToken,
            );
          } on Object {
            outcome = Failed(_failure('publisher_failure'));
          } finally {
            _publicationActive = false;
          }
          if (outcome
              is! Completed<SessionPublicationEvidence, StructuredFailure>) {
            if (reservation != null)
              sourceRegistry._release(_sourceAccess, reservation);
            _acknowledgeFailure(capture);
            if (outcome
                is Cancelled<SessionPublicationEvidence, StructuredFailure>) {
              _completeSave(
                completer,
                capture,
                SessionSaveDisposition.cancelled,
              );
            } else {
              final failure =
                  (outcome
                          as Failed<
                            SessionPublicationEvidence,
                            StructuredFailure
                          >)
                      .failure;
              _completeSave(
                completer,
                capture,
                failure.code.contains('conflict')
                    ? SessionSaveDisposition.conflicted
                    : SessionSaveDisposition.failed,
                _failure('publication_failed'),
              );
            }
            return;
          }
          final evidence = outcome.value;
          final identityMatches = kind == SessionSaveKind.save
              ? evidence.sourceIdentity == bindingBefore!.sourceIdentity
              : evidence.sourceIdentity == destinationIdentity;
          if (!evidence.fresh || !identityMatches) {
            if (reservation != null)
              sourceRegistry._release(_sourceAccess, reservation);
            _acknowledgeFailure(capture);
            _completeSave(
              completer,
              capture,
              SessionSaveDisposition.stale,
              _failure('stale_publication'),
            );
            return;
          }
          if (reservation != null) {
            final committed = sourceRegistry._commit(
              _sourceAccess,
              reservation,
              previousSource: _canonicalSourceOwner
                  ? bindingBefore?.sourceIdentity
                  : null,
            );
            if (committed is Err<void, StructuredFailure>) {
              sourceRegistry._release(_sourceAccess, reservation);
              _acknowledgeFailure(capture);
              _completeSave(
                completer,
                capture,
                SessionSaveDisposition.conflicted,
                committed.error,
              );
              return;
            }
          }
          final acknowledged = coordinator.acknowledgeSave(capture);
          if (acknowledged is Err<void, CommandFailure>) {
            _completeSave(
              completer,
              capture,
              SessionSaveDisposition.failed,
              _failure('save_acknowledgement_failed'),
            );
            return;
          }
          _sourceBinding = StorageSourceBinding(
            sourceIdentity: evidence.sourceIdentity,
            fingerprint: evidence.fingerprint,
          );
          _canonicalSourceOwner = true;
          _externalSource = ExternalSourceState.unchanged;
          _revision =
              (nextRevision as Ok<SessionRevision, StructuredFailure>).value;
          _invalidateCloseEvidence();
          _notify();
          _completeSave(completer, capture, SessionSaveDisposition.published);
        })
        .catchError((Object _) {
          if (!completer.isCompleted) {
            _completeSave(
              completer,
              capture,
              SessionSaveDisposition.failed,
              _failure('queue_failure'),
            );
          }
        });
    return completer.future;
  }

  /// Issues and records one exact close-decision request.
  Result<CloseDecisionRequest, StructuredFailure> requestCloseDecision({
    required Duration validity,
  }) {
    if (validity <= Duration.zero ||
        _lifecycle != SessionLifecycle.open ||
        _publicationActive ||
        _queuedPublications > 0) {
      return Err(_failure('invalid_close_request'));
    }
    final expiry = _closeExpiry(validity);
    if (expiry is Err<DateTime, StructuredFailure>) return Err(expiry.error);
    final token = CloseDecisionToken.generate(uuidGenerator);
    if (token is Err<CloseDecisionToken, StructuredFailure>) {
      return Err(_failure('token_generation'));
    }
    final state = snapshot;
    final permitted = state.isDirty
        ? (_access == SessionAccess.readOnly
              ? {
                  CloseResolution.saveAs,
                  CloseResolution.discard,
                  CloseResolution.cancel,
                }
              : {
                  CloseResolution.save,
                  CloseResolution.saveAs,
                  CloseResolution.discard,
                  CloseResolution.cancel,
                })
        : {CloseResolution.discard, CloseResolution.cancel};
    final request = CloseDecisionRequest._issue(
      sessionId: id,
      sessionRevision: state.revision,
      contentIdentity: state.document.currentContentIdentity,
      dirty: state.isDirty,
      access: state.access,
      fidelity: state.fidelity,
      externalSource: state.externalSource,
      permittedResolutions: permitted,
      token: (token as Ok<CloseDecisionToken, StructuredFailure>).value,
      expiresAtUtc: (expiry as Ok<DateTime, StructuredFailure>).value,
      owner: _closeAuthority,
    );
    _currentCloseDecision = request;
    _currentCloseAuthorization = null;
    return Ok(request);
  }

  /// Resolves one issued decision and performs any requested Save first.
  Future<OperationOutcome<CloseAuthorization, StructuredFailure>>
  resolveCloseDecision(
    CloseDecisionRequest request,
    CloseDecision decision, {
    NormalizedSourceIdentity? saveAsDestination,
    required CancellationToken cancellationToken,
  }) async {
    if (!request.isOwnedBy(_closeAuthority) ||
        !identical(_currentCloseDecision, request) ||
        decision.sessionId != id ||
        decision.token != request.token) {
      return Failed(_failure('decision_mismatch'));
    }
    final now = _capturedUtcNow();
    if (now is Err<DateTime, StructuredFailure>) return Failed(now.error);
    if (!(now as Ok<DateTime, StructuredFailure>).value.isBefore(
      request.expiresAtUtc,
    )) {
      _currentCloseDecision = null;
      return Failed(_failure('decision_expired'));
    }
    _currentCloseDecision = null;
    final current = snapshot;
    if (_publicationActive ||
        request.sessionRevision != current.revision ||
        request.contentIdentity != current.document.currentContentIdentity ||
        request.dirty != current.isDirty ||
        request.access != current.access ||
        request.fidelity != current.fidelity ||
        request.externalSource != current.externalSource) {
      return Failed(_failure('decision_stale'));
    }
    if (!request.permittedResolutions.contains(decision.resolution)) {
      return Failed(_failure('decision_unpermitted'));
    }
    if (decision.resolution == CloseResolution.cancel) {
      return const Cancelled('close_cancelled');
    }
    if (decision.resolution == CloseResolution.save ||
        decision.resolution == CloseResolution.saveAs) {
      final result = decision.resolution == CloseResolution.save
          ? await save(cancellationToken: cancellationToken)
          : saveAsDestination == null
          ? SessionSaveResult(
              disposition: SessionSaveDisposition.failed,
              capturedIdentity: coordinator.snapshot.currentContentIdentity,
              failure: _failure('save_as_destination_required'),
            )
          : await saveAs(
              destinationIdentity: saveAsDestination,
              cancellationToken: cancellationToken,
            );
      if (result.disposition == SessionSaveDisposition.cancelled) {
        return const Cancelled('save_cancelled');
      }
      if (result.disposition != SessionSaveDisposition.published) {
        return Failed(result.failure ?? _failure('close_save_failed'));
      }
    }
    final resolved = snapshot;
    if ((decision.resolution == CloseResolution.save ||
            decision.resolution == CloseResolution.saveAs) &&
        resolved.isDirty) {
      return Failed(_failure('close_resolution_stale'));
    }
    if (_publicationActive || _queuedPublications > 0) {
      return Failed(_failure('publication_pending'));
    }
    final authorization = CloseAuthorization._issue(
      sessionId: id,
      resolution: decision.resolution,
      sessionRevision: resolved.revision,
      contentIdentity: resolved.document.currentContentIdentity,
      dirty: resolved.isDirty,
      sourceBinding: resolved.sourceBinding,
      externalSource: resolved.externalSource,
      owner: _closeAuthority,
    );
    _currentCloseAuthorization = authorization;
    return Completed(authorization);
  }

  /// Closes only with exact one-use Session-issued authorization.
  Result<void, StructuredFailure> close(CloseAuthorization authorization) {
    if (!authorization.isOwnedBy(_closeAuthority) ||
        !identical(_currentCloseAuthorization, authorization)) {
      return Err(_failure('invalid_close_authorization'));
    }
    _currentCloseAuthorization = null;
    if (authorization.sessionId != id ||
        authorization.sessionRevision != _revision ||
        authorization.contentIdentity !=
            coordinator.snapshot.currentContentIdentity ||
        authorization.dirty != coordinator.snapshot.isDirty ||
        authorization.sourceBinding != _sourceBinding ||
        authorization.externalSource != _externalSource ||
        (authorization.resolution != CloseResolution.discard &&
            authorization.dirty) ||
        authorization.resolution == CloseResolution.cancel ||
        _publicationActive ||
        _queuedPublications > 0 ||
        _lifecycle != SessionLifecycle.open) {
      return Err(_failure('invalid_close_authorization'));
    }
    final changed = _mutate(() {
      _closeResolution = authorization.resolution;
      _lifecycle = SessionLifecycle.closed;
    });
    if (changed is Ok<void, StructuredFailure>) {
      sourceRegistry._releaseSession(_sourceAccess);
    }
    return changed;
  }

  /// Moves the Session to failed atomically when not already closed.
  Result<void, StructuredFailure> fail() {
    if (_lifecycle == SessionLifecycle.closed) return Err(_failure('closed'));
    return _mutate(() => _lifecycle = SessionLifecycle.failed);
  }

  /// Begins one exact, bounded Application registration transaction.
  Result<SessionRegistrationAttempt, StructuredFailure>
  _beginApplicationRegistration() {
    if (_registeredWithApplication || _registrationAttempt != null) {
      return Err(_failure('registration_in_progress_or_complete'));
    }
    final attempt = SessionRegistrationAttempt._(id, _closeAuthority);
    _registrationAttempt = attempt;
    return Ok(attempt);
  }

  /// Completes the exact current registration attempt once.
  Result<void, StructuredFailure> _completeApplicationRegistration(
    SessionRegistrationAttempt attempt, {
    required bool accepted,
  }) {
    if (!identical(_registrationAttempt, attempt) ||
        attempt._sessionId != id ||
        !identical(attempt._owner, _closeAuthority)) {
      return Err(_failure('invalid_registration_attempt'));
    }
    _registrationAttempt = null;
    if (accepted) {
      _registeredWithApplication = true;
      return const Ok(null);
    }
    sourceRegistry._releaseSession(_sourceAccess);
    _canonicalSourceOwner = false;
    return const Ok(null);
  }

  Result<void, StructuredFailure> _mutate(void Function() mutation) {
    if (_publicationActive) return Err(_failure('publication_active'));
    final next = _revision.increment();
    if (next is Err<SessionRevision, StructuredFailure>) return Err(next.error);
    mutation();
    _revision = (next as Ok<SessionRevision, StructuredFailure>).value;
    _invalidateCloseEvidence();
    _notify();
    return const Ok(null);
  }

  void _notify() {
    final state = snapshot;
    for (final listener in List<SessionListener>.of(_listeners)) {
      try {
        listener(state);
      } on Object {
        // Listener failure is isolated from authoritative state.
      }
    }
  }

  Result<DateTime, StructuredFailure> _capturedUtcNow() {
    try {
      final now = clock.nowUtc();
      return now.isUtc ? Ok(now) : Err(_failure('invalid_clock'));
    } on Object {
      return Err(_failure('clock_failure'));
    }
  }

  Result<DateTime, StructuredFailure> _closeExpiry(Duration validity) {
    final captured = _capturedUtcNow();
    if (captured is Err<DateTime, StructuredFailure>) return captured;
    try {
      final now = (captured as Ok<DateTime, StructuredFailure>).value;
      final expires = now.add(validity);
      return expires.isUtc && expires.isAfter(now)
          ? Ok(expires)
          : Err(_failure('invalid_close_expiry'));
    } on Object {
      return Err(_failure('invalid_close_expiry'));
    }
  }

  void _invalidateCloseEvidence() {
    _currentCloseDecision = null;
    _currentCloseAuthorization = null;
  }

  void _acknowledgeFailure(DocumentSaveCapture capture) {
    try {
      coordinator.acknowledgeSaveFailure(capture);
    } on Object {
      // Command coordinator failures are fixed and do not alter Session state.
    }
  }

  void _completeSave(
    Completer<SessionSaveResult> completer,
    DocumentSaveCapture capture,
    SessionSaveDisposition disposition, [
    StructuredFailure? failure,
  ]) {
    if (!completer.isCompleted) {
      _queuedPublications -= 1;
      completer.complete(
        SessionSaveResult(
          disposition: disposition,
          capturedIdentity: capture.contentIdentity,
          failure: failure,
        ),
      );
    }
  }
}

SessionRevision _zeroRevision() {
  final result = SessionRevision.create(0);
  if (result is Ok<SessionRevision, StructuredFailure>) return result.value;
  throw StateError('Internal zero Session revision must be valid.');
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.sessions.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The Session operation could not be completed.',
);
