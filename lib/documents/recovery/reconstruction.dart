// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../model/identifiers.dart';
import 'contracts.dart';

/// Validates one reconstructed persistent value using ordinary document rules.
typedef RecoveredValueValidator<T> = bool Function(T value);

/// Verifies that one retained resource is currently available and valid.
typedef RecoveryResourceValidator =
    bool Function(RetainedResourceEvidence resource);

/// Caller-supplied current coordination facts used to judge separate opening.
final class RecoveryReconstructionContext {
  const RecoveryReconstructionContext({
    required this.expectedSetId,
    required this.expectedDocumentId,
    required this.currentOwnership,
    required this.externalSourceCertain,
    required this.coordinationCertain,
  });

  /// Recovery set selected by bounded discovery.
  final RecoverySetId expectedSetId;

  /// Durable Document identity expected by the caller.
  final DocumentId expectedDocumentId;

  /// Current typed lease/branch evidence, if available.
  final RecoveryOwnershipEvidence? currentOwnership;

  /// Whether external canonical-source state is known.
  final bool externalSourceCertain;

  /// Whether process/tab ownership coordination is known.
  final bool coordinationCertain;
}

/// Redaction-safe reconstruction ordering and corruption evidence.
final class RecoveryReconstructionEvidence {
  const RecoveryReconstructionEvidence({
    required this.generation,
    required this.appliedTransactions,
    required this.lostOrCorruptTail,
    required this.usedFallbackGeneration,
  });
  final RecoveryGeneration generation;
  final int appliedTransactions;
  final bool lostOrCorruptTail;
  final bool usedFallbackGeneration;
  @override
  String toString() =>
      'RecoveryReconstructionEvidence(generation: ${generation.value}, applied: $appliedTransactions, lostTail: $lostOrCorruptTail)';
}

/// Valid reconstructed output that always opens with a new dirty baseline.
final class RecoveredCandidate<T> {
  const RecoveredCandidate({
    required this.value,
    required this.evidence,
    required this.opensDirty,
    required this.opensSeparately,
  });
  final T value;
  final RecoveryReconstructionEvidence evidence;
  final bool opensDirty;
  final bool opensSeparately;
}

/// Selects the newest valid generation and applies its valid committed prefix.
final class RecoveryReconstructor<T> {
  const RecoveryReconstructor({
    required this.codec,
    required this.validator,
    required this.resourceValidator,
  });
  final RecoveryCodec<T> codec;
  final RecoveredValueValidator<T> validator;
  final RecoveryResourceValidator resourceValidator;

  /// Reconstructs without trusting timestamps or stored ownership booleans.
  OperationOutcome<RecoveredCandidate<T>, StructuredFailure> reconstruct(
    Iterable<RecoveryGenerationRecord> records, {
    required RecoveryReconstructionContext context,
    required int maximumCheckpointBytes,
    required int maximumJournalBytes,
    required int maximumSteps,
    required int maximumResources,
    required CancellationToken cancellationToken,
  }) {
    if (maximumCheckpointBytes < 0 ||
        maximumJournalBytes < 0 ||
        maximumSteps < 0 ||
        maximumResources < 0) {
      return Failed(_failure('invalid_limits'));
    }
    final candidates = List<RecoveryGenerationRecord>.of(records)
      ..sort(
        (left, right) =>
            right.manifest.generation.compareTo(left.manifest.generation),
      );
    var steps = 0;
    for (
      var candidateIndex = 0;
      candidateIndex < candidates.length;
      candidateIndex += 1
    ) {
      if (cancellationToken.isCancelled) {
        return Cancelled(cancellationToken.reason);
      }
      if (!_takeStep(++steps, maximumSteps)) {
        return Failed(_failure('step_limit'));
      }
      final record = candidates[candidateIndex];
      if (record.manifest.setId != context.expectedSetId ||
          record.manifest.documentId != context.expectedDocumentId ||
          record.manifest.generation != record.checkpoint.generation ||
          !record.checkpoint.committed ||
          record.checkpoint.bytes.length > maximumCheckpointBytes ||
          record.checkpoint.hash != record.manifest.checkpointHash) {
        continue;
      }
      final manifestResources = _indexedResources(
        record.manifest.retainedResources,
      );
      final checkpointResources = _indexedResources(
        record.checkpoint.resources,
      );
      if (manifestResources == null ||
          checkpointResources == null ||
          checkpointResources.length > maximumResources ||
          !_sharedResourcesAgree(manifestResources, checkpointResources) ||
          !_resourcesValid(checkpointResources.values)) {
        continue;
      }
      OperationOutcome<T, StructuredFailure> decoded;
      try {
        decoded = codec.decodeCheckpoint(
          record.checkpoint.bytes,
          maximumBytes: maximumCheckpointBytes,
          cancellationToken: cancellationToken,
        );
      } on Object {
        continue;
      }
      if (decoded is! Completed<T, StructuredFailure>) continue;
      var value = decoded.value;
      final initialHash = _hash(value);
      if (initialHash == null || initialHash != record.checkpoint.hash)
        continue;
      var expectedHash = record.checkpoint.hash;
      var expectedSequence = 1;
      var applied = 0;
      var cumulativeBytes = 0;
      var lostTail = false;
      final seenTransactions = <RecoveryTransactionId>{};
      final validatedResources =
          Map<ResourceIdentity, RetainedResourceEvidence>.of(
            checkpointResources,
          );
      for (final journalRecord in record.journal) {
        if (cancellationToken.isCancelled) {
          return Cancelled(cancellationToken.reason);
        }
        final transaction = journalRecord.transaction;
        if (!journalRecord.committed) {
          lostTail = true;
          break;
        }
        if (!_takeStep(++steps, maximumSteps) ||
            transaction.sequence.value != expectedSequence ||
            !seenTransactions.add(transaction.transactionId) ||
            transaction.baseHash != expectedHash ||
            cumulativeBytes >
                9007199254740991 - transaction.replacementBytes.length) {
          lostTail = true;
          break;
        }
        cumulativeBytes += transaction.replacementBytes.length;
        if (cumulativeBytes > maximumJournalBytes) {
          lostTail = true;
          break;
        }
        OperationOutcome<T, StructuredFailure> replaced;
        try {
          replaced = codec.applyReplacement(
            value,
            transaction.replacementBytes,
            maximumBytes: maximumJournalBytes,
            cancellationToken: cancellationToken,
          );
        } on Object {
          lostTail = true;
          break;
        }
        if (replaced is! Completed<T, StructuredFailure>) {
          lostTail = true;
          break;
        }
        final resultingHash = _hash(replaced.value);
        if (resultingHash == null ||
            resultingHash != transaction.resultingHash) {
          lostTail = true;
          break;
        }
        final changes = transaction.resourceChanges;
        final indexedChanges = _indexedResources(changes);
        if (indexedChanges == null) {
          lostTail = true;
          break;
        }
        final newIdentities = indexedChanges.keys
            .where((identity) => !validatedResources.containsKey(identity))
            .length;
        if (validatedResources.length > maximumResources - newIdentities ||
            indexedChanges.entries.any((entry) {
              final inventory = manifestResources[entry.key];
              return inventory != null &&
                  !_sameResource(inventory, entry.value);
            }) ||
            !_resourcesValid(indexedChanges.values)) {
          lostTail = true;
          break;
        }
        validatedResources.addAll(indexedChanges);
        value = replaced.value;
        expectedHash = resultingHash;
        expectedSequence += 1;
        applied += 1;
      }
      if (record.manifest.lastSequence.value != applied) lostTail = true;
      try {
        if (!validator(value)) continue;
      } on Object {
        continue;
      }
      final ownership = context.currentOwnership;
      final sameOwnership =
          ownership != null &&
          ownership.leaseId == record.manifest.ownership.leaseId &&
          ownership.leaseGeneration ==
              record.manifest.ownership.leaseGeneration &&
          ownership.branchIdentity ==
              record.manifest.ownership.branchIdentity &&
          ownership.valid;
      return Completed(
        RecoveredCandidate(
          value: value,
          evidence: RecoveryReconstructionEvidence(
            generation: record.manifest.generation,
            appliedTransactions: applied,
            lostOrCorruptTail: lostTail,
            usedFallbackGeneration: candidateIndex > 0,
          ),
          opensDirty: true,
          opensSeparately:
              !sameOwnership ||
              !context.externalSourceCertain ||
              !context.coordinationCertain,
        ),
      );
    }
    return Failed(_failure('no_valid_generation'));
  }

  RecoveryHash? _hash(T value) {
    try {
      final result = codec.hashOf(value);
      return result is Ok<RecoveryHash, StructuredFailure>
          ? result.value
          : null;
    } on Object {
      return null;
    }
  }

  bool _resourcesValid(Iterable<RetainedResourceEvidence> resources) {
    try {
      for (final resource in resources) {
        if (!resourceValidator(resource)) return false;
      }
      return true;
    } on Object {
      return false;
    }
  }

  Map<ResourceIdentity, RetainedResourceEvidence>? _indexedResources(
    Iterable<RetainedResourceEvidence> resources,
  ) {
    final indexed = <ResourceIdentity, RetainedResourceEvidence>{};
    for (final resource in resources) {
      final previous = indexed[resource.id];
      if (previous != null && !_sameResource(previous, resource)) return null;
      indexed[resource.id] = resource;
    }
    return indexed;
  }

  bool _sharedResourcesAgree(
    Map<ResourceIdentity, RetainedResourceEvidence> manifest,
    Map<ResourceIdentity, RetainedResourceEvidence> checkpoint,
  ) {
    for (final entry in checkpoint.entries) {
      final inventory = manifest[entry.key];
      if (inventory != null && !_sameResource(inventory, entry.value)) {
        return false;
      }
    }
    return true;
  }
}

bool _sameResource(
  RetainedResourceEvidence left,
  RetainedResourceEvidence right,
) =>
    left.id == right.id &&
    left.hash == right.hash &&
    left.byteLength == right.byteLength;

bool _takeStep(int steps, int maximumSteps) => steps <= maximumSteps;

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'documents.recovery.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.afterUserAction,
  message: 'Recovery reconstruction could not produce a valid candidate.',
);
