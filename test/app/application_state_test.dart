// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/app/state.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/sessions.dart'
    hide ApplicationState, ApplicationStateSnapshot;
import 'package:al_note/platform/platform.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/controllable_clock.dart';
import '../support/document_model_test_support.dart';
import '../support/phase3_test_support.dart';
import '../support/phase5_test_support.dart';
import '../support/uuid_sequence_generator.dart';

void main() {
  test(
    'duplicate Application creation is structured and preserves the owner',
    () {
      final registry = CanonicalSourceRegistry();
      final first = _application(registry);
      Result<ApplicationState, StructuredFailure>? duplicate;
      expect(
        () => duplicate = ApplicationState.create(
          maximumListeners: 16,
          maximumLifecycleListeners: 16,
          sourceRegistry: registry,
        ),
        returnsNormally,
      );
      expect(duplicate, isA<Err<ApplicationState, StructuredFailure>>());
      final session = _plainSession(749, registry);
      expect(
        first.registerSession(session, maximumSessions: 1),
        isA<Ok<DocumentSession, StructuredFailure>>(),
      );
    },
  );

  test('Session changes notify Application listeners exactly once', () {
    final registry = CanonicalSourceRegistry();
    final app = _application(registry);
    final session = _plainSession(750, registry);
    app.registerSession(session, maximumSessions: 2);
    var calls = 0;
    app.addListener((_) => calls += 1);
    session.setExternalSourceState(ExternalSourceState.changed);
    expect(calls, 1);
  });

  test('lookup-before-construction returns canonical open Session', () {
    final registry = CanonicalSourceRegistry();
    final app = _application(registry);
    final source =
        (NormalizedSourceIdentity.create('lookup-source')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final session = _boundSession(760, registry, source);
    app.registerSession(session, maximumSessions: 2);
    expect(app.sessionForSource(source), same(session));
  });

  test('failed registration rolls back canonical source claim', () {
    final registry = CanonicalSourceRegistry();
    final app = _application(registry);
    final source =
        (NormalizedSourceIdentity.create('rollback-source')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final rejected = _boundSession(770, registry, source);
    expect(
      app.registerSession(rejected, maximumSessions: 0),
      isA<Err<DocumentSession, StructuredFailure>>(),
    );
    expect(() => _boundSession(771, registry, source), returnsNormally);
  });

  test('failed registrations leave no abandoned registration attempt', () {
    final registry = CanonicalSourceRegistry();
    final app = _application(registry);
    final source =
        (NormalizedSourceIdentity.create('bounded-rollback-source')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    for (var index = 0; index < 3; index += 1) {
      final rejected = _boundSession(773 + index, registry, source);
      expect(
        app.registerSession(rejected, maximumSessions: 0),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );
      expect(registry.ownerOf(source), isNull);
    }
  });

  test(
    'registration authority is exclusive and registered ownership remains',
    () {
      final registry = CanonicalSourceRegistry();
      final app = _application(registry);
      final source =
          (NormalizedSourceIdentity.create('registered-source')
                  as Ok<NormalizedSourceIdentity, StructuredFailure>)
              .value;
      final session = _boundSession(772, registry, source);
      expect(
        app.registerSession(session, maximumSessions: 1),
        isA<Ok<DocumentSession, StructuredFailure>>(),
      );
      expect(
        ApplicationState.create(
          maximumListeners: 16,
          maximumLifecycleListeners: 16,
          sourceRegistry: registry,
        ),
        isA<Err<ApplicationState, StructuredFailure>>(),
      );
      expect(
        app.registerSession(session, maximumSessions: 1),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );
      expect(registry.ownerOf(source), session.id);
      expect(session.isCanonicalSourceOwner, isTrue);
    },
  );

  test('separate-copy mode comes only from Session construction', () {
    final registry = CanonicalSourceRegistry();
    final app = _application(registry);
    final source =
        (NormalizedSourceIdentity.create('copy-source')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final canonical = _boundSession(780, registry, source);
    final copy = _boundSession(781, registry, source, separate: true);
    app.registerSession(canonical, maximumSessions: 2);
    expect(
      app.registerSession(copy, maximumSessions: 2),
      isA<Ok<DocumentSession, StructuredFailure>>(),
    );
    expect(app.snapshot.sessions, hasLength(2));
  });

  test('a separate registry cannot alter canonical ownership', () {
    final firstRegistry = CanonicalSourceRegistry();
    final secondRegistry = CanonicalSourceRegistry();
    final source =
        (NormalizedSourceIdentity.create('authority-source')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final first = _boundSession(782, firstRegistry, source);
    _boundSession(783, secondRegistry, source);
    expect(firstRegistry.ownerOf(source), first.id);
  });

  test('source collision during reentrant notification is atomic', () {
    final registry = CanonicalSourceRegistry();
    final app = _application(registry);
    final source =
        (NormalizedSourceIdentity.create('reentrant-source')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final first = _boundSession(784, registry, source);
    Result<DocumentSession, StructuredFailure>? collision;
    app.addListener((_) {
      collision = DocumentSession.create(
        maximumQueuedPublications: 16,
        maximumListeners: 16,
        coordinator: phase3Coordinator(),
        publisher: FakeSessionPublisher(),
        uuidGenerator: UuidSequenceGenerator.fromValues([testUuid(785)]),
        clock: ControllableClock(DateTime.utc(2026)),
        sourceRegistry: registry,
        sourceBinding: StorageSourceBinding(
          sourceIdentity: source,
          fingerprint: first.snapshot.sourceBinding!.fingerprint,
        ),
      );
    });
    expect(
      app.registerSession(first, maximumSessions: 2),
      isA<Ok<DocumentSession, StructuredFailure>>(),
    );
    expect(collision, isA<Err<DocumentSession, StructuredFailure>>());
    expect(app.snapshot.sessions.keys, [first.id]);
    expect(registry.ownerOf(source), first.id);
  });

  test('deduplicates normalized sources unless separate copy is explicit', () {
    final source =
        (NormalizedSourceIdentity.create('source-a')
                as Ok<NormalizedSourceIdentity, StructuredFailure>)
            .value;
    final fingerprint =
        (ExternalFingerprint.create(
                  maximumDigestBytes: 64,
                  strength: FingerprintStrength.metadata,
                  byteLength: 1,
                  digest: const [0],
                )
                as Ok<ExternalFingerprint, StructuredFailure>)
            .value;
    final sourceRegistry = CanonicalSourceRegistry();
    Result<DocumentSession, StructuredFailure> make(
      int id, {
      bool separate = false,
    }) => DocumentSession.create(
      maximumQueuedPublications: 16,
      maximumListeners: 16,
      coordinator: phase3Coordinator(),
      publisher: FakeSessionPublisher(),
      uuidGenerator: UuidSequenceGenerator.fromValues([testUuid(id)]),
      clock: ControllableClock(DateTime.utc(2026)),
      sourceRegistry: sourceRegistry,
      sourceBinding: StorageSourceBinding(
        sourceIdentity: source,
        fingerprint: fingerprint,
      ),
      explicitSeparateCopy: separate,
    );
    final app = _application(sourceRegistry);
    final first = (make(820) as Ok<DocumentSession, StructuredFailure>).value;
    expect(
      (app.registerSession(first, maximumSessions: 3)
              as Ok<DocumentSession, StructuredFailure>)
          .value,
      same(first),
    );
    expect(make(821), isA<Err<DocumentSession, StructuredFailure>>());
    expect(app.snapshot.sessions, hasLength(1));
    expect(
      app.registerSession(
        (make(822, separate: true) as Ok<DocumentSession, StructuredFailure>)
            .value,
        maximumSessions: 3,
      ),
      isA<Ok<DocumentSession, StructuredFailure>>(),
    );
    expect(app.snapshot.sessions, hasLength(2));
  });

  test(
    'multiple views share one Session and final-view removal does not close it',
    () {
      final sourceRegistry = CanonicalSourceRegistry();
      final app = _application(sourceRegistry);
      final session =
          (DocumentSession.create(
                    maximumQueuedPublications: 16,
                    maximumListeners: 16,
                    coordinator: phase3Coordinator(),
                    publisher: FakeSessionPublisher(),
                    uuidGenerator: UuidSequenceGenerator.fromValues([
                      testUuid(830),
                    ]),
                    clock: ControllableClock(DateTime.utc(2026)),
                    sourceRegistry: sourceRegistry,
                  )
                  as Ok<DocumentSession, StructuredFailure>)
              .value;
      app.registerSession(session, maximumSessions: 2);
      final first = ViewId.fromUuid(testUuid(831)),
          second = ViewId.fromUuid(testUuid(832));
      app.attachView(
        view: first,
        session: session.id,
        maximumViewsPerSession: 2,
      );
      app.attachView(
        view: second,
        session: session.id,
        maximumViewsPerSession: 2,
      );
      app.detachView(first);
      app.detachView(second);
      expect(session.snapshot.lifecycle, SessionLifecycle.open);
      expect(app.snapshot.sessions, hasLength(1));
    },
  );

  test(
    'listener ceilings accept exact capacity, duplicates, removal and reentrancy',
    () {
      final registry = CanonicalSourceRegistry();
      final app =
          (ApplicationState.create(
                    sourceRegistry: registry,
                    maximumListeners: 1,
                    maximumLifecycleListeners: 1,
                  )
                  as Ok<ApplicationState, StructuredFailure>)
              .value;
      var calls = 0;
      late ApplicationStateListener listener;
      listener = (_) {
        calls += 1;
        expect(app.addListener(listener), isA<Ok<void, StructuredFailure>>());
      };
      expect(app.addListener(listener), isA<Ok<void, StructuredFailure>>());
      expect(app.addListener(listener), isA<Ok<void, StructuredFailure>>());
      expect(app.addListener((_) {}), isA<Err<void, StructuredFailure>>());
      app.focus(null);
      expect(calls, 1);
      app.removeListener(listener);
      expect(app.addListener((_) {}), isA<Ok<void, StructuredFailure>>());

      void lifecycle(PlatformLifecycleEvent _) {}
      expect(
        app.addLifecycleListener(lifecycle),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(
        app.addLifecycleListener(lifecycle),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(
        app.addLifecycleListener((_) {}),
        isA<Err<void, StructuredFailure>>(),
      );
      app.removeLifecycleListener(lifecycle);
      expect(
        app.addLifecycleListener((_) {}),
        isA<Ok<void, StructuredFailure>>(),
      );
    },
  );

  test(
    'capacity rejection is terminal and releases only the exact claim',
    () async {
      final registry = CanonicalSourceRegistry();
      final app = _application(registry);
      final source =
          (NormalizedSourceIdentity.create('terminal-rejection')
                  as Ok<NormalizedSourceIdentity, StructuredFailure>)
              .value;
      final rejected = _boundSession(840, registry, source);
      expect(
        app.registerSession(rejected, maximumSessions: 0),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );
      expect(rejected.snapshot.lifecycle, SessionLifecycle.failed);
      expect(rejected.isExplicitSeparateCopy, isFalse);
      expect(
        app.registerSession(rejected, maximumSessions: 1),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );
      expect(
        await rejected.save(cancellationToken: CancellationController().token),
        isA<SessionSaveResult>().having(
          (value) => value.disposition,
          'disposition',
          SessionSaveDisposition.failed,
        ),
      );
      expect(
        await rejected.saveAs(
          destinationIdentity: source,
          cancellationToken: CancellationController().token,
        ),
        isA<SessionSaveResult>().having(
          (value) => value.disposition,
          'disposition',
          SessionSaveDisposition.failed,
        ),
      );
      expect(
        rejected.attachView(ViewId.fromUuid(testUuid(841)), maximumViews: 1),
        isA<Err<void, StructuredFailure>>(),
      );
      expect(
        rejected.requestCloseDecision(validity: const Duration(seconds: 1)),
        isA<Err<CloseDecisionRequest, StructuredFailure>>(),
      );
      expect(registry.ownerOf(source), isNull);

      final rejectedCopy = _boundSession(843, registry, source, separate: true);
      expect(rejectedCopy.isExplicitSeparateCopy, isTrue);
      expect(
        app.registerSession(rejectedCopy, maximumSessions: 0),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );
      expect(rejectedCopy.snapshot.lifecycle, SessionLifecycle.failed);
      expect(
        app.registerSession(rejectedCopy, maximumSessions: 1),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );

      final replacement = _boundSession(842, registry, source);
      expect(
        app.registerSession(replacement, maximumSessions: 1),
        isA<Ok<DocumentSession, StructuredFailure>>(),
      );
      expect(registry.ownerOf(source), replacement.id);
    },
  );

  test(
    'internal Session observation failure leaves no partial registration',
    () {
      final registry = CanonicalSourceRegistry();
      final app = _application(registry);
      final session =
          (DocumentSession.create(
                    maximumQueuedPublications: 1,
                    maximumListeners: 0,
                    coordinator: phase3Coordinator(),
                    publisher: FakeSessionPublisher(),
                    uuidGenerator: UuidSequenceGenerator.fromValues([
                      testUuid(850),
                    ]),
                    clock: ControllableClock(DateTime.utc(2026)),
                    sourceRegistry: registry,
                  )
                  as Ok<DocumentSession, StructuredFailure>)
              .value;
      expect(
        app.registerSession(session, maximumSessions: 1),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );
      expect(session.snapshot.lifecycle, SessionLifecycle.failed);
      expect(app.snapshot.sessions, isEmpty);
    },
  );

  test(
    'registration rejection releases an exact coordinator listener slot',
    () {
      final sourceRegistry = CanonicalSourceRegistry();
      final app = _application(sourceRegistry);
      final coordinator = phase3Coordinator(maximumListeners: 1);
      DocumentSession create(int id) =>
          (DocumentSession.create(
                    maximumQueuedPublications: 1,
                    maximumListeners: 1,
                    coordinator: coordinator,
                    publisher: FakeSessionPublisher(),
                    uuidGenerator: UuidSequenceGenerator.fromValues([
                      testUuid(id),
                    ]),
                    clock: ControllableClock(DateTime.utc(2026)),
                    sourceRegistry: sourceRegistry,
                  )
                  as Ok<DocumentSession, StructuredFailure>)
              .value;
      final rejected = create(860);
      expect(
        app.registerSession(rejected, maximumSessions: 0),
        isA<Err<DocumentSession, StructuredFailure>>(),
      );
      expect(rejected.snapshot.lifecycle, SessionLifecycle.failed);
      expect(() => create(861), returnsNormally);
    },
  );
}

ApplicationState _application(CanonicalSourceRegistry registry) =>
    (ApplicationState.create(
              maximumListeners: 16,
              maximumLifecycleListeners: 16,
              sourceRegistry: registry,
            )
            as Ok<ApplicationState, StructuredFailure>)
        .value;

DocumentSession _plainSession(int uuid, CanonicalSourceRegistry registry) =>
    (DocumentSession.create(
              maximumQueuedPublications: 16,
              maximumListeners: 16,
              coordinator: phase3Coordinator(),
              publisher: FakeSessionPublisher(),
              uuidGenerator: UuidSequenceGenerator.fromValues([testUuid(uuid)]),
              clock: ControllableClock(DateTime.utc(2026)),
              sourceRegistry: registry,
            )
            as Ok<DocumentSession, StructuredFailure>)
        .value;

DocumentSession _boundSession(
  int uuid,
  CanonicalSourceRegistry registry,
  NormalizedSourceIdentity source, {
  bool separate = false,
}) {
  final fingerprint =
      (ExternalFingerprint.create(
                maximumDigestBytes: 64,
                strength: FingerprintStrength.metadata,
                byteLength: 1,
                digest: const [1],
              )
              as Ok<ExternalFingerprint, StructuredFailure>)
          .value;
  return (DocumentSession.create(
            maximumQueuedPublications: 16,
            maximumListeners: 16,
            coordinator: phase3Coordinator(),
            publisher: FakeSessionPublisher(),
            uuidGenerator: UuidSequenceGenerator.fromValues([testUuid(uuid)]),
            clock: ControllableClock(DateTime.utc(2026)),
            sourceRegistry: registry,
            sourceBinding: StorageSourceBinding(
              sourceIdentity: source,
              fingerprint: fingerprint,
            ),
            explicitSeparateCopy: separate,
          )
          as Ok<DocumentSession, StructuredFailure>)
      .value;
}
