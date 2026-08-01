// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
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
import 'phase6_canvas_runtime.dart';

enum _CanvasTool { pen, wholeEraser, partialEraser, selection }

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

  /// Partial-Eraser segments accepted by the current gesture plan.
  int get partialSegmentCount;

  /// Partial-Eraser cached geometry classifications performed by the plan.
  int get partialSplitCalls;
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
  CommittedPageScene? _committedScene;
  DocumentPage? _committedPage;
  CommittedPageScene? _committedDisplaySource;
  RenderSnapshot? _committedDisplay;
  Set<ObjectId> _committedDisplayExclusions = const {};
  PenGestureSession? _pen;
  final List<RenderSnapshot> _penFrozenPreviewChunks = [];
  final List<ScenePrimitive> _penActivePreviewPrimitives = [];
  int _penPreviewPrimitiveCount = 0;
  final Map<ObjectId, Map<(StrokeId, int), RenderSnapshot>>
  _partialEraserPreviewSegments = {};
  _CanvasTool _tool = _CanvasTool.pen;
  final List<Point2> _partialEraserPath = [];
  final List<Point2> _wholeEraserPath = [];
  ScenePrimitive? _eraserPreviewPrimitive;
  final Map<ObjectId, List<ScenePrimitive>> _eraserObjectPreviews = {};
  WholeEraseGesturePlan? _wholeEraserPlan;
  PartialEraseGesturePlan? _partialEraserPlan;
  Point2? _selectionDown;
  Point2? _selectionCurrent;
  List<int>? _savedBytes;
  DocumentRoot? _savedRoot;
  DocumentRoot? _reopenedMaterializedRoot;
  String _status = 'Ready';

  HandwritingLimits get _limits => widget.runtime.handwritingLimits;
  UuidGenerator get _uuid => widget.runtime.uuidGenerator;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
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
    if (state != AppLifecycleState.resumed && _router.ownership.owner != null) {
      _cancelGesture('Gesture cancelled');
    }
  }

  DocumentPage get _page => _coordinator.snapshot.root.pages.single;
  LayerId get _layerId => _page.layers.whereType<ContentLayer>().first.id;

  void _setTool(_CanvasTool value) {
    if (!_toolRegistry.definitions.containsKey(_toolId(value))) return;
    _pen?.cancel();
    _router.cancel();
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
        final style = _ok(
          StrokeStyle.create(
            argb: 0xff17324d,
            opacity: 1,
            baseWidth: 3,
            pressureInfluence: .65,
            minimumPressureFactor: .2,
            limits: _limits,
          ),
        );
        final started = PenGestureSession.start(
          down: event,
          document: _coordinator.snapshot,
          pageId: _page.id,
          layerId: _layerId,
          viewport: _viewport,
          preset: PenPreset.fromStyle(style),
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
      } else if (routedTool == _CanvasTool.partialEraser) {
        _beginPartialErase(pagePoint);
      } else if (routedTool == _CanvasTool.wholeEraser) {
        _beginWholeErase(pagePoint);
      } else {
        _beginSelection(pagePoint);
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
    } else if (routedTool == _CanvasTool.partialEraser &&
        event.phase == PointerPhase.move) {
      if (!_appendPartialEraserPoint(pagePoint)) return;
    } else if (routedTool == _CanvasTool.wholeEraser &&
        event.phase == PointerPhase.move) {
      if (!_appendWholeEraserPoint(pagePoint)) return;
    } else if (routedTool == _CanvasTool.selection &&
        event.phase == PointerPhase.move) {
      _updateSelection(pagePoint);
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
    } else if (routedTool == _CanvasTool.partialEraser &&
        event.phase == PointerPhase.up) {
      if (!_appendPartialEraserPoint(pagePoint, publish: false)) return;
      _finishPartialErase();
      _router.completeTerminal(event.pointerId);
    } else if (routedTool == _CanvasTool.wholeEraser &&
        event.phase == PointerPhase.up) {
      if (!_appendWholeEraserPoint(pagePoint, publish: false)) return;
      _finishWholeErase();
      _router.completeTerminal(event.pointerId);
    } else if (routedTool == _CanvasTool.selection &&
        event.phase == PointerPhase.up) {
      _finishSelection(pagePoint);
      _router.completeTerminal(event.pointerId);
    } else if (event.phase == PointerPhase.up) {
      _router.completeTerminal(event.pointerId);
    } else if (event.phase == PointerPhase.cancel) {
      _cancelGesture('Gesture cancelled');
    }
  }

  void _beginPartialErase(Point2 point) {
    _clearEraserTransient();
    final prepared = PartialEraseGesturePlan.prepare(
      document: _coordinator.snapshot,
      pageId: _page.id,
      radius: 8 / _viewport.zoom,
      handwritingLimits: _limits,
      objectRegistry: _registry,
      geometryResolver: _geometry,
      geometryCache: widget.runtime.geometryCache,
      maximumObjects: widget.runtime.maximumHitResults,
      maximumStrokes: _limits.maximumStrokes,
      maximumPoints: widget.runtime.maximumEraserPoints,
      maximumIntersections: widget.runtime.maximumEraserIntersections,
      maximumFragments: widget.runtime.maximumEraserFragments,
      maximumOutputSamples: widget.runtime.maximumEraserOutputSamples,
      maximumOperations: widget.runtime.maximumCommandOperations,
    );
    if (prepared is! Ok<PartialEraseGesturePlan, StructuredFailure>) {
      _cancelGesture('Partial erase rejected');
      return;
    }
    _partialEraserPlan = prepared.value;
    if (!_appendPartialEraserPoint(point, publish: false)) return;
    setState(() => _status = 'Partial erasing');
  }

  bool _appendPartialEraserPoint(Point2 point, {bool publish = true}) {
    final plan = _partialEraserPlan;
    if (plan == null || !plan.isCurrent(_coordinator.snapshot)) {
      _cancelGesture('Partial erase rejected');
      return false;
    }
    final update = plan.acceptPoint(point);
    if (update is! Ok<EraserGestureUpdate, StructuredFailure> ||
        !_appendEraserPreview(point, point) ||
        !_refreshPartialEraserPreviewSegments(
          update.value.previewSegmentUpdates,
        )) {
      _cancelGesture('Partial erase rejected');
      return false;
    }
    _partialEraserPath.add(point);
    if (publish && mounted) setState(() {});
    return true;
  }

  void _beginWholeErase(Point2 point) {
    _clearEraserTransient();
    final prepared = WholeEraseGesturePlan.prepare(
      document: _coordinator.snapshot,
      pageId: _page.id,
      radius: 8 / _viewport.zoom,
      handwritingLimits: _limits,
      objectRegistry: _registry,
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

  bool _refreshPartialEraserPreviewSegments(
    List<EraserPreviewSegmentUpdate> updates,
  ) {
    final committed = _committedSceneForCurrentInputs();
    if (committed == null) return false;
    for (final update in updates) {
      final color = RenderColor.create(update.style.argb);
      if (color is! Ok<RenderColor, StructuredFailure>) return false;
      final primitives = <ScenePrimitive>[];
      for (final element in update.elements) {
        final points = <Point2>[];
        for (final pagePoint in element.vertices) {
          final view = _viewport.pageToView(pagePoint);
          if (view is! Ok<ViewPoint, StructuredFailure>) return false;
          points.add(_point(view.value.x, view.value.y));
        }
        final primitive = FilledPolygonPrimitive.create(
          plane: RenderPlane.toolPreview,
          opacity: update.style.opacity,
          color: color.value,
          points: points,
          maximumPoints: _sceneBuilder.limits.maximumPointsPerPrimitive,
        );
        if (primitive is! Ok<FilledPolygonPrimitive, StructuredFailure>) {
          return false;
        }
        primitives.add(primitive.value);
      }
      final snapshot = _sceneBuilder.composeOverlays(
        committed: committed,
        previews: primitives,
      );
      if (snapshot is! Ok<RenderSnapshot, StructuredFailure>) return false;
      _partialEraserPreviewSegments.putIfAbsent(
        update.objectId,
        () => {},
      )[(update.strokeId, update.sourceSegment)] = snapshot.value;
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

  void _finishPartialErase() {
    final plan = _partialEraserPlan;
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
          ? 'Stroke partially erased'
          : 'Partial erase rejected',
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
      _status = status;
    });
  }

  void _clearEraserTransient() {
    _partialEraserPath.clear();
    _wholeEraserPath.clear();
    _eraserObjectPreviews.clear();
    _partialEraserPreviewSegments.clear();
    _eraserPreviewPrimitive = null;
    _wholeEraserPlan = null;
    _partialEraserPlan = null;
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
      resources: const [],
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
                        ..._partialEraserPreviewSegments.keys,
                      });
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
                                  partialSegmentCount: 0,
                                  partialSplitCalls: 0,
                                ),
                              ),
                            ),
                            for (final chunk in _penFrozenPreviewChunks)
                              RepaintBoundary(
                                child: CustomPaint(
                                  painter: _CanvasPainter(
                                    snapshot: chunk,
                                    paintBackground: false,
                                    savedBytes: _savedBytes,
                                    savedRoot: _savedRoot,
                                    currentRoot: _coordinator.snapshot.root,
                                    reopenedMaterializedRoot:
                                        _reopenedMaterializedRoot,
                                    previewPrimitiveCount:
                                        chunk.primitives.length,
                                    eraserPathLength: 0,
                                    wholeSegmentCount: 0,
                                    wholeGeometryChecks: 0,
                                    partialSegmentCount: 0,
                                    partialSplitCalls: 0,
                                  ),
                                ),
                              ),
                            for (final object
                                in _partialEraserPreviewSegments.values)
                              for (final segment in object.values)
                                RepaintBoundary(
                                  child: CustomPaint(
                                    painter: _CanvasPainter(
                                      snapshot: segment,
                                      paintBackground: false,
                                      savedBytes: _savedBytes,
                                      savedRoot: _savedRoot,
                                      currentRoot: _coordinator.snapshot.root,
                                      reopenedMaterializedRoot:
                                          _reopenedMaterializedRoot,
                                      previewPrimitiveCount:
                                          segment.primitives.length,
                                      eraserPathLength: 0,
                                      wholeSegmentCount: 0,
                                      wholeGeometryChecks: 0,
                                      partialSegmentCount: 0,
                                      partialSplitCalls: 0,
                                    ),
                                  ),
                                ),
                            RepaintBoundary(
                              child: CustomPaint(
                                key: const Key('phase6-overlay-paint'),
                                painter: _CanvasPainter(
                                  snapshot: overlays,
                                  paintBackground: false,
                                  savedBytes: _savedBytes,
                                  savedRoot: _savedRoot,
                                  currentRoot: _coordinator.snapshot.root,
                                  reopenedMaterializedRoot:
                                      _reopenedMaterializedRoot,
                                  previewPrimitiveCount: previews.length,
                                  eraserPathLength: math.max(
                                    _partialEraserPath.length,
                                    _wholeEraserPath.length,
                                  ),
                                  wholeSegmentCount:
                                      _wholeEraserPlan?.processedSegmentCount ??
                                      0,
                                  wholeGeometryChecks:
                                      _wholeEraserPlan?.geometryCheckCount ?? 0,
                                  partialSegmentCount:
                                      _partialEraserPlan
                                          ?.processedSegmentCount ??
                                      0,
                                  partialSplitCalls:
                                      _partialEraserPlan
                                          ?.splitInvocationCount ??
                                      0,
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
    return List.unmodifiable([
      ...eraserPreview,
      ..._penActivePreviewPrimitives,
    ]);
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
    for (final element in geometry.elements) {
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
        opacity: preview.style.opacity * .55,
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
      final committed = _committedSceneForCurrentInputs();
      if (committed == null) return false;
      final frozen = _sceneBuilder.composeOverlays(
        committed: committed,
        previews: _penActivePreviewPrimitives,
      );
      if (frozen is! Ok<RenderSnapshot, StructuredFailure>) return false;
      _penFrozenPreviewChunks.add(frozen.value);
      _penActivePreviewPrimitives.clear();
    }
    _penActivePreviewPrimitives.addAll(result);
    _penPreviewPrimitiveCount += result.length;
    return true;
  }

  void _clearPenPreview() {
    _penFrozenPreviewChunks.clear();
    _penActivePreviewPrimitives.clear();
    _penPreviewPrimitiveCount = 0;
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

final class _CanvasPainter extends CustomPainter
    implements Phase6CanvasPersistenceEvidence {
  _CanvasPainter({
    required this.snapshot,
    required this.paintBackground,
    required this.savedBytes,
    required this.savedRoot,
    required this.currentRoot,
    required this.reopenedMaterializedRoot,
    required this.previewPrimitiveCount,
    required this.eraserPathLength,
    required this.wholeSegmentCount,
    required this.wholeGeometryChecks,
    required this.partialSegmentCount,
    required this.partialSplitCalls,
  });
  final RenderSnapshot? snapshot;
  final bool paintBackground;
  final List<int>? savedBytes;
  final DocumentRoot? savedRoot;
  final DocumentRoot currentRoot;
  final DocumentRoot? reopenedMaterializedRoot;
  final int previewPrimitiveCount;
  final int eraserPathLength;
  final int wholeSegmentCount;
  final int wholeGeometryChecks;
  final int partialSegmentCount;
  final int partialSplitCalls;

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
      switch (primitive) {
        case FilledPolygonPrimitive(
          :final points,
          :final color,
          :final opacity,
        ):
          final path = Path()..moveTo(points.first.x, points.first.y);
          for (final point in points.skip(1)) path.lineTo(point.x, point.y);
          path.close();
          canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.fill
              ..color = Color(color.argb).withValues(alpha: opacity),
          );
        case PlaceholderPrimitive(:final plane, :final bounds, :final opacity):
          canvas.drawRect(
            Rect.fromLTRB(bounds.left, bounds.top, bounds.right, bounds.bottom),
            Paint()
              ..color =
                  (plane == RenderPlane.selection ? Colors.blue : Colors.grey)
                      .withValues(alpha: opacity)
              ..style = PaintingStyle.stroke
              ..strokeWidth = plane == RenderPlane.selection ? 2 : 1,
          );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.snapshot != snapshot || old.paintBackground != paintBackground;

  @override
  String toString() =>
      'CanvasPainter(previews: $previewPrimitiveCount, '
      'eraserPath: $eraserPathLength, wholeSegments: $wholeSegmentCount, '
      'wholeChecks: $wholeGeometryChecks, partialSegments: '
      '$partialSegmentCount, partialSplits: $partialSplitCalls)';
}

Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));
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
