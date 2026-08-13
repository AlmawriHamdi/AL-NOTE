// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/commands.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/documents/files.dart';
import 'package:al_note/documents/objects/handwriting.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/hit_testing.dart';
import 'package:al_note/drawing/renderer.dart';
import 'package:al_note/drawing/selection.dart';
import 'package:al_note/drawing/tools.dart';
import 'package:al_note/drawing/viewport.dart';
import 'package:al_note/ui/canvas/flutter_image_decoder.dart';
import 'package:al_note/ui/canvas/flutter_text_layout_engine.dart';
import 'package:al_note/ui/canvas/phase6_canvas.dart';
import 'package:flutter/material.dart' as flutter;
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/phase3_test_support.dart';
import '../support/phase4_test_support.dart';
import '../support/uuid_sequence_generator.dart';

final ShapeLimits _shapeLimits = _ok(
  ShapeLimits.create(
    maximumVertices: 64,
    maximumDashValues: 16,
    maximumUnknownFields: 16,
    maximumUnknownNodes: 1024,
    maximumNestingDepth: 8,
    maximumUnknownStringCodeUnits: 4096,
    maximumCoordinateMagnitude: 10000,
    maximumStrokeWidth: 100,
    maximumMiterLimit: 20,
    maximumCornerRadius: 1000,
    maximumDerivedSegments: 128,
  ),
);

final ShapeInteractionLimits _shapeInteractionLimits = _ok(
  ShapeInteractionLimits.create(maximumChecks: 100000),
);

final ImageLimits _imageLimits = _ok(
  ImageLimits.create(
    maximumEncodedBytes: 4096,
    maximumHeaderBytes: 1024,
    maximumMarkers: 32,
    maximumPixelDimension: 4096,
    maximumPixelCount: 4000000,
    maximumAlternativeTextScalars: 128,
    maximumUnknownFields: 16,
    maximumUnknownNodes: 1024,
    maximumNestingDepth: 8,
    maximumUnknownStringCodeUnits: 4096,
    maximumDocumentDimension: 10000,
  ),
);

final TextLimits _textLimits = _ok(
  TextLimits.create(
    maximumParagraphs: 32,
    maximumRunsPerParagraph: 32,
    maximumScalarsPerRun: 1024,
    maximumTotalScalars: 4096,
    maximumFontFamilyScalars: 64,
    maximumLanguageHintScalars: 32,
    maximumUnknownFields: 16,
    maximumUnknownNodes: 1024,
    maximumNestingDepth: 8,
    maximumUnknownStringCodeUnits: 4096,
    maximumFontSize: 200,
    maximumBoxDimension: 10000,
    maximumPadding: 100,
    maximumLayoutLines: 256,
    maximumLayoutFragments: 1024,
    maximumCaretStops: 4096,
    maximumRangeRectangles: 1024,
    maximumPendingEdits: 16,
  ),
);

void main() {
  group('Phase 7 dependency boundary', () {
    test('characters is exact direct-main and private', () {
      final manifest = File('pubspec.yaml').readAsStringSync();
      final lock = File('pubspec.lock').readAsStringSync();
      expect(manifest, contains('characters: 1.4.1'));
      expect(lock, contains('dependency: "direct main"'));
      expect(
        lock,
        contains(
          'faf38497bda5ead2a8c7615f4f7939df04333478bf32e4173fcb06d428b5716b',
        ),
      );
      final imports = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where(
            (file) =>
                file.readAsStringSync().contains("import 'package:characters/"),
          )
          .toList(growable: false);
      expect(imports, hasLength(1));
      expect(
        imports.single.path.replaceAll('\\', '/'),
        endsWith('lib/documents/objects/text/src/grapheme_adapter.dart'),
      );
      for (final barrel in [
        'lib/documents/document_model.dart',
        'lib/documents/objects/text.dart',
      ]) {
        expect(
          File(barrel).readAsStringSync(),
          isNot(contains('package:characters')),
        );
      }
    });
  });

  group('Shape Object', () {
    test('every kind and style round-trips with unknown fields', () {
      final geometries = <ShapeGeometry>[
        _ok(
          ShapeLineGeometry.create(
            start: _point(1, 2),
            end: _point(7, 8),
            limits: _shapeLimits,
          ),
        ),
        _ok(
          ShapeRectangleGeometry.create(
            bounds: _rect(1, 2, 41, 32),
            cornerRadius: 5,
            limits: _shapeLimits,
          ),
        ),
        _ok(
          ShapeEllipseGeometry.create(
            bounds: _rect(1, 2, 41, 32),
            limits: _shapeLimits,
          ),
        ),
        _ok(
          ShapeVertexGeometry.create(
            kind: ShapeKind.polygon,
            vertices: [
              _point(0, 0),
              _point(20, 20),
              _point(0, 20),
              _point(20, 0),
            ],
            limits: _shapeLimits,
          ),
        ),
        _ok(
          ShapeVertexGeometry.create(
            kind: ShapeKind.polyline,
            vertices: [_point(0, 0), _point(10, 20), _point(30, 5)],
            limits: _shapeLimits,
          ),
        ),
      ];
      final style = _shapeStyle(
        dashes: const [3, 2],
        fillRule: ShapeFillRule.evenOdd,
        start: ShapeArrowhead.open,
        end: ShapeArrowhead.diamond,
      );
      for (final geometry in geometries) {
        final payload = _ok(
          ShapePayload.create(
            geometry: geometry,
            style: style,
            limits: _shapeLimits,
            unknownFields: PreservedMap({
              'future': const PreservedString('opaque'),
            }),
          ),
        );
        final decoded = _ok(
          ShapePayload.decode(payload.encode(), limits: _shapeLimits),
        );
        expect(decoded.encode(), payload.encode());
        expect(decoded.geometry.kind, geometry.kind);
        expect(
          decoded.paintsFill,
          geometry.kind != ShapeKind.line &&
              geometry.kind != ShapeKind.polyline,
        );
      }
    });

    test('payload recaptures every geometry under its current limits', () {
      final geometryUnknown = PreservedMap({
        'future': PreservedMap({'nested': const PreservedString('kept')}),
      });
      final permissive = _shapeLimitsWithUnknownCodeUnits(
        4096,
        maximumNodes: 16,
      );
      final geometries = <ShapeGeometry>[
        _ok(
          ShapeLineGeometry.create(
            start: _point(0, 0),
            end: _point(10, 10),
            limits: permissive,
            unknownFields: geometryUnknown,
          ),
        ),
        _ok(
          ShapeRectangleGeometry.create(
            bounds: _rect(0, 0, 10, 10),
            limits: permissive,
            unknownFields: geometryUnknown,
          ),
        ),
        _ok(
          ShapeEllipseGeometry.create(
            bounds: _rect(0, 0, 10, 10),
            limits: permissive,
            unknownFields: geometryUnknown,
          ),
        ),
        for (final kind in [ShapeKind.polygon, ShapeKind.polyline])
          _ok(
            ShapeVertexGeometry.create(
              kind: kind,
              vertices: kind == ShapeKind.polygon
                  ? [_point(0, 0), _point(10, 0), _point(10, 10), _point(0, 10)]
                  : [_point(0, 0), _point(10, 10)],
              limits: permissive,
              unknownFields: geometryUnknown,
            ),
          ),
      ];
      final exact = _shapeLimitsWithUnknownCodeUnits(
        16,
        maximumFields: 1,
        maximumNodes: 2,
        maximumDepth: 3,
      );
      final noUnknown = _shapeLimitsWithUnknownCodeUnits(
        20,
        maximumFields: 0,
        maximumNodes: 2,
        maximumDepth: 3,
      );
      for (final geometry in geometries) {
        final accepted = _ok(
          ShapePayload.create(
            geometry: geometry,
            style: _shapeStyle(),
            limits: exact,
          ),
        );
        expect(accepted.geometry.unknownFields, geometryUnknown);
        expect(
          _ok(ShapePayload.decode(accepted.encode(), limits: exact)).encode(),
          accepted.encode(),
        );
        final rejected = ShapePayload.create(
          geometry: geometry,
          style: _shapeStyle(),
          limits: noUnknown,
        );
        expect(rejected, isA<Err<ShapePayload, StructuredFailure>>());
        expect('$rejected', isNot(contains('kept')));
      }

      final strictVertices = _ok(
        ShapeLimits.create(
          maximumVertices: 3,
          maximumDashValues: 16,
          maximumUnknownFields: 16,
          maximumUnknownNodes: 16,
          maximumNestingDepth: 8,
          maximumUnknownStringCodeUnits: 4096,
          maximumCoordinateMagnitude: 10000,
          maximumStrokeWidth: 100,
          maximumMiterLimit: 20,
          maximumCornerRadius: 1000,
          maximumDerivedSegments: 128,
        ),
      );
      expect(
        ShapePayload.create(
          geometry: geometries[3],
          style: _shapeStyle(),
          limits: strictVertices,
        ),
        isA<Err<ShapePayload, StructuredFailure>>(),
      );
    });

    test('unknown kinds remain preserved and inert in Registry', () {
      final source = PreservedMap({
        'geometry': PreservedMap({
          'kind': const PreservedString('future-star'),
          'future': const PreservedString('secret'),
        }),
        'style': PreservedMap.empty(),
        'topFuture': _integer(0),
      });
      final object = testObject(typeKey: shapeObjectTypeKey, payload: source);
      final registry = _registry();
      expect(registry.resolve(object), isA<InvalidObjectPayloadResolution>());
      expect(object.payload, same(source));
    });

    test('hostile iterables and numeric/work extremes fail closed', () {
      expect(
        ShapeVertexGeometry.create(
          kind: ShapeKind.polygon,
          vertices: _ThrowingIterable<Point2>(_point(0, 0)),
          limits: _shapeLimits,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        ShapeLineGeometry.create(
          start: _point(10001, 0),
          end: _point(0, 0),
          limits: _shapeLimits,
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        ShapeStyle.create(
          strokeEnabled: true,
          strokeColor: _color(0xff000000),
          strokeWidth: 101,
          cap: ShapeStrokeCap.butt,
          join: ShapeStrokeJoin.miter,
          miterLimit: 4,
          dashArray: const [],
          dashOffset: 0,
          fillEnabled: false,
          fillColor: _color(0xff000000),
          fillRule: ShapeFillRule.nonZero,
          opacity: 1,
          startArrowhead: ShapeArrowhead.none,
          endArrowhead: ShapeArrowhead.none,
          limits: _shapeLimits,
        ),
        isA<Err<Object?, Object?>>(),
      );
    });

    test('rendering, inverse hits, fill rule, bounds, and arrows work', () {
      final payload = _ok(
        ShapePayload.create(
          geometry: _ok(
            ShapeVertexGeometry.create(
              kind: ShapeKind.polygon,
              vertices: [
                _point(10, 10),
                _point(80, 80),
                _point(10, 80),
                _point(80, 10),
              ],
              limits: _shapeLimits,
            ),
          ),
          style: _shapeStyle(
            dashes: const [4, 2],
            fillRule: ShapeFillRule.evenOdd,
            start: ShapeArrowhead.triangle,
            end: ShapeArrowhead.circle,
          ),
          limits: _shapeLimits,
        ),
      );
      final object = testObject(
        typeKey: shapeObjectTypeKey,
        payload: payload.encode(),
      );
      final rendered = ShapeRenderingDefinition(shapeLimits: _shapeLimits)
          .render(
            object: object,
            viewport: _viewport(),
            layerOpacity: .8,
            plane: RenderPlane.committed,
            limits: _renderingLimits(),
          );
      expect(rendered, isA<Ok<List<ScenePrimitive>, StructuredFailure>>());
      expect(
        (rendered as Ok<List<ScenePrimitive>, StructuredFailure>).value,
        contains(isA<FilledPolygonPrimitive>()),
      );
      final hits = ShapeHitTestingDefinition(
        shapeLimits: _shapeLimits,
        interactionLimits: _shapeInteractionLimits,
      );
      expect(
        _ok(
          hits.wholePoint(
            object: object,
            pagePosition: _point(15, 15),
            pageTolerance: 2,
          ),
        ),
        isTrue,
      );
      expect(
        _ok(
          hits.wholeRectangle(
            object: object,
            area: _rect(0, 0, 100, 100),
            mode: AreaHitMode.containment,
          ),
        ),
        isTrue,
      );
    });

    test('non-uniform scale and shear remain explicit render geometry', () {
      final payload = _ok(
        ShapePayload.create(
          geometry: _ok(
            ShapeLineGeometry.create(
              start: _point(0, 0),
              end: _point(40, 20),
              limits: _shapeLimits,
            ),
          ),
          style: _shapeStyle(
            dashes: const [7, 3],
            start: ShapeArrowhead.triangle,
            end: ShapeArrowhead.diamond,
          ),
          limits: _shapeLimits,
        ),
      );
      for (final coefficients in const <List<double>>[
        [10000, 0, 0, .0001, 0, 0],
        [1, 1, 0, 1, 0, 0],
      ]) {
        final object = testObject(
          typeKey: shapeObjectTypeKey,
          payload: payload.encode(),
          transform: _ok(AffineTransform2D.restoreFromStorage(coefficients)),
        );
        final primitives = _ok(
          ShapeRenderingDefinition(shapeLimits: _shapeLimits).render(
            object: object,
            viewport: _viewport(),
            layerOpacity: 1,
            plane: RenderPlane.committed,
            limits: _renderingLimits(),
          ),
        );
        final strokeGeometry = primitives
            .whereType<FilledPolygonGroupPrimitive>();
        expect(strokeGeometry, isNotEmpty);
        for (final primitive in strokeGeometry) {
          expect(primitive.localToViewCoefficients, coefficients);
        }
      }
    });

    test(
      'authoritative stroke geometry covers miters caps joins and arrows',
      () {
        ObjectEnvelope objectFor(
          ShapeStyle style, {
          int id = 760,
          List<Point2>? vertices,
        }) {
          final payload = _ok(
            ShapePayload.create(
              geometry: _ok(
                ShapeVertexGeometry.create(
                  kind: ShapeKind.polyline,
                  vertices:
                      vertices ?? [_point(0, 0), _point(20, 0), _point(.2, 2)],
                  limits: _shapeLimits,
                ),
              ),
              style: style,
              limits: _shapeLimits,
            ),
          );
          return testObject(
            id: id,
            typeKey: shapeObjectTypeKey,
            payload: payload.encode(),
          );
        }

        final miterObject = objectFor(
          _shapeStyle(
            cap: ShapeStrokeCap.butt,
            join: ShapeStrokeJoin.miter,
            miterLimit: 10,
            strokeWidth: 6,
            fillEnabled: false,
          ),
        );
        final rendered = _ok(
          ShapeRenderingDefinition(shapeLimits: _shapeLimits).render(
            object: miterObject,
            viewport: _viewport(),
            layerOpacity: 1,
            plane: RenderPlane.committed,
            limits: _renderingLimits(),
          ),
        );
        final center = _point(20, 0);
        final tip = rendered
            .whereType<FilledPolygonGroupPrimitive>()
            .expand((primitive) => primitive.contours)
            .expand((contour) => contour)
            .reduce(
              (a, b) => _distance(a, center) > _distance(b, center) ? a : b,
            );
        expect(_distance(tip, center), greaterThan(6));
        final hits = ShapeHitTestingDefinition(
          shapeLimits: _shapeLimits,
          interactionLimits: _shapeInteractionLimits,
        );
        expect(
          _ok(
            hits.wholePoint(
              object: miterObject,
              pagePosition: tip,
              pageTolerance: 0,
            ),
          ),
          isTrue,
        );

        final roundJoin = objectFor(
          _shapeStyle(strokeWidth: 10, fillEnabled: false),
          id: 766,
          vertices: [_point(0, 0), _point(20, 0), _point(20, 20)],
        );
        final betweenOldJoinVertices = _point(
          20 + 4.9 * math.cos(-math.pi / 4),
          4.9 * math.sin(-math.pi / 4),
        );
        expect(
          _ok(
            hits.wholePoint(
              object: roundJoin,
              pagePosition: betweenOldJoinVertices,
              pageTolerance: 0,
            ),
          ),
          isTrue,
        );
        final tipArea = _rect(tip.x - .1, tip.y - .1, tip.x + .1, tip.y + .1);
        expect(
          _ok(
            hits.wholeRectangle(
              object: miterObject,
              area: tipArea,
              mode: AreaHitMode.intersection,
            ),
          ),
          isTrue,
        );
        final lasso = _ok(
          GeometryQueryPolygon.create([
            tipArea.topLeft,
            _point(tipArea.right, tipArea.top),
            tipArea.bottomRight,
            _point(tipArea.left, tipArea.bottom),
          ], maximumPoints: 4),
        );
        expect(
          _ok(
            hits.wholeLasso(
              object: miterObject,
              polygon: lasso,
              mode: AreaHitMode.intersection,
            ),
          ),
          isTrue,
        );
        expect(
          _ok(
            hits.wholeSweptSegment(
              object: miterObject,
              start: tip,
              end: tip,
              radius: 0,
            ),
          ),
          isTrue,
        );

        final roundCap = objectFor(
          _shapeStyle(strokeWidth: 10, fillEnabled: false),
          id: 761,
        );
        final betweenOldVertices = _point(
          -4.9 * math.cos(math.pi / 12),
          4.9 * math.sin(math.pi / 12),
        );
        expect(
          _ok(
            hits.wholePoint(
              object: roundCap,
              pagePosition: betweenOldVertices,
              pageTolerance: 0,
            ),
          ),
          isTrue,
        );

        for (final entry in <(ShapeStyle, int)>[
          (
            _shapeStyle(
              join: ShapeStrokeJoin.bevel,
              cap: ShapeStrokeCap.square,
              fillEnabled: false,
            ),
            762,
          ),
          (_shapeStyle(dashes: const [3, 2], fillEnabled: false), 763),
          (
            _shapeStyle(
              start: ShapeArrowhead.open,
              end: ShapeArrowhead.triangle,
              fillEnabled: false,
            ),
            764,
          ),
          (
            _shapeStyle(
              start: ShapeArrowhead.diamond,
              end: ShapeArrowhead.circle,
              fillEnabled: false,
            ),
            765,
          ),
        ]) {
          final object = objectFor(entry.$1, id: entry.$2);
          final primitives = _ok(
            ShapeRenderingDefinition(shapeLimits: _shapeLimits).render(
              object: object,
              viewport: _viewport(),
              layerOpacity: 1,
              plane: RenderPlane.committed,
              limits: _renderingLimits(),
            ),
          ).whereType<FilledPolygonGroupPrimitive>();
          expect(primitives, isNotEmpty);
          final polygon = primitives.last.contours.last;
          final sample = _polygonCentroid(polygon);
          expect(
            _ok(
              hits.wholePoint(
                object: object,
                pagePosition: sample,
                pageTolerance: 0,
              ),
            ),
            isTrue,
          );
        }
      },
    );

    test('visible intrinsic bounds drive Selection and Whole Eraser', () {
      ObjectEnvelope objectFor(
        int id,
        List<Point2> vertices,
        ShapeStyle style, {
        AffineTransform2D? transform,
      }) {
        final geometry = vertices.length == 2
            ? _ok(
                ShapeLineGeometry.create(
                  start: vertices.first,
                  end: vertices.last,
                  limits: _shapeLimits,
                ),
              )
            : _ok(
                ShapeVertexGeometry.create(
                  kind: ShapeKind.polyline,
                  vertices: vertices,
                  limits: _shapeLimits,
                ),
              );
        final payload = _ok(
          ShapePayload.create(
            geometry: geometry,
            style: style,
            limits: _shapeLimits,
          ),
        );
        return testObject(
          id: id,
          typeKey: shapeObjectTypeKey,
          payload: payload.encode(),
          transform: transform,
        );
      }

      final objects = <ObjectEnvelope>[
        objectFor(
          780,
          [_point(20, 40), _point(50, 40), _point(20.2, 43)],
          _shapeStyle(
            strokeWidth: 10,
            cap: ShapeStrokeCap.butt,
            join: ShapeStrokeJoin.miter,
            miterLimit: 20,
            fillEnabled: false,
          ),
        ),
        objectFor(781, [
          _point(20, 80),
          _point(60, 80),
        ], _shapeStyle(strokeWidth: 12, fillEnabled: false)),
        objectFor(
          782,
          [_point(20, 110), _point(60, 110)],
          _shapeStyle(
            strokeWidth: 12,
            cap: ShapeStrokeCap.square,
            fillEnabled: false,
          ),
        ),
        objectFor(
          783,
          [_point(20, 145), _point(70, 145)],
          _shapeStyle(
            strokeWidth: 8,
            end: ShapeArrowhead.circle,
            fillEnabled: false,
          ),
        ),
      ];
      final definition = ShapeObjectTypeDefinition(_shapeLimits);
      final hitDefinition = ShapeHitTestingDefinition(
        shapeLimits: _shapeLimits,
        interactionLimits: _shapeInteractionLimits,
      );
      final hitRegistry = _ok(
        HitTestingRegistry.create(
          [hitDefinition],
          maximumDefinitions: 1,
          maximumBehaviorResults: 1,
        ),
      );
      final registry = testRegistry([definition]);

      for (final object in objects) {
        final payload = _ok(
          ShapePayload.decode(object.payload, limits: _shapeLimits),
        );
        final raw = payload.geometry.bounds;
        final visible = _ok(
          definition.intrinsicGeometry(
            object.payload,
            object.typeSchemaVersion,
          ),
        );
        expect(
          visible.left < raw.left ||
              visible.right > raw.right ||
              visible.top < raw.top ||
              visible.bottom > raw.bottom,
          isTrue,
        );
        final derived = _ok(
          ShapeDerivedGeometry.derive(
            payload: payload,
            shapeLimits: _shapeLimits,
            curveSegments: shapeCurveSegmentsFor(_shapeLimits),
          ),
        );
        final outside = derived.strokePolygons
            .expand((polygon) => polygon)
            .firstWhere(
              (point) =>
                  point.x < raw.left ||
                  point.x > raw.right ||
                  point.y < raw.top ||
                  point.y > raw.bottom,
            );
        expect(
          _ok(
            hitDefinition.wholePoint(
              object: object,
              pagePosition: outside,
              pageTolerance: .01,
            ),
          ),
          isTrue,
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
        final coordinator = _coordinatorFor(root, registry);
        WholeEraseGesturePlan plan() => _ok(
          WholeEraseGesturePlan.prepare(
            document: coordinator.snapshot,
            pageId: root.pages.single.id,
            radius: .01,
            handwritingLimits: _handwritingLimitsForShapeTests(),
            objectRegistry: registry,
            hitTestingRegistry: hitRegistry,
            geometryResolver: StrokeGeometryResolver(
              _strokeGeometryLimitsForShapeTests(),
            ),
            maximumObjects: 1,
            maximumStrokes: 1,
            maximumPoints: 2,
            maximumTargets: 1,
            maximumOperations: 1,
          ),
        );
        final miss = plan();
        expect(
          _ok(miss.acceptPoint(_point(9000, 9000))).newlyAffectedStrokeCount,
          0,
        );
        expect(miss.geometryCheckCount, 0);
        expect(coordinator.snapshot.canUndo, isFalse);

        final hit = plan();
        expect(_ok(hit.acceptPoint(outside)).newlyAffectedStrokeCount, 1);
        expect(hit.geometryCheckCount, 1);
        final before = coordinator.snapshot.root;
        final request = _ok(
          hit.createRequest(
            uuidGenerator: UuidSequenceGenerator.fromValues([testUuid(790)]),
          ),
        );
        _ok(coordinator.execute(request));
        final erased = coordinator.snapshot.root;
        _ok(coordinator.undo());
        expect(coordinator.snapshot.root, before);
        _ok(coordinator.redo());
        expect(coordinator.snapshot.root, erased);
      }

      final transformed = objectFor(
        784,
        [_point(10, 30), _point(60, 30), _point(25, 34)],
        _shapeStyle(
          strokeWidth: 10,
          cap: ShapeStrokeCap.square,
          join: ShapeStrokeJoin.miter,
          miterLimit: 20,
          end: ShapeArrowhead.triangle,
          fillEnabled: false,
        ),
        transform: _ok(
          AffineTransform2D.restoreFromStorage([2, .5, 1.25, .75, 30, 20]),
        ),
      );
      final transformedRoot = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [transformed]),
                ],
              ),
            ],
          ),
        ],
      );
      final transformedCoordinator = _coordinatorFor(transformedRoot, registry);
      final selection = SelectionController(
        objectRegistry: registry,
        coalescingBoundarySink: transformedCoordinator,
        maximumTargets: 1,
      );
      _ok(
        selection.replace(
          root: transformedRoot,
          targets: [
            SelectionTarget.wholeObject(
              pageId: transformedRoot.pages.single.id,
              objectId: transformed.id,
            ),
          ],
        ),
      );
      final local = _ok(
        definition.intrinsicGeometry(
          transformed.payload,
          transformed.typeSchemaVersion,
        ),
      );
      final expected = _transformedBounds(local, transformed.transform);
      expect(selection.state.aggregateBounds, expected);
    });

    test('robust orientation distinguishes cancellation from collinearity', () {
      final epsilon = math.pow(2, -52).toDouble();
      final a = _point(0, 0);
      final b = _point(1, 1 + epsilon);
      final cancellationPoint = _point(1 - epsilon, 1);
      final payload = _ok(
        ShapePayload.create(
          geometry: _ok(
            ShapeVertexGeometry.create(
              kind: ShapeKind.polygon,
              vertices: [a, b, _point(2, 0)],
              limits: _shapeLimits,
            ),
          ),
          style: _shapeStyle(strokeEnabled: false),
          limits: _shapeLimits,
        ),
      );
      final object = testObject(
        id: 791,
        typeKey: shapeObjectTypeKey,
        payload: payload.encode(),
      );
      Result<bool, StructuredFailure> query(Point2 point, int work) =>
          ShapeHitTestingDefinition(
            shapeLimits: _shapeLimits,
            interactionLimits: _ok(
              ShapeInteractionLimits.create(maximumChecks: work),
            ),
          ).wholePoint(object: object, pagePosition: point, pageTolerance: 0);
      expect(_ok(query(cancellationPoint, 100000)), isFalse);
      expect(_ok(query(_point(.5, .5 + epsilon / 2), 100000)), isTrue);

      final registry = testRegistry([ShapeObjectTypeDefinition(_shapeLimits)]);
      final hitRegistry = _ok(
        HitTestingRegistry.create(
          [
            ShapeHitTestingDefinition(
              shapeLimits: _shapeLimits,
              interactionLimits: _ok(
                ShapeInteractionLimits.create(maximumChecks: 1),
              ),
            ),
          ],
          maximumDefinitions: 1,
          maximumBehaviorResults: 1,
        ),
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
      final coordinator = _coordinatorFor(root, registry);
      final beforeFailure = coordinator.snapshot;
      final eraser = _ok(
        WholeEraseGesturePlan.prepare(
          document: beforeFailure,
          pageId: root.pages.single.id,
          radius: 0,
          handwritingLimits: _handwritingLimitsForShapeTests(),
          objectRegistry: registry,
          hitTestingRegistry: hitRegistry,
          geometryResolver: StrokeGeometryResolver(
            _strokeGeometryLimitsForShapeTests(),
          ),
          maximumObjects: 1,
          maximumStrokes: 1,
          maximumPoints: 1,
          maximumTargets: 1,
          maximumOperations: 1,
        ),
      );
      final failedErase = eraser.acceptPoint(cancellationPoint);
      expect(failedErase, isA<Err<EraserGestureUpdate, StructuredFailure>>());
      expect('$failedErase', contains('work_limit'));
      expect(eraser.affectedStrokeCount, 0);
      expect(coordinator.snapshot.root, same(beforeFailure.root));
      expect(coordinator.snapshot.canUndo, beforeFailure.canUndo);

      final selection = SelectionController(
        objectRegistry: registry,
        coalescingBoundarySink: coordinator,
        maximumTargets: 1,
      );
      _ok(
        selection.replace(
          root: root,
          targets: [
            SelectionTarget.wholeObject(
              pageId: root.pages.single.id,
              objectId: object.id,
            ),
          ],
        ),
      );
      final selected = selection.state;
      final hitFailure =
          PageHitTester(
            objectRegistry: registry,
            hitTestingRegistry: hitRegistry,
            maximumCandidates: 1,
            maximumResults: 1,
            maximumLassoPoints: 4,
          ).point(
            page: root.pages.single,
            pagePosition: cancellationPoint,
            pageTolerance: 0,
          );
      expect(hitFailure, isA<Err<HitTestResult?, StructuredFailure>>());
      expect('$hitFailure', contains('work_limit'));
      expect(selection.state, same(selected));
      expect(coordinator.snapshot.root, same(beforeFailure.root));
      expect(coordinator.snapshot.canUndo, beforeFailure.canUndo);

      var safeMinimum = 1;
      while (safeMinimum < 10000 &&
          query(_point(1.5, .1), safeMinimum) is Err) {
        safeMinimum += 1;
      }
      expect(
        query(_point(1.5, .1), safeMinimum),
        isA<Ok<bool, StructuredFailure>>(),
      );
      final exhausted = query(cancellationPoint, safeMinimum);
      expect(exhausted, isA<Err<bool, StructuredFailure>>());
      expect('$exhausted', contains('work_limit'));
      expect('$exhausted', isNot(contains('1.000000')));

      for (final coefficients in const <List<double>>[
        [1e150, 0, 0, 1e150, 0, 0],
        [1e-150, 0, 0, 1e-150, 0, 0],
        [2, .75, 1.25, .5, 1e100, -1e100],
      ]) {
        final transformed = testObject(
          id: 792,
          typeKey: shapeObjectTypeKey,
          payload: payload.encode(),
          transform: _ok(AffineTransform2D.restoreFromStorage(coefficients)),
        );
        final pagePoint = _ok(
          transformed.transform.applyToPoint(_point(1.5, .1)),
        );
        final result =
            ShapeHitTestingDefinition(
              shapeLimits: _shapeLimits,
              interactionLimits: _shapeInteractionLimits,
            ).wholePoint(
              object: transformed,
              pagePosition: pagePoint,
              pageTolerance: 0,
            );
        expect(result, isA<Ok<bool, StructuredFailure>>(), reason: '$result');
      }
    });

    test('distance-to-tolerance decisions are numerically certified', () {
      final payload = _ok(
        ShapePayload.create(
          geometry: _ok(
            ShapeVertexGeometry.create(
              kind: ShapeKind.polygon,
              vertices: [_point(100, 100), _point(200, 100), _point(150, 200)],
              limits: _shapeLimits,
            ),
          ),
          style: _shapeStyle(strokeEnabled: false),
          limits: _shapeLimits,
        ),
      );
      final object = testObject(
        id: 900,
        typeKey: shapeObjectTypeKey,
        payload: payload.encode(),
      );
      Result<bool, StructuredFailure> query(
        Point2 point,
        double tolerance, {
        int work = 100000,
        ObjectEnvelope? target,
      }) =>
          ShapeHitTestingDefinition(
            shapeLimits: _shapeLimits,
            interactionLimits: _ok(
              ShapeInteractionLimits.create(maximumChecks: work),
            ),
          ).wholePoint(
            object: target ?? object,
            pagePosition: point,
            pageTolerance: tolerance,
          );

      const delta = 9.094947017729282e-13;
      expect(_ok(query(_point(150, 99 + delta), 1)), isTrue);
      expect(_ok(query(_point(150, 99), 1)), isTrue);
      expect(_ok(query(_point(150, 99 - delta), 1)), isFalse);
      expect(_ok(query(_point(99, 100), 1)), isTrue);
      expect(_ok(query(_point(98.999999999, 100), 1)), isFalse);
      expect(_ok(query(_point(201, 100), 1)), isTrue);
      expect(_ok(query(_point(201.000000001, 100), 1)), isFalse);

      final nearlyDegenerate = testObject(
        id: 901,
        typeKey: shapeObjectTypeKey,
        payload: _ok(
          ShapePayload.create(
            geometry: _ok(
              ShapeVertexGeometry.create(
                kind: ShapeKind.polygon,
                vertices: [
                  _point(100, 100),
                  _point(100 + 9.094947017729282e-13, 100),
                  _point(200, 200),
                ],
                limits: _shapeLimits,
              ),
            ),
            style: _shapeStyle(strokeEnabled: false),
            limits: _shapeLimits,
          ),
        ).encode(),
      );
      expect(
        query(_point(100, 99), 1, target: nearlyDegenerate),
        isA<Ok<bool, StructuredFailure>>(),
      );

      var separatedBudget = 1;
      while (separatedBudget < 10000 &&
          query(_point(150, 98), 1, work: separatedBudget) is Err) {
        separatedBudget += 1;
      }
      expect(
        query(_point(150, 98), 1, work: separatedBudget),
        isA<Ok<bool, StructuredFailure>>(),
      );
      final exactExhaustion = query(_point(150, 99), 1, work: separatedBudget);
      expect(exactExhaustion, isA<Err<bool, StructuredFailure>>());
      expect('$exactExhaustion', contains('work_limit'));
      expect('$exactExhaustion', isNot(contains('150')));

      for (final coefficients in const <List<double>>[
        [1e150, 0, 0, 1e150, 0, 0],
        [1e-150, 0, 0, 1e-150, 0, 0],
        [2, .5, 1.25, .75, 1e100, -1e100],
      ]) {
        final transform = _ok(
          AffineTransform2D.restoreFromStorage(coefficients),
        );
        final transformed = testObject(
          id: 902,
          typeKey: shapeObjectTypeKey,
          payload: payload.encode(),
          transform: transform,
        );
        final pagePoint = _ok(transform.applyToPoint(_point(150, 99)));
        final toleranceScale = math.max(
          coefficients[0].abs() + coefficients[2].abs(),
          coefficients[1].abs() + coefficients[3].abs(),
        );
        expect(
          query(pagePoint, toleranceScale, target: transformed),
          isA<Ok<bool, StructuredFailure>>(),
        );
      }

      final linePayload = _ok(
        ShapePayload.create(
          geometry: _ok(
            ShapeLineGeometry.create(
              start: _point(100, 100),
              end: _point(200, 100),
              limits: _shapeLimits,
            ),
          ),
          style: _shapeStyle(
            strokeWidth: 2,
            cap: ShapeStrokeCap.butt,
            fillEnabled: false,
          ),
          limits: _shapeLimits,
        ),
      );
      final line = testObject(
        id: 903,
        typeKey: shapeObjectTypeKey,
        payload: linePayload.encode(),
      );
      final whole = ShapeHitTestingDefinition(
        shapeLimits: _shapeLimits,
        interactionLimits: _shapeInteractionLimits,
      );
      expect(
        _ok(
          whole.wholeSweptSegment(
            object: line,
            start: _point(150, 98),
            end: _point(150, 98),
            radius: 1 - delta,
          ),
        ),
        isFalse,
      );
      expect(
        _ok(
          whole.wholeSweptSegment(
            object: line,
            start: _point(150, 98),
            end: _point(150, 98),
            radius: 1,
          ),
        ),
        isTrue,
      );
      expect(
        _ok(
          whole.wholeSweptSegment(
            object: line,
            start: _point(150, 98),
            end: _point(150, 98),
            radius: 1 + delta,
          ),
        ),
        isTrue,
      );

      final registry = testRegistry([ShapeObjectTypeDefinition(_shapeLimits)]);
      final hitRegistry = _ok(
        HitTestingRegistry.create(
          [whole],
          maximumDefinitions: 1,
          maximumBehaviorResults: 1,
        ),
      );
      final root = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [line]),
                ],
              ),
            ],
          ),
        ],
      );
      final coordinator = _coordinatorFor(root, registry);
      WholeEraseGesturePlan eraser(double radius) => _ok(
        WholeEraseGesturePlan.prepare(
          document: coordinator.snapshot,
          pageId: root.pages.single.id,
          radius: radius,
          handwritingLimits: _handwritingLimitsForShapeTests(),
          objectRegistry: registry,
          hitTestingRegistry: hitRegistry,
          geometryResolver: StrokeGeometryResolver(
            _strokeGeometryLimitsForShapeTests(),
          ),
          maximumObjects: 1,
          maximumStrokes: 1,
          maximumPoints: 1,
          maximumTargets: 1,
          maximumOperations: 1,
        ),
      );
      final miss = eraser(1 - delta);
      expect(
        _ok(miss.acceptPoint(_point(150, 98))).newlyAffectedStrokeCount,
        0,
      );
      expect(miss.geometryCheckCount, 0);
      final boundaryHit = eraser(1);
      expect(
        _ok(boundaryHit.acceptPoint(_point(150, 98))).newlyAffectedStrokeCount,
        1,
      );
      final aboveHit = eraser(1 + delta);
      expect(
        _ok(aboveHit.acceptPoint(_point(150, 98))).newlyAffectedStrokeCount,
        1,
      );
      expect(coordinator.snapshot.canUndo, isFalse);
      expect(coordinator.snapshot.root, same(root));
    });

    test(
      'one Shape stroke group composites translucent overlaps once',
      () async {
        FilledPolygonGroupPrimitive render(
          int id,
          List<Point2> vertices,
          ShapeStyle style, {
          AffineTransform2D? transform,
          double layerOpacity = 1,
        }) {
          final geometry = vertices.length == 2
              ? _ok(
                  ShapeLineGeometry.create(
                    start: vertices.first,
                    end: vertices.last,
                    limits: _shapeLimits,
                  ),
                )
              : _ok(
                  ShapeVertexGeometry.create(
                    kind: ShapeKind.polyline,
                    vertices: vertices,
                    limits: _shapeLimits,
                  ),
                );
          final object = testObject(
            id: id,
            typeKey: shapeObjectTypeKey,
            transform: transform,
            payload: _ok(
              ShapePayload.create(
                geometry: geometry,
                style: style,
                limits: _shapeLimits,
              ),
            ).encode(),
          );
          final primitives = _ok(
            ShapeRenderingDefinition(shapeLimits: _shapeLimits).render(
              object: object,
              viewport: _viewport(),
              layerOpacity: layerOpacity,
              plane: RenderPlane.committed,
              limits: _renderingLimits(),
            ),
          );
          expect(primitives.whereType<FilledPolygonPrimitive>(), isEmpty);
          return primitives.single as FilledPolygonGroupPrimitive;
        }

        final cases = <(FilledPolygonGroupPrimitive, Point2, Point2)>[
          (
            render(793, [
              _point(20, 20),
              _point(50, 20),
              _point(50, 50),
            ], _shapeStyle(strokeWidth: 12, fillEnabled: false, opacity: .5)),
            _point(35, 20),
            _point(49, 21),
          ),
          (
            render(
              794,
              [_point(20, 20), _point(50, 20), _point(40, 45)],
              _shapeStyle(
                strokeWidth: 12,
                cap: ShapeStrokeCap.butt,
                join: ShapeStrokeJoin.miter,
                miterLimit: 10,
                fillEnabled: false,
                opacity: .5,
              ),
            ),
            _point(35, 20),
            _point(49, 21),
          ),
          (
            render(795, [
              _point(20, 20),
              _point(60, 20),
            ], _shapeStyle(strokeWidth: 12, fillEnabled: false, opacity: .5)),
            _point(40, 20),
            _point(20, 20),
          ),
          (
            render(
              796,
              [_point(20, 20), _point(60, 20)],
              _shapeStyle(
                strokeWidth: 8,
                end: ShapeArrowhead.triangle,
                fillEnabled: false,
                opacity: .5,
              ),
            ),
            _point(40, 20),
            _point(60, 20),
          ),
        ];
        for (final entry in cases) {
          expect(entry.$1.contours.length, greaterThan(1));
          final body = await _paintedAlpha(entry.$1, entry.$2);
          final overlap = await _paintedAlpha(entry.$1, entry.$3);
          expect(body, inInclusiveRange(126, 129));
          expect(
            overlap,
            inInclusiveRange(126, 129),
            reason: 'body=$body overlap=$overlap',
          );
          expect((body - overlap).abs(), lessThanOrEqualTo(2));
        }

        final colorAndShapeOpacity = render(
          799,
          [_point(20, 20), _point(50, 20), _point(50, 50)],
          _shapeStyle(
            strokeArgb: 0x80000000,
            strokeWidth: 12,
            fillEnabled: false,
            opacity: .5,
          ),
        );
        final translucentBody = await _paintedAlpha(
          colorAndShapeOpacity,
          _point(35, 20),
        );
        final translucentOverlap = await _paintedAlpha(
          colorAndShapeOpacity,
          _point(49, 21),
        );
        expect(translucentBody, inInclusiveRange(63, 65));
        expect(translucentOverlap, inInclusiveRange(63, 65));
        expect(
          (translucentBody - translucentOverlap).abs(),
          lessThanOrEqualTo(2),
        );

        final opaque = render(797, [
          _point(20, 20),
          _point(50, 20),
          _point(50, 50),
        ], _shapeStyle(strokeWidth: 12, fillEnabled: false, opacity: 1));
        expect(await _paintedAlpha(opaque, _point(50, 20)), 255);

        for (final entry in <(int, double, double, int)>[
          (0x80000000, 1, 1, 128),
          (0xff000000, .5, 1, 128),
          (0x80000000, .5, 1, 64),
          (0x80000000, .5, .5, 32),
          (0xff000000, 1, 1, 255),
        ]) {
          final primitive = render(
            800 + entry.$4,
            [_point(20, 20), _point(60, 20)],
            _shapeStyle(
              strokeArgb: entry.$1,
              strokeWidth: 10,
              fillEnabled: false,
              opacity: entry.$2,
            ),
            layerOpacity: entry.$3,
          );
          expect(
            await _paintedAlpha(primitive, _point(40, 20)),
            inInclusiveRange(entry.$4 - 1, entry.$4 + 1),
          );
        }

        final independentPayload = _ok(
          ShapePayload.create(
            geometry: _ok(
              ShapeRectangleGeometry.create(
                bounds: _rect(20, 20, 70, 70),
                limits: _shapeLimits,
              ),
            ),
            style: _shapeStyle(
              strokeArgb: 0x800000ff,
              fillArgb: 0x40ff0000,
              strokeWidth: 10,
              opacity: .5,
            ),
            limits: _shapeLimits,
          ),
        );
        final independent = _ok(
          ShapeRenderingDefinition(shapeLimits: _shapeLimits).render(
            object: testObject(
              id: 899,
              typeKey: shapeObjectTypeKey,
              payload: independentPayload.encode(),
            ),
            viewport: _viewport(),
            layerOpacity: 1,
            plane: RenderPlane.committed,
            limits: _renderingLimits(),
          ),
        );
        final fill = independent.whereType<FilledPolygonPrimitive>().single;
        final stroke = independent
            .whereType<FilledPolygonGroupPrimitive>()
            .single;
        expect(await _paintedRgba(fill, _point(40, 40)), [255, 0, 0, 32]);
        expect(await _paintedRgba(stroke, _point(20, 40)), [0, 0, 255, 64]);

        final affine = _ok(
          AffineTransform2D.restoreFromStorage([1.5, .25, .5, 1, 10, 10]),
        );
        final transformed = render(
          798,
          [_point(20, 20), _point(60, 20)],
          _shapeStyle(strokeWidth: 8, fillEnabled: false, opacity: .5),
          transform: affine,
        );
        expect(transformed.localToViewCoefficients, affine.storageCoefficients);
        final transformedBody = _ok(affine.applyToPoint(_point(40, 20)));
        expect(
          await _paintedAlpha(transformed, transformedBody),
          inInclusiveRange(126, 129),
        );
        final enlarged = _ok(
          FilledPolygonGroupPrimitive.create(
            plane: transformed.plane,
            opacity: transformed.opacity,
            color: transformed.color,
            contours: transformed.contours,
            maximumContours: transformed.contours.length,
            maximumPointsPerContour: 128,
            maximumTotalPoints: 8192,
            localToViewCoefficients: transformed.localToViewCoefficients,
            transformedBounds: _rect(
              transformed.bounds.left - 20,
              transformed.bounds.top - 20,
              transformed.bounds.right + 20,
              transformed.bounds.bottom + 20,
            ),
          ),
        );
        expect(
          await _paintedBytes(transformed),
          await _paintedBytes(enlarged),
          reason: 'inflated view-space saveLayer bounds must retain affine AA',
        );

        final mutable = <Iterable<Point2>>[
          [_point(0, 0), _point(1, 0), _point(0, 1)],
        ];
        final captured = _ok(
          FilledPolygonGroupPrimitive.create(
            plane: RenderPlane.committed,
            opacity: .5,
            color: _ok(RenderColor.create(0xff000000)),
            contours: mutable,
            maximumContours: 1,
            maximumPointsPerContour: 3,
            maximumTotalPoints: 3,
          ),
        );
        mutable.clear();
        expect(captured.contours, hasLength(1));
        expect(
          () => captured.contours.first.add(_point(2, 2)),
          throwsUnsupportedError,
        );
        final rejectedTail = FilledPolygonGroupPrimitive.create(
          plane: RenderPlane.committed,
          opacity: .5,
          color: _ok(RenderColor.create(0xff000000)),
          contours: _RejectedTailIterable<Iterable<Point2>>([
            _point(0, 0),
            _point(1, 0),
            _point(0, 1),
          ]),
          maximumContours: 1,
          maximumPointsPerContour: 3,
          maximumTotalPoints: 3,
        );
        expect('$rejectedTail', contains('polygon_group_limit'));
        expect('$rejectedTail', isNot(contains('hostile')));
      },
    );

    test('polygon groups enforce cumulative hostile-input ceilings', () {
      final triangleA = [_point(0, 0), _point(1, 0), _point(0, 1)];
      final triangleB = [_point(2, 0), _point(3, 0), _point(2, 1)];
      Result<FilledPolygonGroupPrimitive, StructuredFailure> create(
        Iterable<Iterable<Point2>> contours, {
        int maximumContours = 2,
        int maximumPointsPerContour = 3,
        int maximumTotalPoints = 6,
      }) => FilledPolygonGroupPrimitive.create(
        plane: RenderPlane.committed,
        opacity: 1,
        color: _ok(RenderColor.create(0xff000000)),
        contours: contours,
        maximumContours: maximumContours,
        maximumPointsPerContour: maximumPointsPerContour,
        maximumTotalPoints: maximumTotalPoints,
      );

      final exact = _ok(create([triangleA, triangleB]));
      expect(exact.contours, [triangleA, triangleB]);
      expect(() => exact.contours.add(triangleA), throwsUnsupportedError);
      expect(
        () => exact.contours.first.add(_point(9, 9)),
        throwsUnsupportedError,
      );

      final contourTail = _RejectedAfterIterable<Iterable<Point2>>([
        triangleA,
        triangleB,
      ], triangleA);
      final contourOverflow = create(contourTail);
      expect('$contourOverflow', contains('polygon_group_limit'));
      expect(contourTail.rejectedCurrentRead, isFalse);

      final pointTail = _RejectedAfterIterable<Point2>([
        _point(2, 0),
        _point(3, 0),
        _point(2, 1),
      ], _point(3, 1));
      final pointOverflow = create([
        triangleA,
        pointTail,
      ], maximumPointsPerContour: 4);
      expect('$pointOverflow', contains('polygon_group_total_limit'));
      expect(pointTail.rejectedCurrentRead, isFalse);

      final perContourTail = _RejectedAfterIterable<Point2>(
        triangleA,
        _point(1, 1),
      );
      final perContourOverflow = create(
        [perContourTail],
        maximumContours: 1,
        maximumTotalPoints: 4,
      );
      expect('$perContourOverflow', contains('polygon_group_point_limit'));
      expect(perContourTail.rejectedCurrentRead, isFalse);

      for (final hostile in <Iterable<Iterable<Point2>>>[
        _ThrowingIteratorCreationIterable<Iterable<Point2>>(),
        _ThrowingIterable<Iterable<Point2>>(triangleA),
        _AcceptedCurrentThrowingIterable<Iterable<Point2>>(),
        [_ThrowingIteratorCreationIterable<Point2>()],
        [_ThrowingIterable<Point2>(_point(0, 0))],
        [_AcceptedCurrentThrowingIterable<Point2>()],
      ]) {
        final result = create(hostile);
        expect(
          result,
          isA<Err<FilledPolygonGroupPrimitive, StructuredFailure>>(),
        );
        expect('$result', isNot(contains('hostile')));
        expect('$result', isNot(contains('secret')));
      }

      for (final invalid in [0, -1, 1000001, Revision.maximumValue]) {
        final result = create(
          [triangleA],
          maximumContours: 1,
          maximumTotalPoints: invalid,
        );
        expect(
          result,
          isA<Err<FilledPolygonGroupPrimitive, StructuredFailure>>(),
        );
      }
    });

    test('Shape interaction work ceiling is exact and fails redacted', () {
      expect(
        ShapeInteractionLimits.create(
          maximumChecks: ShapeInteractionLimits.maximumSupportedChecks + 1,
        ),
        isA<Err<ShapeInteractionLimits, StructuredFailure>>(),
      );
      final object = _shapeObject(770);
      Result<bool, StructuredFailure> query(int maximum) =>
          ShapeHitTestingDefinition(
            shapeLimits: _shapeLimits,
            interactionLimits: _ok(
              ShapeInteractionLimits.create(maximumChecks: maximum),
            ),
          ).wholePoint(
            object: object,
            pagePosition: _point(10, 20),
            pageTolerance: 0,
          );
      var exact = 1;
      while (exact < 100000 && query(exact) is Err<bool, StructuredFailure>) {
        exact++;
      }
      expect(exact, lessThan(100000));
      expect(query(exact), isA<Ok<bool, StructuredFailure>>());
      final exhausted = query(exact - 1);
      expect(exhausted, isA<Err<bool, StructuredFailure>>());
      expect('$exhausted', contains('work_limit'));
      expect('$exhausted', isNot(contains('payload')));

      final vertices = List<Point2>.generate(64, (index) {
        final angle = index * math.pi * 2 / 64;
        return _point(math.cos(angle) * 100, math.sin(angle) * 100);
      });
      final largePayload = _ok(
        ShapePayload.create(
          geometry: _ok(
            ShapeVertexGeometry.create(
              kind: ShapeKind.polygon,
              vertices: vertices,
              limits: _shapeLimits,
            ),
          ),
          style: _shapeStyle(),
          limits: _shapeLimits,
        ),
      );
      final large = testObject(
        id: 771,
        typeKey: shapeObjectTypeKey,
        payload: largePayload.encode(),
      );
      final lasso = _ok(
        GeometryQueryPolygon.create(vertices, maximumPoints: 64),
      );
      final bounded =
          ShapeHitTestingDefinition(
            shapeLimits: _shapeLimits,
            interactionLimits: _ok(
              ShapeInteractionLimits.create(maximumChecks: 200),
            ),
          ).wholeLasso(
            object: large,
            polygon: lasso,
            mode: AreaHitMode.intersection,
          );
      expect(bounded, isA<Err<bool, StructuredFailure>>());
      expect('$bounded', contains('work_limit'));

      final root = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [large]),
                ],
              ),
            ],
          ),
        ],
      );
      final registry = testRegistry([ShapeObjectTypeDefinition(_shapeLimits)]);
      final coordinator = _ok(
        DocumentMutationCoordinator.create(
          initialRoot: root,
          validator: DocumentValidator(registry),
          uuidGenerator: UuidSequenceGenerator.fromValues([testUuid(775)]),
          historyLimits: _ok(
            HistoryLimits.create(
              maximumRetainedCommandCount: 4,
              maximumEstimatedRetainedBytes: 10000,
            ),
          ),
          retainedCostEstimator: FixedHistoryCostEstimator(100),
          maximumListeners: 2,
        ),
      );
      final beforeErase = coordinator.snapshot;
      final eraser = _ok(
        WholeEraseGesturePlan.prepare(
          document: beforeErase,
          pageId: root.pages.single.id,
          radius: 1,
          handwritingLimits: _handwritingLimitsForShapeTests(),
          objectRegistry: registry,
          hitTestingRegistry: _ok(
            HitTestingRegistry.create(
              [
                ShapeHitTestingDefinition(
                  shapeLimits: _shapeLimits,
                  interactionLimits: _ok(
                    ShapeInteractionLimits.create(maximumChecks: 200),
                  ),
                ),
              ],
              maximumDefinitions: 1,
              maximumBehaviorResults: 1,
            ),
          ),
          geometryResolver: StrokeGeometryResolver(
            _strokeGeometryLimitsForShapeTests(),
          ),
          maximumObjects: 1,
          maximumStrokes: 1,
          maximumPoints: 2,
          maximumTargets: 1,
          maximumOperations: 1,
        ),
      );
      final eraseResult = eraser.acceptPoint(_point(100, 0));
      expect(eraseResult, isA<Err<EraserGestureUpdate, StructuredFailure>>());
      expect(eraser.affectedStrokeCount, 0);
      expect(coordinator.snapshot.root, same(beforeErase.root));
      expect(coordinator.snapshot.canUndo, beforeErase.canUndo);

      final selection = SelectionController(
        objectRegistry: registry,
        coalescingBoundarySink: coordinator,
        maximumTargets: 1,
      );
      expect(
        selection.replace(
          root: root,
          targets: [
            SelectionTarget.wholeObject(
              pageId: root.pages.single.id,
              objectId: large.id,
            ),
          ],
        ),
        isA<Ok<SelectionState, SelectionFailure>>(),
      );
      final selected = selection.state;
      final pageTester = PageHitTester(
        objectRegistry: registry,
        hitTestingRegistry: _ok(
          HitTestingRegistry.create(
            [
              ShapeHitTestingDefinition(
                shapeLimits: _shapeLimits,
                interactionLimits: _ok(
                  ShapeInteractionLimits.create(maximumChecks: 200),
                ),
              ),
            ],
            maximumDefinitions: 1,
            maximumBehaviorResults: 1,
          ),
        ),
        maximumCandidates: 1,
        maximumResults: 1,
        maximumLassoPoints: 64,
      );
      expect(
        pageTester.lasso(
          page: root.pages.single,
          polygon: lasso.points,
          mode: AreaHitMode.intersection,
        ),
        isA<Err<List<HitTestResult>, StructuredFailure>>(),
      );
      expect(selection.state, same(selected));
      expect(coordinator.snapshot.root, same(beforeErase.root));

      final extreme = _ok(
        AffineTransform2D.restoreFromStorage(const [1e150, 0, 0, 1e140, 0, 0]),
      );
      final extremeObject = testObject(
        id: 773,
        typeKey: shapeObjectTypeKey,
        payload: object.payload,
        transform: extreme,
      );
      final extremeResult =
          ShapeHitTestingDefinition(
            shapeLimits: _shapeLimits,
            interactionLimits: _shapeInteractionLimits,
          ).wholePoint(
            object: extremeObject,
            pagePosition: _point(10e150, 20e140),
            pageTolerance: 0,
          );
      expect(extremeResult, isA<Ok<bool, StructuredFailure>>());

      final overflowing = AffineTransform2D.restoreFromStorage(const [
        1e307,
        0,
        0,
        1e307,
        0,
        0,
      ]);
      if (overflowing is Ok<AffineTransform2D, StructuredFailure>) {
        final result =
            ShapeHitTestingDefinition(
              shapeLimits: _shapeLimits,
              interactionLimits: _shapeInteractionLimits,
            ).wholePoint(
              object: testObject(
                id: 774,
                typeKey: shapeObjectTypeKey,
                payload: object.payload,
                transform: overflowing.value,
              ),
              pagePosition: _point(0, 0),
              pageTolerance: 0,
            );
        expect(result, isA<Err<bool, StructuredFailure>>());
        expect('$result', contains('numeric_uncertain'));
      }

      final forty = vertices.take(40).toList(growable: false);
      final fortyPayload = _ok(
        ShapePayload.create(
          geometry: _ok(
            ShapeVertexGeometry.create(
              kind: ShapeKind.polygon,
              vertices: forty,
              limits: _shapeLimits,
            ),
          ),
          style: _shapeStyle(fillEnabled: false),
          limits: _shapeLimits,
        ),
      );
      expect(
        ShapeRenderingDefinition(shapeLimits: _shapeLimits).render(
          object: testObject(
            id: 772,
            typeKey: shapeObjectTypeKey,
            payload: fortyPayload.encode(),
          ),
          viewport: _viewport(),
          layerOpacity: 1,
          plane: RenderPlane.committed,
          limits: _renderingLimits(),
        ),
        isA<Ok<List<ScenePrimitive>, StructuredFailure>>(),
      );
    });

    test('replacement requests preserve style or geometry as declared', () {
      final source = _shapeObject(750);
      final metadata = CommandMetadata(
        family: CommandFamily.objectReplacement,
        correlationId: CommandCorrelationId.fromUuid(testUuid(751)),
        description: 'Replace shape geometry',
      );
      final replacementGeometry = _ok(
        ShapeEllipseGeometry.create(
          bounds: _rect(20, 30, 120, 90),
          limits: _shapeLimits,
        ),
      );
      final request = _ok(
        ShapeObjectEditRequest.replaceGeometry(
          documentId: DocumentId.fromUuid(testUuid(752)),
          source: source,
          geometry: replacementGeometry,
          limits: _shapeLimits,
          metadata: metadata,
          preconditions: RevisionPreconditions(
            objects: {source.id: _revision(3)},
          ),
        ),
      );
      final before = _ok(
        ShapePayload.decode(source.payload, limits: _shapeLimits),
      );
      final after = _ok(
        ShapePayload.decode(
          request.replacements.single.payload,
          limits: _shapeLimits,
        ),
      );
      expect(after.geometry.kind, ShapeKind.ellipse);
      expect(after.style.dashArray, before.style.dashArray);
      expect(request.changeCategories.geometry, isTrue);
      expect(request.changeCategories.appearance, isFalse);
    });
  });

  group('Image Object', () {
    test('preflight rejects every short PNG prefix and corrupt IHDR CRC', () {
      final preflight = ImageHeaderPreflight(_imageLimits);
      for (var length = 0; length < 33; length++) {
        expect(
          preflight.inspect(
            encodedBytes: _pngFixture.take(length),
            mediaType: _mediaType('image/png'),
          ),
          isA<Err<ImagePreflightResult, StructuredFailure>>(),
        );
      }
      final corrupt = List<int>.of(_pngFixture)..[29] ^= 1;
      expect(
        preflight.inspect(
          encodedBytes: corrupt,
          mediaType: _mediaType('image/png'),
        ),
        isA<Err<ImagePreflightResult, StructuredFailure>>(),
      );
    });

    test(
      'PNG and JPEG preflight detects dimensions, resolution, orientation',
      () {
        final preflight = ImageHeaderPreflight(_imageLimits);
        final png = _ok(
          preflight.inspect(
            encodedBytes: _pngFixture,
            mediaType: _mediaType('image/png'),
          ),
        );
        expect(
          (png.format, png.pixelWidth, png.pixelHeight),
          (ImageFormat.png, 2, 3),
        );
        final jpeg = _ok(
          preflight.inspect(
            encodedBytes: _jpegFixture,
            mediaType: _mediaType('image/jpeg'),
          ),
        );
        expect(
          (jpeg.format, jpeg.pixelWidth, jpeg.pixelHeight),
          (ImageFormat.jpeg, 3, 2),
        );
        expect(jpeg.orientation, ImageOrientation.rotate90);
        expect(jpeg.horizontalDpi, 72);
      },
    );

    test('truncation, disagreement, length and dimensions fail closed', () {
      final preflight = ImageHeaderPreflight(_imageLimits);
      expect(
        preflight.inspect(
          encodedBytes: _pngFixture.take(10),
          mediaType: _mediaType('image/png'),
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        preflight.inspect(
          encodedBytes: _pngFixture,
          mediaType: _mediaType('image/jpeg'),
        ),
        isA<Err<Object?, Object?>>(),
      );
      final hostile = List<int>.of(_pngFixture);
      hostile[16] = 0x7f;
      expect(
        preflight.inspect(
          encodedBytes: hostile,
          mediaType: _mediaType('image/png'),
        ),
        isA<Err<Object?, Object?>>(),
      );
      expect(
        preflight.inspect(
          encodedBytes: _ThrowingIterable<int>(0x89),
          mediaType: _mediaType('image/png'),
        ),
        isA<Err<Object?, Object?>>(),
      );
    });

    test('Image byte capture reads each accepted current exactly once', () {
      final stateful = _StatefulCurrentIterable(_pngFixture);
      final accepted = ImageHeaderPreflight(
        _imageLimits,
      ).inspect(encodedBytes: stateful, mediaType: _mediaType('image/png'));
      expect(accepted, isA<Ok<ImagePreflightResult, StructuredFailure>>());
      expect(stateful.currentReads, _pngFixture.length);

      for (final invalid in [-1, 256]) {
        expect(
          ImageHeaderPreflight(_imageLimits).inspect(
            encodedBytes: [invalid],
            mediaType: _mediaType('image/png'),
          ),
          isA<Err<ImagePreflightResult, StructuredFailure>>(),
        );
      }
      expect(
        ImageHeaderPreflight(_imageLimits).inspect(
          encodedBytes: _AcceptedCurrentThrowingIterable<int>(),
          mediaType: _mediaType('image/png'),
        ),
        isA<Err<ImagePreflightResult, StructuredFailure>>(),
      );

      final exactLimits = _imageLimitsWithMaximumBytes(_pngFixture.length);
      expect(
        ImageHeaderPreflight(exactLimits).inspect(
          encodedBytes: _pngFixture,
          mediaType: _mediaType('image/png'),
        ),
        isA<Ok<ImagePreflightResult, StructuredFailure>>(),
      );
      final rejectedTail = _RejectedAfterIterable<int>(_pngFixture, 0);
      expect(
        ImageHeaderPreflight(exactLimits).inspect(
          encodedBytes: rejectedTail,
          mediaType: _mediaType('image/png'),
        ),
        isA<Err<ImagePreflightResult, StructuredFailure>>(),
      );
      expect(rejectedTail.rejectedCurrentRead, isFalse);
    });

    test('all orientations, crop, fit-down, payload and resource sharing', () {
      for (final orientation in ImageOrientation.values) {
        final payload = _ok(
          ImagePayload.create(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(500)),
            encodedPixelWidth: 200,
            encodedPixelHeight: 100,
            intrinsicWidth: orientation.swapsDimensions ? 75 : 150,
            intrinsicHeight: orientation.swapsDimensions ? 150 : 75,
            orientation: orientation,
            crop: _ok(
              ImageCropRect.create(left: .1, top: .2, right: .9, bottom: .8),
            ),
            renderingIntent: ImageRenderingIntent.smooth,
            alternativeText: 'diagram',
            limits: _imageLimits,
            unknownFields: PreservedMap({
              'future': const PreservedBoolean(true),
            }),
          ),
        );
        final decoded = _ok(
          ImagePayload.decode(payload.encode(), limits: _imageLimits),
        );
        expect(decoded.encode(), payload.encode());
        expect(decoded.accessibilityAlternativeText, 'diagram');
        final definition = ImageObjectTypeDefinition(_imageLimits);
        final duplicate = _ok(
          definition.duplicatePayload(
            payload.encode(),
            imageSchemaVersion,
            _emptyRemapping(),
          ),
        );
        expect(duplicate, payload.encode());
        expect(
          _ok(
            definition.resourceReferences(payload.encode(), imageSchemaVersion),
          ).single.identity,
          payload.resourceIdentity,
        );
      }
      expect(
        _ok(
          fitImageDown(intrinsic: _size(400, 200), available: _size(100, 100)),
        ),
        _size(100, 50),
      );
      expect(
        _ok(fitImageDown(intrinsic: _size(40, 20), available: _size(100, 100))),
        _size(40, 20),
      );
    });

    test('cache evicts/disposes and decoder contracts carry cancellation', () {
      final first = _FakeImageHandle(10, 10);
      final second = _FakeImageHandle(20, 10);
      final cache = _ok(
        DecodedImageCache.create(maximumEntries: 1, maximumPixels: 1000),
      );
      final key1 = ImageDecodeCacheKey(
        resourceIdentity: ResourceIdentity.fromUuid(testUuid(1)),
        pixelWidth: 10,
        pixelHeight: 10,
      );
      final key2 = ImageDecodeCacheKey(
        resourceIdentity: ResourceIdentity.fromUuid(testUuid(2)),
        pixelWidth: 20,
        pixelHeight: 10,
      );
      expect(cache.put(key1, first), isA<Ok<void, StructuredFailure>>());
      expect(cache.put(key2, second), isA<Ok<void, StructuredFailure>>());
      expect(first.disposed, isTrue);
      cache.clear();
      expect(second.disposed, isTrue);
      final cancellation = CancellationController()..cancel('private reason');
      final request = _ok(
        ImageDecodeRequest.create(
          resourceIdentity: key1.resourceIdentity,
          encodedBytes: _pngFixture,
          format: ImageFormat.png,
          encodedPixelWidth: 2,
          encodedPixelHeight: 3,
          maximumEncodedBytes: 4096,
          maximumDecodedPixels: 6,
          cancellationToken: cancellation.token,
        ),
      );
      expect(request.cancellationToken.isCancelled, isTrue);
      expect(request.toString(), isNot(contains('private reason')));
      expect(
        DecodedImageCache.create(maximumEntries: 0, maximumPixels: 1),
        isA<Err<DecodedImageCache, StructuredFailure>>(),
      );
      expect(
        cache.put(key1, _ThrowingImageHandle()),
        isA<Err<void, StructuredFailure>>(),
      );
    });

    test(
      'Flutter adapter decodes a real PNG and validates cancellation',
      () async {
        final request = _ok(
          ImageDecodeRequest.create(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(510)),
            encodedBytes: _realPngFixture,
            format: ImageFormat.png,
            encodedPixelWidth: 1,
            encodedPixelHeight: 1,
            maximumEncodedBytes: 4096,
            maximumDecodedPixels: 1,
            cancellationToken: CancellationController().token,
          ),
        );
        final decoded = await const FlutterImageDecoder().decode(request);
        expect(decoded, isA<Ok<DecodedImageHandle, StructuredFailure>>());
        final handle =
            (decoded as Ok<DecodedImageHandle, StructuredFailure>).value;
        expect((handle.pixelWidth, handle.pixelHeight), (1, 1));
        handle.dispose();

        final cancelled = CancellationController()..cancel('sensitive');
        final cancelledRequest = _ok(
          ImageDecodeRequest.create(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(511)),
            encodedBytes: _realPngFixture,
            format: ImageFormat.png,
            encodedPixelWidth: 1,
            encodedPixelHeight: 1,
            maximumEncodedBytes: 4096,
            maximumDecodedPixels: 1,
            cancellationToken: cancelled.token,
          ),
        );
        final rejected = await const FlutterImageDecoder().decode(
          cancelledRequest,
        );
        expect(rejected, isA<Err<DecodedImageHandle, StructuredFailure>>());
        expect(
          (rejected as Err<DecodedImageHandle, StructuredFailure>).error
              .toString(),
          isNot(contains('sensitive')),
        );
      },
    );

    test('Flutter adapter decodes a real JPEG fixture', () async {
      final request = _ok(
        ImageDecodeRequest.create(
          resourceIdentity: ResourceIdentity.fromUuid(testUuid(512)),
          encodedBytes: _realJpegFixture,
          format: ImageFormat.jpeg,
          encodedPixelWidth: 2,
          encodedPixelHeight: 1,
          maximumEncodedBytes: 4096,
          maximumDecodedPixels: 2,
          cancellationToken: CancellationController().token,
        ),
      );
      final decoded = await const FlutterImageDecoder().decode(request);
      expect(decoded, isA<Ok<DecodedImageHandle, StructuredFailure>>());
      final handle =
          (decoded as Ok<DecodedImageHandle, StructuredFailure>).value;
      expect((handle.pixelWidth, handle.pixelHeight), (2, 1));
      handle.dispose();
    });

    test('Flutter painting applies every orientation and crop once', () async {
      final encoded = _coloredPngFixture();
      final expected = <ImageOrientation, List<int>>{
        ImageOrientation.normal: [1, 2, 3, 4, 5, 6],
        ImageOrientation.mirrorHorizontal: [2, 1, 4, 3, 6, 5],
        ImageOrientation.rotate180: [6, 5, 4, 3, 2, 1],
        ImageOrientation.mirrorVertical: [5, 6, 3, 4, 1, 2],
        ImageOrientation.mirrorHorizontalRotate270: [1, 3, 5, 2, 4, 6],
        ImageOrientation.rotate90: [5, 3, 1, 6, 4, 2],
        ImageOrientation.mirrorHorizontalRotate90: [6, 4, 2, 5, 3, 1],
        ImageOrientation.rotate270: [2, 4, 6, 1, 3, 5],
      };
      for (final orientation in ImageOrientation.values) {
        final payload = _ok(
          ImagePayload.create(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(515)),
            encodedPixelWidth: 2,
            encodedPixelHeight: 3,
            intrinsicWidth: orientation.swapsDimensions ? 3 : 2,
            intrinsicHeight: orientation.swapsDimensions ? 2 : 3,
            orientation: orientation,
            crop: ImageCropRect.full,
            renderingIntent: ImageRenderingIntent.crispEdges,
            limits: _imageLimits,
          ),
        );
        final request = _ok(
          ImageDecodeRequest.create(
            resourceIdentity: payload.resourceIdentity,
            encodedBytes: encoded,
            format: ImageFormat.png,
            encodedPixelWidth: 2,
            encodedPixelHeight: 3,
            maximumEncodedBytes: 4096,
            maximumDecodedPixels: 6,
            cancellationToken: CancellationController().token,
          ),
        );
        final decoded = _ok(
          await const FlutterImageDecoder().decodeForPainting(request),
        );
        final width = orientation.swapsDimensions ? 3 : 2;
        final height = orientation.swapsDimensions ? 2 : 3;
        final recorder = ui.PictureRecorder();
        decoded.paint(
          ui.Canvas(recorder),
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          payload,
          opacity: 1,
        );
        final image = await recorder.endRecording().toImage(width, height);
        final bytes = (await image.toByteData())!;
        expect([
          for (var index = 0; index < width * height; index++)
            bytes.getUint8(index * 4),
        ], expected[orientation]);
        image.dispose();
        decoded.dispose();
      }
    });

    test(
      'resource and Image publish atomically with exact undo redo and save',
      () async {
        final registry = testRegistry([
          ImageObjectTypeDefinition(_imageLimits),
        ]);
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
            validator: DocumentValidator(registry),
            uuidGenerator: UuidSequenceGenerator.fromValues([
              for (var value = 800; value < 840; value++) testUuid(value),
            ]),
            historyLimits: _ok(
              HistoryLimits.create(
                maximumRetainedCommandCount: 8,
                maximumEstimatedRetainedBytes: 100000,
              ),
            ),
            retainedCostEstimator: FixedHistoryCostEstimator(100),
            maximumListeners: 4,
          ),
        );
        final prepared = _ok(
          ImageInsertionPreparer(_imageLimits).prepare(
            resourceIdentity: ResourceIdentity.fromUuid(testUuid(520)),
            mediaType: _mediaType('image/png'),
            resourceRole: _resourceRole(),
            encodedBytes: _realPngFixture,
            alternativeText: 'one pixel',
          ),
        );
        final object = testObject(
          id: 521,
          typeKey: imageObjectTypeKey,
          schemaVersion: imageSchemaVersion,
          payload: prepared.payload.encode(),
        );
        final snapshot = coordinator.snapshot;
        final page = root.pages.single;
        final layer = page.layers.single;
        final publisher = CoordinatorImageAtomicPublisher(
          coordinator: coordinator,
          pageId: page.id,
          layerId: layer.id,
          metadata: phase3Metadata(
            family: CommandFamily.objectCollectionEdit.value,
          ),
          maximumOperations: 2,
        );
        final request = _ok(
          ImageAtomicPublicationRequest.create(
            preparation: prepared,
            object: object,
            limits: _imageLimits,
            expectedDocumentRevision: snapshot.revisions.document,
            cancellationToken: CancellationController().token,
          ),
        );
        expect(
          await ImageInsertionPublicationService(
            decoder: _SuccessfulImageDecoder(),
            publisher: publisher,
          ).publish(request),
          isA<Ok<void, StructuredFailure>>(),
        );
        expect(coordinator.snapshot.root.resources.entries, hasLength(1));
        expect(coordinator.snapshot.resources.single.bytes, _realPngFixture);
        final published = coordinator.snapshot;
        final mutableResources = published.resources.toList();
        final publicSnapshot = _ok(
          DocumentCoordinatorSnapshot.create(
            root: published.root,
            resources: mutableResources,
            maximumResources: 1,
            revisions: published.revisions,
            currentContentIdentity: published.currentContentIdentity,
            savedContentIdentity: published.savedContentIdentity,
            canUndo: published.canUndo,
            canRedo: published.canRedo,
            historyTraversalEnabled: published.historyTraversalEnabled,
          ),
        );
        mutableResources.clear();
        expect(publicSnapshot.resources, hasLength(1));
        expect(publicSnapshot.resources.clear, throwsUnsupportedError);
        expect(
          DocumentCoordinatorSnapshot.create(
            root: published.root,
            resources: _RejectedTailIterable(published.resources.single),
            maximumResources: 1,
            revisions: published.revisions,
            currentContentIdentity: published.currentContentIdentity,
            savedContentIdentity: published.savedContentIdentity,
            canUndo: published.canUndo,
            canRedo: published.canRedo,
            historyTraversalEnabled: published.historyTraversalEnabled,
          ),
          isA<Err<DocumentCoordinatorSnapshot, StructuredFailure>>(),
        );
        expect(
          coordinator.snapshot.root.pages.single.layers.single.objects.single,
          object,
        );
        expect(coordinator.undo(), isA<Ok<CommandCommit, CommandFailure>>());
        expect(coordinator.snapshot.root.resources.entries, isEmpty);
        expect(coordinator.snapshot.resources, isEmpty);
        expect(
          coordinator.snapshot.root.pages.single.layers.single.objects,
          isEmpty,
        );
        expect(coordinator.redo(), isA<Ok<CommandCommit, CommandFailure>>());
        expect(coordinator.snapshot.resources.single.bytes, _realPngFixture);
        final capture = coordinator.captureForSave();
        expect(capture.resources.single.bytes, _realPngFixture);

        final stale = await ImageInsertionPublicationService(
          decoder: _SuccessfulImageDecoder(),
          publisher: publisher,
        ).publish(request);
        expect(stale, isA<Err<void, StructuredFailure>>());
        expect(coordinator.snapshot.resources, hasLength(1));
      },
    );
  });

  group('Text Object', () {
    test('nested permissive values are revalidated under caller limits', () {
      final permissive = _textPayload(['nested']);
      final strict = _ok(
        TextLimits.create(
          maximumParagraphs: 1,
          maximumRunsPerParagraph: 1,
          maximumScalarsPerRun: 6,
          maximumTotalScalars: 6,
          maximumFontFamilyScalars: 1,
          maximumLanguageHintScalars: 1,
          maximumUnknownFields: 1,
          maximumUnknownNodes: 8,
          maximumNestingDepth: 2,
          maximumUnknownStringCodeUnits: 64,
          maximumFontSize: 20,
          maximumBoxDimension: 300,
          maximumPadding: 10,
          maximumLayoutLines: 4,
          maximumLayoutFragments: 4,
          maximumCaretStops: 8,
          maximumRangeRectangles: 4,
          maximumPendingEdits: 1,
        ),
      );
      expect(
        TextPayload.create(
          paragraphs: permissive.paragraphs,
          defaultCharacterStyle: permissive.defaultCharacterStyle,
          defaultParagraphStyle: permissive.defaultParagraphStyle,
          boxMode: permissive.boxMode,
          intrinsicWidth: permissive.intrinsicWidth,
          intrinsicHeight: permissive.intrinsicHeight,
          padding: permissive.padding,
          verticalAlignment: permissive.verticalAlignment,
          overflowPolicy: permissive.overflowPolicy,
          limits: strict,
          unknownFields: permissive.unknownFields,
        ),
        isA<Err<TextPayload, StructuredFailure>>(),
      );
      expect(
        TextCharacterStyle.create(
          preferredFontFamily: 'bad\uD800',
          genericFontFamily: TextGenericFontFamily.sansSerif,
          fontSize: 12,
          weight: 400,
          italic: false,
          underline: false,
          strikethrough: false,
          argb: 0xff000000,
          limits: _textLimits,
        ),
        isA<Err<TextCharacterStyle, StructuredFailure>>(),
      );
    });

    test(
      'grapheme adapter preserves emoji combining ZWJ VS and RTL clusters',
      () {
        const source = 'e\u0301👩‍👩‍👧‍👦✈️ مرحبا';
        final boundaries = _ok(
          const TextGraphemeBoundaryService().boundaries(
            source,
            maximumScalars: 100,
          ),
        );
        expect(boundaries.first, 0);
        expect(boundaries.last, source.runes.length);
        expect(boundaries, contains(2));
        expect(boundaries, isNot(contains(3)));
        for (final boundary in boundaries) {
          expect(
            _ok(
              const TextGraphemeBoundaryService().isBoundary(
                source,
                boundary,
                maximumScalars: 100,
              ),
            ),
            isTrue,
          );
        }
      },
    );

    test('normalization, paragraphs, runs, styles and unknowns round-trip', () {
      const decomposed = 'Cafe\u0301';
      final payload = _textPayload([decomposed, 'مرحبا 👋']);
      final decoded = _ok(
        TextPayload.decode(payload.encode(), limits: _textLimits),
      );
      expect(decoded.logicalText, '$decomposed\nمرحبا 👋');
      expect(decoded.encode(), payload.encode());
      expect(decoded.logicalText, isNot('Café\nمرحبا 👋'));
      final definition = TextObjectTypeDefinition(
        _textLimits,
        FlutterTextLayoutEngine(_textLimits),
      );
      expect(
        definition.validatePayload(payload.encode(), textSchemaVersion).isValid,
        isTrue,
      );
      expect(
        _ok(
          definition.classifyPayloadChange(
            payload.encode(),
            _textPayload(['changed']).encode(),
            textSchemaVersion,
          ),
        ).text,
        isTrue,
      );
    });

    test('nested Text unknown changes are deterministic metadata', () {
      final definition = TextObjectTypeDefinition(
        _textLimits,
        FlutterTextLayoutEngine(_textLimits),
      );
      final source = _textPayload(['base']);
      PreservedMap withNestedUnknown({
        PreservedData? runUnknown,
        PreservedData? paragraphUnknown,
        PreservedData? characterUnknown,
        PreservedData? paragraphStyleUnknown,
        PreservedData? topUnknown,
        String? text,
      }) {
        final encoded = source.encode();
        final paragraphs = encoded.values['paragraphs']! as PreservedList;
        final paragraph = paragraphs.values.single as PreservedMap;
        final runs = paragraph.values['runs']! as PreservedList;
        final run = runs.values.single as PreservedMap;
        final runStyle = run.values['style']! as PreservedMap;
        final paragraphStyle = paragraph.values['style']! as PreservedMap;
        final nextRunStyle = PreservedMap({
          ...runStyle.values,
          if (characterUnknown != null) 'characterFuture': characterUnknown,
        });
        final nextRun = PreservedMap({
          ...run.values,
          'text': PreservedString(text ?? source.logicalText),
          'style': nextRunStyle,
          if (runUnknown != null) 'runFuture': runUnknown,
        });
        final nextParagraph = PreservedMap({
          ...paragraph.values,
          'runs': PreservedList([nextRun]),
          'style': PreservedMap({
            ...paragraphStyle.values,
            if (paragraphStyleUnknown != null)
              'paragraphStyleFuture': paragraphStyleUnknown,
          }),
          if (paragraphUnknown != null) 'paragraphFuture': paragraphUnknown,
        });
        return PreservedMap({
          ...encoded.values,
          'paragraphs': PreservedList([nextParagraph]),
          if (topUnknown != null) 'topFuture2': topUnknown,
        });
      }

      final cases =
          <({PreservedMap after, bool appearance, bool text, bool geometry})>[
            (
              after: withNestedUnknown(
                runUnknown: const PreservedBoolean(true),
              ),
              appearance: false,
              text: false,
              geometry: false,
            ),
            (
              after: withNestedUnknown(
                paragraphUnknown: const PreservedBoolean(true),
              ),
              appearance: false,
              text: false,
              geometry: false,
            ),
            (
              after: withNestedUnknown(
                characterUnknown: const PreservedBoolean(true),
              ),
              appearance: true,
              text: false,
              geometry: false,
            ),
            (
              after: withNestedUnknown(
                paragraphStyleUnknown: const PreservedBoolean(true),
              ),
              appearance: true,
              text: false,
              geometry: false,
            ),
            (
              after: withNestedUnknown(
                topUnknown: const PreservedBoolean(true),
              ),
              appearance: false,
              text: false,
              geometry: false,
            ),
            (
              after: withNestedUnknown(
                runUnknown: const PreservedBoolean(true),
                paragraphUnknown: const PreservedBoolean(true),
                text: 'changed',
              ),
              appearance: false,
              text: true,
              geometry: true,
            ),
          ];
      for (final value in cases) {
        final semantics = _ok(
          definition.classifyPayloadChange(
            source.encode(),
            value.after,
            textSchemaVersion,
          ),
        );
        expect(semantics.metadata, isTrue);
        expect(semantics.appearance, value.appearance);
        expect(semantics.text, value.text);
        expect(semantics.geometry, value.geometry);
        expect('$semantics', isNot(contains('Future')));
      }
    });

    test('nested Text metadata is authoritative in both command paths', () {
      final beforePayload = _textPayload(['base']);
      final encoded = beforePayload.encode();
      final paragraph =
          (encoded.values['paragraphs']! as PreservedList).values.single
              as PreservedMap;
      final run =
          (paragraph.values['runs']! as PreservedList).values.single
              as PreservedMap;
      final afterData = PreservedMap({
        ...encoded.values,
        'paragraphs': PreservedList([
          PreservedMap({
            ...paragraph.values,
            'runs': PreservedList([
              PreservedMap({
                ...run.values,
                'futureRun': const PreservedBoolean(true),
              }),
            ]),
          }),
        ]),
      });
      final afterPayload = _ok(
        TextPayload.decode(afterData, limits: _textLimits),
      );
      final source = testObject(
        id: 615,
        typeKey: textObjectTypeKey,
        schemaVersion: textSchemaVersion,
        payload: beforePayload.encode(),
      );
      const correct = ObjectReplacementChangeCategories(
        appearance: false,
        text: false,
        metadata: true,
      );
      expect(
        TextObjectEditRequest.replace(
          documentId: DocumentId.fromUuid(testUuid(1)),
          source: source,
          payload: afterPayload,
          limits: _textLimits,
          layoutEngine: FlutterTextLayoutEngine(_textLimits),
          metadata: phase3Metadata(correlation: 916),
          preconditions: RevisionPreconditions(),
          changeCategories: const ObjectReplacementChangeCategories(
            appearance: false,
            text: false,
            metadata: false,
          ),
        ),
        isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );
      expect(
        TextObjectEditRequest.replace(
          documentId: DocumentId.fromUuid(testUuid(1)),
          source: source,
          payload: afterPayload,
          limits: _textLimits,
          layoutEngine: FlutterTextLayoutEngine(_textLimits),
          metadata: phase3Metadata(correlation: 917),
          preconditions: RevisionPreconditions(),
          changeCategories: correct,
        ),
        isA<Ok<AtomicObjectReplacementRequest, StructuredFailure>>(),
      );

      final root = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [source]),
                ],
              ),
            ],
          ),
        ],
      );
      final countingLayout = _CountingTextLayoutEngine(
        FlutterTextLayoutEngine(_textLimits),
      );
      final coordinator = _ok(
        DocumentMutationCoordinator.create(
          initialRoot: root,
          validator: DocumentValidator(
            testRegistry([
              TextObjectTypeDefinition(_textLimits, countingLayout),
            ]),
          ),
          uuidGenerator: UuidSequenceGenerator.fromValues([
            for (var value = 920; value < 940; value++) testUuid(value),
          ]),
          historyLimits: _ok(
            HistoryLimits.create(
              maximumRetainedCommandCount: 8,
              maximumEstimatedRetainedBytes: 100000,
            ),
          ),
          retainedCostEstimator: FixedHistoryCostEstimator(100),
          maximumListeners: 4,
        ),
      );
      final snapshot = coordinator.snapshot;
      final page = root.pages.single;
      final layer = page.layers.single;
      final replacement = testObject(
        id: 615,
        typeKey: textObjectTypeKey,
        schemaVersion: textSchemaVersion,
        payload: afterPayload.encode(),
      );
      final request = _ok(
        AtomicObjectCollectionEditRequest.create(
          documentId: root.id,
          pageId: page.id,
          metadata: phase3Metadata(
            family: 'alnote.commands.object.collection_edit',
            correlation: 918,
          ),
          preconditions: RevisionPreconditions(
            pages: {page.id: snapshot.revisions.pages[page.id]!},
            layerMembership: {
              layer.id: snapshot.revisions.layerMembership[layer.id]!,
            },
            objects: {source.id: snapshot.revisions.objects[source.id]!},
          ),
          replacements: [replacement],
          replacementChangeCategories: correct,
          maximumOperations: 1,
        ),
      );
      final committed = _ok(coordinator.execute(request));
      expect(committed.change.flags.metadata, isTrue);
      expect(committed.change.flags.appearance, isFalse);
      expect(committed.change.flags.text, isFalse);
      final callsAfterExecute = countingLayout.calls;
      expect(_ok(coordinator.undo()).change.flags.metadata, isTrue);
      expect(_ok(coordinator.redo()).change.flags.metadata, isTrue);
      expect(countingLayout.calls, callsAfterExecute);
      expect('$committed', isNot(contains('futureRun')));
    });

    test('grapheme replacement and semantic history barriers are exact', () {
      const graphemes = TextGraphemeBoundaryService();
      const source = 'A\u{1F469}\u200D\u{1F4BB}B';
      expect(
        _ok(
          graphemes.replace(
            text: source,
            startScalar: 1,
            endScalar: 4,
            replacement: 'X',
            maximumScalars: 10,
          ),
        ),
        'AXB',
      );
      expect(
        graphemes.replace(
          text: source,
          startScalar: 2,
          endScalar: 4,
          replacement: 'X',
          maximumScalars: 10,
        ),
        isA<Err<String, StructuredFailure>>(),
      );

      PendingTextEdit edit(
        TextEditKind kind,
        int start,
        int end,
        String replacement,
      ) => _ok(
        PendingTextEdit.create(
          kind: kind,
          range: _ok(TextRange.create(_position(0, start), _position(0, end))),
          replacement: replacement,
          limits: _textLimits,
        ),
      );
      final first = edit(TextEditKind.insertion, 0, 0, 'a');
      final second = edit(TextEditKind.insertion, 1, 1, 'b');
      expect(
        TextHistoryCoalescingPolicy.mayCoalesce(previous: first, next: second),
        isTrue,
      );
      for (final barrier in TextHistoryBarrier.values) {
        expect(
          TextHistoryCoalescingPolicy.mayCoalesce(
            previous: first,
            next: second,
            barrier: barrier,
          ),
          isFalse,
        );
      }
      expect(
        TextHistoryCoalescingPolicy.mayCoalesce(
          previous: edit(TextEditKind.backwardDeletion, 4, 5, ''),
          next: edit(TextEditKind.backwardDeletion, 3, 4, ''),
        ),
        isTrue,
      );
      expect(
        TextHistoryCoalescingPolicy.mayCoalesce(
          previous: edit(TextEditKind.forwardDeletion, 4, 5, ''),
          next: edit(TextEditKind.forwardDeletion, 4, 5, ''),
        ),
        isTrue,
      );
      expect(
        TextHistoryCoalescingPolicy.mayCoalesce(
          previous: first,
          next: edit(TextEditKind.paste, 1, 1, 'b'),
        ),
        isFalse,
      );
    });

    test('pending edits use the evolving staged draft atomically', () {
      TextEditorSession sessionFor(TextPayload payload) => _ok(
        TextEditorSession.create(
          object: testObject(
            typeKey: textObjectTypeKey,
            schemaVersion: textSchemaVersion,
            payload: payload.encode(),
          ),
          draft: payload,
          baseObjectRevision: _revision(0),
          selection: _ok(TextRange.create(_position(0, 0), _position(0, 0))),
          typingStyle: payload.defaultCharacterStyle,
          limits: _textLimits,
        ),
      );
      PendingTextEdit edit(
        TextEditKind kind,
        int startParagraph,
        int start,
        int endParagraph,
        int end,
        String replacement,
      ) => _ok(
        PendingTextEdit.create(
          kind: kind,
          range: _ok(
            TextRange.create(
              _position(startParagraph, start),
              _position(endParagraph, end),
            ),
          ),
          replacement: replacement,
          limits: _textLimits,
        ),
      );

      final typing = sessionFor(_textPayload(['']));
      expect(
        typing.addPending(edit(TextEditKind.insertion, 0, 0, 0, 0, 'a')),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(typing.draft.logicalText, 'a');
      expect(
        typing.addPending(edit(TextEditKind.insertion, 0, 1, 0, 1, 'b')),
        isA<Ok<void, StructuredFailure>>(),
      );
      for (final value in 'cdef'.split('')) {
        final offset = typing.draft.paragraphs.single.scalarLength;
        expect(
          typing.addPending(
            edit(TextEditKind.insertion, 0, offset, 0, offset, value),
          ),
          isA<Ok<void, StructuredFailure>>(),
        );
      }
      expect(typing.draft.logicalText, 'abcdef');
      expect(typing.pendingEdits, hasLength(6));

      expect(
        typing.addPending(edit(TextEditKind.backwardDeletion, 0, 5, 0, 6, '')),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(typing.draft.logicalText, 'abcde');
      expect(
        typing.addPending(edit(TextEditKind.forwardDeletion, 0, 0, 0, 1, '')),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(typing.draft.logicalText, 'bcde');
      expect(
        typing.addPending(edit(TextEditKind.insertion, 0, 1, 0, 3, 'X')),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(typing.draft.logicalText, 'bXe');
      expect(
        typing.addPending(edit(TextEditKind.insertion, 0, 2, 0, 2, '\nY')),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(typing.draft.logicalText, 'bX\nYe');

      final cross = sessionFor(_textPayload(['first', 'second']));
      expect(
        cross.addPending(edit(TextEditKind.insertion, 0, 2, 1, 3, 'Z')),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(cross.draft.logicalText, 'fiZond');

      final unicode = sessionFor(_textPayload(['']));
      for (final cluster in ['e\u0301', '🇺🇸', '👍🏽', '👩‍💻']) {
        final offset = unicode.draft.paragraphs.single.scalarLength;
        expect(
          unicode.addPending(
            edit(TextEditKind.insertion, 0, offset, 0, offset, cluster),
          ),
          isA<Ok<void, StructuredFailure>>(),
        );
      }
      final beforeDraft = unicode.draft;
      final beforeSelection = unicode.selection;
      final beforePending = unicode.pendingEdits;
      expect(
        unicode.addPending(edit(TextEditKind.insertion, 0, 1, 0, 1, 'invalid')),
        isA<Err<void, StructuredFailure>>(),
      );
      expect(unicode.draft, same(beforeDraft));
      expect(unicode.selection, same(beforeSelection));
      expect(unicode.pendingEdits, beforePending);
      expect(
        () => unicode.pendingEdits.add(
          edit(TextEditKind.insertion, 0, 0, 0, 0, 'x'),
        ),
        throwsUnsupportedError,
      );

      final onePending = _adjustTextLimits(maximumPendingEdits: 1);
      final boundedDraft = _textPayload(['']);
      final bounded = _ok(
        TextEditorSession.create(
          object: testObject(
            typeKey: textObjectTypeKey,
            schemaVersion: textSchemaVersion,
            payload: boundedDraft.encode(),
          ),
          draft: boundedDraft,
          baseObjectRevision: _revision(0),
          selection: _ok(TextRange.create(_position(0, 0), _position(0, 0))),
          typingStyle: boundedDraft.defaultCharacterStyle,
          limits: onePending,
        ),
      );
      expect(
        bounded.addPending(edit(TextEditKind.insertion, 0, 0, 0, 0, 'a')),
        isA<Ok<void, StructuredFailure>>(),
      );
      final exactDraft = bounded.draft;
      final exactSelection = bounded.selection;
      expect(
        bounded.addPending(edit(TextEditKind.insertion, 0, 1, 0, 1, 'b')),
        isA<Err<void, StructuredFailure>>(),
      );
      expect(bounded.draft, same(exactDraft));
      expect(bounded.selection, same(exactSelection));
      expect(bounded.pendingEdits, hasLength(1));
    });

    test('IME confirmation uses the evolving staged draft coordinates', () {
      final payload = _textPayload(['a']);
      final session = _ok(
        TextEditorSession.create(
          object: testObject(
            typeKey: textObjectTypeKey,
            schemaVersion: textSchemaVersion,
            payload: payload.encode(),
          ),
          draft: payload,
          baseObjectRevision: _revision(0),
          selection: _ok(TextRange.create(_position(0, 1), _position(0, 1))),
          typingStyle: payload.defaultCharacterStyle,
          limits: _textLimits,
        ),
      );
      final first = _ok(
        PendingTextEdit.create(
          kind: TextEditKind.insertion,
          range: _ok(TextRange.create(_position(0, 1), _position(0, 1))),
          replacement: 'b',
          limits: _textLimits,
        ),
      );
      expect(session.addPending(first), isA<Ok<void, StructuredFailure>>());
      final composition = _ok(
        TextComposition.create(
          range: _ok(TextRange.create(_position(0, 2), _position(0, 2))),
          text: '👩‍💻',
          limits: _textLimits,
        ),
      );
      expect(
        session.updateComposition(composition),
        isA<Ok<void, StructuredFailure>>(),
      );
      expect(session.confirmComposition(), isA<Ok<void, StructuredFailure>>());
      expect(session.draft.logicalText, 'ab👩‍💻');
      expect(session.composition, isNull);
    });

    test(
      'IME remains temporary, stale evidence is fixed, clipboard is bounded',
      () {
        final payload = _textPayload(['draft']);
        final start = _position(0, 0), end = _position(0, 0);
        final range = _ok(TextRange.create(start, end));
        final object = testObject(
          typeKey: textObjectTypeKey,
          payload: payload.encode(),
        );
        final session = _ok(
          TextEditorSession.create(
            object: object,
            draft: payload,
            baseObjectRevision: _revision(4),
            selection: range,
            typingStyle: payload.defaultCharacterStyle,
            limits: _textLimits,
          ),
        );
        expect(
          session.updateComposition(
            _ok(
              TextComposition.create(
                range: range,
                text: '👩‍💻',
                limits: _textLimits,
              ),
            ),
          ),
          isA<Ok<void, StructuredFailure>>(),
        );
        expect(session.pendingEdits, isEmpty);
        expect(
          session.confirmComposition(),
          isA<Ok<void, StructuredFailure>>(),
        );
        expect(session.pendingEdits.single.replacement, '👩‍💻');
        final stale = StaleTextDraftEvidence(
          baseRevision: _revision(4),
          currentRevision: _revision(5),
        );
        expect(stale.choices, StaleTextDraftRecovery.values);
        final removed = StaleTextDraftEvidence(
          baseRevision: _revision(4),
          currentRevision: null,
        );
        expect(removed.currentRevision, isNull);
        expect(removed.choices, StaleTextDraftRecovery.values);
        final sanitizer = TextClipboardSanitizer(_textLimits);
        expect(
          sanitizer.sanitize(
            kind: TextClipboardKind.unsupportedExternalRichText,
            callerProvidedFallback: 'plain only',
          ),
          isA<Ok<SanitizedTextClipboard, StructuredFailure>>(),
        );
        expect(
          sanitizer.sanitize(
            kind: TextClipboardKind.unsupportedExternalRichText,
            callerProvidedFallback: List.filled(5000, 'x').join(),
          ),
          isA<Err<Object?, Object?>>(),
        );
      },
    );

    test(
      'stale Text replacement rejects without overwriting newer content',
      () {
        final source = testObject(
          id: 610,
          typeKey: textObjectTypeKey,
          schemaVersion: textSchemaVersion,
          payload: _textPayload(['base']).encode(),
        );
        final root = testNotebook(
          sections: [
            testSection(
              pages: [
                testPage(
                  layers: [
                    testContentLayer(objects: [source]),
                  ],
                ),
              ],
            ),
          ],
        );
        final coordinator = _ok(
          DocumentMutationCoordinator.create(
            initialRoot: root,
            validator: DocumentValidator(
              testRegistry([
                TextObjectTypeDefinition(
                  _textLimits,
                  FlutterTextLayoutEngine(_textLimits),
                ),
              ]),
            ),
            uuidGenerator: UuidSequenceGenerator.fromValues([
              for (var value = 900; value < 920; value++) testUuid(value),
            ]),
            historyLimits: _ok(
              HistoryLimits.create(
                maximumRetainedCommandCount: 8,
                maximumEstimatedRetainedBytes: 100000,
              ),
            ),
            retainedCostEstimator: FixedHistoryCostEstimator(100),
            maximumListeners: 4,
          ),
        );
        final base = coordinator.snapshot;
        final layer = root.pages.single.layers.single;
        AtomicObjectReplacementRequest request(String text, int correlation) =>
            _ok(
              TextObjectEditRequest.replace(
                documentId: root.id,
                source: source,
                payload: _textPayload([text]),
                limits: _textLimits,
                layoutEngine: FlutterTextLayoutEngine(_textLimits),
                metadata: phase3Metadata(correlation: correlation),
                preconditions: RevisionPreconditions(
                  objects: {source.id: base.revisions.objects[source.id]!},
                  layerMembership: {
                    layer.id: base.revisions.layerMembership[layer.id]!,
                  },
                ),
                changeCategories: const ObjectReplacementChangeCategories(
                  geometry: true,
                  text: true,
                  appearance: false,
                  metadata: false,
                ),
              ),
            );
        expect(
          coordinator.execute(request('newer', 901)),
          isA<Ok<CommandCommit, CommandFailure>>(),
        );
        final newerRoot = coordinator.snapshot.root;
        expect(
          coordinator.execute(request('stale overwrite', 902)),
          isA<Err<CommandCommit, CommandFailure>>(),
        );
        expect(coordinator.snapshot.root, same(newerRoot));
        expect(
          _ok(
            TextPayload.decode(
              newerRoot.pages.single.layers.single.objects.single.payload,
              limits: _textLimits,
            ),
          ).logicalText,
          'newer',
        );
      },
    );
  });

  test('Flutter layout adapter returns bounded scalar-position geometry', () {
    final payload = _textPayload(['A👩‍💻B', 'مرحبا']);
    final range = _ok(TextRange.create(_position(0, 1), _position(0, 4)));
    final layout = FlutterTextLayoutEngine(
      _textLimits,
    ).layout(TextLayoutRequest(payload: payload, range: range));
    expect(layout, isA<Ok<TextLayoutSnapshot, StructuredFailure>>());
    final snapshot =
        (layout as Ok<TextLayoutSnapshot, StructuredFailure>).value;
    expect(snapshot.lines, isNotEmpty);
    expect(snapshot.caretStops.first.position, _position(0, 0));
    expect(snapshot.caretStops.last.position, _position(1, 5));
    expect(
      snapshot.rangeGeometry.length,
      lessThanOrEqualTo(_textLimits.maximumRangeRectangles),
    );
    expect(snapshot.fontDiagnostics, isNotEmpty);
    expect(
      snapshot.caretStops
          .where((stop) => stop.position.paragraphIndex == 0)
          .map((stop) => stop.position.scalarOffset),
      orderedEquals(const [0, 1, 4, 5]),
    );
  });

  test(
    'shared TextPainter authority fixes fallback locale and lifecycle',
    () async {
      final observer = _TextPainterLifecycleEvidence();
      final factory = FlutterTextPainterFactory(lifecycleObserver: observer);
      final payload = _configuredTextPayload(
        genericFamily: TextGenericFontFamily.monospace,
        preferredFamily: 'Definitely Missing AL NOTE Font',
        languageHint: 'zh-Hant-TW',
        width: 92,
      );
      final painter = factory.create(
        payload: payload,
        paragraph: payload.paragraphs.single,
        maximumWidth: 92,
        layerOpacity: 1,
      );
      final root = painter.text! as flutter.TextSpan;
      final run = root.children!.single as flutter.TextSpan;
      expect(
        root.style!.fontFamily,
        payload.defaultCharacterStyle.preferredFontFamily,
      );
      expect(root.style!.fontFamilyFallback, ['monospace']);
      expect(run.style!.fontFamilyFallback, ['monospace']);
      expect(run.style!.fontSize, 24);
      expect(run.style!.fontStyle, flutter.FontStyle.italic);
      expect(
        run.style!.decoration,
        flutter.TextDecoration.combine(const [
          flutter.TextDecoration.underline,
          flutter.TextDecoration.lineThrough,
        ]),
      );
      expect(painter.locale!.languageCode, 'zh');
      expect(painter.locale!.scriptCode, 'Hant');
      expect(painter.locale!.countryCode, 'TW');
      expect(painter.textWidthBasis, flutter.TextWidthBasis.longestLine);
      factory.dispose(painter);

      final regionPayload = _configuredTextPayload(languageHint: 'en-US');
      final regionPainter = factory.create(
        payload: regionPayload,
        paragraph: regionPayload.paragraphs.single,
        maximumWidth: 120,
        layerOpacity: 1,
      );
      expect(regionPainter.locale!.languageCode, 'en');
      expect(regionPainter.locale!.countryCode, 'US');
      factory.dispose(regionPainter);

      for (final value in <({String hint, String? script, String? region})>[
        (hint: 'en-u-ca-gregory', script: null, region: null),
        (hint: 'sl-rozaj-biske', script: null, region: null),
        (hint: 'de-CH-1901', script: null, region: 'CH'),
        (hint: 'zh-Hant-TW-u-nu-hanidec', script: 'Hant', region: 'TW'),
      ]) {
        final localePayload = _configuredTextPayload(languageHint: value.hint);
        final localePainter = factory.create(
          payload: localePayload,
          paragraph: localePayload.paragraphs.single,
          maximumWidth: 120,
          layerOpacity: 1,
        );
        expect(localePainter.locale!.scriptCode, value.script);
        expect(localePainter.locale!.countryCode, value.region);
        factory.dispose(localePainter);
        expect(
          FlutterTextLayoutEngine(
            _textLimits,
            painterFactory: factory,
          ).layout(TextLayoutRequest(payload: localePayload)),
          isA<Ok<TextLayoutSnapshot, StructuredFailure>>(),
        );
      }

      final sans = _configuredTextPayload(text: 'iiiiiiiiWW', width: 500);
      final mono = _configuredTextPayload(
        genericFamily: TextGenericFontFamily.monospace,
        text: 'iiiiiiiiWW',
        width: 500,
      );
      final sansPainter = factory.create(
        payload: sans,
        paragraph: sans.paragraphs.single,
        maximumWidth: 500,
        layerOpacity: 1,
      );
      final monoPainter = factory.create(
        payload: mono,
        paragraph: mono.paragraphs.single,
        maximumWidth: 500,
        layerOpacity: 1,
      );
      final sansStyle = (sansPainter.text! as flutter.TextSpan).style!;
      final monoStyle = (monoPainter.text! as flutter.TextSpan).style!;
      expect(sansStyle.fontFamilyFallback, ['sans-serif']);
      expect(monoStyle.fontFamilyFallback, ['monospace']);
      expect(sansStyle.fontFamilyFallback, isNot(monoStyle.fontFamilyFallback));
      factory.dispose(sansPainter);
      factory.dispose(monoPainter);

      final snapshot = _ok(
        FlutterTextLayoutEngine(
          _textLimits,
          painterFactory: factory,
        ).layout(TextLayoutRequest(payload: payload)),
      );
      expect(snapshot.paragraphs.single.bounds.height, greaterThan(0));
      expect(observer.createdCount, observer.disposedCount);
      expect(observer.doubleDisposed, isFalse);
      expect(observer.liveCount, 0);

      for (final mode in TextBoxMode.values) {
        for (final alignment in TextVerticalAlignment.values) {
          for (final overflow in TextOverflowPolicy.values) {
            final value = _configuredTextPayload(
              text: 'wrapped geometry agreement across modes',
              languageHint: 'zh-Hant-TW',
              genericFamily: TextGenericFontFamily.monospace,
              mode: mode,
              alignment: alignment,
              overflow: overflow,
              width: 88,
              height: 160,
            );
            final layout = _ok(
              FlutterTextLayoutEngine(
                _textLimits,
                painterFactory: factory,
              ).layout(
                TextLayoutRequest(
                  payload: value,
                  range: _ok(
                    TextRange.create(
                      _position(0, 0),
                      _position(0, value.paragraphs.single.scalarLength),
                    ),
                  ),
                ),
              ),
            );
            final paragraphPainter = factory.create(
              payload: value,
              paragraph: value.paragraphs.single,
              maximumWidth:
                  value.intrinsicWidth -
                  value.padding.left -
                  value.padding.right,
              layerOpacity: 1,
            );
            expect(
              layout.paragraphs.single.bounds.height,
              math.max(
                paragraphPainter.height,
                paragraphPainter.preferredLineHeight,
              ),
            );
            expect(layout.lines, isNotEmpty);
            expect(layout.caretStops, isNotEmpty);
            expect(layout.rangeGeometry, isNotEmpty);
            factory.dispose(paragraphPainter);
          }
        }
      }
      expect(observer.createdCount, observer.disposedCount);
      expect(observer.doubleDisposed, isFalse);
      expect(observer.liveCount, 0);

      final pixelPayload = _configuredTextPayload(
        text: 'pixel wrapping agreement',
        genericFamily: TextGenericFontFamily.monospace,
        languageHint: 'zh-Hant-TW',
        mode: TextBoxMode.fixedWidthFixedHeight,
        alignment: TextVerticalAlignment.center,
        overflow: TextOverflowPolicy.clip,
        width: 90,
        height: 120,
      );
      final pixelLayout = _ok(
        FlutterTextLayoutEngine(
          _textLimits,
        ).layout(TextLayoutRequest(payload: pixelPayload)),
      );
      final primitive = _ok(
        TextRenderingDefinition(
          _textLimits,
          FlutterTextLayoutEngine(_textLimits),
        ).render(
          object: testObject(
            typeKey: textObjectTypeKey,
            schemaVersion: textSchemaVersion,
            payload: pixelPayload.encode(),
          ),
          viewport: _viewport(),
          layerOpacity: .7,
          plane: RenderPlane.committed,
          limits: _renderingLimits(),
        ),
      ).single;
      expect(
        await _paintedBytes(primitive),
        await _paintedTextWithFactory(pixelPayload, pixelLayout, .7),
      );
    },
  );

  test('Text painting multiplies packed alpha by Layer opacity', () async {
    Future<int> maximumPaintedAlpha(int argb, double layerOpacity) async {
      final engine = FlutterTextLayoutEngine(_textLimits);
      final payload = _configuredTextPayload(
        text: 'M',
        fontSize: 64,
        argb: argb,
        italic: false,
        underline: false,
        strikethrough: false,
        width: 240,
      );
      final primitive = _ok(
        TextRenderingDefinition(_textLimits, engine).render(
          object: testObject(
            typeKey: textObjectTypeKey,
            schemaVersion: textSchemaVersion,
            payload: payload.encode(),
            transform: _ok(
              AffineTransform2D.restoreFromStorage([1, 0, 0, 1, 24, 30]),
            ),
          ),
          viewport: _ok(
            ViewportSnapshot.create(
              extent: _ok(ViewExtent.create(width: 600, height: 800)),
              pageOrigin: _point(0, 0),
              zoom: 1,
              minimumZoom: .25,
              maximumZoom: 8,
              revision: _revision(0),
            ),
          ),
          layerOpacity: layerOpacity,
          plane: RenderPlane.committed,
          limits: _renderingLimits(),
        ),
      ).single;
      final bytes = await _paintedBytes(primitive);
      var maximum = 0;
      for (var index = 3; index < bytes.length; index += 4) {
        maximum = math.max(maximum, bytes[index]);
      }
      return maximum;
    }

    expect(
      await maximumPaintedAlpha(0x80000000, 1),
      inInclusiveRange(126, 128),
    );
    expect(
      await maximumPaintedAlpha(0xff000000, .5),
      inInclusiveRange(126, 128),
    );
    expect(await maximumPaintedAlpha(0x80000000, .5), inInclusiveRange(62, 64));
  });

  test('Text classification compares authoritative layout geometry', () {
    final engine = FlutterTextLayoutEngine(_textLimits);
    final definition = TextObjectTypeDefinition(_textLimits, engine);
    ObjectPayloadChangeSemantics classify(
      TextPayload before,
      TextPayload after,
    ) => _ok(
      definition.classifyPayloadChange(
        before.encode(),
        after.encode(),
        textSchemaVersion,
      ),
    );

    final short = _configuredTextPayload(text: 'short', width: 72);
    final wrapped = _configuredTextPayload(
      text: 'short text that wraps over several lines',
      width: 72,
    );
    expect(classify(short, wrapped).geometry, isTrue);
    expect(classify(wrapped, short).geometry, isTrue);

    final larger = _configuredTextPayload(
      text: 'short',
      fontSize: 40,
      width: 72,
    );
    final fontChange = classify(short, larger);
    expect(fontChange.geometry, isTrue);
    expect(fontChange.appearance, isTrue);

    final taller = _configuredTextPayload(
      text: 'short',
      lineHeight: 2,
      width: 72,
    );
    expect(classify(short, taller).geometry, isTrue);

    final visibleShort = _configuredTextPayload(
      text: 'one',
      mode: TextBoxMode.fixedWidthFixedHeight,
      width: 72,
      height: 20,
    );
    final visibleLong = _configuredTextPayload(
      text: 'one two three four five six seven',
      mode: TextBoxMode.fixedWidthFixedHeight,
      width: 72,
      height: 20,
    );
    expect(classify(visibleShort, visibleLong).geometry, isTrue);
    expect(classify(visibleLong, visibleShort).geometry, isTrue);

    final clipped = _configuredTextPayload(
      text: 'one two three four five six seven',
      mode: TextBoxMode.fixedWidthFixedHeight,
      overflow: TextOverflowPolicy.clip,
      width: 72,
      height: 20,
    );
    final clippedLarger = _configuredTextPayload(
      text: 'one two three four five six seven',
      fontSize: 40,
      mode: TextBoxMode.fixedWidthFixedHeight,
      overflow: TextOverflowPolicy.clip,
      width: 72,
      height: 20,
    );
    expect(classify(clipped, clippedLarger).geometry, isTrue);
    final clippedColor = _configuredTextPayload(
      text: 'one two three four five six seven',
      argb: 0xffff0000,
      mode: TextBoxMode.fixedWidthFixedHeight,
      overflow: TextOverflowPolicy.clip,
      width: 72,
      height: 20,
    );
    final colorOnly = classify(clipped, clippedColor);
    expect(colorOnly.geometry, isFalse);
    expect(colorOnly.appearance, isTrue);

    final everything = _configuredTextPayload(
      text: 'different wrapped content for every category',
      fontSize: 42,
      argb: 0xffff0000,
      width: 72,
      payloadUnknown: PreservedMap({'future': const PreservedBoolean(true)}),
    );
    final all = classify(short, everything);
    expect(all.geometry, isTrue);
    expect(all.appearance, isTrue);
    expect(all.text, isTrue);
    expect(all.metadata, isTrue);

    final unavailable = _CountingTextLayoutEngine(engine, fail: true);
    final failure = TextObjectTypeDefinition(_textLimits, unavailable)
        .classifyPayloadChange(
          short.encode(),
          wrapped.encode(),
          textSchemaVersion,
        );
    expect(
      failure,
      isA<Err<ObjectPayloadChangeSemantics, StructuredFailure>>(),
    );
    expect('$failure', isNot(contains('short')));

    final source = testObject(
      id: 966,
      typeKey: textObjectTypeKey,
      schemaVersion: textSchemaVersion,
      payload: short.encode(),
    );
    final categories = ObjectReplacementChangeCategories(
      geometry: all.geometry,
      appearance: all.appearance,
      text: all.text,
      metadata: all.metadata,
    );
    expect(
      TextObjectEditRequest.replace(
        documentId: DocumentId.fromUuid(testUuid(1)),
        source: source,
        payload: everything,
        limits: _textLimits,
        layoutEngine: engine,
        metadata: phase3Metadata(correlation: 967),
        preconditions: RevisionPreconditions(),
        changeCategories: categories,
      ),
      isA<Ok<AtomicObjectReplacementRequest, StructuredFailure>>(),
    );
    expect(
      TextObjectEditRequest.replace(
        documentId: DocumentId.fromUuid(testUuid(1)),
        source: source,
        payload: everything,
        limits: _textLimits,
        layoutEngine: engine,
        metadata: phase3Metadata(correlation: 968),
        preconditions: RevisionPreconditions(),
        changeCategories: const ObjectReplacementChangeCategories(
          appearance: true,
          text: true,
          metadata: true,
        ),
      ),
      isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
    );
    expect(
      TextObjectEditRequest.replace(
        documentId: DocumentId.fromUuid(testUuid(1)),
        source: source,
        payload: everything,
        limits: _textLimits,
        layoutEngine: unavailable,
        metadata: phase3Metadata(correlation: 969),
        preconditions: RevisionPreconditions(),
        changeCategories: categories,
      ),
      isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
    );

    final counting = _CountingTextLayoutEngine(engine);
    final rootDocument = testNotebook(
      sections: [
        testSection(
          pages: [
            testPage(
              layers: [
                testContentLayer(objects: [source]),
              ],
            ),
          ],
        ),
      ],
    );
    final registry = testRegistry([
      TextObjectTypeDefinition(_textLimits, counting),
    ]);
    final coordinator = _coordinatorFor(rootDocument, registry);
    final initial = coordinator.snapshot;
    final page = rootDocument.pages.single;
    final layer = page.layers.single;
    final replacement = testObject(
      id: 966,
      typeKey: textObjectTypeKey,
      schemaVersion: textSchemaVersion,
      payload: everything.encode(),
    );
    AtomicObjectCollectionEditRequest collection(
      ObjectReplacementChangeCategories claims,
      int correlation,
    ) => _ok(
      AtomicObjectCollectionEditRequest.create(
        documentId: rootDocument.id,
        pageId: page.id,
        metadata: phase3Metadata(
          family: 'alnote.commands.object.collection_edit',
          correlation: correlation,
        ),
        preconditions: RevisionPreconditions(
          pages: {page.id: initial.revisions.pages[page.id]!},
          layerMembership: {
            layer.id: initial.revisions.layerMembership[layer.id]!,
          },
          objects: {source.id: initial.revisions.objects[source.id]!},
        ),
        replacements: [replacement],
        replacementChangeCategories: claims,
        maximumOperations: 1,
      ),
    );
    expect(
      coordinator.execute(
        collection(
          const ObjectReplacementChangeCategories(
            appearance: true,
            text: true,
            metadata: true,
          ),
          975,
        ),
      ),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    expect(coordinator.snapshot.root, same(initial.root));
    expect(coordinator.snapshot.canUndo, isFalse);
    final commit = _ok(coordinator.execute(collection(categories, 976)));
    expect(commit.change.flags.geometry, isTrue);
    expect(commit.change.flags.appearance, isTrue);
    expect(commit.change.flags.text, isTrue);
    expect(commit.change.flags.metadata, isTrue);
    final callsAfterCommit = counting.calls;
    final undo = _ok(coordinator.undo());
    final redo = _ok(coordinator.redo());
    for (final evidence in [undo, redo]) {
      expect(evidence.change.flags.geometry, isTrue);
      expect(evidence.change.flags.appearance, isTrue);
      expect(evidence.change.flags.text, isTrue);
      expect(evidence.change.flags.metadata, isTrue);
    }
    expect(counting.calls, callsAfterCommit);
  });

  test('Text classification is total when authoritative bounds are equal', () {
    final base = _configuredTextPayload(
      text: 'a\nb',
      mode: TextBoxMode.fixedWidthFixedHeight,
      height: 120,
    );
    final snapshot = _ok(
      FlutterTextLayoutEngine(
        _textLimits,
      ).layout(TextLayoutRequest(payload: base)),
    );
    final fixed = _FixedTextLayoutEngine(snapshot);
    final definition = TextObjectTypeDefinition(_textLimits, fixed);
    PreservedDouble number(double value) => _ok(PreservedDouble.create(value));
    TextPayload changed(Map<String, PreservedData> overrides) => _ok(
      TextPayload.decode(
        PreservedMap({...base.encode().values, ...overrides}),
        limits: _textLimits,
      ),
    );

    final padding = base.encode().values['padding']! as PreservedMap;
    final explicitParagraphs = _textPayload(['a', 'b']);
    final oneParagraph = _textPayload(['ab']);
    final paragraph = oneParagraph.paragraphs.single;
    final splitRuns = _ok(
      TextPayload.create(
        paragraphs: [
          _ok(
            TextParagraph.create(
              runs: [
                _ok(
                  TextRun.create(
                    text: 'a',
                    style: paragraph.runs.single.style,
                    limits: _textLimits,
                  ),
                ),
                _ok(
                  TextRun.create(
                    text: 'b',
                    style: paragraph.runs.single.style,
                    limits: _textLimits,
                  ),
                ),
              ],
              style: paragraph.style,
              limits: _textLimits,
            ),
          ),
        ],
        defaultCharacterStyle: oneParagraph.defaultCharacterStyle,
        defaultParagraphStyle: oneParagraph.defaultParagraphStyle,
        boxMode: oneParagraph.boxMode,
        intrinsicWidth: oneParagraph.intrinsicWidth,
        intrinsicHeight: oneParagraph.intrinsicHeight,
        padding: oneParagraph.padding,
        verticalAlignment: oneParagraph.verticalAlignment,
        overflowPolicy: oneParagraph.overflowPolicy,
        limits: _textLimits,
        unknownFields: oneParagraph.unknownFields,
      ),
    );
    final cases = <TextPayload>[
      changed({'boxMode': const PreservedString('fixedWidthAutoHeight')}),
      changed({'intrinsicWidth': number(121)}),
      changed({'intrinsicHeight': number(121)}),
      changed({
        'padding': PreservedMap({...padding.values, 'left': number(7)}),
      }),
      changed({'verticalAlignment': const PreservedString('bottom')}),
      changed({'overflowPolicy': const PreservedString('clip')}),
      explicitParagraphs,
    ];
    for (final after in cases) {
      final semantics = _ok(
        definition.classifyPayloadChange(
          base.encode(),
          after.encode(),
          textSchemaVersion,
        ),
      );
      expect(semantics.geometry, isFalse);
      expect(semantics.metadata, isTrue);
      expect(
        semantics.geometry ||
            semantics.appearance ||
            semantics.text ||
            semantics.metadata,
        isTrue,
      );
    }
    final runBoundary = _ok(
      definition.classifyPayloadChange(
        oneParagraph.encode(),
        splitRuns.encode(),
        textSchemaVersion,
      ),
    );
    expect(runBoundary.geometry, isFalse);
    expect(runBoundary.text, isFalse);
    expect(runBoundary.metadata, isTrue);
    expect(oneParagraph.encode(), isNot(splitRuns.encode()));
    expect(fixed.calls, 2 * (cases.length + 1));

    final configurationAfter = cases.first;
    final source = testObject(
      id: 977,
      typeKey: textObjectTypeKey,
      schemaVersion: textSchemaVersion,
      payload: base.encode(),
    );
    const metadataOnly = ObjectReplacementChangeCategories(
      appearance: false,
      text: false,
      metadata: true,
    );
    expect(
      TextObjectEditRequest.replace(
        documentId: DocumentId.fromUuid(testUuid(1)),
        source: source,
        payload: configurationAfter,
        limits: _textLimits,
        layoutEngine: fixed,
        metadata: phase3Metadata(correlation: 978),
        preconditions: RevisionPreconditions(),
        changeCategories: metadataOnly,
      ),
      isA<Ok<AtomicObjectReplacementRequest, StructuredFailure>>(),
    );
    expect(
      TextObjectEditRequest.replace(
        documentId: DocumentId.fromUuid(testUuid(1)),
        source: source,
        payload: configurationAfter,
        limits: _textLimits,
        layoutEngine: fixed,
        metadata: phase3Metadata(correlation: 979),
        preconditions: RevisionPreconditions(),
        changeCategories: const ObjectReplacementChangeCategories(
          appearance: false,
          text: false,
          metadata: false,
        ),
      ),
      isA<Err<AtomicObjectReplacementRequest, StructuredFailure>>(),
    );

    final root = testNotebook(
      sections: [
        testSection(
          pages: [
            testPage(
              layers: [
                testContentLayer(objects: [source]),
              ],
            ),
          ],
        ),
      ],
    );
    final registry = testRegistry([
      TextObjectTypeDefinition(_textLimits, fixed),
    ]);
    final coordinator = _coordinatorFor(root, registry);
    final initial = coordinator.snapshot;
    final page = root.pages.single;
    final layer = page.layers.single;
    final replacement = testObject(
      id: 977,
      typeKey: textObjectTypeKey,
      schemaVersion: textSchemaVersion,
      payload: configurationAfter.encode(),
    );
    AtomicObjectCollectionEditRequest collection(
      ObjectReplacementChangeCategories claims,
      int correlation,
    ) => _ok(
      AtomicObjectCollectionEditRequest.create(
        documentId: root.id,
        pageId: page.id,
        metadata: phase3Metadata(
          family: 'alnote.commands.object.collection_edit',
          correlation: correlation,
        ),
        preconditions: RevisionPreconditions(
          pages: {page.id: initial.revisions.pages[page.id]!},
          layerMembership: {
            layer.id: initial.revisions.layerMembership[layer.id]!,
          },
          objects: {source.id: initial.revisions.objects[source.id]!},
        ),
        replacements: [replacement],
        replacementChangeCategories: claims,
        maximumOperations: 1,
      ),
    );
    expect(
      coordinator.execute(
        collection(
          const ObjectReplacementChangeCategories(
            appearance: false,
            text: false,
            metadata: false,
          ),
          980,
        ),
      ),
      isA<Err<CommandCommit, CommandFailure>>(),
    );
    expect(coordinator.snapshot.root, same(initial.root));
    final committed = _ok(coordinator.execute(collection(metadataOnly, 981)));
    expect(committed.change.flags.geometry, isFalse);
    expect(committed.change.flags.metadata, isTrue);
    final callsAfterCommit = fixed.calls;
    expect(_ok(coordinator.undo()).change.flags.metadata, isTrue);
    expect(_ok(coordinator.redo()).change.flags.metadata, isTrue);
    expect(fixed.calls, callsAfterCommit);
  });

  test('Text derived geometry rejects overflow and underflow redacted', () {
    TextPayload? payloadFor(double fontSize, double lineHeight) {
      final character = TextCharacterStyle.create(
        genericFontFamily: TextGenericFontFamily.sansSerif,
        fontSize: fontSize,
        weight: 400,
        italic: false,
        underline: false,
        strikethrough: false,
        argb: 0xff000000,
        limits: _textLimits,
      );
      final paragraphStyle = TextParagraphStyle.create(
        alignment: TextAlignment.left,
        direction: TextParagraphDirection.ltr,
        lineHeight: lineHeight,
        limits: _textLimits,
      );
      if (character is! Ok<TextCharacterStyle, StructuredFailure> ||
          paragraphStyle is! Ok<TextParagraphStyle, StructuredFailure>) {
        return null;
      }
      final run = _ok(
        TextRun.create(text: 'x', style: character.value, limits: _textLimits),
      );
      final paragraph = _ok(
        TextParagraph.create(
          runs: [run],
          style: paragraphStyle.value,
          limits: _textLimits,
        ),
      );
      return TextPayload.create(
        paragraphs: [paragraph],
        defaultCharacterStyle: character.value,
        defaultParagraphStyle: paragraphStyle.value,
        boxMode: TextBoxMode.fixedWidthAutoHeight,
        intrinsicWidth: 100,
        intrinsicHeight: null,
        padding: _zeroTextPadding(),
        verticalAlignment: TextVerticalAlignment.top,
        overflowPolicy: TextOverflowPolicy.visible,
        limits: _textLimits,
      ).fold<TextPayload?>(onOk: (value) => value, onErr: (_) => null);
    }

    expect(payloadFor(2, double.maxFinite), isNull);
    expect(payloadFor(double.minPositive, double.minPositive), isNull);
    final exact = payloadFor(2, double.maxFinite / 4);
    expect(exact, isNotNull);
    expect(exact!.bounds.bottom.isFinite, isTrue);
    final base = _textPayload(['x']);
    final hostileStyle = _ok(
      TextParagraphStyle.create(
        alignment: TextAlignment.left,
        direction: TextParagraphDirection.ltr,
        lineHeight: double.maxFinite,
        limits: _textLimits,
      ),
    );
    final hostileParagraph = _ok(
      TextParagraph.create(
        runs: base.paragraphs.single.runs,
        style: hostileStyle,
        limits: _textLimits,
      ),
    );
    final failure = TextPayload.create(
      paragraphs: [hostileParagraph],
      defaultCharacterStyle: base.defaultCharacterStyle,
      defaultParagraphStyle: hostileStyle,
      boxMode: TextBoxMode.fixedWidthAutoHeight,
      intrinsicWidth: 100,
      intrinsicHeight: null,
      padding: _zeroTextPadding(),
      verticalAlignment: TextVerticalAlignment.top,
      overflowPolicy: TextOverflowPolicy.visible,
      limits: _textLimits,
    );
    expect(failure, isA<Err<TextPayload, StructuredFailure>>());
    expect('$failure', isNot(contains(double.maxFinite.toString())));
  });

  test('Text layout authority aligns rich wrapping and overflow exactly', () {
    TextLayoutSnapshot layout(
      TextVerticalAlignment alignment,
      TextOverflowPolicy overflow, {
      TextBoxMode mode = TextBoxMode.fixedWidthFixedHeight,
      double height = 80,
    }) => _ok(
      FlutterTextLayoutEngine(_textLimits).layout(
        TextLayoutRequest(
          payload: _richLayoutPayload(
            alignment: alignment,
            overflow: overflow,
            mode: mode,
            height: height,
          ),
          range: _ok(TextRange.create(_position(0, 0), _position(0, 12))),
        ),
      ),
    );

    final top = layout(TextVerticalAlignment.top, TextOverflowPolicy.visible);
    final center = layout(
      TextVerticalAlignment.center,
      TextOverflowPolicy.visible,
      height: 240,
    );
    final bottom = layout(
      TextVerticalAlignment.bottom,
      TextOverflowPolicy.visible,
      height: 240,
    );
    expect(top.paragraphs.first.origin.y, 5);
    expect(center.paragraphs.first.origin.y, greaterThan(5));
    expect(
      bottom.paragraphs.first.origin.y,
      greaterThan(center.paragraphs.first.origin.y),
    );
    expect(
      bottom.paragraphs.first.origin.y - center.paragraphs.first.origin.y,
      closeTo(
        center.paragraphs.first.origin.y - top.paragraphs.first.origin.y,
        0.001,
      ),
    );
    expect(top.lines, hasLength(greaterThan(1)));
    expect(top.lines.expand((line) => line.fragments), isNotEmpty);
    expect(top.caretStops, isNotEmpty);
    expect(top.rangeGeometry, isNotEmpty);

    final clipped = layout(
      TextVerticalAlignment.top,
      TextOverflowPolicy.clip,
      height: 24,
    );
    final visible = layout(
      TextVerticalAlignment.top,
      TextOverflowPolicy.visible,
      height: 24,
    );
    expect(clipped.overflowed, isTrue);
    expect(clipped.logicalBounds.bottom, 24);
    expect(clipped.visualBounds.bottom, lessThanOrEqualTo(24));
    expect(
      [
        ...clipped.lines.map((value) => value.bounds),
        ...clipped.rangeGeometry,
      ].every((bounds) => bounds.bottom <= 24),
      isTrue,
    );
    expect(visible.visualBounds.bottom, greaterThan(24));
    expect(visible.lines.length, greaterThan(clipped.lines.length));

    final auto = layout(
      TextVerticalAlignment.top,
      TextOverflowPolicy.visible,
      mode: TextBoxMode.autoSize,
    );
    final autoHeight = layout(
      TextVerticalAlignment.top,
      TextOverflowPolicy.visible,
      mode: TextBoxMode.fixedWidthAutoHeight,
    );
    expect(auto.logicalBounds.width, lessThanOrEqualTo(64));
    expect(auto.logicalBounds.height, autoHeight.logicalBounds.height);
    expect(autoHeight.logicalBounds.width, 64);
    final oneLine = _adjustTextLimits(maximumLayoutLines: 1);
    expect(
      FlutterTextLayoutEngine(oneLine).layout(
        TextLayoutRequest(
          payload: _richLayoutPayload(
            alignment: TextVerticalAlignment.top,
            overflow: TextOverflowPolicy.visible,
            mode: TextBoxMode.fixedWidthAutoHeight,
          ),
        ),
      ),
      isA<Err<TextLayoutSnapshot, StructuredFailure>>(),
    );
  });

  test('Text render hit and Selection share full-affine visual geometry', () {
    final engine = FlutterTextLayoutEngine(_textLimits);
    final payload = _richLayoutPayload(
      alignment: TextVerticalAlignment.top,
      overflow: TextOverflowPolicy.visible,
      height: 24,
    );
    final transform = _ok(
      AffineTransform2D.restoreFromStorage([1.5, .35, .6, 1.2, 20, 30]),
    );
    final object = testObject(
      id: 965,
      typeKey: textObjectTypeKey,
      schemaVersion: textSchemaVersion,
      payload: payload.encode(),
      transform: transform,
    );
    final local = _ok(
      engine.layout(TextLayoutRequest(payload: payload)),
    ).visualBounds;
    final pageBounds = _transformedBounds(local, transform);
    final viewport = _ok(
      ViewportSnapshot.create(
        extent: _ok(ViewExtent.create(width: 1200, height: 1600)),
        pageOrigin: _point(0, 0),
        zoom: 2,
        minimumZoom: .25,
        maximumZoom: 8,
        revision: _revision(0),
      ),
    );
    final primitive =
        _ok(
              TextRenderingDefinition(_textLimits, engine).render(
                object: object,
                viewport: viewport,
                layerOpacity: .75,
                plane: RenderPlane.committed,
                limits: _renderingLimits(),
              ),
            ).single
            as TextBoxPrimitive;
    expect(primitive.layout.visualBounds, local);
    expect(
      primitive.bounds,
      _rect(
        pageBounds.left * 2,
        pageBounds.top * 2,
        pageBounds.right * 2,
        pageBounds.bottom * 2,
      ),
    );
    final localCenter = _point(
      (local.left + local.right) / 2,
      (local.top + local.bottom) / 2,
    );
    final pageCenter = _ok(transform.applyToPoint(localCenter));
    expect(
      _ok(
        TextHitTestingDefinition(_textLimits, engine).wholePoint(
          object: object,
          pagePosition: pageCenter,
          pageTolerance: 0,
        ),
      ),
      isTrue,
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
    final registry = testRegistry([
      TextObjectTypeDefinition(_textLimits, engine),
    ]);
    final coordinator = _coordinatorFor(root, registry);
    final selection = SelectionController(
      objectRegistry: registry,
      coalescingBoundarySink: coordinator,
      maximumTargets: 1,
    );
    _ok(
      selection.replace(
        root: root,
        targets: [
          SelectionTarget.wholeObject(
            pageId: root.pages.single.id,
            objectId: object.id,
          ),
        ],
      ),
    );
    expect(selection.state.aggregateBounds, pageBounds);
  });

  test('minimal dialog representability never flattens rich Text', () {
    final simple = _textPayload(['simple']);
    final rich = _richLayoutPayload(
      alignment: TextVerticalAlignment.top,
      overflow: TextOverflowPolicy.visible,
      mode: TextBoxMode.fixedWidthAutoHeight,
    );
    expect(simple.isSimpleDialogEditable, isTrue);
    expect(rich.isSimpleDialogEditable, isFalse);
    final embedded = _textPayload(['a\nb']);
    final explicit = _textPayload(['a', 'b']);
    expect(embedded.logicalText, explicit.logicalText);
    expect(embedded.paragraphs, hasLength(1));
    expect(explicit.paragraphs, hasLength(2));
    expect(embedded.isSimpleDialogEditable, isFalse);
    expect(explicit.isSimpleDialogEditable, isTrue);
    expect(embedded.encode(), isNot(explicit.encode()));
    expect(
      _ok(TextPayload.decode(embedded.encode(), limits: _textLimits)).encode(),
      embedded.encode(),
    );
    expect(
      _ok(TextPayload.decode(explicit.encode(), limits: _textLimits)).encode(),
      explicit.encode(),
    );
    final before = rich.encode();
    expect(
      _ok(TextPayload.decode(before, limits: _textLimits)).encode(),
      before,
    );

    final encoded = simple.encode();
    final paragraph =
        ((encoded.values['paragraphs']! as PreservedList).values.single
            as PreservedMap);
    final run =
        ((paragraph.values['runs']! as PreservedList).values.single
            as PreservedMap);
    for (final changed in [
      PreservedMap({...run.values, 'runFuture': const PreservedBoolean(true)}),
      PreservedMap({
        ...paragraph.values,
        'paragraphFuture': const PreservedBoolean(true),
      }),
    ]) {
      final candidate = changed.values.containsKey('runs')
          ? PreservedMap({
              ...encoded.values,
              'paragraphs': PreservedList([changed]),
            })
          : PreservedMap({
              ...encoded.values,
              'paragraphs': PreservedList([
                PreservedMap({
                  ...paragraph.values,
                  'runs': PreservedList([changed]),
                }),
              ]),
            });
      expect(
        _ok(
          TextPayload.decode(candidate, limits: _textLimits),
        ).isSimpleDialogEditable,
        isFalse,
      );
    }
  });

  test(
    'explicit simple paragraphs preserve structure through history and reopen',
    () {
      final engine = FlutterTextLayoutEngine(_textLimits);
      final beforePayload = _textPayload(['a', 'b']);
      final afterPayload = _textPayload(['aa', 'bb']);
      final source = testObject(
        id: 970,
        typeKey: textObjectTypeKey,
        schemaVersion: textSchemaVersion,
        payload: beforePayload.encode(),
      );
      final root = testNotebook(
        sections: [
          testSection(
            pages: [
              testPage(
                layers: [
                  testContentLayer(objects: [source]),
                ],
              ),
            ],
          ),
        ],
      );
      final registry = testRegistry([
        TextObjectTypeDefinition(_textLimits, engine),
      ]);
      final coordinator = _coordinatorFor(root, registry);
      final snapshot = coordinator.snapshot;
      final layer = root.pages.single.layers.single;
      final semantics = _ok(
        TextObjectTypeDefinition(_textLimits, engine).classifyPayloadChange(
          beforePayload.encode(),
          afterPayload.encode(),
          textSchemaVersion,
        ),
      );
      final request = _ok(
        TextObjectEditRequest.replace(
          documentId: root.id,
          source: source,
          payload: afterPayload,
          limits: _textLimits,
          layoutEngine: engine,
          metadata: phase3Metadata(correlation: 971),
          preconditions: RevisionPreconditions(
            objects: {source.id: snapshot.revisions.objects[source.id]!},
            layerMembership: {
              layer.id: snapshot.revisions.layerMembership[layer.id]!,
            },
          ),
          changeCategories: ObjectReplacementChangeCategories(
            geometry: semantics.geometry,
            appearance: semantics.appearance,
            text: semantics.text,
            metadata: semantics.metadata,
          ),
        ),
      );
      _ok(coordinator.execute(request));
      final changed = coordinator.snapshot.root;
      expect(
        _ok(
          TextPayload.decode(
            changed.pages.single.layers.single.objects.single.payload,
            limits: _textLimits,
          ),
        ).paragraphs,
        hasLength(2),
      );
      _ok(coordinator.undo());
      expect(coordinator.snapshot.root, root);
      _ok(coordinator.redo());
      expect(coordinator.snapshot.root, changed);

      final bytes = _ok(
        AlnotePackageCodec(objectRegistry: registry).encode(
          _ok(
            AlnotePackageSnapshot.create(
              document: changed,
              resources: const [],
            ),
          ),
          limits: phase4Limits(),
        ),
      );
      final opened = AlnotePackageReader(objectRegistry: registry).openBytes(
        bytes,
        limits: phase4Limits(),
        cancellationToken: CancellationController().token,
      );
      expect(opened, isA<Completed<OpenedAlnotePackage, StructuredFailure>>());
      final reopened =
          (opened as Completed<OpenedAlnotePackage, StructuredFailure>).value
              .materializeDocument(
                cancellationToken: CancellationController().token,
              );
      expect(reopened, isA<Completed<DocumentRoot, StructuredFailure>>());
      final reopenedPayload = _ok(
        TextPayload.decode(
          (reopened as Completed<DocumentRoot, StructuredFailure>)
              .value
              .pages
              .single
              .layers
              .single
              .objects
              .single
              .payload,
          limits: _textLimits,
        ),
      );
      expect(reopenedPayload.encode(), afterPayload.encode());
      expect(reopenedPayload.paragraphs, hasLength(2));
      expect(
        reopenedPayload.paragraphs.every((value) => value.runs.length == 1),
        isTrue,
      );
    },
  );

  test('unknown keys and strings share one bounded surrogate-safe budget', () {
    final exact = PreservedMap({
      'a': const PreservedString('bc'),
      'd': const PreservedString('ef'),
    });
    final cumulativeOverflow = PreservedMap({
      'a': PreservedList([
        const PreservedString('bc'),
        const PreservedString('defg'),
      ]),
    });
    final oversizedKey = PreservedMap({'1234567': const PreservedNull()});
    final oversizedValue = PreservedMap({'a': const PreservedString('123456')});
    final malformedKey = PreservedMap({'bad\uD800': const PreservedNull()});
    final malformedValue = PreservedMap({
      'a': const PreservedString('bad\uD800'),
    });
    final rejectedTail = PreservedMap({
      'a': const PreservedString('bc'),
      'd': const PreservedString('ef'),
      'z\uD800': const PreservedString('tail\uD800'),
    });
    final nestedExact = PreservedMap({
      'a': PreservedList([const PreservedNull(), const PreservedNull()]),
    });
    final nestedPlusOne = PreservedMap({
      'a': PreservedList([
        const PreservedNull(),
        const PreservedNull(),
        const PreservedString('rejected-tail'),
      ]),
    });

    final shapeLimits = _shapeLimitsWithUnknownCodeUnits(
      6,
      maximumFields: 2,
      maximumNodes: 3,
      maximumDepth: 3,
    );
    final geometry = _ok(
      ShapeLineGeometry.create(
        start: _point(0, 0),
        end: _point(10, 0),
        limits: shapeLimits,
      ),
    );
    Result<ShapePayload, StructuredFailure> shape(PreservedMap unknown) =>
        ShapePayload.create(
          geometry: geometry,
          style: _shapeStyle(),
          limits: shapeLimits,
          unknownFields: unknown,
        );

    final imageLimits = _imageLimitsWithUnknownCodeUnits(
      6,
      maximumFields: 2,
      maximumNodes: 3,
      maximumDepth: 3,
    );
    Result<ImagePayload, StructuredFailure> image(PreservedMap unknown) =>
        ImagePayload.create(
          resourceIdentity: ResourceIdentity.fromUuid(testUuid(980)),
          encodedPixelWidth: 2,
          encodedPixelHeight: 3,
          intrinsicWidth: 2,
          intrinsicHeight: 3,
          orientation: ImageOrientation.normal,
          crop: ImageCropRect.full,
          renderingIntent: ImageRenderingIntent.auto,
          limits: imageLimits,
          unknownFields: unknown,
        );

    final textLimits = _textLimitsWithUnknownCodeUnits(
      6,
      maximumFields: 2,
      maximumNodes: 3,
      maximumDepth: 3,
    );
    final cleanCharacter = _ok(
      TextCharacterStyle.create(
        genericFontFamily: TextGenericFontFamily.sansSerif,
        fontSize: 12,
        weight: 400,
        italic: false,
        underline: false,
        strikethrough: false,
        argb: 0xff000000,
        limits: textLimits,
      ),
    );
    final cleanParagraphStyle = _ok(
      TextParagraphStyle.create(
        alignment: TextAlignment.start,
        direction: TextParagraphDirection.ltr,
        lineHeight: 1,
        limits: textLimits,
      ),
    );
    final cleanParagraph = _ok(
      TextParagraph.create(
        runs: [
          _ok(
            TextRun.create(
              text: 'x',
              style: cleanCharacter,
              limits: textLimits,
            ),
          ),
        ],
        style: cleanParagraphStyle,
        limits: textLimits,
      ),
    );
    final cleanPadding = _ok(
      TextPadding.create(
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        limits: textLimits,
      ),
    );
    Result<TextPayload, StructuredFailure> text(PreservedMap unknown) =>
        TextPayload.create(
          paragraphs: [cleanParagraph],
          defaultCharacterStyle: cleanCharacter,
          defaultParagraphStyle: cleanParagraphStyle,
          boxMode: TextBoxMode.fixedWidthFixedHeight,
          intrinsicWidth: 100,
          intrinsicHeight: 30,
          padding: cleanPadding,
          verticalAlignment: TextVerticalAlignment.top,
          overflowPolicy: TextOverflowPolicy.clip,
          limits: textLimits,
          unknownFields: unknown,
        );

    for (final factory
        in <Result<Object, StructuredFailure> Function(PreservedMap)>[
          shape,
          image,
          text,
        ]) {
      expect(factory(exact), isA<Ok<Object, StructuredFailure>>());
      expect(factory(nestedExact), isA<Ok<Object, StructuredFailure>>());
      for (final rejected in [
        cumulativeOverflow,
        oversizedKey,
        oversizedValue,
        malformedKey,
        malformedValue,
        rejectedTail,
        nestedPlusOne,
      ]) {
        final result = factory(rejected);
        expect(result, isA<Err<Object, StructuredFailure>>());
        expect('$result', isNot(contains('123456')));
        expect('$result', isNot(contains('bad')));
      }
    }
  });

  test('all built-ins register and exact package storage reopens', () {
    final shape = _shapeObject(701);
    final text = testObject(
      id: 702,
      typeKey: textObjectTypeKey,
      payload: _textPayload(['saved text']).encode(),
    );
    final imagePayload = _ok(
      ImagePayload.create(
        resourceIdentity: ResourceIdentity.fromUuid(testUuid(703)),
        encodedPixelWidth: 2,
        encodedPixelHeight: 3,
        intrinsicWidth: 1.5,
        intrinsicHeight: 2.25,
        orientation: ImageOrientation.normal,
        crop: ImageCropRect.full,
        renderingIntent: ImageRenderingIntent.auto,
        alternativeText: 'saved image',
        limits: _imageLimits,
      ),
    );
    final image = testObject(
      id: 704,
      typeKey: imageObjectTypeKey,
      payload: imagePayload.encode(),
    );
    final resource = _ok(
      DocumentResource.capture(
        identity: imagePayload.resourceIdentity,
        mediaType: _mediaType('image/png'),
        role: _resourceRole(),
        schemaVersion: testSchemaVersion,
        bytes: _pngFixture,
      ),
    );
    final catalog = _ok(
      ResourceCatalog.create([ResourceCatalogEntry(resource.identity)]),
    );
    final root = testNotebook(
      resources: catalog,
      sections: [
        testSection(
          pages: [
            testPage(
              layers: [
                testContentLayer(objects: [shape, image, text]),
              ],
            ),
          ],
        ),
      ],
    );
    final registry = _registry();
    for (final object in [shape, image, text]) {
      expect(registry.resolve(object), isA<SupportedObjectResolution>());
    }
    final package = _ok(
      AlnotePackageSnapshot.create(
        document: root,
        resources: [DocumentResourceSnapshot(resource)],
      ),
    );
    final bytes = _ok(
      AlnotePackageCodec(
        objectRegistry: registry,
      ).encode(package, limits: phase4Limits()),
    );
    final opened = AlnotePackageReader(objectRegistry: registry).openBytes(
      bytes,
      limits: phase4Limits(),
      cancellationToken: CancellationController().token,
    );
    expect(opened, isA<Completed<OpenedAlnotePackage, StructuredFailure>>());
    final materialized =
        (opened as Completed<OpenedAlnotePackage, StructuredFailure>).value
            .materializeDocument(
              cancellationToken: CancellationController().token,
            );
    expect(materialized, isA<Completed<DocumentRoot, StructuredFailure>>());
    expect(
      (materialized as Completed<DocumentRoot, StructuredFailure>).value,
      root,
    );
  });
}

ShapeStyle _shapeStyle({
  Iterable<double> dashes = const [],
  ShapeFillRule fillRule = ShapeFillRule.nonZero,
  ShapeArrowhead start = ShapeArrowhead.none,
  ShapeArrowhead end = ShapeArrowhead.none,
  ShapeStrokeCap cap = ShapeStrokeCap.round,
  ShapeStrokeJoin join = ShapeStrokeJoin.round,
  double miterLimit = 4,
  double strokeWidth = 3,
  int strokeArgb = 0xff17324d,
  int fillArgb = 0x8017a24d,
  bool strokeEnabled = true,
  bool fillEnabled = true,
  double opacity = .9,
}) => _ok(
  ShapeStyle.create(
    strokeEnabled: strokeEnabled,
    strokeColor: _color(strokeArgb),
    strokeWidth: strokeWidth,
    cap: cap,
    join: join,
    miterLimit: miterLimit,
    dashArray: dashes,
    dashOffset: 1,
    fillEnabled: fillEnabled,
    fillColor: _color(fillArgb),
    fillRule: fillRule,
    opacity: opacity,
    startArrowhead: start,
    endArrowhead: end,
    limits: _shapeLimits,
  ),
);

DocumentMutationCoordinator _coordinatorFor(
  DocumentRoot root,
  ObjectRegistry registry,
) => _ok(
  DocumentMutationCoordinator.create(
    initialRoot: root,
    validator: DocumentValidator(registry),
    uuidGenerator: UuidSequenceGenerator.fromValues([
      testUuid(890),
      testUuid(891),
      testUuid(892),
      testUuid(893),
    ]),
    historyLimits: _ok(
      HistoryLimits.create(
        maximumRetainedCommandCount: 8,
        maximumEstimatedRetainedBytes: 100000,
      ),
    ),
    retainedCostEstimator: FixedHistoryCostEstimator(100),
    maximumListeners: 4,
  ),
);

Rect2 _transformedBounds(Rect2 local, AffineTransform2D transform) {
  final points = [
    local.topLeft,
    _point(local.right, local.top),
    local.bottomRight,
    _point(local.left, local.bottom),
  ].map((point) => _ok(transform.applyToPoint(point))).toList();
  final xs = points.map((point) => point.x).toList()..sort();
  final ys = points.map((point) => point.y).toList()..sort();
  return _rect(xs.first, ys.first, xs.last, ys.last);
}

ShapeColor _color(int argb) => _ok(
  ShapeColor.create(
    red: argb >> 16 & 0xff,
    green: argb >> 8 & 0xff,
    blue: argb & 0xff,
    alpha: argb >> 24 & 0xff,
  ),
);

ObjectEnvelope _shapeObject(int id) {
  final payload = _ok(
    ShapePayload.create(
      geometry: _ok(
        ShapeRectangleGeometry.create(
          bounds: _rect(10, 20, 100, 80),
          cornerRadius: 8,
          limits: _shapeLimits,
        ),
      ),
      style: _shapeStyle(),
      limits: _shapeLimits,
    ),
  );
  return testObject(
    id: id,
    typeKey: shapeObjectTypeKey,
    payload: payload.encode(),
  );
}

TextPadding _zeroTextPadding() => _ok(
  TextPadding.create(left: 0, top: 0, right: 0, bottom: 0, limits: _textLimits),
);

TextLimits _adjustTextLimits({
  int? maximumLayoutLines,
  int? maximumPendingEdits,
}) => _ok(
  TextLimits.create(
    maximumParagraphs: _textLimits.maximumParagraphs,
    maximumRunsPerParagraph: _textLimits.maximumRunsPerParagraph,
    maximumScalarsPerRun: _textLimits.maximumScalarsPerRun,
    maximumTotalScalars: _textLimits.maximumTotalScalars,
    maximumFontFamilyScalars: _textLimits.maximumFontFamilyScalars,
    maximumLanguageHintScalars: _textLimits.maximumLanguageHintScalars,
    maximumUnknownFields: _textLimits.maximumUnknownFields,
    maximumUnknownNodes: _textLimits.maximumUnknownNodes,
    maximumNestingDepth: _textLimits.maximumNestingDepth,
    maximumUnknownStringCodeUnits: _textLimits.maximumUnknownStringCodeUnits,
    maximumFontSize: _textLimits.maximumFontSize,
    maximumBoxDimension: _textLimits.maximumBoxDimension,
    maximumPadding: _textLimits.maximumPadding,
    maximumLayoutLines: maximumLayoutLines ?? _textLimits.maximumLayoutLines,
    maximumLayoutFragments: _textLimits.maximumLayoutFragments,
    maximumCaretStops: _textLimits.maximumCaretStops,
    maximumRangeRectangles: _textLimits.maximumRangeRectangles,
    maximumPendingEdits: maximumPendingEdits ?? _textLimits.maximumPendingEdits,
  ),
);

TextPayload _richLayoutPayload({
  required TextVerticalAlignment alignment,
  required TextOverflowPolicy overflow,
  TextBoxMode mode = TextBoxMode.fixedWidthFixedHeight,
  double height = 80,
}) {
  TextCharacterStyle character(double size, int color) => _ok(
    TextCharacterStyle.create(
      genericFontFamily: TextGenericFontFamily.sansSerif,
      fontSize: size,
      weight: 400,
      italic: false,
      underline: false,
      strikethrough: false,
      argb: color,
      limits: _textLimits,
    ),
  );

  final small = character(10, 0xff000000);
  final large = character(28, 0xffff0000);
  final paragraphStyle = _ok(
    TextParagraphStyle.create(
      alignment: TextAlignment.left,
      direction: TextParagraphDirection.ltr,
      lineHeight: 1.4,
      limits: _textLimits,
    ),
  );
  final emptyStyle = _ok(
    TextParagraphStyle.create(
      alignment: TextAlignment.right,
      direction: TextParagraphDirection.ltr,
      lineHeight: 1.1,
      limits: _textLimits,
    ),
  );
  final paragraph = _ok(
    TextParagraph.create(
      runs: [
        _ok(
          TextRun.create(
            text: 'small wrap ',
            style: small,
            limits: _textLimits,
          ),
        ),
        _ok(TextRun.create(text: 'BIG', style: large, limits: _textLimits)),
      ],
      style: paragraphStyle,
      limits: _textLimits,
    ),
  );
  final empty = _ok(
    TextParagraph.create(
      runs: const [],
      style: emptyStyle,
      limits: _textLimits,
    ),
  );
  return _ok(
    TextPayload.create(
      paragraphs: [paragraph, empty],
      defaultCharacterStyle: small,
      defaultParagraphStyle: paragraphStyle,
      boxMode: mode,
      intrinsicWidth: 64,
      intrinsicHeight: mode == TextBoxMode.fixedWidthFixedHeight
          ? height
          : null,
      padding: _ok(
        TextPadding.create(
          left: 4,
          top: 5,
          right: 4,
          bottom: 6,
          limits: _textLimits,
        ),
      ),
      verticalAlignment: alignment,
      overflowPolicy: overflow,
      limits: _textLimits,
    ),
  );
}

TextPayload _configuredTextPayload({
  String text = 'MMMM MMMM MMMM',
  double fontSize = 24,
  double lineHeight = 1.2,
  int argb = 0xff000000,
  bool italic = true,
  bool underline = true,
  bool strikethrough = true,
  TextGenericFontFamily genericFamily = TextGenericFontFamily.sansSerif,
  String? preferredFamily,
  String? languageHint,
  TextBoxMode mode = TextBoxMode.fixedWidthAutoHeight,
  TextOverflowPolicy overflow = TextOverflowPolicy.visible,
  TextVerticalAlignment alignment = TextVerticalAlignment.top,
  double width = 120,
  double height = 80,
  PreservedMap? payloadUnknown,
}) {
  final character = _ok(
    TextCharacterStyle.create(
      preferredFontFamily: preferredFamily,
      genericFontFamily: genericFamily,
      fontSize: fontSize,
      weight: 500,
      italic: italic,
      underline: underline,
      strikethrough: strikethrough,
      argb: argb,
      limits: _textLimits,
    ),
  );
  final paragraphStyle = _ok(
    TextParagraphStyle.create(
      alignment: TextAlignment.left,
      direction: TextParagraphDirection.ltr,
      lineHeight: lineHeight,
      languageHint: languageHint,
      limits: _textLimits,
    ),
  );
  final paragraph = _ok(
    TextParagraph.create(
      runs: [
        _ok(TextRun.create(text: text, style: character, limits: _textLimits)),
      ],
      style: paragraphStyle,
      limits: _textLimits,
    ),
  );
  return _ok(
    TextPayload.create(
      paragraphs: [paragraph],
      defaultCharacterStyle: character,
      defaultParagraphStyle: paragraphStyle,
      boxMode: mode,
      intrinsicWidth: width,
      intrinsicHeight: mode == TextBoxMode.fixedWidthFixedHeight
          ? height
          : null,
      padding: _zeroTextPadding(),
      verticalAlignment: alignment,
      overflowPolicy: overflow,
      limits: _textLimits,
      unknownFields: payloadUnknown,
    ),
  );
}

TextPayload _textPayload(List<String> paragraphs) {
  final character = _ok(
    TextCharacterStyle.create(
      preferredFontFamily: 'Requested Family',
      genericFontFamily: TextGenericFontFamily.sansSerif,
      fontSize: 18,
      weight: 500,
      italic: true,
      underline: true,
      strikethrough: false,
      argb: 0xff17324d,
      limits: _textLimits,
      unknownFields: PreservedMap({'charFuture': const PreservedBoolean(true)}),
    ),
  );
  final paragraphStyle = _ok(
    TextParagraphStyle.create(
      alignment: TextAlignment.start,
      direction: TextParagraphDirection.automatic,
      lineHeight: 1.25,
      languageHint: 'en-US',
      limits: _textLimits,
    ),
  );
  final values = <TextParagraph>[];
  for (final source in paragraphs) {
    final run = _ok(
      TextRun.create(text: source, style: character, limits: _textLimits),
    );
    values.add(
      _ok(
        TextParagraph.create(
          runs: [run],
          style: paragraphStyle,
          limits: _textLimits,
        ),
      ),
    );
  }
  return _ok(
    TextPayload.create(
      paragraphs: values,
      defaultCharacterStyle: character,
      defaultParagraphStyle: paragraphStyle,
      boxMode: TextBoxMode.fixedWidthFixedHeight,
      intrinsicWidth: 240,
      intrinsicHeight: 120,
      padding: _ok(
        TextPadding.create(
          left: 6,
          top: 7,
          right: 8,
          bottom: 9,
          limits: _textLimits,
        ),
      ),
      verticalAlignment: TextVerticalAlignment.center,
      overflowPolicy: TextOverflowPolicy.clip,
      limits: _textLimits,
      unknownFields: PreservedMap({
        'payloadFuture': const PreservedString('opaque'),
      }),
    ),
  );
}

ShapeLimits _shapeLimitsWithUnknownCodeUnits(
  int maximum, {
  int maximumFields = 16,
  int maximumNodes = 1024,
  int maximumDepth = 8,
}) => _ok(
  ShapeLimits.create(
    maximumVertices: 64,
    maximumDashValues: 16,
    maximumUnknownFields: maximumFields,
    maximumUnknownNodes: maximumNodes,
    maximumNestingDepth: maximumDepth,
    maximumUnknownStringCodeUnits: maximum,
    maximumCoordinateMagnitude: 10000,
    maximumStrokeWidth: 100,
    maximumMiterLimit: 20,
    maximumCornerRadius: 1000,
    maximumDerivedSegments: 128,
  ),
);

ImageLimits _imageLimitsWithUnknownCodeUnits(
  int maximum, {
  int maximumFields = 16,
  int maximumNodes = 1024,
  int maximumDepth = 8,
}) => _ok(
  ImageLimits.create(
    maximumEncodedBytes: 4096,
    maximumHeaderBytes: 1024,
    maximumMarkers: 32,
    maximumPixelDimension: 4096,
    maximumPixelCount: 4000000,
    maximumAlternativeTextScalars: 128,
    maximumUnknownFields: maximumFields,
    maximumUnknownNodes: maximumNodes,
    maximumNestingDepth: maximumDepth,
    maximumUnknownStringCodeUnits: maximum,
    maximumDocumentDimension: 10000,
  ),
);

ImageLimits _imageLimitsWithMaximumBytes(int maximumEncodedBytes) => _ok(
  ImageLimits.create(
    maximumEncodedBytes: maximumEncodedBytes,
    maximumHeaderBytes: 33,
    maximumMarkers: 32,
    maximumPixelDimension: 4096,
    maximumPixelCount: 4000000,
    maximumAlternativeTextScalars: 128,
    maximumUnknownFields: 16,
    maximumUnknownNodes: 1024,
    maximumNestingDepth: 8,
    maximumUnknownStringCodeUnits: 4096,
    maximumDocumentDimension: 10000,
  ),
);

TextLimits _textLimitsWithUnknownCodeUnits(
  int maximum, {
  int maximumFields = 16,
  int maximumNodes = 1024,
  int maximumDepth = 8,
}) => _ok(
  TextLimits.create(
    maximumParagraphs: 32,
    maximumRunsPerParagraph: 32,
    maximumScalarsPerRun: 1024,
    maximumTotalScalars: 4096,
    maximumFontFamilyScalars: 64,
    maximumLanguageHintScalars: 32,
    maximumUnknownFields: maximumFields,
    maximumUnknownNodes: maximumNodes,
    maximumNestingDepth: maximumDepth,
    maximumUnknownStringCodeUnits: maximum,
    maximumFontSize: 200,
    maximumBoxDimension: 10000,
    maximumPadding: 100,
    maximumLayoutLines: 256,
    maximumLayoutFragments: 1024,
    maximumCaretStops: 4096,
    maximumRangeRectangles: 1024,
    maximumPendingEdits: 16,
  ),
);

HandwritingLimits _handwritingLimitsForShapeTests() => _ok(
  HandwritingLimits.create(
    maximumStrokes: 1,
    maximumSamplesPerStroke: 2,
    maximumUnknownFields: 1,
    maximumNestingDepth: 1,
    maximumUnknownNodes: 1,
    maximumCoordinateMagnitude: 10000,
    maximumStrokeWidth: 100,
    maximumAbsoluteTilt: math.pi / 2,
    maximumAbsoluteOrientation: math.pi * 2,
  ),
);

StrokeGeometryLimits _strokeGeometryLimitsForShapeTests() => _ok(
  StrokeGeometryLimits.create(
    maximumElements: 4,
    maximumVertices: 16,
    ellipseVertexCount: 8,
    maximumContainmentChecks: 16,
  ),
);

ObjectRegistry _registry() => _ok(
  ObjectRegistry.create([
    ShapeObjectTypeDefinition(_shapeLimits),
    ImageObjectTypeDefinition(_imageLimits),
    TextObjectTypeDefinition(_textLimits, FlutterTextLayoutEngine(_textLimits)),
  ]),
);

RenderingLimits _renderingLimits() => _ok(
  RenderingLimits.create(
    maximumPrimitives: 512,
    maximumPointsPerPrimitive: 128,
    maximumDamageRegions: 64,
    maximumPreviewOverlays: 16,
    maximumSelectionOverlays: 16,
  ),
);

ViewportSnapshot _viewport() => _ok(
  ViewportSnapshot.create(
    extent: _ok(ViewExtent.create(width: 600, height: 800)),
    pageOrigin: _point(0, 0),
    zoom: 1,
    minimumZoom: .25,
    maximumZoom: 8,
    revision: _revision(0),
  ),
);

IdentityRemapping _emptyRemapping() => IdentityRemapping();

ResourceMediaType _mediaType(String value) =>
    _ok(ResourceMediaType.parse(value));
ResourceRole _resourceRole() => _ok(ResourceRole.parse('alnote.image.source'));
TextPosition _position(int paragraph, int scalar) =>
    _ok(TextPosition.create(paragraphIndex: paragraph, scalarOffset: scalar));
Revision _revision(int value) => _ok(Revision.create(value));
Point2 _point(double x, double y) => _ok(Point2.create(x: x, y: y));
Rect2 _rect(double l, double t, double r, double b) =>
    _ok(Rect2.fromEdges(left: l, top: t, right: r, bottom: b));
Size2 _size(double width, double height) =>
    _ok(Size2.create(width: width, height: height));
double _distance(Point2 first, Point2 second) => math.sqrt(
  math.pow(first.x - second.x, 2) + math.pow(first.y - second.y, 2),
);
Point2 _polygonCentroid(List<Point2> polygon) => _point(
  polygon.fold<double>(0, (sum, point) => sum + point.x) / polygon.length,
  polygon.fold<double>(0, (sum, point) => sum + point.y) / polygon.length,
);
PreservedInteger _integer(int value) => _ok(PreservedInteger.create(value));
T _ok<T, E>(Result<T, E> value) => (value as Ok<T, E>).value;

final class _ThrowingIterable<T> extends Iterable<T> {
  _ThrowingIterable(this.first);
  final T first;
  @override
  Iterator<T> get iterator => _ThrowingIterator(first);
}

final class _ThrowingIterator<T> implements Iterator<T> {
  _ThrowingIterator(this._first);
  final T _first;
  var _state = 0;
  @override
  T get current => _state == 1 ? _first : throw StateError('hostile-current');
  @override
  bool moveNext() {
    if (_state++ == 0) return true;
    throw StateError('hostile-moveNext');
  }
}

final class _RejectedTailIterable<T> extends Iterable<T> {
  _RejectedTailIterable(this.first);
  final T first;
  @override
  Iterator<T> get iterator => _RejectedTailIterator(first);
}

final class _RejectedTailIterator<T> implements Iterator<T> {
  _RejectedTailIterator(this._first);
  final T _first;
  var _state = 0;
  @override
  T get current => switch (_state) {
    1 => _first,
    2 => throw StateError('rejected tail must never be read'),
    _ => throw StateError('no current value'),
  };
  @override
  bool moveNext() {
    if (_state < 2) {
      _state++;
      return true;
    }
    return false;
  }
}

final class _RejectedAfterIterable<T> extends Iterable<T> {
  _RejectedAfterIterable(this.accepted, this.rejected);
  final List<T> accepted;
  final T rejected;
  bool rejectedCurrentRead = false;
  @override
  Iterator<T> get iterator => _RejectedAfterIterator(this);
}

final class _RejectedAfterIterator<T> implements Iterator<T> {
  _RejectedAfterIterator(this.owner);
  final _RejectedAfterIterable<T> owner;
  var index = -1;
  @override
  T get current {
    if (index < owner.accepted.length) return owner.accepted[index];
    owner.rejectedCurrentRead = true;
    return owner.rejected;
  }

  @override
  bool moveNext() {
    index += 1;
    return index <= owner.accepted.length;
  }
}

final class _ThrowingIteratorCreationIterable<T> extends Iterable<T> {
  @override
  Iterator<T> get iterator => throw StateError('hostile iterator secret');
}

final class _AcceptedCurrentThrowingIterable<T> extends Iterable<T> {
  @override
  Iterator<T> get iterator => _AcceptedCurrentThrowingIterator<T>();
}

final class _AcceptedCurrentThrowingIterator<T> implements Iterator<T> {
  var moved = false;
  @override
  T get current => throw StateError('hostile current secret');
  @override
  bool moveNext() => !moved && (moved = true);
}

final class _StatefulCurrentIterable extends Iterable<int> {
  _StatefulCurrentIterable(this.values);
  final List<int> values;
  int currentReads = 0;
  @override
  Iterator<int> get iterator => _StatefulCurrentIterator(this);
}

final class _StatefulCurrentIterator implements Iterator<int> {
  _StatefulCurrentIterator(this.owner);
  final _StatefulCurrentIterable owner;
  var index = -1;
  var readAtIndex = false;
  @override
  int get current {
    owner.currentReads += 1;
    if (readAtIndex) return 256;
    readAtIndex = true;
    return owner.values[index];
  }

  @override
  bool moveNext() {
    index += 1;
    readAtIndex = false;
    return index < owner.values.length;
  }
}

final class _TextPainterLifecycleEvidence
    implements FlutterTextPainterLifecycleObserver {
  final Set<flutter.TextPainter> _live = {};
  final Set<flutter.TextPainter> _disposed = {};
  int createdCount = 0;
  int disposedCount = 0;
  bool doubleDisposed = false;

  int get liveCount => _live.length;

  @override
  void created(flutter.TextPainter painter) {
    createdCount += 1;
    _live.add(painter);
  }

  @override
  void disposed(flutter.TextPainter painter) {
    disposedCount += 1;
    if (!_live.remove(painter) || !_disposed.add(painter)) {
      doubleDisposed = true;
    }
  }
}

final class _CountingTextLayoutEngine implements TextLayoutEngine {
  _CountingTextLayoutEngine(this.delegate, {this.fail = false});

  final TextLayoutEngine delegate;
  final bool fail;
  int calls = 0;

  @override
  Result<TextLayoutSnapshot, StructuredFailure> layout(
    TextLayoutRequest request,
  ) {
    calls += 1;
    return fail
        ? Err(
            StructuredFailure(
              code: 'test.text.layout_unavailable',
              category: FailureCategory.dependency,
              retryDisposition: RetryDisposition.never,
              message: 'Text layout is unavailable.',
            ),
          )
        : delegate.layout(request);
  }
}

final class _FixedTextLayoutEngine implements TextLayoutEngine {
  _FixedTextLayoutEngine(this.snapshot);

  final TextLayoutSnapshot snapshot;
  int calls = 0;

  @override
  Result<TextLayoutSnapshot, StructuredFailure> layout(
    TextLayoutRequest request,
  ) {
    calls += 1;
    return Ok(snapshot);
  }
}

final class _FakeImageHandle implements DecodedImageHandle {
  _FakeImageHandle(this.pixelWidth, this.pixelHeight);
  @override
  final int pixelWidth;
  @override
  final int pixelHeight;
  bool disposed = false;
  @override
  void dispose() => disposed = true;
}

final class _ThrowingImageHandle implements DecodedImageHandle {
  @override
  int get pixelWidth => throw StateError('hostile width');
  @override
  int get pixelHeight => throw StateError('hostile height');
  @override
  void dispose() => throw StateError('hostile dispose');
}

final class _SuccessfulImageDecoder implements ImageDecoder {
  @override
  Future<Result<DecodedImageHandle, StructuredFailure>> decode(
    ImageDecodeRequest request,
  ) async => Ok(
    _FakeImageHandle(request.encodedPixelWidth, request.encodedPixelHeight),
  );
}

const List<int> _pngFixture = [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  2,
  0,
  0,
  0,
  3,
  8,
  6,
  0,
  0,
  0,
  185,
  234,
  222,
  129,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

const List<int> _jpegFixture = [
  0xff,
  0xd8,
  0xff,
  0xe0,
  0x00,
  0x10,
  0x4a,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
  0x02,
  0x01,
  0x00,
  0x48,
  0x00,
  0x48,
  0x00,
  0x00,
  0xff,
  0xe1,
  0x00,
  0x22,
  0x45,
  0x78,
  0x69,
  0x66,
  0x00,
  0x00,
  0x49,
  0x49,
  0x2a,
  0x00,
  0x08,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x12,
  0x01,
  0x03,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x06,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0xff,
  0xc0,
  0x00,
  0x11,
  0x08,
  0x00,
  0x02,
  0x00,
  0x03,
  0x03,
  0x01,
  0x11,
  0x00,
  0x02,
  0x11,
  0x00,
  0x03,
  0x11,
  0x00,
  0xff,
  0xd9,
];

final List<int> _realPngFixture = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Future<int> _paintedAlpha(ScenePrimitive primitive, Point2 point) async {
  final bytes = await _paintedBytes(primitive);
  final x = point.x.round();
  final y = point.y.round();
  return bytes[(y * 256 + x) * 4 + 3];
}

Future<List<int>> _paintedRgba(ScenePrimitive primitive, Point2 point) async {
  final bytes = await _paintedBytes(primitive);
  final offset = (point.y.round() * 256 + point.x.round()) * 4;
  return bytes.sublist(offset, offset + 4);
}

Future<List<int>> _paintedBytes(ScenePrimitive primitive) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  paintScenePrimitiveForTesting(canvas, primitive);
  final image = await recorder.endRecording().toImage(256, 256);
  try {
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (bytes == null) throw StateError('Pixel evidence unavailable.');
    return bytes.buffer.asUint8List().toList(growable: false);
  } finally {
    image.dispose();
  }
}

Future<List<int>> _paintedTextWithFactory(
  TextPayload payload,
  TextLayoutSnapshot layout,
  double layerOpacity,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final painters = <flutter.TextPainter>[];
  const factory = FlutterTextPainterFactory();
  canvas.save();
  if (payload.boxMode == TextBoxMode.fixedWidthFixedHeight &&
      payload.overflowPolicy == TextOverflowPolicy.clip) {
    canvas.clipRect(
      ui.Rect.fromLTRB(
        layout.logicalBounds.left,
        layout.logicalBounds.top,
        layout.logicalBounds.right,
        layout.logicalBounds.bottom,
      ),
    );
  }
  try {
    final maximumWidth = math.max<double>(
      0,
      payload.intrinsicWidth - payload.padding.left - payload.padding.right,
    );
    for (final paragraph in payload.paragraphs) {
      painters.add(
        factory.create(
          payload: payload,
          paragraph: paragraph,
          maximumWidth: maximumWidth,
          layerOpacity: layerOpacity,
        ),
      );
    }
    for (var index = 0; index < painters.length; index++) {
      final origin = layout.paragraphs[index].origin;
      painters[index].paint(canvas, ui.Offset(origin.x, origin.y));
    }
  } finally {
    for (final painter in painters) {
      factory.dispose(painter);
    }
    canvas.restore();
  }
  final image = await recorder.endRecording().toImage(256, 256);
  try {
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (bytes == null) throw StateError('Pixel evidence unavailable.');
    return bytes.buffer.asUint8List().toList(growable: false);
  } finally {
    image.dispose();
  }
}

final List<int> _realJpegFixture = base64Decode(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAABAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD4H8Q/8h/Uv+vmX/0M0UUV/ptkP/Ipwn/XuH/pKPAzr/kZ4r/r5P8A9KZ//9k=',
);

List<int> _coloredPngFixture() {
  final raw = <int>[];
  for (var value = 1; value <= 6; value++) {
    if (value.isOdd) raw.add(0);
    raw.addAll([value, 0, 0, 255]);
  }
  return <int>[
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ..._pngChunk('IHDR', [..._u32Bytes(2), ..._u32Bytes(3), 8, 6, 0, 0, 0]),
    ..._pngChunk('IDAT', ZLibEncoder().convert(raw)),
    ..._pngChunk('IEND', const []),
  ];
}

List<int> _pngChunk(String type, List<int> data) {
  final name = ascii.encode(type);
  return [
    ..._u32Bytes(data.length),
    ...name,
    ...data,
    ..._u32Bytes(_crc32([...name, ...data])),
  ];
}

List<int> _u32Bytes(int value) => [
  value >> 24 & 0xff,
  value >> 16 & 0xff,
  value >> 8 & 0xff,
  value & 0xff,
];

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
