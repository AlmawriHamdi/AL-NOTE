// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
import 'phase6_canvas_runtime.dart';
import 'phase6_diagnostics.dart';

enum _CanvasTool { pen, wholeEraser, selection, shape, text }

const double _selectionDragThreshold = 6;
const int _penPreviewChunkPrimitiveLimit = 192;
const double _workspacePadding = 24;

/// Accessible Phase 6 Canvas vertical-slice experience.
final class Phase6Canvas extends StatefulWidget {
  /// Creates the Canvas.
  const Phase6Canvas({required this.runtime, super.key});

  /// Explicit production or test runtime dependencies.
  final Phase6CanvasRuntime runtime;
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
  CommittedPageScene? _committedDisplaySource;
  RenderSnapshot? _committedDisplay;
  Set<ObjectId> _committedDisplayExclusions = const {};
  PenGestureSession? _pen;
  final List<ui.Picture> _penFrozenPreviewChunks = [];
  final List<ScenePrimitive> _penActivePreviewPrimitives = [];
  int _penPreviewPrimitiveCount = 0;
  _CanvasTool _tool = _CanvasTool.pen;
  final List<Point2> _wholeEraserPath = [];
  ScenePrimitive? _eraserPreviewPrimitive;
  final Map<ObjectId, List<ScenePrimitive>> _eraserObjectPreviews = {};
  WholeEraseGesturePlan? _wholeEraserPlan;
  Point2? _selectionDown;
  Point2? _selectionCurrent;
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
  BuildContext? _activeTextDialogContext;
  _TextDialogResult? _staleTextDraft;
  StaleTextDraftEvidence? _staleTextEvidence;

  HandwritingLimits get _limits => widget.runtime.handwritingLimits;
  UuidGenerator get _uuid => widget.runtime.uuidGenerator;
  Phase6DiagnosticTrace get _diagnostics => widget.runtime.diagnosticTrace;

  void _pictureCreated() {
    try {
      widget.runtime.nativePictureObserver.pictureCreated();
    } on Object {
      // Accounting observers cannot affect Canvas ownership.
    }
  }

  void _pictureDisposed() {
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
    _router.cancel();
    _clearEraserTransient();
    _clearPenPreview();
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
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _eraserCursor = _EraserCursorController(
      onRequest: () {
        _cursorRepaintRequests += 1;
        _diagnostics.record(
          stage: Phase6DiagnosticStage.cursorRepaintRequested,
          pointerSegments: _wholeEraserPlan?.processedSegmentCount ?? 0,
          repaints: _cursorRepaintRequests,
        );
      },
      onRepaint: (elapsedMicros) {
        _cursorRepaints += 1;
        _diagnostics.record(
          stage: Phase6DiagnosticStage.cursorRepaintCompleted,
          pointerSegments: _wholeEraserPlan?.processedSegmentCount ?? 0,
          repaints: _cursorRepaints,
          elapsedMicros: elapsedMicros,
        );
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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      final dialogContext = _activeTextDialogContext;
      final draft = _activeTextDraft;
      if (dialogContext != null && draft != null) {
        Navigator.of(dialogContext).pop(draft);
      }
    }
    if (state != AppLifecycleState.resumed && _router.ownership.owner != null) {
      _cancelGesture('Gesture cancelled');
    }
  }

  DocumentPage get _page => _coordinator.snapshot.root.pages.single;
  LayerId get _layerId => _page.layers.whereType<ContentLayer>().first.id;

  ObjectEnvelope? get _selectedTextObject {
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
    _pen?.cancel();
    _router.cancel();
    _eraserCursor.clear();
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
      _creationDown = null;
      _creationCurrent = null;
      _tool = value;
      _status = '${value.name} active';
    });
  }

  void _undo() {
    final result = _coordinator.undo();
    _selection.reconcile(_coordinator.snapshot.root);
    setState(() {
      _status = result is Ok ? 'Undone' : 'Nothing to undo';
    });
  }

  void _redo() {
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
        );
        if (started is Ok<PenGestureSession, StructuredFailure>) {
          _pen = started.value;
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
        _beginSelection(pagePoint);
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
      if (!_appendPenPreviewTail()) {
        _cancelGesture('Stroke rejected');
        return;
      }
      setState(() {});
    } else if (routedTool == _CanvasTool.wholeEraser &&
        event.phase == PointerPhase.move) {
      _eraserCursor.update(event.viewPosition);
      if (!_appendWholeEraserPoint(pagePoint)) return;
    } else if (routedTool == _CanvasTool.selection &&
        event.phase == PointerPhase.move) {
      _updateSelection(pagePoint);
    } else if ((routedTool == _CanvasTool.shape ||
            routedTool == _CanvasTool.text) &&
        event.phase == PointerPhase.move) {
      setState(() => _creationCurrent = pagePoint);
    } else if (_pen != null &&
        routedTool == _CanvasTool.pen &&
        event.phase == PointerPhase.up) {
      final request = _pen!.finish(
        event,
        latestDocument: _coordinator.snapshot,
        viewportRevision: _viewport.revision,
        pointerOwnerAtTerminal: _router.ownership.owner,
      );
      if (request is Ok<AtomicObjectCollectionEditRequest, StructuredFailure>) {
        final commit = _coordinator.execute(request.value);
        setState(() {
          _status = commit is Ok ? 'Stroke committed' : 'Stroke rejected';
          _pen = null;
          _clearPenPreview();
        });
      } else {
        setState(() {
          _status = 'Stroke rejected';
          _pen = null;
          _clearPenPreview();
        });
      }
      _router.completeTerminal(event.pointerId);
      _selection.reconcile(_coordinator.snapshot.root);
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
      if (bounds != null) unawaited(_openTextEditor(bounds));
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

  Future<void> _openTextEditor(
    Rect2 pageBounds, {
    ObjectEnvelope? existing,
  }) async {
    final prior = existing == null
        ? null
        : TextPayload.decode(
            existing.payload,
            limits: widget.runtime.textLimits,
          ).fold<TextPayload?>(onOk: (value) => value, onErr: (_) => null);
    if (existing != null && prior == null) {
      setState(() => _status = 'Text unavailable');
      return;
    }
    final baseObjectRevision = existing == null
        ? null
        : _coordinator.snapshot.revisions.objects[existing.id];
    if (existing != null && baseObjectRevision == null) {
      setState(() => _status = 'Text unavailable');
      return;
    }
    final initial = _TextDialogResult(
      text: prior?.logicalText ?? '',
      fontSize: prior?.defaultCharacterStyle.fontSize ?? 24,
      bold: (prior?.defaultCharacterStyle.weight ?? 400) >= 700,
      italic: prior?.defaultCharacterStyle.italic ?? false,
      alignment: prior?.defaultParagraphStyle.alignment ?? TextAlignment.left,
      argb: prior?.defaultCharacterStyle.argb ?? 0xff17324d,
    );
    _activeTextDraft = initial;
    final result = await showDialog<_TextDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        _activeTextDialogContext = context;
        return _TextEditorDialog(
          initial: initial,
          editing: existing != null,
          onDraftChanged: (value) => _activeTextDraft = value,
        );
      },
    );
    _activeTextDialogContext = null;
    _activeTextDraft = null;
    if (!mounted) return;
    if (result == null || existing == null && result.text.isEmpty) {
      setState(
        () => _status = existing == null
            ? 'Text creation cancelled'
            : 'Text editing cancelled',
      );
      return;
    }
    final committed = _commitTextDialog(
      pageBounds,
      result,
      existing: existing,
      prior: prior,
      baseObjectRevision: baseObjectRevision,
    );
    final currentObjectRevision = existing == null
        ? null
        : _coordinator.snapshot.revisions.objects[existing.id];
    final stale =
        !committed &&
        baseObjectRevision != null &&
        currentObjectRevision != baseObjectRevision;
    if (committed) {
      _staleTextDraft = null;
      _staleTextEvidence = null;
    } else if (stale) {
      _staleTextDraft = result;
      _staleTextEvidence = StaleTextDraftEvidence(
        baseRevision: baseObjectRevision,
        currentRevision: currentObjectRevision,
      );
    }
    _selection.reconcile(_coordinator.snapshot.root);
    setState(
      () => _status = committed
          ? existing == null
                ? 'Text created'
                : 'Text updated'
          : stale
          ? 'Text changed elsewhere; draft retained '
                '(${_staleTextEvidence!.choices.length} recovery options, '
                '${_staleTextDraft!.text.length} characters)'
          : 'Text rejected',
    );
  }

  bool _commitTextDialog(
    Rect2 pageBounds,
    _TextDialogResult dialog, {
    ObjectEnvelope? existing,
    TextPayload? prior,
    Revision? baseObjectRevision,
  }) {
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
    if (character == null || paragraphStyle == null || padding == null)
      return false;
    final paragraphs = <TextParagraph>[];
    for (final text in dialog.text.split('\n')) {
      final run = TextRun.create(
        text: text,
        style: character,
        limits: limits,
      ).fold<TextRun?>(onOk: (value) => value, onErr: (_) => null);
      if (run == null) return false;
      final paragraph = TextParagraph.create(
        runs: [run],
        style: paragraphStyle,
        limits: limits,
      ).fold<TextParagraph?>(onOk: (value) => value, onErr: (_) => null);
      if (paragraph == null) return false;
      paragraphs.add(paragraph);
    }
    final payload = TextPayload.create(
      paragraphs: paragraphs,
      defaultCharacterStyle: character,
      defaultParagraphStyle: paragraphStyle,
      boxMode: prior?.boxMode ?? TextBoxMode.fixedWidthFixedHeight,
      intrinsicWidth: prior?.intrinsicWidth ?? pageBounds.width,
      intrinsicHeight: prior != null
          ? prior.intrinsicHeight
          : pageBounds.height,
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
    if (payload == null) return false;
    if (existing != null && prior != null) {
      return baseObjectRevision != null &&
          _publishTextReplacement(existing, prior, payload, baseObjectRevision);
    }
    return transform != null &&
        _publishNewObject(
          typeKey: textObjectTypeKey,
          schemaVersion: textSchemaVersion,
          payload: payload.encode(),
          transform: transform,
          description: 'Create text',
        );
  }

  bool _publishTextReplacement(
    ObjectEnvelope source,
    TextPayload before,
    TextPayload after,
    Revision baseObjectRevision,
  ) {
    try {
      final semantics = TextObjectTypeDefinition(widget.runtime.textLimits)
          .classifyPayloadChange(
            before.encode(),
            after.encode(),
            textSchemaVersion,
          );
      final correlation = _uuid.generateV4();
      final snapshot = _coordinator.snapshot;
      final membershipRevision = snapshot.revisions.layerMembership[_layerId];
      if (semantics is! Ok<ObjectPayloadChangeSemantics, StructuredFailure> ||
          correlation is! Ok<UuidIdentifier, StructuredFailure> ||
          membershipRevision == null) {
        return false;
      }
      final request = TextObjectEditRequest.replace(
        documentId: snapshot.root.id,
        source: source,
        payload: after,
        limits: widget.runtime.textLimits,
        metadata: CommandMetadata(
          family: CommandFamily.objectReplacement,
          correlationId: CommandCorrelationId.fromUuid(correlation.value),
          description: 'Edit text',
        ),
        preconditions: RevisionPreconditions(
          objects: {source.id: baseObjectRevision},
          layerMembership: {_layerId: membershipRevision},
        ),
        changeCategories: ObjectReplacementChangeCategories(
          geometry: semantics.value.geometry,
          appearance: semantics.value.appearance,
          text: semantics.value.text,
          metadata: semantics.value.metadata,
        ),
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

  void _beginSelection(Point2 pagePoint) {
    setState(() {
      _selectionDown = pagePoint;
      _selectionCurrent = pagePoint;
      _status = 'Selecting';
    });
  }

  void _updateSelection(Point2 pagePoint) {
    if (_selectionDown == null) return;
    setState(() => _selectionCurrent = pagePoint);
  }

  void _finishSelection(Point2 pagePoint) {
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
    final targets = queried.value.reversed
        .map((hit) => hit.toSelectionTarget())
        .toList(growable: false);
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
                : '${targets.length} strokes selected')
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
            targets: [hit.toSelectionTarget()],
          );
    setState(() {
      _status = result is Ok
          ? (hit == null ? 'Selection cleared' : 'Stroke selected')
          : 'Selection rejected';
    });
  }

  void _finishWholeErase() {
    final plan = _wholeEraserPlan;
    final noHits = plan != null && plan.affectedStrokeCount == 0;
    final request = plan != null && plan.isCurrent(_coordinator.snapshot)
        ? plan.createRequest(uuidGenerator: _uuid)
        : null;
    final commit =
        request is Ok<AtomicObjectCollectionEditRequest, StructuredFailure>
        ? _coordinator.execute(request.value)
        : null;
    _clearEraserTransient();
    _selection.reconcile(_coordinator.snapshot.root);
    setState(
      () => _status = commit is Ok
          ? 'Stroke erased'
          : noHits
          ? 'Nothing erased'
          : 'Erase rejected',
    );
  }

  void _cancelGesture(String status) {
    _pen?.cancel();
    _router.cancel();
    _clearEraserTransient();
    _clearPenPreview();
    setState(() {
      _pen = null;
      _selectionDown = null;
      _selectionCurrent = null;
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

  void _zoom(double factor) {
    _zoomTo(
      (_viewport.zoom * factor).clamp(
        _viewport.minimumZoom,
        _viewport.maximumZoom,
      ),
    );
  }

  void _zoomTo(double zoom) {
    if (_router.ownership.owner != null) return;
    final pivot = _viewPoint(
      _viewport.extent.width / 2,
      _viewport.extent.height / 2,
    );
    final result = _viewport.zoomedAbout(
      newZoom: zoom.clamp(_viewport.minimumZoom, _viewport.maximumZoom),
      viewPivot: pivot,
      expectedRevision: _viewport.revision,
    );
    if (result is Ok<ViewportSnapshot, StructuredFailure>) {
      final centered = _recenterWhenPageFits(result.value);
      if (centered == null) return;
      final published = _viewportController.publish(centered);
      if (published is! Ok<ViewportSnapshot, StructuredFailure>) return;
      setState(() {
        _viewport = published.value;
        _status = 'Zoom ${(_viewport.zoom * 100).round()}%';
      });
    }
  }

  void _synchronizeCanvasExtent(Size size) {
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
    final resized = ViewportSnapshot.create(
      extent: extent.value,
      pageOrigin: _centeredOrigin(
        extent: extent.value,
        zoom: _viewport.zoom,
        fallback: _viewport.pageOrigin,
      ),
      zoom: _viewport.zoom,
      minimumZoom: _viewport.minimumZoom,
      maximumZoom: _viewport.maximumZoom,
      revision: revision.value,
    );
    if (resized is! Ok<ViewportSnapshot, StructuredFailure>) return;
    final published = _viewportController.publish(resized.value);
    if (published is Ok<ViewportSnapshot, StructuredFailure>) {
      _viewport = published.value;
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
    return _point(x, y);
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
  }

  @override
  Widget build(BuildContext context) {
    final gestureIdle = _router.ownership.owner == null;
    final selectedText = _selectedTextObject;
    final lineShapeSelected = _shapeCreationKind == ShapeKind.line;
    final controls = <Widget>[
      for (final tool in _CanvasTool.values)
        Semantics(
          button: true,
          selected: _tool == tool,
          label: '${tool.name} tool',
          child: ChoiceChip(
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
                unawaited(
                  _openTextEditor(payload.bounds, existing: selectedText),
                );
              }
            },
            icon: const Icon(Icons.edit),
            label: const Text('Edit text'),
          ),
        ),
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
      TextButton(onPressed: _save, child: const Text('Save in memory')),
      TextButton(
        onPressed: _savedBytes == null ? null : _reopen,
        child: const Text('Reopen saved'),
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
    final scaffold = Scaffold(
      appBar: AppBar(title: const Text('AL NOTE')),
      body: Column(
        children: [
          Material(
            key: const Key('canvas-toolbar'),
            elevation: 2,
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: controls,
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                _synchronizeCanvasExtent(size);
                final previews = _previewPrimitives();
                final committed = _committedSceneForCurrentInputs();
                final committedDisplay = committed == null
                    ? null
                    : _committedDisplayFor(committed, {
                        ..._eraserObjectPreviews.keys,
                      });
                _scheduleImageRefresh(committedDisplay);
                final overlays = committed == null
                    ? null
                    : _sceneBuilder
                          .composeOverlays(
                            committed: committed,
                            previews: previews,
                            selections: _selectionPrimitives(),
                          )
                          .fold<RenderSnapshot?>(
                            onOk: (value) => value,
                            onErr: (_) => null,
                          );
                return ClipRect(
                  child: Semantics(
                    label: 'Handwriting canvas',
                    container: true,
                    child: Listener(
                      key: const Key('phase6-canvas-listener'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _pointer,
                      onPointerMove: _pointer,
                      onPointerUp: _pointer,
                      onPointerCancel: _pointer,
                      child: RepaintBoundary(
                        key: const Key('phase6-canvas-paint'),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(
                                key: const Key('phase6-committed-paint'),
                                painter: _CanvasPainter(
                                  snapshot: committedDisplay,
                                  decodedImages: Map.unmodifiable(
                                    _decodedImages,
                                  ),
                                  paintBackground: true,
                                  savedBytes: _savedBytes,
                                  savedRoot: _savedRoot,
                                  currentRoot: _coordinator.snapshot.root,
                                  reopenedMaterializedRoot:
                                      _reopenedMaterializedRoot,
                                  previewPrimitiveCount: 0,
                                  eraserPathLength: 0,
                                  wholeSegmentCount: 0,
                                  wholeGeometryChecks: 0,
                                ),
                              ),
                            ),
                            if (_penFrozenPreviewChunks.isNotEmpty ||
                                _penActivePreviewPrimitives.isNotEmpty)
                              RepaintBoundary(
                                child: CustomPaint(
                                  painter: _PenPreviewPainter(
                                    pageClip: committed?.pageClip,
                                    frozen: List.unmodifiable(
                                      _penFrozenPreviewChunks,
                                    ),
                                    active: List.unmodifiable(
                                      _penActivePreviewPrimitives,
                                    ),
                                  ),
                                ),
                              ),
                            RepaintBoundary(
                              child: CustomPaint(
                                key: const Key('phase6-overlay-paint'),
                                painter: _CanvasPainter(
                                  snapshot: overlays,
                                  decodedImages: Map.unmodifiable(
                                    _decodedImages,
                                  ),
                                  paintBackground: false,
                                  savedBytes: _savedBytes,
                                  savedRoot: _savedRoot,
                                  currentRoot: _coordinator.snapshot.root,
                                  reopenedMaterializedRoot:
                                      _reopenedMaterializedRoot,
                                  previewPrimitiveCount: previews.length,
                                  eraserPathLength: _wholeEraserPath.length,
                                  wholeSegmentCount:
                                      _wholeEraserPlan?.processedSegmentCount ??
                                      0,
                                  wholeGeometryChecks:
                                      _wholeEraserPlan?.geometryCheckCount ?? 0,
                                ),
                              ),
                            ),
                            ValueListenableBuilder<ViewPoint?>(
                              valueListenable: _eraserCursor.position,
                              builder: (context, position, child) =>
                                  RepaintBoundary(
                                    child: CustomPaint(
                                      key: const Key('phase6-eraser-cursor'),
                                      painter: _EraserCursorPainter(
                                        position: position,
                                        onPainted: _diagnostics.enabled
                                            ? _eraserCursor.didPaint
                                            : null,
                                      ),
                                    ),
                                  ),
                            ),
                          ],
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
      shortcuts: const {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            const _UndoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyY, control: true):
            const _RedoIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const _CancelIntent(),
        const SingleActivator(LogicalKeyboardKey.keyP): const _PenIntent(),
        const SingleActivator(LogicalKeyboardKey.keyE): const _EraserIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV):
            const _SelectionIntent(),
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
              _cancelGesture('Cancelled');
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
        },
        child: Focus(
          autofocus: true,
          onFocusChange: (focused) {
            if (!focused && _router.ownership.owner != null) {
              _cancelGesture('Gesture cancelled');
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
    return List.unmodifiable([...eraserPreview, ...creation]);
  }

  List<ScenePrimitive> _creationPreview() {
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
    final preview = session?.previewTail;
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
    if (_penActivePreviewPrimitives.isNotEmpty &&
        _penActivePreviewPrimitives.length + result.length >
            _penPreviewChunkPrimitiveLimit) {
      final picture = _recordPenPicture(_penActivePreviewPrimitives);
      _pictureCreated();
      _penFrozenPreviewChunks.add(picture);
      _penActivePreviewPrimitives.clear();
    }
    _penActivePreviewPrimitives.addAll(result);
    _penPreviewPrimitiveCount += result.length;
    return true;
  }

  void _clearPenPreview() {
    for (final picture in _penFrozenPreviewChunks) {
      _disposePicture(picture);
    }
    _penFrozenPreviewChunks.clear();
    _penActivePreviewPrimitives.clear();
    _penPreviewPrimitiveCount = 0;
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
    _committedPage = page;
    _committedScene = built.value;
    return built.value;
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

  List<ScenePrimitive> _selectionPrimitives() {
    final result = <ScenePrimitive>[];
    final bounds = _selection.state.aggregateBounds;
    if (bounds != null) {
      final primitive = _selectionRectPrimitive(bounds);
      if (primitive != null) result.add(primitive);
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
      :final opacity,
      :final localToViewCoefficients,
    ):
      canvas.save();
      canvas.transform(_canvasMatrix(localToViewCoefficients));
      final box = Rect.fromLTWH(
        0,
        0,
        payload.bounds.width,
        payload.bounds.height,
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
      for (final paragraph in payload.paragraphs) {
        final paragraphStyle = paragraph.style;
        painters.add(
          TextPainter(
            text: TextSpan(
              children: [
                for (final run in paragraph.runs)
                  TextSpan(
                    text: run.text,
                    style: _flutterTextStyle(
                      run.style,
                      opacity,
                      lineHeight: paragraphStyle.lineHeight,
                    ),
                  ),
              ],
            ),
            textDirection: _flutterParagraphDirection(paragraph),
            textAlign: _flutterParagraphAlignment(paragraphStyle.alignment),
            locale: _flutterLocale(paragraphStyle.languageHint),
          )..layout(maxWidth: maximumWidth),
        );
      }
      final paintedHeight = painters.fold<double>(
        0,
        (height, painter) => height + painter.height,
      );
      var top = payload.padding.top;
      final availableHeight =
          payload.bounds.height - payload.padding.top - payload.padding.bottom;
      if (payload.verticalAlignment == TextVerticalAlignment.center) {
        top += math.max(0, (availableHeight - paintedHeight) / 2);
      } else if (payload.verticalAlignment == TextVerticalAlignment.bottom) {
        top += math.max(0, availableHeight - paintedHeight);
      }
      for (final painter in painters) {
        painter.paint(canvas, Offset(payload.padding.left, top));
        top += painter.height;
        painter.dispose();
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

TextStyle _flutterTextStyle(
  TextCharacterStyle style,
  double opacity, {
  double? lineHeight,
}) => TextStyle(
  fontFamily: style.preferredFontFamily,
  fontFamilyFallback: [_genericFontFamily(style.genericFontFamily)],
  fontSize: style.fontSize,
  fontWeight: FontWeight.values[((style.weight / 100).round() - 1).clamp(0, 8)],
  fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
  height: lineHeight,
  decoration: TextDecoration.combine([
    if (style.underline) TextDecoration.underline,
    if (style.strikethrough) TextDecoration.lineThrough,
  ]),
  color: Color(style.argb).withValues(alpha: opacity),
);

TextDirection _flutterParagraphDirection(TextParagraph paragraph) {
  if (paragraph.style.direction == TextParagraphDirection.rtl) {
    return TextDirection.rtl;
  }
  if (paragraph.style.direction == TextParagraphDirection.ltr) {
    return TextDirection.ltr;
  }
  for (final rune in paragraph.logicalText.runes) {
    if (rune >= 0x0590 && rune <= 0x08ff ||
        rune >= 0xfb1d && rune <= 0xfdff ||
        rune >= 0xfe70 && rune <= 0xfeff) {
      return TextDirection.rtl;
    }
    if (rune >= 0x0041 && rune <= 0x005a || rune >= 0x0061 && rune <= 0x007a) {
      return TextDirection.ltr;
    }
  }
  return TextDirection.ltr;
}

TextAlign _flutterParagraphAlignment(TextAlignment alignment) =>
    switch (alignment) {
      TextAlignment.left => TextAlign.left,
      TextAlignment.center => TextAlign.center,
      TextAlignment.right => TextAlign.right,
      TextAlignment.justified => TextAlign.justify,
      TextAlignment.start => TextAlign.start,
      TextAlignment.end => TextAlign.end,
    };

Locale? _flutterLocale(String? languageHint) {
  if (languageHint == null) return null;
  final parts = languageHint.split('-');
  if (parts.isEmpty || parts.first.isEmpty) return null;
  return parts.length > 1
      ? Locale(parts.first, parts.last)
      : Locale(parts.first);
}

String _genericFontFamily(TextGenericFontFamily family) => switch (family) {
  TextGenericFontFamily.sansSerif => 'sans-serif',
  TextGenericFontFamily.serif => 'serif',
  TextGenericFontFamily.monospace => 'monospace',
  TextGenericFontFamily.cursive => 'cursive',
  TextGenericFontFamily.fantasy => 'fantasy',
  TextGenericFontFamily.systemUi => 'system-ui',
};

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

final class _PenPreviewPainter extends CustomPainter {
  const _PenPreviewPainter({
    required this.pageClip,
    required this.frozen,
    required this.active,
  });

  final Rect2? pageClip;
  final List<ui.Picture> frozen;
  final List<ScenePrimitive> active;

  @override
  void paint(Canvas canvas, Size size) {
    final clip = pageClip;
    if (clip == null) return;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(clip.left, clip.top, clip.right, clip.bottom),
    );
    for (final picture in frozen) canvas.drawPicture(picture);
    for (final primitive in active) _paintPrimitive(canvas, primitive);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PenPreviewPainter old) =>
      old.pageClip != pageClip || old.frozen != frozen || old.active != active;
}

final class _CanvasPainter extends CustomPainter
    implements Phase6CanvasPersistenceEvidence {
  _CanvasPainter({
    required this.snapshot,
    required this.decodedImages,
    required this.paintBackground,
    required this.savedBytes,
    required this.savedRoot,
    required this.currentRoot,
    required this.reopenedMaterializedRoot,
    required this.previewPrimitiveCount,
    required this.eraserPathLength,
    required this.wholeSegmentCount,
    required this.wholeGeometryChecks,
  });
  final RenderSnapshot? snapshot;
  final Map<ImageDecodeCacheKey, FlutterDecodedImage> decodedImages;
  final bool paintBackground;
  final List<int>? savedBytes;
  final DocumentRoot? savedRoot;
  final DocumentRoot currentRoot;
  final DocumentRoot? reopenedMaterializedRoot;
  final int previewPrimitiveCount;
  final int eraserPathLength;
  final int wholeSegmentCount;
  final int wholeGeometryChecks;

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
    for (final primitive in scene.primitives) {
      _paintPrimitive(canvas, primitive, decodedImages: decodedImages);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.snapshot != snapshot ||
      old.paintBackground != paintBackground ||
      !mapEquals(old.decodedImages, decodedImages);

  @override
  SemanticsBuilderCallback get semanticsBuilder => (Size size) {
    final scene = snapshot;
    if (scene == null) return const <CustomPainterSemantics>[];
    final semantics = <CustomPainterSemantics>[];
    for (final primitive in scene.primitives) {
      final label = switch (primitive) {
        ImageBoxPrimitive(:final payload) =>
          payload.accessibilityAlternativeText,
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
  };

  @override
  bool shouldRebuildSemantics(covariant _CanvasPainter old) =>
      old.snapshot != snapshot;

  @override
  String toString() =>
      'CanvasPainter(previews: $previewPrimitiveCount, '
      'eraserPath: $eraserPathLength, wholeSegments: $wholeSegmentCount, '
      'wholeChecks: $wholeGeometryChecks)';
}

Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));
ShapeColor? _shapeColor(int argb) => ShapeColor.create(
  red: argb >> 16 & 0xff,
  green: argb >> 8 & 0xff,
  blue: argb & 0xff,
  alpha: argb >> 24 & 0xff,
).fold<ShapeColor?>(onOk: (value) => value, onErr: (_) => null);
bool _sameObjectIds(Set<ObjectId> first, Set<ObjectId> second) =>
    first.length == second.length && first.every(second.contains);
ViewPoint _viewPoint(double x, double y) => _ok(ViewPoint.create(x: x, y: y));
ToolId _toolId(_CanvasTool tool) =>
    _ok(ToolId.parse('alnote.tools.${tool.name.toLowerCase()}'));
InteractionActionId _actionId(_CanvasTool tool) =>
    _ok(InteractionActionId.parse('alnote.actions.${tool.name.toLowerCase()}'));
Revision _revision(int v) => _ok(Revision.create(v));
T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;

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

final class _TextEditorDialog extends StatefulWidget {
  const _TextEditorDialog({
    required this.initial,
    required this.editing,
    required this.onDraftChanged,
  });

  final _TextDialogResult initial;
  final bool editing;
  final ValueChanged<_TextDialogResult> onDraftChanged;

  @override
  State<_TextEditorDialog> createState() => _TextEditorDialogState();
}

final class _TextEditorDialogState extends State<_TextEditorDialog> {
  late final TextEditingController _controller;
  late double _fontSize;
  late bool _bold;
  late bool _italic;
  late TextAlignment _alignment;
  late int _argb;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _controller = TextEditingController(text: initial.text)
      ..addListener(_notifyDraft);
    _fontSize = initial.fontSize;
    _bold = initial.bold;
    _italic = initial.italic;
    _alignment = initial.alignment;
    _argb = initial.argb;
  }

  _TextDialogResult get _draft => _TextDialogResult(
    text: _controller.text,
    fontSize: _fontSize,
    bold: _bold,
    italic: _italic,
    alignment: _alignment,
    argb: _argb,
  );

  void _notifyDraft() => widget.onDraftChanged(_draft);

  void _update(VoidCallback change) {
    setState(change);
    _notifyDraft();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_notifyDraft)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing ? 'Edit text box' : 'Create text box'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('text-object-editor'),
              controller: _controller,
              autofocus: true,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'Text'),
            ),
            Row(
              children: [
                const Text('Size'),
                Expanded(
                  child: Slider(
                    value: _fontSize,
                    min: 8,
                    max: 72,
                    divisions: 64,
                    onChanged: (value) => _update(() => _fontSize = value),
                  ),
                ),
                Text('${_fontSize.round()}'),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                FilterChip(
                  label: const Text('Bold'),
                  selected: _bold,
                  onSelected: (value) => _update(() => _bold = value),
                ),
                FilterChip(
                  label: const Text('Italic'),
                  selected: _italic,
                  onSelected: (value) => _update(() => _italic = value),
                ),
                DropdownButton<TextAlignment>(
                  value: _alignment,
                  items: TextAlignment.values
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.name),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) _update(() => _alignment = value);
                  },
                ),
                DropdownButton<int>(
                  value: _argb,
                  items: const [
                    DropdownMenuItem(value: 0xff17324d, child: Text('Navy')),
                    DropdownMenuItem(value: 0xff111111, child: Text('Black')),
                    DropdownMenuItem(value: 0xffb42318, child: Text('Red')),
                  ],
                  onChanged: (value) {
                    if (value != null) _update(() => _argb = value);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _draft),
        child: Text(widget.editing ? 'Save' : 'Add'),
      ),
    ],
  );
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
