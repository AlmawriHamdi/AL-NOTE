// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/recovery.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/controllable_clock.dart';
import '../../support/document_model_test_support.dart';
import '../../support/phase5_test_support.dart';

T ok<T>(Result<T, StructuredFailure> value) =>
    (value as Ok<T, StructuredFailure>).value;

void main() {
  test('bad committed tail restores newest valid checkpoint prefix', () {
    var resourceChecks = 0;
    final record = _generation(
      tail: _transaction(resultHash: 99, resources: [_resource()]),
      committed: true,
      manifestLast: 1,
    );
    final outcome =
        RecoveryReconstructor<int>(
          codec: const _IntCodec(),
          validator: (_) => true,
          resourceValidator: (_) {
            resourceChecks += 1;
            return false;
          },
        ).reconstruct(
          [record],
          context: _context(record),
          maximumGenerations: 16,
          maximumCheckpointBytes: 10,
          maximumJournalBytes: 10,
          maximumSteps: 10,
          maximumResources: 0,
          cancellationToken: CancellationController().token,
        );
    final candidate =
        (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
            .value;
    expect(candidate.value, 1);
    expect(candidate.evidence.appliedTransactions, 0);
    expect(candidate.evidence.lostOrCorruptTail, isTrue);
    expect(candidate.evidence.usedFallbackGeneration, isFalse);
    expect(resourceChecks, 0);
  });

  test('incomplete tail and manifest disagreement preserve valid prefix', () {
    var resourceChecks = 0;
    final record = _generation(
      tail: _transaction(resultHash: 2, resources: [_resource()]),
      committed: false,
      manifestLast: 1,
    );
    final outcome =
        RecoveryReconstructor<int>(
          codec: const _IntCodec(),
          validator: (_) => true,
          resourceValidator: (_) {
            resourceChecks += 1;
            return false;
          },
        ).reconstruct(
          [record],
          context: _context(record),
          maximumGenerations: 16,
          maximumCheckpointBytes: 10,
          maximumJournalBytes: 10,
          maximumSteps: 10,
          maximumResources: 0,
          cancellationToken: CancellationController().token,
        );
    final candidate =
        (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
            .value;
    expect(candidate.value, 1);
    expect(candidate.evidence.lostOrCorruptTail, isTrue);
    expect(resourceChecks, 0);
  });

  test('missing resource in valid committed tail preserves checkpoint', () {
    final record = _generation(
      tail: _transaction(resultHash: 2, resources: [_resource()]),
      committed: true,
      manifestLast: 1,
    );
    final outcome =
        RecoveryReconstructor<int>(
          codec: const _IntCodec(),
          validator: (_) => true,
          resourceValidator: (_) => false,
        ).reconstruct(
          [record],
          context: _context(record),
          maximumGenerations: 16,
          maximumCheckpointBytes: 10,
          maximumJournalBytes: 10,
          maximumSteps: 10,
          maximumResources: 1,
          cancellationToken: CancellationController().token,
        );
    final candidate =
        (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
            .value;
    expect(candidate.value, 1);
    expect(candidate.evidence.appliedTransactions, 0);
    expect(candidate.evidence.lostOrCorruptTail, isTrue);
  });

  test(
    'invalid newest checkpoint genuinely falls back to older generation',
    () {
      final newest = _generation(
        generationValue: 2,
        checkpointHashByte: 9,
        tail: _transaction(resultHash: 2),
        committed: false,
        manifestLast: 0,
      );
      final older = _generation(
        tail: _transaction(resultHash: 2),
        committed: false,
        manifestLast: 0,
      );
      final outcome = _reconstructor().reconstruct(
        [older, newest],
        context: _context(newest),
        maximumGenerations: 16,
        maximumCheckpointBytes: 10,
        maximumJournalBytes: 10,
        maximumSteps: 10,
        maximumResources: 0,
        cancellationToken: CancellationController().token,
      );
      final candidate =
          (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
              .value;
      expect(candidate.evidence.generation.value, 1);
      expect(candidate.evidence.usedFallbackGeneration, isTrue);
    },
  );

  test('manifest resource belonging only to corrupt tail is not required', () {
    var checks = 0;
    final tailResource = _resource(id: 885, hash: 8);
    final record = _generation(
      manifestResources: [tailResource],
      tail: _transaction(resultHash: 99, resources: [tailResource]),
      committed: true,
      manifestLast: 1,
    );
    final outcome =
        RecoveryReconstructor<int>(
          codec: const _IntCodec(),
          validator: (_) => true,
          resourceValidator: (_) {
            checks += 1;
            return false;
          },
        ).reconstruct(
          [record],
          context: _context(record),
          maximumGenerations: 16,
          maximumCheckpointBytes: 10,
          maximumJournalBytes: 10,
          maximumSteps: 10,
          maximumResources: 1,
          cancellationToken: CancellationController().token,
        );
    final candidate =
        (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
            .value;
    expect(candidate.value, 1);
    expect(candidate.evidence.appliedTransactions, 0);
    expect(checks, 0);
  });

  test('resource update at ceiling applies without another slot', () {
    final prior = _resource(id: 886);
    final updated = _resource(id: 886, hash: 8);
    final record = _generation(
      checkpointResources: [prior],
      tail: _transaction(resultHash: 2, resources: [updated]),
      committed: true,
      manifestLast: 1,
    );
    final outcome = _reconstructor().reconstruct(
      [record],
      context: _context(record),
      maximumGenerations: 16,
      maximumCheckpointBytes: 10,
      maximumJournalBytes: 10,
      maximumSteps: 10,
      maximumResources: 1,
      cancellationToken: CancellationController().token,
    );
    final candidate =
        (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
            .value;
    expect(candidate.value, 2);
    expect(candidate.evidence.appliedTransactions, 1);
  });

  test('shared manifest and checkpoint hash evidence must agree', () {
    final baseline = _resource(id: 890);
    final conflicting = _resource(id: 890, hash: 250);
    final record = _generation(
      manifestResources: [conflicting],
      checkpointResources: [baseline],
      tail: _transaction(resultHash: 2),
      committed: false,
      manifestLast: 0,
    );
    final outcome = _reconstructor().reconstruct(
      [record],
      context: _context(record),
      maximumGenerations: 16,
      maximumCheckpointBytes: 10,
      maximumJournalBytes: 10,
      maximumSteps: 10,
      maximumResources: 1,
      cancellationToken: CancellationController().token,
    );
    expect(outcome, isA<Failed<RecoveredCandidate<int>, StructuredFailure>>());
    final failure =
        (outcome as Failed<RecoveredCandidate<int>, StructuredFailure>).failure;
    expect(failure.toString(), isNot(contains('250')));
    expect(failure.toString(), isNot(contains(testUuid(890).value)));
  });

  test('shared manifest and checkpoint byte lengths must agree', () {
    final baseline = _resource(id: 891);
    final conflicting = _resource(id: 891, byteLength: 777);
    final record = _generation(
      manifestResources: [conflicting],
      checkpointResources: [baseline],
      tail: _transaction(resultHash: 2),
      committed: false,
      manifestLast: 0,
    );
    final outcome = _reconstructor().reconstruct(
      [record],
      context: _context(record),
      maximumGenerations: 16,
      maximumCheckpointBytes: 10,
      maximumJournalBytes: 10,
      maximumSteps: 10,
      maximumResources: 1,
      cancellationToken: CancellationController().token,
    );
    expect(outcome, isA<Failed<RecoveredCandidate<int>, StructuredFailure>>());
    final failure =
        (outcome as Failed<RecoveredCandidate<int>, StructuredFailure>).failure;
    expect(failure.toString(), isNot(contains('777')));
  });

  test('identical shared resource evidence is accepted', () {
    final baseline = _resource(id: 892, hash: 9, byteLength: 2);
    final record = _generation(
      manifestResources: [baseline],
      checkpointResources: [baseline],
      tail: _transaction(resultHash: 2),
      committed: false,
      manifestLast: 0,
    );
    expect(
      _reconstructor().reconstruct(
        [record],
        context: _context(record),
        maximumGenerations: 16,
        maximumCheckpointBytes: 10,
        maximumJournalBytes: 10,
        maximumSteps: 10,
        maximumResources: 1,
        cancellationToken: CancellationController().token,
      ),
      isA<Completed<RecoveredCandidate<int>, StructuredFailure>>(),
    );
  });

  test('newest shared-resource conflict falls back without disclosure', () {
    final baseline = _resource(id: 893);
    final hostile = _resource(id: 893, hash: 250, byteLength: 777);
    final newest = _generation(
      generationValue: 2,
      manifestResources: [hostile],
      checkpointResources: [baseline],
      tail: _transaction(resultHash: 2),
      committed: false,
      manifestLast: 0,
    );
    final older = _generation(
      tail: _transaction(resultHash: 2),
      committed: false,
      manifestLast: 0,
    );
    final outcome = _reconstructor().reconstruct(
      [newest, older],
      context: _context(newest),
      maximumGenerations: 16,
      maximumCheckpointBytes: 10,
      maximumJournalBytes: 10,
      maximumSteps: 10,
      maximumResources: 1,
      cancellationToken: CancellationController().token,
    );
    final candidate =
        (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
            .value;
    expect(candidate.evidence.generation.value, 1);
    expect(candidate.evidence.usedFallbackGeneration, isTrue);
    expect(outcome.toString(), isNot(contains('777')));
    expect(outcome.toString(), isNot(contains('250')));
  });

  test('new resource beyond ceiling preserves the prior prefix', () {
    final prior = _resource(id: 887);
    final added = _resource(id: 888, hash: 8);
    final record = _generation(
      manifestResources: [prior, added],
      checkpointResources: [prior],
      tail: _transaction(resultHash: 2, resources: [added]),
      committed: true,
      manifestLast: 1,
    );
    final outcome = _reconstructor().reconstruct(
      [record],
      context: _context(record),
      maximumGenerations: 16,
      maximumCheckpointBytes: 10,
      maximumJournalBytes: 10,
      maximumSteps: 10,
      maximumResources: 1,
      cancellationToken: CancellationController().token,
    );
    final candidate =
        (outcome as Completed<RecoveredCandidate<int>, StructuredFailure>)
            .value;
    expect(candidate.value, 1);
    expect(candidate.evidence.appliedTransactions, 0);
    expect(candidate.evidence.lostOrCorruptTail, isTrue);
  });

  test('conflicting duplicate checkpoint evidence fails safely', () {
    final first = _resource(id: 889);
    final conflicting = _resource(id: 889, hash: 8);
    final invalid = _generation(
      checkpointResources: [first, conflicting],
      hostileCheckpoint: true,
      tail: _transaction(resultHash: 2),
      committed: false,
      manifestLast: 0,
    );
    expect(
      _reconstructor().reconstruct(
        [invalid],
        context: _context(invalid),
        maximumGenerations: 16,
        maximumCheckpointBytes: 10,
        maximumJournalBytes: 10,
        maximumSteps: 10,
        maximumResources: 2,
        cancellationToken: CancellationController().token,
      ),
      isA<Failed<RecoveredCandidate<int>, StructuredFailure>>(),
    );
  });

  test('scheduling failure preserves counters and prior tasks atomically', () {
    final tasks = ManualRecoveryTaskSource();
    final coordinator = _scheduling(tasks);
    expect(
      coordinator.committed(encodedDeltaBytes: 1),
      isA<Ok<void, StructuredFailure>>(),
    );
    final firstDirty = coordinator.firstDirtyUtc;
    final active = tasks.activeTaskCount;
    tasks.throwOnSchedule = true;
    expect(
      coordinator.committed(encodedDeltaBytes: 2),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(coordinator.firstDirtyUtc, firstDirty);
    expect(tasks.activeTaskCount, active);
  });

  test('throwing scheduling clock is redacted without task mutation', () {
    final tasks = ManualRecoveryTaskSource();
    final coordinator = _scheduling(tasks, clock: _ThrowRecoveryClock());
    expect(
      coordinator.committed(encodedDeltaBytes: 1),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(coordinator.firstDirtyUtc, isNull);
    expect(tasks.activeTaskCount, 0);
  });

  test('trigger failure is observable and disposal suppresses triggers', () {
    final tasks = ManualRecoveryTaskSource();
    final failed = _scheduling(tasks, throwTrigger: true);
    expect(
      failed.committed(encodedDeltaBytes: 20),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(failed.status, RecoverySchedulingStatus.failed);
    final healthy = _scheduling(ManualRecoveryTaskSource());
    healthy.committed(encodedDeltaBytes: 1);
    healthy.durableBoundary(checkpoint: true);
    expect(healthy.status, RecoverySchedulingStatus.current);
    healthy.dispose();
    expect(healthy.explicitFlush(), isA<Err<void, StructuredFailure>>());
  });

  test('quiet replacement and durable boundary cancel obsolete tasks', () {
    final tasks = ManualRecoveryTaskSource();
    final coordinator = _scheduling(tasks);
    expect(
      coordinator.committed(encodedDeltaBytes: 1),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(tasks.activeTaskCount, 3);
    expect(
      coordinator.committed(encodedDeltaBytes: 1),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(tasks.activeTaskCount, 3);
    expect(
      coordinator.durableBoundary(checkpoint: true),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(tasks.activeTaskCount, 0);
  });

  test('synchronous task delivery emits each staged trigger exactly once', () {
    final tasks = ManualRecoveryTaskSource()..runSynchronously = true;
    final reasons = <RecoveryScheduleReason>[];
    final coordinator = RecoverySchedulingCoordinator(
      policy: _policy(),
      clock: ControllableClock(DateTime.utc(2026)),
      taskSource: tasks,
      trigger: (reason, checkpoint) => reasons.add(reason),
    );
    expect(
      coordinator.committed(encodedDeltaBytes: 1),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(reasons, [
      RecoveryScheduleReason.quietPeriod,
      RecoveryScheduleReason.maximumDirtyAge,
      RecoveryScheduleReason.periodicCheckpoint,
    ]);
    expect(tasks.activeTaskCount, 0);
  });

  test('synchronous trigger failure is returned and redacted', () {
    final tasks = ManualRecoveryTaskSource()..runSynchronously = true;
    final coordinator = RecoverySchedulingCoordinator(
      policy: _policy(),
      clock: ControllableClock(DateTime.utc(2026)),
      taskSource: tasks,
      trigger: (reason, checkpoint) => throw StateError('secret trigger'),
    );
    expect(
      coordinator.committed(encodedDeltaBytes: 1),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(coordinator.status, RecoverySchedulingStatus.failed);
    expect(tasks.activeTaskCount, 0);
  });

  test(
    'reentrant scheduling operations are deterministic and disposal wins',
    () {
      for (final operation in [
        'committed',
        'durable',
        'lifecycle',
        'explicit',
        'dispose',
      ]) {
        late RecoverySchedulingCoordinator coordinator;
        Result<void, StructuredFailure>? nested;
        var triggers = 0;
        coordinator = RecoverySchedulingCoordinator(
          policy: _policy(),
          clock: ControllableClock(DateTime.utc(2026)),
          taskSource: ManualRecoveryTaskSource(),
          trigger: (reason, checkpoint) {
            triggers += 1;
            switch (operation) {
              case 'committed':
                nested = coordinator.committed(encodedDeltaBytes: 1);
              case 'durable':
                nested = coordinator.durableBoundary(checkpoint: true);
              case 'lifecycle':
                nested = coordinator.lifecycleFlush();
              case 'explicit':
                nested = coordinator.explicitFlush();
              case 'dispose':
                coordinator.dispose();
            }
          },
        );
        final outer = coordinator.committed(encodedDeltaBytes: 20);
        expect(triggers, 1, reason: operation);
        if (operation == 'dispose') {
          expect(outer, isA<Err<void, StructuredFailure>>());
          expect(coordinator.status, RecoverySchedulingStatus.disposed);
          expect(
            coordinator.committed(encodedDeltaBytes: 1),
            isA<Err<void, StructuredFailure>>(),
          );
        } else {
          expect(outer, isA<Ok<void, StructuredFailure>>(), reason: operation);
          expect(
            nested,
            isA<Err<void, StructuredFailure>>(),
            reason: operation,
          );
          expect(coordinator.status, RecoverySchedulingStatus.pending);
        }
      }
    },
  );

  test('all staged tasks are cancelled even when cancellation throws', () {
    final tasks = ManualRecoveryTaskSource()
      ..throwOnScheduleCall = 3
      ..throwOnCancel = true;
    final coordinator = _scheduling(tasks);
    expect(
      coordinator.committed(encodedDeltaBytes: 1),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(tasks.cancellationAttempts, 2);
    expect(tasks.activeTaskCount, 0);
    expect(coordinator.firstDirtyUtc, isNull);
  });

  test('failed boundary survives and explicit retry publishes it', () async {
    var fail = true;
    final values = <int>[];
    final writer = RecoveryWriter<int>(
      maximumListeners: 16,
      maximumRetryAttempts: 0,
      publisher: (boundary, token) async {
        values.add(boundary.state);
        return fail
            ? Failed(_writerFailure(RetryDisposition.never))
            : const Completed(null);
      },
    );
    writer.schedule(
      _boundary(10),
      cancellationToken: CancellationController().token,
    );
    expect(await writer.flush(), RecoveryFlushDisposition.failed);
    fail = false;
    expect(
      writer.retry(cancellationToken: CancellationController().token),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(await writer.flush(), RecoveryFlushDisposition.completed);
    expect(values, [10, 10]);
  });

  test('cancelled and thrown attempts retain pending work', () async {
    var throwing = true;
    final writer = RecoveryWriter<int>(
      maximumListeners: 16,
      maximumRetryAttempts: 0,
      publisher: (boundary, token) async {
        if (throwing) throw StateError('secret');
        return const Completed(null);
      },
    );
    writer.schedule(
      _boundary(1),
      cancellationToken: CancellationController().token,
    );
    expect(await writer.flush(), RecoveryFlushDisposition.failed);
    throwing = false;
    writer.retry(cancellationToken: CancellationController().token);
    expect(await writer.flush(), RecoveryFlushDisposition.completed);
    final cancelled = CancellationController()..cancel('old');
    writer.schedule(_boundary(2), cancellationToken: cancelled.token);
    expect(await writer.flush(), RecoveryFlushDisposition.delayed);
    writer.retry(cancellationToken: CancellationController().token);
    expect(await writer.flush(), RecoveryFlushDisposition.completed);
  });

  test(
    'retryable failure exhausts exact deterministic attempt bound',
    () async {
      var attempts = 0;
      final writer = RecoveryWriter<int>(
        maximumListeners: 16,
        maximumRetryAttempts: 2,
        publisher: (boundary, token) async {
          attempts += 1;
          return Failed(_writerFailure(RetryDisposition.retryable));
        },
      );
      writer.schedule(
        _boundary(1),
        cancellationToken: CancellationController().token,
      );
      expect(await writer.flush(), RecoveryFlushDisposition.failed);
      expect(attempts, 3);
    },
  );

  test(
    'new boundary coalesces retained transitions with a fresh token',
    () async {
      var fail = true;
      RecoveryBoundary<int>? published;
      final writer = RecoveryWriter<int>(
        maximumListeners: 16,
        maximumRetryAttempts: 0,
        publisher: (boundary, token) async {
          if (fail) return Failed(_writerFailure(RetryDisposition.never));
          published = boundary;
          return const Completed(null);
        },
      );
      writer.schedule(
        _boundary(1),
        cancellationToken: CancellationController().token,
      );
      await writer.flush();
      fail = false;
      writer.schedule(
        _boundary(2),
        cancellationToken: CancellationController().token,
      );
      expect(await writer.flush(), RecoveryFlushDisposition.completed);
      expect(published?.state, 2);
      expect(published?.nonDroppableTransitions, 2);
      expect(published?.requiresCheckpoint, isTrue);
    },
  );

  test('writer reports failed after bounded publisher failure', () async {
    final writer = RecoveryWriter<int>(
      maximumListeners: 16,
      maximumRetryAttempts: 0,
      publisher: (boundary, token) async => Failed(
        StructuredFailure(
          code: 'test.failure',
          category: FailureCategory.state,
          retryDisposition: RetryDisposition.never,
          message: 'failed',
        ),
      ),
    );
    writer.schedule(
      ok(
        RecoveryBoundary.create<int>(
          state: 1,
          requiresCheckpoint: true,
          nonDroppableTransitions: 1,
        ),
      ),
      cancellationToken: CancellationController().token,
    );
    expect(await writer.flush(), RecoveryFlushDisposition.failed);
    expect(writer.status, RecoveryStatus.failed);
  });

  test(
    'boundary validates transitions and writer publishes exact state',
    () async {
      RecoveryBoundary<int>? published;
      final writer = RecoveryWriter<int>(
        maximumListeners: 16,
        maximumRetryAttempts: 1,
        publisher: (boundary, token) async {
          published = boundary;
          return const Completed(null);
        },
      );
      expect(
        RecoveryBoundary.create<int>(
          state: 1,
          requiresCheckpoint: false,
          nonDroppableTransitions: 0,
        ),
        isA<Err<RecoveryBoundary<int>, StructuredFailure>>(),
      );
      final boundary = ok(
        RecoveryBoundary.create<int>(
          state: 2,
          requiresCheckpoint: false,
          nonDroppableTransitions: 1,
        ),
      );
      expect(
        writer.schedule(
          boundary,
          cancellationToken: CancellationController().token,
        ),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(await writer.flush(), RecoveryFlushDisposition.completed);
      expect(published?.state, 2);
      expect(writer.status, RecoveryStatus.current);
    },
  );

  test('fresh boundary is not poisoned by an older cancelled token', () async {
    final values = <int>[];
    final writer = RecoveryWriter<int>(
      maximumListeners: 16,
      maximumRetryAttempts: 0,
      publisher: (boundary, token) async {
        values.add(boundary.state);
        return const Completed(null);
      },
    );
    final old = CancellationController()..cancel('old');
    writer.schedule(
      ok(
        RecoveryBoundary.create<int>(
          state: 1,
          requiresCheckpoint: false,
          nonDroppableTransitions: 1,
        ),
      ),
      cancellationToken: old.token,
    );
    writer.schedule(
      ok(
        RecoveryBoundary.create<int>(
          state: 2,
          requiresCheckpoint: false,
          nonDroppableTransitions: 1,
        ),
      ),
      cancellationToken: CancellationController().token,
    );
    await writer.flush();
    expect(values, contains(2));
  });

  test('hash, quota, and cleanup construction reject hostile values', () {
    expect(
      RecoveryHash.create(const [-1], maximumBytes: 2),
      isA<Err<RecoveryHash, StructuredFailure>>(),
    );
    expect(
      RecoveryQuotaEvidence.create(
        maximumBytes: 1,
        usedBytes: 2,
        durable: true,
      ),
      isA<Err<RecoveryQuotaEvidence, StructuredFailure>>(),
    );
  });

  test('Recovery byte collection stops before an infinite rejected tail', () {
    final source = _CountingIterable<int>(() => 7);
    expect(
      RecoveryHash.create(source, maximumBytes: 2),
      isA<Err<RecoveryHash, StructuredFailure>>(),
    );
    expect(source.moveNextCalls, 3);
    expect(source.currentReads, 2);

    for (final exact in <Iterable<int>>[
      HostileList(const [1, 2], reportedLength: 0),
      HostileList(const [1, 2], reportedLength: 999),
      ThrowingLengthList(const [1, 2]),
    ]) {
      expect(
        RecoveryHash.create(exact, maximumBytes: 2),
        isA<Ok<RecoveryHash, StructuredFailure>>(),
      );
    }
    for (final hostile in <Iterable<int>>[
      IteratorCreationThrowingValues(),
      ThrowingValues(),
      CurrentThrowingValues(),
    ]) {
      expect(
        RecoveryHash.create(hostile, maximumBytes: 2),
        isA<Err<RecoveryHash, StructuredFailure>>(),
      );
    }
    final finite = TrackingValues([1, 2, 222]);
    expect(
      RecoveryHash.create(
        HostileList(finite, reportedLength: 0),
        maximumBytes: 2,
      ),
      isA<Err<RecoveryHash, StructuredFailure>>(),
    );
    expect(finite.moveNextCalls, 3);
    expect(finite.currentReads, 2);
  });

  test(
    'Recovery collection contains iterator failures at and before boundary',
    () {
      final before = _CountingIterable<int>(() => 1, throwOnMove: 1);
      final boundary = _CountingIterable<int>(() => 1, throwOnMove: 3);
      expect(
        RecoveryHash.create(before, maximumBytes: 2),
        isA<Err<RecoveryHash, StructuredFailure>>(),
      );
      expect(
        RecoveryHash.create(boundary, maximumBytes: 2),
        isA<Err<RecoveryHash, StructuredFailure>>(),
      );
      expect(boundary.currentReads, 2);
    },
  );

  test('Recovery listener ceiling is exact, duplicate-safe and removable', () {
    final writer = RecoveryWriter<int>(
      publisher: (_, _) async => const Completed(null),
      maximumRetryAttempts: 0,
      maximumListeners: 1,
    );
    void listener(RecoveryStatus _) {}
    expect(writer.addListener(listener), isA<Ok<void, StructuredFailure>>());
    expect(writer.addListener(listener), isA<Ok<void, StructuredFailure>>());
    expect(writer.addListener((_) {}), isA<Err<void, StructuredFailure>>());
    writer.removeListener(listener);
    expect(writer.addListener((_) {}), isA<Ok<void, StructuredFailure>>());
  });

  test(
    'reconstruction bounds candidate collection before sorting or tail reads',
    () {
      final record = _generation(
        tail: _transaction(resultHash: 2),
        committed: true,
        manifestLast: 1,
      );
      final source = _CountingIterable<RecoveryGenerationRecord>(() => record);
      final outcome = _reconstructor().reconstruct(
        source,
        context: _context(record),
        maximumGenerations: 1,
        maximumCheckpointBytes: 10,
        maximumJournalBytes: 10,
        maximumSteps: 10,
        maximumResources: 0,
        cancellationToken: CancellationController().token,
      );
      expect(
        outcome,
        isA<Failed<RecoveredCandidate<int>, StructuredFailure>>(),
      );
      expect(source.moveNextCalls, 2);
      expect(source.currentReads, 1);

      for (final exact in <Iterable<RecoveryGenerationRecord>>[
        HostileList([record], reportedLength: 0),
        HostileList([record], reportedLength: 999),
        ThrowingLengthList([record]),
      ]) {
        expect(
          _reconstructor().reconstruct(
            exact,
            context: _context(record),
            maximumGenerations: 1,
            maximumCheckpointBytes: 10,
            maximumJournalBytes: 10,
            maximumSteps: 10,
            maximumResources: 0,
            cancellationToken: CancellationController().token,
          ),
          isA<Completed<RecoveredCandidate<int>, StructuredFailure>>(),
        );
      }
      for (final hostile in <Iterable<RecoveryGenerationRecord>>[
        IteratorCreationThrowingValues(),
        ThrowingValues(),
        CurrentThrowingValues(),
      ]) {
        expect(
          _reconstructor().reconstruct(
            hostile,
            context: _context(record),
            maximumGenerations: 1,
            maximumCheckpointBytes: 10,
            maximumJournalBytes: 10,
            maximumSteps: 10,
            maximumResources: 0,
            cancellationToken: CancellationController().token,
          ),
          isA<Failed<RecoveredCandidate<int>, StructuredFailure>>(),
        );
      }
    },
  );
}

final class _CountingIterable<T> extends Iterable<T> {
  _CountingIterable(this.value, {this.throwOnMove});
  final T Function() value;
  final int? throwOnMove;
  int moveNextCalls = 0;
  int currentReads = 0;

  @override
  Iterator<T> get iterator => _CountingIterator(this);
}

final class _CountingIterator<T> implements Iterator<T> {
  _CountingIterator(this.owner);
  final _CountingIterable<T> owner;

  @override
  T get current {
    owner.currentReads += 1;
    return owner.value();
  }

  @override
  bool moveNext() {
    owner.moveNextCalls += 1;
    if (owner.throwOnMove == owner.moveNextCalls) {
      throw StateError('sensitive iterator');
    }
    return true;
  }
}

RecoveryBoundary<int> _boundary(int state) => ok(
  RecoveryBoundary.create<int>(
    state: state,
    requiresCheckpoint: false,
    nonDroppableTransitions: 1,
  ),
);

StructuredFailure _writerFailure(RetryDisposition retry) => StructuredFailure(
  code: 'test.recovery.failure',
  category: FailureCategory.dependency,
  retryDisposition: retry,
  message: 'failed',
);

RecoverySchedulingCoordinator _scheduling(
  ManualRecoveryTaskSource tasks, {
  bool throwTrigger = false,
  Clock? clock,
}) => RecoverySchedulingCoordinator(
  policy: _policy(),
  clock: clock ?? ControllableClock(DateTime.utc(2026)),
  taskSource: tasks,
  trigger: (reason, checkpoint) {
    if (throwTrigger) throw StateError('secret');
  },
);

RecoverySchedulingPolicy _policy() => ok(
  RecoverySchedulingPolicy.create(
    quietPeriodMilliseconds: 1,
    maximumDirtyAgeMilliseconds: 2,
    checkpointPeriodMilliseconds: 3,
    maximumJournalTransactions: 2,
    maximumJournalBytes: 10,
    largeChangeBytes: 20,
  ),
);

final class _ThrowRecoveryClock implements Clock {
  @override
  DateTime nowUtc() => throw StateError('secret clock');
}

RecoveryGenerationRecord _generation({
  required RecoveryJournalTransaction tail,
  required bool committed,
  required int manifestLast,
  int generationValue = 1,
  int checkpointHashByte = 1,
  List<RetainedResourceEvidence> manifestResources = const [],
  List<RetainedResourceEvidence> checkpointResources = const [],
  bool hostileCheckpoint = false,
}) {
  final generation = ok(RecoveryGeneration.create(generationValue));
  final hash = ok(RecoveryHash.create([checkpointHashByte], maximumBytes: 1));
  final ownership = ok(
    RecoveryOwnershipEvidence.create(
      leaseId: RecoveryLeaseId.fromUuid(testUuid(880)),
      leaseGeneration: 1,
      branchIdentity: 'main',
      valid: true,
    ),
  );
  final setId = RecoverySetId.fromUuid(testUuid(881));
  final documentId = DocumentId.fromUuid(testUuid(882));
  final manifest = ok(
    RecoveryManifest.create(
      setId: setId,
      documentId: documentId,
      generation: generation,
      lastSequence: ok(JournalSequence.create(manifestLast)),
      checkpointHash: hash,
      retainedResources: manifestResources,
      ownership: ownership,
      cleanShutdown: false,
      maximumRetainedResources: manifestResources.length,
    ),
  );
  final checkpointResult = hostileCheckpoint
      ? RecoveryCheckpoint.fromStorage(
          generation: generation,
          bytes: const [1],
          hash: hash,
          resources: checkpointResources,
          committed: true,
          maximumBytes: 10,
          maximumResources: checkpointResources.length,
        )
      : RecoveryCheckpoint.create(
          generation: generation,
          bytes: const [1],
          hash: hash,
          resources: checkpointResources,
          committed: true,
          maximumBytes: 10,
          maximumResources: checkpointResources.length,
        );
  final checkpoint = ok(checkpointResult);
  return ok(
    RecoveryGenerationRecord.fromStorage(
      manifest: manifest,
      checkpoint: checkpoint,
      journal: [RecoveryJournalRecord(transaction: tail, committed: committed)],
      lastKnownGood: true,
      maximumTransactions: 1,
      maximumJournalBytes: 10,
    ),
  );
}

RecoveryJournalTransaction _transaction({
  required int resultHash,
  List<RetainedResourceEvidence> resources = const [],
}) => ok(
  RecoveryJournalTransaction.create(
    sequence: ok(JournalSequence.create(1)),
    transactionId: RecoveryTransactionId.fromUuid(testUuid(883)),
    baseHash: ok(RecoveryHash.create(const [1], maximumBytes: 1)),
    resultingHash: ok(RecoveryHash.create([resultHash], maximumBytes: 1)),
    replacementBytes: const [2],
    resourceChanges: resources,
    maximumBytes: 10,
    maximumResources: resources.length,
  ),
);

RetainedResourceEvidence _resource({
  int id = 884,
  int hash = 7,
  int byteLength = 1,
}) => ok(
  RetainedResourceEvidence.create(
    id: ResourceIdentity.fromUuid(testUuid(id)),
    hash: ok(RecoveryHash.create([hash], maximumBytes: 1)),
    byteLength: byteLength,
  ),
);

RecoveryReconstructor<int> _reconstructor() => RecoveryReconstructor(
  codec: const _IntCodec(),
  validator: (_) => true,
  resourceValidator: (_) => true,
);

RecoveryReconstructionContext _context(RecoveryGenerationRecord record) =>
    RecoveryReconstructionContext(
      expectedSetId: record.manifest.setId,
      expectedDocumentId: record.manifest.documentId,
      currentOwnership: record.manifest.ownership,
      externalSourceCertain: true,
      coordinationCertain: true,
    );

final class _IntCodec implements RecoveryCodec<int> {
  const _IntCodec();
  @override
  OperationOutcome<List<int>, StructuredFailure> encodeCheckpoint(
    int value, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) => Completed([value]);
  @override
  OperationOutcome<int, StructuredFailure> decodeCheckpoint(
    List<int> bytes, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) => Completed(bytes.single);
  @override
  OperationOutcome<int, StructuredFailure> applyReplacement(
    int base,
    List<int> replacementBytes, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) => Completed(replacementBytes.single);
  @override
  Result<RecoveryHash, StructuredFailure> hashOf(int value) =>
      RecoveryHash.create([value], maximumBytes: 1);
}
