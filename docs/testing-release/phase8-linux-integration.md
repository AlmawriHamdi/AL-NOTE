# Linux isolated PDF integration — review handoff

**2026-09-09 correction:** the [integration correction record](#integration-corrections--2026-09-09) below supersedes the original cleanup, staging and raster handoff descriptions. The original integration record is retained as historical evidence.

Implemented against `phase-8-pdf-system`, HEAD
`921e43f41a31b0649a2ae890c993fd4e406ad39a`, preserving the existing worktree.
The prototype, both independent Linux reports, and accepted Correction 1,
Correction 2 and consolidated reports were read. This handoff requests Main AI
and independent integration review. It does not approve ordinary-PDF admission
or release. No commits, pushes, PR changes, tags, merges or publication occurred.

## Application scope and admission

`createApplicationPdfBackend` selects an AL NOTE-owned isolated backend on Linux.
It does not fall back to the pdfrx in-process adapter when resources or host
support are missing. Other platforms retain their existing fixture-only factory.
The existing main debug/release gate, bounded picker, workflow, atomic replacement,
Canvas scheduling/publication, immutable-resource identity and cancellation
checks remain. No coordinator, history, source geometry, Canvas implementation,
opacity, duplication, vendor engine, dependency, lockfile or CI changes.

The existing `DevelopmentFixturePdfBackend` still supplies one active operation
and one superseding latest render interest, before resource capture/worker work.
Completion reserves the next slot. Each isolated operation finishes staging,
transport, validation and cleanup before releasing that slot. Waiting requests
have no native process or second source capture. Disposal cancels the existing
Canvas tokens; canceled or stale completions never publish. Runtime resource
staging occurs in a separate isolate so hashing/copying does not block Canvas.

The shipped ordinary-PDF gate is unchanged. The original 45-fixture registry is
byte-for-byte unchanged. Only an explicit non-product Linux build with
`--dart-define=ALNOTE_LINUX_INTEGRATION_TEST=true` additionally admits the two exact
locally generated digests in `test/fixtures/phase8/linux-integration/manifest.json`:
a 1,300-byte ordinary three-page file and a 46,751-byte heavy graphics control.
Neither altered bytes, document trust flags nor claimed identities grant
admission. Product builds and Android/Windows/Web cannot activate this test route.
The flag is not a shipped setting and does not grant arbitrary-PDF admission.
The legacy fixture adapter remains available for its existing engine regressions;
application Linux composition always selects isolation.

## Packaged resources and provenance

Linux CMake installs the preverified resource package into `data/pdf_linux` beside
the executable. Runtime discovery uses `Platform.resolvedExecutable`; it has no
reference to audit files, Python, development directories, SDKs or source trees.
`package_resources.py` is build-time tooling only. Normal packaging compares its
entire generated manifest with the checked-in expected manifest and rejects a
mismatch. `--candidate` only creates an inert review candidate; it never edits a
compiled pin. Different rebuild/runtime bytes require a new explicit review.

Manifest SHA-256, compiled in Dart and checked during Linux installation:

`c46a58a923da790ce5af71d0474018912fc520517c2cb038be57ee79ca3ab3c3`

| Executed resource | SHA-256 |
| --- | --- |
| Restricted AOT worker | `39997fe16f47d93475aca901d99d334cca4bd6279013dd046e6d076447c4980e` |
| Seccomp guard | `9c66b86370938d5384436bfab5bda9192cf8472d133ef7903315f6ea466af938` |
| Controlled PDFium | `d9c4c59ee98575e4be174a86a64834c91dff1aa5c9ad20604308f31cc05a7d8a` |
| New exact-write transport | `44ecfc816b34a17212801e6d7db541778ae9ad4cdc524f61950b3d65c2a3bae4` |

Worker and guard were rebuilt with the existing Flutter 3.44.6/Dart 3.12.2 and
Ubuntu GCC 13.3.0 and exactly match the independently exercised prototype bytes.
The PDFium library was reused without rebuilding; source
`f91ca5a72358bb0b00b4da9481b21fe668157614` and prior controlled-build correspondence
remain unchanged. The publisher candidate stays quarantined. The transport is
new AL NOTE C code compiled with existing GCC; it needs independent review.
These are local controlled-build/integrity claims, not new publisher attestations
or cross-machine bit-reproducibility claims.

The package contains **114 files**: ten executable/runtime files (19,954,816
bytes) and 104 notice files (1,853,952 bytes). Exact sizes/hashes are in
`tool/linux_pdf/packaged_resources.json`. The staged runtime includes the loader,
libc, libdl, libpthread, libm and libgcc. Their host package sources are
`glibc-2.43-7.fc44.src.rpm` and `gcc-16.1.1-2.fc44.src.rpm`; no new host packages
were installed. Notices include the controlled PDFium notices, glibc/libgcc,
Dart SDK, AL NOTE and a conservative superset of resolved Dart-package licenses.
No new OS-package authenticity audit or OS-source rebuild is claimed.

Every operation checks the compiled manifest digest, then bounded reads, exact
sizes and hashes for all package files. Symlink files and group/other-writable
files reject. The application creates its own temporary directory, sets mode
0700 before writing resource bytes, and stages the same captured buffers that
were hashed. Executable files become 0500. Writes are awaited/closed; ephemeral
runtime copies do not require durable fsync. Only runtime files enter the
read-only sandbox mount; notices stay outside. The transport itself is started
with the verified packaged loader and library path. The private directory is
deleted after operation cleanup, including rejection and cancellation. There
is no persistent source/engine cache or staged PDF file.

## Transport and containment

The first hostile integration test demonstrated that Dart `IOSink.flush/close`
can complete even when the full request did not reach the kernel pipe. Therefore
Dart stream completion alone is not accepted as transmission evidence.

The new 129-line `input_transport.c` forwards two bounded frames with a single
64-KiB buffer. It validates declared lengths, counts actual successful writes,
rejects short/closed transport, and reaps the concrete systemd-run child. Exit
zero requires complete framed transmission and child exit zero. `ppoll` atomically
restores the signal mask while waiting, avoiding lost child-exit/cancellation
wakeups. Parent-death signaling and cancellation terminate/reap the launcher.
The Dart parent still independently validates output and the worker cgroup. A
plausible worker response cannot override a nonzero transport exit.

Full transmission proves necessary pipe transport, not that a hostile worker
consumed/interpreted every byte; systemd/OS buffering remains possible. No PDF
parser was introduced in Dart or the transport helper.

The approved actual-host systemd/bubblewrap restrictions remain: separate
namespaces, cleared environment, dropped capabilities, no home/session/network
mounts, read-only runtime, private proc/dev/tmp, TSYNC guard before PDFium ready,
1 GiB memory, zero swap, 32 tasks, disabled core dumps and 64 descriptors.
Actual cgroup controller values are read before transmitting any request byte.
The worker ceiling is 30 seconds; the parent watchdog adds two seconds, and
cleanup/controller operations have separate finite waits. Kernel-uninterruptible
work and scheduler overshoot remain outside a strict real-time guarantee.

Input is bounded to 50,000,000 bytes, pages to 1,000, raster dimensions to 4,096,
metadata frames to 256 KiB, diagnostics to 4 KiB and RGBA to the requested size.
Response IDs/version/dimensions/lengths/optional timings require exact integers;
booleans and integral floats reject. Geometry is bounded before conversion,
finite and exact, including rotation and saved-reference matching. A 401-digit
coordinate returns structured failure after cleanup. All failures discard
private partial output; native handles never enter document contracts.

Password/encryption/extraction/clipped-render capability is not expanded. The
worker's coarse rejection protocol maps parsing failures to `PdfCorrupt`;
missing packaged resources maps to backend unavailable. Full-page Canvas
rendering, legacy saved box names with matching exact geometry, source visibility
and opacity remain supported through the existing contracts.

## Personally run verification

Logs/evidence: `/tmp/al-note-linux-integration/`.

| Check | Result / evidence |
| --- | --- |
| Final full application suite, normal shipped gate | **818 passed, 5 opt-in host cases skipped**, `full-suite-final.log` |
| Serial real-host integration plus existing dependency boundaries | **15 passed**, `verified-focused.log` |
| Additional transport/permission/symlink package coverage | **2 passed**, `packaging-extra-checks.log` |
| Native transport tests | **5 passed**, `native-transport.log` |
| Fatal-info analysis | no issues, `handoff-analysis.log` |
| Authored Dart formatting | applied and checked; logs `final-format*.log`, `handoff-format.log` |
| Python/C/whitespace | AST/whitespace checks; GCC `-Wall -Wextra -Werror`; `git diff --check` |
| Linux application | debug build passed, `linux-build.log` |
| Shared Web factory/import compatibility | build and Wasm dry run passed, `web-build.log` |
| Installed package | all 114 files/hash/size/permission checks pass, `built-resource-verification.json` |
| Packaging reproducibility with existing inputs | exact manifest match, `repackage.log` |
| Relocated AOT components/default bundle discovery | eight successful operations outside the repository, `relocated-measurements.json` |

Real-host tests cover incomplete input with valid-looking success, exact integer
metadata, huge geometry, invalid/truncated/excess output, oversized frames,
stderr flooding, nonzero and early exit, an actual SIGSEGV after valid output,
hang, descendant cancellation, missing host executables, valid inspection/render
and heavy native cancellation. The package tests cover missing/corrupt worker,
transport, guard, engine, all runtime libraries, notices and manifest, plus
writable/symlink resources. The supervisor verifies stopped services and observed
empty cgroups before returning; the serial hostile test also checks no matching
active test services remain. Native tests cover 31/65,535/65,536/65,537-byte
fragmented consumption and cancellation with concrete-child reaping.

Canvas tests use the real Linux backend and a controlled test picker. Success
commits a live draft exactly once before replacement, renders three-page input,
recovers after navigation/zoom bursts without additional user action, saves and
reopens. Missing-package rejection preserves root/revisions, live editor/draft,
Selection, history, saved-buffer identity, UUID count and zero publication.
Disposal cancels pending work and prevents image publication. The full suite
also covers the retained observer/reentrancy, stale-identity, Undo/Redo, opacity,
visibility and annotated-duplication regressions. No Canvas implementation was
changed to make these pass.

Execution history is explicit: the first full-suite run had **817 passes and one
failure** because a direct crypto import violated the existing private-adapter
boundary. That was corrected through the existing adapter without changing its
old hashing behavior; the final full suite above passed. An initial concurrent
host run incorrectly treated another test's legitimate Canvas service as leaked;
the documented host selection runs serially and passed. The widget wait helper
was corrected to advance virtual and real time together. The native transport
was added only after the real incomplete-transmission reproducer failed.
After the final passing full suite/build state, only test coverage and the
test-only measurement driver were strengthened; the affected package tests,
formatting, analysis and relocated driver were rerun. Application code did not
change afterward. The full suite was run **twice total**, not repeatedly claimed
as a single run.

Not repeated: unchanged engine build/provenance research, complete earlier host
containment audit, broad geometry matrices, browser pixel audit, Android/Windows
builds or vendor audits. Web compilation was justified by shared main/factory and
conditional imports. Its existing Cupertino-font warning is recorded; no new
font/package installation was made. Linux release-mode execution is still gated;
the verified application build here is debug. AOT timings are from the dedicated
compiled integration driver, not a release-admission build.

## End-to-end measurements and responsiveness

The relocated AOT driver uses the actual installed package and default
bundle-relative resolver. It includes resource verification/isolate staging,
request transmission, engine operation, response validation, launcher/cgroup
cleanup, controller reset and directory deletion. It excludes picker interaction,
document construction and Flutter image decoding; those are included in the
separate Canvas measurements below apart from human dialog interaction.

| Measured path | Observed |
| --- | --- |
| AOT inspection including staging/cleanup | 526.144 ms |
| Seven AOT renders, rotating pages and increasing 530×690 through 710×930 sizes | median 852.448 ms; 462.468–971.047 ms |
| Resource staging across eight AOT operations | median 609.863 ms |
| Debug Canvas open tap/live draft through first displayed image | 3,648 ms |
| Three debug Canvas navigation/zoom bursts through latest image | 2,705 / 2,305 / 2,356 ms |

These are actual host observations, not a throughput guarantee; host background
load and debug instrumentation affect them. Stage work runs outside the UI
isolate. Rapid navigation/zoom supersedes obsolete work, but placeholders can
remain until the latest operation completes. One fresh worker and private runtime
per operation has noticeable latency; no persistent-cache or smooth 60-fps zoom
claim is made. This is a concrete remaining performance limitation for review,
not a relaxation of bounds or an in-process fallback.

## Reproducible reviewer commands

Use the existing reviewed controlled engine build from the prototype. Compile in
`al-note-dev`; package and run host tests on Bazzite. No Python participates in
application runtime. Use a **new** packaging destination for each verification;
normal packaging refuses to overwrite an existing directory or approve new hashes.

```sh
mkdir -p build/linux-pdf-tools
distrobox enter al-note-dev -- dart compile exe --packages=.dart_tool/package_config.json tool/linux_pdf/worker.dart -o build/linux-pdf-tools/pdf-worker
distrobox enter al-note-dev -- gcc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared tool/linux_pdf/sandbox_guard.c -o build/linux-pdf-tools/libguard.so
distrobox enter al-note-dev -- gcc -std=c11 -O2 -Wall -Wextra -Werror tool/linux_pdf/input_transport.c -o build/linux-pdf-tools/transport
distrobox enter al-note-dev -- gcc -std=c11 -O2 -Wall -Wextra -Werror tool/linux_pdf/protocol_probe.c tool/linux_pdf/sandbox_guard.c -o build/linux-pdf-tools/protocol-worker
PYTHONDONTWRITEBYTECODE=1 python3 tool/linux_pdf/package_resources.py --worker build/linux-pdf-tools/pdf-worker --guard build/linux-pdf-tools/libguard.so --transport build/linux-pdf-tools/transport --destination /tmp/alnote-reviewed-package-new
PYTHONDONTWRITEBYTECODE=1 python3 tool/linux_pdf/test_input_transport.py -v
/home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_INTEGRATION_TEST=true test/documents/files/dependency_boundary_test.dart test/documents/linux_pdf_integration_test.dart test/widget_test.dart --name 'Linux |Phase 4 dependency boundaries' --reporter expanded
distrobox enter al-note-dev -- flutter test --no-pub --reporter expanded
distrobox enter al-note-dev -- flutter analyze --no-pub --fatal-infos
distrobox enter al-note-dev -- flutter build linux --debug --no-pub
distrobox enter al-note-dev -- flutter build web --no-pub
distrobox enter al-note-dev -- dart compile exe --packages=.dart_tool/package_config.json tool/linux_pdf/measure_integration.dart -o build/linux-pdf-tools/measure-integration
build/linux-pdf-tools/measure-integration build/linux/x64/debug/bundle/data/pdf_linux test/fixtures/phase8/linux-integration/ordinary.pdf
```

`build/linux-pdf-resources` already contains the verified package used by CMake
and tests. For a fresh workspace, use that absent destination in the packaging
command above after reproducing the reviewed engine inputs. A relocation check
copies the built `data/pdf_linux` and compiled measurement executable to a new
private directory, changes cwd away from the repository, and invokes the driver
with **only the absolute generated fixture path**. It then exercises the same
default resource resolver as the application. The driver rejects other fixture
bytes and performs bounded input reading.

## Exact incremental scope and remaining approval

Seven pre-existing files changed from the 467-file integration baseline:
`lib/main.dart`, `lib/documents/pdf.dart`,
`lib/documents/pdf/pdf_fixture_admission.dart`,
`lib/documents/files/src/sha256_adapter.dart`, `linux/CMakeLists.txt`,
`test/widget_test.dart`, and the test-only `tool/linux_pdf/protocol_probe.c`.
Twenty-one files were added: ten factory/gate/Linux-backend Dart files under
`lib/documents/pdf/src/`, two integration test files, three generated fixture/
manifest files, five transport/package/measurement tooling files, and this report.
The final machine-readable hashes/scope are in `final-scope.json` beside the logs.
All other **460 baseline files** retain their hashes. Existing broad Git changes
are preserved, not attributed to this integration.

Before final ordinary-Linux enablement, independently review this supervisor,
new transport, packaging/ownership assumptions and observed latency. The smallest
subsequent policy change is an explicitly approved **isolated-Linux** admission
policy applied consistently at workflow, Canvas and isolated backend reception,
with 50-MB bounds, plus enabling the Linux backend/picker outside the existing
main debug gate and updating the fixture-only UI label. Do not simply broaden
the shared development-fixture registry: the legacy in-process fixture adapter
must remain fixture-only. Other platforms and untrusted-input release quarantine
must remain unchanged. No parser, geometry, history or replacement redesign is
needed for that later policy decision.

Residual limits include supported Bazzite/x86-64 host facilities, trusted local
installation/compiler inputs, same-user/privileged host compromise, kernel and
runtime vulnerabilities, syscall-denylist residual attack surface, uninterruptible
work, packaging distribution/source-notice review, coarse password/encryption
failure mapping, no extraction/clipped rendering and the per-operation staging
cost. The tests do not establish arbitrary-PDF safety or successful production
release admission. Stop for Main AI and independent review.


## Integration corrections — 2026-09-09

Scope: the three findings C1/P1/P2 in
`/tmp/al-note-linux-integration-independent/report.md`. All existing work was
preserved. Evidence for this correction is in
`/tmp/al-note-linux-integration-correction/`. The initial 488-file worktree
snapshot is `baseline.json`; it is independent of Git HEAD because most Phase 8
work remains uncommitted. No admission, engine, guard, transport, manifest pin,
geometry, coordinator, history, dependency, lockfile, CI or release gate changes.

### Cleanup ownership (C1)

The old supervisor ignored controller exit status and treated rejection plus
transport reap as completion even when the manager-owned worker cgroup remained
populated. Its delegate then deleted staging and released the admission guard.

Controller commands now check exit status, bounded output, stream failures and
three-second timeouts. Cleanup requests cgroup-wide SIGKILL, independently
requires a successful inactive/failed state query, checks `cgroup.events` for
`populated 0` on both the observed and returned groups (including descendants),
and reaps the concrete launcher. A failed kill command can mean an already
stopped service; only independent successful state/emptiness checks establish
cleanup. Resetting an already empty failed unit is housekeeping.

An unsuccessful cleanup attempt enters explicit `cleanupUnconfirmed` state,
discards private output and escalates the concrete launcher to SIGKILL. It keeps
one outstanding operation, its staging directory and its admission reservation.
One bounded controller attempt runs at a time, with a one-second delay between
attempts; neither a timeout nor the service runtime ceiling releases ownership.
The operation future completes only after confirmed cleanup. The UI remains
responsive while awaiting it. `LinuxPdfBackendStatus` receives this state from
the operation isolate; selected/document bytes cannot set it. The unchanged
outer guard retains at most one latest render interest, and removes cancelled
or superseded interest without capturing its source. Disposal cancels interest
and publication while the owner continues cleanup.

Permanent regressions launch the real systemd/bubblewrap hostile diagnostic,
wait for four concrete PIDs including the detached SIGTERM-ignoring descendant,
and then make controller calls fail or time out. Both inspection and queued
render admission stay blocked with zero reader calls while cleanup is unknown.
After controller restoration, the old future rejects, all four PIDs disappear,
the group is empty, and the latest pending reader is admitted. Repeated rounds
and valid real-worker inspection/render recovery are covered. Controller paths
are app-owned test dependencies, never PDF fields.

### Raster and image handoff (P1)

The integrated backend previously called the generic synchronous per-byte
`PdfRenderOutput.capture` loop on its caller's isolate. Protocol raster assembly
also ran there, followed by another full Dart raster copy in Canvas.

The Linux operation now runs in a cancellable isolate, including staging,
process supervision, streaming frame assembly, protocol validation and raster
capture. Cancellation messages are cooperative; an isolate owning workers is
never killed to implement cancellation. `Isolate.exit` transfers the completed
object graph rather than copying its large output on the UI isolate. A typed
capture path checks dimensions, receiving limits and exact byte length, then
copies `Uint8List` into private storage in that isolate. Typed bytes intrinsically
satisfy the byte range. Its unmodifiable typed view, including its exposed buffer,
is covered by mutation regressions. Generic iterable validation remains intact.

Canvas uses `preparePdfRasterImage`, which sends those immutable typed bytes to
`ui.ImmutableBuffer` without another Dart raster copy. Native buffer/image
preparation still has a cost; cancellation is checked between its asynchronous
steps and every temporary native object is disposed. Existing final Canvas
lifecycle, request key, source-byte identity and page-reference checks still
control publication. The maintained measurement uses this exact helper and
verifies every rendered byte by image readback; readback/assertion work is outside
the reported preparation timing. Pre-cancel, cancellation during image
preparation, disposal, and valid subsequent image preparation are covered.

### Staging and verified-byte reuse (P2)

Old staging rehashed 114 files and recopied runtime resources for every operation,
without receiving cancellation until all preparation had finished. Preparation
now checks cancellation during reads/file transitions and between 64-KiB digest
chunks. Rejected preparation deletes its private directory before returning.
The caller also checks cancellation after the isolate handoff and deletes a
stage cancelled at that boundary.

Each backend retains only the verified private runtime byte snapshot (10 files,
19,954,816 bytes) plus bounded package metadata. It retains no parser, PDF
document, worker, open resource handle or idle staging directory. Each operation
still writes a fresh private runtime from those exact verified bytes. Manifest
identity and every file's type, permissions, size and modification/change metadata
are checked on reuse. Changed metadata invalidates the cache and requires full
captured-byte hash verification. Missing, symlinked or writable resources reject.
These metadata checks select reuse of previously pinned private bytes; they never
make changed installation bytes trusted. The cache dies with its backend, and
no caller can mutate it through a staged file. The operation isolate handoff can
copy the bounded cached input graph; that cost is included in the caller's
heartbeat measurements. Notices are verified but are not retained as runtime
bytes. Package mutation, restoration, missing cached notices, private stage
mutation, repeated cold cancellation and automatic latest-render recovery have
permanent coverage.

### Reproducer results and measurements

The original auditor source files were not edited. The unchanged initial
`run_disconnect.py` reproduced exit-status 1 controller failure, rejection after
3,017 ms, an active service and four remaining PIDs. The unchanged AOT backend
probe reproduced 1,519-ms heartbeat stalls at 3200² and a 348-ms delay between
cancelling A and admission of C. Its capture-only executable took 1,564 ms at
3200². All were personally run before correction.

After recompiling the original sources against the correction:

- The unchanged disconnect harness times out at its 20-second outer deadline
  (exit 1). Its irreversible TSYNC denial prevents every subsequent controller
  query, so the corrected owner deliberately does not return proof of cleanup.
  The harness kills its child process and externally kills/resets its owned
  service in `finally`; no service remains. This is **not** reported as a passing
  original harness. The maintained reversible outage/timeout regressions prove
  blocked admission, continued ownership, restoration and eventual recovery.
- The unchanged backend/supersession probe rejects its old timing assumption
  (`Bad state: stale output`): faster cancellation can let uncancelled B acquire
  and finish before C supersedes a pending request. It had assumed B remained
  queued for its fixed 10-ms sleeps. This is **not** reported as a passing original
  probe. `backend_scaling.dart` is a separately labelled diagnostic copy with
  only this timing-dependent prelude removed; its raster sizes, fixture, backend
  calls and heartbeat loop are unchanged. The maintained cold-stage test queues
  B and C while A demonstrably owns a stage and verifies B's zero reader calls.
- The unchanged capture-only source measures 0.552 / 1.857 / 7.770 / 31.772 ms
  for 400/800/1600/3200 square typed buffers. That synchronous API still does not
  execute queued timers during capture; the Linux caller runs it off the UI
  isolate. This microbenchmark alone is not evidence of application performance.
- The unchanged staging source completes its cancelled stage 8.202 ms after
  cancellation (5.127-ms maximum heartbeat gap). Its fresh-object cold stages
  remain 610–768 ms; its final explicitly instrumented old implementation row
  is not counted as corrected production behavior.

Comparable actual-backend AOT measurements, same admitted `blank-workflow.pdf`,
5-ms heartbeat and square dimensions (microseconds retained in JSON):

| Dimension | Before render | After render | Before max heartbeat gap | After max heartbeat gap |
| --- | ---: | ---: | ---: | ---: |
| 400 | 547 ms | 300 ms | 31.6 ms | 28.4 ms |
| 800 | 654 ms | 316 ms | 108.1 ms | 26.0 ms |
| 1600 | 1,227 ms | 408 ms | 641.1 ms | 27.2 ms |
| 3200 | 2,685 ms | 565 ms | 1,518.9 ms | 54.5 ms |

These include admission, resource handoff/staging, worker execution, output
validation/capture, cleanup and runtime deletion. They exclude Flutter decoding.
The cache is warm from inspection; the previous backend had no reusable cache.
Measurements are single-host samples, not cross-machine or frame-rate guarantees.

The first corrected Flutter handoff run measured 473 / 441 / 530 / 1,025 / 895 ms
through image creation at 400/800/1600/3200/4096, with maximum heartbeat gaps
40.1 / 29.9 / 20.5 / 72.2 / 90.9 ms. A second serial combined run measured
397 / 382 / 394 / 379 / 529 ms, with gaps 34.4 / 26.7 / 17.5 / 27.0 / 36.8 ms.
Variation is reported instead of selecting one favorable run. All pixels were
checked through native image readback. Cold cancellation regression samples were
1–6 ms to return with no leftover stage; latest rendering required no new action.

Engineering regression targets for this reviewed host are a maximum measured
100-ms heartbeat gap through a supported 4096² handoff, cold-stage cancellation
below 250 ms, and a warmed 400² actual-backend operation below one second.
These are review targets, not a 60-fps promise or approval of product UX. The
real Canvas open/live-draft/navigation checks include rendering/publication and
are reported separately from AOT timing.

### Verification and preservation

Personally executed at the final shared-code state:

| Check | Result | Evidence |
| --- | --- | --- |
| Complete application suite, once | **820 passed, 9 skipped** | `full-suite-final.log` |
| Serial Linux protocol/package/cleanup/cache/raster/Canvas selection | **21 passed** | `host-final.log` |
| Maintained native transport cleanup tests | **5 passed** | `native-transport-final.log` |
| Fatal-info analysis | **No issues** | `analysis-final.log` |
| Formatting, all 11 changed Dart files | **0 changes** | `format-final.log` |
| Linux debug build, al-note-dev | **Passed** | `linux-build-final.log` |
| Real backend using newly built installed resources | **Inspection and all four renders passed** | `installed-backend-final.json` |

The full suite was not repeated. No production or test source changed after it
started; only this report/evidence was updated. Affected host tests were then
rerun serially after the Linux build. The 9 full-suite skips are the 5 existing
opt-in host checks plus 4 new opt-in correction checks; final explicit host
verification ran those checks. No Web, Android or Windows build, engine/guard/
transport rebuild, dependency upgrade, provenance research, broad geometry
matrix or unrelated host/vendor audit was repeated.

Final Flutter handoff measurements at 400/800/1600/3200/4096 were
468 / 458 / 479 / 827 / 892 ms through image creation, with maximum heartbeat
gaps 25.4 / 28.2 / 18.1 / 60.0 / 93.4 ms. Final cold-stage cancellations were
6 / 4 / 2 ms. Final Canvas open through first image took 2,818 ms and navigation/
zoom bursts took 1,832 / 1,699 / 1,628 ms. The earlier corrected combined run
measured 1,549 ms open and 1,068 / 1,092 / 1,240 ms navigation. These variable
end-to-end samples include actual publication, and are not a claim of smooth
frame delivery. The auditor's prior Canvas measurements were 5,456 ms open and
3,399 / 2,980 / 3,040 ms navigation; those prior audit measurements were reviewed,
not personally re-executed against old Canvas source during this correction.

The final installed-bundle AOT control measured render times
290 / 322 / 380 / 683 ms at 400/800/1600/3200, with maximum heartbeat gaps
23.3 / 29.4 / 24.6 / 57.2 ms. It performs a real inspection first and retains the
same manifest/engine/guard/transport pins. The unchanged final auditor backend
probe again exited 255 on its obsolete timing assumption; the unchanged final
disconnect harness again exited 1 at its 20-second outer timeout. Exact exit
codes are in `final-probe-exits.json`; neither is counted among passing tests.

Development-only failures are retained in evidence: the initial analyzer found
8 infos, corrected before final verification; the cache regression initially
tried to overwrite its read-only fixture worker, then was fixed to replace that
test file and passed independently and in the final host run. Initial focused
runs passed 8, 4 and 19 tests respectively. The final image-cancellation pair
passed independently. No implementation failure was concealed by repeating the
full suite.

Changed scope relative to `baseline.json`: **9 modified, 3 added, 479 unchanged,
0 removed** (491 scoped files total). Modified files:

- `docs/testing-release/phase8-linux-integration.md`
- `lib/documents/files/src/sha256_adapter.dart`
- `lib/documents/pdf/pdf_backend.dart`
- `lib/documents/pdf/src/linux/linux_pdf_backend.dart`
- `lib/documents/pdf/src/linux/linux_pdf_protocol.dart`
- `lib/documents/pdf/src/linux/linux_pdf_resources.dart`
- `lib/documents/pdf/src/linux/linux_pdf_supervisor.dart`
- `lib/ui/canvas/phase6_canvas.dart`
- `test/support/pdf_linux_integration_checks.dart`

Added files:

- `lib/documents/pdf/src/linux/linux_pdf_isolate.dart`
- `lib/ui/canvas/pdf_raster_image.dart`
- `test/documents/linux_pdf_correction_test.dart`

The admission registry/guard, main debug/release gates, dependency versions and
lockfile, native worker/engine/guard/transport, package manifest and pin, CMake,
geometry, coordinator/history and CI remain byte-identical to the starting
snapshot. No commit, push, tag, PR or publication was performed.

### Remaining limitations and cleanup status

A permanently inaccessible controller deliberately leaves the backend
cleanup-unconfirmed and unavailable, even after its service runtime ceiling.
It cannot safely infer cleanup from elapsed time. Recovery requires a successful
controller state/emptiness check; the retained operation does not block the UI.
Cold preparation still costs roughly 0.6–0.8 seconds on this host. Flutter native
buffer/image preparation still produces measurable stalls, up to 93.4 ms in the
final maximum-raster run. Host load and machines vary; Main AI and independent
review must assess the interaction targets before claiming performance readiness.
Application-process crashes, catastrophic isolate/OOM failure and hostile
same-user host compromise were not newly injected or audited.

Both unchanged disconnect harness runs performed their external service kill,
inactive/failed wait, reset and no-running-service assertion in `finally`. Because
they intentionally killed the blocked auditor process, they left two private
runtime directories: `/tmp/alnote-pdf-NQWZGK` and `/tmp/alnote-pdf-XDHAAR`.
Their creation times and mode-6 diagnostic contents identify these correction
runs. The five pre-existing runtime directories were preserved.

**Final housekeeping is blocked:** automatic approval review rejected the
combined final read-only worker/cgroup check and deletion of those two known
audit runtime directories because the account usage limit was reached. That
rejected command did not execute. The two directories remain; no final independent
controller/cgroup check after the harness cleanup is claimed. All application,
regression, analysis, formatting and Linux build verification above had already
completed successfully. Do not bypass the rejection; finish this explicit
housekeeping when tool approval is available.

Ordinary-PDF admission and release quarantine remain unchanged. Stop here for
Main AI and independent recheck; this correction is not Phase 8/release approval.
