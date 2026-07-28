// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/sessions.dart';
import 'package:al_note/platform/platform.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/controllable_clock.dart';
import '../../support/document_model_test_support.dart';
import '../../support/phase3_test_support.dart';
import '../../support/phase5_test_support.dart';
import '../../support/uuid_sequence_generator.dart';

void main() {
  test(
    'new close evidence replaces abandoned requests and authorization',
    () async {
      final session = _session(700, uuidValues: [700, 701, 702, 703]);
      final first =
          (session.requestCloseDecision(validity: const Duration(minutes: 1))
                  as Ok<CloseDecisionRequest, StructuredFailure>)
              .value;
      final second =
          (session.requestCloseDecision(validity: const Duration(minutes: 1))
                  as Ok<CloseDecisionRequest, StructuredFailure>)
              .value;
      expect(
        await session.resolveCloseDecision(
          first,
          CloseDecision(
            sessionId: session.id,
            token: first.token,
            resolution: CloseResolution.cancel,
          ),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<CloseAuthorization, StructuredFailure>>(),
      );
      final authorization = await _resolveDiscard(session, second);
      final replacement = session.requestCloseDecision(
        validity: const Duration(minutes: 1),
      );
      expect(replacement, isA<Ok<CloseDecisionRequest, StructuredFailure>>());
      expect(session.close(authorization), isA<Err<void, StructuredFailure>>());
    },
  );

  test(
    'close freshness captures one UTC time and contains hostile clocks',
    () async {
      final clock = _MutableClock(DateTime.utc(2026));
      final generator = UuidSequenceGenerator.fromValues([
        testUuid(710),
        testUuid(711),
        testUuid(712),
      ]);
      final session = _sessionWith(clock, generator);
      final before = session.snapshot;
      clock.throwNow = true;
      expect(
        session.requestCloseDecision(validity: const Duration(minutes: 1)),
        isA<Err<CloseDecisionRequest, StructuredFailure>>(),
      );
      expect(generator.remaining, 2);
      expect(session.snapshot.revision, before.revision);
      clock
        ..throwNow = false
        ..utc = false;
      expect(
        session.requestCloseDecision(validity: const Duration(minutes: 1)),
        isA<Err<CloseDecisionRequest, StructuredFailure>>(),
      );
      expect(generator.remaining, 2);
      clock
        ..utc = true
        ..reads = 0;
      final request =
          (session.requestCloseDecision(validity: const Duration(minutes: 1))
                  as Ok<CloseDecisionRequest, StructuredFailure>)
              .value;
      expect(clock.reads, 1);
      clock.throwNow = true;
      expect(
        await session.resolveCloseDecision(
          request,
          CloseDecision(
            sessionId: session.id,
            token: request.token,
            resolution: CloseResolution.cancel,
          ),
          cancellationToken: CancellationController().token,
        ),
        isA<Failed<CloseAuthorization, StructuredFailure>>(),
      );
      clock.throwNow = false;
      expect(
        await session.resolveCloseDecision(
          request,
          CloseDecision(
            sessionId: session.id,
            token: request.token,
            resolution: CloseResolution.cancel,
          ),
          cancellationToken: CancellationController().token,
        ),
        isA<Cancelled<CloseAuthorization, StructuredFailure>>(),
      );
    },
  );

  test('overflowing close expiry consumes no UUID or Session state', () {
    final generator = UuidSequenceGenerator.fromValues([
      testUuid(720),
      testUuid(721),
    ]);
    final session = _sessionWith(_MutableClock(DateTime.utc(2026)), generator);
    final before = session.snapshot.revision;
    expect(
      session.requestCloseDecision(
        validity: const Duration(microseconds: 9223372036854775807),
      ),
      isA<Err<CloseDecisionRequest, StructuredFailure>>(),
    );
    expect(generator.remaining, 1);
    expect(session.snapshot.revision, before);
  });
  test('edit after close authorization makes close atomic and stale', () async {
    final session = _session(700);
    final authorization = await _discardAuthorization(session);
    _edit(session.coordinator, 'newer');
    final before = session.snapshot;
    expect(session.close(authorization), isA<Err<void, StructuredFailure>>());
    expect(session.snapshot.lifecycle, before.lifecycle);
  });

  test('wrong Session and replayed close authorization reject', () async {
    final first = _session(710);
    final second = _session(720);
    final authorization = await _discardAuthorization(first);
    expect(second.close(authorization), isA<Err<void, StructuredFailure>>());
    expect(first.close(authorization), isA<Ok<void, StructuredFailure>>());
    expect(first.close(authorization), isA<Err<void, StructuredFailure>>());
  });

  test('external-state change invalidates close authorization', () async {
    final session = _session(730);
    final authorization = await _discardAuthorization(session);
    session.setExternalSourceState(ExternalSourceState.changed);
    expect(session.close(authorization), isA<Err<void, StructuredFailure>>());
    expect(session.snapshot.lifecycle, SessionLifecycle.open);
  });

  test('editing during close Save As requires a new decision', () async {
    final coordinator = phase3Coordinator();
    _edit(coordinator, 'dirty');
    final publisher = FakeSessionPublisher();
    final session = _session(
      740,
      coordinator: coordinator,
      publisher: publisher,
      uuidValues: [740, 741, 742],
    );
    final request =
        (session.requestCloseDecision(validity: const Duration(minutes: 1))
                as Ok<CloseDecisionRequest, StructuredFailure>)
            .value;
    final destination =
        (NormalizedSourceIdentity.create('close-save-as')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final pending = session.resolveCloseDecision(
      request,
      CloseDecision(
        sessionId: session.id,
        token: request.token,
        resolution: CloseResolution.saveAs,
      ),
      saveAsDestination: destination,
      cancellationToken: CancellationController().token,
    );
    await Future<void>.microtask(() {});
    _edit(coordinator, 'newer-during-save');
    final fingerprint =
        (ExternalFingerprint.create(
                  strength: FingerprintStrength.fullContent,
                  byteLength: 1,
                  digest: const [1],
                )
                as Ok<ExternalFingerprint, StructuredFailure>)
            .value;
    publisher.completions.single.complete(
      Completed(
        SessionPublicationEvidence(
          sourceIdentity: destination,
          fingerprint: fingerprint,
          fresh: true,
        ),
      ),
    );
    expect(await pending, isA<Failed<CloseAuthorization, StructuredFailure>>());
    expect(session.snapshot.isDirty, isTrue);
    expect(session.snapshot.lifecycle, SessionLifecycle.open);
  });

  test('ordinary Save without a source has no publisher side effect', () async {
    final publisher = FakeSessionPublisher();
    final session =
        (DocumentSession.create(
                  coordinator: phase3Coordinator(),
                  publisher: publisher,
                  uuidGenerator: UuidSequenceGenerator.fromValues([
                    testUuid(799),
                  ]),
                  clock: ControllableClock(DateTime.utc(2026)),
                  sourceRegistry: CanonicalSourceRegistry(),
                )
                as Ok<DocumentSession, StructuredFailure>)
            .value;
    final result = await session.save(
      cancellationToken: CancellationController().token,
    );
    expect(result.disposition, SessionSaveDisposition.failed);
    expect(publisher.requests, isEmpty);
  });

  test('successful Save proactively invalidates close authorization', () async {
    final publisher = FakeSessionPublisher();
    final source =
        (NormalizedSourceIdentity.create('save-invalidates-close')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final initialFingerprint =
        (ExternalFingerprint.create(
                  strength: FingerprintStrength.metadata,
                  byteLength: 1,
                  digest: const [1],
                )
                as Ok<ExternalFingerprint, StructuredFailure>)
            .value;
    final session =
        (DocumentSession.create(
                  coordinator: phase3Coordinator(),
                  publisher: publisher,
                  uuidGenerator: UuidSequenceGenerator.fromValues([
                    testUuid(797),
                    testUuid(798),
                    testUuid(799),
                  ]),
                  clock: ControllableClock(DateTime.utc(2026)),
                  sourceRegistry: CanonicalSourceRegistry(),
                  sourceBinding: StorageSourceBinding(
                    sourceIdentity: source,
                    fingerprint: initialFingerprint,
                  ),
                )
                as Ok<DocumentSession, StructuredFailure>)
            .value;
    final authorization = await _discardAuthorization(session);
    final pending = session.save(
      cancellationToken: CancellationController().token,
    );
    await Future<void>.microtask(() {});
    publisher.completions.single.complete(
      Completed(
        SessionPublicationEvidence(
          sourceIdentity: source,
          fingerprint: initialFingerprint,
          fresh: true,
        ),
      ),
    );
    expect((await pending).disposition, SessionSaveDisposition.published);
    expect(session.close(authorization), isA<Err<void, StructuredFailure>>());
    expect(session.snapshot.lifecycle, SessionLifecycle.open);
  });

  test(
    'unsaved baseline is dirty while default loaded baseline stays clean',
    () {
      final generator = UuidSequenceGenerator.fromValues([testUuid(800)]);
      final result = DocumentMutationCoordinator.create(
        initialRoot: phase3Notebook(),
        validator: DocumentValidator(editableTestRegistry()),
        uuidGenerator: generator,
        historyLimits: commandValue(
          HistoryLimits.create(
            maximumRetainedCommandCount: 10,
            maximumEstimatedRetainedBytes: 1000,
          ),
        ),
        retainedCostEstimator: FixedHistoryCostEstimator(1),
        initialSaveState: InitialDocumentSaveState.unsaved,
      );
      final coordinator =
          (result as Ok<DocumentMutationCoordinator, CommandFailure>).value;
      expect(coordinator.snapshot.savedContentIdentity, isNull);
      expect(coordinator.snapshot.isDirty, isTrue);
      expect(phase3Coordinator().snapshot.isDirty, isFalse);
    },
  );

  test(
    'Save is serialized and Save As binds only fresh successful evidence',
    () async {
      final coordinatorGenerator = UuidSequenceGenerator.fromValues([
        testUuid(801),
      ]);
      final coordinator =
          (DocumentMutationCoordinator.create(
                    initialRoot: phase3Notebook(),
                    validator: DocumentValidator(editableTestRegistry()),
                    uuidGenerator: coordinatorGenerator,
                    historyLimits: commandValue(
                      HistoryLimits.create(
                        maximumRetainedCommandCount: 10,
                        maximumEstimatedRetainedBytes: 1000,
                      ),
                    ),
                    retainedCostEstimator: FixedHistoryCostEstimator(1),
                    initialSaveState: InitialDocumentSaveState.unsaved,
                  )
                  as Ok<DocumentMutationCoordinator, CommandFailure>)
              .value;
      final publisher = FakeSessionPublisher();
      final runtimeGenerator = UuidSequenceGenerator.fromValues([
        testUuid(802),
        testUuid(803),
        testUuid(804),
      ]);
      final session =
          (DocumentSession.create(
                    coordinator: coordinator,
                    publisher: publisher,
                    uuidGenerator: runtimeGenerator,
                    clock: ControllableClock(DateTime.utc(2026)),
                    sourceRegistry: CanonicalSourceRegistry(),
                  )
                  as Ok<DocumentSession, StructuredFailure>)
              .value;
      final destination =
          (NormalizedSourceIdentity.create('opaque-source')
                  as Ok<NormalizedSourceIdentity, StructuredFailure>)
              .value;
      final first = session.saveAs(
        destinationIdentity: destination,
        cancellationToken: CancellationController().token,
      );
      final second = session.save(
        cancellationToken: CancellationController().token,
      );
      await Future<void>.microtask(() {});
      expect(publisher.requests, hasLength(1));
      final fingerprint =
          (ExternalFingerprint.create(
                    strength: FingerprintStrength.fullContent,
                    byteLength: 12,
                    digest: [1, 2],
                  )
                  as Ok<ExternalFingerprint, StructuredFailure>)
              .value;
      publisher.completions.first.complete(
        Completed(
          SessionPublicationEvidence(
            sourceIdentity: destination,
            fingerprint: fingerprint,
            fresh: true,
          ),
        ),
      );
      expect((await first).disposition, SessionSaveDisposition.published);
      await Future<void>.microtask(() {});
      expect(publisher.requests, hasLength(1));
      expect((await second).disposition, SessionSaveDisposition.failed);
      expect(session.snapshot.sourceBinding?.sourceIdentity, destination);
      expect(session.snapshot.isDirty, isFalse);
    },
  );

  test(
    'close decision is owner-bound, one-use, freshness-bound and expiring',
    () {
      final clock = ControllableClock(DateTime.utc(2026));
      final session =
          (DocumentSession.create(
                    coordinator: phase3Coordinator(),
                    publisher: FakeSessionPublisher(),
                    uuidGenerator: UuidSequenceGenerator.fromValues([
                      testUuid(810),
                      testUuid(811),
                    ]),
                    clock: clock,
                    sourceRegistry: CanonicalSourceRegistry(),
                  )
                  as Ok<DocumentSession, StructuredFailure>)
              .value;
      final request =
          (session.requestCloseDecision(validity: const Duration(seconds: 1))
                  as Ok<CloseDecisionRequest, StructuredFailure>)
              .value;
      final decision = CloseDecision(
        sessionId: session.id,
        token: request.token,
        resolution: CloseResolution.cancel,
      );
      final first = session.resolveCloseDecision(
        request,
        decision,
        cancellationToken: CancellationController().token,
      );
      expect(
        first,
        completion(isA<Cancelled<CloseAuthorization, StructuredFailure>>()),
      );
      expect(
        session.resolveCloseDecision(
          request,
          decision,
          cancellationToken: CancellationController().token,
        ),
        completion(isA<Failed<CloseAuthorization, StructuredFailure>>()),
      );
    },
  );
}

DocumentSession _session(
  int uuid, {
  DocumentMutationCoordinator? coordinator,
  FakeSessionPublisher? publisher,
  List<int>? uuidValues,
}) =>
    (DocumentSession.create(
              coordinator: coordinator ?? phase3Coordinator(),
              publisher: publisher ?? FakeSessionPublisher(),
              uuidGenerator: UuidSequenceGenerator.fromValues([
                for (final value in uuidValues ?? [uuid, uuid + 1])
                  testUuid(value),
              ]),
              clock: ControllableClock(DateTime.utc(2026)),
              sourceRegistry: CanonicalSourceRegistry(),
            )
            as Ok<DocumentSession, StructuredFailure>)
        .value;

Future<CloseAuthorization> _discardAuthorization(
  DocumentSession session,
) async {
  final request =
      (session.requestCloseDecision(validity: const Duration(minutes: 1))
              as Ok<CloseDecisionRequest, StructuredFailure>)
          .value;
  final outcome = await session.resolveCloseDecision(
    request,
    CloseDecision(
      sessionId: session.id,
      token: request.token,
      resolution: CloseResolution.discard,
    ),
    cancellationToken: CancellationController().token,
  );
  return (outcome as Completed<CloseAuthorization, StructuredFailure>).value;
}

Future<CloseAuthorization> _resolveDiscard(
  DocumentSession session,
  CloseDecisionRequest request,
) async {
  final outcome = await session.resolveCloseDecision(
    request,
    CloseDecision(
      sessionId: session.id,
      token: request.token,
      resolution: CloseResolution.discard,
    ),
    cancellationToken: CancellationController().token,
  );
  return (outcome as Completed<CloseAuthorization, StructuredFailure>).value;
}

DocumentSession _sessionWith(Clock clock, UuidSequenceGenerator generator) =>
    (DocumentSession.create(
              coordinator: phase3Coordinator(),
              publisher: FakeSessionPublisher(),
              uuidGenerator: generator,
              clock: clock,
              sourceRegistry: CanonicalSourceRegistry(),
            )
            as Ok<DocumentSession, StructuredFailure>)
        .value;

final class _MutableClock implements Clock {
  _MutableClock(this.value);
  final DateTime value;
  bool throwNow = false;
  bool utc = true;
  int reads = 0;
  @override
  DateTime nowUtc() {
    reads += 1;
    if (throwNow) throw StateError('secret clock');
    return utc ? value.toUtc() : value.toLocal();
  }
}

void _edit(DocumentMutationCoordinator coordinator, String payload) {
  final snapshot = coordinator.snapshot;
  final target = snapshot.root.pages.single.layers.single.objects.first.id;
  final source = snapshot.root.pages.single.layers.single.objects.first;
  coordinator.execute(
    commandValue(
      AtomicObjectReplacementRequest.create(
        documentId: snapshot.root.id,
        metadata: phase3Metadata(
          correlation: payload.hashCode.abs() % 100000 + 1000,
        ),
        preconditions: objectPreconditions(snapshot, target),
        targetIds: [target],
        replacements: [replacementObject(source, payload)],
        changeCategories: const ObjectReplacementChangeCategories(
          appearance: true,
          text: false,
          metadata: false,
        ),
      ),
    ),
  );
}
