// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';

/// Validated identity for one application-private repository.
final class PrivateRepositoryId {
  const PrivateRepositoryId._(this.value);
  static Result<PrivateRepositoryId, StructuredFailure> parse(String value) =>
      RegExp(
            r'^alnote\.(settings|recovery|restoration|capabilities)(?:\.[a-z0-9_-]+)*$',
          ).hasMatch(value) &&
          value.length <= 128
      ? Ok(PrivateRepositoryId._(value))
      : Err(_storageFailure('invalid_repository'));
  final String value;
  @override
  bool operator ==(Object other) =>
      other is PrivateRepositoryId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Validated sortable identity for one private byte record.
final class PrivateRecordId implements Comparable<PrivateRecordId> {
  const PrivateRecordId._(this.value);
  static Result<PrivateRecordId, StructuredFailure> parse(String value) =>
      RegExp(r'^[a-z][a-z0-9._-]{0,127}$').hasMatch(value)
      ? Ok(PrivateRecordId._(value))
      : Err(_storageFailure('invalid_record'));
  final String value;
  @override
  int compareTo(PrivateRecordId other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) =>
      other is PrivateRecordId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Schema-independent immutable checksummed byte record.
final class PrivateByteRecord {
  PrivateByteRecord._({
    required this.id,
    required this.recordRevision,
    required Iterable<int> bytes,
    required Iterable<int> checksum,
    required this.lastKnownGood,
  }) : bytes = _copyBytes(bytes),
       checksum = _copyBytes(checksum);
  final PrivateRecordId id;
  final Revision recordRevision;
  final List<int> bytes;
  final List<int> checksum;
  final bool lastKnownGood;
  static Result<PrivateByteRecord, StructuredFailure> create({
    required PrivateRecordId id,
    required Revision recordRevision,
    required Iterable<int> bytes,
    required Iterable<int> checksum,
    required bool lastKnownGood,
    required int maximumBytes,
    required int maximumChecksumBytes,
  }) {
    try {
      final copiedBytes = _checkedBytes(bytes);
      final copiedChecksum = _checkedBytes(checksum);
      if (maximumBytes < 0 ||
          maximumChecksumBytes < 0 ||
          copiedBytes.length > maximumBytes ||
          copiedChecksum.isEmpty ||
          copiedChecksum.length > maximumChecksumBytes)
        return Err(_storageFailure('invalid_byte_record'));
      return Ok(
        PrivateByteRecord._(
          id: id,
          recordRevision: recordRevision,
          bytes: copiedBytes,
          checksum: copiedChecksum,
          lastKnownGood: lastKnownGood,
        ),
      );
    } on Object {
      return Err(_storageFailure('invalid_byte_record'));
    }
  }

  @override
  String toString() =>
      'PrivateByteRecord(id: $id, bytes: ${bytes.length}, revision: $recordRevision)';
}

/// Closed base for one private-storage batch mutation.
sealed class PrivateStorageMutation {
  const PrivateStorageMutation();
}

/// Bounded write guarded by an optional expected record revision.
final class WritePrivateRecord extends PrivateStorageMutation {
  WritePrivateRecord._({
    required this.id,
    required Iterable<int> bytes,
    this.expectedRecordRevision,
  }) : bytes = _copyBytes(bytes);
  final PrivateRecordId id;
  final List<int> bytes;
  final Revision? expectedRecordRevision;
  static Result<WritePrivateRecord, StructuredFailure> create({
    required PrivateRecordId id,
    required Iterable<int> bytes,
    Revision? expectedRecordRevision,
    required int maximumBytes,
  }) {
    try {
      final copied = _checkedBytes(bytes);
      return maximumBytes >= 0 && copied.length <= maximumBytes
          ? Ok(
              WritePrivateRecord._(
                id: id,
                bytes: copied,
                expectedRecordRevision: expectedRecordRevision,
              ),
            )
          : Err(_storageFailure('invalid_write'));
    } on Object {
      return Err(_storageFailure('invalid_write'));
    }
  }
}

/// Delete guarded by an exact expected record revision.
final class DeletePrivateRecord extends PrivateStorageMutation {
  const DeletePrivateRecord({
    required this.id,
    required this.expectedRecordRevision,
  });
  final PrivateRecordId id;
  final Revision expectedRecordRevision;
}

/// Bounded atomic batch guarded by an expected store revision.
final class PrivateStorageBatch {
  PrivateStorageBatch._({
    required this.repository,
    required this.expectedStoreRevision,
    required Iterable<PrivateStorageMutation> operations,
  }) : operations = List.unmodifiable(operations);
  final PrivateRepositoryId repository;
  final Revision expectedStoreRevision;
  final List<PrivateStorageMutation> operations;
  static Result<PrivateStorageBatch, StructuredFailure> create({
    required PrivateRepositoryId repository,
    required Revision expectedStoreRevision,
    required Iterable<PrivateStorageMutation> operations,
    required int maximumOperations,
  }) {
    try {
      final copied = List<PrivateStorageMutation>.of(operations);
      final ids = <PrivateRecordId>{};
      if (maximumOperations < 0 ||
          copied.length > maximumOperations ||
          copied.any(
            (operation) => !ids.add(
              operation is WritePrivateRecord
                  ? operation.id
                  : (operation as DeletePrivateRecord).id,
            ),
          ))
        return Err(_storageFailure('invalid_batch'));
      return Ok(
        PrivateStorageBatch._(
          repository: repository,
          expectedStoreRevision: expectedStoreRevision,
          operations: copied,
        ),
      );
    } on Object {
      return Err(_storageFailure('invalid_batch'));
    }
  }
}

/// Closed evidence describing storage commit atomicity.
final class StorageAtomicityEvidence {
  const StorageAtomicityEvidence._({required this.atomic});
  static const atomicCommit = StorageAtomicityEvidence._(atomic: true);
  static const nonAtomic = StorageAtomicityEvidence._(atomic: false);
  final bool atomic;
}

/// Validated durability and flush evidence for a storage commit.
final class StorageDurabilityEvidence {
  const StorageDurabilityEvidence._({
    required this.durable,
    required this.flushed,
  });
  final bool durable;
  final bool flushed;
  static Result<StorageDurabilityEvidence, StructuredFailure> create({
    required bool durable,
    required bool flushed,
  }) => !flushed || durable
      ? Ok(StorageDurabilityEvidence._(durable: durable, flushed: flushed))
      : Err(_storageFailure('invalid_durability'));
}

/// Closed storage-pressure states reported by an adapter.
enum StoragePressure { normal, elevated, low, quotaExceeded }

/// Validated storage pressure and available-byte evidence.
final class StoragePressureEvidence {
  const StoragePressureEvidence._({
    required this.pressure,
    required this.availableBytes,
  });
  final StoragePressure pressure;
  final int? availableBytes;
  static Result<StoragePressureEvidence, StructuredFailure> create({
    required StoragePressure pressure,
    required int? availableBytes,
  }) =>
      (availableBytes == null ||
              (availableBytes >= 0 && availableBytes <= 9007199254740991)) &&
          (pressure != StoragePressure.quotaExceeded || availableBytes == 0)
      ? Ok(
          StoragePressureEvidence._(
            pressure: pressure,
            availableBytes: availableBytes,
          ),
        )
      : Err(_storageFailure('invalid_pressure'));
}

/// Bounded corruption evidence for private records.
final class StorageCorruptionEvidence {
  const StorageCorruptionEvidence._({
    required this.recordCount,
    required this.lastKnownGoodAvailable,
  });
  final int recordCount;
  final bool lastKnownGoodAvailable;
  static Result<StorageCorruptionEvidence, StructuredFailure> create({
    required int recordCount,
    required bool lastKnownGoodAvailable,
  }) => recordCount > 0 && recordCount <= 9007199254740991
      ? Ok(
          StorageCorruptionEvidence._(
            recordCount: recordCount,
            lastKnownGoodAvailable: lastKnownGoodAvailable,
          ),
        )
      : Err(_storageFailure('invalid_corruption'));
  @override
  String toString() => 'StorageCorruptionEvidence(records: $recordCount)';
}

/// Monotonic revision evidence for an external store change.
final class ExternalStoreChangeEvidence {
  const ExternalStoreChangeEvidence._({
    required this.previousRevision,
    required this.currentRevision,
  });
  final Revision previousRevision;
  final Revision currentRevision;
  static Result<ExternalStoreChangeEvidence, StructuredFailure> create({
    required Revision previousRevision,
    required Revision currentRevision,
  }) => currentRevision.compareTo(previousRevision) > 0
      ? Ok(
          ExternalStoreChangeEvidence._(
            previousRevision: previousRevision,
            currentRevision: currentRevision,
          ),
        )
      : Err(_storageFailure('invalid_external_change'));
}

/// Validated atomic commit evidence for private storage.
final class PrivateStorageCommitEvidence {
  const PrivateStorageCommitEvidence._({
    required this.storeRevision,
    required this.atomicity,
    required this.durability,
  });
  final Revision storeRevision;
  final StorageAtomicityEvidence atomicity;
  final StorageDurabilityEvidence durability;
  static Result<PrivateStorageCommitEvidence, StructuredFailure> create({
    required Revision storeRevision,
    required StorageAtomicityEvidence atomicity,
    required StorageDurabilityEvidence durability,
  }) => atomicity.atomic
      ? Ok(
          PrivateStorageCommitEvidence._(
            storeRevision: storeRevision,
            atomicity: atomicity,
            durability: durability,
          ),
        )
      : Err(_storageFailure('non_atomic_commit'));
}

/// Bounded immutable enumeration of private records.
final class PrivateStorageEnumeration {
  PrivateStorageEnumeration._({
    required Iterable<PrivateByteRecord> records,
    required this.truncated,
  }) : records = List.unmodifiable(records);
  final List<PrivateByteRecord> records;
  final bool truncated;
  static Result<PrivateStorageEnumeration, StructuredFailure> create({
    required Iterable<PrivateByteRecord> records,
    required bool truncated,
    required int maximumResults,
    required int maximumRecordBytes,
  }) {
    try {
      final copied = List<PrivateByteRecord>.of(records);
      final ids = <PrivateRecordId>{};
      if (maximumResults < 0 ||
          maximumRecordBytes < 0 ||
          copied.length > maximumResults ||
          copied.any(
            (record) =>
                record.bytes.length > maximumRecordBytes || !ids.add(record.id),
          ))
        return Err(_storageFailure('invalid_enumeration'));
      return Ok(
        PrivateStorageEnumeration._(records: copied, truncated: truncated),
      );
    } on Object {
      return Err(_storageFailure('invalid_enumeration'));
    }
  }
}

/// Bounded duplicate-free cleanup plan guarded by a store revision.
final class PrivateCleanupPlan {
  PrivateCleanupPlan._({
    required this.repository,
    required this.expectedStoreRevision,
    required Iterable<PrivateRecordId> records,
  }) : records = List.unmodifiable(records);
  final PrivateRepositoryId repository;
  final Revision expectedStoreRevision;
  final List<PrivateRecordId> records;
  static Result<PrivateCleanupPlan, StructuredFailure> create({
    required PrivateRepositoryId repository,
    required Revision expectedStoreRevision,
    required Iterable<PrivateRecordId> records,
    required int maximumRecords,
  }) {
    try {
      final copied = List<PrivateRecordId>.of(records);
      if (maximumRecords < 0 ||
          copied.length > maximumRecords ||
          copied.toSet().length != copied.length) {
        return Err(_storageFailure('invalid_cleanup'));
      }
      return Ok(
        PrivateCleanupPlan._(
          repository: repository,
          expectedStoreRevision: expectedStoreRevision,
          records: copied,
        ),
      );
    } on Object {
      return Err(_storageFailure('invalid_cleanup'));
    }
  }
}

/// Portable, bounded, revision-checked private byte storage contract.
abstract interface class PrivateStorage {
  Future<OperationOutcome<Revision, StructuredFailure>> revision(
    PrivateRepositoryId repository, {
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<PrivateByteRecord?, StructuredFailure>> read(
    PrivateRepositoryId repository,
    PrivateRecordId id, {
    required int maximumBytes,
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<PrivateStorageEnumeration, StructuredFailure>>
  enumerate(
    PrivateRepositoryId repository, {
    required int maximumResults,
    required int maximumRecordBytes,
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<PrivateStorageCommitEvidence, StructuredFailure>>
  commit(
    PrivateStorageBatch batch, {
    required int maximumOperations,
    required int maximumRecordBytes,
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<PrivateStorageCommitEvidence, StructuredFailure>>
  cleanup(
    PrivateCleanupPlan plan, {
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<StoragePressureEvidence, StructuredFailure>>
  pressure({required CancellationToken cancellationToken});
}

List<int> _copyBytes(Iterable<int> source) => List.unmodifiable(source);

List<int> _checkedBytes(Iterable<int> source) {
  final copied = List<int>.of(source);
  if (copied.any((v) => v < 0 || v > 255))
    throw ArgumentError('Bytes must be unsigned.');
  return List.unmodifiable(copied);
}

StructuredFailure _storageFailure(String leaf) => StructuredFailure(
  code: 'platform.private_storage.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Private storage data is invalid.',
);
