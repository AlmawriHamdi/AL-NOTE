// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/content_identity.dart';
import '../../core/versioning/revision.dart';
import '../layers/document_layer.dart';
import '../model/document_root.dart';
import '../model/document_validator.dart';
import '../model/identifiers.dart';
import '../objects/object_envelope.dart';
import '../objects/object_registry.dart';
import 'command_contracts.dart';
import 'revision_snapshot.dart';

/// A snapshot-style listener for one already published change.
typedef CommittedChangeListener = void Function(CommittedChange change);

/// Immutable root and content identity captured for asynchronous saving.
final class DocumentSaveCapture {
  /// Creates an exact immutable save capture.
  const DocumentSaveCapture._({
    required this.root,
    required this.contentIdentity,
    required Object owner,
  }) : _owner = owner;

  /// The exact captured authoritative root.
  final DocumentRoot root;

  /// The exact captured session content identity.
  final ContentIdentity contentIdentity;
  final Object _owner;
  @override
  String toString() => 'DocumentSaveCapture(document: ${root.id})';
}

/// Immutable outward-facing state of one document mutation coordinator.
final class DocumentCoordinatorSnapshot {
  /// Creates an immutable coordinator snapshot.
  const DocumentCoordinatorSnapshot({
    required this.root,
    required this.revisions,
    required this.currentContentIdentity,
    required this.savedContentIdentity,
    required this.canUndo,
    required this.canRedo,
    required this.historyTraversalEnabled,
  });

  /// Current authoritative document root.
  final DocumentRoot root;

  /// Current session revision tokens.
  final DocumentRevisionSnapshot revisions;

  /// Current state identity.
  final ContentIdentity currentContentIdentity;

  /// Last successfully acknowledged saved identity.
  final ContentIdentity? savedContentIdentity;

  /// Whether one valid Undo entry is reachable.
  final bool canUndo;

  /// Whether one valid Redo entry is reachable.
  final bool canRedo;

  /// Whether history has remained internally consistent.
  final bool historyTraversalEnabled;

  /// Dirty state depends only on content identities.
  bool get isDirty => currentContentIdentity != savedContentIdentity;
}

/// Whether the initial coordinator root has a canonical saved baseline.
enum InitialDocumentSaveState {
  /// The initial root was loaded from or acknowledged by canonical storage.
  saved,

  /// The initial root has never been canonically saved, including Recovery.
  unsaved,
}

/// The sole document-scoped gateway for Phase 3 persistent mutations.
final class DocumentMutationCoordinator implements CoalescingBoundarySink {
  DocumentMutationCoordinator._({
    required DocumentRoot root,
    required DocumentValidator validator,
    required UuidGenerator uuidGenerator,
    required HistoryLimits historyLimits,
    required HistoryRetainedCostEstimator retainedCostEstimator,
    required ContentIdentity initialIdentity,
    required InitialDocumentSaveState initialSaveState,
  }) : _root = root,
       _validator = validator,
       _uuidGenerator = uuidGenerator,
       _historyLimits = historyLimits,
       _retainedCostEstimator = retainedCostEstimator,
       _revisions = DocumentRevisionSnapshot.initial(root),
       _currentContentIdentity = initialIdentity,
       _savedContentIdentity =
           initialSaveState == InitialDocumentSaveState.saved
           ? initialIdentity
           : null,
       _issuedContentIdentities = <ContentIdentity>{initialIdentity};

  /// Creates a coordinator after validating the baseline and generating its
  /// initial session-only content identity.
  static Result<DocumentMutationCoordinator, CommandFailure> create({
    required DocumentRoot initialRoot,
    required DocumentValidator validator,
    required UuidGenerator uuidGenerator,
    required HistoryLimits historyLimits,
    required HistoryRetainedCostEstimator retainedCostEstimator,
    InitialDocumentSaveState initialSaveState = InitialDocumentSaveState.saved,
  }) {
    if (!validator.validate(initialRoot).isValid) {
      return Err(
        _failure('invalid_initial_document', FailureCategory.validation),
      );
    }
    try {
      return uuidGenerator.generateV4().fold(
        onOk: (uuid) => Ok(
          DocumentMutationCoordinator._(
            root: initialRoot,
            validator: validator,
            uuidGenerator: uuidGenerator,
            historyLimits: historyLimits,
            retainedCostEstimator: retainedCostEstimator,
            initialIdentity: ContentIdentity(uuid),
            initialSaveState: initialSaveState,
          ),
        ),
        onErr: (_) => Err(
          _failure(
            'content_identity_generation_failed',
            FailureCategory.dependency,
          ),
        ),
      );
    } on Object {
      return Err(
        _failure(
          'content_identity_generation_failed',
          FailureCategory.dependency,
        ),
      );
    }
  }

  final DocumentValidator _validator;
  final UuidGenerator _uuidGenerator;
  final HistoryLimits _historyLimits;
  final HistoryRetainedCostEstimator _retainedCostEstimator;
  DocumentRoot _root;
  DocumentRevisionSnapshot _revisions;
  ContentIdentity _currentContentIdentity;
  ContentIdentity? _savedContentIdentity;
  final Set<ContentIdentity> _issuedContentIdentities;
  final List<_HistoryEntry> _history = [];
  int _historyCursor = 0;
  bool _historyTraversalEnabled = true;
  bool _mutationActive = false;
  bool _coalescingBoundaryPending = true;
  final List<CommittedChangeListener> _listeners = [];
  final Object _saveCaptureOwner = Object();

  /// Current immutable coordinator state.
  DocumentCoordinatorSnapshot get snapshot => DocumentCoordinatorSnapshot(
    root: _root,
    revisions: _revisions,
    currentContentIdentity: _currentContentIdentity,
    savedContentIdentity: _savedContentIdentity,
    canUndo: _historyTraversalEnabled && _historyCursor > 0,
    canRedo: _historyTraversalEnabled && _historyCursor < _history.length,
    historyTraversalEnabled: _historyTraversalEnabled,
  );

  /// Current retained history entry count across Undo and Redo.
  int get retainedHistoryCount => _history.length;

  /// Current estimated retained bytes across Undo and Redo.
  int get estimatedRetainedHistoryBytes =>
      _history.fold(0, (total, entry) => total + entry.cost.estimatedBytes);

  /// Adds [listener] once. Listener mutation during notification affects only
  /// later notifications.
  void addListener(CommittedChangeListener listener) {
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  /// Removes [listener] for later notifications.
  void removeListener(CommittedChangeListener listener) {
    _listeners.remove(listener);
  }

  @override
  Result<void, StructuredFailure> establishCoalescingBoundary(
    CoalescingBoundary boundary,
  ) {
    _coalescingBoundaryPending = true;
    return const Ok(null);
  }

  /// Executes one typed request synchronously and atomically.
  Result<CommandCommit, CommandFailure> execute(CommandRequest request) {
    if (_mutationActive) {
      return Err(_failure('reentrant_mutation', FailureCategory.state));
    }
    _mutationActive = true;
    try {
      return _executeInsideBoundary(request);
    } finally {
      _mutationActive = false;
    }
  }

  Result<CommandCommit, CommandFailure> _executeInsideBoundary(
    CommandRequest request,
  ) {
    if (request.documentId != _root.id) {
      return Err(_failure('wrong_document', FailureCategory.validation));
    }
    final stale = _revisions.mismatches(request.preconditions);
    if (stale.isNotEmpty) {
      return Err(
        CommandFailure(
          code: 'documents.commands.stale_revision',
          category: FailureCategory.state,
          staleEvidence: stale,
        ),
      );
    }

    final prepared = switch (request) {
      AtomicObjectReplacementRequest() => _prepareReplacement(request),
      AtomicWholeObjectTransformRequest() => _prepareTransform(request),
    };
    return prepared.fold(
      onOk: (value) => _publishPrepared(value, request),
      onErr: Err<CommandCommit, CommandFailure>.new,
    );
  }

  Result<_Prepared, CommandFailure> _prepareReplacement(
    AtomicObjectReplacementRequest request,
  ) {
    if (request.targetIds.any(
      (target) => !request.preconditions.objects.containsKey(target),
    )) {
      return Err(
        _failure('missing_revision_precondition', FailureCategory.validation),
      );
    }
    final replacements = <ObjectId, ObjectEnvelope>{};
    for (var index = 0; index < request.targetIds.length; index += 1) {
      replacements[request.targetIds[index]] = request.replacements[index];
    }
    final locations = _locateObjects(_root, replacements.keys);
    if (locations == null) {
      return Err(
        _failure('target_missing_or_not_unique', FailureCategory.state),
      );
    }
    final pages = <PageId>{};
    final layers = <LayerId>{};
    final oldObjectBounds = <ObjectId, Rect2>{};
    final newObjectBounds = <ObjectId, Rect2>{};
    for (final location in locations.values) {
      if (!request.preconditions.layerMembership.containsKey(
        location.layer.id,
      )) {
        return Err(
          _failure('missing_revision_precondition', FailureCategory.validation),
        );
      }
      final eligible = _editableResolution(location.layer, location.object);
      final beforeBounds = eligible == null
          ? null
          : _objectBounds(location.object);
      if (eligible == null ||
          beforeBounds == null ||
          !_boundsAreReachable(location.page, beforeBounds)) {
        return Err(_failure('target_not_editable', FailureCategory.state));
      }
      final replacement = replacements[location.object.id]!;
      final replacementEligible = _editableResolution(
        location.layer,
        replacement,
        requireAvailableResources: false,
      );
      final afterBounds = replacementEligible == null
          ? null
          : _objectBounds(replacement);
      if (replacement.id != location.object.id ||
          !_replacementPreservesCommonEnvelope(location.object, replacement) ||
          replacementEligible == null ||
          afterBounds == null ||
          !_boundsAreReachable(location.page, afterBounds)) {
        return Err(_failure('invalid_replacement', FailureCategory.validation));
      }
      oldObjectBounds[location.object.id] = beforeBounds;
      newObjectBounds[replacement.id] = afterBounds;
      pages.add(location.page.id);
      layers.add(location.layer.id);
    }
    final candidateResult = _replaceObjects(_root, replacements);
    return candidateResult.fold(
      onOk: (candidate) {
        if (!_validator.validate(candidate).isValid) {
          return Err(_failure('invalid_candidate', FailureCategory.validation));
        }
        final oldReferences = _resourceReferences(
          locations.values.map((value) => value.object),
        );
        final newReferences = _resourceReferences(replacements.values);
        if (oldReferences == null || newReferences == null) {
          return Err(_failure('target_not_editable', FailureCategory.state));
        }
        if ({
          ...oldReferences,
          ...newReferences,
        }.any((identity) => !_root.resources.contains(identity))) {
          return Err(_failure('missing_resource', FailureCategory.state));
        }
        if (candidate == _root) {
          return Err(_failure('no_change', FailureCategory.validation));
        }
        final geometryChangedObjectIds = _boundChangedObjectIds(
          oldObjectBounds,
          newObjectBounds,
        );
        final addedReferences = newReferences.difference(oldReferences);
        final removedReferences = oldReferences.difference(newReferences);
        if (geometryChangedObjectIds.isEmpty &&
            !request.changeCategories.appearance &&
            !request.changeCategories.text &&
            !request.changeCategories.metadata &&
            addedReferences.isEmpty &&
            removedReferences.isEmpty) {
          return Err(
            _failure('unclassified_payload_change', FailureCategory.validation),
          );
        }
        return Ok(
          _Prepared(
            before: _root,
            after: candidate,
            objectIds: replacements.keys.toSet(),
            pageIds: pages,
            layerIds: layers,
            oldObjectBounds: oldObjectBounds,
            newObjectBounds: newObjectBounds,
            geometryChangedObjectIds: geometryChangedObjectIds,
            appearanceChanged: request.changeCategories.appearance,
            textChanged: request.changeCategories.text,
            metadataChanged: request.changeCategories.metadata,
            addedResourceReferences: addedReferences,
            removedResourceReferences: removedReferences,
          ),
        );
      },
      onErr: Err<_Prepared, CommandFailure>.new,
    );
  }

  Result<_Prepared, CommandFailure> _prepareTransform(
    AtomicWholeObjectTransformRequest request,
  ) {
    if (!request.preconditions.pages.containsKey(request.pageId) ||
        request.targetIds.any(
          (target) => !request.preconditions.objects.containsKey(target),
        )) {
      return Err(
        _failure('missing_revision_precondition', FailureCategory.validation),
      );
    }
    final affine = AffineTransform2D.fromOperation(
      request.operation,
    ).fold(onOk: (value) => value, onErr: (_) => null);
    if (affine == null) {
      return Err(_failure('invalid_transform', FailureCategory.validation));
    }
    final locations = _locateObjects(_root, request.targetIds);
    if (locations == null ||
        locations.values.any(
          (location) => location.page.id != request.pageId,
        )) {
      return Err(
        _failure('target_missing_or_wrong_page', FailureCategory.state),
      );
    }
    final replacements = <ObjectId, ObjectEnvelope>{};
    final layers = <LayerId>{};
    final oldObjectBounds = <ObjectId, Rect2>{};
    final newObjectBounds = <ObjectId, Rect2>{};
    final geometryChangedObjectIds = <ObjectId>{};
    for (final location in locations.values) {
      if (!request.preconditions.layerMembership.containsKey(
        location.layer.id,
      )) {
        return Err(
          _failure('missing_revision_precondition', FailureCategory.validation),
        );
      }
      final resolution = _editableResolution(location.layer, location.object);
      if (resolution == null ||
          !_supportsOperation(resolution, request.operation)) {
        return Err(
          _failure('transform_capability_denied', FailureCategory.state),
        );
      }
      final transformed = location.object.transform
          .then(affine)
          .fold(onOk: (value) => value, onErr: (_) => null);
      if (transformed == null) {
        return Err(_failure('invalid_transform', FailureCategory.validation));
      }
      final replacement = ObjectEnvelope.create(
        id: location.object.id,
        typeKey: location.object.typeKey,
        envelopeVersion: location.object.envelopeVersion,
        typeSchemaVersion: location.object.typeSchemaVersion,
        transform: transformed,
        visible: location.object.visible,
        locked: location.object.locked,
        payload: location.object.payload,
        extensionData: location.object.extensionData,
      ).fold(onOk: (value) => value, onErr: (_) => null);
      final beforeBounds = _objectBounds(location.object);
      final afterBounds = replacement == null
          ? null
          : _objectBounds(replacement);
      if (replacement == null ||
          beforeBounds == null ||
          afterBounds == null ||
          !_boundsAreReachable(location.page, afterBounds)) {
        return Err(
          _failure('transform_unreachable', FailureCategory.validation),
        );
      }
      replacements[replacement.id] = replacement;
      oldObjectBounds[location.object.id] = beforeBounds;
      newObjectBounds[replacement.id] = afterBounds;
      if (location.object.transform != replacement.transform) {
        geometryChangedObjectIds.add(replacement.id);
      }
      layers.add(location.layer.id);
    }
    final candidate = _replaceObjects(
      _root,
      replacements,
    ).fold(onOk: (value) => value, onErr: (_) => null);
    if (candidate == null || !_validator.validate(candidate).isValid) {
      return Err(_failure('invalid_candidate', FailureCategory.validation));
    }
    if (candidate == _root) {
      return Err(_failure('no_change', FailureCategory.validation));
    }
    return Ok(
      _Prepared(
        before: _root,
        after: candidate,
        objectIds: replacements.keys.toSet(),
        pageIds: {request.pageId},
        layerIds: layers,
        oldObjectBounds: oldObjectBounds,
        newObjectBounds: newObjectBounds,
        geometryChangedObjectIds: geometryChangedObjectIds,
        appearanceChanged: false,
        textChanged: false,
        metadataChanged: false,
        addedResourceReferences: const {},
        removedResourceReferences: const {},
      ),
    );
  }

  Result<CommandCommit, CommandFailure> _publishPrepared(
    _Prepared prepared,
    CommandRequest request,
  ) {
    final nextRevisions = _advancedRevisions(prepared);
    if (nextRevisions == null) {
      return Err(_failure('revision_overflow', FailureCategory.resource));
    }
    final identityResult = _generateContentIdentity();
    final identityFailure = identityResult.fold<CommandFailure?>(
      onOk: (_) => null,
      onErr: (failure) => failure,
    );
    if (identityFailure != null) return Err(identityFailure);
    final nextIdentity =
        (identityResult as Ok<ContentIdentity, CommandFailure>).value;

    final historyResult = _planHistory(prepared, request, nextIdentity);
    final historyFailure = historyResult.fold<CommandFailure?>(
      onOk: (_) => null,
      onErr: (failure) => failure,
    );
    if (historyFailure != null) return Err(historyFailure);
    final historyPlan =
        (historyResult as Ok<_HistoryPlan, CommandFailure>).value;
    final change = _changeFor(
      prepared,
      request.metadata,
      CommandOrigin.user,
      nextRevisions.document,
    );

    _root = prepared.after;
    _revisions = nextRevisions;
    _currentContentIdentity = nextIdentity;
    _issuedContentIdentities.add(nextIdentity);
    _history
      ..clear()
      ..addAll(historyPlan.entries);
    _historyCursor = historyPlan.cursor;
    _coalescingBoundaryPending = false;
    final observerFailures = _notify(change);
    return Ok(
      CommandCommit(change: change, observerFailureCount: observerFailures),
    );
  }

  Result<_HistoryPlan, CommandFailure> _planHistory(
    _Prepared prepared,
    CommandRequest request,
    ContentIdentity afterIdentity,
  ) {
    final entries = List<_HistoryEntry>.of(_history.take(_historyCursor));
    var cursor = entries.length;
    final prior = entries.isEmpty ? null : entries.last;
    final canCoalesce =
        !_coalescingBoundaryPending &&
        request is AtomicObjectReplacementRequest &&
        request.metadata.coalescing != null &&
        prior != null &&
        prior.family == request.metadata.family &&
        prior.coalescing == request.metadata.coalescing &&
        prior.after == prepared.before;
    final estimateInput = HistoryCostEstimateInput(
      beforeRoot: canCoalesce ? prior.before : prepared.before,
      afterRoot: prepared.after,
      replacedObjectCount: prepared.objectIds.length,
    );
    final costResult = _estimateCost(
      estimateInput,
      request.metadata.description,
    );
    final costFailure = costResult.fold<CommandFailure?>(
      onOk: (_) => null,
      onErr: (failure) => failure,
    );
    if (costFailure != null) return Err(costFailure);
    final cost = (costResult as Ok<HistoryRetainedCost, CommandFailure>).value;
    if (_historyLimits.maximumRetainedCommandCount == 0 ||
        _historyLimits.maximumEstimatedRetainedBytes == 0 ||
        cost.estimatedBytes > _historyLimits.maximumEstimatedRetainedBytes) {
      return Err(_failure('history_limit_exceeded', FailureCategory.resource));
    }
    final entry = _HistoryEntry(
      before: canCoalesce ? prior.before : prepared.before,
      after: prepared.after,
      beforeIdentity: canCoalesce
          ? prior.beforeIdentity
          : _currentContentIdentity,
      afterIdentity: afterIdentity,
      family: request.metadata.family,
      correlationId: request.metadata.correlationId,
      description: request.metadata.description,
      coalescing: request.metadata.coalescing,
      prepared: canCoalesce ? prior.prepared.merge(prepared) : prepared,
      cost: cost,
    );
    if (canCoalesce) {
      entries[entries.length - 1] = entry;
    } else {
      entries.add(entry);
      cursor += 1;
    }
    var total = 0;
    for (final item in entries) {
      if (total > Revision.maximumValue - item.cost.estimatedBytes) {
        return Err(_failure('history_cost_overflow', FailureCategory.resource));
      }
      total += item.cost.estimatedBytes;
    }
    while (entries.length > _historyLimits.maximumRetainedCommandCount ||
        total > _historyLimits.maximumEstimatedRetainedBytes) {
      if (entries.length <= 1) {
        return Err(
          _failure('history_limit_exceeded', FailureCategory.resource),
        );
      }
      total -= entries.removeAt(0).cost.estimatedBytes;
      cursor -= 1;
    }
    return Ok(_HistoryPlan(entries, cursor));
  }

  Result<HistoryRetainedCost, CommandFailure> _estimateCost(
    HistoryCostEstimateInput input,
    String retainedDescription,
  ) {
    try {
      final estimated = _retainedCostEstimator
          .estimate(input)
          .fold(onOk: (value) => value, onErr: (_) => null);
      if (estimated == null) {
        return Err(
          _failure(
            'history_cost_estimation_failed',
            FailureCategory.dependency,
          ),
        );
      }
      final descriptionBytes = utf8.encode(retainedDescription).length;
      if (descriptionBytes > Revision.maximumValue ||
          estimated.estimatedBytes > Revision.maximumValue - descriptionBytes) {
        return Err(_failure('history_cost_overflow', FailureCategory.resource));
      }
      return HistoryRetainedCost.create(
        estimated.estimatedBytes + descriptionBytes,
      ).fold(
        onOk: Ok<HistoryRetainedCost, CommandFailure>.new,
        onErr: (_) =>
            Err(_failure('history_cost_overflow', FailureCategory.resource)),
      );
    } on Object {
      return Err(
        _failure('history_cost_estimation_failed', FailureCategory.dependency),
      );
    }
  }

  Result<ContentIdentity, CommandFailure> _generateContentIdentity() {
    try {
      return _uuidGenerator.generateV4().fold(
        onOk: (uuid) {
          final identity = ContentIdentity(uuid);
          if (_issuedContentIdentities.contains(identity)) {
            return Err(
              _failure('content_identity_collision', FailureCategory.state),
            );
          }
          return Ok(identity);
        },
        onErr: (_) => Err(
          _failure(
            'content_identity_generation_failed',
            FailureCategory.dependency,
          ),
        ),
      );
    } on Object {
      return Err(
        _failure(
          'content_identity_generation_failed',
          FailureCategory.dependency,
        ),
      );
    }
  }

  /// Undoes the newest reachable history entry exactly, without Registry calls.
  Result<CommandCommit, CommandFailure> undo() => _traverse(undoing: true);

  /// Redoes the next reachable history entry exactly, without Registry calls.
  Result<CommandCommit, CommandFailure> redo() => _traverse(undoing: false);

  Result<CommandCommit, CommandFailure> _traverse({required bool undoing}) {
    if (_mutationActive)
      return Err(_failure('reentrant_mutation', FailureCategory.state));
    if (!_historyTraversalEnabled) {
      return Err(_failure('history_disabled', FailureCategory.state));
    }
    final index = undoing ? _historyCursor - 1 : _historyCursor;
    if (index < 0 || index >= _history.length) {
      return Err(
        _failure(
          undoing ? 'nothing_to_undo' : 'nothing_to_redo',
          FailureCategory.state,
        ),
      );
    }
    _mutationActive = true;
    try {
      final entry = _history[index];
      final expectedRoot = undoing ? entry.after : entry.before;
      final expectedIdentity = undoing
          ? entry.afterIdentity
          : entry.beforeIdentity;
      if (_root != expectedRoot ||
          _currentContentIdentity != expectedIdentity) {
        _historyTraversalEnabled = false;
        return Err(_failure('history_inconsistent', FailureCategory.state));
      }
      final nextRevisions = _advancedRevisions(entry.prepared);
      if (nextRevisions == null) {
        return Err(_failure('revision_overflow', FailureCategory.resource));
      }
      final destination = undoing ? entry.before : entry.after;
      final destinationIdentity = undoing
          ? entry.beforeIdentity
          : entry.afterIdentity;
      final prepared = undoing ? entry.prepared.reversed() : entry.prepared;
      final metadata = CommandMetadata(
        family: entry.family,
        correlationId: entry.correlationId,
        description: entry.description,
      );
      final change = _changeFor(
        prepared,
        metadata,
        undoing ? CommandOrigin.undo : CommandOrigin.redo,
        nextRevisions.document,
        historyRecorded: false,
      );
      _root = destination;
      _currentContentIdentity = destinationIdentity;
      _revisions = nextRevisions;
      _historyCursor += undoing ? -1 : 1;
      _coalescingBoundaryPending = true;
      return Ok(
        CommandCommit(change: change, observerFailureCount: _notify(change)),
      );
    } finally {
      _mutationActive = false;
    }
  }

  /// Clears history and establishes the current state as a new valid baseline.
  Result<void, CommandFailure> resetHistoryBaseline() {
    if (_mutationActive)
      return Err(_failure('reentrant_mutation', FailureCategory.state));
    _history.clear();
    _historyCursor = 0;
    _historyTraversalEnabled = true;
    _coalescingBoundaryPending = true;
    return const Ok(null);
  }

  /// Captures the exact state to save and establishes a save coalescing boundary.
  DocumentSaveCapture captureForSave() {
    establishCoalescingBoundary(CoalescingBoundary.saveCheckpoint);
    return DocumentSaveCapture._(
      root: _root,
      contentIdentity: _currentContentIdentity,
      owner: _saveCaptureOwner,
    );
  }

  /// Acknowledges that [capture] was saved successfully.
  Result<void, CommandFailure> acknowledgeSave(DocumentSaveCapture capture) {
    if (!identical(capture._owner, _saveCaptureOwner) ||
        capture.root.id != _root.id) {
      return Err(_failure('invalid_save_capture', FailureCategory.validation));
    }
    _savedContentIdentity = capture.contentIdentity;
    return const Ok(null);
  }

  /// Records a failed save without moving the saved checkpoint.
  Result<void, CommandFailure> acknowledgeSaveFailure(
    DocumentSaveCapture capture,
  ) {
    if (!identical(capture._owner, _saveCaptureOwner) ||
        capture.root.id != _root.id) {
      return Err(_failure('invalid_save_capture', FailureCategory.validation));
    }
    return const Ok(null);
  }

  int _notify(CommittedChange change) {
    var failures = 0;
    final listeners = List<CommittedChangeListener>.of(_listeners);
    for (final listener in listeners) {
      try {
        listener(change);
      } on Object {
        failures += 1;
      }
    }
    return failures;
  }

  DocumentRevisionSnapshot? _advancedRevisions(_Prepared prepared) {
    return _revisions
        .advanceObjects(prepared.objectIds)
        .fold(onOk: (value) => value, onErr: (_) => null);
  }

  CommittedChange _changeFor(
    _Prepared prepared,
    CommandMetadata metadata,
    CommandOrigin origin,
    Revision newRevision, {
    bool historyRecorded = true,
  }) => CommittedChange(
    documentId: _root.id,
    previousRevision: _revisions.document,
    newRevision: newRevision,
    origin: origin,
    family: metadata.family,
    description: metadata.description,
    correlationId: metadata.correlationId,
    replacedObjectIds: prepared.objectIds,
    movedObjectIds: prepared.geometryChangedObjectIds,
    affectedPageIds: prepared.pageIds,
    affectedLayerIds: prepared.layerIds,
    addedResourceReferences: prepared.addedResourceReferences,
    removedResourceReferences: prepared.removedResourceReferences,
    oldBounds: prepared.oldBounds,
    newBounds: prepared.newBounds,
    flags: CommittedChangeFlags(
      geometry: prepared.geometryChanged,
      appearance: prepared.appearanceChanged,
      text: prepared.textChanged,
      resources:
          prepared.addedResourceReferences.isNotEmpty ||
          prepared.removedResourceReferences.isNotEmpty,
      metadata: prepared.metadataChanged,
    ),
    historyRecorded: historyRecorded,
    savedCheckpointChanged: false,
  );

  SupportedObjectResolution? _editableResolution(
    DocumentLayer layer,
    ObjectEnvelope object, {
    bool requireAvailableResources = true,
  }) {
    if (!layer.isObjectEffectivelyVisible(object) ||
        layer.isObjectEffectivelyLocked(object))
      return null;
    final resolution = _validator.objectRegistry.resolve(object);
    if (resolution is! SupportedObjectResolution ||
        !resolution.definition.capabilities.selectable)
      return null;
    final capabilities = resolution.definition.capabilities;
    try {
      if (capabilities.hasIntrinsicGeometry) {
        final available = resolution.definition
            .intrinsicGeometry(object.payload, object.typeSchemaVersion)
            .fold(onOk: (_) => true, onErr: (_) => false);
        if (!available) return null;
      }
      if (capabilities.discoversResourceReferences) {
        final references = resolution.definition
            .resourceReferences(object.payload, object.typeSchemaVersion)
            .fold(onOk: (values) => values, onErr: (_) => null);
        if (references == null ||
            (requireAvailableResources &&
                references.any(
                  (reference) => !_root.resources.contains(reference.identity),
                ))) {
          return null;
        }
      }
    } on Object {
      return null;
    }
    return resolution;
  }

  bool _supportsOperation(
    SupportedObjectResolution resolution,
    TransformOperation2D operation,
  ) {
    final capabilities = resolution.definition.capabilities;
    if (!capabilities.hasIntrinsicGeometry) return false;
    return switch (operation) {
      IdentityTransformOperation2D() => true,
      TranslationTransformOperation2D() => capabilities.movable,
      RotationTransformOperation2D() => capabilities.rotatable,
      ScaleTransformOperation2D() => capabilities.resizable,
    };
  }

  bool _boundsAreReachable(DocumentPage page, Rect2 bounds) =>
      bounds.right >= 0 &&
      bounds.bottom >= 0 &&
      bounds.left <= page.size.width &&
      bounds.top <= page.size.height;

  Rect2? _objectBounds(ObjectEnvelope object) {
    final resolution = _validator.objectRegistry.resolve(object);
    if (resolution is! SupportedObjectResolution ||
        !resolution.definition.capabilities.hasIntrinsicGeometry)
      return null;
    try {
      final intrinsic = resolution.definition
          .intrinsicGeometry(object.payload, object.typeSchemaVersion)
          .fold(onOk: (value) => value, onErr: (_) => null);
      if (intrinsic == null) return null;
      final points = <Point2>[];
      for (final point in <Point2>[
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
      ]) {
        final transformed = object.transform
            .applyToPoint(point)
            .fold(onOk: (value) => value, onErr: (_) => null);
        if (transformed == null) return null;
        points.add(transformed);
      }
      final xs = points.map((point) => point.x).toList()..sort();
      final ys = points.map((point) => point.y).toList()..sort();
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

  Set<ResourceIdentity>? _resourceReferences(Iterable<ObjectEnvelope> objects) {
    final result = <ResourceIdentity>{};
    for (final object in objects) {
      final resolution = _validator.objectRegistry.resolve(object);
      if (resolution is! SupportedObjectResolution) return null;
      if (!resolution.definition.capabilities.discoversResourceReferences) {
        continue;
      }
      try {
        final references = resolution.definition
            .resourceReferences(object.payload, object.typeSchemaVersion)
            .fold(onOk: (values) => values, onErr: (_) => null);
        if (references == null) return null;
        result.addAll(references.map((value) => value.identity));
      } on Object {
        return null;
      }
    }
    return result;
  }

  bool _replacementPreservesCommonEnvelope(
    ObjectEnvelope before,
    ObjectEnvelope after,
  ) =>
      before.id == after.id &&
      before.typeKey == after.typeKey &&
      before.envelopeVersion == after.envelopeVersion &&
      before.typeSchemaVersion == after.typeSchemaVersion &&
      before.transform == after.transform &&
      before.visible == after.visible &&
      before.locked == after.locked &&
      before.extensionData == after.extensionData;
}

final class _Location {
  const _Location(this.page, this.layer, this.object);
  final DocumentPage page;
  final DocumentLayer layer;
  final ObjectEnvelope object;
}

Map<ObjectId, _Location>? _locateObjects(
  DocumentRoot root,
  Iterable<ObjectId> targets,
) {
  final wanted = targets.toSet();
  final result = <ObjectId, _Location>{};
  for (final page in root.pages) {
    for (final layer in page.layers) {
      for (final object in layer.objects) {
        if (wanted.contains(object.id)) {
          if (result.containsKey(object.id)) return null;
          result[object.id] = _Location(page, layer, object);
        }
      }
    }
  }
  return result.length == wanted.length ? result : null;
}

Result<DocumentRoot, CommandFailure> _replaceObjects(
  DocumentRoot root,
  Map<ObjectId, ObjectEnvelope> replacements,
) {
  DocumentPage rebuildPage(DocumentPage page) {
    final layers = <DocumentLayer>[];
    for (final layer in page.layers) {
      final objects = <ObjectEnvelope>[
        for (final object in layer.objects) replacements[object.id] ?? object,
      ];
      final rebuilt = layer
          .withObjects(objects)
          .fold(
            onOk: (value) => value,
            onErr: (_) => throw const _CandidateBuildFailure(),
          );
      layers.add(rebuilt);
    }
    return DocumentPage.create(
      id: page.id,
      name: page.name,
      size: page.size,
      layers: layers,
      extensionData: page.extensionData,
    ).fold(
      onOk: (value) => value,
      onErr: (_) => throw const _CandidateBuildFailure(),
    );
  }

  try {
    return switch (root) {
      StandalonePageDocument() =>
        StandalonePageDocument.create(
              id: root.id,
              schemaVersion: root.schemaVersion,
              title: root.title,
              resources: root.resources,
              extensionData: root.extensionData,
              page: rebuildPage(root.page),
            )
            .map<DocumentRoot>((value) => value)
            .mapError(
              (_) => _failure('invalid_candidate', FailureCategory.validation),
            ),
      StandalonePdfDocument() =>
        StandalonePdfDocument.create(
              id: root.id,
              schemaVersion: root.schemaVersion,
              title: root.title,
              resources: root.resources,
              extensionData: root.extensionData,
              pages: root.pages.map(rebuildPage),
              source: root.source,
            )
            .map<DocumentRoot>((value) => value)
            .mapError(
              (_) => _failure('invalid_candidate', FailureCategory.validation),
            ),
      NotebookDocument() =>
        NotebookDocument.create(
              id: root.id,
              schemaVersion: root.schemaVersion,
              title: root.title,
              resources: root.resources,
              extensionData: root.extensionData,
              sections: [
                for (final section in root.sections)
                  DocumentSection.create(
                    id: section.id,
                    name: section.name,
                    pages: section.pages.map(rebuildPage),
                    extensionData: section.extensionData,
                  ).fold(
                    onOk: (value) => value,
                    onErr: (_) => throw const _CandidateBuildFailure(),
                  ),
              ],
            )
            .map<DocumentRoot>((value) => value)
            .mapError(
              (_) => _failure('invalid_candidate', FailureCategory.validation),
            ),
    };
  } on _CandidateBuildFailure {
    return Err(_failure('invalid_candidate', FailureCategory.validation));
  }
}

final class _Prepared {
  _Prepared({
    required this.before,
    required this.after,
    required Set<ObjectId> objectIds,
    required Set<PageId> pageIds,
    required Set<LayerId> layerIds,
    required Map<ObjectId, Rect2> oldObjectBounds,
    required Map<ObjectId, Rect2> newObjectBounds,
    required Set<ObjectId> geometryChangedObjectIds,
    required this.appearanceChanged,
    required this.textChanged,
    required this.metadataChanged,
    required Set<ResourceIdentity> addedResourceReferences,
    required Set<ResourceIdentity> removedResourceReferences,
  }) : assert(_sameKeys(oldObjectBounds, newObjectBounds)),
       assert(_setEquals(objectIds, oldObjectBounds.keys.toSet())),
       assert(objectIds.containsAll(geometryChangedObjectIds)),
       objectIds = Set<ObjectId>.unmodifiable(objectIds),
       pageIds = Set<PageId>.unmodifiable(pageIds),
       layerIds = Set<LayerId>.unmodifiable(layerIds),
       oldObjectBounds = Map<ObjectId, Rect2>.unmodifiable(oldObjectBounds),
       newObjectBounds = Map<ObjectId, Rect2>.unmodifiable(newObjectBounds),
       geometryChangedObjectIds = Set<ObjectId>.unmodifiable(
         geometryChangedObjectIds,
       ),
       addedResourceReferences = Set<ResourceIdentity>.unmodifiable(
         addedResourceReferences,
       ),
       removedResourceReferences = Set<ResourceIdentity>.unmodifiable(
         removedResourceReferences,
       );
  final DocumentRoot before;
  final DocumentRoot after;
  final Set<ObjectId> objectIds;
  final Set<PageId> pageIds;
  final Set<LayerId> layerIds;
  final Map<ObjectId, Rect2> oldObjectBounds;
  final Map<ObjectId, Rect2> newObjectBounds;
  final Set<ObjectId> geometryChangedObjectIds;
  Rect2? get oldBounds => _aggregateRectangles(oldObjectBounds.values);
  Rect2? get newBounds => _aggregateRectangles(newObjectBounds.values);
  bool get geometryChanged => geometryChangedObjectIds.isNotEmpty;
  final bool appearanceChanged;
  final bool textChanged;
  final bool metadataChanged;
  final Set<ResourceIdentity> addedResourceReferences;
  final Set<ResourceIdentity> removedResourceReferences;

  _Prepared reversed() => _Prepared(
    before: after,
    after: before,
    objectIds: objectIds,
    pageIds: pageIds,
    layerIds: layerIds,
    oldObjectBounds: newObjectBounds,
    newObjectBounds: oldObjectBounds,
    geometryChangedObjectIds: geometryChangedObjectIds,
    appearanceChanged: appearanceChanged,
    textChanged: textChanged,
    metadataChanged: metadataChanged,
    addedResourceReferences: removedResourceReferences,
    removedResourceReferences: addedResourceReferences,
  );

  _Prepared merge(_Prepared later) {
    final added = {
      ...addedResourceReferences,
      ...later.addedResourceReferences,
    };
    final removed = {
      ...removedResourceReferences,
      ...later.removedResourceReferences,
    };
    final mergedOldBounds = <ObjectId, Rect2>{
      ...later.oldObjectBounds,
      ...oldObjectBounds,
    };
    final mergedNewBounds = <ObjectId, Rect2>{
      ...newObjectBounds,
      ...later.newObjectBounds,
    };
    return _Prepared(
      before: before,
      after: later.after,
      objectIds: {...objectIds, ...later.objectIds},
      pageIds: {...pageIds, ...later.pageIds},
      layerIds: {...layerIds, ...later.layerIds},
      oldObjectBounds: mergedOldBounds,
      newObjectBounds: mergedNewBounds,
      geometryChangedObjectIds: _boundChangedObjectIds(
        mergedOldBounds,
        mergedNewBounds,
      ),
      appearanceChanged: appearanceChanged || later.appearanceChanged,
      textChanged: textChanged || later.textChanged,
      metadataChanged: metadataChanged || later.metadataChanged,
      addedResourceReferences: added.difference(removed),
      removedResourceReferences: removed.difference(added),
    );
  }
}

Rect2? _aggregateRectangles(Iterable<Rect2> bounds) {
  Rect2? aggregate;
  for (final value in bounds) {
    aggregate = aggregate == null
        ? value
        : Rect2.fromEdges(
            left: aggregate.left < value.left ? aggregate.left : value.left,
            top: aggregate.top < value.top ? aggregate.top : value.top,
            right: aggregate.right > value.right
                ? aggregate.right
                : value.right,
            bottom: aggregate.bottom > value.bottom
                ? aggregate.bottom
                : value.bottom,
          ).fold(onOk: (result) => result, onErr: (_) => null);
    if (aggregate == null) return null;
  }
  return aggregate;
}

bool _sameKeys<K, V>(Map<K, V> left, Map<K, V> right) =>
    _setEquals(left.keys.toSet(), right.keys.toSet());

bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

Set<ObjectId> _boundChangedObjectIds(
  Map<ObjectId, Rect2> oldBounds,
  Map<ObjectId, Rect2> newBounds,
) => Set<ObjectId>.unmodifiable(
  oldBounds.keys.where((id) => oldBounds[id] != newBounds[id]),
);

final class _HistoryEntry {
  _HistoryEntry({
    required this.before,
    required this.after,
    required this.beforeIdentity,
    required this.afterIdentity,
    required this.family,
    required this.correlationId,
    required this.description,
    required this.coalescing,
    required this.prepared,
    required this.cost,
  });
  final DocumentRoot before;
  final DocumentRoot after;
  final ContentIdentity beforeIdentity;
  final ContentIdentity afterIdentity;
  final CommandFamily family;
  final CommandCorrelationId correlationId;
  final String description;
  final CommandCoalescing? coalescing;
  final _Prepared prepared;
  final HistoryRetainedCost cost;
}

final class _HistoryPlan {
  const _HistoryPlan(this.entries, this.cursor);
  final List<_HistoryEntry> entries;
  final int cursor;
}

final class _CandidateBuildFailure implements Exception {
  const _CandidateBuildFailure();
}

CommandFailure _failure(String leaf, FailureCategory category) =>
    CommandFailure(code: 'documents.commands.$leaf', category: category);
