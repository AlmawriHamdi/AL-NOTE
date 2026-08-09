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
import 'package:al_note/ui/canvas/phase6_diagnostics.dart';
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
          maximumCandidates: 16,
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
        maximumExistingIds: 8,
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

  test(
    'partial eraser classifies the auditor affine counterexample exactly',
    () {
      final resolver = StrokeGeometryResolver(_geometryLimits());
      final transform = _ok(
        AffineTransform2D.restoreFromStorage([1, 4, 0, 1, 0, 0]),
      );
      final hit = _ok(
        resolver.classifySourceSegmentErasure(
          first: _sample(0, 0, 0),
          second: _sample(10, 0, 10),
          style: _stroke(1, [_sample(0, 0, 0)]).style,
          localToPage: transform,
          eraserSegment: _ok(
            SweptPath.create([_point(8.96, .99)], maximumPoints: 1),
          ),
          radius: 0,
          handwritingLimits: _limits,
        ),
      );
      expect(hit, isNotEmpty);
      expect(hit.single.start, lessThan(.5));
      expect(hit.single.end, greaterThan(.5));

      final miss = _ok(
        resolver.classifySourceSegmentErasure(
          first: _sample(0, 0, 0),
          second: _sample(10, 0, 10),
          style: _stroke(1, [_sample(0, 0, 0)]).style,
          localToPage: transform,
          eraserSegment: _ok(
            SweptPath.create([_point(9.04, 1.01)], maximumPoints: 1),
          ),
          radius: 0,
          handwritingLimits: _limits,
        ),
      );
      expect(miss, isEmpty);
    },
  );

  test('rotation and nonuniform scale classify in both composition orders', () {
    final rotation = _ok(
      AffineTransform2D.fromOperation(
        _ok(
          RotationTransformOperation2D.create(
            radians: .73,
            pivot: _point(0, 0),
          ),
        ),
      ),
    );
    final scale = _ok(
      AffineTransform2D.fromOperation(
        _ok(
          ScaleTransformOperation2D.create(
            scaleX: 4,
            scaleY: .5,
            pivot: _point(0, 0),
          ),
        ),
      ),
    );
    final resolver = StrokeGeometryResolver(_geometryLimits());
    for (final transform in [
      _ok(rotation.then(scale)),
      _ok(scale.then(rotation)),
    ]) {
      final pageHit = _ok(transform.applyToPoint(_point(3.7, .9999999)));
      final pageMiss = _ok(transform.applyToPoint(_point(3.7, 1.0000001)));
      List<StrokeErasureInterval> classify(Point2 point) => _ok(
        resolver.classifySourceSegmentErasure(
          first: _sample(0, 0, 0),
          second: _sample(10, 0, 10),
          style: _stroke(1, [_sample(0, 0, 0)]).style,
          localToPage: transform,
          eraserSegment: _ok(SweptPath.create([point], maximumPoints: 1)),
          radius: 0,
          handwritingLimits: _limits,
        ),
      );
      expect(classify(pageHit), isNotEmpty);
      expect(classify(pageMiss), isEmpty);
    }
  });

  test('zero-radius ambiguity uses measurable bounded exact fallback', () {
    final resolver = StrokeGeometryResolver(_geometryLimits());
    final evidence = _ok(
      resolver.classifySourceSegmentErasureDetailed(
        first: _sample(0, 0, 0),
        second: _sample(10, 0, 10),
        style: _stroke(1, [_sample(0, 0, 0)]).style,
        localToPage: _identity(),
        eraserSegment: _ok(SweptPath.create([_point(5, 0)], maximumPoints: 1)),
        radius: 0,
        handwritingLimits: _limits,
        maximumChecks: 256,
      ),
    );
    expect(evidence.intervals, isNotEmpty);
    expect(evidence.ordinaryAnalyticClassifications, 0);
    expect(evidence.exactFallbackClassifications, 1);
    expect(evidence.exactFallbackExhaustions, 0);
  });

  test('certified positive-radius search preserves narrow near tangencies', () {
    final resolver = StrokeGeometryResolver(_geometryLimits());
    final style = _stroke(1, [_sample(0, 0, 0)]).style;
    List<StrokeErasureInterval> classify(double radius) => _ok(
      resolver.classifySourceSegmentErasure(
        first: _sample(0, 0, 0),
        second: _sample(10, 0, 10),
        style: style,
        localToPage: _identity(),
        eraserSegment: _ok(
          SweptPath.create([_point(5.123456789, 1.000001)], maximumPoints: 1),
        ),
        radius: radius,
        handwritingLimits: _limits,
      ),
    );

    final hit = classify(1.1e-6);
    expect(hit, hasLength(1));
    expect(hit.single.start, lessThan(.5123456789));
    expect(hit.single.end, greaterThan(.5123456789));
    expect(classify(9e-7), isEmpty);

    final endpoint = _ok(
      resolver.classifySourceSegmentErasure(
        first: _sample(0, 0, 0),
        second: _sample(-10, 0, 10),
        style: style,
        localToPage: _identity(),
        eraserSegment: _ok(SweptPath.create([_point(1, 0)], maximumPoints: 1)),
        radius: 0,
        handwritingLimits: _limits,
      ),
    );
    expect(endpoint, hasLength(1));
    expect(endpoint.single.start, 0);
    expect(endpoint.single.end, 0);
  });

  test('near-tangent analytic classification resumes without replay', () {
    final resolver = StrokeGeometryResolver(_geometryLimits());
    final stroke = _stroke(1, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final prepared = _ok(
      resolver.prepareStrokeErasure(stroke: stroke, localToPage: _identity()),
    );
    final classification = _ok(
      resolver.beginPreparedSourceSegmentErasure(
        prepared: prepared,
        sourceSegment: 0,
        eraserSegment: _ok(
          SweptPath.create([_point(5.123456789, 1.000001)], maximumPoints: 1),
        ),
        radius: 1.1e-6,
        maximumChecks: 256,
      ),
    );
    StrokeErasureClassificationEvidence? evidence;
    var frames = 0;
    var predicates = 0;
    var roots = 0;
    while (evidence == null && frames < 256) {
      final progress = _ok(
        classification.advance(
          maximumPredicateEvaluations: 1,
          maximumRootIsolationAdvances: 1,
          maximumFeatureTransitions: 32,
          maximumElapsedMicros: 1000000,
        ),
      );
      expect(progress.predicateEvaluations, lessThanOrEqualTo(1));
      expect(progress.rootIsolationAdvances, lessThanOrEqualTo(1));
      expect(progress.featureTransitions, lessThanOrEqualTo(32));
      predicates += progress.predicateEvaluations;
      roots += progress.rootIsolationAdvances;
      evidence = progress.evidence;
      frames += 1;
    }
    expect(evidence, isNotNull);
    expect(frames, greaterThan(2));
    expect(roots, 0);
    expect(evidence!.intervals, hasLength(1));
    expect(evidence.classificationChecks, predicates);
    expect(evidence.maximumSearchDepth, 0);
    expect(evidence.ordinaryAnalyticClassifications, 1);
    expect(evidence.exactFallbackClassifications, 0);
    expect(evidence.exactFallbackExhaustions, 0);
  });

  test('certified roots remain distinct below the former merge epsilon', () {
    final tinyStyle = _ok(
      StrokeStyle.create(
        argb: 0xff000000,
        opacity: 1,
        baseWidth: 1e-9,
        pressureInfluence: 0,
        minimumPressureFactor: 0,
        limits: _limits,
      ),
    );
    final intervals = _ok(
      StrokeGeometryResolver(_geometryLimits()).classifySourceSegmentErasure(
        first: _sample(0, 0, 0),
        second: _sample(10000, 0, 10),
        style: tinyStyle,
        localToPage: _identity(),
        eraserSegment: _ok(
          SweptPath.create([_point(5000, 0)], maximumPoints: 1),
        ),
        radius: 0,
        handwritingLimits: _limits,
      ),
    );
    expect(intervals, hasLength(1));
    expect(intervals.single.end, greaterThan(intervals.single.start));
    expect(intervals.single.end - intervals.single.start, lessThan(1e-12));
  });

  test(
    'positive-radius certification covers affine order width and features',
    () {
      final rotation = _ok(
        AffineTransform2D.fromOperation(
          _ok(
            RotationTransformOperation2D.create(
              radians: .41,
              pivot: _point(0, 0),
            ),
          ),
        ),
      );
      final scale = _ok(
        AffineTransform2D.fromOperation(
          _ok(
            ScaleTransformOperation2D.create(
              scaleX: 3,
              scaleY: .4,
              pivot: _point(0, 0),
            ),
          ),
        ),
      );
      final variableStyle = _ok(
        StrokeStyle.create(
          argb: 0xff000000,
          opacity: 1,
          baseWidth: 2,
          pressureInfluence: .8,
          minimumPressureFactor: .1,
          limits: _limits,
        ),
      );
      final first = _ok(
        StrokeSample.create(
          position: _point(0, 0),
          timeMicros: 0,
          pressure: 0,
          limits: _limits,
        ),
      );
      final second = _ok(
        StrokeSample.create(
          position: _point(10, 0),
          timeMicros: 10,
          pressure: 1,
          limits: _limits,
        ),
      );
      for (final transform in [
        _ok(rotation.then(scale)),
        _ok(scale.then(rotation)),
        _ok(AffineTransform2D.restoreFromStorage([1, .75, .4, 1, 0, 0])),
      ]) {
        for (final radius in [double.minPositive, 1e-9, .25, 1000.0]) {
          final page = _ok(transform.applyToPoint(_point(5, 0)));
          final hit = _ok(
            StrokeGeometryResolver(
              _geometryLimits(),
            ).classifySourceSegmentErasure(
              first: first,
              second: second,
              style: variableStyle,
              localToPage: transform,
              eraserSegment: _ok(
                SweptPath.create([
                  page,
                  _ok(transform.applyToPoint(_point(5, .2))),
                ], maximumPoints: 2),
              ),
              radius: radius,
              handwritingLimits: _limits,
            ),
          );
          expect(hit, isNotEmpty);
        }
      }

      final dot = _ok(
        StrokeGeometryResolver(_geometryLimits()).classifySourceSegmentErasure(
          first: first,
          second: first,
          style: variableStyle,
          localToPage: _identity(),
          eraserSegment: _ok(
            SweptPath.create([_point(0, 0)], maximumPoints: 1),
          ),
          radius: .1,
          handwritingLimits: _limits,
        ),
      );
      expect(dot, hasLength(1));
      expect(dot.single.start, 0);
      expect(dot.single.end, 1);
    },
  );

  test('extreme prepared erasure is exact or fails instead of empty', () {
    final resolver = StrokeGeometryResolver(_geometryLimits());
    final style = _stroke(1, [_sample(0, 0, 0)]).style;
    final translated = _ok(
      AffineTransform2D.restoreFromStorage([1, 0, 0, 1, 1e300, -1e300]),
    );
    for (final evidence in [
      (point: _point(1e300, -1e300), hit: true),
      (point: _point(-1e300, 1e300), hit: false),
    ]) {
      final result = resolver.classifySourceSegmentErasure(
        first: _sample(0, 0, 0),
        second: _sample(10, 0, 10),
        style: style,
        localToPage: translated,
        eraserSegment: _ok(
          SweptPath.create([evidence.point], maximumPoints: 1),
        ),
        radius: 1,
        handwritingLimits: _limits,
      );
      expect(result, isA<Ok<Object?, Object?>>());
      expect(_ok(result).isNotEmpty, evidence.hit);
    }

    final nonrepresentable = AffineTransform2D.restoreFromStorage([
      1e308,
      0,
      0,
      1e-308,
      0,
      0,
    ]);
    expect(nonrepresentable, isA<Err<Object?, Object?>>());
    expect(nonrepresentable.toString(), isNot(contains('1e+308')));

    final limited = resolver.classifySourceSegmentErasureDetailed(
      first: _sample(0, 0, 0),
      second: _sample(10, 0, 10),
      style: style,
      localToPage: _identity(),
      eraserSegment: _ok(SweptPath.create([_point(5, 1)], maximumPoints: 1)),
      radius: 0,
      handwritingLimits: _limits,
      maximumChecks: 2,
    );
    expect(limited, isA<Err<Object?, Object?>>());
    expect(limited.toString(), isNot(contains('secret')));
  });

  test('transformed Partial Eraser preview equals terminal survivors', () {
    final source = _stroke(5, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final transform = _ok(
      AffineTransform2D.restoreFromStorage([1, 4, 0, 1, 0, 0]),
    );
    final resolver = StrokeGeometryResolver(_geometryLimits());
    final sourceGeometry = _ok(
      resolver.resolve(stroke: source, localToPage: transform),
    );
    final path = [_point(8.96, .99)];
    final preview = _ok(
      previewStrokeSplitByEraser(
        source: source,
        sourceGeometry: sourceGeometry,
        eraserPath: path,
        radius: 0,
        localToPage: transform,
        geometryResolver: resolver,
        maximumEraserPoints: 1,
        maximumIntersections: 8,
        maximumFragments: 4,
        maximumOutputSamples: 16,
        handwritingLimits: _limits,
      ),
    );
    final terminal = _ok(
      splitStrokeByEraser(
        source: source,
        eraserPath: path,
        radius: 0,
        localToPage: transform,
        geometryResolver: resolver,
        strokeIdGenerator: _CountingUuidGenerator(),
        existingIds: {source.id},
        maximumExistingIds: 1,
        maximumEraserPoints: 1,
        maximumIntersections: 8,
        maximumFragments: 4,
        maximumOutputSamples: 16,
        handwritingLimits: _limits,
      ),
    );
    List<List<StrokeSample>> samples(StrokeSplitResult value) =>
        value.strokes.map((stroke) => stroke.samples).toList();
    expect(samples(preview), samples(terminal));
  });

  test('classification limits fail redacted before UUID allocation', () {
    final source = _stroke(4, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final resolver = StrokeGeometryResolver(
      _ok(
        StrokeGeometryLimits.create(
          maximumElements: 128,
          maximumVertices: 2048,
          ellipseVertexCount: 16,
          maximumContainmentChecks: 1,
        ),
      ),
    );
    final generator = _CountingUuidGenerator();
    final result = splitStrokeByEraser(
      source: source,
      eraserPath: [_point(5, .99)],
      radius: 0,
      localToPage: _identity(),
      geometryResolver: resolver,
      strokeIdGenerator: generator,
      existingIds: {source.id},
      maximumExistingIds: 1,
      maximumEraserPoints: 1,
      maximumIntersections: 8,
      maximumFragments: 4,
      maximumOutputSamples: 16,
      handwritingLimits: _limits,
    );
    expect(result, isA<Err<Object?, Object?>>());
    expect(result.toString(), isNot(contains('5')));
    expect(generator.calls, 0);
  });

  test('aggregate Partial Eraser work exhaustion is atomic and redacted', () {
    final object = _object(7, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final root = _rootWithObject(object);
    final coordinator = _coordinator(root);
    final plan = _ok(
      PartialEraseGesturePlan.prepare(
        document: coordinator.snapshot,
        pageId: root.pages.single.id,
        radius: .1,
        handwritingLimits: _limits,
        objectRegistry: _objectRegistry(),
        geometryResolver: StrokeGeometryResolver(_geometryLimits()),
        maximumObjects: 1,
        maximumStrokes: 1,
        maximumPoints: 4,
        maximumIntersections: 8,
        maximumFragments: 4,
        maximumOutputSamples: 16,
        maximumOperations: 1,
        maximumClassificationChecks: 1,
      ),
    );
    final before = coordinator.snapshot.root;
    final result = plan.acceptPoint(_point(5, 0));
    expect(result, isA<Err<Object?, Object?>>());
    expect(result.toString(), isNot(contains('5')));
    expect(plan.classificationCheckCount, 1);
    expect(plan.pointCount, 0);
    expect(plan.hasChanges, isFalse);
    expect(coordinator.snapshot.root, same(before));
    final generator = _CountingUuidGenerator();
    expect(
      plan.createRequest(uuidGenerator: generator),
      isA<Err<Object?, Object?>>(),
    );
    expect(generator.calls, 0);
  });

  test('overflowed swept bounds fall back without false hit results', () {
    final geometry = _ok(
      StrokeGeometryResolver(_geometryLimits()).resolve(
        stroke: _stroke(2, [_sample(0, 0, 0), _sample(10, 0, 1)]),
        localToPage: _identity(),
      ),
    );
    Result<bool, StructuredFailure> query(List<Point2> points, double radius) =>
        geometry.intersectsSweptPath(
          _ok(SweptPath.create(points, maximumPoints: points.length)),
          radius,
        );
    expect(_ok(query([_point(1e308, 0)], 1.1e308)), isTrue);
    expect(_ok(query([_point(-1e308, 0)], 1.1e308)), isTrue);
    expect(_ok(query([_point(1e308, 1e308)], 1.1e308)), isFalse);
    expect(_ok(query([_point(-1e308, 0), _point(1e308, 0)], 0)), isTrue);
  });

  test('SweptPath owns bounded hostile input without consulting length', () {
    final points = [_point(0, 0), _point(1, 0)];
    for (final reportedLength in [0, 999]) {
      final hostile = _HostilePointList(points, reportedLength: reportedLength);
      final captured = _ok(SweptPath.create(hostile, maximumPoints: 2));
      expect(captured.points, points);
      expect(hostile.lengthRead, isFalse);
      expect(() => captured.points.add(points.first), throwsUnsupportedError);
    }
    for (final hostile in <_HostilePointList>[
      _HostilePointList(points, throwLength: true),
      _HostilePointList(points, throwIterator: true),
      _HostilePointList(points, throwMoveAt: 0),
      _HostilePointList(points, throwCurrentAt: 0),
      _HostilePointList(points, infinite: true),
    ]) {
      final result = SweptPath.create(hostile, maximumPoints: 2);
      if (!hostile.throwLength) {
        expect(result, isA<Err<Object?, Object?>>());
        expect(result.toString(), isNot(contains('secret-swept-path')));
      } else {
        expect(result, isA<Ok<Object?, Object?>>());
        expect(hostile.lengthRead, isFalse);
      }
    }
    final tail = _HostilePointList(points, infinite: true);
    expect(
      SweptPath.create(tail, maximumPoints: 2),
      isA<Err<Object?, Object?>>(),
    );
    expect(tail.rejectedTailCurrentRead, isFalse);
    expect(
      SweptPath.create(points, maximumPoints: 0),
      isA<Err<Object?, Object?>>(),
    );
  });

  test('SweptPath compacts only exact duplicate same-direction evidence', () {
    expect(
      _ok(
        SweptPath.isRedundantMiddle(
          first: _point(0, 0),
          middle: _point(1, 0),
          last: _point(2, 0),
        ),
      ),
      isTrue,
    );
    expect(
      _ok(
        SweptPath.isRedundantMiddle(
          first: _point(0, 0),
          middle: _point(0, 0),
          last: _point(1, 0),
        ),
      ),
      isTrue,
    );
    expect(
      _ok(
        SweptPath.isRedundantMiddle(
          first: _point(0, 0),
          middle: _point(1, 0),
          last: _point(.5, 0),
        ),
      ),
      isFalse,
    );
    expect(
      _ok(
        SweptPath.isRedundantMiddle(
          first: _point(0, 0),
          middle: _point(1, double.minPositive),
          last: _point(2, 0),
        ),
      ),
      isFalse,
    );
    expect(
      _ok(
        SweptPath.isRedundantMiddle(
          first: _point(0, 0),
          middle: _point(1, 1),
          last: _point(2, 0),
        ),
      ),
      isFalse,
    );
  });

  test(
    'GeometryQueryPolygon bounds hostile input and validates simplicity',
    () {
      final triangle = [_point(0, 0), _point(4, 0), _point(0, 4)];
      for (final reportedLength in [0, 999]) {
        final hostile = _HostilePointList(
          triangle,
          reportedLength: reportedLength,
        );
        final polygon = _ok(
          GeometryQueryPolygon.create(hostile, maximumPoints: 3),
        );
        expect(polygon.points, triangle);
        expect(hostile.lengthRead, isFalse);
        expect(hostile.currentReadCount, 3);
        expect(
          () => polygon.points.add(triangle.first),
          throwsUnsupportedError,
        );
      }
      final throwingLength = _HostilePointList(triangle, throwLength: true);
      expect(
        GeometryQueryPolygon.create(throwingLength, maximumPoints: 3),
        isA<Ok<Object?, Object?>>(),
      );
      expect(throwingLength.lengthRead, isFalse);

      for (final hostile in [
        _HostilePointList(triangle, throwIterator: true),
        _HostilePointList(triangle, throwMoveAt: 0),
        _HostilePointList(triangle, throwCurrentAt: 0),
      ]) {
        final result = GeometryQueryPolygon.create(hostile, maximumPoints: 3);
        expect(result, isA<Err<Object?, Object?>>());
        expect(result.toString(), isNot(contains('secret-swept-path')));
      }
      final infinite = _HostilePointList(triangle, infinite: true);
      expect(
        GeometryQueryPolygon.create(infinite, maximumPoints: 3),
        isA<Err<Object?, Object?>>(),
      );
      expect(infinite.rejectedTailCurrentRead, isFalse);
      final rejectedTail = _HostilePointList([
        ...triangle,
        _point(4, 4),
      ], throwCurrentAt: 3);
      expect(
        GeometryQueryPolygon.create(rejectedTail, maximumPoints: 3),
        isA<Err<Object?, Object?>>(),
      );
      expect(rejectedTail.currentReadCount, 3);
      expect(
        GeometryQueryPolygon.create(triangle.take(2), maximumPoints: 3),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        GeometryQueryPolygon.create([
          triangle.first,
          triangle[1],
          triangle.first,
        ], maximumPoints: 3),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        GeometryQueryPolygon.create([
          _point(0, 0),
          _point(1, 0),
          _point(2, 0),
        ], maximumPoints: 3),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        GeometryQueryPolygon.create([
          _point(0, 0),
          _point(2, 2),
          _point(0, 2),
          _point(2, 0),
        ], maximumPoints: 4),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        GeometryQueryPolygon.create(triangle, maximumPoints: 2),
        isA<Err<Object?, Object?>>(),
      );
    },
  );

  test('Page lasso captures one typed polygon and reuses it per Object', () {
    final definition = _PolygonIdentityHitDefinition();
    final tester = PageHitTester(
      objectRegistry: _objectRegistry(),
      hitTestingRegistry: _ok(
        HitTestingRegistry.create(
          [definition],
          maximumDefinitions: 1,
          maximumBehaviorResults: 1,
        ),
      ),
      maximumCandidates: 2,
      maximumResults: 2,
      maximumLassoPoints: 3,
    );
    final input = _HostilePointList([
      _point(-2, -2),
      _point(20, -2),
      _point(-2, 20),
    ], reportedLength: 999);
    final page = testPage(
      layers: [
        testContentLayer(
          objects: [
            _object(301, [_sample(0, 0, 0)]),
            _object(302, [_sample(1, 1, 0)]),
          ],
        ),
      ],
    );
    expect(
      tester.lasso(page: page, polygon: input, mode: AreaHitMode.intersection),
      isA<Ok<Object?, Object?>>(),
    );
    expect(input.iteratorCreationCount, 1);
    expect(input.currentReadCount, 3);
    expect(definition.polygons, hasLength(2));
    expect(
      identical(definition.polygons.first, definition.polygons.last),
      isTrue,
    );
  });

  test('StrokeSplitResult validates scalar evidence and invariants', () {
    final stroke = _stroke(6, [_sample(0, 0, 0), _sample(1, 0, 1)]);
    final valid = _ok(
      StrokeSplitResult.create(
        strokes: [stroke],
        maximumStrokes: 1,
        intersectionCount: 1,
        outputSampleCount: 2,
        affected: true,
      ),
    );
    expect(valid.strokes, [stroke]);
    expect(() => valid.strokes.add(stroke), throwsUnsupportedError);
    expect(
      StrokeSplitResult.create(
        strokes: const [],
        maximumStrokes: 1,
        intersectionCount: Revision.maximumValue,
        affected: true,
      ),
      isA<Ok<Object?, Object?>>(),
    );
    for (final result in [
      StrokeSplitResult.create(
        strokes: [stroke],
        maximumStrokes: 1,
        intersectionCount: -1,
        outputSampleCount: 2,
        affected: true,
      ),
      StrokeSplitResult.create(
        strokes: [stroke],
        maximumStrokes: 1,
        intersectionCount: Revision.maximumValue + 1,
        outputSampleCount: 2,
        affected: true,
      ),
      StrokeSplitResult.create(
        strokes: [stroke],
        maximumStrokes: 1,
        outputSampleCount: -1,
        affected: true,
      ),
      StrokeSplitResult.create(
        strokes: [stroke],
        maximumStrokes: 1,
        outputSampleCount: Revision.maximumValue + 1,
        affected: true,
      ),
      StrokeSplitResult.create(
        strokes: [stroke],
        maximumStrokes: 1,
        outputSampleCount: 1,
        affected: true,
      ),
      StrokeSplitResult.create(
        strokes: [stroke],
        maximumStrokes: 1,
        intersectionCount: 1,
      ),
      StrokeSplitResult.create(strokes: [stroke, stroke], maximumStrokes: 2),
    ]) {
      expect(result, isA<Err<Object?, Object?>>());
      expect(
        result.toString(),
        isNot(contains('${Revision.maximumValue + 1}')),
      );
    }
  });

  test(
    'Phase 6 diagnostic trace is bounded ordered redacted and disableable',
    () {
      final trace = _ok(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 3),
      );
      for (var index = 0; index < 5; index += 1) {
        trace.record(
          stage: Phase6DiagnosticStage.partialMoveCompleted,
          pointerSegments: index,
          classificationChecks: index * 2,
        );
      }
      expect(trace.events.map((event) => event.sequence), [2, 3, 4]);
      final text = trace.copyText();
      expect(text, contains('stage=partialMoveCompleted'));
      expect(text, contains('checks=8'));
      expect(text, isNot(contains('coordinate')));
      expect(text, isNot(contains('strokeSamples')));
      expect(text, isNot(contains('secret')));

      final disabled = _ok(
        Phase6DiagnosticTrace.create(enabled: false, capacity: 1),
      );
      disabled.record(stage: Phase6DiagnosticStage.partialMoveEntered);
      expect(disabled.events, isEmpty);
      expect(disabled.copyText(), isEmpty);
      expect(
        Phase6DiagnosticTrace.create(enabled: true, capacity: 65),
        isA<Err<Object?, Object?>>(),
      );
    },
  );

  test('diagnostics aggregate per gesture stages and reset baselines', () {
    final trace = _ok(
      Phase6DiagnosticTrace.create(enabled: true, capacity: 64),
    );
    expect(trace.beginGesture(), 1);
    trace.record(
      stage: Phase6DiagnosticStage.intervalClassification,
      elapsedMicros: 40,
      processedBatchSize: 8,
      eventBacklog: 12,
      workBudgetUsed: 20,
      workBudgetRemaining: 80,
    );
    trace.record(
      stage: Phase6DiagnosticStage.intervalClassification,
      elapsedMicros: 60,
      processedBatchSize: 4,
      workBudgetUsed: 30,
      workBudgetRemaining: 70,
    );
    trace.record(
      stage: Phase6DiagnosticStage.sceneComposition,
      elapsedMicros: 25,
    );
    expect(trace.copyText(), contains('dominant=intervalClassification'));
    expect(trace.copyText(), contains('totalMicros=100'));
    expect(trace.copyText(), contains('invocations=2'));

    expect(trace.beginGesture(), 2);
    trace.record(
      stage: Phase6DiagnosticStage.sceneComposition,
      elapsedMicros: 7,
    );
    final second = trace.copyText();
    expect(second, contains('gesture=2 dominant=sceneComposition'));
    expect(second, contains('totalMicros=7'));
    expect(second, isNot(contains('totalMicros=100')));
    expect(second, isNot(contains('secret')));
  });

  test('split captures hostile existing IDs before UUID allocation', () {
    final source = _stroke(3, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final owned = _HostileStrokeList(
      [source.id],
      reportedLength: 999,
      throwContains: true,
    );
    final generator = _CountingUuidGenerator();
    final split = splitStrokeByEraser(
      source: source,
      eraserPath: [_point(5, 0)],
      radius: .1,
      localToPage: _identity(),
      geometryResolver: StrokeGeometryResolver(_geometryLimits()),
      strokeIdGenerator: generator,
      existingIds: owned,
      maximumExistingIds: 1,
      maximumEraserPoints: 1,
      maximumIntersections: 8,
      maximumFragments: 4,
      maximumOutputSamples: 16,
      handwritingLimits: _limits,
    );
    expect(split, isA<Ok<Object?, Object?>>());
    expect(owned.lengthRead, isFalse);
    expect(owned.containsRead, isFalse);
    expect(generator.calls, 2);

    final ignoredLengths = [
      _HostileStrokeList([source.id], reportedLength: 0),
      _HostileStrokeList([source.id], throwLength: true),
    ];
    for (final ids in ignoredLengths) {
      final idsGenerator = _CountingUuidGenerator();
      expect(
        splitStrokeByEraser(
          source: source,
          eraserPath: [_point(50, 0)],
          radius: 0,
          localToPage: _identity(),
          geometryResolver: StrokeGeometryResolver(_geometryLimits()),
          strokeIdGenerator: idsGenerator,
          existingIds: ids,
          maximumExistingIds: 1,
          maximumEraserPoints: 1,
          maximumIntersections: 8,
          maximumFragments: 4,
          maximumOutputSamples: 16,
          handwritingLimits: _limits,
        ),
        isA<Ok<Object?, Object?>>(),
      );
      expect(ids.lengthRead, isFalse);
      expect(idsGenerator.calls, 0);
    }

    for (final ids in [
      _HostileStrokeList([source.id], throwIterator: true),
      _HostileStrokeList([source.id], throwMoveAt: 0),
      _HostileStrokeList([source.id], throwCurrentAt: 0),
    ]) {
      final idsGenerator = _CountingUuidGenerator();
      final result = splitStrokeByEraser(
        source: source,
        eraserPath: [_point(5, 0)],
        radius: .1,
        localToPage: _identity(),
        geometryResolver: StrokeGeometryResolver(_geometryLimits()),
        strokeIdGenerator: idsGenerator,
        existingIds: ids,
        maximumExistingIds: 1,
        maximumEraserPoints: 1,
        maximumIntersections: 8,
        maximumFragments: 4,
        maximumOutputSamples: 16,
        handwritingLimits: _limits,
      );
      expect(result, isA<Err<Object?, Object?>>());
      expect(result.toString(), isNot(contains('secret')));
      expect(idsGenerator.calls, 0);
    }

    final rejected = _HostileStrokeList([source.id], infinite: true);
    final rejectedGenerator = _CountingUuidGenerator();
    final failure = splitStrokeByEraser(
      source: source,
      eraserPath: [_point(5, 0)],
      radius: .1,
      localToPage: _identity(),
      geometryResolver: StrokeGeometryResolver(_geometryLimits()),
      strokeIdGenerator: rejectedGenerator,
      existingIds: rejected,
      maximumExistingIds: 1,
      maximumEraserPoints: 1,
      maximumIntersections: 8,
      maximumFragments: 4,
      maximumOutputSamples: 16,
      handwritingLimits: _limits,
    );
    expect(failure, isA<Err<Object?, Object?>>());
    expect(failure.toString(), isNot(contains('secret')));
    expect(rejected.rejectedTailCurrentRead, isFalse);
    expect(rejectedGenerator.calls, 0);
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
      maximumCandidates: 8,
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
        maximumCandidates: 4,
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
          polygon: _ok(
            GeometryQueryPolygon.create([
              _point(0, 0),
              _point(1, 0),
              _point(0, 1),
            ], maximumPoints: 3),
          ),
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
      maximumCandidates: 2,
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

  test('whole Eraser plan reuses prepared geometry and target evidence', () {
    final first = _object(110, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final second = _object(111, [_sample(0, 10, 0), _sample(10, 10, 10)]);
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
    final plan = _ok(
      WholeEraseGesturePlan.prepare(
        document: snapshot,
        pageId: root.pages.single.id,
        radius: .2,
        handwritingLimits: _limits,
        objectRegistry: _objectRegistry(),
        geometryResolver: StrokeGeometryResolver(_geometryLimits()),
        maximumObjects: 8,
        maximumStrokes: 8,
        maximumPoints: 8,
        maximumTargets: 8,
        maximumOperations: 4,
      ),
    );
    expect(_ok(plan.acceptPoint(_point(5, -5))).newlyAffectedStrokeCount, 0);
    expect(_ok(plan.acceptPoint(_point(5, 1))).newlyAffectedStrokeCount, 1);
    expect(_ok(plan.acceptPoint(_point(5, 11))).newlyAffectedStrokeCount, 1);
    expect(plan.processedSegmentCount, 3);
    expect(plan.affectedStrokeCount, 2);
    expect(plan.previews, hasLength(2));
    final checksBeforeTerminal = plan.geometryCheckCount;
    final generator = _CountingUuidGenerator();
    final request = _ok(plan.createRequest(uuidGenerator: generator));
    expect(request.removals, [first.id, second.id]);
    expect(generator.calls, 1);
    expect(plan.processedSegmentCount, 3);
    expect(plan.geometryCheckCount, checksBeforeTerminal);
  });

  test(
    'cached committed scene avoids rendering callbacks across Eraser moves',
    () {
      final object = _object(114, [_sample(0, 0, 0), _sample(10, 0, 10)]);
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
      final registry = _objectRegistry();
      final geometry = StrokeGeometryResolver(_geometryLimits());
      final rendering = _CountingRenderingDefinition(
        HandwritingRenderingDefinition(
          handwritingLimits: _limits,
          geometryResolver: geometry,
        ),
      );
      final builder = PageSceneBuilder(
        objectRegistry: registry,
        renderingRegistry: _ok(
          RenderingRegistry.create([rendering], maximumDefinitions: 1),
        ),
        limits: _renderingLimits(),
      );
      final snapshot = _coordinator(root).snapshot;
      final viewport = _viewport(origin: _point(0, 0), zoom: 1);
      final committed = _ok(
        builder.buildCommitted(
          page: root.pages.single,
          viewport: viewport,
          documentRevision: snapshot.revisions.document,
        ),
      );
      expect(rendering.calls, 1);
      final plan = _ok(
        WholeEraseGesturePlan.prepare(
          document: snapshot,
          pageId: root.pages.single.id,
          radius: .2,
          handwritingLimits: _limits,
          objectRegistry: registry,
          geometryResolver: geometry,
          maximumObjects: 8,
          maximumStrokes: 8,
          maximumPoints: 64,
          maximumTargets: 8,
          maximumOperations: 4,
        ),
      );
      expect(plan.geometryResolutionCount, 1);
      var committedCompositions = 1;
      _ok(builder.compose(committed: committed));
      for (var index = 0; index < 40; index += 1) {
        final update = _ok(plan.acceptPoint(_point(5, index.isEven ? -2 : 2)));
        if (update.changedObjectIds.isNotEmpty) {
          committedCompositions += 1;
          _ok(
            builder.compose(
              committed: committed,
              excludedObjectIds: update.changedObjectIds
                  .map(plan.previewFor)
                  .whereType<EraserPreviewObject>()
                  .map((preview) => preview.objectId),
            ),
          );
        }
        _ok(builder.composeOverlays(committed: committed));
      }
      expect(plan.processedSegmentCount, 40);
      expect(plan.geometryResolutionCount, 1);
      expect(committedCompositions, 2);
      expect(rendering.calls, 1);
    },
  );

  test(
    'partial Eraser plan applies each segment once and commits its preview',
    () {
      final object = _object(112, [_sample(0, 0, 0), _sample(10, 0, 10)]);
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
      final snapshot = _coordinator(root).snapshot;
      final plan = _ok(
        PartialEraseGesturePlan.prepare(
          document: snapshot,
          pageId: root.pages.single.id,
          radius: .2,
          handwritingLimits: _limits,
          objectRegistry: _objectRegistry(),
          geometryResolver: StrokeGeometryResolver(_geometryLimits()),
          maximumObjects: 8,
          maximumStrokes: 8,
          maximumPoints: 64,
          maximumIntersections: 16,
          maximumFragments: 16,
          maximumOutputSamples: 64,
          maximumOperations: 4,
          maximumClassificationChecks: 100000,
        ),
      );
      expect(plan.preparedObjectCount, 1);
      expect(plan.geometryResolutionCount, 1);
      _ok(plan.acceptPoint(_point(5, -1)));
      _ok(plan.acceptPoint(_point(5, 1)));
      expect(plan.processedSegmentCount, 2);
      expect(plan.hasChanges, isTrue);
      final preview = plan.previews.single.strokes;
      expect(preview.single.stroke, _payload(object).strokes.single);
      expect(plan.geometryResolutionCount, 1);
      final resolutionsAfterSplit = plan.geometryResolutionCount;
      for (var index = 0; index < 20; index += 1) {
        _ok(plan.acceptPoint(_point(50 + index.toDouble(), 50)));
      }
      expect(plan.geometryResolutionCount, resolutionsAfterSplit);
      final splitCallsBeforeTerminal = plan.splitInvocationCount;
      final generator = _CountingUuidGenerator();
      final request = _ok(plan.createRequest(uuidGenerator: generator));
      final committed = _payload(request.replacements.single).strokes;
      expect(committed, hasLength(2));
      expect(generator.calls, committed.length + 1);
      expect(plan.processedSegmentCount, 22);
      expect(plan.splitInvocationCount, splitCallsBeforeTerminal);
      expect(plan.geometryResolutionCount, resolutionsAfterSplit);
      expect(plan.fragmentGeometryResolutionCount, committed.length);
    },
  );

  test('partial Eraser preview is exact transparent survivor geometry', () {
    final erased = _stroke(301, [_sample(0, 0, 0), _sample(10, 0, 10)]);
    final unaffected = _stroke(302, [_sample(0, 10, 0), _sample(10, 10, 10)]);
    final object = testObject(
      id: 301,
      typeKey: handwritingObjectTypeKey,
      schemaVersion: handwritingSchemaVersion,
      payload: _ok(
        HandwritingPayload.create(
          strokes: [erased, unaffected],
          limits: _limits,
        ),
      ).encode(),
    );
    final crossing = _copyObject(
      _object(303, [_sample(5, -5, 0), _sample(5, 5, 10)]),
      locked: true,
    );
    final root = testNotebook(
      sections: [
        testSection(
          pages: [
            testPage(
              layers: [
                testContentLayer(objects: [crossing, object]),
              ],
            ),
          ],
        ),
      ],
    );
    final resolver = StrokeGeometryResolver(_geometryLimits());
    final plan = _ok(
      PartialEraseGesturePlan.prepare(
        document: _coordinator(root).snapshot,
        pageId: root.pages.single.id,
        radius: .25,
        handwritingLimits: _limits,
        objectRegistry: _objectRegistry(),
        geometryResolver: resolver,
        maximumObjects: 2,
        maximumStrokes: 4,
        maximumPoints: 16,
        maximumIntersections: 16,
        maximumFragments: 16,
        maximumOutputSamples: 64,
        maximumOperations: 2,
        maximumClassificationChecks: 100000,
      ),
    );
    final initial = _ok(plan.acceptPoint(_point(5, -1)));
    final update = _ok(plan.acceptPoint(_point(5, 1)));
    expect(update.changedObjectIds, {object.id});
    expect(update.changedObjectIds, isNot(contains(crossing.id)));
    final previewBySegment = <(StrokeId, int), EraserPreviewSegmentUpdate>{};
    for (final evidence in [
      ...initial.previewSegmentUpdates,
      ...update.previewSegmentUpdates,
    ]) {
      previewBySegment[(evidence.strokeId, evidence.sourceSegment)] = evidence;
    }
    expect(previewBySegment.values.map((value) => value.strokeId).toSet(), {
      erased.id,
      unaffected.id,
    });
    final previewElements = previewBySegment.values
        .expand((value) => value.elements)
        .toList(growable: false);
    expect(previewElements, isNotEmpty);
    expect(
      previewElements.any((element) => element.bounds.contains(_point(5, 0))),
      isFalse,
      reason: 'the predicted gap is absent geometry, not an opaque mask',
    );
    final renderingLimits = _renderingLimits();
    final builder = PageSceneBuilder(
      objectRegistry: _objectRegistry(),
      renderingRegistry: _ok(
        RenderingRegistry.create([
          HandwritingRenderingDefinition(
            handwritingLimits: _limits,
            geometryResolver: resolver,
          ),
        ], maximumDefinitions: 1),
      ),
      limits: renderingLimits,
    );
    final committedScene = _ok(
      builder.buildCommitted(
        page: root.pages.single,
        viewport: _viewport(origin: _point(0, 0), zoom: 1),
        documentRevision: _revision(0),
      ),
    );
    final visibleCommitted = _ok(
      builder.compose(
        committed: committedScene,
        excludedObjectIds: {object.id},
      ),
    );
    expect(
      visibleCommitted.primitives,
      committedScene.objects
          .where((value) => value.objectId == crossing.id)
          .single
          .primitives,
      reason: 'the unrelated crossing Object remains visible through the gap',
    );
    expect(
      previewElements.any((element) => element.bounds.contains(_point(5, 10))),
      isTrue,
      reason: 'an unaffected Stroke in the same Object remains visible',
    );

    final created = plan.createRequest(uuidGenerator: _CountingUuidGenerator());
    expect(
      created,
      isA<Ok<AtomicObjectCollectionEditRequest, StructuredFailure>>(),
      reason: '$created',
    );
    final request = _ok(created);
    final terminal = _payload(request.replacements.single);
    final terminalElements = terminal.strokes
        .expand(
          (stroke) => _ok(
            resolver.resolve(stroke: stroke, localToPage: object.transform),
          ).elements,
        )
        .toList(growable: false);
    expect(
      _geometryVertices(previewElements),
      _geometryVertices(terminalElements),
      reason: 'the last preview and terminal publication have equal geometry',
    );
    expect(plan.terminalMaterializationCount, 1);
    expect(
      plan.previewRangeMaterializationCount,
      lessThanOrEqualTo(plan.splitInvocationCount * 2),
    );
  });

  test(
    'many-Object selection reuses bounded candidates and publishes once',
    () {
      final objects = [
        for (var index = 0; index < 80; index += 1)
          _object(400 + index, [
            _sample(10, index * 2.0 + 10, 0),
            _sample(90, index * 2.0 + 10, 1),
          ]),
      ];
      NotebookDocument makeRoot(List<ObjectEnvelope> values) => testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(layers: [testContentLayer(objects: values)]),
            ],
          ),
        ],
      );
      final root = makeRoot(objects);
      final resolver = StrokeGeometryResolver(_geometryLimits());
      final cache = HandwritingGeometryCache(
        maximumObjects: 100,
        maximumStrokes: 100,
      );
      final definition = HandwritingHitTestingDefinition(
        handwritingLimits: _limits,
        geometryResolver: resolver,
        geometryCache: cache,
      );
      final tester = PageHitTester(
        objectRegistry: _objectRegistry(),
        hitTestingRegistry: _ok(
          HitTestingRegistry.create(
            [definition],
            maximumDefinitions: 1,
            maximumBehaviorResults: 100,
          ),
        ),
        maximumCandidates: 100,
        maximumResults: 100,
        maximumLassoPoints: 16,
      );
      final area = _rect(0, 0, 100, 200);
      final first = _ok(
        tester.rectangle(
          page: root.pages.single,
          area: area,
          mode: AreaHitMode.containment,
        ),
      );
      expect(first, hasLength(objects.length));
      expect(tester.candidateIndexBuildCount, 1);
      expect(tester.registryResolutionCount, objects.length);
      expect(cache.resolutionCount, objects.length);
      expect(definition.detailedHitCount, 0);

      final coordinator = _coordinator(root);
      final selection = SelectionController(
        objectRegistry: _objectRegistry(),
        coalescingBoundarySink: coordinator,
        maximumTargets: 100,
        handwritingLimits: _limits,
        strokeGeometryResolver: resolver,
        handwritingGeometryCache: cache,
      );
      final orderedTargets = first.reversed
          .map((value) => value.toSelectionTarget())
          .toList(growable: false);
      _ok(selection.replace(root: root, targets: orderedTargets));
      expect(selection.state.targets, orderedTargets);
      expect(selection.publicationCount, 1);
      expect(selection.targetResolutionCount, objects.length);
      expect(cache.resolutionCount, objects.length);
      _ok(selection.replace(root: root, targets: orderedTargets));
      expect(selection.publicationCount, 1);
      expect(selection.targetResolutionCount, objects.length);

      final changedObjects = [
        ...objects.take(objects.length - 1),
        _copyObject(objects.last, visible: false),
      ];
      final changedRoot = makeRoot(changedObjects);
      final changed = _ok(
        tester.rectangle(
          page: changedRoot.pages.single,
          area: area,
          mode: AreaHitMode.containment,
        ),
      );
      expect(changed, hasLength(objects.length - 1));
      expect(tester.candidateIndexBuildCount, 2);
      expect(tester.registryResolutionCount, objects.length * 2 - 1);
      expect(cache.resolutionCount, objects.length);
      expect(definition.detailedHitCount, 0);
    },
  );

  test(
    'Eraser eligibility is Registry-owned, inert, bounded, and redacted',
    () {
      final valid = _object(115, [_sample(0, 0, 0), _sample(10, 0, 10)]);
      final baseRoot = _rootWithObject(valid);
      final base = _coordinator(baseRoot).snapshot;
      final unavailableRegistry = _ok(
        ObjectRegistry.create([
          TestObjectTypeDefinition(
            typeKey: handwritingObjectTypeKey,
            supportedSchemaVersions: [handwritingSchemaVersion],
            capabilities: const ObjectTypeCapabilities(
              hasIntrinsicGeometry: true,
              discoversResourceReferences: false,
              supportsScopedDuplication: true,
              selectable: true,
            ),
            validationExceptionMessage: 'secret-registry-payload',
          ),
        ]),
      );
      final incapableRegistry = _ok(
        ObjectRegistry.create([
          TestObjectTypeDefinition(
            typeKey: handwritingObjectTypeKey,
            supportedSchemaVersions: [handwritingSchemaVersion],
            capabilities: const ObjectTypeCapabilities(
              hasIntrinsicGeometry: true,
              discoversResourceReferences: false,
              supportsScopedDuplication: true,
              selectable: true,
            ),
          ),
        ]),
      );
      final unknown = _copyObject(valid, typeKey: testObjectTypeKey());
      final invalid = _copyObject(
        valid,
        payload: const PreservedString('invalid-secret-payload'),
      );
      final hidden = _copyObject(valid, visible: false);
      final locked = _copyObject(valid, locked: true);
      for (final entry in <(ObjectEnvelope, ObjectRegistry)>[
        (unknown, _objectRegistry()),
        (_unsupportedSchemaObject(valid), _objectRegistry()),
        (invalid, _objectRegistry()),
        (hidden, _objectRegistry()),
        (locked, _objectRegistry()),
        (valid, unavailableRegistry),
        (valid, incapableRegistry),
      ]) {
        final snapshot = DocumentCoordinatorSnapshot(
          root: _rootWithObject(entry.$1),
          revisions: base.revisions,
          currentContentIdentity: base.currentContentIdentity,
          savedContentIdentity: base.savedContentIdentity,
          canUndo: base.canUndo,
          canRedo: base.canRedo,
          historyTraversalEnabled: base.historyTraversalEnabled,
        );
        final whole = WholeEraseGesturePlan.prepare(
          document: snapshot,
          pageId: snapshot.root.pages.single.id,
          radius: 1,
          handwritingLimits: _limits,
          objectRegistry: entry.$2,
          geometryResolver: StrokeGeometryResolver(_geometryLimits()),
          maximumObjects: 1,
          maximumStrokes: 1,
          maximumPoints: 1,
          maximumTargets: 1,
          maximumOperations: 1,
        );
        final partial = PartialEraseGesturePlan.prepare(
          document: snapshot,
          pageId: snapshot.root.pages.single.id,
          radius: 1,
          handwritingLimits: _limits,
          objectRegistry: entry.$2,
          geometryResolver: StrokeGeometryResolver(_geometryLimits()),
          maximumObjects: 1,
          maximumStrokes: 1,
          maximumPoints: 1,
          maximumIntersections: 2,
          maximumFragments: 2,
          maximumOutputSamples: 4,
          maximumOperations: 1,
          maximumClassificationChecks: 100000,
        );
        final wholePlan = _ok(whole);
        final partialPlan = _ok(partial);
        expect(
          _ok(wholePlan.acceptPoint(_point(5, 0))).newlyAffectedStrokeCount,
          0,
        );
        expect(
          _ok(partialPlan.acceptPoint(_point(5, 0))).newlyAffectedStrokeCount,
          0,
        );
        expect('$whole$partial', isNot(contains('secret')));
      }
    },
  );

  test('Eraser preparation accepts exact Object and Stroke ceilings', () {
    final first = _object(116, [_sample(0, 0, 0)]);
    final second = _object(117, [_sample(10, 0, 0)]);
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
    Result<WholeEraseGesturePlan, StructuredFailure> whole(int ceiling) =>
        WholeEraseGesturePlan.prepare(
          document: snapshot,
          pageId: root.pages.single.id,
          radius: 1,
          handwritingLimits: _limits,
          objectRegistry: _objectRegistry(),
          geometryResolver: StrokeGeometryResolver(_geometryLimits()),
          maximumObjects: ceiling,
          maximumStrokes: ceiling,
          maximumPoints: 1,
          maximumTargets: 2,
          maximumOperations: 2,
        );
    Result<PartialEraseGesturePlan, StructuredFailure> partial(int ceiling) =>
        PartialEraseGesturePlan.prepare(
          document: snapshot,
          pageId: root.pages.single.id,
          radius: 1,
          handwritingLimits: _limits,
          objectRegistry: _objectRegistry(),
          geometryResolver: StrokeGeometryResolver(_geometryLimits()),
          maximumObjects: ceiling,
          maximumStrokes: ceiling,
          maximumPoints: 1,
          maximumIntersections: 2,
          maximumFragments: 2,
          maximumOutputSamples: 4,
          maximumOperations: 2,
          maximumClassificationChecks: 100000,
        );
    expect(whole(2), isA<Ok<WholeEraseGesturePlan, StructuredFailure>>());
    expect(partial(2), isA<Ok<PartialEraseGesturePlan, StructuredFailure>>());
    for (final rejected in [whole(1), partial(1)]) {
      expect(rejected, isA<Err<Object?, StructuredFailure>>());
      final failure = (rejected as Err<Object?, StructuredFailure>).error;
      expect(failure.code, startsWith('drawing.tools.'));
      expect('$failure', isNot(contains('secret')));
    }
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
    final polygon = _ok(
      GeometryQueryPolygon.create([
        _point(-2, -3),
        _point(12, -3),
        _point(12, 3),
        _point(7, 3),
        _point(7, -.5),
        _point(3, -.5),
        _point(3, 3),
        _point(-2, 3),
      ], maximumPoints: 8),
    );
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

  test(
    'long Pen preview copies constant-bounded tails and commits exactly',
    () {
      final limits = _ok(
        HandwritingLimits.create(
          maximumStrokes: 1,
          maximumSamplesPerStroke: 1000,
          maximumUnknownFields: 1,
          maximumNestingDepth: 1,
          maximumUnknownNodes: 4,
          maximumCoordinateMagnitude: 10000,
          maximumStrokeWidth: 100,
          maximumAbsoluteTilt: 2,
          maximumAbsoluteOrientation: 7,
        ),
      );
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
      final session = _ok(
        PenGestureSession.start(
          down: _event(PointerPhase.down),
          document: coordinator.snapshot,
          pageId: root.pages.single.id,
          layerId: root.pages.single.layers.single.id,
          viewport: _viewport(origin: _point(0, 0), zoom: 1),
          preset: PenPreset.fromStyle(
            _ok(
              StrokeStyle.create(
                argb: 0xff000000,
                opacity: 1,
                baseWidth: 2,
                pressureInfluence: 0,
                minimumPressureFactor: 0,
                limits: limits,
              ),
            ),
          ),
          maximumSamples: 1000,
          handwritingLimits: limits,
          uuidGenerator: _CountingUuidGenerator(),
          maximumCommandOperations: 1,
        ),
      );
      expect(session.previewTail!.samples, hasLength(1));
      for (var index = 1; index < 999; index += 1) {
        _ok(
          session.update(
            _event(PointerPhase.move, time: index, x: index.toDouble()),
            viewportRevision: _revision(0),
          ),
        );
        expect(session.previewTail!.samples, hasLength(2));
      }
      expect(session.sampleCount, 999);
      expect(session.previewSampleCopyCount, 1997);
      final request = _ok(
        session.finish(
          _event(PointerPhase.up, time: 999, x: 999),
          latestDocument: coordinator.snapshot,
          viewportRevision: _revision(0),
          pointerOwnerAtTerminal: 1,
        ),
      );
      final stroke = _ok(
        HandwritingPayload.decode(
          request.additions.single.object.payload,
          limits: limits,
        ),
      ).strokes.single;
      expect(stroke.samples, hasLength(1000));
      expect(stroke.samples.first.position, _point(0, 0));
      expect(stroke.samples.last.position, _point(999, 0));
      expect(stroke.samples.last.timeMicros, 999);
    },
  );

  test('shared long-stroke geometry is resolved once for render and hits', () {
    final limits = _ok(
      HandwritingLimits.create(
        maximumStrokes: 256,
        maximumSamplesPerStroke: 120,
        maximumUnknownFields: 1,
        maximumNestingDepth: 1,
        maximumUnknownNodes: 4,
        maximumCoordinateMagnitude: 10000,
        maximumStrokeWidth: 10,
        maximumAbsoluteTilt: 2,
        maximumAbsoluteOrientation: 7,
      ),
    );
    final samples = [
      for (var index = 0; index < 120; index += 1)
        _ok(
          StrokeSample.create(
            position: _point(index.toDouble(), 0),
            timeMicros: index,
            limits: limits,
          ),
        ),
    ];
    final stroke = _ok(
      HandwritingStroke.create(
        id: StrokeId.fromUuid(testUuid(998)),
        samples: samples,
        style: _ok(
          StrokeStyle.create(
            argb: 0xff000000,
            opacity: 1,
            baseWidth: 2,
            pressureInfluence: 0,
            minimumPressureFactor: 0,
            limits: limits,
          ),
        ),
        limits: limits,
      ),
    );
    final object = testObject(
      id: 998,
      typeKey: handwritingObjectTypeKey,
      schemaVersion: handwritingSchemaVersion,
      payload: _ok(
        HandwritingPayload.create(strokes: [stroke], limits: limits),
      ).encode(),
    );
    final geometryLimits = _ok(
      StrokeGeometryLimits.create(
        maximumElements: 256,
        maximumVertices: 4096,
        ellipseVertexCount: 16,
        maximumContainmentChecks: 100000,
      ),
    );
    final resolver = StrokeGeometryResolver(geometryLimits);
    final cache = HandwritingGeometryCache(
      maximumObjects: 4,
      maximumStrokes: 4,
    );
    final rendering = HandwritingRenderingDefinition(
      handwritingLimits: limits,
      geometryResolver: resolver,
      geometryCache: cache,
    );
    final hits = HandwritingHitTestingDefinition(
      handwritingLimits: limits,
      geometryResolver: resolver,
      geometryCache: cache,
    );
    _ok(
      rendering.render(
        object: object,
        viewport: _viewport(origin: _point(0, 0), zoom: 1),
        layerOpacity: 1,
        plane: RenderPlane.committed,
        limits: _ok(
          RenderingLimits.create(
            maximumPrimitives: 256,
            maximumPointsPerPrimitive: 16,
            maximumDamageRegions: 1,
            maximumPreviewOverlays: 1,
            maximumSelectionOverlays: 1,
          ),
        ),
      ),
    );
    expect(cache.resolutionCount, 1);
    for (var index = 0; index < 40; index += 1) {
      expect(
        _ok(
          hits.point(
            object: object,
            pagePosition: _point(60, 0),
            pageTolerance: 1,
          ),
        ),
        stroke.id,
      );
      expect(
        _ok(
          hits.rectangle(
            object: object,
            area: _rect(59, -2, 61, 2),
            mode: AreaHitMode.intersection,
          ),
        ),
        [stroke.id],
      );
    }
    expect(cache.resolutionCount, 1);
    final prepared = _ok(
      cache.prepare(
        object: object,
        handwritingLimits: limits,
        geometryResolver: resolver,
      ),
    );
    final query = _ok(
      prepared.geometries.single.querySweptPath(
        _ok(
          SweptPath.create([_point(60, -1), _point(60, 1)], maximumPoints: 2),
        ),
        .5,
      ),
    );
    expect(query.intersects, isTrue);
    expect(
      query.examinedElements,
      lessThan(prepared.geometries.single.elements.length),
    );

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
    final registry = _ok(
      ObjectRegistry.create([HandwritingObjectTypeDefinition(limits)]),
    );
    final coordinator = _ok(
      DocumentMutationCoordinator.create(
        initialRoot: root,
        validator: DocumentValidator(registry),
        uuidGenerator: _CountingUuidGenerator(),
        historyLimits: _ok(
          HistoryLimits.create(
            maximumRetainedCommandCount: 4,
            maximumEstimatedRetainedBytes: 100000,
          ),
        ),
        retainedCostEstimator: FixedHistoryCostEstimator(1),
        maximumListeners: 1,
      ),
    );
    final whole = _ok(
      WholeEraseGesturePlan.prepare(
        document: coordinator.snapshot,
        pageId: root.pages.single.id,
        radius: .5,
        handwritingLimits: limits,
        objectRegistry: registry,
        geometryResolver: resolver,
        geometryCache: cache,
        maximumObjects: 2,
        maximumStrokes: 2,
        maximumPoints: 720,
        maximumTargets: 2,
        maximumOperations: 2,
      ),
    );
    final partial = _ok(
      PartialEraseGesturePlan.prepare(
        document: coordinator.snapshot,
        pageId: root.pages.single.id,
        radius: .5,
        handwritingLimits: limits,
        objectRegistry: registry,
        geometryResolver: resolver,
        geometryCache: cache,
        maximumObjects: 2,
        maximumStrokes: 2,
        maximumPoints: 720,
        maximumIntersections: 256,
        maximumFragments: 256,
        maximumOutputSamples: 1000,
        maximumOperations: 2,
        maximumClassificationChecks: 100000,
      ),
    );
    for (var start = 0; start < 720; start += 24) {
      final batch = <Point2>[];
      for (var index = start; index < start + 24; index += 1) {
        final point = _point(60, index.isEven ? -1 : 1);
        if (index < 80) _ok(whole.acceptPoint(point));
        batch.add(point);
      }
      _ok(partial.acceptBatch(batch, maximumBatchPoints: 24));
    }
    expect(whole.affectedStrokeCount, 1);
    expect(whole.geometryElementExaminationCount, lessThan(256));
    expect(partial.splitInvocationCount, lessThanOrEqualTo(2880));
    expect(partial.geometryResolutionCount, 1);
    expect(partial.erasurePreparationCount, 1);
    expect(partial.processedSegmentCount, 720);
    expect(partial.processedBatchCount, 30);
    expect(partial.maximumProcessedBatchSize, 24);
    expect(partial.classificationCheckCount, lessThan(1500));
    expect(partial.maximumClassificationDepth, lessThanOrEqualTo(256));
    expect(
      partial.maximumPendingClassificationIntervals,
      lessThanOrEqualTo(64),
    );
    expect(partial.classificationCacheHitCount, greaterThan(700));
    expect(partial.intervalMergeCount, lessThan(20));
    expect(partial.previewRangeMaterializationCount, lessThan(20));
    expect(cache.resolutionCount, 1);
    final classifications = partial.splitInvocationCount;
    final ids = _CountingUuidGenerator();
    final created = partial.createRequest(uuidGenerator: ids);
    expect(
      created,
      isA<Ok<AtomicObjectCollectionEditRequest, StructuredFailure>>(),
      reason: '$created',
    );
    final request = _ok(created);
    expect(partial.splitInvocationCount, classifications);
    expect(partial.terminalMaterializationCount, 1);
    expect(partial.terminalSourceSegmentPassCount, 119);
    final beforeErase = coordinator.snapshot.root;
    _ok(coordinator.execute(request));
    final afterErase = coordinator.snapshot.root;
    expect(afterErase, isNot(beforeErase));
    _ok(coordinator.undo());
    expect(coordinator.snapshot.root, beforeErase);
    _ok(coordinator.redo());
    expect(coordinator.snapshot.root, afterErase);
  });

  test('partial Eraser resumes dense candidate work without replay', () {
    final samples = List<StrokeSample>.generate(
      16,
      (index) => _sample(index.isEven ? 0 : 120, index.isEven ? -1 : 1, index),
      growable: false,
    );
    final object = _object(210, samples);
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
    final plan = _ok(
      PartialEraseGesturePlan.prepare(
        document: _coordinator(root).snapshot,
        pageId: root.pages.single.id,
        radius: .5,
        handwritingLimits: _limits,
        objectRegistry: _objectRegistry(),
        geometryResolver: StrokeGeometryResolver(_geometryLimits()),
        maximumObjects: 2,
        maximumStrokes: 2,
        maximumPoints: 4,
        maximumIntersections: 512,
        maximumFragments: 512,
        maximumOutputSamples: 1000,
        maximumOperations: 2,
        maximumClassificationChecks: 100000,
      ),
    );

    var batches = 0;
    var candidates = 0;
    var classifications = 0;
    var checks = 0;
    Point2? point = _point(60, 0);
    while (true) {
      final batch = _ok(
        plan.processPointWork(
          point: point,
          maximumCandidateSourceSegments: 1,
          maximumClassifications: 1,
          maximumChecks:
              StrokeGeometryResolver.maximumPreparedClassificationChecks,
          maximumRootIsolationAdvances: 8,
          maximumFeatureTransitions: 128,
          maximumElapsedMicros: 1000000,
          materializePreviewEvidence: false,
        ),
      );
      point = null;
      batches += 1;
      candidates += batch.candidateSourceSegments;
      classifications += batch.intervalClassifications;
      checks += batch.classificationChecks;
      expect(batch.candidateSourceSegments, lessThanOrEqualTo(1));
      expect(batch.intervalClassifications, lessThanOrEqualTo(1));
      expect(
        batch.classificationChecks,
        lessThanOrEqualTo(
          StrokeGeometryResolver.maximumPreparedClassificationChecks,
        ),
      );
      if (batch.pointCompleted) {
        expect(batch.update, isNotNull);
        break;
      }
      expect(plan.hasPendingPointWork, isTrue);
    }

    expect(batches, greaterThan(2));
    expect(candidates, greaterThan(1));
    expect(plan.candidateSourceSegmentCount, candidates);
    expect(plan.splitInvocationCount, candidates);
    expect(classifications, candidates);
    expect(plan.classificationCheckCount, checks);
    expect(plan.processedSegmentCount, 1);
    expect(plan.hasPendingPointWork, isFalse);
    final previews = _ok(plan.materializeFinalObjectPreviews());
    expect(previews, hasLength(1));
    expect(previews.single.strokes, isNotEmpty);
    final materializations = plan.terminalMaterializationCount;
    plan.createRequest(uuidGenerator: _CountingUuidGenerator());
    expect(plan.terminalMaterializationCount, materializations);
  });
}

NormalizedPointerEvent _event(
  PointerPhase phase, {
  PointerSource source = PointerSource.mouse,
  int time = 0,
  double x = 0,
  double y = 0,
}) => _ok(
  NormalizedPointerEvent.create(
    pointerId: 1,
    source: source,
    phase: phase,
    viewPosition: _viewPoint(x, y),
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

NotebookDocument _rootWithObject(ObjectEnvelope object) => testNotebook(
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

ObjectEnvelope _copyObject(
  ObjectEnvelope source, {
  ObjectTypeKey? typeKey,
  PreservedData? payload,
  bool? visible,
  bool? locked,
}) => _ok(
  ObjectEnvelope.create(
    id: source.id,
    typeKey: typeKey ?? source.typeKey,
    envelopeVersion: source.envelopeVersion,
    typeSchemaVersion: source.typeSchemaVersion,
    transform: source.transform,
    visible: visible ?? source.visible,
    locked: locked ?? source.locked,
    payload: payload ?? source.payload,
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

List<String> _geometryVertices(Iterable<StrokeGeometryElement> elements) {
  final values = elements
      .map(
        (element) => element.vertices
            .map(
              (point) =>
                  '${point.x.toStringAsFixed(9)},${point.y.toStringAsFixed(9)}',
            )
            .join(';'),
      )
      .toList();
  values.sort();
  return values;
}

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

final class _CountingRenderingDefinition implements ObjectRenderingDefinition {
  _CountingRenderingDefinition(this.delegate);
  final ObjectRenderingDefinition delegate;
  int calls = 0;

  @override
  ObjectTypeKey get typeKey => delegate.typeKey;

  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    calls += 1;
    return delegate.render(
      object: object,
      viewport: viewport,
      layerOpacity: layerOpacity,
      plane: plane,
      limits: limits,
    );
  }
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
    required GeometryQueryPolygon polygon,
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
    required GeometryQueryPolygon polygon,
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
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) => Ok(output);
}

final class _PolygonIdentityHitDefinition
    implements ObjectHitTestingDefinition {
  final List<GeometryQueryPolygon> polygons = [];

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
  }) => const Ok([]);

  @override
  Result<List<StrokeId>, StructuredFailure> lasso({
    required ObjectEnvelope object,
    required GeometryQueryPolygon polygon,
    required AreaHitMode mode,
  }) {
    polygons.add(polygon);
    return const Ok([]);
  }
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
    this.throwContains = false,
  });
  final List<StrokeId> values;
  final int? reportedLength;
  final bool throwLength;
  final bool throwIterator;
  final int? throwMoveAt;
  final int? throwCurrentAt;
  final bool infinite;
  final bool throwContains;
  bool lengthRead = false;
  bool containsRead = false;
  bool rejectedTailCurrentRead = false;

  @override
  bool contains(Object? element) {
    containsRead = true;
    if (throwContains) throw StateError('secret-existing-id-contains');
    return values.contains(element);
  }

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

final class _HostilePointList extends ListBase<Point2> {
  _HostilePointList(
    this.values, {
    this.reportedLength,
    this.throwLength = false,
    this.throwIterator = false,
    this.throwMoveAt,
    this.throwCurrentAt,
    this.infinite = false,
  });

  final List<Point2> values;
  final int? reportedLength;
  final bool throwLength;
  final bool throwIterator;
  final int? throwMoveAt;
  final int? throwCurrentAt;
  final bool infinite;
  bool lengthRead = false;
  bool rejectedTailCurrentRead = false;
  int iteratorCreationCount = 0;
  int currentReadCount = 0;

  @override
  int get length {
    lengthRead = true;
    if (throwLength) throw StateError('secret-swept-path-length');
    return reportedLength ?? values.length;
  }

  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  Point2 operator [](int index) => values[index];
  @override
  void operator []=(int index, Point2 value) =>
      throw UnsupportedError('immutable');

  @override
  Iterator<Point2> get iterator {
    if (throwIterator) throw StateError('secret-swept-path-iterator');
    iteratorCreationCount += 1;
    return _HostilePointIterator(this);
  }
}

final class _HostilePointIterator implements Iterator<Point2> {
  _HostilePointIterator(this.owner);

  final _HostilePointList owner;
  var index = -1;

  @override
  bool moveNext() {
    final next = index + 1;
    if (owner.throwMoveAt == next) throw StateError('secret-swept-path-move');
    index = next;
    return owner.infinite || index < owner.values.length;
  }

  @override
  Point2 get current {
    owner.currentReadCount += 1;
    if (owner.throwCurrentAt == index) {
      throw StateError('secret-swept-path-current');
    }
    if (index >= owner.values.length) {
      owner.rejectedTailCurrentRead = true;
      return owner.values[index % owner.values.length];
    }
    return owner.values[index];
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
