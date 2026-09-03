// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' hide HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../core/versioning/schema_version.dart';
import '../../documents/commands.dart';
import '../../documents/document_model.dart';
import '../../documents/files.dart';
import '../../documents/objects/handwriting.dart';
import '../../drawing/geometry.dart';
import '../../drawing/hit_testing.dart';
import '../../drawing/renderer.dart';
import '../../drawing/selection.dart';
import '../../drawing/tools.dart';
import '../../drawing/viewport.dart';
import 'flutter_image_decoder.dart';
import 'flutter_text_layout_engine.dart';
import 'phase6_canvas_runtime.dart';
import 'phase6_diagnostics.dart';

enum _CanvasTool { pen, wholeEraser, selection, shape, text }

enum _SelectionTransformMode { move, resize, rotate }

enum _TextResizeHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
}

enum _InlineTextCommitOutcome { committed, noChange, rejected }

const double _selectionDragThreshold = 6;
const int _penPreviewChunkPrimitiveLimit = 192;
const double _workspacePadding = 24;
const int _maximumPendingNavigationOperations = 256;

/// Accessible Phase 6 Canvas vertical-slice experience.
final class Phase6Canvas extends StatefulWidget {
  /// Creates the Canvas.
  const Phase6Canvas({
    required this.runtime,
    this.renderingRegistryOverride,
    this.textLayoutEngineOverride,
    super.key,
  });

  /// Explicit production or test runtime dependencies.
  final Phase6CanvasRuntime runtime;

  /// Renderer override used by bounded adversarial widget tests.
  @visibleForTesting
  final RenderingRegistry? renderingRegistryOverride;

  /// Text layout override used by bounded adversarial widget tests.
  @visibleForTesting
  final TextLayoutEngine? textLayoutEngineOverride;
  @override
  State<Phase6Canvas> createState() => _Phase6CanvasState();
}

/// Read-only in-memory persistence evidence exposed by the Canvas painter.
abstract interface class Phase6CanvasPersistenceEvidence {
  /// Exact immutable bytes captured by the latest successful Save.
  List<int>? get savedBytes;

  /// Exact document root captured by the latest successful Save.
  DocumentRoot? get savedRoot;

  /// Document root currently owned by the active coordinator.
  DocumentRoot get currentRoot;

  /// Exact materialized root installed by the latest successful Reopen.
  DocumentRoot? get reopenedMaterializedRoot;

  /// Current transformed Page clip, when a scene is available.
  Rect2? get pageClip;

  /// Active bounded overlay primitive count.
  int get previewPrimitiveCount;

  /// Current Selection-plane primitive count.
  int get selectionPrimitiveCount;

  /// Current authoritative Selection frame, when Selection is nonempty.
  Phase6SelectionFrameEvidence? get selectionFrame;

  /// Complete accepted Eraser path length retained for terminal publication.
  int get eraserPathLength;

  /// Whole-Eraser segments accepted by the current gesture plan.
  int get wholeSegmentCount;

  /// Cached Whole-Eraser geometry checks performed by the current plan.
  int get wholeGeometryChecks;
}

/// Read-only lightweight Eraser cursor evidence exposed by its isolated painter.
abstract interface class Phase6EraserCursorEvidence {
  /// Latest normalized View-space cursor center, or null while hidden.
  ViewPoint? get cursorPosition;
}

/// Read-only deterministic evidence from the isolated live-Pen overlay.
abstract interface class Phase6PenPreviewEvidence {
  /// Latest accepted Page-space sample represented by the overlay.
  Point2? get latestAcceptedSampleCenter;

  /// Number of authoritative samples incorporated into preview geometry.
  int get previewedSampleCount;

  /// Previously recorded bounded chunks retained without reconstruction.
  int get frozenChunkCount;

  /// Current bounded, not-yet-frozen primitive count.
  int get activePrimitiveCount;

  /// Bounds of the newest rendered tail primitive in View space.
  Rect2? get latestPrimitiveBounds;
}

/// Read-only evidence from the independent paper-only Pen cursor.
abstract interface class Phase6PenCursorEvidence {
  /// Exact newest raw View-space pointer center, or null when hidden.
  ViewPoint? get cursorPosition;

  /// Number of synchronous cursor-position publications.
  int get updateCount;

  /// Number of cursor-only paint invocations.
  int get paintCount;
}

/// Immutable geometry evidence shared by Selection painting and interaction.
abstract interface class Phase6SelectionFrameEvidence {
  /// Clockwise View-space corners beginning at the visible top-left corner.
  List<Point2> get viewCorners;

  /// Visible rotation-circle center in View space.
  Point2 get rotationCenter;

  /// Connector endpoint on the visible top edge.
  Point2 get rotationConnectorStart;

  /// Connector endpoint at the visible circle.
  Point2 get rotationConnectorEnd;

  /// View-space radius of the circular rotation handle.
  double get rotationRadius;

  /// Whether this is the editable intrinsic frame for one Text Object.
  bool get isSingleText;
}

final class _Phase6CanvasState extends State<Phase6Canvas>
    with WidgetsBindingObserver {
  late final ObjectRegistry _registry;
  late final StrokeGeometryResolver _geometry;
  late final PageHitTester _hitTester;
  late final PageSceneBuilder _sceneBuilder;
  late final ToolRegistry _toolRegistry;
  late final InteractionGestureRouter _router;
  late DocumentMutationCoordinator _coordinator;
  late SelectionController _selection;
  late ViewportSnapshot _viewport;
  late ViewportController _viewportController;
  late final _EraserCursorController _eraserCursor;
  CommittedPageScene? _committedScene;
  DocumentPage? _committedPage;
  _CommittedPaintEvidence? _committedPaintEvidence;
  List<_CommittedPaintChunk> _displayCommittedPaintChunks = const [];
  _CommittedPaintEvidence? _displayCommittedPaintSource;
  Set<ObjectId> _displayCommittedPaintExclusions = const {};
  int _nextCommittedPaintChunkId = 0;
  CommittedPageScene? _committedDisplaySource;
  RenderSnapshot? _committedDisplay;
  Set<ObjectId> _committedDisplayExclusions = const {};
  PenGestureSession? _pen;
  PenDocumentIdentitySnapshot? _penIdentitySnapshot;
  Stopwatch? _pendingPenReadyClock;
  Revision? _pendingPenPaintRevision;
  final List<ScenePrimitive> _penActivePreviewPrimitives = [];
  late final ValueNotifier<List<_PenFrozenLayer>> _penFrozenPreviewLayers;
  late final _PenPreviewController _penPreviewOverlay;
  late final _PenCursorController _penCursor;
  int _penPreviewPrimitiveCount = 0;
  int _penPreviewedSampleCount = 0;
  int _penRawPointCount = 0;
  int _penVisualUpdateRequests = 0;
  int _penPreviewRepaints = 0;
  int _penMaximumPendingVisualWork = 0;
  int _penCommittedSceneRebuilds = 0;
  int _penGeometryResolutions = 0;
  int _penPreviewPaintInvocations = 0;
  int _penFrozenPictureReplays = 0;
  int _penMaximumActivePaintPrimitives = 0;
  int _penMaximumRetainedPictures = 0;
  int _penCompactions = 0;
  int _penParentBuilds = 0;
  int _penCommittedChunksRetained = 0;
  int _penCommittedChunksRebuilt = 0;
  int _penUnchangedObjectsReplayed = 0;
  int _penNewObjectsRendered = 0;
  int _penCommittedPrimitivesPainted = 0;
  int _penNativeResourcesCreated = 0;
  int _penNativeResourcesDisposed = 0;
  int _penFirstCommittedPaintInvocations = 0;
  ObjectId? _pendingPenAddedObjectId;
  bool _penPreviewAwaitingCommittedPaint = false;
  bool _penPreviewReleaseScheduled = false;
  int _penNextLayerId = 0;
  _CanvasTool _tool = _CanvasTool.pen;
  final List<Point2> _wholeEraserPath = [];
  ScenePrimitive? _eraserPreviewPrimitive;
  final Map<ObjectId, List<ScenePrimitive>> _eraserObjectPreviews = {};
  WholeEraseGesturePlan? _wholeEraserPlan;
  Point2? _selectionDown;
  Point2? _selectionCurrent;
  _SelectionTransformMode? _selectionTransformMode;
  Point2? _selectionTransformDown;
  Rect2? _selectionTransformBounds;
  Point2? _selectionTransformPivot;
  double? _selectionTransformInitialViewWidth;
  double? _selectionTransformInitialViewHeight;
  _TextResizeHandle? _selectionResizeHandle;
  bool _selectionResizeClampedToInitial = false;
  _SelectionTransformRenderEvidence? _selectionTransformEvidence;
  _SelectionTransformPreparation? _selectionTransformPreparation;
  Point2? _creationDown;
  Point2? _creationCurrent;
  ShapeKind _shapeCreationKind = ShapeKind.rectangle;
  bool _shapeStrokeEnabled = true;
  bool _shapeFillEnabled = false;
  int _shapeArgb = 0xff17324d;
  List<int>? _savedBytes;
  DocumentRoot? _savedRoot;
  DocumentRoot? _reopenedMaterializedRoot;
  String _status = 'Ready';
  int _cursorRepaintRequests = 0;
  int _cursorRepaints = 0;
  final Map<ImageDecodeCacheKey, FlutterDecodedImage> _decodedImages = {};
  final Map<ImageDecodeCacheKey, CancellationController> _imageDecodes = {};
  int _decodedImagePixels = 0;
  bool _imageRefreshScheduled = false;
  _TextDialogResult? _activeTextDraft;
  _InlineTextSession? _inlineText;
  TextEditingController? _inlineTextController;
  FocusNode? _inlineTextFocus;
  int? _inlineResizePointer;
  _TextResizeHandle? _inlineResizeHandle;
  Rect2? _inlineResizeStartBounds;
  AffineTransform2D? _inlineResizeSourceTransform;
  late final TextEditingController _zoomController;
  late final FocusNode _zoomFocus;
  late final FocusNode _canvasFocus;
  int? _navigationPointer;
  ViewPoint? _navigationLast;
  double _panZoomScale = 1;
  ViewPoint? _panZoomFocalPoint;
  double _textFontSize = 24;
  bool _textBold = false;
  bool _textItalic = false;
  TextAlignment _textAlignment = TextAlignment.left;
  int _textArgb = 0xff17324d;
  int? _lastSelectionTapMicros;
  Point2? _lastSelectionTapPoint;
  bool _navigationFrameScheduled = false;
  final List<_PendingNavigationOperation> _pendingNavigationOperations = [];
  bool _canvasExtentInitialized = false;
  int _textLayoutRequests = 0;
  int _textLayoutCacheHits = 0;
  int _textTransformRequests = 0;
  int _textPreviewRepaints = 0;
  int _selectionTransformFrameUpdates = 0;
  int _selectionTransformRegistryResolutions = 0;
  int _selectionTransformRendererPreparations = 0;
  int _selectionTransformCompositions = 0;
  int _selectionTransformMaximumRetainedEvidence = 0;
  _PendingSelectionTransformUpdate? _pendingSelectionTransformUpdate;
  _PendingSelectionTransformUpdate? _lastSelectionTransformUpdate;
  bool _selectionTransformFrameScheduled = false;
  int _selectionTransformGeneration = 0;
  _TextResizeHandle? _hoverTextResizeHandle;
  _SelectionFrameSnapshot? _selectionFrame;
  bool _leftShiftDown = false;
  bool _rightShiftDown = false;
  int _shiftKeyDownEvents = 0;
  int _shiftKeyUpEvents = 0;
  int _shiftPointerUpdates = 0;
  int _snappedPreviewUpdates = 0;
  double? _selectionRotationLastPointerAngle;
  Point2? _selectionRotationLastPointerPoint;
  double _selectionRotationUnwrappedAngle = 0;
  bool _selectionRotationIdentityPreview = false;
  int _selectionRotationUnwrappedTransitions = 0;
  int _selectionRotationIdentityEntries = 0;
  int _selectionRotationIdentityExits = 0;
  int _selectionRotationBranchCrossings = 0;
  int _selectionTransformPictureCreations = 0;
  int _selectionTransformHandwritingPreparations = 0;
  int _selectionTransformFramePrimitiveRebuilds = 0;
  int _selectionTransformUnrelatedReplays = 0;
  int _selectionTransformPublications = 0;
  int _lastSelectionHoverZoneCode = 0;
  int _lastSelectionCursorCode = 0;
  int _selectionTransformFailureStageCode = 0;

  HandwritingLimits get _limits => widget.runtime.handwritingLimits;
  UuidGenerator get _uuid => widget.runtime.uuidGenerator;
  Phase6DiagnosticTrace get _diagnostics => widget.runtime.diagnosticTrace;

  _SelectionTransformRenderEvidence? get _currentSelectionTransformEvidence {
    final evidence = _selectionTransformEvidence;
    final preparation = _selectionTransformPreparation;
    if (evidence == null ||
        preparation == null ||
        evidence.documentRevision != _coordinator.snapshot.revisions.document ||
        evidence.viewportRevision != _viewport.revision ||
        !_selectionTransformPreparationIsCurrent(preparation) ||
        !_sameObjectIds(evidence.targetIds, preparation.targetIds)) {
      return null;
    }
    return evidence;
  }

  bool get _selectionTransformPreviewReady =>
      _currentSelectionTransformEvidence != null;

  void _pictureCreated() {
    if (_pen != null || _penPreviewAwaitingCommittedPaint) {
      _penNativeResourcesCreated += 1;
    }
    try {
      widget.runtime.nativePictureObserver.pictureCreated();
    } on Object {
      // Accounting observers cannot affect Canvas ownership.
    }
  }

  void _pictureDisposed() {
    if (_pen != null || _penPreviewAwaitingCommittedPaint) {
      _penNativeResourcesDisposed += 1;
    }
    try {
      widget.runtime.nativePictureObserver.pictureDisposed();
    } on Object {
      // Accounting observers cannot affect Canvas ownership.
    }
  }

  void _disposePicture(ui.Picture picture) {
    try {
      picture.dispose();
    } on Object {
      // Native cleanup is best-effort and must not interrupt other cleanup.
    } finally {
      _pictureDisposed();
    }
  }

  Future<void> _copyDiagnostics() async {
    Result<void, StructuredFailure>? copied;
    try {
      copied = await widget.runtime.debugClipboard.copyText(
        _diagnostics.copyText(),
      );
    } on Object {
      copied = null;
    }
    if (!mounted) return;
    setState(
      () => _status = copied is Ok<void, StructuredFailure>
          ? 'Diagnostics copied'
          : 'Diagnostics copy failed',
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    try {
      _pen?.cancel();
    } on Object {
      // Cleanup remains best-effort and idempotent at platform boundaries.
    }
    _pen = null;
    _clearCanvasModifierState(recomputeRotation: false);
    _router.cancel();
    _clearEraserTransient();
    _clearPenPreview();
    _penPreviewOverlay.dispose();
    _penFrozenPreviewLayers.dispose();
    _penCursor.dispose();
    _clearPendingSelectionTransformUpdate();
    _disposeSelectionTransformPreparation();
    _eraserCursor.dispose();
    for (final controller in _imageDecodes.values) {
      controller.cancel();
    }
    _imageDecodes.clear();
    for (final image in _decodedImages.values) {
      image.dispose();
    }
    _decodedImages.clear();
    _decodedImagePixels = 0;
    _disposeInlineTextEditor();
    _zoomFocus.removeListener(_editableFocusChanged);
    _zoomFocus.dispose();
    _zoomController.dispose();
    _canvasFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _penFrozenPreviewLayers = ValueNotifier(const []);
    _canvasFocus = FocusNode(debugLabel: 'Canvas keyboard boundary');
    _penPreviewOverlay = _PenPreviewController(
      frozen: _penFrozenPreviewLayers,
      active: _penActivePreviewPrimitives,
    );
    _penCursor = _PenCursorController();
    _eraserCursor = _EraserCursorController(
      onRequest: () {
        _cursorRepaintRequests += 1;
        if (_shouldRecordExponentialProgress(_cursorRepaintRequests)) {
          _diagnostics.record(
            stage: Phase6DiagnosticStage.cursorRepaintRequested,
            pointerSegments: _wholeEraserPlan?.processedSegmentCount ?? 0,
            repaints: _cursorRepaintRequests,
          );
        }
      },
      onRepaint: (elapsedMicros) {
        _cursorRepaints += 1;
        if (_shouldRecordExponentialProgress(_cursorRepaints)) {
          _diagnostics.record(
            stage: Phase6DiagnosticStage.cursorRepaintCompleted,
            pointerSegments: _wholeEraserPlan?.processedSegmentCount ?? 0,
            repaints: _cursorRepaints,
            elapsedMicros: elapsedMicros,
          );
        }
      },
    );
    WidgetsBinding.instance.addObserver(this);
    _registry = widget.runtime.objectRegistry;
    _geometry = widget.runtime.geometryResolver;
    _hitTester = PageHitTester(
      objectRegistry: _registry,
      hitTestingRegistry: widget.runtime.hitTestingRegistry,
      maximumCandidates: widget.runtime.maximumHitResults,
      maximumResults: widget.runtime.maximumHitResults,
      maximumLassoPoints: widget.runtime.maximumLassoPoints,
    );
    _sceneBuilder = PageSceneBuilder(
      objectRegistry: _registry,
      renderingRegistry: widget.runtime.renderingRegistry,
      limits: widget.runtime.renderingLimits,
    );
    _toolRegistry = widget.runtime.toolRegistry;
    _router = InteractionGestureRouter(
      resolver: InteractionResolver(
        registry: widget.runtime.actionRegistry,
        profile: widget.runtime.bindingProfile,
      ),
      ownership: PointerOwnership(),
    );
    _coordinator = widget.runtime.initialCoordinator;
    _selection = SelectionController(
      objectRegistry: _registry,
      coalescingBoundarySink: _coordinator,
      maximumTargets: widget.runtime.maximumSelectionTargets,
      handwritingLimits: _limits,
      strokeGeometryResolver: _geometry,
      handwritingGeometryCache: widget.runtime.geometryCache,
    );
    _viewport = _ok(
      ViewportSnapshot.create(
        extent: _ok(ViewExtent.create(width: 640, height: 800)),
        pageOrigin: _point(0, 0),
        zoom: 1,
        minimumZoom: .25,
        maximumZoom: 8,
        revision: _revision(0),
      ),
    );
    _viewportController = ViewportController(
      initial: _viewport,
      maximumListeners: widget.runtime.maximumListeners,
    );
    _zoomController = TextEditingController(text: '100');
    _zoomFocus = FocusNode(debugLabel: 'Canvas zoom editor');
    _zoomFocus.addListener(_editableFocusChanged);
  }

  bool get _editableFieldFocused =>
      (_inlineTextFocus?.hasFocus ?? false) || _zoomFocus.hasFocus;

  void _editableFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _inlineText != null) {
      _commitInlineTextEditor();
    }
    if (state != AppLifecycleState.resumed && _router.ownership.owner != null) {
      _cancelGesture('Gesture cancelled');
    }
    if (state != AppLifecycleState.resumed) {
      _clearCanvasModifierState(recomputeRotation: false);
      _cancelNavigation();
    }
  }

  DocumentPage get _page => _coordinator.snapshot.root.pages.single;
  LayerId get _layerId => _page.layers.whereType<ContentLayer>().first.id;

  ObjectEnvelope? get _selectedTextObject {
    if (_inlineText != null) return null;
    final targets = _selection.state.targets;
    if (targets.length != 1 || !targets.single.isWholeObject) return null;
    final id = targets.single.objectId;
    return _page.layers
        .expand((layer) => layer.objects)
        .where(
          (object) => object.id == id && object.typeKey == textObjectTypeKey,
        )
        .firstOrNull;
  }

  void _setTool(_CanvasTool value) {
    if (!_toolRegistry.definitions.containsKey(_toolId(value))) return;
    if (_inlineText != null && !_commitInlineTextEditor()) return;
    _pen?.cancel();
    _router.cancel();
    _cancelNavigation();
    _selection.cancelTransform();
    _selectionTransformEvidence = null;
    _disposeSelectionTransformPreparation();
    _eraserCursor.clear();
    _penCursor.clear();
    if (_tool == _CanvasTool.selection && value != _CanvasTool.selection) {
      final discarded = _selection.discard();
      if (discarded is! Ok<SelectionState, SelectionFailure>) {
        setState(() => _status = 'Selection clear failed');
        return;
      }
    }
    setState(() {
      _pen = null;
      _clearPenPreview();
      _clearEraserTransient();
      _selectionDown = null;
      _selectionCurrent = null;
      _selectionTransformMode = null;
      _selectionTransformDown = null;
      _selectionTransformBounds = null;
      _creationDown = null;
      _creationCurrent = null;
      _tool = value;
      _status = '${value.name} active';
    });
  }

  void _undo() {
    if (_inlineText != null && !_commitInlineTextEditor()) return;
    _invalidateSelectionTransformForExternalChange();
    final result = _coordinator.undo();
    _selection.reconcile(_coordinator.snapshot.root);
    setState(() {
      _status = result is Ok ? 'Undone' : 'Nothing to undo';
    });
  }

  void _redo() {
    if (_inlineText != null && !_commitInlineTextEditor()) return;
    _invalidateSelectionTransformForExternalChange();
    final result = _coordinator.redo();
    _selection.reconcile(_coordinator.snapshot.root);
    setState(() {
      _status = result is Ok ? 'Redone' : 'Nothing to redo';
    });
  }

  void _pointer(PointerEvent raw) {
    final normalized = widget.runtime.pointerAdapter.normalize(raw);
    if (normalized is! Ok<NormalizedPointerEvent, StructuredFailure>) {
      if (_router.ownership.owner == raw.pointer) {
        _cancelGesture('Gesture rejected');
      }
      return;
    }
    final event = normalized.value;
    final routed = _router.route(
      event,
      InteractionContextSnapshot(
        activeTool: _tool.name,
        pageRevision: _coordinator.snapshot.revisions.pages[_page.id]!,
        suspended: false,
      ),
    );
    if (routed is! Ok<RoutedInteraction?, StructuredFailure> ||
        routed.value == null) {
      if (routed is Err<RoutedInteraction?, StructuredFailure>) {
        _cancelGesture('Gesture rejected');
      }
      return;
    }
    final route = routed.value!;
    final routedTool = _CanvasTool.values
        .where((value) => _actionId(value) == route.action.id)
        .firstOrNull;
    if (routedTool == null ||
        !_toolRegistry.definitions.containsKey(_toolId(routedTool))) {
      _cancelGesture('Gesture rejected');
      return;
    }
    final pagePoint = _viewport
        .viewToPage(event.viewPosition)
        .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    if (pagePoint == null) {
      _cancelGesture('Gesture rejected');
      return;
    }
    if (event.phase == PointerPhase.down) {
      if (routedTool == _CanvasTool.pen) {
        var identitySnapshot = _penIdentitySnapshot;
        if (identitySnapshot == null ||
            !identical(identitySnapshot.root, _coordinator.snapshot.root)) {
          final captured = PenDocumentIdentitySnapshot.capture(
            root: _coordinator.snapshot.root,
            handwritingLimits: _limits,
            maximumIdentities: widget.runtime.maximumHitResults,
          );
          if (captured is! Ok<PenDocumentIdentitySnapshot, StructuredFailure>) {
            _cancelGesture('Gesture rejected');
            return;
          }
          identitySnapshot = captured.value;
          _penIdentitySnapshot = identitySnapshot;
        }
        final started = PenGestureSession.start(
          down: event,
          document: _coordinator.snapshot,
          pageId: _page.id,
          layerId: _layerId,
          viewport: _viewport,
          preset: PenPreset.fromStyle(widget.runtime.penStyle),
          maximumSamples: widget.runtime.maximumPenSamples,
          handwritingLimits: _limits,
          uuidGenerator: _uuid,
          maximumCommandOperations: widget.runtime.maximumCommandOperations,
          identitySnapshot: identitySnapshot,
        );
        if (started is Ok<PenGestureSession, StructuredFailure>) {
          if (_penPreviewAwaitingCommittedPaint) {
            _pendingPenReadyClock?.stop();
            _pendingPenReadyClock = null;
            _pendingPenPaintRevision = null;
            _pendingPenAddedObjectId = null;
            _penPreviewAwaitingCommittedPaint = false;
            _penPreviewReleaseScheduled = false;
            _clearPenPreview();
          }
          _pen = started.value;
          _penRawPointCount = 1;
          _penVisualUpdateRequests = 1;
          _penPreviewRepaints = 1;
          _penMaximumPendingVisualWork = 0;
          _penCommittedSceneRebuilds = 0;
          _penGeometryResolutions = 0;
          _penPreviewPaintInvocations = 0;
          _penFrozenPictureReplays = 0;
          _penMaximumActivePaintPrimitives = 0;
          _penMaximumRetainedPictures = 0;
          _penCompactions = 0;
          _penParentBuilds = 0;
          _penCommittedChunksRetained = 0;
          _penCommittedChunksRebuilt = 0;
          _penUnchangedObjectsReplayed = 0;
          _penNewObjectsRendered = 0;
          _penCommittedPrimitivesPainted = 0;
          _penNativeResourcesCreated = 0;
          _penNativeResourcesDisposed = 0;
          _penFirstCommittedPaintInvocations = 0;
          _pendingPenAddedObjectId = null;
          _penPreviewAwaitingCommittedPaint = false;
          _penPreviewReleaseScheduled = false;
          if (!_appendPenPreviewTail()) {
            _cancelGesture('Gesture rejected');
            return;
          }
          setState(() {
            _status = 'Drawing';
          });
        } else {
          _cancelGesture('Gesture rejected');
        }
      } else if (routedTool == _CanvasTool.wholeEraser) {
        _eraserCursor.update(event.viewPosition);
        _beginWholeErase(pagePoint);
      } else if (routedTool == _CanvasTool.selection) {
        _beginSelection(pagePoint, event.timeMicros);
      } else {
        _creationDown = pagePoint;
        _creationCurrent = pagePoint;
        setState(
          () => _status = routedTool == _CanvasTool.shape
              ? 'Creating shape'
              : 'Creating text box',
        );
      }
    } else if (_pen != null &&
        routedTool == _CanvasTool.pen &&
        event.phase == PointerPhase.move) {
      final updated = _pen!.update(event, viewportRevision: _viewport.revision);
      if (updated is Err<void, StructuredFailure>) {
        _cancelGesture('Stroke rejected');
        return;
      }
      _penRawPointCount += 1;
      if (!_updatePenPreviewImmediately()) {
        _cancelGesture('Stroke rejected');
      }
    } else if (routedTool == _CanvasTool.wholeEraser &&
        event.phase == PointerPhase.move) {
      _eraserCursor.update(event.viewPosition);
      if (!_appendWholeEraserPoint(pagePoint)) return;
    } else if (routedTool == _CanvasTool.selection &&
        event.phase == PointerPhase.move) {
      _updateSelection(pagePoint, event.modifiers);
    } else if ((routedTool == _CanvasTool.shape ||
            routedTool == _CanvasTool.text) &&
        event.phase == PointerPhase.move) {
      setState(() => _creationCurrent = pagePoint);
    } else if (_pen != null &&
        routedTool == _CanvasTool.pen &&
        event.phase == PointerPhase.up) {
      final totalClock = Stopwatch()..start();
      final normalizationClock = Stopwatch()..start();
      final terminalUpdate = _pen!.update(
        event,
        viewportRevision: _viewport.revision,
      );
      if (terminalUpdate is Err<void, StructuredFailure> ||
          !_flushPenPreviewUpdate()) {
        _cancelGesture('Stroke rejected');
        return;
      }
      normalizationClock.stop();
      _diagnostics.record(
        stage: Phase6DiagnosticStage.penTerminalNormalization,
        elapsedMicros: normalizationClock.elapsedMicroseconds,
      );
      _penRawPointCount += 1;
      final authoritativeSamples = _pen!.sampleCount;
      final before = _coordinator.snapshot;
      final previousCommitted = _committedScene;
      final requestClock = Stopwatch()..start();
      final request = _pen!.finish(
        event,
        latestDocument: _coordinator.snapshot,
        viewportRevision: _viewport.revision,
        pointerOwnerAtTerminal: _router.ownership.owner,
      );
      requestClock.stop();
      _diagnostics.record(
        stage: Phase6DiagnosticStage.penRequestConstruction,
        elapsedMicros: requestClock.elapsedMicroseconds,
      );
      var penCommitted = false;
      if (request is Ok<AtomicObjectCollectionEditRequest, StructuredFailure>) {
        final commit = _coordinator.execute(
          request.value,
          diagnostics: (stage, elapsedMicros) {
            final phase = switch (stage) {
              CommandExecutionDiagnosticStage.preparationValidation =>
                Phase6DiagnosticStage.penCoordinatorPreparation,
              CommandExecutionDiagnosticStage.historyAccounting =>
                Phase6DiagnosticStage.penHistoryAccounting,
              CommandExecutionDiagnosticStage.publicationObservers =>
                Phase6DiagnosticStage.penPublicationObservers,
            };
            _diagnostics.record(stage: phase, elapsedMicros: elapsedMicros);
          },
        );
        penCommitted = commit is Ok;
        if (penCommitted) {
          final after = _coordinator.snapshot;
          final advanced = _penIdentitySnapshot?.advance(
            before: before.root,
            after: after.root,
            request: request.value,
          );
          _penIdentitySnapshot =
              advanced is Ok<PenDocumentIdentitySnapshot, StructuredFailure>
              ? advanced.value
              : null;
          final sceneClock = Stopwatch()..start();
          final addedObjectId = (commit as Ok<CommandCommit, CommandFailure>)
              .value
              .change
              .addedObjectIds
              .singleOrNull;
          final increment =
              previousCommitted != null &&
                  previousCommitted.documentRevision ==
                      before.revisions.document &&
                  previousCommitted.viewportRevision == _viewport.revision &&
                  addedObjectId != null
              ? _sceneBuilder.appendCommittedObject(
                  previous: previousCommitted,
                  page: after.root.pages.single,
                  viewport: _viewport,
                  previousDocumentRevision: before.revisions.document,
                  documentRevision: after.revisions.document,
                  addedObjectId: addedObjectId,
                )
              : null;
          if (increment is Ok<CommittedPageScene, StructuredFailure>) {
            _committedPage = after.root.pages.single;
            _committedScene = increment.value;
            _committedDisplay = null;
            _committedDisplaySource = null;
            _committedDisplayExclusions = const {};
          }
          sceneClock.stop();
          _diagnostics.record(
            stage: Phase6DiagnosticStage.penCommittedSceneUpdate,
            elapsedMicros: sceneClock.elapsedMicroseconds,
            cacheHits: increment is Ok<CommittedPageScene, StructuredFailure>
                ? previousCommitted!.objects.length
                : 0,
            geometryResolutions:
                increment is Ok<CommittedPageScene, StructuredFailure> ? 1 : 0,
          );
          if (addedObjectId != null) {
            _pendingPenReadyClock = totalClock;
            _pendingPenPaintRevision = after.revisions.document;
            _pendingPenAddedObjectId = addedObjectId;
            _penPreviewAwaitingCommittedPaint = true;
          }
        }
        setState(() {
          _status = commit is Ok ? 'Stroke committed' : 'Stroke rejected';
          _pen = null;
          if (!_penPreviewAwaitingCommittedPaint) _clearPenPreview();
        });
      } else {
        setState(() {
          _status = 'Stroke rejected';
          _pen = null;
          _clearPenPreview();
        });
      }
      _diagnostics.record(
        stage: Phase6DiagnosticStage.penTerminal,
        rawPoints: _penRawPointCount,
        authoritativeSamples: authoritativeSamples,
        visualUpdates: _penVisualUpdateRequests,
        repaints: _penPreviewRepaints,
        pendingWork: _penMaximumPendingVisualWork,
        sceneCompositions: _penCommittedSceneRebuilds,
        terminalDisposition: penCommitted ? 1 : 2,
        geometryResolutions: _penGeometryResolutions,
        frozenReplays: _penFrozenPictureReplays,
        maximumActivePaintPrimitives: _penMaximumActivePaintPrimitives,
        maximumRetainedResources: _penMaximumRetainedPictures,
        parentRebuilds: _penParentBuilds,
        compactions: _penCompactions,
        previewPaints: _penPreviewPaintInvocations,
      );
      _router.completeTerminal(event.pointerId);
      final reconcileClock = Stopwatch()..start();
      _selection.reconcile(_coordinator.snapshot.root);
      reconcileClock.stop();
      _diagnostics.record(
        stage: Phase6DiagnosticStage.penSelectionReconciliation,
        elapsedMicros: reconcileClock.elapsedMicroseconds,
      );
      if (!penCommitted) {
        totalClock.stop();
        _diagnostics.record(
          stage: Phase6DiagnosticStage.penPointerUpReady,
          elapsedMicros: totalClock.elapsedMicroseconds,
          terminalDisposition: 2,
        );
      }
    } else if (routedTool == _CanvasTool.wholeEraser &&
        event.phase == PointerPhase.up) {
      _eraserCursor.clear();
      if (!_appendWholeEraserPoint(pagePoint, publish: false)) return;
      _finishWholeErase();
      _router.completeTerminal(event.pointerId);
    } else if (routedTool == _CanvasTool.selection &&
        event.phase == PointerPhase.up) {
      _finishSelection(pagePoint);
      _router.completeTerminal(event.pointerId);
    } else if (routedTool == _CanvasTool.shape &&
        event.phase == PointerPhase.up) {
      _creationCurrent = pagePoint;
      _finishShapeCreation();
      _router.completeTerminal(event.pointerId);
    } else if (routedTool == _CanvasTool.text &&
        event.phase == PointerPhase.up) {
      _creationCurrent = pagePoint;
      final bounds = _creationBounds(defaultWidth: 180, defaultHeight: 80);
      _creationDown = null;
      _creationCurrent = null;
      _router.completeTerminal(event.pointerId);
      if (bounds != null) _openTextEditor(bounds);
    } else if (event.phase == PointerPhase.up) {
      _router.completeTerminal(event.pointerId);
    } else if (event.phase == PointerPhase.cancel) {
      _cancelGesture('Gesture cancelled');
    }
  }

  void _beginWholeErase(Point2 point) {
    _diagnostics.beginGesture();
    _clearEraserTransient();
    final prepared = WholeEraseGesturePlan.prepare(
      document: _coordinator.snapshot,
      pageId: _page.id,
      radius: 8 / _viewport.zoom,
      handwritingLimits: _limits,
      objectRegistry: _registry,
      hitTestingRegistry: widget.runtime.hitTestingRegistry,
      geometryResolver: _geometry,
      geometryCache: widget.runtime.geometryCache,
      maximumObjects: widget.runtime.maximumHitResults,
      maximumStrokes: _limits.maximumStrokes,
      maximumPoints: widget.runtime.maximumEraserPoints,
      maximumTargets: widget.runtime.maximumHitResults,
      maximumOperations: widget.runtime.maximumCommandOperations,
    );
    if (prepared is! Ok<WholeEraseGesturePlan, StructuredFailure>) {
      _cancelGesture('Erase rejected');
      return;
    }
    _wholeEraserPlan = prepared.value;
    if (!_appendWholeEraserPoint(point, publish: false)) return;
    setState(() => _status = 'Whole erasing');
  }

  Rect2? _creationBounds({double? defaultWidth, double? defaultHeight}) {
    final start = _creationDown;
    final end = _creationCurrent;
    if (start == null || end == null) return null;
    final left = math.min(start.x, end.x);
    final top = math.min(start.y, end.y);
    var right = math.max(start.x, end.x);
    var bottom = math.max(start.y, end.y);
    if (right == left && defaultWidth != null) right += defaultWidth;
    if (bottom == top && defaultHeight != null) bottom += defaultHeight;
    return Rect2.fromEdges(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
  }

  void _finishShapeCreation() {
    final payload = _shapeCreationPayload();
    final transform = AffineTransform2D.fromOperation(
      const IdentityTransformOperation2D(),
    ).fold<AffineTransform2D?>(onOk: (value) => value, onErr: (_) => null);
    final committed = payload != null && transform != null
        ? _publishNewObject(
            typeKey: shapeObjectTypeKey,
            schemaVersion: shapeSchemaVersion,
            payload: payload.encode(),
            transform: transform,
            description: 'Create shape',
          )
        : false;
    _creationDown = null;
    _creationCurrent = null;
    _selection.reconcile(_coordinator.snapshot.root);
    setState(() => _status = committed ? 'Shape created' : 'Shape rejected');
  }

  ShapePayload? _shapeCreationPayload() {
    final start = _creationDown;
    final end = _creationCurrent;
    if (start == null || end == null || start == end) return null;
    final isLine = _shapeCreationKind == ShapeKind.line;
    if ((isLine && (!_shapeStrokeEnabled || _shapeFillEnabled)) ||
        (!isLine && !_shapeStrokeEnabled && !_shapeFillEnabled)) {
      return null;
    }
    final bounds = _creationBounds();
    ShapeGeometry? geometry;
    if (_shapeCreationKind == ShapeKind.line) {
      geometry = ShapeLineGeometry.create(
        start: start,
        end: end,
        limits: widget.runtime.shapeLimits,
      ).fold<ShapeGeometry?>(onOk: (value) => value, onErr: (_) => null);
    } else if (bounds != null && _shapeCreationKind == ShapeKind.rectangle) {
      geometry = ShapeRectangleGeometry.create(
        bounds: bounds,
        limits: widget.runtime.shapeLimits,
      ).fold<ShapeGeometry?>(onOk: (value) => value, onErr: (_) => null);
    } else if (bounds != null) {
      geometry = ShapeEllipseGeometry.create(
        bounds: bounds,
        limits: widget.runtime.shapeLimits,
      ).fold<ShapeGeometry?>(onOk: (value) => value, onErr: (_) => null);
    }
    final color = _shapeColor(_shapeArgb);
    final style = color == null
        ? null
        : ShapeStyle.create(
            strokeEnabled: _shapeStrokeEnabled,
            strokeColor: color,
            strokeWidth: 3,
            cap: ShapeStrokeCap.round,
            join: ShapeStrokeJoin.round,
            miterLimit: 4,
            dashArray: const [],
            dashOffset: 0,
            fillEnabled: _shapeFillEnabled,
            fillColor: color,
            fillRule: ShapeFillRule.nonZero,
            opacity: 1,
            startArrowhead: ShapeArrowhead.none,
            endArrowhead: ShapeArrowhead.none,
            limits: widget.runtime.shapeLimits,
          ).fold<ShapeStyle?>(onOk: (value) => value, onErr: (_) => null);
    final payload = geometry == null || style == null
        ? null
        : ShapePayload.create(
            geometry: geometry,
            style: style,
            limits: widget.runtime.shapeLimits,
          ).fold<ShapePayload?>(onOk: (value) => value, onErr: (_) => null);
    return payload;
  }

  bool _openTextEditor(Rect2 pageBounds, {ObjectEnvelope? existing}) {
    if (_inlineText != null && !_commitInlineTextEditor()) return false;
    final priorSelectionTargets = List<SelectionTarget>.unmodifiable(
      _selection.state.targets,
    );
    final prior = existing == null
        ? null
        : TextPayload.decode(
            existing.payload,
            limits: widget.runtime.textLimits,
          ).fold<TextPayload?>(onOk: (value) => value, onErr: (_) => null);
    if (existing != null && prior == null) {
      setState(() => _status = 'Text unavailable');
      return false;
    }
    if (prior != null && !prior.isSimpleDialogEditable) {
      setState(() => _status = 'Rich text editing unavailable');
      return false;
    }
    final baseObjectRevision = existing == null
        ? null
        : _coordinator.snapshot.revisions.objects[existing.id];
    final owningLayer = existing == null
        ? null
        : _page.layers
              .whereType<ContentLayer>()
              .where(
                (layer) =>
                    layer.objects.any((object) => object.id == existing.id),
              )
              .firstOrNull;
    final membershipRevision = owningLayer == null
        ? null
        : _coordinator.snapshot.revisions.layerMembership[owningLayer.id];
    if (existing != null &&
        (baseObjectRevision == null ||
            owningLayer == null ||
            membershipRevision == null)) {
      setState(() => _status = 'Text unavailable');
      return false;
    }
    if (prior != null) {
      Result<TextLayoutSnapshot, StructuredFailure>? preparedLayout;
      try {
        preparedLayout =
            (widget.textLayoutEngineOverride ?? widget.runtime.textLayoutEngine)
                .layout(TextLayoutRequest(payload: prior));
      } on Object {
        preparedLayout = null;
      }
      if (preparedLayout is! Ok<TextLayoutSnapshot, StructuredFailure>) {
        setState(() => _status = 'Text unavailable');
        return false;
      }
      final discarded = _selection.discard();
      if (discarded is! Ok<SelectionState, SelectionFailure>) {
        setState(() => _status = 'Text unavailable');
        return false;
      }
      _selection.cancelTransform();
      _selectionTransformEvidence = null;
      _disposeSelectionTransformPreparation();
      _selectionFrame = null;
      _selectionTransformMode = null;
      _selectionTransformDown = null;
      _selectionTransformBounds = null;
      _selectionTransformPivot = null;
      _selectionTransformInitialViewWidth = null;
      _selectionTransformInitialViewHeight = null;
      _selectionResizeHandle = null;
      _selectionResizeClampedToInitial = false;
      _hoverTextResizeHandle = null;
      _lastSelectionHoverZoneCode = 0;
      _lastSelectionCursorCode = 0;
      _clearPendingSelectionTransformUpdate();
      _resetSelectionTransformPerformanceEvidence();
    }
    final initial = _TextDialogResult(
      text: prior?.logicalText ?? '',
      fontSize: prior?.defaultCharacterStyle.fontSize ?? _textFontSize,
      bold: prior == null
          ? _textBold
          : prior.defaultCharacterStyle.weight >= 700,
      italic: prior?.defaultCharacterStyle.italic ?? _textItalic,
      alignment: prior?.defaultParagraphStyle.alignment ?? _textAlignment,
      argb: prior?.defaultCharacterStyle.argb ?? _textArgb,
    );
    final controller = TextEditingController(text: initial.text);
    final focus = FocusNode(debugLabel: 'Inline text editor');
    focus.addListener(_editableFocusChanged);
    void updateDraft() {
      if (!mounted || _inlineTextController != controller) return;
      _activeTextDraft = _currentTextDraft;
    }

    controller.addListener(updateDraft);
    _inlineTextController = controller;
    _inlineTextFocus = focus;
    _activeTextDraft = initial;
    _textFontSize = initial.fontSize;
    _textBold = initial.bold;
    _textItalic = initial.italic;
    _textAlignment = initial.alignment;
    _textArgb = initial.argb;
    setState(() {
      _inlineText = _InlineTextSession(
        pageBounds: pageBounds,
        existing: existing,
        prior: prior,
        baseObjectRevision: baseObjectRevision,
        documentId: _coordinator.snapshot.root.id,
        pageId: _page.id,
        layerId: owningLayer?.id,
        baseMembershipRevision: membershipRevision,
        priorSelectionTargets: priorSelectionTargets,
        removeControllerListener: updateDraft,
      );
      _status = existing == null ? 'Creating text box' : 'Editing text box';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _inlineTextFocus == focus) focus.requestFocus();
    });
    return true;
  }

  _TextDialogResult get _currentTextDraft => _TextDialogResult(
    text: _inlineTextController?.text ?? _activeTextDraft?.text ?? '',
    fontSize: _textFontSize,
    bold: _textBold,
    italic: _textItalic,
    alignment: _textAlignment,
    argb: _textArgb,
  );

  bool _commitInlineTextEditor() {
    final session = _inlineText;
    if (session == null) return true;
    final result = _currentTextDraft;
    final existing = session.existing;
    if (existing == null && result.text.isEmpty) {
      _closeInlineTextEditor(
        status: 'Text creation cancelled',
        rebuild: mounted,
      );
      return true;
    }
    final outcome = _commitTextDialog(
      session.pageBounds,
      result,
      session: session,
      existing: existing,
      prior: session.prior,
      baseObjectRevision: session.baseObjectRevision,
    );
    if (outcome == _InlineTextCommitOutcome.rejected) {
      if (mounted) {
        setState(() => _status = 'Text rejected; editor remains open');
        _inlineTextFocus?.requestFocus();
      }
      return false;
    }
    if (outcome == _InlineTextCommitOutcome.committed) {
      _selection.reconcile(_coordinator.snapshot.root);
    }
    _closeInlineTextEditor(
      status: outcome == _InlineTextCommitOutcome.noChange
          ? 'Text unchanged'
          : outcome == _InlineTextCommitOutcome.committed
          ? existing == null
                ? 'Text created'
                : 'Text updated'
          : 'Text rejected',
      rebuild: mounted,
    );
    return true;
  }

  void _cancelInlineTextEditor() {
    final session = _inlineText;
    final editing = session?.existing != null;
    if (session == null) return;
    _restoreInlineTextSelection(session);
    _closeInlineTextEditor(
      status: editing ? 'Text editing cancelled' : 'Text creation cancelled',
      rebuild: mounted,
    );
  }

  void _recordPendingPenCommittedPaint() {
    final clock = _pendingPenReadyClock;
    final revision = _pendingPenPaintRevision;
    if (clock == null ||
        revision == null ||
        revision != _coordinator.snapshot.revisions.document) {
      return;
    }
    clock.stop();
    final elapsed = clock.elapsedMicroseconds;
    _pendingPenReadyClock = null;
    _pendingPenPaintRevision = null;
    _pendingPenAddedObjectId = null;
    _penFirstCommittedPaintInvocations += 1;
    _diagnostics.record(
      stage: Phase6DiagnosticStage.penFirstCommittedPaint,
      elapsedMicros: elapsed,
      committedChunksRetained: _penCommittedChunksRetained,
      committedChunksRebuilt: _penCommittedChunksRebuilt,
      unchangedObjectsReplayed: _penUnchangedObjectsReplayed,
      newObjectsRendered: _penNewObjectsRendered,
      committedPrimitivesPainted: _penCommittedPrimitivesPainted,
      nativeResourcesCreated: _penNativeResourcesCreated,
      nativeResourcesDisposed: _penNativeResourcesDisposed,
      firstCommittedPaintInvocations: _penFirstCommittedPaintInvocations,
    );
    _diagnostics.record(
      stage: Phase6DiagnosticStage.penPointerUpReady,
      elapsedMicros: elapsed,
      terminalDisposition: 1,
      committedChunksRetained: _penCommittedChunksRetained,
      committedChunksRebuilt: _penCommittedChunksRebuilt,
      unchangedObjectsReplayed: _penUnchangedObjectsReplayed,
      newObjectsRendered: _penNewObjectsRendered,
      committedPrimitivesPainted: _penCommittedPrimitivesPainted,
      nativeResourcesCreated: _penNativeResourcesCreated,
      nativeResourcesDisposed: _penNativeResourcesDisposed,
      firstCommittedPaintInvocations: _penFirstCommittedPaintInvocations,
    );
  }

  void _recordCommittedChunkPaint(_CommittedPaintChunk chunk) {
    final added = _pendingPenAddedObjectId;
    if (added == null) return;
    _penCommittedPrimitivesPainted += chunk.primitives.length;
    final containsAddition = chunk.objects.any(
      (object) => object.objectId == added,
    );
    if (containsAddition) {
      _penNewObjectsRendered += 1;
      _recordPendingPenCommittedPaint();
    } else {
      _penUnchangedObjectsReplayed += chunk.objects.length;
    }
  }

  void _preparePendingPenCommittedPaint() {
    if (_penPreviewReleaseScheduled || !_penPreviewAwaitingCommittedPaint) {
      return;
    }
    _penPreviewReleaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _penPreviewReleaseScheduled = false;
      if (!_penPreviewAwaitingCommittedPaint) return;
      setState(() {
        _penPreviewAwaitingCommittedPaint = false;
        _clearPenPreview();
      });
    });
  }

  void _recordFlattenedCommittedPaint() {
    final added = _pendingPenAddedObjectId;
    final scene = _committedScene;
    if (added != null && scene != null) {
      _penCommittedPrimitivesPainted += scene.objects.fold<int>(
        0,
        (sum, object) => sum + object.primitives.length,
      );
      _penNewObjectsRendered +=
          scene.objects.any((object) => object.objectId == added) ? 1 : 0;
      _penUnchangedObjectsReplayed += scene.objects
          .where((object) => object.objectId != added)
          .length;
    }
    _recordPendingPenCommittedPaint();
  }

  void _restoreInlineTextSelection(_InlineTextSession session) {
    final targets = session.priorSelectionTargets;
    if (targets.isEmpty) return;
    final restored = _selection.replace(
      root: _coordinator.snapshot.root,
      targets: targets,
    );
    if (restored is Ok<SelectionState, SelectionFailure>) {
      _selectionFrame = null;
    }
  }

  void _closeInlineTextEditor({required String status, required bool rebuild}) {
    final session = _inlineText;
    final controller = _inlineTextController;
    if (session != null && controller != null) {
      controller.removeListener(session.removeControllerListener);
    }
    controller?.dispose();
    _inlineTextFocus?.removeListener(_editableFocusChanged);
    _inlineTextFocus?.dispose();
    _inlineText = null;
    _inlineTextController = null;
    _inlineTextFocus = null;
    _inlineResizePointer = null;
    _inlineResizeHandle = null;
    _inlineResizeStartBounds = null;
    _inlineResizeSourceTransform = null;
    _activeTextDraft = null;
    if (rebuild) {
      setState(() => _status = status);
    } else {
      _status = status;
    }
  }

  void _disposeInlineTextEditor() {
    if (_inlineText == null &&
        _inlineTextController == null &&
        _inlineTextFocus == null) {
      return;
    }
    _closeInlineTextEditor(status: _status, rebuild: false);
  }

  _InlineTextCommitOutcome _commitTextDialog(
    Rect2 pageBounds,
    _TextDialogResult dialog, {
    required _InlineTextSession session,
    ObjectEnvelope? existing,
    TextPayload? prior,
    Revision? baseObjectRevision,
  }) {
    if (existing != null && !_isCurrentTextSession(session)) {
      return _InlineTextCommitOutcome.rejected;
    }
    final limits = widget.runtime.textLimits;
    final character = TextCharacterStyle.create(
      preferredFontFamily: prior?.defaultCharacterStyle.preferredFontFamily,
      genericFontFamily:
          prior?.defaultCharacterStyle.genericFontFamily ??
          TextGenericFontFamily.sansSerif,
      fontSize: dialog.fontSize,
      weight: dialog.bold ? 700 : 400,
      italic: dialog.italic,
      underline: prior?.defaultCharacterStyle.underline ?? false,
      strikethrough: prior?.defaultCharacterStyle.strikethrough ?? false,
      argb: dialog.argb,
      limits: limits,
      unknownFields: prior?.defaultCharacterStyle.unknownFields,
    ).fold<TextCharacterStyle?>(onOk: (value) => value, onErr: (_) => null);
    final paragraphStyle = TextParagraphStyle.create(
      alignment: dialog.alignment,
      direction:
          prior?.defaultParagraphStyle.direction ??
          TextParagraphDirection.automatic,
      lineHeight: prior?.defaultParagraphStyle.lineHeight ?? 1.2,
      limits: limits,
      languageHint: prior?.defaultParagraphStyle.languageHint,
      unknownFields: prior?.defaultParagraphStyle.unknownFields,
    ).fold<TextParagraphStyle?>(onOk: (value) => value, onErr: (_) => null);
    final padding =
        prior?.padding ??
        TextPadding.create(
          left: 6,
          top: 6,
          right: 6,
          bottom: 6,
          limits: limits,
        ).fold<TextPadding?>(onOk: (value) => value, onErr: (_) => null);
    if (character == null || paragraphStyle == null || padding == null) {
      return _InlineTextCommitOutcome.rejected;
    }
    final paragraphs = <TextParagraph>[];
    for (final text in dialog.text.split('\n')) {
      final run = TextRun.create(
        text: text,
        style: character,
        limits: limits,
      ).fold<TextRun?>(onOk: (value) => value, onErr: (_) => null);
      if (run == null) return _InlineTextCommitOutcome.rejected;
      final paragraph = TextParagraph.create(
        runs: [run],
        style: paragraphStyle,
        limits: limits,
      ).fold<TextParagraph?>(onOk: (value) => value, onErr: (_) => null);
      if (paragraph == null) return _InlineTextCommitOutcome.rejected;
      paragraphs.add(paragraph);
    }
    final draftPayload = TextPayload.create(
      paragraphs: paragraphs,
      defaultCharacterStyle: character,
      defaultParagraphStyle: paragraphStyle,
      boxMode: prior?.boxMode ?? TextBoxMode.fixedWidthFixedHeight,
      intrinsicWidth: pageBounds.width,
      intrinsicHeight: pageBounds.height,
      padding: padding,
      verticalAlignment: prior?.verticalAlignment ?? TextVerticalAlignment.top,
      overflowPolicy: prior?.overflowPolicy ?? TextOverflowPolicy.clip,
      limits: limits,
      unknownFields: prior?.unknownFields,
    ).fold<TextPayload?>(onOk: (value) => value, onErr: (_) => null);
    final vector = Vector2.create(
      x: pageBounds.left,
      y: pageBounds.top,
    ).fold<Vector2?>(onOk: (value) => value, onErr: (_) => null);
    final transform = vector == null
        ? null
        : AffineTransform2D.fromOperation(
            TranslationTransformOperation2D(vector),
          ).fold<AffineTransform2D?>(
            onOk: (value) => value,
            onErr: (_) => null,
          );
    if (draftPayload == null) return _InlineTextCommitOutcome.rejected;
    final payload = _fitCommittedTextPayload(draftPayload);
    if (payload == null) return _InlineTextCommitOutcome.rejected;
    if (existing != null && prior != null) {
      if (payload.encode() == prior.encode() &&
          session.currentTransform == existing.transform) {
        return _InlineTextCommitOutcome.noChange;
      }
      return baseObjectRevision != null &&
              _publishTextReplacement(
                session,
                existing,
                prior,
                payload,
                baseObjectRevision,
              )
          ? _InlineTextCommitOutcome.committed
          : _InlineTextCommitOutcome.rejected;
    }
    return transform != null &&
            _publishNewObject(
              typeKey: textObjectTypeKey,
              schemaVersion: textSchemaVersion,
              payload: payload.encode(),
              transform: transform,
              description: 'Create text',
            )
        ? _InlineTextCommitOutcome.committed
        : _InlineTextCommitOutcome.rejected;
  }

  bool _isCurrentTextSession(_InlineTextSession session) {
    final source = session.existing;
    final layerId = session.layerId;
    final objectRevision = session.baseObjectRevision;
    final membershipRevision = session.baseMembershipRevision;
    if (source == null ||
        layerId == null ||
        objectRevision == null ||
        membershipRevision == null) {
      return false;
    }
    try {
      final snapshot = _coordinator.snapshot;
      if (snapshot.root.id != session.documentId ||
          snapshot.revisions.objects[source.id] != objectRevision ||
          snapshot.revisions.layerMembership[layerId] != membershipRevision) {
        return false;
      }
      final page = snapshot.root.pages
          .where((value) => value.id == session.pageId)
          .firstOrNull;
      final layer = page?.layers
          .whereType<ContentLayer>()
          .where((value) => value.id == layerId)
          .firstOrNull;
      final current = layer?.objects
          .where((object) => object.id == source.id)
          .firstOrNull;
      return current == source;
    } on Object {
      return false;
    }
  }

  bool _publishTextReplacement(
    _InlineTextSession session,
    ObjectEnvelope source,
    TextPayload before,
    TextPayload after,
    Revision baseObjectRevision,
  ) {
    try {
      if (!_isCurrentTextSession(session)) return false;
      final semantics =
          TextObjectTypeDefinition(
            widget.runtime.textLimits,
            widget.textLayoutEngineOverride ?? widget.runtime.textLayoutEngine,
          ).classifyPayloadChange(
            before.encode(),
            after.encode(),
            textSchemaVersion,
          );
      final correlation = _uuid.generateV4();
      final snapshot = _coordinator.snapshot;
      final layerId = session.layerId;
      final membershipRevision = layerId == null
          ? null
          : snapshot.revisions.layerMembership[layerId];
      if (semantics is! Ok<ObjectPayloadChangeSemantics, StructuredFailure> ||
          correlation is! Ok<UuidIdentifier, StructuredFailure> ||
          membershipRevision == null) {
        return false;
      }
      final dimensionsChanged =
          before.intrinsicWidth != after.intrinsicWidth ||
          before.intrinsicHeight != after.intrinsicHeight;
      final explicitlyResized = session.preservedAnchor != null;
      final fit = dimensionsChanged && !explicitlyResized
          ? TextObjectTypeDefinition(
              widget.runtime.textLimits,
              widget.textLayoutEngineOverride ??
                  widget.runtime.textLayoutEngine,
            ).validateIntrinsicVisibleContentFit(
              before.encode(),
              after.encode(),
              textSchemaVersion,
            )
          : null;
      final preservedAnchor = explicitlyResized
          ? session.preservedAnchor!
          : fit is Ok<IntrinsicVisibleContentFitChange, StructuredFailure>
          ? _textFitAnchor(fit.value)
          : null;
      if (dimensionsChanged && preservedAnchor == null) return false;
      final resizeTransform = dimensionsChanged
          ? _textResizeTransform(
              source.transform,
              before,
              after,
              preservedAnchor!,
            )
          : null;
      if (dimensionsChanged && resizeTransform == null) return false;
      final request = TextObjectEditRequest.replace(
        documentId: snapshot.root.id,
        source: source,
        payload: after,
        limits: widget.runtime.textLimits,
        layoutEngine:
            widget.textLayoutEngineOverride ?? widget.runtime.textLayoutEngine,
        metadata: CommandMetadata(
          family: CommandFamily.objectReplacement,
          correlationId: CommandCorrelationId.fromUuid(correlation.value),
          description: 'Edit text',
        ),
        preconditions: RevisionPreconditions(
          objects: {source.id: baseObjectRevision},
          layerMembership: {layerId!: membershipRevision},
        ),
        changeCategories: ObjectReplacementChangeCategories(
          geometry: semantics.value.geometry,
          appearance: semantics.value.appearance,
          text: semantics.value.text,
          metadata: semantics.value.metadata,
        ),
        textBoxResizeTransform: dimensionsChanged
            ? explicitlyResized
                  ? TextBoxResizeTransformEvidence.create(
                      preservedAnchor: preservedAnchor!,
                      replacementTransform: resizeTransform!,
                    )
                  : TextBoxResizeTransformEvidence.visibleContentFit(
                      preservedAnchor: preservedAnchor!,
                      replacementTransform: resizeTransform!,
                    )
            : null,
      );
      return request is Ok<AtomicObjectReplacementRequest, StructuredFailure> &&
          _coordinator.execute(request.value)
              is Ok<CommandCommit, CommandFailure>;
    } on Object {
      return false;
    }
  }

  bool _publishNewObject({
    required ObjectTypeKey typeKey,
    required SchemaVersion schemaVersion,
    required PreservedData payload,
    required AffineTransform2D transform,
    required String description,
  }) {
    try {
      final objectUuid = _uuid.generateV4();
      final correlationUuid = _uuid.generateV4();
      if (objectUuid is! Ok<UuidIdentifier, StructuredFailure>) return false;
      if (correlationUuid is! Ok<UuidIdentifier, StructuredFailure>) {
        return false;
      }
      if (objectUuid.value == correlationUuid.value) return false;
      final envelopeVersion = SchemaVersion.create(
        1,
      ).fold<SchemaVersion?>(onOk: (value) => value, onErr: (_) => null);
      if (envelopeVersion == null) return false;
      final object = ObjectEnvelope.create(
        id: ObjectId.fromUuid(objectUuid.value),
        typeKey: typeKey,
        envelopeVersion: envelopeVersion,
        typeSchemaVersion: schemaVersion,
        transform: transform,
        visible: true,
        locked: false,
        payload: payload,
        extensionData: PreservedMap.empty(),
      );
      if (object is! Ok<ObjectEnvelope, StructuredFailure>) return false;
      final snapshot = _coordinator.snapshot;
      final pageRevision = snapshot.revisions.pages[_page.id];
      final membershipRevision = snapshot.revisions.layerMembership[_layerId];
      if (pageRevision == null || membershipRevision == null) return false;
      final request = AtomicObjectCollectionEditRequest.create(
        documentId: snapshot.root.id,
        metadata: CommandMetadata(
          family: CommandFamily.objectCollectionEdit,
          correlationId: CommandCorrelationId.fromUuid(correlationUuid.value),
          description: description,
        ),
        preconditions: RevisionPreconditions(
          pages: {_page.id: pageRevision},
          layerMembership: {_layerId: membershipRevision},
        ),
        pageId: _page.id,
        additions: [
          ObjectCollectionAddition(layerId: _layerId, object: object.value),
        ],
        maximumOperations: widget.runtime.maximumCommandOperations,
      );
      return request
              is Ok<AtomicObjectCollectionEditRequest, StructuredFailure> &&
          _coordinator.execute(request.value) is Ok;
    } on Object {
      return false;
    }
  }

  bool _appendWholeEraserPoint(Point2 point, {bool publish = true}) {
    final plan = _wholeEraserPlan;
    if (plan == null || !plan.isCurrent(_coordinator.snapshot)) {
      _cancelGesture('Erase rejected');
      return false;
    }
    final previous = _wholeEraserPath.lastOrNull;
    final update = plan.acceptPoint(point);
    if (update is! Ok<EraserGestureUpdate, StructuredFailure> ||
        !_appendEraserPreview(previous ?? point, point) ||
        !_refreshEraserObjectPreviews(
          update.value.changedObjectIds
              .map(plan.previewFor)
              .whereType<EraserPreviewObject>()
              .toList(growable: false),
          update.value.changedObjectIds,
        )) {
      _cancelGesture('Erase rejected');
      return false;
    }
    _wholeEraserPath.add(point);
    if (publish && mounted) setState(() {});
    return true;
  }

  bool _appendEraserPreview(Point2 first, Point2 second) {
    final a = _viewport
        .pageToView(first)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    final b = _viewport
        .pageToView(second)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    if (a == null || b == null) return false;
    final bounds = Rect2.fromEdges(
      left: math.min(a.x, b.x) - 8,
      top: math.min(a.y, b.y) - 8,
      right: math.max(a.x, b.x) + 8,
      bottom: math.max(a.y, b.y) + 8,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
    if (bounds == null) return false;
    final primitive = PlaceholderPrimitive.create(
      plane: RenderPlane.toolPreview,
      bounds: bounds,
      opacity: .8,
    );
    if (primitive is! Ok<PlaceholderPrimitive, StructuredFailure>) {
      return false;
    }
    _eraserPreviewPrimitive = primitive.value;
    return true;
  }

  bool _refreshEraserObjectPreviews(
    List<EraserPreviewObject> previews,
    Set<ObjectId> changed,
  ) {
    for (final objectId in changed) {
      final preview = previews
          .where((value) => value.objectId == objectId)
          .firstOrNull;
      if (preview == null) return false;
      final primitives = <ScenePrimitive>[];
      for (final survivor in preview.strokes) {
        final stroke = survivor.stroke;
        final color = RenderColor.create(stroke.style.argb);
        if (color is! Ok<RenderColor, StructuredFailure>) {
          return false;
        }
        for (final element in survivor.geometry.elements) {
          final points = <Point2>[];
          for (final pagePoint in element.vertices) {
            final view = _viewport.pageToView(pagePoint);
            if (view is! Ok<ViewPoint, StructuredFailure>) return false;
            points.add(_point(view.value.x, view.value.y));
          }
          final primitive = FilledPolygonPrimitive.create(
            plane: RenderPlane.toolPreview,
            opacity: stroke.style.opacity,
            color: color.value,
            points: points,
            maximumPoints: _sceneBuilder.limits.maximumPointsPerPrimitive,
          );
          if (primitive is! Ok<FilledPolygonPrimitive, StructuredFailure>) {
            return false;
          }
          primitives.add(primitive.value);
          if (primitives.length >
              widget.runtime.renderingLimits.maximumPreviewOverlays) {
            return false;
          }
        }
      }
      _eraserObjectPreviews[objectId] = List.unmodifiable(primitives);
    }
    return true;
  }

  _SelectionFrameSnapshot? _createSelectionFrame() {
    if (_inlineText != null) return null;
    final state = _selection.state;
    if (state.targets.isEmpty) return null;
    final preview = state.transformPreview;
    final targetIds = state.targets.map((value) => value.objectId).toList();
    final singleText = targetIds.length == 1 ? _selectedTextObject : null;
    final singleWholeObject =
        targetIds.length == 1 && state.targets.single.isWholeObject
        ? _page.layers
              .expand((value) => value.objects)
              .where((value) => value.id == targetIds.single)
              .firstOrNull
        : null;
    final pageCorners = <Point2>[];
    final isSingleText = singleText != null;
    if (singleWholeObject != null) {
      final object =
          preview?.candidateObjects[singleWholeObject.id] ?? singleWholeObject;
      final prepared = _selectionTransformPreparation;
      Rect2? box =
          prepared != null && prepared.singleObjectId == singleWholeObject.id
          ? prepared.singleLocalBounds
          : null;
      if (box == null) {
        final resolution = _registry.resolve(object);
        if (resolution is! SupportedObjectResolution) return null;
        box = resolution.definition
            .intrinsicGeometry(object.payload, object.typeSchemaVersion)
            .fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
      }
      if (box == null) return null;
      for (final local in <Point2>[
        box.topLeft,
        _point(box.right, box.top),
        box.bottomRight,
        _point(box.left, box.bottom),
      ]) {
        final transformed = object.transform.applyToPoint(local);
        if (transformed is! Ok<Point2, StructuredFailure>) return null;
        pageCorners.add(transformed.value);
      }
    } else {
      final bounds = preview?.newBounds ?? state.aggregateBounds;
      if (bounds == null) return null;
      pageCorners.addAll([
        bounds.topLeft,
        _point(bounds.right, bounds.top),
        bounds.bottomRight,
        _point(bounds.left, bounds.bottom),
      ]);
    }
    final viewCorners = <Point2>[];
    for (final page in pageCorners) {
      final view = _viewport.pageToView(page);
      if (view is! Ok<ViewPoint, StructuredFailure>) return null;
      viewCorners.add(_point(view.value.x, view.value.y));
    }
    final topLeft = viewCorners[0];
    final topRight = viewCorners[1];
    final topDx = topRight.x - topLeft.x;
    final topDy = topRight.y - topLeft.y;
    final topLength = math.sqrt(topDx * topDx + topDy * topDy);
    if (!topLength.isFinite || topLength <= 0) return null;
    final topCenter = _point(
      (topLeft.x + topRight.x) / 2,
      (topLeft.y + topRight.y) / 2,
    );
    final outwardX = topDy / topLength;
    final outwardY = -topDx / topLength;
    const connectorLength = 28.0;
    const rotationRadius = 7.0;
    final rotationCenter = _point(
      topCenter.x + outwardX * connectorLength,
      topCenter.y + outwardY * connectorLength,
    );
    final connectorEnd = _point(
      rotationCenter.x - outwardX * rotationRadius,
      rotationCenter.y - outwardY * rotationRadius,
    );
    final center = _point(
      pageCorners.map((value) => value.x).reduce((a, b) => a + b) / 4,
      pageCorners.map((value) => value.y).reduce((a, b) => a + b) / 4,
    );
    final pageBounds = Rect2.fromEdges(
      left: pageCorners.map((value) => value.x).reduce(math.min),
      top: pageCorners.map((value) => value.y).reduce(math.min),
      right: pageCorners.map((value) => value.x).reduce(math.max),
      bottom: pageCorners.map((value) => value.y).reduce(math.max),
    );
    if (pageBounds is! Ok<Rect2, StructuredFailure>) return null;
    final prepared = _selectionTransformPreparation;
    var rotationSupported =
        prepared != null &&
            _sameObjectIds(prepared.targetIds, targetIds.toSet())
        ? prepared.rotationSupported
        : state.targets.every((target) => target.isWholeObject);
    var resizeSupported =
        prepared != null &&
            _sameObjectIds(prepared.targetIds, targetIds.toSet())
        ? prepared.resizeSupported
        : state.targets.every((target) => target.isWholeObject);
    if (prepared == null ||
        !_sameObjectIds(prepared.targetIds, targetIds.toSet())) {
      for (final id in targetIds) {
        final object = _page.layers
            .expand((value) => value.objects)
            .where((value) => value.id == id)
            .firstOrNull;
        final resolution = object == null ? null : _registry.resolve(object);
        if (resolution is! SupportedObjectResolution) {
          rotationSupported = false;
          resizeSupported = false;
          break;
        }
        rotationSupported &= resolution.definition.capabilities.rotatable;
        resizeSupported &= resolution.definition.capabilities.resizable;
      }
    }
    return _SelectionFrameSnapshot(
      documentRevision: _coordinator.snapshot.revisions.document,
      viewportRevision: _viewport.revision,
      selectionRevision: state.revision,
      preview: preview,
      targetIds: targetIds,
      pageCorners: pageCorners,
      viewCorners: viewCorners,
      pageBounds: pageBounds.value,
      pageCenter: center,
      rotationCenter: rotationCenter,
      rotationConnectorStart: topCenter,
      rotationConnectorEnd: connectorEnd,
      rotationRadius: rotationRadius,
      isSingleText: isSingleText,
      rotationSupported: rotationSupported,
      resizeSupported: resizeSupported,
      resizeHitSizeViewPixels: widget.runtime.selectionHandleHitSizeViewPixels,
    );
  }

  bool _selectionFrameIsCurrent(_SelectionFrameSnapshot frame) {
    final state = _selection.state;
    return frame.documentRevision == _coordinator.snapshot.revisions.document &&
        frame.viewportRevision == _viewport.revision &&
        frame.selectionRevision == state.revision &&
        identical(frame.preview, state.transformPreview) &&
        _sameObjectIds(
          frame.targetIds.toSet(),
          state.targets.map((v) => v.objectId).toSet(),
        );
  }

  void _beginSelection(Point2 pagePoint, int timeMicros) {
    final previousTime = _lastSelectionTapMicros;
    final previousPoint = _lastSelectionTapPoint;
    _lastSelectionTapMicros = timeMicros;
    _lastSelectionTapPoint = pagePoint;
    final selectedText = _selectedTextObject;
    if (selectedText != null &&
        previousTime != null &&
        timeMicros >= previousTime &&
        timeMicros - previousTime <= 500000 &&
        previousPoint != null &&
        _distance(previousPoint, pagePoint) <= 8 / _viewport.zoom) {
      final payload = TextPayload.decode(
        selectedText.payload,
        limits: widget.runtime.textLimits,
      ).fold<TextPayload?>(onOk: (value) => value, onErr: (_) => null);
      if (payload != null) {
        _router.cancel();
        _openTextEditor(_textBoxBounds(payload), existing: selectedText);
        return;
      }
    }
    var frame = _selectionFrame;
    if (frame == null || !_selectionFrameIsCurrent(frame)) {
      frame = _createSelectionFrame();
    }
    if (frame != null) {
      _selectionFrame = frame;
      final view = _viewport
          .pageToView(pagePoint)
          .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
      final viewPoint = view == null ? null : Offset(view.x, view.y);
      final resizeHandle = viewPoint == null
          ? null
          : frame.resizeHandleAt(viewPoint);
      if (resizeHandle != null) {
        _beginSelectionTransform(
          _SelectionTransformMode.resize,
          pagePoint,
          frame.pageBounds,
          frame.oppositePivot(resizeHandle),
          resizeHandle: resizeHandle,
        );
        return;
      }
      if (viewPoint != null && frame.hitsRotation(viewPoint)) {
        if (!frame.rotationSupported) return;
        _beginSelectionTransform(
          _SelectionTransformMode.rotate,
          pagePoint,
          frame.pageBounds,
          frame.pageCenter,
        );
        return;
      }
      if (viewPoint != null && frame.contains(viewPoint)) {
        _beginSelectionTransform(
          _SelectionTransformMode.move,
          pagePoint,
          frame.pageBounds,
          frame.pageCenter,
        );
        return;
      }
    }
    setState(() {
      _selectionDown = pagePoint;
      _selectionCurrent = pagePoint;
      _status = 'Selecting';
    });
  }

  Map<_TextResizeHandle, Offset>? _viewCorners(
    Rect2 bounds,
    AffineTransform2D? transform,
  ) {
    final local = <_TextResizeHandle, Point2>{
      _TextResizeHandle.topLeft: bounds.topLeft,
      _TextResizeHandle.topRight: _point(bounds.right, bounds.top),
      _TextResizeHandle.bottomRight: bounds.bottomRight,
      _TextResizeHandle.bottomLeft: _point(bounds.left, bounds.bottom),
    };
    final result = <_TextResizeHandle, Offset>{};
    for (final entry in local.entries) {
      final page = transform == null
          ? entry.value
          : transform
                .applyToPoint(entry.value)
                .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
      if (page == null) return null;
      final view = _viewport
          .pageToView(page)
          .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
      if (view == null) return null;
      result[entry.key] = Offset(view.x, view.y);
    }
    return result;
  }

  _TextResizeHandle? _resizeHandleAtView(
    Offset point,
    Map<_TextResizeHandle, Offset>? corners, {
    bool includeEdges = true,
    bool includeCorners = true,
  }) {
    if (!point.dx.isFinite || !point.dy.isFinite || corners == null) {
      return null;
    }
    if (includeCorners) {
      const cornerTolerance = 11.0;
      final candidates = <(_TextResizeHandle, double, int)>[];
      var ordinal = 0;
      for (final handle in const [
        _TextResizeHandle.topLeft,
        _TextResizeHandle.topRight,
        _TextResizeHandle.bottomRight,
        _TextResizeHandle.bottomLeft,
      ]) {
        final distance = (point - corners[handle]!).distance;
        if (distance <= cornerTolerance) {
          candidates.add((handle, distance, ordinal));
        }
        ordinal += 1;
      }
      if (candidates.isNotEmpty) {
        candidates.sort((left, right) {
          final byDistance = left.$2.compareTo(right.$2);
          return byDistance != 0 ? byDistance : left.$3.compareTo(right.$3);
        });
        return candidates.first.$1;
      }
    }
    if (!includeEdges) return null;
    const edgeTolerance = 7.0;
    final edges = <(_TextResizeHandle, Offset, Offset)>[
      (
        _TextResizeHandle.top,
        corners[_TextResizeHandle.topLeft]!,
        corners[_TextResizeHandle.topRight]!,
      ),
      (
        _TextResizeHandle.right,
        corners[_TextResizeHandle.topRight]!,
        corners[_TextResizeHandle.bottomRight]!,
      ),
      (
        _TextResizeHandle.bottom,
        corners[_TextResizeHandle.bottomLeft]!,
        corners[_TextResizeHandle.bottomRight]!,
      ),
      (
        _TextResizeHandle.left,
        corners[_TextResizeHandle.topLeft]!,
        corners[_TextResizeHandle.bottomLeft]!,
      ),
    ];
    final candidates = <(_TextResizeHandle, double, int)>[];
    for (var index = 0; index < edges.length; index += 1) {
      final edge = edges[index];
      final distance = _distanceToViewSegment(point, edge.$2, edge.$3);
      if (distance <= edgeTolerance) {
        candidates.add((edge.$1, distance, index));
      }
    }
    if (candidates.isNotEmpty) {
      candidates.sort((left, right) {
        final byDistance = left.$2.compareTo(right.$2);
        return byDistance != 0 ? byDistance : left.$3.compareTo(right.$3);
      });
      return candidates.first.$1;
    }
    return null;
  }

  double _distanceToViewSegment(Offset point, Offset start, Offset end) {
    final delta = end - start;
    final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
    if (lengthSquared == 0) return (point - start).distance;
    final projection =
        (((point - start).dx * delta.dx) + ((point - start).dy * delta.dy)) /
        lengthSquared;
    final t = projection.clamp(0.0, 1.0);
    return (point - (start + delta * t)).distance;
  }

  Rect2 _textBoxBounds(TextPayload payload) => Rect2.fromEdges(
    left: 0,
    top: 0,
    right: payload.intrinsicWidth,
    bottom: payload.intrinsicHeight ?? payload.bounds.bottom,
  ).fold<Rect2>(onOk: (value) => value, onErr: (_) => payload.bounds);

  TextPayload? _fitCommittedTextPayload(TextPayload draft) =>
      TextObjectTypeDefinition(
            widget.runtime.textLimits,
            widget.textLayoutEngineOverride ?? widget.runtime.textLayoutEngine,
          )
          .fitVisibleContent(draft)
          .fold<TextPayload?>(onOk: (value) => value, onErr: (_) => null);

  AffineTransform2D? _textResizeTransform(
    AffineTransform2D source,
    TextPayload before,
    TextPayload after,
    TextBoxResizePreservedAnchor anchor,
  ) {
    final horizontalFactor = switch (anchor) {
      TextBoxResizePreservedAnchor.topLeft ||
      TextBoxResizePreservedAnchor.centerLeft ||
      TextBoxResizePreservedAnchor.bottomLeft => 0.0,
      TextBoxResizePreservedAnchor.topCenter ||
      TextBoxResizePreservedAnchor.center ||
      TextBoxResizePreservedAnchor.bottomCenter => 0.5,
      TextBoxResizePreservedAnchor.topRight ||
      TextBoxResizePreservedAnchor.centerRight ||
      TextBoxResizePreservedAnchor.bottomRight => 1.0,
    };
    final verticalFactor = switch (anchor) {
      TextBoxResizePreservedAnchor.topLeft ||
      TextBoxResizePreservedAnchor.topCenter ||
      TextBoxResizePreservedAnchor.topRight => 0.0,
      TextBoxResizePreservedAnchor.centerLeft ||
      TextBoxResizePreservedAnchor.center ||
      TextBoxResizePreservedAnchor.centerRight => 0.5,
      TextBoxResizePreservedAnchor.bottomLeft ||
      TextBoxResizePreservedAnchor.bottomCenter ||
      TextBoxResizePreservedAnchor.bottomRight => 1.0,
    };
    final beforeHeight = before.intrinsicHeight;
    final afterHeight = after.intrinsicHeight;
    if ((beforeHeight == null) != (afterHeight == null)) return null;
    final delta = Vector2.create(
      x: (before.intrinsicWidth - after.intrinsicWidth) * horizontalFactor,
      y: beforeHeight != null
          ? (beforeHeight - afterHeight!) * verticalFactor
          : 0,
    );
    if (delta is! Ok<Vector2, StructuredFailure>) return null;
    final translation = AffineTransform2D.fromOperation(
      TranslationTransformOperation2D(delta.value),
    );
    return translation is Ok<AffineTransform2D, StructuredFailure>
        ? translation.value
              .then(source)
              .fold<AffineTransform2D?>(
                onOk: (value) => value,
                onErr: (_) => null,
              )
        : null;
  }

  TextBoxResizePreservedAnchor _textFitAnchor(
    IntrinsicVisibleContentFitChange fit,
  ) => switch ((fit.horizontalAnchor, fit.verticalAnchor)) {
    (IntrinsicHorizontalAnchor.left, IntrinsicVerticalAnchor.top) =>
      TextBoxResizePreservedAnchor.topLeft,
    (IntrinsicHorizontalAnchor.center, IntrinsicVerticalAnchor.top) =>
      TextBoxResizePreservedAnchor.topCenter,
    (IntrinsicHorizontalAnchor.right, IntrinsicVerticalAnchor.top) =>
      TextBoxResizePreservedAnchor.topRight,
    (IntrinsicHorizontalAnchor.left, IntrinsicVerticalAnchor.center) =>
      TextBoxResizePreservedAnchor.centerLeft,
    (IntrinsicHorizontalAnchor.center, IntrinsicVerticalAnchor.center) =>
      TextBoxResizePreservedAnchor.center,
    (IntrinsicHorizontalAnchor.right, IntrinsicVerticalAnchor.center) =>
      TextBoxResizePreservedAnchor.centerRight,
    (IntrinsicHorizontalAnchor.left, IntrinsicVerticalAnchor.bottom) =>
      TextBoxResizePreservedAnchor.bottomLeft,
    (IntrinsicHorizontalAnchor.center, IntrinsicVerticalAnchor.bottom) =>
      TextBoxResizePreservedAnchor.bottomCenter,
    (IntrinsicHorizontalAnchor.right, IntrinsicVerticalAnchor.bottom) =>
      TextBoxResizePreservedAnchor.bottomRight,
  };

  void _beginSelectionTransform(
    _SelectionTransformMode mode,
    Point2 down,
    Rect2 bounds,
    Point2 pivot, {
    _TextResizeHandle? resizeHandle,
  }) {
    _resetSelectionTransformPerformanceEvidence();
    _selectionTransformFailureStageCode = 0;
    _selectionResizeClampedToInitial = false;
    _resetSelectionRotationTracking();
    _diagnostics.beginGesture();
    final prepared = _prepareSelectionTransform();
    if (prepared == null) {
      final counts = _selectionTargetTypeCounts;
      _diagnostics.record(
        stage: Phase6DiagnosticStage.selectionTransformPreview,
        acceptedTargets: _selection.state.targets.length,
        geometryResolutions: _selectionTransformRegistryResolutions,
        commandOperations: _selectionTransformRendererPreparations,
        maximumRetainedResources: _selectionTransformMaximumRetainedEvidence,
        terminalDisposition: 2,
        handwritingTargetCount: counts.handwriting,
        shapeTargetCount: counts.shape,
        textTargetCount: counts.text,
        transformModeCode: mode.index + 1,
        failureStageCode: 7,
      );
      setState(() => _status = 'Transform unavailable');
      return;
    }
    final frame = _selectionFrame;
    final initialViewWidth = frame == null
        ? null
        : _distance(frame.viewCorners[0], frame.viewCorners[1]);
    final initialViewHeight = frame == null
        ? null
        : _distance(frame.viewCorners[0], frame.viewCorners[3]);
    setState(() {
      _selectionTransformEvidence = null;
      _replaceSelectionTransformPreparation(prepared);
      _selectionTransformMode = mode;
      _selectionTransformDown = down;
      _selectionTransformBounds = bounds;
      _selectionTransformPivot = pivot;
      _selectionTransformInitialViewWidth = initialViewWidth;
      _selectionTransformInitialViewHeight = initialViewHeight;
      _selectionResizeHandle = resizeHandle;
      _status = switch (mode) {
        _SelectionTransformMode.move => 'Moving selection',
        _SelectionTransformMode.resize => 'Resizing selection',
        _SelectionTransformMode.rotate => 'Rotating selection',
      };
    });
    if (mode == _SelectionTransformMode.rotate) {
      _selectionRotationLastPointerPoint = down;
      _selectionRotationLastPointerAngle = math.atan2(
        down.y - pivot.y,
        down.x - pivot.x,
      );
    }
  }

  void _updateSelection(Point2 pagePoint, InputModifiers modifiers) {
    if (_selectionTransformMode != null) {
      _applySelectionTransformUpdate(pagePoint, modifiers);
      return;
    }
    if (_selectionDown == null) return;
    setState(() => _selectionCurrent = pagePoint);
  }

  void _applySelectionTransformUpdate(
    Point2 pagePoint,
    InputModifiers modifiers,
  ) {
    final operation = _selectionOperation(pagePoint, modifiers);
    if (operation == null) return;
    final validated = _validateSelectionTransformPreview(
      operation,
      identity: _selectionRotationIdentityPreview,
    );
    if (validated is Ok<_SelectionTransformRenderEvidence, StructuredFailure>) {
      _selectionTransformFrameUpdates += 1;
      if (_selectionTransformMode == _SelectionTransformMode.rotate &&
          modifiers.shift) {
        _snappedPreviewUpdates += 1;
      }
      _lastSelectionTransformUpdate = _PendingSelectionTransformUpdate(
        pagePoint: pagePoint,
        modifiers: modifiers,
      );
      setState(() => _selectionTransformEvidence = validated.value);
    } else {
      _abandonSelectionTransform(
        'Transform preview unavailable',
        failureStageCode: 3,
      );
    }
  }

  void _abandonSelectionTransform(
    String status, {
    required int failureStageCode,
  }) {
    _selectionTransformFailureStageCode = failureStageCode;
    _selection.cancelTransform();
    _clearPendingSelectionTransformUpdate();
    setState(() {
      _selectionTransformEvidence = null;
      _disposeSelectionTransformPreparation();
      _selectionTransformMode = null;
      _selectionTransformDown = null;
      _selectionTransformBounds = null;
      _selectionTransformPivot = null;
      _selectionTransformInitialViewWidth = null;
      _selectionTransformInitialViewHeight = null;
      _selectionResizeHandle = null;
      _selectionResizeClampedToInitial = false;
      _resetSelectionRotationTracking();
      _status = status;
    });
  }

  TransformOperation2D? _selectionOperation(
    Point2 current,
    InputModifiers modifiers,
  ) {
    final mode = _selectionTransformMode;
    final down = _selectionTransformDown;
    final bounds = _selectionTransformBounds;
    final pivot = _selectionTransformPivot;
    if (mode == null || down == null || bounds == null || pivot == null) {
      return null;
    }
    switch (mode) {
      case _SelectionTransformMode.move:
        final offset = Vector2.create(
          x: current.x - down.x,
          y: current.y - down.y,
        );
        return offset is Ok<Vector2, StructuredFailure>
            ? TranslationTransformOperation2D(offset.value)
            : null;
      case _SelectionTransformMode.rotate:
        var radians = _continuousSelectionRotation(current, pivot);
        if (radians == null) return null;
        if (modifiers.shift) {
          const step = math.pi / 12;
          radians = (radians / step).round() * step;
        }
        final identity = _isIdentityRotation(radians);
        if (identity != _selectionRotationIdentityPreview) {
          if (identity) {
            _selectionRotationIdentityEntries += 1;
          } else {
            _selectionRotationIdentityExits += 1;
          }
          _selectionRotationIdentityPreview = identity;
        }
        if (identity) {
          return const IdentityTransformOperation2D();
        }
        return RotationTransformOperation2D.create(
          radians: radians,
          pivot: pivot,
        ).fold<TransformOperation2D?>(
          onOk: (value) => value,
          onErr: (_) => null,
        );
      case _SelectionTransformMode.resize:
        final handle = _selectionResizeHandle;
        final prepared = _selectionTransformPreparation;
        if (handle == null || prepared == null) return null;
        final angle = prepared.orientationRadians;
        final cosine = math.cos(angle);
        final sine = math.sin(angle);
        double projectX(double x, double y) => x * cosine + y * sine;
        double projectY(double x, double y) => -x * sine + y * cosine;
        final baseDx = down.x - pivot.x;
        final baseDy = down.y - pivot.y;
        final currentDx = current.x - pivot.x;
        final currentDy = current.y - pivot.y;
        final baseX = projectX(baseDx, baseDy);
        final baseY = projectY(baseDx, baseDy);
        final affectsX =
            handle == _TextResizeHandle.left ||
            handle == _TextResizeHandle.right ||
            handle == _TextResizeHandle.topLeft ||
            handle == _TextResizeHandle.topRight ||
            handle == _TextResizeHandle.bottomLeft ||
            handle == _TextResizeHandle.bottomRight;
        final affectsY =
            handle == _TextResizeHandle.top ||
            handle == _TextResizeHandle.bottom ||
            handle == _TextResizeHandle.topLeft ||
            handle == _TextResizeHandle.topRight ||
            handle == _TextResizeHandle.bottomLeft ||
            handle == _TextResizeHandle.bottomRight;
        var scaleX = affectsX && baseX != 0 && baseX.isFinite
            ? projectX(currentDx, currentDy) / baseX
            : 1.0;
        var scaleY = affectsY && baseY != 0 && baseY.isFinite
            ? projectY(currentDx, currentDy) / baseY
            : 1.0;
        final minimumViewExtent =
            widget.runtime.minimumInteractiveSelectionExtentViewPixels;
        final initialViewWidth = _selectionTransformInitialViewWidth;
        final initialViewHeight = _selectionTransformInitialViewHeight;
        final minimumScaleX = initialViewWidth == null || initialViewWidth <= 0
            ? 1.0
            : math.min(1.0, minimumViewExtent / initialViewWidth);
        final minimumScaleY =
            initialViewHeight == null || initialViewHeight <= 0
            ? 1.0
            : math.min(1.0, minimumViewExtent / initialViewHeight);
        const maximumSafeScale = 1.3407807929942596e154;
        double boundedScale(double value, double minimum) {
          if (value.isNaN || value.isNegative) return minimum;
          if (!value.isFinite) return maximumSafeScale;
          return value.clamp(minimum, maximumSafeScale);
        }

        scaleX = affectsX ? boundedScale(scaleX, minimumScaleX) : 1.0;
        scaleY = affectsY ? boundedScale(scaleY, minimumScaleY) : 1.0;
        if (modifiers.shift && affectsX && affectsY) {
          final uniform = math.max(
            math.max(minimumScaleX, minimumScaleY),
            math.max(scaleX, scaleY),
          );
          scaleX = boundedScale(
            uniform,
            math.max(minimumScaleX, minimumScaleY),
          );
          scaleY = scaleX;
        }
        _selectionResizeClampedToInitial = scaleX == 1 && scaleY == 1;
        if (_selectionResizeClampedToInitial) {
          const previewOnlyScale = 1.000000000001;
          if (affectsX) {
            scaleX = previewOnlyScale;
          } else if (affectsY) {
            scaleY = previewOnlyScale;
          }
        }
        return ScaleTransformOperation2D.create(
          scaleX: scaleX,
          scaleY: scaleY,
          pivot: pivot,
          orientationRadians: angle,
        ).fold<TransformOperation2D?>(
          onOk: (value) => value,
          onErr: (_) => null,
        );
    }
  }

  void _finishSelection(Point2 pagePoint) {
    if (_selectionTransformMode != null) {
      final evidence = _currentSelectionTransformEvidence;
      final transformModeCode = _selectionTransformMode!.index + 1;
      final targetTypeCounts = _selectionTargetTypeCounts;
      final finalWasSnapped =
          _lastSelectionTransformUpdate?.modifiers.shift ?? false;
      final unchangedClamp =
          _selectionTransformMode == _SelectionTransformMode.resize &&
          _selectionResizeClampedToInitial;
      final unchangedRotation =
          _selectionTransformMode == _SelectionTransformMode.rotate &&
          _selectionRotationIdentityPreview;
      var committed = false;
      var failureStageCode = _selectionTransformFailureStageCode;
      if (!unchangedClamp &&
          !unchangedRotation &&
          evidence != null &&
          _selectionTransformPreviewReady) {
        final started = _selection.beginTransform(
          document: _coordinator.snapshot,
          operation: evidence.operation,
        );
        final preview = started is Ok<SelectionState, SelectionFailure>
            ? started.value.transformPreview
            : null;
        final request = preview?.commandRequest(
          CommandMetadata(
            family: CommandFamily.wholeObjectTransform,
            correlationId: CommandCorrelationId.fromUuid(
              evidence.targetIds.first.uuid,
            ),
            description: 'Transform selection',
          ),
        );
        if (request
            is Ok<AtomicWholeObjectTransformRequest, StructuredFailure>) {
          committed =
              _coordinator.execute(request.value)
                  is Ok<CommandCommit, CommandFailure>;
          if (committed) _selectionTransformPublications += 1;
          if (!committed) failureStageCode = 6;
        } else {
          failureStageCode = started is Ok ? 5 : 2;
        }
      } else {
        failureStageCode = unchangedClamp || unchangedRotation ? 0 : 4;
      }
      _selection.cancelTransform();
      _selectionTransformEvidence = null;
      _disposeSelectionTransformPreparation();
      _selectionTransformMode = null;
      _selectionTransformDown = null;
      _selectionTransformBounds = null;
      _selectionTransformPivot = null;
      _selectionTransformInitialViewWidth = null;
      _selectionTransformInitialViewHeight = null;
      _selectionResizeHandle = null;
      _selectionResizeClampedToInitial = false;
      _clearPendingSelectionTransformUpdate();
      _selection.reconcile(_coordinator.snapshot.root);
      _diagnostics.record(
        stage: Phase6DiagnosticStage.selectionTransformPreview,
        rawPoints: _textTransformRequests,
        visualUpdates: _selectionTransformFrameUpdates,
        layoutRequests: _textLayoutRequests,
        cacheHits: _textLayoutCacheHits,
        transformRequests: _textTransformRequests,
        repaints: _textPreviewRepaints,
        acceptedTargets: evidence?.targetIds.length ?? 0,
        sceneCompositions: _selectionTransformCompositions,
        geometryResolutions: _selectionTransformRegistryResolutions,
        commandOperations: _selectionTransformRendererPreparations,
        maximumRetainedResources: _selectionTransformMaximumRetainedEvidence,
        terminalDisposition: committed
            ? 1
            : unchangedClamp || unchangedRotation
            ? 3
            : 2,
        shiftKeyDownEvents: _shiftKeyDownEvents,
        shiftKeyUpEvents: _shiftKeyUpEvents,
        shiftPointerUpdates: _shiftPointerUpdates,
        snappedPreviewUpdates: _snappedPreviewUpdates,
        finalSnapDisposition: finalWasSnapped ? 1 : 2,
        handwritingTargetCount: targetTypeCounts.handwriting,
        shapeTargetCount: targetTypeCounts.shape,
        textTargetCount: targetTypeCounts.text,
        transformModeCode: transformModeCode,
        failureStageCode: committed || unchangedClamp ? 0 : failureStageCode,
        unwrappedAngleTransitions: _selectionRotationUnwrappedTransitions,
        identitySectorEntries: _selectionRotationIdentityEntries,
        identitySectorExits: _selectionRotationIdentityExits,
        branchCutCrossings: _selectionRotationBranchCrossings,
        rendererPreparations: _selectionTransformRendererPreparations,
        handwritingGeometryPreparations:
            _selectionTransformHandwritingPreparations,
        selectedContentPictureCreations: _selectionTransformPictureCreations,
        perTargetPrimitiveRebuilds: _selectionTransformFramePrimitiveRebuilds,
        unrelatedCommittedContentReplays: _selectionTransformUnrelatedReplays,
        terminalPublications: _selectionTransformPublications,
      );
      _resetSelectionRotationTracking();
      setState(
        () => _status = committed
            ? 'Selection transformed'
            : unchangedClamp || unchangedRotation
            ? 'Selection unchanged'
            : 'Transform cancelled',
      );
      return;
    }
    final down = _selectionDown;
    _selectionDown = null;
    _selectionCurrent = null;
    if (down == null) return;
    final first = _viewport
        .pageToView(down)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    final last = _viewport
        .pageToView(pagePoint)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    if (first == null || last == null) {
      setState(() => _status = 'Selection rejected');
      return;
    }
    final dx = last.x - first.x, dy = last.y - first.y;
    if (math.sqrt(dx * dx + dy * dy) <= _selectionDragThreshold) {
      _pointSelection(pagePoint);
      return;
    }
    final area = Rect2.fromEdges(
      left: math.min(down.x, pagePoint.x),
      top: math.min(down.y, pagePoint.y),
      right: math.max(down.x, pagePoint.x),
      bottom: math.max(down.y, pagePoint.y),
    );
    if (area is! Ok<Rect2, StructuredFailure>) {
      setState(() => _status = 'Selection rejected');
      return;
    }
    final queried = _hitTester.rectangle(
      page: _page,
      area: area.value,
      mode: AreaHitMode.intersection,
    );
    if (queried is! Ok<List<HitTestResult>, StructuredFailure> ||
        queried.value.length > widget.runtime.maximumSelectionTargets) {
      setState(() => _status = 'Selection rejected');
      return;
    }
    final targets = _canvasWholeObjectTargets(queried.value.reversed);
    final result = targets.isEmpty
        ? _selection.clear()
        : _selection.replace(
            root: _coordinator.snapshot.root,
            targets: targets,
          );
    setState(() {
      _status = result is Ok
          ? (targets.isEmpty
                ? 'Selection cleared'
                : '${targets.length} Objects selected')
          : 'Selection rejected';
    });
  }

  void _pointSelection(Point2 pagePoint) {
    final hit = _hitTester
        .point(
          page: _page,
          pagePosition: pagePoint,
          pageTolerance: 8 / _viewport.zoom,
        )
        .fold<HitTestResult?>(onOk: (v) => v, onErr: (_) => null);
    final result = hit == null
        ? _selection.clear()
        : _selection.replace(
            root: _coordinator.snapshot.root,
            targets: [
              SelectionTarget.wholeObject(
                pageId: hit.pageId,
                objectId: hit.objectId,
              ),
            ],
          );
    setState(() {
      _status = result is Ok
          ? (hit == null ? 'Selection cleared' : 'Object selected')
          : 'Selection rejected';
    });
  }

  List<SelectionTarget> _canvasWholeObjectTargets(
    Iterable<HitTestResult> hits,
  ) {
    final seen = <ObjectId>{};
    final targets = <SelectionTarget>[];
    for (final hit in hits) {
      if (!seen.add(hit.objectId)) continue;
      targets.add(
        SelectionTarget.wholeObject(pageId: hit.pageId, objectId: hit.objectId),
      );
      if (targets.length == widget.runtime.maximumSelectionTargets) break;
    }
    return List<SelectionTarget>.unmodifiable(targets);
  }

  void _finishWholeErase() {
    final plan = _wholeEraserPlan;
    final noHits = plan != null && plan.affectedStrokeCount == 0;
    final limitReached = plan?.limitReached ?? false;
    final request = plan != null && plan.isCurrent(_coordinator.snapshot)
        ? plan.createRequest(uuidGenerator: _uuid)
        : null;
    final commit =
        request is Ok<AtomicObjectCollectionEditRequest, StructuredFailure>
        ? _coordinator.execute(request.value)
        : null;
    if (plan != null) {
      _diagnostics.record(
        stage: Phase6DiagnosticStage.eraserTerminal,
        pointerSegments: plan.processedSegmentCount,
        acceptedTargets: plan.affectedStrokeCount,
        rejectedTargets: plan.rejectedExcessTargetCount,
        commandOperations: plan.commandOperationCount,
        terminalDisposition: commit is Ok ? (limitReached ? 3 : 1) : 2,
      );
    }
    _clearEraserTransient();
    _selection.reconcile(_coordinator.snapshot.root);
    setState(
      () => _status = commit is Ok
          ? limitReached
                ? 'Eraser limit reached; accepted erasures applied'
                : 'Stroke erased'
          : noHits
          ? 'Nothing erased'
          : 'Erase rejected',
    );
  }

  void _cancelGesture(String status) {
    _pen?.cancel();
    _clearCanvasModifierState(recomputeRotation: false);
    _penCursor.clear();
    _router.cancel();
    _cancelNavigation();
    _selection.cancelTransform();
    _selectionTransformEvidence = null;
    _disposeSelectionTransformPreparation();
    _clearEraserTransient();
    _clearPenPreview();
    _clearPendingSelectionTransformUpdate();
    setState(() {
      _pen = null;
      _selectionDown = null;
      _selectionCurrent = null;
      _selectionTransformMode = null;
      _selectionTransformDown = null;
      _selectionTransformBounds = null;
      _selectionTransformPivot = null;
      _selectionTransformInitialViewWidth = null;
      _selectionTransformInitialViewHeight = null;
      _selectionResizeHandle = null;
      _selectionResizeClampedToInitial = false;
      _creationDown = null;
      _creationCurrent = null;
      _status = status;
    });
  }

  void _clearEraserTransient() {
    _eraserCursor.clear();
    _wholeEraserPath.clear();
    _eraserObjectPreviews.clear();
    _eraserPreviewPrimitive = null;
    _wholeEraserPlan = null;
  }

  void _zoom(double factor, {ViewPoint? pivot}) {
    if (!factor.isFinite || factor <= 0) return;
    _zoomTo(
      (_viewport.zoom * factor).clamp(
        _viewport.minimumZoom,
        _viewport.maximumZoom,
      ),
      pivot: pivot,
      recenterFitted: pivot == null,
    );
  }

  void _zoomByLogDelta(double logDelta, ViewPoint pivot) {
    if (!logDelta.isFinite) return;
    final currentLog = math.log(_viewport.zoom);
    final proposedLog = currentLog + logDelta;
    final minimumLog = math.log(_viewport.minimumZoom);
    final maximumLog = math.log(_viewport.maximumZoom);
    final targetLog = proposedLog.isFinite
        ? proposedLog.clamp(minimumLog, maximumLog)
        : logDelta.isNegative
        ? minimumLog
        : maximumLog;
    _zoomTo(math.exp(targetLog), pivot: pivot, recenterFitted: false);
  }

  void _zoomTo(double zoom, {ViewPoint? pivot, bool recenterFitted = true}) {
    if (_router.ownership.owner != null) return;
    if (!zoom.isFinite ||
        zoom < _viewport.minimumZoom ||
        zoom > _viewport.maximumZoom) {
      setState(() => _status = 'Zoom rejected');
      return;
    }
    final effectivePivot =
        pivot ??
        _viewPoint(_viewport.extent.width / 2, _viewport.extent.height / 2);
    final result = _viewport.zoomedAbout(
      newZoom: zoom,
      viewPivot: effectivePivot,
      expectedRevision: _viewport.revision,
    );
    if (result is Ok<ViewportSnapshot, StructuredFailure>) {
      final next = recenterFitted
          ? _recenterWhenPageFits(result.value)
          : result.value;
      if (next != null) _publishViewport(next, 'Zoom');
    }
  }

  void _publishViewport(ViewportSnapshot next, String status) {
    final published = _viewportController.publish(next);
    if (published is! Ok<ViewportSnapshot, StructuredFailure>) return;
    _invalidateSelectionTransformForExternalChange();
    setState(() {
      _viewport = published.value;
      _zoomController.text = (_viewport.zoom * 100).toStringAsFixed(
        (_viewport.zoom * 100) % 1 == 0 ? 0 : 1,
      );
      _status = '$status ${(_viewport.zoom * 100).round()}%';
    });
  }

  void _applyZoomInput(String source) {
    final percentage = double.tryParse(source.trim());
    if (percentage == null || !percentage.isFinite) {
      setState(() => _status = 'Zoom rejected');
      return;
    }
    _zoomTo(percentage / 100);
  }

  void _fitPage() => _fitViewport(widthOnly: false);

  void _fitWidth() => _fitViewport(widthOnly: true);

  void _fitViewport({required bool widthOnly}) {
    if (_router.ownership.owner != null) return;
    final usableWidth = math.max(
      1,
      _viewport.extent.width - 2 * _workspacePadding,
    );
    final usableHeight = math.max(
      1,
      _viewport.extent.height - 2 * _workspacePadding,
    );
    final proposed = widthOnly
        ? usableWidth / _page.size.width
        : math.min(
            usableWidth / _page.size.width,
            usableHeight / _page.size.height,
          );
    final zoom = proposed.clamp(_viewport.minimumZoom, _viewport.maximumZoom);
    final revision = _viewport.revision.increment();
    if (revision is! Ok<Revision, StructuredFailure>) return;
    final extent = _viewport.extent;
    final origin = _point(
      -(extent.width / zoom - _page.size.width) / 2,
      widthOnly
          ? _centeredOrigin(
              extent: extent,
              zoom: zoom,
              fallback: _viewport.pageOrigin,
            ).y
          : -(extent.height / zoom - _page.size.height) / 2,
    );
    final next = ViewportSnapshot.create(
      extent: extent,
      pageOrigin: origin,
      zoom: zoom,
      minimumZoom: _viewport.minimumZoom,
      maximumZoom: _viewport.maximumZoom,
      revision: revision.value,
    );
    if (next is Ok<ViewportSnapshot, StructuredFailure>) {
      _publishViewport(next.value, widthOnly ? 'Fit width' : 'Fit page');
    }
  }

  Rect2 get _pageBounds => _ok(
    Rect2.fromEdges(
      left: 0,
      top: 0,
      right: _page.size.width,
      bottom: _page.size.height,
    ),
  );

  void _panByViewDelta(double dx, double dy) {
    if (dx == 0 && dy == 0) return;
    final delta = Vector2.create(x: dx, y: dy);
    if (delta is! Ok<Vector2, StructuredFailure>) return;
    final next = _viewport.pannedByViewDelta(
      viewDelta: delta.value,
      pageBounds: _pageBounds,
      minimumReachablePixels: 48,
      expectedRevision: _viewport.revision,
    );
    if (next is Ok<ViewportSnapshot, StructuredFailure>) {
      if (next.value.revision == _viewport.revision) return;
      _publishViewport(next.value, 'Pan');
    }
  }

  bool _beginNavigation(PointerDownEvent event) {
    final position = _validatedViewPoint(
      event.localPosition.dx,
      event.localPosition.dy,
    );
    if (position == null) return false;
    final middle = event.buttons & kMiddleMouseButton != 0;
    final touch = event.kind == PointerDeviceKind.touch;
    final spacePrimary =
        event.buttons & kPrimaryMouseButton != 0 &&
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.space,
        );
    if (!middle && !spacePrimary && !touch) return false;
    if (_navigationPointer != null) return true;
    _penCursor.clear();
    _router.cancel();
    _selection.cancelTransform();
    _selectionTransformEvidence = null;
    _disposeSelectionTransformPreparation();
    _navigationPointer = event.pointer;
    _navigationLast = position;
    setState(() => _status = 'Panning');
    return true;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_tool == _CanvasTool.pen) _updatePenCursorAt(event.localPosition);
    if (_validatedViewPoint(event.localPosition.dx, event.localPosition.dy) ==
        null) {
      return;
    }
    if (_inlineResizePointer != null) return;
    final inlineHandle = _inlineTextResizeHandleAt(event.localPosition);
    if (_inlineText != null &&
        inlineHandle != null &&
        event.buttons & kPrimaryMouseButton != 0) {
      _inlineResizePointer = event.pointer;
      _inlineResizeHandle = inlineHandle;
      _inlineResizeStartBounds = _inlineText!.pageBounds;
      _inlineResizeSourceTransform = _inlineText!.existing?.transform;
      _inlineText!.preservedAnchor = _inlineTextResizePreservedAnchor(
        inlineHandle,
      );
      _inlineTextFocus?.requestFocus();
      return;
    }
    if (_inlineText != null &&
        _inlineEditorContainsViewPoint(event.localPosition)) {
      return;
    }
    if (_inlineText != null && !_commitInlineTextEditor()) return;
    _canvasFocus.requestFocus();
    _synchronizeCanvasShiftStateFromHardware();
    if (_beginNavigation(event)) return;
    _pointer(event);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (_tool == _CanvasTool.pen) _updatePenCursorAt(event.localPosition);
    if (_inlineResizePointer == event.pointer) {
      _updateInlineTextResize(event.localPosition);
      return;
    }
    if (_navigationPointer == event.pointer) {
      final previous = _navigationLast;
      final current = _validatedViewPoint(
        event.localPosition.dx,
        event.localPosition.dy,
      );
      if (current == null) {
        _cancelNavigation(status: 'Pan cancelled');
        return;
      }
      _navigationLast = current;
      if (previous != null) {
        _panByViewDelta(current.x - previous.x, current.y - previous.y);
      }
      return;
    }
    if (_selectionTransformMode != null) {
      _scheduleSelectionTransformMove(event);
      return;
    }
    _pointer(event);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_tool == _CanvasTool.pen) _updatePenCursorAt(event.localPosition);
    if (_inlineResizePointer == event.pointer) {
      _inlineResizePointer = null;
      _inlineResizeHandle = null;
      _inlineResizeStartBounds = null;
      _inlineResizeSourceTransform = null;
      _inlineTextFocus?.requestFocus();
      return;
    }
    if (_navigationPointer == event.pointer) {
      _cancelNavigation(status: 'Pan complete');
      return;
    }
    _flushSelectionTransformMove(event);
    _pointer(event);
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _penCursor.clear();
    if (_inlineResizePointer == event.pointer) {
      _inlineResizePointer = null;
      _inlineResizeHandle = null;
      _inlineResizeStartBounds = null;
      _inlineResizeSourceTransform = null;
      _inlineTextFocus?.requestFocus();
      return;
    }
    if (_navigationPointer == event.pointer) {
      _cancelNavigation(status: 'Pan cancelled');
      return;
    }
    _clearPendingSelectionTransformUpdate();
    _pointer(event);
  }

  Rect2? _paperViewRect() {
    final topLeft = _viewport.pageToView(_point(0, 0));
    final bottomRight = _viewport.pageToView(
      _point(_page.size.width, _page.size.height),
    );
    if (topLeft is! Ok<ViewPoint, StructuredFailure> ||
        bottomRight is! Ok<ViewPoint, StructuredFailure>) {
      return null;
    }
    return Rect2.fromEdges(
      left: math.min(topLeft.value.x, bottomRight.value.x),
      top: math.min(topLeft.value.y, bottomRight.value.y),
      right: math.max(topLeft.value.x, bottomRight.value.x),
      bottom: math.max(topLeft.value.y, bottomRight.value.y),
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
  }

  void _updatePenCursorAt(Offset viewPosition) {
    final paper = _paperViewRect();
    if (_tool != _CanvasTool.pen ||
        paper == null ||
        viewPosition.dx < paper.left ||
        viewPosition.dx > paper.right ||
        viewPosition.dy < paper.top ||
        viewPosition.dy > paper.bottom) {
      _penCursor.clear();
      return;
    }
    final point = ViewPoint.create(x: viewPosition.dx, y: viewPosition.dy);
    if (point is Ok<ViewPoint, StructuredFailure>) {
      _penCursor.update(point.value);
    } else {
      _penCursor.clear();
    }
  }

  _TextResizeHandle? _inlineTextResizeHandleAt(Offset viewPoint) {
    final session = _inlineText;
    if (session == null) return null;
    return _resizeHandleAtView(
      viewPoint,
      _viewCorners(
        session.pageBounds,
        session.existing == null ? null : session.currentTransform,
      ),
    );
  }

  void _updateInlineTextResize(Offset viewPoint) {
    final session = _inlineText;
    final handle = _inlineResizeHandle;
    final start = _inlineResizeStartBounds;
    if (session == null || handle == null || start == null) return;
    final view = ViewPoint.create(x: viewPoint.dx, y: viewPoint.dy);
    final page = view is Ok<ViewPoint, StructuredFailure>
        ? _viewport.viewToPage(view.value)
        : null;
    Point2? local = page is Ok<Point2, StructuredFailure> ? page.value : null;
    final sourceTransform = _inlineResizeSourceTransform;
    if (local != null && sourceTransform != null) {
      final inverse = sourceTransform.inverse();
      local = inverse is Ok<AffineTransform2D, StructuredFailure>
          ? inverse.value
                .applyToPoint(local)
                .fold<Point2?>(onOk: (value) => value, onErr: (_) => null)
          : null;
    }
    if (local == null) return;
    const minimum = 12.0;
    final affectsLeft =
        handle == _TextResizeHandle.left ||
        handle == _TextResizeHandle.topLeft ||
        handle == _TextResizeHandle.bottomLeft;
    final affectsRight =
        handle == _TextResizeHandle.right ||
        handle == _TextResizeHandle.topRight ||
        handle == _TextResizeHandle.bottomRight;
    final affectsTop =
        handle == _TextResizeHandle.top ||
        handle == _TextResizeHandle.topLeft ||
        handle == _TextResizeHandle.topRight;
    final affectsBottom =
        handle == _TextResizeHandle.bottom ||
        handle == _TextResizeHandle.bottomLeft ||
        handle == _TextResizeHandle.bottomRight;
    if (sourceTransform == null) {
      final left = affectsLeft
          ? math.min(local.x, start.right - minimum)
          : start.left;
      final right = affectsRight
          ? math.max(local.x, start.left + minimum)
          : start.right;
      final top = affectsTop
          ? math.min(local.y, start.bottom - minimum)
          : start.top;
      final bottom = affectsBottom
          ? math.max(local.y, start.top + minimum)
          : start.bottom;
      final bounds = Rect2.fromEdges(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      );
      if (bounds is Ok<Rect2, StructuredFailure>) {
        setState(() => session.pageBounds = bounds.value);
      }
      return;
    }
    final width = affectsLeft
        ? math.max(minimum, start.right - local.x)
        : affectsRight
        ? math.max(minimum, local.x - start.left)
        : start.width;
    final height = affectsTop
        ? math.max(minimum, start.bottom - local.y)
        : affectsBottom
        ? math.max(minimum, local.y - start.top)
        : start.height;
    final bounds = Rect2.fromEdges(
      left: 0,
      top: 0,
      right: width,
      bottom: height,
    );
    final delta = Vector2.create(
      x: affectsLeft ? start.width - width : 0,
      y: affectsTop ? start.height - height : 0,
    );
    final translation = delta is Ok<Vector2, StructuredFailure>
        ? AffineTransform2D.fromOperation(
            TranslationTransformOperation2D(delta.value),
          )
        : null;
    final transform = translation is Ok<AffineTransform2D, StructuredFailure>
        ? translation.value.then(sourceTransform)
        : null;
    if (bounds is Ok<Rect2, StructuredFailure> &&
        transform is Ok<AffineTransform2D, StructuredFailure>) {
      setState(() {
        session.pageBounds = bounds.value;
        session.resizedTransform = transform.value;
      });
    }
  }

  TextBoxResizePreservedAnchor _inlineTextResizePreservedAnchor(
    _TextResizeHandle handle,
  ) => switch (handle) {
    _TextResizeHandle.topLeft => TextBoxResizePreservedAnchor.bottomRight,
    _TextResizeHandle.top ||
    _TextResizeHandle.topRight => TextBoxResizePreservedAnchor.bottomLeft,
    _TextResizeHandle.right ||
    _TextResizeHandle.bottomRight ||
    _TextResizeHandle.bottom => TextBoxResizePreservedAnchor.topLeft,
    _TextResizeHandle.bottomLeft ||
    _TextResizeHandle.left => TextBoxResizePreservedAnchor.topRight,
  };

  void _handleCanvasHover(PointerHoverEvent event) {
    final inline = _inlineTextResizeHandleAt(event.localPosition);
    _TextResizeHandle? selected;
    _SelectionFrameSnapshot? frame;
    if (_inlineText == null) {
      frame = _selectionFrame;
      if (frame == null || !_selectionFrameIsCurrent(frame)) {
        frame = _createSelectionFrame();
      }
      if (inline == null && frame != null) {
        selected = frame.resizeHandleAt(event.localPosition);
      }
    } else {
      _selectionFrame = null;
    }
    final next = inline ?? selected;
    final zoneCode = selected == null ? 0 : selected.index + 1;
    final cursorCode = selected == null || frame == null
        ? 0
        : _resizeCursorCodeForDirection(
            frame.resizeDirection(selected).dx,
            frame.resizeDirection(selected).dy,
          );
    if (zoneCode != _lastSelectionHoverZoneCode ||
        cursorCode != _lastSelectionCursorCode) {
      _lastSelectionHoverZoneCode = zoneCode;
      _lastSelectionCursorCode = cursorCode;
      final counts = _selectionTargetTypeCounts;
      _diagnostics.record(
        stage: Phase6DiagnosticStage.selectionHoverSummary,
        acceptedTargets: _selection.state.targets.length,
        handwritingTargetCount: counts.handwriting,
        shapeTargetCount: counts.shape,
        textTargetCount: counts.text,
        hoverZoneCode: zoneCode,
        cursorCode: cursorCode,
      );
    }
    if (next != _hoverTextResizeHandle) {
      setState(() => _hoverTextResizeHandle = next);
    }
  }

  MouseCursor get _canvasMouseCursor {
    final handle = _hoverTextResizeHandle;
    if (handle == null) return SystemMouseCursors.basic;
    var dx = 0.0;
    var dy = 0.0;
    final frame = _selectionFrame;
    if (_inlineText == null &&
        frame != null &&
        _selectionFrameIsCurrent(frame)) {
      final direction = frame.resizeDirection(handle);
      dx = direction.dx;
      dy = direction.dy;
    } else {
      final vector = switch (handle) {
        _TextResizeHandle.left || _TextResizeHandle.right => _point(1, 0),
        _TextResizeHandle.top || _TextResizeHandle.bottom => _point(0, 1),
        _TextResizeHandle.topLeft ||
        _TextResizeHandle.bottomRight => _point(1, 1),
        _TextResizeHandle.topRight ||
        _TextResizeHandle.bottomLeft => _point(1, -1),
      };
      dx = vector.x;
      dy = vector.y;
      final transform = _inlineText?.existing != null
          ? _inlineText!.currentTransform
          : null;
      final value = Vector2.create(
        x: dx,
        y: dy,
      ).fold<Vector2?>(onOk: (value) => value, onErr: (_) => null);
      final rotated = value == null || transform == null
          ? null
          : transform
                .applyToVector(value)
                .fold<Vector2?>(onOk: (value) => value, onErr: (_) => null);
      if (rotated != null) {
        dx = rotated.x;
        dy = rotated.y;
      }
    }
    return switch (_resizeCursorCodeForDirection(dx, dy)) {
      1 => SystemMouseCursors.resizeLeftRight,
      2 => SystemMouseCursors.resizeUpLeftDownRight,
      3 => SystemMouseCursors.resizeUpDown,
      _ => SystemMouseCursors.resizeUpRightDownLeft,
    };
  }

  int _resizeCursorCodeForDirection(double dx, double dy) =>
      ((math.atan2(dy, dx) / (math.pi / 4)).round() % 4 + 4) % 4 + 1;

  void _scheduleSelectionTransformMove(PointerMoveEvent event) {
    final update = _selectionTransformUpdateFrom(event);
    if (update == null) {
      _abandonSelectionTransform('Transform unavailable', failureStageCode: 1);
      return;
    }
    _textTransformRequests += 1;
    _pendingSelectionTransformUpdate = update;
    if (_selectionTransformFrameScheduled) return;
    _selectionTransformFrameScheduled = true;
    final generation = _selectionTransformGeneration;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (!mounted || generation != _selectionTransformGeneration) return;
      _selectionTransformFrameScheduled = false;
      final latest = _pendingSelectionTransformUpdate;
      _pendingSelectionTransformUpdate = null;
      if (latest != null) {
        _applySelectionTransformUpdate(latest.pagePoint, latest.modifiers);
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _flushSelectionTransformMove(PointerUpEvent event) {
    if (_selectionTransformMode == null) {
      _clearPendingSelectionTransformUpdate();
      return;
    }
    final pending = _pendingSelectionTransformUpdate;
    _pendingSelectionTransformUpdate = null;
    _selectionTransformGeneration += 1;
    _selectionTransformFrameScheduled = false;
    if (pending != null) {
      _applySelectionTransformUpdate(pending.pagePoint, pending.modifiers);
    }
    if (_selectionTransformMode == null) return;
    final terminal = _selectionTransformUpdateFrom(event);
    if (terminal != null &&
        !_sameSelectionTransformUpdate(
          terminal,
          _lastSelectionTransformUpdate,
        )) {
      _applySelectionTransformUpdate(terminal.pagePoint, terminal.modifiers);
    }
  }

  _PendingSelectionTransformUpdate? _selectionTransformUpdateFrom(
    PointerEvent event,
  ) {
    final normalized = widget.runtime.pointerAdapter.normalize(event);
    if (normalized is! Ok<NormalizedPointerEvent, StructuredFailure>) {
      return null;
    }
    final pagePoint = _viewport
        .viewToPage(normalized.value.viewPosition)
        .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    final modifiers = _selectionModifiersAtPointerArrival(
      normalized.value.modifiers,
    );
    return pagePoint == null
        ? null
        : _PendingSelectionTransformUpdate(
            pagePoint: pagePoint,
            modifiers: modifiers,
          );
  }

  InputModifiers _selectionModifiersAtPointerArrival(InputModifiers source) {
    final shift = _leftShiftDown || _rightShiftDown;
    if (shift) _shiftPointerUpdates += 1;
    return InputModifiers(
      shift: shift,
      control: source.control,
      alt: source.alt,
      meta: source.meta,
    );
  }

  KeyEventResult _handleCanvasKeyEvent(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isLeft = key == LogicalKeyboardKey.shiftLeft;
    final isRight = key == LogicalKeyboardKey.shiftRight;
    if (!isLeft && !isRight) return KeyEventResult.ignored;
    final down = event is KeyDownEvent || event is KeyRepeatEvent;
    final before = _leftShiftDown || _rightShiftDown;
    if (isLeft) {
      if (down && !_leftShiftDown) _shiftKeyDownEvents += 1;
      if (!down && _leftShiftDown) _shiftKeyUpEvents += 1;
      _leftShiftDown = down;
    } else {
      if (down && !_rightShiftDown) _shiftKeyDownEvents += 1;
      if (!down && _rightShiftDown) _shiftKeyUpEvents += 1;
      _rightShiftDown = down;
    }
    final after = _leftShiftDown || _rightShiftDown;
    if (before != after) _recomputeRotationForTrackedShift();
    return KeyEventResult.handled;
  }

  void _synchronizeCanvasShiftStateFromHardware() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    _leftShiftDown = pressed.contains(LogicalKeyboardKey.shiftLeft);
    _rightShiftDown = pressed.contains(LogicalKeyboardKey.shiftRight);
  }

  void _recomputeRotationForTrackedShift() {
    if (_selectionTransformMode != _SelectionTransformMode.rotate) return;
    final prior = _lastSelectionTransformUpdate;
    final point = prior?.pagePoint;
    if (point == null) return;
    final source = prior?.modifiers ?? const InputModifiers();
    _applySelectionTransformUpdate(
      point,
      InputModifiers(
        shift: _leftShiftDown || _rightShiftDown,
        control: source.control,
        alt: source.alt,
        meta: source.meta,
      ),
    );
  }

  void _clearCanvasModifierState({required bool recomputeRotation}) {
    final changed = _leftShiftDown || _rightShiftDown;
    _leftShiftDown = false;
    _rightShiftDown = false;
    if (changed && recomputeRotation) _recomputeRotationForTrackedShift();
  }

  bool _sameSelectionTransformUpdate(
    _PendingSelectionTransformUpdate left,
    _PendingSelectionTransformUpdate? right,
  ) =>
      right != null &&
      left.pagePoint == right.pagePoint &&
      left.modifiers.shift == right.modifiers.shift &&
      left.modifiers.control == right.modifiers.control &&
      left.modifiers.alt == right.modifiers.alt &&
      left.modifiers.meta == right.modifiers.meta;

  void _clearPendingSelectionTransformUpdate() {
    _selectionTransformGeneration += 1;
    _selectionTransformFrameScheduled = false;
    _pendingSelectionTransformUpdate = null;
    _lastSelectionTransformUpdate = null;
  }

  void _resetSelectionRotationTracking() {
    _selectionRotationLastPointerAngle = null;
    _selectionRotationLastPointerPoint = null;
    _selectionRotationUnwrappedAngle = 0;
    _selectionRotationIdentityPreview = false;
  }

  double? _continuousSelectionRotation(Point2 current, Point2 pivot) {
    final raw = math.atan2(current.y - pivot.y, current.x - pivot.x);
    if (!raw.isFinite) return null;
    final previous = _selectionRotationLastPointerAngle;
    final previousPoint = _selectionRotationLastPointerPoint;
    if (previous == null || previousPoint == null) {
      _selectionRotationLastPointerAngle = raw;
      _selectionRotationLastPointerPoint = current;
      return _selectionRotationUnwrappedAngle;
    }
    if (previousPoint == current) return _selectionRotationUnwrappedAngle;
    var delta = raw - previous;
    if (delta > math.pi) {
      delta -= 2 * math.pi;
      _selectionRotationBranchCrossings += 1;
    } else if (delta < -math.pi) {
      delta += 2 * math.pi;
      _selectionRotationBranchCrossings += 1;
    }
    final next = _selectionRotationUnwrappedAngle + delta;
    if (!next.isFinite) return null;
    _selectionRotationLastPointerAngle = raw;
    _selectionRotationLastPointerPoint = current;
    _selectionRotationUnwrappedAngle = next;
    _selectionRotationUnwrappedTransitions += 1;
    return next;
  }

  bool _isIdentityRotation(double radians) {
    if (!radians.isFinite) return false;
    final turns = radians / (2 * math.pi);
    return (turns - turns.round()).abs() <= 1e-12;
  }

  void _resetSelectionTransformPerformanceEvidence() {
    _textLayoutRequests = 0;
    _textLayoutCacheHits = 0;
    _textTransformRequests = 0;
    _textPreviewRepaints = 0;
    _selectionTransformFrameUpdates = 0;
    _selectionTransformRegistryResolutions = 0;
    _selectionTransformRendererPreparations = 0;
    _selectionTransformCompositions = 0;
    _selectionTransformMaximumRetainedEvidence = 0;
    _selectionTransformPictureCreations = 0;
    _selectionTransformHandwritingPreparations = 0;
    _selectionTransformFramePrimitiveRebuilds = 0;
    _selectionTransformUnrelatedReplays = 0;
    _selectionTransformPublications = 0;
    _shiftKeyDownEvents = 0;
    _shiftKeyUpEvents = 0;
    _shiftPointerUpdates = 0;
    _snappedPreviewUpdates = 0;
    _selectionRotationUnwrappedTransitions = 0;
    _selectionRotationIdentityEntries = 0;
    _selectionRotationIdentityExits = 0;
    _selectionRotationBranchCrossings = 0;
    _resetSelectionRotationTracking();
    _clearPendingSelectionTransformUpdate();
  }

  void _cancelNavigation({String? status}) {
    final changed = _navigationPointer != null || _panZoomFocalPoint != null;
    _navigationPointer = null;
    _navigationLast = null;
    _panZoomScale = 1;
    _panZoomFocalPoint = null;
    _pendingNavigationOperations.clear();
    if (changed && mounted && status != null) setState(() => _status = status);
  }

  void _pointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _router.ownership.owner != null) return;
    if (_pendingNavigationOperations.length >=
        _maximumPendingNavigationOperations) {
      return;
    }
    final dx = event.scrollDelta.dx;
    final dy = event.scrollDelta.dy;
    if (!dx.isFinite || !dy.isFinite) return;
    final control = HardwareKeyboard.instance.isControlPressed;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    if (control || meta) {
      final pivot = _validatedViewPoint(
        event.localPosition.dx,
        event.localPosition.dy,
      );
      final logDelta = -dy * .002;
      if (pivot == null || !logDelta.isFinite) return;
      _pendingNavigationOperations.add(_PendingZoom(logDelta, pivot));
    } else {
      final delta = Vector2.create(x: -dx, y: -dy);
      if (delta is! Ok<Vector2, StructuredFailure>) return;
      _pendingNavigationOperations.add(
        _PendingPan(delta.value.x, delta.value.y),
      );
    }
    _scheduleNavigationFrame();
  }

  void _scheduleNavigationFrame() {
    if (_navigationFrameScheduled) return;
    _navigationFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _navigationFrameScheduled = false;
      if (!mounted) return;
      final operations = List<_PendingNavigationOperation>.of(
        _pendingNavigationOperations,
      );
      _pendingNavigationOperations.clear();
      for (final operation in operations) {
        switch (operation) {
          case _PendingPan(:final dx, :final dy):
            _panByViewDelta(dx, dy);
          case _PendingZoom(:final logDelta, :final pivot):
            _zoomByLogDelta(logDelta, pivot);
        }
      }
    });
  }

  void _scaleStart(ScaleStartDetails details) {
    if (details.pointerCount < 2) return;
    final focalPoint = _validatedViewPoint(
      details.localFocalPoint.dx,
      details.localFocalPoint.dy,
    );
    if (focalPoint == null) return;
    _router.cancel();
    _navigationPointer = null;
    _navigationLast = null;
    _panZoomScale = 1;
    _panZoomFocalPoint = focalPoint;
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    final previous = _panZoomFocalPoint;
    if (previous == null) return;
    final current = _validatedViewPoint(
      details.localFocalPoint.dx,
      details.localFocalPoint.dy,
    );
    if (current == null ||
        !details.scale.isFinite ||
        details.scale <= 0 ||
        !_panZoomScale.isFinite ||
        _panZoomScale <= 0) {
      _cancelNavigation(status: 'Pan cancelled');
      return;
    }
    final relativeScale = details.scale / _panZoomScale;
    if (!relativeScale.isFinite || relativeScale <= 0) {
      _cancelNavigation(status: 'Pan cancelled');
      return;
    }
    final panDelta = Vector2.create(
      x: current.x - previous.x,
      y: current.y - previous.y,
    );
    if (panDelta is! Ok<Vector2, StructuredFailure>) {
      _cancelNavigation(status: 'Pan cancelled');
      return;
    }
    _panByViewDelta(panDelta.value.x, panDelta.value.y);
    if (relativeScale != 1) {
      _zoom(relativeScale, pivot: current);
    }
    _panZoomScale = details.scale;
    _panZoomFocalPoint = current;
  }

  void _scaleEnd(ScaleEndDetails details) {
    if (_panZoomFocalPoint != null) _cancelNavigation(status: 'Pan complete');
  }

  void _updateTextOptions(VoidCallback change) {
    setState(() {
      change();
      if (_inlineText != null) _activeTextDraft = _currentTextDraft;
    });
  }

  void _keyboardTransform(TransformOperation2D operation) {
    _resetSelectionTransformPerformanceEvidence();
    _diagnostics.beginGesture();
    final targetTypeCounts = _selectionTargetTypeCounts;
    final transformModeCode = switch (operation) {
      TranslationTransformOperation2D() => 1,
      ScaleTransformOperation2D() => 2,
      RotationTransformOperation2D() => 3,
      _ => 0,
    };
    final prepared = _prepareSelectionTransform();
    if (prepared == null) {
      _diagnostics.record(
        stage: Phase6DiagnosticStage.selectionTransformPreview,
        acceptedTargets: _selection.state.targets.length,
        geometryResolutions: _selectionTransformRegistryResolutions,
        commandOperations: _selectionTransformRendererPreparations,
        maximumRetainedResources: _selectionTransformMaximumRetainedEvidence,
        terminalDisposition: 2,
        handwritingTargetCount: targetTypeCounts.handwriting,
        shapeTargetCount: targetTypeCounts.shape,
        textTargetCount: targetTypeCounts.text,
        transformModeCode: transformModeCode,
        failureStageCode: 7,
      );
      setState(() => _status = 'Transform unavailable');
      return;
    }
    _replaceSelectionTransformPreparation(prepared);
    final validated = _validateSelectionTransformPreview(
      operation,
      identity: false,
    );
    if (validated
        is! Ok<_SelectionTransformRenderEvidence, StructuredFailure>) {
      _disposeSelectionTransformPreparation();
      setState(() => _status = 'Transform unavailable');
      return;
    }
    final started = _selection.beginTransform(
      document: _coordinator.snapshot,
      operation: operation,
    );
    if (started is! Ok<SelectionState, SelectionFailure>) {
      _disposeSelectionTransformPreparation();
      _diagnostics.record(
        stage: Phase6DiagnosticStage.selectionTransformPreview,
        transformRequests: 1,
        acceptedTargets: _selection.state.targets.length,
        geometryResolutions: _selectionTransformRegistryResolutions,
        commandOperations: _selectionTransformRendererPreparations,
        maximumRetainedResources: _selectionTransformMaximumRetainedEvidence,
        terminalDisposition: 2,
        handwritingTargetCount: targetTypeCounts.handwriting,
        shapeTargetCount: targetTypeCounts.shape,
        textTargetCount: targetTypeCounts.text,
        transformModeCode: transformModeCode,
        failureStageCode: 2,
      );
      setState(() => _status = 'Transform unavailable');
      return;
    }
    final preview = _selection.state.transformPreview;
    final request = preview?.commandRequest(
      CommandMetadata(
        family: CommandFamily.wholeObjectTransform,
        correlationId: CommandCorrelationId.fromUuid(
          preview.targetIds.first.uuid,
        ),
        description: 'Transform selection',
      ),
    );
    final committed =
        request is Ok<AtomicWholeObjectTransformRequest, StructuredFailure> &&
        _coordinator.execute(request.value)
            is Ok<CommandCommit, CommandFailure>;
    _diagnostics.record(
      stage: Phase6DiagnosticStage.selectionTransformPreview,
      visualUpdates: 1,
      layoutRequests: _textLayoutRequests,
      cacheHits: _textLayoutCacheHits,
      transformRequests: 1,
      acceptedTargets: _selection.state.targets.length,
      sceneCompositions: _selectionTransformCompositions,
      geometryResolutions: _selectionTransformRegistryResolutions,
      commandOperations: _selectionTransformRendererPreparations,
      maximumRetainedResources: _selectionTransformMaximumRetainedEvidence,
      terminalDisposition: committed ? 1 : 2,
      handwritingTargetCount: targetTypeCounts.handwriting,
      shapeTargetCount: targetTypeCounts.shape,
      textTargetCount: targetTypeCounts.text,
      transformModeCode: transformModeCode,
      failureStageCode: committed ? 0 : 6,
    );
    _selection.cancelTransform();
    _selectionTransformEvidence = null;
    _disposeSelectionTransformPreparation();
    _selection.reconcile(_coordinator.snapshot.root);
    setState(
      () => _status = committed
          ? 'Selection transformed'
          : 'Transform unavailable',
    );
  }

  TransformOperation2D? _keyboardScale(double factor) {
    var frame = _selectionFrame;
    if (frame == null || !_selectionFrameIsCurrent(frame)) {
      frame = _createSelectionFrame();
    }
    final pivot = frame?.pageCenter;
    if (pivot == null) return null;
    return ScaleTransformOperation2D.create(
      scaleX: factor,
      scaleY: factor,
      pivot: pivot,
    ).fold<TransformOperation2D?>(onOk: (value) => value, onErr: (_) => null);
  }

  TransformOperation2D? _keyboardRotation(double radians) {
    var frame = _selectionFrame;
    if (frame == null || !_selectionFrameIsCurrent(frame)) {
      frame = _createSelectionFrame();
    }
    final pivot = frame?.pageCenter;
    if (pivot == null) return null;
    return RotationTransformOperation2D.create(
      radians: radians,
      pivot: pivot,
    ).fold<TransformOperation2D?>(onOk: (value) => value, onErr: (_) => null);
  }

  ({bool movable, bool resizable, bool rotatable})
  get _currentSelectionCapabilities {
    final targets = _selection.state.targets;
    if (targets.isEmpty || targets.any((target) => !target.isWholeObject)) {
      return (movable: false, resizable: false, rotatable: false);
    }
    var movable = true;
    var resizable = true;
    var rotatable = true;
    for (final target in targets) {
      final object = _page.layers
          .expand((layer) => layer.objects)
          .where((candidate) => candidate.id == target.objectId)
          .firstOrNull;
      final resolution = object == null ? null : _registry.resolve(object);
      if (resolution is! SupportedObjectResolution) {
        return (movable: false, resizable: false, rotatable: false);
      }
      movable &= resolution.definition.capabilities.movable;
      resizable &= resolution.definition.capabilities.resizable;
      rotatable &= resolution.definition.capabilities.rotatable;
    }
    return (movable: movable, resizable: resizable, rotatable: rotatable);
  }

  ({int handwriting, int shape, int text}) get _selectionTargetTypeCounts {
    var handwriting = 0;
    var shape = 0;
    var text = 0;
    final ids = _selection.state.targets
        .map((target) => target.objectId)
        .toSet();
    for (final object in _page.layers.expand((layer) => layer.objects)) {
      if (!ids.contains(object.id)) continue;
      if (object.typeKey == handwritingObjectTypeKey) handwriting += 1;
      if (object.typeKey == shapeObjectTypeKey) shape += 1;
      if (object.typeKey == textObjectTypeKey) text += 1;
    }
    return (handwriting: handwriting, shape: shape, text: text);
  }

  Rect2? _inlineEditorPositionRect() {
    final session = _inlineText;
    if (session == null) return null;
    final bounds = session.pageBounds;
    final page = session.existing == null
        ? bounds.topLeft
        : session.currentTransform
              .applyToPoint(bounds.topLeft)
              .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    if (page == null) return null;
    final view = _viewport.pageToView(page);
    if (view is! Ok<ViewPoint, StructuredFailure>) return null;
    return Rect2.fromEdges(
      left: view.value.x,
      top: view.value.y,
      right: view.value.x + bounds.width * _viewport.zoom,
      bottom: view.value.y + bounds.height * _viewport.zoom,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
  }

  Matrix4 _inlineEditorTransform() {
    final session = _inlineText;
    if (session?.existing == null) return Matrix4.identity();
    final c = session!.currentTransform.storageCoefficients;
    return Matrix4.identity()
      ..setEntry(0, 0, c[0])
      ..setEntry(0, 1, c[1])
      ..setEntry(1, 0, c[2])
      ..setEntry(1, 1, c[3]);
  }

  Widget _buildInlineTextEditor() {
    final bounds = _inlineEditorPositionRect();
    final controller = _inlineTextController;
    final focus = _inlineTextFocus;
    if (bounds == null || controller == null || focus == null) {
      return const SizedBox.shrink();
    }
    final align = switch (_textAlignment) {
      TextAlignment.left => TextAlign.left,
      TextAlignment.center => TextAlign.center,
      TextAlignment.right => TextAlign.right,
      TextAlignment.justified => TextAlign.justify,
      TextAlignment.start => TextAlign.start,
      TextAlignment.end => TextAlign.end,
    };
    return Positioned(
      key: const Key('inline-text-editor-overlay'),
      left: bounds.left,
      top: bounds.top,
      width: bounds.width,
      height: bounds.height,
      child: Transform(
        key: const Key('inline-text-editor-transform'),
        alignment: Alignment.topLeft,
        transform: _inlineEditorTransform(),
        child: RepaintBoundary(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape):
                  _cancelInlineTextEditor,
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _commitInlineTextEditor,
              const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                  _commitInlineTextEditor,
            },
            child: Material(
              key: const Key('inline-text-editor-surface'),
              type: MaterialType.transparency,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: TextField(
                      key: const Key('text-object-editor'),
                      controller: controller,
                      focusNode: focus,
                      autofocus: true,
                      expands: true,
                      maxLines: null,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(
                          widget.runtime.textLimits.maximumTotalScalars,
                        ),
                      ],
                      textAlign: align,
                      style: TextStyle(
                        fontSize: _textFontSize * _viewport.zoom,
                        fontWeight: _textBold
                            ? FontWeight.w700
                            : FontWeight.w400,
                        fontStyle: _textItalic
                            ? FontStyle.italic
                            : FontStyle.normal,
                        color: Color(_textArgb),
                      ),
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.all(6),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        key: const Key('inline-text-dashed-boundary'),
                        painter: _DashedTextBoundaryPainter(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _synchronizeCanvasExtent(Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width < 0 ||
        size.height < 0) {
      return;
    }
    final width = math.max(1.0, size.width);
    final height = math.max(1.0, size.height);
    if (_viewport.extent.width == width && _viewport.extent.height == height) {
      return;
    }
    final extent = ViewExtent.create(width: width, height: height);
    final revision = _viewport.revision.increment();
    if (extent is! Ok<ViewExtent, StructuredFailure> ||
        revision is! Ok<Revision, StructuredFailure>) {
      return;
    }
    final fallback = _canvasExtentInitialized
        ? Point2.create(
            x:
                _viewport.pageOrigin.x +
                (_viewport.extent.width - extent.value.width) /
                    (2 * _viewport.zoom),
            y:
                _viewport.pageOrigin.y +
                (_viewport.extent.height - extent.value.height) /
                    (2 * _viewport.zoom),
          ).fold<Point2?>(onOk: (value) => value, onErr: (_) => null)
        : Point2.create(
            x: 0,
            y: 0,
          ).fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    if (fallback == null) return;
    final resized = ViewportSnapshot.create(
      extent: extent.value,
      pageOrigin: _centeredOrigin(
        extent: extent.value,
        zoom: _viewport.zoom,
        fallback: fallback,
      ),
      zoom: _viewport.zoom,
      minimumZoom: _viewport.minimumZoom,
      maximumZoom: _viewport.maximumZoom,
      revision: revision.value,
    );
    if (resized is! Ok<ViewportSnapshot, StructuredFailure>) return;
    final published = _viewportController.publish(resized.value);
    if (published is Ok<ViewportSnapshot, StructuredFailure>) {
      _invalidateSelectionTransformForExternalChange();
      _viewport = published.value;
      _canvasExtentInitialized = true;
    }
  }

  Point2 _centeredOrigin({
    required ViewExtent extent,
    required double zoom,
    required Point2 fallback,
  }) {
    final pageWidth = _page.size.width * zoom;
    final pageHeight = _page.size.height * zoom;
    final x = pageWidth + _workspacePadding * 2 <= extent.width
        ? -(extent.width / zoom - _page.size.width) / 2
        : fallback.x;
    final y = pageHeight + _workspacePadding * 2 <= extent.height
        ? -(extent.height / zoom - _page.size.height) / 2
        : fallback.y;
    return Point2.create(
      x: x,
      y: y,
    ).fold<Point2>(onOk: (value) => value, onErr: (_) => fallback);
  }

  ViewportSnapshot? _recenterWhenPageFits(ViewportSnapshot value) =>
      ViewportSnapshot.create(
        extent: value.extent,
        pageOrigin: _centeredOrigin(
          extent: value.extent,
          zoom: value.zoom,
          fallback: value.pageOrigin,
        ),
        zoom: value.zoom,
        minimumZoom: value.minimumZoom,
        maximumZoom: value.maximumZoom,
        revision: value.revision,
      ).fold<ViewportSnapshot?>(onOk: (result) => result, onErr: (_) => null);

  void _save() {
    if (_inlineText != null && !_commitInlineTextEditor()) return;
    final capture = _coordinator.captureForSave();
    final snapshot = AlnotePackageSnapshot.create(
      document: capture.root,
      resources: capture.resources,
    );
    if (snapshot is! Ok<AlnotePackageSnapshot, StructuredFailure>) {
      _coordinator.acknowledgeSaveFailure(capture);
      setState(() => _status = 'Save failed');
      return;
    }
    final bytes = AlnotePackageCodec(
      objectRegistry: _registry,
    ).encode(snapshot.value, limits: widget.runtime.storageLimits);
    setState(() {
      if (bytes is Ok<List<int>, StructuredFailure>) {
        final acknowledged = _coordinator.acknowledgeSave(capture);
        if (acknowledged is Ok<void, CommandFailure>) {
          _savedBytes = List<int>.unmodifiable(bytes.value);
          _savedRoot = capture.root;
          _reopenedMaterializedRoot = null;
          _status = 'Saved in memory (${bytes.value.length} bytes)';
        } else {
          _coordinator.acknowledgeSaveFailure(capture);
          _status = 'Save failed';
        }
      } else {
        _coordinator.acknowledgeSaveFailure(capture);
        _status = 'Save failed';
      }
    });
  }

  void _reopen() {
    if (_inlineText != null) _cancelInlineTextEditor();
    _invalidateSelectionTransformForExternalChange();
    final bytes = _savedBytes;
    final savedRoot = _savedRoot;
    if (bytes == null || savedRoot == null) {
      setState(() => _status = 'No in-memory save exists');
      return;
    }
    final outcome = widget.runtime.reopenGateway.reopen(
      bytes: bytes,
      savedRoot: savedRoot,
    );
    if (outcome is Phase6ReopenFailure) {
      setState(
        () => _status = switch (outcome.stage) {
          Phase6ReopenFailureStage.read => 'Reopen failed (read)',
          Phase6ReopenFailureStage.materialization =>
            'Reopen failed (materialization)',
          Phase6ReopenFailureStage.mismatch => 'Reopen failed (mismatch)',
          Phase6ReopenFailureStage.coordinator => 'Reopen failed (coordinator)',
        },
      );
      return;
    }
    final reopened = outcome as Phase6ReopenSuccess;
    setState(() {
      _coordinator = reopened.coordinator;
      _selection = SelectionController(
        objectRegistry: _registry,
        coalescingBoundarySink: _coordinator,
        maximumTargets: widget.runtime.maximumSelectionTargets,
        handwritingLimits: _limits,
        strokeGeometryResolver: _geometry,
        handwritingGeometryCache: widget.runtime.geometryCache,
      );
      _pen = null;
      _clearPenPreview();
      _router.cancel();
      _clearEraserTransient();
      _selectionDown = null;
      _selectionCurrent = null;
      _committedScene = null;
      _committedPage = null;
      _reopenedMaterializedRoot = reopened.root;
      _status = 'Reopened in-memory save';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitPage();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_pen != null) _penParentBuilds += 1;
    final gestureIdle = _router.ownership.owner == null;
    final selectedText = _selectedTextObject;
    final selectionCapabilities = _currentSelectionCapabilities;
    final lineShapeSelected = _shapeCreationKind == ShapeKind.line;
    final controls = <Widget>[
      for (final tool in _CanvasTool.values)
        Semantics(
          button: true,
          selected: _tool == tool,
          label: '${tool.name} tool',
          child: ChoiceChip(
            avatar: Icon(_toolIcon(tool), size: 18),
            label: Text(tool.name),
            selected: _tool == tool,
            onSelected: (_) => _setTool(tool),
          ),
        ),
      if (_tool == _CanvasTool.shape) ...[
        Semantics(
          label: 'Shape kind',
          child: DropdownButton<ShapeKind>(
            key: const Key('shape-kind-control'),
            value: _shapeCreationKind,
            items:
                const [ShapeKind.line, ShapeKind.rectangle, ShapeKind.ellipse]
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.name),
                      ),
                    )
                    .toList(growable: false),
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _shapeCreationKind = value;
                  if (value == ShapeKind.line) {
                    _shapeStrokeEnabled = true;
                    _shapeFillEnabled = false;
                  } else if (!_shapeStrokeEnabled && !_shapeFillEnabled) {
                    _shapeStrokeEnabled = true;
                  }
                });
              }
            },
          ),
        ),
        Semantics(
          label: lineShapeSelected
              ? 'Stroke required for line'
              : 'Shape stroke',
          enabled: !lineShapeSelected,
          child: Tooltip(
            message: lineShapeSelected
                ? 'Lines require a visible stroke'
                : 'Toggle shape stroke',
            child: FilterChip(
              key: const Key('shape-stroke-control'),
              label: const Text('Stroke'),
              selected: _shapeStrokeEnabled,
              onSelected: lineShapeSelected
                  ? null
                  : (value) => setState(() {
                      _shapeStrokeEnabled = value;
                      if (!value && !_shapeFillEnabled) {
                        _shapeFillEnabled = true;
                      }
                    }),
            ),
          ),
        ),
        Semantics(
          label: lineShapeSelected ? 'Fill unavailable for line' : 'Shape fill',
          enabled: !lineShapeSelected,
          child: Tooltip(
            message: lineShapeSelected
                ? 'Fill is unavailable for lines'
                : 'Toggle shape fill',
            child: FilterChip(
              key: const Key('shape-fill-control'),
              label: const Text('Fill'),
              selected: _shapeFillEnabled,
              onSelected: lineShapeSelected
                  ? null
                  : (value) => setState(() {
                      _shapeFillEnabled = value;
                      if (!value && !_shapeStrokeEnabled) {
                        _shapeStrokeEnabled = true;
                      }
                    }),
            ),
          ),
        ),
        Semantics(
          label: 'Shape color',
          child: DropdownButton<int>(
            key: const Key('shape-color-control'),
            value: _shapeArgb,
            items: const [
              DropdownMenuItem(value: 0xff17324d, child: Text('Navy')),
              DropdownMenuItem(value: 0xff111111, child: Text('Black')),
              DropdownMenuItem(value: 0xffb42318, child: Text('Red')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _shapeArgb = value);
            },
          ),
        ),
      ],
      if (selectedText != null)
        Semantics(
          button: true,
          label: 'Edit selected text object',
          child: TextButton.icon(
            key: const Key('edit-selected-text'),
            onPressed: () {
              final payload = TextPayload.decode(
                selectedText.payload,
                limits: widget.runtime.textLimits,
              ).fold<TextPayload?>(onOk: (value) => value, onErr: (_) => null);
              if (payload != null) {
                _openTextEditor(
                  _textBoxBounds(payload),
                  existing: selectedText,
                );
              }
            },
            icon: const Icon(Icons.edit),
            label: const Text('Edit text'),
          ),
        ),
      if (_tool == _CanvasTool.text || _inlineText != null) ...[
        Semantics(
          label: 'Text font size',
          child: DropdownButton<double>(
            key: const Key('text-font-size-control'),
            value: _textFontSize,
            items:
                ({12.0, 18.0, 24.0, 36.0, 48.0, 72.0, _textFontSize}.toList()
                      ..sort())
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text('${value.round()} pt'),
                      ),
                    )
                    .toList(growable: false),
            onChanged: (value) {
              if (value != null) {
                _updateTextOptions(() => _textFontSize = value);
              }
            },
          ),
        ),
        Semantics(
          button: true,
          selected: _textBold,
          label: 'Bold text',
          child: FilterChip(
            key: const Key('text-bold-control'),
            avatar: const Icon(Icons.format_bold, size: 18),
            label: const Text('Bold'),
            selected: _textBold,
            onSelected: (value) => _updateTextOptions(() => _textBold = value),
          ),
        ),
        Semantics(
          button: true,
          selected: _textItalic,
          label: 'Italic text',
          child: FilterChip(
            key: const Key('text-italic-control'),
            avatar: const Icon(Icons.format_italic, size: 18),
            label: const Text('Italic'),
            selected: _textItalic,
            onSelected: (value) =>
                _updateTextOptions(() => _textItalic = value),
          ),
        ),
        Semantics(
          label: 'Text alignment',
          child: DropdownButton<TextAlignment>(
            key: const Key('text-alignment-control'),
            value: _textAlignment,
            items: TextAlignment.values
                .map(
                  (value) =>
                      DropdownMenuItem(value: value, child: Text(value.name)),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value != null) {
                _updateTextOptions(() => _textAlignment = value);
              }
            },
          ),
        ),
        Semantics(
          label: 'Text color',
          child: DropdownButton<int>(
            key: const Key('text-color-control'),
            value: _textArgb,
            items: const [
              DropdownMenuItem(value: 0xff17324d, child: Text('Navy')),
              DropdownMenuItem(value: 0xff111111, child: Text('Black')),
              DropdownMenuItem(value: 0xffb42318, child: Text('Red')),
            ],
            onChanged: (value) {
              if (value != null) _updateTextOptions(() => _textArgb = value);
            },
          ),
        ),
      ],
      if (_tool == _CanvasTool.selection &&
          _selection.state.targets.isNotEmpty) ...[
        for (final action in <(String, IconData, double, double)>[
          ('Left', Icons.arrow_left, -10, 0),
          ('Right', Icons.arrow_right, 10, 0),
          ('Up', Icons.arrow_upward, 0, -10),
          ('Down', Icons.arrow_downward, 0, 10),
        ])
          Tooltip(
            message: selectionCapabilities.movable
                ? 'Move selection ${action.$1.toLowerCase()} by 10 points'
                : 'Move is unavailable for this selection',
            child: TextButton.icon(
              onPressed: !selectionCapabilities.movable
                  ? null
                  : () {
                      final offset = Vector2.create(x: action.$3, y: action.$4);
                      if (offset is Ok<Vector2, StructuredFailure>) {
                        _keyboardTransform(
                          TranslationTransformOperation2D(offset.value),
                        );
                      }
                    },
              icon: Icon(action.$2),
              label: Text(action.$1),
            ),
          ),
        Tooltip(
          message: selectionCapabilities.resizable
              ? 'Grow selection proportionally by 10 percent'
              : 'Resize is unavailable for this selection',
          child: TextButton.icon(
            onPressed: !selectionCapabilities.resizable
                ? null
                : () {
                    final operation = _keyboardScale(1.1);
                    if (operation != null) _keyboardTransform(operation);
                  },
            icon: const Icon(Icons.open_in_full),
            label: const Text('Grow'),
          ),
        ),
        Tooltip(
          message: selectionCapabilities.rotatable
              ? 'Rotate selection clockwise by 15 degrees'
              : 'Rotation is unavailable for this selection',
          child: TextButton.icon(
            onPressed: !selectionCapabilities.rotatable
                ? null
                : () {
                    final operation = _keyboardRotation(math.pi / 12);
                    if (operation != null) _keyboardTransform(operation);
                  },
            icon: const Icon(Icons.rotate_right),
            label: const Text('Rotate'),
          ),
        ),
      ],
      Tooltip(
        message: 'Undo',
        child: TextButton.icon(
          onPressed: _coordinator.snapshot.canUndo ? _undo : null,
          icon: const Icon(Icons.undo),
          label: const Text('Undo'),
        ),
      ),
      Tooltip(
        message: 'Redo',
        child: TextButton.icon(
          onPressed: _coordinator.snapshot.canRedo ? _redo : null,
          icon: const Icon(Icons.redo),
          label: const Text('Redo'),
        ),
      ),
      TextButton.icon(
        onPressed: _save,
        icon: const Icon(Icons.save),
        label: const Text('Save in memory'),
      ),
      TextButton.icon(
        onPressed: _savedBytes == null ? null : _reopen,
        icon: const Icon(Icons.folder_open),
        label: const Text('Reopen saved'),
      ),
      Tooltip(
        message: 'Zoom out',
        child: TextButton.icon(
          onPressed: gestureIdle ? () => _zoom(1 / 1.2) : null,
          icon: const Icon(Icons.zoom_out),
          label: const Text('Zoom Out'),
        ),
      ),
      Tooltip(
        message: 'Zoom in',
        child: TextButton.icon(
          onPressed: gestureIdle ? () => _zoom(1.2) : null,
          icon: const Icon(Icons.zoom_in),
          label: const Text('Zoom In'),
        ),
      ),
      Semantics(
        button: true,
        label: 'Reset zoom to 100 percent',
        child: TextButton(
          key: const Key('zoom-reset'),
          onPressed: gestureIdle ? () => _zoomTo(1) : null,
          child: const Text('100%'),
        ),
      ),
      Tooltip(
        message: 'Fit the complete page in the canvas',
        child: TextButton.icon(
          key: const Key('zoom-fit-page'),
          onPressed: gestureIdle ? _fitPage : null,
          icon: const Icon(Icons.fit_screen),
          label: const Text('Fit Page'),
        ),
      ),
      Tooltip(
        message: 'Fit page width to the canvas',
        child: TextButton.icon(
          key: const Key('zoom-fit-width'),
          onPressed: gestureIdle ? _fitWidth : null,
          icon: const Icon(Icons.fit_screen_outlined),
          label: const Text('Fit Width'),
        ),
      ),
      SizedBox(
        width: 96,
        child: TextField(
          key: const Key('zoom-input'),
          controller: _zoomController,
          focusNode: _zoomFocus,
          enabled: gestureIdle,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          onSubmitted: _applyZoomInput,
          decoration: const InputDecoration(
            labelText: 'Zoom %',
            suffixText: '%',
            isDense: true,
          ),
        ),
      ),
      SizedBox(
        width: 190,
        child: Semantics(
          label: 'Canvas zoom percentage',
          value: '${(_viewport.zoom * 100).round()}%',
          slider: true,
          child: Slider(
            key: const Key('zoom-slider'),
            min: _viewport.minimumZoom,
            max: _viewport.maximumZoom,
            value: _viewport.zoom,
            onChanged: gestureIdle ? _zoomTo : null,
          ),
        ),
      ),
      Text(
        '${(_viewport.zoom * 100).round()}%',
        key: const Key('zoom-percentage'),
      ),
      if (kDebugMode && _diagnostics.enabled)
        TextButton.icon(
          key: const Key('phase6-diagnostics-copy'),
          onPressed: _copyDiagnostics,
          icon: const Icon(Icons.bug_report),
          label: const Text('Diagnostics'),
        ),
    ];
    final contextualCount =
        (_tool == _CanvasTool.shape ? 4 : 0) +
        (selectedText != null ? 1 : 0) +
        (_tool == _CanvasTool.text || _inlineText != null ? 5 : 0) +
        (_tool == _CanvasTool.selection && _selection.state.targets.isNotEmpty
            ? 6
            : 0);
    final primaryTail = controls
        .skip(_CanvasTool.values.length + contextualCount)
        .toList(growable: false);
    final primaryToolControls = controls
        .take(_CanvasTool.values.length)
        .toList(growable: false);
    final primaryDocumentControls = primaryTail.take(4).toList(growable: false);
    final primaryNavigationControls = primaryTail
        .skip(4)
        .toList(growable: false);
    final contextualControls = controls
        .skip(_CanvasTool.values.length)
        .take(contextualCount)
        .toList(growable: false);
    final scaffold = Scaffold(
      appBar: AppBar(title: const Text('AL NOTE')),
      body: Column(
        children: [
          Material(
            key: const Key('canvas-toolbar'),
            elevation: 2,
            child: SizedBox(
              height: 150,
              width: double.infinity,
              child: Column(
                children: [
                  SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: primaryToolControls),
                    ),
                  ),
                  SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: primaryDocumentControls),
                    ),
                  ),
                  SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: primaryNavigationControls),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Material(
            key: const Key('canvas-tool-options'),
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: SizedBox(
                width: double.infinity,
                child: Semantics(
                  container: true,
                  label: '${_tool.name} tool options',
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: contextualControls.isEmpty
                        ? [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text('No ${_tool.name} options'),
                            ),
                          ]
                        : contextualControls,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                _synchronizeCanvasExtent(size);
                final transformEvidence = _currentSelectionTransformEvidence;
                final previews = transformEvidence == null
                    ? _previewPrimitives()
                    : _nonTransformPreviewPrimitives();
                final committed =
                    transformEvidence?.committed ??
                    _committedSceneForCurrentInputs();
                final committedExclusions =
                    transformEvidence?.targetIds ??
                    <ObjectId>{
                      ..._eraserObjectPreviews.keys,
                      if (_inlineText?.existing != null)
                        _inlineText!.existing!.id,
                    };
                final committedDisplay =
                    transformEvidence?.committedDisplay ??
                    (committed == null
                        ? null
                        : _committedDisplayFor(committed, committedExclusions));
                final committedPaintChunks = committed == null
                    ? null
                    : _committedPaintChunksFor(committed, committedExclusions);
                _scheduleImageRefresh(committedDisplay);
                final selectionFrame = _inlineText != null
                    ? null
                    : transformEvidence?.selectionFrame ??
                          _createSelectionFrame();
                _selectionFrame = selectionFrame;
                final selections = _selectionPrimitives(selectionFrame);
                final overlays =
                    transformEvidence?.overlays ??
                    (committed == null
                        ? null
                        : _sceneBuilder
                              .composeOverlays(
                                committed: committed,
                                previews: previews,
                                selections: selections,
                              )
                              .fold<RenderSnapshot?>(
                                onOk: (value) => value,
                                onErr: (_) => null,
                              ));
                return ClipRect(
                  child: MouseRegion(
                    key: const Key('phase6-canvas-mouse-region'),
                    cursor: _canvasMouseCursor,
                    onHover: _handleCanvasHover,
                    onExit: (_) {
                      if (_hoverTextResizeHandle != null) {
                        setState(() => _hoverTextResizeHandle = null);
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _scaleStart,
                      onScaleUpdate: _scaleUpdate,
                      onScaleEnd: _scaleEnd,
                      child: Semantics(
                        label: 'Handwriting canvas',
                        container: true,
                        child: Listener(
                          key: const Key('phase6-canvas-listener'),
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: _handlePointerDown,
                          onPointerMove: _handlePointerMove,
                          onPointerUp: _handlePointerUp,
                          onPointerCancel: _handlePointerCancel,
                          onPointerSignal: _pointerSignal,
                          onPointerPanZoomStart: (event) {
                            final focalPoint = _validatedViewPoint(
                              event.localPosition.dx,
                              event.localPosition.dy,
                            );
                            if (focalPoint == null) return;
                            _router.cancel();
                            _panZoomScale = 1;
                            _panZoomFocalPoint = focalPoint;
                          },
                          onPointerPanZoomUpdate: (event) {
                            final previous = _panZoomFocalPoint;
                            final current = _validatedViewPoint(
                              event.localPosition.dx,
                              event.localPosition.dy,
                            );
                            final panDelta = Vector2.create(
                              x: event.panDelta.dx,
                              y: event.panDelta.dy,
                            );
                            if (current == null ||
                                panDelta is! Ok<Vector2, StructuredFailure> ||
                                !event.scale.isFinite ||
                                event.scale <= 0 ||
                                !_panZoomScale.isFinite ||
                                _panZoomScale <= 0) {
                              _cancelNavigation(status: 'Pan cancelled');
                              return;
                            }
                            final relativeScale = event.scale / _panZoomScale;
                            if (!relativeScale.isFinite || relativeScale <= 0) {
                              _cancelNavigation(status: 'Pan cancelled');
                              return;
                            }
                            if (previous != null) {
                              _panByViewDelta(
                                panDelta.value.x,
                                panDelta.value.y,
                              );
                              if (relativeScale != 1) {
                                _zoom(relativeScale, pivot: current);
                              }
                            }
                            _panZoomScale = event.scale;
                            _panZoomFocalPoint = current;
                          },
                          onPointerPanZoomEnd: (_) =>
                              _cancelNavigation(status: 'Pan complete'),
                          child: RepaintBoundary(
                            key: const Key('phase6-canvas-paint'),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                RepaintBoundary(
                                  key: const Key('phase6-document-paint'),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      RepaintBoundary(
                                        child: CustomPaint(
                                          key: const Key(
                                            'phase6-committed-paint',
                                          ),
                                          painter: _CanvasPainter(
                                            snapshot: committedDisplay,
                                            decodedImages: Map.unmodifiable(
                                              _decodedImages,
                                            ),
                                            paintBackground: true,
                                            paintPrimitives:
                                                committedPaintChunks == null,
                                            buildSemantics:
                                                committedPaintChunks == null,
                                            savedBytes: _savedBytes,
                                            savedRoot: _savedRoot,
                                            currentRoot:
                                                _coordinator.snapshot.root,
                                            reopenedMaterializedRoot:
                                                _reopenedMaterializedRoot,
                                            previewPrimitiveCount: 0,
                                            selectionPrimitiveCount: 0,
                                            selectionFrame: null,
                                            eraserPathLength: 0,
                                            wholeSegmentCount: 0,
                                            wholeGeometryChecks: 0,
                                            onPainted:
                                                committedPaintChunks == null
                                                ? _recordFlattenedCommittedPaint
                                                : null,
                                          ),
                                        ),
                                      ),
                                      if (committedPaintChunks != null)
                                        for (final chunk
                                            in committedPaintChunks)
                                          RepaintBoundary(
                                            key: ValueKey(
                                              'committed-chunk-${chunk.id}',
                                            ),
                                            child: CustomPaint(
                                              painter: _CommittedChunkPainter(
                                                chunk: chunk,
                                                decodedImages: Map.unmodifiable(
                                                  _decodedImages,
                                                ),
                                                pageClip: committed!.pageClip,
                                                excludedObjectId:
                                                    _penPreviewAwaitingCommittedPaint &&
                                                        chunk.objects.any(
                                                          (object) =>
                                                              object.objectId ==
                                                              _pendingPenAddedObjectId,
                                                        )
                                                    ? _pendingPenAddedObjectId
                                                    : null,
                                                onPainted: (paintedAddition) {
                                                  if (paintedAddition) {
                                                    _recordCommittedChunkPaint(
                                                      chunk,
                                                    );
                                                  } else if (_pendingPenAddedObjectId !=
                                                          null &&
                                                      chunk.objects.any(
                                                        (object) =>
                                                            object.objectId ==
                                                            _pendingPenAddedObjectId,
                                                      )) {
                                                    _preparePendingPenCommittedPaint();
                                                  }
                                                },
                                              ),
                                            ),
                                          ),
                                      if (_pen != null ||
                                          _penPreviewAwaitingCommittedPaint) ...[
                                        ValueListenableBuilder<
                                          List<_PenFrozenLayer>
                                        >(
                                          valueListenable:
                                              _penFrozenPreviewLayers,
                                          builder: (context, layers, child) => Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              for (final layer in layers)
                                                RepaintBoundary(
                                                  key: ValueKey(
                                                    'pen-frozen-${layer.id}',
                                                  ),
                                                  child: CustomPaint(
                                                    painter:
                                                        _FrozenPenPicturePainter(
                                                          pageClip: committed
                                                              ?.pageClip,
                                                          picture:
                                                              layer.picture,
                                                          onPainted: () {
                                                            _penFrozenPictureReplays +=
                                                                1;
                                                          },
                                                        ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        RepaintBoundary(
                                          child: CustomPaint(
                                            key: const Key(
                                              'phase6-pen-preview',
                                            ),
                                            painter: _PenPreviewPainter(
                                              pageClip: committed?.pageClip,
                                              controller: _penPreviewOverlay,
                                              onPainted: (primitiveCount) {
                                                _penPreviewPaintInvocations +=
                                                    1;
                                                _penMaximumActivePaintPrimitives =
                                                    math.max(
                                                      _penMaximumActivePaintPrimitives,
                                                      primitiveCount,
                                                    );
                                              },
                                            ),
                                          ),
                                        ),
                                      ],
                                      if (transformEvidence != null &&
                                          _selectionTransformPreparation
                                                  ?.selectedPicture !=
                                              null)
                                        RepaintBoundary(
                                          key: const Key(
                                            'phase6-selection-picture',
                                          ),
                                          child: CustomPaint(
                                            painter: _SelectionPicturePainter(
                                              pageClip: committed?.pageClip,
                                              picture:
                                                  _selectionTransformPreparation!
                                                      .selectedPicture!,
                                              viewTransformCoefficients:
                                                  transformEvidence
                                                      .viewTransformCoefficients,
                                              onPainted: () {
                                                _textPreviewRepaints += 1;
                                              },
                                            ),
                                          ),
                                        ),
                                      RepaintBoundary(
                                        child: CustomPaint(
                                          key: const Key(
                                            'phase6-overlay-paint',
                                          ),
                                          painter: _CanvasPainter(
                                            snapshot: overlays,
                                            decodedImages: Map.unmodifiable(
                                              _decodedImages,
                                            ),
                                            paintBackground: false,
                                            paintPrimitives: true,
                                            buildSemantics: false,
                                            savedBytes: _savedBytes,
                                            savedRoot: _savedRoot,
                                            currentRoot:
                                                _coordinator.snapshot.root,
                                            reopenedMaterializedRoot:
                                                _reopenedMaterializedRoot,
                                            previewPrimitiveCount:
                                                transformEvidence
                                                    ?.previewPrimitiveCount ??
                                                previews.length,
                                            selectionPrimitiveCount:
                                                selections.length,
                                            selectionFrame: selectionFrame,
                                            eraserPathLength:
                                                _wholeEraserPath.length,
                                            wholeSegmentCount:
                                                _wholeEraserPlan
                                                    ?.processedSegmentCount ??
                                                0,
                                            wholeGeometryChecks:
                                                _wholeEraserPlan
                                                    ?.geometryCheckCount ??
                                                0,
                                          ),
                                        ),
                                      ),
                                      ValueListenableBuilder<ViewPoint?>(
                                        valueListenable: _eraserCursor.position,
                                        builder: (context, position, child) =>
                                            RepaintBoundary(
                                              child: CustomPaint(
                                                key: const Key(
                                                  'phase6-eraser-cursor',
                                                ),
                                                painter: _EraserCursorPainter(
                                                  position: position,
                                                  onPainted:
                                                      _diagnostics.enabled
                                                      ? _eraserCursor.didPaint
                                                      : null,
                                                ),
                                              ),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_tool == _CanvasTool.pen &&
                                    committed?.pageClip != null)
                                  Positioned(
                                    left: committed!.pageClip.left,
                                    top: committed.pageClip.top,
                                    width: committed.pageClip.width,
                                    height: committed.pageClip.height,
                                    child: MouseRegion(
                                      key: const Key('phase6-pen-paper-region'),
                                      cursor: SystemMouseCursors.none,
                                      onEnter: (event) => _updatePenCursorAt(
                                        Offset(
                                          event.localPosition.dx +
                                              committed.pageClip.left,
                                          event.localPosition.dy +
                                              committed.pageClip.top,
                                        ),
                                      ),
                                      onHover: (event) => _updatePenCursorAt(
                                        Offset(
                                          event.localPosition.dx +
                                              committed.pageClip.left,
                                          event.localPosition.dy +
                                              committed.pageClip.top,
                                        ),
                                      ),
                                      onExit: (_) => _penCursor.clear(),
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                if (_tool == _CanvasTool.pen)
                                  RepaintBoundary(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        key: const Key('phase6-pen-cursor'),
                                        painter: _PenCursorPainter(
                                          controller: _penCursor,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (_inlineText != null)
                                  _buildInlineTextEditor(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Semantics(
            liveRegion: true,
            label: 'Canvas status',
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_status, key: const Key('canvas-status')),
            ),
          ),
        ],
      ),
    );
    return Shortcuts(
      shortcuts: _editableFieldFocused
          ? const <ShortcutActivator, Intent>{}
          : const {
              const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                  const _UndoIntent(),
              const SingleActivator(LogicalKeyboardKey.keyY, control: true):
                  const _RedoIntent(),
              const SingleActivator(LogicalKeyboardKey.escape):
                  const _CancelIntent(),
              const SingleActivator(LogicalKeyboardKey.keyP):
                  const _PenIntent(),
              const SingleActivator(LogicalKeyboardKey.keyE):
                  const _EraserIntent(),
              const SingleActivator(LogicalKeyboardKey.keyV):
                  const _SelectionIntent(),
              const SingleActivator(LogicalKeyboardKey.keyR):
                  const _ShapeIntent(),
              const SingleActivator(LogicalKeyboardKey.keyT):
                  const _TextIntent(),
              const SingleActivator(LogicalKeyboardKey.enter):
                  const _EditTextIntent(),
              const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
                  const _PanCanvasIntent(40, 0),
              const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
                  const _PanCanvasIntent(-40, 0),
              const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
                  const _PanCanvasIntent(0, 40),
              const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
                  const _PanCanvasIntent(0, -40),
            },
      child: Actions(
        actions: {
          _UndoIntent: CallbackAction<_UndoIntent>(
            onInvoke: (_) {
              _undo();
              return null;
            },
          ),
          _RedoIntent: CallbackAction<_RedoIntent>(
            onInvoke: (_) {
              _redo();
              return null;
            },
          ),
          _CancelIntent: CallbackAction<_CancelIntent>(
            onInvoke: (_) {
              if (_inlineText != null) {
                _cancelInlineTextEditor();
              } else {
                _cancelGesture('Cancelled');
              }
              return null;
            },
          ),
          _PenIntent: CallbackAction<_PenIntent>(
            onInvoke: (_) {
              _setTool(_CanvasTool.pen);
              return null;
            },
          ),
          _EraserIntent: CallbackAction<_EraserIntent>(
            onInvoke: (_) {
              _setTool(_CanvasTool.wholeEraser);
              return null;
            },
          ),
          _SelectionIntent: CallbackAction<_SelectionIntent>(
            onInvoke: (_) {
              _setTool(_CanvasTool.selection);
              return null;
            },
          ),
          _ShapeIntent: CallbackAction<_ShapeIntent>(
            onInvoke: (_) {
              if (_inlineText == null) _setTool(_CanvasTool.shape);
              return null;
            },
          ),
          _TextIntent: CallbackAction<_TextIntent>(
            onInvoke: (_) {
              if (_inlineText == null) _setTool(_CanvasTool.text);
              return null;
            },
          ),
          _EditTextIntent: CallbackAction<_EditTextIntent>(
            onInvoke: (_) {
              final selected = _selectedTextObject;
              if (_inlineText == null && selected != null) {
                final payload =
                    TextPayload.decode(
                      selected.payload,
                      limits: widget.runtime.textLimits,
                    ).fold<TextPayload?>(
                      onOk: (value) => value,
                      onErr: (_) => null,
                    );
                if (payload != null) {
                  _openTextEditor(_textBoxBounds(payload), existing: selected);
                }
              }
              return null;
            },
          ),
          _PanCanvasIntent: CallbackAction<_PanCanvasIntent>(
            onInvoke: (intent) {
              if (_inlineText == null && _router.ownership.owner == null) {
                _panByViewDelta(intent.dx, intent.dy);
              }
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _canvasFocus,
          autofocus: true,
          onKeyEvent: _handleCanvasKeyEvent,
          onFocusChange: (focused) {
            if (!focused && _router.ownership.owner != null) {
              _cancelGesture('Gesture cancelled');
            }
            if (!focused) {
              _clearCanvasModifierState(recomputeRotation: false);
              _cancelNavigation(status: 'Pan cancelled');
            }
          },
          child: scaffold,
        ),
      ),
    );
  }

  List<ScenePrimitive> _previewPrimitives() {
    final eraser = _eraserPreviewPrimitive;
    final eraserPreview = <ScenePrimitive>[
      ..._eraserObjectPreviews.values.expand((value) => value),
      if (eraser != null) eraser,
    ];
    final creation = _creationPreview();
    final transform = _transformPreviewPrimitives();
    return List.unmodifiable([...eraserPreview, ...creation, ...transform]);
  }

  List<ScenePrimitive> _transformPreviewPrimitives() {
    return const [];
  }

  bool _inlineEditorContainsViewPoint(Offset point) {
    final session = _inlineText;
    if (session == null || !point.dx.isFinite || !point.dy.isFinite) {
      return false;
    }
    final corners = _viewCorners(
      session.pageBounds,
      session.existing == null ? null : session.currentTransform,
    );
    if (corners == null) return false;
    final polygon = <Offset>[
      corners[_TextResizeHandle.topLeft]!,
      corners[_TextResizeHandle.topRight]!,
      corners[_TextResizeHandle.bottomRight]!,
      corners[_TextResizeHandle.bottomLeft]!,
    ];
    var sign = 0;
    for (var index = 0; index < polygon.length; index += 1) {
      final first = polygon[index];
      final second = polygon[(index + 1) % polygon.length];
      final cross =
          (second.dx - first.dx) * (point.dy - first.dy) -
          (second.dy - first.dy) * (point.dx - first.dx);
      if (cross.abs() <= 1e-7) continue;
      final current = cross > 0 ? 1 : -1;
      if (sign != 0 && sign != current) return false;
      sign = current;
    }
    return true;
  }

  _SelectionTransformPreparation? _prepareSelectionTransform() {
    final state = _selection.state;
    if (state.targets.isEmpty ||
        state.targets.any((target) => !target.isWholeObject)) {
      return null;
    }
    var baseFrame = _selectionFrame;
    if (baseFrame == null || !_selectionFrameIsCurrent(baseFrame)) {
      baseFrame = _createSelectionFrame();
    }
    if (baseFrame == null) return null;
    final snapshot = _coordinator.snapshot;
    final committed = _committedSceneForCurrentInputs();
    if (committed == null ||
        committed.documentRevision != snapshot.revisions.document ||
        committed.viewportRevision != _viewport.revision) {
      return null;
    }
    final targetIds = state.targets.map((target) => target.objectId).toSet();
    final scenes = <ObjectId, CommittedObjectScene>{
      for (final scene in committed.objects) scene.objectId: scene,
    };
    final primitives = <ScenePrimitive>[];
    final objectRevisions = <ObjectId, Revision>{};
    final membershipRevisions = <LayerId, Revision>{};
    var rotationSupported = true;
    var resizeSupported = true;
    Rect2? singleLocalBounds;
    ObjectId? singleObjectId;
    var orientationRadians = 0.0;
    for (final target in state.targets) {
      final object = _page.layers
          .expand((layer) => layer.objects)
          .where((value) => value.id == target.objectId)
          .firstOrNull;
      final layerId = state.layerMembership[target.objectId];
      final scene = scenes[target.objectId];
      final objectRevision = snapshot.revisions.objects[target.objectId];
      final membershipRevision = layerId == null
          ? null
          : snapshot.revisions.layerMembership[layerId];
      final resolution = object == null ? null : _registry.resolve(object);
      _selectionTransformRegistryResolutions += 1;
      if (object == null ||
          layerId == null ||
          scene == null ||
          objectRevision == null ||
          membershipRevision == null ||
          resolution is! SupportedObjectResolution) {
        return null;
      }
      rotationSupported &= resolution.definition.capabilities.rotatable;
      resizeSupported &= resolution.definition.capabilities.resizable;
      if (object.typeKey == handwritingObjectTypeKey) {
        _selectionTransformHandwritingPreparations += 1;
      }
      if (object.typeKey == textObjectTypeKey) {
        _textLayoutRequests += 1;
      }
      objectRevisions[target.objectId] = objectRevision;
      membershipRevisions[layerId] = membershipRevision;
      Iterable<ScenePrimitive> preparedPrimitives = scene.primitives;
      final renderingOverride = widget.renderingRegistryOverride;
      if (renderingOverride != null) {
        final layer = _page.layers
            .where((value) => value.id == layerId)
            .firstOrNull;
        final definition = renderingOverride.definitions[object.typeKey];
        if (layer == null || definition == null) return null;
        Result<List<ScenePrimitive>, StructuredFailure>? rendered;
        try {
          rendered = definition.render(
            object: object,
            viewport: _viewport,
            layerOpacity: layer.opacity,
            plane: RenderPlane.toolPreview,
            limits: widget.runtime.renderingLimits,
          );
        } on Object {
          rendered = null;
        }
        if (rendered is! Ok<List<ScenePrimitive>, StructuredFailure> ||
            rendered.value.any(
              (primitive) => primitive.plane != RenderPlane.toolPreview,
            )) {
          return null;
        }
        preparedPrimitives = rendered.value;
      }
      for (final primitive in preparedPrimitives) {
        if (primitives.length >=
            widget.runtime.renderingLimits.maximumPreviewOverlays) {
          return null;
        }
        primitives.add(primitive);
      }
      if (targetIds.length == 1) {
        singleObjectId = object.id;
        singleLocalBounds = resolution.definition
            .intrinsicGeometry(object.payload, object.typeSchemaVersion)
            .fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
        if (singleLocalBounds == null) return null;
        final first = object.transform.applyToPoint(singleLocalBounds.topLeft);
        final second = object.transform.applyToPoint(
          _point(singleLocalBounds.right, singleLocalBounds.top),
        );
        if (first is! Ok<Point2, StructuredFailure> ||
            second is! Ok<Point2, StructuredFailure>) {
          return null;
        }
        orientationRadians = math.atan2(
          second.value.y - first.value.y,
          second.value.x - first.value.x,
        );
      }
    }
    final identity = AffineTransform2D.fromOperation(
      const IdentityTransformOperation2D(),
    );
    if (identity is! Ok<AffineTransform2D, StructuredFailure>) return null;
    final previewPrimitives = <ScenePrimitive>[];
    try {
      for (final primitive in primitives) {
        final prepared = _transformPreparedPrimitive(primitive, identity.value);
        if (prepared == null) return null;
        previewPrimitives.add(prepared);
      }
    } on Object {
      return null;
    }
    final selections = _selectionFramePrimitives(baseFrame);
    if (selections is! Ok<List<ScenePrimitive>, StructuredFailure>) return null;
    final exclusions = Set<ObjectId>.unmodifiable(targetIds);
    _selectionTransformCompositions += 2;
    final complete = _sceneBuilder.compose(
      committed: committed,
      previews: previewPrimitives,
      selections: selections.value,
      excludedObjectIds: exclusions,
    );
    final committedDisplay = _sceneBuilder.compose(
      committed: committed,
      excludedObjectIds: exclusions,
    );
    if (complete is! Ok<RenderSnapshot, StructuredFailure> ||
        committedDisplay is! Ok<RenderSnapshot, StructuredFailure>) {
      return null;
    }
    ui.Picture? picture;
    try {
      picture = _recordSelectionPicture(previewPrimitives);
    } on Object {
      picture = null;
    }
    if (picture == null) return null;
    _pictureCreated();
    _selectionTransformPictureCreations += 1;
    final selectedViewBounds = _aggregatePrimitiveBounds(previewPrimitives);
    if (selectedViewBounds == null) {
      _disposePicture(picture);
      return null;
    }
    _selectionTransformRendererPreparations = targetIds.length;
    _selectionTransformMaximumRetainedEvidence = 1;
    return _SelectionTransformPreparation(
      documentRevision: snapshot.revisions.document,
      resourceRevision: snapshot.revisions.resourceCatalog,
      viewportRevision: _viewport.revision,
      selectionRevision: state.revision,
      targetIds: targetIds,
      objectRevisions: objectRevisions,
      membershipRevisions: membershipRevisions,
      selectedPicture: picture,
      selectedViewBounds: selectedViewBounds,
      basePrimitiveCount: previewPrimitives.length,
      baseFrame: baseFrame,
      committed: committed,
      committedDisplay: committedDisplay.value,
      rotationSupported: rotationSupported,
      resizeSupported: resizeSupported,
      orientationRadians: orientationRadians,
      singleObjectId: singleObjectId,
      singleLocalBounds: singleLocalBounds,
    );
  }

  bool _selectionTransformPreparationIsCurrent(
    _SelectionTransformPreparation preparation,
  ) {
    final snapshot = _coordinator.snapshot;
    final state = _selection.state;
    return preparation.documentRevision == snapshot.revisions.document &&
        preparation.resourceRevision == snapshot.revisions.resourceCatalog &&
        preparation.viewportRevision == _viewport.revision &&
        preparation.selectionRevision == state.revision &&
        _sameObjectIds(
          preparation.targetIds,
          state.targets.map((target) => target.objectId).toSet(),
        ) &&
        preparation.objectRevisions.entries.every(
          (entry) => snapshot.revisions.objects[entry.key] == entry.value,
        ) &&
        preparation.membershipRevisions.entries.every(
          (entry) =>
              snapshot.revisions.layerMembership[entry.key] == entry.value,
        );
  }

  ui.Picture _recordSelectionPicture(List<ScenePrimitive> primitives) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final primitive in primitives) {
      _paintPrimitive(canvas, primitive, decodedImages: _decodedImages);
    }
    return recorder.endRecording();
  }

  Rect2? _aggregatePrimitiveBounds(List<ScenePrimitive> primitives) {
    if (primitives.isEmpty) return null;
    return Rect2.fromEdges(
      left: primitives.map((value) => value.bounds.left).reduce(math.min),
      top: primitives.map((value) => value.bounds.top).reduce(math.min),
      right: primitives.map((value) => value.bounds.right).reduce(math.max),
      bottom: primitives.map((value) => value.bounds.bottom).reduce(math.max),
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
  }

  List<double>? _pageTransformToViewCoefficients(
    AffineTransform2D pageTransform,
  ) {
    Point2? map(double x, double y) {
      final page = _viewport.viewToPage(_viewPoint(x, y));
      final transformed = page is Ok<Point2, StructuredFailure>
          ? pageTransform.applyToPoint(page.value)
          : null;
      final view = transformed is Ok<Point2, StructuredFailure>
          ? _viewport.pageToView(transformed.value)
          : null;
      return view is Ok<ViewPoint, StructuredFailure>
          ? _point(view.value.x, view.value.y)
          : null;
    }

    final origin = map(0, 0);
    final x = map(1, 0);
    final y = map(0, 1);
    if (origin == null || x == null || y == null) return null;
    final result = <double>[
      x.x - origin.x,
      y.x - origin.x,
      x.y - origin.y,
      y.y - origin.y,
      origin.x,
      origin.y,
    ];
    return result.every((value) => value.isFinite)
        ? List<double>.unmodifiable(result)
        : null;
  }

  Rect2? _transformViewBounds(Rect2 bounds, List<double> coefficients) {
    if (coefficients.length != 6) return null;
    Point2 map(Point2 point) => _point(
      coefficients[0] * point.x + coefficients[1] * point.y + coefficients[4],
      coefficients[2] * point.x + coefficients[3] * point.y + coefficients[5],
    );

    final points = <Point2>[
      map(bounds.topLeft),
      map(_point(bounds.right, bounds.top)),
      map(bounds.bottomRight),
      map(_point(bounds.left, bounds.bottom)),
    ];
    return Rect2.fromEdges(
      left: points.map((value) => value.x).reduce(math.min),
      top: points.map((value) => value.y).reduce(math.min),
      right: points.map((value) => value.x).reduce(math.max),
      bottom: points.map((value) => value.y).reduce(math.max),
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
  }

  void _replaceSelectionTransformPreparation(
    _SelectionTransformPreparation? next,
  ) {
    final previous = _selectionTransformPreparation;
    if (identical(previous, next)) return;
    _selectionTransformPreparation = next;
    final picture = previous?.takePicture();
    if (picture != null) _disposePicture(picture);
  }

  void _disposeSelectionTransformPreparation() {
    _replaceSelectionTransformPreparation(null);
  }

  void _invalidateSelectionTransformForExternalChange() {
    if (_selectionTransformPreparation == null &&
        _selectionTransformMode == null &&
        _selectionTransformEvidence == null) {
      return;
    }
    _selection.cancelTransform();
    _selectionTransformEvidence = null;
    _disposeSelectionTransformPreparation();
    _clearPendingSelectionTransformUpdate();
    _selectionTransformMode = null;
    _selectionTransformDown = null;
    _selectionTransformBounds = null;
    _selectionTransformPivot = null;
    _selectionTransformInitialViewWidth = null;
    _selectionTransformInitialViewHeight = null;
    _selectionResizeHandle = null;
    _selectionResizeClampedToInitial = false;
    _resetSelectionRotationTracking();
  }

  ScenePrimitive? _transformPreparedPrimitive(
    ScenePrimitive primitive,
    AffineTransform2D pageTransform,
  ) {
    Point2? mapPoint(Point2 viewPoint) {
      final view = ViewPoint.create(x: viewPoint.x, y: viewPoint.y);
      final page = view is Ok<ViewPoint, StructuredFailure>
          ? _viewport.viewToPage(view.value)
          : null;
      final transformed = page is Ok<Point2, StructuredFailure>
          ? pageTransform.applyToPoint(page.value)
          : null;
      final mapped = transformed is Ok<Point2, StructuredFailure>
          ? _viewport.pageToView(transformed.value)
          : null;
      return mapped is Ok<ViewPoint, StructuredFailure>
          ? _point(mapped.value.x, mapped.value.y)
          : null;
    }

    Rect2? mapBounds(Rect2 bounds) {
      final points = [
        bounds.topLeft,
        _point(bounds.right, bounds.top),
        bounds.bottomRight,
        _point(bounds.left, bounds.bottom),
      ].map(mapPoint).toList(growable: false);
      if (points.any((point) => point == null)) return null;
      final values = points.whereType<Point2>().toList(growable: false);
      return Rect2.fromEdges(
        left: values.map((point) => point.x).reduce(math.min),
        top: values.map((point) => point.y).reduce(math.min),
        right: values.map((point) => point.x).reduce(math.max),
        bottom: values.map((point) => point.y).reduce(math.max),
      ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
    }

    List<double>? mapCoefficients(List<double> source) {
      if (source.length != 6) return null;
      final origin = mapPoint(_point(source[4], source[5]));
      final x = mapPoint(_point(source[0] + source[4], source[2] + source[5]));
      final y = mapPoint(_point(source[1] + source[4], source[3] + source[5]));
      if (origin == null || x == null || y == null) return null;
      return List<double>.unmodifiable([
        x.x - origin.x,
        y.x - origin.x,
        x.y - origin.y,
        y.y - origin.y,
        origin.x,
        origin.y,
      ]);
    }

    final mappedBounds = mapBounds(primitive.bounds);
    if (mappedBounds == null) return null;
    final sharedViewTransform = mapCoefficients(const [1, 0, 0, 1, 0, 0]);
    if (sharedViewTransform == null) return null;
    switch (primitive) {
      case FilledPolygonPrimitive():
        final coefficients = primitive.localToViewCoefficients;
        return FilledPolygonPrimitive.create(
          plane: RenderPlane.toolPreview,
          opacity: primitive.opacity,
          color: primitive.color,
          fillRule: primitive.fillRule,
          points: primitive.points,
          maximumPoints:
              widget.runtime.renderingLimits.maximumPointsPerPrimitive,
          localToViewCoefficients: coefficients == null
              ? sharedViewTransform
              : mapCoefficients(coefficients),
          transformedBounds: mappedBounds,
        ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
      case FilledPolygonGroupPrimitive():
        final coefficients = primitive.localToViewCoefficients;
        final totalPoints = primitive.contours.fold<int>(
          0,
          (total, contour) => total + contour.length,
        );
        return FilledPolygonGroupPrimitive.create(
          plane: RenderPlane.toolPreview,
          opacity: primitive.opacity,
          color: primitive.color,
          contours: primitive.contours,
          maximumContours: primitive.contours.length,
          maximumPointsPerContour:
              widget.runtime.renderingLimits.maximumPointsPerPrimitive,
          maximumTotalPoints: totalPoints,
          localToViewCoefficients: coefficients == null
              ? sharedViewTransform
              : mapCoefficients(coefficients),
          transformedBounds: mappedBounds,
        ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
      case StrokedPathPrimitive():
        final coefficients = primitive.localToViewCoefficients;
        return StrokedPathPrimitive.create(
          plane: RenderPlane.toolPreview,
          opacity: primitive.opacity,
          color: primitive.color,
          strokeWidth: primitive.strokeWidth,
          cap: primitive.cap,
          join: primitive.join,
          miterLimit: primitive.miterLimit,
          closed: primitive.closed,
          dashArray: primitive.dashArray,
          dashOffset: primitive.dashOffset,
          points: primitive.points,
          maximumPoints:
              widget.runtime.renderingLimits.maximumPointsPerPrimitive,
          localToViewCoefficients: coefficients == null
              ? sharedViewTransform
              : mapCoefficients(coefficients),
          transformedBounds: mappedBounds,
        ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
      case ImageBoxPrimitive():
        final coefficients = mapCoefficients(primitive.localToViewCoefficients);
        if (coefficients == null) return null;
        return ImageBoxPrimitive.create(
          plane: RenderPlane.toolPreview,
          bounds: mappedBounds,
          opacity: primitive.opacity,
          payload: primitive.payload,
          localToViewCoefficients: coefficients,
        ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
      case TextBoxPrimitive():
        final coefficients = mapCoefficients(primitive.localToViewCoefficients);
        if (coefficients == null) return null;
        return TextBoxPrimitive.create(
          plane: RenderPlane.toolPreview,
          bounds: mappedBounds,
          opacity: primitive.opacity,
          payload: primitive.payload,
          layout: primitive.layout,
          localToViewCoefficients: coefficients,
        ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
      case PlaceholderPrimitive():
        return PlaceholderPrimitive.create(
          plane: RenderPlane.toolPreview,
          bounds: mappedBounds,
          opacity: primitive.opacity,
        ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
    }
  }

  Result<_SelectionTransformRenderEvidence, StructuredFailure>
  _validateSelectionTransformPreview(
    TransformOperation2D operation, {
    required bool identity,
  }) {
    final preparation = _selectionTransformPreparation;
    if (preparation == null ||
        !_selectionTransformPreparationIsCurrent(preparation)) {
      return Err(_canvasFailure('preview_missing'));
    }
    final affine = AffineTransform2D.fromOperation(operation);
    if (affine is! Ok<AffineTransform2D, StructuredFailure>) {
      return Err(_canvasFailure('preview_render_failed'));
    }
    final viewTransform = _pageTransformToViewCoefficients(affine.value);
    if (viewTransform == null) {
      return Err(_canvasFailure('preview_render_failed'));
    }
    final selectionFrame = identity
        ? preparation.baseFrame
        : preparation.baseFrame.transformedBy(affine.value, viewTransform);
    final selections = selectionFrame == null
        ? null
        : _selectionFramePrimitives(selectionFrame);
    if (selectionFrame == null ||
        selections is! Ok<List<ScenePrimitive>, StructuredFailure>) {
      return Err(_canvasFailure('preview_selection_failed'));
    }
    final committed = preparation.committed;
    if (committed.documentRevision !=
            _coordinator.snapshot.revisions.document ||
        committed.viewportRevision != _viewport.revision) {
      return Err(_canvasFailure('preview_committed_stale'));
    }
    final previewPrimitives = List<ScenePrimitive>.unmodifiable([
      ..._nonTransformPreviewPrimitives(),
    ]);
    final targetIds = preparation.targetIds;
    final transformedBounds = _transformViewBounds(
      preparation.selectedViewBounds,
      viewTransform,
    );
    final damageProbe = transformedBounds == null
        ? null
        : PlaceholderPrimitive.create(
            plane: RenderPlane.toolPreview,
            bounds: transformedBounds,
            opacity: 0,
          );
    if (damageProbe is! Ok<PlaceholderPrimitive, StructuredFailure>) {
      return Err(_canvasFailure('preview_composition_failed'));
    }
    _selectionTransformCompositions += 2;
    final validatedOverlay = _sceneBuilder.composeOverlays(
      committed: committed,
      previews: [...previewPrimitives, damageProbe.value],
      selections: selections.value,
    );
    final overlays = _sceneBuilder.composeOverlays(
      committed: committed,
      previews: previewPrimitives,
      selections: selections.value,
    );
    if (validatedOverlay is! Ok<RenderSnapshot, StructuredFailure> ||
        overlays is! Ok<RenderSnapshot, StructuredFailure>) {
      return Err(_canvasFailure('preview_composition_failed'));
    }
    return Ok(
      _SelectionTransformRenderEvidence(
        documentRevision: committed.documentRevision,
        viewportRevision: committed.viewportRevision,
        targetIds: targetIds,
        committed: committed,
        committedDisplay: preparation.committedDisplay,
        overlays: overlays.value,
        operation: operation,
        identity: identity,
        viewTransformCoefficients: viewTransform,
        previewPrimitiveCount:
            preparation.basePrimitiveCount + previewPrimitives.length,
        selectionFrame: selectionFrame,
      ),
    );
  }

  List<ScenePrimitive> _nonTransformPreviewPrimitives() {
    final eraser = _eraserPreviewPrimitive;
    return List<ScenePrimitive>.unmodifiable([
      ..._eraserObjectPreviews.values.expand((value) => value),
      if (eraser != null) eraser,
      ..._creationPreview(),
    ]);
  }

  Result<List<ScenePrimitive>, StructuredFailure> _selectionFramePrimitives(
    _SelectionFrameSnapshot frame,
  ) {
    final color = RenderColor.create(0xff2563eb);
    if (color is! Ok<RenderColor, StructuredFailure>) {
      return Err(_canvasFailure('preview_selection_failed'));
    }
    StrokedPathPrimitive? path(
      Iterable<Point2> points, {
      required bool closed,
      double strokeWidth = 1.5,
    }) => StrokedPathPrimitive.create(
      plane: RenderPlane.selection,
      opacity: 1,
      color: color.value,
      strokeWidth: strokeWidth,
      cap: RenderStrokeCap.round,
      join: RenderStrokeJoin.round,
      miterLimit: 4,
      closed: closed,
      dashArray: const [],
      dashOffset: 0,
      points: points,
      maximumPoints: _sceneBuilder.limits.maximumPointsPerPrimitive,
    ).fold<StrokedPathPrimitive?>(onOk: (value) => value, onErr: (_) => null);

    final outline = path(frame.viewCorners, closed: true);
    if (outline == null) return Err(_canvasFailure('preview_selection_failed'));
    final result = <ScenePrimitive>[outline];
    if (frame.rotationSupported) {
      final connector = path(
        [frame.rotationConnectorStart, frame.rotationConnectorEnd],
        closed: false,
        strokeWidth: 1,
      );
      final circlePoints = <Point2>[];
      const segments = 24;
      for (var index = 0; index < segments; index += 1) {
        final radians = 2 * math.pi * index / segments;
        circlePoints.add(
          _point(
            frame.rotationCenter.x + math.cos(radians) * frame.rotationRadius,
            frame.rotationCenter.y + math.sin(radians) * frame.rotationRadius,
          ),
        );
      }
      final circle = path(circlePoints, closed: true);
      if (connector == null || circle == null) {
        return Err(_canvasFailure('preview_selection_failed'));
      }
      result.addAll([connector, circle]);
    }
    return Ok(List.unmodifiable(result));
  }

  List<ScenePrimitive> _creationPreview() {
    if (_tool == _CanvasTool.text) {
      final bounds = _creationBounds(defaultWidth: 180, defaultHeight: 80);
      final outline = bounds == null ? null : _creationRectPrimitive(bounds);
      return outline == null ? const [] : [outline];
    }
    if (_tool != _CanvasTool.shape) return const [];
    final payload = _shapeCreationPayload();
    final identity = AffineTransform2D.fromOperation(
      const IdentityTransformOperation2D(),
    ).fold<AffineTransform2D?>(onOk: (value) => value, onErr: (_) => null);
    if (payload == null || identity == null) return const [];
    return ShapeRenderingDefinition(shapeLimits: widget.runtime.shapeLimits)
        .renderTransient(
          payload: payload,
          localToPage: identity,
          viewport: _viewport,
          layerOpacity: 1,
          plane: RenderPlane.toolPreview,
          limits: widget.runtime.renderingLimits,
        )
        .fold<List<ScenePrimitive>>(
          onOk: (value) => value,
          onErr: (_) => const [],
        );
  }

  bool _appendPenPreviewTail() {
    final session = _pen;
    if (session == null) return false;
    if (session.sampleCount == _penPreviewedSampleCount) return true;
    final preview = session.previewSince(_penPreviewedSampleCount);
    if (preview == null || preview.samples.isEmpty) return false;
    final identity = AffineTransform2D.fromOperation(
      const IdentityTransformOperation2D(),
    ).fold<AffineTransform2D?>(onOk: (value) => value, onErr: (_) => null);
    if (identity == null) {
      return false;
    }
    final geometry = _geometry
        .resolvePreview(
          samples: preview.samples,
          style: preview.style,
          localToPage: identity,
          maximumSamples: widget.runtime.maximumPenSamples,
        )
        .fold<TransformedStrokeGeometry?>(
          onOk: (value) => value,
          onErr: (_) => null,
        );
    _penGeometryResolutions += 1;
    final color = RenderColor.create(
      preview.style.argb,
    ).fold<RenderColor?>(onOk: (value) => value, onErr: (_) => null);
    if (geometry == null || color == null) {
      return false;
    }
    final result = <ScenePrimitive>[];
    final skipSharedStart =
        _penPreviewPrimitiveCount > 0 && preview.samples.length > 1;
    final elements = skipSharedStart
        ? geometry.elements.skip(1)
        : geometry.elements;
    for (final element in elements) {
      final points = <Point2>[];
      for (final pagePoint in element.vertices) {
        final view = _viewport
            .pageToView(pagePoint)
            .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
        if (view == null) return false;
        points.add(_point(view.x, view.y));
      }
      final primitive = FilledPolygonPrimitive.create(
        plane: RenderPlane.toolPreview,
        opacity: preview.style.opacity,
        color: color,
        points: points,
        maximumPoints: _sceneBuilder.limits.maximumPointsPerPrimitive,
      );
      if (primitive is! Ok<FilledPolygonPrimitive, StructuredFailure>) {
        return false;
      }
      result.add(primitive.value);
    }
    if (_penPreviewPrimitiveCount + result.length >
        widget.runtime.renderingLimits.maximumPreviewOverlays) {
      return false;
    }
    for (final primitive in result) {
      if (_penActivePreviewPrimitives.length ==
          _penPreviewChunkPrimitiveLimit) {
        if (!_freezeActivePenPreview()) return false;
      }
      _penActivePreviewPrimitives.add(primitive);
    }
    _penMaximumActivePaintPrimitives = math.max(
      _penMaximumActivePaintPrimitives,
      _penActivePreviewPrimitives.length,
    );
    _penPreviewPrimitiveCount += result.length;
    _penPreviewedSampleCount = session.sampleCount;
    _penPreviewOverlay.update(
      latestAcceptedSampleCenter: preview.samples.last.position,
      previewedSampleCount: _penPreviewedSampleCount,
    );
    return true;
  }

  bool _updatePenPreviewImmediately() {
    _penVisualUpdateRequests += 1;
    final appended = _appendPenPreviewTail();
    if (appended) _penPreviewRepaints += 1;
    return appended;
  }

  bool _flushPenPreviewUpdate() {
    _penVisualUpdateRequests += 1;
    final needsAppend = _pen?.sampleCount != _penPreviewedSampleCount;
    final appended = _appendPenPreviewTail();
    if (appended && needsAppend) _penPreviewRepaints += 1;
    return appended;
  }

  void _clearPenPreview() {
    final frozen = _penFrozenPreviewLayers.value;
    _penFrozenPreviewLayers.value = const [];
    for (final layer in frozen) {
      _disposePicture(layer.picture);
    }
    _penActivePreviewPrimitives.clear();
    _penPreviewPrimitiveCount = 0;
    _penPreviewedSampleCount = 0;
    _penPreviewOverlay.clear();
  }

  bool _freezeActivePenPreview() {
    if (_penActivePreviewPrimitives.isEmpty) return true;
    final layers = List<_PenFrozenLayer>.of(_penFrozenPreviewLayers.value);
    final picture = _recordPenPicture(_penActivePreviewPrimitives);
    _pictureCreated();
    layers.add(
      _PenFrozenLayer(id: _penNextLayerId++, tier: 0, picture: picture),
    );
    _penActivePreviewPrimitives.clear();
    while (layers.length >= 2 &&
        layers[layers.length - 1].tier == layers[layers.length - 2].tier) {
      final second = layers.removeLast();
      final first = layers.removeLast();
      final merged = _recordCombinedPenPicture(first.picture, second.picture);
      _pictureCreated();
      _disposePicture(first.picture);
      _disposePicture(second.picture);
      layers.add(
        _PenFrozenLayer(
          id: _penNextLayerId++,
          tier: first.tier + 1,
          picture: merged,
        ),
      );
      _penCompactions += 1;
    }
    if (layers.length > widget.runtime.maximumPenPreviewLayers) {
      _penFrozenPreviewLayers.value = const [];
      for (final layer in layers) {
        _disposePicture(layer.picture);
      }
      return false;
    }
    _penMaximumRetainedPictures = math.max(
      _penMaximumRetainedPictures,
      layers.length,
    );
    _penFrozenPreviewLayers.value = List.unmodifiable(layers);
    return true;
  }

  ui.Picture _recordCombinedPenPicture(ui.Picture first, ui.Picture second) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawPicture(first);
    canvas.drawPicture(second);
    return recorder.endRecording();
  }

  void _scheduleImageRefresh(RenderSnapshot? scene) {
    if (scene == null || _imageRefreshScheduled) return;
    _imageRefreshScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _imageRefreshScheduled = false;
      if (!mounted) return;
      unawaited(_refreshDecodedImages(scene));
    });
  }

  Future<void> _refreshDecodedImages(RenderSnapshot scene) async {
    final requested = <ImageDecodeCacheKey, ImagePayload>{};
    for (final primitive in scene.primitives) {
      if (primitive case ImageBoxPrimitive(:final payload)) {
        requested[ImageDecodeCacheKey(
              resourceIdentity: payload.resourceIdentity,
              pixelWidth: payload.encodedPixelWidth,
              pixelHeight: payload.encodedPixelHeight,
            )] =
            payload;
      }
    }
    for (final key in _decodedImages.keys.toList()) {
      if (!requested.containsKey(key) ||
          !_coordinator.snapshot.root.resources.contains(
            key.resourceIdentity,
          )) {
        _removeDecodedImage(key);
      }
    }
    for (final key in _imageDecodes.keys.toList()) {
      if (!requested.containsKey(key)) {
        _imageDecodes.remove(key)?.cancel();
      }
    }
    final resources = {
      for (final resource in _coordinator.snapshot.resources)
        resource.identity: resource,
    };
    for (final entry in requested.entries) {
      if (_decodedImages.containsKey(entry.key) ||
          _imageDecodes.containsKey(entry.key)) {
        continue;
      }
      final resource = resources[entry.key.resourceIdentity];
      final format = switch (resource?.mediaType.value) {
        'image/png' => ImageFormat.png,
        'image/jpeg' => ImageFormat.jpeg,
        _ => null,
      };
      if (resource == null || format == null) continue;
      final cancellation = CancellationController();
      _imageDecodes[entry.key] = cancellation;
      final request = ImageDecodeRequest.create(
        resourceIdentity: entry.key.resourceIdentity,
        encodedBytes: resource.bytes,
        format: format,
        encodedPixelWidth: entry.value.encodedPixelWidth,
        encodedPixelHeight: entry.value.encodedPixelHeight,
        maximumEncodedBytes: widget.runtime.imageLimits.maximumEncodedBytes,
        maximumDecodedPixels: widget.runtime.imageLimits.maximumPixelCount,
        cancellationToken: cancellation.token,
      );
      if (request is! Ok<ImageDecodeRequest, StructuredFailure>) {
        _imageDecodes.remove(entry.key);
        continue;
      }
      final decoded = await const FlutterImageDecoder().decodeForPainting(
        request.value,
      );
      _imageDecodes.remove(entry.key);
      if (!mounted ||
          cancellation.token.isCancelled ||
          !_coordinator.snapshot.root.resources.contains(
            entry.key.resourceIdentity,
          ) ||
          decoded is! Ok<FlutterDecodedImage, StructuredFailure>) {
        if (decoded is Ok<FlutterDecodedImage, StructuredFailure>) {
          decoded.value.dispose();
        }
        continue;
      }
      final pixels = decoded.value.pixelWidth * decoded.value.pixelHeight;
      while (_decodedImages.isNotEmpty &&
          (_decodedImages.length >= widget.runtime.maximumHitResults ||
              _decodedImagePixels >
                  widget.runtime.imageLimits.maximumPixelCount - pixels)) {
        final oldest = _decodedImages.keys.first;
        _removeDecodedImage(oldest);
      }
      if (pixels > widget.runtime.imageLimits.maximumPixelCount) {
        decoded.value.dispose();
        continue;
      }
      _decodedImages[entry.key] = decoded.value;
      _decodedImagePixels += pixels;
      if (mounted) setState(() {});
    }
  }

  void _removeDecodedImage(ImageDecodeCacheKey key) {
    final image = _decodedImages.remove(key);
    if (image == null) return;
    _decodedImagePixels -= image.pixelWidth * image.pixelHeight;
    image.dispose();
  }

  CommittedPageScene? _committedSceneForCurrentInputs() {
    final page = _page;
    final documentRevision = _coordinator.snapshot.revisions.document;
    final cached = _committedScene;
    if (cached != null &&
        identical(_committedPage, page) &&
        cached.documentRevision == documentRevision &&
        cached.viewportRevision == _viewport.revision) {
      return cached;
    }
    final built = _sceneBuilder.buildCommitted(
      page: page,
      viewport: _viewport,
      documentRevision: documentRevision,
    );
    if (built is! Ok<CommittedPageScene, StructuredFailure>) return null;
    if (_pen != null) _penCommittedSceneRebuilds += 1;
    _committedPage = page;
    _committedScene = built.value;
    return built.value;
  }

  _CommittedPaintEvidence? _committedPaintEvidenceFor(
    CommittedPageScene scene,
  ) {
    final current = _committedPaintEvidence;
    if (current != null && identical(current.scene, scene)) return current;
    final isExactAppend =
        current != null &&
        scene.objects.length == current.scene.objects.length + 1 &&
        scene.pageClip == current.scene.pageClip &&
        scene.viewportRevision == current.scene.viewportRevision &&
        List.generate(
          current.scene.objects.length,
          (index) =>
              identical(current.scene.objects[index], scene.objects[index]),
        ).every((value) => value);
    if (isExactAppend &&
        current.chunks.length < widget.runtime.maximumCommittedPaintChunks) {
      final addition = scene.objects.last;
      if (addition.primitives.length <=
          widget.runtime.maximumCommittedPaintChunkPrimitives) {
        final next = _CommittedPaintEvidence(
          scene: scene,
          chunks: [
            ...current.chunks,
            _CommittedPaintChunk(
              id: _nextCommittedPaintChunkId++,
              objects: [addition],
            ),
          ],
        );
        _committedPaintEvidence = next;
        _displayCommittedPaintSource = null;
        if (_pendingPenAddedObjectId != null) {
          _penCommittedChunksRetained = current.chunks.length;
          _penCommittedChunksRebuilt = 1;
        }
        return next;
      }
    }
    final chunks = <_CommittedPaintChunk>[];
    var objects = <CommittedObjectScene>[];
    var primitives = 0;
    bool flush() {
      if (objects.isEmpty) return true;
      if (chunks.length == widget.runtime.maximumCommittedPaintChunks) {
        return false;
      }
      chunks.add(
        _CommittedPaintChunk(
          id: _nextCommittedPaintChunkId++,
          objects: objects,
        ),
      );
      objects = <CommittedObjectScene>[];
      primitives = 0;
      return true;
    }

    for (final object in scene.objects) {
      final count = object.primitives.length;
      if (count > widget.runtime.maximumCommittedPaintChunkPrimitives) {
        return null;
      }
      if (objects.isNotEmpty &&
          (objects.length == widget.runtime.maximumCommittedPaintChunkObjects ||
              primitives + count >
                  widget.runtime.maximumCommittedPaintChunkPrimitives)) {
        if (!flush()) return null;
      }
      objects.add(object);
      primitives += count;
    }
    if (!flush()) return null;
    final next = _CommittedPaintEvidence(scene: scene, chunks: chunks);
    _committedPaintEvidence = next;
    _displayCommittedPaintSource = null;
    if (_pendingPenAddedObjectId != null) {
      _penCommittedChunksRetained = 0;
      _penCommittedChunksRebuilt = chunks.length;
    }
    return next;
  }

  List<_CommittedPaintChunk>? _committedPaintChunksFor(
    CommittedPageScene scene,
    Set<ObjectId> exclusions,
  ) {
    final evidence = _committedPaintEvidenceFor(scene);
    if (evidence == null) return null;
    if (identical(_displayCommittedPaintSource, evidence) &&
        _sameObjectIds(_displayCommittedPaintExclusions, exclusions)) {
      return _displayCommittedPaintChunks;
    }
    final result = <_CommittedPaintChunk>[];
    for (final chunk in evidence.chunks) {
      if (exclusions.isEmpty) {
        result.add(chunk);
        continue;
      }
      final visible = chunk.objects
          .where((object) => !exclusions.contains(object.objectId))
          .toList(growable: false);
      if (visible.isEmpty) continue;
      result.add(
        visible.length == chunk.objects.length
            ? chunk
            : _CommittedPaintChunk(id: chunk.id, objects: visible),
      );
    }
    _displayCommittedPaintSource = evidence;
    _displayCommittedPaintExclusions = Set<ObjectId>.unmodifiable(exclusions);
    _displayCommittedPaintChunks = List<_CommittedPaintChunk>.unmodifiable(
      result,
    );
    return _displayCommittedPaintChunks;
  }

  RenderSnapshot? _committedDisplayFor(
    CommittedPageScene committed,
    Set<ObjectId> exclusions,
  ) {
    final cached = _committedDisplay;
    if (cached != null &&
        identical(_committedDisplaySource, committed) &&
        _sameObjectIds(_committedDisplayExclusions, exclusions)) {
      return cached;
    }
    final composed = _sceneBuilder.compose(
      committed: committed,
      excludedObjectIds: exclusions,
    );
    if (composed is! Ok<RenderSnapshot, StructuredFailure>) return null;
    _committedDisplaySource = committed;
    _committedDisplayExclusions = Set<ObjectId>.unmodifiable(exclusions);
    _committedDisplay = composed.value;
    return composed.value;
  }

  List<ScenePrimitive> _selectionPrimitives(_SelectionFrameSnapshot? frame) {
    final result = <ScenePrimitive>[];
    if (frame != null) {
      final primitives = _selectionFramePrimitives(frame);
      if (primitives is Ok<List<ScenePrimitive>, StructuredFailure>) {
        result.addAll(primitives.value);
      }
    }
    final down = _selectionDown;
    final current = _selectionCurrent;
    if (down != null && current != null) {
      final marquee = Rect2.fromEdges(
        left: math.min(down.x, current.x),
        top: math.min(down.y, current.y),
        right: math.max(down.x, current.x),
        bottom: math.max(down.y, current.y),
      );
      if (marquee is Ok<Rect2, StructuredFailure>) {
        final primitive = _selectionRectPrimitive(marquee.value);
        if (primitive != null) result.add(primitive);
      }
    }
    return List.unmodifiable(result);
  }

  ScenePrimitive? _selectionRectPrimitive(Rect2 bounds) {
    final first = _viewport
        .pageToView(bounds.topLeft)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    final second = _viewport
        .pageToView(bounds.bottomRight)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    if (first == null || second == null) return null;
    final viewBounds = Rect2.fromEdges(
      left: first.x < second.x ? first.x : second.x,
      top: first.y < second.y ? first.y : second.y,
      right: first.x > second.x ? first.x : second.x,
      bottom: first.y > second.y ? first.y : second.y,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
    if (viewBounds == null) return null;
    return PlaceholderPrimitive.create(
      plane: RenderPlane.selection,
      bounds: viewBounds,
      opacity: 1,
    ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
  }

  ScenePrimitive? _creationRectPrimitive(Rect2 bounds) {
    final first = _viewport
        .pageToView(bounds.topLeft)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    final second = _viewport
        .pageToView(bounds.bottomRight)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    if (first == null || second == null) return null;
    final viewBounds = Rect2.fromEdges(
      left: math.min(first.x, second.x),
      top: math.min(first.y, second.y),
      right: math.max(first.x, second.x),
      bottom: math.max(first.y, second.y),
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
    if (viewBounds == null) return null;
    return PlaceholderPrimitive.create(
      plane: RenderPlane.toolPreview,
      bounds: viewBounds,
      opacity: 1,
    ).fold<ScenePrimitive?>(onOk: (value) => value, onErr: (_) => null);
  }
}

final class _EraserCursorController {
  _EraserCursorController({required this.onRequest, required this.onRepaint});

  final VoidCallback onRequest;
  final ValueChanged<int> onRepaint;
  final ValueNotifier<ViewPoint?> position = ValueNotifier(null);
  ViewPoint? _latest;
  bool _scheduled = false;
  int _generation = 0;

  void update(ViewPoint value) {
    _latest = value;
    onRequest();
    if (_scheduled) return;
    _scheduled = true;
    final generation = _generation;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (generation != _generation) return;
      _scheduled = false;
      position.value = _latest;
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void didPaint(int elapsedMicros) => onRepaint(elapsedMicros);

  void clear() {
    _generation += 1;
    _scheduled = false;
    _latest = null;
    position.value = null;
  }

  void dispose() {
    _generation += 1;
    position.dispose();
  }
}

final class _EraserCursorPainter extends CustomPainter
    implements Phase6EraserCursorEvidence {
  const _EraserCursorPainter({required this.position, this.onPainted});

  final ViewPoint? position;
  final ValueChanged<int>? onPainted;

  @override
  ViewPoint? get cursorPosition => position;

  @override
  void paint(Canvas canvas, Size size) {
    final value = position;
    if (value == null) return;
    final callback = onPainted;
    final clock = callback == null ? null : (Stopwatch()..start());
    canvas.drawCircle(
      Offset(value.x, value.y),
      8,
      Paint()
        ..color = Colors.grey.withValues(alpha: .8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    clock?.stop();
    if (callback != null) callback(clock!.elapsedMicroseconds);
  }

  @override
  bool shouldRepaint(covariant _EraserCursorPainter old) =>
      old.position != position;
}

ui.Picture _recordPenPicture(Iterable<ScenePrimitive> primitives) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (final primitive in primitives) {
    _paintPrimitive(canvas, primitive);
  }
  return recorder.endRecording();
}

/// Paints one validated scene primitive for render-boundary regression tests.
@visibleForTesting
void paintScenePrimitiveForTesting(Canvas canvas, ScenePrimitive primitive) {
  _paintPrimitive(canvas, primitive);
}

void _paintPrimitive(
  Canvas canvas,
  ScenePrimitive primitive, {
  Map<ImageDecodeCacheKey, FlutterDecodedImage> decodedImages = const {},
}) {
  switch (primitive) {
    case FilledPolygonPrimitive(
      :final points,
      :final color,
      :final opacity,
      :final localToViewCoefficients,
    ):
      if (localToViewCoefficients != null) {
        canvas.save();
        canvas.transform(_canvasMatrix(localToViewCoefficients));
      }
      final path = Path()
        ..fillType = primitive.fillRule == RenderFillRule.evenOdd
            ? PathFillType.evenOdd
            : PathFillType.nonZero
        ..moveTo(points.first.x, points.first.y);
      for (final point in points.skip(1)) path.lineTo(point.x, point.y);
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = Color(
            color.argb,
          ).withValues(alpha: _colorAlpha(color.argb) * opacity),
      );
      if (localToViewCoefficients != null) canvas.restore();
    case FilledPolygonGroupPrimitive(
      :final contours,
      :final color,
      :final opacity,
      :final localToViewCoefficients,
    ):
      final effectiveAlpha = _colorAlpha(color.argb) * opacity;
      canvas.saveLayer(
        Rect.fromLTRB(
          primitive.bounds.left,
          primitive.bounds.top,
          primitive.bounds.right,
          primitive.bounds.bottom,
        ).inflate(2),
        Paint()
          ..color = const Color(0xffffffff).withValues(alpha: effectiveAlpha),
      );
      if (localToViewCoefficients != null) {
        canvas.save();
        canvas.transform(_canvasMatrix(localToViewCoefficients));
      }
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = Color(color.argb).withValues(alpha: 1);
      for (final contour in contours) {
        final path = Path()..moveTo(contour.first.x, contour.first.y);
        for (final point in contour.skip(1)) {
          path.lineTo(point.x, point.y);
        }
        path.close();
        canvas.drawPath(path, paint);
      }
      if (localToViewCoefficients != null) canvas.restore();
      canvas.restore();
    case StrokedPathPrimitive(
      :final points,
      :final color,
      :final opacity,
      :final strokeWidth,
      :final cap,
      :final join,
      :final miterLimit,
      :final closed,
      :final dashArray,
      :final dashOffset,
      :final localToViewCoefficients,
    ):
      if (localToViewCoefficients != null) {
        canvas.save();
        canvas.transform(_canvasMatrix(localToViewCoefficients));
      }
      final path = Path()..moveTo(points.first.x, points.first.y);
      for (final point in points.skip(1)) path.lineTo(point.x, point.y);
      if (closed) path.close();
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = Color(color.argb).withValues(alpha: opacity)
        ..strokeWidth = strokeWidth
        ..strokeCap = switch (cap) {
          RenderStrokeCap.butt => StrokeCap.butt,
          RenderStrokeCap.round => StrokeCap.round,
          RenderStrokeCap.square => StrokeCap.square,
        }
        ..strokeJoin = switch (join) {
          RenderStrokeJoin.miter => StrokeJoin.miter,
          RenderStrokeJoin.round => StrokeJoin.round,
          RenderStrokeJoin.bevel => StrokeJoin.bevel,
        }
        ..strokeMiterLimit = miterLimit;
      if (dashArray.isEmpty) {
        canvas.drawPath(path, paint);
      } else {
        _drawDashedPath(canvas, path, paint, dashArray, dashOffset);
      }
      if (localToViewCoefficients != null) canvas.restore();
    case ImageBoxPrimitive(
      :final payload,
      :final opacity,
      :final localToViewCoefficients,
    ):
      canvas.save();
      canvas.transform(_canvasMatrix(localToViewCoefficients));
      final rect = Rect.fromLTWH(
        0.0,
        0,
        payload.bounds.width,
        payload.bounds.height,
      );
      final decoded =
          decodedImages[ImageDecodeCacheKey(
            resourceIdentity: payload.resourceIdentity,
            pixelWidth: payload.encodedPixelWidth,
            pixelHeight: payload.encodedPixelHeight,
          )];
      if (decoded != null) {
        decoded.paint(canvas, rect, payload, opacity: opacity);
        canvas.restore();
        break;
      }
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xffeef1f4).withValues(alpha: opacity)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xff6b7280).withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      canvas.drawLine(
        rect.topLeft,
        rect.bottomRight,
        Paint()..color = const Color(0xff9ca3af).withValues(alpha: opacity),
      );
      canvas.drawLine(
        rect.topRight,
        rect.bottomLeft,
        Paint()..color = const Color(0xff9ca3af).withValues(alpha: opacity),
      );
      canvas.restore();
    case TextBoxPrimitive(
      :final payload,
      :final layout,
      :final opacity,
      :final localToViewCoefficients,
    ):
      canvas.save();
      canvas.transform(_canvasMatrix(localToViewCoefficients));
      final box = Rect.fromLTRB(
        layout.logicalBounds.left,
        layout.logicalBounds.top,
        layout.logicalBounds.right,
        layout.logicalBounds.bottom,
      );
      if (payload.boxMode == TextBoxMode.fixedWidthFixedHeight &&
          payload.overflowPolicy == TextOverflowPolicy.clip) {
        canvas.clipRect(box);
      }
      final painters = <TextPainter>[];
      final maximumWidth = math.max<double>(
        0,
        payload.intrinsicWidth - payload.padding.left - payload.padding.right,
      );
      const factory = FlutterTextPainterFactory();
      try {
        for (final paragraph in payload.paragraphs) {
          painters.add(
            factory.create(
              payload: payload,
              paragraph: paragraph,
              maximumWidth: maximumWidth,
              layerOpacity: opacity,
            ),
          );
        }
        for (var index = 0; index < painters.length; index++) {
          final painter = painters[index];
          final placement = layout.paragraphs[index];
          painter.paint(canvas, Offset(placement.origin.x, placement.origin.y));
        }
      } finally {
        for (final painter in painters) {
          factory.dispose(painter);
        }
      }
      canvas.restore();
    case PlaceholderPrimitive(:final plane, :final bounds, :final opacity):
      canvas.drawRect(
        Rect.fromLTRB(bounds.left, bounds.top, bounds.right, bounds.bottom),
        Paint()
          ..color = (plane == RenderPlane.selection ? Colors.blue : Colors.grey)
              .withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = plane == RenderPlane.selection ? 2 : 1,
      );
  }
}

double _colorAlpha(int argb) => (argb >>> 24 & 0xff) / 255;

Float64List _canvasMatrix(List<double> coefficients) => Float64List.fromList([
  coefficients[0],
  coefficients[2],
  0,
  0,
  coefficients[1],
  coefficients[3],
  0,
  0,
  0,
  0,
  1,
  0,
  coefficients[4],
  coefficients[5],
  0,
  1,
]);

void _drawDashedPath(
  Canvas canvas,
  Path source,
  Paint paint,
  List<double> pattern,
  double offset,
) {
  final cycle = pattern.fold<double>(0, (sum, value) => sum + value);
  if (!cycle.isFinite || cycle <= 0) return;
  var phase = offset % cycle;
  if (phase < 0) phase += cycle;
  for (final metric in source.computeMetrics()) {
    var index = 0;
    while (phase >= pattern[index]) {
      phase -= pattern[index];
      index = (index + 1) % pattern.length;
    }
    var distance = -phase;
    while (distance < metric.length) {
      final length = pattern[index];
      final start = math.max(0.0, distance);
      final end = math.min(metric.length, distance + length);
      if (index.isEven && end > start) {
        canvas.drawPath(metric.extractPath(start, end), paint);
      }
      distance += length;
      index = (index + 1) % pattern.length;
    }
  }
}

final class _DashedTextBoundaryPainter extends CustomPainter {
  const _DashedTextBoundaryPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRect(Offset.zero & size);
    _drawDashedPath(
      canvas,
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
      const [4, 3],
      0,
    );
  }

  @override
  bool shouldRepaint(covariant _DashedTextBoundaryPainter old) =>
      old.color != color;
}

final class _PenCursorController extends ChangeNotifier {
  ViewPoint? position;
  int updateCount = 0;
  int paintCount = 0;

  void update(ViewPoint value) {
    position = value;
    updateCount += 1;
    notifyListeners();
  }

  void clear() {
    if (position == null) return;
    position = null;
    notifyListeners();
  }

  void didPaint() => paintCount += 1;
}

final class _PenCursorPainter extends CustomPainter
    implements Phase6PenCursorEvidence {
  _PenCursorPainter({required this.controller}) : super(repaint: controller);

  final _PenCursorController controller;

  @override
  ViewPoint? get cursorPosition => controller.position;

  @override
  int get updateCount => controller.updateCount;

  @override
  int get paintCount => controller.paintCount;

  @override
  void paint(Canvas canvas, Size size) {
    final point = controller.position;
    if (point == null) return;
    canvas.drawCircle(
      Offset(point.x, point.y),
      4,
      Paint()
        ..color = const Color(0x9917324d)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    controller.didPaint();
  }

  @override
  bool shouldRepaint(covariant _PenCursorPainter old) =>
      old.controller != controller;
}

final class _PenPreviewController extends ChangeNotifier {
  _PenPreviewController({required this.frozen, required this.active});

  final ValueListenable<List<_PenFrozenLayer>> frozen;
  final List<ScenePrimitive> active;
  Point2? latestAcceptedSampleCenter;
  int previewedSampleCount = 0;

  void update({
    required Point2 latestAcceptedSampleCenter,
    required int previewedSampleCount,
  }) {
    this.latestAcceptedSampleCenter = latestAcceptedSampleCenter;
    this.previewedSampleCount = previewedSampleCount;
    notifyListeners();
  }

  void clear() {
    latestAcceptedSampleCenter = null;
    previewedSampleCount = 0;
    notifyListeners();
  }
}

final class _PenPreviewPainter extends CustomPainter
    implements Phase6PenPreviewEvidence {
  _PenPreviewPainter({
    required this.pageClip,
    required this.controller,
    required this.onPainted,
  }) : super(repaint: controller);

  final Rect2? pageClip;
  final _PenPreviewController controller;
  final ValueChanged<int> onPainted;

  @override
  Point2? get latestAcceptedSampleCenter =>
      controller.latestAcceptedSampleCenter;

  @override
  int get previewedSampleCount => controller.previewedSampleCount;

  @override
  int get frozenChunkCount => controller.frozen.value.length;

  @override
  int get activePrimitiveCount => controller.active.length;

  @override
  Rect2? get latestPrimitiveBounds => controller.active.lastOrNull?.bounds;

  @override
  void paint(Canvas canvas, Size size) {
    final clip = pageClip;
    if (clip == null) return;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(clip.left, clip.top, clip.right, clip.bottom),
    );
    for (final primitive in controller.active)
      _paintPrimitive(canvas, primitive);
    canvas.restore();
    onPainted(controller.active.length);
  }

  @override
  bool shouldRepaint(covariant _PenPreviewPainter old) =>
      old.pageClip != pageClip || old.controller != controller;
}

final class _PenFrozenLayer {
  const _PenFrozenLayer({
    required this.id,
    required this.tier,
    required this.picture,
  });

  final int id;
  final int tier;
  final ui.Picture picture;
}

final class _FrozenPenPicturePainter extends CustomPainter {
  const _FrozenPenPicturePainter({
    required this.pageClip,
    required this.picture,
    required this.onPainted,
  });

  final Rect2? pageClip;
  final ui.Picture picture;
  final VoidCallback onPainted;

  @override
  void paint(Canvas canvas, Size size) {
    final clip = pageClip;
    if (clip == null) return;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(clip.left, clip.top, clip.right, clip.bottom),
    );
    canvas.drawPicture(picture);
    canvas.restore();
    onPainted();
  }

  @override
  bool shouldRepaint(covariant _FrozenPenPicturePainter old) =>
      old.pageClip != pageClip || old.picture != picture;
}

final class _CommittedPaintEvidence {
  _CommittedPaintEvidence({
    required this.scene,
    required Iterable<_CommittedPaintChunk> chunks,
  }) : chunks = List<_CommittedPaintChunk>.unmodifiable(chunks);

  final CommittedPageScene scene;
  final List<_CommittedPaintChunk> chunks;
}

final class _CommittedPaintChunk {
  factory _CommittedPaintChunk({
    required int id,
    required Iterable<CommittedObjectScene> objects,
  }) {
    final captured = List<CommittedObjectScene>.unmodifiable(objects);
    return _CommittedPaintChunk._(
      id: id,
      objects: captured,
      primitives: captured
          .expand((object) => object.primitives)
          .toList(growable: false),
    );
  }

  _CommittedPaintChunk._({
    required this.id,
    required this.objects,
    required Iterable<ScenePrimitive> primitives,
  }) : primitives = List<ScenePrimitive>.unmodifiable(primitives);

  final int id;
  final List<CommittedObjectScene> objects;
  final List<ScenePrimitive> primitives;
}

final class _CommittedChunkPainter extends CustomPainter {
  const _CommittedChunkPainter({
    required this.chunk,
    required this.decodedImages,
    required this.pageClip,
    required this.excludedObjectId,
    required this.onPainted,
  });

  final _CommittedPaintChunk chunk;
  final Map<ImageDecodeCacheKey, FlutterDecodedImage> decodedImages;
  final Rect2 pageClip;
  final ObjectId? excludedObjectId;
  final ValueChanged<bool> onPainted;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        pageClip.left,
        pageClip.top,
        pageClip.right,
        pageClip.bottom,
      ),
    );
    for (final object in chunk.objects) {
      if (object.objectId == excludedObjectId) continue;
      for (final primitive in object.primitives) {
        _paintPrimitive(canvas, primitive, decodedImages: decodedImages);
      }
    }
    canvas.restore();
    onPainted(excludedObjectId == null);
  }

  @override
  bool shouldRepaint(covariant _CommittedChunkPainter old) =>
      old.chunk != chunk ||
      old.pageClip != pageClip ||
      old.excludedObjectId != excludedObjectId ||
      !mapEquals(old.decodedImages, decodedImages);

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (Size size) => _primitiveSemantics(chunk.primitives);

  @override
  bool shouldRebuildSemantics(covariant _CommittedChunkPainter old) =>
      old.chunk != chunk;
}

final class _CanvasPainter extends CustomPainter
    implements Phase6CanvasPersistenceEvidence {
  _CanvasPainter({
    required this.snapshot,
    required this.decodedImages,
    required this.paintBackground,
    required this.paintPrimitives,
    required this.buildSemantics,
    required this.savedBytes,
    required this.savedRoot,
    required this.currentRoot,
    required this.reopenedMaterializedRoot,
    required this.previewPrimitiveCount,
    required this.selectionPrimitiveCount,
    required this.selectionFrame,
    required this.eraserPathLength,
    required this.wholeSegmentCount,
    required this.wholeGeometryChecks,
    this.onPainted,
  });
  final RenderSnapshot? snapshot;
  final Map<ImageDecodeCacheKey, FlutterDecodedImage> decodedImages;
  final bool paintBackground;
  final bool paintPrimitives;
  final bool buildSemantics;
  final List<int>? savedBytes;
  final DocumentRoot? savedRoot;
  final DocumentRoot currentRoot;
  final DocumentRoot? reopenedMaterializedRoot;
  final int previewPrimitiveCount;
  @override
  final int selectionPrimitiveCount;
  @override
  final Phase6SelectionFrameEvidence? selectionFrame;
  final int eraserPathLength;
  final int wholeSegmentCount;
  final int wholeGeometryChecks;
  final VoidCallback? onPainted;

  @override
  Rect2? get pageClip => snapshot?.pageClip;

  @override
  void paint(Canvas canvas, Size size) {
    if (paintBackground) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xffd9dde2),
      );
    }
    final scene = snapshot;
    if (scene == null) return;
    final clip = Rect.fromLTRB(
      scene.pageClip.left,
      scene.pageClip.top,
      scene.pageClip.right,
      scene.pageClip.bottom,
    );
    canvas.save();
    canvas.clipRect(clip);
    if (paintBackground) {
      canvas.drawRect(clip, Paint()..color = Colors.white);
    }
    if (paintPrimitives) {
      for (final primitive in scene.primitives) {
        _paintPrimitive(canvas, primitive, decodedImages: decodedImages);
      }
    }
    canvas.restore();
    onPainted?.call();
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.snapshot != snapshot ||
      old.paintBackground != paintBackground ||
      old.paintPrimitives != paintPrimitives ||
      !mapEquals(old.decodedImages, decodedImages);

  @override
  SemanticsBuilderCallback get semanticsBuilder => (Size size) {
    final scene = snapshot;
    if (!buildSemantics || scene == null) {
      return const <CustomPainterSemantics>[];
    }
    return _primitiveSemantics(scene.primitives);
  };

  @override
  bool shouldRebuildSemantics(covariant _CanvasPainter old) =>
      old.snapshot != snapshot || old.buildSemantics != buildSemantics;

  @override
  String toString() =>
      'CanvasPainter(previews: $previewPrimitiveCount, '
      'eraserPath: $eraserPathLength, wholeSegments: $wholeSegmentCount, '
      'wholeChecks: $wholeGeometryChecks)';
}

List<CustomPainterSemantics> _primitiveSemantics(
  Iterable<ScenePrimitive> primitives,
) {
  final semantics = <CustomPainterSemantics>[];
  for (final primitive in primitives) {
    final label = switch (primitive) {
      ImageBoxPrimitive(:final payload) => payload.accessibilityAlternativeText,
      TextBoxPrimitive(:final payload) => payload.logicalText,
      _ => null,
    };
    if (label == null || label.isEmpty) continue;
    final direction = switch (primitive) {
      TextBoxPrimitive(:final payload)
          when payload.defaultParagraphStyle.direction ==
              TextParagraphDirection.rtl =>
        TextDirection.rtl,
      _ => TextDirection.ltr,
    };
    semantics.add(
      CustomPainterSemantics(
        rect: Rect.fromLTRB(
          primitive.bounds.left,
          primitive.bounds.top,
          primitive.bounds.right,
          primitive.bounds.bottom,
        ),
        properties: SemanticsProperties(
          label: label,
          readOnly: true,
          textDirection: direction,
        ),
      ),
    );
  }
  return semantics;
}

Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));
double _distance(Point2 first, Point2 second) {
  final dx = first.x - second.x;
  final dy = first.y - second.y;
  return math.sqrt(dx * dx + dy * dy);
}

IconData _toolIcon(_CanvasTool tool) => switch (tool) {
  _CanvasTool.pen => Icons.draw,
  _CanvasTool.wholeEraser => Icons.auto_fix_normal,
  _CanvasTool.selection => Icons.select_all,
  _CanvasTool.shape => Icons.category_outlined,
  _CanvasTool.text => Icons.text_fields,
};
ShapeColor? _shapeColor(int argb) => ShapeColor.create(
  red: argb >> 16 & 0xff,
  green: argb >> 8 & 0xff,
  blue: argb & 0xff,
  alpha: argb >> 24 & 0xff,
).fold<ShapeColor?>(onOk: (value) => value, onErr: (_) => null);
bool _sameObjectIds(Set<ObjectId> first, Set<ObjectId> second) =>
    first.length == second.length && first.every(second.contains);
bool _shouldRecordExponentialProgress(int value) =>
    value > 0 && (value <= 4 || value & (value - 1) == 0);
ViewPoint _viewPoint(double x, double y) => _ok(ViewPoint.create(x: x, y: y));
ViewPoint? _validatedViewPoint(double x, double y) => ViewPoint.create(
  x: x,
  y: y,
).fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
ToolId _toolId(_CanvasTool tool) =>
    _ok(ToolId.parse('alnote.tools.${tool.name.toLowerCase()}'));
InteractionActionId _actionId(_CanvasTool tool) =>
    _ok(InteractionActionId.parse('alnote.actions.${tool.name.toLowerCase()}'));
Revision _revision(int v) => _ok(Revision.create(v));
T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;

StructuredFailure _canvasFailure(String leaf) => StructuredFailure(
  code: 'ui.canvas.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Canvas operation is unavailable.',
);

sealed class _PendingNavigationOperation {
  const _PendingNavigationOperation();
}

final class _PendingPan extends _PendingNavigationOperation {
  const _PendingPan(this.dx, this.dy);
  final double dx;
  final double dy;
}

final class _PendingZoom extends _PendingNavigationOperation {
  const _PendingZoom(this.logDelta, this.pivot);
  final double logDelta;
  final ViewPoint pivot;
}

final class _UndoIntent extends Intent {
  const _UndoIntent();
}

final class _TextDialogResult {
  const _TextDialogResult({
    required this.text,
    required this.fontSize,
    required this.bold,
    required this.italic,
    required this.alignment,
    required this.argb,
  });
  final String text;
  final double fontSize;
  final bool bold;
  final bool italic;
  final TextAlignment alignment;
  final int argb;
}

final class _InlineTextSession {
  _InlineTextSession({
    required this.pageBounds,
    required this.existing,
    required this.prior,
    required this.baseObjectRevision,
    required this.documentId,
    required this.pageId,
    required this.layerId,
    required this.baseMembershipRevision,
    required Iterable<SelectionTarget> priorSelectionTargets,
    required this.removeControllerListener,
  }) : priorSelectionTargets = List<SelectionTarget>.unmodifiable(
         priorSelectionTargets,
       );

  Rect2 pageBounds;
  final ObjectEnvelope? existing;
  final TextPayload? prior;
  final Revision? baseObjectRevision;
  final DocumentId documentId;
  final PageId pageId;
  final LayerId? layerId;
  final Revision? baseMembershipRevision;
  final List<SelectionTarget> priorSelectionTargets;
  final VoidCallback removeControllerListener;
  AffineTransform2D? resizedTransform;
  TextBoxResizePreservedAnchor? preservedAnchor;

  AffineTransform2D get currentTransform =>
      resizedTransform ?? existing!.transform;
}

final class _SelectionResizeZone {
  const _SelectionResizeZone({
    required this.handle,
    required this.start,
    required this.end,
    required this.radius,
    required this.isCorner,
    required this.ordinal,
  });

  static List<_SelectionResizeZone> createAll(
    List<Point2> corners,
    double hitSize,
  ) {
    if (corners.length != 4) return const [];
    final offsets = corners
        .map((point) => Offset(point.x, point.y))
        .toList(growable: false);
    final radius = hitSize / 2;
    return List<_SelectionResizeZone>.unmodifiable([
      for (final entry in const [
        (_TextResizeHandle.topLeft, 0),
        (_TextResizeHandle.topRight, 1),
        (_TextResizeHandle.bottomRight, 2),
        (_TextResizeHandle.bottomLeft, 3),
      ])
        _SelectionResizeZone(
          handle: entry.$1,
          start: offsets[entry.$2],
          end: offsets[entry.$2],
          radius: radius,
          isCorner: true,
          ordinal: entry.$2,
        ),
      for (final entry in const [
        (_TextResizeHandle.top, 0, 1),
        (_TextResizeHandle.right, 1, 2),
        (_TextResizeHandle.bottom, 3, 2),
        (_TextResizeHandle.left, 0, 3),
      ].indexed)
        _SelectionResizeZone(
          handle: entry.$2.$1,
          start: offsets[entry.$2.$2],
          end: offsets[entry.$2.$3],
          radius: radius,
          isCorner: false,
          ordinal: 4 + entry.$1,
        ),
    ]);
  }

  final _TextResizeHandle handle;
  final Offset start;
  final Offset end;
  final double radius;
  final bool isCorner;
  final int ordinal;

  double distanceFrom(Offset point) {
    final delta = end - start;
    final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
    if (lengthSquared == 0) return (point - start).distance;
    final projection =
        ((point - start).dx * delta.dx + (point - start).dy * delta.dy) /
        lengthSquared;
    final nearest = start + delta * projection.clamp(0.0, 1.0);
    return (point - nearest).distance;
  }

  bool contains(Offset point) => distanceFrom(point) <= radius;
}

final class _SelectionFrameSnapshot implements Phase6SelectionFrameEvidence {
  _SelectionFrameSnapshot({
    required this.documentRevision,
    required this.viewportRevision,
    required this.selectionRevision,
    required this.preview,
    required Iterable<ObjectId> targetIds,
    required Iterable<Point2> pageCorners,
    required Iterable<Point2> viewCorners,
    required this.pageBounds,
    required this.pageCenter,
    required this.rotationCenter,
    required this.rotationConnectorStart,
    required this.rotationConnectorEnd,
    required this.rotationRadius,
    required this.isSingleText,
    required this.rotationSupported,
    required this.resizeSupported,
    required this.resizeHitSizeViewPixels,
  }) : targetIds = List<ObjectId>.unmodifiable(targetIds),
       pageCorners = List<Point2>.unmodifiable(pageCorners),
       viewCorners = List<Point2>.unmodifiable(viewCorners),
       resizeZones = _SelectionResizeZone.createAll(
         List<Point2>.unmodifiable(viewCorners),
         resizeHitSizeViewPixels,
       );

  final Revision documentRevision;
  final Revision viewportRevision;
  final Revision selectionRevision;
  final WholeObjectTransformPreview? preview;
  final List<ObjectId> targetIds;
  final List<Point2> pageCorners;
  @override
  final List<Point2> viewCorners;
  final Rect2 pageBounds;
  final Point2 pageCenter;
  @override
  final Point2 rotationCenter;
  @override
  final Point2 rotationConnectorStart;
  @override
  final Point2 rotationConnectorEnd;
  @override
  final double rotationRadius;
  @override
  final bool isSingleText;
  final bool rotationSupported;
  final bool resizeSupported;
  final double resizeHitSizeViewPixels;
  final List<_SelectionResizeZone> resizeZones;

  _SelectionFrameSnapshot? transformedBy(
    AffineTransform2D pageTransform,
    List<double> viewTransform,
  ) {
    if (viewTransform.length != 6) return null;
    final nextPage = <Point2>[];
    for (final point in pageCorners) {
      final transformed = pageTransform.applyToPoint(point);
      if (transformed is! Ok<Point2, StructuredFailure>) return null;
      nextPage.add(transformed.value);
    }
    Point2 mapView(Point2 point) => _point(
      viewTransform[0] * point.x +
          viewTransform[1] * point.y +
          viewTransform[4],
      viewTransform[2] * point.x +
          viewTransform[3] * point.y +
          viewTransform[5],
    );

    final nextView = viewCorners.map(mapView).toList(growable: false);
    final topLeft = nextView[0];
    final topRight = nextView[1];
    final topDx = topRight.x - topLeft.x;
    final topDy = topRight.y - topLeft.y;
    final topLength = math.sqrt(topDx * topDx + topDy * topDy);
    if (!topLength.isFinite || topLength <= 0) return null;
    final topCenter = _point(
      (topLeft.x + topRight.x) / 2,
      (topLeft.y + topRight.y) / 2,
    );
    final outwardX = topDy / topLength;
    final outwardY = -topDx / topLength;
    const connectorLength = 28.0;
    final nextRotationCenter = _point(
      topCenter.x + outwardX * connectorLength,
      topCenter.y + outwardY * connectorLength,
    );
    final nextConnectorEnd = _point(
      nextRotationCenter.x - outwardX * rotationRadius,
      nextRotationCenter.y - outwardY * rotationRadius,
    );
    final bounds = Rect2.fromEdges(
      left: nextPage.map((value) => value.x).reduce(math.min),
      top: nextPage.map((value) => value.y).reduce(math.min),
      right: nextPage.map((value) => value.x).reduce(math.max),
      bottom: nextPage.map((value) => value.y).reduce(math.max),
    );
    final center = pageTransform.applyToPoint(pageCenter);
    if (bounds is! Ok<Rect2, StructuredFailure> ||
        center is! Ok<Point2, StructuredFailure>) {
      return null;
    }
    return _SelectionFrameSnapshot(
      documentRevision: documentRevision,
      viewportRevision: viewportRevision,
      selectionRevision: selectionRevision,
      preview: null,
      targetIds: targetIds,
      pageCorners: nextPage,
      viewCorners: nextView,
      pageBounds: bounds.value,
      pageCenter: center.value,
      rotationCenter: nextRotationCenter,
      rotationConnectorStart: topCenter,
      rotationConnectorEnd: nextConnectorEnd,
      rotationRadius: rotationRadius,
      isSingleText: isSingleText,
      rotationSupported: rotationSupported,
      resizeSupported: resizeSupported,
      resizeHitSizeViewPixels: resizeHitSizeViewPixels,
    );
  }

  Map<_TextResizeHandle, Offset> get cornerOffsets => {
    _TextResizeHandle.topLeft: Offset(viewCorners[0].x, viewCorners[0].y),
    _TextResizeHandle.topRight: Offset(viewCorners[1].x, viewCorners[1].y),
    _TextResizeHandle.bottomRight: Offset(viewCorners[2].x, viewCorners[2].y),
    _TextResizeHandle.bottomLeft: Offset(viewCorners[3].x, viewCorners[3].y),
  };

  _TextResizeHandle? resizeHandleAt(Offset point) {
    if (!resizeSupported || !point.dx.isFinite || !point.dy.isFinite) {
      return null;
    }
    final candidates = resizeZones
        .where((zone) => zone.contains(point))
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      if (left.isCorner != right.isCorner) return left.isCorner ? -1 : 1;
      final distance = left
          .distanceFrom(point)
          .compareTo(right.distanceFrom(point));
      return distance != 0 ? distance : left.ordinal.compareTo(right.ordinal);
    });
    return candidates.first.handle;
  }

  int? cornerIndexFor(_TextResizeHandle handle) => switch (handle) {
    _TextResizeHandle.topLeft => 0,
    _TextResizeHandle.topRight => 1,
    _TextResizeHandle.bottomRight => 2,
    _TextResizeHandle.bottomLeft => 3,
    _ => null,
  };

  Point2 oppositePivot(_TextResizeHandle handle) {
    Point2 midpoint(Point2 first, Point2 second) =>
        _point((first.x + second.x) / 2, (first.y + second.y) / 2);
    return switch (handle) {
      _TextResizeHandle.topLeft => pageCorners[2],
      _TextResizeHandle.top => midpoint(pageCorners[2], pageCorners[3]),
      _TextResizeHandle.topRight => pageCorners[3],
      _TextResizeHandle.right => midpoint(pageCorners[0], pageCorners[3]),
      _TextResizeHandle.bottomRight => pageCorners[0],
      _TextResizeHandle.bottom => midpoint(pageCorners[0], pageCorners[1]),
      _TextResizeHandle.bottomLeft => pageCorners[1],
      _TextResizeHandle.left => midpoint(pageCorners[1], pageCorners[2]),
    };
  }

  double get scaleOrientationRadians => math.atan2(
    pageCorners[1].y - pageCorners[0].y,
    pageCorners[1].x - pageCorners[0].x,
  );

  Offset resizeDirection(_TextResizeHandle handle) {
    final topLeft = viewCorners[0];
    final topRight = viewCorners[1];
    final bottomRight = viewCorners[2];
    final bottomLeft = viewCorners[3];
    return switch (handle) {
      _TextResizeHandle.left || _TextResizeHandle.right => Offset(
        topRight.x - topLeft.x,
        topRight.y - topLeft.y,
      ),
      _TextResizeHandle.top || _TextResizeHandle.bottom => Offset(
        bottomLeft.x - topLeft.x,
        bottomLeft.y - topLeft.y,
      ),
      _TextResizeHandle.topLeft || _TextResizeHandle.bottomRight => Offset(
        bottomRight.x - topLeft.x,
        bottomRight.y - topLeft.y,
      ),
      _TextResizeHandle.topRight || _TextResizeHandle.bottomLeft => Offset(
        bottomLeft.x - topRight.x,
        bottomLeft.y - topRight.y,
      ),
    };
  }

  bool hitsRotation(Offset point) =>
      (point - Offset(rotationCenter.x, rotationCenter.y)).distance <= 11;

  bool contains(Offset point) {
    var sign = 0;
    for (var index = 0; index < viewCorners.length; index += 1) {
      final first = viewCorners[index];
      final second = viewCorners[(index + 1) % viewCorners.length];
      final cross =
          (second.x - first.x) * (point.dy - first.y) -
          (second.y - first.y) * (point.dx - first.x);
      if (cross.abs() <= 1e-7) continue;
      final current = cross > 0 ? 1 : -1;
      if (sign != 0 && sign != current) return false;
      sign = current;
    }
    return true;
  }
}

final class _PendingSelectionTransformUpdate {
  const _PendingSelectionTransformUpdate({
    required this.pagePoint,
    required this.modifiers,
  });

  final Point2 pagePoint;
  final InputModifiers modifiers;
}

final class _SelectionTransformPreparation {
  _SelectionTransformPreparation({
    required this.documentRevision,
    required this.resourceRevision,
    required this.viewportRevision,
    required this.selectionRevision,
    required Set<ObjectId> targetIds,
    required Map<ObjectId, Revision> objectRevisions,
    required Map<LayerId, Revision> membershipRevisions,
    required ui.Picture selectedPicture,
    required this.selectedViewBounds,
    required this.basePrimitiveCount,
    required this.baseFrame,
    required this.committed,
    required this.committedDisplay,
    required this.rotationSupported,
    required this.resizeSupported,
    required this.orientationRadians,
    required this.singleObjectId,
    required this.singleLocalBounds,
  }) : targetIds = Set<ObjectId>.unmodifiable(targetIds),
       objectRevisions = Map<ObjectId, Revision>.unmodifiable(objectRevisions),
       membershipRevisions = Map<LayerId, Revision>.unmodifiable(
         membershipRevisions,
       ),
       _selectedPicture = selectedPicture;

  final Revision documentRevision;
  final Revision resourceRevision;
  final Revision viewportRevision;
  final Revision selectionRevision;
  final Set<ObjectId> targetIds;
  final Map<ObjectId, Revision> objectRevisions;
  final Map<LayerId, Revision> membershipRevisions;
  ui.Picture? _selectedPicture;
  final Rect2 selectedViewBounds;
  final int basePrimitiveCount;
  final _SelectionFrameSnapshot baseFrame;
  final CommittedPageScene committed;
  final RenderSnapshot committedDisplay;
  final bool rotationSupported;
  final bool resizeSupported;
  final double orientationRadians;
  final ObjectId? singleObjectId;
  final Rect2? singleLocalBounds;

  ui.Picture? get selectedPicture => _selectedPicture;

  ui.Picture? takePicture() {
    final result = _selectedPicture;
    _selectedPicture = null;
    return result;
  }
}

final class _SelectionPicturePainter extends CustomPainter {
  const _SelectionPicturePainter({
    required this.pageClip,
    required this.picture,
    required this.viewTransformCoefficients,
    required this.onPainted,
  });

  final Rect2? pageClip;
  final ui.Picture picture;
  final List<double> viewTransformCoefficients;
  final VoidCallback onPainted;

  @override
  void paint(Canvas canvas, Size size) {
    final clip = pageClip;
    if (clip == null || viewTransformCoefficients.length != 6) return;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(clip.left, clip.top, clip.right, clip.bottom),
    );
    canvas.transform(_canvasMatrix(viewTransformCoefficients));
    canvas.drawPicture(picture);
    canvas.restore();
    onPainted();
  }

  @override
  bool shouldRepaint(covariant _SelectionPicturePainter old) =>
      old.pageClip != pageClip ||
      old.picture != picture ||
      !listEquals(old.viewTransformCoefficients, viewTransformCoefficients);
}

final class _SelectionTransformRenderEvidence {
  const _SelectionTransformRenderEvidence({
    required this.documentRevision,
    required this.viewportRevision,
    required this.targetIds,
    required this.committed,
    required this.committedDisplay,
    required this.overlays,
    required this.operation,
    required this.identity,
    required this.viewTransformCoefficients,
    required this.previewPrimitiveCount,
    required this.selectionFrame,
  });

  final Revision documentRevision;
  final Revision viewportRevision;
  final Set<ObjectId> targetIds;
  final CommittedPageScene committed;
  final RenderSnapshot committedDisplay;
  final RenderSnapshot overlays;
  final TransformOperation2D operation;
  final bool identity;
  final List<double> viewTransformCoefficients;
  final int previewPrimitiveCount;
  final _SelectionFrameSnapshot selectionFrame;
}

final class _RedoIntent extends Intent {
  const _RedoIntent();
}

final class _CancelIntent extends Intent {
  const _CancelIntent();
}

final class _PenIntent extends Intent {
  const _PenIntent();
}

final class _EraserIntent extends Intent {
  const _EraserIntent();
}

final class _SelectionIntent extends Intent {
  const _SelectionIntent();
}

final class _ShapeIntent extends Intent {
  const _ShapeIntent();
}

final class _TextIntent extends Intent {
  const _TextIntent();
}

final class _EditTextIntent extends Intent {
  const _EditTextIntent();
}

final class _PanCanvasIntent extends Intent {
  const _PanCanvasIntent(this.dx, this.dy);

  final double dx;
  final double dy;
}
