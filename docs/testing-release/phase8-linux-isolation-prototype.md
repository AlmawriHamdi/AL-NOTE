# Phase 8 — verified Linux engine and isolation prototype

**GO for a separately reviewed Linux integration change. Ordinary-PDF opening
in the application remains NO-GO and unchanged.** This prototype proves the
existing patched pdfrx engine can inspect and render in a restricted subprocess.
It is not a packaged production backend or a hostile-input security certification.

Baseline: `phase-8-pdf-system`, HEAD
`921e43f41a31b0649a2ae890c993fd4e406ad39a`. The accepted correction reports,
consolidated independent approval and prior ordinary-PDF proposal were read.
The implementation used the recovered `al-note-dev`: Flutter 3.44.6, Dart 3.12.2,
Ubuntu GCC 13.3.0. Execution containment was tested on the actual Bazzite host,
44.20260713.0, kernel `7.1.3-ogc3.4.fc44.x86_64`, bubblewrap 0.11.0 and systemd
259.7. Distrobox supplied build/test tools; it was not the parser sandbox.

## Engine authentication and controlled build

The proposed [PDFium 155.0.8044.0 release](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F8044)
was evaluated before engine execution. These are distinct identities:

| Item | Exact identity |
| --- | --- |
| PDFium source | `f91ca5a72358bb0b00b4da9481b21fe668157614` |
| Distributor recipe | `5453f3afc4785cbad82c05f6ceb4dabea0cb81a0` |
| Publisher Linux x64 archive SHA-256 | `eb142f416aed3a72fc5a02dbd5884868a16cb99dc0cf53e6bdd64afbf67b05f4` |
| Library inside that archive SHA-256 | `b0361f8ba0bc6ffeb2325949a88f08b09356f46abe257ffdf846202999daa27b` |
| **Controlled library actually executed** SHA-256 | **`d9c4c59ee98575e4be174a86a64834c91dff1aa5c9ad20604308f31cc05a7d8a`** |

Installed cosign 3.1.1 verified the publisher's SLSA/Sigstore bundle, including
transparency-log verification, against the exact workflow identity
`https://github.com/bblanchon/pdfium-binaries/.github/workflows/build-all.yml@refs/heads/master`,
issuer `https://token.actions.githubusercontent.com` and recipe commit above.
The signed subject matches the archive digest. No insecure verification switches
were used. Subsequent offline checks use the exact trusted-root snapshot obtained
by the successful TUF-backed verification, pinned to SHA-256
`6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66`.
One later online verification failed on DNS; it did not grant trust. The pinned
offline check passed. Root rotation requires review, not automatic hash changes.

**Publisher provenance gap:** the signed payload binds the workflow/recipe but
does not record the PDFium checkout SHA. Public job-log retrieval returned
403/404. The branch declaration alone was not promoted to exact source proof.
The publisher library was extracted for static inspection but **never loaded or
executed**. Its manifest retains `source_correspondence_verified: false` and
`verify_engine.py --require-executable` rejects it.

The authorized controlled-build alternative was therefore used. PDFium was
checked out at the exact source commit; its DEPS-pinned dependencies were fetched
with hooks disabled. Depot tools were pinned to
`d4e958941a37fee7df84d21c0851068285291443`, automatic updates disabled. Its bootstrap
CIPD client matched the source-pinned SHA-256
`11a383b48744870d96365192b92992650b695eedf3a745615948b8d6561834ed`.
The optional broad infrastructure bootstrap was stopped and configuration used
the existing container Python. No OS packages were installed.

The compiler came from the source DEPS pin
`llvmorg-24-init-3796-g20e97c4b-4`; its archive matched
`565f7d980b31411e76d9478731cf3f0ac907a46f274d289ea7f03d9137354053`.
Gclient checks declared GCS digests before extraction. The controlled manifest
retains 41 actual dependency-revision entries, including exact CIPD instances.

Only the distributor's `shared_library.patch` was applied to the controlled
PDFium checkout, SHA-256
`0fbc6207a5c9da8528914418598a494a3ed358ccb8ee91c8b3f8c1f95ab84057`.
It changes the shared-library target/export declarations in `BUILD.gn` and
`public/fpdfview.h`; no parser algorithm was edited. Other distributor platform
patches were unnecessary for this Linux build. The source revision, patch,
compiler, arguments, dependency inventory and successful 1194-step Ninja build
establish local source/build correspondence. This is **local controlled-build
evidence**, not publisher attestation or a bit-reproducibility claim.

`tool/linux_pdf/controlled_engine.json` freezes the resulting expected library
digest. Runtime staging rechecks that digest before making the library available
to the worker. A rebuilt or downloaded library with different bytes fails closed;
the tooling never automatically rewrites an expected digest.

Build flags retain non-V8/non-XFA, AGG rendering and disabled PartitionAlloc.
`use_sysroot=false` uses the existing container headers; the full arguments and
compiler pin are recorded. No Chrome renderer sandbox or Chrome allocator
hardening is implied. Thirteen corresponding source notices were retained under
`build/linux-pdf-controlled/notices/`, with source/staged hashes in the manifest.
Release packaging still needs an OS-runtime notice inventory and distribution
review. No binaries or notices were published.

## Relevant fixes and compatibility

The [July 29 upstream advisory](https://chromereleases.googleblog.com/2026/07/stable-channel-update-for-desktop_0887107924.html)
maps CVE-2026-17875 to issue 522299155 and CVE-2026-18012 to issue 522938824.
The proposed source history contains their explicit fix commits:

- [`7c53431c7e353de36f70df5fddd0e397ad9d79cf`](https://pdfium.googlesource.com/pdfium/+/7c53431c7e353de36f70df5fddd0e397ad9d79cf):
  retain/swap existing name-tree objects instead of destroying objects behind
  outstanding pointers. The controlled checkout contains the corrected body.
- [`ee47c0ef8b813c8c681643688e9e425e87ee391f`](https://pdfium.googlesource.com/pdfium/+/ee47c0ef8b813c8c681643688e9e425e87ee391f):
  clear additional XFA/JavaScript bindings on destruction. The source contains
  this correction; XFA/V8 are excluded from this build.

This proves the cited source corrections, not exploitability of the previous
AL NOTE artifacts or absence of other vulnerabilities. No exhaustive CVE audit
or attack PDF was used.

The existing pdfrx 2.4.8 / pdfrx_engine 0.4.7 / pdfium_dart 0.2.5 graph, lockfile
and all five accepted vendor patches remain unchanged. Static export checks and
actual execution confirm the required native ABI, including bounding boxes,
rotation, memory opening, rendering and disposal. The AOT worker uses the
existing patched `pdfrx_engine`, not a newly written PDF parser.

The accepted 40 exact fixture byte sequences were reused with their known
resolved bounds, rotations and asymmetric marked-centroid expectations:
**36 rendered cases pass; four disjoint cases reject**. Inherited/negative,
contained/overlapping/oversized/reversed and fractional geometry at all four
rotations pass. Fractional endpoints retain binary32 evidence, with the same
single-rounded extent check; receiving geometry remains exact. Both colored
centroids must agree within the accepted 0.6-pixel raster quantization bound.

Each successful operation explicitly disposes its image/document, checks the
backing-release callback occurred exactly once, and stops PDFium's background
isolate before exit. The parent requires successful exit before returning any
result. Native disposal follows the reviewed wrapper's form-exit/document-close
order. This does not rerun or newly certify the unchanged Web initialization
cleanup matrix; no WASM asset or Web source changed.

Two locally generated, non-allowlisted PDFs were exercised only after the
containment checks passed: an ordinary three-page Helvetica/Flate/graphics file,
and a three-page repeated-graphics cancellation control. Their generators and
digests are retained in the probe/results. Text and graphics pixels are checked.
Malformed controls reject, and valid operations succeed after rejection and
cancellation. No private user PDF was accessed.

## Isolation and communication

The prototype supervisor is Python tooling; parsing lives in a separate AOT Dart
executable. This is not application composition or a general sandbox framework.
Each operation has its own transient systemd user service and bubblewrap process.

- Separate user/PID/network/IPC namespaces, cleared environment, dropped
  capabilities, new session, private `/tmp`, no home mounts or session/display
  sockets. Only the worker, guard, checked engine and required runtime libraries
  are staged read-only. Private proc/dev mounts support the runtime. Kernel
  metadata remains visible; host home files and application documents do not.
- A narrow syscall denylist blocks networking/socket creation, execution,
  namespace/mount changes and selected process/kernel interfaces. TSYNC applies
  it to existing threads; later threads inherit it. This is not a complete
  syscall allowlist or a claim against kernel exploits.
- PDF workers have **1 GiB memory, zero swap, 32 tasks**, disabled core dumps,
  64 file descriptors and a default **30-second service runtime ceiling**.
  The caller cannot disable the finite ceiling. The supervisor reads actual
  `memory.max`, `memory.swap.max` and `pids.max` before sending any request byte.
  Missing binaries, worker, controller evidence or mismatched limits reject.
- Input is immutable bytes, at most 50,000,000 bytes; writes are at most 64 KiB.
  Request headers are bounded, versioned and identified. Pages are capped at
  1000; raster dimensions at 4096 each. Parent validation checks finite/exact
  geometry, identifiers, dimensions, frame lengths and expected RGBA byte count.
  Metadata frames are capped at 256 KiB, diagnostics at 4 KiB, and raster output
  at the requested size (maximum 64 MiB). No paths/handles cross the PDF protocol.
- Cancellation kills the entire service cgroup and reaps the launcher. A separate
  parent watchdog covers service/transport failure. Truncated, malformed, excess
  or failed output is discarded. No partial image is returned, and there is no
  in-process parser fallback. One call handles one operation and has no retry
  queue. Application-level latest-request admission remains future integration
  work; the approved existing guard is untouched.

The 10-case host diagnostic proves home/session/display absence, read-only
runtime, cleared environment, disabled core dumps, networking denial in both
the main thread and a thread created before filtering, process exhaustion,
memory OOM termination, timeout, cancellation/reaping, crash, malformed/excess
output rejection, restart and missing-worker rejection. Its smaller test ceiling
is 64 MiB/16 tasks: 13 children were admitted before fork returned EAGAIN, and
memory pressure produced systemd `oom-kill`. The real PDF path independently
confirms its 1 GiB/32-task limits before input transfer.

Five opt-in actual Canvas tests use a test-only backend to translate real
isolated-worker failures into the existing `PdfCorrupt` rejection outcome. They
cover malformed input, timeout, cancellation under native load, missing worker
and missing-limit evidence. Assertions retain the authoritative snapshot and
revisions, nonempty saved bytes, edited live draft, Selection, history, UUID
count and zero coordinator publications. This proves the failure boundary; it
does not implement successful ordinary-PDF opening in application composition.

## Measurements and checks

Final controlled-fixture run on this host:

| Measurement | Observed |
| --- | --- |
| Worker startup, 36 renders | median 33.87 ms; 26.68–85.48 ms |
| Inspection service round trip, 37 small cases | median 74.04 ms |
| Render service round trip, 37 small cases | median 76.38 ms |
| Worker inspection phase | median 0.349 ms |
| Worker render/conversion phase | median 0.781 ms |
| Ordinary three-page file | inspect 74.04 ms; render 138.30 ms |
| Heavy control | 46,751 encoded bytes; 1,373.90 ms round trip |
| Heavy cancellation after complete input transfer + 50 ms | 23.78 ms from kill request through reap; no image returned |
| Diagnostic 0.8-second service ceiling | systemd `timeout`; 1,028.96 ms through reap |

These are measured wall-clock/process and worker Stopwatch intervals, not
predictions for arbitrary PDFs. Round trips exclude runtime-file staging and
post-reap status/reset commands. The heavy operation includes inspection,
rendering and cleanup; cancellation is not attributed to a particular native
instruction. Timer granularity/stop grace explain timeout overshoot; no strict
microsecond deadline or termination of kernel-uninterruptible tasks is claimed.

Verification evidence under `/tmp/al-note-linux-prototype/`:

| Check | Result / log |
| --- | --- |
| Publisher authentication | `Verified OK`, `cosign.log`, `verification-tool-offline.log` |
| Controlled native build | 1194 steps, `native-build.log`; worker `dart-worker-build.log` |
| Final host containment | 10 cases, `final-containment.log`, `final-containment/containment.json` |
| Isolated geometry/ordinary/heavy controls | pass, `final-compatibility.log`, `final-compatibility/pdf-results.json` |
| Authentication/acquisition/receiving-limit tests | 12 passed, `final-verification-tests.log` |
| Broader PDF Canvas selection | 59 passed, `final-pdf-widgets.log` |
| PDF model/admission/workflow selection | 37 passed, `final-pdf-contracts.log` |
| Final affected Canvas rerun | 5 passed, `final-isolated-widgets.log`; `failure-*.json` |
| Fatal-info analysis | no issues, `final-analysis.log` |
| Dart formatting | three files, zero changes, `final-format.log` |
| Native/Python checks | GCC `-Wall -Wextra -Werror`; Python AST checks and tests; whitespace check |

Focused iterations found/fixed a test-harness clock wait and analyzer issues in
new test code. No application defect was found. After the 59/37 selections,
tool-only refinements tightened cgroup handshaking, runtime staging and native
cancellation/finite-timeout checks. Affected native/verification/Canvas tests were
rerun; **the 59/37 broader selections were not repeated**. The full app suite and
Linux/Web/Android application builds were not run in this prototype task: no
application, dependency, vendor or platform source changed. No unchanged vendor,
Web, Android or Windows audit was repeated. An automatic approval-service timeout
delayed one final test launch; its permitted retry started and passed.

## Independent reproduction

Run from the repository root. Existing evidence and controlled build outputs are
retained locally; these commands neither enroll fixtures nor enable the app:

```sh
python3 tool/linux_pdf/verify_engine.py /tmp/al-note-linux-prototype --trusted-root /tmp/al-note-linux-prototype/trusted_root.json
python3 tool/linux_pdf/test_verification.py
distrobox enter al-note-dev -- gcc -std=c11 -O2 -Wall -Wextra -Werror -pthread tool/linux_pdf/sandbox_probe.c tool/linux_pdf/sandbox_guard.c -o /tmp/al-note-linux-prototype/sandbox-probe
distrobox enter al-note-dev -- gcc -std=c11 -O2 -Wall -Wextra -Werror -fPIC -shared tool/linux_pdf/sandbox_guard.c -o /tmp/al-note-linux-prototype/libguard.so
distrobox enter al-note-dev -- dart compile exe --packages=.dart_tool/package_config.json tool/linux_pdf/worker.dart -o /tmp/al-note-linux-prototype/pdf-worker
python3 tool/linux_pdf/check_containment.py --probe /tmp/al-note-linux-prototype/sandbox-probe --output /tmp/al-note-linux-auditor-containment
python3 tool/linux_pdf/check_pdf.py --worker /tmp/al-note-linux-prototype/pdf-worker --guard /tmp/al-note-linux-prototype/libguard.so --library build/linux-pdf-controlled/pdfium/out/alnote/libpdfium.so --output /tmp/al-note-linux-auditor-pdf
distrobox enter al-note-dev -- flutter test --no-pub --dart-define=ALNOTE_LINUX_PDF_PROTOTYPE=true test/widget_test.dart --name 'PDF isolated Linux failure retains Canvas state'
```

The two Python containment/PDF commands execute on **Bazzite**, not inside
Distrobox. The opt-in widget harness uses `distrobox-host-exec` for this boundary.
Run containment before non-allowlisted PDF checks. Expected negative check:
add `--require-executable` to publisher verification and observe rejection for
unbound source provenance. `fetch_engine.py` optionally acquires this same
candidate with bounded downloads and verification of both new and cached bytes;
it only stages quarantined artifacts and never loads them.

For a clean controlled rebuild, use a new build directory: fetch the exact depot
tools and PDFium commits above, disable `DEPOT_TOOLS_UPDATE`, and set
`VPYTHON_BYPASS='manually managed python not supported by chrome operations'` to
use the existing container Python. Configure `gclient` with unmanaged solution
`pdfium`, URL `https://pdfium.googlesource.com/pdfium.git`, custom variable
`checkout_configuration=minimal`. Run `gclient sync --nohooks --no-history
--shallow --revision pdfium@f91ca5a72358bb0b00b4da9481b21fe668157614 -j 4`.
Compare `gclient revinfo --actual` to the recorded manifest. Apply only the exact
shared-library patch from the pinned distributor recipe, generate LASTCHANGE
with `python3 build/util/lastchange.py -o build/util/LASTCHANGE`, and run the
checked-out `buildtools/linux64/gn gen out/alnote` using the manifest's `args_gn`.
Build with container `ninja -C out/alnote -j 4 pdfium`. Compare hashes/source
evidence; **do not auto-approve a different rebuild digest**. Source acquisition
and toolchain files remain in ignored `build/linux-pdf-controlled/` (several GB).

## Scope, limitations and next integration

Exactly one baseline file changed: `test/widget_test.dart`, two registration
lines for the opt-in test part. Fourteen files were added: this report,
`test/support/pdf_linux_prototype_checks.dart`, and the twelve files under
`tool/linux_pdf/`. All other 449 baseline files retain their hashes. Removing
the two test-registration lines reproduces that file's baseline hash.
The source/build/provenance artifacts are under ignored build and `/tmp` paths.
The final machine-readable scope/status record is
`/tmp/al-note-linux-prototype/final-scope.json`.

Expected final Git status: **241 tracked modifications, 196 untracked files,
zero staged changes**; branch/HEAD unchanged. These counts include all preserved
pre-existing work, not just this prototype. No commit, push, PR change, merge,
tag, branch deletion, CI edit or release enablement occurred.

Remaining ordinary-Linux work is application integration and packaging: replace
the test/Python supervision bridge with the reviewed application-owned launcher
and backend mapping; preserve the existing one-active/one-latest admission,
immutable identity and cancellation/publication rules; package/verify worker,
guard, engine and runtime resources; review the syscall policy independently;
test real picker/lifecycle/save/reopen routes and a wider controlled compatibility
corpus. Only then propose the separate admission-policy change. The production
native-asset hook and exact-fixture gate are unchanged in this task.

This prototype uses one process/document per operation and full-page renders;
it does not promise production zoom latency, broad font compatibility, clipped
rendering integration, extraction, password handling or a persistent document
cache. The existing model/history/save behavior is preserved. Worker failures
and resource excess are contained within the tested limits, but kernel/runtime
vulnerabilities, malicious engine output, resource pressure outside the worker
and all arbitrary-PDF behavior are not eliminated. Parent IPC remains a security
boundary requiring independent review. Android/Windows/Web ordinary-input
enablement and public release remain separate work. Stop for Main AI and
independent review.
