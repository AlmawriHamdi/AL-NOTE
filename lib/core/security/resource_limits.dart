// SPDX-License-Identifier: GPL-3.0-or-later

import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';

/// A stable lowercase namespaced key identifying one resource ceiling.
final class ResourceLimitKey implements Comparable<ResourceLimitKey> {
  const ResourceLimitKey._(this.value);

  static final RegExp _pattern = RegExp(
    r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$',
  );

  /// Parses [source] as a resource-limit key.
  static Result<ResourceLimitKey, StructuredFailure> parse(String source) {
    if (source.length < 2 ||
        source.length > 255 ||
        !_pattern.hasMatch(source)) {
      return Err<ResourceLimitKey, StructuredFailure>(
        StructuredFailure(
          code: 'core.security.invalid_resource_limit_key',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'The resource-limit key is not valid.',
        ),
      );
    }
    return Ok<ResourceLimitKey, StructuredFailure>(ResourceLimitKey._(source));
  }

  /// The canonical resource-limit key.
  final String value;

  @override
  int compareTo(ResourceLimitKey other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceLimitKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The explicit unit associated with a resource ceiling.
enum ResourceLimitUnit {
  /// A number of bytes.
  bytes,

  /// A number of discrete items.
  count,

  /// A nesting or traversal depth.
  depth,

  /// An integer ratio.
  ratio,

  /// A duration measured in milliseconds.
  milliseconds,
}

/// An immutable nonnegative ceiling paired with its required unit.
final class ResourceLimitCeiling {
  const ResourceLimitCeiling._({required this.value, required this.unit});

  /// Creates a unit-bearing ceiling from an externally supplied [value].
  static Result<ResourceLimitCeiling, StructuredFailure> create({
    required int value,
    required ResourceLimitUnit unit,
  }) {
    if (value < 0) {
      return Err<ResourceLimitCeiling, StructuredFailure>(
        StructuredFailure(
          code: 'core.security.invalid_resource_limit_ceiling',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'A resource-limit ceiling must be nonnegative.',
        ),
      );
    }
    return Ok<ResourceLimitCeiling, StructuredFailure>(
      ResourceLimitCeiling._(value: value, unit: unit),
    );
  }

  /// The nonnegative ceiling value.
  final int value;

  /// The unit in which [value] is measured.
  final ResourceLimitUnit unit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceLimitCeiling &&
          other.value == value &&
          other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => '$value ${unit.name}';
}

/// An immutable snapshot of caller-supplied resource ceilings.
final class ResourceLimitSnapshot {
  ResourceLimitSnapshot._(Map<ResourceLimitKey, ResourceLimitCeiling> ceilings)
    : _ceilings = Map<ResourceLimitKey, ResourceLimitCeiling>.unmodifiable(
        ceilings,
      );

  final Map<ResourceLimitKey, ResourceLimitCeiling> _ceilings;

  /// Creates a snapshot from key/ceiling records.
  ///
  /// The input iterable is consumed immediately and copied. Duplicate keys are
  /// rejected instead of being collapsed.
  static Result<ResourceLimitSnapshot, StructuredFailure> create(
    Iterable<({ResourceLimitKey key, ResourceLimitCeiling ceiling})> limits,
  ) {
    final copiedLimits =
        List<({ResourceLimitKey key, ResourceLimitCeiling ceiling})>.of(limits);
    final ceilings = <ResourceLimitKey, ResourceLimitCeiling>{};
    for (final limit in copiedLimits) {
      if (ceilings.containsKey(limit.key)) {
        return Err<ResourceLimitSnapshot, StructuredFailure>(
          StructuredFailure(
            code: 'core.security.duplicate_resource_limit',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'A resource-limit key appears more than once.',
          ),
        );
      }
      ceilings[limit.key] = limit.ceiling;
    }
    return Ok<ResourceLimitSnapshot, StructuredFailure>(
      ResourceLimitSnapshot._(ceilings),
    );
  }

  /// An unmodifiable view of every ceiling in the snapshot.
  Map<ResourceLimitKey, ResourceLimitCeiling> get ceilings => _ceilings;

  /// Returns the ceiling for [key], or `null` when the key is not present.
  ResourceLimitCeiling? ceilingFor(ResourceLimitKey key) => _ceilings[key];

  /// Atomically applies only non-raising updates to existing keys.
  ///
  /// Update order does not affect the result. Duplicate keys are ambiguous and
  /// rejected. Every update is validated before a replacement snapshot is
  /// created, so any failure leaves this snapshot unchanged.
  Result<ResourceLimitSnapshot, StructuredFailure> tighten(
    Iterable<({ResourceLimitKey key, ResourceLimitCeiling ceiling})> updates,
  ) {
    final copiedUpdates =
        List<({ResourceLimitKey key, ResourceLimitCeiling ceiling})>.of(
          updates,
        );
    final updatedKeys = <ResourceLimitKey>{};

    for (final update in copiedUpdates) {
      if (!updatedKeys.add(update.key)) {
        return Err<ResourceLimitSnapshot, StructuredFailure>(
          StructuredFailure(
            code: 'core.security.ambiguous_resource_limit_update',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'A resource-limit update contains a duplicate key.',
          ),
        );
      }

      final current = _ceilings[update.key];
      if (current == null) {
        return Err<ResourceLimitSnapshot, StructuredFailure>(
          StructuredFailure(
            code: 'core.security.unknown_resource_limit',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'Only an existing resource-limit key may be tightened.',
          ),
        );
      }
      if (current.unit != update.ceiling.unit) {
        return Err<ResourceLimitSnapshot, StructuredFailure>(
          StructuredFailure(
            code: 'core.security.resource_limit_unit_mismatch',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'A resource-limit update must preserve its unit.',
          ),
        );
      }
      if (update.ceiling.value > current.value) {
        return Err<ResourceLimitSnapshot, StructuredFailure>(
          StructuredFailure(
            code: 'core.security.resource_limit_raise_rejected',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'A resource-limit ceiling cannot be raised.',
          ),
        );
      }
    }

    final tightened = Map<ResourceLimitKey, ResourceLimitCeiling>.of(_ceilings);
    for (final update in copiedUpdates) {
      tightened[update.key] = update.ceiling;
    }
    return Ok<ResourceLimitSnapshot, StructuredFailure>(
      ResourceLimitSnapshot._(tightened),
    );
  }
}
