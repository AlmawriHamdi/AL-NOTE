// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';

import 'package:al_note/core/interaction.dart';
import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/hit_testing.dart';
import 'package:al_note/drawing/renderer.dart';
import 'package:al_note/drawing/selection.dart';
import 'package:al_note/drawing/tools.dart';
import 'package:al_note/drawing/viewport.dart';
import 'package:al_note/ui/canvas/phase6_canvas_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/phase3_test_support.dart';
import '../support/uuid_sequence_generator.dart';

final _limits = _ok(
  HandwritingLimits.create(
    maximumStrokes: 8,
    maximumSamplesPerStroke: 16,
    maximumUnknownFields: 8,
    maximumNestingDepth: 8,
    maximumUnknownNodes: 1024,
    maximumCoordinateMagnitude: 10000,
    maximumStrokeWidth: 100,
    maximumAbsoluteTilt: 2,
    maximumAbsoluteOrientation: 7,
  ),
);

void main() {
  test('viewport conversions round trip and zoom preserves pivot', () {
    final view = _viewport();
    final page = _point(23, 44);
    final screen = _ok(view.pageToView(page));
    expect(_ok(view.viewToPage(screen)), page);
    expect(view.visiblePageRect, _rect(10, 20, 110, 70));
    final zoomed = _ok(
      view.zoomedAbout(
        newZoom: 4,
        viewPivot: _viewPoint(20, 20),
        expectedRevision: view.revision,
      ),
    );
    expect(
      _ok(zoomed.viewToPage(_viewPoint(20, 20))),
      _ok(view.viewToPage(_viewPoint(20, 20))),
    );
    expect(
      view.zoomedAbout(
        newZoom: 4,
        viewPivot: _viewPoint(0, 0),
        expectedRevision: _revision(9),
      ),
      isA<Err<Object?, Object?>>(),
    );
  });

  test('binding conflicts fail closed and touch is suppressed', () {
    final id = _ok(InteractionActionId.parse('alnote.actions.pen'));
    final binding = InteractionBinding(
      actionId: id,
      source: PointerSource.mouse,
      requiresPrimaryButton: true,
    );
    expect(
      BindingProfile.create([binding, binding], maximumBindings: 4),
      isA<Err<Object?, Object?>>(),
    );
    final registry = _ok(
      InteractionActionRegistry.create([
        InteractionActionDefinition(
          id: id,
          navigation: false,
          temporary: false,
        ),
      ], maximumActions: 4),
    );
    final profile = _ok(BindingProfile.create([binding], maximumBindings: 4));
    final resolver = InteractionResolver(registry: registry, profile: profile);
    final touch = _event(PointerPhase.down, source: PointerSource.touch);
    expect(
      _ok(
        resolver.resolve(
          touch,
          InteractionContextSnapshot(
            activeTool: 'pen',
            pageRevision: _revision(0),
            suspended: false,
          ),
        ),
      ),
      isNull,
    );
  });

  test(
    'renderer produces dot/polyline and hit testing returns topmost stroke',
    () {
      final first = _object(1, [_sample(10, 10, 0)]);
      final second = _object(2, [_sample(10, 10, 0), _sample(20, 10, 1)]);
      final page = testPage(
        layers: [
          testContentLayer(objects: [first, second]),
        ],
      );
      final viewport = _viewport(origin: _point(0, 0), zoom: 1);
      final geometry = StrokeGeometryResolver(_geometryLimits());
      final objectRegistry = _objectRegistry();
      final scene = _ok(
        PageSceneBuilder(
          objectRegistry: objectRegistry,
          renderingRegistry: _ok(
            RenderingRegistry.create([
              HandwritingRenderingDefinition(
                handwritingLimits: _limits,
                geometryResolver: geometry,
              ),
            ], maximumDefinitions: 4),
          ),
          limits: _renderingLimits(),
        ).build(page: page, viewport: viewport, documentRevision: _revision(0)),
      );
      expect(scene.primitives.whereType<FilledPolygonPrimitive>(), isNotEmpty);
      final hit = _ok(
        PageHitTester(
          objectRegistry: objectRegistry,
          hitTestingRegistry: _ok(
            HitTestingRegistry.create(
              [
                HandwritingHitTestingDefinition(
                  handwritingLimits: _limits,
                  geometryResolver: geometry,
                ),
              ],
              maximumDefinitions: 4,
              maximumBehaviorResults: 16,
            ),
          ),
          maximumResults: 16,
          maximumLassoPoints: 64,
        ).point(page: page, pagePosition: _point(15, 10), pageTolerance: 1),
      );
      expect(hit?.objectId, second.id);
      expect(hit?.strokeId, _payload(second).strokes.single.id);
    },
  );

  test('partial eraser creates deterministic contiguous fragments', () {
    final stroke = _stroke(1, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final generator = UuidSequenceGenerator.fromValues([
      testUuid(30),
      testUuid(31),
    ]);
    final result = _ok(
      splitStrokeByEraser(
        source: stroke,
        eraserPath: [_point(5, 0)],
        radius: .1,
        localToPage: _ok(
          AffineTransform2D.fromOperation(const IdentityTransformOperation2D()),
        ),
        geometryResolver: StrokeGeometryResolver(_geometryLimits()),
        strokeIdGenerator: generator,
        existingIds: {stroke.id},
        maximumEraserPoints: 4,
        maximumIntersections: 16,
        maximumFragments: 8,
        maximumOutputSamples: 32,
        handwritingLimits: _limits,
      ),
    );
    expect(result.strokes, hasLength(2));
    expect(result.strokes.first.samples.first.position.x, 0);
    expect(result.strokes.first.samples.last.position.x, closeTo(3.9, .01));
    expect(result.strokes.last.samples.first.position.x, closeTo(6.1, .01));
    expect(result.strokes.last.samples.last.position.x, 10);
    expect(result.strokes.map((s) => s.id), [
      StrokeId.fromUuid(testUuid(30)),
      StrokeId.fromUuid(testUuid(31)),
    ]);
  });

  test('pointer ownership rejects additional pointers and permits reuse', () {
    final ownership = PointerOwnership();
    expect(ownership.claim(1), isTrue);
    expect(ownership.claim(2), isFalse);
    expect(ownership.release(2), isFalse);
    expect(ownership.release(1), isTrue);
    expect(ownership.claim(1), isTrue);
  });

  test(
    'nonuniform transforms apply to dot width and area crossing geometry',
    () {
      final scale = _ok(
        AffineTransform2D.fromOperation(
          _ok(
            ScaleTransformOperation2D.create(
              scaleX: 4,
              scaleY: 2,
              pivot: _point(0, 0),
            ),
          ),
        ),
      );
      final dot = _stroke(20, [_sample(0, 0, 0)]);
      final geometry = _ok(
        StrokeGeometryResolver(
          _geometryLimits(),
        ).resolve(stroke: dot, localToPage: scale),
      );
      expect(geometry.bounds.left, closeTo(-4, .001));
      expect(geometry.bounds.right, closeTo(4, .001));
      expect(geometry.bounds.top, closeTo(-2, .001));
      expect(geometry.bounds.bottom, closeTo(2, .001));

      final line = _ok(
        StrokeGeometryResolver(_geometryLimits()).resolve(
          stroke: _stroke(21, [_sample(0, 0, 0), _sample(10, 0, 1)]),
          localToPage: _identity(),
        ),
      );
      expect(line.intersectsRectangle(_rect(4.9, -.1, 5.1, .1)), isTrue);
      expect(line.intersectsRectangle(_rect(20, -.1, 30, .1)), isFalse);
    },
  );

  test('rotation is shared by rendering and point hit testing', () {
    final rotation = _ok(
      AffineTransform2D.fromOperation(
        _ok(
          RotationTransformOperation2D.create(
            radians: 1.5707963267948966,
            pivot: _point(0, 0),
          ),
        ),
      ),
    );
    final object = _object(31, [
      _sample(0, 0, 0),
      _sample(10, 0, 1),
    ], transform: rotation);
    final page = testPage(
      layers: [
        testContentLayer(objects: [object]),
      ],
    );
    final geometry = StrokeGeometryResolver(_geometryLimits());
    final tester = PageHitTester(
      objectRegistry: _objectRegistry(),
      hitTestingRegistry: _ok(
        HitTestingRegistry.create(
          [
            HandwritingHitTestingDefinition(
              handwritingLimits: _limits,
              geometryResolver: geometry,
            ),
          ],
          maximumDefinitions: 2,
          maximumBehaviorResults: 8,
        ),
      ),
      maximumResults: 8,
      maximumLassoPoints: 16,
    );
    expect(
      _ok(
        tester.point(page: page, pagePosition: _point(0, 7), pageTolerance: .1),
      )?.objectId,
      object.id,
    );
    expect(
      _ok(
        tester.point(page: page, pagePosition: _point(7, 0), pageTolerance: .1),
      ),
      isNull,
    );
  });

  test('registries capture metadata once and isolate throwing behavior', () {
    final key = handwritingObjectTypeKey;
    final renderingSource = _ThrowingRenderingDefinition(key);
    final rendering = _ok(
      RenderingRegistry.create([renderingSource], maximumDefinitions: 1),
    );
    expect(renderingSource.reads, 1);
    final object = _object(40, [_sample(1, 1, 0)]);
    expect(
      rendering.definitions[key]!.render(
        object: object,
        viewport: _viewport(origin: _point(0, 0), zoom: 1),
        layerOpacity: 1,
        plane: RenderPlane.committed,
        limits: _renderingLimits(),
      ),
      isA<Err<Object?, Object?>>(),
    );
    final hitSource = _ThrowingHitDefinition(key);
    final hits = _ok(
      HitTestingRegistry.create(
        [hitSource],
        maximumDefinitions: 1,
        maximumBehaviorResults: 4,
      ),
    );
    expect(hitSource.reads, 1);
    expect(
      hits.definitions[key]!.point(
        object: object,
        pagePosition: _point(1, 1),
        pageTolerance: 1,
      ),
      isA<Err<Object?, Object?>>(),
    );
  });

  test('scene factories reject invalid values and hostile oversized tails', () {
    expect(RenderColor.create(0x100000000), isA<Err<Object?, Object?>>());
    expect(
      FilledPolygonPrimitive.create(
        plane: RenderPlane.committed,
        opacity: double.nan,
        color: _ok(RenderColor.create(0xff000000)),
        points: [_point(0, 0), _point(1, 0), _point(0, 1)],
        maximumPoints: 3,
      ),
      isA<Err<Object?, Object?>>(),
    );
    final iterable = _RejectedTailIterable<Point2>([
      _point(0, 0),
      _point(1, 0),
      _point(0, 1),
    ]);
    expect(
      FilledPolygonPrimitive.create(
        plane: RenderPlane.committed,
        opacity: 1,
        color: _ok(RenderColor.create(0xff000000)),
        points: iterable,
        maximumPoints: 3,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(iterable.rejectedCurrentRead, isFalse);
  });

  test(
    'gesture router snapshots Tool, rejects time regression, and releases',
    () {
      final action = _ok(InteractionActionId.parse('alnote.actions.pen'));
      final router = InteractionGestureRouter(
        resolver: InteractionResolver(
          registry: _ok(
            InteractionActionRegistry.create([
              InteractionActionDefinition(
                id: action,
                navigation: false,
                temporary: false,
              ),
            ], maximumActions: 1),
          ),
          profile: _ok(
            BindingProfile.create([
              InteractionBinding(
                actionId: action,
                source: PointerSource.mouse,
                requiresPrimaryButton: true,
                activeTool: 'pen',
              ),
            ], maximumBindings: 1),
          ),
        ),
        ownership: PointerOwnership(),
      );
      final context = InteractionContextSnapshot(
        activeTool: 'pen',
        pageRevision: _revision(4),
        suspended: false,
      );
      expect(
        _ok(
          router.route(_event(PointerPhase.down, time: 10), context),
        )?.activeTool,
        'pen',
      );
      final changed = InteractionContextSnapshot(
        activeTool: 'selection',
        pageRevision: _revision(5),
        suspended: false,
      );
      expect(
        _ok(
          router.route(_event(PointerPhase.move, time: 11), changed),
        )?.activeTool,
        'pen',
      );
      expect(
        router.route(_event(PointerPhase.move, time: 9), changed),
        isA<Err<Object?, Object?>>(),
      );
      expect(router.ownership.owner, isNull);
      expect(
        _ok(router.route(_event(PointerPhase.down, time: 20), context)),
        isNotNull,
      );
      expect(
        _ok(router.route(_event(PointerPhase.up, time: 21), context)),
        isNotNull,
      );
      expect(router.completeTerminal(1), isTrue);
      expect(router.ownership.owner, isNull);
    },
  );

  test(
    'SelectionController resolves and reconciles Handwriting Stroke targets',
    () {
      final object = _object(50, [_sample(2, 3, 0)]);
      final page = testPage(
        layers: [
          testContentLayer(objects: [object]),
        ],
      );
      final root = testNotebook(
        sections: [
          testSection(pages: [page]),
        ],
      );
      final controller = SelectionController(
        objectRegistry: _objectRegistry(),
        coalescingBoundarySink: _BoundarySink(),
        maximumTargets: 4,
        handwritingLimits: _limits,
        strokeGeometryResolver: StrokeGeometryResolver(_geometryLimits()),
      );
      final target = SelectionTarget.subTarget(
        pageId: page.id,
        objectId: object.id,
        kind: handwritingStrokeSelectionSubTargetKind,
        id: SelectionSubTargetId.fromUuid(
          _payload(object).strokes.single.id.uuid,
        ),
      );
      final selected = controller.replace(root: root, targets: [_ok(target)]);
      expect(selected, isA<Ok<Object?, Object?>>());
      expect(controller.state.targets, hasLength(1));
      expect(controller.state.aggregateBounds, isNotNull);
      controller.reconcile(testNotebook());
      expect(controller.state.isEmpty, isTrue);
    },
  );

  test('Unknown Layers and unsupported handwriting schemas stay inert', () {
    final supported = _object(51, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final unsupported = _unsupportedSchemaObject(supported);
    for (final layer in [
      testUnknownLayer(objects: [supported]),
      testContentLayer(objects: [unsupported]),
    ]) {
      final page = testPage(layers: [layer]);
      final root = testNotebook(
        sections: [
          testSection(pages: [page]),
        ],
      );
      final counter = _ForbiddenBehaviorCounter();
      final scene = _ok(
        PageSceneBuilder(
          objectRegistry: _objectRegistry(),
          renderingRegistry: _ok(
            RenderingRegistry.create([
              _ForbiddenRenderingDefinition(counter),
            ], maximumDefinitions: 1),
          ),
          limits: _renderingLimits(),
        ).build(
          page: page,
          viewport: _viewport(origin: _point(0, 0), zoom: 1),
          documentRevision: _revision(0),
        ),
      );
      expect(scene.primitives, isEmpty);

      final hitTester = PageHitTester(
        objectRegistry: _objectRegistry(),
        hitTestingRegistry: _ok(
          HitTestingRegistry.create(
            [_ForbiddenHitDefinition(counter)],
            maximumDefinitions: 1,
            maximumBehaviorResults: 4,
          ),
        ),
        maximumResults: 4,
        maximumLassoPoints: 4,
      );
      expect(
        _ok(
          hitTester.point(
            page: page,
            pagePosition: _point(5, 0),
            pageTolerance: 1,
          ),
        ),
        isNull,
      );
      expect(
        _ok(
          hitTester.rectangle(
            page: page,
            area: _rect(-2, -2, 12, 2),
            mode: AreaHitMode.intersection,
          ),
        ),
        isEmpty,
      );

      final selection = SelectionController(
        objectRegistry: _objectRegistry(),
        coalescingBoundarySink: _BoundarySink(),
        maximumTargets: 1,
        handwritingLimits: _limits,
        strokeGeometryResolver: StrokeGeometryResolver(_geometryLimits()),
      );
      final target = SelectionTarget.wholeObject(
        pageId: page.id,
        objectId: layer.objects.single.id,
      );
      expect(
        selection.replace(root: root, targets: [target]),
        isA<Err<Object?, Object?>>(),
      );
      expect(selection.state.isEmpty, isTrue);

      final generator = _CountingUuidGenerator();
      final before = layer.objects.single;
      final partial = createPartialEraseRequest(
        document: _coordinator(root).snapshot,
        pageId: page.id,
        pagePath: [_point(5, 0)],
        pageRadius: 1,
        uuidGenerator: generator,
        handwritingLimits: _limits,
        geometryResolver: StrokeGeometryResolver(_geometryLimits()),
        maximumEraserPoints: 1,
        maximumIntersections: 2,
        maximumFragments: 2,
        maximumOutputSamples: 4,
        maximumCommandOperations: 1,
      );
      expect(partial, isA<Err<Object?, Object?>>());
      expect(partial.toString(), isNot(contains('secret-inert-content')));
      expect(generator.calls, 0);
      expect(counter.calls, 0);
      expect(layer.objects.single, before);
      expect(layer.objects.single.payload, before.payload);
    }
  });

  test('Pen stale finalization rejects before any UUID allocation', () {
    final root = testNotebook(
      sections: [
        testSection(
          pages: [
            testPage(layers: [testContentLayer()]),
          ],
        ),
      ],
    );
    final coordinator = _coordinator(root);
    final page = root.pages.single;
    final layer = page.layers.single;
    final generator = _CountingUuidGenerator();
    final session = _ok(
      PenGestureSession.start(
        down: _event(PointerPhase.down, time: 10),
        document: coordinator.snapshot,
        pageId: page.id,
        layerId: layer.id,
        viewport: _viewport(origin: _point(0, 0), zoom: 1),
        preset: PenPreset.fromStyle(_stroke(70, [_sample(0, 0, 0)]).style),
        maximumSamples: 4,
        handwritingLimits: _limits,
        uuidGenerator: generator,
        maximumCommandOperations: 4,
      ),
    );
    final current = coordinator.snapshot;
    final stale = DocumentCoordinatorSnapshot(
      root: testNotebook(id: 41),
      revisions: current.revisions,
      currentContentIdentity: current.currentContentIdentity,
      savedContentIdentity: current.savedContentIdentity,
      canUndo: current.canUndo,
      canRedo: current.canRedo,
      historyTraversalEnabled: current.historyTraversalEnabled,
    );
    expect(
      session.finish(
        _event(PointerPhase.up, time: 11),
        latestDocument: stale,
        viewportRevision: _revision(0),
        pointerOwnerAtTerminal: 1,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(generator.calls, 0);
    expect(session.preview, isNull);
  });

  test(
    'hit behavior output is iterator-bounded without consulting List length',
    () {
      final ids = [
        StrokeId.fromUuid(testUuid(950)),
        StrokeId.fromUuid(testUuid(951)),
      ];
      for (final reportedLength in [0, 999]) {
        final hostile = _HostileStrokeList(ids, reportedLength: reportedLength);
        final definition = _AreaHitDefinition(hostile);
        final registry = _ok(
          HitTestingRegistry.create(
            [definition],
            maximumDefinitions: 1,
            maximumBehaviorResults: 2,
          ),
        );
        final result = _ok(
          registry.definitions[handwritingObjectTypeKey]!.rectangle(
            object: _object(80, [_sample(0, 0, 0)]),
            area: _rect(-1, -1, 1, 1),
            mode: AreaHitMode.intersection,
          ),
        );
        expect(result, ids);
        expect(hostile.lengthRead, isFalse);
        expect(() => result.add(ids.first), throwsUnsupportedError);
      }
      final throwingLength = _HostileStrokeList(ids, throwLength: true);
      final registry = _ok(
        HitTestingRegistry.create(
          [_AreaHitDefinition(throwingLength)],
          maximumDefinitions: 1,
          maximumBehaviorResults: 2,
        ),
      );
      expect(
        registry.definitions[handwritingObjectTypeKey]!.lasso(
          object: _object(81, [_sample(0, 0, 0)]),
          polygon: [_point(0, 0), _point(1, 0), _point(0, 1)],
          mode: AreaHitMode.intersection,
        ),
        isA<Ok<Object?, Object?>>(),
      );
      expect(throwingLength.lengthRead, isFalse);
    },
  );

  test(
    'hit behavior output contains iterator faults, tails, infinity, and duplicates',
    () {
      final first = StrokeId.fromUuid(testUuid(960));
      final second = StrokeId.fromUuid(testUuid(961));
      final cases = <List<StrokeId>>[
        _HostileStrokeList([first], throwIterator: true),
        _HostileStrokeList([first], throwMoveAt: 0),
        _HostileStrokeList([first], throwCurrentAt: 0),
        _HostileStrokeList([first, second], infinite: true),
        _HostileStrokeList([first, first]),
        _HostileStrokeList([first, second, first]),
      ];
      for (final hostile in cases) {
        final registry = _ok(
          HitTestingRegistry.create(
            [_AreaHitDefinition(hostile)],
            maximumDefinitions: 1,
            maximumBehaviorResults: 2,
          ),
        );
        final result = registry.definitions[handwritingObjectTypeKey]!
            .rectangle(
              object: _object(82, [_sample(0, 0, 0)]),
              area: _rect(-1, -1, 1, 1),
              mode: AreaHitMode.intersection,
            );
        expect(result, isA<Err<Object?, Object?>>());
        expect(result.toString(), isNot(contains('secret-hit-output')));
      }
      final rejectedTail = _HostileStrokeList([first, second, first]);
      final registry = _ok(
        HitTestingRegistry.create(
          [_AreaHitDefinition(rejectedTail)],
          maximumDefinitions: 1,
          maximumBehaviorResults: 2,
        ),
      );
      registry.definitions[handwritingObjectTypeKey]!.rectangle(
        object: _object(83, [_sample(0, 0, 0)]),
        area: _rect(-1, -1, 1, 1),
        mode: AreaHitMode.intersection,
      );
      expect(rejectedTail.rejectedTailCurrentRead, isFalse);
    },
  );

  test('Page hit result ceiling is cumulative across Objects', () {
    final first = _object(84, [_sample(0, 0, 0)]);
    final second = _object(85, [_sample(0, 0, 0)]);
    final geometry = StrokeGeometryResolver(_geometryLimits());
    final tester = PageHitTester(
      objectRegistry: _objectRegistry(),
      hitTestingRegistry: _ok(
        HitTestingRegistry.create(
          [
            HandwritingHitTestingDefinition(
              handwritingLimits: _limits,
              geometryResolver: geometry,
            ),
          ],
          maximumDefinitions: 1,
          maximumBehaviorResults: 2,
        ),
      ),
      maximumResults: 1,
      maximumLassoPoints: 8,
    );
    expect(
      tester.rectangle(
        page: testPage(
          layers: [
            testContentLayer(objects: [first, second]),
          ],
        ),
        area: _rect(-2, -2, 2, 2),
        mode: AreaHitMode.intersection,
      ),
      isA<Err<Object?, Object?>>(),
    );
  });

  test('history cost traverses actual UTF-8 preserved content and nesting', () {
    final estimator = HandwritingHistoryCostEstimator(
      _limits,
      maximumAccountingValue: Revision.maximumValue,
    );
    int cost(String value, {bool nested = false}) => _ok(
      estimator.estimate(
        HistoryCostEstimateInput(
          beforeRoot: _historyRoot(value, nested: nested),
          afterRoot: _historyRoot(value, nested: nested),
          replacedObjectCount: 1,
        ),
      ),
    ).estimatedBytes;
    expect(cost('x' * 4096), greaterThan(cost('x')));
    expect(cost('é'), greaterThan(cost('e')));
    expect(
      cost('nested-value', nested: true),
      greaterThan(cost('nested-value')),
    );
  });

  test('history UTF-8 accounting matches Dart surrogate semantics', () {
    final estimator = HandwritingHistoryCostEstimator(
      _limits,
      maximumAccountingValue: Revision.maximumValue,
    );
    int cost(String value, {String key = 'unknown'}) => _ok(
      estimator.estimate(
        HistoryCostEstimateInput(
          beforeRoot: _historyRoot(value, key: key),
          afterRoot: _historyRoot(value, key: key),
          replacedObjectCount: 1,
        ),
      ),
    ).estimatedBytes;
    final base = cost('');
    expect(cost('A') - base, 4);
    expect(cost('\u00e9') - base, 8);
    expect(cost('\u20ac') - base, 12);
    final pair = String.fromCharCodes([0xd83d, 0xde00]);
    expect(cost(pair) - base, 16);
    expect(cost(String.fromCharCode(0xd800)) - base, 12);
    expect(cost(String.fromCharCode(0xdc00)) - base, 12);

    final shortKey = cost('', key: 'k');
    expect(cost('', key: '\u20ac') - shortKey, 4);
    expect(
      cost('nested', key: 'large-key-' + ('x' * 4096)),
      greaterThan(cost('nested', key: 'large-key')),
    );
  });

  test('history UTF-8 accounting rejects huge strings incrementally', () {
    const secret = 'secret-allocation-bounded-history';
    final estimator = HandwritingHistoryCostEstimator(
      _limits,
      maximumAccountingValue: 256,
    );
    final result = estimator.estimate(
      HistoryCostEstimateInput(
        beforeRoot: _historyRoot(secret + ('x' * 2000000), nested: true),
        afterRoot: _historyRoot('small'),
        replacedObjectCount: 1,
      ),
    );
    expect(result, isA<Err<Object?, Object?>>());
    expect(result.toString(), isNot(contains(secret)));
  });

  test(
    'history accounting overflow is fixed, redacted, and blocks publication',
    () {
      const secret = 'secret-history-content-that-must-not-cross';
      final estimator = HandwritingHistoryCostEstimator(
        _limits,
        maximumAccountingValue: 512,
      );
      final failure = estimator.estimate(
        HistoryCostEstimateInput(
          beforeRoot: _historyRoot(secret),
          afterRoot: _historyRoot(secret),
          replacedObjectCount: 1,
        ),
      );
      expect(failure, isA<Err<Object?, Object?>>());
      expect(failure.toString(), isNot(contains(secret)));

      final root = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(layers: [testContentLayer()]),
            ],
          ),
        ],
      );
      final coordinator = _ok(
        DocumentMutationCoordinator.create(
          initialRoot: root,
          validator: DocumentValidator(_objectRegistry()),
          uuidGenerator: UuidSequenceGenerator.fromValues([
            testUuid(970),
            testUuid(971),
          ]),
          historyLimits: _ok(
            HistoryLimits.create(
              maximumRetainedCommandCount: 2,
              maximumEstimatedRetainedBytes: 600,
            ),
          ),
          retainedCostEstimator: HandwritingHistoryCostEstimator(
            _limits,
            maximumAccountingValue: Revision.maximumValue,
          ),
          maximumListeners: 1,
        ),
      );
      final page = root.pages.single, layer = page.layers.single;
      final request = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: root.id,
          metadata: CommandMetadata(
            family: CommandFamily.objectCollectionEdit,
            correlationId: CommandCorrelationId.fromUuid(testUuid(972)),
            description: 'Bounded history',
          ),
          preconditions: RevisionPreconditions(
            pages: {page.id: coordinator.snapshot.revisions.pages[page.id]!},
            layerMembership: {
              layer.id:
                  coordinator.snapshot.revisions.layerMembership[layer.id]!,
            },
          ),
          pageId: page.id,
          additions: [
            ObjectCollectionAddition(
              layerId: layer.id,
              object: _historyObject(secret * 100),
            ),
          ],
          maximumOperations: 1,
        ),
      );
      expect(coordinator.execute(request), isA<Err<Object?, Object?>>());
      expect(coordinator.snapshot.root, root);
    },
  );

  test('partial erase preflight enforces cumulative budgets before UUIDs', () {
    final first = _object(101, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final second = _object(102, [_sample(0, 10, 0), _sample(10, 10, 10)]);
    final root = testNotebook(
      sections: [
        testSection(
          pages: [
            testPage(
              layers: [
                testContentLayer(objects: [first, second]),
              ],
            ),
          ],
        ),
      ],
    );
    final snapshot = _coordinator(root).snapshot;
    final page = root.pages.single;

    Result<AtomicObjectCollectionEditRequest, StructuredFailure> create(
      _CountingUuidGenerator generator, {
      int intersections = 4,
      int fragments = 4,
      int samples = 8,
      int operations = 2,
    }) => createPartialEraseRequest(
      document: snapshot,
      pageId: page.id,
      pagePath: [_point(5, -2), _point(5, 12)],
      pageRadius: .1,
      uuidGenerator: generator,
      handwritingLimits: _limits,
      geometryResolver: StrokeGeometryResolver(_geometryLimits()),
      maximumEraserPoints: 2,
      maximumIntersections: intersections,
      maximumFragments: fragments,
      maximumOutputSamples: samples,
      maximumCommandOperations: operations,
    );

    for (final limits in [
      (intersections: 3, fragments: 4, samples: 8, operations: 2),
      (intersections: 4, fragments: 3, samples: 8, operations: 2),
      (intersections: 4, fragments: 4, samples: 7, operations: 2),
      (intersections: 4, fragments: 4, samples: 8, operations: 1),
    ]) {
      final generator = _CountingUuidGenerator();
      expect(
        create(
          generator,
          intersections: limits.intersections,
          fragments: limits.fragments,
          samples: limits.samples,
          operations: limits.operations,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(generator.calls, 0);
    }

    final generator = _CountingUuidGenerator();
    final request = _ok(create(generator));
    expect(request.replacements, hasLength(2));
    expect(generator.calls, 5); // Four fragments, then one correlation ID.
    expect(
      request.replacements
          .expand((object) => _payload(object).strokes)
          .map((stroke) => stroke.id.uuid),
      [testUuid(901), testUuid(902), testUuid(903), testUuid(904)],
    );
  });

  test('partial erase rejects incomplete revision evidence before UUIDs', () {
    final object = _object(103, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final root = testNotebook(
      sections: [
        testSection(
          pages: [
            testPage(
              layers: [
                testContentLayer(objects: [object]),
              ],
            ),
          ],
        ),
      ],
    );
    final current = _coordinator(root).snapshot;
    final revisions = current.revisions;
    final incompleteRevisions = [
      DocumentRevisionSnapshot.fromValues(
        documentId: revisions.documentId,
        document: revisions.document,
        sections: revisions.sections,
        layers: revisions.layers,
        layerMembership: revisions.layerMembership,
        objects: revisions.objects,
        resourceCatalog: revisions.resourceCatalog,
      ),
      DocumentRevisionSnapshot.fromValues(
        documentId: revisions.documentId,
        document: revisions.document,
        sections: revisions.sections,
        pages: revisions.pages,
        layers: revisions.layers,
        layerMembership: revisions.layerMembership,
        resourceCatalog: revisions.resourceCatalog,
      ),
      DocumentRevisionSnapshot.fromValues(
        documentId: revisions.documentId,
        document: revisions.document,
        sections: revisions.sections,
        pages: revisions.pages,
        layers: revisions.layers,
        objects: revisions.objects,
        resourceCatalog: revisions.resourceCatalog,
      ),
    ];
    for (final incompleteRevision in incompleteRevisions) {
      final incomplete = DocumentCoordinatorSnapshot(
        root: current.root,
        revisions: incompleteRevision,
        currentContentIdentity: current.currentContentIdentity,
        savedContentIdentity: current.savedContentIdentity,
        canUndo: current.canUndo,
        canRedo: current.canRedo,
        historyTraversalEnabled: current.historyTraversalEnabled,
      );
      final generator = _CountingUuidGenerator();
      expect(
        createPartialEraseRequest(
          document: incomplete,
          pageId: root.pages.single.id,
          pagePath: [_point(5, 0)],
          pageRadius: .1,
          uuidGenerator: generator,
          handwritingLimits: _limits,
          geometryResolver: StrokeGeometryResolver(_geometryLimits()),
          maximumEraserPoints: 1,
          maximumIntersections: 2,
          maximumFragments: 2,
          maximumOutputSamples: 4,
          maximumCommandOperations: 1,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(generator.calls, 0);
    }

    final collision = _CountingUuidGenerator([
      _payload(object).strokes.single.id.uuid,
    ]);
    expect(
      createPartialEraseRequest(
        document: current,
        pageId: root.pages.single.id,
        pagePath: [_point(5, 0)],
        pageRadius: .1,
        uuidGenerator: collision,
        handwritingLimits: _limits,
        geometryResolver: StrokeGeometryResolver(_geometryLimits()),
        maximumEraserPoints: 1,
        maximumIntersections: 2,
        maximumFragments: 2,
        maximumOutputSamples: 4,
        maximumCommandOperations: 1,
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(collision.calls, 1);
  });

  test('viewport rejects finite but unrepresentable visible rectangles', () {
    expect(
      ViewportSnapshot.create(
        extent: _ok(
          ViewExtent.create(width: double.maxFinite, height: double.maxFinite),
        ),
        pageOrigin: _point(0, 0),
        zoom: double.minPositive,
        minimumZoom: double.minPositive,
        maximumZoom: 1,
        revision: _revision(0),
      ),
      isA<Err<Object?, Object?>>(),
    );
    expect(
      ViewportSnapshot.create(
        extent: _ok(ViewExtent.create(width: 10, height: 10)),
        pageOrigin: _point(double.maxFinite, double.maxFinite),
        zoom: 1,
        minimumZoom: 1,
        maximumZoom: 1,
        revision: _revision(0),
      ),
      isA<Err<Object?, Object?>>(),
    );
  });

  test('concave containment checks stroke edges and has a ceiling', () {
    final polygon = [
      _point(-2, -3),
      _point(12, -3),
      _point(12, 3),
      _point(7, 3),
      _point(7, -.5),
      _point(3, -.5),
      _point(3, 3),
      _point(-2, 3),
    ];
    final geometry = _ok(
      StrokeGeometryResolver(_geometryLimits()).resolve(
        stroke: _stroke(201, [_sample(0, 0, 0), _sample(10, 0, 1)]),
        localToPage: _identity(),
      ),
    );
    expect(_ok(geometry.containedByPolygon(polygon)), isFalse);
    final bounded = _ok(
      StrokeGeometryLimits.create(
        maximumElements: 128,
        maximumVertices: 2048,
        ellipseVertexCount: 16,
        maximumContainmentChecks: 1,
      ),
    );
    final limited = _ok(
      StrokeGeometryResolver(bounded).resolve(
        stroke: _stroke(202, [_sample(0, 0, 0)]),
        localToPage: _identity(),
      ),
    );
    expect(limited.containedByPolygon(polygon), isA<Err<Object?, Object?>>());
  });

  test('point tolerance remains correct when bounds expansion overflows', () {
    final hugeLimits = _ok(
      HandwritingLimits.create(
        maximumStrokes: 1,
        maximumSamplesPerStroke: 1,
        maximumUnknownFields: 1,
        maximumNestingDepth: 1,
        maximumUnknownNodes: 4,
        maximumCoordinateMagnitude: 1e308,
        maximumStrokeWidth: 2,
        maximumAbsoluteTilt: 1,
        maximumAbsoluteOrientation: 1,
      ),
    );
    final stroke = _ok(
      HandwritingStroke.create(
        id: StrokeId.fromUuid(testUuid(999)),
        samples: [
          _ok(
            StrokeSample.create(
              position: _point(1e308, 0),
              timeMicros: 0,
              limits: hugeLimits,
            ),
          ),
        ],
        style: _ok(
          StrokeStyle.create(
            argb: 0,
            opacity: 1,
            baseWidth: 2,
            pressureInfluence: 0,
            minimumPressureFactor: 0,
            limits: hugeLimits,
          ),
        ),
        limits: hugeLimits,
      ),
    );
    final geometry = _ok(
      StrokeGeometryResolver(
        _geometryLimits(),
      ).resolve(stroke: stroke, localToPage: _identity()),
    );
    expect(geometry.hitsPoint(_point(0, 0), 1.1e308), isTrue);
    expect(geometry.hitsPoint(_point(-1e308, 0), 1.1e308), isFalse);
  });
}

NormalizedPointerEvent _event(
  PointerPhase phase, {
  PointerSource source = PointerSource.mouse,
  int time = 0,
}) => _ok(
  NormalizedPointerEvent.create(
    pointerId: 1,
    source: source,
    phase: phase,
    viewPosition: _viewPoint(0, 0),
    buttons: const PointerButtons(1),
    timeMicros: time,
    cancellationReason: phase == PointerPhase.cancel
        ? InteractionCancellationReason.explicit
        : null,
  ),
);
ViewportSnapshot _viewport({Point2? origin, double zoom = 2}) => _ok(
  ViewportSnapshot.create(
    extent: _ok(ViewExtent.create(width: 200, height: 100)),
    pageOrigin: origin ?? _point(10, 20),
    zoom: zoom,
    minimumZoom: .5,
    maximumZoom: 8,
    revision: _revision(0),
  ),
);
ObjectEnvelope _object(
  int id,
  List<StrokeSample> samples, {
  AffineTransform2D? transform,
}) {
  final payload = _ok(
    HandwritingPayload.create(strokes: [_stroke(id, samples)], limits: _limits),
  );
  return testObject(
    id: id,
    typeKey: handwritingObjectTypeKey,
    schemaVersion: handwritingSchemaVersion,
    payload: payload.encode(),
    transform: transform,
  );
}

ObjectEnvelope _unsupportedSchemaObject(ObjectEnvelope source) => _ok(
  ObjectEnvelope.create(
    id: source.id,
    typeKey: source.typeKey,
    envelopeVersion: source.envelopeVersion,
    typeSchemaVersion: _ok(SchemaVersion.create(2)),
    transform: source.transform,
    visible: source.visible,
    locked: source.locked,
    payload: source.payload,
    extensionData: source.extensionData,
  ),
);

ObjectEnvelope _historyObject(
  String value, {
  bool nested = false,
  String key = 'unknown',
}) {
  final unknownValue = nested
      ? PreservedMap({
          'outer': PreservedList([
            PreservedMap({'inner': PreservedString(value)}),
          ]),
        })
      : PreservedString(value);
  final stroke = _stroke(90, [_sample(1, 1, 0)]);
  final payload = _ok(
    HandwritingPayload.create(
      strokes: [stroke],
      limits: _limits,
      unknownFields: PreservedMap({key: unknownValue}),
    ),
  );
  return testObject(
    id: 990,
    typeKey: handwritingObjectTypeKey,
    schemaVersion: handwritingSchemaVersion,
    payload: payload.encode(),
    extensionData: PreservedMap({'extension': PreservedString(value)}),
  );
}

NotebookDocument _historyRoot(
  String value, {
  bool nested = false,
  String key = 'unknown',
}) => testNotebook(
  sections: [
    testSection(
      pages: [
        testPage(
          layers: [
            testContentLayer(
              objects: [_historyObject(value, nested: nested, key: key)],
            ),
          ],
        ),
      ],
    ),
  ],
);

HandwritingPayload _payload(ObjectEnvelope object) =>
    _ok(HandwritingPayload.decode(object.payload, limits: _limits));
HandwritingStroke _stroke(int id, List<StrokeSample> samples) => _ok(
  HandwritingStroke.create(
    id: StrokeId.fromUuid(testUuid(100 + id)),
    samples: samples,
    style: _ok(
      StrokeStyle.create(
        argb: 0xff000000,
        opacity: 1,
        baseWidth: 2,
        pressureInfluence: 0,
        minimumPressureFactor: 0,
        limits: _limits,
      ),
    ),
    limits: _limits,
  ),
);
StrokeSample _sample(double x, double y, int t) => _ok(
  StrokeSample.create(position: _point(x, y), timeMicros: t, limits: _limits),
);
Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));
ViewPoint _viewPoint(double x, double y) => _ok(ViewPoint.create(x: x, y: y));
Rect2 _rect(double l, double t, double r, double b) =>
    _ok(Rect2.fromEdges(left: l, top: t, right: r, bottom: b));
ObjectRegistry _objectRegistry() =>
    _ok(ObjectRegistry.create([HandwritingObjectTypeDefinition(_limits)]));
StrokeGeometryLimits _geometryLimits() => _ok(
  StrokeGeometryLimits.create(
    maximumElements: 128,
    maximumVertices: 2048,
    ellipseVertexCount: 16,
    maximumContainmentChecks: 100000,
  ),
);
RenderingLimits _renderingLimits() => _ok(
  RenderingLimits.create(
    maximumPrimitives: 256,
    maximumPointsPerPrimitive: 32,
    maximumDamageRegions: 32,
    maximumPreviewOverlays: 64,
    maximumSelectionOverlays: 64,
  ),
);
AffineTransform2D _identity() =>
    _ok(AffineTransform2D.fromOperation(const IdentityTransformOperation2D()));
DocumentMutationCoordinator _coordinator(DocumentRoot root) => _ok(
  DocumentMutationCoordinator.create(
    initialRoot: root,
    validator: DocumentValidator(_objectRegistry()),
    uuidGenerator: UuidSequenceGenerator.fromValues([
      testUuid(800),
      testUuid(801),
    ]),
    historyLimits: _ok(
      HistoryLimits.create(
        maximumRetainedCommandCount: 4,
        maximumEstimatedRetainedBytes: 10000,
      ),
    ),
    retainedCostEstimator: FixedHistoryCostEstimator(1),
    maximumListeners: 2,
  ),
);
Revision _revision(int v) => _ok(Revision.create(v));
T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;

final class _ThrowingRenderingDefinition implements ObjectRenderingDefinition {
  _ThrowingRenderingDefinition(this._key);
  final ObjectTypeKey _key;
  int reads = 0;
  @override
  ObjectTypeKey get typeKey {
    reads += 1;
    if (reads > 1) throw StateError('hostile getter reread');
    return _key;
  }

  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) => throw StateError('secret renderer failure');
}

final class _ForbiddenBehaviorCounter {
  int calls = 0;
}

final class _ForbiddenRenderingDefinition implements ObjectRenderingDefinition {
  const _ForbiddenRenderingDefinition(this.counter);
  final _ForbiddenBehaviorCounter counter;
  @override
  ObjectTypeKey get typeKey => handwritingObjectTypeKey;

  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    counter.calls += 1;
    throw StateError('secret-inert-content-render');
  }
}

final class _ForbiddenHitDefinition implements ObjectHitTestingDefinition {
  const _ForbiddenHitDefinition(this.counter);
  final _ForbiddenBehaviorCounter counter;
  @override
  ObjectTypeKey get typeKey => handwritingObjectTypeKey;

  Never _forbidden() {
    counter.calls += 1;
    throw StateError('secret-inert-content-hit');
  }

  @override
  Result<StrokeId?, StructuredFailure> point({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) => _forbidden();

  @override
  Result<List<StrokeId>, StructuredFailure> rectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) => _forbidden();

  @override
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required List<Point2> polygon,
    required AreaHitMode mode,
  }) => _forbidden();
}

final class _ThrowingHitDefinition implements ObjectHitTestingDefinition {
  _ThrowingHitDefinition(this._key);
  final ObjectTypeKey _key;
  int reads = 0;
  @override
  ObjectTypeKey get typeKey {
    reads += 1;
    if (reads > 1) throw StateError('hostile getter reread');
    return _key;
  }

  @override
  Result<StrokeId?, StructuredFailure> point({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) => throw StateError('secret hit failure');

  @override
  Result<List<StrokeId>, StructuredFailure> rectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) => throw StateError('secret hit failure');

  @override
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required List<Point2> polygon,
    required AreaHitMode mode,
  }) => throw StateError('secret hit failure');
}

final class _RejectedTailIterable<T> extends Iterable<T> {
  _RejectedTailIterable(this.values);
  final List<T> values;
  bool rejectedCurrentRead = false;
  @override
  Iterator<T> get iterator => _RejectedTailIterator<T>(this);
}

final class _RejectedTailIterator<T> implements Iterator<T> {
  _RejectedTailIterator(this.owner);
  final _RejectedTailIterable<T> owner;
  var index = -1;
  @override
  bool moveNext() {
    index += 1;
    return index <= owner.values.length;
  }

  @override
  T get current {
    if (index >= owner.values.length) {
      owner.rejectedCurrentRead = true;
      throw StateError('rejected tail current');
    }
    return owner.values[index];
  }
}

final class _BoundarySink implements CoalescingBoundarySink {
  @override
  Result<void, StructuredFailure> establishCoalescingBoundary(
    CoalescingBoundary boundary,
  ) => const Ok(null);
}

final class _CountingUuidGenerator implements UuidGenerator {
  _CountingUuidGenerator([this.values = const []]);

  final List<UuidIdentifier> values;
  int calls = 0;

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    calls += 1;
    return Ok(
      calls <= values.length ? values[calls - 1] : testUuid(900 + calls),
    );
  }
}

final class _AreaHitDefinition implements ObjectHitTestingDefinition {
  const _AreaHitDefinition(this.output);
  final List<StrokeId> output;
  @override
  ObjectTypeKey get typeKey => handwritingObjectTypeKey;

  @override
  Result<StrokeId?, StructuredFailure> point({
    required ObjectEnvelope object,
    required Point2 pagePosition,
    required double pageTolerance,
  }) => const Ok(null);

  @override
  Result<List<StrokeId>, StructuredFailure> rectangle({
    required ObjectEnvelope object,
    required Rect2 area,
    required AreaHitMode mode,
  }) => Ok(output);

  @override
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required List<Point2> polygon,
    required AreaHitMode mode,
  }) => Ok(output);
}

final class _HostileStrokeList extends ListBase<StrokeId> {
  _HostileStrokeList(
    this.values, {
    this.reportedLength,
    this.throwLength = false,
    this.throwIterator = false,
    this.throwMoveAt,
    this.throwCurrentAt,
    this.infinite = false,
  });
  final List<StrokeId> values;
  final int? reportedLength;
  final bool throwLength;
  final bool throwIterator;
  final int? throwMoveAt;
  final int? throwCurrentAt;
  final bool infinite;
  bool lengthRead = false;
  bool rejectedTailCurrentRead = false;

  @override
  int get length {
    lengthRead = true;
    if (throwLength) throw StateError('secret-hit-output-length');
    return reportedLength ?? values.length;
  }

  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  StrokeId operator [](int index) => values[index];
  @override
  void operator []=(int index, StrokeId value) =>
      throw UnsupportedError('immutable');

  @override
  Iterator<StrokeId> get iterator {
    if (throwIterator) throw StateError('secret-hit-output-iterator');
    return _HostileStrokeIterator(this);
  }
}

final class _HostileStrokeIterator implements Iterator<StrokeId> {
  _HostileStrokeIterator(this.owner);
  final _HostileStrokeList owner;
  var index = -1;

  @override
  bool moveNext() {
    final next = index + 1;
    if (owner.throwMoveAt == next) throw StateError('secret-hit-output-move');
    index = next;
    return owner.infinite || index < owner.values.length;
  }

  @override
  StrokeId get current {
    if (owner.throwCurrentAt == index)
      throw StateError('secret-hit-output-current');
    if (index >= owner.values.length) {
      owner.rejectedTailCurrentRead = true;
      return owner.values[index % owner.values.length];
    }
    return owner.values[index];
  }
}
