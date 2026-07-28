// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import 'contracts.dart';
import 'package_codec.dart';
import 'package_reader.dart';

/// Captures exactly one immutable complete package snapshot for Save or Save As.
typedef AlnoteSnapshotCapture = AlnotePackageSnapshot Function();

/// Coordinates complete staged validation and conflict-safe replacement.
final class AlnoteSaveCoordinator {
  /// Creates a coordinator over AL NOTE-owned portable contracts.
  const AlnoteSaveCoordinator({
    required this.captureSnapshot,
    required this.codec,
    required this.reader,
  });

  /// Captures one immutable state exactly once per [save] call.
  final AlnoteSnapshotCapture captureSnapshot;

  /// The deterministic package codec.
  final AlnotePackageCodec codec;

  /// The independent staged-output reader/validator.
  final AlnotePackageReader reader;

  /// Saves by complete staged replacement without blind overwrite.
  Future<OperationOutcome<AlnoteSaveEvidence, StructuredFailure>> save({
    required PackageReplacementDestination destination,
    required PackageFingerprint? expectedFingerprint,
    required ResourceLimitSnapshot limits,
    required CancellationToken cancellationToken,
  }) async {
    if (cancellationToken.isCancelled) return _cancelled(cancellationToken);
    AlnotePackageSnapshot snapshot;
    try {
      snapshot = captureSnapshot();
    } on Object {
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('snapshot'),
      );
    }
    OperationOutcome<List<int>, StructuredFailure> encoded;
    try {
      encoded = codec.encodeOperation(
        snapshot,
        limits: limits,
        cancellationToken: cancellationToken,
      );
    } on Object {
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _saveFailure('encoding', 'The package could not be encoded.'),
      );
    }
    if (encoded is Failed<List<int>, StructuredFailure>) {
      return Failed<AlnoteSaveEvidence, StructuredFailure>(encoded.failure);
    }
    if (encoded is Cancelled<List<int>, StructuredFailure>) {
      return Cancelled<AlnoteSaveEvidence, StructuredFailure>(encoded.reason);
    }
    final bytes = (encoded as Completed<List<int>, StructuredFailure>).value;
    OperationOutcome<PackageStagingArea, StructuredFailure> stagingOutcome;
    try {
      stagingOutcome = await destination.beginStaging(
        maximumBytes: bytes.length,
        cancellationToken: cancellationToken,
      );
    } on Object {
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('begin_staging'),
      );
    }
    if (stagingOutcome is Failed<PackageStagingArea, StructuredFailure>) {
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('begin_staging'),
      );
    }
    if (stagingOutcome is Cancelled<PackageStagingArea, StructuredFailure>) {
      return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
        cancellationToken.isCancelled ? cancellationToken.reason : null,
      );
    }
    final staging =
        (stagingOutcome as Completed<PackageStagingArea, StructuredFailure>)
            .value;
    if (cancellationToken.isCancelled) {
      await _abortSafely(staging);
      return _cancelled(cancellationToken);
    }
    OperationOutcome<int, StructuredFailure> write;
    try {
      write = await staging.write(bytes, cancellationToken: cancellationToken);
    } on Object {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('write'),
      );
    }
    if (write is! Completed<int, StructuredFailure> ||
        write.value != bytes.length) {
      await _abortSafely(staging);
      if (write is Cancelled<int, StructuredFailure> ||
          cancellationToken.isCancelled) {
        return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
          write is Cancelled<int, StructuredFailure>
              ? (cancellationToken.isCancelled
                    ? cancellationToken.reason
                    : null)
              : cancellationToken.reason,
        );
      }
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        write is Failed<int, StructuredFailure>
            ? _adapterFailure('write')
            : _saveFailure(
                'short_write',
                'The staged destination accepted a short write.',
              ),
      );
    }
    var flushEvidence = const SaveDurabilityEvidence(
      flushed: false,
      durable: false,
    );
    bool supportsFlush;
    try {
      supportsFlush = staging.supportsFlush;
    } on Object {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('flush_support'),
      );
    }
    if (supportsFlush) {
      OperationOutcome<SaveDurabilityEvidence, StructuredFailure> flush;
      try {
        flush = await staging.flush(cancellationToken: cancellationToken);
      } on Object {
        await _abortSafely(staging);
        return Failed<AlnoteSaveEvidence, StructuredFailure>(
          _adapterFailure('flush'),
        );
      }
      if (flush is! Completed<SaveDurabilityEvidence, StructuredFailure>) {
        await _abortSafely(staging);
        if (flush is Cancelled<SaveDurabilityEvidence, StructuredFailure> ||
            cancellationToken.isCancelled) {
          return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
            flush is Cancelled<SaveDurabilityEvidence, StructuredFailure>
                ? (cancellationToken.isCancelled
                      ? cancellationToken.reason
                      : null)
                : cancellationToken.reason,
          );
        }
        return Failed<AlnoteSaveEvidence, StructuredFailure>(
          _adapterFailure('flush'),
        );
      }
      flushEvidence = flush.value;
      if (!flushEvidence.flushed) {
        await _abortSafely(staging);
        return Failed<AlnoteSaveEvidence, StructuredFailure>(
          _adapterFailure('flush'),
        );
      }
    }
    if (cancellationToken.isCancelled) {
      await _abortSafely(staging);
      return _cancelled(cancellationToken);
    }
    final storageLimits = AlnoteStorageLimits.fromSnapshot(
      limits,
    ).fold(onOk: (value) => value, onErr: (_) => null);
    if (storageLimits == null) {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _saveFailure('limits', 'Required save limits are unavailable.'),
      );
    }
    OperationOutcome<List<int>, StructuredFailure> readBack;
    try {
      readBack = await staging.readBack(
        maximumBytes: storageLimits['alnote.storage.package_bytes'],
        cancellationToken: cancellationToken,
      );
    } on Object {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('read_back'),
      );
    }
    if (readBack is! Completed<List<int>, StructuredFailure>) {
      await _abortSafely(staging);
      if (readBack is Cancelled<List<int>, StructuredFailure> ||
          cancellationToken.isCancelled) {
        return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
          readBack is Cancelled<List<int>, StructuredFailure>
              ? (cancellationToken.isCancelled
                    ? cancellationToken.reason
                    : null)
              : cancellationToken.reason,
        );
      }
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('read_back'),
      );
    }
    final copiedReadBack = _copyStagedBytes(
      readBack.value,
      storageLimits['alnote.storage.package_bytes'],
    );
    if (copiedReadBack == null || !_bytesEqual(copiedReadBack, bytes)) {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _saveFailure(
          'read_back_mismatch',
          'The staged output differs from the complete encoded package.',
        ),
      );
    }
    final opened = reader.openBytes(
      copiedReadBack,
      limits: limits,
      cancellationToken: cancellationToken,
    );
    if (opened is! Completed<OpenedAlnotePackage, StructuredFailure>) {
      await _abortSafely(staging);
      if (opened is Cancelled<OpenedAlnotePackage, StructuredFailure> ||
          cancellationToken.isCancelled) {
        return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
          opened is Cancelled<OpenedAlnotePackage, StructuredFailure>
              ? opened.reason
              : cancellationToken.reason,
        );
      }
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        (opened as Failed<OpenedAlnotePackage, StructuredFailure>).failure,
      );
    }
    final candidate = opened.value.materializeSnapshot(
      cancellationToken: cancellationToken,
    );
    if (candidate is! Completed<AlnotePackageSnapshot, StructuredFailure>) {
      await _abortSafely(staging);
      if (candidate is Cancelled<AlnotePackageSnapshot, StructuredFailure> ||
          cancellationToken.isCancelled) {
        return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
          candidate is Cancelled<AlnotePackageSnapshot, StructuredFailure>
              ? candidate.reason
              : cancellationToken.reason,
        );
      }
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        (candidate as Failed<AlnotePackageSnapshot, StructuredFailure>).failure,
      );
    }
    OperationOutcome<PackageFingerprint?, StructuredFailure> fingerprint;
    try {
      fingerprint = await destination.fingerprint(
        cancellationToken: cancellationToken,
      );
    } on Object {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('fingerprint'),
      );
    }
    if (fingerprint is! Completed<PackageFingerprint?, StructuredFailure>) {
      await _abortSafely(staging);
      if (fingerprint is Cancelled<PackageFingerprint?, StructuredFailure> ||
          cancellationToken.isCancelled) {
        return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
          fingerprint is Cancelled<PackageFingerprint?, StructuredFailure>
              ? (cancellationToken.isCancelled
                    ? cancellationToken.reason
                    : null)
              : cancellationToken.reason,
        );
      }
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('fingerprint'),
      );
    }
    if (fingerprint.value != expectedFingerprint) {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _saveFailure(
          'conflict',
          'The destination fingerprint changed before replacement.',
        ),
      );
    }
    if (cancellationToken.isCancelled) {
      await _abortSafely(staging);
      return _cancelled(cancellationToken);
    }
    OperationOutcome<SaveReplacementEvidence, StructuredFailure> commit;
    try {
      commit = await staging.commit(
        expectedFingerprint: expectedFingerprint,
        cancellationToken: cancellationToken,
      );
    } on Object {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('commit'),
      );
    }
    if (commit is Failed<SaveReplacementEvidence, StructuredFailure>) {
      await _abortSafely(staging);
      return Failed<AlnoteSaveEvidence, StructuredFailure>(
        _adapterFailure('commit'),
      );
    }
    if (commit is Cancelled<SaveReplacementEvidence, StructuredFailure>) {
      await _abortSafely(staging);
      return Cancelled<AlnoteSaveEvidence, StructuredFailure>(
        cancellationToken.isCancelled ? cancellationToken.reason : null,
      );
    }
    return Completed<AlnoteSaveEvidence, StructuredFailure>(
      AlnoteSaveEvidence(
        packageByteLength: bytes.length,
        replacement:
            (commit as Completed<SaveReplacementEvidence, StructuredFailure>)
                .value,
        flush: flushEvidence,
      ),
    );
  }
}

Cancelled<AlnoteSaveEvidence, StructuredFailure> _cancelled(
  CancellationToken token,
) => Cancelled<AlnoteSaveEvidence, StructuredFailure>(token.reason);

Future<bool> _abortSafely(PackageStagingArea staging) async {
  try {
    final outcome = await staging.abort();
    return outcome is Completed<void, StructuredFailure>;
  } on Object {
    return false;
  }
}

List<int>? _copyStagedBytes(List<int> source, int maximumBytes) {
  final copied = <int>[];
  try {
    for (final byte in source) {
      if (copied.length == maximumBytes || byte < 0 || byte > 255) return null;
      copied.add(byte);
    }
    return List<int>.unmodifiable(copied);
  } on Object {
    return null;
  }
}

StructuredFailure _adapterFailure(String boundary) => _saveFailure(
  boundary,
  'A destination adapter boundary did not complete safely.',
);

StructuredFailure _saveFailure(String dimension, String message) =>
    StructuredFailure(
      code: 'documents.save.$dimension',
      category: FailureCategory.state,
      retryDisposition: RetryDisposition.afterUserAction,
      message: message,
    );

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
