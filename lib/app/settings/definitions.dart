// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/data_classification.dart';
import '../../core/security/resource_limits.dart';

/// Stable, validated identity for one Setting definition.
final class SettingKey implements Comparable<SettingKey> {
  const SettingKey._(this.value);
  static final RegExp _pattern = RegExp(
    r'^alnote\.settings\.[a-z][a-zA-Z0-9]*(?:\.[a-z][a-zA-Z0-9]*)*$',
  );
  static Result<SettingKey, StructuredFailure> parse(String value) =>
      value.length <= 192 && _pattern.hasMatch(value)
      ? Ok(SettingKey._(value))
      : Err(_failure('invalid_key'));
  final String value;
  @override
  int compareTo(SettingKey other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) => other is SettingKey && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// Closed storage or preview scope for a Setting value.
enum SettingScope { user, deviceLocal, temporaryPreview }

/// Boundary at which an accepted Setting becomes effective.
enum SettingApplicationTiming {
  immediate,
  nextInputSequence,
  nextOperation,
  nextToolActivationOrGesture,
  reopenView,
  applicationRestart,
}

/// Restart breadth required after a Setting change.
enum SettingRestartRequirement { none, view, application }

/// Lifecycle state of a registered Setting definition.
enum SettingDeprecationState { active, deprecated, removed }

/// Whether a Setting is eligible for future synchronization.
enum SettingSynchronizationEligibility { eligible, ineligible }

/// Type-specific bounded codec. Encoded bytes are copied by repositories.
abstract interface class SettingValueCodec<T> {
  String get identity;
  Result<List<int>, StructuredFailure> encode(
    T value, {
    required int maximumBytes,
  });
  Result<T, StructuredFailure> decode(
    List<int> bytes, {
    required int maximumBytes,
  });
}

/// Validates one typed Setting candidate without normalization.
typedef SettingValidator<T> = Result<void, StructuredFailure> Function(T value);

/// Canonicalizes one typed Setting candidate.
typedef SettingNormalizer<T> = Result<T, StructuredFailure> Function(T value);

/// Supplies a typed default without persistence.
typedef SettingDefaultProvider<T> = T Function();

/// Migrates one typed value between adjacent schemas.
typedef SettingMigration<T> = Result<T, StructuredFailure> Function(T value);

/// Applies mandatory security, accessibility, preservation, capability,
/// resource, and domain constraints to one typed candidate.
typedef MandatorySettingConstraints<T> =
    Result<T, StructuredFailure> Function(T value);

/// One typed, adjacent Setting schema migration.
final class SettingMigrationStep<T> {
  const SettingMigrationStep({
    required this.fromVersion,
    required this.toVersion,
    required this.handler,
  });
  final int fromVersion;
  final int toVersion;
  final SettingMigration<T> handler;
}

/// Potentially external metadata source read only during protected registration.
abstract interface class SettingDefinitionSource<T> {
  SettingKey get key;
  SettingValueCodec<T> get codec;
  int get schemaVersion;
  SettingDefaultProvider<T> get defaultProvider;
  Set<SettingScope> get permittedPersistentScopes;
  SettingValidator<T> get validator;
  SettingNormalizer<T> get normalizer;
  MandatorySettingConstraints<T> get mandatoryConstraints;
  DataClassification get dataClassification;
  SettingApplicationTiming get applicationTiming;
  bool get previewSupported;
  SettingSynchronizationEligibility get synchronizationEligibility;
  SettingRestartRequirement get restartRequirement;
  SettingDeprecationState get deprecationState;
  String get owningDomain;
  List<SettingMigrationStep<T>> get migrations;
  Map<String, int> get requiredResourceLimits;
}

/// Immutable metadata snapshot; hostile getters are never reread after capture.
final class RegisteredSettingDefinition<T> {
  RegisteredSettingDefinition._({
    required this.key,
    required this.codec,
    required this.schemaVersion,
    required this.defaultProvider,
    required Set<SettingScope> permittedPersistentScopes,
    required this.validator,
    required this.normalizer,
    required this.mandatoryConstraints,
    required this.dataClassification,
    required this.applicationTiming,
    required this.previewSupported,
    required this.synchronizationEligibility,
    required this.restartRequirement,
    required this.deprecationState,
    required this.owningDomain,
    required List<SettingMigrationStep<T>> migrations,
    required Map<String, int> requiredResourceLimits,
  }) : permittedPersistentScopes = UnmodifiableSetView(
         Set.of(permittedPersistentScopes),
       ),
       migrations = List.unmodifiable(migrations),
       requiredResourceLimits = UnmodifiableMapView(
         Map.of(requiredResourceLimits),
       );
  final SettingKey key;
  final SettingValueCodec<T> codec;
  final int schemaVersion;
  final SettingDefaultProvider<T> defaultProvider;
  final Set<SettingScope> permittedPersistentScopes;
  final SettingValidator<T> validator;
  final SettingNormalizer<T> normalizer;
  final MandatorySettingConstraints<T> mandatoryConstraints;
  final DataClassification dataClassification;
  final SettingApplicationTiming applicationTiming;
  final bool previewSupported;
  final SettingSynchronizationEligibility synchronizationEligibility;
  final SettingRestartRequirement restartRequirement;
  final SettingDeprecationState deprecationState;
  final String owningDomain;
  final List<SettingMigrationStep<T>> migrations;
  final Map<String, int> requiredResourceLimits;

  static Result<RegisteredSettingDefinition<T>, StructuredFailure> _capture<T>(
    SettingDefinitionSource<T> source,
  ) {
    try {
      final key = source.key;
      final codec = source.codec;
      final schemaVersion = source.schemaVersion;
      final defaultProvider = source.defaultProvider;
      final scopes = Set<SettingScope>.of(source.permittedPersistentScopes);
      final validator = source.validator;
      final normalizer = source.normalizer;
      final mandatoryConstraints = source.mandatoryConstraints;
      final classification = source.dataClassification;
      final timing = source.applicationTiming;
      final preview = source.previewSupported;
      final sync = source.synchronizationEligibility;
      final restart = source.restartRequirement;
      final deprecation = source.deprecationState;
      final owner = source.owningDomain;
      final migrations = List<SettingMigrationStep<T>>.of(source.migrations);
      final limits = Map<String, int>.of(source.requiredResourceLimits);
      if (schemaVersion <= 0 ||
          schemaVersion > 9007199254740991 ||
          codec.identity.isEmpty ||
          codec.identity.length > 128 ||
          owner.isEmpty ||
          owner.length > 96 ||
          scopes.contains(SettingScope.temporaryPreview) ||
          limits.values.any((v) => v < 0 || v > 9007199254740991))
        return Err(_failure('invalid_metadata'));
      final sorted = List<SettingMigrationStep<T>>.of(migrations)
        ..sort((a, b) => a.fromVersion.compareTo(b.fromVersion));
      for (var i = 0; i < sorted.length; i++) {
        final step = sorted[i];
        if (step.toVersion != step.fromVersion + 1 ||
            step.fromVersion <= 0 ||
            (i > 0 && sorted[i - 1].toVersion != step.fromVersion))
          return Err(_failure('invalid_migration_chain'));
      }
      return Ok(
        RegisteredSettingDefinition._(
          key: key,
          codec: codec,
          schemaVersion: schemaVersion,
          defaultProvider: defaultProvider,
          permittedPersistentScopes: scopes,
          validator: validator,
          normalizer: normalizer,
          mandatoryConstraints: mandatoryConstraints,
          dataClassification: classification,
          applicationTiming: timing,
          previewSupported: preview,
          synchronizationEligibility: sync,
          restartRequirement: restart,
          deprecationState: deprecation,
          owningDomain: owner,
          migrations: sorted,
          requiredResourceLimits: limits,
        ),
      );
    } on Object {
      return Err(_failure('metadata_failure'));
    }
  }

  Result<T, StructuredFailure> validated(T value) {
    try {
      final normalized = normalizer(value);
      if (normalized is Err<T, StructuredFailure>)
        return Err(_failure('normalization_failed'));
      final candidate = (normalized as Ok<T, StructuredFailure>).value;
      final valid = validator(candidate);
      if (valid is! Ok<void, StructuredFailure>) {
        return Err(_failure('validation_failed'));
      }
      final constrained = mandatoryConstraints(candidate);
      if (constrained is! Ok<T, StructuredFailure>) {
        return Err(_failure('constraint_failed'));
      }
      final finalValue = constrained.value;
      final postConstraint = validator(finalValue);
      return postConstraint is Ok<void, StructuredFailure>
          ? Ok(finalValue)
          : Err(_failure('constraint_failed'));
    } on Object {
      return Err(_failure('validation_failed'));
    }
  }

  Result<T, StructuredFailure> defaultValue() {
    try {
      return validated(defaultProvider());
    } on Object {
      return Err(_failure('default_failed'));
    }
  }

  /// Encodes one fully constrained typed value inside a protected boundary.
  Result<List<int>, StructuredFailure> encodeValue(
    T value, {
    required int maximumBytes,
  }) {
    if (maximumBytes < 0 || maximumBytes > 9007199254740991) {
      return Err(_failure('invalid_value_limit'));
    }
    final checked = validated(value);
    if (checked is Err<T, StructuredFailure>) return Err(checked.error);
    try {
      final encoded = codec.encode(
        (checked as Ok<T, StructuredFailure>).value,
        maximumBytes: maximumBytes,
      );
      if (encoded is Err<List<int>, StructuredFailure>) {
        return Err(_failure('encoding_failed'));
      }
      final bytes = List<int>.of(
        (encoded as Ok<List<int>, StructuredFailure>).value,
      );
      if (bytes.length > maximumBytes ||
          bytes.any((byte) => byte < 0 || byte > 255)) {
        return Err(_failure('encoding_failed'));
      }
      return Ok(List.unmodifiable(bytes));
    } on Object {
      return Err(_failure('encoding_failed'));
    }
  }

  /// Decodes and fully constrains one bounded stored value.
  Result<T, StructuredFailure> decodeValue(
    List<int> bytes, {
    required int maximumBytes,
  }) {
    if (maximumBytes < 0 ||
        bytes.length > maximumBytes ||
        bytes.any((byte) => byte < 0 || byte > 255)) {
      return Err(_failure('decoding_failed'));
    }
    try {
      final decoded = codec.decode(
        List.unmodifiable(List<int>.of(bytes)),
        maximumBytes: maximumBytes,
      );
      if (decoded is Err<T, StructuredFailure>) {
        return Err(_failure('decoding_failed'));
      }
      return validated((decoded as Ok<T, StructuredFailure>).value);
    } on Object {
      return Err(_failure('decoding_failed'));
    }
  }

  /// Applies the exact adjacent forward migration chain and post-validates.
  Result<T, StructuredFailure> migrateValue(T value, int fromVersion) {
    if (fromVersion <= 0 || fromVersion > schemaVersion) {
      return Err(_failure('invalid_migration_version'));
    }
    var current = value;
    var version = fromVersion;
    try {
      while (version < schemaVersion) {
        final step = migrations
            .where((candidate) => candidate.fromVersion == version)
            .firstOrNull;
        if (step == null) return Err(_failure('missing_migration'));
        final migrated = step.handler(current);
        if (migrated is Err<T, StructuredFailure>) {
          return Err(_failure('migration_failed'));
        }
        current = (migrated as Ok<T, StructuredFailure>).value;
        version = step.toVersion;
      }
      return validated(current);
    } on Object {
      return Err(_failure('migration_failed'));
    }
  }
}

/// Instance-owned registry that preserves typed definition handles.
final class SettingRegistry {
  final Map<SettingKey, RegisteredSettingDefinition<Object?>> _definitions = {};

  /// Number of immutable registered definitions.
  int get length => _definitions.length;

  /// Immutable non-erasing view of registered keys.
  Set<SettingKey> get keys => Set.unmodifiable(_definitions.keys);
  Result<void, StructuredFailure> register<T>(
    SettingDefinitionSource<T> source,
  ) {
    final captured = RegisteredSettingDefinition._capture(source);
    if (captured is Err<RegisteredSettingDefinition<T>, StructuredFailure>)
      return Err(captured.error);
    final value =
        (captured as Ok<RegisteredSettingDefinition<T>, StructuredFailure>)
            .value;
    if (_definitions.containsKey(value.key))
      return Err(_failure('duplicate_key'));
    _definitions[value.key] = value as RegisteredSettingDefinition<Object?>;
    return const Ok(null);
  }

  RegisteredSettingDefinition<T>? definition<T>(SettingKey key) {
    final value = _definitions[key];
    return value is RegisteredSettingDefinition<T> ? value : null;
  }

  /// Returns whether [definition] is the exact handle issued by this registry.
  bool owns<T>(RegisteredSettingDefinition<T> definition) =>
      identical(_definitions[definition.key], definition);

  /// Invokes [visitor] with the typed registered handle for [key].
  R visit<R>(SettingKey key, SettingDefinitionVisitor<R> visitor, R missing) {
    final definition = _definitions[key];
    if (definition == null) return missing;
    return visitor.visit(definition);
  }
}

/// Type-preserving visitor used to keep registry erasure private.
abstract interface class SettingDefinitionVisitor<R> {
  /// Visits one exact registry-issued typed definition handle.
  R visit<T>(RegisteredSettingDefinition<T> definition);
}

final Map<String, ResourceLimitUnit> alnoteSettingsLimitRequirements =
    UnmodifiableMapView({
      'alnote.settings.record_count': ResourceLimitUnit.count,
      'alnote.settings.key_length': ResourceLimitUnit.count,
      'alnote.settings.value_bytes': ResourceLimitUnit.bytes,
      'alnote.settings.nested_depth': ResourceLimitUnit.depth,
      'alnote.settings.migration_steps': ResourceLimitUnit.count,
      'alnote.settings.preview_overrides': ResourceLimitUnit.count,
      'alnote.settings.change_event_batch': ResourceLimitUnit.count,
    });

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'app.settings.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'The Setting definition or value is invalid.',
);
