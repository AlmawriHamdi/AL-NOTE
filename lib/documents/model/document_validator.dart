// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/validation/validation_issue.dart';
import '../../core/validation/validation_path.dart';
import '../../core/validation/validation_report.dart';
import '../../core/validation/validator.dart';
import '../layers/document_layer.dart';
import '../objects/object_envelope.dart';
import '../objects/object_registry.dart';
import 'document_root.dart';
import 'identifiers.dart';
import 'placeholders.dart';

/// A deterministic validation report paired with safe placeholder evidence.
final class DocumentValidationResult {
  /// Defensively copies placeholder evidence.
  DocumentValidationResult({
    required this.report,
    required Iterable<PlaceholderDescriptor> placeholders,
  }) : placeholders = List<PlaceholderDescriptor>.unmodifiable(placeholders);

  /// The deterministic redaction-safe validation report.
  final ValidationReport report;

  /// Non-UI inert placeholder evidence in deterministic traversal order.
  final List<PlaceholderDescriptor> placeholders;

  @override
  String toString() =>
      'DocumentValidationResult(valid: ${report.isValid}, '
      'issues: ${report.issues.length}, placeholders: ${placeholders.length})';
}

/// Deterministically validates authoritative documents against one Registry.
final class DocumentValidator implements Validator<DocumentRoot> {
  /// Creates a validator using the immutable injected [objectRegistry].
  const DocumentValidator(this.objectRegistry);

  /// The Object behavior registry used for resolution.
  final ObjectRegistry objectRegistry;

  /// Validates [value] and returns only the closed Phase 1 report contract.
  @override
  ValidationReport validate(DocumentRoot value) =>
      validateWithPlaceholders(value).report;

  /// Validates [document] and also returns model-level placeholder evidence.
  DocumentValidationResult validateWithPlaceholders(DocumentRoot document) {
    final issues = <ValidationIssue>[];
    final placeholders = <PlaceholderDescriptor>[];
    final sectionIds = <SectionId>{};
    final pageIds = <PageId>{};
    final layerIds = <LayerId>{};
    final objectIds = <ObjectId>{};
    final references = <ResourceIdentity>{};

    if (document.schemaVersion.value <= 0) {
      issues.add(
        _issue(
          ValidationIssueCode.invalidStructure,
          ValidationSeverity.error,
          _path(<ValidationPathSegment>[
            ValidationPathSegment.document,
            ValidationPathSegment.root,
            ValidationPathSegment.schemaVersion,
          ]),
        ),
      );
    }
    if (document is NotebookDocument) {
      for (final section in document.sections) {
        if (!sectionIds.add(section.id)) {
          issues.add(
            _issue(
              ValidationIssueCode.duplicateIdentity,
              ValidationSeverity.error,
              _path(<ValidationPathSegment>[
                ValidationPathSegment.document,
                ValidationPathSegment.sections,
                ValidationPathSegment.section,
                ValidationPathSegment.identity,
              ]),
            ),
          );
        }
      }
    }
    if (document case StandalonePdfDocument(:final source)) {
      references.add(source.identity);
    }

    for (final page in document.pages) {
      _validatePage(
        page,
        issues: issues,
        placeholders: placeholders,
        pageIds: pageIds,
        layerIds: layerIds,
        objectIds: objectIds,
        references: references,
      );
    }

    final sortedReferences = references.toList()
      ..sort((left, right) => left.uuid.value.compareTo(right.uuid.value));
    for (final reference in sortedReferences) {
      if (!document.resources.contains(reference)) {
        issues.add(
          _issue(
            ValidationIssueCode.missingResource,
            ValidationSeverity.warning,
            _path(<ValidationPathSegment>[
              ValidationPathSegment.document,
              ValidationPathSegment.resources,
              ValidationPathSegment.reference,
            ]),
          ),
        );
        placeholders.add(
          ResourcePlaceholderDescriptor(
            reason: PlaceholderReason.missingResource,
            resourceIdentity: reference,
          ),
        );
      }
    }
    return DocumentValidationResult(
      report: ValidationReport(issues),
      placeholders: placeholders,
    );
  }

  void _validatePage(
    DocumentPage page, {
    required List<ValidationIssue> issues,
    required List<PlaceholderDescriptor> placeholders,
    required Set<PageId> pageIds,
    required Set<LayerId> layerIds,
    required Set<ObjectId> objectIds,
    required Set<ResourceIdentity> references,
  }) {
    if (!pageIds.add(page.id)) {
      issues.add(
        _issue(
          ValidationIssueCode.duplicateIdentity,
          ValidationSeverity.error,
          _pagePath(ValidationPathSegment.identity),
        ),
      );
    }
    if (page.size.isEmpty) {
      issues.add(
        _issue(
          ValidationIssueCode.invalidStructure,
          ValidationSeverity.error,
          _pagePath(ValidationPathSegment.size),
        ),
      );
    }
    var contentCount = 0;
    var backgroundCount = 0;
    var pdfCount = 0;
    var priorRole = -1;
    for (final layer in page.layers) {
      if (!layerIds.add(layer.id)) {
        issues.add(
          _issue(
            ValidationIssueCode.multipleOwnership,
            ValidationSeverity.error,
            _layerPath(ValidationPathSegment.identity),
          ),
        );
      }
      final roleIndex = switch (layer.role) {
        LayerCoreRole.backgroundSource => 0,
        LayerCoreRole.pdfSource => 1,
        LayerCoreRole.content => 2,
      };
      if (roleIndex < priorRole) {
        issues.add(
          _issue(
            ValidationIssueCode.invalidLayerOrder,
            ValidationSeverity.error,
            _layerPath(ValidationPathSegment.role),
          ),
        );
      }
      priorRole = roleIndex;
      switch (layer.role) {
        case LayerCoreRole.content:
          contentCount += 1;
        case LayerCoreRole.backgroundSource:
          backgroundCount += 1;
        case LayerCoreRole.pdfSource:
          pdfCount += 1;
      }
      if (!layer.opacity.isFinite || layer.opacity < 0 || layer.opacity > 1) {
        issues.add(
          _issue(
            ValidationIssueCode.invalidStructure,
            ValidationSeverity.error,
            _layerPath(ValidationPathSegment.opacity),
          ),
        );
      }
      if (layer.envelopeVersion.value <= 0 ||
          layer.typeSchemaVersion.value <= 0) {
        issues.add(
          _issue(
            ValidationIssueCode.invalidStructure,
            ValidationSeverity.error,
            _layerPath(ValidationPathSegment.schemaVersion),
          ),
        );
      }
      if (layer is UnknownLayer) {
        issues.add(
          _issue(
            ValidationIssueCode.unknownLayerType,
            ValidationSeverity.warning,
            _layerPath(ValidationPathSegment.type),
          ),
        );
        placeholders.add(
          LayerPlaceholderDescriptor(
            reason: PlaceholderReason.unknownLayerType,
            layerId: layer.id,
            typeKey: layer.typeKey,
          ),
        );
      }
      for (final object in layer.objects) {
        if (!objectIds.add(object.id)) {
          issues.add(
            _issue(
              ValidationIssueCode.multipleOwnership,
              ValidationSeverity.error,
              _objectPath(ValidationPathSegment.identity),
            ),
          );
        }
        if (object.envelopeVersion.value <= 0 ||
            object.typeSchemaVersion.value <= 0) {
          issues.add(
            _issue(
              ValidationIssueCode.invalidStructure,
              ValidationSeverity.error,
              _objectPath(ValidationPathSegment.schemaVersion),
            ),
          );
        }
        _validateObject(
          object,
          issues: issues,
          placeholders: placeholders,
          references: references,
        );
      }
    }
    if (contentCount == 0) {
      issues.add(
        _issue(
          ValidationIssueCode.missingContentLayer,
          ValidationSeverity.error,
          _pagePath(ValidationPathSegment.layers),
        ),
      );
    }
    if (backgroundCount > 1 || pdfCount > 1) {
      issues.add(
        _issue(
          ValidationIssueCode.invalidLayerRoleCount,
          ValidationSeverity.error,
          _pagePath(ValidationPathSegment.layers),
        ),
      );
    }
  }

  void _validateObject(
    ObjectEnvelope object, {
    required List<ValidationIssue> issues,
    required List<PlaceholderDescriptor> placeholders,
    required Set<ResourceIdentity> references,
  }) {
    final resolution = objectRegistry.resolve(object);
    switch (resolution) {
      case UnknownObjectTypeResolution():
        issues.add(
          _issue(
            ValidationIssueCode.unknownObjectType,
            ValidationSeverity.warning,
            _objectPath(ValidationPathSegment.type),
          ),
        );
        placeholders.add(
          ObjectPlaceholderDescriptor(
            reason: PlaceholderReason.unknownObjectType,
            objectId: object.id,
            typeKey: object.typeKey,
          ),
        );
      case UnsupportedObjectSchemaResolution():
        issues.add(
          _issue(
            ValidationIssueCode.unsupportedObjectSchema,
            ValidationSeverity.warning,
            _objectPath(ValidationPathSegment.schemaVersion),
          ),
        );
        placeholders.add(
          ObjectPlaceholderDescriptor(
            reason: PlaceholderReason.unsupportedObjectSchema,
            objectId: object.id,
            typeKey: object.typeKey,
          ),
        );
      case InvalidObjectPayloadResolution(:final report):
        issues
          ..addAll(report.issues)
          ..add(
            _issue(
              ValidationIssueCode.invalidObjectPayload,
              ValidationSeverity.error,
              _objectPath(ValidationPathSegment.payload),
            ),
          );
      case UnavailableObjectBehaviorResolution():
        issues.add(
          _issue(
            ValidationIssueCode.unavailableBehavior,
            ValidationSeverity.warning,
            _objectPath(ValidationPathSegment.type),
          ),
        );
        placeholders.add(
          ObjectPlaceholderDescriptor(
            reason: PlaceholderReason.unavailableRequiredBehavior,
            objectId: object.id,
            typeKey: object.typeKey,
          ),
        );
      case SupportedObjectResolution(:final definition, :final report):
        issues.addAll(report.issues);
        var requiredBehaviorUnavailable = false;
        final capabilities = definition.capabilities;
        if (capabilities.hasIntrinsicGeometry) {
          try {
            definition
                .intrinsicGeometry(object.payload, object.typeSchemaVersion)
                .fold<void>(
                  onOk: (_) {},
                  onErr: (_) {
                    requiredBehaviorUnavailable = true;
                  },
                );
          } on Object {
            requiredBehaviorUnavailable = true;
          }
        }
        if (capabilities.discoversResourceReferences) {
          try {
            definition
                .resourceReferences(object.payload, object.typeSchemaVersion)
                .fold<void>(
                  onOk: (values) {
                    for (final value in values) {
                      references.add(value.identity);
                    }
                  },
                  onErr: (_) {
                    requiredBehaviorUnavailable = true;
                  },
                );
          } on Object {
            requiredBehaviorUnavailable = true;
          }
        }
        if (requiredBehaviorUnavailable) {
          _addUnavailableBehavior(
            object,
            issues: issues,
            placeholders: placeholders,
          );
        }
    }
  }
}

void _addUnavailableBehavior(
  ObjectEnvelope object, {
  required List<ValidationIssue> issues,
  required List<PlaceholderDescriptor> placeholders,
}) {
  issues.add(
    _issue(
      ValidationIssueCode.unavailableBehavior,
      ValidationSeverity.warning,
      _objectPath(ValidationPathSegment.type),
    ),
  );
  placeholders.add(
    ObjectPlaceholderDescriptor(
      reason: PlaceholderReason.unavailableRequiredBehavior,
      objectId: object.id,
      typeKey: object.typeKey,
    ),
  );
}

ValidationPath _pagePath(ValidationPathSegment tail) =>
    _path(<ValidationPathSegment>[
      ValidationPathSegment.document,
      ValidationPathSegment.pages,
      ValidationPathSegment.page,
      tail,
    ]);

ValidationPath _layerPath(ValidationPathSegment tail) =>
    _path(<ValidationPathSegment>[
      ValidationPathSegment.document,
      ValidationPathSegment.pages,
      ValidationPathSegment.page,
      ValidationPathSegment.layers,
      ValidationPathSegment.layer,
      tail,
    ]);

ValidationPath _objectPath(ValidationPathSegment tail) =>
    _path(<ValidationPathSegment>[
      ValidationPathSegment.document,
      ValidationPathSegment.pages,
      ValidationPathSegment.page,
      ValidationPathSegment.layers,
      ValidationPathSegment.layer,
      ValidationPathSegment.objects,
      ValidationPathSegment.object,
      tail,
    ]);

ValidationPath _path(Iterable<ValidationPathSegment> segments) =>
    ValidationPath.fromSegments(segments).fold(
      onOk: (value) => value,
      onErr: (_) => throw StateError('Invalid trusted validation path.'),
    );

ValidationIssue _issue(
  ValidationIssueCode code,
  ValidationSeverity severity,
  ValidationPath path,
) => ValidationIssue.create(code: code, severity: severity, path: path).fold(
  onOk: (value) => value,
  onErr: (_) => throw StateError('Invalid trusted validation issue.'),
);
