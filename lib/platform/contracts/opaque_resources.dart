// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/time/clock.dart';

/// A normalized adapter-supplied source identity. It is not a path.
final class NormalizedSourceIdentity {
  const NormalizedSourceIdentity._(this._value);

  /// Creates a bounded opaque source identity supplied by a trusted adapter.
  static Result<NormalizedSourceIdentity, StructuredFailure> create(
    String value,
  ) {
    if (value.isEmpty || value.length > 512) {
      return Err(_failure('invalid_source_identity'));
    }
    return Ok(NormalizedSourceIdentity._(value));
  }

  final String _value;

  @override
  bool operator ==(Object other) =>
      other is NormalizedSourceIdentity && other._value == _value;
  @override
  int get hashCode => _value.hashCode;
  @override
  String toString() => 'NormalizedSourceIdentity(redacted)';
}

/// Strength of structured external-source fingerprint evidence.
enum FingerprintStrength { weak, metadata, selectedContent, fullContent }

/// Immutable structured evidence that an external source has one state.
final class ExternalFingerprint {
  ExternalFingerprint._({
    required this.strength,
    required int byteLength,
    required Iterable<int> digest,
  }) : byteLength = byteLength,
       digest = List<int>.unmodifiable(digest);

  static Result<ExternalFingerprint, StructuredFailure> create({
    required FingerprintStrength strength,
    required int byteLength,
    required Iterable<int> digest,
  }) {
    try {
      final bytes = List<int>.of(digest);
      if (byteLength < 0 ||
          byteLength > 9007199254740991 ||
          bytes.isEmpty ||
          bytes.length > 64 ||
          bytes.any((value) => value < 0 || value > 255)) {
        return Err(_failure('invalid_fingerprint'));
      }
      return Ok(
        ExternalFingerprint._(
          strength: strength,
          byteLength: byteLength,
          digest: bytes,
        ),
      );
    } on Object {
      return Err(_failure('invalid_fingerprint'));
    }
  }

  final FingerprintStrength strength;
  final int byteLength;
  final List<int> digest;

  @override
  bool operator ==(Object other) =>
      other is ExternalFingerprint &&
      other.strength == strength &&
      other.byteLength == byteLength &&
      _bytesEqual(other.digest, digest);
  @override
  int get hashCode => Object.hash(strength, byteLength, Object.hashAll(digest));
  @override
  String toString() =>
      'ExternalFingerprint(strength: ${strength.name}, bytes: $byteLength)';
}

/// Kinds of opaque platform token. Kinds are intentionally non-interchangeable.
enum OpaqueTokenKind {
  resource,
  destination,
  authorization,
  temporaryResource,
  secretReference,
}

abstract base class _TokenBinding {
  const _TokenBinding(this.value);
  final String value;
  static bool valid(String value) =>
      RegExp(r'^[a-z][a-z0-9._-]{0,127}$').hasMatch(value);
  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is _TokenBinding &&
      other.value == value;
  @override
  int get hashCode => Object.hash(runtimeType, value);
  @override
  String toString() => '$runtimeType(redacted)';
}

/// Validated subsystem identity that owns an opaque token.
final class OpaqueTokenOwner extends _TokenBinding {
  const OpaqueTokenOwner._(super.value);
  static Result<OpaqueTokenOwner, StructuredFailure> parse(String value) =>
      _TokenBinding.valid(value)
      ? Ok(OpaqueTokenOwner._(value))
      : Err(_failure('invalid_owner'));
}

/// Validated operation identity authorized by an opaque token.
final class OpaqueTokenOperation extends _TokenBinding {
  const OpaqueTokenOperation._(super.value);
  static Result<OpaqueTokenOperation, StructuredFailure> parse(String value) =>
      _TokenBinding.valid(value)
      ? Ok(OpaqueTokenOperation._(value))
      : Err(_failure('invalid_operation'));
}

/// Validated resource scope bound to an opaque token.
final class OpaqueTokenScope extends _TokenBinding {
  const OpaqueTokenScope._(super.value);
  static Result<OpaqueTokenScope, StructuredFailure> parse(String value) =>
      _TokenBinding.valid(value)
      ? Ok(OpaqueTokenScope._(value))
      : Err(_failure('invalid_scope'));
}

/// Base for owner-, operation-, scope-, expiry-, and revocation-bound tokens.
sealed class OpaquePlatformToken {
  const OpaquePlatformToken._({
    required this.kind,
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
    required DateTime? expiresAtUtc,
    required int revocationGeneration,
    required UuidIdentifier nonce,
    required Object authority,
  }) : _owner = owner,
       _operation = operation,
       _scope = scope,
       _expiresAtUtc = expiresAtUtc,
       _revocationGeneration = revocationGeneration,
       _nonce = nonce,
       _authority = authority;

  final OpaqueTokenKind kind;
  final OpaqueTokenOwner _owner;
  final OpaqueTokenOperation _operation;
  final OpaqueTokenScope _scope;
  final DateTime? _expiresAtUtc;
  final int _revocationGeneration;
  final UuidIdentifier _nonce;
  final Object _authority;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is OpaquePlatformToken &&
      other._nonce == _nonce;
  @override
  int get hashCode => Object.hash(runtimeType, _nonce);
  @override
  String toString() => '$runtimeType(redacted)';
}

/// Opaque authority-bound reference to an external resource.
final class ResourceToken extends OpaquePlatformToken {
  const ResourceToken._({
    required super.owner,
    required super.operation,
    required super.scope,
    required super.expiresAtUtc,
    required super.revocationGeneration,
    required super.nonce,
    required super.authority,
  }) : super._(kind: OpaqueTokenKind.resource);
}

/// Opaque authority-bound publication destination.
final class DestinationToken extends OpaquePlatformToken {
  const DestinationToken._({
    required super.owner,
    required super.operation,
    required super.scope,
    required super.expiresAtUtc,
    required super.revocationGeneration,
    required super.nonce,
    required super.authority,
  }) : super._(kind: OpaqueTokenKind.destination);
}

/// Expiring opaque authorization for one operation and scope.
final class AuthorizationToken extends OpaquePlatformToken {
  const AuthorizationToken._({
    required super.owner,
    required super.operation,
    required super.scope,
    required super.expiresAtUtc,
    required super.revocationGeneration,
    required super.nonce,
    required super.authority,
  }) : super._(kind: OpaqueTokenKind.authorization);
}

/// Expiring opaque reference to temporary adapter-owned content.
final class TemporaryResourceToken extends OpaquePlatformToken {
  const TemporaryResourceToken._({
    required super.owner,
    required super.operation,
    required super.scope,
    required super.expiresAtUtc,
    required super.revocationGeneration,
    required super.nonce,
    required super.authority,
  }) : super._(kind: OpaqueTokenKind.temporaryResource);
}

/// A non-secret opaque reference. Ordinary Settings APIs never resolve it.
final class SecretReference extends OpaquePlatformToken {
  const SecretReference._({
    required super.owner,
    required super.operation,
    required super.scope,
    required super.expiresAtUtc,
    required super.revocationGeneration,
    required super.nonce,
    required super.authority,
  }) : super._(kind: OpaqueTokenKind.secretReference);
}

/// The only ordinary public minting boundary for opaque tokens.
abstract interface class OpaqueTokenCapabilityPolicy {
  Result<void, StructuredFailure> validate({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
  });
}

/// Instance-owned bounded issuer and validator for opaque platform tokens.
final class OpaqueTokenAuthority {
  OpaqueTokenAuthority._(
    this.uuidGenerator,
    this.clock,
    this.maximumLifetime,
    this.capabilityPolicy,
    this.maximumIssuedTokens,
    this.maximumConsumedTokens,
    this.maximumRevocationOwners,
  );
  static Result<OpaqueTokenAuthority, StructuredFailure> create({
    required UuidGenerator uuidGenerator,
    required Clock clock,
    required Duration maximumLifetime,
    required OpaqueTokenCapabilityPolicy capabilityPolicy,
    required int maximumIssuedTokens,
    required int maximumConsumedTokens,
    required int maximumRevocationOwners,
  }) =>
      maximumLifetime > Duration.zero &&
          maximumIssuedTokens >= 0 &&
          maximumConsumedTokens >= 0 &&
          maximumRevocationOwners >= 0 &&
          maximumIssuedTokens <= 9007199254740991 &&
          maximumConsumedTokens <= 9007199254740991 &&
          maximumRevocationOwners <= 9007199254740991
      ? Ok(
          OpaqueTokenAuthority._(
            uuidGenerator,
            clock,
            maximumLifetime,
            capabilityPolicy,
            maximumIssuedTokens,
            maximumConsumedTokens,
            maximumRevocationOwners,
          ),
        )
      : Err(_failure('invalid_authority'));
  final UuidGenerator uuidGenerator;
  final Clock clock;
  final Duration maximumLifetime;
  final OpaqueTokenCapabilityPolicy capabilityPolicy;
  final int maximumIssuedTokens;
  final int maximumConsumedTokens;
  final int maximumRevocationOwners;
  final Map<OpaqueTokenOwner, int> _revocations = {};
  final Set<OpaquePlatformToken> _consumed = {};
  final Set<OpaquePlatformToken> _issued = {};
  final Set<UuidIdentifier> _issuedNonces = {};
  final Object _authorityIdentity = Object();
  bool _disposed = false;

  int _generation(OpaqueTokenOwner owner) => _revocations[owner] ?? 0;
  Result<void, StructuredFailure> revoke(OpaqueTokenOwner owner) {
    if (_disposed) return Err(_failure('disposed'));
    final current = _generation(owner);
    if (current == 0 &&
        !_revocations.containsKey(owner) &&
        _revocations.length >= maximumRevocationOwners) {
      return Err(_failure('revocation_owner_limit'));
    }
    if (current >= 9007199254740991)
      return Err(_failure('revocation_overflow'));
    _revocations[owner] = current + 1;
    return const Ok(null);
  }

  Result<bool, StructuredFailure> revalidate(
    OpaquePlatformToken token, {
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
    bool consume = false,
  }) {
    if (_disposed) return Err(_failure('disposed'));
    try {
      final capability = capabilityPolicy.validate(
        owner: owner,
        operation: operation,
        scope: scope,
      );
      if (capability is Err<void, StructuredFailure>) return const Ok(false);
      if (!identical(token._authority, _authorityIdentity) ||
          !_issued.contains(token) ||
          token._owner != owner ||
          token._operation != operation ||
          token._scope != scope ||
          token._revocationGeneration != _generation(owner) ||
          (token._expiresAtUtc != null &&
              !clock.nowUtc().isBefore(token._expiresAtUtc)) ||
          _consumed.contains(token))
        return const Ok(false);
      if (consume) {
        if (_consumed.length >= maximumConsumedTokens) {
          return Err(_failure('consumed_token_limit'));
        }
        _consumed.add(token);
      }
      return const Ok(true);
    } on Object {
      return Err(_failure('revalidation_failure'));
    }
  }

  Result<bool, StructuredFailure> _validExpiry(
    DateTime? expiry, {
    required bool required,
  }) {
    if (required && expiry == null) return const Ok(false);
    if (expiry == null) return const Ok(true);
    try {
      final now = clock.nowUtc();
      return Ok(
        expiry.isAfter(now) && !expiry.isAfter(now.add(maximumLifetime)),
      );
    } on Object {
      return Err(_failure('clock_failure'));
    }
  }

  Result<T, StructuredFailure> _mint<T extends OpaquePlatformToken>(
    T Function(UuidIdentifier nonce) build,
  ) {
    final preflight = _mintPreflight();
    if (preflight is Err<void, StructuredFailure>) return Err(preflight.error);
    try {
      final generated = uuidGenerator.generateV4();
      if (generated is Err<UuidIdentifier, StructuredFailure>) {
        return Err(generated.error);
      }
      final nonce = (generated as Ok<UuidIdentifier, StructuredFailure>).value;
      if (_issuedNonces.contains(nonce)) {
        return Err(_failure('token_identity_collision'));
      }
      final token = build(nonce);
      _issuedNonces.add(nonce);
      _issued.add(token);
      return Ok(token);
    } on Object {
      return Err(_failure('mint_failure'));
    }
  }

  Result<void, StructuredFailure> _mintPreflight() {
    if (_disposed) return Err(_failure('disposed'));
    if (_issued.length >= maximumIssuedTokens) {
      return Err(_failure('issued_token_limit'));
    }
    return const Ok(null);
  }

  Result<T, StructuredFailure> _mintChecked<T extends OpaquePlatformToken>({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
    required DateTime? expiry,
    required bool expiryRequired,
    required T Function(UuidIdentifier nonce) build,
  }) {
    final preflight = _mintPreflight();
    if (preflight is Err<void, StructuredFailure>) return Err(preflight.error);
    final allowed = _policyAllows(owner, operation, scope);
    if (allowed is Err<void, StructuredFailure>) return Err(allowed.error);
    final valid = _validExpiry(expiry, required: expiryRequired);
    if (valid is Err<bool, StructuredFailure>) return Err(valid.error);
    if (!(valid as Ok<bool, StructuredFailure>).value) {
      return Err(_failure('invalid_expiry'));
    }
    return _mint(build);
  }

  Result<void, StructuredFailure> _policyAllows(
    OpaqueTokenOwner owner,
    OpaqueTokenOperation operation,
    OpaqueTokenScope scope,
  ) {
    try {
      final result = capabilityPolicy.validate(
        owner: owner,
        operation: operation,
        scope: scope,
      );
      return result is Ok<void, StructuredFailure>
          ? const Ok(null)
          : Err(_failure('capability_denied'));
    } on Object {
      return Err(_failure('capability_policy_failure'));
    }
  }

  Result<ResourceToken, StructuredFailure> resource({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
    DateTime? expiresAtUtc,
  }) => _mintChecked(
    owner: owner,
    operation: operation,
    scope: scope,
    expiry: expiresAtUtc,
    expiryRequired: false,
    build: (nonce) => ResourceToken._(
      owner: owner,
      operation: operation,
      scope: scope,
      expiresAtUtc: expiresAtUtc?.toUtc(),
      revocationGeneration: _generation(owner),
      nonce: nonce,
      authority: _authorityIdentity,
    ),
  );
  Result<DestinationToken, StructuredFailure> destination({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
    DateTime? expiresAtUtc,
  }) => _mintChecked(
    owner: owner,
    operation: operation,
    scope: scope,
    expiry: expiresAtUtc,
    expiryRequired: false,
    build: (nonce) => DestinationToken._(
      owner: owner,
      operation: operation,
      scope: scope,
      expiresAtUtc: expiresAtUtc?.toUtc(),
      revocationGeneration: _generation(owner),
      nonce: nonce,
      authority: _authorityIdentity,
    ),
  );
  Result<AuthorizationToken, StructuredFailure> authorization({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
    DateTime? expiresAtUtc,
  }) => _mintChecked(
    owner: owner,
    operation: operation,
    scope: scope,
    expiry: expiresAtUtc,
    expiryRequired: true,
    build: (nonce) => AuthorizationToken._(
      owner: owner,
      operation: operation,
      scope: scope,
      expiresAtUtc: expiresAtUtc?.toUtc(),
      revocationGeneration: _generation(owner),
      nonce: nonce,
      authority: _authorityIdentity,
    ),
  );
  Result<TemporaryResourceToken, StructuredFailure> temporaryResource({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation operation,
    required OpaqueTokenScope scope,
    required DateTime expiresAtUtc,
  }) => _mintChecked(
    owner: owner,
    operation: operation,
    scope: scope,
    expiry: expiresAtUtc,
    expiryRequired: true,
    build: (nonce) => TemporaryResourceToken._(
      owner: owner,
      operation: operation,
      scope: scope,
      expiresAtUtc: expiresAtUtc.toUtc(),
      revocationGeneration: _generation(owner),
      nonce: nonce,
      authority: _authorityIdentity,
    ),
  );
  Result<SecretReference, StructuredFailure> secretReference({
    required OpaqueTokenOwner owner,
    required OpaqueTokenOperation purpose,
    required OpaqueTokenScope scope,
  }) => _mintChecked(
    owner: owner,
    operation: purpose,
    scope: scope,
    expiry: null,
    expiryRequired: false,
    build: (nonce) => SecretReference._(
      owner: owner,
      operation: purpose,
      scope: scope,
      expiresAtUtc: null,
      revocationGeneration: _generation(owner),
      nonce: nonce,
      authority: _authorityIdentity,
    ),
  );

  Result<void, StructuredFailure> dispose() {
    if (_disposed) return const Ok(null);
    _disposed = true;
    _issued.clear();
    _issuedNonces.clear();
    _consumed.clear();
    _revocations.clear();
    return const Ok(null);
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'platform.tokens.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Opaque platform evidence is invalid.',
);
