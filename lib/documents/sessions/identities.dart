// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';

abstract base class _RuntimeIdentity {
  const _RuntimeIdentity(this.uuid);
  final UuidIdentifier uuid;
  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is _RuntimeIdentity &&
      other.uuid == uuid;
  @override
  int get hashCode => Object.hash(runtimeType, uuid);
}

/// Runtime-only logical document Session identity; never document identity.
final class SessionId extends _RuntimeIdentity {
  const SessionId.fromUuid(super.uuid);
  static Result<SessionId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(SessionId.fromUuid);
  @override
  String toString() => 'SessionId(${uuid.value})';
}

/// Runtime-only view identity.
final class ViewId extends _RuntimeIdentity {
  const ViewId.fromUuid(super.uuid);
  static Result<ViewId, StructuredFailure> generate(UuidGenerator generator) =>
      generator.generateV4().map(ViewId.fromUuid);
  @override
  String toString() => 'ViewId(${uuid.value})';
}

/// Durable workspace-restoration identity, distinct from [SessionId].
final class RestorationEntryId extends _RuntimeIdentity {
  const RestorationEntryId.fromUuid(super.uuid);
  static Result<RestorationEntryId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(RestorationEntryId.fromUuid);
  @override
  String toString() => 'RestorationEntryId(${uuid.value})';
}

/// Session operation identity.
final class SessionOperationId extends _RuntimeIdentity {
  const SessionOperationId.fromUuid(super.uuid);
  static Result<SessionOperationId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(SessionOperationId.fromUuid);
  @override
  String toString() => 'SessionOperationId(${uuid.value})';
}
