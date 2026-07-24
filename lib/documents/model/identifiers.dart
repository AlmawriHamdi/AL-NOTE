// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';

/// A document-unique immutable document identity.
final class DocumentId {
  /// Creates an identity from an already validated AL NOTE UUID.
  const DocumentId.fromUuid(this.uuid);

  /// Generates an identity through the injected AL NOTE [generator].
  static Result<DocumentId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(DocumentId.fromUuid);

  /// The wrapped AL NOTE UUID value.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DocumentId && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(DocumentId, uuid);

  @override
  String toString() => 'DocumentId(${uuid.value})';
}

/// A document-unique immutable Section identity.
final class SectionId {
  /// Creates an identity from an already validated AL NOTE UUID.
  const SectionId.fromUuid(this.uuid);

  /// Generates an identity through the injected AL NOTE [generator].
  static Result<SectionId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(SectionId.fromUuid);

  /// The wrapped AL NOTE UUID value.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SectionId && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(SectionId, uuid);

  @override
  String toString() => 'SectionId(${uuid.value})';
}

/// A document-unique immutable Page identity.
final class PageId {
  /// Creates an identity from an already validated AL NOTE UUID.
  const PageId.fromUuid(this.uuid);

  /// Generates an identity through the injected AL NOTE [generator].
  static Result<PageId, StructuredFailure> generate(UuidGenerator generator) =>
      generator.generateV4().map(PageId.fromUuid);

  /// The wrapped AL NOTE UUID value.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PageId && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(PageId, uuid);

  @override
  String toString() => 'PageId(${uuid.value})';
}

/// A document-unique immutable Layer identity.
final class LayerId {
  /// Creates an identity from an already validated AL NOTE UUID.
  const LayerId.fromUuid(this.uuid);

  /// Generates an identity through the injected AL NOTE [generator].
  static Result<LayerId, StructuredFailure> generate(UuidGenerator generator) =>
      generator.generateV4().map(LayerId.fromUuid);

  /// The wrapped AL NOTE UUID value.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LayerId && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(LayerId, uuid);

  @override
  String toString() => 'LayerId(${uuid.value})';
}

/// A document-unique immutable Object identity.
final class ObjectId {
  /// Creates an identity from an already validated AL NOTE UUID.
  const ObjectId.fromUuid(this.uuid);

  /// Generates an identity through the injected AL NOTE [generator].
  static Result<ObjectId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(ObjectId.fromUuid);

  /// The wrapped AL NOTE UUID value.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ObjectId && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(ObjectId, uuid);

  @override
  String toString() => 'ObjectId(${uuid.value})';
}

/// A document-scoped immutable logical resource identity.
final class ResourceIdentity {
  /// Creates an identity from an already validated AL NOTE UUID.
  const ResourceIdentity.fromUuid(this.uuid);

  /// Generates an identity through the injected AL NOTE [generator].
  static Result<ResourceIdentity, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(ResourceIdentity.fromUuid);

  /// The wrapped AL NOTE UUID value.
  final UuidIdentifier uuid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ResourceIdentity && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(ResourceIdentity, uuid);

  @override
  String toString() => 'ResourceIdentity(${uuid.value})';
}
