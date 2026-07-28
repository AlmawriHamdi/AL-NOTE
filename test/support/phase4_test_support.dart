// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/files.dart';

/// Creates a complete explicit Phase 4 limit snapshot with no production defaults.
ResourceLimitSnapshot phase4Limits({
  int ceiling = 1000000,
  Map<String, int> overrides = const <String, int>{},
}) {
  final limits = <({ResourceLimitKey key, ResourceLimitCeiling ceiling})>[];
  for (final requirement in alnoteStorageLimitRequirements.entries) {
    final key =
        (ResourceLimitKey.parse(requirement.key)
                as Ok<ResourceLimitKey, StructuredFailure>)
            .value;
    final unitCeiling =
        (ResourceLimitCeiling.create(
                  value:
                      overrides[requirement.key] ??
                      (requirement.value == ResourceLimitUnit.ratio
                          ? 1000
                          : ceiling),
                  unit: requirement.value,
                )
                as Ok<ResourceLimitCeiling, StructuredFailure>)
            .value;
    limits.add((key: key, ceiling: unitCeiling));
  }
  return (ResourceLimitSnapshot.create(limits)
          as Ok<ResourceLimitSnapshot, StructuredFailure>)
      .value;
}

/// A deterministic in-memory portable package source.
final class InMemoryPackageSource implements PackageByteSource {
  /// Defensively captures source bytes.
  InMemoryPackageSource(Iterable<int> bytes)
    : bytes = List<int>.unmodifiable(List<int>.of(bytes));

  /// Immutable source bytes.
  final List<int> bytes;

  @override
  Future<OperationOutcome<List<int>, StructuredFailure>> readAll({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) async {
    if (cancellationToken.isCancelled) {
      return Cancelled<List<int>, StructuredFailure>(cancellationToken.reason);
    }
    if (bytes.length > maximumBytes) {
      return Failed<List<int>, StructuredFailure>(_fakeFailure('source_limit'));
    }
    return Completed<List<int>, StructuredFailure>(
      List<int>.unmodifiable(List<int>.of(bytes)),
    );
  }
}

/// Deterministic fault modes for complete replacement tests.
enum ReplacementFault {
  /// No injected fault.
  none,

  /// Accept fewer bytes than supplied.
  shortWrite,

  /// Fail explicit flush.
  flush,

  /// Corrupt staged read-back bytes.
  readBack,

  /// Fail final replacement.
  replacement,
}

/// One adapter boundary selected for deterministic failure or exception.
enum SaveAdapterBoundary {
  beginStaging,
  supportsFlush,
  write,
  flush,
  readBack,
  fingerprint,
  commit,
  abort,
}

/// A deterministic in-memory complete-replacement destination.
final class InMemoryReplacementDestination
    implements PackageReplacementDestination {
  /// Creates a destination retaining [generation] until successful commit.
  InMemoryReplacementDestination({
    Iterable<int> generation = const <int>[],
    this.fault = ReplacementFault.none,
    this.atomic = true,
    this.durable = true,
    this.flushSupported = true,
    this.flushEvidenceFlushed = true,
    this.reportedFingerprint,
    this.failAt,
    this.throwAt,
    this.oversizedReadBack = false,
    this.returnMutableReadBack = false,
    this.beforeConditionalCommit,
    this.afterSuccessfulCommit,
    this.hostile = 'adapter-secret',
  }) : generation = List<int>.of(generation);

  /// Current committed generation.
  List<int> generation;

  /// Injected deterministic fault.
  final ReplacementFault fault;

  /// Replacement atomicity evidence.
  final bool atomic;

  /// Explicit durability evidence.
  final bool durable;

  /// Whether flush is supported.
  final bool flushSupported;

  /// Whether a completed explicit flush reports actual flush evidence.
  final bool flushEvidenceFlushed;

  /// Optional externally controlled conflict evidence.
  PackageFingerprint? reportedFingerprint;

  /// Boundary returning a secret-bearing failure.
  final SaveAdapterBoundary? failAt;

  /// Boundary throwing a secret-bearing exception.
  final SaveAdapterBoundary? throwAt;

  /// Whether read-back violates its authorized maximum.
  final bool oversizedReadBack;

  /// Whether read-back intentionally returns a mutable adapter-owned list.
  final bool returnMutableReadBack;

  /// Last adapter-owned read-back list for defensive-copy assertions.
  List<int>? lastReadBack;

  /// Hook run inside the atomic conditional replacement operation.
  final void Function(InMemoryReplacementDestination destination)?
  beforeConditionalCommit;

  /// Hook run after replacement succeeds but before evidence returns.
  final void Function(InMemoryReplacementDestination destination)?
  afterSuccessfulCommit;

  /// Hostile adapter text that coordinator diagnostics must never retain.
  final String hostile;

  /// Whether staging was aborted.
  bool aborted = false;

  /// Whether replacement committed.
  bool committed = false;

  @override
  Future<OperationOutcome<PackageStagingArea, StructuredFailure>> beginStaging({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) async {
    _throwIf(SaveAdapterBoundary.beginStaging);
    if (failAt == SaveAdapterBoundary.beginStaging) {
      return Failed<PackageStagingArea, StructuredFailure>(_hostileFailure());
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<PackageStagingArea, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<PackageStagingArea, StructuredFailure>(
      _InMemoryStaging(this, maximumBytes),
    );
  }

  @override
  Future<OperationOutcome<PackageFingerprint?, StructuredFailure>> fingerprint({
    required CancellationToken cancellationToken,
  }) async {
    _throwIf(SaveAdapterBoundary.fingerprint);
    if (failAt == SaveAdapterBoundary.fingerprint) {
      return Failed<PackageFingerprint?, StructuredFailure>(_hostileFailure());
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<PackageFingerprint?, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<PackageFingerprint?, StructuredFailure>(
      reportedFingerprint,
    );
  }

  void _throwIf(SaveAdapterBoundary boundary) {
    if (throwAt == boundary) throw StateError(hostile);
  }

  StructuredFailure _hostileFailure() => StructuredFailure(
    code: 'test.storage.$hostile',
    category: FailureCategory.platform,
    retryDisposition: RetryDisposition.never,
    message: hostile,
  );
}

final class _InMemoryStaging implements PackageStagingArea {
  _InMemoryStaging(this.owner, this.maximumBytes);

  final InMemoryReplacementDestination owner;
  final int maximumBytes;
  final List<int> staged = <int>[];

  @override
  bool get supportsFlush {
    owner._throwIf(SaveAdapterBoundary.supportsFlush);
    return owner.flushSupported;
  }

  @override
  Future<OperationOutcome<int, StructuredFailure>> write(
    List<int> bytes, {
    required CancellationToken cancellationToken,
  }) async {
    owner._throwIf(SaveAdapterBoundary.write);
    if (owner.failAt == SaveAdapterBoundary.write) {
      return Failed<int, StructuredFailure>(owner._hostileFailure());
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<int, StructuredFailure>(cancellationToken.reason);
    }
    if (bytes.length > maximumBytes) {
      return Failed<int, StructuredFailure>(_fakeFailure('destination_limit'));
    }
    final accepted = owner.fault == ReplacementFault.shortWrite
        ? bytes.length - 1
        : bytes.length;
    staged.addAll(bytes.take(accepted));
    return Completed<int, StructuredFailure>(accepted);
  }

  @override
  Future<OperationOutcome<SaveDurabilityEvidence, StructuredFailure>> flush({
    required CancellationToken cancellationToken,
  }) async {
    owner._throwIf(SaveAdapterBoundary.flush);
    if (owner.failAt == SaveAdapterBoundary.flush) {
      return Failed<SaveDurabilityEvidence, StructuredFailure>(
        owner._hostileFailure(),
      );
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<SaveDurabilityEvidence, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    if (owner.fault == ReplacementFault.flush) {
      return Failed<SaveDurabilityEvidence, StructuredFailure>(
        _fakeFailure('flush'),
      );
    }
    return Completed<SaveDurabilityEvidence, StructuredFailure>(
      SaveDurabilityEvidence(
        flushed: owner.flushEvidenceFlushed,
        durable: owner.durable,
      ),
    );
  }

  @override
  Future<OperationOutcome<List<int>, StructuredFailure>> readBack({
    required int maximumBytes,
    required CancellationToken cancellationToken,
  }) async {
    owner._throwIf(SaveAdapterBoundary.readBack);
    if (owner.failAt == SaveAdapterBoundary.readBack) {
      return Failed<List<int>, StructuredFailure>(owner._hostileFailure());
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<List<int>, StructuredFailure>(cancellationToken.reason);
    }
    final result = List<int>.of(staged);
    if (owner.fault == ReplacementFault.readBack && result.isNotEmpty) {
      result[result.length ~/ 2] ^= 1;
    }
    if (owner.oversizedReadBack) {
      result.addAll(List<int>.filled(maximumBytes + 1, 0));
    }
    owner.lastReadBack = result;
    return Completed<List<int>, StructuredFailure>(
      owner.returnMutableReadBack ? result : List<int>.unmodifiable(result),
    );
  }

  @override
  Future<OperationOutcome<SaveReplacementEvidence, StructuredFailure>> commit({
    required PackageFingerprint? expectedFingerprint,
    required CancellationToken cancellationToken,
  }) async {
    owner._throwIf(SaveAdapterBoundary.commit);
    if (owner.failAt == SaveAdapterBoundary.commit) {
      return Failed<SaveReplacementEvidence, StructuredFailure>(
        owner._hostileFailure(),
      );
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<SaveReplacementEvidence, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    if (owner.fault == ReplacementFault.replacement) {
      return Failed<SaveReplacementEvidence, StructuredFailure>(
        _fakeFailure('replacement'),
      );
    }
    owner.beforeConditionalCommit?.call(owner);
    if (owner.reportedFingerprint != expectedFingerprint) {
      return Failed<SaveReplacementEvidence, StructuredFailure>(
        _fakeFailure('conflict'),
      );
    }
    owner
      ..generation = List<int>.unmodifiable(List<int>.of(staged))
      ..committed = true;
    owner.afterSuccessfulCommit?.call(owner);
    return Completed<SaveReplacementEvidence, StructuredFailure>(
      SaveReplacementEvidence(atomic: owner.atomic, durable: owner.durable),
    );
  }

  @override
  Future<OperationOutcome<void, StructuredFailure>> abort() async {
    owner._throwIf(SaveAdapterBoundary.abort);
    if (owner.failAt == SaveAdapterBoundary.abort) {
      owner.aborted = true;
      return Failed<void, StructuredFailure>(owner._hostileFailure());
    }
    staged.clear();
    owner.aborted = true;
    return const Completed<void, StructuredFailure>(null);
  }
}

StructuredFailure _fakeFailure(String dimension) => StructuredFailure(
  code: 'test.storage.$dimension',
  category: FailureCategory.platform,
  retryDisposition: RetryDisposition.never,
  message: 'A deterministic test adapter failure occurred.',
);
