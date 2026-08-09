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
    this.selectable = false,
    this.movable = false,
    this.resizable = false,
    this.rotatable = false,
  });

  /// Whether the definition supplies intrinsic local geometry.
  final bool hasIntrinsicGeometry;

  /// Whether the definition may declare logical resource references.
  final bool discoversResourceReferences;

  /// Whether the definition supports interpreted scoped duplication.
  final bool supportsScopedDuplication;

  /// Whether supported valid Objects of this type may enter editable Selection.
  final bool selectable;

  /// Whether whole Objects of this type may be translated.
  final bool movable;

  /// Whether whole Objects of this type may be positively scaled.
  final bool resizable;

  /// Whether whole Objects of this type may be rotated.
  final bool rotatable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectTypeCapabilities &&
          other.hasIntrinsicGeometry == hasIntrinsicGeometry &&
          other.discoversResourceReferences == discoversResourceReferences &&
          other.supportsScopedDuplication == supportsScopedDuplication &&
          other.selectable == selectable &&
          other.movable == movable &&
          other.resizable == resizable &&
          other.rotatable == rotatable;

  @override
  int get hashCode => Object.hash(
    hasIntrinsicGeometry,
    discoversResourceReferences,
    supportsScopedDuplication,
    selectable,
    movable,
    resizable,
    rotatable,
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

/// Authoritative semantic categories for a supported payload replacement.
final class ObjectPayloadChangeSemantics {
  /// Creates closed, immutable change evidence.
  const ObjectPayloadChangeSemantics({
    required this.geometry,
    required this.appearance,
    required this.text,
    required this.metadata,
  });

  /// Whether intrinsic payload geometry changed.
  final bool geometry;

  /// Whether visual styling changed independently of geometry.
  final bool appearance;

  /// Whether user-visible text semantics changed.
  final bool text;

  /// Whether nonvisual payload metadata changed.
  final bool metadata;
}

/// Optional Object-type behavior that classifies a before/after payload pair.
abstract interface class ObjectPayloadChangeClassifier {
  /// Classifies one valid same-schema payload replacement without mutation.
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
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
    required this.supportsPayloadChangeClassification,
  });

  /// The resolved immutable definition.
  final ObjectTypeDefinition definition;

  /// Deterministic payload warnings, if any.
  final ValidationReport report;

  /// Whether the captured definition can classify same-schema payload edits.
  final bool supportsPayloadChangeClassification;
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

  /// Creates a registry after safely snapshotting definition metadata.
  static Result<ObjectRegistry, StructuredFailure> create(
    Iterable<ObjectTypeDefinition> definitions,
  ) {
    try {
      final copied = <_RegisteredObjectTypeDefinition>[
        for (final definition in definitions)
          _RegisteredObjectTypeDefinition.capture(definition),
      ]..sort((left, right) => left.typeKey.compareTo(right.typeKey));
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
    } on Object {
      return Err<ObjectRegistry, StructuredFailure>(
        _definitionMetadataFailure(),
      );
    }
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
        supportsPayloadChangeClassification:
            (definition as _RegisteredObjectTypeDefinition)
                .supportsPayloadChangeClassification,
      );
    } on Object {
      return UnavailableObjectBehaviorResolution(envelope);
    }
  }

  @override
  String toString() => 'ObjectRegistry(length: ${definitions.length})';
}

final class _RegisteredObjectTypeDefinition
    implements ObjectTypeDefinition, ObjectPayloadChangeClassifier {
  _RegisteredObjectTypeDefinition._({
    required ObjectTypeDefinition delegate,
    required this.typeKey,
    required this.supportedSchemaVersions,
    required this.capabilities,
    required this.migrations,
    required this.supportsPayloadChangeClassification,
  }) : _delegate = delegate;

  factory _RegisteredObjectTypeDefinition.capture(
    ObjectTypeDefinition definition,
  ) {
    final typeKey = definition.typeKey;
    final supportedSchemaVersions = List<SchemaVersion>.unmodifiable(
      definition.supportedSchemaVersions,
    );
    final capabilities = definition.capabilities;
    final transformable =
        capabilities.movable ||
        capabilities.resizable ||
        capabilities.rotatable;
    if ((capabilities.selectable && !capabilities.hasIntrinsicGeometry) ||
        (transformable &&
            (!capabilities.selectable || !capabilities.hasIntrinsicGeometry))) {
      throw StateError('Invalid Object capability metadata.');
    }
    final migrations = List<ObjectPayloadMigrationContract>.unmodifiable(
      definition.migrations.map(
        (migration) => ObjectPayloadMigrationContract(
          fromSchemaVersion: migration.fromSchemaVersion,
          toSchemaVersion: migration.toSchemaVersion,
        ),
      ),
    );
    return _RegisteredObjectTypeDefinition._(
      delegate: definition,
      typeKey: typeKey,
      supportedSchemaVersions: supportedSchemaVersions,
      capabilities: ObjectTypeCapabilities(
        hasIntrinsicGeometry: capabilities.hasIntrinsicGeometry,
        discoversResourceReferences: capabilities.discoversResourceReferences,
        supportsScopedDuplication: capabilities.supportsScopedDuplication,
        selectable: capabilities.selectable,
        movable: capabilities.movable,
        resizable: capabilities.resizable,
        rotatable: capabilities.rotatable,
      ),
      migrations: migrations,
      supportsPayloadChangeClassification:
          definition is ObjectPayloadChangeClassifier,
    );
  }

  final ObjectTypeDefinition _delegate;

  @override
  final ObjectTypeKey typeKey;

  @override
  final List<SchemaVersion> supportedSchemaVersions;

  @override
  final ObjectTypeCapabilities capabilities;

  @override
  final List<ObjectPayloadMigrationContract> migrations;

  final bool supportsPayloadChangeClassification;

  @override
  ValidationReport validatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => _delegate.validatePayload(payload, schemaVersion);

  @override
  Result<Rect2, StructuredFailure> intrinsicGeometry(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => _delegate.intrinsicGeometry(payload, schemaVersion);

  @override
  Result<List<ResourceReference>, StructuredFailure> resourceReferences(
    PreservedData payload,
    SchemaVersion schemaVersion,
  ) => _delegate.resourceReferences(payload, schemaVersion);

  @override
  Result<PreservedData, StructuredFailure> duplicatePayload(
    PreservedData payload,
    SchemaVersion schemaVersion,
    IdentityRemapping remapping,
  ) => _delegate.duplicatePayload(payload, schemaVersion, remapping);

  @override
  Result<ObjectPayloadChangeSemantics, StructuredFailure> classifyPayloadChange(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    final delegate = _delegate;
    final classifier = delegate is ObjectPayloadChangeClassifier
        ? delegate as ObjectPayloadChangeClassifier
        : null;
    if (classifier == null) {
      return Err(_definitionMetadataFailure());
    }
    try {
      final result = classifier.classifyPayloadChange(
        before,
        after,
        schemaVersion,
      );
      return result is Ok<ObjectPayloadChangeSemantics, StructuredFailure>
          ? result
          : Err(_definitionMetadataFailure());
    } on Object {
      return Err(_definitionMetadataFailure());
    }
  }
}

StructuredFailure _definitionMetadataFailure() => StructuredFailure(
  code: 'documents.objects.definition_metadata_failure',
  category: FailureCategory.dependency,
  retryDisposition: RetryDisposition.never,
  message: 'Object definition metadata could not be registered.',
);
