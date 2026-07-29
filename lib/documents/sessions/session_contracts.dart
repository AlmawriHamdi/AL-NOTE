// SPDX-License-Identifier: GPL-3.0-or-later

part of '../sessions.dart';

/// Closed lifecycle states for a logical Session.
enum SessionLifecycle { opening, open, closing, closed, failed }

/// Whether a Session is still loading or ready for use.
enum SessionReadiness { loading, ready }

/// Mutability mode of a Session.
enum SessionAccess { editable, readOnly }

/// Whether a Session preserves complete or degraded content fidelity.
enum SessionFidelity { complete, degraded }

/// Last validated state of a Session's external source.
enum ExternalSourceState { unchanged, changed, missing, unverifiable }

/// Checked monotonic revision of Session-owned state.
final class SessionRevision implements Comparable<SessionRevision> {
  const SessionRevision._(this.value);
  static Result<SessionRevision, StructuredFailure> create(int value) =>
      value >= 0 && value <= Revision.maximumValue
      ? Ok(SessionRevision._(value))
      : Err(_sessionFailure('invalid_revision'));
  final int value;
  Result<SessionRevision, StructuredFailure> increment() =>
      value == Revision.maximumValue
      ? Err(_sessionFailure('revision_overflow'))
      : Ok(SessionRevision._(value + 1));
  @override
  int compareTo(SessionRevision other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) =>
      other is SessionRevision && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => '$value';
}

/// Immutable normalized source and fingerprint binding.
final class StorageSourceBinding {
  const StorageSourceBinding({
    required this.sourceIdentity,
    required this.fingerprint,
  });
  final NormalizedSourceIdentity sourceIdentity;
  final ExternalFingerprint fingerprint;
  @override
  bool operator ==(Object other) =>
      other is StorageSourceBinding &&
      other.sourceIdentity == sourceIdentity &&
      other.fingerprint == fingerprint;
  @override
  int get hashCode => Object.hash(sourceIdentity, fingerprint);
  @override
  String toString() => 'StorageSourceBinding(redacted)';
}

/// Opaque one-use reservation for a prospective canonical source binding.
final class _CanonicalSourceReservation {
  const _CanonicalSourceReservation({
    required this.sessionId,
    required this.operationId,
    required this.sourceIdentity,
    required Object owner,
  }) : _owner = owner;

  /// Session for which the reservation was issued.
  final SessionId sessionId;

  /// Save As operation for which the reservation was issued.
  final SessionOperationId operationId;

  /// Reserved normalized source evidence.
  final NormalizedSourceIdentity sourceIdentity;

  final Object _owner;

  /// Returns whether this evidence was issued by [authority].
  bool isOwnedBy(Object authority) => identical(_owner, authority);

  @override
  String toString() => 'CanonicalSourceReservation(redacted)';
}

/// Opaque per-Session capability accepted only by its issuing registry.
final class _CanonicalSourceAccess {
  const _CanonicalSourceAccess(this.sessionId, this._owner);
  final SessionId sessionId;
  final Object _owner;
  @override
  String toString() => 'CanonicalSourceAccess(redacted)';
}

/// Library-private capability held by the sole Application State for a registry.
final class _CanonicalSourceApplicationAccess {
  const _CanonicalSourceApplicationAccess(this._owner);
  final Object _owner;
  @override
  String toString() => 'CanonicalSourceApplicationAccess(redacted)';
}

/// Coordinates canonical source ownership across logical Sessions.
///
/// Reservations are deterministic, one-use, and do not become ownership until
/// [commit] succeeds. Failed and cancelled Save As operations call [release].
final class CanonicalSourceRegistry {
  final Object _owner = Object();
  final Map<NormalizedSourceIdentity, SessionId> _owners = {};
  final Map<NormalizedSourceIdentity, _CanonicalSourceReservation>
  _reservations = {};
  final Map<SessionId, _CanonicalSourceAccess> _accesses = {};
  _CanonicalSourceApplicationAccess? _applicationAccess;

  Result<ApplicationState, StructuredFailure> _createApplicationState({
    required int maximumListeners,
    required int maximumLifecycleListeners,
  }) {
    if (!_webSafeNonnegative(maximumListeners) ||
        !_webSafeNonnegative(maximumLifecycleListeners)) {
      return Err(_sessionFailure('invalid_application_limits'));
    }
    if (_applicationAccess != null) {
      return Err(_sessionFailure('application_access_claimed'));
    }
    try {
      final access = _CanonicalSourceApplicationAccess(_owner);
      final application = ApplicationState._(
        this,
        access,
        maximumListeners,
        maximumLifecycleListeners,
      );
      _applicationAccess = access;
      return Ok(application);
    } on Object {
      return Err(_sessionFailure('application_creation_failed'));
    }
  }

  bool _validApplicationAccess(_CanonicalSourceApplicationAccess access) =>
      identical(access._owner, _owner) && identical(_applicationAccess, access);

  Result<SessionRegistrationAttempt, StructuredFailure> _beginRegistration(
    _CanonicalSourceApplicationAccess access,
    DocumentSession session,
  ) {
    if (!_validApplicationAccess(access) ||
        !identical(session.sourceRegistry, this)) {
      return Err(_sessionFailure('invalid_application_access'));
    }
    return session._beginApplicationRegistration();
  }

  Result<void, StructuredFailure> _completeRegistration(
    _CanonicalSourceApplicationAccess access,
    DocumentSession session,
    SessionRegistrationAttempt attempt, {
    required bool accepted,
  }) {
    if (!_validApplicationAccess(access) ||
        !identical(session.sourceRegistry, this)) {
      return Err(_sessionFailure('invalid_application_access'));
    }
    return session._completeApplicationRegistration(
      attempt,
      accepted: accepted,
    );
  }

  /// Issues the sole ownership capability for a newly constructed Session.
  Result<_CanonicalSourceAccess, StructuredFailure> _openSession(SessionId id) {
    if (_accesses.containsKey(id))
      return Err(_sessionFailure('duplicate_source_access'));
    final access = _CanonicalSourceAccess(id, _owner);
    _accesses[id] = access;
    return Ok(access);
  }

  bool _valid(_CanonicalSourceAccess access) =>
      identical(access._owner, _owner) &&
      identical(_accesses[access.sessionId], access);

  /// Claims an already-bound source for [sessionId].
  Result<void, StructuredFailure> _claimInitial(
    _CanonicalSourceAccess access,
    NormalizedSourceIdentity sourceIdentity,
  ) {
    if (!_valid(access)) return Err(_sessionFailure('invalid_source_access'));
    final sessionId = access.sessionId;
    final owner = _owners[sourceIdentity];
    if (owner != null && owner != sessionId) {
      return Err(_sessionFailure('source_owned'));
    }
    final reservation = _reservations[sourceIdentity];
    if (reservation != null && reservation.sessionId != sessionId) {
      return Err(_sessionFailure('source_reserved'));
    }
    _owners[sourceIdentity] = sessionId;
    return const Ok(null);
  }

  /// Reserves [sourceIdentity] for one Save As operation.
  Result<_CanonicalSourceReservation, StructuredFailure> _reserve({
    required _CanonicalSourceAccess access,
    required SessionOperationId operationId,
    required NormalizedSourceIdentity sourceIdentity,
  }) {
    if (!_valid(access)) return Err(_sessionFailure('invalid_source_access'));
    final sessionId = access.sessionId;
    final owner = _owners[sourceIdentity];
    if (owner != null && owner != sessionId) {
      return Err(_sessionFailure('source_owned'));
    }
    if (_reservations.containsKey(sourceIdentity)) {
      return Err(_sessionFailure('source_reserved'));
    }
    final reservation = _CanonicalSourceReservation(
      sessionId: sessionId,
      operationId: operationId,
      sourceIdentity: sourceIdentity,
      owner: _owner,
    );
    _reservations[sourceIdentity] = reservation;
    return Ok(reservation);
  }

  /// Commits one exact live reservation and releases the Session's old source.
  Result<void, StructuredFailure> _commit(
    _CanonicalSourceAccess access,
    _CanonicalSourceReservation reservation, {
    NormalizedSourceIdentity? previousSource,
  }) {
    if (!_valid(access) ||
        reservation.sessionId != access.sessionId ||
        !identical(reservation._owner, _owner) ||
        !identical(_reservations[reservation.sourceIdentity], reservation)) {
      return Err(_sessionFailure('invalid_source_reservation'));
    }
    final owner = _owners[reservation.sourceIdentity];
    if (owner != null && owner != reservation.sessionId) {
      return Err(_sessionFailure('source_owned'));
    }
    if (previousSource != null &&
        previousSource != reservation.sourceIdentity) {
      if (_owners[previousSource] == reservation.sessionId) {
        _owners.remove(previousSource);
      }
    }
    _reservations.remove(reservation.sourceIdentity);
    _owners[reservation.sourceIdentity] = reservation.sessionId;
    return const Ok(null);
  }

  /// Releases one still-live reservation without changing ownership.
  void _release(
    _CanonicalSourceAccess access,
    _CanonicalSourceReservation reservation,
  ) {
    if (_valid(access) &&
        reservation.sessionId == access.sessionId &&
        identical(reservation._owner, _owner) &&
        identical(_reservations[reservation.sourceIdentity], reservation)) {
      _reservations.remove(reservation.sourceIdentity);
    }
  }

  /// Releases all ownership and reservations for a closed Session.
  void _releaseSession(_CanonicalSourceAccess access) {
    if (!_valid(access)) return;
    final sessionId = access.sessionId;
    _owners.removeWhere((_, owner) => owner == sessionId);
    _reservations.removeWhere((_, value) => value.sessionId == sessionId);
    _accesses.remove(sessionId);
  }

  /// Returns immutable ownership evidence for registry coordination.
  SessionId? ownerOf(NormalizedSourceIdentity source) => _owners[source];
}

/// Complete immutable snapshot of one logical Session.
final class SessionSnapshot {
  SessionSnapshot._({
    required this.id,
    required this.lifecycle,
    required this.readiness,
    required this.access,
    required this.fidelity,
    required this.externalSource,
    required this.revision,
    required this.document,
    required this.sourceBinding,
    required Iterable<ViewId> views,
  }) : views = UnmodifiableSetView(Set<ViewId>.from(views));
  final SessionId id;
  final SessionLifecycle lifecycle;
  final SessionReadiness readiness;
  final SessionAccess access;
  final SessionFidelity fidelity;
  final ExternalSourceState externalSource;
  final SessionRevision revision;
  final DocumentCoordinatorSnapshot document;
  final StorageSourceBinding? sourceBinding;
  final Set<ViewId> views;
  bool get isDirty => document.isDirty;
}

/// Requested canonical publication operation.
enum SessionSaveKind { save, saveAs }

/// Closed outcome of one Session publication attempt.
enum SessionSaveDisposition { published, cancelled, failed, stale, conflicted }

/// Immutable request passed to the Session publication adapter.
final class SessionPublicationRequest {
  const SessionPublicationRequest({
    required this.sessionId,
    required this.operationId,
    required this.kind,
    required this.capture,
    required this.currentBinding,
    required this.destinationIdentity,
  });
  final SessionId sessionId;
  final SessionOperationId operationId;
  final SessionSaveKind kind;
  final DocumentSaveCapture capture;
  final StorageSourceBinding? currentBinding;
  final NormalizedSourceIdentity? destinationIdentity;
  @override
  String toString() => 'SessionPublicationRequest(${kind.name})';
}

/// Adapter evidence returned after canonical Session publication.
final class SessionPublicationEvidence {
  const SessionPublicationEvidence({
    required this.sourceIdentity,
    required this.fingerprint,
    required this.fresh,
  });
  final NormalizedSourceIdentity sourceIdentity;
  final ExternalFingerprint fingerprint;
  final bool fresh;
  @override
  String toString() => 'SessionPublicationEvidence(fresh: $fresh)';
}

/// Hostile adapter boundary for canonical Session publication.
abstract interface class SessionPublisher {
  Future<OperationOutcome<SessionPublicationEvidence, StructuredFailure>>
  publish(
    SessionPublicationRequest request, {
    required CancellationToken cancellationToken,
  });
}

/// Redaction-safe result of a Session Save operation.
final class SessionSaveResult {
  const SessionSaveResult({
    required this.disposition,
    required this.capturedIdentity,
    required this.failure,
  });
  final SessionSaveDisposition disposition;
  final ContentIdentity capturedIdentity;
  final StructuredFailure? failure;
  @override
  String toString() => 'SessionSaveResult(${disposition.name})';
}

/// User decision available for an issued close request.
enum CloseResolution { save, saveAs, discard, cancel }

/// Opaque random correlation token for one close decision.
final class CloseDecisionToken {
  const CloseDecisionToken._(this._uuid);
  final UuidIdentifier _uuid;

  /// Generates a random token through the AL NOTE UUID boundary.
  static Result<CloseDecisionToken, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(CloseDecisionToken._);
  @override
  bool operator ==(Object other) =>
      other is CloseDecisionToken && other._uuid == _uuid;
  @override
  int get hashCode => _uuid.hashCode;
  @override
  String toString() => 'CloseDecisionToken(redacted)';
}

/// Session-owned immutable facts presented for a close decision.
final class CloseDecisionRequest {
  CloseDecisionRequest._({
    required this.sessionId,
    required this.sessionRevision,
    required this.contentIdentity,
    required this.dirty,
    required this.access,
    required this.fidelity,
    required this.externalSource,
    required Iterable<CloseResolution> permittedResolutions,
    required this.token,
    required this.expiresAtUtc,
    required Object owner,
  }) : permittedResolutions = UnmodifiableSetView(Set.of(permittedResolutions)),
       _owner = owner;
  final SessionId sessionId;
  final SessionRevision sessionRevision;
  final ContentIdentity contentIdentity;
  final bool dirty;
  final SessionAccess access;
  final SessionFidelity fidelity;
  final ExternalSourceState externalSource;
  final Set<CloseResolution> permittedResolutions;
  final CloseDecisionToken token;
  final DateTime expiresAtUtc;
  final Object _owner;

  /// Returns whether this evidence was issued by [authority].
  bool isOwnedBy(Object authority) => identical(_owner, authority);
  @override
  String toString() =>
      'CloseDecisionRequest(session: $sessionId, dirty: $dirty)';

  /// Issues inert request evidence for an owning Session authority.
  static CloseDecisionRequest _issue({
    required SessionId sessionId,
    required SessionRevision sessionRevision,
    required ContentIdentity contentIdentity,
    required bool dirty,
    required SessionAccess access,
    required SessionFidelity fidelity,
    required ExternalSourceState externalSource,
    required Iterable<CloseResolution> permittedResolutions,
    required CloseDecisionToken token,
    required DateTime expiresAtUtc,
    required Object owner,
  }) => CloseDecisionRequest._(
    sessionId: sessionId,
    sessionRevision: sessionRevision,
    contentIdentity: contentIdentity,
    dirty: dirty,
    access: access,
    fidelity: fidelity,
    externalSource: externalSource,
    permittedResolutions: permittedResolutions,
    token: token,
    expiresAtUtc: expiresAtUtc,
    owner: owner,
  );
}

/// Caller response to one exact issued close request.
final class CloseDecision {
  const CloseDecision({
    required this.sessionId,
    required this.token,
    required this.resolution,
  });
  final SessionId sessionId;
  final CloseDecisionToken token;
  final CloseResolution resolution;
}

/// Opaque one-use authorization produced by resolving an issued close request.
final class CloseAuthorization {
  const CloseAuthorization._({
    required this.sessionId,
    required this.resolution,
    required this.sessionRevision,
    required this.contentIdentity,
    required this.dirty,
    required this.sourceBinding,
    required this.externalSource,
    required Object owner,
  }) : _owner = owner;

  /// Owning logical Session.
  final SessionId sessionId;

  /// Resolution that authorized close.
  final CloseResolution resolution;

  /// Session revision after any required successful Save.
  final SessionRevision sessionRevision;
  final ContentIdentity contentIdentity;
  final bool dirty;
  final StorageSourceBinding? sourceBinding;
  final ExternalSourceState externalSource;

  final Object _owner;

  /// Returns whether this evidence was issued by [authority].
  bool isOwnedBy(Object authority) => identical(_owner, authority);

  /// Issues inert authorization evidence for an owning Session authority.
  static CloseAuthorization _issue({
    required SessionId sessionId,
    required CloseResolution resolution,
    required SessionRevision sessionRevision,
    required ContentIdentity contentIdentity,
    required bool dirty,
    required StorageSourceBinding? sourceBinding,
    required ExternalSourceState externalSource,
    required Object owner,
  }) => CloseAuthorization._(
    sessionId: sessionId,
    resolution: resolution,
    sessionRevision: sessionRevision,
    contentIdentity: contentIdentity,
    dirty: dirty,
    sourceBinding: sourceBinding,
    externalSource: externalSource,
    owner: owner,
  );

  @override
  String toString() => 'CloseAuthorization(redacted)';
}

/// Opaque one-use capability for one Application registration attempt.
final class SessionRegistrationAttempt {
  const SessionRegistrationAttempt._(this._sessionId, this._owner);
  final SessionId _sessionId;
  final Object _owner;
  @override
  String toString() => 'SessionRegistrationAttempt(redacted)';
}

/// Exact Phase 5 Session requirements without numeric defaults.
final Map<String, ResourceLimitUnit> alnoteSessionLimitRequirements =
    UnmodifiableMapView({
      'alnote.sessions.open_sessions': ResourceLimitUnit.count,
      'alnote.sessions.views_per_session': ResourceLimitUnit.count,
      'alnote.sessions.restoration_entries': ResourceLimitUnit.count,
      'alnote.sessions.concurrent_operations': ResourceLimitUnit.count,
      'alnote.sessions.publication_queue': ResourceLimitUnit.count,
      'alnote.sessions.listeners': ResourceLimitUnit.count,
      'alnote.sessions.application_listeners': ResourceLimitUnit.count,
      'alnote.sessions.lifecycle_listeners': ResourceLimitUnit.count,
      'alnote.sessions.document_listeners': ResourceLimitUnit.count,
    });

StructuredFailure _sessionFailure(String leaf) => StructuredFailure(
  code: 'documents.sessions.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The Session operation was rejected.',
);
