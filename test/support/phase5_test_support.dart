// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:collection';

import 'package:al_note/app/settings.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/recovery.dart';
import 'package:al_note/documents/sessions.dart';
import 'package:al_note/platform/platform.dart';

/// Collection doubles whose reported lengths are deliberately untrustworthy.
final class HostileSet<E> extends SetBase<E> {
  HostileSet(this.values, {required this.reportedLength});
  final Iterable<E> values;
  final int reportedLength;
  @override
  int get length => reportedLength;
  @override
  Iterator<E> get iterator => values.iterator;
  @override
  bool contains(Object? element) => values.contains(element);
  @override
  E? lookup(Object? element) {
    for (final value in values) {
      if (value == element) return value;
    }
    return null;
  }

  @override
  bool add(E value) => throw UnsupportedError('hostile');
  @override
  bool remove(Object? value) => throw UnsupportedError('hostile');
  @override
  void clear() => throw UnsupportedError('hostile');
  @override
  Set<E> toSet() => throw UnsupportedError('hostile');
}

final class HostileList<E> extends ListBase<E> {
  HostileList(this.values, {required this.reportedLength});
  final Iterable<E> values;
  final int reportedLength;
  @override
  int get length => reportedLength;
  @override
  set length(int value) => throw UnsupportedError('hostile');
  @override
  E operator [](int index) => throw UnsupportedError('hostile');
  @override
  void operator []=(int index, E value) => throw UnsupportedError('hostile');
  @override
  Iterator<E> get iterator => values.iterator;
}

final class HostileMap<K, V> extends MapBase<K, V> {
  HostileMap(this.sourceEntries, {required this.reportedLength});
  final Iterable<MapEntry<K, V>> sourceEntries;
  final int reportedLength;
  @override
  int get length => reportedLength;
  @override
  Iterable<MapEntry<K, V>> get entries => sourceEntries;
  @override
  Iterable<K> get keys => sourceEntries.map((entry) => entry.key);
  @override
  V? operator [](Object? key) => throw UnsupportedError('hostile');
  @override
  void operator []=(K key, V value) => throw UnsupportedError('hostile');
  @override
  V? remove(Object? key) => throw UnsupportedError('hostile');
  @override
  void clear() => throw UnsupportedError('hostile');
}

/// Uses [MapBase.entries] so key-current and value-lookup failures are exposed.
final class GetterThrowingMap<K, V> extends MapBase<K, V> {
  GetterThrowingMap.key(this.key) : throwKey = true;
  GetterThrowingMap.value(this.key) : throwKey = false;
  final K key;
  final bool throwKey;
  @override
  Iterable<K> get keys => throwKey ? CurrentThrowingValues<K>() : [key];
  @override
  V? operator [](Object? key) => throw StateError('secret map value');
  @override
  void operator []=(K key, V value) => throw UnsupportedError('hostile');
  @override
  V? remove(Object? key) => throw UnsupportedError('hostile');
  @override
  void clear() => throw UnsupportedError('hostile');
}

final class InfiniteValues<E> extends Iterable<E> {
  InfiniteValues(this.value);
  final E value;
  int moveNextCalls = 0;
  int currentReads = 0;
  @override
  Iterator<E> get iterator => _InfiniteValuesIterator(this);
}

final class _InfiniteValuesIterator<E> implements Iterator<E> {
  _InfiniteValuesIterator(this.owner);
  final InfiniteValues<E> owner;
  @override
  E get current {
    owner.currentReads += 1;
    return owner.value;
  }

  @override
  bool moveNext() {
    owner.moveNextCalls += 1;
    return true;
  }
}

final class ThrowingValues<E> extends Iterable<E> {
  @override
  Iterator<E> get iterator => _ThrowingValuesIterator<E>();
}

final class CurrentThrowingValues<E> extends Iterable<E> {
  @override
  Iterator<E> get iterator => _CurrentThrowingValuesIterator<E>();
}

final class _CurrentThrowingValuesIterator<E> implements Iterator<E> {
  bool _moved = false;
  @override
  E get current => throw StateError('secret collection current');
  @override
  bool moveNext() {
    if (_moved) return false;
    _moved = true;
    return true;
  }
}

final class _ThrowingValuesIterator<E> implements Iterator<E> {
  @override
  E get current => throw StateError('secret collection value');
  @override
  bool moveNext() => throw StateError('secret collection iterator');
}

final class FakeSessionPublisher implements SessionPublisher {
  final List<SessionPublicationRequest> requests = [];
  final List<
    Completer<OperationOutcome<SessionPublicationEvidence, StructuredFailure>>
  >
  completions = [];
  @override
  Future<OperationOutcome<SessionPublicationEvidence, StructuredFailure>>
  publish(
    SessionPublicationRequest request, {
    required CancellationToken cancellationToken,
  }) {
    requests.add(request);
    final completer =
        Completer<
          OperationOutcome<SessionPublicationEvidence, StructuredFailure>
        >();
    completions.add(completer);
    return completer.future;
  }
}

enum TestAdapterFault { none, failure, exception, cancellation }

/// Deterministic transactional Settings adapter with conflict/fault injection.
final class InMemorySettingsAdapter implements SettingsPersistenceAdapter {
  InMemorySettingsAdapter({
    required SettingsPersistenceSnapshot initial,
    this.fault = TestAdapterFault.none,
  }) : current = initial;
  SettingsPersistenceSnapshot current;
  TestAdapterFault fault;
  bool returnUnexpectedCommitRevision = false;
  Completer<void>? loadGate;
  Completer<void>? commitGate;
  int loadInvocations = 0;
  int commitInvocations = 0;
  @override
  Future<OperationOutcome<SettingsPersistenceSnapshot, StructuredFailure>>
  load({
    required int maximumRecords,
    required int maximumUnknownRecords,
    required int maximumUnknownFieldsPerRecord,
    required int maximumValueBytes,
    required CancellationToken cancellationToken,
  }) async {
    loadInvocations += 1;
    if (loadGate != null) await loadGate!.future;
    if (fault == TestAdapterFault.exception)
      throw StateError('sensitive adapter value');
    if (cancellationToken.isCancelled || fault == TestAdapterFault.cancellation)
      return Cancelled(cancellationToken.reason);
    if (fault == TestAdapterFault.failure ||
        current.records.length > maximumRecords ||
        current.unknownRecords.length > maximumUnknownRecords ||
        current.records.any(
          (record) =>
              record.valueBytes.length > maximumValueBytes ||
              record.valueBytes.any((byte) => byte < 0 || byte > 255) ||
              record.unknownFields.length > maximumUnknownFieldsPerRecord ||
              record.unknownFields.values.any(
                (bytes) =>
                    bytes.length > maximumValueBytes ||
                    bytes.any((byte) => byte < 0 || byte > 255),
              ),
        ) ||
        current.unknownRecords.any(
          (record) =>
              record.bytes.length > maximumValueBytes ||
              record.bytes.any((byte) => byte < 0 || byte > 255),
        ))
      return Failed(testFailure('settings_load'));
    return Completed(current);
  }

  @override
  Future<OperationOutcome<SettingsCommitEvidence, StructuredFailure>> commit({
    required SettingsStoreRevision expectedRevision,
    required List<SettingsLogicalRecord> records,
    required List<UnknownSettingsRecord> preservedUnknownRecords,
    required CancellationToken cancellationToken,
  }) async {
    commitInvocations += 1;
    if (commitGate != null) await commitGate!.future;
    if (fault == TestAdapterFault.exception)
      throw StateError('sensitive adapter value');
    if (cancellationToken.isCancelled || fault == TestAdapterFault.cancellation)
      return Cancelled(cancellationToken.reason);
    if (fault == TestAdapterFault.failure ||
        expectedRevision.value != current.storeRevision.value)
      return Failed(testFailure('settings_conflict'));
    final next = current.storeRevision.value.increment();
    if (next is Err<Revision, StructuredFailure>) return Failed(next.error);
    final revision = SettingsStoreRevision(
      (next as Ok<Revision, StructuredFailure>).value,
    );
    current =
        (SettingsPersistenceSnapshot.create(
                  maximumUnknownRecords: 16,
                  maximumUnknownFieldsPerRecord: 16,
                  storeRevision: revision,
                  records: records,
                  unknownRecords: preservedUnknownRecords,
                  damaged: false,
                  lastKnownGoodAvailable: true,
                  maximumRecords: 100000,
                  maximumValueBytes: 100000000,
                )
                as Ok<SettingsPersistenceSnapshot, StructuredFailure>)
            .value;
    return Completed(
      (SettingsCommitEvidence.create(
                storeRevision: returnUnexpectedCommitRevision
                    ? expectedRevision
                    : revision,
                atomicity: SettingsAtomicityEvidence.atomicCommit,
                durability: SettingsDurabilityEvidence.durableCommit,
              )
              as Ok<SettingsCommitEvidence, StructuredFailure>)
          .value,
    );
  }
}

/// Manual deterministic task source; tests decide exactly when callbacks run.
final class ManualRecoveryTaskSource implements RecoveryTaskSource {
  final List<_ManualTask> tasks = [];
  bool throwOnSchedule = false;
  int? throwOnScheduleCall;
  int schedulingAttempts = 0;
  bool runSynchronously = false;
  bool throwOnCancel = false;
  int cancellationAttempts = 0;
  int get activeTaskCount =>
      tasks.where((task) => !task.cancelled && !task.completed).length;
  @override
  ScheduledTask schedule(Duration delay, void Function() task) {
    schedulingAttempts += 1;
    if (throwOnSchedule || throwOnScheduleCall == schedulingAttempts) {
      throw StateError('sensitive task source');
    }
    final value = _ManualTask(delay, task, () {
      cancellationAttempts += 1;
      return throwOnCancel;
    });
    tasks.add(value);
    if (runSynchronously) value.run();
    return value;
  }

  void runNext() {
    final active = tasks.where((task) => !task.cancelled).firstOrNull;
    active?.run();
  }
}

final class _ManualTask implements ScheduledTask {
  _ManualTask(this.delay, this.callback, this.shouldThrowOnCancel);
  final Duration delay;
  final void Function() callback;
  final bool Function() shouldThrowOnCancel;
  bool cancelled = false;
  bool completed = false;
  void run() {
    if (cancelled || completed) return;
    completed = true;
    callback();
  }

  @override
  void cancel() {
    cancelled = true;
    if (shouldThrowOnCancel()) throw StateError('sensitive cancellation');
  }
}

/// Deterministic Recovery store supporting corruption, quota, cancellation and exceptions.
final class InMemoryRecoveryStore implements RecoveryStore {
  final Map<RecoverySetId, List<RecoveryGenerationRecord>> records = {};
  TestAdapterFault fault = TestAdapterFault.none;
  int quotaBytes = 1000000;
  void _throw() {
    if (fault == TestAdapterFault.exception)
      throw StateError('sensitive recovery bytes');
  }

  @override
  Future<OperationOutcome<RecoveryEnumeration, StructuredFailure>> enumerate({
    required int maximumResults,
    required CancellationToken cancellationToken,
  }) async {
    _throw();
    if (cancellationToken.isCancelled || fault == TestAdapterFault.cancellation)
      return Cancelled(cancellationToken.reason);
    final values = records.keys.take(maximumResults).toList();
    final captured = RecoveryEnumeration.create(
      sets: values,
      truncated: records.length > values.length,
      maximumSets: maximumResults,
    );
    return captured is Ok<RecoveryEnumeration, StructuredFailure>
        ? Completed(captured.value)
        : Failed(
            (captured as Err<RecoveryEnumeration, StructuredFailure>).error,
          );
  }

  @override
  Future<OperationOutcome<List<RecoveryGenerationRecord>, StructuredFailure>>
  generations(
    RecoverySetId setId, {
    required int maximumGenerations,
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) async {
    _throw();
    if (cancellationToken.isCancelled)
      return Cancelled(cancellationToken.reason);
    if (fault == TestAdapterFault.failure)
      return Failed(testFailure('recovery_read'));
    return Completed(
      List.unmodifiable((records[setId] ?? const []).take(maximumGenerations)),
    );
  }

  @override
  Future<OperationOutcome<void, StructuredFailure>> publishCheckpoint(
    RecoverySetId setId,
    RecoveryGenerationRecord record, {
    required CancellationToken cancellationToken,
  }) async {
    _throw();
    if (cancellationToken.isCancelled)
      return Cancelled(cancellationToken.reason);
    if (fault == TestAdapterFault.failure)
      return Failed(testFailure('recovery_checkpoint'));
    records.putIfAbsent(setId, () => []).add(record);
    return const Completed(null);
  }

  @override
  Future<OperationOutcome<void, StructuredFailure>> appendJournal(
    RecoverySetId setId,
    RecoveryGeneration generation,
    RecoveryJournalTransaction transaction, {
    required CancellationToken cancellationToken,
  }) async {
    _throw();
    if (cancellationToken.isCancelled)
      return Cancelled(cancellationToken.reason);
    final values = records[setId];
    if (values == null) return Failed(testFailure('recovery_missing'));
    final index = values.indexWhere(
      (r) => r.manifest.generation.value == generation.value,
    );
    if (index < 0) return Failed(testFailure('recovery_missing'));
    final prior = values[index];
    values[index] =
        (RecoveryGenerationRecord.create(
                  manifest: prior.manifest,
                  checkpoint: prior.checkpoint,
                  journal: [
                    ...prior.journal,
                    RecoveryJournalRecord(
                      transaction: transaction,
                      committed: false,
                    ),
                  ],
                  lastKnownGood: prior.lastKnownGood,
                  maximumTransactions: 100000,
                  maximumJournalBytes: 100000000,
                )
                as Ok<RecoveryGenerationRecord, StructuredFailure>)
            .value;
    return const Completed(null);
  }

  @override
  Future<OperationOutcome<void, StructuredFailure>> publishCommitMarker(
    RecoverySetId setId,
    RecoveryGeneration generation,
    JournalSequence sequence, {
    required CancellationToken cancellationToken,
  }) async {
    if (cancellationToken.isCancelled)
      return Cancelled(cancellationToken.reason);
    final values = records[setId];
    final index =
        values?.indexWhere(
          (record) => record.manifest.generation == generation,
        ) ??
        -1;
    if (values == null || index < 0)
      return Failed(testFailure('recovery_missing'));
    final prior = values[index];
    final markerIndex = prior.journal.indexWhere(
      (record) => record.transaction.sequence == sequence,
    );
    if (markerIndex < 0 ||
        prior.journal.take(markerIndex).any((record) => !record.committed))
      return Failed(testFailure('recovery_marker_gap'));
    final journal = [...prior.journal];
    journal[markerIndex] = RecoveryJournalRecord(
      transaction: journal[markerIndex].transaction,
      committed: true,
    );
    final manifest =
        (RecoveryManifest.create(
                  setId: prior.manifest.setId,
                  documentId: prior.manifest.documentId,
                  generation: generation,
                  lastSequence: sequence,
                  checkpointHash: prior.manifest.checkpointHash,
                  retainedResources: prior.manifest.retainedResources,
                  ownership: prior.manifest.ownership,
                  cleanShutdown: prior.manifest.cleanShutdown,
                  maximumRetainedResources:
                      prior.manifest.retainedResources.length,
                )
                as Ok<RecoveryManifest, StructuredFailure>)
            .value;
    values[index] =
        (RecoveryGenerationRecord.create(
                  manifest: manifest,
                  checkpoint: prior.checkpoint,
                  journal: journal,
                  lastKnownGood: prior.lastKnownGood,
                  maximumTransactions: journal.length,
                  maximumJournalBytes: journal.fold<int>(
                    0,
                    (sum, record) =>
                        sum + record.transaction.replacementBytes.length,
                  ),
                )
                as Ok<RecoveryGenerationRecord, StructuredFailure>)
            .value;
    return const Completed(null);
  }

  @override
  Future<OperationOutcome<RecoveryQuotaEvidence, StructuredFailure>> quota({
    required CancellationToken cancellationToken,
  }) async => cancellationToken.isCancelled
      ? Cancelled(cancellationToken.reason)
      : Completed(
          (RecoveryQuotaEvidence.create(
                    maximumBytes: quotaBytes,
                    usedBytes: 0,
                    durable: true,
                  )
                  as Ok<RecoveryQuotaEvidence, StructuredFailure>)
              .value,
        );
  @override
  Future<OperationOutcome<void, StructuredFailure>> cleanup(
    RecoveryCleanupPlan plan, {
    required CancellationToken cancellationToken,
  }) async {
    if (cancellationToken.isCancelled)
      return Cancelled(cancellationToken.reason);
    records[plan.setId]?.removeWhere(
      (record) => plan.generations.any(
        (g) => g.value == record.manifest.generation.value,
      ),
    );
    return const Completed(null);
  }
}

/// Deterministic schema-independent private store with optimistic concurrency.
final class InMemoryPrivateStorage implements PrivateStorage {
  final Map<PrivateRepositoryId, Map<PrivateRecordId, PrivateByteRecord>>
  _data = {};
  final Map<PrivateRepositoryId, Revision> _revisions = {};
  TestAdapterFault fault = TestAdapterFault.none;
  int quotaBytes = 1000000;
  Revision get _zero =>
      (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
  OperationOutcome<T, StructuredFailure>? _preflight<T>(
    CancellationToken token,
  ) {
    if (fault == TestAdapterFault.exception)
      throw StateError('sensitive private bytes');
    if (token.isCancelled || fault == TestAdapterFault.cancellation)
      return Cancelled(token.reason);
    if (fault == TestAdapterFault.failure)
      return Failed(testFailure('private_store'));
    return null;
  }

  @override
  Future<OperationOutcome<Revision, StructuredFailure>> revision(
    PrivateRepositoryId repository, {
    required CancellationToken cancellationToken,
  }) async =>
      _preflight<Revision>(cancellationToken) ??
      Completed(_revisions[repository] ?? _zero);
  @override
  Future<OperationOutcome<PrivateByteRecord?, StructuredFailure>> read(
    PrivateRepositoryId repository,
    PrivateRecordId id, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) async {
    final prior = _preflight<PrivateByteRecord?>(cancellationToken);
    if (prior != null) return prior;
    if (maximumBytes < 0) return Failed(testFailure('private_limit'));
    final record = _data[repository]?[id];
    if (record != null &&
        (record.bytes.length > maximumBytes ||
            !_sameBytes(record.checksum, _checksum(record.bytes))))
      return Failed(testFailure('private_limit'));
    return Completed(record);
  }

  @override
  Future<OperationOutcome<PrivateStorageEnumeration, StructuredFailure>>
  enumerate(
    PrivateRepositoryId repository, {
    required int maximumResults,
    required int maximumRecordBytes,
    required CancellationToken cancellationToken,
  }) async {
    final prior = _preflight<PrivateStorageEnumeration>(cancellationToken);
    if (prior != null) return prior;
    if (maximumResults < 0 || maximumRecordBytes < 0)
      return Failed(testFailure('private_limit'));
    final source = (_data[repository]?.values ?? const <PrivateByteRecord>[])
        .toList();
    if (source.any(
      (record) =>
          record.bytes.length > maximumRecordBytes ||
          !_sameBytes(record.checksum, _checksum(record.bytes)),
    )) {
      return Failed(testFailure('private_corruption'));
    }
    final all = source..sort((a, b) => a.id.compareTo(b.id));
    return Completed(
      (PrivateStorageEnumeration.create(
                records: all.take(maximumResults),
                truncated: all.length > maximumResults,
                maximumResults: maximumResults,
                maximumRecordBytes: maximumRecordBytes,
              )
              as Ok<PrivateStorageEnumeration, StructuredFailure>)
          .value,
    );
  }

  @override
  Future<OperationOutcome<PrivateStorageCommitEvidence, StructuredFailure>>
  commit(
    PrivateStorageBatch batch, {
    required int maximumOperations,
    required int maximumRecordBytes,
    required CancellationToken cancellationToken,
  }) async {
    final prior = _preflight<PrivateStorageCommitEvidence>(cancellationToken);
    if (prior != null) return prior;
    if (maximumOperations < 0 || maximumRecordBytes < 0)
      return Failed(testFailure('private_limit'));
    final currentRevision = _revisions[batch.repository] ?? _zero;
    if (currentRevision != batch.expectedStoreRevision ||
        batch.operations.length > maximumOperations)
      return Failed(testFailure('private_conflict'));
    final candidate = Map<PrivateRecordId, PrivateByteRecord>.of(
      _data[batch.repository] ?? {},
    );
    for (final operation in batch.operations) {
      final current =
          candidate[operation is WritePrivateRecord
              ? operation.id
              : (operation as DeletePrivateRecord).id];
      if (operation is WritePrivateRecord) {
        if (operation.bytes.length > maximumRecordBytes ||
            operation.expectedRecordRevision != current?.recordRevision)
          return Failed(testFailure('private_conflict'));
        final nextRecord = (current?.recordRevision ?? _zero).increment();
        if (nextRecord is Err<Revision, StructuredFailure>)
          return Failed(nextRecord.error);
        candidate[operation.id] =
            (PrivateByteRecord.create(
                      id: operation.id,
                      recordRevision:
                          (nextRecord as Ok<Revision, StructuredFailure>).value,
                      bytes: operation.bytes,
                      checksum: _checksum(operation.bytes),
                      lastKnownGood: true,
                      maximumBytes: maximumRecordBytes,
                      maximumChecksumBytes: 64,
                    )
                    as Ok<PrivateByteRecord, StructuredFailure>)
                .value;
      } else if (operation is DeletePrivateRecord) {
        if (current?.recordRevision != operation.expectedRecordRevision)
          return Failed(testFailure('private_conflict'));
        candidate.remove(operation.id);
      }
    }
    final used = candidate.values.fold<int>(
      0,
      (sum, r) => sum + r.bytes.length,
    );
    if (used > quotaBytes) return Failed(testFailure('private_quota'));
    final next = currentRevision.increment();
    if (next is Err<Revision, StructuredFailure>) return Failed(next.error);
    final revision = (next as Ok<Revision, StructuredFailure>).value;
    _data[batch.repository] = candidate;
    _revisions[batch.repository] = revision;
    return Completed(
      (PrivateStorageCommitEvidence.create(
                storeRevision: revision,
                atomicity: StorageAtomicityEvidence.atomicCommit,
                durability:
                    (StorageDurabilityEvidence.create(
                              durable: true,
                              flushed: true,
                            )
                            as Ok<StorageDurabilityEvidence, StructuredFailure>)
                        .value,
              )
              as Ok<PrivateStorageCommitEvidence, StructuredFailure>)
          .value,
    );
  }

  @override
  Future<OperationOutcome<PrivateStorageCommitEvidence, StructuredFailure>>
  cleanup(
    PrivateCleanupPlan plan, {
    required CancellationToken cancellationToken,
  }) => commit(
    (PrivateStorageBatch.create(
              repository: plan.repository,
              expectedStoreRevision: plan.expectedStoreRevision,
              operations: [
                for (final id in plan.records)
                  if (_data[plan.repository]?[id] case final record?)
                    DeletePrivateRecord(
                      id: id,
                      expectedRecordRevision: record.recordRevision,
                    ),
              ],
              maximumOperations: plan.records.length,
            )
            as Ok<PrivateStorageBatch, StructuredFailure>)
        .value,
    maximumOperations: plan.records.length,
    maximumRecordBytes: quotaBytes,
    cancellationToken: cancellationToken,
  );
  @override
  Future<OperationOutcome<StoragePressureEvidence, StructuredFailure>>
  pressure({required CancellationToken cancellationToken}) async =>
      _preflight<StoragePressureEvidence>(cancellationToken) ??
      Completed(
        (StoragePressureEvidence.create(
                  pressure: StoragePressure.normal,
                  availableBytes: quotaBytes,
                )
                as Ok<StoragePressureEvidence, StructuredFailure>)
            .value,
      );
}

List<int> _checksum(List<int> bytes) => List<int>.unmodifiable(<int>[
  bytes.fold<int>(0, (value, byte) => (value + byte) & 0xff),
]);

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

StructuredFailure testFailure(String leaf) => StructuredFailure(
  code: 'test.phase5.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'A deterministic test failure occurred.',
);
