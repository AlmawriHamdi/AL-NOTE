# Movable PDF Objects: F1 Page-clipped interaction

Correction handoff, 2026-09-22. F1 only; awaiting independent recheck. The source
baseline is the existing dirty worktree, not HEAD. Branch/HEAD remain
`phase-8-pdf-system` / `921e43f41a31b0649a2ae890c993fd4e406ad39a`.

## Cause and correction

Rendering already applied the destination Page clip. PDF hit testing instead
queried the entire transformed crop rectangle, so invisible geometry in the gray
margin could acquire Selection or be removed by Whole Eraser.

- The hit Registry now binds optional Page-aware behavior when preparing Page
  Selection candidates and Whole Eraser candidates. Only PDF implements this
  behavior; other definitions retain their existing captured delegate.
- PDF interaction intersects its transformed, cropped local rectangle with four
  Page half-planes. This bounded convex intersection has at most eight vertices.
  Point, rectangle/marquee, lasso, and swept-capsule queries use that polygon.
  Empty and zero-area intersections miss, including containment queries. PDF
  boundary containment includes exact polygon edges without widening geometry.
- Off-Page Selection points are rejected even with tolerance. Query coordinates
  and eraser segments are never clamped. A capsule crossing into visible content
  can hit; a capsule wholly outside cannot. The eraser's existing un-clipped AABB
  remains only a conservative broad-phase filter before the precise query.
- Intrinsic/editable bounds and handles remain unchanged. A partially clipped
  Object can still be selected in its visible area, moved and resized. Persistent
  payload/crop/source references and transforms are never rewritten by queries.

Production changes are limited to
[`content_hit_testing.dart`](../../lib/drawing/hit_testing/content_hit_testing.dart),
[`hit_testing.dart`](../../lib/drawing/hit_testing/hit_testing.dart), and
[`eraser_gesture_plans.dart`](../../lib/drawing/tools/eraser_gesture_plans.dart).
Regressions add [`pdf_object_page_clip_test.dart`](../../test/drawing/pdf_object_page_clip_test.dart)
and extend [`pdf_object_insertion_checks.dart`](../../test/support/pdf_object_insertion_checks.dart).
This report and the original handoff's correction link complete the file scope:
**five modifications, two additions, zero removals; 528 baseline files unchanged**.
The Git index is unchanged. See [scope inventory](../../build/pdf-object-f1-review/scope.json),
[before hashes](../../build/pdf-object-f1-review/source-before.json), and
[after hashes](../../build/pdf-object-f1-review/source-after.json).

## Verification

Evidence is retained in `build/pdf-object-f1-review/`. Results below are personally
run for this correction and are not the previous feature's full-suite totals.

| Check | Result / evidence |
| --- | --- |
| Auditor's original fixture Canvas Selection / Whole Eraser probes, unchanged | Before: **2 expected-no-hit failures**, reproducing F1. After: **2 passed**. [before](../../build/pdf-object-f1-review/original-before.log), [final](../../build/pdf-object-f1-review/original-final.log). |
| Auditor's original real-worker eraser probe, unchanged | Before: **1 expected-no-hit failure**. After: **1 passed**, same gray RGBA `[217,221,226,255]`, Object count **1 → 1**. [before](../../build/pdf-object-f1-review/original-host-before.log), [final](../../build/pdf-object-f1-review/original-host-final.log). |
| New geometry and deterministic Canvas checks | **42 passed**, `focused-development3.log`. All four edges/four corners, partial/full clipping, rotated nonuniformly scaled crops, point and small-area grid queries against independent inverse equations, rectangle/lasso containment, zero-area contact, visible hits, stationary and boundary-crossing sweeps (including both endpoints outside), margin gestures, retained full handles, exact Undo/Redo and zero publication/history/state change on misses. |
| Affected shared-code and complete Canvas coverage | **401 passed**, 3m11s, `affected-tests.log`. Includes the 42 above; counts are not additive. Existing non-PDF Image/Text/Shape/handwriting, Selection, Whole Eraser, transforms/history, PDF insertion/open/import and draft/observer tests are included. |
| New permanent actual Linux-worker regression | **1 passed**, [log](../../build/pdf-object-f1-review/host-regression-final.log). A successfully rendered controlled ordinary PDF has gray margin pixels; point/marquee/eraser misses retain state/history and publish nothing, a crossing sweep erases, Undo restores the exact root, and disposal drains workers. |
| Final worker cleanup | **Zero units, zero staged-runtime processes, zero stage directories**; systemd query succeeded. [inventory](../../build/pdf-object-f1-review/host-cleanup-final.json). |
| Formatting / whitespace | **5 Dart files, 0 changes**; `git diff --check` passed. [format log](../../build/pdf-object-f1-review/format-check.log). |
| Strict analysis | **No issues**, `flutter analyze --no-pub --fatal-infos`, `analysis.log`. |

Exact affected-test command (from `/home/Hamdi/Projacts/AL-NOTE`):

```sh
/home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub --concurrency=1 \
  test/core/geometry test/drawing test/documents/phase7_objects_test.dart \
  test/documents/commands/phase6_collection_edit_test.dart \
  test/documents/pdf_object_insertion_test.dart test/widget_test.dart \
  --reporter expanded
```

Formatting used the bundled Dart executable directly:
`/home/Hamdi/Development/flutter-3.47.4/bin/cache/dart-sdk/bin/dart format --output=none --set-exit-if-changed`
on the five changed/added Dart files. The SDK launcher attempted a cache-stamp
write in the read-only sandbox; calling its bundled Dart directly completed the
check without requiring an SDK write. An earlier escalation review timed out;
this did not block the completed check.

The 401-test run, strict analysis, formatting and final original/host probes all
cover the final Dart source state. Only report edits followed. The 42-case
focused run preceded the 401-test run. No passing totals include failed
exploratory runs.

The original probes use the exact commands from
`/tmp/al-note-pdf-objects-independent/report.md`, with output redirected to the
correction evidence directory. No assertions in that harness were changed. The permanent host command was:

```sh
/home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub --concurrency=1 \
  --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true \
  --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true \
  test/widget_test.dart --name 'private Linux PDF Page clip' --reporter expanded
```

Development failures are retained, not counted as passes: an initial test-only
invalid `const`; PDF lasso boundary containment failures caught by the new edge
matrix; and a test setup attempting an unreachable whole-Object transform. The
existing coordinator correctly rejects geometry entirely beyond the Page. The
Canvas zero-visible-area case now uses a reachable exact-edge placement; domain
queries additionally exercise geometry wholly beyond every Page edge/corner.
No coordinator validation was weakened.

## Limits and preservation

The two forced no-draft Undo/Redo disposal probes remain **INCONCLUSIVE** because
of the previously recorded Flutter paint-layer assertion. They were not rerun,
weakened, counted as passes, or classified as confirmed feature defects. This
correction does not expand into framework disposal work.

No full-suite rerun, platform build, engine/package audit, or manual/device
acceptance was performed: only interaction dispatch/geometry and its regressions
changed. Existing SDK/dependency/worker/package pins, admission, rendering,
source capture, model/schema, storage, history implementation and deferred
features remain unchanged. Previous Pen/zoom and Save/Reopen performance
limitations remain unresolved. No commits, publication, or approval of manual
acceptance is implied.
