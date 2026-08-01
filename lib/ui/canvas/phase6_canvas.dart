// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
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

/// Accessible Phase 6 Canvas vertical-slice experience.
final class Phase6Canvas extends StatefulWidget {
  /// Creates the Canvas.
  const Phase6Canvas({required this.runtime, super.key});

  /// Explicit production or test runtime dependencies.
  final Phase6CanvasRuntime runtime;
  @override
  State<Phase6Canvas> createState() => _Phase6CanvasState();
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
  PenGestureSession? _pen;
  _CanvasTool _tool = _CanvasTool.pen;
  final List<Point2> _partialEraserPath = [];
  final List<Point2> _wholeEraserPath = [];
  ScenePrimitive? _eraserPreviewPrimitive;
  final Map<ObjectId, Set<StrokeId>> _wholeEraserTargets = {};
  int _wholeEraserTargetCount = 0;
  DocumentCoordinatorSnapshot? _wholeEraserBase;
  DocumentCoordinatorSnapshot? _partialEraserBase;
  List<int>? _savedBytes;
  DocumentRoot? _savedRoot;
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
    setState(() {
      _pen = null;
      _partialEraserPath.clear();
      _wholeEraserPath.clear();
      _wholeEraserTargets.clear();
      _wholeEraserTargetCount = 0;
      _wholeEraserBase = null;
      _partialEraserBase = null;
      _eraserPreviewPrimitive = null;
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
          setState(() {
            _pen = started.value;
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
        _pointAction(pagePoint, routedTool);
      }
    } else if (_pen != null &&
        routedTool == _CanvasTool.pen &&
        event.phase == PointerPhase.move) {
      final updated = _pen!.update(event, viewportRevision: _viewport.revision);
      if (updated is Err<void, StructuredFailure>) {
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
        });
      } else {
        setState(() {
          _status = 'Stroke rejected';
          _pen = null;
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
    } else if (event.phase == PointerPhase.up) {
      _router.completeTerminal(event.pointerId);
    } else if (event.phase == PointerPhase.cancel) {
      _cancelGesture('Gesture cancelled');
    }
  }

  void _beginPartialErase(Point2 point) {
    _partialEraserPath.clear();
    _eraserPreviewPrimitive = null;
    _partialEraserBase = _coordinator.snapshot;
    if (!_appendPartialEraserPoint(point, publish: false)) return;
    setState(() => _status = 'Partial erasing');
  }

  bool _appendPartialEraserPoint(Point2 point, {bool publish = true}) {
    if (_partialEraserBase?.currentContentIdentity !=
            _coordinator.snapshot.currentContentIdentity ||
        _partialEraserPath.length >= widget.runtime.maximumEraserPoints) {
      _cancelGesture('Partial erase rejected');
      return false;
    }
    final previous = _partialEraserPath.lastOrNull;
    if (!_appendEraserPreview(previous ?? point, point)) {
      _cancelGesture('Partial erase rejected');
      return false;
    }
    _partialEraserPath.add(point);
    if (publish && mounted) setState(() {});
    return true;
  }

  void _beginWholeErase(Point2 point) {
    _wholeEraserPath.clear();
    _wholeEraserTargets.clear();
    _wholeEraserTargetCount = 0;
    _eraserPreviewPrimitive = null;
    _wholeEraserBase = _coordinator.snapshot;
    if (!_appendWholeEraserPoint(point, publish: false)) return;
    setState(() => _status = 'Whole erasing');
  }

  bool _appendWholeEraserPoint(Point2 point, {bool publish = true}) {
    final base = _wholeEraserBase;
    if (base == null ||
        base.currentContentIdentity !=
            _coordinator.snapshot.currentContentIdentity ||
        _wholeEraserPath.length >= widget.runtime.maximumEraserPoints) {
      _cancelGesture('Erase rejected');
      return false;
    }
    final previous = _wholeEraserPath.lastOrNull;
    if (!_appendEraserPreview(previous ?? point, point) ||
        !_collectWholeEraseHits(previous, point)) {
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

  bool _collectWholeEraseHits(Point2? previous, Point2 point) {
    final hits = <HitTestResult>[];
    final pointHits = _hitTester.point(
      page: _page,
      pagePosition: point,
      pageTolerance: 8 / _viewport.zoom,
    );
    if (pointHits is Err<HitTestResult?, StructuredFailure>) return false;
    final pointHit = (pointHits as Ok<HitTestResult?, StructuredFailure>).value;
    if (pointHit != null) hits.add(pointHit);
    if (previous != null && previous != point) {
      final dx = point.x - previous.x, dy = point.y - previous.y;
      final length = math.sqrt(dx * dx + dy * dy);
      if (!length.isFinite || length == 0) return false;
      final radius = 8 / _viewport.zoom;
      final nx = -dy / length * radius, ny = dx / length * radius;
      final polygon = <Point2>[
        _point(previous.x + nx, previous.y + ny),
        _point(point.x + nx, point.y + ny),
        _point(point.x - nx, point.y - ny),
        _point(previous.x - nx, previous.y - ny),
      ];
      final swept = _hitTester.lasso(
        page: _page,
        polygon: polygon,
        mode: AreaHitMode.intersection,
      );
      if (swept is Err<List<HitTestResult>, StructuredFailure>) return false;
      hits.addAll((swept as Ok<List<HitTestResult>, StructuredFailure>).value);
    }
    for (final hit in hits) {
      final stroke = hit.strokeId;
      if (stroke == null) continue;
      final targets = _wholeEraserTargets.putIfAbsent(hit.objectId, () => {});
      if (targets.contains(stroke)) continue;
      if (_wholeEraserTargetCount >= widget.runtime.maximumHitResults) {
        return false;
      }
      targets.add(stroke);
      _wholeEraserTargetCount += 1;
    }
    return true;
  }

  void _pointAction(Point2 pagePoint, _CanvasTool routedTool) {
    final hit = _hitTester
        .point(
          page: _page,
          pagePosition: pagePoint,
          pageTolerance: 8 / _viewport.zoom,
        )
        .fold<HitTestResult?>(onOk: (v) => v, onErr: (_) => null);
    if (routedTool == _CanvasTool.selection) {
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
      return;
    }
  }

  void _finishWholeErase() {
    final base = _wholeEraserBase;
    final noHits =
        base != null &&
        base.currentContentIdentity ==
            _coordinator.snapshot.currentContentIdentity &&
        _wholeEraserTargets.isEmpty;
    Result<AtomicObjectCollectionEditRequest, StructuredFailure>? request;
    if (base != null &&
        base.currentContentIdentity ==
            _coordinator.snapshot.currentContentIdentity &&
        _wholeEraserTargets.isNotEmpty &&
        _wholeEraserTargets.length <= widget.runtime.maximumCommandOperations) {
      final page = base.root.pages
          .where((value) => value.id == _page.id)
          .firstOrNull;
      final replacements = <ObjectEnvelope>[];
      final removals = <ObjectId>[];
      final objectRevisions = <ObjectId, Revision>{};
      final membershipRevisions = <LayerId, Revision>{};
      var valid = page != null;
      if (page != null) {
        for (final layer in page.layers.whereType<ContentLayer>()) {
          for (final object in layer.objects) {
            final erased = _wholeEraserTargets[object.id];
            if (erased == null) continue;
            final payload =
                HandwritingPayload.decode(
                  object.payload,
                  limits: _limits,
                ).fold<HandwritingPayload?>(
                  onOk: (value) => value,
                  onErr: (_) => null,
                );
            final objectRevision = base.revisions.objects[object.id];
            final membershipRevision = base.revisions.layerMembership[layer.id];
            if (payload == null ||
                objectRevision == null ||
                membershipRevision == null ||
                !payload.strokes
                    .map((value) => value.id)
                    .toSet()
                    .containsAll(erased)) {
              valid = false;
              break;
            }
            final survivors = payload.strokes
                .where((stroke) => !erased.contains(stroke.id))
                .toList(growable: false);
            objectRevisions[object.id] = objectRevision;
            membershipRevisions[layer.id] = membershipRevision;
            if (survivors.isEmpty) {
              removals.add(object.id);
              continue;
            }
            final nextPayload = HandwritingPayload.create(
              strokes: survivors,
              limits: _limits,
              unknownFields: payload.unknownFields,
            );
            if (nextPayload is! Ok<HandwritingPayload, StructuredFailure>) {
              valid = false;
              break;
            }
            final replacement = ObjectEnvelope.create(
              id: object.id,
              typeKey: object.typeKey,
              envelopeVersion: object.envelopeVersion,
              typeSchemaVersion: object.typeSchemaVersion,
              transform: object.transform,
              visible: object.visible,
              locked: object.locked,
              payload: nextPayload.value.encode(),
              extensionData: object.extensionData,
            );
            if (replacement is! Ok<ObjectEnvelope, StructuredFailure>) {
              valid = false;
              break;
            }
            replacements.add(replacement.value);
          }
          if (!valid) break;
        }
      }
      if (valid &&
          replacements.length + removals.length == _wholeEraserTargets.length) {
        Result<UuidIdentifier, StructuredFailure>? correlation;
        try {
          correlation = _uuid.generateV4();
        } on Object {
          correlation = null;
        }
        if (correlation is Ok<UuidIdentifier, StructuredFailure>) {
          request = AtomicObjectCollectionEditRequest.create(
            documentId: base.root.id,
            metadata: CommandMetadata(
              family: CommandFamily.objectCollectionEdit,
              correlationId: CommandCorrelationId.fromUuid(correlation.value),
              description: 'Erase strokes',
            ),
            preconditions: RevisionPreconditions(
              pages: {_page.id: base.revisions.pages[_page.id]!},
              objects: objectRevisions,
              layerMembership: membershipRevisions,
            ),
            pageId: _page.id,
            removals: removals,
            replacements: replacements,
            replacementChangeCategories: ObjectReplacementChangeCategories(
              geometry: replacements.isNotEmpty,
              appearance: false,
              text: false,
              metadata: replacements.isNotEmpty,
            ),
            maximumOperations: widget.runtime.maximumCommandOperations,
          );
        }
      }
    }
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
    final base = _partialEraserBase;
    final request =
        base == null ||
            base.currentContentIdentity !=
                _coordinator.snapshot.currentContentIdentity
        ? Err<AtomicObjectCollectionEditRequest, StructuredFailure>(
            StructuredFailure(
              code: 'ui.canvas.partial_erase_stale',
              category: FailureCategory.state,
              retryDisposition: RetryDisposition.never,
              message: 'Partial erase input is no longer current.',
            ),
          )
        : createPartialEraseRequest(
            document: base,
            pageId: _page.id,
            pagePath: List<Point2>.of(_partialEraserPath),
            pageRadius: 8 / _viewport.zoom,
            uuidGenerator: _uuid,
            handwritingLimits: _limits,
            geometryResolver: _geometry,
            maximumEraserPoints: widget.runtime.maximumEraserPoints,
            maximumIntersections: widget.runtime.maximumEraserIntersections,
            maximumFragments: widget.runtime.maximumEraserFragments,
            maximumOutputSamples: widget.runtime.maximumEraserOutputSamples,
            maximumCommandOperations: widget.runtime.maximumCommandOperations,
          );
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
    setState(() {
      _pen = null;
      _status = status;
    });
  }

  void _clearEraserTransient() {
    _partialEraserPath.clear();
    _wholeEraserPath.clear();
    _wholeEraserTargets.clear();
    _wholeEraserTargetCount = 0;
    _eraserPreviewPrimitive = null;
    _wholeEraserBase = null;
    _partialEraserBase = null;
  }

  void _zoom(double factor) {
    if (_pen != null) return;
    final pivot = _viewPoint(
      _viewport.extent.width / 2,
      _viewport.extent.height / 2,
    );
    final result = _viewport.zoomedAbout(
      newZoom: (_viewport.zoom * factor).clamp(
        _viewport.minimumZoom,
        _viewport.maximumZoom,
      ),
      viewPivot: pivot,
      expectedRevision: _viewport.revision,
    );
    if (result is Ok<ViewportSnapshot, StructuredFailure>) {
      final published = _viewportController.publish(result.value);
      if (published is! Ok<ViewportSnapshot, StructuredFailure>) return;
      setState(() {
        _viewport = published.value;
        _status = 'Zoom ${(_viewport.zoom * 100).round()}%';
      });
    }
  }

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
          _status = 'Saved ${bytes.value.length} bytes';
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
    if (bytes == null) {
      setState(() => _status = 'Save first');
      return;
    }
    final opened = AlnotePackageReader(objectRegistry: _registry).openBytes(
      bytes,
      limits: widget.runtime.storageLimits,
      cancellationToken: CancellationController().token,
    );
    if (opened is Completed<OpenedAlnotePackage, StructuredFailure>) {
      final materialized = opened.value.materializeDocument(
        cancellationToken: CancellationController().token,
      );
      if (materialized is Completed<DocumentRoot, StructuredFailure> &&
          materialized.value == _savedRoot) {
        setState(() {
          final reopened = widget.runtime.createCoordinator(materialized.value);
          if (reopened is! Ok<DocumentMutationCoordinator, CommandFailure>) {
            _status = 'Reopen failed';
            return;
          }
          _coordinator = reopened.value;
          _selection = SelectionController(
            objectRegistry: _registry,
            coalescingBoundarySink: _coordinator,
            maximumTargets: widget.runtime.maximumSelectionTargets,
            handwritingLimits: _limits,
            strokeGeometryResolver: _geometry,
          );
          _pen = null;
          _router.cancel();
          _partialEraserPath.clear();
          _status = 'Reopened identical content';
        });
        return;
      }
    }
    setState(() => _status = 'Reopen failed');
  }

  @override
  Widget build(BuildContext context) {
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
      IconButton(
        tooltip: 'Undo',
        onPressed: _coordinator.snapshot.canUndo ? _undo : null,
        icon: const Icon(Icons.undo),
      ),
      IconButton(
        tooltip: 'Redo',
        onPressed: _coordinator.snapshot.canRedo ? _redo : null,
        icon: const Icon(Icons.redo),
      ),
      TextButton(onPressed: _save, child: const Text('Save')),
      TextButton(onPressed: _reopen, child: const Text('Reopen')),
      IconButton(
        tooltip: 'Zoom out',
        onPressed: _pen == null ? () => _zoom(1 / 1.2) : null,
        icon: const Icon(Icons.zoom_out),
      ),
      IconButton(
        tooltip: 'Zoom in',
        onPressed: _pen == null ? () => _zoom(1.2) : null,
        icon: const Icon(Icons.zoom_in),
      ),
    ];
    final previews = _previewPrimitives();
    final scene = _sceneBuilder
        .build(
          page: _page,
          viewport: _viewport,
          documentRevision: _coordinator.snapshot.revisions.document,
          previews: previews,
          selections: _selectionPrimitives(),
        )
        .fold<RenderSnapshot?>(onOk: (value) => value, onErr: (_) => null);
    final canvas = Semantics(
      label: 'Handwriting canvas',
      container: true,
      child: Listener(
        key: const Key('phase6-canvas-listener'),
        onPointerDown: _pointer,
        onPointerMove: _pointer,
        onPointerUp: _pointer,
        onPointerCancel: _pointer,
        child: RepaintBoundary(
          key: const Key('phase6-canvas-paint'),
          child: CustomPaint(
            size: const Size(640, 800),
            painter: _CanvasPainter(
              snapshot: scene,
              previewPrimitiveCount: previews.length,
              eraserPathLength: math.max(
                _partialEraserPath.length,
                _wholeEraserPath.length,
              ),
            ),
          ),
        ),
      ),
    );
    final scaffold = Scaffold(
      appBar: AppBar(title: const Text('AL NOTE')),
      body: Column(
        children: [
          Wrap(spacing: 6, children: controls),
          Expanded(child: Center(child: canvas)),
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
    final eraserPreview = eraser == null
        ? const <ScenePrimitive>[]
        : <ScenePrimitive>[eraser];
    final preview = _pen?.preview;
    if (preview == null || preview.samples.isEmpty) {
      return eraserPreview;
    }
    final identity = AffineTransform2D.fromOperation(
      const IdentityTransformOperation2D(),
    ).fold<AffineTransform2D?>(onOk: (value) => value, onErr: (_) => null);
    if (identity == null) {
      return eraserPreview;
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
      return eraserPreview;
    }
    final result = <ScenePrimitive>[...eraserPreview];
    for (final element in geometry.elements) {
      final points = <Point2>[];
      for (final pagePoint in element.vertices) {
        final view = _viewport
            .pageToView(pagePoint)
            .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
        if (view == null) return List<ScenePrimitive>.unmodifiable(result);
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
        return List<ScenePrimitive>.unmodifiable(result);
      }
      result.add(primitive.value);
    }
    return result;
  }

  List<ScenePrimitive> _selectionPrimitives() {
    final bounds = _selection.state.aggregateBounds;
    if (bounds == null) return const [];
    final first = _viewport
        .pageToView(bounds.topLeft)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    final second = _viewport
        .pageToView(bounds.bottomRight)
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    if (first == null || second == null) return const [];
    final viewBounds = Rect2.fromEdges(
      left: first.x < second.x ? first.x : second.x,
      top: first.y < second.y ? first.y : second.y,
      right: first.x > second.x ? first.x : second.x,
      bottom: first.y > second.y ? first.y : second.y,
    ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
    if (viewBounds == null) return const [];
    return PlaceholderPrimitive.create(
      plane: RenderPlane.selection,
      bounds: viewBounds,
      opacity: 1,
    ).fold<List<ScenePrimitive>>(
      onOk: (value) => [value],
      onErr: (_) => const [],
    );
  }
}

final class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.snapshot,
    required this.previewPrimitiveCount,
    required this.eraserPathLength,
  });
  final RenderSnapshot? snapshot;
  final int previewPrimitiveCount;
  final int eraserPathLength;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xffd9dde2),
    );
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
    canvas.drawRect(clip, Paint()..color = Colors.white);
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
  bool shouldRepaint(covariant _CanvasPainter old) => old.snapshot != snapshot;

  @override
  String toString() =>
      'CanvasPainter(previews: $previewPrimitiveCount, '
      'eraserPath: $eraserPathLength)';
}

Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));
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
