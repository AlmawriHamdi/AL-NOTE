# Movable PDF page Objects

Implementation handoff for Main AI and independent review. This adds movable
Objects to notebooks; it does not declare Phase 8 complete or enable release PDF
admission. Flutter 3.47.4 / Dart 3.13.3 is the adopted toolchain. Branch and HEAD
remain `phase-8-pdf-system` / `921e43f41a31b0649a2ae890c993fd4e406ad39a`.

**F1 follow-up:** destination-Page-clipped interaction is corrected in the
[separate correction handoff](phase8-pdf-objects-f1.md). The scope and test totals
below describe the original feature implementation.

## Scope

**Insert PDF page** is separate from Open PDF and Import PDF pages. The existing
bounded picker, source ownership/admission and backend inspection prepare the
source. The user chooses `all` or one-based pages/ranges. Selected pages are
deduplicated and sorted in source order. Each becomes an independent
`alnote.pdf.page` schema-1 Object on the current content layer.

- `lib/documents/pdf/pdf_object_insertion.dart` prepares a bounded
  `AtomicObjectCollectionEditRequest` without document mutation. It validates
  notebook/Page/layer eligibility, selection, resource identity/digest/metadata,
  operation capacity and UUID collisions. It captures Page, layer, membership and
  resource-catalog revisions. The existing coordinator validates the complete
  candidate and history budget, then publishes resource plus all Objects once.
- New Objects fit within 72% of each Page dimension while preserving aspect
  ratio. Placement begins at 8% of Page width/height, with source-order diagonal
  offsets no greater than 16 points per Object and 12% of the shorter Page side
  in total. Position, scale and rotation live only in the common transform;
  source box, rotation, dimensions and reference remain unchanged.
- Existing resource identity and exact digest/metadata reuse the destination's
  immutable bytes. One Undo removes the complete insertion; Redo restores the
  exact Objects, references and resource. Live drafts, existing Selection and
  saved checkpoints are retained. Immediate insertion Undo/Redo preserves the
  draft using the existing notebook-import companion-publication mechanism.
  Synchronous observers run after UI ownership is settled, with no success-tail
  writes over reentrant Save/Reopen/disposal.
- PDF rendering and precise transformed bounds-based hit testing are registered
  alongside existing Object types. Whole Eraser adds PDF to its existing
  supported built-in list and retains Registry, visibility and lock checks.
  Common move/resize/rotate and multi-selection need no new command family.
- `pdf_object_paint.dart` paints actual native PDF images. The normalized clip
  selects a source-image rectangle and rebases it to the existing cropped local
  bounds, before the common transform and Page clipping. No backend crop
  capability or source-geometry rewrite was introduced.
- Per the user's explicit decision, opacity follows the existing layer setting.
  Object visibility stays independent. No schema field, opacity control, parser
  fallback, password flow, extraction, export or dependency upgrade was added.

The incremental source scope is **8 modified existing files, 6 added files,
zero removals, 519 unchanged baseline files**. The modified paths are the PDF
README, rendering scene and content-rendering registries, content hit testing,
Whole Eraser gesture plans, Canvas/runtime, and the widget-test entry point.
The additions are the insertion preparer, PDF Object paint helper, domain and
pixel/hit-test files, widget regression support, and this report. No coordinator,
model/schema, source capture, backend, worker, native binary, package pin,
dependency/lockfile, CI or storage implementation changed.

## Render ownership and bounds

Canvas now drains one bounded current-Page interest set sequentially for both
source layers and movable Objects. It replaces obsolete interest rather than
accumulating requests per frame. Only one Canvas render/image-preparation chain
is active. The unchanged backend scheduler retains cleanup ownership and handles
transient contention. Cancellation, owner/Page replacement, exact source-byte
identity and current reference are checked before image publication. Disposal
first detaches all ownership, then releases native images and cancellation
callbacks through the existing publication boundaries.

Images are shared by full `PdfPageReference`, immutable byte identity and raster
dimensions, independently of Object UUID, crop and common transform. At most
`min(maximumHitResults, maximumRenderPixels)` distinct references are retained;
production values are 10,000 references and 16,777,216 aggregate image pixels.
Each reference receives an equal share of that pixel ceiling and also obeys the
existing 4,096 dimension ceiling. A cancelled old in-flight result and bounded
backend/image handoff can temporarily coexist with the current cache; the pixel
ceiling is a cache bound, not a total-process RSS guarantee. Failed requests are
cached as placeholders for that interest/byte identity, with no polling or
infinite retry. The Page/resource revision cache avoids rebuilding the interest
set for each zoom/hover/frame.

Rendering remains serial and at no more than one pixel per PDF point before
budget downscaling. Many distinct pages reduce image resolution and increase
completion latency. Cropping uses a full-page raster. Zoom-dependent quality,
viewport prioritization and performance fixes are not claimed here. Opening
still permits up to 50,000,000 encoded bytes; the separate production history
budget and storage ceilings remain 10,000,000 bytes. A source that opens can
therefore be rejected for insertion/history or in-memory Save. Selection parsing
allows up to 1,000 source pages, within the existing 1,024 command-operation
ceiling including a new resource when needed. Preparation yields every 32 Objects.

**Save/Reopen is in-memory, not durable export.** The prior 8 MB Reopen stall
(2.20 s), 50 MB rejected Save stall (4.69 s), and 2.21 GB process high-water RSS
across that earlier run remain unresolved. This change is not evidence that the
Pen, zoom, Save/Reopen or other deferred performance work is fixed.

## Verification

All results below were personally executed. Evidence is retained under
`build/pdf-object-review/`; paths are relative to the repository.

| Check | Result and evidence |
| --- | --- |
| Final complete Flutter suite | **924 passed, 14 expected host/private skips**, 3m46s. One completed full run at the final Dart source state; [log](../../build/pdf-object-review/full-suite.log). |
| Focused insertion, geometry/crop pixels, prior opening/import and cleanup | **79 passed** before the final review corrections; [log](../../build/pdf-object-review/focused-final.log). The domain/crop subset contains 10 cases. |
| Toolbar, layer eligibility, unknown schema/layer inertness and affected existing flows | **71 passed** after those corrections, including the unchanged Selection resize/zoom regression; [log](../../build/pdf-object-review/focused-after-review.log). |
| Final detached-key cleanup, repeated cancellation and synchronous observers | **30 passed** after the last code edit; [log](../../build/pdf-object-review/final-cleanup-focused.log). All subsequently passed in the final full suite. |
| Tight aggregate cache ceiling and repeated source reuse | **1 passed** with a 900-pixel ceiling and repeated insertion sharing the same two rasters; [log](../../build/pdf-object-review/cache-budget.log). Included again in the final full suite. |
| Final formatting and fatal-info analysis | **221 Dart files, zero formatting changes; no analysis issues**; [format](../../build/pdf-object-review/format-check.log), [analysis](../../build/pdf-object-review/analysis.log). |
| Linux private debug build | **Passed**, using the unchanged reviewed package; [log](../../build/pdf-object-review/linux-build.log). |
| Web release and Wasm dry run | **Passed**; [log](../../build/pdf-object-review/web-build.log). This checks the new shared scene/UI primitive across the Web compiler; ordinary-PDF admission remains disabled. The existing nonfatal CupertinoIcons font notice remains. |
| Final actual-host PDF checks after builds | **5 passed**: movable Object pixels/Save-Reopen/disposal, notebook import/annotations/recovery, live-draft standalone open, missing-package rejection, and in-flight disposal; [log](../../build/pdf-object-review/host-final.log). |
| Package/source preservation and final host cleanup | All **114 canonical and installed resources** verified under unchanged manifest `82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298`; [installed verification](../../build/pdf-object-review/package-installed.log). **Zero worker units and zero owned processes executing from PDF stages**; [inventory](../../build/pdf-object-review/final-host-cleanup.json). |

The actual-host Object test sends an ordinary, untrusted PDF through the approved
isolated backend, then paints its native image through the production Canvas.
The red and blue marks have source centers `(25, 752)` and `(80, 727)` on a
612 × 792 page; their Canvas centroids match the common transform within two
screen pixels. Reopen restores the exact root and native rendering. This is
automated Flutter/native-image evidence, not manual GPU/device acceptance.

Two earlier suite attempts were deliberately interrupted and are **not full-suite
passes**. The first exposed the new button's toolbar grouping error, which moved
Zoom In off-screen; the document-control count was corrected without changing
zoom semantics. The layer review also added a disabled/rejected insertion path
for unavailable editable layers and kept unknown schemas/layers inert. A second
attempt was interrupted to clear the detached render key as well as images,
preventing an idle replacement Canvas from retaining old source bytes. The
interrupted logs remain as `full-suite-interrupted.log` and
`full-suite-interrupted-cleanup.log`; SIGINT produced incomplete-test/finalization
messages. The completed final run came after all corrections. **No Dart source
changed after that run began**, verified by `final-code-hashes.json`. Two
nonfatal missed-tap warnings for `zoom-input` also occur in the retained
pre-feature `build/sdk-ci-r1-r2/fresh-full-suite.log`; both tests still pass.
Their assertions and the existing zoom-input behavior were not weakened.

The existing standalone functional host check logged 2,035 ms to first image
and 1,705/1,643/1,540 ms for navigation/zoom completion. These single-run
diagnostics are not a controlled performance comparison or an event-loop/RSS
benchmark. No performance improvement is claimed.

Source-scope evidence is in `source-changes.json`. The initial session's `/tmp`
logs/inventory were cleared between sessions. The baseline hashes were recovered
from the retained 527-file end-of-R2 inventory, using resumed hashes for the two
unchanged CI reports finalized after that inventory. All affected checks were
rerun with retained logs. The engine, worker, guard, transport, dependencies,
lockfile, CI and admission sources remain unchanged. Generated Flutter build
outputs were refreshed normally; protected PDF sources and rollback resources
were not cleaned or removed.

No Android/Windows build or physical device/stylus test was run for this feature.
No unchanged engine build, broad engine/security audit, or publication was
repeated. Web compilation was justified by the shared renderer/UI changes;
it is not Web ordinary-PDF runtime approval.

## Auditor commands and manual acceptance

From `/home/Hamdi/Projacts/AL-NOTE`, with the existing verified fixture and isolated
packages provisioned as documented in `sdk-347-ci-resource-publication.md`:

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && /home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub --concurrency=1 test/documents/pdf_object_insertion_test.dart test/drawing/pdf_object_rendering_test.dart test/widget_test.dart --name "PDF Object|Notebook PDF import|PDF production guard|PDF waiting render|PDF permanent guarded|PDF cleanup publication"'
/home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true test/widget_test.dart --name 'private Linux PDF Objects|private Linux notebook PDF import|Linux integrated'
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && /home/Hamdi/Development/flutter-3.47.4/bin/flutter build linux --debug --no-pub --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true'
python3 tool/linux_pdf/verify_package.py build/linux/x64/debug/bundle/data/pdf_linux
```

Build in `al-note-dev`; exercise the isolated backend on the actual systemd host.
Launch that private debug bundle from the host:

```sh
cd /home/Hamdi/Projacts/AL-NOTE
./build/linux/x64/debug/bundle/al_note
```

1. In a notebook with notes or a live text draft, choose Insert PDF page; select
   an ordinary local PDF and pages `3, 1-2`. Expect three independent Objects in
   source order, one shared resource, and retained notes/draft.
2. Use Fit Page if needed to see the whole notebook Page. Move, resize and rotate
   one Object and a marquee selection; check content orientation and hit testing.
3. Undo/Redo the transform and insertion. Whole Eraser removes the Object while
   respecting existing visibility/locking; Undo restores exact content.
4. Save in memory, Reopen saved, and check pixels/geometry. Cancel a picker/page
   selection and verify that content, draft and history are unchanged.
5. Recheck standalone Open PDF and Import PDF pages. Closing/disposal during
   rendering must not publish stale images or leave worker ownership behind.

Windows and physical device/stylus execution are not claimed. No Android PDF,
ordinary Windows/Web PDF, release admission, commits, pushes, PR changes, tags,
merges or publication are part of this implementation. Independent review and manual acceptance remain
separate from automated verification.
