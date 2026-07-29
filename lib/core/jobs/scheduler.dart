// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import '../outcomes/cancellation.dart';
import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import '../time/clock.dart';
import 'contracts.dart';

/// Fully injected bounded scheduler limits with no production defaults.
final class JobSchedulerLimits {
  const JobSchedulerLimits._({
    required this.globalQueued,
    required this.globalRunning,
    required this.perSessionQueued,
    required this.perSessionRunning,
    required this.reservedPersistenceSlots,
    required this.maximumScopeDepth,
    required this.maximumChildren,
    required this.maximumRetryAttempts,
    required this.maximumProgressListeners,
    required this.resourceUnits,
  });
  final int globalQueued;
  final int globalRunning;
  final int perSessionQueued;
  final int perSessionRunning;
  final int reservedPersistenceSlots;
  final int maximumScopeDepth;
  final int maximumChildren;
  final int maximumRetryAttempts;
  final int maximumProgressListeners;
  final Map<String, int> resourceUnits;

  /// Creates validated Web-safe scheduler limits.
  static Result<JobSchedulerLimits, StructuredFailure> create({
    required int globalQueued,
    required int globalRunning,
    required int perSessionQueued,
    required int perSessionRunning,
    required int reservedPersistenceSlots,
    required int maximumScopeDepth,
    required int maximumChildren,
    required int maximumRetryAttempts,
    required int maximumProgressListeners,
    required int maximumResourceCategories,
    required Map<String, int> resourceUnits,
  }) {
    try {
      if (maximumResourceCategories < 0 ||
          maximumResourceCategories > 9007199254740991) {
        return Err(_failure('invalid_limits'));
      }
      final resources = _boundedSchedulerMap(
        resourceUnits,
        maximumResourceCategories,
      );
      if (resources == null) return Err(_failure('invalid_limits'));
      final values = [
        globalQueued,
        globalRunning,
        perSessionQueued,
        perSessionRunning,
        reservedPersistenceSlots,
        maximumScopeDepth,
        maximumChildren,
        maximumRetryAttempts,
        maximumProgressListeners,
        maximumResourceCategories,
        ...resources.values,
      ];
      if (values.any((value) => value < 0 || value > 9007199254740991) ||
          globalRunning == 0 ||
          perSessionRunning == 0 ||
          reservedPersistenceSlots > globalRunning ||
          resources.keys.any(
            (key) => !RegExp(r'^[a-z][a-z0-9._-]{0,127}$').hasMatch(key),
          )) {
        return Err(_failure('invalid_limits'));
      }
      return Ok(
        JobSchedulerLimits._(
          globalQueued: globalQueued,
          globalRunning: globalRunning,
          perSessionQueued: perSessionQueued,
          perSessionRunning: perSessionRunning,
          reservedPersistenceSlots: reservedPersistenceSlots,
          maximumScopeDepth: maximumScopeDepth,
          maximumChildren: maximumChildren,
          maximumRetryAttempts: maximumRetryAttempts,
          maximumProgressListeners: maximumProgressListeners,
          resourceUnits: Map.unmodifiable(resources),
        ),
      );
    } on Object {
      return Err(_failure('invalid_limits'));
    }
  }
}

/// Revalidates current capability and Security authority at admission/attempts.
abstract interface class JobAdmissionController {
  Result<void, StructuredFailure> validate({
    required List<String> requiredCapabilities,
    required JobAdmissionEvidence evidence,
  });
}

/// Observes validated bounded progress after scheduler coalescing.
typedef JobProgressListener = void Function(JobId id, JobProgress progress);

abstract class _QueuedJob {
  _QueuedJob(this.sequence, this.controller);
  final int sequence;
  final CancellationController controller;
  JobId get id;
  JobScope get scope;
  SchedulingClass get schedulingClass;
  String get kindIdentity;
  JobId? get parentJobId;
  ChildRequirement get childRequirement;
  JobResourceEstimate get resources;
  JobProgressPolicy get progressPolicy;
  DateTime? get expiresAtUtc;
  JobAdmissionEvidence get admissionEvidence;
  List<String> get requiredCapabilities;
  bool supersedes(_QueuedJob other);
  Future<void> run(JobScheduler scheduler);
  void completeCancelled(JobOutcome outcome);
  JobOutcome get terminalOutcome;
}

final class _TypedQueuedJob<T, R, S> extends _QueuedJob {
  _TypedQueuedJob(
    this.request,
    this.normalizedInput,
    this.completer,
    super.sequence,
    super.controller,
  );
  final JobRequest<T, R, S> request;
  final T normalizedInput;
  final Completer<JobResult<R>> completer;
  JobOutcome _terminalOutcome = JobOutcome.failed;
  @override
  JobOutcome get terminalOutcome => _terminalOutcome;
  @override
  JobId get id => request.id;
  @override
  JobScope get scope => request.scope;
  @override
  SchedulingClass get schedulingClass => request.schedulingClass;
  @override
  String get kindIdentity => request.kind.identity;
  @override
  JobId? get parentJobId => request.parentJobId;
  @override
  ChildRequirement get childRequirement => request.childRequirement;
  @override
  JobResourceEstimate get resources => request.resources;
  @override
  JobProgressPolicy get progressPolicy => request.progressPolicy;
  @override
  DateTime? get expiresAtUtc => request.expiresAtUtc;
  @override
  JobAdmissionEvidence get admissionEvidence => request.admissionEvidence;
  @override
  List<String> get requiredCapabilities => request.requiredCapabilities;

  @override
  bool supersedes(_QueuedJob other) =>
      other is _TypedQueuedJob<T, R, S> &&
      request.supersessionKey != null &&
      other.request.supersessionKey == request.supersessionKey &&
      other.kindIdentity == kindIdentity &&
      other.scope.sessionKey == scope.sessionKey;

  @override
  Future<void> run(JobScheduler scheduler) async {
    var attempts = 0;
    while (true) {
      if (controller.token.isCancelled) {
        scheduler._cancelChildren(id, 'parent_cancelled');
        scheduler._parentRunnerCompleted(id);
        scheduler._releaseForChildJoin(this);
        await scheduler._joinRequiredChildren(id);
        _finish(JobOutcome.cancelled, attempts: attempts);
        return;
      }
      if (scheduler._expired(this) ||
          scheduler._revalidate(this) is Err<void, StructuredFailure>) {
        scheduler._cancelChildren(id, 'parent_rejected');
        scheduler._parentRunnerCompleted(id);
        scheduler._releaseForChildJoin(this);
        await scheduler._joinRequiredChildren(id);
        completer.complete(
          _failed(id, _failure('authority_or_expiry'), attempts),
        );
        return;
      }
      attempts += 1;
      R value;
      try {
        value = await request.kind.runner(
          normalizedInput,
          JobExecutionContext(
            cancellationToken: controller.token,
            reportProgress: (progress) => scheduler._progress(this, progress),
            attempt: attempts,
          ),
        );
      } on Object {
        if (controller.token.isCancelled) {
          scheduler._cancelChildren(id, 'parent_cancelled');
          scheduler._parentRunnerCompleted(id);
          scheduler._releaseForChildJoin(this);
          await scheduler._joinRequiredChildren(id);
          _finish(JobOutcome.cancelled, attempts: attempts);
          return;
        }
        final retry =
            request.kind.supportsRetry &&
            request.retryClassification == JobRetryClassification.transient &&
            request.idempotency == JobIdempotency.idempotent &&
            attempts < request.maximumAttempts &&
            attempts <= scheduler.limits.maximumRetryAttempts &&
            !controller.token.isCancelled &&
            !scheduler._expired(this) &&
            scheduler._revalidate(this) is Ok<void, StructuredFailure>;
        if (!retry) {
          scheduler._cancelChildren(id, 'parent_failed');
          scheduler._parentRunnerCompleted(id);
          scheduler._releaseForChildJoin(this);
          try {
            await scheduler._joinRequiredChildren(id);
          } on Object {
            // Join failures are terminal and never retry the successful runner.
          }
          completer.complete(_failed(id, _failure('runner_failure'), attempts));
          return;
        }
        continue;
      }
      scheduler._parentRunnerCompleted(id);
      scheduler._releaseForChildJoin(this);
      _ChildState childState;
      try {
        childState = await scheduler._joinRequiredChildren(id);
      } on Object {
        completer.complete(
          _failed(id, _failure('child_join_failure'), attempts),
        );
        return;
      }
      if (controller.token.isCancelled) {
        _finish(JobOutcome.cancelled, attempts: attempts);
      } else if (childState.requiredFailure) {
        completer.complete(
          _failed(id, _failure('required_child_failed'), attempts),
        );
      } else {
        _terminalOutcome = JobOutcome.completed;
        completer.complete(
          JobResult(
            jobId: id,
            outcome: JobOutcome.completed,
            completeness: JobCompleteness.complete,
            degradation: childState.optionalFailure
                ? JobDegradation.degraded
                : JobDegradation.normal,
            freshness: JobFreshness.requiresValidation,
            publication: JobPublication.unpublished,
            value: value,
            failure: null,
            attempts: attempts,
          ),
        );
      }
      return;
    }
  }

  void _finish(JobOutcome outcome, {required int attempts}) {
    _terminalOutcome = outcome;
    if (!completer.isCompleted) {
      completer.complete(
        JobResult(
          jobId: id,
          outcome: outcome,
          completeness: JobCompleteness.partial,
          degradation: JobDegradation.normal,
          freshness: JobFreshness.stale,
          publication: JobPublication.unpublished,
          value: null,
          failure: null,
          attempts: attempts,
        ),
      );
    }
  }

  @override
  void completeCancelled(JobOutcome outcome) => _finish(outcome, attempts: 0);
}

/// Portable deterministic bounded scheduler; it never publishes owner results.
final class JobScheduler {
  JobScheduler._({
    required this.clock,
    required this.limits,
    required this.registry,
    required this.admissionController,
  });

  /// Creates a scheduler only from validated limits and admission contracts.
  static Result<JobScheduler, StructuredFailure> create({
    required Clock clock,
    required JobSchedulerLimits limits,
    required JobRegistry registry,
    required JobAdmissionController admissionController,
  }) => Ok(
    JobScheduler._(
      clock: clock,
      limits: limits,
      registry: registry,
      admissionController: admissionController,
    ),
  );

  final Clock clock;
  final JobSchedulerLimits limits;
  final JobRegistry registry;
  final JobAdmissionController admissionController;
  final List<_QueuedJob> _queue = [];
  final Map<JobId, _QueuedJob> _running = {};
  final Set<JobId> _knownIds = {};
  final Map<JobScopeId, Set<JobId>> _scopeJobs = {};
  final Map<JobId, Set<JobId>> _children = {};
  final Map<JobId, ChildRequirement> _childRequirements = {};
  final Map<JobId, Completer<JobOutcome>> _childOutcomes = {};
  final Set<JobId> _parentsDone = {};
  final Map<String, int> _reserved = {};
  final Set<JobId> _releasedForJoin = {};
  final List<JobProgressListener> _progressListeners = [];
  final Map<JobId, int> _progressCounts = {};
  final Map<JobId, JobProgress> _coalescedProgress = {};
  int _sequence = 0;
  int _roundRobinIndex = 0;
  JobLifecycleState _lifecycle = JobLifecycleState.foreground;

  /// Adds a snapshot-based, exception-isolated progress listener.
  Result<void, StructuredFailure> addProgressListener(
    JobProgressListener listener,
  ) {
    if (_progressListeners.contains(listener)) return const Ok(null);
    if (_progressListeners.length >= limits.maximumProgressListeners) {
      return Err(_failure('progress_listener_limit'));
    }
    _progressListeners.add(listener);
    return const Ok(null);
  }

  /// Removes a progress listener from later events.
  void removeProgressListener(JobProgressListener listener) =>
      _progressListeners.remove(listener);

  /// Validates and queues one registry-issued typed request atomically.
  Future<JobResult<R>> submit<T, R, S>(JobRequest<T, R, S> request) {
    final completer = Completer<JobResult<R>>();
    StructuredFailure? rejection;
    _Present<T>? normalized;
    if (!registry.owns(request.kind)) {
      rejection = _failure('unregistered_kind');
    } else if (_knownIds.contains(request.id)) {
      rejection = _failure('duplicate_job_id');
    } else if (!request.kind.permittedSchedulingClasses.contains(
      request.schedulingClass,
    )) {
      rejection = _failure('scheduling_class_rejected');
    } else if (request.scope.depth > limits.maximumScopeDepth) {
      rejection = _failure('scope_depth');
    } else if (_expiredRequest(request.expiresAtUtc)) {
      rejection = _failure('expired');
    } else if (request.maximumAttempts > _maximumTotalAttempts()) {
      rejection = _failure('retry_limit');
    } else if (!_resourcesKnownAndBounded(request.resources)) {
      rejection = _failure('resource_denied');
    } else if (_queue.length >= limits.globalQueued ||
        (request.scope.sessionKey != null &&
            _queue
                    .where(
                      (job) => job.scope.sessionKey == request.scope.sessionKey,
                    )
                    .length >=
                limits.perSessionQueued)) {
      rejection = _failure('overload');
    } else if (request.parentJobId != null &&
        (!_knownIds.contains(request.parentJobId) ||
            _parentsDone.contains(request.parentJobId))) {
      rejection = _failure('unknown_or_completed_parent');
    } else if (request.parentJobId != null &&
        (_children[request.parentJobId]?.length ?? 0) >=
            limits.maximumChildren) {
      rejection = _failure('child_limit');
    } else if (_sequence == 9007199254740991) {
      rejection = _failure('sequence_overflow');
    } else {
      try {
        final validated = request.kind.validator(request.input);
        if (validated is Ok<T, StructuredFailure>) {
          normalized = _Present(validated.value);
        } else {
          rejection = _failure('invalid_input');
        }
      } on Object {
        rejection = _failure('validator_failure');
      }
    }
    if (rejection == null &&
        _initialAdmission(request) is Err<void, StructuredFailure>) {
      rejection = _failure('admission_denied');
    }
    if (rejection != null) {
      completer.complete(_failed(request.id, rejection, 0));
      return completer.future;
    }
    final controller = CancellationController();
    final job = _TypedQueuedJob<T, R, S>(
      request,
      normalized!.value,
      completer,
      _sequence++,
      controller,
    );
    if (request.supersessionKey != null) {
      final replaced = _queue.where(job.supersedes).toList();
      for (final prior in replaced) {
        _queue.remove(prior);
        prior.controller.cancel('superseded');
        prior.completeCancelled(JobOutcome.superseded);
        _cleanup(prior, JobOutcome.superseded);
      }
    }
    _knownIds.add(request.id);
    _queue.add(job);
    _scopeJobs.putIfAbsent(request.scope.id, () => {}).add(request.id);
    if (request.parentJobId != null) {
      _children.putIfAbsent(request.parentJobId!, () => {}).add(request.id);
      _childRequirements[request.id] = request.childRequirement;
      _childOutcomes[request.id] = Completer<JobOutcome>();
    }
    _pump();
    return completer.future;
  }

  /// Cancels queued/running work and recursively propagates to children.
  bool cancelJob(JobId id, [String? reason]) {
    final queued = _queue.where((job) => job.id == id).firstOrNull;
    if (queued != null) {
      _queue.remove(queued);
      queued.controller.cancel(reason);
      queued.completeCancelled(JobOutcome.cancelled);
      _parentRunnerCompleted(id);
      _cancelChildren(id, reason);
      _cleanup(queued, JobOutcome.cancelled);
      _pump();
      return true;
    }
    final running = _running[id];
    if (running == null) return false;
    final won = running.controller.cancel(reason);
    _cancelChildren(id, reason);
    return won;
  }

  /// Cancels every Job currently indexed to [scope].
  void cancelScope(JobScopeId scope, [String? reason]) {
    for (final id in List<JobId>.of(_scopeJobs[scope] ?? const {})) {
      cancelJob(id, reason);
    }
  }

  /// Applies deterministic lifecycle degradation to queued work.
  void setLifecycle(JobLifecycleState state) {
    _lifecycle = state;
    if (state == JobLifecycleState.memoryPressure ||
        state == JobLifecycleState.closing ||
        state == JobLifecycleState.safeMode ||
        state == JobLifecycleState.suspended) {
      final cancelled = _queue
          .where(
            (job) =>
                job.schedulingClass == SchedulingClass.opportunistic ||
                (state != JobLifecycleState.memoryPressure &&
                    job.schedulingClass ==
                        SchedulingClass.backgroundMaintenance),
          )
          .toList();
      for (final job in cancelled) {
        _queue.remove(job);
        job.controller.cancel('lifecycle');
        job.completeCancelled(JobOutcome.cancelled);
        _cleanup(job, JobOutcome.cancelled);
      }
    }
    _pump();
  }

  void _pump() {
    final expired = _queue.where(_expired).toList();
    for (final job in expired) {
      _queue.remove(job);
      job.completeCancelled(JobOutcome.cancelled);
      _cleanup(job, JobOutcome.cancelled);
    }
    while (_running.length < limits.globalRunning) {
      final job = _select();
      if (job == null) break;
      if (!_reserve(job)) {
        // _select filters this path; retain defensive containment.
        break;
      }
      _queue.remove(job);
      _running[job.id] = job;
      unawaited(
        job.run(this).whenComplete(() {
          _running.remove(job.id);
          if (!_releasedForJoin.remove(job.id)) _release(job);
          final outcome = job.terminalOutcome;
          _cleanup(job, outcome);
          _pump();
        }),
      );
    }
  }

  _QueuedJob? _select() {
    final admissible = _queue
        .where((job) => !_expired(job))
        .where(_canReserve)
        .where(
          (job) =>
              _lifecycle == JobLifecycleState.foreground ||
              (job.schedulingClass != SchedulingClass.opportunistic &&
                  job.schedulingClass != SchedulingClass.backgroundMaintenance),
        )
        .where((job) {
          if (job.schedulingClass == SchedulingClass.persistenceCritical)
            return true;
          final ordinaryRunning = _running.values
              .where(
                (running) =>
                    running.schedulingClass !=
                    SchedulingClass.persistenceCritical,
              )
              .length;
          return ordinaryRunning <
              limits.globalRunning - limits.reservedPersistenceSlots;
        })
        .where(
          (job) =>
              job.scope.sessionKey == null ||
              _running.values
                      .where(
                        (running) =>
                            running.scope.sessionKey == job.scope.sessionKey,
                      )
                      .length <
                  limits.perSessionRunning,
        )
        .toList();
    if (admissible.isEmpty) return null;
    final persistence = admissible
        .where(
          (job) => job.schedulingClass == SchedulingClass.persistenceCritical,
        )
        .toList();
    final ordinaryCapacity =
        limits.globalRunning - limits.reservedPersistenceSlots;
    final pool = persistence.isNotEmpty && _running.length >= ordinaryCapacity
        ? persistence
        : admissible;
    final priority = pool
        .map((job) => job.schedulingClass.index)
        .reduce((left, right) => left < right ? left : right);
    final classJobs = pool
        .where((job) => job.schedulingClass.index == priority)
        .toList();
    final sessions =
        classJobs.map((job) => job.scope.sessionKey ?? '').toSet().toList()
          ..sort();
    _roundRobinIndex %= sessions.length;
    final selectedSession = sessions[_roundRobinIndex++];
    return classJobs
        .where((job) => (job.scope.sessionKey ?? '') == selectedSession)
        .reduce((left, right) => left.sequence < right.sequence ? left : right);
  }

  bool _resourcesKnownAndBounded(JobResourceEstimate estimate) {
    for (final entry in estimate.units.entries) {
      final capacity = limits.resourceUnits[entry.key];
      if (capacity == null || entry.value > capacity) return false;
    }
    return true;
  }

  bool _canReserve(_QueuedJob job) {
    for (final entry in job.resources.units.entries) {
      final current = _reserved[entry.key] ?? 0;
      final capacity = limits.resourceUnits[entry.key] ?? 0;
      if (current > 9007199254740991 - entry.value ||
          current + entry.value > capacity) {
        return false;
      }
    }
    return true;
  }

  bool _reserve(_QueuedJob job) {
    if (!_canReserve(job)) return false;
    for (final entry in job.resources.units.entries) {
      _reserved[entry.key] = (_reserved[entry.key] ?? 0) + entry.value;
    }
    return true;
  }

  void _release(_QueuedJob job) {
    for (final entry in job.resources.units.entries) {
      final value = (_reserved[entry.key] ?? 0) - entry.value;
      if (value <= 0) {
        _reserved.remove(entry.key);
      } else {
        _reserved[entry.key] = value;
      }
    }
  }

  void _releaseForChildJoin(_QueuedJob job) {
    if (_running.remove(job.id) != null) {
      _release(job);
      _releasedForJoin.add(job.id);
      _pump();
    }
  }

  Result<void, StructuredFailure> _revalidate(_QueuedJob job) {
    try {
      return admissionController.validate(
        requiredCapabilities: job.requiredCapabilities,
        evidence: job.admissionEvidence,
      );
    } on Object {
      return Err(_failure('admission_failure'));
    }
  }

  Result<void, StructuredFailure> _initialAdmission<T, R, S>(
    JobRequest<T, R, S> request,
  ) {
    try {
      return admissionController.validate(
        requiredCapabilities: request.requiredCapabilities,
        evidence: request.admissionEvidence,
      );
    } on Object {
      return Err(_failure('admission_failure'));
    }
  }

  bool _expired(_QueuedJob job) => _expiredRequest(job.expiresAtUtc);
  int _maximumTotalAttempts() => limits.maximumRetryAttempts == 9007199254740991
      ? 9007199254740991
      : limits.maximumRetryAttempts + 1;

  bool _expiredRequest(DateTime? expiry) {
    if (expiry == null) return false;
    try {
      return !clock.nowUtc().isBefore(expiry);
    } on Object {
      return true;
    }
  }

  void _progress(_QueuedJob job, JobProgress progress) {
    if (!_running.containsKey(job.id)) return;
    final count = _progressCounts[job.id] ?? 0;
    final immediateLimit =
        job.progressPolicy.coalesce && job.progressPolicy.maximumEvents > 0
        ? job.progressPolicy.maximumEvents - 1
        : job.progressPolicy.maximumEvents;
    if (count >= immediateLimit) {
      if (job.progressPolicy.coalesce && job.progressPolicy.maximumEvents > 0) {
        _coalescedProgress[job.id] = progress;
      }
      return;
    }
    _progressCounts[job.id] = count + 1;
    for (final listener in List<JobProgressListener>.of(_progressListeners)) {
      try {
        listener(job.id, progress);
      } on Object {
        // Listener exceptions are isolated.
      }
    }
  }

  void _cancelChildren(JobId parent, String? reason) {
    for (final child in List<JobId>.of(_children[parent] ?? const {})) {
      cancelJob(child, reason);
    }
  }

  void _parentRunnerCompleted(JobId parent) => _parentsDone.add(parent);

  Future<_ChildState> _joinRequiredChildren(JobId parent) async {
    final children = List<JobId>.of(_children[parent] ?? const {});
    var requiredFailure = false;
    var optionalFailure = false;
    for (final child in children) {
      final outcome = await _childOutcomes[child]!.future;
      if (outcome != JobOutcome.completed) {
        if (_childRequirements[child] == ChildRequirement.required) {
          requiredFailure = true;
        } else {
          optionalFailure = true;
        }
      }
    }
    return _ChildState(requiredFailure, optionalFailure);
  }

  void _cleanup(_QueuedJob job, JobOutcome outcome) {
    final retained = _coalescedProgress.remove(job.id);
    if (retained != null &&
        (_progressCounts[job.id] ?? 0) < job.progressPolicy.maximumEvents) {
      _publishProgress(job.id, retained);
    }
    final scopeSet = _scopeJobs[job.scope.id];
    scopeSet?.remove(job.id);
    if (scopeSet?.isEmpty ?? false) _scopeJobs.remove(job.scope.id);
    final childOutcome = _childOutcomes[job.id];
    if (childOutcome != null && !childOutcome.isCompleted) {
      childOutcome.complete(outcome);
    }
    _parentsDone.add(job.id);
    final ownedChildren = _children[job.id] ?? const <JobId>{};
    final incomplete = ownedChildren
        .map((child) => _childOutcomes[child])
        .whereType<Completer<JobOutcome>>()
        .where((outcome) => !outcome.isCompleted)
        .toList();
    if (incomplete.isEmpty) {
      _removeChildEvidence(job.id, ownedChildren);
    } else {
      unawaited(
        Future.wait(
          incomplete.map((outcome) => outcome.future),
        ).whenComplete(() => _removeChildEvidence(job.id, ownedChildren)),
      );
    }
    _progressCounts.remove(job.id);
  }

  void _removeChildEvidence(JobId parent, Set<JobId> children) {
    if (!identical(_children[parent], children)) return;
    _children.remove(parent);
    for (final child in children) {
      _childOutcomes.remove(child);
      _childRequirements.remove(child);
    }
  }

  void _publishProgress(JobId id, JobProgress progress) {
    _progressCounts[id] = (_progressCounts[id] ?? 0) + 1;
    for (final listener in List<JobProgressListener>.of(_progressListeners)) {
      try {
        listener(id, progress);
      } on Object {
        /* isolated */
      }
    }
  }
}

final class _Present<T> {
  const _Present(this.value);
  final T value;
}

final class _ChildState {
  const _ChildState(this.requiredFailure, this.optionalFailure);
  final bool requiredFailure;
  final bool optionalFailure;
}

JobResult<R> _failed<R>(JobId id, StructuredFailure failure, int attempts) =>
    JobResult(
      jobId: id,
      outcome: JobOutcome.failed,
      completeness: JobCompleteness.partial,
      degradation: JobDegradation.degraded,
      freshness: JobFreshness.requiresValidation,
      publication: JobPublication.unpublished,
      value: null,
      failure: failure,
      attempts: attempts,
    );

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'core.jobs.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The Job operation could not be completed.',
);

Map<K, V>? _boundedSchedulerMap<K, V>(Map<K, V> source, int maximum) {
  try {
    final captured = <K, V>{};
    final iterator = source.entries.iterator;
    while (iterator.moveNext()) {
      if (captured.length >= maximum) return null;
      final entry = iterator.current;
      final key = entry.key;
      final value = entry.value;
      if (captured.containsKey(key)) return null;
      captured[key] = value;
    }
    return Map.unmodifiable(captured);
  } on Object {
    return null;
  }
}
