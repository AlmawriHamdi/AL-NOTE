// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import '../model/identifiers.dart';

abstract base class _RecoveryUuid {
  const _RecoveryUuid(this.uuid);
  final UuidIdentifier uuid;
  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is _RecoveryUuid &&
      other.uuid == uuid;
  @override
  int get hashCode => Object.hash(runtimeType, uuid);
}

/// Stable identity for one Recovery set.
final class RecoverySetId extends _RecoveryUuid {
  const RecoverySetId.fromUuid(super.uuid);
  static Result<RecoverySetId, StructuredFailure> generate(UuidGenerator g) =>
      g.generateV4().map(RecoverySetId.fromUuid);
  @override
  String toString() => 'RecoverySetId(${uuid.value})';
}

/// Stable identity for one Recovery journal transaction.
final class RecoveryTransactionId extends _RecoveryUuid {
  const RecoveryTransactionId.fromUuid(super.uuid);
  static Result<RecoveryTransactionId, StructuredFailure> generate(
    UuidGenerator g,
  ) => g.generateV4().map(RecoveryTransactionId.fromUuid);
  @override
  String toString() => 'RecoveryTransactionId(${uuid.value})';
}

/// Stable identity for one Recovery ownership lease.
final class RecoveryLeaseId extends _RecoveryUuid {
  const RecoveryLeaseId.fromUuid(super.uuid);
  static Result<RecoveryLeaseId, StructuredFailure> generate(UuidGenerator g) =>
      g.generateV4().map(RecoveryLeaseId.fromUuid);
  @override
  String toString() => 'RecoveryLeaseId(redacted)';
}

abstract base class _CheckedRecoveryValue<T extends _CheckedRecoveryValue<T>>
    implements Comparable<T> {
  const _CheckedRecoveryValue(this.value);
  final int value;
  @override
  int compareTo(T other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is _CheckedRecoveryValue<T> &&
      other.value == value;
  @override
  int get hashCode => Object.hash(runtimeType, value);
  @override
  String toString() => '$value';
}

/// Positive ordered Recovery generation number.
final class RecoveryGeneration
    extends _CheckedRecoveryValue<RecoveryGeneration> {
  const RecoveryGeneration._(super.value);
  static Result<RecoveryGeneration, StructuredFailure> create(int v) =>
      _valid(v)
      ? Ok(RecoveryGeneration._(v))
      : Err(_failure('invalid_generation'));
  Result<RecoveryGeneration, StructuredFailure> increment() =>
      value == 9007199254740991
      ? Err(_failure('generation_overflow'))
      : Ok(RecoveryGeneration._(value + 1));
}

/// Non-negative ordered sequence within one Recovery journal.
final class JournalSequence extends _CheckedRecoveryValue<JournalSequence> {
  const JournalSequence._(super.value);
  static Result<JournalSequence, StructuredFailure> create(int v) =>
      _valid(v) ? Ok(JournalSequence._(v)) : Err(_failure('invalid_sequence'));
  Result<JournalSequence, StructuredFailure> increment() =>
      value == 9007199254740991
      ? Err(_failure('sequence_overflow'))
      : Ok(JournalSequence._(value + 1));
}

/// Bounded opaque hash evidence for Recovery content.
final class RecoveryHash {
  RecoveryHash._(this.bytes);
  final List<int> bytes;

  /// Creates bounded immutable hash evidence from unsigned bytes.
  static Result<RecoveryHash, StructuredFailure> create(
    Iterable<int> bytes, {
    required int maximumBytes,
  }) {
    if (maximumBytes <= 0 || maximumBytes > 64) {
      return Err(_failure('invalid_hash'));
    }
    final captured = _boundedBytes(bytes, maximumBytes, 'invalid_hash');
    if (captured case Ok<List<int>, StructuredFailure>(value: final copied)) {
      return copied.isEmpty
          ? Err(_failure('invalid_hash'))
          : Ok(RecoveryHash._(copied));
    }
    return Err(_failure('invalid_hash'));
  }

  @override
  bool operator ==(Object other) =>
      other is RecoveryHash && _bytesEqual(other.bytes, bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
  @override
  String toString() => 'RecoveryHash(redacted)';
}

/// Hash and size evidence for one retained Recovery resource.
final class RetainedResourceEvidence {
  const RetainedResourceEvidence._({
    required this.id,
    required this.hash,
    required this.byteLength,
  });
  final ResourceIdentity id;
  final RecoveryHash hash;
  final int byteLength;

  /// Creates validated retained-resource evidence.
  static Result<RetainedResourceEvidence, StructuredFailure> create({
    required ResourceIdentity id,
    required RecoveryHash hash,
    required int byteLength,
  }) => _valid(byteLength)
      ? Ok(
          RetainedResourceEvidence._(
            id: id,
            hash: hash,
            byteLength: byteLength,
          ),
        )
      : Err(_failure('invalid_resource_length'));
  @override
  String toString() => 'RetainedResourceEvidence(bytes: $byteLength)';
}

/// Observable durability status of Recovery publication.
enum RecoveryStatus { current, pending, delayed, failed }

/// Typed lease and branch evidence for Recovery ownership.
final class RecoveryOwnershipEvidence {
  const RecoveryOwnershipEvidence._({
    required this.leaseId,
    required this.leaseGeneration,
    required this.branchIdentity,
    required this.valid,
  });
  final RecoveryLeaseId leaseId;
  final int leaseGeneration;
  final String branchIdentity;
  final bool valid;

  /// Creates bounded lease and branch evidence.
  static Result<RecoveryOwnershipEvidence, StructuredFailure> create({
    required RecoveryLeaseId leaseId,
    required int leaseGeneration,
    required String branchIdentity,
    required bool valid,
  }) =>
      leaseGeneration >= 0 &&
          leaseGeneration <= 9007199254740991 &&
          RegExp(r'^[a-zA-Z0-9._-]{1,128}$').hasMatch(branchIdentity)
      ? Ok(
          RecoveryOwnershipEvidence._(
            leaseId: leaseId,
            leaseGeneration: leaseGeneration,
            branchIdentity: branchIdentity,
            valid: valid,
          ),
        )
      : Err(_failure('invalid_ownership'));
  @override
  String toString() => 'RecoveryOwnershipEvidence(valid: $valid)';
}

/// Validated manifest for one published Recovery generation.
final class RecoveryManifest {
  RecoveryManifest._({
    required this.setId,
    required this.documentId,
    required this.generation,
    required this.lastSequence,
    required this.checkpointHash,
    required Iterable<RetainedResourceEvidence> retainedResources,
    required this.ownership,
    required this.cleanShutdown,
  }) : retainedResources = List.unmodifiable(retainedResources);
  final RecoverySetId setId;
  final DocumentId documentId;
  final RecoveryGeneration generation;
  final JournalSequence lastSequence;
  final RecoveryHash checkpointHash;
  final List<RetainedResourceEvidence> retainedResources;
  final RecoveryOwnershipEvidence ownership;
  final bool cleanShutdown;

  /// Creates a coherent bounded manifest with unique retained resources.
  static Result<RecoveryManifest, StructuredFailure> create({
    required RecoverySetId setId,
    required DocumentId documentId,
    required RecoveryGeneration generation,
    required JournalSequence lastSequence,
    required RecoveryHash checkpointHash,
    required Iterable<RetainedResourceEvidence> retainedResources,
    required RecoveryOwnershipEvidence ownership,
    required bool cleanShutdown,
    required int maximumRetainedResources,
  }) {
    try {
      final captured = _boundedList(
        retainedResources,
        maximumRetainedResources,
        'invalid_manifest_resources',
      );
      if (captured is! Ok<List<RetainedResourceEvidence>, StructuredFailure>) {
        return Err(_failure('invalid_manifest_resources'));
      }
      final resources = captured.value;
      final ids = <ResourceIdentity>{};
      if (maximumRetainedResources < 0 ||
          resources.any((resource) => !ids.add(resource.id))) {
        return Err(_failure('invalid_manifest_resources'));
      }
      return Ok(
        RecoveryManifest._(
          setId: setId,
          documentId: documentId,
          generation: generation,
          lastSequence: lastSequence,
          checkpointHash: checkpointHash,
          retainedResources: resources,
          ownership: ownership,
          cleanShutdown: cleanShutdown,
        ),
      );
    } on Object {
      return Err(_failure('invalid_manifest'));
    }
  }

  @override
  String toString() =>
      'RecoveryManifest(generation: ${generation.value}, resources: ${retainedResources.length})';
}

/// Complete committed checkpoint for one Recovery generation.
final class RecoveryCheckpoint {
  RecoveryCheckpoint._({
    required this.generation,
    required Iterable<int> bytes,
    required this.hash,
    required Iterable<RetainedResourceEvidence> resources,
    required this.committed,
  }) : bytes = List.unmodifiable(bytes),
       resources = List.unmodifiable(resources);
  final RecoveryGeneration generation;
  final List<int> bytes;
  final RecoveryHash hash;
  final List<RetainedResourceEvidence> resources;
  final bool committed;

  /// Creates a bounded complete checkpoint artifact.
  static Result<RecoveryCheckpoint, StructuredFailure> create({
    required RecoveryGeneration generation,
    required Iterable<int> bytes,
    required RecoveryHash hash,
    required Iterable<RetainedResourceEvidence> resources,
    required bool committed,
    required int maximumBytes,
    required int maximumResources,
  }) {
    try {
      final capturedBytes = _boundedBytes(
        bytes,
        maximumBytes,
        'invalid_checkpoint',
      );
      final capturedResources = _boundedList(
        resources,
        maximumResources,
        'invalid_checkpoint',
      );
      if (capturedBytes is! Ok<List<int>, StructuredFailure> ||
          capturedResources
              is! Ok<List<RetainedResourceEvidence>, StructuredFailure>) {
        return Err(_failure('invalid_checkpoint'));
      }
      final copied = capturedBytes.value;
      final retained = capturedResources.value;
      final ids = <ResourceIdentity>{};
      if (maximumBytes < 0 ||
          maximumResources < 0 ||
          retained.any((resource) => !ids.add(resource.id))) {
        return Err(_failure('invalid_checkpoint'));
      }
      return Ok(
        RecoveryCheckpoint._(
          generation: generation,
          bytes: copied,
          hash: hash,
          resources: retained,
          committed: committed,
        ),
      );
    } on Object {
      return Err(_failure('invalid_checkpoint'));
    }
  }

  /// Captures bounded hostile storage data for reconstruction validation.
  ///
  /// Duplicate identities are retained so the reconstructor can reject
  /// conflicting baseline evidence without trusting the adapter.
  static Result<RecoveryCheckpoint, StructuredFailure> fromStorage({
    required RecoveryGeneration generation,
    required Iterable<int> bytes,
    required RecoveryHash hash,
    required Iterable<RetainedResourceEvidence> resources,
    required bool committed,
    required int maximumBytes,
    required int maximumResources,
  }) {
    try {
      final capturedBytes = _boundedBytes(
        bytes,
        maximumBytes,
        'invalid_checkpoint',
      );
      final capturedResources = _boundedList(
        resources,
        maximumResources,
        'invalid_checkpoint',
      );
      if (capturedBytes is! Ok<List<int>, StructuredFailure> ||
          capturedResources
              is! Ok<List<RetainedResourceEvidence>, StructuredFailure>) {
        return Err(_failure('invalid_checkpoint'));
      }
      final copied = capturedBytes.value;
      final retained = capturedResources.value;
      if (maximumBytes < 0 || maximumResources < 0) {
        return Err(_failure('invalid_checkpoint'));
      }
      return Ok(
        RecoveryCheckpoint._(
          generation: generation,
          bytes: copied,
          hash: hash,
          resources: retained,
          committed: committed,
        ),
      );
    } on Object {
      return Err(_failure('invalid_checkpoint'));
    }
  }

  @override
  String toString() =>
      'RecoveryCheckpoint(generation: ${generation.value}, bytes: ${bytes.length})';
}

/// Append-only persistent after-state replacement data, never Commands.
final class RecoveryJournalTransaction {
  RecoveryJournalTransaction._({
    required this.sequence,
    required this.transactionId,
    required this.baseHash,
    required this.resultingHash,
    required Iterable<int> replacementBytes,
    required Iterable<RetainedResourceEvidence> resourceChanges,
  }) : replacementBytes = List.unmodifiable(replacementBytes),
       resourceChanges = List.unmodifiable(resourceChanges);
  final JournalSequence sequence;
  final RecoveryTransactionId transactionId;
  final RecoveryHash baseHash;
  final RecoveryHash resultingHash;
  final List<int> replacementBytes;
  final List<RetainedResourceEvidence> resourceChanges;
  @override
  String toString() =>
      'RecoveryJournalTransaction(sequence: ${sequence.value}, bytes: ${replacementBytes.length})';

  /// Creates bounded uncommitted transaction data.
  static Result<RecoveryJournalTransaction, StructuredFailure> create({
    required JournalSequence sequence,
    required RecoveryTransactionId transactionId,
    required RecoveryHash baseHash,
    required RecoveryHash resultingHash,
    required Iterable<int> replacementBytes,
    required Iterable<RetainedResourceEvidence> resourceChanges,
    required int maximumBytes,
    required int maximumResources,
  }) {
    try {
      final capturedBytes = _boundedBytes(
        replacementBytes,
        maximumBytes,
        'invalid_journal_transaction',
      );
      final capturedResources = _boundedList(
        resourceChanges,
        maximumResources,
        'invalid_journal_transaction',
      );
      if (capturedBytes is! Ok<List<int>, StructuredFailure> ||
          capturedResources
              is! Ok<List<RetainedResourceEvidence>, StructuredFailure>) {
        return Err(_failure('invalid_journal_transaction'));
      }
      final bytes = capturedBytes.value;
      final resources = capturedResources.value;
      final ids = <ResourceIdentity>{};
      if (sequence.value < 1 ||
          maximumBytes < 0 ||
          maximumResources < 0 ||
          resources.any((resource) => !ids.add(resource.id))) {
        return Err(_failure('invalid_journal_transaction'));
      }
      return Ok(
        RecoveryJournalTransaction._(
          sequence: sequence,
          transactionId: transactionId,
          baseHash: baseHash,
          resultingHash: resultingHash,
          replacementBytes: bytes,
          resourceChanges: resources,
        ),
      );
    } on Object {
      return Err(_failure('invalid_journal_transaction'));
    }
  }
}

/// Stored journal data plus a separately published durable commit marker.
final class RecoveryJournalRecord {
  const RecoveryJournalRecord({
    required this.transaction,
    required this.committed,
  });
  final RecoveryJournalTransaction transaction;
  final bool committed;
}

/// Bounded storage record containing a checkpoint and journal tail.
final class RecoveryGenerationRecord {
  RecoveryGenerationRecord._({
    required this.manifest,
    required this.checkpoint,
    required Iterable<RecoveryJournalRecord> journal,
    required this.lastKnownGood,
  }) : journal = List.unmodifiable(journal);
  final RecoveryManifest manifest;
  final RecoveryCheckpoint checkpoint;
  final List<RecoveryJournalRecord> journal;
  final bool lastKnownGood;

  /// Creates a coherent generation record with unique ordered transactions.
  static Result<RecoveryGenerationRecord, StructuredFailure> create({
    required RecoveryManifest manifest,
    required RecoveryCheckpoint checkpoint,
    required Iterable<RecoveryJournalRecord> journal,
    required bool lastKnownGood,
    required int maximumTransactions,
    required int maximumJournalBytes,
  }) {
    try {
      final captured = _boundedList(
        journal,
        maximumTransactions,
        'incoherent_generation',
      );
      if (captured is! Ok<List<RecoveryJournalRecord>, StructuredFailure>) {
        return Err(_failure('incoherent_generation'));
      }
      final records = captured.value;
      final sequences = <int>{};
      final transactions = <RecoveryTransactionId>{};
      var cumulativeBytes = 0;
      var expected = 1;
      var lastCommitted = 0;
      if (manifest.generation != checkpoint.generation ||
          manifest.checkpointHash != checkpoint.hash ||
          !checkpoint.committed ||
          maximumTransactions < 0 ||
          maximumJournalBytes < 0) {
        return Err(_failure('incoherent_generation'));
      }
      for (final record in records) {
        final transaction = record.transaction;
        if (!sequences.add(transaction.sequence.value) ||
            !transactions.add(transaction.transactionId) ||
            transaction.sequence.value != expected) {
          return Err(_failure('invalid_journal_order'));
        }
        expected += 1;
        if (cumulativeBytes >
            9007199254740991 - transaction.replacementBytes.length) {
          return Err(_failure('journal_bytes_overflow'));
        }
        cumulativeBytes += transaction.replacementBytes.length;
        if (cumulativeBytes > maximumJournalBytes) {
          return Err(_failure('journal_bytes_limit'));
        }
        if (record.committed) {
          if (transaction.sequence.value != lastCommitted + 1) {
            return Err(_failure('commit_marker_gap'));
          }
          lastCommitted = transaction.sequence.value;
        } else if (records.skip(expected - 1).any((later) => later.committed)) {
          return Err(_failure('commit_after_incomplete'));
        }
      }
      if (manifest.lastSequence.value != lastCommitted) {
        return Err(_failure('manifest_sequence_mismatch'));
      }
      return Ok(
        RecoveryGenerationRecord._(
          manifest: manifest,
          checkpoint: checkpoint,
          journal: records,
          lastKnownGood: lastKnownGood,
        ),
      );
    } on Object {
      return Err(_failure('incoherent_generation'));
    }
  }

  /// Captures bounded hostile store output for prefix reconstruction.
  /// Structural journal corruption remains representable and is interpreted
  /// only by the reconstructor; byte/count bounds are still enforced here.
  static Result<RecoveryGenerationRecord, StructuredFailure> fromStorage({
    required RecoveryManifest manifest,
    required RecoveryCheckpoint checkpoint,
    required Iterable<RecoveryJournalRecord> journal,
    required bool lastKnownGood,
    required int maximumTransactions,
    required int maximumJournalBytes,
  }) {
    try {
      final captured = _boundedList(
        journal,
        maximumTransactions,
        'incoherent_generation',
      );
      if (captured is! Ok<List<RecoveryJournalRecord>, StructuredFailure>) {
        return Err(_failure('incoherent_generation'));
      }
      final records = captured.value;
      var bytes = 0;
      if (maximumTransactions < 0 || maximumJournalBytes < 0)
        return Err(_failure('incoherent_generation'));
      for (final record in records) {
        final length = record.transaction.replacementBytes.length;
        if (bytes > 9007199254740991 - length)
          return Err(_failure('journal_bytes_overflow'));
        bytes += length;
        if (bytes > maximumJournalBytes)
          return Err(_failure('journal_bytes_limit'));
      }
      return Ok(
        RecoveryGenerationRecord._(
          manifest: manifest,
          checkpoint: checkpoint,
          journal: records,
          lastKnownGood: lastKnownGood,
        ),
      );
    } on Object {
      return Err(_failure('incoherent_generation'));
    }
  }
}

/// Bounded enumeration of available Recovery generations.
final class RecoveryEnumeration {
  RecoveryEnumeration._({
    required Iterable<RecoverySetId> sets,
    required this.truncated,
  }) : sets = List.unmodifiable(sets);
  final List<RecoverySetId> sets;
  final bool truncated;

  static Result<RecoveryEnumeration, StructuredFailure> create({
    required Iterable<RecoverySetId> sets,
    required bool truncated,
    required int maximumSets,
  }) => _boundedList(sets, maximumSets, 'invalid_enumeration').map(
    (captured) => RecoveryEnumeration._(sets: captured, truncated: truncated),
  );
}

/// Validated quota and durability evidence from Recovery storage.
final class RecoveryQuotaEvidence {
  const RecoveryQuotaEvidence._({
    required this.maximumBytes,
    required this.usedBytes,
    required this.durable,
  });
  final int maximumBytes;
  final int usedBytes;
  final bool durable;

  /// Creates bounded honest quota evidence.
  static Result<RecoveryQuotaEvidence, StructuredFailure> create({
    required int maximumBytes,
    required int usedBytes,
    required bool durable,
  }) => _valid(maximumBytes) && _valid(usedBytes) && usedBytes <= maximumBytes
      ? Ok(
          RecoveryQuotaEvidence._(
            maximumBytes: maximumBytes,
            usedBytes: usedBytes,
            durable: durable,
          ),
        )
      : Err(_failure('invalid_quota'));
}

/// Bounded generation cleanup plan guarded by an expected manifest.
final class RecoveryCleanupPlan {
  RecoveryCleanupPlan._({
    required this.setId,
    required Iterable<RecoveryGeneration> generations,
    required this.expectedOwnership,
  }) : generations = List.unmodifiable(generations);
  final RecoverySetId setId;
  final List<RecoveryGeneration> generations;
  final RecoveryOwnershipEvidence expectedOwnership;

  /// Creates a nonempty duplicate-free cleanup plan.
  static Result<RecoveryCleanupPlan, StructuredFailure> create({
    required RecoverySetId setId,
    required Iterable<RecoveryGeneration> generations,
    required RecoveryOwnershipEvidence expectedOwnership,
    required int maximumGenerations,
  }) {
    final captured = _boundedList(
      generations,
      maximumGenerations,
      'invalid_cleanup_plan',
    );
    if (captured is! Ok<List<RecoveryGeneration>, StructuredFailure>) {
      return Err(_failure('invalid_cleanup_plan'));
    }
    final copied = captured.value;
    if (copied.isEmpty ||
        copied.map((value) => value.value).toSet().length != copied.length) {
      return Err(_failure('invalid_cleanup_plan'));
    }
    return Ok(
      RecoveryCleanupPlan._(
        setId: setId,
        generations: copied,
        expectedOwnership: expectedOwnership,
      ),
    );
  }
}

/// Hostile adapter boundary for Recovery storage operations.
abstract interface class RecoveryStore {
  Future<OperationOutcome<RecoveryEnumeration, StructuredFailure>> enumerate({
    required int maximumResults,
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<List<RecoveryGenerationRecord>, StructuredFailure>>
  generations(
    RecoverySetId setId, {
    required int maximumGenerations,
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<void, StructuredFailure>> publishCheckpoint(
    RecoverySetId setId,
    RecoveryGenerationRecord record, {
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<void, StructuredFailure>> appendJournal(
    RecoverySetId setId,
    RecoveryGeneration generation,
    RecoveryJournalTransaction transaction, {
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<void, StructuredFailure>> publishCommitMarker(
    RecoverySetId setId,
    RecoveryGeneration generation,
    JournalSequence sequence, {
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<RecoveryQuotaEvidence, StructuredFailure>> quota({
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<void, StructuredFailure>> cleanup(
    RecoveryCleanupPlan plan, {
    required CancellationToken cancellationToken,
  });
}

/// Bounded, replaceable Recovery encoding. No permanent format is exposed.
abstract interface class RecoveryCodec<T> {
  OperationOutcome<List<int>, StructuredFailure> encodeCheckpoint(
    T value, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });
  OperationOutcome<T, StructuredFailure> decodeCheckpoint(
    List<int> bytes, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });
  OperationOutcome<T, StructuredFailure> applyReplacement(
    T base,
    List<int> replacementBytes, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });
  Result<RecoveryHash, StructuredFailure> hashOf(T value);
}

final Map<String, ResourceLimitUnit> alnoteRecoveryLimitRequirements =
    UnmodifiableMapView({
      'alnote.recovery.sets': ResourceLimitUnit.count,
      'alnote.recovery.generations': ResourceLimitUnit.count,
      'alnote.recovery.journal_transactions': ResourceLimitUnit.count,
      'alnote.recovery.journal_bytes': ResourceLimitUnit.bytes,
      'alnote.recovery.checkpoint_bytes': ResourceLimitUnit.bytes,
      'alnote.recovery.total_bytes': ResourceLimitUnit.bytes,
      'alnote.recovery.retained_resources': ResourceLimitUnit.count,
      'alnote.recovery.pending_boundaries': ResourceLimitUnit.count,
      'alnote.recovery.reconstruction_steps': ResourceLimitUnit.count,
      'alnote.recovery.quiet_period_ms': ResourceLimitUnit.milliseconds,
      'alnote.recovery.maximum_dirty_age_ms': ResourceLimitUnit.milliseconds,
      'alnote.recovery.checkpoint_period_ms': ResourceLimitUnit.milliseconds,
      'alnote.recovery.listeners': ResourceLimitUnit.count,
    });

bool _valid(int value) => value >= 0 && value <= 9007199254740991;
Result<List<T>, StructuredFailure> _boundedList<T>(
  Iterable<T> source,
  int maximum,
  String failureLeaf,
) {
  if (!_valid(maximum)) return Err(_failure(failureLeaf));
  try {
    if ((source is List<T> || source is Set<T>) && source.length > maximum) {
      return Err(_failure(failureLeaf));
    }
    final result = <T>[];
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (result.length >= maximum) return Err(_failure(failureLeaf));
      result.add(iterator.current);
    }
    return Ok(List.unmodifiable(result));
  } on Object {
    return Err(_failure(failureLeaf));
  }
}

Result<List<int>, StructuredFailure> _boundedBytes(
  Iterable<int> source,
  int maximum,
  String failureLeaf,
) {
  if (!_valid(maximum)) return Err(_failure(failureLeaf));
  try {
    if (source is List<int> && source.length > maximum) {
      return Err(_failure(failureLeaf));
    }
    final result = <int>[];
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (result.length >= maximum) return Err(_failure(failureLeaf));
      final value = iterator.current;
      if (value < 0 || value > 255) return Err(_failure(failureLeaf));
      result.add(value);
    }
    return Ok(List.unmodifiable(result));
  } on Object {
    return Err(_failure(failureLeaf));
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
  return true;
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.recovery.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Recovery data is invalid.',
);
