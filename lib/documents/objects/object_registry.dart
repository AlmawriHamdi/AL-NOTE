// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/validation/validation_report.dart';
import '../../core/versioning/schema_version.dart';
import '../model/identity_remapping.dart';
import '../model/preserved_data.dart';
import '../resources/resources.dart';
import 'object_envelope.dart';

/// Immutable schema-transition metadata owned by an Object type.
///
/// This is metadata only. Storage-owned migration orchestration is deferred.
final class ObjectPayloadMigrationContract {
  /// Creates schema-transition metadata.
  const ObjectPayloadMigrationContract({
    required this.fromSchemaVersion,
    required this.toSchemaVersion,
  });

  /// The supported source payload schema.
  final SchemaVersion fromSchemaVersion;

  /// The supported destination payload schema.
  final SchemaVersion toSchemaVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectPayloadMigrationContract &&
          other.fromSchemaVersion == fromSchemaVersion &&
          other.toSchemaVersion == toSchemaVersion;

  @override
  int get hashCode => Object.hash(fromSchemaVersion, toSchemaVersion);

  @override
  String toString() => 'ObjectPayloadMigrationContract';
}

/// Immutable non-rendering capability information for one Object type.
final class ObjectTypeCapabilities {
  /// Creates immutable capability information.
  const ObjectTypeCapabilities({
    required this.hasIntrinsicGeometry,
    required this.discoversResourceReferences,
    required this.supportsScopedDuplication,
  });

  /// Whether the definition supplies intrinsic local geometry.
  final bool hasIntrinsicGeometry;

  /// Whether the definition may declare logical resource references.
  final bool discoversResourceReferences;

  /// Whether the definition supports interpreted scoped duplication.
  final bool supportsScopedDuplication;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectTypeCapabilities &&
          other.hasIntrinsicGeometry == hasIntrinsicGeometry &&
          other.discoversResourceReferences == discoversResourceReferences &&
          other.supportsScopedDuplication == supportsScopedDuplication;

  @override
  int get hashCode => Object.hash(
    hasIntrinsicGeometry,
    discoversResourceReferences,
    supportsScopedDuplication,
  );

  @override
  String toString() => 'ObjectTypeCapabilities';
}

/// AL NOTE-owned behavior contract for one known Object type.
///
/// Implementations must be immutable and must not render, hit test, perform
/// platform work, or publish document mutations.
abstract interface class ObjectTypeDefinition {
  /// The permanent Object type key.
  ObjectTypeKey get typeKey;

  /// The supported positive payload schema versions.
  List<SchemaVersion> get supportedSchemaVersions;

  /// Immutable non-rendering capability information.
  ObjectTypeCapabilities get capabilities;

  /// Immutable migration metadata, without migration orchestration.
  List<ObjectPayloadMigrationContract> get migrations;

  /// Validates one preserved payload without exposing its content.
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  );

  /// Derives the authoritative intrinsic local geometry.
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  );

  /// Discovers declared logical resource references.
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  );

  /// Safely duplicates and remaps a known payload.
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  );
}

/// The closed result family for Object Registry resolution.
sealed class ObjectResolution {
  const ObjectResolution({required this.envelope});

  /// The exactly preserved source envelope.
  final ObjectEnvelope envelope;
}

/// A supported known Object with a valid payload.
final class SupportedObjectResolution extends ObjectResolution {
  /// Creates a supported resolution.
  const SupportedObjectResolution({
    required super.envelope,
    required this.definition,
    required this.report,
  });

  /// The resolved immutable definition.
  final ObjectTypeDefinition definition;

  /// Deterministic payload warnings, if any.
  final ValidationReport report;
}

/// An Object whose type key is not registered.
final class UnknownObjectTypeResolution extends ObjectResolution {
  /// Creates an unknown-type resolution that preserves [envelope].
  const UnknownObjectTypeResolution(ObjectEnvelope envelope)
    : super(envelope: envelope);
}

/// A known Object type whose declared payload schema is unsupported.
final class UnsupportedObjectSchemaResolution extends ObjectResolution {
  /// Creates an unsupported-schema resolution that preserves [envelope].
  const UnsupportedObjectSchemaResolution(ObjectEnvelope envelope)
    : super(envelope: envelope);
}

/// A known supported Object whose payload is invalid.
final class InvalidObjectPayloadResolution extends ObjectResolution {
  /// Creates an invalid-payload resolution.
  const InvalidObjectPayloadResolution({
    required super.envelope,
    required this.report,
  });

  /// The deterministic redaction-safe invalid report.
  final ValidationReport report;
}

/// A known Object whose required registered behavior failed unexpectedly.
final class UnavailableObjectBehaviorResolution extends ObjectResolution {
  /// Creates unavailable-behavior evidence while preserving [envelope].
  const UnavailableObjectBehaviorResolution(ObjectEnvelope envelope)
    : super(envelope: envelope);
}

/// An immutable nonglobal registry of AL NOTE-owned Object definitions.
final class ObjectRegistry {
  ObjectRegistry._(this.definitions);

  /// Creates a registry after defensively copying and rejecting duplicate keys.
  static Result<ObjectRegistry, StructuredFailure> create(
    Iterable<ObjectTypeDefinition> definitions,
  ) {
    final copied = List<ObjectTypeDefinition>.of(definitions)
      ..sort((left, right) => left.typeKey.compareTo(right.typeKey));
    final byKey = <ObjectTypeKey, ObjectTypeDefinition>{};
    for (final definition in copied) {
      if (byKey.containsKey(definition.typeKey)) {
        return Err<ObjectRegistry, StructuredFailure>(
          StructuredFailure(
            code: 'documents.objects.duplicate_type_key',
            category: FailureCategory.validation,
            retryDisposition: RetryDisposition.never,
            message: 'An Object Registry contains a duplicate type key.',
          ),
        );
      }
      byKey[definition.typeKey] = definition;
    }
    return Ok<ObjectRegistry, StructuredFailure>(
      ObjectRegistry._(
        Map<ObjectTypeKey, ObjectTypeDefinition>.unmodifiable(byKey),
      ),
    );
  }

  /// Definitions in deterministic key order.
  final Map<ObjectTypeKey, ObjectTypeDefinition> definitions;

  /// Resolves [envelope] without modifying or converting it.
  ObjectResolution resolve(ObjectEnvelope envelope) {
    final definition = definitions[envelope.typeKey];
    if (definition == null) {
      return UnknownObjectTypeResolution(envelope);
    }
    final supported = List<SchemaVersion>.of(
      definition.supportedSchemaVersions,
    ).contains(envelope.typeSchemaVersion);
    if (!supported) {
      return UnsupportedObjectSchemaResolution(envelope);
    }
    try {
      final report = definition.validatePayload(
        envelope.payload,
        envelope.typeSchemaVersion,
      );
      if (!report.isValid) {
        return InvalidObjectPayloadResolution(
          envelope: envelope,
          report: report,
        );
      }
      return SupportedObjectResolution(
        envelope: envelope,
        definition: definition,
        report: report,
      );
    } on Object {
      return UnavailableObjectBehaviorResolution(envelope);
    }
  }

  @override
  String toString() => 'ObjectRegistry(length: ${definitions.length})';
}
