> Historical independent report, copied for migration continuity. Repository/SDK paths and a historical PID are normalized; raw-log links identify excluded HDD evidence. Results and limitations are retained. This is not a new audit.

**Independent review — movable PDF page Objects — 2026-09-22**

**BLOCK movable-PDF-object manual acceptance.** One confirmed correctness defect makes interaction disagree with Page-clipped rendering. The actual-worker crop/transform/persistence probes otherwise passed. No implementation or repository/Git mutation was performed. This is not a Phase 8 or release review.

**F1 — P2: invisible, off-Page PDF geometry remains selectable and erasable.**

A movable PDF Object may extend beyond its destination Page. Rendering correctly clips its pixels to the Page, but the newly registered PDF hit definition passes the entire transformed Object rectangle to Selection and Whole Eraser. A pointer wholly in the gray margin can select that invisible portion; an eraser gesture there deletes the whole Object.

Relevant code:

- [PDF hit-definition registration/geometry](../../../lib/drawing/hit_testing/content_hit_testing.dart#L34).
- [Transformed polygon returned without Page intersection](../../../lib/drawing/hit_testing/content_hit_testing.dart#L184).
- [Whole Eraser queries the un-clipped polygon](../../../lib/drawing/tools/eraser_gesture_plans.dart#L333); PDF joins its supported list at [line 566](../../../lib/drawing/tools/eraser_gesture_plans.dart#L566).
- [Canvas forwards off-Page pointer coordinates](../../../lib/ui/canvas/phase6_canvas.dart#L880).
- Rendering does clip: [committed Object painter](../../../lib/ui/canvas/phase6_canvas.dart#L8124) and [Page painter](../../../lib/ui/canvas/phase6_canvas.dart#L8245).

Minimal UI reproduction: insert one PDF page into a notebook, move it so its left edge is 20 Page units inside the right Page edge, and use Fit Page. At a point 25 Page units beyond the right edge, inside the Object's un-clipped rectangle, click Selection or make a short Whole Eraser stroke. Expected: no hit from a gesture wholly outside the visible Page. Actual: Selection acquires the Object; Whole Eraser removes it.

I reproduced both interactions through production Canvas with a deterministic fixture backend, then reproduced erasure with the real isolated Linux worker and the existing controlled `linux-integration/ordinary.pdf`. The latter recorded gray RGBA **[217, 221, 226, 255]** at screen point **(511.3, 314.3)**, beyond the Page's right edge **503.2**. Object count changed **1 → 0**. The worker had successfully rendered the PDF before the gesture, and was fully cleaned up before the failing assertion.

Exact independent reproducers, run from `<repository>`:

```sh
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 /tmp/al-note-pdf-objects-independent/test/widget_test.dart --name 'AUDIT off-page' --reporter expanded
<Flutter-3.47.4>/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true /tmp/al-note-pdf-objects-independent/test/widget_test.dart --name 'AUDIT HOST off-page' --reporter expanded
```

The assertions intentionally fail on current code. Evidence: off-page.log (`/tmp/al-note-pdf-objects-independent/off-page.log`, raw HDD evidence), host-off-page.log (`/tmp/al-note-pdf-objects-independent/host-off-page.log`, raw HDD evidence), temporary harness (`/tmp/al-note-pdf-objects-independent/test/widget_test.dart:8106`, raw HDD evidence).

Minimal fix: make PDF interaction use the transformed cropped polygon intersected with the destination Page, consistently for point/area Selection and swept Whole Eraser. Reject queries wholly outside that visible geometry. Do not merely clamp off-Page pointers onto the Page edge, which can create false hits. Retain editable bounds separately if needed for transform handles. Add off-Page point, area and swept-eraser regressions, including fully clipped and rotated Objects. This omission uses shared bounds infrastructure also used by other content; it is the new PDF integration's failure to satisfy the requested visible-geometry contract, not a claim that all shared hit-testing code was newly written.

**Personally executed evidence.**

| Check | Result |
| --- | --- |
| Existing focused insertion/domain/crop/hit tests, notebook import, production contention recovery, cancellation and cleanup publication | **80 passed**, focused.log (`/tmp/al-note-pdf-objects-independent/focused.log`, raw HDD evidence) |
| Existing actual-host movable Objects, import/annotation/recovery, standalone live-draft open, missing package and in-flight disposal | **5 passed**, host-existing.log (`/tmp/al-note-pdf-objects-independent/host-existing.log`, raw HDD evidence) |
| Independent synchronous insertion/Undo/Redo observer matrix with Save, Reopen, nested history and disposal; two cached-image disposal callbacks | **26 passed; two forced history-disposal cases hit the framework assertion described below**, independent.log (`/tmp/al-note-pdf-objects-independent/independent.log`, raw HDD evidence) |
| Independent real-worker source rotations 0/90/180/270, asymmetric normalized crop, nonuniform scale, common rotation/translation, Page-edge clipping and actual pixels after Save/Reopen | **4 passed**, host-independent.log (`/tmp/al-note-pdf-objects-independent/host-independent.log`, raw HDD evidence) |
| Off-Page Selection / Whole Eraser, including real worker | **Three expected-no-hit assertions failed**, confirming F1 |
| Canonical and installed isolated packages | **114 resources each verified**, unchanged manifest `82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298` |
| Final host inventory | **Zero worker units, zero staged-runtime processes, zero PDF stage directories**, host-final.json (`/tmp/al-note-pdf-objects-independent/host-final.json`, raw HDD evidence) |

Counts overlap in coverage; they are not a unique full-suite total. Host PDF invocations ran serially. All independent fixtures were existing controlled inputs or generated by the repository's marked-PDF writer; no arbitrary third-party PDF was used.

The independent host pixel oracle maps screenshot pixel centers backward through separately calculated translation/rotation/nonuniform scale, normalized crop and source rotation into the known red/blue source rectangles. It does not derive expected positions from the production Object transform or PDF coordinate mapper. Tested clip: left .07, top .04, right .93, bottom .97; common scales 1.3 and .75; rotation .37 radians. Centroids matched within two screen pixels, including a partially Page-clipped mark and after in-memory Reopen. Crop/common-transform edits reused the same raster; Reopen acquired a fresh raster. The larger test viewport separates interpolation at tiny raster edges from mapping correctness. No colored pixels escaped the Page clip.

**Verified behavior and review coverage.**

- Insertion parses bounded selection through the accepted shared parser, deduplicates and preserves source order, creates independent IDs, appends to the eligible content layer, and retains exact PDF references. Placement uses common transforms. Existing resource identity/digest/metadata is checked and immutable bytes are shared. Domain/focused tests cover operation limits, identity collisions, stale revisions, cancellation and history rejection without partial resources or Objects.
- The UI captures destination owner/content identity/Page and checks cancellation/currentness after each asynchronous preparation stage. The coordinator validates the entire candidate and history before publication. The companion hook settles insertion ownership before observers; no successful tail overwrites a reentrant Reopen/disposal. Independent observer assertions were collected outside callbacks so swallowed listener exceptions cannot manufacture a passing result. Save/Reopen/nested Undo/Redo and draft retention passed in the exercised cases.
- Atomic insertion Undo/Redo and common transform/erase history preserve Objects and payload/resource references in the focused tests. The real-worker probe also traversed transform history and checked actual cropped/rotated content after small-document in-memory Save/Reopen. This is not durable export or large-document storage verification.
- Layer/Object visibility and locks, half-opacity rendering, unsupported schema and unknown-layer inertness passed the focused tests. Opacity remains the existing layer setting; interaction eligibility continues to use the existing visible/locked flags. F1 is the confirmed visible-geometry mismatch at the Page boundary.
- The raster key includes the full `PdfPageReference` (including box provenance, rotation, dimensions and unknown fields), immutable byte identity and raster dimensions. UUID/crop/common transforms intentionally do not duplicate a full-page raster. The reviewed queue replaces current-Page interest, prunes obsolete images/failures before callbacks and drains sequentially. Existing bounded-cache tests exercise repeated resource/raster reuse under a **900-pixel aggregate ceiling**. Repeated supersession, old completion rejection, guarded contention recovery and stable permanent-failure placeholders passed. Detached cache/key ownership is cleared on owner replacement/disposal; a bounded old in-flight operation may retain its input until it finishes cleanup, as documented. This is not an RSS/GC proof.
- Standalone opening and notebook-page import passed the focused and actual-host regressions. Admission policy, scheduler/backend, protocol validation, worker/guard/transport, dependencies, SDK/lockfile and release restrictions are protected unchanged files; package contents independently verified. No engine audit or platform build was repeated.

**Synchronous-disposal limitation.**

The no-draft Undo and Redo probes forcibly attach/build/finalize a replacement root inside a synchronous observer. Their document/publication assertions ran, but Flutter subsequently asserted `node._layerHandle.layer != null` in `PipelineOwner.flushPaint` during the test binding's warm-up/teardown frame. The same harness on the existing notebook-import Undo path reproduced the assertion; its Redo control passed. See disposal-control.log (`/tmp/al-note-pdf-objects-independent/disposal-control.log`, raw HDD evidence). This evidence does not isolate a new movable-Object defect, so it is not counted as an additional confirmed finding or a passing verification. Ordinary disposal, insertion-observer disposal, draft-bearing history-disposal cases and native-image cleanup callback disposal passed. These two forced no-draft history cases need a framework-compatible harness/control before claiming complete synchronous-disposal coverage.

The earlier exploratory pixel harness also attempted an unsupported transform-through-replacement command, which correctly rejected; it was changed to the actual common-transform command family. Its initial very small viewport made pure-color area assertions sensitive to filtering; final host probes used 1400 × 1400 and retained independent position/Page-clipping assertions. Development logs are retained and are not reported as successful final checks.

**Exact scope and preservation.**

Current source matches the recorded delta exactly: **8 modifications, 6 additions, no removals; 519 baseline files unchanged**. The recovered 527-file baseline agrees with the retained end-of-R2 inventory except the two documented CI report hashes; those equal the resumed inventory. This accounts for the lost initial `/tmp` inventory without substituting HEAD as a baseline. See scope.json (`/tmp/al-note-pdf-objects-independent/scope.json`, raw HDD evidence), recovery-check.json (`/tmp/al-note-pdf-objects-independent/recovery-check.json`, raw HDD evidence).

All **533 current tracked/untracked source hashes**, Git status and index entries remained unchanged across this audit. Branch remains `phase-8-pdf-system`, HEAD `921e43f41a31b0649a2ae890c993fd4e406ad39a`. Evidence: preservation-final.json (`/tmp/al-note-pdf-objects-independent/preservation-final.json`, raw HDD evidence).

I reviewed the final **924-passed/14-skipped** full-suite log, fatal-info analysis, **221-file** formatting result, Linux build and Web/Wasm build logs. All **304 recorded final-code hashes** still match current files. Interrupted suite logs were not treated as passes. Windows, Android and physical stylus/GPU/manual device acceptance were not executed. SDK signatures remain UNVERIFIED under the previously accepted checksum exception.

Documented serial-render latency, fixed/budget-reduced raster quality and full-page raster use for crops are not classified as defects. Existing Pen, zoom, Save/Reopen stalls/limits and memory-performance concerns remain fixes-milestone work. The canceled Text redesign/plugin conversion was not investigated or implemented. No Phase 8, ordinary-PDF release or publication approval is implied.
