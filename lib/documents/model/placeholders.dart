// SPDX-License-Identifier: GPL-3.0-or-later

import '../layers/document_layer.dart';
import '../objects/object_envelope.dart';
import 'identifiers.dart';

/// A closed redaction-safe reason for inert model-level placeholder evidence.
enum PlaceholderReason {
  /// No behavior is registered for an Object type.
  unknownObjectType,

  /// A known Object type does not support the declared schema.
  unsupportedObjectSchema,

  /// No built-in behavior is available for a Layer type.
  unknownLayerType,

  /// A logical resource reference is not available.
  missingResource,

  /// A required registered operation could not be supplied.
  unavailableRequiredBehavior,
}

/// Redaction-safe non-UI evidence for preserved unavailable content.
sealed class PlaceholderDescriptor {
  const PlaceholderDescriptor({required this.reason});

  /// The stable closed reason.
  final PlaceholderReason reason;
}

/// Placeholder evidence concerning one Object.
final class ObjectPlaceholderDescriptor extends PlaceholderDescriptor {
  /// Creates safe Object placeholder evidence.
  const ObjectPlaceholderDescriptor({
    required super.reason,
    required this.objectId,
    required this.typeKey,
  });

  /// The affected Object identity.
  final ObjectId objectId;

  /// The affected permanent Object type key.
  final ObjectTypeKey typeKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectPlaceholderDescriptor &&
          other.reason == reason &&
          other.objectId == objectId &&
          other.typeKey == typeKey;

  @override
  int get hashCode => Object.hash(reason, objectId, typeKey);

  @override
  String toString() =>
      'ObjectPlaceholderDescriptor(${reason.name}, $objectId, $typeKey)';
}

/// Placeholder evidence concerning one Layer.
final class LayerPlaceholderDescriptor extends PlaceholderDescriptor {
  /// Creates safe Layer placeholder evidence.
  const LayerPlaceholderDescriptor({
    required super.reason,
    required this.layerId,
    required this.typeKey,
  });

  /// The affected Layer identity.
  final LayerId layerId;

  /// The affected permanent Layer type key.
  final LayerTypeKey typeKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayerPlaceholderDescriptor &&
          other.reason == reason &&
          other.layerId == layerId &&
          other.typeKey == typeKey;

  @override
  int get hashCode => Object.hash(reason, layerId, typeKey);

  @override
  String toString() =>
      'LayerPlaceholderDescriptor(${reason.name}, $layerId, $typeKey)';
}

/// Placeholder evidence concerning one missing logical resource.
final class ResourcePlaceholderDescriptor extends PlaceholderDescriptor {
  /// Creates safe resource placeholder evidence.
  const ResourcePlaceholderDescriptor({
    required super.reason,
    required this.resourceIdentity,
  });

  /// The unavailable logical resource identity.
  final ResourceIdentity resourceIdentity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourcePlaceholderDescriptor &&
          other.reason == reason &&
          other.resourceIdentity == resourceIdentity;

  @override
  int get hashCode => Object.hash(reason, resourceIdentity);

  @override
  String toString() =>
      'ResourcePlaceholderDescriptor(${reason.name}, $resourceIdentity)';
}
