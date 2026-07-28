// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../identity/uuid_generator.dart';
import '../identity/uuid_identifier.dart';
import '../outcomes/cancellation.dart';
import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import '../security/resource_limits.dart';

abstract base class _JobUuid {
  const _JobUuid(this.uuid);
  final UuidIdentifier uuid;
  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is _JobUuid &&
      other.uuid == uuid;
  @override
  int get hashCode => Object.hash(runtimeType, uuid);
}

/// Runtime Job identity.
final class JobId extends _JobUuid {
  const JobId.fromUuid(super.uuid);
  static Result<JobId, StructuredFailure> generate(UuidGenerator generator) =>
      generator.generateV4().map(JobId.fromUuid);
  @override
  String toString() => 'JobId(${uuid.value})';
}

/// Structured-concurrency scope identity.
final class JobScopeId extends _JobUuid {
  const JobScopeId.fromUuid(super.uuid);
  static Result<JobScopeId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(JobScopeId.fromUuid);
  @override
  String toString() => 'JobScopeId(${uuid.value})';
}

/// Closed Job scope ownership kinds.
enum JobScopeKind { application, session, view, operation, parentJob }

/// Validated immutable Job scope shape.
final class JobScope {
  const JobScope._({
    required this.id,
    required this.kind,
    required this.parent,
    required this.sessionKey,
    required this.viewKey,
    required this.depth,
    required this.detached,
  });
  final JobScopeId id;
  final JobScopeKind kind;
  final JobScopeId? parent;
  final String? sessionKey;
  final String? viewKey;
  final int depth;
  final bool detached;

  /// Creates a scope after validating its complete shape and safe keys.
  static Result<JobScope, StructuredFailure> create({
    required JobScopeId id,
    required JobScopeKind kind,
    JobScopeId? parent,
    String? sessionKey,
    String? viewKey,
    required int depth,
    bool detached = false,
  }) {
    final safe = RegExp(r'^[a-zA-Z0-9._-]{1,128}$');
    final validKeys =
        (sessionKey == null || safe.hasMatch(sessionKey)) &&
        (viewKey == null || safe.hasMatch(viewKey));
    final validShape = switch (kind) {
      JobScopeKind.application =>
        parent == null && sessionKey == null && viewKey == null,
      JobScopeKind.session => sessionKey != null && viewKey == null,
      JobScopeKind.view => sessionKey != null && viewKey != null,
      JobScopeKind.operation => parent != null,
      JobScopeKind.parentJob => parent != null,
    };
    if (!validKeys ||
        !validShape ||
        depth < 0 ||
        depth > 9007199254740991 ||
        (detached && kind != JobScopeKind.application)) {
      return Err(_failure('invalid_scope'));
    }
    return Ok(
      JobScope._(
        id: id,
        kind: kind,
        parent: parent,
        sessionKey: sessionKey,
        viewKey: viewKey,
        depth: depth,
        detached: detached,
      ),
    );
  }

  @override
  String toString() => 'JobScope(${kind.name})';
}

/// Closed scheduling classes in strict priority order.
enum SchedulingClass {
  inputCritical,
  frameCritical,
  userBlocking,
  persistenceCritical,
  userVisible,
  backgroundMaintenance,
  opportunistic,
}

/// Closed terminal outcomes for Job execution.
enum JobOutcome { completed, cancelled, superseded, failed }

/// Whether a terminal Job result contains complete or partial work.
enum JobCompleteness { complete, partial }

/// Whether a Job result was degraded by optional work.
enum JobDegradation { normal, degraded }

/// Freshness evidence attached to a Job result.
enum JobFreshness { current, stale, requiresValidation }

/// Owner-controlled publication state of a Job result.
enum JobPublication { unpublished, accepted, rejected, ownerPublished }

/// Declared retry classification for a Job request.
enum JobRetryClassification { never, transient }

/// Declared idempotency required for safe retries.
enum JobIdempotency { nonIdempotent, idempotent }

/// Whether a child outcome is required or optional for its parent.
enum ChildRequirement { required, optional }

/// Lifecycle state used to degrade or cancel queued Jobs.
enum JobLifecycleState {
  foreground,
  background,
  hidden,
  suspended,
  memoryPressure,
  closing,
  safeMode,
}

/// Validated immutable resource-unit estimate.
final class JobResourceEstimate {
  JobResourceEstimate._(Map<String, int> units)
    : units = UnmodifiableMapView(units);
  final Map<String, int> units;

  static Result<JobResourceEstimate, StructuredFailure> create(
    Map<String, int> units, {
    required int maximumCategories,
  }) {
    try {
      final copied = Map<String, int>.of(units);
      if (maximumCategories < 0 ||
          copied.length > maximumCategories ||
          copied.keys.any(
            (key) => !RegExp(r'^[a-z][a-z0-9._-]{0,127}$').hasMatch(key),
          ) ||
          copied.values.any((value) => value < 0 || value > 9007199254740991)) {
        return Err(_failure('invalid_resource_estimate'));
      }
      return Ok(JobResourceEstimate._(copied));
    } on Object {
      return Err(_failure('invalid_resource_estimate'));
    }
  }
}

/// Typed Security/capability admission evidence, not authorization by identity.
final class JobAdmissionEvidence {
  JobAdmissionEvidence._({
    required Set<String> capabilities,
    required this.securityGeneration,
  }) : capabilities = UnmodifiableSetView(capabilities);
  final Set<String> capabilities;
  final int securityGeneration;

  static Result<JobAdmissionEvidence, StructuredFailure> create({
    required Iterable<String> capabilities,
    required int securityGeneration,
    required int maximumCapabilities,
  }) {
    try {
      final copied = Set<String>.of(capabilities);
      if (securityGeneration < 0 ||
          securityGeneration > 9007199254740991 ||
          maximumCapabilities < 0 ||
          copied.length > maximumCapabilities ||
          copied.any(
            (value) => !RegExp(
              r'^alnote\.platform\.[a-z][a-z0-9._-]*$',
            ).hasMatch(value),
          )) {
        return Err(_failure('invalid_admission_evidence'));
      }
      return Ok(
        JobAdmissionEvidence._(
          capabilities: copied,
          securityGeneration: securityGeneration,
        ),
      );
    } on Object {
      return Err(_failure('invalid_admission_evidence'));
    }
  }
}

/// Typed redacted supersession key.
final class SupersessionKey<S> {
  const SupersessionKey(this.value);
  final S value;
  @override
  bool operator ==(Object other) =>
      other is SupersessionKey<S> && other.value == value;
  @override
  int get hashCode => Object.hash(S, value);
  @override
  String toString() => 'SupersessionKey(redacted)';
}

/// Validated progress throttling/coalescing policy.
final class JobProgressPolicy {
  const JobProgressPolicy._({
    required this.maximumEvents,
    required this.coalesce,
  });
  final int maximumEvents;
  final bool coalesce;
  static Result<JobProgressPolicy, StructuredFailure> create({
    required int maximumEvents,
    required bool coalesce,
  }) => maximumEvents >= 0 && maximumEvents <= 9007199254740991
      ? Ok(
          JobProgressPolicy._(maximumEvents: maximumEvents, coalesce: coalesce),
        )
      : Err(_failure('invalid_progress_policy'));
}

/// Validated typed redacted progress event.
final class JobProgress {
  const JobProgress._({
    required this.phase,
    required this.completedUnits,
    required this.totalUnits,
  });
  final String phase;
  final int completedUnits;
  final int? totalUnits;
  static Result<JobProgress, StructuredFailure> create({
    required String phase,
    required int completedUnits,
    int? totalUnits,
  }) =>
      RegExp(r'^[a-z][a-z0-9._-]{0,63}$').hasMatch(phase) &&
          completedUnits >= 0 &&
          completedUnits <= 9007199254740991 &&
          (totalUnits == null ||
              (totalUnits >= completedUnits && totalUnits <= 9007199254740991))
      ? Ok(
          JobProgress._(
            phase: phase,
            completedUnits: completedUnits,
            totalUnits: totalUnits,
          ),
        )
      : Err(_failure('invalid_progress'));
  @override
  String toString() => 'JobProgress(phase: $phase, completed: $completedUnits)';
}

/// Validates and normalizes one typed Job input.
typedef JobInputValidator<T> = Result<T, StructuredFailure> Function(T input);

/// Executes one validated Job input within a cooperative context.
typedef JobRunner<T, R> =
    Future<R> Function(T input, JobExecutionContext context);

/// Potentially hostile metadata source captured once by [JobRegistry].
abstract interface class JobKindSource<T, R, S> {
  String get identity;
  String get ownerSubsystem;
  String get payloadContractIdentity;
  Set<SchedulingClass> get permittedSchedulingClasses;
  bool get supportsSupersession;
  bool get supportsRetry;
  bool get supportsPartialResults;
  bool get supportsDetachedExecution;
  JobInputValidator<T> get validator;
  JobRunner<T, R> get runner;
}

/// Registry-issued immutable typed Job-kind handle.
final class RegisteredJobKind<T, R, S> {
  RegisteredJobKind._({
    required this.identity,
    required this.ownerSubsystem,
    required this.payloadContractIdentity,
    required Set<SchedulingClass> permittedSchedulingClasses,
    required this.supportsSupersession,
    required this.supportsRetry,
    required this.supportsPartialResults,
    required this.supportsDetachedExecution,
    required this.validator,
    required this.runner,
    required Object owner,
  }) : permittedSchedulingClasses = UnmodifiableSetView(
         permittedSchedulingClasses,
       ),
       _owner = owner;
  final String identity;
  final String ownerSubsystem;
  final String payloadContractIdentity;
  final Set<SchedulingClass> permittedSchedulingClasses;
  final bool supportsSupersession;
  final bool supportsRetry;
  final bool supportsPartialResults;
  final bool supportsDetachedExecution;
  final JobInputValidator<T> validator;
  final JobRunner<T, R> runner;
  final Object _owner;
  bool _issuedBy(Object owner) => identical(_owner, owner);
}

/// Central registry that exclusively issues submit-capable kind handles.
final class JobRegistry {
  final Object _owner = Object();
  final Map<String, Object> _kinds = {};

  /// Captures metadata exactly once and rejects hostile or duplicate sources.
  Result<RegisteredJobKind<T, R, S>, StructuredFailure> register<T, R, S>(
    JobKindSource<T, R, S> source,
  ) {
    try {
      final identity = source.identity;
      final ownerSubsystem = source.ownerSubsystem;
      final payload = source.payloadContractIdentity;
      final classes = Set<SchedulingClass>.of(
        source.permittedSchedulingClasses,
      );
      final supersession = source.supportsSupersession;
      final retry = source.supportsRetry;
      final partial = source.supportsPartialResults;
      final detached = source.supportsDetachedExecution;
      final validator = source.validator;
      final runner = source.runner;
      final safe = RegExp(r'^[a-zA-Z][a-zA-Z0-9._-]{0,127}$');
      if (!RegExp(r'^alnote\.jobs\.[a-z][a-z0-9._-]*$').hasMatch(identity) ||
          !safe.hasMatch(ownerSubsystem) ||
          !safe.hasMatch(payload) ||
          classes.isEmpty ||
          _kinds.containsKey(identity)) {
        return Err(_failure('invalid_or_duplicate_kind'));
      }
      final kind = RegisteredJobKind<T, R, S>._(
        identity: identity,
        ownerSubsystem: ownerSubsystem,
        payloadContractIdentity: payload,
        permittedSchedulingClasses: classes,
        supportsSupersession: supersession,
        supportsRetry: retry,
        supportsPartialResults: partial,
        supportsDetachedExecution: detached,
        validator: validator,
        runner: runner,
        owner: _owner,
      );
      _kinds[identity] = kind;
      return Ok(kind);
    } on Object {
      return Err(_failure('kind_metadata_failure'));
    }
  }

  /// Returns whether [kind] is the exact handle issued by this registry.
  bool owns<T, R, S>(RegisteredJobKind<T, R, S> kind) =>
      kind._issuedBy(_owner) && identical(_kinds[kind.identity], kind);
}

/// Immutable typed request validated before queue mutation.
final class JobRequest<T, R, S> {
  const JobRequest._({
    required this.id,
    required this.kind,
    required this.scope,
    required this.input,
    required this.schedulingClass,
    required this.resources,
    required this.requiredCapabilities,
    required this.admissionEvidence,
    required this.expiresAtUtc,
    required this.supersessionKey,
    required this.progressPolicy,
    required this.retryClassification,
    required this.idempotency,
    required this.maximumAttempts,
    required this.parentJobId,
    required this.childRequirement,
  });
  final JobId id;
  final RegisteredJobKind<T, R, S> kind;
  final JobScope scope;
  final T input;
  final SchedulingClass schedulingClass;
  final JobResourceEstimate resources;
  final List<String> requiredCapabilities;
  final JobAdmissionEvidence admissionEvidence;
  final DateTime? expiresAtUtc;
  final SupersessionKey<S>? supersessionKey;
  final JobProgressPolicy progressPolicy;
  final JobRetryClassification retryClassification;
  final JobIdempotency idempotency;
  final int maximumAttempts;
  final JobId? parentJobId;
  final ChildRequirement childRequirement;

  /// Creates a structurally valid request; scheduler admission remains separate.
  static Result<JobRequest<T, R, S>, StructuredFailure> create<T, R, S>({
    required JobId id,
    required RegisteredJobKind<T, R, S> kind,
    required JobScope scope,
    required T input,
    required SchedulingClass schedulingClass,
    required JobResourceEstimate resources,
    required Iterable<String> requiredCapabilities,
    required JobAdmissionEvidence admissionEvidence,
    DateTime? expiresAtUtc,
    SupersessionKey<S>? supersessionKey,
    required JobProgressPolicy progressPolicy,
    required JobRetryClassification retryClassification,
    required JobIdempotency idempotency,
    required int maximumAttempts,
    JobId? parentJobId,
    ChildRequirement childRequirement = ChildRequirement.required,
  }) {
    try {
      final capabilities = List<String>.of(requiredCapabilities);
      final expiry = expiresAtUtc?.toUtc();
      if (maximumAttempts <= 0 ||
          maximumAttempts > 9007199254740991 ||
          capabilities.toSet().length != capabilities.length ||
          capabilities.any(
            (value) => !RegExp(
              r'^alnote\.platform\.[a-z][a-z0-9._-]*$',
            ).hasMatch(value),
          ) ||
          (retryClassification == JobRetryClassification.transient &&
              (idempotency != JobIdempotency.idempotent ||
                  !kind.supportsRetry)) ||
          (supersessionKey != null && !kind.supportsSupersession) ||
          (scope.detached && !kind.supportsDetachedExecution) ||
          (parentJobId == null) != (scope.kind != JobScopeKind.parentJob)) {
        return Err(_failure('invalid_request'));
      }
      return Ok(
        JobRequest._(
          id: id,
          kind: kind,
          scope: scope,
          input: input,
          schedulingClass: schedulingClass,
          resources: resources,
          requiredCapabilities: List.unmodifiable(capabilities),
          admissionEvidence: admissionEvidence,
          expiresAtUtc: expiry,
          supersessionKey: supersessionKey,
          progressPolicy: progressPolicy,
          retryClassification: retryClassification,
          idempotency: idempotency,
          maximumAttempts: maximumAttempts,
          parentJobId: parentJobId,
          childRequirement: childRequirement,
        ),
      );
    } on Object {
      return Err(_failure('invalid_request'));
    }
  }

  @override
  String toString() =>
      'JobRequest(id: $id, kind: ${kind.identity}, class: ${schedulingClass.name})';
}

/// Immutable terminal Job evidence; publication remains owner-controlled.
final class JobResult<R> {
  const JobResult({
    required this.jobId,
    required this.outcome,
    required this.completeness,
    required this.degradation,
    required this.freshness,
    required this.publication,
    required this.value,
    required this.failure,
    required this.attempts,
  });
  final JobId jobId;
  final JobOutcome outcome;
  final JobCompleteness completeness;
  final JobDegradation degradation;
  final JobFreshness freshness;
  final JobPublication publication;
  final R? value;
  final StructuredFailure? failure;
  final int attempts;
  @override
  String toString() =>
      'JobResult(job: $jobId, outcome: ${outcome.name}, freshness: ${freshness.name}, publication: ${publication.name})';
}

/// Narrow cooperative execution context supplied to a runner.
final class JobExecutionContext {
  const JobExecutionContext({
    required this.cancellationToken,
    required this.reportProgress,
    required this.attempt,
  });
  final CancellationToken cancellationToken;
  final void Function(JobProgress progress) reportProgress;
  final int attempt;
}

final Map<String, ResourceLimitUnit> alnoteJobLimitRequirements =
    UnmodifiableMapView({
      'alnote.jobs.global_queued': ResourceLimitUnit.count,
      'alnote.jobs.global_running': ResourceLimitUnit.count,
      'alnote.jobs.session_queued': ResourceLimitUnit.count,
      'alnote.jobs.session_running': ResourceLimitUnit.count,
      'alnote.jobs.scope_depth': ResourceLimitUnit.depth,
      'alnote.jobs.child_count': ResourceLimitUnit.count,
      'alnote.jobs.retry_attempts': ResourceLimitUnit.count,
      'alnote.jobs.progress_events': ResourceLimitUnit.count,
      'alnote.jobs.reserved_resource_units': ResourceLimitUnit.count,
    });

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'core.jobs.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'The Job contract is invalid.',
);
