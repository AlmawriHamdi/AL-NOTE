// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/identity/namespaced_identifier.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../documents/commands.dart';
import '../../documents/document_model.dart';

/// A stable namespaced kind for a future selectable sub-target.
final class SelectionSubTargetKind {
  /// Creates a kind from an already validated identifier.
  const SelectionSubTargetKind.fromIdentifier(this.identifier);

  /// Parses a stable kind.
  static Result<SelectionSubTargetKind, StructuredFailure> parse(
    String source,
  ) => NamespacedIdentifier.parse(
    source,
  ).map(SelectionSubTargetKind.fromIdentifier);

  /// The wrapped identifier.
  final NamespacedIdentifier identifier;

  /// Stable string value.
  String get value => identifier.value;
  @override
  bool operator ==(Object other) =>
      other is SelectionSubTargetKind && other.identifier == identifier;
  @override
  int get hashCode => Object.hash(SelectionSubTargetKind, identifier);
  @override
  String toString() => value;
}

/// UUID-backed stable identity of a sub-target within one Object.
final class SelectionSubTargetId {
  /// Creates an identity from an AL NOTE UUID.
  const SelectionSubTargetId.fromUuid(this.uuid);

  /// The wrapped UUID.
  final UuidIdentifier uuid;
  @override
  bool operator ==(Object other) =>
      other is SelectionSubTargetId && other.uuid == uuid;
  @override
  int get hashCode => Object.hash(SelectionSubTargetId, uuid);
  @override
  String toString() => 'SelectionSubTargetId(${uuid.value})';
}

/// Temporary identity of a whole Object or declared stable sub-target.
final class SelectionTarget {
  const SelectionTarget._({
    required this.pageId,
    required this.objectId,
    required this.subTargetKind,
    required this.subTargetId,
  });

  /// Creates a whole-Object selection target.
  const SelectionTarget.wholeObject({
    required this.pageId,
    required this.objectId,
  }) : subTargetKind = null,
       subTargetId = null;

  /// Creates a sub-target only when both kind and identity are present.
  static Result<SelectionTarget, StructuredFailure> subTarget({
    required PageId pageId,
    required ObjectId objectId,
    required SelectionSubTargetKind kind,
    required SelectionSubTargetId id,
  }) => Ok(
    SelectionTarget._(
      pageId: pageId,
      objectId: objectId,
      subTargetKind: kind,
      subTargetId: id,
    ),
  );

  /// Page containing the target.
  final PageId pageId;

  /// Containing Object identity.
  final ObjectId objectId;

  /// Optional stable sub-target kind.
  final SelectionSubTargetKind? subTargetKind;

  /// Optional stable sub-target identity.
  final SelectionSubTargetId? subTargetId;

  /// Whether this is the executable Phase 3 whole-Object form.
  bool get isWholeObject => subTargetKind == null && subTargetId == null;
  @override
  bool operator ==(Object other) =>
      other is SelectionTarget &&
      other.pageId == pageId &&
      other.objectId == objectId &&
      other.subTargetKind == subTargetKind &&
      other.subTargetId == subTargetId;
  @override
  int get hashCode => Object.hash(pageId, objectId, subTargetKind, subTargetId);
  @override
  String toString() =>
      'SelectionTarget(page: $pageId, object: $objectId, '
      'wholeObject: $isWholeObject)';
}

/// Closed Phase 3 temporary selection mode.
enum SelectionOperationMode { wholeObject }

/// Redaction-safe temporary Selection failure.
final class SelectionFailure {
  /// Creates a stable Selection failure.
  factory SelectionFailure(String code, FailureCategory category) {
    if (!_selectionFailureCodePattern.hasMatch(code)) {
      throw ArgumentError.value(
        code,
        'code',
        'must be a stable namespaced code',
      );
    }
    return SelectionFailure._(code, category);
  }

  const SelectionFailure._(this.code, this.category);

  /// Stable namespaced code.
  final String code;

  /// Broad failure category.
  final FailureCategory category;
  @override
  bool operator ==(Object other) =>
      other is SelectionFailure &&
      other.code == code &&
      other.category == category;
  @override
  int get hashCode => Object.hash(code, category);
  @override
  String toString() => 'SelectionFailure($code)';
}

final RegExp _selectionFailureCodePattern = RegExp(
  r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$',
);

/// Immutable transform candidate built entirely outside document state.
final class WholeObjectTransformPreview {
  WholeObjectTransformPreview._({
    required this.documentId,
    required this.pageId,
    required Iterable<ObjectId> targetIds,
    required this.operation,
    required Map<ObjectId, ObjectEnvelope> baseObjects,
    required Map<ObjectId, ObjectEnvelope> candidateObjects,
    required this.preconditions,
    required this.oldBounds,
    required this.newBounds,
  }) : targetIds = List<ObjectId>.unmodifiable(targetIds),
       baseObjects = UnmodifiableMapView(Map.of(baseObjects)),
       candidateObjects = UnmodifiableMapView(Map.of(candidateObjects));

  /// Validates and creates an immutable transform preview.
  static Result<WholeObjectTransformPreview, SelectionFailure> create({
    required DocumentId documentId,
    required PageId pageId,
    required Iterable<ObjectId> targetIds,
    required TransformOperation2D operation,
    required Map<ObjectId, ObjectEnvelope> baseObjects,
    required Map<ObjectId, ObjectEnvelope> candidateObjects,
    required RevisionPreconditions preconditions,
    required Rect2 oldBounds,
    required Rect2 newBounds,
  }) {
    final targets = List<ObjectId>.of(targetIds);
    if (targets.isEmpty || targets.toSet().length != targets.length) {
      return Err(_selectionContractFailure('invalid_preview_targets'));
    }
    if (operation is IdentityTransformOperation2D ||
        baseObjects.length != targets.length ||
        candidateObjects.length != targets.length ||
        !baseObjects.keys.toSet().containsAll(targets) ||
        !candidateObjects.keys.toSet().containsAll(targets) ||
        !preconditions.pages.containsKey(pageId) ||
        targets.any((id) => !preconditions.objects.containsKey(id))) {
      return Err(_selectionContractFailure('invalid_preview_state'));
    }
    final affine = AffineTransform2D.fromOperation(
      operation,
    ).fold(onOk: (value) => value, onErr: (_) => null);
    if (affine == null) {
      return Err(_selectionContractFailure('invalid_preview_transform'));
    }
    var changed = false;
    for (final id in targets) {
      final base = baseObjects[id];
      final candidate = candidateObjects[id];
      if (base == null ||
          candidate == null ||
          base.id != id ||
          candidate.id != id ||
          !_sameExceptTransform(base, candidate)) {
        return Err(_selectionContractFailure('invalid_preview_candidate'));
      }
      final expected = base.transform
          .then(affine)
          .fold(onOk: (value) => value, onErr: (_) => null);
      if (expected == null || candidate.transform != expected) {
        return Err(_selectionContractFailure('invalid_preview_candidate'));
      }
      changed = changed || candidate != base;
    }
    if (!changed) return Err(_selectionContractFailure('no_change'));
    return Ok(
      WholeObjectTransformPreview._(
        documentId: documentId,
        pageId: pageId,
        targetIds: targets,
        operation: operation,
        baseObjects: baseObjects,
        candidateObjects: candidateObjects,
        preconditions: preconditions,
        oldBounds: oldBounds,
        newBounds: newBounds,
      ),
    );
  }

  /// Target document.
  final DocumentId documentId;

  /// One active Page.
  final PageId pageId;

  /// Ordered unique whole-Object identities.
  final List<ObjectId> targetIds;

  /// Controlled page-space operation.
  final TransformOperation2D operation;

  /// Captured exact base Objects.
  final Map<ObjectId, ObjectEnvelope> baseObjects;

  /// Immutable candidate Objects.
  final Map<ObjectId, ObjectEnvelope> candidateObjects;

  /// Required scoped revision snapshot.
  final RevisionPreconditions preconditions;

  /// Aggregate old page-space bounds.
  final Rect2 oldBounds;

  /// Aggregate candidate page-space bounds.
  final Rect2 newBounds;

  /// Creates the one atomic command request for this valid preview.
  Result<AtomicWholeObjectTransformRequest, StructuredFailure> commandRequest(
    CommandMetadata metadata,
  ) => AtomicWholeObjectTransformRequest.create(
    documentId: documentId,
    metadata: metadata,
    preconditions: preconditions,
    pageId: pageId,
    targetIds: targetIds,
    operation: operation,
  );

  @override
  String toString() =>
      'WholeObjectTransformPreview(document: $documentId, '
      'targets: ${targetIds.length})';
}

/// Immutable temporary page-scoped Selection state.
final class SelectionState {
  SelectionState._({
    required this.activePageId,
    required Iterable<SelectionTarget> targets,
    required this.primaryTarget,
    required this.revision,
    required this.operationMode,
    required Map<ObjectId, LayerId> layerMembership,
    required this.aggregateBounds,
    required this.transformPreview,
  }) : targets = List<SelectionTarget>.unmodifiable(targets),
       layerMembership = UnmodifiableMapView(Map.of(layerMembership));

  /// Creates a valid empty Selection at [revision].
  static SelectionState empty(Revision revision) => SelectionState._(
    activePageId: null,
    targets: const [],
    primaryTarget: null,
    revision: revision,
    operationMode: SelectionOperationMode.wholeObject,
    layerMembership: const {},
    aggregateBounds: null,
    transformPreview: null,
  );

  /// Validates and creates immutable Selection state.
  static Result<SelectionState, SelectionFailure> create({
    required PageId? activePageId,
    required Iterable<SelectionTarget> targets,
    required SelectionTarget? primaryTarget,
    required Revision revision,
    required SelectionOperationMode operationMode,
    required Map<ObjectId, LayerId> layerMembership,
    required Rect2? aggregateBounds,
    required WholeObjectTransformPreview? transformPreview,
  }) {
    final copied = List<SelectionTarget>.of(targets);
    final empty = copied.isEmpty;
    if (copied.toSet().length != copied.length ||
        (activePageId == null) != empty ||
        (primaryTarget == null) != empty ||
        (!empty && !copied.contains(primaryTarget)) ||
        copied.any((target) => target.pageId != activePageId)) {
      return Err(_selectionContractFailure('invalid_selection_state'));
    }
    final wholeIds = copied
        .where((target) => target.isWholeObject)
        .map((target) => target.objectId)
        .toSet();
    if (layerMembership.keys.toSet().length != layerMembership.length ||
        !_setEquals(layerMembership.keys.toSet(), wholeIds) ||
        (!empty && aggregateBounds == null) ||
        (empty && (aggregateBounds != null || transformPreview != null))) {
      return Err(_selectionContractFailure('invalid_selection_derived_state'));
    }
    final preview = transformPreview;
    if (preview != null &&
        (copied.any((target) => !target.isWholeObject) ||
            preview.pageId != activePageId ||
            !_listEquals(
              preview.targetIds,
              copied.map((target) => target.objectId).toList(),
            ))) {
      return Err(_selectionContractFailure('invalid_selection_preview'));
    }
    return Ok(
      SelectionState._(
        activePageId: activePageId,
        targets: copied,
        primaryTarget: primaryTarget,
        revision: revision,
        operationMode: operationMode,
        layerMembership: layerMembership,
        aggregateBounds: aggregateBounds,
        transformPreview: transformPreview,
      ),
    );
  }

  /// Active Page, or null for empty Selection.
  final PageId? activePageId;

  /// Ordered unique targets.
  final List<SelectionTarget> targets;

  /// Primary target, always one member when non-null.
  final SelectionTarget? primaryTarget;

  /// Monotonic temporary revision.
  final Revision revision;

  /// Current closed operation mode.
  final SelectionOperationMode operationMode;

  /// Derived target-to-Layer membership.
  final Map<ObjectId, LayerId> layerMembership;

  /// Derived aggregate page-space bounds.
  final Rect2? aggregateBounds;

  /// Optional immutable transform preview.
  final WholeObjectTransformPreview? transformPreview;

  /// Whether no targets are selected.
  bool get isEmpty => targets.isEmpty;
  @override
  String toString() =>
      'SelectionState(page: $activePageId, targets: ${targets.length}, '
      'revision: $revision)';
}

bool _sameExceptTransform(ObjectEnvelope left, ObjectEnvelope right) =>
    left.id == right.id &&
    left.typeKey == right.typeKey &&
    left.envelopeVersion == right.envelopeVersion &&
    left.typeSchemaVersion == right.typeSchemaVersion &&
    left.visible == right.visible &&
    left.locked == right.locked &&
    left.payload == right.payload &&
    left.extensionData == right.extensionData;

bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

SelectionFailure _selectionContractFailure(String leaf) =>
    SelectionFailure('drawing.selection.$leaf', FailureCategory.validation);
