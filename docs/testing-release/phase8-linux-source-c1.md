# Private Linux source capture C1 correction

C1 source correction is ready for independent recheck. This does not lift the
independent review hold or approve user acceptance testing/release admission.
Independent report: `/tmp/al-note-linux-private-independent/report.md`.
Correction evidence: `/tmp/al-note-source-c1/`.

## Root cause and exact correction

`CapturedResourceBytes.capture` checked `isEmpty` and `length`, then reread the
caller-controlled `List.length` for allocation. A changing getter could therefore
allocate and return eight captured bytes despite a two-byte receiving ceiling.
The public IO preparation wrapper also read length repeatedly before its handoff.

Only two production functions changed:

- `lib/documents/resources/resource_records.dart`:
  `CapturedResourceBytes.capture` reads source length once, validates that exact
  positive value against `maximumBytes`, and uses it for allocation and all copy
  ranges. Generic sources are read only by bounded index access. Length/index
  failures, including shrinking that invalidates an accessed index, become fixed
  `FormatException` rejections.
  Growth may succeed with the bounded captured prefix. Octets remain validated;
  cancellation checks and cooperative hashing over the owned bytes are retained.
- `lib/documents/pdf/src/pdf_source_preparation_io.dart`:
  `preparePdfSource` snapshots and validates length once at the caller boundary.
  Typed transfer uses a view with exactly that validated length and the original
  byte offset. The validated length is passed as the background receiving ceiling.
  Background capture independently snapshots/validates the received source length,
  so a changed getter cannot enlarge the initially admitted capture. Invalid
  lengths and throwing accessors produce controlled rejection.

The portable preparation path already delegates directly to corrected capture;
its production source did not need changing. This is bounded prefix capture, not
an assumption that arbitrary mutable Lists provide an atomic content snapshot.
The digest always describes the immutable bytes actually captured.

One permanent test file was added:
`test/documents/pdf_source_capture_bounds_test.dart` (21 tests across direct,
public IO and portable preparation). Tests check changing lengths at several
thresholds, single caller length reads, bounded index access, exact two-byte
backing buffers, throwing/shrinking/growing sources, invalid lengths/octets,
typed views and offsets, caller mutation, digest/immutability, cancellation and
subsequent valid recovery. The owned-buffer allocation itself now uses only the
single validated length, eliminating the unchecked eight-byte allocation path.

No admission policy, scheduler, worker, package pin, dependency, geometry, storage
implementation or save/history behavior changed. Existing work is preserved; no
commits or publication were performed. `scope.json` records before/after hashes.

## Verification

Before the fix, the auditor's unchanged file reproduced both failures:
`PUBLIC_PREPARATION captured=8 maximum=2` and
`CHANGING_LENGTH captured=8 maximum=2 reads=3`. The caller-mutation/digest check
passed. `original-before.log`: one passed, two failed as expected.

The public-preparation reproducer identified by the report's
`public-preparation-limit.log` is a test in the same
`/tmp/al-note-linux-private-independent/source_adversarial_test.dart` file. Both
original reproductions and its mutation/digest check were executed unchanged
before and after this correction; the file's SHA-256 is preserved in evidence.

After correction, both original reproductions return exactly two captured bytes;
direct capture reads source length once. The focused run passed **52 tests with
one skip**: three unchanged auditor tests, 21 new boundary tests, four existing
source/preparation checks, and 24 resource/JSON checks. The skipped test is the
unchanged opt-in private backend guard test, unrelated to this source correction.

Formatting passed for all three changed Dart files with zero changes; fatal-info
analysis passed with no issues. Results are in `format.log` and `analysis.log`. No full suite, application/engine build, packaging, broad host
or all-platform audit was rerun for C1. The existing application binary was not
rebuilt; this handoff verifies the corrected sources through focused tests.

Recheck command, using the existing development container:

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && exec /home/Hamdi/Development/flutter-3.44.6/bin/flutter test --no-pub /tmp/al-note-linux-private-independent/source_adversarial_test.dart test/documents/pdf_source_capture_bounds_test.dart test/documents/pdf_private_preparation_test.dart test/documents/files/json_resource_test.dart --reporter expanded'
```

## Separate performance findings — retained and unresolved

These are the independent auditor's measurements, not new measurements or fixes
from this correction:

- **8 MB Reopen: 2.20-second UI stall.**
- **50 MB Save rejection: 4.69-second UI stall.**
- **2.21 GB process high-water RSS across the serial test run**, not proven
  allocation by that operation alone.
- Opening permits up to **50 MB**, while storage retains separate **10 MB limits**.
  A PDF that opens may therefore exceed the storage limits.

C1 does not change synchronous Save/Reopen, reject oversized saves earlier, alter
storage ceilings, or resolve these performance findings. Save/Reopen remains
in-memory, not durable PDF export. Native PDF annotation/form appearances may
still be omitted. Stop here for the independent C1 recheck.
