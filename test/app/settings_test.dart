// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:al_note/app/settings.dart';
import 'package:al_note/core/primitives.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/phase5_test_support.dart';

void main() {
  test('oversized draft rejects before construction', () {
    final zero = (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
    expect(
      SettingsDraftTransaction.create(
        expectedRevision: SettingsStoreRevision(zero),
        operations: const [],
        maximumOperations: -1,
      ),
      isA<Err<SettingsDraftTransaction, StructuredFailure>>(),
    );
  });

  test('validated change sets are repository-owned and one-use', () async {
    final registry = SettingRegistry(
      maximumPersistentScopes: 8,
      maximumMigrations: 16,
      maximumResourceLimits: 16,
    )..register(_IntDefinition());
    final first = await _openRepository(
      registry,
      InMemorySettingsAdapter(initial: _emptyPersistence()),
    );
    final second = await _openRepository(
      registry,
      InMemorySettingsAdapter(initial: _emptyPersistence()),
    );
    final definition = registry.definition<int>(_IntDefinition().key)!;
    final changes =
        first.validate(
              _draft(
                expectedRevision: first.snapshot.storeRevision,
                operations: [
                  SetSettingValue(
                    key: definition.key,
                    scope: SettingScope.user,
                    definition: definition,
                    value: 6,
                  ),
                ],
              ),
              maximumOperations: 1,
            )
            as Ok<ValidatedSettingsChangeSet, StructuredFailure>;
    expect(
      await second.apply(
        changes.value,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      ),
      isA<Failed<SettingsCommitEvidence, StructuredFailure>>(),
    );
    expect(
      await first.apply(
        changes.value,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      ),
      isA<Completed<SettingsCommitEvidence, StructuredFailure>>(),
    );
    expect(
      await first.apply(
        changes.value,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      ),
      isA<Failed<SettingsCommitEvidence, StructuredFailure>>(),
    );
  });

  test(
    'unexpected post-commit evidence poisons until bounded reload',
    () async {
      final registry = SettingRegistry(
        maximumPersistentScopes: 8,
        maximumMigrations: 16,
        maximumResourceLimits: 16,
      )..register(_IntDefinition());
      final adapter = InMemorySettingsAdapter(initial: _emptyPersistence())
        ..returnUnexpectedCommitRevision = true;
      final repository = await _openRepository(registry, adapter);
      final definition = registry.definition<int>(_IntDefinition().key)!;
      final changes =
          (repository.validate(
                    _draft(
                      expectedRevision: repository.snapshot.storeRevision,
                      operations: [
                        SetSettingValue(
                          key: definition.key,
                          scope: SettingScope.user,
                          definition: definition,
                          value: 6,
                        ),
                      ],
                    ),
                    maximumOperations: 1,
                  )
                  as Ok<ValidatedSettingsChangeSet, StructuredFailure>)
              .value;
      expect(
        await repository.apply(
          changes,
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<SettingsCommitEvidence, StructuredFailure>>(),
      );
      expect(repository.reloadRequired, isTrue);
      expect(
        repository.installPreview(definition, 7, maximumPreviews: 1),
        isA<Err<void, StructuredFailure>>(),
      );
      expect(
        await repository.reload(
          maximumUnknownRecords: 16,
          maximumUnknownFieldsPerRecord: 16,
          maximumRecords: 10,
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Completed<void, StructuredFailure>>(),
      );
      expect(repository.reloadRequired, isFalse);
    },
  );

  test('definition metadata is snapshotted and duplicate keys reject', () {
    final registry = SettingRegistry(
      maximumPersistentScopes: 8,
      maximumMigrations: 16,
      maximumResourceLimits: 16,
    );
    final source = _IntDefinition();
    expect(registry.register(source), isA<Ok<void, StructuredFailure>>());
    expect(registry.register(source), isA<Err<void, StructuredFailure>>());
    expect(registry.keys, isNotEmpty);
    expect(() => registry.keys.clear(), throwsUnsupportedError);
  });

  test('definition metadata ignores false lengths and stops at ceilings', () {
    final infiniteScopes = InfiniteValues(SettingScope.user);
    final oversized = _MetadataDefinition(
      scopes: HostileSet(infiniteScopes, reportedLength: 0),
    );
    expect(
      SettingRegistry(
        maximumPersistentScopes: 1,
        maximumMigrations: 0,
        maximumResourceLimits: 1,
      ).register(oversized),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(infiniteScopes.moveNextCalls, 2);
    expect(infiniteScopes.currentReads, 1);

    final exact = _MetadataDefinition(
      scopes: HostileSet(const [
        SettingScope.user,
        SettingScope.deviceLocal,
      ], reportedLength: 0),
      migrationsSource: HostileList(const [], reportedLength: 99),
      limits: HostileMap(const [MapEntry('bytes', 1)], reportedLength: 0),
    );
    expect(
      SettingRegistry(
        maximumPersistentScopes: 2,
        maximumMigrations: 0,
        maximumResourceLimits: 1,
      ).register(exact),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(
      SettingRegistry(
        maximumPersistentScopes: 2,
        maximumMigrations: 1,
        maximumResourceLimits: 1,
      ).register(
        _MetadataDefinition(
          limits: HostileMap(ThrowingValues(), reportedLength: 0),
        ),
      ),
      isA<Err<void, StructuredFailure>>(),
    );
  });

  test(
    'unknown fields are bounded incrementally and revalidated on load',
    () async {
      final zero =
          (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
      final recordRevision = SettingsRecordRevision(zero);
      final key = (_IntDefinition().key);
      final infiniteEntries = InfiniteValues(
        const MapEntry('future', <int>[1]),
      );
      expect(
        SettingsLogicalRecord.create(
          key: key,
          scope: SettingScope.user,
          schemaVersion: 1,
          codecIdentity: 'test.int',
          recordRevision: recordRevision,
          valueBytes: const [1],
          unknownFields: HostileMap(infiniteEntries, reportedLength: 0),
          active: true,
          lastKnownGood: true,
          maximumValueBytes: 2,
          maximumUnknownFields: 1,
        ),
        isA<Err<SettingsLogicalRecord, StructuredFailure>>(),
      );
      expect(infiniteEntries.moveNextCalls, 2);
      expect(infiniteEntries.currentReads, 1);

      for (final fields in <Map<String, List<int>>>[
        GetterThrowingMap<String, List<int>>.key('future'),
        GetterThrowingMap<String, List<int>>.value('future'),
      ]) {
        expect(
          SettingsLogicalRecord.create(
            key: key,
            scope: SettingScope.user,
            schemaVersion: 1,
            codecIdentity: 'test.int',
            recordRevision: recordRevision,
            valueBytes: const [1],
            unknownFields: fields,
            active: true,
            lastKnownGood: true,
            maximumValueBytes: 1,
            maximumUnknownFields: 1,
          ),
          isA<Err<SettingsLogicalRecord, StructuredFailure>>(),
        );
      }

      final record =
          (SettingsLogicalRecord.create(
                    key: key,
                    scope: SettingScope.user,
                    schemaVersion: 1,
                    codecIdentity: 'test.int',
                    recordRevision: recordRevision,
                    valueBytes: const [1, 2],
                    unknownFields: HostileMap(const [
                      MapEntry('future', <int>[3, 4]),
                    ], reportedLength: 0),
                    active: true,
                    lastKnownGood: true,
                    maximumValueBytes: 2,
                    maximumUnknownFields: 1,
                  )
                  as Ok<SettingsLogicalRecord, StructuredFailure>)
              .value;
      expect(
        SettingsPersistenceSnapshot.create(
          storeRevision: SettingsStoreRevision(zero),
          records: [record],
          unknownRecords: const [],
          damaged: false,
          lastKnownGoodAvailable: true,
          maximumRecords: 1,
          maximumUnknownRecords: 0,
          maximumUnknownFieldsPerRecord: 0,
          maximumValueBytes: 2,
        ),
        isA<Err<SettingsPersistenceSnapshot, StructuredFailure>>(),
      );
      expect(
        SettingsPersistenceSnapshot.create(
          storeRevision: SettingsStoreRevision(zero),
          records: [record],
          unknownRecords: const [],
          damaged: false,
          lastKnownGoodAvailable: true,
          maximumRecords: 1,
          maximumUnknownRecords: 0,
          maximumUnknownFieldsPerRecord: 1,
          maximumValueBytes: 1,
        ),
        isA<Err<SettingsPersistenceSnapshot, StructuredFailure>>(),
      );
      final oldSnapshot =
          (SettingsPersistenceSnapshot.create(
                    storeRevision: SettingsStoreRevision(zero),
                    records: [record],
                    unknownRecords: const [],
                    damaged: false,
                    lastKnownGoodAvailable: true,
                    maximumRecords: 1,
                    maximumUnknownRecords: 0,
                    maximumUnknownFieldsPerRecord: 1,
                    maximumValueBytes: 2,
                  )
                  as Ok<SettingsPersistenceSnapshot, StructuredFailure>)
              .value;
      final registry = SettingRegistry(
        maximumPersistentScopes: 2,
        maximumMigrations: 0,
        maximumResourceLimits: 1,
      )..register(_IntDefinition());
      expect(
        await SettingsRepository.open(
          registry: registry,
          adapter: InMemorySettingsAdapter(initial: oldSnapshot),
          maximumRecords: 1,
          maximumUnknownRecords: 0,
          maximumUnknownFieldsPerRecord: 0,
          maximumValueBytes: 2,
          maximumListeners: 1,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<SettingsRepository, StructuredFailure>>(),
      );
    },
  );

  test(
    'defaults, user/device precedence, preview, cancel and reset are transactional',
    () async {
      final registry = SettingRegistry(
        maximumPersistentScopes: 8,
        maximumMigrations: 16,
        maximumResourceLimits: 16,
      );
      registry.register(_IntDefinition());
      final key =
          (SettingKey.parse('alnote.settings.test.number')
                  as Ok<SettingKey, StructuredFailure>)
              .value;
      final definition = registry.definition<int>(key)!;
      final zero =
          (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
      final adapter = InMemorySettingsAdapter(
        initial:
            (SettingsPersistenceSnapshot.create(
                      maximumUnknownRecords: 16,
                      maximumUnknownFieldsPerRecord: 16,
                      storeRevision: SettingsStoreRevision(zero),
                      records: const [],
                      unknownRecords: [
                        (UnknownSettingsRecord.create(
                                  identity: 'future',
                                  bytes: [9],
                                  supported: false,
                                  maximumBytes: 10,
                                )
                                as Ok<UnknownSettingsRecord, StructuredFailure>)
                            .value,
                      ],
                      damaged: false,
                      lastKnownGoodAvailable: true,
                      maximumRecords: 10,
                      maximumValueBytes: 10,
                    )
                    as Ok<SettingsPersistenceSnapshot, StructuredFailure>)
                .value,
      );
      final opened = await SettingsRepository.open(
        maximumUnknownRecords: 16,
        maximumUnknownFieldsPerRecord: 16,
        maximumListeners: 16,
        registry: registry,
        adapter: adapter,
        maximumRecords: 10,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      );
      final repository =
          (opened as Completed<SettingsRepository, StructuredFailure>).value;
      expect(
        (repository.snapshot.resolve(definition) as Ok<int, StructuredFailure>)
            .value,
        5,
      );
      final user = repository.validate(
        _draft(
          expectedRevision: repository.snapshot.storeRevision,
          operations: [
            SetSettingValue(
              key: key,
              scope: SettingScope.user,
              definition: definition,
              value: 7,
            ),
          ],
        ),
        maximumOperations: 10,
      );
      await repository.apply(
        (user as Ok<ValidatedSettingsChangeSet, StructuredFailure>).value,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      );
      expect(
        (repository.snapshot.resolve(definition) as Ok<int, StructuredFailure>)
            .value,
        7,
      );
      final device = repository.validate(
        _draft(
          expectedRevision: repository.snapshot.storeRevision,
          operations: [
            SetSettingValue(
              key: key,
              scope: SettingScope.deviceLocal,
              definition: definition,
              value: 8,
            ),
          ],
        ),
        maximumOperations: 10,
      );
      await repository.apply(
        (device as Ok<ValidatedSettingsChangeSet, StructuredFailure>).value,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      );
      repository.installPreview(definition, 9, maximumPreviews: 1);
      expect(
        (repository.snapshot.resolve(definition) as Ok<int, StructuredFailure>)
            .value,
        9,
      );
      repository.cancelPreviews();
      expect(
        (repository.snapshot.resolve(definition) as Ok<int, StructuredFailure>)
            .value,
        8,
      );
      final reset = repository.validate(
        _draft(
          expectedRevision: repository.snapshot.storeRevision,
          operations: [
            ResetSettingValue(key: key, scope: SettingScope.deviceLocal),
          ],
        ),
        maximumOperations: 10,
      );
      await repository.apply(
        (reset as Ok<ValidatedSettingsChangeSet, StructuredFailure>).value,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      );
      expect(
        (repository.snapshot.resolve(definition) as Ok<int, StructuredFailure>)
            .value,
        7,
      );
      expect(repository.snapshot.unknownRecords.single.bytes, [9]);
    },
  );

  test(
    'stale writers and hostile adapter exceptions become fixed failures',
    () async {
      final registry = SettingRegistry(
        maximumPersistentScopes: 8,
        maximumMigrations: 16,
        maximumResourceLimits: 16,
      )..register(_IntDefinition());
      final zero =
          (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
      final adapter = InMemorySettingsAdapter(
        initial:
            (SettingsPersistenceSnapshot.create(
                      maximumUnknownRecords: 16,
                      maximumUnknownFieldsPerRecord: 16,
                      storeRevision: SettingsStoreRevision(zero),
                      records: const [],
                      unknownRecords: const [],
                      damaged: false,
                      lastKnownGoodAvailable: true,
                      maximumRecords: 1,
                      maximumValueBytes: 1,
                    )
                    as Ok<SettingsPersistenceSnapshot, StructuredFailure>)
                .value,
        fault: TestAdapterFault.exception,
      );
      final outcome = await SettingsRepository.open(
        maximumUnknownRecords: 16,
        maximumUnknownFieldsPerRecord: 16,
        maximumListeners: 16,
        registry: registry,
        adapter: adapter,
        maximumRecords: 1,
        maximumValueBytes: 1,
        cancellationToken: CancellationController().token,
      );
      expect(outcome, isA<Failed<SettingsRepository, StructuredFailure>>());
      expect(outcome.toString(), isNot(contains('sensitive')));
    },
  );

  test(
    'apply guard rejects overlap without consuming the second change set',
    () async {
      final registry = SettingRegistry(
        maximumPersistentScopes: 8,
        maximumMigrations: 16,
        maximumResourceLimits: 16,
      )..register(_IntDefinition());
      final adapter = InMemorySettingsAdapter(initial: _emptyPersistence());
      final repository = await _openRepository(registry, adapter);
      final first = _change(repository, registry, 6);
      final second = _change(repository, registry, 7);
      final gate = Completer<void>();
      adapter.commitGate = gate;
      var events = 0;
      repository.addListener((_) {
        events += 1;
        expect(
          repository.apply(
            second,
            maximumValueBytes: 10,
            cancellationToken: CancellationController().token,
          ),
          completion(isA<Failed<SettingsCommitEvidence, StructuredFailure>>()),
        );
      });
      final active = repository.apply(
        first,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        await repository.apply(
          second,
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<SettingsCommitEvidence, StructuredFailure>>(),
      );
      expect(adapter.commitInvocations, 1);
      expect(
        await repository.reload(
          maximumRecords: 10,
          maximumUnknownRecords: 10,
          maximumUnknownFieldsPerRecord: 10,
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<void, StructuredFailure>>(),
      );
      expect(adapter.loadInvocations, 1);
      gate.complete();
      expect(
        await active,
        isA<Completed<SettingsCommitEvidence, StructuredFailure>>(),
      );
      expect(events, 1);
      expect(adapter.commitInvocations, 1);
      expect(
        await repository.apply(
          second,
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<SettingsCommitEvidence, StructuredFailure>>(),
      );
    },
  );

  test(
    'reload guard rejects apply overlap and releases after completion',
    () async {
      final registry = SettingRegistry(
        maximumPersistentScopes: 8,
        maximumMigrations: 16,
        maximumResourceLimits: 16,
      )..register(_IntDefinition());
      final adapter = InMemorySettingsAdapter(initial: _emptyPersistence());
      final repository = await _openRepository(registry, adapter);
      final changes = _change(repository, registry, 6);
      final gate = Completer<void>();
      adapter.loadGate = gate;
      final reload = repository.reload(
        maximumRecords: 10,
        maximumUnknownRecords: 10,
        maximumUnknownFieldsPerRecord: 10,
        maximumValueBytes: 10,
        cancellationToken: CancellationController().token,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        await repository.apply(
          changes,
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<SettingsCommitEvidence, StructuredFailure>>(),
      );
      expect(adapter.commitInvocations, 0);
      gate.complete();
      expect(await reload, isA<Completed<void, StructuredFailure>>());
      adapter.loadGate = null;
      expect(
        await repository.apply(
          changes,
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Completed<SettingsCommitEvidence, StructuredFailure>>(),
      );
    },
  );

  test(
    'adapter exception releases mutation guard and listener ceiling is exact',
    () async {
      final registry = SettingRegistry(
        maximumPersistentScopes: 8,
        maximumMigrations: 16,
        maximumResourceLimits: 16,
      )..register(_IntDefinition());
      final adapter = InMemorySettingsAdapter(initial: _emptyPersistence());
      final opened = await SettingsRepository.open(
        registry: registry,
        adapter: adapter,
        maximumRecords: 10,
        maximumUnknownRecords: 10,
        maximumUnknownFieldsPerRecord: 10,
        maximumValueBytes: 10,
        maximumListeners: 1,
        cancellationToken: CancellationController().token,
      );
      final repository =
          (opened as Completed<SettingsRepository, StructuredFailure>).value;
      void listener(SettingsChangeEvent _) {}
      expect(
        repository.addListener(listener),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(
        repository.addListener(listener),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(
        repository.addListener((_) {}),
        isA<Err<void, StructuredFailure>>(),
      );
      repository.removeListener(listener);
      expect(
        repository.addListener((_) {}),
        isA<Ok<void, StructuredFailure>>(),
      );

      adapter.fault = TestAdapterFault.exception;
      expect(
        await repository.apply(
          _change(repository, registry, 6),
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<SettingsCommitEvidence, StructuredFailure>>(),
      );
      adapter.fault = TestAdapterFault.none;
      expect(
        await repository.apply(
          _change(repository, registry, 7),
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Completed<SettingsCommitEvidence, StructuredFailure>>(),
      );

      adapter.fault = TestAdapterFault.cancellation;
      expect(
        await repository.apply(
          _change(repository, registry, 8),
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Cancelled<SettingsCommitEvidence, StructuredFailure>>(),
      );
      adapter.fault = TestAdapterFault.none;
      expect(
        await repository.apply(
          _change(repository, registry, 9),
          maximumValueBytes: 10,
          cancellationToken: CancellationController().token,
        ),
        isA<Completed<SettingsCommitEvidence, StructuredFailure>>(),
      );
    },
  );

  test('Settings byte factories stop before hostile oversized tails', () {
    final bytes = _InfiniteBytes();
    expect(
      UnknownSettingsRecord.create(
        identity: 'future',
        bytes: bytes,
        supported: false,
        maximumBytes: 2,
      ),
      isA<Err<UnknownSettingsRecord, StructuredFailure>>(),
    );
    expect(bytes.moveNextCalls, 3);
    expect(bytes.currentReads, 2);

    for (final exact in <Iterable<int>>[
      HostileList(const [1, 2], reportedLength: 0),
      HostileList(const [1, 2], reportedLength: 999),
      ThrowingLengthList(const [1, 2]),
    ]) {
      expect(
        UnknownSettingsRecord.create(
          identity: 'future',
          bytes: exact,
          supported: false,
          maximumBytes: 2,
        ),
        isA<Ok<UnknownSettingsRecord, StructuredFailure>>(),
      );
    }
    for (final hostile in <Iterable<int>>[
      IteratorCreationThrowingValues(),
      ThrowingValues(),
      CurrentThrowingValues(),
    ]) {
      expect(
        UnknownSettingsRecord.create(
          identity: 'future',
          bytes: hostile,
          supported: false,
          maximumBytes: 2,
        ),
        isA<Err<UnknownSettingsRecord, StructuredFailure>>(),
      );
    }
    final finite = TrackingValues([1, 2, 222]);
    expect(
      UnknownSettingsRecord.create(
        identity: 'future',
        bytes: HostileList(finite, reportedLength: 0),
        supported: false,
        maximumBytes: 2,
      ),
      isA<Err<UnknownSettingsRecord, StructuredFailure>>(),
    );
    expect(finite.moveNextCalls, 3);
    expect(finite.currentReads, 2);

    final zero = (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
    final operation = ResetSettingValue(
      key: _IntDefinition().key,
      scope: SettingScope.user,
    );
    final operations = _InfiniteOperations(operation);
    expect(
      SettingsDraftTransaction.create(
        expectedRevision: SettingsStoreRevision(zero),
        operations: operations,
        maximumOperations: 1,
      ),
      isA<Err<SettingsDraftTransaction, StructuredFailure>>(),
    );
    expect(operations.moveNextCalls, 2);
    expect(operations.currentReads, 1);
  });

  test(
    'Settings codec bytes are captured without consulting hostile length',
    () {
      final codec = _BoundaryCodec();
      final registry = SettingRegistry(
        maximumPersistentScopes: 2,
        maximumMigrations: 0,
        maximumResourceLimits: 1,
      )..register(_CodecDefinition(codec));
      final definition = registry.definition<int>(_IntDefinition().key)!;

      codec.encoded = HostileList(const [7], reportedLength: 99);
      final encoded = definition.encodeValue(7, maximumBytes: 1);
      expect(encoded, isA<Ok<List<int>, StructuredFailure>>());
      final publicBytes = (encoded as Ok<List<int>, StructuredFailure>).value;
      expect(publicBytes, [7]);
      expect(() => publicBytes.add(8), throwsUnsupportedError);

      codec.encoded = ThrowingLengthList(const [7]);
      expect(
        definition.encodeValue(7, maximumBytes: 1),
        isA<Ok<List<int>, StructuredFailure>>(),
      );
      expect(
        definition.decodeValue(ThrowingLengthList(const [7]), maximumBytes: 1),
        isA<Ok<int, StructuredFailure>>(),
      );
      expect(codec.decodeSawImmutableInput, isTrue);

      final infiniteEncode = InfiniteValues(7);
      codec.encoded = HostileList(infiniteEncode, reportedLength: 0);
      expect(
        definition.encodeValue(7, maximumBytes: 1),
        isA<Err<List<int>, StructuredFailure>>(),
      );
      expect(infiniteEncode.moveNextCalls, 2);
      expect(infiniteEncode.currentReads, 1);

      final finiteEncode = TrackingValues([7, 222]);
      codec.encoded = HostileList(finiteEncode, reportedLength: 0);
      expect(
        definition.encodeValue(7, maximumBytes: 1),
        isA<Err<List<int>, StructuredFailure>>(),
      );
      expect(finiteEncode.moveNextCalls, 2);
      expect(finiteEncode.currentReads, 1);

      for (final hostile in <List<int>>[
        HostileList(IteratorCreationThrowingValues(), reportedLength: 0),
        HostileList(ThrowingValues(), reportedLength: 0),
        HostileList(CurrentThrowingValues(), reportedLength: 0),
        HostileList(const [256], reportedLength: 0),
      ]) {
        codec.encoded = hostile;
        final failure = definition.encodeValue(7, maximumBytes: 1);
        expect(failure, isA<Err<List<int>, StructuredFailure>>());
        expect(failure.toString(), isNot(contains('secret')));
      }

      final infiniteDecode = InfiniteValues(7);
      expect(
        definition.decodeValue(
          HostileList(infiniteDecode, reportedLength: 0),
          maximumBytes: 1,
        ),
        isA<Err<int, StructuredFailure>>(),
      );
      expect(infiniteDecode.moveNextCalls, 2);
      expect(infiniteDecode.currentReads, 1);

      for (final hostile in <List<int>>[
        HostileList(IteratorCreationThrowingValues(), reportedLength: 0),
        HostileList(ThrowingValues(), reportedLength: 0),
        HostileList(CurrentThrowingValues(), reportedLength: 0),
        HostileList(const [-1], reportedLength: 0),
      ]) {
        final failure = definition.decodeValue(hostile, maximumBytes: 1);
        expect(failure, isA<Err<int, StructuredFailure>>());
        expect(failure.toString(), isNot(contains('secret')));
      }
    },
  );
}

ValidatedSettingsChangeSet _change(
  SettingsRepository repository,
  SettingRegistry registry,
  int value,
) {
  final definition = registry.definition<int>(_IntDefinition().key)!;
  return (repository.validate(
            _draft(
              expectedRevision: repository.snapshot.storeRevision,
              operations: [
                SetSettingValue(
                  key: definition.key,
                  scope: SettingScope.user,
                  definition: definition,
                  value: value,
                ),
              ],
            ),
            maximumOperations: 1,
          )
          as Ok<ValidatedSettingsChangeSet, StructuredFailure>)
      .value;
}

final class _InfiniteBytes extends Iterable<int> {
  int moveNextCalls = 0;
  int currentReads = 0;
  @override
  Iterator<int> get iterator => _InfiniteByteIterator(this);
}

final class _InfiniteByteIterator implements Iterator<int> {
  _InfiniteByteIterator(this.owner);
  final _InfiniteBytes owner;
  @override
  int get current {
    owner.currentReads += 1;
    return 1;
  }

  @override
  bool moveNext() {
    owner.moveNextCalls += 1;
    return true;
  }
}

final class _InfiniteOperations extends Iterable<SettingsDraftOperation> {
  _InfiniteOperations(this.operation);
  final SettingsDraftOperation operation;
  int moveNextCalls = 0;
  int currentReads = 0;
  @override
  Iterator<SettingsDraftOperation> get iterator =>
      _InfiniteOperationIterator(this);
}

final class _InfiniteOperationIterator
    implements Iterator<SettingsDraftOperation> {
  _InfiniteOperationIterator(this.owner);
  final _InfiniteOperations owner;
  @override
  SettingsDraftOperation get current {
    owner.currentReads += 1;
    return owner.operation;
  }

  @override
  bool moveNext() {
    owner.moveNextCalls += 1;
    return true;
  }
}

SettingsDraftTransaction _draft({
  required SettingsStoreRevision expectedRevision,
  required List<SettingsDraftOperation> operations,
}) =>
    (SettingsDraftTransaction.create(
              expectedRevision: expectedRevision,
              operations: operations,
              maximumOperations: 10,
            )
            as Ok<SettingsDraftTransaction, StructuredFailure>)
        .value;

SettingsPersistenceSnapshot _emptyPersistence() {
  final zero = (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
  return (SettingsPersistenceSnapshot.create(
            maximumUnknownRecords: 16,
            maximumUnknownFieldsPerRecord: 16,
            storeRevision: SettingsStoreRevision(zero),
            records: const [],
            unknownRecords: const [],
            damaged: false,
            lastKnownGoodAvailable: true,
            maximumRecords: 10,
            maximumValueBytes: 10,
          )
          as Ok<SettingsPersistenceSnapshot, StructuredFailure>)
      .value;
}

Future<SettingsRepository> _openRepository(
  SettingRegistry registry,
  InMemorySettingsAdapter adapter,
) async =>
    ((await SettingsRepository.open(
              maximumUnknownRecords: 16,
              maximumUnknownFieldsPerRecord: 16,
              maximumListeners: 16,
              registry: registry,
              adapter: adapter,
              maximumRecords: 10,
              maximumValueBytes: 10,
              cancellationToken: CancellationController().token,
            ))
            as Completed<SettingsRepository, StructuredFailure>)
        .value;

class _IntDefinition implements SettingDefinitionSource<int> {
  @override
  MandatorySettingConstraints<int> get mandatoryConstraints => _allow;
  static Result<int, StructuredFailure> _allow(int value) => Ok(value);
  @override
  SettingApplicationTiming get applicationTiming =>
      SettingApplicationTiming.nextOperation;
  @override
  SettingValueCodec<int> get codec => const _IntCodec();
  @override
  DataClassification get dataClassification => DataClassification.internal;
  @override
  SettingDefaultProvider<int> get defaultProvider =>
      () => 5;
  @override
  SettingDeprecationState get deprecationState =>
      SettingDeprecationState.active;
  @override
  SettingKey get key =>
      (SettingKey.parse('alnote.settings.test.number')
              as Ok<SettingKey, StructuredFailure>)
          .value;
  @override
  List<SettingMigrationStep<int>> get migrations => const [];
  @override
  SettingNormalizer<int> get normalizer =>
      (value) => Ok(value.clamp(0, 10));
  @override
  String get owningDomain => 'test';
  @override
  Set<SettingScope> get permittedPersistentScopes => {
    SettingScope.user,
    SettingScope.deviceLocal,
  };
  @override
  bool get previewSupported => true;
  @override
  Map<String, int> get requiredResourceLimits => const {'bytes': 1};
  @override
  SettingRestartRequirement get restartRequirement =>
      SettingRestartRequirement.none;
  @override
  int get schemaVersion => 1;
  @override
  SettingSynchronizationEligibility get synchronizationEligibility =>
      SettingSynchronizationEligibility.eligible;
  @override
  SettingValidator<int> get validator =>
      (value) => value >= 0 && value <= 10
      ? const Ok(null)
      : Err(testFailure('invalid_setting'));
}

final class _MetadataDefinition extends _IntDefinition {
  _MetadataDefinition({this.scopes, this.migrationsSource, this.limits});
  final Set<SettingScope>? scopes;
  final List<SettingMigrationStep<int>>? migrationsSource;
  final Map<String, int>? limits;
  @override
  Set<SettingScope> get permittedPersistentScopes =>
      scopes ?? super.permittedPersistentScopes;
  @override
  List<SettingMigrationStep<int>> get migrations =>
      migrationsSource ?? super.migrations;
  @override
  Map<String, int> get requiredResourceLimits =>
      limits ?? super.requiredResourceLimits;
}

final class _CodecDefinition extends _IntDefinition {
  _CodecDefinition(this.boundaryCodec);
  final _BoundaryCodec boundaryCodec;
  @override
  SettingValueCodec<int> get codec => boundaryCodec;
}

final class _BoundaryCodec implements SettingValueCodec<int> {
  List<int> encoded = const [7];
  bool decodeSawImmutableInput = false;
  @override
  String get identity => 'test.boundary';
  @override
  Result<List<int>, StructuredFailure> encode(
    int value, {
    required int maximumBytes,
  }) => Ok(encoded);
  @override
  Result<int, StructuredFailure> decode(
    List<int> bytes, {
    required int maximumBytes,
  }) {
    try {
      bytes.add(9);
    } on UnsupportedError {
      decodeSawImmutableInput = true;
    }
    return bytes.length == 1
        ? Ok(bytes.single)
        : Err(testFailure('boundary_decode'));
  }
}

final class _IntCodec implements SettingValueCodec<int> {
  const _IntCodec();
  @override
  String get identity => 'test.int';
  @override
  Result<int, StructuredFailure> decode(
    List<int> bytes, {
    required int maximumBytes,
  }) => bytes.length == 1 && bytes.length <= maximumBytes
      ? Ok(bytes.single)
      : Err(testFailure('decode'));
  @override
  Result<List<int>, StructuredFailure> encode(
    int value, {
    required int maximumBytes,
  }) => maximumBytes >= 1
      ? Ok(List.unmodifiable([value]))
      : Err(testFailure('encode'));
}
