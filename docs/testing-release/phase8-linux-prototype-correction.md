# Linux prototype parent-boundary correction

Implemented the three blockers in `/tmp/al-note-linux-independent/report.md`.
This is a focused correction for independent recheck, not integration approval.
The external prototype remains outside application composition and ordinary-PDF
admission. No engine, guard, dependency, lockfile, CI or admission changes.

## Root causes and correction

1. **Incomplete input transport.** Broken stdin previously closed the stream
   without recording rejection; successful exit plus valid output could publish
   a response with request bytes still pending. The parent now rejects broken or
   zero-byte writes, rejects final metadata while input is pending, and requires
   both exhaustion of all four input frames and the exact declared total byte
   count at the final success gate. The same immutable source memoryview and
   bounded writes remain. No queue, source reread or parser copy was introduced.
2. **Integer type confusion.** Python equality accepts `True == 1 == 1.0`.
   Version, request ID, raster width/height and raster byte length now require
   `type(value) is int` before their existing exact-value/size checks. Optional
   microsecond timing fields, when present, also require nonnegative exact
   integers. Rotation and request integer checks remain exact. Physical geometry
   still permits bounded finite integers/floats; no geometry tolerance changed.
3. **Oversized geometry.** `math.isfinite` converted arbitrary-precision JSON
   integers before the magnitude bound and could raise `OverflowError`. Type
   and magnitude checks now precede conversion. The same ordering applies to
   timeout/cancellation arguments. Numeric overflow also enters the existing
   structured worker rejection path as defense in depth. The 401-digit worker
   coordinate now returns `ok: false`, `reason: invalid coordinates`, no frames.
   Direct `geometry` callers receive its established `ValueError` validation
   exception, rather than an unhandled conversion `OverflowError`.

All three worker-output failures enter the existing kill/wait, stream/selector
close, service-state and cgroup-empty verification, and unit-reset path before
return. Partial output is never returned on rejection. Missing containment
support continues to fail closed; there is no in-process fallback.

## Exact correction scope

Three existing files modified:

- `tool/linux_pdf/run_pdf.py`: only parent transport/type/numeric validation.
- `tool/linux_pdf/check_failure.py`: three fixed protocol failure controls using
  the diagnostic worker; the original five failure controls remain.
- `test/support/pdf_linux_prototype_checks.dart`: register those three additional
  cases in the existing full Canvas state-retention harness and correct a comment.

Three files added:

- `tool/linux_pdf/protocol_probe.c`: maintained diagnostic derived from the
  auditor's worker; no PDF parser. Uses the existing actual seccomp guard and
  real host launcher, including hostile descendants and input/output failures.
- `tool/linux_pdf/test_protocol.py`: numeric and opt-in real-host regressions,
  including a valid existing AOT worker inspection/render control.
- This correction report.

No other pre-existing file content changed from the 464-file correction baseline.
The baseline/final hashes and Git state are in
`/tmp/al-note-linux-correction/{baseline,final-scope}.json`.

## Personally executed evidence

Evidence directory: `/tmp/al-note-linux-correction/`.

- **Original audit reproducers, unchanged, before and after:**
  `early_response.py` and `hostile_boundary.py` cover all three findings. Before:
  incomplete request accepted with only **61,535 bytes transmitted** for a
  1,000,000-byte source; boolean/float metadata accepted; 401-digit geometry raised
  `OverflowError`. After: all reject with empty output and confirmed stopped
  services. The early-response script deliberately asserts the vulnerable
  behavior, so its unchanged post-fix run exits **1 with AssertionError** because
  it receives the correct structured rejection. This is not claimed as a passing
  exit status. All **26** boundary scenarios match the corrected expectations;
  both valid controls still succeed. The tiny `valid-without-input` control can
  fully fit in transport buffers; transmission does not prove worker consumption.
  Original script/C hashes are unchanged. Logs: `before-early.log`,
  `before-boundary.log`, `after-early.log`, `after-boundary.log`; structured final
  results: `after-early.json`, `after-boundary.json`.
- **Auditor's direct geometry expression, unchanged:** exits 1 with the intended
  `ValueError: invalid coordinates`, recorded in `direct-geometry.log`. Its real
  worker equivalent returns structured rejection as above.
- **11 permanent protocol/numeric tests pass** (`protocol-final.log`), with real
  launches for boolean/integral-float IDs/dimensions/lengths, invalid optional
  integer timings, enormous coordinates/extents, plausible success on incomplete
  transport, immediate exit, truncated/invalid/non-UTF-8/oversized/excess output,
  nonzero exit, hang, closed output, stderr flood, descendant cancellation and
  restart. Rejections assert empty frames, stopped service, reaped launcher,
  no remaining members in the observed cgroup, and unchanged parent FD count.
  Zero-byte/BrokenPipe writes are additionally injected into a real launch for
  deterministic branch coverage. Other hostile transport cases use real writes.
- **Real AOT worker control passes** within those 11 tests: locally generated
  ordinary text/graphics, three inspected pages, successful **400×300 RGBA**
  render, **480,000 bytes**, fully opaque and nonuniform pixel values; exit zero
  and full input transmission. Pixel SHA-256:
  `94e5a3dc9e8d62a8c6a6b0153adf68369ddaf9be60ec3ae586cb13a47c6d4efd`.
- **Four existing receiving/limit tests pass** (`existing-receiving.log`): exact
  geometry, finite wall clock, missing isolation support, oversize prelaunch input.
- **Eight real-host Canvas failure tests pass** (`canvas.log`): original malformed,
  timeout, cancellation, missing-worker and missing-limit cases plus short input,
  integer metadata and oversized coordinates. All preserve authoritative owner/
  revisions, saved bytes, live editor/draft, Selection, retained history, UUID
  count and zero coordinator observer publication. Metadata/geometry diagnostic
  failures also launch descendants for cleanup verification.
- New C diagnostic compiles with GCC `-std=c11 -O2 -Wall -Wextra -Werror`, linked
  against the unchanged guard source. No native engine/AOT worker rebuild.
- Dart formatting: one changed test file, zero formatting changes. Python AST
  parsing and trailing-whitespace checks pass; `git diff --check` passes.
  `flutter analyze --no-pub --fatal-infos`: **no issues**, `analysis.log`.

An initial protocol-suite run failed only because the new test observer asserted
that a cgroup must still exist after an immediate worker exit. That observer now
records a cgroup when present and lets the real readiness validator reject missing
limits. The entire affected protocol suite was rerun after this test fix and an
additional deterministic broken-write case: **11/11 pass**, no skips. No parent
code changed after the first complete regression runs. Canvas tests ran once
with all eight final cases; the four existing checks and analysis/formatting ran
once after final changes. Only documentation/scope records were added afterward.

Not rerun: unchanged engine builds or provenance/authentication tests/research,
full containment diagnostic suite, broad geometry matrix, full Flutter suite,
browser checks or any platform/application builds. The focused audit protocol
cases include the affected cleanup paths. These omissions follow the requested
bounded correction scope.

## Reproduction

Run from the repository root. Existing controlled engine, `pdf-worker` and
`libguard.so` artifacts from the prior prototype must be present. Only the new
small diagnostic needs compilation; use the actual Bazzite host for Python.

```sh
distrobox enter al-note-dev -- gcc -std=c11 -O2 -Wall -Wextra -Werror tool/linux_pdf/protocol_probe.c tool/linux_pdf/sandbox_guard.c -o /tmp/al-note-linux-prototype/protocol-worker
ALNOTE_PROTOCOL_WORKER=/tmp/al-note-linux-prototype/protocol-worker PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/linux_pdf -p test_protocol.py -v
PYTHONPATH=tool/linux_pdf PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_verification.VerificationTest.test_receiving_geometry_stays_exact test_verification.VerificationTest.test_wall_clock_cannot_be_disabled test_verification.VerificationTest.test_missing_isolation_support test_verification.VerificationTest.test_oversize_request_before_launch
distrobox enter al-note-dev -- flutter test --no-pub --dart-define=ALNOTE_LINUX_PDF_PROTOTYPE=true test/widget_test.dart --name 'PDF isolated Linux failure retains Canvas state' --reporter expanded
```

## Remaining limitations

Full transmission is a necessary transport invariant, not proof that a hostile
worker parsed or consumed every byte. Tests use public/generated data and a
controlled diagnostic. They do not establish arbitrary-PDF safety or eliminate
kernel-uninterruptible work, host compromise, scheduling overshoot or the existing
syscall-denylist threat-model limits. The Canvas test adapter deliberately maps
these failures to `PdfCorrupt`; it does not establish production error mapping or
successful application integration. Executable packaging/authentication and the
remaining integration requirements in the independent report are unchanged.

Preserved branch `phase-8-pdf-system`, HEAD
`921e43f41a31b0649a2ae890c993fd4e406ad39a`, and zero staged changes. No app
integration, ordinary-PDF enablement, upgrades, commits, pushes or publication.
Stop for independent recheck.
