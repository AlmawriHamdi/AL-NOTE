# Phase 8 consolidated remaining implementation

Implementation record for Main AI and independent auditor review, 2026-09-07.
This is not Phase 8 or release approval. Branch `phase-8-pdf-system`, starting
HEAD `921e43f41a31b0649a2ae890c993fd4e406ad39a`. Existing uncommitted work was
preserved. No commit, push, PR, tag, CI edit or publication was performed.

The consolidated assignment supersedes the earlier correction-only exclusions
for duplication, opacity and the narrow Android channel. Checkpoints A–D were
implemented and tested in order. Final callback inventory then found Flutter's
own disposal instrumentation; the additional A changes and affected reruns are
recorded explicitly below. E is assessment only.

## A — Complete compound publication

Both supplied probes were first run unchanged and failed as reported:
`/tmp/al-note-phase8-A-reproduce-picture.log` and
`/tmp/al-note-phase8-A-reproduce-disposal.log`. The first observed the new PDF
with the notebook's saved state; callback Reopen was overwritten. The second
synchronously finalized the tree and installation resumed into a disposed Pen
preview notifier.

The cleanup path had external notifications inside owner installation. Canvas
now detaches old resources, closes/detaches the editor, installs coordinator,
Selection, saved pair, status and owned-fit generation, and only then delivers
cleanup, repaint, cancellation and command notifications. Four private
publication-aware notifiers update values synchronously and coalesce pending
repaint delivery into at most four slots. Deferred resource disposers are bounded
by existing retained Pen pictures, one Selection preparation, the PDF image,
existing image-cache limits, and a fixed number of editor/focus controllers.
There is no timer, polling loop, copied source buffer or unbounded request queue.

Final inventory found that Flutter 3.44.6 also invokes `Picture.onDispose` and
`Image.onDispose` synchronously before releasing their native handles. Physical
disposal of detached resources therefore occurs after installation, before app
accounting notifications. A temporary exception-catching wrapper preserves the
original hook call and native release; conditional restoration preserves any
hook replacement deliberately made by a reentrant callback. This protects
Canvas-owned cleanup, not arbitrary resources disposed elsewhere by Flutter.
Controller disposal, including framework allocation instrumentation, is also
deferred through the bounded batch. Notifier base disposal happens exactly once,
after active listener dispatch returns when necessary.

`_closing` makes retained actions inert during teardown, including the period
when Flutter still reports `mounted`. Delivery attempts each detached resource,
accounting notification and cancellation independently. Repaint delivery skips
disposed notifiers. Installation has no subsequent owner writes after delivery.
Owned-fit callbacks check coordinator, page and generation; Save, Reopen, tool
change and zoom invalidate obsolete fitting. Existing draft preparation,
intended commit identity, UUID/history behavior, guarded companion publication,
retained Reopen snapshots, cancellation and stale-result checks remain in place.

### Installation/teardown callback inventory

| Path | Handling |
| --- | --- |
| Pen frozen pictures, compaction remnants, Selection preparation picture | Detached before publication; native disposal and accounting delivered afterward; one accounting event per owned picture. |
| `ui.Picture.onDispose`, `ui.Image.onDispose` | Called only after complete installation for detached Canvas resources; exceptions cannot prevent native release; callback reassignment is preserved. |
| Pen frozen-layer value, Pen overlay, Pen cursor, eraser cursor position | Four fixed notifier slots; complete values before listeners; disposed/reentrant notifier lifecycle handled. |
| Inline TextEditingController/FocusNode, Canvas zoom/focus teardown | Own listeners removed, editor references/draft detached; actual disposal deferred during compound publication. |
| Selection cancellation, modifier/transient cleanup, router cancellation | Plain owner state/coalescing changes; Selection resources use the same batch. |
| setState, viewport/owned-fit registration | Synchronous owner state completed before delivery; scheduled fitting checks ownership/generation. |
| PDF open/render and image decode cancellation tokens | Controllers detached first; captured cancellation attempts after owner installation or teardown; listener exceptions do not skip other controllers. |
| Old-document command observers | Existing coordinator guard and `publishCompanionState` ordering retained; all owner publication and cleanup precede command observers. |
| Synchronous tree disposal from any delivered callback | `_closing`, detached resources, deferred notifier base disposal, and no obsolete publication tail. |

Scope: `lib/ui/canvas/phase6_canvas.dart`, `test/widget_test.dart`, and new
`test/support/pdf_cleanup_publication_checks.dart`. Canvas and widget test also
contain C changes; no coordinator implementation was changed in this assignment.
Initial checkpoint hashes: `/tmp/al-note-phase8-A-scope.json`; final combined
hashes: `/tmp/al-note-phase8-consolidated-scope.json`.

Evidence:

- Initial A correction: 32 focused tests and both unchanged probes passed.
- Final additions: 22 Pen/Selection/native-image cleanup cases. Pen and Selection
  each cover app-observer Reopen/Save/throw/dispose/repaint and native-hook
  Reopen/Save/throw/dispose. Four image-hook cases cover the same retained actions.
  Assertions include authoritative state captured inside callbacks and checked
  afterward, exact notification prefixes, balanced picture counts, unique native
  disposal, saved-buffer retention and unchanged old history.
- Final combined affected selection: **49 passed**, including actual production
  guard recovery/navigation/zoom, draft atomicity, command/cancellation ordering,
  cleanup and source-style tests. Log: `/tmp/al-note-phase8-A-final-focused.log`.
- Both original probes passed unchanged against the final production source:
  `/tmp/al-note-phase8-A-picture-verified.log` and
  `/tmp/al-note-phase8-A-disposal-verified.log`, one pass each. The picture probe
  reports new PDF/null saved state at callback, final notebook/notebook saved
  state and retained saved bytes. Disposal probe has no disposed-controller error.
- Native-hook test assertions were subsequently moved outside the protected
  callback so caught observer exceptions cannot hide failed assertions. These
  strengthened tests are included in the consolidated full suite below.

Limit: callbacks can intentionally perform further actions; the batch guarantees
bounded work for its own captured cleanup and does not constrain arbitrary user
callback recursion. Framework resources outside Canvas ownership are outside this
cleanup wrapper. No parser-isolation change was made.

## B — Annotated PDF duplication

`PdfSourceLayer` has no Objects, but Page/Section duplication passes a shared
remapping table containing sibling annotations. Rejecting any nonempty table
incorrectly rejected valid annotated PDF subtrees. The source branch now ignores
unrelated object mappings and uses existing `withIdentity`, retaining the exact
immutable reference. Existing allocation/collision/annotation remapping remains
unchanged.

Scope: `lib/documents/model/document_duplication.dart` and
`test/documents/phase8_pdf_test.dart`.
`/tmp/al-note-phase8-B-scope.json` records checkpoint hashes.

**47 focused tests passed** across the PDF model and existing duplication suite:
`/tmp/al-note-phase8-B-focused-final.log`. New coverage duplicates an annotated
page and a two-page section, checks distinct page/layer/object IDs, remaps
annotation references across the section, preserves original objects/state and
source invariants, shares one PDF resource, and validates a package round trip
containing originals plus copies. Existing PDF Object/source schema and
crop/resolved-bounds package tests remain green.

No duplication UI or new duplication semantics were introduced.

## C — Source visibility and opacity

The Canvas image/placeholder branch omitted the source Layer's common style.
It now passes the current `PdfSourceLayer` into the painter and its repaint
comparison. A small source-only painting function skips hidden/zero-alpha
sources and applies fractional alpha to a single image/placeholder group.
Placeholder diagonals and their background receive group alpha once at overlap.
Annotations are painted outside that group. Source opacity does not enter the
PDF raster key because styling changes do not change raster contents; current
Layer state controls painting/repaint, and replacement still invalidates the old
image cache.

Scope: `lib/ui/canvas/phase6_canvas.dart`, new
`lib/ui/canvas/pdf_source_paint.dart`, `test/widget_test.dart`, new
`test/support/pdf_source_style_checks.dart` and
`test/drawing/pdf_source_paint_test.dart`.
Checkpoint hashes: `/tmp/al-note-phase8-C-scope.json`.

**10 focused tests passed**: `/tmp/al-note-phase8-C-focused-final.log`.
Eight pixel cases cover image and unavailable placeholder × full/fractional/
zero/hidden styles, independently opaque annotation pixels, and placeholder
intersection pixels. Expectations account for quantized 8-bit alpha, allowing
one channel level for raster rounding. Two actual Canvas cases cycle styles,
Save/Reopen and replacement cache invalidation while preserving annotation
pixels and the exact saved source style.

**8 pixel cases passed in real Chrome** through Flutter's browser test runner:
`/tmp/al-note-phase8-C-browser.log`. No layer-editing UI was added.

## D — Bounded Android reader

The prior Android picker eagerly copied provider content before Dart could
apply its budget. The app now registers a private
`alnote/pdf_fixture_reader` channel in the existing MainActivity. Its native
reader launches single `ACTION_OPEN_DOCUMENT`/`CATEGORY_OPENABLE` selection and
keeps the URI only in a native opener closure. It never queries provider size,
gets a filesystem path, persists URI permission or copies to a cache file.

The interface supplies the budget when reading begins, because the existing
portable picker contract selects before `openRead` receives its budget. Native
selection does not open/read provider content. First read fixes the session's
budget; later reads must match it. Native and Dart enforce 64 KiB chunks and a
50,000,000-byte ceiling (the current app limit); native uses
`min(64 KiB, remaining + 1)` and an actual one-byte EOF/overflow probe. Short reads
may make one additional bounded chunk copy. No full-file accumulator exists in
the native/bridge layer; the unchanged portable selector owns bounded capture.

One slot covers pending picker, opened source, active read and closing work.
One reader executor performs blocking open/read/normal EOF/error close; a second
closer can interrupt a blocked read without blocking the UI thread. No next
session enters until old physical read and close finish. Cancellation detaches
callbacks/streams, drops late data and closes once. A cancelled outstanding
picker reserves its slot until its activity result arrives, preventing request
code reuse from misattributing late results. Teardown cancels callbacks and
shuts down executors after queued work. Invalid owners, exact argument shapes,
non-integer budgets/sequences, stale IDs and duplicate/out-of-order reads reject
with fixed redacted errors.

Scope:

- `android/app/src/main/kotlin/io/github/almawrihamdi/alnote/MainActivity.kt`
- New sibling `PdfFixtureReader.kt` (channel and directly tested transfer core)
- `lib/documents/pdf/src/file_selector_local_pdf_adapter.dart`
- New `lib/documents/pdf/src/local_pdf_picker_android.dart`
- `test/documents/pdf_host_io_test.dart` (Android routing assertion only)
- New `test/documents/pdf_host_android_test.dart`
- New `test/native/PdfFixtureReaderTest.kt`
- New `tool/check_pdf_android_native.py`

Checkpoint hashes: `/tmp/al-note-phase8-D-scope.json`; final formatting/import
cleanup is represented in the consolidated manifest. No dependency, Gradle
configuration, plugin or vendor patch was added.

**14 native JVM cases passed** against the actual production Kotlin transfer
core, compiled with cached Kotlin/Android/Flutter artifacts:
`/tmp/al-note-phase8-D-native-final.log`. Cases include empty/exact/over-budget,
64 KiB and short reads, throwing reads, wrong owner/ID/order/budget/argument
types, one in-flight request, late picker completion, cancellation during open
and read, teardown, exactly-once close, and 100 rejected new selections while
both read and close remain blocked. Thread observations verify blocking work
runs off the caller thread. No size metadata is read, so null/false sizes cannot
affect allocation. Tests inject stream factories, not real ContentProviders.

**28 focused Dart/host tests passed** (including 12 new bridge cases and existing
Linux/portable selector cases): `/tmp/al-note-phase8-D-focused-final.log`.
They establish bounded sequential typed transfers, duplicate-handle rejection,
malformed/oversized responses, cumulative ceilings, late selection/read
cancellation, exactly-one close, redaction and no eager Android plugin call.
Android factory routing was enabled only after the native and bridge tests passed.

Limits: no Android emulator/device, real ContentProvider, native file-dialog or
permission-lifecycle execution is claimed. Android framework wiring is source
inspection plus the APK build below. A provider that never returns from both
read and close can keep the single slot unavailable; it cannot grow threads,
queue, retained transfers or publish late bytes. Releasing such a stuck provider
would require stronger process isolation, outside this bounded reader change.

## E — Ordinary-PDF readiness (assessment only)

Opening an arbitrary locally selected file remains intentionally blocked. The
unchanged fixture admission compares exact immutable bytes to the reviewed
fixture set; selection does not confer trust. Release composition remains
quarantined. Bounded selection, corrected application behavior and passing
fixture tests are necessary but do not establish hostile-parser safety.

Remaining decisions, separated by responsibility:

1. **Native artifact authentication and source correspondence.** The unchanged
   cached `pdfium_dart 0.2.5/hook/build.dart` selects `chromium/7811`, downloads
   a third-party target archive and accepts an existing output without comparing
   an authenticated expected digest. Local inventory hashes document observed
   bytes only. The distributor identifies this as
   [PDFium 149.0.7811.0, released April 27, 2026](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F7811).
   Smallest next proposal: approve one exact reviewed engine build/source set,
   authenticated expected per-target hashes, fail-closed verification of cached
   and downloaded binaries, and matching bundled third-party notices. A package
   archive hash alone cannot authenticate those separate native downloads.
2. **Known upstream engine vulnerabilities.** Google subsequently published
   PDFium use-after-free fixes, including CVE-2026-17875 and CVE-2026-18012 in the
   [July 29, 2026 Chrome 151 security update](https://chromereleases.googleblog.com/2026/07/stable-channel-update-for-desktop_0887107924.html).
   These are concrete upstream advisories, not a claim that every advisory's
   vulnerable code path is present/reachable in AL NOTE's exact native or WASM
   build. Exact fix-commit/build-feature correspondence remains unverified.
   Smallest next proposal: review the selected native and WASM source revisions
   against those fixes and current advisories, approve a patched pinned build,
   then rerun the accepted geometry/cleanup/admission regressions. Authentication
   and engine patch level are separate gates.
3. **Containment and enforceable resource ceilings.** The app's native adapter
   invokes PDFium in-process. Dart cancellation, one-operation admission and
   output/byte limits do not forcibly stop native parsing or bound all parser
   allocations. Chromium's own security record describes
   [separate PDFium hardening and process sandbox controls](https://www.chromium.org/Home/chromium-security/quarterly-updates/).
   A library embedding does not inherit Chrome's renderer sandbox. Smallest
   proposal: review a narrow worker-process boundary with no ambient file/network
   authority and enforceable memory/time termination on native targets; separately
   review worker/WASM memory, termination and browser messaging capabilities.
   Keep the current portable backend contract where possible.
4. **Application correctness and target evidence.** A–D address the scoped
   defects; the accepted geometry, precision, cancellation, immutable identity
   and stale-result checks remain. Before ordinary-input enablement, independently
   review this diff, exercise real Android providers and lifecycle races and the
   unexecuted Windows route, and add a bounded adversarial corpus for the approved
   engine/containment configuration. Do not treat fixture coverage as exhaustive
   PDF compatibility or hostile-input validation.

No engine upgrade, new dependency, admission removal, parsing-policy change or
containment implementation was made. The proposed route needs separate approval.
Upstream assessment sources were checked on 2026-09-07; no exhaustive CVE or
binary vulnerability audit is claimed.

## Consolidated verification and preservation

Final results:

| Check | Result | Evidence |
| --- | --- | --- |
| Authored Dart formatting | 12 files; final check zero changes | `/tmp/al-note-phase8-final-format-check.log` |
| Fatal-info analysis | Passed, no issues; passed again after native refinement | `/tmp/al-note-phase8-final-analysis.log`, `/tmp/al-note-phase8-post-suite-analysis.log` |
| Consolidated full Flutter suite | **815 passed**, one full-suite invocation, 2m20s | `/tmp/al-note-phase8-final-full-test.log` |
| Linux debug | Passed after regenerating missing generated engine outputs | `/tmp/al-note-phase8-final-linux-retry.log` |
| Web | Passed, including Wasm dry run | `/tmp/al-note-phase8-final-web-build.log` |
| Android debug APK | Passed against final Kotlin source | `/tmp/al-note-phase8-final-android-verified.log` |
| Real Chrome source pixels | **8 passed** | `/tmp/al-note-phase8-C-browser.log` |
| Final native JVM regression selection | **17 passed** | `/tmp/al-note-phase8-D-native-verified.log` |
| Post-suite affected Dart/host selection | **28 passed** | `/tmp/al-note-phase8-D-post-suite-tests.log` |
| Whitespace/Python | `git diff --check`, Kotlin/Python trailing whitespace and Python syntax passed | Final scope/status manifests |

The full suite contains the final Dart source and strengthened native-hook
assertions. After it passed, final lifecycle review refined **only**
`PdfFixtureReader.kt` and `PdfFixtureReaderTest.kt`: one process-wide admission
lease survives Activity recreation until old physical read/close completion,
and picker request codes are never reused during the process lifetime (range
exhaustion fails closed). A new Activity cannot mistake an old Activity's late
result for its own selection. Failed activity launch clears the pending code and
releases admission. Added JVM cases cover these paths, including 100 rejected
attempts from a new transfer instance while the old disposed instance remains
blocked. The final 17-case JVM run, 28 affected Dart/host tests, fatal-info
analysis and Android APK build were rerun afterward. **The full suite, Linux
build and Web build were not rerun after that native-only refinement.** This is
not a claim that the Dart full suite executes Android framework code.

The first Linux attempt failed because both cached `unpack_linux.stamp` files
claimed 28 outputs that were all missing. Only these generated stamps were
backed up under `/tmp/al-note-phase8-linux-stamp-backup` and invalidated; the
normal Flutter build regenerated headers/engine files and passed. No Linux
source or dependency changed. The first Android build also passed; its second
build was necessary to verify the subsequent native lifecycle refinement.
Web's existing nonfatal missing CupertinoIcons font warning remains. No Kotlin
formatter dependency was introduced: Kotlin was checked for whitespace and
compiled by both the JVM harness and Android build.

Machine-readable initial commands/exit codes: `/tmp/al-note-phase8-verification.json`.
All Flutter commands execute through `distrobox enter al-note-dev --`, with
Flutter 3.44.6 / Dart 3.12.2 and `--no-pub`.

Reproducible focused commands:

```sh
flutter test --no-pub /tmp/al-note-correction2-observer-independent/picture_probe_test.dart --plain-name 'audit picture cleanup'
flutter test --no-pub /tmp/al-note-correction2-observer-independent/picture_disposal_probe_test.dart --plain-name 'audit picture cleanup'
flutter test --no-pub test/widget_test.dart --name 'PDF cleanup publication|PDF native image cleanup|PDF compound|PDF admitted|PDF production guard|PDF waiting|PDF source'
flutter test --no-pub test/documents/phase8_pdf_test.dart test/documents/replacement_duplication_test.dart
flutter test --no-pub test/drawing/pdf_source_paint_test.dart test/widget_test.dart --name 'PDF source'
flutter test --no-pub --platform chrome test/drawing/pdf_source_paint_test.dart
python3 tool/check_pdf_android_native.py
flutter test --no-pub test/documents/pdf_host_android_test.dart test/documents/pdf_host_io_test.dart test/documents/pdf_file_selection_test.dart
```

The consolidated baseline and final before/after SHA-256 manifest are
`/tmp/al-note-phase8-consolidated-baseline.json` and
`/tmp/al-note-phase8-consolidated-scope.json`. They separate this assignment from
all earlier uncommitted work. The exact scope is the union of A–D paths above
plus this report (17 files). Shared Canvas/widget paths are counted once.
No baseline file was deleted. All **433 other baseline paths**, including vendor files,
fixture corpus/admission, Linux/Web host implementations, backend guard,
coordinator, dependency versions/lockfile, geometry/precision and CI, retain their
hashes. No unrelated vendor or host audit was repeated; existing maintained tests
remain part of the full suite.

Final Git status (expanded untracked files): **241 tracked modifications, 182
untracked files, zero staged changes**, 423 entries. Starting status was 241/172/0;
this assignment added ten files and changed seven existing baseline files.
All 440 baseline files still exist. Final inventory contains 450 files. Branch
and HEAD remain exactly as recorded above. Expanded status:
`/tmp/al-note-phase8-final-git-status.json`.

No Windows execution, Android emulator/device or real provider execution is
claimed. No unrelated vendor/host audit, whole-suite repeat, dependency upgrade
or release/untrusted-input enablement was performed. Main AI and independent
review remain required.
