// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pdf_geometry_checks.dart';

void main() {
  final approved = markedPdf(geometryCases.first, 0);
  final altered = List<int>.of(approved)..[10] ^= 1;

  test('fixed reviewed registry matches every retained local fixture', () {
    final manifest = jsonDecode(
      File('test/fixtures/phase8/admitted/manifest.json').readAsStringSync(),
    ) as List<dynamic>;
    expect(manifest.length, 45);
    for (final entry in manifest) {
      final row = entry as Map<String, dynamic>;
      final bytes = File('test/fixtures/phase8/admitted/${row['name']}.pdf')
          .readAsBytesSync();
      expect(bytes.length, row['bytes']);
      expect(
        geometryOk(Sha256Digest.calculate(bytes)).hexadecimal,
        row['sha256'],
      );
      expect(
        PdfFixtureAdmission.permits(bytes, CancellationController().token),
        isTrue,
      );
    }
  });

  test('approved bytes pass; unknown or one-byte modification never reaches inspect/render', () async {
    for (final bytes in [
      approved,
      altered,
      <int>[1, 2, 3],
    ]) {
      final delegate = _SpyBackend();
      final backend = DevelopmentFixturePdfBackend(delegate: delegate);
      final inspected = await backend.inspect(
        _inspection(),
        resourceReader: GeometryReader(bytes),
      );
      final rendered = await backend.render(
        _render(),
        resourceReader: GeometryReader(bytes),
      );
      if (identical(bytes, approved)) {
        expect(delegate.inspections, 1);
        expect(delegate.renders, 1);
      } else {
        expect(inspected, isA<PdfQuarantined>());
        expect(
          (rendered as PdfRenderFailure).reason,
          PdfRenderFailureReason.quarantined,
        );
        expect(delegate.inspections, 0);
        expect(delegate.renders, 0);
      }
    }
  });

  test(
    'serialized trust claims and reused resource UUID never grant admission',
    () async {
      final delegate = _SpyBackend();
      final backend = DevelopmentFixturePdfBackend(delegate: delegate);
      final reference = _reference();
      final forged = geometryOk(
        PdfPageReference.decode(
          PreservedMap({
            ...reference.encode().values,
            'trustedDevelopmentFixture': const PreservedBoolean(true),
            'approvedDigest': PreservedString(
              geometryOk(Sha256Digest.calculate(approved)).hexadecimal,
            ),
          }),
          limits: geometryModelLimits,
        ),
      );
      // A reopened reference can render approved bytes; the same UUID/reference
      // with modified bytes must be revalidated, without cached trust.
      await backend.render(
        _render(reference: forged),
        resourceReader: GeometryReader(approved),
      );
      final result = await backend.render(
        _render(reference: forged),
        resourceReader: GeometryReader(altered),
      );
      expect(delegate.renders, 1);
      expect(
        (result as PdfRenderFailure).reason,
        PdfRenderFailureReason.quarantined,
      );
    },
  );

  test(
    'admission freezes one read and forwards those exact immutable bytes',
    () async {
      final reader = _ChangingReader(approved, altered);
      final delegate = _SpyBackend();
      final backend = DevelopmentFixturePdfBackend(delegate: delegate);
      await backend.inspect(_inspection(), resourceReader: reader);
      expect(reader.calls, 1);
      expect(delegate.received, approved);
      expect(() => delegate.received![0] = 0, throwsUnsupportedError);
    },
  );

  test(
    'cancelled admission and simultaneous operations never reach delegate',
    () async {
      final delegate = _SpyBackend();
      final backend = DevelopmentFixturePdfBackend(delegate: delegate);
      final cancellation = CancellationController();
      final reader = _DelayedReader();
      final pending = backend.inspect(
        _inspection(token: cancellation.token),
        resourceReader: reader,
      );
      await reader.entered.future;
      final renderCancellation = CancellationController();
      final simultaneous = backend.render(
        _render(token: renderCancellation.token),
        resourceReader: GeometryReader(approved),
      );
      renderCancellation.cancel();
      expect(
        (await simultaneous as PdfRenderFailure).reason,
        PdfRenderFailureReason.cancelled,
      );
      cancellation.cancel();
      reader.done.complete(
        geometryOk(
          PdfResourceBytes.capture(
            identity: geometryIdentity,
            bytes: approved,
            limits: geometryProcessingLimits,
            cancellationToken: CancellationController().token,
          ),
        ),
      );
      expect(await pending, isA<PdfInspectionCancelled>());
      expect(delegate.inspections, 0);
      expect(delegate.renders, 0);
    },
  );
  test(
    'one latest waiter, cancellation and reserved completion need no retry',
    () async {
      final delegate = _SpyBackend();
      final backend = DevelopmentFixturePdfBackend(delegate: delegate);
      final oldReader = _DelayedReader();
      final active = backend.inspect(_inspection(), resourceReader: oldReader);
      await oldReader.entered.future;
      final readers = List.generate(
        20,
        (_) => _ChangingReader(approved, altered),
      );
      final pending = <Future<PdfRenderOutcome>>[];
      for (final reader in readers) {
        pending.add(backend.render(_render(), resourceReader: reader));
      }
      for (final abandoned in pending.take(19)) {
        expect(
          (await abandoned as PdfRenderFailure).reason,
          PdfRenderFailureReason.cancelled,
        );
      }
      expect(readers.map((r) => r.calls), everyElement(0));
      oldReader.done.complete(
        geometryOk(
          PdfResourceBytes.capture(
            identity: geometryIdentity,
            bytes: approved,
            limits: geometryProcessingLimits,
            cancellationToken: CancellationController().token,
          ),
        ),
      );
      await active;
      await pending.last;
      expect(readers.take(19).map((r) => r.calls), everyElement(0));
      expect(readers.last.calls, 1);
      expect(delegate.renders, 1);
      // Permanent failure is returned once; availability cannot retry it.
      await Future<void>.value();
      expect(delegate.renders, 1);
    },
  );

  test('completion before registration and cancellation after handoff release slot', () async {
    final delegate = _SpyBackend();
    final backend = DevelopmentFixturePdfBackend(delegate: delegate);
    // The idle path reserves synchronously, before its async continuation.
    final token = CancellationController();
    final cancelled = backend.render(
      _render(token: token.token),
      resourceReader: GeometryReader(approved),
    );
    token.cancel();
    final next = backend.render(
      _render(),
      resourceReader: GeometryReader(approved),
    );
    expect(
      (await cancelled as PdfRenderFailure).reason,
      PdfRenderFailureReason.cancelled,
    );
    await next;
    expect(delegate.renders, 1);
    await backend.render(_render(), resourceReader: GeometryReader(approved));
    expect(delegate.renders, 2);
  });
}

PdfInspectRequest _inspection({CancellationToken? token}) => PdfInspectRequest(
  resourceIdentity: geometryIdentity,
  trust: PdfInputTrust.trustedDevelopmentFixture,
  modelLimits: geometryModelLimits,
  limits: geometryProcessingLimits,
  cancellationToken: token ?? CancellationController().token,
);
PdfPageReference _reference() => geometryOk(
  PdfPageReference.create(
    resourceIdentity: geometryIdentity,
    pageIndex: 0,
    boxKind: PdfPageBoxKind.resolvedBounds,
    sourceBox: geometryOk(
      PdfSourceBox.create(
        left: 10,
        bottom: 20,
        right: 110,
        top: 90,
        limits: geometryModelLimits,
      ),
    ),
    rotation: PdfPageRotation.degrees0,
    displayedWidth: 100,
    displayedHeight: 70,
    limits: geometryModelLimits,
  ),
);
PdfRenderRequest _render({
  PdfPageReference? reference,
  CancellationToken? token,
}) => geometryOk(
  PdfRenderRequest.create(
    reference: reference ?? _reference(),
    trust: PdfInputTrust.trustedDevelopmentFixture,
    region: PdfPageClip.full,
    pixelWidth: 100,
    pixelHeight: 70,
    includeSafeNativeAppearances: false,
    limits: geometryProcessingLimits,
    cancellationToken: token ?? CancellationController().token,
  ),
);

final class _SpyBackend implements PdfBackend {
  int inspections = 0;
  int renders = 0;
  List<int>? received;
  @override
  Future<PdfInspectOutcome> inspect(
    PdfInspectRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    inspections++;
    final resource = geometryOk(
      await resourceReader.read(
        identity: request.resourceIdentity,
        limits: request.limits,
        cancellationToken: request.cancellationToken,
      ),
    );
    received = resource.bytes;
    return const PdfBackendUnavailable();
  }

  @override
  Future<PdfRenderOutcome> render(
    PdfRenderRequest request, {
    required PdfResourceReader resourceReader,
  }) async {
    renders++;
    return const PdfRenderFailure(PdfRenderFailureReason.backendUnavailable);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ChangingReader implements PdfResourceReader {
  _ChangingReader(this.first, this.second);
  final List<int> first;
  final List<int> second;
  int calls = 0;
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async => PdfResourceBytes.capture(
    identity: identity,
    bytes: calls++ == 0 ? first : second,
    limits: limits,
    cancellationToken: cancellationToken,
  );
}

final class _DelayedReader implements PdfResourceReader {
  final entered = Completer<void>();
  final done = Completer<PdfResourceBytes>();
  @override
  Future<Result<PdfResourceBytes, StructuredFailure>> read({
    required ResourceIdentity identity,
    required PdfProcessingLimits limits,
    required CancellationToken cancellationToken,
  }) async {
    entered.complete();
    return Ok(await done.future);
  }
}
