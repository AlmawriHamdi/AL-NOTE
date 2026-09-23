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

/// Validated intrinsic box dimensions for a pure box-resize payload change.
final class IntrinsicBoxResizeChange {
  IntrinsicBoxResizeChange._({
    required this.beforeWidth,
    required this.beforeHeight,
    required this.afterWidth,
    required this.afterHeight,
  });

  /// Creates finite positive, dimension-changing box evidence.
  static Result<IntrinsicBoxResizeChange, StructuredFailure> create({
    required double beforeWidth,
    required double? beforeHeight,
    required double afterWidth,
    required double? afterHeight,
  }) {
    final heightsMatch = (beforeHeight == null) == (afterHeight == null);
    if (!beforeWidth.isFinite ||
        beforeWidth <= 0 ||
        !afterWidth.isFinite ||
        afterWidth <= 0 ||
        !heightsMatch ||
        (beforeHeight != null &&
            (!beforeHeight.isFinite || beforeHeight <= 0)) ||
        (afterHeight != null && (!afterHeight.isFinite || afterHeight <= 0)) ||
        beforeWidth == afterWidth && beforeHeight == afterHeight) {
      return Err(_definitionMetadataFailure());
    }
    return Ok(
      IntrinsicBoxResizeChange._(
        beforeWidth: beforeWidth,
        beforeHeight: beforeHeight,
        afterWidth: afterWidth,
        afterHeight: afterHeight,
      ),
    );
  }

  final double beforeWidth;
  final double? beforeHeight;
  final double afterWidth;
  final double? afterHeight;

  @override
  String toString() => '$runtimeType(validated: true)';
}

/// Optional trusted behavior for validating a pure intrinsic box resize.
abstract interface class IntrinsicBoxResizeValidator {
  /// Extracts authoritative intrinsic box dimensions from one valid payload.
  Result<IntrinsicBoxResizeChange, StructuredFailure>
  validateIntrinsicBoxResize(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  );

  /// Reports whether two valid payloads change intrinsic box dimensions.
  Result<bool, StructuredFailure> changesIntrinsicBoxDimensions(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  );
}

/// Horizontal content anchor retained by an intrinsic visible-content fit.
enum IntrinsicHorizontalAnchor { left, center, right }

/// Vertical content anchor retained by an intrinsic visible-content fit.
enum IntrinsicVerticalAnchor { top, center, bottom }

/// Independently validated evidence for one canonical visible-content fit.
final class IntrinsicVisibleContentFitChange {
  const IntrinsicVisibleContentFitChange({
    required this.resize,
    required this.horizontalAnchor,
    required this.verticalAnchor,
  });

  /// Authoritative before/after intrinsic dimensions.
  final IntrinsicBoxResizeChange resize;

  /// Horizontal content anchor that must remain fixed in Page space.
  final IntrinsicHorizontalAnchor horizontalAnchor;

  /// Vertical content anchor that must remain fixed in Page space.
  final IntrinsicVerticalAnchor verticalAnchor;

  @override
  String toString() => '$runtimeType(validated: true)';
}

/// Optional trusted behavior for validating a canonical visible-content fit.
abstract interface class IntrinsicVisibleContentFitValidator {
  /// Recomputes the canonical fit and its required content anchor.
  Result<IntrinsicVisibleContentFitChange, StructuredFailure>
  validateIntrinsicVisibleContentFit(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  );
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
    required this.supportsIntrinsicBoxResizeValidation,
    required this.supportsIntrinsicVisibleContentFitValidation,
  });

  /// The resolved immutable definition.
  final ObjectTypeDefinition definition;

  /// Deterministic payload warnings, if any.
  final ValidationReport report;

  /// Whether the captured definition can classify same-schema payload edits.
  final bool supportsPayloadChangeClassification;

  /// Whether the captured definition validates pure intrinsic box resizes.
  final bool supportsIntrinsicBoxResizeValidation;

  /// Whether the captured definition validates canonical content fitting.
  final bool supportsIntrinsicVisibleContentFitValidation;
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
    final supported = List<SchemaVersion>.of(definition.supportedSchemaVersions)
        .contains(envelope.typeSchemaVersion);
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
        supportsIntrinsicBoxResizeValidation:
            definition.supportsIntrinsicBoxResizeValidation,
        supportsIntrinsicVisibleContentFitValidation:
            definition.supportsIntrinsicVisibleContentFitValidation,
      );
    } on Object {
      return UnavailableObjectBehaviorResolution(envelope);
    }
  }

  @override
  String toString() => 'ObjectRegistry(length: ${definitions.length})';
}

final class _RegisteredObjectTypeDefinition
    implements
        ObjectTypeDefinition,
        ObjectPayloadChangeClassifier,
        IntrinsicBoxResizeValidator,
        IntrinsicVisibleContentFitValidator {
  _RegisteredObjectTypeDefinition._({
    required ObjectTypeDefinition delegate,
    required this.typeKey,
    required this.supportedSchemaVersions,
    required this.capabilities,
    required this.migrations,
    required this.supportsPayloadChangeClassification,
    required this.supportsIntrinsicBoxResizeValidation,
    required this.supportsIntrinsicVisibleContentFitValidation,
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
      supportsIntrinsicBoxResizeValidation:
          definition is IntrinsicBoxResizeValidator,
      supportsIntrinsicVisibleContentFitValidation:
          definition is IntrinsicVisibleContentFitValidator,
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

  final bool supportsIntrinsicBoxResizeValidation;

  final bool supportsIntrinsicVisibleContentFitValidation;

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

  @override
  Result<IntrinsicBoxResizeChange, StructuredFailure>
  validateIntrinsicBoxResize(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    final delegate = _delegate;
    final validator = delegate is IntrinsicBoxResizeValidator
        ? delegate as IntrinsicBoxResizeValidator
        : null;
    if (validator == null) return Err(_definitionMetadataFailure());
    try {
      final result = validator.validateIntrinsicBoxResize(
        before,
        after,
        schemaVersion,
      );
      return result is Ok<IntrinsicBoxResizeChange, StructuredFailure>
          ? result
          : Err(_definitionMetadataFailure());
    } on Object {
      return Err(_definitionMetadataFailure());
    }
  }

  @override
  Result<bool, StructuredFailure> changesIntrinsicBoxDimensions(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    final delegate = _delegate;
    final validator = delegate is IntrinsicBoxResizeValidator
        ? delegate as IntrinsicBoxResizeValidator
        : null;
    if (validator == null) return Err(_definitionMetadataFailure());
    try {
      final result = validator.changesIntrinsicBoxDimensions(
        before,
        after,
        schemaVersion,
      );
      return result is Ok<bool, StructuredFailure>
          ? result
          : Err(_definitionMetadataFailure());
    } on Object {
      return Err(_definitionMetadataFailure());
    }
  }

  @override
  Result<IntrinsicVisibleContentFitChange, StructuredFailure>
  validateIntrinsicVisibleContentFit(
    PreservedData before,
    PreservedData after,
    SchemaVersion schemaVersion,
  ) {
    final delegate = _delegate;
    final validator = delegate is IntrinsicVisibleContentFitValidator
        ? delegate as IntrinsicVisibleContentFitValidator
        : null;
    if (validator == null) return Err(_definitionMetadataFailure());
    try {
      final result = validator.validateIntrinsicVisibleContentFit(
        before,
        after,
        schemaVersion,
      );
      return result is Ok<IntrinsicVisibleContentFitChange, StructuredFailure>
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
