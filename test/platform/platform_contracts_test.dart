// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/platform/platform.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/controllable_clock.dart';
import '../support/document_model_test_support.dart';
import '../support/phase5_test_support.dart';
import '../support/uuid_sequence_generator.dart';

void main() {
  test('unrelated token authority rejects structurally matching token', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final first = _authority(clock, 940);
    final second = _authority(clock, 941);
    final bindings = _bindings();
    final token =
        (first.authorization(
                  owner: bindings.$1,
                  operation: bindings.$2,
                  scope: bindings.$3,
                  expiresAtUtc: clock.nowUtc().add(const Duration(seconds: 5)),
                )
                as Ok<AuthorizationToken, StructuredFailure>)
            .value;
    expect(
      second.revalidate(
        token,
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Ok<bool, StructuredFailure>>().having(
        (value) => value.value,
        'value',
        isFalse,
      ),
    );
  });

  test('capability policy gates every token kind before UUID issuance', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final bindings = _bindings();
    final generator = UuidSequenceGenerator.fromValues([
      for (var index = 0; index < 5; index += 1) testUuid(942 + index),
    ]);
    final policy = _MutableTokenPolicy()..allowed = false;
    final denied =
        (OpaqueTokenAuthority.create(
                  uuidGenerator: generator,
                  clock: clock,
                  maximumLifetime: const Duration(minutes: 1),
                  capabilityPolicy: policy,
                  maximumIssuedTokens: 1,
                  maximumConsumedTokens: 1,
                  maximumRevocationOwners: 1,
                )
                as Ok<OpaqueTokenAuthority, StructuredFailure>)
            .value;
    expect(
      denied.resource(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<ResourceToken, StructuredFailure>>(),
    );
    expect(
      denied.destination(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<DestinationToken, StructuredFailure>>(),
    );
    expect(
      denied.authorization(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
        expiresAtUtc: clock.nowUtc().add(const Duration(seconds: 5)),
      ),
      isA<Err<AuthorizationToken, StructuredFailure>>(),
    );
    expect(
      denied.temporaryResource(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
        expiresAtUtc: clock.nowUtc().add(const Duration(seconds: 5)),
      ),
      isA<Err<TemporaryResourceToken, StructuredFailure>>(),
    );
    expect(
      denied.secretReference(
        owner: bindings.$1,
        purpose: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<SecretReference, StructuredFailure>>(),
    );
    expect(generator.remaining, 5);
    policy.allowed = true;
    expect(
      denied.resource(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Ok<ResourceToken, StructuredFailure>>(),
    );
    expect(generator.remaining, 4);
  });

  test(
    'policy exceptions consume no UUID and later revocation is rechecked',
    () {
      final clock = ControllableClock(DateTime.utc(2026));
      final bindings = _bindings();
      final generator = UuidSequenceGenerator.fromValues([
        testUuid(947),
        testUuid(948),
      ]);
      final policy = _MutableTokenPolicy()..throwNow = true;
      final authority =
          (OpaqueTokenAuthority.create(
                    uuidGenerator: generator,
                    clock: clock,
                    maximumLifetime: const Duration(minutes: 1),
                    capabilityPolicy: policy,
                    maximumIssuedTokens: 1,
                    maximumConsumedTokens: 1,
                    maximumRevocationOwners: 1,
                  )
                  as Ok<OpaqueTokenAuthority, StructuredFailure>)
              .value;
      expect(
        authority.resource(
          owner: bindings.$1,
          operation: bindings.$2,
          scope: bindings.$3,
        ),
        isA<Err<ResourceToken, StructuredFailure>>(),
      );
      expect(generator.remaining, 2);
      policy.throwNow = false;
      final token =
          (authority.resource(
                    owner: bindings.$1,
                    operation: bindings.$2,
                    scope: bindings.$3,
                  )
                  as Ok<ResourceToken, StructuredFailure>)
              .value;
      policy.allowed = false;
      expect(
        authority.revalidate(
          token,
          owner: bindings.$1,
          operation: bindings.$2,
          scope: bindings.$3,
        ),
        isA<Ok<bool, StructuredFailure>>().having(
          (result) => result.value,
          'value',
          isFalse,
        ),
      );
    },
  );

  test('token limit and disposal remain authority-owned', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final bindings = _bindings();
    final limited = _authority(clock, 943, maximumIssued: 1);
    final token =
        (limited.authorization(
                  owner: bindings.$1,
                  operation: bindings.$2,
                  scope: bindings.$3,
                  expiresAtUtc: clock.nowUtc().add(const Duration(seconds: 5)),
                )
                as Ok<AuthorizationToken, StructuredFailure>)
            .value;
    expect(
      limited.authorization(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
        expiresAtUtc: clock.nowUtc().add(const Duration(seconds: 5)),
      ),
      isA<Err<AuthorizationToken, StructuredFailure>>(),
    );
    limited.dispose();
    expect(
      limited.revalidate(
        token,
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<bool, StructuredFailure>>(),
    );
  });

  test('repeated UUID in one token kind is rejected without retry', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final bindings = _bindings();
    final repeated = testUuid(949);
    final generator = UuidSequenceGenerator.fromValues([
      repeated,
      repeated,
      testUuid(950),
    ]);
    final authority =
        (OpaqueTokenAuthority.create(
                  uuidGenerator: generator,
                  clock: clock,
                  maximumLifetime: const Duration(minutes: 1),
                  capabilityPolicy: _AllowTokenPolicy(),
                  maximumIssuedTokens: 2,
                  maximumConsumedTokens: 2,
                  maximumRevocationOwners: 1,
                )
                as Ok<OpaqueTokenAuthority, StructuredFailure>)
            .value;
    final original =
        (authority.resource(
                  owner: bindings.$1,
                  operation: bindings.$2,
                  scope: bindings.$3,
                )
                as Ok<ResourceToken, StructuredFailure>)
            .value;
    final collision = authority.resource(
      owner: bindings.$1,
      operation: bindings.$2,
      scope: bindings.$3,
    );
    expect(collision, isA<Err<ResourceToken, StructuredFailure>>());
    expect(
      (collision as Err<ResourceToken, StructuredFailure>).error.code,
      'platform.tokens.token_identity_collision',
    );
    expect(collision.toString(), isNot(contains(repeated.value)));
    expect(generator.remaining, 1);
    expect(
      authority.revalidate(
        original,
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Ok<bool, StructuredFailure>>().having(
        (result) => result.value,
        'value',
        isTrue,
      ),
    );
    expect(
      authority.destination(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Ok<DestinationToken, StructuredFailure>>(),
    );
    expect(generator.remaining, 0);
  });

  test('repeated UUID across token kinds is authority-wide collision', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final bindings = _bindings();
    final repeated = testUuid(951);
    final generator = UuidSequenceGenerator.fromValues([repeated, repeated]);
    final authority =
        (OpaqueTokenAuthority.create(
                  uuidGenerator: generator,
                  clock: clock,
                  maximumLifetime: const Duration(minutes: 1),
                  capabilityPolicy: _AllowTokenPolicy(),
                  maximumIssuedTokens: 2,
                  maximumConsumedTokens: 2,
                  maximumRevocationOwners: 1,
                )
                as Ok<OpaqueTokenAuthority, StructuredFailure>)
            .value;
    expect(
      authority.resource(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Ok<ResourceToken, StructuredFailure>>(),
    );
    expect(
      authority.destination(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<DestinationToken, StructuredFailure>>(),
    );
    expect(generator.remaining, 0);
  });

  test('disposed and issued-limit preflights skip policy and UUID', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final bindings = _bindings();
    final generator = UuidSequenceGenerator.fromValues([
      testUuid(952),
      testUuid(953),
    ]);
    final policy = _MutableTokenPolicy();
    final authority =
        (OpaqueTokenAuthority.create(
                  uuidGenerator: generator,
                  clock: clock,
                  maximumLifetime: const Duration(minutes: 1),
                  capabilityPolicy: policy,
                  maximumIssuedTokens: 1,
                  maximumConsumedTokens: 1,
                  maximumRevocationOwners: 1,
                )
                as Ok<OpaqueTokenAuthority, StructuredFailure>)
            .value;
    expect(
      authority.resource(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Ok<ResourceToken, StructuredFailure>>(),
    );
    expect(policy.calls, 1);
    expect(generator.remaining, 1);
    policy.throwNow = true;
    expect(
      authority.destination(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<DestinationToken, StructuredFailure>>(),
    );
    expect(policy.calls, 1);
    expect(generator.remaining, 1);
    authority.dispose();
    expect(
      authority.secretReference(
        owner: bindings.$1,
        purpose: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<SecretReference, StructuredFailure>>(),
    );
    expect(policy.calls, 1);
    expect(generator.remaining, 1);
  });

  test(
    'reentrant registry disposal invokes accepted disposer exactly once',
    () {
      final registry =
          (CapabilityRegistry.create(
                    maximumListeners: 16,
                    maximumCapabilities: 2,
                  )
                  as Ok<CapabilityRegistry, StructuredFailure>)
              .value;
      var disposals = 0;
      registry.addListener((_) => registry.dispose());
      expect(
        registry.register(
          _capabilityEvidence(),
          disposer: () {
            disposals += 1;
            return const Ok(null);
          },
        ),
        isA<Ok<void, StructuredFailure>>(),
      );
      registry.dispose();
      expect(disposals, 1);
      expect(registry.snapshot.capabilities, isEmpty);
    },
  );

  test(
    'typed capability initialization enforces contract compatibility',
    () async {
      final registry =
          (CapabilityRegistry.create(
                    maximumListeners: 16,
                    maximumCapabilities: 2,
                  )
                  as Ok<CapabilityRegistry, StructuredFailure>)
              .value;
      final adapter = _TestCapabilityAdapter(_capabilityEvidence());
      expect(
        await registry.initialize<void>(
          adapter: adapter,
          requiredVersion: _version(1, 0),
          cancellationToken: CancellationController().token,
        ),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(adapter.initializations, 1);
      registry.dispose();
      registry.dispose();
      expect(adapter.disposals, 1);
      final other =
          (CapabilityRegistry.create(
                    maximumListeners: 16,
                    maximumCapabilities: 2,
                  )
                  as Ok<CapabilityRegistry, StructuredFailure>)
              .value;
      expect(
        await other.initialize<void>(
          adapter: _TestCapabilityAdapter(_capabilityEvidence()),
          requiredVersion: _version(2, 0),
          cancellationToken: CancellationController().token,
        ),
        isA<Err<void, StructuredFailure>>(),
      );
    },
  );

  test('equal-but-distinct adapter evidence transfers ownership', () async {
    final metadata = _capabilityEvidence();
    final equalAdapter =
        (AdapterEvidence.create(
                  identity: metadata.adapter.identity,
                  version: metadata.adapter.version,
                )
                as Ok<AdapterEvidence, StructuredFailure>)
            .value;
    expect(equalAdapter, equals(metadata.adapter));
    expect(identical(equalAdapter, metadata.adapter), isFalse);
    final adapter = _MismatchCapabilityAdapter(
      metadata,
      _evidenceLike(metadata, adapter: equalAdapter),
    );
    final registry =
        (CapabilityRegistry.create(maximumListeners: 16, maximumCapabilities: 1)
                as Ok<CapabilityRegistry, StructuredFailure>)
            .value;
    expect(
      await registry.initialize<void>(
        adapter: adapter,
        requiredVersion: _version(1, 0),
        cancellationToken: CancellationController().token,
      ),
      isA<Ok<void, StructuredFailure>>(),
    );
    expect(adapter.disposals, 0);
    registry.dispose();
    expect(adapter.disposals, 1);
  });

  test(
    'capability initialization failure and exception publish evidence',
    () async {
      for (final throws in [false, true]) {
        final registry =
            (CapabilityRegistry.create(
                      maximumListeners: 16,
                      maximumCapabilities: 1,
                    )
                    as Ok<CapabilityRegistry, StructuredFailure>)
                .value;
        final adapter = _TestCapabilityAdapter(
          _capabilityEvidence(),
          failInitialization: !throws,
          throwInitialization: throws,
        );
        expect(
          await registry.initialize<void>(
            adapter: adapter,
            requiredVersion: _version(1, 0),
            cancellationToken: CancellationController().token,
          ),
          isA<Ok<void, StructuredFailure>>(),
        );
        expect(adapter.initializations, 1);
        expect(
          registry.snapshot.capabilities.values.single.availability,
          CapabilityAvailability.initializationFailed,
        );
        registry.dispose();
        registry.dispose();
        expect(adapter.disposals, 1);
      }
    },
  );

  test(
    'reentrant initialization collision releases the losing adapter',
    () async {
      final registry =
          (CapabilityRegistry.create(
                    maximumListeners: 16,
                    maximumCapabilities: 2,
                  )
                  as Ok<CapabilityRegistry, StructuredFailure>)
              .value;
      final evidence = _capabilityEvidence();
      final adapter = _ReentrantCapabilityAdapter(evidence, () {
        expect(registry.register(evidence), isA<Ok<void, StructuredFailure>>());
      });
      expect(
        await registry.initialize<void>(
          adapter: adapter,
          requiredVersion: _version(1, 0),
          cancellationToken: CancellationController().token,
        ),
        isA<Err<void, StructuredFailure>>(),
      );
      expect(adapter.disposals, 1);
      expect(registry.snapshot.capabilities, hasLength(1));
    },
  );

  test(
    'every initialization evidence mismatch disposes exactly once',
    () async {
      final base = _capabilityEvidence();
      final cases = <(CapabilityEvidence, CapabilityEvidence)>[
        (
          base,
          _evidenceLike(
            base,
            key:
                (CapabilityKey.parse('alnote.platform.other')
                        as Ok<CapabilityKey, StructuredFailure>)
                    .value,
          ),
        ),
        (base, _evidenceLike(base, version: _version(1, 2))),
        (
          base,
          _evidenceLike(
            base,
            adapter:
                (AdapterEvidence.create(identity: 'other', version: '1')
                        as Ok<AdapterEvidence, StructuredFailure>)
                    .value,
          ),
        ),
        (
          base,
          _evidenceLike(
            base,
            adapter:
                (AdapterEvidence.create(identity: 'test', version: '2')
                        as Ok<AdapterEvidence, StructuredFailure>)
                    .value,
          ),
        ),
      ];
      for (final values in cases) {
        final registry =
            (CapabilityRegistry.create(
                      maximumListeners: 16,
                      maximumCapabilities: 1,
                    )
                    as Ok<CapabilityRegistry, StructuredFailure>)
                .value;
        final adapter = _MismatchCapabilityAdapter(values.$1, values.$2);
        expect(
          await registry.initialize<void>(
            adapter: adapter,
            requiredVersion: _version(1, 0),
            cancellationToken: CancellationController().token,
          ),
          isA<Err<void, StructuredFailure>>(),
        );
        expect(adapter.disposals, 1);
        registry.dispose();
        expect(adapter.disposals, 1);
      }
    },
  );

  test('initialization cancellation has exact invocation ownership', () async {
    final preCancelled = CancellationController()..cancel('before');
    final untouched = _TestCapabilityAdapter(_capabilityEvidence());
    final first =
        (CapabilityRegistry.create(maximumListeners: 16, maximumCapabilities: 1)
                as Ok<CapabilityRegistry, StructuredFailure>)
            .value;
    expect(
      await first.initialize<void>(
        adapter: untouched,
        requiredVersion: _version(1, 0),
        cancellationToken: preCancelled.token,
      ),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(untouched.initializations, 0);
    expect(untouched.disposals, 0);

    final during = CancellationController();
    final invoked = _MismatchCapabilityAdapter(
      _capabilityEvidence(),
      _capabilityEvidence(),
      onInitialize: () => during.cancel('during'),
    );
    final second =
        (CapabilityRegistry.create(maximumListeners: 16, maximumCapabilities: 1)
                as Ok<CapabilityRegistry, StructuredFailure>)
            .value;
    expect(
      await second.initialize<void>(
        adapter: invoked,
        requiredVersion: _version(1, 0),
        cancellationToken: during.token,
      ),
      isA<Err<void, StructuredFailure>>(),
    );
    expect(invoked.initializations, 1);
    expect(invoked.disposals, 1);
  });

  test(
    'reentrant disposal and throwing rejected disposer remain one-use',
    () async {
      final base = _capabilityEvidence();
      late CapabilityRegistry registry;
      registry =
          (CapabilityRegistry.create(
                    maximumListeners: 16,
                    maximumCapabilities: 1,
                  )
                  as Ok<CapabilityRegistry, StructuredFailure>)
              .value;
      final disposedDuring = _MismatchCapabilityAdapter(
        _capabilityEvidence(),
        _capabilityEvidence(),
        onInitialize: registry.dispose,
      );
      expect(
        await registry.initialize<void>(
          adapter: disposedDuring,
          requiredVersion: _version(1, 0),
          cancellationToken: CancellationController().token,
        ),
        isA<Err<void, StructuredFailure>>(),
      );
      expect(disposedDuring.disposals, 1);

      final other =
          (CapabilityRegistry.create(
                    maximumListeners: 16,
                    maximumCapabilities: 1,
                  )
                  as Ok<CapabilityRegistry, StructuredFailure>)
              .value;
      final throwing = _MismatchCapabilityAdapter(
        base,
        _evidenceLike(
          base,
          key:
              (CapabilityKey.parse('alnote.platform.other')
                      as Ok<CapabilityKey, StructuredFailure>)
                  .value,
        ),
        throwOnDispose: true,
      );
      expect(
        await other.initialize<void>(
          adapter: throwing,
          requiredVersion: _version(1, 0),
          cancellationToken: CancellationController().token,
        ),
        isA<Err<void, StructuredFailure>>(),
      );
      expect(throwing.disposals, 1);
      other.dispose();
      expect(throwing.disposals, 1);
    },
  );

  test('token clock exceptions are redacted at mint and revalidation', () {
    final clock = _ToggleClock(DateTime.utc(2026))..throwNow = true;
    final authority = _authority(clock, 944);
    final bindings = _bindings();
    expect(
      authority.authorization(
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
        expiresAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
      ),
      isA<Err<AuthorizationToken, StructuredFailure>>(),
    );
    clock.throwNow = false;
    final token =
        (authority.authorization(
                  owner: bindings.$1,
                  operation: bindings.$2,
                  scope: bindings.$3,
                  expiresAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
                )
                as Ok<AuthorizationToken, StructuredFailure>)
            .value;
    clock.throwNow = true;
    expect(
      authority.revalidate(
        token,
        owner: bindings.$1,
        operation: bindings.$2,
        scope: bindings.$3,
      ),
      isA<Err<bool, StructuredFailure>>(),
    );
  });

  test('private storage evidence factories reject inconsistent states', () {
    final zero = (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
    final one = (Revision.create(1) as Ok<Revision, StructuredFailure>).value;
    final repository =
        (PrivateRepositoryId.parse('alnote.settings')
                as Ok<PrivateRepositoryId, StructuredFailure>)
            .value;
    final id =
        (PrivateRecordId.parse('record')
                as Ok<PrivateRecordId, StructuredFailure>)
            .value;
    final durability =
        (StorageDurabilityEvidence.create(durable: true, flushed: true)
                as Ok<StorageDurabilityEvidence, StructuredFailure>)
            .value;
    final record =
        (PrivateByteRecord.create(
                  id: id,
                  recordRevision: one,
                  bytes: const [1],
                  checksum: const [1],
                  lastKnownGood: true,
                  maximumBytes: 1,
                  maximumChecksumBytes: 1,
                )
                as Ok<PrivateByteRecord, StructuredFailure>)
            .value;
    expect(
      StorageDurabilityEvidence.create(durable: false, flushed: true),
      isA<Err<StorageDurabilityEvidence, StructuredFailure>>(),
    );
    expect(
      StoragePressureEvidence.create(
        pressure: StoragePressure.quotaExceeded,
        availableBytes: 1,
      ),
      isA<Err<StoragePressureEvidence, StructuredFailure>>(),
    );
    expect(
      StorageCorruptionEvidence.create(
        recordCount: 0,
        lastKnownGoodAvailable: false,
      ),
      isA<Err<StorageCorruptionEvidence, StructuredFailure>>(),
    );
    expect(
      ExternalStoreChangeEvidence.create(
        previousRevision: one,
        currentRevision: zero,
      ),
      isA<Err<ExternalStoreChangeEvidence, StructuredFailure>>(),
    );
    expect(
      PrivateStorageCommitEvidence.create(
        storeRevision: one,
        atomicity: StorageAtomicityEvidence.nonAtomic,
        durability: durability,
      ),
      isA<Err<PrivateStorageCommitEvidence, StructuredFailure>>(),
    );
    expect(
      PrivateStorageEnumeration.create(
        records: [record, record],
        truncated: false,
        maximumResults: 2,
        maximumRecordBytes: 1,
      ),
      isA<Err<PrivateStorageEnumeration, StructuredFailure>>(),
    );
    expect(
      PrivateCleanupPlan.create(
        repository: repository,
        expectedStoreRevision: zero,
        records: [id, id],
        maximumRecords: 2,
      ),
      isA<Err<PrivateCleanupPlan, StructuredFailure>>(),
    );
  });

  test('token replay and revocation are authority-owned', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final authority =
        (OpaqueTokenAuthority.create(
                  uuidGenerator: UuidSequenceGenerator.fromValues([
                    testUuid(949),
                  ]),
                  clock: clock,
                  maximumLifetime: const Duration(minutes: 1),
                  capabilityPolicy: _AllowTokenPolicy(),
                  maximumIssuedTokens: 4,
                  maximumConsumedTokens: 4,
                  maximumRevocationOwners: 4,
                )
                as Ok<OpaqueTokenAuthority, StructuredFailure>)
            .value;
    final owner =
        (OpaqueTokenOwner.parse('sessions')
                as Ok<OpaqueTokenOwner, StructuredFailure>)
            .value;
    final operation =
        (OpaqueTokenOperation.parse('save')
                as Ok<OpaqueTokenOperation, StructuredFailure>)
            .value;
    final scope =
        (OpaqueTokenScope.parse('one')
                as Ok<OpaqueTokenScope, StructuredFailure>)
            .value;
    final token =
        (authority.authorization(
                  owner: owner,
                  operation: operation,
                  scope: scope,
                  expiresAtUtc: clock.nowUtc().add(const Duration(seconds: 5)),
                )
                as Ok<AuthorizationToken, StructuredFailure>)
            .value;
    expect(
      authority.revalidate(
        token,
        owner: owner,
        operation: operation,
        scope: scope,
        consume: true,
      ),
      isA<Ok<bool, StructuredFailure>>().having(
        (value) => value.value,
        'value',
        isTrue,
      ),
    );
    expect(
      authority.revalidate(
        token,
        owner: owner,
        operation: operation,
        scope: scope,
      ),
      isA<Ok<bool, StructuredFailure>>().having(
        (value) => value.value,
        'value',
        isFalse,
      ),
    );
    expect(authority.revoke(owner), isA<Ok<void, StructuredFailure>>());
  });

  test('lifecycle sequencing and byte requests reject hostile values', () {
    final sequence = PlatformLifecycleSequencer();
    expect(
      sequence.next(kind: PlatformLifecycleKind.foreground, sequence: 1),
      isA<Ok<PlatformLifecycleEvent, StructuredFailure>>(),
    );
    expect(
      sequence.next(kind: PlatformLifecycleKind.background, sequence: 1),
      isA<Err<PlatformLifecycleEvent, StructuredFailure>>(),
    );
    final id =
        (PrivateRecordId.parse('record')
                as Ok<PrivateRecordId, StructuredFailure>)
            .value;
    expect(
      WritePrivateRecord.create(id: id, bytes: const [-1], maximumBytes: 1),
      isA<Err<WritePrivateRecord, StructuredFailure>>(),
    );
  });

  test('opaque tokens are distinct, redacted, owner-bound and expiring', () {
    final clock = ControllableClock(DateTime.utc(2026));
    final issuer =
        (OpaqueTokenAuthority.create(
                  uuidGenerator: UuidSequenceGenerator.fromValues([
                    testUuid(950),
                    testUuid(951),
                  ]),
                  clock: clock,
                  maximumLifetime: const Duration(minutes: 1),
                  capabilityPolicy: _AllowTokenPolicy(),
                  maximumIssuedTokens: 4,
                  maximumConsumedTokens: 4,
                  maximumRevocationOwners: 4,
                )
                as Ok<OpaqueTokenAuthority, StructuredFailure>)
            .value;
    final owner =
        (OpaqueTokenOwner.parse('sessions')
                as Ok<OpaqueTokenOwner, StructuredFailure>)
            .value;
    final other =
        (OpaqueTokenOwner.parse('other')
                as Ok<OpaqueTokenOwner, StructuredFailure>)
            .value;
    final operation =
        (OpaqueTokenOperation.parse('overwrite')
                as Ok<OpaqueTokenOperation, StructuredFailure>)
            .value;
    final scope =
        (OpaqueTokenScope.parse('one')
                as Ok<OpaqueTokenScope, StructuredFailure>)
            .value;
    final token =
        (issuer.authorization(
                  owner: owner,
                  operation: operation,
                  scope: scope,
                  expiresAtUtc: clock.nowUtc().add(const Duration(seconds: 1)),
                )
                as Ok<AuthorizationToken, StructuredFailure>)
            .value;
    expect(
      issuer.revalidate(
        token,
        owner: owner,
        operation: operation,
        scope: scope,
      ),
      isA<Ok<bool, StructuredFailure>>().having(
        (value) => value.value,
        'value',
        isTrue,
      ),
    );
    expect(
      issuer.revalidate(
        token,
        owner: other,
        operation: operation,
        scope: scope,
      ),
      isA<Ok<bool, StructuredFailure>>().having(
        (value) => value.value,
        'value',
        isFalse,
      ),
    );
    expect(token.toString(), isNot(contains(testUuid(950).value)));
    clock.advance(const Duration(seconds: 1));
    expect(
      issuer.revalidate(
        token,
        owner: owner,
        operation: operation,
        scope: scope,
      ),
      isA<Ok<bool, StructuredFailure>>().having(
        (value) => value.value,
        'value',
        isFalse,
      ),
    );
  });

  test(
    'capability publication is immutable, generation-based and listener-safe',
    () {
      final registry =
          (CapabilityRegistry.create(
                    maximumListeners: 16,
                    maximumCapabilities: 4,
                  )
                  as Ok<CapabilityRegistry, StructuredFailure>)
              .value;
      var calls = 0;
      registry.addListener((event) {
        calls++;
        throw StateError('listener');
      });
      final key =
          (CapabilityKey.parse('alnote.platform.private_storage')
                  as Ok<CapabilityKey, StructuredFailure>)
              .value;
      final version =
          (CapabilityContractVersion.create(major: 1, minor: 0)
                  as Ok<CapabilityContractVersion, StructuredFailure>)
              .value;
      final evidence =
          (CapabilityEvidence.create(
                    maximumLimitEntries: 16,
                    key: key,
                    contractVersion: version,
                    adapter:
                        (AdapterEvidence.create(identity: 'test', version: '1')
                                as Ok<AdapterEvidence, StructuredFailure>)
                            .value,
                    availability: CapabilityAvailability.supported,
                    health: CapabilityHealth.healthy,
                    degradation: CapabilityDegradation.none,
                    permission: CapabilityPermission.notApplicable,
                    limits: const {'bytes': 10},
                    initialization: const CapabilityInitializationEvidence(
                      attempted: true,
                      completed: true,
                    ),
                  )
                  as Ok<CapabilityEvidence, StructuredFailure>)
              .value;
      expect(registry.register(evidence), isA<Ok<void, StructuredFailure>>());
      expect(calls, 1);
      expect(registry.register(evidence), isA<Err<void, StructuredFailure>>());
      expect(
        () => registry.snapshot.capabilities.clear(),
        throwsUnsupportedError,
      );
      registry.dispose();
      registry.dispose();
    },
  );

  test(
    'private storage enforces expected revisions, defensive bytes and bounds',
    () async {
      final store = InMemoryPrivateStorage();
      final repository =
          (PrivateRepositoryId.parse('alnote.settings')
                  as Ok<PrivateRepositoryId, StructuredFailure>)
              .value;
      final record =
          (PrivateRecordId.parse('record')
                  as Ok<PrivateRecordId, StructuredFailure>)
              .value;
      final zero =
          (Revision.create(0) as Ok<Revision, StructuredFailure>).value;
      final bytes = [1, 2];
      final batch =
          (PrivateStorageBatch.create(
                    repository: repository,
                    expectedStoreRevision: zero,
                    operations: [
                      (WritePrivateRecord.create(
                                id: record,
                                bytes: bytes,
                                maximumBytes: 10,
                              )
                              as Ok<WritePrivateRecord, StructuredFailure>)
                          .value,
                    ],
                    maximumOperations: 1,
                  )
                  as Ok<PrivateStorageBatch, StructuredFailure>)
              .value;
      bytes[0] = 9;
      final committed = await store.commit(
        batch,
        maximumOperations: 1,
        maximumRecordBytes: 10,
        cancellationToken: CancellationController().token,
      );
      expect(
        committed,
        isA<Completed<PrivateStorageCommitEvidence, StructuredFailure>>(),
      );
      final stale = await store.commit(
        batch,
        maximumOperations: 1,
        maximumRecordBytes: 10,
        cancellationToken: CancellationController().token,
      );
      expect(
        stale,
        isA<Failed<PrivateStorageCommitEvidence, StructuredFailure>>(),
      );
      final read = await store.read(
        repository,
        record,
        maximumBytes: 10,
        cancellationToken: CancellationController().token,
      );
      expect(
        (read as Completed<PrivateByteRecord?, StructuredFailure>).value!.bytes,
        [1, 2],
      );
    },
  );

  test('platform byte factories stop before hostile oversized tails', () {
    final digest = _InfinitePlatformBytes();
    expect(
      ExternalFingerprint.create(
        strength: FingerprintStrength.fullContent,
        byteLength: 1,
        digest: digest,
        maximumDigestBytes: 2,
      ),
      isA<Err<ExternalFingerprint, StructuredFailure>>(),
    );
    expect(digest.moveNextCalls, 3);
    expect(digest.currentReads, 2);

    final bytes = _InfinitePlatformBytes();
    final id =
        (PrivateRecordId.parse('hostile')
                as Ok<PrivateRecordId, StructuredFailure>)
            .value;
    expect(
      WritePrivateRecord.create(id: id, bytes: bytes, maximumBytes: 2),
      isA<Err<WritePrivateRecord, StructuredFailure>>(),
    );
    expect(bytes.moveNextCalls, 3);
    expect(bytes.currentReads, 2);
  });

  test('capability limit maps and listeners honor zero and exact ceilings', () {
    final source = _capabilityEvidence();
    final infiniteLimits = InfiniteValues(const MapEntry('bytes', 1));
    expect(
      CapabilityEvidence.create(
        key: source.key,
        contractVersion: source.contractVersion,
        adapter: source.adapter,
        availability: source.availability,
        health: source.health,
        degradation: source.degradation,
        permission: source.permission,
        limits: HostileMap(infiniteLimits, reportedLength: 0),
        maximumLimitEntries: 1,
        initialization: source.initialization,
      ),
      isA<Err<CapabilityEvidence, StructuredFailure>>(),
    );
    expect(infiniteLimits.moveNextCalls, 2);
    expect(infiniteLimits.currentReads, 1);
    expect(
      CapabilityEvidence.create(
        key: source.key,
        contractVersion: source.contractVersion,
        adapter: source.adapter,
        availability: source.availability,
        health: source.health,
        degradation: source.degradation,
        permission: source.permission,
        limits: HostileMap(const [MapEntry('bytes', 1)], reportedLength: 0),
        maximumLimitEntries: 1,
        initialization: source.initialization,
      ),
      isA<Ok<CapabilityEvidence, StructuredFailure>>(),
    );
    expect(
      CapabilityEvidence.create(
        key: source.key,
        contractVersion: source.contractVersion,
        adapter: source.adapter,
        availability: source.availability,
        health: source.health,
        degradation: source.degradation,
        permission: source.permission,
        limits: HostileMap(ThrowingValues(), reportedLength: 0),
        maximumLimitEntries: 1,
        initialization: source.initialization,
      ),
      isA<Err<CapabilityEvidence, StructuredFailure>>(),
    );
    expect(
      CapabilityEvidence.create(
        key: source.key,
        contractVersion: source.contractVersion,
        adapter: source.adapter,
        availability: source.availability,
        health: source.health,
        degradation: source.degradation,
        permission: source.permission,
        limits: const {'bytes': 1},
        maximumLimitEntries: 0,
        initialization: source.initialization,
      ),
      isA<Err<CapabilityEvidence, StructuredFailure>>(),
    );
    expect(
      CapabilityEvidence.create(
        key: source.key,
        contractVersion: source.contractVersion,
        adapter: source.adapter,
        availability: source.availability,
        health: source.health,
        degradation: source.degradation,
        permission: source.permission,
        limits: const {'bytes': 1},
        maximumLimitEntries: 1,
        initialization: source.initialization,
      ),
      isA<Ok<CapabilityEvidence, StructuredFailure>>(),
    );
    final registry =
        (CapabilityRegistry.create(maximumCapabilities: 1, maximumListeners: 1)
                as Ok<CapabilityRegistry, StructuredFailure>)
            .value;
    void listener(CapabilityRegistryChange _) {}
    expect(registry.addListener(listener), isA<Ok<void, StructuredFailure>>());
    expect(registry.addListener(listener), isA<Ok<void, StructuredFailure>>());
    expect(registry.addListener((_) {}), isA<Err<void, StructuredFailure>>());
    registry.removeListener(listener);
    expect(registry.addListener((_) {}), isA<Ok<void, StructuredFailure>>());
  });
}

final class _InfinitePlatformBytes extends Iterable<int> {
  int moveNextCalls = 0;
  int currentReads = 0;
  @override
  Iterator<int> get iterator => _InfinitePlatformByteIterator(this);
}

final class _InfinitePlatformByteIterator implements Iterator<int> {
  _InfinitePlatformByteIterator(this.owner);
  final _InfinitePlatformBytes owner;
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

final class _AllowTokenPolicy implements OpaqueTokenCapabilityPolicy {
  @override
  Result<void, StructuredFailure> validate({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
  }) => const Ok(null);
}

final class _MutableTokenPolicy implements OpaqueTokenCapabilityPolicy {
  bool allowed = true;
  bool throwNow = false;
  int calls = 0;
  @override
  Result<void, StructuredFailure> validate({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
  }) {
    calls += 1;
    if (throwNow) throw StateError('secret policy');
    return allowed ? const Ok(null) : Err(testFailure('capability_denied'));
  }
}

OpaqueTokenAuthority _authority(
  Clock clock,
  int uuid, {
  OpaqueTokenCapabilityPolicy? policy,
  int maximumIssued = 4,
}) =>
    (OpaqueTokenAuthority.create(
              uuidGenerator: UuidSequenceGenerator.fromValues([
                testUuid(uuid),
                testUuid(uuid + 100),
              ]),
              clock: clock,
              maximumLifetime: const Duration(minutes: 1),
              capabilityPolicy: policy ?? _AllowTokenPolicy(),
              maximumIssuedTokens: maximumIssued,
              maximumConsumedTokens: 4,
              maximumRevocationOwners: 4,
            )
            as Ok<OpaqueTokenAuthority, StructuredFailure>)
        .value;

(OpaqueTokenOwner, OpaqueTokenOperation, OpaqueTokenScope) _bindings() => (
  (OpaqueTokenOwner.parse('sessions')
          as Ok<OpaqueTokenOwner, StructuredFailure>)
      .value,
  (OpaqueTokenOperation.parse('save')
          as Ok<OpaqueTokenOperation, StructuredFailure>)
      .value,
  (OpaqueTokenScope.parse('one') as Ok<OpaqueTokenScope, StructuredFailure>)
      .value,
);

CapabilityContractVersion _version(int major, int minor) =>
    (CapabilityContractVersion.create(major: major, minor: minor)
            as Ok<CapabilityContractVersion, StructuredFailure>)
        .value;

CapabilityEvidence _capabilityEvidence({
  String keyIdentity = 'alnote.platform.test',
  int minorVersion = 1,
  String adapterIdentity = 'test',
}) =>
    (CapabilityEvidence.create(
              maximumLimitEntries: 16,
              key:
                  (CapabilityKey.parse(keyIdentity)
                          as Ok<CapabilityKey, StructuredFailure>)
                      .value,
              contractVersion: _version(1, minorVersion),
              adapter:
                  (AdapterEvidence.create(
                            identity: adapterIdentity,
                            version: '1',
                          )
                          as Ok<AdapterEvidence, StructuredFailure>)
                      .value,
              availability: CapabilityAvailability.supported,
              health: CapabilityHealth.healthy,
              degradation: CapabilityDegradation.none,
              permission: CapabilityPermission.notApplicable,
              limits: const {},
              initialization: const CapabilityInitializationEvidence(
                attempted: true,
                completed: true,
              ),
            )
            as Ok<CapabilityEvidence, StructuredFailure>)
        .value;

CapabilityEvidence _evidenceLike(
  CapabilityEvidence source, {
  CapabilityKey? key,
  CapabilityContractVersion? version,
  AdapterEvidence? adapter,
}) =>
    (CapabilityEvidence.create(
              maximumLimitEntries: 16,
              key: key ?? source.key,
              contractVersion: version ?? source.contractVersion,
              adapter: adapter ?? source.adapter,
              availability: source.availability,
              health: source.health,
              degradation: source.degradation,
              permission: source.permission,
              limits: source.limits,
              initialization: source.initialization,
            )
            as Ok<CapabilityEvidence, StructuredFailure>)
        .value;

final class _TestCapabilityAdapter implements CapabilityAdapter<void> {
  _TestCapabilityAdapter(
    this.evidence, {
    this.failInitialization = false,
    this.throwInitialization = false,
  });
  final CapabilityEvidence evidence;
  final bool failInitialization;
  final bool throwInitialization;
  int initializations = 0;
  int disposals = 0;
  @override
  CapabilityKey get key => evidence.key;
  @override
  CapabilityContractVersion get contractVersion => evidence.contractVersion;
  @override
  AdapterEvidence get adapterEvidence => evidence.adapter;
  @override
  Future<Result<CapabilityEvidence, StructuredFailure>> initialize(
    CancellationToken cancellationToken,
  ) async {
    initializations += 1;
    if (throwInitialization) throw StateError('secret initialization');
    if (failInitialization) return Err(testFailure('adapter_failure'));
    return Ok(evidence);
  }

  @override
  Result<void, StructuredFailure> dispose() {
    disposals += 1;
    return const Ok(null);
  }
}

final class _ToggleClock implements Clock {
  _ToggleClock(this.value);
  final DateTime value;
  bool throwNow = false;
  @override
  DateTime nowUtc() {
    if (throwNow) throw StateError('secret clock');
    return value;
  }
}

final class _ReentrantCapabilityAdapter implements CapabilityAdapter<void> {
  _ReentrantCapabilityAdapter(this.evidence, this.reenter);
  final CapabilityEvidence evidence;
  final void Function() reenter;
  int disposals = 0;
  @override
  CapabilityKey get key => evidence.key;
  @override
  CapabilityContractVersion get contractVersion => evidence.contractVersion;
  @override
  AdapterEvidence get adapterEvidence => evidence.adapter;
  @override
  Future<Result<CapabilityEvidence, StructuredFailure>> initialize(
    CancellationToken cancellationToken,
  ) async {
    reenter();
    return Ok(evidence);
  }

  @override
  Result<void, StructuredFailure> dispose() {
    disposals += 1;
    return const Ok(null);
  }
}

final class _MismatchCapabilityAdapter implements CapabilityAdapter<void> {
  _MismatchCapabilityAdapter(
    this.metadata,
    this.returned, {
    this.onInitialize,
    this.throwOnDispose = false,
  });
  final CapabilityEvidence metadata;
  final CapabilityEvidence returned;
  final void Function()? onInitialize;
  final bool throwOnDispose;
  int initializations = 0;
  int disposals = 0;
  @override
  CapabilityKey get key => metadata.key;
  @override
  CapabilityContractVersion get contractVersion => metadata.contractVersion;
  @override
  AdapterEvidence get adapterEvidence => metadata.adapter;
  @override
  Future<Result<CapabilityEvidence, StructuredFailure>> initialize(
    CancellationToken cancellationToken,
  ) async {
    initializations += 1;
    onInitialize?.call();
    return Ok(returned);
  }

  @override
  Result<void, StructuredFailure> dispose() {
    disposals += 1;
    if (throwOnDispose) throw StateError('secret disposal');
    return const Ok(null);
  }
}
