// SPDX-License-Identifier: GPL-3.0-or-later

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
    final registry = SettingRegistry()..register(_IntDefinition());
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
      final registry = SettingRegistry()..register(_IntDefinition());
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
    final registry = SettingRegistry();
    final source = _IntDefinition();
    expect(registry.register(source), isA<Ok<void, StructuredFailure>>());
    expect(registry.register(source), isA<Err<void, StructuredFailure>>());
    expect(registry.keys, isNotEmpty);
    expect(() => registry.keys.clear(), throwsUnsupportedError);
  });

  test(
    'defaults, user/device precedence, preview, cancel and reset are transactional',
    () async {
      final registry = SettingRegistry();
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
      final registry = SettingRegistry()..register(_IntDefinition());
      final zero =
          (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
      final adapter = InMemorySettingsAdapter(
        initial:
            (SettingsPersistenceSnapshot.create(
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
              registry: registry,
              adapter: adapter,
              maximumRecords: 10,
              maximumValueBytes: 10,
              cancellationToken: CancellationController().token,
            ))
            as Completed<SettingsRepository, StructuredFailure>)
        .value;

final class _IntDefinition implements SettingDefinitionSource<int> {
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
