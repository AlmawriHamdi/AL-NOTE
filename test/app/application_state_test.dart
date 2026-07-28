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
        () => duplicate = ApplicationState.create(sourceRegistry: registry),
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
        ApplicationState.create(sourceRegistry: registry),
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
}

ApplicationState _application(CanonicalSourceRegistry registry) =>
    (ApplicationState.create(sourceRegistry: registry)
            as Ok<ApplicationState, StructuredFailure>)
        .value;

DocumentSession _plainSession(int uuid, CanonicalSourceRegistry registry) =>
    (DocumentSession.create(
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
                strength: FingerprintStrength.metadata,
                byteLength: 1,
                digest: const [1],
              )
              as Ok<ExternalFingerprint, StructuredFailure>)
          .value;
  return (DocumentSession.create(
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
