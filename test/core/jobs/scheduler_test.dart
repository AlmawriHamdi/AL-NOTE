// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:al_note/core/jobs.dart';
import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/controllable_clock.dart';
import '../../support/document_model_test_support.dart';
import '../../support/phase5_test_support.dart';

T ok<T>(Result<T, StructuredFailure> value) =>
    (value as Ok<T, StructuredFailure>).value;

void main() {
  test('zero retry limit permits exactly one initial attempt', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    var runs = 0;
    final kind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.zero_retry',
          {SchedulingClass.userVisible},
          (value, context) async {
            runs += 1;
            return value;
          },
        ),
      ),
    );
    final result = await _schedulerWithRetryLimit(
      registry,
      0,
    ).submit(_retryRequest(kind, 1, maximumAttempts: 1, transient: false));
    expect(result.outcome, JobOutcome.completed);
    expect(result.attempts, 1);
    expect(runs, 1);
  });

  test('retry ceiling counts retries after the initial invocation', () async {
    for (final retryLimit in [1, 2]) {
      final registry = JobRegistry(maximumSchedulingClasses: 16);
      var runs = 0;
      final kind = ok(
        registry.register<int, int, String>(
          _ControlledKind(
            'alnote.jobs.retry_$retryLimit',
            {SchedulingClass.userVisible},
            (value, context) async {
              runs += 1;
              if (runs <= retryLimit) throw StateError('retry');
              return value;
            },
            supportsRetry: true,
          ),
        ),
      );
      final result = await _schedulerWithRetryLimit(registry, retryLimit)
          .submit(
            _retryRequest(
              kind,
              2 + retryLimit,
              maximumAttempts: retryLimit + 1,
              transient: true,
            ),
          );
      expect(result.outcome, JobOutcome.completed);
      expect(result.attempts, retryLimit + 1);
      expect(runs, retryLimit + 1);
    }
  });

  test('attempt ceiling beyond retry policy rejects before runner', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    var runs = 0;
    final kind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.retry_rejected',
          {SchedulingClass.userVisible},
          (value, context) async {
            runs += 1;
            return value;
          },
          supportsRetry: true,
        ),
      ),
    );
    final result = await _schedulerWithRetryLimit(
      registry,
      1,
    ).submit(_retryRequest(kind, 5, maximumAttempts: 3, transient: true));
    expect(result.outcome, JobOutcome.failed);
    expect(result.attempts, 0);
    expect(runs, 0);
  });

  test('failed retry reports exact total attempt count', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final kind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.retry_failure',
          {SchedulingClass.userVisible},
          (value, context) async => throw StateError('failure'),
          supportsRetry: true,
        ),
      ),
    );
    final result = await _schedulerWithRetryLimit(
      registry,
      1,
    ).submit(_retryRequest(kind, 6, maximumAttempts: 2, transient: true));
    expect(result.outcome, JobOutcome.failed);
    expect(result.attempts, 2);
  });

  test('transient non-idempotent request is structurally rejected', () {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final kind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.non_idempotent_retry',
          {SchedulingClass.userVisible},
          (value, context) async => value,
          supportsRetry: true,
        ),
      ),
    );
    expect(
      JobRequest.create<int, int, String>(
        maximumRequiredCapabilities: 16,
        id: JobId.fromUuid(testUuid(7)),
        kind: kind,
        scope: ok(
          JobScope.create(
            id: JobScopeId.fromUuid(testUuid(107)),
            kind: JobScopeKind.application,
            depth: 0,
          ),
        ),
        input: 1,
        schedulingClass: SchedulingClass.userVisible,
        resources: ok(
          JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
        ),
        requiredCapabilities: const [],
        admissionEvidence: _evidence(),
        progressPolicy: ok(
          JobProgressPolicy.create(maximumEvents: 0, coalesce: false),
        ),
        retryClassification: JobRetryClassification.transient,
        idempotency: JobIdempotency.nonIdempotent,
        maximumAttempts: 2,
      ),
      isA<Err<JobRequest<int, int, String>, StructuredFailure>>(),
    );
  });
  test('late persistence work can use reserved capacity', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final gate = Completer<int>();
    var ordinaryStarts = 0;
    var persistenceStarts = 0;
    final ordinary = ok(
      registry.register<int, int, String>(
        _ControlledKind('alnote.jobs.ordinary', {SchedulingClass.userVisible}, (
          value,
          context,
        ) {
          ordinaryStarts += 1;
          return ordinaryStarts == 1 ? gate.future : Future.value(value);
        }),
      ),
    );
    final persistence = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.persistence',
          {SchedulingClass.persistenceCritical},
          (value, context) async {
            persistenceStarts += 1;
            return value;
          },
        ),
      ),
    );
    final limits = ok(
      JobSchedulerLimits.create(
        maximumResourceCategories: 16,
        maximumProgressListeners: 16,
        globalQueued: 4,
        globalRunning: 2,
        perSessionQueued: 4,
        perSessionRunning: 2,
        reservedPersistenceSlots: 1,
        maximumScopeDepth: 2,
        maximumChildren: 2,
        maximumRetryAttempts: 1,
        resourceUnits: const {'cpu': 2},
      ),
    );
    final scheduler = ok(
      JobScheduler.create(
        clock: ControllableClock(DateTime.utc(2026)),
        limits: limits,
        registry: registry,
        admissionController: _Admission(),
      ),
    );
    final first = scheduler.submit(
      _classifiedRequest(ordinary, 30, SchedulingClass.userVisible),
    );
    final second = scheduler.submit(
      _classifiedRequest(ordinary, 31, SchedulingClass.userVisible),
    );
    await Future<void>.microtask(() {});
    expect(ordinaryStarts, 1);
    final durable = await scheduler.submit(
      _classifiedRequest(persistence, 32, SchedulingClass.persistenceCritical),
    );
    expect(durable.outcome, JobOutcome.completed);
    expect(persistenceStarts, 1);
    gate.complete(1);
    await first;
    await second;
  });

  test('nullable normalized input preserves present null', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final kind = ok(registry.register<int?, String, String>(_NullableKind()));
    final scheduler = _scheduler(registry);
    final request = ok(
      JobRequest.create<int?, String, String>(
        maximumRequiredCapabilities: 16,
        id: JobId.fromUuid(testUuid(20)),
        kind: kind,
        scope: ok(
          JobScope.create(
            id: JobScopeId.fromUuid(testUuid(21)),
            kind: JobScopeKind.application,
            depth: 0,
          ),
        ),
        input: 1,
        schedulingClass: SchedulingClass.userVisible,
        resources: ok(
          JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
        ),
        requiredCapabilities: const [],
        admissionEvidence: _evidence(),
        progressPolicy: ok(
          JobProgressPolicy.create(maximumEvents: 1, coalesce: false),
        ),
        retryClassification: JobRetryClassification.never,
        idempotency: JobIdempotency.nonIdempotent,
        maximumAttempts: 1,
      ),
    );
    expect((await scheduler.submit(request)).value, 'null');
  });

  test('throwing initial admission and clock become failed results', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final kind = ok(registry.register<int, int, String>(_Kind()));
    final limits = ok(
      JobSchedulerLimits.create(
        maximumResourceCategories: 16,
        maximumProgressListeners: 16,
        globalQueued: 2,
        globalRunning: 1,
        perSessionQueued: 2,
        perSessionRunning: 1,
        reservedPersistenceSlots: 0,
        maximumScopeDepth: 2,
        maximumChildren: 1,
        maximumRetryAttempts: 1,
        resourceUnits: const {'cpu': 1},
      ),
    );
    final admissionScheduler = ok(
      JobScheduler.create(
        clock: ControllableClock(DateTime.utc(2026)),
        limits: limits,
        registry: registry,
        admissionController: _ThrowAdmission(),
      ),
    );
    expect(
      (await admissionScheduler.submit(_requestWithId(kind, 22))).outcome,
      JobOutcome.failed,
    );
    final clockScheduler = ok(
      JobScheduler.create(
        clock: _ThrowClock(),
        limits: limits,
        registry: registry,
        admissionController: _Admission(),
      ),
    );
    final expiring = _requestWithId(kind, 23, expiresAtUtc: DateTime.utc(2027));
    expect((await clockScheduler.submit(expiring)).outcome, JobOutcome.failed);
  });

  test('completed Job IDs remain unavailable for scheduler lifetime', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final kind = ok(registry.register<int, int, String>(_Kind()));
    final scheduler = _scheduler(registry);
    final request = _requestWithId(kind, 24);
    expect((await scheduler.submit(request)).outcome, JobOutcome.completed);
    expect((await scheduler.submit(request)).outcome, JobOutcome.failed);
  });

  test('progress coalescing emits first and latest within ceiling', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final kind = ok(registry.register<int, int, String>(_ProgressKind()));
    final scheduler = _scheduler(registry);
    final values = <int>[];
    scheduler.addProgressListener(
      (id, progress) => values.add(progress.completedUnits),
    );
    await scheduler.submit(_requestWithId(kind, 25));
    expect(values, [1, 3]);
  });

  test('progress reported after terminal completion is ignored', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final source = _LateProgressKind();
    final kind = ok(registry.register<int, int, String>(source));
    final scheduler = _scheduler(registry);
    final values = <int>[];
    scheduler.addProgressListener(
      (id, progress) => values.add(progress.completedUnits),
    );
    expect(
      (await scheduler.submit(_requestWithId(kind, 26))).outcome,
      JobOutcome.completed,
    );
    source.report!(ok(JobProgress.create(phase: 'late', completedUnits: 1)));
    expect(values, isEmpty);
  });

  test(
    'required child failure fails parent without retrying its runner',
    () async {
      final registry = JobRegistry(maximumSchedulingClasses: 16);
      final releaseParent = Completer<void>();
      var parentRuns = 0;
      final parentKind = ok(
        registry.register<int, int, String>(
          _ControlledKind('alnote.jobs.parent', {SchedulingClass.userVisible}, (
            value,
            context,
          ) async {
            parentRuns += 1;
            await releaseParent.future;
            return value;
          }, supportsRetry: true),
        ),
      );
      final childKind = ok(
        registry.register<int, int, String>(
          _ControlledKind('alnote.jobs.child', {
            SchedulingClass.userVisible,
          }, (value, context) async => throw StateError('child')),
        ),
      );
      final scheduler = _scheduler(registry);
      final parent = _parentRequest(parentKind, 40);
      final parentFuture = scheduler.submit(parent);
      final childFuture = scheduler.submit(
        _childRequest(childKind, 41, parent.id, ChildRequirement.required),
      );
      releaseParent.complete();
      expect((await childFuture).outcome, JobOutcome.failed);
      expect((await parentFuture).outcome, JobOutcome.failed);
      expect(parentRuns, 1);
      expect(
        (await scheduler.submit(
          _childRequest(childKind, 41, parent.id, ChildRequirement.required),
        )).outcome,
        JobOutcome.failed,
      );
    },
  );

  test('optional child failure degrades successful parent', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final releaseParent = Completer<void>();
    final parentKind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.optional_parent',
          {SchedulingClass.userVisible},
          (value, context) async {
            await releaseParent.future;
            return value;
          },
        ),
      ),
    );
    final childKind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.optional_child',
          {SchedulingClass.userVisible},
          (value, context) async => throw StateError('child'),
        ),
      ),
    );
    final scheduler = _scheduler(registry);
    final parent = _parentRequest(parentKind, 42);
    final parentFuture = scheduler.submit(parent);
    final childFuture = scheduler.submit(
      _childRequest(childKind, 43, parent.id, ChildRequirement.optional),
    );
    releaseParent.complete();
    expect((await childFuture).outcome, JobOutcome.failed);
    final result = await parentFuture;
    expect(result.outcome, JobOutcome.completed);
    expect(result.degradation, JobDegradation.degraded);
  });

  test('failing parent cancels and joins a running child', () async {
    final registry = JobRegistry(maximumSchedulingClasses: 16);
    final releaseParent = Completer<void>();
    final childStarted = Completer<void>();
    final childCancelled = Completer<int>();
    final parentKind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.failing_parent',
          {SchedulingClass.userVisible},
          (value, context) async {
            await releaseParent.future;
            throw StateError('parent');
          },
        ),
      ),
    );
    final childKind = ok(
      registry.register<int, int, String>(
        _ControlledKind(
          'alnote.jobs.running_child',
          {SchedulingClass.userVisible},
          (value, context) {
            childStarted.complete();
            context.cancellationToken.addListener((_) {
              if (!childCancelled.isCompleted) childCancelled.complete(value);
            });
            return childCancelled.future;
          },
        ),
      ),
    );
    final scheduler = _scheduler(registry);
    final parent = _parentRequest(parentKind, 44);
    final parentFuture = scheduler.submit(parent);
    final childFuture = scheduler.submit(
      _childRequest(childKind, 45, parent.id, ChildRequirement.required),
    );
    await childStarted.future;
    releaseParent.complete();
    expect((await childFuture).outcome, JobOutcome.cancelled);
    expect((await parentFuture).outcome, JobOutcome.failed);
  });

  test(
    'scheduler limits reject zero running and unknown arithmetic shapes',
    () {
      expect(
        JobSchedulerLimits.create(
          maximumResourceCategories: 16,
          maximumProgressListeners: 16,
          globalQueued: 1,
          globalRunning: 0,
          perSessionQueued: 1,
          perSessionRunning: 1,
          reservedPersistenceSlots: 0,
          maximumScopeDepth: 1,
          maximumChildren: 1,
          maximumRetryAttempts: 1,
          resourceUnits: const {'cpu': 1},
        ),
        isA<Err<JobSchedulerLimits, StructuredFailure>>(),
      );
    },
  );

  test(
    'registry rejects duplicates and scheduler runs normalized input',
    () async {
      final registry = JobRegistry(maximumSchedulingClasses: 16);
      final source = _Kind();
      final kind = ok(registry.register<int, int, String>(source));
      expect(
        registry.register<int, int, String>(source),
        isA<Err<Object?, StructuredFailure>>(),
      );
      final scheduler = _scheduler(registry);
      final result = await scheduler.submit(_request(kind, 3));
      expect(result.value, 8);
      expect(result.publication, JobPublication.unpublished);
    },
  );

  test(
    'unregistered handles and duplicate ids reject without runner side effects',
    () async {
      final owner = JobRegistry(maximumSchedulingClasses: 16);
      final foreign = JobRegistry(maximumSchedulingClasses: 16);
      final kind = ok(foreign.register<int, int, String>(_Kind()));
      final scheduler = _scheduler(owner);
      expect(
        (await scheduler.submit(_request(kind, 1))).outcome,
        JobOutcome.failed,
      );
    },
  );

  test(
    'factories reject malformed scope, resources, progress, and evidence',
    () {
      expect(
        JobScope.create(
          id: JobScopeId.fromUuid(testUuid(1)),
          kind: JobScopeKind.view,
          depth: 0,
        ),
        isA<Err<JobScope, StructuredFailure>>(),
      );
      expect(
        JobResourceEstimate.create({'CPU': 1}, maximumCategories: 1),
        isA<Err<JobResourceEstimate, StructuredFailure>>(),
      );
      expect(
        JobProgressPolicy.create(maximumEvents: -1, coalesce: true),
        isA<Err<JobProgressPolicy, StructuredFailure>>(),
      );
      expect(
        JobAdmissionEvidence.create(
          capabilities: const ['secret'],
          securityGeneration: 0,
          maximumCapabilities: 1,
        ),
        isA<Err<JobAdmissionEvidence, StructuredFailure>>(),
      );
    },
  );

  test(
    'invalid and throwing validators never invoke admission or reserve IDs',
    () async {
      final admission = _AdmissionSpy();
      final registry = JobRegistry(maximumSchedulingClasses: 1);
      final invalid = ok(
        registry.register<int, int, String>(
          _ValidationKind(
            'alnote.jobs.invalid_input',
            (_) => Err(_testFailure('invalid')),
          ),
        ),
      );
      final throwing = ok(
        registry.register<int, int, String>(
          _ValidationKind(
            'alnote.jobs.throwing_input',
            (_) => throw StateError('sensitive input'),
          ),
        ),
      );
      final valid = ok(
        registry.register<int, int, String>(
          _ValidationKind('alnote.jobs.valid_input', (value) => Ok(value + 1)),
        ),
      );
      final scheduler = _schedulerWithAdmission(registry, admission);
      expect(
        (await scheduler.submit(_requestWithId(invalid, 940))).outcome,
        JobOutcome.failed,
      );
      expect(
        (await scheduler.submit(_requestWithId(throwing, 941))).outcome,
        JobOutcome.failed,
      );
      expect(admission.calls, 0);
      final accepted = await scheduler.submit(_requestWithId(valid, 940));
      expect(accepted.outcome, JobOutcome.completed);
      expect(accepted.value, 4);
      expect(admission.calls, 2);
    },
  );

  test('validation precedes clock and expiry precedes admission', () async {
    final expiry = DateTime.utc(2027);
    var foreignValidatorCalls = 0;
    final ownerRegistry = JobRegistry(maximumSchedulingClasses: 1);
    final foreignRegistry = JobRegistry(maximumSchedulingClasses: 1);
    final foreignKind = ok(
      foreignRegistry.register<int, int, String>(
        _ValidationKind('alnote.jobs.foreign_preclock', (_) {
          foreignValidatorCalls += 1;
          throw StateError('secret foreign validator');
        }),
      ),
    );
    final foreignClock = _CountingClock(DateTime.utc(2026));
    final foreignAdmission = _AdmissionSpy();
    expect(
      (await _schedulerWithClockAdmission(
        ownerRegistry,
        foreignAdmission,
        foreignClock,
      ).submit(_requestWithId(foreignKind, 969, expiresAtUtc: expiry))).outcome,
      JobOutcome.failed,
    );
    expect(foreignValidatorCalls, 0);
    expect(foreignClock.calls, 0);
    expect(foreignAdmission.calls, 0);

    for (final validation in <JobInputValidator<int>>[
      (_) => Err(_testFailure('invalid secret input 731')),
      (_) => throw StateError('secret validator text 731'),
    ]) {
      final clock = _CountingClock(DateTime.utc(2026));
      final admission = _AdmissionSpy();
      final registry = JobRegistry(maximumSchedulingClasses: 1);
      final kind = ok(
        registry.register<int, int, String>(
          _ValidationKind('alnote.jobs.preclock_${clock.hashCode}', validation),
        ),
      );
      final scheduler = _schedulerWithClockAdmission(
        registry,
        admission,
        clock,
      );
      final result = await scheduler.submit(
        _requestWithId(kind, 970, expiresAtUtc: expiry),
      );
      expect(result.outcome, JobOutcome.failed);
      expect(result.failure.toString(), isNot(contains('731')));
      expect(result.failure.toString(), isNot(contains('secret')));
      expect(clock.calls, 0);
      expect(admission.calls, 0);
    }

    final validClock = _CountingClock(DateTime.utc(2026));
    late _AdmissionSpy validAdmission;
    validAdmission = _AdmissionSpy(
      onValidate: () {
        if (validAdmission.calls == 1) expect(validClock.calls, 1);
      },
    );
    final validRegistry = JobRegistry(maximumSchedulingClasses: 1);
    var normalizedRunInput = -1;
    final validKind = ok(
      validRegistry.register<int, int, String>(
        _ValidationKind(
          'alnote.jobs.preclock_valid',
          (value) => Ok(value + 4),
          onRun: (value) => normalizedRunInput = value,
        ),
      ),
    );
    final validScheduler = _schedulerWithClockAdmission(
      validRegistry,
      validAdmission,
      validClock,
    );
    final validResult = await validScheduler.submit(
      _requestWithId(validKind, 971, expiresAtUtc: expiry),
    );
    expect(validResult.outcome, JobOutcome.completed);
    expect(normalizedRunInput, 7);

    final expiredClock = _CountingClock(DateTime.utc(2028));
    final expiredAdmission = _AdmissionSpy();
    final expiredRegistry = JobRegistry(maximumSchedulingClasses: 1);
    final expiredKind = ok(
      expiredRegistry.register<int, int, String>(
        _ValidationKind('alnote.jobs.preclock_expired', Ok.new),
      ),
    );
    final expiredScheduler = _schedulerWithClockAdmission(
      expiredRegistry,
      expiredAdmission,
      expiredClock,
    );
    final expiredResult = await expiredScheduler.submit(
      _requestWithId(expiredKind, 972, expiresAtUtc: expiry),
    );
    expect(expiredResult.outcome, JobOutcome.failed);
    expect(expiredClock.calls, 1);
    expect(expiredAdmission.calls, 0);
    expect(
      (await expiredScheduler.submit(_requestWithId(expiredKind, 972))).outcome,
      JobOutcome.completed,
    );
  });

  test(
    'denied admission publishes no normalized input and reserves no Job ID',
    () async {
      final admission = _AdmissionSpy()..allow = false;
      final registry = JobRegistry(maximumSchedulingClasses: 1);
      var runs = 0;
      final kind = ok(
        registry.register<int, int, String>(
          _ValidationKind(
            'alnote.jobs.denied_input',
            (value) => Ok(value + 10),
            onRun: (_) => runs += 1,
          ),
        ),
      );
      final scheduler = _schedulerWithAdmission(registry, admission);
      expect(
        (await scheduler.submit(_requestWithId(kind, 950))).outcome,
        JobOutcome.failed,
      );
      expect(runs, 0);
      admission.allow = true;
      final accepted = await scheduler.submit(_requestWithId(kind, 950));
      expect(accepted.outcome, JobOutcome.completed);
      expect(accepted.value, 13);
      expect(runs, 1);
      expect(
        (await scheduler.submit(_requestWithId(kind, 950))).outcome,
        JobOutcome.failed,
      );
    },
  );

  test('Job capability collection stops before an infinite rejected tail', () {
    final source = _InfiniteCapabilities();
    expect(
      JobAdmissionEvidence.create(
        capabilities: source,
        securityGeneration: 0,
        maximumCapabilities: 2,
      ),
      isA<Err<JobAdmissionEvidence, StructuredFailure>>(),
    );
    expect(source.moveNextCalls, 3);
    expect(source.currentReads, 2);

    for (final exact in <Iterable<String>>[
      HostileList(const [
        'alnote.platform.one',
        'alnote.platform.two',
      ], reportedLength: 0),
      HostileList(const [
        'alnote.platform.one',
        'alnote.platform.two',
      ], reportedLength: 999),
      ThrowingLengthList(const ['alnote.platform.one', 'alnote.platform.two']),
    ]) {
      expect(
        JobAdmissionEvidence.create(
          capabilities: exact,
          securityGeneration: 0,
          maximumCapabilities: 2,
        ),
        isA<Ok<JobAdmissionEvidence, StructuredFailure>>(),
      );
    }
    for (final hostile in <Iterable<String>>[
      IteratorCreationThrowingValues(),
      ThrowingValues(),
      CurrentThrowingValues(),
    ]) {
      expect(
        JobAdmissionEvidence.create(
          capabilities: hostile,
          securityGeneration: 0,
          maximumCapabilities: 2,
        ),
        isA<Err<JobAdmissionEvidence, StructuredFailure>>(),
      );
    }
    final finite = TrackingValues([
      'alnote.platform.one',
      'alnote.platform.two',
      'tail must not be read',
    ]);
    expect(
      JobAdmissionEvidence.create(
        capabilities: HostileList(finite, reportedLength: 0),
        securityGeneration: 0,
        maximumCapabilities: 2,
      ),
      isA<Err<JobAdmissionEvidence, StructuredFailure>>(),
    );
    expect(finite.moveNextCalls, 3);
    expect(finite.currentReads, 2);
  });

  test('Job maps and scheduling sets distrust reported collection lengths', () {
    final resourceEntries = InfiniteValues(const MapEntry('cpu', 1));
    expect(
      JobResourceEstimate.create(
        HostileMap(resourceEntries, reportedLength: 0),
        maximumCategories: 1,
      ),
      isA<Err<JobResourceEstimate, StructuredFailure>>(),
    );
    expect(resourceEntries.moveNextCalls, 2);
    expect(resourceEntries.currentReads, 1);
    expect(
      JobResourceEstimate.create(
        HostileMap(const [MapEntry('cpu', 1)], reportedLength: 0),
        maximumCategories: 1,
      ),
      isA<Ok<JobResourceEstimate, StructuredFailure>>(),
    );

    final scheduling = InfiniteValues(SchedulingClass.userVisible);
    expect(
      JobRegistry(maximumSchedulingClasses: 1).register<int, int, String>(
        _HostileKind(HostileSet(scheduling, reportedLength: 0)),
      ),
      isA<Err<RegisteredJobKind<int, int, String>, StructuredFailure>>(),
    );
    expect(scheduling.moveNextCalls, 2);
    expect(scheduling.currentReads, 1);

    final limitEntries = InfiniteValues(const MapEntry('cpu', 1));
    expect(
      JobSchedulerLimits.create(
        globalQueued: 1,
        globalRunning: 1,
        perSessionQueued: 1,
        perSessionRunning: 1,
        reservedPersistenceSlots: 0,
        maximumScopeDepth: 1,
        maximumChildren: 1,
        maximumRetryAttempts: 1,
        maximumProgressListeners: 1,
        maximumResourceCategories: 1,
        resourceUnits: HostileMap(limitEntries, reportedLength: 0),
      ),
      isA<Err<JobSchedulerLimits, StructuredFailure>>(),
    );
    expect(limitEntries.moveNextCalls, 2);
    expect(limitEntries.currentReads, 1);
    expect(
      JobResourceEstimate.create(
        HostileMap(ThrowingValues(), reportedLength: 0),
        maximumCategories: 1,
      ),
      isA<Err<JobResourceEstimate, StructuredFailure>>(),
    );
  });

  test('Job progress listener ceiling is exact and duplicate-safe', () {
    final registry = JobRegistry(maximumSchedulingClasses: 1);
    final scheduler = _schedulerWithAdmission(registry, _Admission());
    void listener(JobId _, JobProgress __) {}
    expect(
      scheduler.addProgressListener(listener),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(
      scheduler.addProgressListener(listener),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(
      scheduler.addProgressListener((_, _) {}),
      isA<Err<void, StructuredFailure>>(),
    );
    scheduler.removeProgressListener(listener);
    expect(
      scheduler.addProgressListener((_, _) {}),
      isA<Ok<void, StructuredFailure>>(),
    );
  });
}

final class _InfiniteCapabilities extends Iterable<String> {
  int moveNextCalls = 0;
  int currentReads = 0;
  @override
  Iterator<String> get iterator => _InfiniteCapabilityIterator(this);
}

final class _InfiniteCapabilityIterator implements Iterator<String> {
  _InfiniteCapabilityIterator(this.owner);
  final _InfiniteCapabilities owner;
  @override
  String get current {
    owner.currentReads += 1;
    return 'alnote.platform.capability';
  }

  @override
  bool moveNext() {
    owner.moveNextCalls += 1;
    return true;
  }
}

class _Kind implements JobKindSource<int, int, String> {
  @override
  String get identity => 'alnote.jobs.test';
  @override
  String get ownerSubsystem => 'test';
  @override
  String get payloadContractIdentity => 'test.int';
  @override
  Set<SchedulingClass> get permittedSchedulingClasses => {
    SchedulingClass.userVisible,
  };
  @override
  bool get supportsSupersession => false;
  @override
  bool get supportsRetry => false;
  @override
  bool get supportsPartialResults => false;
  @override
  bool get supportsDetachedExecution => false;
  @override
  JobInputValidator<int> get validator =>
      (value) => Ok(value + 1);
  @override
  JobRunner<int, int> get runner =>
      (value, context) async => value * 2;
}

final class _HostileKind extends _Kind {
  _HostileKind(this.classes);
  final Set<SchedulingClass> classes;
  @override
  String get identity => 'alnote.jobs.hostile_metadata';
  @override
  Set<SchedulingClass> get permittedSchedulingClasses => classes;
}

final class _NullableKind implements JobKindSource<int?, String, String> {
  @override
  String get identity => 'alnote.jobs.nullable';
  @override
  String get ownerSubsystem => 'test';
  @override
  String get payloadContractIdentity => 'test.nullable';
  @override
  Set<SchedulingClass> get permittedSchedulingClasses => {
    SchedulingClass.userVisible,
  };
  @override
  bool get supportsSupersession => false;
  @override
  bool get supportsRetry => false;
  @override
  bool get supportsPartialResults => false;
  @override
  bool get supportsDetachedExecution => false;
  @override
  JobInputValidator<int?> get validator =>
      (_) => const Ok(null);
  @override
  JobRunner<int?, String> get runner =>
      (value, context) async => value == null ? 'null' : 'value';
}

final class _ProgressKind extends _Kind {
  @override
  String get identity => 'alnote.jobs.progress';
  @override
  JobRunner<int, int> get runner => (value, context) async {
    for (var index = 1; index <= 3; index += 1) {
      context.reportProgress(
        ok(
          JobProgress.create(
            phase: 'work',
            completedUnits: index,
            totalUnits: 3,
          ),
        ),
      );
    }
    return value;
  };
}

final class _ControlledKind implements JobKindSource<int, int, String> {
  _ControlledKind(
    this.identity,
    this.permittedSchedulingClasses,
    this.runner, {
    this.supportsRetry = false,
  });
  @override
  final String identity;
  @override
  final Set<SchedulingClass> permittedSchedulingClasses;
  @override
  final JobRunner<int, int> runner;
  @override
  String get ownerSubsystem => 'test';
  @override
  String get payloadContractIdentity => 'test.controlled';
  @override
  bool get supportsSupersession => false;
  @override
  final bool supportsRetry;
  @override
  bool get supportsPartialResults => false;
  @override
  bool get supportsDetachedExecution => false;
  @override
  JobInputValidator<int> get validator => _accept;
  static Result<int, StructuredFailure> _accept(int value) => Ok(value);
}

final class _LateProgressKind extends _Kind {
  @override
  String get identity => 'alnote.jobs.late_progress';
  void Function(JobProgress)? report;
  @override
  JobRunner<int, int> get runner => (value, context) async {
    report = context.reportProgress;
    return value;
  };
}

final class _Admission implements JobAdmissionController {
  @override
  Result<void, StructuredFailure> validate({
    required List<String> requiredCapabilities,
    required JobAdmissionEvidence evidence,
  }) => const Ok(null);
}

final class _AdmissionSpy implements JobAdmissionController {
  _AdmissionSpy({this.onValidate});
  int calls = 0;
  bool allow = true;
  final void Function()? onValidate;
  @override
  Result<void, StructuredFailure> validate({
    required List<String> requiredCapabilities,
    required JobAdmissionEvidence evidence,
  }) {
    calls += 1;
    onValidate?.call();
    return allow ? const Ok(null) : Err(_testFailure('denied'));
  }
}

final class _ValidationKind implements JobKindSource<int, int, String> {
  _ValidationKind(this.identity, this.validation, {this.onRun});
  @override
  final String identity;
  final JobInputValidator<int> validation;
  final void Function(int value)? onRun;
  @override
  String get ownerSubsystem => 'test';
  @override
  String get payloadContractIdentity => 'test.validation';
  @override
  Set<SchedulingClass> get permittedSchedulingClasses => {
    SchedulingClass.userVisible,
  };
  @override
  bool get supportsSupersession => false;
  @override
  bool get supportsRetry => false;
  @override
  bool get supportsPartialResults => false;
  @override
  bool get supportsDetachedExecution => false;
  @override
  JobInputValidator<int> get validator => validation;
  @override
  JobRunner<int, int> get runner => (value, context) async {
    onRun?.call(value);
    return value;
  };
}

final class _ThrowAdmission implements JobAdmissionController {
  @override
  Result<void, StructuredFailure> validate({
    required List<String> requiredCapabilities,
    required JobAdmissionEvidence evidence,
  }) => throw StateError('secret');
}

final class _ThrowClock implements Clock {
  @override
  DateTime nowUtc() => throw StateError('secret');
}

final class _CountingClock implements Clock {
  _CountingClock(this.value);
  final DateTime value;
  int calls = 0;
  @override
  DateTime nowUtc() {
    calls += 1;
    return value;
  }
}

StructuredFailure _testFailure(String leaf) => StructuredFailure(
  code: 'test.jobs.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Test failure.',
);

JobScheduler _scheduler(JobRegistry registry) => ok(
  JobScheduler.create(
    clock: ControllableClock(DateTime.utc(2026)),
    registry: registry,
    admissionController: _Admission(),
    limits: ok(
      JobSchedulerLimits.create(
        maximumResourceCategories: 16,
        maximumProgressListeners: 16,
        globalQueued: 8,
        globalRunning: 2,
        perSessionQueued: 8,
        perSessionRunning: 2,
        reservedPersistenceSlots: 0,
        maximumScopeDepth: 4,
        maximumChildren: 4,
        maximumRetryAttempts: 2,
        resourceUnits: const {'cpu': 2},
      ),
    ),
  ),
);

JobScheduler _schedulerWithAdmission(
  JobRegistry registry,
  JobAdmissionController admission,
) => ok(
  JobScheduler.create(
    clock: ControllableClock(DateTime.utc(2026)),
    registry: registry,
    admissionController: admission,
    limits: ok(
      JobSchedulerLimits.create(
        maximumResourceCategories: 1,
        maximumProgressListeners: 1,
        globalQueued: 4,
        globalRunning: 1,
        perSessionQueued: 4,
        perSessionRunning: 1,
        reservedPersistenceSlots: 0,
        maximumScopeDepth: 4,
        maximumChildren: 1,
        maximumRetryAttempts: 0,
        resourceUnits: const {'cpu': 1},
      ),
    ),
  ),
);

JobScheduler _schedulerWithClockAdmission(
  JobRegistry registry,
  JobAdmissionController admission,
  Clock clock,
) => ok(
  JobScheduler.create(
    clock: clock,
    registry: registry,
    admissionController: admission,
    limits: ok(
      JobSchedulerLimits.create(
        maximumResourceCategories: 1,
        maximumProgressListeners: 1,
        globalQueued: 4,
        globalRunning: 1,
        perSessionQueued: 4,
        perSessionRunning: 1,
        reservedPersistenceSlots: 0,
        maximumScopeDepth: 4,
        maximumChildren: 1,
        maximumRetryAttempts: 0,
        resourceUnits: const {'cpu': 1},
      ),
    ),
  ),
);

JobScheduler _schedulerWithRetryLimit(JobRegistry registry, int retries) => ok(
  JobScheduler.create(
    clock: ControllableClock(DateTime.utc(2026)),
    registry: registry,
    admissionController: _Admission(),
    limits: ok(
      JobSchedulerLimits.create(
        maximumResourceCategories: 16,
        maximumProgressListeners: 16,
        globalQueued: 4,
        globalRunning: 1,
        perSessionQueued: 4,
        perSessionRunning: 1,
        reservedPersistenceSlots: 0,
        maximumScopeDepth: 2,
        maximumChildren: 1,
        maximumRetryAttempts: retries,
        resourceUnits: const {'cpu': 1},
      ),
    ),
  ),
);

JobRequest<int, int, String> _retryRequest(
  RegisteredJobKind<int, int, String> kind,
  int id, {
  required int maximumAttempts,
  required bool transient,
}) => ok(
  JobRequest.create<int, int, String>(
    maximumRequiredCapabilities: 16,
    id: JobId.fromUuid(testUuid(id)),
    kind: kind,
    scope: ok(
      JobScope.create(
        id: JobScopeId.fromUuid(testUuid(id + 100)),
        kind: JobScopeKind.application,
        depth: 0,
      ),
    ),
    input: 1,
    schedulingClass: SchedulingClass.userVisible,
    resources: ok(
      JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
    ),
    requiredCapabilities: const [],
    admissionEvidence: _evidence(),
    progressPolicy: ok(
      JobProgressPolicy.create(maximumEvents: 0, coalesce: false),
    ),
    retryClassification: transient
        ? JobRetryClassification.transient
        : JobRetryClassification.never,
    idempotency: transient
        ? JobIdempotency.idempotent
        : JobIdempotency.nonIdempotent,
    maximumAttempts: maximumAttempts,
  ),
);

JobRequest<int, int, String> _request(
  RegisteredJobKind<int, int, String> kind,
  int input,
) => ok(
  JobRequest.create<int, int, String>(
    maximumRequiredCapabilities: 16,
    id: JobId.fromUuid(testUuid(10)),
    kind: kind,
    scope: ok(
      JobScope.create(
        id: JobScopeId.fromUuid(testUuid(11)),
        kind: JobScopeKind.application,
        depth: 0,
      ),
    ),
    input: input,
    schedulingClass: SchedulingClass.userVisible,
    resources: ok(
      JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
    ),
    requiredCapabilities: const [],
    admissionEvidence: ok(
      JobAdmissionEvidence.create(
        capabilities: const [],
        securityGeneration: 0,
        maximumCapabilities: 0,
      ),
    ),
    progressPolicy: ok(
      JobProgressPolicy.create(maximumEvents: 2, coalesce: true),
    ),
    retryClassification: JobRetryClassification.never,
    idempotency: JobIdempotency.nonIdempotent,
    maximumAttempts: 1,
  ),
);

JobAdmissionEvidence _evidence() => ok(
  JobAdmissionEvidence.create(
    capabilities: const [],
    securityGeneration: 0,
    maximumCapabilities: 0,
  ),
);

JobRequest<T, R, String> _requestWithId<T, R>(
  RegisteredJobKind<T, R, String> kind,
  int id, {
  DateTime? expiresAtUtc,
}) => ok(
  JobRequest.create<T, R, String>(
    maximumRequiredCapabilities: 16,
    id: JobId.fromUuid(testUuid(id)),
    kind: kind,
    scope: ok(
      JobScope.create(
        id: JobScopeId.fromUuid(testUuid(id + 100)),
        kind: JobScopeKind.application,
        depth: 0,
      ),
    ),
    input: (3 as T),
    schedulingClass: SchedulingClass.userVisible,
    resources: ok(
      JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
    ),
    requiredCapabilities: const [],
    admissionEvidence: _evidence(),
    expiresAtUtc: expiresAtUtc,
    progressPolicy: ok(
      JobProgressPolicy.create(maximumEvents: 2, coalesce: true),
    ),
    retryClassification: JobRetryClassification.never,
    idempotency: JobIdempotency.nonIdempotent,
    maximumAttempts: 1,
  ),
);

JobRequest<int, int, String> _classifiedRequest(
  RegisteredJobKind<int, int, String> kind,
  int id,
  SchedulingClass schedulingClass,
) => ok(
  JobRequest.create<int, int, String>(
    maximumRequiredCapabilities: 16,
    id: JobId.fromUuid(testUuid(id)),
    kind: kind,
    scope: ok(
      JobScope.create(
        id: JobScopeId.fromUuid(testUuid(id + 200)),
        kind: JobScopeKind.application,
        depth: 0,
      ),
    ),
    input: 1,
    schedulingClass: schedulingClass,
    resources: ok(
      JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
    ),
    requiredCapabilities: const [],
    admissionEvidence: _evidence(),
    progressPolicy: ok(
      JobProgressPolicy.create(maximumEvents: 1, coalesce: false),
    ),
    retryClassification: JobRetryClassification.never,
    idempotency: JobIdempotency.nonIdempotent,
    maximumAttempts: 1,
  ),
);

JobRequest<int, int, String> _parentRequest(
  RegisteredJobKind<int, int, String> kind,
  int id,
) => ok(
  JobRequest.create<int, int, String>(
    maximumRequiredCapabilities: 16,
    id: JobId.fromUuid(testUuid(id)),
    kind: kind,
    scope: ok(
      JobScope.create(
        id: JobScopeId.fromUuid(testUuid(id + 300)),
        kind: JobScopeKind.application,
        depth: 0,
      ),
    ),
    input: 1,
    schedulingClass: SchedulingClass.userVisible,
    resources: ok(
      JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
    ),
    requiredCapabilities: const [],
    admissionEvidence: _evidence(),
    progressPolicy: ok(
      JobProgressPolicy.create(maximumEvents: 1, coalesce: false),
    ),
    retryClassification: kind.supportsRetry
        ? JobRetryClassification.transient
        : JobRetryClassification.never,
    idempotency: kind.supportsRetry
        ? JobIdempotency.idempotent
        : JobIdempotency.nonIdempotent,
    maximumAttempts: kind.supportsRetry ? 2 : 1,
  ),
);

JobRequest<int, int, String> _childRequest(
  RegisteredJobKind<int, int, String> kind,
  int id,
  JobId parent,
  ChildRequirement requirement,
) => ok(
  JobRequest.create<int, int, String>(
    maximumRequiredCapabilities: 16,
    id: JobId.fromUuid(testUuid(id)),
    kind: kind,
    scope: ok(
      JobScope.create(
        id: JobScopeId.fromUuid(testUuid(id + 300)),
        kind: JobScopeKind.parentJob,
        parent: JobScopeId.fromUuid(testUuid(id + 301)),
        depth: 1,
      ),
    ),
    input: 1,
    schedulingClass: SchedulingClass.userVisible,
    resources: ok(
      JobResourceEstimate.create(const {'cpu': 1}, maximumCategories: 1),
    ),
    requiredCapabilities: const [],
    admissionEvidence: _evidence(),
    progressPolicy: ok(
      JobProgressPolicy.create(maximumEvents: 1, coalesce: false),
    ),
    retryClassification: JobRetryClassification.never,
    idempotency: JobIdempotency.nonIdempotent,
    maximumAttempts: 1,
    parentJobId: parent,
    childRequirement: requirement,
  ),
);
