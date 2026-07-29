// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import 'definitions.dart';

/// Revision of the complete persisted Settings store.
final class SettingsStoreRevision {
  const SettingsStoreRevision(this.value);
  final Revision value;
}

/// Revision of one persisted Setting record.
final class SettingsRecordRevision {
  const SettingsRecordRevision(this.value);
  final Revision value;
}

/// Immutable logical override record. Unknown bytes are preserved inertly.
final class SettingsLogicalRecord {
  SettingsLogicalRecord._({
    required this.key,
    required this.scope,
    required this.schemaVersion,
    required this.codecIdentity,
    required this.recordRevision,
    required Iterable<int> valueBytes,
    required Map<String, List<int>> unknownFields,
    required this.active,
    required this.lastKnownGood,
  }) : valueBytes = List.unmodifiable(valueBytes),
       unknownFields = UnmodifiableMapView(
         Map.fromEntries(
           unknownFields.entries.map(
             (e) => MapEntry(e.key, List.unmodifiable(e.value)),
           ),
         ),
       );
  final SettingKey key;
  final SettingScope scope;
  final int schemaVersion;
  final String codecIdentity;
  final SettingsRecordRevision recordRevision;
  final List<int> valueBytes;
  final Map<String, List<int>> unknownFields;
  final bool active;
  final bool lastKnownGood;
  @override
  String toString() =>
      'SettingsLogicalRecord(key: $key, scope: ${scope.name}, bytes: ${valueBytes.length}, active: $active)';

  /// Creates one bounded immutable override record.
  static Result<SettingsLogicalRecord, StructuredFailure> create({
    required SettingKey key,
    required SettingScope scope,
    required int schemaVersion,
    required String codecIdentity,
    required SettingsRecordRevision recordRevision,
    required Iterable<int> valueBytes,
    required Map<String, List<int>> unknownFields,
    required bool active,
    required bool lastKnownGood,
    required int maximumValueBytes,
    required int maximumUnknownFields,
  }) {
    try {
      if (!_validLimit(maximumValueBytes) ||
          !_validLimit(maximumUnknownFields)) {
        return Err(_failure('invalid_record'));
      }
      final capturedBytes = _boundedBytes(valueBytes, maximumValueBytes);
      if (capturedBytes == null) return Err(_failure('invalid_record'));
      final capturedFields = _boundedSettingsMap(
        unknownFields,
        maximumUnknownFields,
      );
      if (capturedFields == null) return Err(_failure('invalid_record'));
      final fields = <String, List<int>>{};
      for (final entry in capturedFields.entries) {
        final captured = _boundedBytes(entry.value, maximumValueBytes);
        if (captured == null) return Err(_failure('invalid_record'));
        fields[entry.key] = captured;
      }
      final safeCodec = RegExp(r'^[a-zA-Z0-9._-]{1,128}$');
      final safeField = RegExp(r'^[a-zA-Z][a-zA-Z0-9._-]{0,127}$');
      if ((scope != SettingScope.user && scope != SettingScope.deviceLocal) ||
          schemaVersion <= 0 ||
          schemaVersion > 9007199254740991 ||
          !safeCodec.hasMatch(codecIdentity) ||
          fields.keys.any((field) => !safeField.hasMatch(field))) {
        return Err(_failure('invalid_record'));
      }
      return Ok(
        SettingsLogicalRecord._(
          key: key,
          scope: scope,
          schemaVersion: schemaVersion,
          codecIdentity: codecIdentity,
          recordRevision: recordRevision,
          valueBytes: capturedBytes,
          unknownFields: fields,
          active: active,
          lastKnownGood: lastKnownGood,
        ),
      );
    } on Object {
      return Err(_failure('invalid_record'));
    }
  }
}

/// Bounded inert record retained for forward-compatible preservation.
final class UnknownSettingsRecord {
  UnknownSettingsRecord._({
    required this.identity,
    required Iterable<int> bytes,
    required this.supported,
  }) : bytes = List.unmodifiable(bytes);
  final String identity;
  final List<int> bytes;
  final bool supported;
  @override
  String toString() =>
      'UnknownSettingsRecord(bytes: ${bytes.length}, supported: $supported)';

  /// Creates one bounded inert unknown record.
  static Result<UnknownSettingsRecord, StructuredFailure> create({
    required String identity,
    required Iterable<int> bytes,
    required bool supported,
    required int maximumBytes,
  }) {
    try {
      final copied = _boundedBytes(bytes, maximumBytes);
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9._-]{0,127}$').hasMatch(identity) ||
          copied == null) {
        return Err(_failure('invalid_unknown_record'));
      }
      return Ok(
        UnknownSettingsRecord._(
          identity: identity,
          bytes: copied,
          supported: supported,
        ),
      );
    } on Object {
      return Err(_failure('invalid_unknown_record'));
    }
  }
}

/// Validated complete snapshot returned by a persistence adapter.
final class SettingsPersistenceSnapshot {
  SettingsPersistenceSnapshot._({
    required this.storeRevision,
    required Iterable<SettingsLogicalRecord> records,
    required Iterable<UnknownSettingsRecord> unknownRecords,
    required this.damaged,
    required this.lastKnownGoodAvailable,
  }) : records = List.unmodifiable(records),
       unknownRecords = List.unmodifiable(unknownRecords);
  final SettingsStoreRevision storeRevision;
  final List<SettingsLogicalRecord> records;
  final List<UnknownSettingsRecord> unknownRecords;
  final bool damaged;
  final bool lastKnownGoodAvailable;

  /// Validates hostile adapter output and creates an immutable snapshot.
  static Result<SettingsPersistenceSnapshot, StructuredFailure> create({
    required SettingsStoreRevision storeRevision,
    required Iterable<SettingsLogicalRecord> records,
    required Iterable<UnknownSettingsRecord> unknownRecords,
    required bool damaged,
    required bool lastKnownGoodAvailable,
    required int maximumRecords,
    required int maximumUnknownRecords,
    required int maximumUnknownFieldsPerRecord,
    required int maximumValueBytes,
  }) {
    try {
      final copiedRecords = _boundedIterable(records, maximumRecords);
      final copiedUnknown = _boundedIterable(
        unknownRecords,
        maximumUnknownRecords,
      );
      if (copiedRecords == null ||
          copiedUnknown == null ||
          !_validLimit(maximumValueBytes) ||
          !_validLimit(maximumUnknownFieldsPerRecord) ||
          copiedRecords.any(
            (record) =>
                record.valueBytes.length > maximumValueBytes ||
                record.valueBytes.any((byte) => byte < 0 || byte > 255) ||
                record.unknownFields.length > maximumUnknownFieldsPerRecord ||
                record.unknownFields.values.any(
                  (bytes) =>
                      bytes.length > maximumValueBytes ||
                      bytes.any((byte) => byte < 0 || byte > 255),
                ) ||
                record.scope == SettingScope.temporaryPreview,
          ) ||
          copiedUnknown.any(
            (record) =>
                record.bytes.length > maximumValueBytes ||
                record.bytes.any((byte) => byte < 0 || byte > 255),
          )) {
        return Err(_failure('invalid_adapter_snapshot'));
      }
      final logicalKeys = <(SettingKey, SettingScope)>{};
      if (copiedRecords.any(
        (record) => !logicalKeys.add((record.key, record.scope)),
      )) {
        return Err(_failure('duplicate_stored_record'));
      }
      final unknownIds = <String>{};
      if (copiedUnknown.any((record) => !unknownIds.add(record.identity))) {
        return Err(_failure('duplicate_unknown_record'));
      }
      return Ok(
        SettingsPersistenceSnapshot._(
          storeRevision: storeRevision,
          records: copiedRecords,
          unknownRecords: copiedUnknown,
          damaged: damaged,
          lastKnownGoodAvailable: lastKnownGoodAvailable,
        ),
      );
    } on Object {
      return Err(_failure('invalid_adapter_snapshot'));
    }
  }
}

/// Closed evidence describing whether a commit was atomic.
final class SettingsAtomicityEvidence {
  const SettingsAtomicityEvidence._({required this.atomic});
  static const atomicCommit = SettingsAtomicityEvidence._(atomic: true);
  static const nonAtomic = SettingsAtomicityEvidence._(atomic: false);
  final bool atomic;
}

/// Closed evidence describing persistence durability.
final class SettingsDurabilityEvidence {
  const SettingsDurabilityEvidence._({required this.durable});
  static const durableCommit = SettingsDurabilityEvidence._(durable: true);
  static const bestEffort = SettingsDurabilityEvidence._(durable: false);
  final bool durable;
}

/// Validated evidence returned after a Settings commit.
final class SettingsCommitEvidence {
  const SettingsCommitEvidence._({
    required this.storeRevision,
    required this.atomicity,
    required this.durability,
  });
  final SettingsStoreRevision storeRevision;
  final SettingsAtomicityEvidence atomicity;
  final SettingsDurabilityEvidence durability;

  /// Creates evidence only for a fully atomic transaction.
  static Result<SettingsCommitEvidence, StructuredFailure> create({
    required SettingsStoreRevision storeRevision,
    required SettingsAtomicityEvidence atomicity,
    required SettingsDurabilityEvidence durability,
  }) => atomicity.atomic
      ? Ok(
          SettingsCommitEvidence._(
            storeRevision: storeRevision,
            atomicity: atomicity,
            durability: durability,
          ),
        )
      : Err(_failure('non_atomic_commit'));
}

/// Hostile persistence boundary for complete Settings snapshots and commits.
abstract interface class SettingsPersistenceAdapter {
  Future<OperationOutcome<SettingsPersistenceSnapshot, StructuredFailure>>
  load({
    required int maximumRecords,
    required int maximumUnknownRecords,
    required int maximumUnknownFieldsPerRecord,
    required int maximumValueBytes,
    required CancellationToken cancellationToken,
  });
  Future<OperationOutcome<SettingsCommitEvidence, StructuredFailure>> commit({
    required SettingsStoreRevision expectedRevision,
    required List<SettingsLogicalRecord> records,
    required List<UnknownSettingsRecord> preservedUnknownRecords,
    required CancellationToken cancellationToken,
  });
}

/// Immutable typed Settings view resolved through registered handles.
final class SettingsSnapshot {
  SettingsSnapshot._({
    required SettingRegistry registry,
    required this.storeRevision,
    required Map<SettingKey, Object?> user,
    required Map<SettingKey, Object?> device,
    required Map<SettingKey, Object?> preview,
    required List<UnknownSettingsRecord> unknownRecords,
  }) : _registry = registry,
       _user = UnmodifiableMapView(
         Map.fromEntries(
           user.entries.map((e) => MapEntry(e.key, _Slot(e.value))),
         ),
       ),
       _device = UnmodifiableMapView(
         Map.fromEntries(
           device.entries.map((e) => MapEntry(e.key, _Slot(e.value))),
         ),
       ),
       _preview = UnmodifiableMapView(
         Map.fromEntries(
           preview.entries.map((e) => MapEntry(e.key, _Slot(e.value))),
         ),
       ),
       unknownRecords = List.unmodifiable(unknownRecords);
  final SettingRegistry _registry;
  final SettingsStoreRevision storeRevision;
  final Map<SettingKey, _Slot> _user, _device, _preview;
  final List<UnknownSettingsRecord> unknownRecords;

  Result<T, StructuredFailure> resolve<T>(
    RegisteredSettingDefinition<T> definition,
  ) {
    if (!_registry.owns(definition)) return Err(_failure('forged_definition'));
    final slot =
        _preview[definition.key] ??
        _device[definition.key] ??
        _user[definition.key];
    if (slot == null) return definition.defaultValue();
    final candidate = slot.value;
    if (candidate is! T) {
      return Err(_failure('type_mismatch'));
    }
    return definition.validated(candidate);
  }
}

final class _Slot {
  const _Slot(this.value);
  final Object? value;
}

/// Closed base for one typed Settings transaction operation.
sealed class SettingsDraftOperation {
  const SettingsDraftOperation(this.key, this.scope);
  final SettingKey key;
  final SettingScope scope;
}

/// Typed operation that sets one Setting value.
final class SetSettingValue<T> extends SettingsDraftOperation {
  const SetSettingValue({
    required SettingKey key,
    required SettingScope scope,
    required this.definition,
    required this.value,
  }) : super(key, scope);
  final RegisteredSettingDefinition<T> definition;
  final T value;
}

/// Operation that removes one scoped Setting override.
final class ResetSettingValue extends SettingsDraftOperation {
  const ResetSettingValue({
    required SettingKey key,
    required SettingScope scope,
  }) : super(key, scope);
}

/// Bounded immutable caller draft awaiting repository validation.
final class SettingsDraftTransaction {
  SettingsDraftTransaction._({
    required this.expectedRevision,
    required Iterable<SettingsDraftOperation> operations,
  }) : operations = List.unmodifiable(operations);
  final SettingsStoreRevision expectedRevision;
  final List<SettingsDraftOperation> operations;

  static Result<SettingsDraftTransaction, StructuredFailure> create({
    required SettingsStoreRevision expectedRevision,
    required Iterable<SettingsDraftOperation> operations,
    required int maximumOperations,
  }) {
    final captured = _boundedIterable(operations, maximumOperations);
    if (captured == null) {
      return Err(_failure('transaction_limit'));
    }
    return Ok(
      SettingsDraftTransaction._(
        expectedRevision: expectedRevision,
        operations: captured,
      ),
    );
  }
}

/// Repository-owned, one-use Settings change set.
final class ValidatedSettingsChangeSet {
  ValidatedSettingsChangeSet._({
    required this.expectedRevision,
    required List<SettingsDraftOperation> operations,
    required Object owner,
  }) : operations = List.unmodifiable(operations),
       _owner = owner;
  final SettingsStoreRevision expectedRevision;
  final List<SettingsDraftOperation> operations;
  final Object _owner;
  bool _consumed = false;
}

/// Redaction-safe optimistic-concurrency conflict evidence.
final class SettingsConflictEvidence {
  const SettingsConflictEvidence._({
    required this.expected,
    required this.actual,
    required this.overlap,
  });
  final SettingsStoreRevision expected;
  final SettingsStoreRevision actual;
  final bool overlap;
  static Result<SettingsConflictEvidence, StructuredFailure> create({
    required SettingsStoreRevision expected,
    required SettingsStoreRevision actual,
    required bool overlap,
  }) => expected.value != actual.value
      ? Ok(
          SettingsConflictEvidence._(
            expected: expected,
            actual: actual,
            overlap: overlap,
          ),
        )
      : Err(_failure('invalid_conflict_evidence'));
}

/// Bounded post-commit Setting-key change event.
final class SettingsChangeEvent {
  SettingsChangeEvent._({
    required this.previousRevision,
    required this.currentRevision,
    required Iterable<SettingKey> keys,
  }) : keys = List.unmodifiable(List<SettingKey>.of(keys)..sort());
  final SettingsStoreRevision previousRevision, currentRevision;
  final List<SettingKey> keys;
  static Result<SettingsChangeEvent, StructuredFailure> create({
    required SettingsStoreRevision previousRevision,
    required SettingsStoreRevision currentRevision,
    required Iterable<SettingKey> keys,
    required int maximumKeys,
  }) {
    if (maximumKeys < 0 || maximumKeys > 9007199254740991) {
      return Err(_failure('invalid_change_event'));
    }
    try {
      final copied = _boundedIterable(keys, maximumKeys);
      if (copied == null) {
        return Err(_failure('invalid_change_event'));
      }
      if (copied.toSet().length != copied.length ||
          currentRevision.value.compareTo(previousRevision.value) <= 0) {
        return Err(_failure('invalid_change_event'));
      }
      return Ok(
        SettingsChangeEvent._(
          previousRevision: previousRevision,
          currentRevision: currentRevision,
          keys: copied,
        ),
      );
    } on Object {
      return Err(_failure('invalid_change_event'));
    }
  }
}

/// Receives one immutable post-commit Settings event.
typedef SettingsListener = void Function(SettingsChangeEvent event);

/// Resolves previews and validates complete transactional change sets.
final class SettingsRepository {
  SettingsRepository._({
    required this.registry,
    required this.adapter,
    required SettingsPersistenceSnapshot persistence,
    required this.maximumListeners,
  }) : _persistence = persistence,
       _snapshot = SettingsSnapshot._(
         registry: registry,
         storeRevision: persistence.storeRevision,
         user: const {},
         device: const {},
         preview: const {},
         unknownRecords: persistence.unknownRecords,
       );
  final SettingRegistry registry;
  final SettingsPersistenceAdapter adapter;
  final int maximumListeners;
  SettingsPersistenceSnapshot _persistence;
  SettingsSnapshot _snapshot;
  final List<SettingsListener> _listeners = [];
  final Object _changeSetOwner = Object();
  bool _poisoned = false;
  bool _operationActive = false;
  Object _generation = Object();
  SettingsSnapshot get snapshot => _snapshot;
  bool get reloadRequired => _poisoned;

  static Future<OperationOutcome<SettingsRepository, StructuredFailure>> open({
    required SettingRegistry registry,
    required SettingsPersistenceAdapter adapter,
    required int maximumRecords,
    required int maximumUnknownRecords,
    required int maximumUnknownFieldsPerRecord,
    required int maximumValueBytes,
    required int maximumListeners,
    required CancellationToken cancellationToken,
  }) async {
    if (maximumRecords < 0 ||
        maximumUnknownRecords < 0 ||
        maximumUnknownFieldsPerRecord < 0 ||
        maximumValueBytes < 0 ||
        maximumRecords > 9007199254740991 ||
        maximumValueBytes > 9007199254740991 ||
        maximumUnknownRecords > 9007199254740991 ||
        maximumUnknownFieldsPerRecord > 9007199254740991 ||
        maximumListeners < 0 ||
        maximumListeners > 9007199254740991) {
      return Failed(_failure('invalid_limits'));
    }
    OperationOutcome<SettingsPersistenceSnapshot, StructuredFailure> loaded;
    try {
      loaded = await adapter.load(
        maximumRecords: maximumRecords,
        maximumUnknownRecords: maximumUnknownRecords,
        maximumUnknownFieldsPerRecord: maximumUnknownFieldsPerRecord,
        maximumValueBytes: maximumValueBytes,
        cancellationToken: cancellationToken,
      );
    } on Object {
      return Failed(_failure('adapter_load'));
    }
    if (loaded is Cancelled<SettingsPersistenceSnapshot, StructuredFailure>)
      return Cancelled(loaded.reason);
    if (loaded is Failed<SettingsPersistenceSnapshot, StructuredFailure>)
      return Failed(_failure('adapter_load'));
    final persistence =
        (loaded as Completed<SettingsPersistenceSnapshot, StructuredFailure>)
            .value;
    final revalidated = SettingsPersistenceSnapshot.create(
      storeRevision: persistence.storeRevision,
      records: persistence.records,
      unknownRecords: persistence.unknownRecords,
      damaged: persistence.damaged,
      lastKnownGoodAvailable: persistence.lastKnownGoodAvailable,
      maximumRecords: maximumRecords,
      maximumUnknownRecords: maximumUnknownRecords,
      maximumUnknownFieldsPerRecord: maximumUnknownFieldsPerRecord,
      maximumValueBytes: maximumValueBytes,
    );
    if (revalidated is Err<SettingsPersistenceSnapshot, StructuredFailure>) {
      return Failed(revalidated.error);
    }
    final validatedPersistence =
        (revalidated as Ok<SettingsPersistenceSnapshot, StructuredFailure>)
            .value;
    if (validatedPersistence.damaged &&
        !validatedPersistence.lastKnownGoodAvailable)
      return Failed(_failure('damaged_store'));
    final repository = SettingsRepository._(
      registry: registry,
      adapter: adapter,
      persistence: validatedPersistence,
      maximumListeners: maximumListeners,
    );
    final activation = repository._activate(maximumValueBytes);
    if (activation is Err<void, StructuredFailure>)
      return Failed(activation.error);
    return Completed(repository);
  }

  /// Listener notification occurs only after commit. It snapshots listeners;
  /// mutation affects later notifications, reentrancy is allowed, and exceptions are isolated.
  Result<void, StructuredFailure> addListener(SettingsListener listener) {
    if (_listeners.contains(listener)) return const Ok(null);
    if (_listeners.length >= maximumListeners) {
      return Err(_failure('listener_limit'));
    }
    _listeners.add(listener);
    return const Ok(null);
  }

  void removeListener(SettingsListener listener) => _listeners.remove(listener);

  Result<void, StructuredFailure> installPreview<T>(
    RegisteredSettingDefinition<T> definition,
    T value, {
    required int maximumPreviews,
  }) {
    if (_poisoned) return Err(_failure('reload_required'));
    if (_operationActive) return Err(_failure('operation_active'));
    if (maximumPreviews < 0 || maximumPreviews > 9007199254740991) {
      return Err(_failure('invalid_preview_limit'));
    }
    if (!registry.owns(definition)) return Err(_failure('forged_definition'));
    if (!definition.previewSupported)
      return Err(_failure('preview_unsupported'));
    final validated = definition.validated(value);
    if (validated is Err<T, StructuredFailure>) return Err(validated.error);
    if (!_snapshot._preview.containsKey(definition.key) &&
        _snapshot._preview.length >= maximumPreviews)
      return Err(_failure('preview_limit'));
    final preview = _slotValues(_snapshot._preview)
      ..[definition.key] = (validated as Ok<T, StructuredFailure>).value;
    _snapshot = SettingsSnapshot._(
      registry: registry,
      storeRevision: _snapshot.storeRevision,
      user: _slotValues(_snapshot._user),
      device: _slotValues(_snapshot._device),
      preview: preview,
      unknownRecords: _snapshot.unknownRecords,
    );
    _generation = Object();
    return const Ok(null);
  }

  Result<void, StructuredFailure> cancelPreviews() {
    if (_operationActive) return Err(_failure('operation_active'));
    _snapshot = SettingsSnapshot._(
      registry: registry,
      storeRevision: _snapshot.storeRevision,
      user: _slotValues(_snapshot._user),
      device: _slotValues(_snapshot._device),
      preview: const {},
      unknownRecords: _snapshot.unknownRecords,
    );
    _generation = Object();
    return const Ok(null);
  }

  Result<ValidatedSettingsChangeSet, StructuredFailure> validate(
    SettingsDraftTransaction draft, {
    required int maximumOperations,
  }) {
    if (_poisoned) return Err(_failure('reload_required'));
    if (maximumOperations < 0 ||
        maximumOperations > 9007199254740991 ||
        draft.operations.length > maximumOperations) {
      return Err(_failure('transaction_limit'));
    }
    if (draft.expectedRevision.value != _snapshot.storeRevision.value)
      return Err(_failure('stale_transaction'));
    final seen = <(SettingKey, SettingScope)>{};
    for (final operation in draft.operations) {
      if (operation.scope == SettingScope.temporaryPreview ||
          !seen.add((operation.key, operation.scope)))
        return Err(_failure('invalid_transaction'));
      if (operation is SetSettingValue<Object?>) {
        if (!registry.owns(operation.definition) ||
            operation.definition.key != operation.key ||
            !operation.definition.permittedPersistentScopes.contains(
              operation.scope,
            ) ||
            operation.definition.validated(operation.value)
                is Err<Object?, StructuredFailure>)
          return Err(_failure('validation_failed'));
      } else if (operation is ResetSettingValue) {
        final validReset = registry.visit<bool>(
          operation.key,
          _ResetScopeVisitor(operation.scope),
          false,
        );
        if (!validReset) return Err(_failure('invalid_reset'));
      }
    }
    return Ok(
      ValidatedSettingsChangeSet._(
        expectedRevision: draft.expectedRevision,
        operations: draft.operations,
        owner: _changeSetOwner,
      ),
    );
  }

  Future<OperationOutcome<SettingsCommitEvidence, StructuredFailure>> apply(
    ValidatedSettingsChangeSet changes, {
    required int maximumValueBytes,
    required CancellationToken cancellationToken,
  }) async {
    if (maximumValueBytes < 0 || maximumValueBytes > 9007199254740991) {
      return Failed(_failure('invalid_value_limit'));
    }
    if (_poisoned) return Failed(_failure('reload_required'));
    if (!identical(changes._owner, _changeSetOwner) || changes._consumed) {
      return Failed(_failure('invalid_change_set'));
    }
    if (_operationActive) return Failed(_failure('operation_active'));
    if (changes.expectedRevision.value != _snapshot.storeRevision.value)
      return Failed(_failure('stale_transaction'));
    _operationActive = true;
    final startingGeneration = _generation;
    final startingRevision = _snapshot.storeRevision;
    final startingPersistence = _persistence;
    try {
      final nextStoreRevision = _snapshot.storeRevision.value.increment();
      if (nextStoreRevision is Err<Revision, StructuredFailure>) {
        return Failed(_failure('store_revision_overflow'));
      }
      final expectedNext = SettingsStoreRevision(
        (nextStoreRevision as Ok<Revision, StructuredFailure>).value,
      );
      final records = List<SettingsLogicalRecord>.of(_persistence.records);
      for (final operation in changes.operations) {
        final existing = records
            .where(
              (record) =>
                  record.key == operation.key &&
                  record.scope == operation.scope,
            )
            .firstOrNull;
        records.removeWhere(
          (record) =>
              record.key == operation.key && record.scope == operation.scope,
        );
        if (operation is SetSettingValue<Object?>) {
          if (!registry.owns(operation.definition)) {
            return Failed(_failure('forged_definition'));
          }
          final normalized = operation.definition.validated(operation.value);
          if (normalized is Err<Object?, StructuredFailure>)
            return Failed(_failure('validation_failed'));
          final encoded = operation.definition.encodeValue(
            (normalized as Ok<Object?, StructuredFailure>).value,
            maximumBytes: maximumValueBytes,
          );
          if (encoded is Err<List<int>, StructuredFailure>)
            return Failed(_failure('encoding_failed'));
          final recordRevision = existing == null
              ? _zeroRevision()
              : existing.recordRevision.value.increment().fold(
                  onOk: (value) => value,
                  onErr: (_) => null,
                );
          if (recordRevision == null) {
            return Failed(_failure('record_revision_overflow'));
          }
          final record = SettingsLogicalRecord.create(
            key: operation.key,
            scope: operation.scope,
            schemaVersion: operation.definition.schemaVersion,
            codecIdentity: operation.definition.codec.identity,
            recordRevision: SettingsRecordRevision(recordRevision),
            valueBytes: (encoded as Ok<List<int>, StructuredFailure>).value,
            unknownFields: const {},
            active: true,
            lastKnownGood: true,
            maximumValueBytes: maximumValueBytes,
            maximumUnknownFields: 0,
          );
          if (record is Err<SettingsLogicalRecord, StructuredFailure>) {
            return Failed(record.error);
          }
          records.add(
            (record as Ok<SettingsLogicalRecord, StructuredFailure>).value,
          );
        }
      }
      final candidatePersistence = SettingsPersistenceSnapshot._(
        storeRevision: expectedNext,
        records: records,
        unknownRecords: _persistence.unknownRecords,
        damaged: false,
        lastKnownGoodAvailable: true,
      );
      final candidateSnapshot = _buildSnapshot(
        candidatePersistence,
        maximumValueBytes,
        const {},
      );
      if (candidateSnapshot is Err<SettingsSnapshot, StructuredFailure>) {
        return Failed(candidateSnapshot.error);
      }
      OperationOutcome<SettingsCommitEvidence, StructuredFailure> committed;
      changes._consumed = true;
      try {
        committed = await adapter.commit(
          expectedRevision: changes.expectedRevision,
          records: List.unmodifiable(records),
          preservedUnknownRecords: _persistence.unknownRecords,
          cancellationToken: cancellationToken,
        );
      } on Object {
        return Failed(_failure('adapter_commit'));
      }
      if (committed is! Completed<SettingsCommitEvidence, StructuredFailure>)
        return committed is Cancelled<SettingsCommitEvidence, StructuredFailure>
            ? Cancelled(committed.reason)
            : Failed(_failure('adapter_commit'));
      final evidence = committed.value;
      if (!identical(_generation, startingGeneration) ||
          _snapshot.storeRevision.value != startingRevision.value ||
          !identical(_persistence, startingPersistence)) {
        _poisoned = true;
        return Failed(_failure('authoritative_state_changed'));
      }
      if (evidence.storeRevision.value != expectedNext.value ||
          !evidence.atomicity.atomic) {
        _poisoned = true;
        return Failed(_failure('adapter_evidence_mismatch'));
      }
      final previous = _snapshot.storeRevision;
      final eventResult = SettingsChangeEvent.create(
        previousRevision: previous,
        currentRevision: evidence.storeRevision,
        keys: changes.operations.map((o) => o.key).toSet(),
        maximumKeys: changes.operations.length,
      );
      if (eventResult is Err<SettingsChangeEvent, StructuredFailure>) {
        _poisoned = true;
        return Failed(_failure('event_evidence_mismatch'));
      }
      final event =
          (eventResult as Ok<SettingsChangeEvent, StructuredFailure>).value;
      _persistence = candidatePersistence;
      _snapshot =
          (candidateSnapshot as Ok<SettingsSnapshot, StructuredFailure>).value;
      _generation = Object();
      for (final listener in List<SettingsListener>.of(_listeners)) {
        try {
          listener(event);
        } on Object {
          /* isolated */
        }
      }
      return Completed(evidence);
    } finally {
      _operationActive = false;
    }
  }

  Future<OperationOutcome<void, StructuredFailure>> reload({
    required int maximumRecords,
    required int maximumUnknownRecords,
    required int maximumUnknownFieldsPerRecord,
    required int maximumValueBytes,
    required CancellationToken cancellationToken,
  }) async {
    if (maximumRecords < 0 ||
        maximumUnknownRecords < 0 ||
        maximumUnknownFieldsPerRecord < 0 ||
        maximumValueBytes < 0 ||
        maximumRecords > 9007199254740991 ||
        maximumValueBytes > 9007199254740991 ||
        maximumUnknownRecords > 9007199254740991 ||
        maximumUnknownFieldsPerRecord > 9007199254740991) {
      return Failed(_failure('invalid_limits'));
    }
    if (_operationActive) return Failed(_failure('operation_active'));
    _operationActive = true;
    final startingGeneration = _generation;
    final startingRevision = _snapshot.storeRevision;
    final startingPersistence = _persistence;
    try {
      OperationOutcome<SettingsPersistenceSnapshot, StructuredFailure> loaded;
      try {
        loaded = await adapter.load(
          maximumRecords: maximumRecords,
          maximumUnknownRecords: maximumUnknownRecords,
          maximumUnknownFieldsPerRecord: maximumUnknownFieldsPerRecord,
          maximumValueBytes: maximumValueBytes,
          cancellationToken: cancellationToken,
        );
      } on Object {
        return Failed(_failure('adapter_load'));
      }
      if (loaded is Cancelled<SettingsPersistenceSnapshot, StructuredFailure>)
        return Cancelled(loaded.reason);
      if (loaded is Failed<SettingsPersistenceSnapshot, StructuredFailure>)
        return Failed(_failure('adapter_load'));
      final value =
          (loaded as Completed<SettingsPersistenceSnapshot, StructuredFailure>)
              .value;
      final checked = SettingsPersistenceSnapshot.create(
        storeRevision: value.storeRevision,
        records: value.records,
        unknownRecords: value.unknownRecords,
        damaged: value.damaged,
        lastKnownGoodAvailable: value.lastKnownGoodAvailable,
        maximumRecords: maximumRecords,
        maximumUnknownRecords: maximumUnknownRecords,
        maximumUnknownFieldsPerRecord: maximumUnknownFieldsPerRecord,
        maximumValueBytes: maximumValueBytes,
      );
      if (checked is Err<SettingsPersistenceSnapshot, StructuredFailure>)
        return Failed(checked.error);
      final persistence =
          (checked as Ok<SettingsPersistenceSnapshot, StructuredFailure>).value;
      final built = _buildSnapshot(persistence, maximumValueBytes, const {});
      if (built is Err<SettingsSnapshot, StructuredFailure>)
        return Failed(built.error);
      if (!identical(_generation, startingGeneration) ||
          _snapshot.storeRevision.value != startingRevision.value ||
          !identical(_persistence, startingPersistence)) {
        _poisoned = true;
        return Failed(_failure('authoritative_state_changed'));
      }
      _persistence = persistence;
      _snapshot = (built as Ok<SettingsSnapshot, StructuredFailure>).value;
      _poisoned = false;
      _generation = Object();
      return const Completed(null);
    } finally {
      _operationActive = false;
    }
  }

  Result<void, StructuredFailure> _activate(int maximumValueBytes) {
    final built = _buildSnapshot(
      _persistence,
      maximumValueBytes,
      _slotValues(_snapshot._preview),
    );
    if (built is Err<SettingsSnapshot, StructuredFailure>) {
      return Err(built.error);
    }
    _snapshot = (built as Ok<SettingsSnapshot, StructuredFailure>).value;
    return const Ok(null);
  }

  Result<SettingsSnapshot, StructuredFailure> _buildSnapshot(
    SettingsPersistenceSnapshot persistence,
    int maximumValueBytes,
    Map<SettingKey, Object?> preview,
  ) {
    final user = <SettingKey, Object?>{}, device = <SettingKey, Object?>{};
    for (final record in persistence.records) {
      if (!record.active) continue;
      final activation = registry.visit<_Activation>(
        record.key,
        _ActivationVisitor(record, maximumValueBytes),
        const _Activation.inactive(),
      );
      if (activation.failure != null) {
        continue;
      }
      if (!activation.active) continue;
      if (record.scope == SettingScope.user) {
        user[record.key] = activation.value;
      } else if (record.scope == SettingScope.deviceLocal) {
        device[record.key] = activation.value;
      }
    }
    return Ok(
      SettingsSnapshot._(
        registry: registry,
        storeRevision: persistence.storeRevision,
        user: user,
        device: device,
        preview: preview,
        unknownRecords: persistence.unknownRecords,
      ),
    );
  }
}

final class _ResetScopeVisitor implements SettingDefinitionVisitor<bool> {
  const _ResetScopeVisitor(this.scope);
  final SettingScope scope;
  @override
  bool visit<T>(RegisteredSettingDefinition<T> definition) =>
      definition.permittedPersistentScopes.contains(scope);
}

final class _ActivationVisitor
    implements SettingDefinitionVisitor<_Activation> {
  const _ActivationVisitor(this.record, this.maximumValueBytes);
  final SettingsLogicalRecord record;
  final int maximumValueBytes;

  @override
  _Activation visit<T>(RegisteredSettingDefinition<T> definition) {
    if (record.schemaVersion > definition.schemaVersion ||
        record.codecIdentity != definition.codec.identity) {
      return const _Activation.inactive();
    }
    final decoded = definition.decodeValue(
      record.valueBytes,
      maximumBytes: maximumValueBytes,
    );
    if (decoded is Err<T, StructuredFailure>) {
      return _Activation.failed(decoded.error);
    }
    final initial = (decoded as Ok<T, StructuredFailure>).value;
    final migrated = record.schemaVersion == definition.schemaVersion
        ? definition.validated(initial)
        : definition.migrateValue(initial, record.schemaVersion);
    if (migrated is Err<T, StructuredFailure>) {
      return _Activation.failed(migrated.error);
    }
    return _Activation.active((migrated as Ok<T, StructuredFailure>).value);
  }
}

final class _Activation {
  const _Activation.active(this.value) : active = true, failure = null;
  const _Activation.inactive() : active = false, value = null, failure = null;
  const _Activation.failed(this.failure) : active = false, value = null;
  final bool active;
  final Object? value;
  final StructuredFailure? failure;
}

Map<SettingKey, Object?> _slotValues(Map<SettingKey, _Slot> source) => {
  for (final entry in source.entries) entry.key: entry.value.value,
};

Revision _zeroRevision() {
  final result = Revision.create(0);
  if (result is Ok<Revision, StructuredFailure>) return result.value;
  throw StateError('Internal zero Settings revision must be valid.');
}

bool _validLimit(int value) => value >= 0 && value <= 9007199254740991;

List<T>? _boundedIterable<T>(Iterable<T> source, int maximum) {
  if (!_validLimit(maximum)) return null;
  try {
    final captured = <T>[];
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (captured.length >= maximum) return null;
      captured.add(iterator.current);
    }
    return List.unmodifiable(captured);
  } on Object {
    return null;
  }
}

List<int>? _boundedBytes(Iterable<int> source, int maximum) {
  final captured = _boundedIterable(source, maximum);
  if (captured == null || captured.any((v) => v < 0 || v > 255)) return null;
  return captured;
}

Map<K, V>? _boundedSettingsMap<K, V>(Map<K, V> source, int maximum) {
  if (!_validLimit(maximum)) return null;
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

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'app.settings.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The Settings operation could not be completed.',
);
