// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:al_note/core/primitives.dart';
import 'package:al_note/documents/document_model.dart';
import 'package:al_note/drawing/geometry.dart';
import 'package:al_note/drawing/hit_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/document_model_test_support.dart';
import '../support/pdf_geometry_checks.dart';
import 'pdf_object_rendering_test.dart' show pdfPayload, point, value;

void main() {
  final pageBounds = rect(0, 0, 600, 800);
  final registry = value(
    HitTestingRegistry.create(
      [PdfPageHitTestingDefinition(geometryModelLimits)],
      maximumDefinitions: 1,
      maximumBehaviorResults: 10,
    ),
  );
  for (final edge in [
    (name: 'left', x: 0.0, y: 400.0, nx: -1, ny: 0),
    (name: 'right', x: 600.0, y: 400.0, nx: 1, ny: 0),
    (name: 'top', x: 300.0, y: 0.0, nx: 0, ny: -1),
    (name: 'bottom', x: 300.0, y: 800.0, nx: 0, ny: 1),
    (name: 'top left', x: 0.0, y: 0.0, nx: -1, ny: -1),
    (name: 'top right', x: 600.0, y: 0.0, nx: 1, ny: -1),
    (name: 'bottom left', x: 0.0, y: 800.0, nx: -1, ny: 1),
    (name: 'bottom right', x: 600.0, y: 800.0, nx: 1, ny: 1),
  ]) {
    for (final angle in [0.0, math.pi / 4]) {
      for (final fullyClipped in [false, true]) {
        test(
          'PDF Page clip ${edge.name}, angle $angle, fully $fullyClipped',
          () {
            // Cropped local size 20 x 40; nonuniform scale makes it 40 x 20.
            final cx = edge.x + (fullyClipped ? 100 * edge.nx : 0);
            final cy = edge.y + (fullyClipped ? 100 * edge.ny : 0);
            final cos = math.cos(angle), sin = math.sin(angle);
            final object = testObject(
              typeKey: pdfPageObjectTypeKey,
              payload: pdfPayload().encode(),
              transform: value(
                AffineTransform2D.restoreFromStorage([
                  2 * cos,
                  -.5 * sin,
                  2 * sin,
                  .5 * cos,
                  cx - 20 * cos + 10 * sin,
                  cy - 20 * sin - 10 * cos,
                ]),
              ),
            );
            final originalPayload = object.payload;
            final originalTransform = object.transform;
            final page = testPage(
              layers: [
                testContentLayer(objects: [object]),
              ],
            );
            final tester = PageHitTester(
              objectRegistry: testRegistry([
                PdfPageObjectTypeDefinition(geometryModelLimits),
              ]),
              hitTestingRegistry: registry,
              maximumCandidates: 10,
              maximumResults: 10,
              maximumLassoPoints: 10,
            );
            final hits =
                registry.definitionForPage(object.typeKey, page)!
                    as ObjectWholeHitTestingDefinition;
            // Independent inverse equations test the true rotated polygon, not
            // its AABB, throughout the visible and invisible boundary region.
            for (final dx in [
              -35.0,
              -25.0,
              -15.0,
              -5.0,
              5.0,
              15.0,
              25.0,
              35.0,
            ]) {
              for (final dy in [
                -35.0,
                -25.0,
                -15.0,
                -5.0,
                5.0,
                15.0,
                25.0,
                35.0,
              ]) {
                final p = point(cx + dx, cy + dy);
                final localX = (cos * dx + sin * dy) / 2 + 10;
                final localY = (-sin * dx + cos * dy) / .5 + 20;
                final expected =
                    pageBounds.contains(p) &&
                    localX >= 0 &&
                    localX <= 20 &&
                    localY >= 0 &&
                    localY <= 40;
                expect(
                  value(
                        tester.point(
                          page: page,
                          pagePosition: p,
                          pageTolerance: 0,
                        ),
                      ) !=
                      null,
                  expected,
                  reason: 'offset ($dx, $dy)',
                );
                expect(
                  value(
                    tester.rectangle(
                      page: page,
                      area: rect(p.x - .01, p.y - .01, p.x + .01, p.y + .01),
                      mode: AreaHitMode.intersection,
                    ),
                  ).isNotEmpty,
                  expected,
                  reason: 'rectangle offset ($dx, $dy)',
                );
                expect(
                  value(
                    hits.wholeSweptSegment(
                      object: object,
                      start: p,
                      end: p,
                      radius: 0,
                    ),
                  ),
                  expected,
                  reason: 'stationary sweep offset ($dx, $dy)',
                );
              }
            }
            final outside = point(cx + edge.nx * 8, cy + edge.ny * 8);
            final margin = rect(
              outside.x - 1,
              outside.y - 1,
              outside.x + 1,
              outside.y + 1,
            );
            expect(
              value(
                tester.point(
                  page: page,
                  pagePosition: outside,
                  pageTolerance: 100,
                ),
              ),
              isNull,
            );
            for (final mode in AreaHitMode.values) {
              expect(
                value(tester.rectangle(page: page, area: margin, mode: mode)),
                isEmpty,
              );
              expect(
                value(
                  tester.rectangle(page: page, area: pageBounds, mode: mode),
                ),
                hasLength(fullyClipped ? 0 : 1),
              );
              expect(
                value(
                  tester.lasso(
                    page: page,
                    polygon: [
                      point(0, 0),
                      point(600, 0),
                      point(600, 800),
                      point(0, 800),
                    ],
                    mode: mode,
                  ),
                ),
                hasLength(fullyClipped ? 0 : 1),
              );
            }
            expect(
              value(
                hits.wholeSweptSegment(
                  object: object,
                  start: outside,
                  end: point(outside.x + .5, outside.y + .5),
                  radius: 1,
                ),
              ),
              isFalse,
            );
            final visible = point(edge.x - edge.nx * 2, edge.y - edge.ny * 2);
            expect(
              value(
                    tester.point(
                      page: page,
                      pagePosition: visible,
                      pageTolerance: 0,
                    ),
                  ) !=
                  null,
              !fullyClipped,
            );
            expect(
              value(
                tester.rectangle(
                  page: page,
                  area: rect(
                    visible.x - .25,
                    visible.y - .25,
                    visible.x + .25,
                    visible.y + .25,
                  ),
                  mode: AreaHitMode.intersection,
                ),
              ).isNotEmpty,
              !fullyClipped,
            );
            // Original segment is queried intact; it crosses the Page boundary.
            expect(
              value(
                hits.wholeSweptSegment(
                  object: object,
                  start: outside,
                  end: visible,
                  radius: 0,
                ),
              ),
              !fullyClipped,
            );
            expect(
              value(
                hits.wholeSweptSegment(
                  object: object,
                  start: outside,
                  end: point(edge.x - edge.nx * 900, edge.y - edge.ny * 900),
                  radius: 0,
                ),
              ),
              !fullyClipped,
              reason: 'both endpoints outside, crossing visible content',
            );
            if (fullyClipped) {
              expect(
                value(
                  hits.wholeRectangle(
                    object: object,
                    area: rect(cx - 50, cy - 50, cx + 50, cy + 50),
                    mode: AreaHitMode.containment,
                  ),
                ),
                isFalse,
              );
            }
            expect(object.payload, same(originalPayload));
            expect(object.transform, same(originalTransform));
          },
        );
      }
    }
  }
  test(
    'PDF touching Page only at an edge or corner has no visible interaction',
    () {
      for (final position in [
        (-20.0, 50.0),
        (600.0, 50.0),
        (50.0, -40.0),
        (50.0, 800.0),
        (-20.0, -40.0),
        (600.0, 800.0),
      ]) {
        final object = testObject(
          typeKey: pdfPageObjectTypeKey,
          payload: pdfPayload().encode(),
          transform: value(
            AffineTransform2D.fromOperation(
              TranslationTransformOperation2D(
                value(Vector2.create(x: position.$1, y: position.$2)),
              ),
            ),
          ),
        );
        final hits = PdfPageHitTestingDefinition(geometryModelLimits)
            .withPageBounds(pageBounds);
        expect(
          value(
            hits.wholeRectangle(
              object: object,
              area: pageBounds,
              mode: AreaHitMode.intersection,
            ),
          ),
          isFalse,
        );
        expect(
          value(
            hits.wholeRectangle(
              object: object,
              area: pageBounds,
              mode: AreaHitMode.containment,
            ),
          ),
          isFalse,
        );
        expect(
          value(
            hits.wholeSweptSegment(
              object: object,
              start: point(-100, -100),
              end: point(700, 900),
              radius: 1000,
            ),
          ),
          isFalse,
        );
        expect(
          value(
            hits.wholeLasso(
              object: object,
              polygon: value(
                GeometryQueryPolygon.create([
                  point(-100, -100),
                  point(700, -100),
                  point(700, 900),
                  point(-100, 900),
                ], maximumPoints: 4),
              ),
              mode: AreaHitMode.containment,
            ),
          ),
          isFalse,
        );
      }
    },
  );
}

Rect2 rect(double left, double top, double right, double bottom) =>
    value(Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom));
