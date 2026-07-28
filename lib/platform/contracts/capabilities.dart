// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';

/// Stable `alnote.platform.*` capability identity.
final class CapabilityKey implements Comparable<CapabilityKey> {
  const CapabilityKey._(this.value);
  static final RegExp _pattern = RegExp(
    r'^alnote\.platform\.[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
  );
  static Result<CapabilityKey, StructuredFailure> parse(String value) =>
      value.length <= 160 && _pattern.hasMatch(value)
      ? Ok(CapabilityKey._(value))
      : Err(_capabilityFailure('invalid_key'));
  final String value;
  @override
  int compareTo(CapabilityKey other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) =>
      other is CapabilityKey && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// A positive major/minor portable capability contract version.
final class CapabilityContractVersion {
  const CapabilityContractVersion._(this.major, this.minor);
  static Result<CapabilityContractVersion, StructuredFailure> create({
    required int major,
    required int minor,
  }) =>
      major > 0 &&
          minor >= 0 &&
          major <= 9007199254740991 &&
          minor <= 9007199254740991
      ? Ok(CapabilityContractVersion._(major, minor))
      : Err(_capabilityFailure('invalid_contract_version'));
  final int major;
  final int minor;
}

/// Closed availability states for a platform capability.
enum CapabilityAvailability {
  supported,
  supportedWithDegradation,
  temporarilyUnavailable,
  permissionRequired,
  permissionDenied,
  permissionRevoked,
  initializationFailed,
  unsupported,
}

/// Current health of a capability adapter.
enum CapabilityHealth { healthy, degraded, unhealthy, unknown }

/// Declared degradation of a supported capability.
enum CapabilityDegradation {
  none,
  reducedGuarantees,
  reducedPerformance,
  partial,
}

/// Permission evidence associated with a capability.
enum CapabilityPermission {
  notApplicable,
  unknown,
  granted,
  required,
  denied,
  revoked,
}

/// Redaction-safe adapter identity and version evidence.
final class AdapterEvidence {
  const AdapterEvidence._({required this.identity, required this.version});
  static final RegExp _safe = RegExp(r'^[a-zA-Z0-9._-]{1,96}$');
  static Result<AdapterEvidence, StructuredFailure> create({
    required String identity,
    required String version,
  }) => _safe.hasMatch(identity) && _safe.hasMatch(version)
      ? Ok(AdapterEvidence._(identity: identity, version: version))
      : Err(_capabilityFailure('invalid_adapter_evidence'));
  final String identity;
  final String version;
  @override
  bool operator ==(Object other) =>
      other is AdapterEvidence &&
      other.identity == identity &&
      other.version == version;
  @override
  int get hashCode => Object.hash(identity, version);
  @override
  String toString() => 'AdapterEvidence($identity, $version)';
}

/// Immutable initialization evidence without raw adapter diagnostics.
final class CapabilityInitializationEvidence {
  const CapabilityInitializationEvidence({
    required this.attempted,
    required this.completed,
    this.failureCode,
  });
  final bool attempted;
  final bool completed;
  final String? failureCode;
}

/// Complete immutable evidence for one capability.
final class CapabilityEvidence {
  CapabilityEvidence._({
    required this.key,
    required this.contractVersion,
    required this.adapter,
    required this.availability,
    required this.health,
    required this.degradation,
    required this.permission,
    required Map<String, int> limits,
    required this.initialization,
  }) : limits = UnmodifiableMapView(Map<String, int>.of(limits));
  final CapabilityKey key;
  final CapabilityContractVersion contractVersion;
  final AdapterEvidence adapter;
  final CapabilityAvailability availability;
  final CapabilityHealth health;
  final CapabilityDegradation degradation;
  final CapabilityPermission permission;
  final Map<String, int> limits;
  final CapabilityInitializationEvidence initialization;

  static Result<CapabilityEvidence, StructuredFailure> create({
    required CapabilityKey key,
    required CapabilityContractVersion contractVersion,
    required AdapterEvidence adapter,
    required CapabilityAvailability availability,
    required CapabilityHealth health,
    required CapabilityDegradation degradation,
    required CapabilityPermission permission,
    required Map<String, int> limits,
    required CapabilityInitializationEvidence initialization,
  }) {
    try {
      final copied = Map<String, int>.of(limits);
      final safeCode =
          initialization.failureCode == null ||
          RegExp(
            r'^[a-z][a-z0-9._-]{0,127}$',
          ).hasMatch(initialization.failureCode!);
      final validInitialization =
          !initialization.completed || initialization.attempted;
      final validAvailability = switch (availability) {
        CapabilityAvailability.supported =>
          health == CapabilityHealth.healthy &&
              degradation == CapabilityDegradation.none &&
              (permission == CapabilityPermission.granted ||
                  permission == CapabilityPermission.notApplicable) &&
              initialization.completed,
        CapabilityAvailability.supportedWithDegradation =>
          degradation != CapabilityDegradation.none && initialization.completed,
        _ => true,
      };
      if (!safeCode ||
          !validInitialization ||
          !validAvailability ||
          copied.keys.any(
            (key) => !RegExp(r'^[a-z][a-z0-9._-]{0,127}$').hasMatch(key),
          ) ||
          copied.values.any((value) => value < 0 || value > 9007199254740991)) {
        return Err(_capabilityFailure('invalid_evidence'));
      }
      return Ok(
        CapabilityEvidence._(
          key: key,
          contractVersion: contractVersion,
          adapter: adapter,
          availability: availability,
          health: health,
          degradation: degradation,
          permission: permission,
          limits: copied,
          initialization: initialization,
        ),
      );
    } on Object {
      return Err(_capabilityFailure('invalid_evidence'));
    }
  }
}

/// A checked Web-safe registry generation.
final class RegistryGeneration implements Comparable<RegistryGeneration> {
  const RegistryGeneration._(this.value);
  static Result<RegistryGeneration, StructuredFailure> create(int value) =>
      value >= 0 && value <= 9007199254740991
      ? Ok(RegistryGeneration._(value))
      : Err(_capabilityFailure('invalid_generation'));
  final int value;
  Result<RegistryGeneration, StructuredFailure> increment() =>
      value == 9007199254740991
      ? Err(_capabilityFailure('generation_overflow'))
      : Ok(RegistryGeneration._(value + 1));
  @override
  int compareTo(RegistryGeneration other) => value.compareTo(other.value);
}

/// Complete immutable registry snapshot.
final class CapabilitySnapshot {
  CapabilitySnapshot({
    required this.generation,
    required Map<CapabilityKey, CapabilityEvidence> capabilities,
  }) : capabilities = UnmodifiableMapView(
         Map<CapabilityKey, CapabilityEvidence>.fromEntries(
           capabilities.entries.toList()
             ..sort((a, b) => a.key.compareTo(b.key)),
         ),
       );
  final RegistryGeneration generation;
  final Map<CapabilityKey, CapabilityEvidence> capabilities;
}

/// One post-publication complete snapshot event.
final class CapabilityRegistryChange {
  const CapabilityRegistryChange({
    required this.previousGeneration,
    required this.snapshot,
  });
  final RegistryGeneration previousGeneration;
  final CapabilitySnapshot snapshot;
}

/// Receives one complete post-publication capability snapshot.
typedef CapabilityRegistryListener =
    void Function(CapabilityRegistryChange change);

/// Releases one accepted adapter exactly once.
typedef CapabilityDisposer = Result<void, StructuredFailure> Function();

/// Typed protected adapter initialization and cleanup boundary.
abstract interface class CapabilityAdapter<T> {
  CapabilityKey get key;
  CapabilityContractVersion get contractVersion;
  AdapterEvidence get adapterEvidence;
  Future<Result<CapabilityEvidence, StructuredFailure>> initialize(
    CancellationToken cancellationToken,
  );
  Result<void, StructuredFailure> dispose();
}

/// Instance-owned capability registry with isolated initialization failures.
final class CapabilityRegistry {
  CapabilityRegistry._(this.maximumCapabilities)
    : _generation = const RegistryGeneration._(0);
  static Result<CapabilityRegistry, StructuredFailure> create({
    required int maximumCapabilities,
  }) => maximumCapabilities >= 0 && maximumCapabilities <= 9007199254740991
      ? Ok(CapabilityRegistry._(maximumCapabilities))
      : Err(_capabilityFailure('invalid_capability_limit'));
  final int maximumCapabilities;
  final Map<CapabilityKey, CapabilityEvidence> _capabilities = {};
  final Map<CapabilityKey, CapabilityDisposer> _disposers = {};
  final Set<CapabilityKey> _disposedAdapters = {};
  final List<CapabilityRegistryListener> _listeners = [];
  RegistryGeneration _generation;
  bool _disposed = false;
  CapabilitySnapshot get snapshot =>
      CapabilitySnapshot(generation: _generation, capabilities: _capabilities);

  /// Adds a listener once. Notifications use a listener snapshot; mutations
  /// affect later events, reentrant publication is permitted and queued by the
  /// call stack, and listener exceptions are contained.
  void addListener(CapabilityRegistryListener listener) {
    if (!_disposed && !_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(CapabilityRegistryListener listener) =>
      _listeners.remove(listener);

  Result<void, StructuredFailure> register(
    CapabilityEvidence evidence, {
    CapabilityDisposer? disposer,
  }) {
    if (_disposed) return Err(_capabilityFailure('disposed'));
    if (_capabilities.containsKey(evidence.key))
      return Err(_capabilityFailure('duplicate'));
    if (_capabilities.length >= maximumCapabilities)
      return Err(_capabilityFailure('capability_limit'));
    if (disposer != null) _disposers[evidence.key] = disposer;
    final result = _publish({..._capabilities, evidence.key: evidence});
    if (result is Err<void, StructuredFailure> && !_disposed) {
      _disposers.remove(evidence.key);
    }
    return result;
  }

  Future<Result<void, StructuredFailure>> initialize<T>({
    required CapabilityAdapter<T> adapter,
    required CapabilityContractVersion requiredVersion,
    required CancellationToken cancellationToken,
  }) async {
    if (_disposed) return Err(_capabilityFailure('disposed'));
    if (cancellationToken.isCancelled) {
      return Err(_capabilityFailure('initialization_cancelled'));
    }
    CapabilityKey key;
    CapabilityContractVersion providerVersion;
    AdapterEvidence adapterEvidence;
    Future<Result<CapabilityEvidence, StructuredFailure>> Function(
      CancellationToken,
    )
    initialize;
    CapabilityDisposer disposer;
    try {
      key = adapter.key;
      providerVersion = adapter.contractVersion;
      adapterEvidence = adapter.adapterEvidence;
      initialize = adapter.initialize;
      disposer = adapter.dispose;
    } on Object {
      return Err(_capabilityFailure('adapter_metadata_failure'));
    }
    if (_capabilities.containsKey(key)) {
      return Err(_capabilityFailure('duplicate'));
    }
    if (_capabilities.length >= maximumCapabilities) {
      return Err(_capabilityFailure('capability_limit'));
    }
    if (providerVersion.major != requiredVersion.major ||
        providerVersion.minor < requiredVersion.minor) {
      return Err(_capabilityFailure('contract_incompatible'));
    }
    Result<CapabilityEvidence, StructuredFailure> initialized;
    try {
      initialized = await initialize(cancellationToken);
    } on Object {
      initialized = Err(_capabilityFailure('initialization_failure'));
    }
    if (cancellationToken.isCancelled) {
      return _disposeRejectedAdapter(
        disposer,
        _capabilityFailure('initialization_cancelled'),
      );
    }
    CapabilityEvidence evidence;
    if (initialized is Ok<CapabilityEvidence, StructuredFailure>) {
      evidence = initialized.value;
      if (evidence.key != key ||
          evidence.contractVersion.major != providerVersion.major ||
          evidence.contractVersion.minor != providerVersion.minor ||
          evidence.adapter != adapterEvidence) {
        return _disposeRejectedAdapter(
          disposer,
          _capabilityFailure('initialization_evidence_mismatch'),
        );
      }
    } else {
      final failed = CapabilityEvidence.create(
        key: key,
        contractVersion: providerVersion,
        adapter: adapterEvidence,
        availability: CapabilityAvailability.initializationFailed,
        health: CapabilityHealth.unhealthy,
        degradation: CapabilityDegradation.none,
        permission: CapabilityPermission.unknown,
        limits: const {},
        initialization: const CapabilityInitializationEvidence(
          attempted: true,
          completed: false,
          failureCode: 'initialization_failed',
        ),
      );
      if (failed is Err<CapabilityEvidence, StructuredFailure>) {
        return _disposeRejectedAdapter(disposer, failed.error);
      }
      evidence = (failed as Ok<CapabilityEvidence, StructuredFailure>).value;
    }
    final registered = register(evidence, disposer: disposer);
    if (registered is Ok<void, StructuredFailure>) {
      return registered;
    }
    return _disposeRejectedAdapter(
      disposer,
      (registered as Err<void, StructuredFailure>).error,
    );
  }

  Result<void, StructuredFailure> _disposeRejectedAdapter(
    CapabilityDisposer disposer,
    StructuredFailure rejection,
  ) {
    try {
      if (disposer() is Err<void, StructuredFailure>) {
        return Err(_capabilityFailure('disposal_failed'));
      }
    } on Object {
      return Err(_capabilityFailure('disposal_failed'));
    }
    return Err(rejection);
  }

  Result<void, StructuredFailure> update(CapabilityEvidence evidence) {
    if (_disposed) return Err(_capabilityFailure('disposed'));
    if (!_capabilities.containsKey(evidence.key))
      return Err(_capabilityFailure('unknown'));
    return _publish({..._capabilities, evidence.key: evidence});
  }

  Result<void, StructuredFailure> _publish(
    Map<CapabilityKey, CapabilityEvidence> next,
  ) {
    final incremented = _generation.increment();
    if (incremented is Err<RegistryGeneration, StructuredFailure>)
      return Err(incremented.error);
    final previous = _generation;
    _generation =
        (incremented as Ok<RegistryGeneration, StructuredFailure>).value;
    _capabilities
      ..clear()
      ..addAll(next);
    final event = CapabilityRegistryChange(
      previousGeneration: previous,
      snapshot: snapshot,
    );
    for (final listener in List<CapabilityRegistryListener>.of(_listeners)) {
      if (_disposed) break;
      try {
        listener(event);
      } on Object {
        /* isolated */
      }
    }
    return const Ok(null);
  }

  /// Disposes registered cleanup exactly once and reports redacted failures.
  Result<void, StructuredFailure> dispose() {
    if (_disposed) return const Ok(null);
    _disposed = true;
    var failed = false;
    for (final entry in _disposers.entries) {
      if (!_disposedAdapters.add(entry.key)) continue;
      try {
        if (entry.value() is Err<void, StructuredFailure>) failed = true;
      } on Object {
        failed = true;
      }
    }
    _listeners.clear();
    _capabilities.clear();
    _disposers.clear();
    return failed ? Err(_capabilityFailure('disposal_failed')) : const Ok(null);
  }
}

/// Exact Phase 5 capability/private-storage requirements without defaults.
final Map<String, ResourceLimitUnit> alnotePlatformLimitRequirements =
    UnmodifiableMapView({
      'alnote.platform.capability_count': ResourceLimitUnit.count,
      'alnote.platform.token_count': ResourceLimitUnit.count,
      'alnote.platform.record_count': ResourceLimitUnit.count,
      'alnote.platform.record_bytes': ResourceLimitUnit.bytes,
      'alnote.platform.transaction_operations': ResourceLimitUnit.count,
      'alnote.platform.enumeration_results': ResourceLimitUnit.count,
      'alnote.platform.temporary_bytes': ResourceLimitUnit.bytes,
    });

StructuredFailure _capabilityFailure(String leaf) => StructuredFailure(
  code: 'platform.capabilities.$leaf',
  category: FailureCategory.state,
  retryDisposition: RetryDisposition.never,
  message: 'The capability registry operation was rejected.',
);
