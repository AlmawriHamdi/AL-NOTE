# Phase 8 correction 2: fixture admission and bounded host reading

Only Correction 2 is implemented here. The starting branch is
`phase-8-pdf-system`, HEAD `921e43f41a31b0649a2ae890c993fd4e406ad39a`.
Correction 1's geometry, numerical reconciliation, saved mapping and vendor Web
initialization cleanup are preserved. The initial source hash snapshot is
`/tmp/al-note-correction2-baseline.json`.

## Admission and limitations

The immutable compiled registry in
`lib/documents/pdf/src/reviewed_pdf_fixture_digests.dart` admits exactly 45 locally
generated controlled byte sequences. Their bytes, lengths, SHA-256 values and
provenance are retained under `test/fixtures/phase8/admitted/`. Forty are the
independently approved Correction 1 marked geometry matrix; four are existing
blank adapter controls; one is an explicitly truncated corruption control.
Disjoint/truncated fixtures are admitted negative controls which the engine
must reject. The maximum corpus member is 605 bytes.

There is no automatic enrollment, mutable policy, user setting, document field
or registry-writing tool. Digest membership establishes identity against this
reviewed corpus; it does not establish that arbitrary content or PDFium is safe.
The public trust enum is only a requested processing mode. Neither a caller's
flag nor a serialized trust/digest claim authorizes parsing.

The open workflow checks the captured immutable bytes before calling inspect.
The canvas checks immutable resource bytes before calling render. The production
factory wraps its private parser in `DevelopmentFixturePdfBackend`, which
independently verifies the exact immutable `PdfResourceBytes` snapshot before
forwarding inspect/render, including calls made outside the picker workflow.
The inner reader returns that same snapshot, so a second mutable resource read
cannot substitute different bytes. Resource UUID and computed/claimed resource
digest are never accepted instead of byte verification.

No admission evidence is serialized or cached by resource UUID. Save/Reopen
revalidates reconstructed bytes. Canvas image reuse requires the identical
immutable source byte object plus the reference and render dimensions; changed
bytes invalidate the key, and a stale render completion also checks byte identity
before publication. Unknown or one-byte-modified content remains quarantined.
Release application composition continues to use `QuarantinedPdfBackend` and
never enables the fixture-opening workflow.

The app bar prominently says development PDF fixtures only and that other files
stay quarantined; the compact Fixtures button preserves toolbar space. Rejection
leaves document/history/revision/selection state unchanged. Picker/admission
rejection consumes no user UUIDs. Later replacement/draft preparation can consume
unpublished UUIDs through the existing non-transactional generator; these are not
rolled back or reused. Pending inline text is committed only after replacement
preparation and a final current-state check; a picker lifecycle transition while
admission is pending does not commit the draft. The follow-up record below
corrects two independently reproduced defects in the original implementation.

## Actual pinned platform boundaries

No dependency, plugin/native source or platform channel was added or upgraded.
The retained file_selector graph remains pinned. Public APIs were inspected:

| Platform | Inspected source and current behavior | Evidence level |
| --- | --- | --- |
| Linux | `file_selector_linux 0.9.4+1` returns GTK filenames; AL NOTE opens one read-only `RandomAccessFile` and reads bounded chunks. | Pinned Dart/C++ source inspection plus actual Linux filesystem reading/cancellation tests; dialog selection is mocked in those tests. |
| Windows | `file_selector_windows 0.9.3+6` obtains `SIGDN_FILESYSPATH` from the system dialog; same Dart read-only reader. | Pinned Dart/C++ source inspection. No Windows machine/build was exercised. |
| Web | Pinned `file_selector_web 0.9.5` creates object URLs; `cross_file 0.3.5+5` hydrates the URL and materializes an unbounded slice with FileReader by default. AL NOTE bypasses this content path using standard input/File/Blob/FileReader APIs via `dart:js_interop`. | Real Chrome instrumented production adapter; no new package or vendored plugin patch. |
| Android | Pinned `file_selector_android 0.5.2+10` allocates `new byte[size]` from provider metadata, calls `readFully`, and then makes a full cache-file copy. Its public API accepts no byte budget. | Java/Dart source inspection and Dart test proving the route is unavailable before the picker is called. No native/device bounded reader is implemented or claimed. |

Unsupported routes, including Android, are rejected by the platform factory;
the IO adapter also guards against invoking a non-desktop picker. Main app
composition disables the button before host invocation, with an explicit
bounded-reader-unavailable status. **Disabling Android is not implementing
Android Open PDF.** The design below needs Main AI authorization.

Desktop content length is never consulted. Each read requests at most 64 KiB,
or remaining budget plus a one-byte overflow probe, whichever is smaller.
Short reads advance by actual delivered bytes; EOF is a zero-byte delivery.
The file handle closes in `finally` on success, failure and cancellation. AL NOTE
creates no source disk/cache copy and exposes no selected path to its contracts.
An in-flight OS file read or native dialog cannot be forcibly interrupted using
the current public API; cancellation prevents later reads/publication and closes
the file when the bounded in-flight operation completes. This is cooperative
cancellation, not a host-time limit.

Web selects a File directly without an object URL, XHR, path hydration or full
FileReader read. Reported Blob size can reject early, never grant trust or stop
actual counting. Blob slices request at most 64 KiB or remaining budget plus one;
actual ArrayBuffer lengths are counted independently. Even falsely small size
metadata cannot bypass the ceiling. Reader cancellation calls `abort`; all
reader/input listeners are removed and the input element is removed on every
completion/error/cancellation. Modern browser `cancel` events represent dialog
cancellation. There is no app-created source disk copy.

## Application-owned buffering bounds

Let B be the configured selection budget (50,000,000 bytes in main), C = 65,536
bytes, and A = 605 bytes (largest admitted fixture). There is one selection/capture
in flight per selector and one inspect/render operation per production backend;
concurrent selections/inspections fail with fixed outcomes. A contending render
retains one cancellable latest interest and waits for completion, before source
capture or parser work. Superseded interests complete as cancelled; no source
copies or parser operations are queued.

The host reads at most C bytes per request and at most B+1 actual bytes before
EOF/overflow rejection. A Web size > B rejects without a read. Platform-to-Dart
ArrayBuffer conversion can contribute one extra C-sized view/copy. Capture owns
packed octets, coalesced into fixed blocks, not growable integer lists or one
retained object per hostile short chunk. At most ceil(B/C) blocks are retained.
Flattening can briefly retain blocks and one contiguous output: conservatively
**2B + 8C payload bytes**, plus bounded block/stream/runtime metadata, for source
selection and its bridge copies. The conservative C allowance covers the
platform buffer, optional bridge copy, current/previous stream delivery,
validated chunk copy and partially filled coalescing block; it does not assume
that a suspended async frame immediately releases its prior locals. No allocation uses a declared provider length.
This is a payload bound, not an exact VM/browser resident-memory measurement.

Unapproved captured input over A is rejected by length before hashing or document
construction. The parser gate narrows reader limits to min(request budget, A).
The resource snapshot, digest temporaries, private adapter's transient Uint8List,
Web structured-clone delivery and PDFium source backing therefore each operate
on at most A source bytes. `DocumentResource`'s existing list copies also see
only admitted A-byte input in this workflow. These are a fixed number of bounded
copies, not one arbitrary B-sized copy per parser phase. Previously saved
resources have separate receiving/storage limits; the gate cannot retroactively
bound package decoding but never forwards non-admitted bytes to PDFium.

OS file-dialog/provider caches, browser-owned File/Blob storage, browser internals,
VM metadata/GC retention, raster output and parser allocations are separate.
No claim of total process memory, time/decompression limits or untrusted parser
containment is made. Existing raster/model/storage ceilings remain unchanged.

## Smallest Android design requiring authorization

The current package's API cannot enforce the required boundary. No unrelated
plugin patch is authorized by the pdfrx vendor approval. The smallest proposed
implementation uses the existing app's Android host, with no new package:

1. Add a narrow app-owned channel in
   `android/app/src/main/kotlin/io/github/almawrihamdi/alnote/PdfFixtureReader.kt`
   and register it from the existing `MainActivity.kt`.
2. `selectOne(budget, chunkLimit)` launches a single `ACTION_OPEN_DOCUMENT`
   selection. Keep the returned URI entirely native; do not obtain a path,
   allocate from `OpenableColumns.SIZE`, persist permission, or copy to cache.
3. Open one ContentResolver InputStream/descriptor after selection. A private
   ephemeral session ID identifies it on the channel; it is never serialized.
   `readNext(session)` requests at most min(C, remaining+1) into a fixed byte
   array, counts actual bytes, detects overflow before delivery, and permits one
   read/bridge transfer at a time. Reported length is only an optional early
   rejection hint. No ByteArrayOutputStream or file copy is allowed.
4. `cancel/close`, activity detach, selection replacement, read failure and EOF
   close the native stream exactly once and remove callbacks/session maps.
   Return only fixed status codes and bounded typed byte chunks to Dart.
5. Add `lib/documents/pdf/src/local_pdf_picker_android.dart` using this channel,
   wire it through the existing platform factory, and enable Android only after
   review. Add native tests with a controlled ContentProvider for false/null
   lengths, short/throwing reads, over-budget content, cancellation and lifecycle
   cleanup, plus Dart bridge tests proving bounded transfer and no cache copy.
   Physical-device/provider tests remain a separate explicitly reported check.

Affected production files: the existing `MainActivity.kt`, one new Kotlin reader,
one new private Dart adapter, and the platform factory. Native test files and
Dart platform regression files would also be added. Dependencies: existing
Flutter channels and Android framework only. This is substantial native channel
work and therefore **requires Main AI authorization before implementation**.

## Verification record

Development checks so far:

- Original focused selection/workflow/admitted native geometry checks: 21 passed.
- Admission and actual Linux host checks: 9 passed.
- Real Chrome host-reading assertions: 11 cases passed; final runner exits zero
  after fixing a test-harness Chrome profile cleanup race.
- UI tests exposed a toolbar-width regression from the longer fixture label;
  final status is moved into the existing app bar and the action label is compact.
- Final focused admission/reading/geometry checks: **35 passed**.
- Final affected PDF UI/Save/Reopen checks: **10 passed**, including preservation
  of an inline draft across picker lifecycle changes.
- The full suite was run **once**, as requested: **735 passed, one failed**. The
  failure was the existing dependency-boundary test detecting a direct crypto
  import in the new admission class. That import was removed; admission now
  uses the existing `Sha256Digest.calculate` contract/adapter. A post-fix run of
  dependency-boundary, admission, workflow and marked geometry tests passed
  **23 tests**. The full suite was not repeated; this is not a claim of a second
  all-green full-suite execution.
- Formatting: all **20** authored/modified Dart files checked with zero changes;
  nonbinary files also passed newline/trailing-whitespace checks.
- Final `flutter analyze --no-pub --fatal-infos`: no issues.
- Linux debug app build: passed. Web release app build: passed (42.7 seconds).
- Final Web host-reading harness build: passed (40.1 seconds); actual Chrome
  production-reader checks: all 11 cases passed, runner exited zero.
- Admitted geometry Web harness build: passed (41.3 seconds). Native and actual
  Chrome results match exactly for 36 marked passes and four disjoint rejections.
  Unchanged vendor cleanup remains documents 76/76, forms 49/49, allocations
  304/304 and range availability 25/25; bridge rejection cleanup is 4/4.
- Web builds reported a nonfatal missing CupertinoIcons font-family warning;
  builds completed successfully. No font/dependency changes were made.
- Final diff check: passed. No baseline file was deleted; dependencies, CI,
  Android native source and protected Correction 1 files retain their hashes.

No full app suite has been claimed from focused tests. No Android native/device
execution or Windows execution is claimed. Builds and browser checks use Flutter
3.44.6 / Dart 3.12.2 in the existing `al-note-dev` container.

Reproducible commands (run from the repository root):

```sh
distrobox enter al-note-dev -- flutter test --no-pub test/documents/pdf_file_selection_test.dart test/documents/pdf_open_workflow_test.dart test/documents/pdf_fixture_admission_test.dart test/documents/pdf_host_io_test.dart test/documents/pdfrx_patch_test.dart --reporter expanded
distrobox enter al-note-dev -- flutter build web --no-pub --release --no-web-resources-cdn --target test/documents/pdf_host_web_main.dart --output build/pdf-host-check
distrobox enter al-note-dev -- python3 tool/check_pdf_host_browser.py --app build/pdf-host-check --output /tmp/al-note-correction2-web-host
distrobox enter al-note-dev -- flutter build web --no-pub --release --no-web-resources-cdn --target test/documents/pdfrx_web_parity_main.dart --output build/pdf-parity
distrobox enter al-note-dev -- python3 tool/check_pdf_browser.py --app build/pdf-parity --output /tmp/al-note-correction2-parity
```

## Scope and remaining blockers

The correction changes 72 files: 27 text/source/documentation files and 45
controlled PDF fixtures. The exact path/hash scope is
`/tmp/al-note-correction2-scope.json`; the full working-tree status is
`/tmp/al-note-correction2-git-status.txt`. These include no baseline deletions.
Final status: branch `phase-8-pdf-system`, unchanged starting HEAD, no staged
changes; **241 modified tracked paths and 170 untracked files** (411 entries,
including the pre-existing work and mode-only status). Correction-only changes
are 14 existing files plus 58 additions, including the 45 generated PDFs.

The 27 non-PDF paths are:

- `docs/dependency-review/README.md`
- `docs/testing-release/phase8-correction2.md`
- `lib/documents/pdf.dart`
- `lib/documents/pdf/README.md`
- `lib/documents/pdf/pdf_backend.dart`
- `lib/documents/pdf/pdf_file_selection.dart`
- `lib/documents/pdf/pdf_fixture_admission.dart`
- `lib/documents/pdf/pdf_open_workflow.dart`
- `lib/documents/pdf/src/file_selector_local_pdf_adapter.dart`
- `lib/documents/pdf/src/local_pdf_picker_io.dart`
- `lib/documents/pdf/src/local_pdf_picker_stub.dart`
- `lib/documents/pdf/src/local_pdf_picker_web.dart`
- `lib/documents/pdf/src/pdfrx_pdf_backend_adapter.dart`
- `lib/documents/pdf/src/reviewed_pdf_fixture_digests.dart`
- `lib/main.dart`
- `lib/ui/canvas/phase6_canvas.dart`
- `test/documents/pdf_file_selection_test.dart`
- `test/documents/pdf_fixture_admission_test.dart`
- `test/documents/pdf_host_io_test.dart`
- `test/documents/pdf_host_web_main.dart`
- `test/documents/pdf_open_workflow_test.dart`
- `test/documents/pdfrx_patch_test.dart`
- `test/fixtures/phase8/admitted/PROVENANCE.md`
- `test/fixtures/phase8/admitted/manifest.json`
- `test/fixtures/phase8/web_host_reading.js`
- `test/widget_test.dart`
- `tool/check_pdf_host_browser.py`

The fixture manifest lists all 45 PDF paths, lengths and hashes. The only
Correction 1 adapter changes are one import and the factory admission wrapper;
removing those two additions reproduces its starting file hash exactly. Every
vendor file, persistent PDF model, shared marked-fixture generator, prior Web
parity harness, dependency pin and CI file still matches its starting hash.
 Existing
uncommitted work is preserved. No CI, dependency versions, Flutter version,
Android implementation, pdfrx vendor file, geometry/codec mapping, annotated-page
duplication, or source visibility/opacity implementation is changed. Native
binary-download authentication and untrusted parser security remain unresolved.
No commit, push, PR, tag, publication or automatic fixture enrollment occurs.
Stop for Main AI review; this correction does not approve the whole milestone.


## Correction 2 follow-up: render recovery and draft atomicity

This bounded follow-up addresses only the two defects in
`/tmp/al-note-correction2-independent/report.md`. Baseline:
`/tmp/al-note-correction2-followup-baseline.json` (438 existing paths), same branch
and HEAD as above. Both supplied probes were run before source edits. Each
reproduced **two failures**, including the real PDFium busy render and admitted
fixture/live-draft self-rejection:

- `/tmp/al-note-correction2-followup-reproduce-production.log`
- `/tmp/al-note-correction2-followup-reproduce-controlled.log`

### Root causes and implementation

**Render:** the production admission guard returned `limitExceeded` while an
old operation was still physically active. Canvas correctly cached that failure
as a permanent placeholder, leaving the current page stranded after navigation.
The guard now distinguishes contention by waiting internally rather than
returning a permanent failure. It holds at most one pending render interest;
a newer request supersedes the previous one. Cancellation removes the interest
and its listener, including Canvas navigation and disposal. Pending requests
perform no resource capture, digest, bridge copy or parser call. Once granted,
admission runs exactly as before against the immutable captured source.

Availability checking, interest registration and cancellation are synchronous.
The operation's `finally` removes the waiter and reserves `_busy` for it **before**
completing its future. A new operation cannot steal the slot between wakeup and
resumption. Cancellation after handoff is checked before capture and releases
that reservation through the same `finally`. There is no polling, retry loop or
unbounded queue. Permanent delegate failures still complete once and retain the
existing Canvas failure cache. Reference/immutable-byte/cancellation/stale-image
checks and native image cleanup remain unchanged.

**Draft:** the old flow committed and closed an admitted live draft before
preparing the replacement coordinator, then compared the changed identity to
its own pre-picker identity. The replacement coordinator is now prepared first.
The original coordinator and content identity, operation generation, mounting
and cancellation are checked before attempting a draft commit. For a changed
draft, that same condition runs again inside the existing atomic command
publication boundary, after all fallible payload, geometry, UUID and history
preparation and before any authoritative mutation or observer notification.

The only shared command API addition is optional `execute(..., stillCurrent:)`.
False or a thrown condition rejects with a fixed state failure. It runs under
the existing reentrancy guard; ordinary commands retain their previous path.
Unchanged/empty drafts check the condition before closing. A successful draft
command intentionally advances the old content identity and consumes the
starting-identity precondition. This original follow-up installed the prepared
coordinator after command return. Independent review then proved that synchronous
observers could replace the Canvas before that return; the final observer-atomicity
correction below supersedes that ordering. Lack of an await was not an atomicity
guarantee. The old document's draft command,
history entry and observer semantics remain intact; the replacement starts its
normal history. No draft is silently discarded and no history rollback or new
transaction store is introduced.

UUID generation remains an attempted allocation, not a reversible reservation.
A successful new draft uses four UUID calls after selection (replacement
coordinator, object, correlation, content identity); an edited existing draft
uses three; unchanged/empty text uses only the replacement coordinator identity.
Cancellation at the picker/disposal consumes none. Replacement identity failure
and layout rejection consume one attempted identity. Draft identity/history
failure can consume four attempted identities while publishing no state. These
counts are explicitly asserted; the flow does not rewind the generator or
deliberately reuse its output.

### Maintained regressions

`test/support/pdf_canvas_followup_checks.dart` is a part of the existing widget
test library so it can reuse its established runtime, fixture and state-evidence
helpers without copying the auditor's entire widget suite. It includes:

- Actual production factory/native PDFium with a delayed old document load,
  repeated navigation cancellation, zoom, automatic latest-page recovery, three
  total parser entries (inspection, old render, latest render) and maximum one
  active load. Test waiting is bounded; production recovery is completion-driven.
- Controlled production guard with an old successful image returned after
  cancellation and the latest render separately delayed. No old image publishes;
  disposal cancels pending interest and suppresses later work/publication.
- Permanent `limitExceeded` remains cached through repeated zoom.
- Admitted live draft with real PDFium as well as controlled delegates: new and
  existing draft success, unchanged/empty draft, layout failure, replacement
  identity failure, draft identity failure, history rejection, picker cancellation,
  disposal, external edits during picker/replacement preparation/draft validation.
  Assertions cover authoritative root, resources, identities, revisions, dirty
  state, history, observer counts, editor text, Selection, UUID counts and old
  draft undo/redo. A rejected existing-draft open retains the original Selection
  for Escape restoration.

Admission unit tests cover 20 successive contenders with only one final source
read/delegate call, cancellation before registration/after idle reservation,
completion before a later registration and permanent failures without retries.
Coordinator tests exercise false/throwing/successful publication conditions,
observer/history atomicity and rejection of reentrant mutation.

### Follow-up verification and scope

Final follow-up evidence:

- Supplied production and controlled probes: both original failures reproduced
  in each probe before edits. The original probes have not been rerun after the
  fix; maintained equivalents include both actual production/PDFium cases.
- Focused development runs: existing PDF/picker checks 5 passed; initial expanded
  tests exposed test-harness timing assumptions, corrected by bounded waits for
  actual async completion; subsequent runs 11, 23 and 16 passed as coverage grew.
- Final focused selection: **51 passed, zero failures**, 52 seconds, including
  the two production regressions, all 20 new widget cases, the new guard and
  coordinator cases, and existing affected Text/Selection behavior. Command:
  `flutter test --no-pub test/widget_test.dart test/documents/pdf_fixture_admission_test.dart test/documents/commands/document_mutation_coordinator_test.dart --name 'PDF|picker|Text|text|publication condition|waiter|handoff|simultaneous' --reporter expanded`.
  Log: `/tmp/al-note-correction2-followup-focused-final.log`. An existing Text
  resize test emits a nonfatal hit-test warning. Its assertions pass.
- Fatal-info analysis first found only four test-import lint issues. Removed the
  redundant typed-data import and ordered imports; final
  `flutter analyze --no-pub --fatal-infos` reports **No issues found**, 2.9 seconds.
  Log: `/tmp/al-note-correction2-followup-analysis-final.log`.
- Final `dart format --output=none --set-exit-if-changed` on all seven changed
  Dart files: **0 changes**, exit 0 (0.74 seconds). An earlier attempt was rejected
  before execution because automatic approval review hit an account usage limit;
  the same check was subsequently accepted and completed. No bypass was used.
- Final full app suite: **761 passed, zero failures**, 2 minutes 11 seconds,
  `flutter test --no-pub --reporter expanded`, exit 0. Executed **exactly once**
  for this follow-up, after final code/test changes including import cleanup.
  Log: `/tmp/al-note-correction2-followup-full-test.log`. No subsequent code/test
  fix or affected-test rerun was needed. Documentation-only updates followed.
- Linux debug build: `flutter build linux --debug --no-pub`, **passed**, exit 0,
  output `build/linux/x64/debug/bundle/al_note`.
  Log: `/tmp/al-note-correction2-followup-linux-build.log`.
- Web release build: `flutter build web --release --no-pub --no-web-resources-cdn`,
  **passed**, exit 0, 41.9 seconds, output `build/web`. Wasm dry run succeeded;
  the existing nonfatal CupertinoIcons missing-font-family warning remains.
  Log: `/tmp/al-note-correction2-followup-web-build.log`. No separate browser
  runtime audit was repeated for this follow-up.
- `git diff --check` passed. Hash comparison confirms all 431 baseline paths
  outside this follow-up remain unchanged, including vendor/geometry/precision,
  immutable admission registry/corpus, host readers, dependencies/lockfile,
  Android, CI and release composition. No unrelated vendor/host audit was rerun.

Exact incremental scope: **8 paths: 7 existing modifications, 1 addition**.

1. `lib/documents/pdf/pdf_fixture_admission.dart`
2. `lib/documents/commands/document_mutation_coordinator.dart`
3. `lib/ui/canvas/phase6_canvas.dart`
4. `test/documents/pdf_fixture_admission_test.dart`
5. `test/documents/commands/document_mutation_coordinator_test.dart`
6. `test/widget_test.dart`
7. `test/support/pdf_canvas_followup_checks.dart` (new)
8. `docs/testing-release/phase8-correction2.md`

Exact before/after SHA-256 scope:
`/tmp/al-note-correction2-followup-scope.json`. Expanded current Git status:
`/tmp/al-note-correction2-followup-git-status.txt`: 241 tracked modifications,
171 untracked files, zero staged changes, same branch and HEAD. No baseline
files deleted. Existing uncommitted work is preserved; no commit, push, PR,
tag or publication occurred.

The bounded follow-up is implemented and the requested verification has passed.
Stop for Main AI review; this is not whole-milestone approval. Parser operation
duration still has no hard deadline: completion-driven recovery requires the
active operation to finish, and cancellation does not forcibly interrupt native
parsing. This adds no untrusted-PDF safety, release-readiness, Android, duplication
or opacity claim. Those separate blockers remain outstanding.


## Final Correction 2: observer-atomic PDF replacement

Only the observer/replacement race from
`/tmp/al-note-correction2-followup-independent/report.md` is addressed here. The
439-path starting snapshot is `/tmp/al-note-correction2-observer-baseline.json`.
Accepted busy-render recovery is not changed.

### Reproduction and boundary

The exact supplied actual-PDFium probe was first run unchanged and failed:
`/tmp/al-note-correction2-observer-reproduce.log`. One old-document observer
reopened the saved notebook and cancelled PDF opening, but the obsolete open
then installed its PDF and erased the saved buffer. The prior `stillCurrent`
check protected command mutation only; observers ran between that mutation and
Canvas replacement.

The chosen order was stated before editing and is now synchronous:

1. Prepare/validate the replacement coordinator and draft command, including
   all fallible payload/layout, identities and history work. Check the original
   coordinator/content identity, generation, cancellation and mounting before
   authoritative mutation, as in the accepted preceding correction.
2. Publish the old draft root, identity, revisions and history under its existing
   command guard.
3. Before command observers, close the editor and install the prepared Canvas
   coordinator, Selection and render state; reset the old saved buffers and
   publish the new status. Register any page-fit callback with coordinator
   ownership checks so it cannot act on a subsequent replacement.
4. Deliver the two captured old operation cancellations only after all owner
   fields are complete. Then deliver the old command's observers synchronously
   under the old coordinator's mutation guard.
5. Return without any obsolete Canvas installation, save reset, editor close or
   status change. Observers may have saved, reopened, changed tools or disposed
   the Canvas; their completed actions remain authoritative.

This uses an optional `DocumentMutationCoordinator.execute` argument,
`publishCompanionState`, for an application-owned synchronous publication hook.
It runs after prepared command publication but before `_notify`. It performs no
remaining fallible preparation. Ordinary calls without the hook retain the same
notification/reentrancy path and observer failure count. `stillCurrent` rejection
runs before both command and companion publication. `_notify` is in `finally`,
so even an invalid unexpectedly throwing hook cannot skip observers or strand
the guard; such a programming error propagates after delivery and does not roll
back a published command. The Canvas hook is composed only from its already
prepared installation/cleanup, with no remaining rejection branch.

Cancellation delivery itself is externally callable. `_installCoordinator`
therefore captures at most two old controllers and returns one synchronous
cleanup closure. Callers complete all saved/status fields and register the
owned page fit before invoking it. Each cancellation is attempted even if a
listener throws. Nothing is queued or polled; the closure is consumed in the
same synchronous publication and retains no source copies. Command observers
remain exactly-once and snapshot-ordered, and listener exceptions do not stop
later listeners. No timers/microtasks establish this boundary.

### Reentrant action semantics and saved state

A Reopen button captures the immutable saved bytes/root represented when that
button is built. Calling a retained button callback after PDF installation can
therefore reopen that notebook even though the completed PDF installation has
cleared the old Canvas save fields. Successful Reopen installs that captured
snapshot as both the current document and its saved-buffer pair. This preserves
the auditor's explicit Reopen action; it is not ignored, rolled back or followed
by an obsolete PDF reset. A normally rebuilt button represents the latest save.
There is no additional byte copy or new saved-document queue.

Save and tool callbacks act immediately on the document current at invocation.
Listeners run in registration order. Thus Save followed by a retained Reopen
saves the current PDF and then reopens that button's notebook; retained Reopen
followed by Save saves the reopened notebook. Later listeners see the preceding
action's resulting owner/state. Calls into the old coordinator during its event
are still rejected by its existing guard; commands on a newly installed owner
are independent. Save/Reopen/tool callbacks retained past disposal return before
mutation. Old notifications still finish exactly once after disposal, and the
old guard is released. No obsolete post-frame fit acts on a newer coordinator.

`Phase6CanvasPublicationEvidence` supplies four read-only, test-only owner
getters. They expose current root, saved root/bytes and draft presence during
synchronous callbacks. Tests use this actual owner state rather than the painter
snapshot from a preceding frame; no mutation API or production control is added.

### Regression evidence

The original independent probe was rerun **unchanged** after the fix:
`/tmp/al-note-correction2-observer-original-postfix.log`, **1 passed**. Its essential
no-overwrite assertion and saved notebook target are unchanged. It reports one
observer, cancelled opening token, old history count one, final `NotebookDocument`
and retained saved bytes. The token is now cancelled by completed installation
before observer delivery; the original boolean assertion still passes, without
claiming that Reopen was necessarily the first cancellation source.

`test/support/pdf_observer_atomicity_checks.dart`, registered from the existing
widget test library, retains this real-PDFium scenario and five further direct
ordering cases: Save, Save then Reopen, Reopen then Save, synchronous tree
disposal, and a throwing cancellation listener that reopens before command
observers. Each uses three command observers, a throwing first listener,
reentrant old-command attempts, exact event sequence and actual owner snapshots.
The first external notification must see an installed PDF, cleared saved fields
and no draft. Later listeners must see earlier actions' effects. The tests verify
retained notebook/PDF saves, no obsolete installation/reset, one old history
entry, UUID counts, old draft bytes and undo/redo, and no publication after
disposal. Synchronous disposal is driven by real tree replacement/finalization,
not a delayed task.

Coordinator regressions cover companion-before-observer order, observer failure
count, mutation reentry, rejection before either publication, and guard/event
cleanup for a deliberately invalid throwing hook. Existing new/existing/unchanged
draft and failure-before-publication tests are retained unchanged and rerun.

### Final observer-correction verification and scope

- Exact original independent probe before edits: **1 failed**, confirming the
  reported overwrite, 9 seconds. After the fix, the same probe with no expectation
  changes: **1 passed**, 7 seconds. Command:
  `flutter test --no-pub --reporter expanded /tmp/al-note-correction2-followup-independent/observer_probe_test.dart --plain-name 'audit synchronous'`.
- Initial new ordering checks: **8 passed, 1 test-harness failure**. The disposal
  harness omitted Flutter's root View; adding that View corrected the render-tree
  setup without a production-code change. Log:
  `/tmp/al-note-correction2-observer-focused.log`.
- Final focused run: **82 passed**, 35 seconds, including the complete coordinator
  file, all six actual-PDFium observer cases, retained PDF/draft regressions and
  affected Save/Reopen checks. Command:
  `flutter test --no-pub test/widget_test.dart test/documents/commands/document_mutation_coordinator_test.dart --name 'PDF|compound publication|DocumentMutationCoordinator|final publication|Reopen|reopen|Save|save' --reporter expanded`.
  Log: `/tmp/al-note-correction2-observer-focused-final.log`.
- Final formatting check on all five authored/modified Dart files: **0 changes**,
  exit 0, 1.12 seconds. Log: `/tmp/al-note-correction2-observer-format.log`.
- Final `flutter analyze --no-pub --fatal-infos`: **No issues found**, 2.5 seconds,
  exit 0. Log: `/tmp/al-note-correction2-observer-analysis-final.log`.
- Full suite after final code/test changes: **770 passed, zero failures**,
  2 minutes 18 seconds, exit 0. Command:
  `flutter test --no-pub --reporter expanded`. Run once for this final correction;
  no later code/test fix or rerun was needed. Log:
  `/tmp/al-note-correction2-observer-full-test.log`.
- Linux debug build: `flutter build linux --debug --no-pub`, **passed**, exit 0,
  output `build/linux/x64/debug/bundle/al_note`. Log:
  `/tmp/al-note-correction2-observer-linux-build.log`.
- Web release build: `flutter build web --release --no-pub --no-web-resources-cdn`,
  **passed**, exit 0, 42.5 seconds, output `build/web`. Wasm dry run passed; the
  existing nonfatal CupertinoIcons font warning remains. Log:
  `/tmp/al-note-correction2-observer-web-build.log`. No new browser runtime or
  unrelated vendor/host audit was run.
- Final `git diff --check`, authored-file whitespace checks and protected baseline
  hashes pass. No source/test changes followed the full suite; only this report
  and external scope/status records were updated.

Exact incremental scope: **6 paths: 5 existing modifications, 1 addition**.

1. `lib/documents/commands/document_mutation_coordinator.dart`
2. `lib/ui/canvas/phase6_canvas.dart`
3. `test/documents/commands/document_mutation_coordinator_test.dart`
4. `test/widget_test.dart`
5. `test/support/pdf_observer_atomicity_checks.dart` (new)
6. `docs/testing-release/phase8-correction2.md`

Before/after SHA-256 scope: `/tmp/al-note-correction2-observer-scope.json`.
Expanded Git status: `/tmp/al-note-correction2-observer-git-status.txt`:
241 tracked modifications, 172 untracked files, zero staged changes. Branch
`phase-8-pdf-system` and HEAD `921e43f41a31b0649a2ae890c993fd4e406ad39a`
are unchanged; no baseline file was deleted.
All 434 other baseline paths are unchanged, including the accepted render guard
and its maintained regressions, admission, geometry, bounded readers, dependencies,
lockfile, Android, release composition and CI. Canvas cancellation delivery during
coordinator replacement is reordered solely to keep callbacks outside incomplete
owner publication; render acquisition/recovery and image publication checks are
unchanged. No unrelated vendor/host audit is repeated.

No commit, push, PR, tag or publication is created. This correction does not
approve Phase 8 or remove its separate Android, duplication, opacity, binary
provenance or untrusted-input blockers. Recovery still depends on native operation
completion; no parser deadline, sandbox or new general PDF support is claimed.
All requested correction checks are complete. Stop for Main AI review.
