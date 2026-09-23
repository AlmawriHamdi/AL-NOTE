> Historical independent report, copied for migration continuity. Repository/SDK paths and a historical PID are normalized; raw-log links identify excluded HDD evidence. Results and limitations are retained. This is not a new audit.

**Independent recheck — movable PDF Object F1 — 2026-09-22**

**F1: RESOLVED. APPROVE F1 and proceeding to movable-PDF-object manual acceptance.** No confirmed correction-induced defect. This is permission to proceed with the bounded feature's manual acceptance, not a claim that manual/device testing has already passed or that Phase 8/release is approved.

Reviewed the original independent report and `docs/testing-release/phase8-pdf-objects-f1.md`, actual corrected dispatch/geometry and regression assertions. Project `<repository>`, branch `phase-8-pdf-system`, HEAD `921e43f41a31b0649a2ae890c993fd4e406ad39a`; SDK Flutter 3.47.4 / Dart 3.13.3.

**Original reproducers, unchanged: all three passed.**

The two original fixture Canvas cases now leave off-Page Selection empty and prevent off-Page Whole Eraser deletion. The original real-worker case still measures gray RGBA `[217,221,226,255]` at `(511.3,314.3)`, beyond Page right `503.2`, but Object count now remains **1 → 1**. All 68 original temporary probe files match their retained hashes before and after this recheck.

Exact reruns from the project directory, with output redirected to this evidence directory:

```sh
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 /tmp/al-note-pdf-objects-independent/test/widget_test.dart --name 'AUDIT off-page' --reporter expanded
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true /tmp/al-note-pdf-objects-independent/test/widget_test.dart --name 'AUDIT HOST off-page' --reporter expanded
```

Logs: original-fixture.log (`/tmp/al-note-pdf-objects-f1-independent/original-fixture.log`, raw HDD evidence), original-host.log (`/tmp/al-note-pdf-objects-f1-independent/original-host.log`, raw HDD evidence).

**Personally executed focused evidence.** Counts are test executions with overlapping coverage, not a full-suite total.

| Check | Result |
| --- | --- |
| Three original reproducers | 3 passed |
| New permanent actual-worker margin/marquee/eraser/crossing/Undo regression | 1 passed, host-regression.log (`/tmp/al-note-pdf-objects-f1-independent/host-regression.log`, raw HDD evidence) |
| PDF Page-clip matrix and PDF rendering, shared portable hit/eraser behavior, Selection controller | 110 passed, focused-geometry-shared.log (`/tmp/al-note-pdf-objects-f1-independent/focused-geometry-shared.log`, raw HDD evidence) |
| Focused Canvas clipping, handles/history, PDF insert/transform/round-trip and selected handwriting/Shape/Text interaction | 17 passed, focused-canvas.log (`/tmp/al-note-pdf-objects-f1-independent/focused-canvas.log`, raw HDD evidence) |
| Additional independent geometry oracle | 1 passed: 5,760 queries, 34,560 comparisons, oracle.log (`/tmp/al-note-pdf-objects-f1-independent/oracle.log`, raw HDD evidence) |

The supplied matrix checks all four Page edges and corners, partial/full/zero-area clipping, crop plus nonuniform scale and rotation, point/rectangle/lasso, containment, stationary and crossing sweeps (including both endpoints outside). Canvas miss assertions preserve exact root, content identity, revisions, resources, retained history, saved state and zero observer publications. Visible move/resize and crossing erasure publish once and traverse exact-root/content-identity Undo/Redo. Editable bounds remain full-size beyond the Page edge.

My additional oracle uses independently enumerated feasible intersections of linear inequalities, rather than the production sequential polygon-clipping algorithm. Deterministic seed 927401 generates 240 asymmetric normalized crops, random rotations and nonuniform scales at all edges/corners. Each has 24 point/tolerance, swept-capsule and rectangle/rectangular-lasso queries in both area modes. It includes fully outside geometry and outside query endpoints, comparing against the actual Page-bound registry and PageHitTester. See generator (`/tmp/al-note-pdf-objects-f1-independent/generate_oracle.py`, raw HDD evidence), inputs (`/tmp/al-note-pdf-objects-f1-independent/oracle.json`, raw HDD evidence), Dart probe (`/tmp/al-note-pdf-objects-f1-independent/oracle_test.dart`, raw HDD evidence). An initial missing helper in this new temporary harness caused a compilation failure; `oracle-development.log` retains it. Only the corrected successful run is counted. Original reproducers were never edited.

Additional exact commands:

```sh
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true test/widget_test.dart --name 'private Linux PDF Page clip' --reporter expanded
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 test/drawing/pdf_object_page_clip_test.dart test/drawing/pdf_object_rendering_test.dart test/drawing/phase6_portable_test.dart test/drawing/selection/selection_controller_test.dart --reporter expanded
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 test/widget_test.dart --name 'PDF Page clip|selects, whole-erases|Shape tool creates|short Text commit fits|Text Selection scales|whole Eraser drag is|Selection corner resize and rotation|PDF Objects insert' --reporter expanded
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 /tmp/al-note-pdf-objects-f1-independent/oracle_test.dart --reporter expanded
```

**Code review conclusion.** PDF's [Page-bound polygon](../../../lib/drawing/hit_testing/content_hit_testing.dart#L60) intersects the transformed crop with the destination Page; [clipping](../../../lib/drawing/hit_testing/content_hit_testing.dart#L256) rejects empty/zero-area results. Point, area and swept-capsule queries consume that polygon. [Off-Page point rejection](../../../lib/drawing/hit_testing/content_hit_testing.dart#L78) applies even with tolerance. No pointer/segment clamping is introduced. A capsule can hit when its actual radius/path intersects visible content, even when its center starts outside.

The [registry](../../../lib/drawing/hit_testing/hit_testing.dart#L175) binds PDF behavior for both [Selection candidates](../../../lib/drawing/hit_testing/hit_testing.dart#L759) and [Whole Eraser candidates](../../../lib/drawing/tools/eraser_gesture_plans.dart#L577). Non-PDF definitions retain their original captured delegates; default bounds containment behavior remains unchanged. The eraser's full transformed AABB is only a conservative broad-phase filter. Intrinsic geometry and persistent payload/source/transform data remain untouched by hit queries.

**Scope and preservation.** Independently confirmed **five modifications, two additions, zero removals and 528 unchanged baseline files**, using the original independent audit's 533-file inventory, which exactly matches the correction's before inventory. All 535 final source hashes match the correction's after inventory. Git index entries match both recorded pre-correction inventories. See scope-check.json (`/tmp/al-note-pdf-objects-f1-independent/scope-check.json`, raw HDD evidence).

Across this recheck, all 535 tracked/untracked source hashes, Git status and raw index hash remained unchanged; branch/HEAD are unchanged. Preservation evidence (`/tmp/al-note-pdf-objects-f1-independent/preservation-final.json`, raw HDD evidence). Existing model/history, rendering, Canvas, admission, engine/package pins, dependencies/lockfile and CI are among the preserved files. Diagnostics were written only outside repository source.

Host PDF tests ran serially. Final successful systemd query found **zero PDF service units, zero staged-runtime processes and zero staging directories**: host-final.json (`/tmp/al-note-pdf-objects-f1-independent/host-final.json`, raw HDD evidence). No audit-created worker remains.

Reviewed, rather than reran, the correction's 401-passing affected-suite log, clean fatal-info analysis and five-file/no-change formatting result. Recorded final source hashes match current files. No full app suite, platform build or engine audit was repeated.

**Limitations retained.** The two forced no-draft synchronous **Undo-disposal and Redo-disposal cases remain explicitly INCONCLUSIVE**, unchanged from the prior independent report. They were not rerun, counted as passes or reclassified: their framework paint-layer assertion still requires an appropriate harness/control. Manual/device acceptance remains to be performed. This narrow recheck does not newly establish Windows/Android, physical stylus/GPU behavior or arbitrary-input security. Existing Pen, zoom and Save/Reopen issues, storage/stall limits, serial-render latency and raster-quality/performance limits remain disclosed and unresolved. No implementation, source/Git edit, rebuild, publication or Phase 8/release approval was performed.
