// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../documents/commands.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../geometry.dart';
import 'selection_contracts.dart';

/// Owns one view's temporary page-scoped editable Selection.
final class SelectionController {
  /// Creates an empty controller using injected Registry and boundary sink.
  SelectionController({
    required ObjectRegistry objectRegistry,
    required CoalescingBoundarySink coalescingBoundarySink,
    this.maximumTargets = Revision.maximumValue,
    this.handwritingLimits,
    this.strokeGeometryResolver,
    Revision? initialRevision,
  }) : _registry = objectRegistry,
       _boundarySink = coalescingBoundarySink,
       _state = SelectionState.empty(initialRevision ?? _zeroRevision);

  final ObjectRegistry _registry;
  final CoalescingBoundarySink _boundarySink;

  /// Maximum targets captured by one operation.
  final int maximumTargets;

  /// Decode limits required for Handwriting Stroke targets.
  final HandwritingLimits? handwritingLimits;

  /// Shared geometry required for exact Stroke bounds.
  final StrokeGeometryResolver? strokeGeometryResolver;
  SelectionState _state;
  DocumentCoordinatorSnapshot? _previewBase;

  /// Current immutable temporary state.
  SelectionState get state => _state;

  /// Replaces Selection with [targets] in their supplied order.
  Result<SelectionState, SelectionFailure> replace({
    required DocumentRoot root,
    required Iterable<SelectionTarget> targets,
    SelectionTarget? primaryTarget,
  }) {
    final captured = _captureTargets(targets);
    if (captured == null) return Err(_selectionFailure('target_limit'));
    return _setTargets(
      root: root,
      proposed: captured,
      primary: primaryTarget,
      rejectIneligible: true,
    );
  }

  /// Adds unique [targets] after existing targets.
  Result<SelectionState, SelectionFailure> add({
    required DocumentRoot root,
    required Iterable<SelectionTarget> targets,
    SelectionTarget? primaryTarget,
  }) {
    final additions = _captureTargets(targets);
    if (additions == null) return Err(_selectionFailure('target_limit'));
    if (additions.toSet().length != additions.length) {
      return Err(_selectionFailure('duplicate_target'));
    }
    return _setTargets(
      root: root,
      proposed: [
        ..._state.targets,
        ...additions.where((t) => !_state.targets.contains(t)),
      ],
      primary: primaryTarget ?? _state.primaryTarget,
      rejectIneligible: true,
    );
  }

  /// Removes [targets], preserving relative order of remaining targets.
  Result<SelectionState, SelectionFailure> remove({
    required DocumentRoot root,
    required Iterable<SelectionTarget> targets,
  }) {
    final removals = _captureTargets(targets);
    if (removals == null) return Err(_selectionFailure('target_limit'));
    if (removals.toSet().length != removals.length) {
      return Err(_selectionFailure('duplicate_target'));
    }
    final proposed = _state.targets
        .where((target) => !removals.contains(target))
        .toList();
    return _setTargets(
      root: root,
      proposed: proposed,
      primary: proposed.contains(_state.primaryTarget)
          ? _state.primaryTarget
          : (proposed.isEmpty ? null : proposed.first),
      rejectIneligible: false,
    );
  }

  /// Toggles [targets] deterministically in supplied order.
  Result<SelectionState, SelectionFailure> toggle({
    required DocumentRoot root,
    required Iterable<SelectionTarget> targets,
  }) {
    final toggles = _captureTargets(targets);
    if (toggles == null) return Err(_selectionFailure('target_limit'));
    if (toggles.toSet().length != toggles.length) {
      return Err(_selectionFailure('duplicate_target'));
    }
    final proposed = List<SelectionTarget>.of(_state.targets);
    for (final target in toggles) {
      proposed.contains(target)
          ? proposed.remove(target)
          : proposed.add(target);
    }
    return _setTargets(
      root: root,
      proposed: proposed,
      primary: proposed.contains(_state.primaryTarget)
          ? _state.primaryTarget
          : (proposed.isEmpty ? null : proposed.last),
      rejectIneligible: true,
    );
  }

  /// Clears Selection if it is nonempty or has an active preview.
  Result<SelectionState, SelectionFailure> clear() {
    if (_state.targets.isEmpty && _state.transformPreview == null)
      return Ok(_state);
    return _publishState(
      activePageId: null,
      targets: const [],
      primary: null,
      memberships: const {},
      bounds: null,
      preview: null,
      createBoundary: true,
    );
  }

  /// Reconciles temporary targets against the latest immutable document root.
  Result<SelectionState, SelectionFailure> reconcile(DocumentRoot root) =>
      _setTargets(
        root: root,
        proposed: _state.targets,
        primary: _state.primaryTarget,
        rejectIneligible: false,
      );

  /// Starts a validated immutable whole-Object transform preview.
  Result<SelectionState, SelectionFailure> beginTransform({
    required DocumentCoordinatorSnapshot document,
    required TransformOperation2D operation,
  }) {
    if (_state.targets.isEmpty ||
        _state.targets.any((target) => !target.isWholeObject)) {
      return Err(_selectionFailure('unsupported_sub_target'));
    }
    final preview = _buildPreview(document, operation);
    return preview.fold(
      onOk: (value) {
        final next = SelectionState.create(
          activePageId: _state.activePageId,
          targets: _state.targets,
          primaryTarget: _state.primaryTarget,
          revision: _state.revision,
          operationMode: _state.operationMode,
          layerMembership: _state.layerMembership,
          aggregateBounds: _state.aggregateBounds,
          transformPreview: value,
        );
        final failure = next.fold<SelectionFailure?>(
          onOk: (_) => null,
          onErr: (error) => error,
        );
        if (failure != null) return Err(failure);
        _state = (next as Ok<SelectionState, SelectionFailure>).value;
        _previewBase = document;
        return Ok(_state);
      },
      onErr: Err<SelectionState, SelectionFailure>.new,
    );
  }

  /// Replaces the active preview with another valid operation based on the same
  /// captured document state. Failure retains the last valid preview.
  Result<SelectionState, SelectionFailure> updateTransform(
    DocumentCoordinatorSnapshot _,
    TransformOperation2D operation,
  ) {
    final base = _previewBase;
    if (_state.transformPreview == null || base == null) {
      return Err(_selectionFailure('missing_preview'));
    }
    final preview = _buildPreview(base, operation);
    return preview.fold(
      onOk: (value) {
        final next = SelectionState.create(
          activePageId: _state.activePageId,
          targets: _state.targets,
          primaryTarget: _state.primaryTarget,
          revision: _state.revision,
          operationMode: _state.operationMode,
          layerMembership: _state.layerMembership,
          aggregateBounds: _state.aggregateBounds,
          transformPreview: value,
        );
        final failure = next.fold<SelectionFailure?>(
          onOk: (_) => null,
          onErr: (error) => error,
        );
        if (failure != null) return Err(failure);
        _state = (next as Ok<SelectionState, SelectionFailure>).value;
        return Ok(_state);
      },
      onErr: Err<SelectionState, SelectionFailure>.new,
    );
  }

  /// Cancels the active preview without changing persistent document state.
  SelectionState cancelTransform() {
    if (_state.transformPreview == null) return _state;
    _previewBase = null;
    _state = _trustedSelectionState(
      activePageId: _state.activePageId,
      targets: _state.targets,
      primaryTarget: _state.primaryTarget,
      revision: _state.revision,
      operationMode: _state.operationMode,
      layerMembership: _state.layerMembership,
      aggregateBounds: _state.aggregateBounds,
      transformPreview: null,
    );
    return _state;
  }

  Result<WholeObjectTransformPreview, SelectionFailure> _buildPreview(
    DocumentCoordinatorSnapshot document,
    TransformOperation2D operation,
  ) {
    final activePageId = _state.activePageId;
    if (document.root.id != document.revisions.documentId ||
        activePageId == null ||
        !document.revisions.pages.containsKey(activePageId)) {
      return Err(_selectionFailure('inconsistent_document_state'));
    }
    final affine = AffineTransform2D.fromOperation(
      operation,
    ).fold(onOk: (value) => value, onErr: (_) => null);
    if (affine == null) return Err(_selectionFailure('invalid_transform'));
    final page = document.root.pages
        .where((page) => page.id == activePageId)
        .singleOrNull;
    if (page == null) {
      return Err(_selectionFailure('inconsistent_document_state'));
    }
    final base = <ObjectId, ObjectEnvelope>{};
    final candidates = <ObjectId, ObjectEnvelope>{};
    final targetMembership = <ObjectId, LayerId>{};
    final objectRevisions = <ObjectId, Revision>{};
    final membershipRevisions = <LayerId, Revision>{};
    for (final target in _state.targets) {
      if (!document.revisions.objects.containsKey(target.objectId)) {
        return Err(_selectionFailure('inconsistent_document_state'));
      }
      DocumentLayer? owningLayer;
      for (final layer in page.layers) {
        if (layer.objects.any((object) => object.id == target.objectId)) {
          if (owningLayer != null) {
            return Err(_selectionFailure('inconsistent_document_state'));
          }
          owningLayer = layer;
        }
      }
      if (owningLayer == null ||
          _state.layerMembership[target.objectId] != owningLayer.id ||
          !document.revisions.layerMembership.containsKey(owningLayer.id)) {
        return Err(_selectionFailure('inconsistent_document_state'));
      }
      final resolved = _resolve(page, document.root.resources, target);
      if (resolved == null || !_supports(resolved.resolution, operation)) {
        return Err(_selectionFailure('transform_capability_denied'));
      }
      final transform = resolved.object.transform
          .then(affine)
          .fold(onOk: (value) => value, onErr: (_) => null);
      if (transform == null) return Err(_selectionFailure('invalid_transform'));
      final replacement = ObjectEnvelope.create(
        id: resolved.object.id,
        typeKey: resolved.object.typeKey,
        envelopeVersion: resolved.object.envelopeVersion,
        typeSchemaVersion: resolved.object.typeSchemaVersion,
        transform: transform,
        visible: resolved.object.visible,
        locked: resolved.object.locked,
        payload: resolved.object.payload,
        extensionData: resolved.object.extensionData,
      ).fold(onOk: (value) => value, onErr: (_) => null);
      if (replacement == null || !_reachable(page, replacement)) {
        return Err(_selectionFailure('transform_unreachable'));
      }
      base[target.objectId] = resolved.object;
      candidates[target.objectId] = replacement;
      targetMembership[target.objectId] = resolved.layer.id;
      objectRevisions[target.objectId] =
          document.revisions.objects[target.objectId]!;
      membershipRevisions[resolved.layer.id] =
          document.revisions.layerMembership[resolved.layer.id]!;
    }
    final oldBounds = _aggregateBounds(base.values);
    final newBounds = _aggregateBounds(candidates.values);
    if (oldBounds == null || newBounds == null) {
      return Err(_selectionFailure('geometry_unavailable'));
    }
    return WholeObjectTransformPreview.create(
      documentId: document.root.id,
      pageId: page.id,
      targetIds: _state.targets.map((target) => target.objectId),
      operation: operation,
      baseObjects: base,
      candidateObjects: candidates,
      targetLayerMembership: targetMembership,
      preconditions: RevisionPreconditions(
        pages: {page.id: document.revisions.pages[page.id]!},
        layerMembership: membershipRevisions,
        objects: objectRevisions,
      ),
      oldBounds: oldBounds,
      newBounds: newBounds,
    );
  }

  Result<SelectionState, SelectionFailure> _setTargets({
    required DocumentRoot root,
    required List<SelectionTarget> proposed,
    required SelectionTarget? primary,
    required bool rejectIneligible,
  }) {
    if (maximumTargets < 0 ||
        maximumTargets > Revision.maximumValue ||
        proposed.length > maximumTargets ||
        proposed.toSet().length != proposed.length) {
      return Err(_selectionFailure('duplicate_target'));
    }
    final pageIds = proposed.map((target) => target.pageId).toSet();
    if (pageIds.length > 1)
      return Err(_selectionFailure('cross_page_selection'));
    if (primary != null && !proposed.contains(primary)) {
      return Err(_selectionFailure('primary_not_selected'));
    }
    final page = pageIds.isEmpty
        ? null
        : root.pages.where((page) => page.id == pageIds.single).singleOrNull;
    if (page == null && proposed.isNotEmpty && rejectIneligible) {
      return Err(_selectionFailure('page_unavailable'));
    }
    final accepted = <SelectionTarget>[];
    final memberships = <ObjectId, LayerId>{};
    for (final target in proposed) {
      final resolved = page == null
          ? null
          : _resolve(page, root.resources, target);
      if (resolved == null) {
        if (rejectIneligible)
          return Err(_selectionFailure('target_not_selectable'));
        continue;
      }
      accepted.add(target);
      memberships[target.objectId] = resolved.layer.id;
    }
    final resolvedPrimary = accepted.contains(primary)
        ? primary
        : (accepted.isEmpty ? null : accepted.first);
    final resolvedBounds = <Rect2>[];
    for (final target in accepted) {
      final resolved = _resolve(page!, root.resources, target);
      if (resolved == null)
        return Err(_selectionFailure('target_not_selectable'));
      resolvedBounds.add(resolved.bounds);
    }
    final bounds = _aggregateRectBounds(resolvedBounds);
    final unchanged =
        _listEquals(accepted, _state.targets) &&
        resolvedPrimary == _state.primaryTarget &&
        _mapEquals(memberships, _state.layerMembership) &&
        bounds == _state.aggregateBounds &&
        _state.transformPreview == null;
    if (unchanged) return Ok(_state);
    return _publishState(
      activePageId: accepted.isEmpty ? null : page!.id,
      targets: accepted,
      primary: resolvedPrimary,
      memberships: memberships,
      bounds: bounds,
      preview: null,
      createBoundary: true,
    );
  }

  Result<SelectionState, SelectionFailure> _publishState({
    required PageId? activePageId,
    required Iterable<SelectionTarget> targets,
    required SelectionTarget? primary,
    required Map<ObjectId, LayerId> memberships,
    required Rect2? bounds,
    required WholeObjectTransformPreview? preview,
    required bool createBoundary,
  }) {
    final next = _state.revision.increment().fold(
      onOk: (value) => value,
      onErr: (_) => null,
    );
    if (next == null) return Err(_selectionFailure('revision_overflow'));
    final candidate = SelectionState.create(
      activePageId: activePageId,
      targets: targets,
      primaryTarget: primary,
      revision: next,
      operationMode: SelectionOperationMode.wholeObject,
      layerMembership: memberships,
      aggregateBounds: bounds,
      transformPreview: preview,
    );
    final stateFailure = candidate.fold<SelectionFailure?>(
      onOk: (_) => null,
      onErr: (failure) => failure,
    );
    if (stateFailure != null) return Err(stateFailure);
    if (createBoundary) {
      try {
        final boundary = _boundarySink.establishCoalescingBoundary(
          CoalescingBoundary.selectionChange,
        );
        final boundaryFailed = boundary.fold<bool>(
          onOk: (_) => false,
          onErr: (_) => true,
        );
        if (boundaryFailed) {
          return Err(_selectionFailure('coalescing_boundary_failed'));
        }
      } on Object {
        return Err(_selectionFailure('coalescing_boundary_failed'));
      }
    }
    _state = (candidate as Ok<SelectionState, SelectionFailure>).value;
    if (createBoundary) _previewBase = null;
    return Ok(_state);
  }

  _Resolved? _resolve(
    DocumentPage page,
    ResourceCatalog resources,
    SelectionTarget target,
  ) {
    if (target.pageId != page.id) return null;
    _Resolved? result;
    for (final layer in page.layers) {
      if (layer is! ContentLayer) continue;
      for (final object in layer.objects) {
        if (object.id != target.objectId) continue;
        if (result != null ||
            !layer.isObjectEffectivelyVisible(object) ||
            layer.isObjectEffectivelyLocked(object))
          return null;
        if (object.typeKey == handwritingObjectTypeKey &&
            object.typeSchemaVersion != handwritingSchemaVersion) {
          return null;
        }
        final resolution = _registry.resolve(object);
        if (resolution is! SupportedObjectResolution ||
            !resolution.definition.capabilities.selectable ||
            !resolution.definition.capabilities.hasIntrinsicGeometry ||
            !_reachable(page, object)) {
          return null;
        }
        if (resolution.definition.capabilities.discoversResourceReferences) {
          try {
            final references = resolution.definition
                .resourceReferences(object.payload, object.typeSchemaVersion)
                .fold(onOk: (value) => value, onErr: (_) => null);
            if (references == null ||
                references.any(
                  (reference) => !resources.contains(reference.identity),
                )) {
              return null;
            }
          } on Object {
            return null;
          }
        }
        Rect2? targetBounds;
        if (target.isWholeObject) {
          targetBounds = _bounds(object);
        } else if (target.subTargetKind ==
                handwritingStrokeSelectionSubTargetKind &&
            object.typeKey == handwritingObjectTypeKey &&
            object.typeSchemaVersion == handwritingSchemaVersion &&
            handwritingLimits != null &&
            strokeGeometryResolver != null) {
          final payload =
              HandwritingPayload.decode(
                object.payload,
                limits: handwritingLimits!,
              ).fold<HandwritingPayload?>(
                onOk: (value) => value,
                onErr: (_) => null,
              );
          final stroke = payload?.strokes
              .where((value) => value.id.uuid == target.subTargetId!.uuid)
              .firstOrNull;
          targetBounds = stroke == null
              ? null
              : strokeGeometryResolver!
                    .resolve(stroke: stroke, localToPage: object.transform)
                    .fold<Rect2?>(
                      onOk: (value) => value.bounds,
                      onErr: (_) => null,
                    );
        }
        if (targetBounds == null) return null;
        result = _Resolved(layer, object, resolution, targetBounds);
      }
    }
    return result;
  }

  bool _supports(
    SupportedObjectResolution resolution,
    TransformOperation2D operation,
  ) => switch (operation) {
    IdentityTransformOperation2D() => true,
    TranslationTransformOperation2D() =>
      resolution.definition.capabilities.movable,
    RotationTransformOperation2D() =>
      resolution.definition.capabilities.rotatable,
    ScaleTransformOperation2D() => resolution.definition.capabilities.resizable,
  };

  bool _reachable(DocumentPage page, ObjectEnvelope object) {
    final bounds = _bounds(object);
    return bounds != null &&
        bounds.right >= 0 &&
        bounds.bottom >= 0 &&
        bounds.left <= page.size.width &&
        bounds.top <= page.size.height;
  }

  Rect2? _bounds(ObjectEnvelope object) {
    final resolution = _registry.resolve(object);
    if (resolution is! SupportedObjectResolution ||
        !resolution.definition.capabilities.hasIntrinsicGeometry)
      return null;
    try {
      final intrinsic = resolution.definition
          .intrinsicGeometry(object.payload, object.typeSchemaVersion)
          .fold(onOk: (value) => value, onErr: (_) => null);
      if (intrinsic == null) return null;
      final corners = <Point2>[
        intrinsic.topLeft,
        Point2.create(
          x: intrinsic.right,
          y: intrinsic.top,
        ).fold(onOk: (v) => v, onErr: (_) => intrinsic.topLeft),
        intrinsic.bottomRight,
        Point2.create(
          x: intrinsic.left,
          y: intrinsic.bottom,
        ).fold(onOk: (v) => v, onErr: (_) => intrinsic.bottomRight),
      ];
      final transformed = <Point2>[];
      for (final corner in corners) {
        final point = object.transform
            .applyToPoint(corner)
            .fold(onOk: (value) => value, onErr: (_) => null);
        if (point == null) return null;
        transformed.add(point);
      }
      final xs = transformed.map((point) => point.x).toList()..sort();
      final ys = transformed.map((point) => point.y).toList()..sort();
      return Rect2.fromEdges(
        left: xs.first,
        top: ys.first,
        right: xs.last,
        bottom: ys.last,
      ).fold(onOk: (value) => value, onErr: (_) => null);
    } on Object {
      return null;
    }
  }

  Rect2? _aggregateBounds(Iterable<ObjectEnvelope> objects) {
    Rect2? result;
    for (final object in objects) {
      final bounds = _bounds(object);
      if (bounds == null) return null;
      result = result == null
          ? bounds
          : Rect2.fromEdges(
              left: result.left < bounds.left ? result.left : bounds.left,
              top: result.top < bounds.top ? result.top : bounds.top,
              right: result.right > bounds.right ? result.right : bounds.right,
              bottom: result.bottom > bounds.bottom
                  ? result.bottom
                  : bounds.bottom,
            ).fold(onOk: (value) => value, onErr: (_) => null);
    }
    return result;
  }

  Rect2? _aggregateRectBounds(Iterable<Rect2> values) {
    Rect2? result;
    for (final bounds in values) {
      result = result == null
          ? bounds
          : Rect2.fromEdges(
              left: result.left < bounds.left ? result.left : bounds.left,
              top: result.top < bounds.top ? result.top : bounds.top,
              right: result.right > bounds.right ? result.right : bounds.right,
              bottom: result.bottom > bounds.bottom
                  ? result.bottom
                  : bounds.bottom,
            ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
      if (result == null) return null;
    }
    return result;
  }

  List<SelectionTarget>? _captureTargets(Iterable<SelectionTarget> source) {
    if (maximumTargets < 0 || maximumTargets > Revision.maximumValue)
      return null;
    final values = <SelectionTarget>[];
    try {
      final iterator = source.iterator;
      while (true) {
        final hasNext = iterator.moveNext();
        if (!hasNext) break;
        if (values.length >= maximumTargets) return null;
        values.add(iterator.current);
      }
    } on Object {
      return null;
    }
    return values;
  }
}

final class _Resolved {
  const _Resolved(this.layer, this.object, this.resolution, this.bounds);
  final DocumentLayer layer;
  final ObjectEnvelope object;
  final SupportedObjectResolution resolution;
  final Rect2 bounds;
}

final Revision _zeroRevision = Revision.create(0).fold(
  onOk: (value) => value,
  onErr: (_) => throw StateError('Zero Revision must be valid.'),
);

SelectionFailure _selectionFailure(String leaf) => SelectionFailure(
  'drawing.selection.$leaf',
  leaf == 'inconsistent_document_state' ||
          leaf.contains('unavailable') ||
          leaf.contains('missing')
      ? FailureCategory.state
      : FailureCategory.validation,
);

SelectionState _trustedSelectionState({
  required PageId? activePageId,
  required Iterable<SelectionTarget> targets,
  required SelectionTarget? primaryTarget,
  required Revision revision,
  required SelectionOperationMode operationMode,
  required Map<ObjectId, LayerId> layerMembership,
  required Rect2? aggregateBounds,
  required WholeObjectTransformPreview? transformPreview,
}) =>
    SelectionState.create(
      activePageId: activePageId,
      targets: targets,
      primaryTarget: primaryTarget,
      revision: revision,
      operationMode: operationMode,
      layerMembership: layerMembership,
      aggregateBounds: aggregateBounds,
      transformPreview: transformPreview,
    ).fold(
      onOk: (value) => value,
      onErr: (failure) => throw StateError(
        'Internally derived SelectionState was invalid: ${failure.code}',
      ),
    );

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _mapEquals<K, V>(Map<K, V> left, Map<K, V> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}
