// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import '../../core/versioning/schema_version.dart';
import '../model/document_root.dart';
import '../model/document_validator.dart';
import '../model/identifiers.dart';
import '../model/preserved_data.dart';
import '../objects/object_envelope.dart';
import '../objects/object_registry.dart';
import 'contracts.dart';
import 'src/bounded_json.dart';
import 'src/record_codec.dart';

/// The trusted structured-record scope of a migration transition.
enum AlnoteMigrationScope {
  /// The package/manifest record family.
  package,

  /// The document-root record family.
  documentRoot,

  /// One known Object payload type.
  objectPayload,
}

/// A trusted AL NOTE-owned immutable migration handler.
typedef AlnoteMigrationHandler =
    Result<PreservedData, StructuredFailure> Function(PreservedData input);

/// Builds one complete immutable candidate from migrated structured data.
typedef AlnoteMigratedSnapshotBuilder =
    Result<AlnotePackageSnapshot, StructuredFailure> Function(
      PreservedData migrated,
      AlnotePackageSnapshot original,
    );

/// Exact Object-payload transition target bound to one persistent identity.
final class AlnoteObjectMigrationTarget {
  /// Creates typed source/target evidence for one Object payload migration.
  const AlnoteObjectMigrationTarget({
    required this.objectType,
    required this.objectId,
    required this.sourceSchemaVersion,
    required this.targetSchemaVersion,
  });

  /// The intended registered Object type.
  final ObjectTypeKey objectType;

  /// The exact persistent Object identity in the original snapshot.
  final ObjectId objectId;

  /// The exact original Object payload schema version.
  final SchemaVersion sourceSchemaVersion;

  /// The exact completed Object payload schema version.
  final SchemaVersion targetSchemaVersion;
}

/// One exact adjacent trusted migration transition.
final class AlnoteMigrationStep implements Comparable<AlnoteMigrationStep> {
  /// Creates immutable transition metadata and a trusted handler.
  const AlnoteMigrationStep({
    required this.scope,
    required this.sourceVersion,
    required this.targetVersion,
    required this.handler,
    this.objectType,
  });

  /// The structured-record scope.
  final AlnoteMigrationScope scope;

  /// The exact positive source version.
  final int sourceVersion;

  /// The exact adjacent target version.
  final int targetVersion;

  /// The Object type for [AlnoteMigrationScope.objectPayload].
  final ObjectTypeKey? objectType;

  /// The trusted deterministic side-effect-free handler.
  final AlnoteMigrationHandler handler;

  @override
  int compareTo(AlnoteMigrationStep other) {
    final scopeOrder = scope.index.compareTo(other.scope.index);
    if (scopeOrder != 0) return scopeOrder;
    final typeOrder = (objectType?.value ?? '').compareTo(
      other.objectType?.value ?? '',
    );
    if (typeOrder != 0) return typeOrder;
    return sourceVersion.compareTo(other.sourceVersion);
  }
}

/// A nonglobal immutable registry of trusted AL NOTE-owned migrations.
final class AlnoteMigrationRegistry {
  AlnoteMigrationRegistry._(this.steps);

  /// Validates adjacency, uniqueness, ordering, and Object-scope metadata.
  static Result<AlnoteMigrationRegistry, StructuredFailure> create(
    Iterable<AlnoteMigrationStep> source,
  ) {
    final steps = List<AlnoteMigrationStep>.of(source)..sort();
    final keys = <String>{};
    for (final step in steps) {
      if (step.sourceVersion <= 0 ||
          step.targetVersion != step.sourceVersion + 1 ||
          (step.scope == AlnoteMigrationScope.objectPayload) !=
              (step.objectType != null)) {
        return Err<AlnoteMigrationRegistry, StructuredFailure>(
          _migrationFailure('registry', 'Migration metadata is not valid.'),
        );
      }
      final key =
          '${step.scope.index}|${step.objectType?.value ?? ''}|${step.sourceVersion}';
      if (!keys.add(key)) {
        return Err<AlnoteMigrationRegistry, StructuredFailure>(
          _migrationFailure(
            'registry',
            'Migration transitions must be unique.',
          ),
        );
      }
    }
    return Ok<AlnoteMigrationRegistry, StructuredFailure>(
      AlnoteMigrationRegistry._(List<AlnoteMigrationStep>.unmodifiable(steps)),
    );
  }

  /// Every transition in deterministic scope/type/source order.
  final List<AlnoteMigrationStep> steps;

  /// Plans one exact contiguous forward path; gaps and reverse paths reject.
  Result<AlnoteMigrationPlan, StructuredFailure> plan({
    required AlnoteMigrationScope scope,
    required int sourceVersion,
    required int targetVersion,
    ObjectTypeKey? objectType,
  }) {
    if (sourceVersion <= 0 ||
        targetVersion < sourceVersion ||
        (scope == AlnoteMigrationScope.objectPayload) != (objectType != null)) {
      return Err<AlnoteMigrationPlan, StructuredFailure>(
        _migrationFailure('plan', 'A migration plan request is not valid.'),
      );
    }
    final planned = <AlnoteMigrationStep>[];
    var current = sourceVersion;
    while (current < targetVersion) {
      final matches = steps.where(
        (step) =>
            step.scope == scope &&
            step.objectType == objectType &&
            step.sourceVersion == current,
      );
      if (matches.length != 1) {
        return Err<AlnoteMigrationPlan, StructuredFailure>(
          _migrationFailure(
            'plan',
            'A migration path contains a gap or ambiguity.',
          ),
        );
      }
      final step = matches.single;
      planned.add(step);
      current = step.targetVersion;
    }
    return Ok<AlnoteMigrationPlan, StructuredFailure>(
      AlnoteMigrationPlan._(
        scope: scope,
        sourceVersion: sourceVersion,
        targetVersion: targetVersion,
        objectType: objectType,
        steps: planned,
      ),
    );
  }
}

/// One immutable deterministic migration plan.
final class AlnoteMigrationPlan {
  AlnoteMigrationPlan._({
    required this.scope,
    required this.sourceVersion,
    required this.targetVersion,
    required this.objectType,
    required List<AlnoteMigrationStep> steps,
  }) : steps = List<AlnoteMigrationStep>.unmodifiable(steps);

  /// The migrated record scope.
  final AlnoteMigrationScope scope;

  /// The original positive schema version.
  final int sourceVersion;

  /// The planned positive schema version.
  final int targetVersion;

  /// The Object type for Object-payload plans.
  final ObjectTypeKey? objectType;

  /// Exact adjacent steps in application order.
  final List<AlnoteMigrationStep> steps;

  /// Applies trusted handlers immutably within explicit step/expansion limits.
  OperationOutcome<AlnoteMigrationResult, StructuredFailure> apply(
    PreservedData input, {
    required ResourceLimitSnapshot limits,
    required CancellationToken cancellationToken,
  }) {
    final parsedLimits = AlnoteStorageLimits.fromSnapshot(limits);
    if (parsedLimits is Err<AlnoteStorageLimits, StructuredFailure>) {
      return Failed<AlnoteMigrationResult, StructuredFailure>(
        parsedLimits.error,
      );
    }
    final storageLimits =
        (parsedLimits as Ok<AlnoteStorageLimits, StructuredFailure>).value;
    if (steps.length > storageLimits['alnote.storage.migration_steps']) {
      return Failed<AlnoteMigrationResult, StructuredFailure>(
        _migrationFailure('steps', 'The migration step ceiling was exceeded.'),
      );
    }
    final json = BoundedJsonCodec(
      maximumBytes: storageLimits['alnote.storage.json_bytes'],
      maximumDepth: storageLimits['alnote.storage.json_depth'],
      maximumValues: storageLimits['alnote.storage.json_values'],
      maximumStringCodeUnits: storageLimits['alnote.storage.string_code_units'],
    );
    var current = input;
    var priorSize = json
        .encode(current)
        .fold(onOk: (bytes) => bytes.length, onErr: (_) => -1);
    if (priorSize < 0) {
      return Failed<AlnoteMigrationResult, StructuredFailure>(
        _migrationFailure(
          'input',
          'Migration input is not valid preserved data.',
        ),
      );
    }
    var expansion = 0;
    for (final step in steps) {
      if (cancellationToken.isCancelled) {
        return Cancelled<AlnoteMigrationResult, StructuredFailure>(
          cancellationToken.reason,
        );
      }
      Result<PreservedData, StructuredFailure> result;
      try {
        result = step.handler(current);
      } on Object {
        return Failed<AlnoteMigrationResult, StructuredFailure>(
          _handlerFailure(),
        );
      }
      if (result is Err<PreservedData, StructuredFailure>) {
        return Failed<AlnoteMigrationResult, StructuredFailure>(
          _handlerFailure(),
        );
      }
      final candidate = (result as Ok<PreservedData, StructuredFailure>).value;
      final candidateSize = json
          .encode(candidate)
          .fold(onOk: (bytes) => bytes.length, onErr: (_) => -1);
      if (candidateSize < 0) {
        return Failed<AlnoteMigrationResult, StructuredFailure>(
          _handlerFailure(),
        );
      }
      if (candidateSize > priorSize) {
        final increase = candidateSize - priorSize;
        if (increase > maximumWebSafeInteger - expansion) {
          return Failed<AlnoteMigrationResult, StructuredFailure>(
            _migrationFailure(
              'expansion_bytes',
              'Migration expansion is not representable.',
            ),
          );
        }
        expansion += increase;
        if (expansion >
            storageLimits['alnote.storage.migration_expansion_bytes']) {
          return Failed<AlnoteMigrationResult, StructuredFailure>(
            _migrationFailure(
              'expansion_bytes',
              'The migration expansion ceiling was exceeded.',
            ),
          );
        }
      }
      current = candidate;
      priorSize = candidateSize;
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<AlnoteMigrationResult, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<AlnoteMigrationResult, StructuredFailure>(
      AlnoteMigrationResult(
        value: current,
        evidence: AlnoteMigrationEvidence(stepCount: steps.length),
      ),
    );
  }

  /// Migrates data, builds one complete candidate, and validates it atomically.
  ///
  /// The original snapshot is never mutated. Resources and unknown package
  /// preservation must remain exact. This produces no package bytes; migrated
  /// bytes require a later explicit successful Save.
  OperationOutcome<AlnotePackageMigrationResult, StructuredFailure>
  applyToPackage(
    PreservedData input, {
    required AlnotePackageSnapshot original,
    required AlnoteMigratedSnapshotBuilder buildCandidate,
    required ObjectRegistry objectRegistry,
    required ResourceLimitSnapshot limits,
    required CancellationToken cancellationToken,
    AlnoteObjectMigrationTarget? objectTarget,
  }) {
    final sourceRecord = _recordForScope(
      original,
      scope: scope,
      objectTarget: objectTarget,
    );
    if (!_sourceMatchesPlan(
          original,
          scope: scope,
          sourceVersion: sourceVersion,
          targetVersion: targetVersion,
          objectType: objectType,
          objectTarget: objectTarget,
        ) ||
        sourceRecord == null ||
        sourceRecord != input) {
      return Failed<AlnotePackageMigrationResult, StructuredFailure>(
        _candidateFailure(),
      );
    }
    final migrated = apply(
      input,
      limits: limits,
      cancellationToken: cancellationToken,
    );
    if (migrated is Failed<AlnoteMigrationResult, StructuredFailure>) {
      return Failed<AlnotePackageMigrationResult, StructuredFailure>(
        migrated.failure,
      );
    }
    if (migrated is Cancelled<AlnoteMigrationResult, StructuredFailure>) {
      return Cancelled<AlnotePackageMigrationResult, StructuredFailure>(
        migrated.reason,
      );
    }
    Result<AlnotePackageSnapshot, StructuredFailure> built;
    try {
      built = buildCandidate(
        (migrated as Completed<AlnoteMigrationResult, StructuredFailure>)
            .value
            .value,
        original,
      );
    } on Object {
      return Failed<AlnotePackageMigrationResult, StructuredFailure>(
        _candidateFailure(),
      );
    }
    if (built is Err<AlnotePackageSnapshot, StructuredFailure>) {
      return Failed<AlnotePackageMigrationResult, StructuredFailure>(
        _candidateFailure(),
      );
    }
    final candidate =
        (built as Ok<AlnotePackageSnapshot, StructuredFailure>).value;
    final migratedValue = migrated.value.value;
    final candidateRecord = _recordForScope(
      candidate,
      scope: scope,
      objectTarget: objectTarget,
    );
    if (!_targetMatchesPlan(
          candidate,
          scope: scope,
          targetVersion: targetVersion,
          objectTarget: objectTarget,
        ) ||
        candidateRecord == null ||
        candidateRecord != migratedValue ||
        !_scopeIsolated(
          original,
          candidate,
          scope: scope,
          objectTarget: objectTarget,
        ) ||
        !_sameResources(original, candidate) ||
        !_samePreservation(original.preservation, candidate.preservation) ||
        !DocumentValidator(
          objectRegistry,
        ).validate(candidate.document).isValid) {
      return Failed<AlnotePackageMigrationResult, StructuredFailure>(
        _candidateFailure(),
      );
    }
    if (cancellationToken.isCancelled) {
      return Cancelled<AlnotePackageMigrationResult, StructuredFailure>(
        cancellationToken.reason,
      );
    }
    return Completed<AlnotePackageMigrationResult, StructuredFailure>(
      AlnotePackageMigrationResult(
        snapshot: candidate,
        evidence: migrated.value.evidence,
      ),
    );
  }
}

/// Immutable migrated preserved data and redaction-safe evidence.
final class AlnoteMigrationResult {
  /// Creates a complete migration result.
  const AlnoteMigrationResult({required this.value, required this.evidence});

  /// The new immutable preserved value; original input remains untouched.
  final PreservedData value;

  /// Redaction-safe migration evidence.
  final AlnoteMigrationEvidence evidence;
}

/// A fully validated migrated package snapshot that has not yet been saved.
final class AlnotePackageMigrationResult {
  /// Creates a complete in-memory migration result.
  const AlnotePackageMigrationResult({
    required this.snapshot,
    required this.evidence,
  });

  /// The fully validated immutable candidate snapshot.
  final AlnotePackageSnapshot snapshot;

  /// Redaction-safe migration evidence.
  final AlnoteMigrationEvidence evidence;
}

StructuredFailure _handlerFailure() => _migrationFailure(
  'handler',
  'A trusted migration handler could not produce a valid result.',
);

StructuredFailure _candidateFailure() => _migrationFailure(
  'candidate',
  'A complete migrated package candidate could not be validated.',
);

StructuredFailure _migrationFailure(String dimension, String message) =>
    StructuredFailure(
      code: 'documents.migration.$dimension',
      category: FailureCategory.validation,
      retryDisposition: RetryDisposition.never,
      message: message,
    );

bool _sameResources(
  AlnotePackageSnapshot original,
  AlnotePackageSnapshot candidate,
) {
  if (original.resources.length != candidate.resources.length) return false;
  for (var index = 0; index < original.resources.length; index += 1) {
    final left = original.resources[index];
    final right = candidate.resources[index];
    if (left.identity != right.identity ||
        left.digest != right.digest ||
        left.decodedByteLength != right.decodedByteLength ||
        left.mediaType != right.mediaType ||
        left.role != right.role ||
        left.schemaVersion != right.schemaVersion ||
        left.packagePath != right.packagePath ||
        !_bytesEqual(left.bytes, right.bytes)) {
      return false;
    }
  }
  return true;
}

bool _samePreservation(
  AlnotePackagePreservation left,
  AlnotePackagePreservation right,
) {
  if (left.unknownManifestFields != right.unknownManifestFields ||
      !_sameStrings(left.optionalFeatures, right.optionalFeatures) ||
      !_sameStrings(left.extensionNamespaces, right.extensionNamespaces) ||
      !_samePreservedMaps(left.entryCatalogFields, right.entryCatalogFields) ||
      !_samePreservedMaps(
        left.resourceCatalogFields,
        right.resourceCatalogFields,
      ) ||
      left.opaqueEntries.length != right.opaqueEntries.length) {
    return false;
  }
  for (var index = 0; index < left.opaqueEntries.length; index += 1) {
    final leftEntry = left.opaqueEntries[index];
    final rightEntry = right.opaqueEntries[index];
    if (leftEntry.path != rightEntry.path ||
        leftEntry.mediaType != rightEntry.mediaType ||
        leftEntry.schemaVersion != rightEntry.schemaVersion ||
        !_bytesEqual(leftEntry.bytes, rightEntry.bytes)) {
      return false;
    }
  }
  return true;
}

bool _sourceMatchesPlan(
  AlnotePackageSnapshot original, {
  required AlnoteMigrationScope scope,
  required int sourceVersion,
  required int targetVersion,
  required ObjectTypeKey? objectType,
  required AlnoteObjectMigrationTarget? objectTarget,
}) {
  switch (scope) {
    case AlnoteMigrationScope.package:
      return objectTarget == null && original.version.value == sourceVersion;
    case AlnoteMigrationScope.documentRoot:
      return objectTarget == null &&
          original.document.schemaVersion.value == sourceVersion;
    case AlnoteMigrationScope.objectPayload:
      if (objectTarget == null ||
          objectTarget.objectType != objectType ||
          objectTarget.sourceSchemaVersion.value != sourceVersion ||
          objectTarget.targetSchemaVersion.value != targetVersion) {
        return false;
      }
      final object = _findObject(original.document, objectTarget.objectId);
      return object != null &&
          object.typeKey == objectTarget.objectType &&
          object.typeSchemaVersion == objectTarget.sourceSchemaVersion;
  }
}

bool _targetMatchesPlan(
  AlnotePackageSnapshot candidate, {
  required AlnoteMigrationScope scope,
  required int targetVersion,
  required AlnoteObjectMigrationTarget? objectTarget,
}) {
  switch (scope) {
    case AlnoteMigrationScope.package:
      return candidate.version.value == targetVersion;
    case AlnoteMigrationScope.documentRoot:
      return candidate.document.schemaVersion.value == targetVersion;
    case AlnoteMigrationScope.objectPayload:
      if (objectTarget == null) return false;
      final object = _findObject(candidate.document, objectTarget.objectId);
      return object != null &&
          object.typeKey == objectTarget.objectType &&
          object.typeSchemaVersion == objectTarget.targetSchemaVersion;
  }
}

PreservedData? _recordForScope(
  AlnotePackageSnapshot snapshot, {
  required AlnoteMigrationScope scope,
  required AlnoteObjectMigrationTarget? objectTarget,
}) {
  switch (scope) {
    case AlnoteMigrationScope.package:
      return PreservedMap(<String, PreservedData>{
        'packageVersion': _preservedInteger(snapshot.version.value),
      });
    case AlnoteMigrationScope.documentRoot:
      return RecordEncoder().document(snapshot.document);
    case AlnoteMigrationScope.objectPayload:
      if (objectTarget == null) return null;
      return _findObject(snapshot.document, objectTarget.objectId)?.payload;
  }
}

bool _scopeIsolated(
  AlnotePackageSnapshot original,
  AlnotePackageSnapshot candidate, {
  required AlnoteMigrationScope scope,
  required AlnoteObjectMigrationTarget? objectTarget,
}) {
  return switch (scope) {
    AlnoteMigrationScope.package => original.document == candidate.document,
    AlnoteMigrationScope.documentRoot =>
      original.version == candidate.version &&
          _sameDocumentChildren(original.document, candidate.document),
    AlnoteMigrationScope.objectPayload =>
      objectTarget != null &&
          original.version == candidate.version &&
          _sameObjectMigrationTree(
            original.document,
            candidate.document,
            objectTarget,
          ),
  };
}

bool _sameDocumentChildren(DocumentRoot left, DocumentRoot right) {
  if (left.runtimeType != right.runtimeType ||
      left.id != right.id ||
      left.resources != right.resources) {
    return false;
  }
  return switch ((left, right)) {
    (
      NotebookDocument(:final sections),
      NotebookDocument(sections: final otherSections),
    ) =>
      _sameValues(sections, otherSections),
    (
      StandalonePageDocument(:final page),
      StandalonePageDocument(page: final otherPage),
    ) =>
      page == otherPage,
    (
      StandalonePdfDocument(:final pages, :final source),
      StandalonePdfDocument(pages: final otherPages, source: final otherSource),
    ) =>
      source == otherSource && _sameValues(pages, otherPages),
    _ => false,
  };
}

bool _sameObjectMigrationTree(
  DocumentRoot left,
  DocumentRoot right,
  AlnoteObjectMigrationTarget target,
) {
  if (left.runtimeType != right.runtimeType ||
      left.id != right.id ||
      left.schemaVersion != right.schemaVersion ||
      left.title != right.title ||
      left.resources != right.resources ||
      left.extensionData != right.extensionData) {
    return false;
  }
  final leftSections = _sections(left);
  final rightSections = _sections(right);
  if (leftSections.length != rightSections.length) return false;
  for (var index = 0; index < leftSections.length; index += 1) {
    final leftSection = leftSections[index];
    final rightSection = rightSections[index];
    if (leftSection.id != rightSection.id ||
        leftSection.name != rightSection.name ||
        leftSection.extensionData != rightSection.extensionData ||
        !_sameValues(
          leftSection.pages.map((page) => page.id).toList(),
          rightSection.pages.map((page) => page.id).toList(),
        )) {
      return false;
    }
  }
  if (left case StandalonePdfDocument(:final source)) {
    if (right is! StandalonePdfDocument || source != right.source) return false;
  }
  final leftPages = left.pages;
  final rightPages = right.pages;
  if (leftPages.length != rightPages.length) return false;
  var targetCount = 0;
  for (var pageIndex = 0; pageIndex < leftPages.length; pageIndex += 1) {
    final leftPage = leftPages[pageIndex];
    final rightPage = rightPages[pageIndex];
    if (leftPage.id != rightPage.id ||
        leftPage.name != rightPage.name ||
        leftPage.size != rightPage.size ||
        leftPage.extensionData != rightPage.extensionData ||
        leftPage.layers.length != rightPage.layers.length) {
      return false;
    }
    for (
      var layerIndex = 0;
      layerIndex < leftPage.layers.length;
      layerIndex += 1
    ) {
      final leftLayer = leftPage.layers[layerIndex];
      final rightLayer = rightPage.layers[layerIndex];
      if (leftLayer.runtimeType != rightLayer.runtimeType ||
          leftLayer.id != rightLayer.id ||
          leftLayer.typeKey != rightLayer.typeKey ||
          leftLayer.envelopeVersion != rightLayer.envelopeVersion ||
          leftLayer.typeSchemaVersion != rightLayer.typeSchemaVersion ||
          leftLayer.name != rightLayer.name ||
          leftLayer.role != rightLayer.role ||
          leftLayer.visible != rightLayer.visible ||
          leftLayer.locked != rightLayer.locked ||
          leftLayer.opacity != rightLayer.opacity ||
          leftLayer.typeData != rightLayer.typeData ||
          leftLayer.extensionData != rightLayer.extensionData ||
          leftLayer.objects.length != rightLayer.objects.length) {
        return false;
      }
      for (
        var objectIndex = 0;
        objectIndex < leftLayer.objects.length;
        objectIndex += 1
      ) {
        final leftObject = leftLayer.objects[objectIndex];
        final rightObject = rightLayer.objects[objectIndex];
        if (leftObject.id != target.objectId) {
          if (leftObject != rightObject) return false;
          continue;
        }
        targetCount += 1;
        if (leftObject.typeKey != target.objectType ||
            rightObject.id != leftObject.id ||
            rightObject.typeKey != leftObject.typeKey ||
            rightObject.envelopeVersion != leftObject.envelopeVersion ||
            rightObject.transform != leftObject.transform ||
            rightObject.visible != leftObject.visible ||
            rightObject.locked != leftObject.locked ||
            rightObject.extensionData != leftObject.extensionData) {
          return false;
        }
      }
    }
  }
  return targetCount == 1;
}

ObjectEnvelope? _findObject(DocumentRoot document, ObjectId id) {
  for (final page in document.pages) {
    for (final layer in page.layers) {
      for (final object in layer.objects) {
        if (object.id == id) return object;
      }
    }
  }
  return null;
}

List<DocumentSection> _sections(DocumentRoot document) => switch (document) {
  NotebookDocument(:final sections) => sections,
  _ => const <DocumentSection>[],
};

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameValues<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _samePreservedMaps(
  Map<String, PreservedMap> left,
  Map<String, PreservedMap> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

PreservedInteger _preservedInteger(int value) =>
    (PreservedInteger.create(value) as Ok<PreservedInteger, StructuredFailure>)
        .value;

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
