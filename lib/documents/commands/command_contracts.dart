// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/identity/namespaced_identifier.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../model/document_root.dart';
import '../model/identifiers.dart';
import '../objects/object_envelope.dart';
import 'revision_snapshot.dart';

/// A stable lowercase namespaced command-family identity.
final class CommandFamily implements Comparable<CommandFamily> {
  /// Creates a family from an already validated identifier.
  const CommandFamily.fromIdentifier(this.identifier);

  /// Parses a command-family identity.
  static Result<CommandFamily, StructuredFailure> parse(String source) =>
      NamespacedIdentifier.parse(source).map(CommandFamily.fromIdentifier);

  /// The fixed Phase 3 Object-replacement family.
  static final CommandFamily objectReplacement = _trustedCommandFamily(
    'alnote.commands.object.replace',
  );

  /// The fixed Phase 3 whole-Object transform family.
  static final CommandFamily wholeObjectTransform = _trustedCommandFamily(
    'alnote.commands.object.transform',
  );

  /// The wrapped identifier.
  final NamespacedIdentifier identifier;

  /// The stable string value.
  String get value => identifier.value;

  @override
  int compareTo(CommandFamily other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) =>
      other is CommandFamily && other.identifier == identifier;
  @override
  int get hashCode => Object.hash(CommandFamily, identifier);
  @override
  String toString() => value;
}

/// UUID-backed correlation identity shared by related command activity.
final class CommandCorrelationId {
  /// Creates an identity from an AL NOTE UUID.
  const CommandCorrelationId.fromUuid(this.uuid);

  /// Generates an identity through [generator].
  static Result<CommandCorrelationId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(CommandCorrelationId.fromUuid);

  /// The wrapped UUID.
  final UuidIdentifier uuid;
  @override
  bool operator ==(Object other) =>
      other is CommandCorrelationId && other.uuid == uuid;
  @override
  int get hashCode => Object.hash(CommandCorrelationId, uuid);
  @override
  String toString() => 'CommandCorrelationId(${uuid.value})';
}

/// An explicit semantic merge-key identity.
final class CoalescingMergeKey {
  /// Creates a key from an already validated identifier.
  const CoalescingMergeKey.fromIdentifier(this.identifier);

  /// Parses an explicit merge key.
  static Result<CoalescingMergeKey, StructuredFailure> parse(String source) =>
      NamespacedIdentifier.parse(source).map(CoalescingMergeKey.fromIdentifier);

  /// The wrapped identifier.
  final NamespacedIdentifier identifier;

  /// The stable string value.
  String get value => identifier.value;
  @override
  bool operator ==(Object other) =>
      other is CoalescingMergeKey && other.identifier == identifier;
  @override
  int get hashCode => Object.hash(CoalescingMergeKey, identifier);
  @override
  String toString() => value;
}

/// UUID-backed identity for one explicit coalescing session.
final class CoalescingSessionId {
  /// Creates an identity from an AL NOTE UUID.
  const CoalescingSessionId.fromUuid(this.uuid);

  /// Generates a session identity through [generator].
  static Result<CoalescingSessionId, StructuredFailure> generate(
    UuidGenerator generator,
  ) => generator.generateV4().map(CoalescingSessionId.fromUuid);

  /// The wrapped UUID.
  final UuidIdentifier uuid;
  @override
  bool operator ==(Object other) =>
      other is CoalescingSessionId && other.uuid == uuid;
  @override
  int get hashCode => Object.hash(CoalescingSessionId, uuid);
  @override
  String toString() => 'CoalescingSessionId(${uuid.value})';
}

/// The only Phase 3 logical coalescing target: exactly one Object.
final class LogicalCoalescingTarget {
  /// Creates a typed Object target.
  const LogicalCoalescingTarget.object(this.objectId);

  /// The exact Object identity.
  final ObjectId objectId;
  @override
  bool operator ==(Object other) =>
      other is LogicalCoalescingTarget && other.objectId == objectId;
  @override
  int get hashCode => Object.hash(LogicalCoalescingTarget, objectId);
  @override
  String toString() => 'LogicalCoalescingTarget.object($objectId)';
}

/// The trusted source category of a published change.
enum CommandOrigin { user, undo, redo }

/// The only Phase 3 public execution category.
enum CommandPolicy { interactiveContentEdit }

/// An explicit event that prevents history coalescing across it.
enum CoalescingBoundary {
  saveCheckpoint,
  focusChange,
  selectionChange,
  structuralChange,
  editorSessionEnd,
}

/// Receives explicit semantic coalescing boundaries.
abstract interface class CoalescingBoundarySink {
  /// Establishes [boundary] for later command submissions.
  Result<void, StructuredFailure> establishCoalescingBoundary(
    CoalescingBoundary boundary,
  );
}

/// Required closed intent categories for an Object payload replacement.
final class ObjectReplacementChangeCategories {
  /// Creates declared payload-change categories.
  const ObjectReplacementChangeCategories({
    required this.appearance,
    required this.text,
    required this.metadata,
  });

  /// Whether appearance semantics changed.
  final bool appearance;

  /// Whether text semantics changed.
  final bool text;

  /// Whether metadata semantics changed.
  final bool metadata;

  @override
  bool operator ==(Object other) =>
      other is ObjectReplacementChangeCategories &&
      other.appearance == appearance &&
      other.text == text &&
      other.metadata == metadata;
  @override
  int get hashCode => Object.hash(appearance, text, metadata);
}

/// Complete explicit coalescing metadata for an eligible command.
final class CommandCoalescing {
  /// Creates explicit semantic coalescing metadata.
  const CommandCoalescing({
    required this.mergeKey,
    required this.sessionId,
    required this.logicalTarget,
  });

  /// The editor-owned merge policy key.
  final CoalescingMergeKey mergeKey;

  /// The explicit editor session.
  final CoalescingSessionId sessionId;

  /// The logical edited target.
  final LogicalCoalescingTarget logicalTarget;
  @override
  bool operator ==(Object other) =>
      other is CommandCoalescing &&
      other.mergeKey == mergeKey &&
      other.sessionId == sessionId &&
      other.logicalTarget == logicalTarget;
  @override
  int get hashCode => Object.hash(mergeKey, sessionId, logicalTarget);
}

/// Immutable common request metadata.
final class CommandMetadata {
  /// Creates metadata, explicitly exposing the intended consumer description.
  const CommandMetadata({
    required this.family,
    required this.correlationId,
    required this.description,
    this.coalescing,
  });

  /// The command family.
  final CommandFamily family;

  /// The correlation identity.
  final CommandCorrelationId correlationId;

  /// Sensitive user-visible descriptive text.
  final String description;

  /// Optional complete semantic coalescing metadata.
  final CommandCoalescing? coalescing;

  @override
  bool operator ==(Object other) =>
      other is CommandMetadata &&
      other.family == family &&
      other.correlationId == correlationId &&
      other.description == description &&
      other.coalescing == coalescing;
  @override
  int get hashCode =>
      Object.hash(family, correlationId, description, coalescing);
  @override
  String toString() =>
      'CommandMetadata(family: $family, correlation: $correlationId)';
}

/// A sealed immutable typed request to mutate exactly one document.
sealed class CommandRequest {
  const CommandRequest({
    required this.documentId,
    required this.metadata,
    required this.preconditions,
  });

  /// The only target document.
  final DocumentId documentId;

  /// Correlation and intended-consumer description data.
  final CommandMetadata metadata;

  /// Exactly the scoped revisions on which this request depends.
  final RevisionPreconditions preconditions;

  @override
  String toString() =>
      '$runtimeType(document: $documentId, family: ${metadata.family})';
}

/// An atomic ordered set of whole-Object replacements.
final class AtomicObjectReplacementRequest extends CommandRequest {
  AtomicObjectReplacementRequest._({
    required super.documentId,
    required super.metadata,
    required super.preconditions,
    required this.changeCategories,
    required List<ObjectId> targetIds,
    required List<ObjectEnvelope> replacements,
  }) : targetIds = List<ObjectId>.unmodifiable(targetIds),
       replacements = List<ObjectEnvelope>.unmodifiable(replacements);

  /// Creates a request after checking cardinality, uniqueness, and identity
  /// retention.
  static Result<AtomicObjectReplacementRequest, StructuredFailure> create({
    required DocumentId documentId,
    required CommandMetadata metadata,
    required RevisionPreconditions preconditions,
    required Iterable<ObjectId> targetIds,
    required Iterable<ObjectEnvelope> replacements,
    required ObjectReplacementChangeCategories changeCategories,
  }) {
    final targets = List<ObjectId>.of(targetIds);
    final values = List<ObjectEnvelope>.of(replacements);
    if (targets.isEmpty || targets.length != values.length) {
      return Err(_requestFailure('invalid_replacement_count'));
    }
    if (targets.toSet().length != targets.length) {
      return Err(_requestFailure('duplicate_target'));
    }
    if (metadata.family != CommandFamily.objectReplacement) {
      return Err(_requestFailure('invalid_command_family'));
    }
    final coalescing = metadata.coalescing;
    if (coalescing != null &&
        (targets.length != 1 ||
            coalescing.logicalTarget.objectId != targets.single)) {
      return Err(_requestFailure('invalid_coalescing_target'));
    }
    for (var index = 0; index < targets.length; index += 1) {
      if (targets[index] != values[index].id) {
        return Err(_requestFailure('identity_mismatch'));
      }
    }
    return Ok(
      AtomicObjectReplacementRequest._(
        documentId: documentId,
        metadata: metadata,
        preconditions: preconditions,
        changeCategories: changeCategories,
        targetIds: targets,
        replacements: values,
      ),
    );
  }

  /// Ordered unique target identities.
  final List<ObjectId> targetIds;

  /// Ordered replacements corresponding exactly to [targetIds].
  final List<ObjectEnvelope> replacements;

  /// Required declared payload semantics.
  final ObjectReplacementChangeCategories changeCategories;

  @override
  bool operator ==(Object other) =>
      other is AtomicObjectReplacementRequest &&
      other.documentId == documentId &&
      other.metadata == metadata &&
      other.preconditions == preconditions &&
      other.changeCategories == changeCategories &&
      _listEquals(other.targetIds, targetIds) &&
      _listEquals(other.replacements, replacements);
  @override
  int get hashCode => Object.hash(
    documentId,
    metadata,
    preconditions,
    changeCategories,
    Object.hashAll(targetIds),
    Object.hashAll(replacements),
  );
}

/// One atomic controlled page-space transform of whole Objects.
final class AtomicWholeObjectTransformRequest extends CommandRequest {
  AtomicWholeObjectTransformRequest._({
    required super.documentId,
    required super.metadata,
    required super.preconditions,
    required this.pageId,
    required List<ObjectId> targetIds,
    required this.operation,
  }) : targetIds = List<ObjectId>.unmodifiable(targetIds);

  /// Creates an atomic transform request with unique nonempty targets.
  static Result<AtomicWholeObjectTransformRequest, StructuredFailure> create({
    required DocumentId documentId,
    required CommandMetadata metadata,
    required RevisionPreconditions preconditions,
    required PageId pageId,
    required Iterable<ObjectId> targetIds,
    required TransformOperation2D operation,
  }) {
    final targets = List<ObjectId>.of(targetIds);
    if (targets.isEmpty) {
      return Err(_requestFailure('missing_target'));
    }
    if (targets.toSet().length != targets.length) {
      return Err(_requestFailure('duplicate_target'));
    }
    if (metadata.family != CommandFamily.wholeObjectTransform) {
      return Err(_requestFailure('invalid_command_family'));
    }
    if (metadata.coalescing != null) {
      return Err(_requestFailure('transform_coalescing_not_supported'));
    }
    if (operation is IdentityTransformOperation2D) {
      return Err(_requestFailure('no_change'));
    }
    return Ok(
      AtomicWholeObjectTransformRequest._(
        documentId: documentId,
        metadata: metadata,
        preconditions: preconditions,
        pageId: pageId,
        targetIds: targets,
        operation: operation,
      ),
    );
  }

  /// The only target Page.
  final PageId pageId;

  /// Ordered unique whole-Object targets.
  final List<ObjectId> targetIds;

  /// The controlled Phase 1 operation; raw matrices cannot enter this request.
  final TransformOperation2D operation;

  @override
  bool operator ==(Object other) =>
      other is AtomicWholeObjectTransformRequest &&
      other.documentId == documentId &&
      other.metadata == metadata &&
      other.preconditions == preconditions &&
      other.pageId == pageId &&
      _listEquals(other.targetIds, targetIds) &&
      other.operation == operation;
  @override
  int get hashCode => Object.hash(
    documentId,
    metadata,
    preconditions,
    pageId,
    Object.hashAll(targetIds),
    operation,
  );
}

/// Closed flags describing the nature of a committed content change.
final class CommittedChangeFlags {
  /// Creates an immutable flag set.
  const CommittedChangeFlags({
    this.geometry = false,
    this.appearance = false,
    this.text = false,
    this.structure = false,
    this.resources = false,
    this.metadata = false,
  });

  /// Geometry changed.
  final bool geometry;

  /// Appearance changed.
  final bool appearance;

  /// Text changed.
  final bool text;

  /// Structure changed.
  final bool structure;

  /// Resource references changed.
  final bool resources;

  /// Metadata changed.
  final bool metadata;

  @override
  bool operator ==(Object other) =>
      other is CommittedChangeFlags &&
      other.geometry == geometry &&
      other.appearance == appearance &&
      other.text == text &&
      other.structure == structure &&
      other.resources == resources &&
      other.metadata == metadata;

  @override
  int get hashCode =>
      Object.hash(geometry, appearance, text, structure, resources, metadata);
}

/// Immutable, deterministic committed-change evidence.
final class CommittedChange {
  /// Creates change evidence and deterministically orders all identity sets.
  CommittedChange({
    required this.documentId,
    required this.previousRevision,
    required this.newRevision,
    required this.origin,
    required this.family,
    required this.description,
    required this.correlationId,
    Iterable<ObjectId> addedObjectIds = const [],
    Iterable<ObjectId> removedObjectIds = const [],
    Iterable<ObjectId> replacedObjectIds = const [],
    Iterable<ObjectId> movedObjectIds = const [],
    Iterable<PageId> affectedPageIds = const [],
    Iterable<LayerId> affectedLayerIds = const [],
    this.membershipChanged = false,
    this.orderChanged = false,
    Iterable<ResourceIdentity> addedResourceReferences = const [],
    Iterable<ResourceIdentity> removedResourceReferences = const [],
    this.oldBounds,
    this.newBounds,
    this.flags = const CommittedChangeFlags(),
    required this.historyRecorded,
    required this.savedCheckpointChanged,
  }) : addedObjectIds = _sortedIds(addedObjectIds),
       removedObjectIds = _sortedIds(removedObjectIds),
       replacedObjectIds = _sortedIds(replacedObjectIds),
       movedObjectIds = _sortedIds(movedObjectIds),
       affectedPageIds = _sortedIds(affectedPageIds),
       affectedLayerIds = _sortedIds(affectedLayerIds),
       addedResourceReferences = _sortedIds(addedResourceReferences),
       removedResourceReferences = _sortedIds(removedResourceReferences);

  /// The changed document.
  final DocumentId documentId;

  /// The prior global revision.
  final Revision previousRevision;

  /// The published global revision.
  final Revision newRevision;

  /// The publication origin.
  final CommandOrigin origin;

  /// The semantic command family.
  final CommandFamily family;

  /// Sensitive user-visible description, explicitly available to consumers.
  final String description;

  /// The correlation identity.
  final CommandCorrelationId correlationId;

  /// Added Object identities.
  final List<ObjectId> addedObjectIds;

  /// Removed Object identities.
  final List<ObjectId> removedObjectIds;

  /// Replaced Object identities.
  final List<ObjectId> replacedObjectIds;

  /// Moved Object identities.
  final List<ObjectId> movedObjectIds;

  /// Affected Pages.
  final List<PageId> affectedPageIds;

  /// Affected Layers.
  final List<LayerId> affectedLayerIds;

  /// Whether structural membership changed.
  final bool membershipChanged;

  /// Whether authoritative ordering changed.
  final bool orderChanged;

  /// Newly referenced resources.
  final List<ResourceIdentity> addedResourceReferences;

  /// No-longer-referenced resources.
  final List<ResourceIdentity> removedResourceReferences;

  /// Optional old page-space damage bounds.
  final Rect2? oldBounds;

  /// Optional new page-space damage bounds.
  final Rect2? newBounds;

  /// Closed change-category flags.
  final CommittedChangeFlags flags;

  /// Whether undo history was retained.
  final bool historyRecorded;

  /// Whether the saved checkpoint itself changed.
  final bool savedCheckpointChanged;

  @override
  String toString() =>
      'CommittedChange(document: $documentId, revision: $newRevision, '
      'family: $family, origin: $origin)';
}

/// Safe evidence returned after a successful publication.
final class CommandCommit {
  /// Creates commit evidence.
  const CommandCommit({
    required this.change,
    required this.observerFailureCount,
  });

  /// The one published change description.
  final CommittedChange change;

  /// Count of observers that threw, without exception contents.
  final int observerFailureCount;
}

/// A redaction-safe structured command failure.
final class CommandFailure {
  /// Creates a command failure.
  factory CommandFailure({
    required String code,
    required FailureCategory category,
    Iterable<StaleRevisionEvidence> staleEvidence = const [],
  }) {
    if (!_failureCodePattern.hasMatch(code)) {
      throw ArgumentError.value(
        code,
        'code',
        'must be a stable namespaced code',
      );
    }
    return CommandFailure._(
      code: code,
      category: category,
      staleEvidence: List<StaleRevisionEvidence>.unmodifiable(
        List<StaleRevisionEvidence>.of(staleEvidence)..sort(),
      ),
    );
  }

  const CommandFailure._({
    required this.code,
    required this.category,
    required this.staleEvidence,
  });

  /// Stable namespaced failure code.
  final String code;

  /// Broad failure category.
  final FailureCategory category;

  /// Deterministically ordered typed stale evidence.
  final List<StaleRevisionEvidence> staleEvidence;
  @override
  bool operator ==(Object other) =>
      other is CommandFailure &&
      other.code == code &&
      other.category == category &&
      _listEquals(other.staleEvidence, staleEvidence);
  @override
  int get hashCode =>
      Object.hash(code, category, Object.hashAll(staleEvidence));
  @override
  String toString() => 'CommandFailure($code)';
}

/// A retained history cost expressed explicitly in estimated bytes.
final class HistoryRetainedCost {
  const HistoryRetainedCost._(this.estimatedBytes);

  /// Creates a nonnegative Web-safe retained cost.
  static Result<HistoryRetainedCost, StructuredFailure> create(int bytes) {
    if (bytes < 0 || bytes > Revision.maximumValue) {
      return Err(_requestFailure('invalid_history_cost'));
    }
    return Ok(HistoryRetainedCost._(bytes));
  }

  /// Estimated retained bytes, excluding copied resource blobs.
  final int estimatedBytes;
  @override
  bool operator ==(Object other) =>
      other is HistoryRetainedCost && other.estimatedBytes == estimatedBytes;
  @override
  int get hashCode => Object.hash(HistoryRetainedCost, estimatedBytes);
}

/// Mandatory caller-supplied history limits with explicit units.
final class HistoryLimits {
  const HistoryLimits._({
    required this.maximumRetainedCommandCount,
    required this.maximumEstimatedRetainedBytes,
  });

  /// Creates strictly positive Web-safe limits.
  static Result<HistoryLimits, StructuredFailure> create({
    required int maximumRetainedCommandCount,
    required int maximumEstimatedRetainedBytes,
  }) {
    if (maximumRetainedCommandCount < 0 ||
        maximumRetainedCommandCount > Revision.maximumValue ||
        maximumEstimatedRetainedBytes < 0 ||
        maximumEstimatedRetainedBytes > Revision.maximumValue) {
      return Err(_requestFailure('invalid_history_limits'));
    }
    return Ok(
      HistoryLimits._(
        maximumRetainedCommandCount: maximumRetainedCommandCount,
        maximumEstimatedRetainedBytes: maximumEstimatedRetainedBytes,
      ),
    );
  }

  /// Maximum combined Undo/Redo entry count.
  final int maximumRetainedCommandCount;

  /// Maximum combined estimated retained bytes.
  final int maximumEstimatedRetainedBytes;
}

/// Immutable values supplied to a retained-cost estimator.
final class HistoryCostEstimateInput {
  /// Creates estimator input containing no resource bytes.
  const HistoryCostEstimateInput({
    required this.beforeRoot,
    required this.afterRoot,
    required this.replacedObjectCount,
  });

  /// Exact before root.
  final DocumentRoot beforeRoot;

  /// Exact after root.
  final DocumentRoot afterRoot;

  /// Number of retained replacement targets.
  final int replacedObjectCount;
}

/// Injected AL NOTE-owned history retained-cost estimator.
abstract interface class HistoryRetainedCostEstimator {
  /// Estimates structurally retained bytes without copying resource bytes.
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  );
}

StructuredFailure _requestFailure(String leaf) => StructuredFailure(
  code: 'documents.commands.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'The command request is not valid.',
);

List<T> _sortedIds<T>(Iterable<T> values) {
  final result = values.toSet().toList();
  result.sort((left, right) => _idText(left).compareTo(_idText(right)));
  return List<T>.unmodifiable(result);
}

String _idText(Object? value) => switch (value) {
  DocumentId(:final uuid) ||
  SectionId(:final uuid) ||
  PageId(:final uuid) ||
  LayerId(:final uuid) ||
  ObjectId(:final uuid) ||
  ResourceIdentity(:final uuid) => uuid.value,
  _ => value.toString(),
};

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final RegExp _failureCodePattern = RegExp(
  r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$',
);

CommandFamily _trustedCommandFamily(String source) =>
    CommandFamily.parse(source).fold(
      onOk: (value) => value,
      onErr: (_) => throw StateError('Invalid trusted Command family.'),
    );
