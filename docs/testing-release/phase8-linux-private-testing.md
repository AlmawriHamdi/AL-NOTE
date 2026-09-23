# Private Linux ordinary-PDF testing — implementation and verification

Implementation and requested verification are complete; ready for focused independent review.
Private debug testing only. Independent review and user acceptance testing remain
separate gates; this change does not approve Version 1 distribution or ordinary
PDFs in release builds. Linux and Android remain V1 targets; Android implementation
is a separate task. Windows/Web ordinary-PDF support remains deferred.

## Exact implementation scope

The original fixture decisions existed independently in the open workflow,
production guard and Canvas. Larger sources would also run repeated generic-list
capture and SHA-256 work on the UI isolate. The worker's single generic rejection
could not distinguish known document failures from missing isolation support.

- `ALNOTE_LINUX_PRIVATE_PDF_TEST` defaults off. The isolated factory requires
  Linux x86-64 and debug mode (neither product nor profile). The existing main
  composition still uses `QuarantinedPdfBackend` outside debug builds.
- Only the isolated Linux factory constructs the private admission capability.
  `Phase6CanvasRuntime` and the opening workflow obtain policy from that backend;
  Canvas applies it again when rendering reopened saved state. Ordinary requests
  remain `PdfInputTrust.untrusted`. Request trust flags and document metadata
  cannot grant the capability. The fixture digest registry and in-process adapter
  are unchanged.
- The reviewed scheduler was extracted and shared: one active operation, one
  latest render interest, synchronous reservation before notification, cancelled
  and superseded listeners removed. Pending render interest captures no source.
  Inspection reports a distinct busy outcome while ownership remains held.
- The private guard caps reader admission at 50,000,000 bytes before reading.
  An opaque resource capture owns typed immutable bytes and computes its digest
  internally in cancellable background chunks. A transferable handoff replaces
  large VM graph copies; its bounded initial copy is still measurable UI work.
  Workflow construction, parser readers and resource snapshots reuse the exact
  owned bytes. Existing independent resource validation is retained, and ordinary
  resource construction also ends in immutable typed storage.
- Worker rejection reasons are closed: password required, unsupported, limit
  exceeded, or failed. Recognition requires exact version/id fields, exactly two
  complete frames, complete successful input transmission, a normal worker exit,
  confirmed service cleanup and launcher reap. Error frames cannot contain extra
  details or raster output. Unknown exits remain generic processing failures.
- Missing/unverified isolation is reported separately. Cleanup-unconfirmed state
  reaches Canvas while ownership remains held; opening is disabled until cleanup
  is confirmed. Lifecycle observers cannot release operation ownership and are
  detached on disposal. Page failure is visible without replacing the document.
- The worker was rebuilt and the manifest/CMake/Dart pins updated. The candidate
  manifest differs only in the worker entry. Engine, guard, transport, runtime
  libraries, notices, dependency versions and lockfile are unchanged.

No changes to draft commit/publication ordering, history, UUID derivation,
Selection, saved-state behavior, geometry/precision, engine containment or Web
cleanup were required. All earlier uncommitted work is preserved. There were no
commits, pushes, releases or dependency upgrades.

## Package identity

Worker SHA-256:
`4ac43854c1aff531a0ec876fe5868d2b557ecae346a7b0ff6ae820b9fdc0ad88`

Manifest SHA-256:
`34c8908a55689bdd7f8a8795c0e32fe59eccf86dfea8aa71972649be38ab4824`

The previous package is retained at `build/linux-pdf-resources-before-private`.
The previous worker and pin files, inert candidate, exact manifest diff, baseline
hashes and verification logs are in `/tmp/al-note-linux-private-enablement/`.
`scope.json` records the exact incremental source changes against that baseline:
17 existing files changed, 17 files added, none removed; 474 baseline files are
unchanged. Main composition, the legacy adapter, fixture registry, dependency
files, CI, Android sources and accepted geometry/precision files remain unchanged.

## Verification actually run

- **Full suite: 831 passed, 14 skipped**, run once at the final shared production
  code state. Skips are explicit host/private opt-ins. `full-suite.log`.
- **Formatting: 212 Dart files, zero changes. Fatal-info analysis: no issues.**
  Final checks were repeated after the test-only refinements below;
  `format-handoff.log` and `analysis-handoff.log`.
- **Linux debug private build passed. Affected Web release compilation passed**
  with the private define supplied; its ordinary admission remains disabled.
  Web emitted a nonfatal CupertinoIcons font notice; no font/dependency changes
  were made. No Android/Windows build or full Linux release-app build was run.
- Admission probes: debug-on, profile-off, actual compiled product-off, and
  compiled Web-off executed successfully. The Web probe ran in existing headless
  Chrome. Windows is excluded by the Linux-only factory branch; no Windows binary
  was executed. After the architecture test expectation was made explicitly x86-64,
  source/gate tests passed again: flag off **4 passed/1 skipped**, flag on **5 passed**.
- Focused development runs: fixture/workflow/protocol **14 passed/5 skipped**;
  resource integrity/source **28 passed**; Canvas guard/draft/observer/message/cleanup
  **60 passed** before the last busy-message case; final preflight **13 passed**.
  The additional busy-message case passed in the full suite.
- Actual-host installed-package private tests: **4 passed**, covering ordinary
  text/scan/mixed open/render/exact source reuse; password, unsupported encryption,
  page-limit and malformed failures with recovery; cancelled/stale opening; and
  exact 50 MB input through final native image with repeated preparation cancellation.
- Actual-host private Canvas tests: **3 passed**, covering live draft success,
  navigation/zoom/save-reopen, missing-package state retention, and in-flight
  disposal/reaping. These existing Canvas helpers use the canonical verified
  package; its bytes match the installed package used by the four tests above.
- Affected default/fixture host tests: **16 passed initially**; the protocol test
  passed after its old infrastructure-exception assertions were updated. Its
  final matrix covers **19 hostile cases**, including recognized rejection frames
  after short input, abnormal exit and cancellation, plus two missing-prerequisite
  cases. All remaining workers are reaped before rejection returns.
- The **8 existing prototype Canvas probes passed** from their required container
  launcher, which invokes the actual host via `distrobox-host-exec`.
- Controller recovery confirmed **four PIDs per round**, cgroup empty and launcher
  reaped in both controller-failure/timeout rounds. Cold staging cancellation took
  **7/5/7 ms** and latest requests recovered. Exact raster/native-image checks passed
  through 4096 square pixels; the largest measured heartbeat gap was **89,397 us**.
- Final host inventory: **zero registered worker units and zero matching worker
  processes**. Five pre-existing staging directories were left untouched; no
  unrelated temporary data was deleted. `final-cleanup.json`.
- All **114 installed package files** match the pinned manifest. The Linux SDK
  header is present and matches the SDK; CMake still uses `/home/.../AL-NOTE/linux`.
- A relocated copy of the installed package passed **8 real-worker operations**
  through the existing fixed-fixture AOT diagnostic, using default executable-relative
  discovery from `/tmp`. End-to-end operation times were **830–1,102 ms**. This
  diagnostic is not an alternate application admission route.

The full suite was **not rerun** after subsequent **test-only** changes: explicit
x86-64 gate expectation, three additional rejection-frame cases, and updated
assertions for the new infrastructure outcome. Their affected tests and final
formatting/analysis were rerun. Production code, worker and pins did not change
after the full suite, so the Linux/Web builds were not repeated. No engine, guard,
transport, dependency or unrelated vendor audit/build was repeated.

### Failed attempts retained in evidence

One focused command named nonexistent `resources_test.dart`: four source tests
passed, but that command failed to load the nonexistent file. The corrected
`json_resource_test.dart` command passed all 28 tests. Initial analysis found
import-ordering infos and then one unnecessary-async info; both were fixed before
the full suite.

An initial affected-host batch finished with 16 passes and nine failures: one
protocol test still expected generic `FormatException` for pre-readiness failure,
and eight prototype tests were invoked on the host despite requiring the container
launcher. A protocol-only retry reached two further outdated missing-prerequisite
assertions. Those assertions now require `LinuxPdfIsolationUnavailable`; all 19
hostile cases and both prerequisite cases passed in `host-protocol-final.log`.
The eight environment-misplaced tests passed in `prototype-canvas-recheck.log`.
These were test expectation/execution corrections, not ignored production failures.

## Timing and memory evidence

All times are observations on this host, not latency guarantees. The final private
run was serial, with external 10-ms worker-cgroup sampling. No other task build or
PDF test ran concurrently.

| Scenario | Observation |
|---|---:|
| Initial rebuilt-worker inspect/render control, including staging/cleanup | 1,378 / 1,130 ms |
| Final installed ordinary text / scan / mixed open through native image | 9,682 / 861 / 964 ms |
| Exact 50,000,000-byte open | 3,740 ms |
| Same input through 400 × 300 native image | 5,892 ms |
| Same complete path, maximum 1-ms heartbeat gap | 102,292 us |
| Sampled parent RSS peak / reported parent maximum RSS | 469,114,880 / 507,469,824 bytes |
| Highest sampled worker `memory.current` / individual `memory.peak` | 113,197,056 / 113,459,200 bytes |
| Maximum populated worker cgroups observed | 1 |
| Near-limit token-cancel to preparation completion, three rounds | 15 / 1 / <1 ms |
| Private Canvas open through first image | 2,156 ms |
| Private Canvas navigation/zoom rounds | 1,798 / 1,106 / 1,942 ms |

The first ordinary text result includes a **9.682-second spike** whose cause was
not isolated. Earlier identical text/scan/mixed observations were 1,572/841/806 ms;
the spike is retained rather than replaced with the faster numbers.

During development, the initial background-preparation implementation still used
VM graph copying at handoff: the same 50 MB open measured 5,005 ms and a 141,303-us
maximum gap. After transferable handoff, the open-only measurement was 4,461 ms
with a 78,191-us gap. The final 102,292-us result above includes rendering and image
preparation as well. This is **not** evidence of smooth-frame delivery. Cancellation
numbers start when the cancellation token is signalled; queued user input can also
experience the measured UI gap. Parent RSS and worker cgroup accounting are
separate measurements and are not a simultaneous total-process-tree peak.

`host-installed-private.log`, `host-worker-memory.json`,
`installed-package-verification.json`, `relocated-installed-results.json`,
`host-affected-final.log` and the final rerun logs contain the underlying evidence.

## Build in the development container

Use `/home/Hamdi/Projacts/AL-NOTE` consistently. Do not use `flutter clean`, switch
repository path aliases, or remove protected PDF build resources. See
`/tmp/al-note-linux-generated-repair/report.md` for the prior alias-cleanup defect.

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && exec /home/Hamdi/Development/flutter-3.44.6/bin/flutter build linux --debug --no-pub --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true'
```

The verified `build/linux-pdf-resources` package must already exist. Rebuilding
only this worker (when reproducing the exact reviewed code/dependencies):

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && exec /home/Hamdi/Development/flutter-3.44.6/bin/dart compile exe --packages=.dart_tool/package_config.json tool/linux_pdf/worker.dart -o /tmp/alnote-private-worker-reproduced'
cd /home/Hamdi/Projacts/AL-NOTE
python3 tool/linux_pdf/package_resources.py --worker /tmp/alnote-private-worker-reproduced --guard build/linux-pdf-tools/libguard.so --transport build/linux-pdf-tools/transport --destination /tmp/alnote-private-package-reproduced
```

Use absent destinations. Normal packaging compares every file to the reviewed
manifest and rejects differences. Do not approve new hashes by rerunning the
candidate path blindly. Engine/guard/transport rebuilding is unnecessary here.

## Run on the actual host, after independent review

The development container builds the app. The host supplies the reviewed user
systemd/cgroup and bubblewrap isolation environment. Launch the built executable
on the host, not `flutter run` inside the container:

```sh
cd /home/Hamdi/Projacts/AL-NOTE
./build/linux/x64/debug/bundle/al_note
```

Only the reviewed Linux x86-64 host configuration is evidenced (Bazzite 44,
systemd 259.7, bubblewrap 0.11.0). No other distribution/architecture or release
installation approval is implied.

## Auditor commands

Run host tests serially so service cleanup assertions and timing measurements
are not affected by another PDF test. Installed-package private cases:

```sh
cd /home/Hamdi/Projacts/AL-NOTE
/home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true --dart-define=ALNOTE_PDF_TEST_BUNDLE=/home/Hamdi/Projacts/AL-NOTE/build/linux/x64/debug/bundle/data/pdf_linux test/documents/linux_pdf_private_test.dart test/widget_test.dart --name 'private Linux|Linux integrated' --reporter expanded
```

Affected protocol checks run on the **host**:

```sh
cd /home/Hamdi/Projacts/AL-NOTE
/home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_INTEGRATION_TEST=true test/documents/linux_pdf_integration_test.dart test/documents/linux_pdf_correction_test.dart --reporter expanded
```

The older prototype Canvas probes require the **container launcher**, which
executes their worker checks on the actual host:

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && exec /home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PDF_PROTOTYPE=true test/widget_test.dart --name "PDF isolated Linux failure" --reporter expanded'
```

`tool/linux_pdf/private_test_fixtures.py` deterministically creates the controlled
text/scan/mixed/password/encrypted/page-limit PDFs. Their manifest is evidence,
not an admission registry. The near-limit test generates exactly 50,000,000 bytes
at runtime and records input capture, opening, rendering, native image preparation,
heartbeat, parent memory and repeated preparation cancellation.

## Remaining limitations

Existing native PDF annotation and form appearances may be omitted: the worker
renders with annotations disabled. AL NOTE's existing overlays remain supported.
**Save/Reopen is currently in-memory and is not durable PDF export.**

This is bounded, unencrypted, full-page rendering. Password entry/decryption,
interactive forms, native text extraction/OCR/link activation, clipped/tiled
rendering, persistent parser caches and a 60-fps zoom guarantee are not enabled.
A fresh isolated worker per operation adds visible latency. Near-limit input was
measured at 400 × 300 output; 4096-square output was tested separately with a small
fixture, not combined with the largest input. Large in-memory Save/Reopen archive
encoding/materialization retains existing synchronous behavior and separate storage
limits; its near-limit responsiveness was not measured or improved in this task. Whole-application
crash/restart containment and installation support across distributions remain
separate distribution gates. No user acceptance testing or release approval is
claimed by the automated checks.
