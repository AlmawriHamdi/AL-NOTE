# Phase 8 correction 1: geometry and Web initialization

Bounded correction for Main AI review on `phase-8-pdf-system`, starting at
`921e43f41a31b0649a2ae890c993fd4e406ad39a`. Existing uncommitted work is preserved.
This is not approval of Phase 8 or of release/untrusted-PDF use.

## Root causes and changes

Raw `FPDFPage_GetCropBox`/`GetMediaBox` calls do not establish inherited rendering
geometry. CropBox-first selection also misses PDFium normalization and MediaBox
intersection. Both vendor readers now use `FPDF_GetPageBoundingBox` for the
source rectangle and `FPDFPage_GetRotation` for effective rotation. This matches
PDFium's [public bounding-box contract](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/public/fpdfview.h)
and [page geometry implementation](https://pdfium.googlesource.com/pdfium/+/refs/heads/main/core/fpdfapi/page/cpdf_page.cpp);
actual checks below establish behavior of the installed native and Web artifacts.
The API is labeled experimental by PDFium but is already exported by both pinned
artifacts and their supported bindings; no new ABI, parser or native-handle
contract was added.

Evidence now identifies `resolvedBounds`, with no inferred raw-box kind or
provenance. The API does not report the originating dictionary or whether it
inherited, defaulted, normalized or clipped a raw box. The patch deliberately
does not reconstruct that history. Resolved bounds and rotation alone define
render mapping. Raw PDF conformance is not proved by a positive resolved region.

PDFium's displayed extents are binary32 subtractions, whereas Dart subtracts
promoted endpoints in double precision. The adapter now requires exact equality
between the engine extent and one binary32 rounding of the rotated endpoint
difference. This admits only the specified round-to-nearest/ties-to-even result
(at most half an ULP of the extent), not an origin-scaled epsilon. Saved endpoints
are untouched; saved extents are their exact double differences. Model, codec,
receiving limits and saved geometry matching remain exact. The fractional
fixture's width is saved as `200.2000026702881`, while PDFium reports
`200.1999969482422`; the bounded rounding check reconciles these values.

Unavailable/nonfinite/empty resolved regions, disjoint boxes, nonpositive engine
dimensions and irreconcilable extent evidence reject. Normalized reversed boxes,
inherited boxes/rotation, negative origins, contained/overlapping/oversized crops
and ordinary fractional coordinates are supported. Model and processing limits
remain independent receiving checks, not parser containment claims.

The smallest neutral contract change adds `resolvedBounds` to the existing
schema-1 enum and validation allowlist; its codec already serializes named enum
values. Old `cropBox`/`mediaBox` references retain their wire data and render only
when all endpoints, canonical dimensions and rotation match. This proves their
mapping, not their historical provenance. Older builds reject references using
the new enum value. No coordinate migration or automatic box substitution occurs.

Web initialization previously freed backing storage without closing a loaded
document on rejection, and leaked backing storage for null-document errors.
One common owner now exits form state, releases form-info storage, closes the
document, clears associated maps, then releases memory/file/range backing.
Ownership transfers at the end of initialization. The range-opening catch cannot
close a transferred handle again; repeated close requests do not dispose twice.
Font resets clear pending font discoveries rather than another live document's
map. The Dart bridge also closes a returned worker document when constructing its
local evidence/document fails.

## Controlled regression evidence

`test/support/pdf_geometry_checks.dart` generates all PDF input locally and is
shared by the native test and real-browser Flutter harness. Each accepted case
checks the expected source rectangle, provenance classification, effective
rotation, reference encode/decode, forward/inverse coordinates, actual adapter
rendering from the reopened reference, and rejection of a translated rectangle
with identical dimensions.

The source contains a red 10×20 mark centered at `(25,40)` and a blue 20×10 mark
centered at `(80,65)`. Both are measured in actual rendered RGBA pixels at about
2 pixels per point. The test allows at most 0.6 pixel of centroid quantization;
this pixel assertion is never used for geometry acceptance.

| Cases at each of 0/90/180/270 | Native | Chrome Web |
| --- | --- | --- |
| Contained, overlapping, oversized CropBox | 12 marked passes | 12 marked passes |
| Reversed CropBox and reversed MediaBox | 8 marked passes | 8 marked passes |
| Inherited MediaBox/CropBox/rotation and inherited negative-origin MediaBox | 8 marked passes | 8 marked passes |
| Explicit negative origins and fractional coordinates | 8 marked passes | 8 marked passes |
| Disjoint MediaBox/CropBox | 4 rejections | 4 rejections |

Native and Web centroid result rows are identical. Integer cases match predicted
centroids exactly; maximum fractional centroid coordinate difference is
`0.4790437399200371` pixel. This establishes source/pixel alignment for these
controlled full-page renders, not arbitrary canvas zoom/DPR or every PDF feature.

The boundary test accepts the precise binary32 rounding, rejects a one-ULP
change and larger dimension mismatches, and confirms the neutral model still
rejects independently rounded saved dimensions. Package Save/Reopen is tested
with both legacy and resolved bounds, including immutable shared resources and
unknown-field preservation. Existing receiving-limit regressions remain active.

The browser cleanup harness wraps actual WASM exports and exercises eight
failure stages three times over memory, file and range paths (72 failures),
null-handle errors, success/disposal, repeated disposal, and a second document
kept alive across failures. It verifies that document close precedes backing
release, form exit precedes form-info release/document close, and associated
maps are empty without damaging the kept document.

| Resource | Opens / allocations | Closes / releases |
| --- | ---: | ---: |
| Loaded documents | 76 | 76 |
| Form environments | 49 | 49 |
| JavaScript-owned WASM allocations | 304 | 304 |
| Range-document availability | 25 | 25 |

There are 75 common-owner backing callbacks: 73 loaded documents reached that
owner, plus two null-document errors. Three range page-count failures close in
the range owner before common initialization. No double close, double free,
ordering violation, retained document/form/allocation, or map leak is observed.
The separate Dart bridge test forces four evidence-construction rejections after
real worker opens and confirms four completed close commands.

## Reproducible commands

Run Flutter/Chrome commands in the existing `al-note-dev` container, from the
repository root. Toolchain remains Flutter 3.44.6 / Dart 3.12.2; no upgrades.

```sh
distrobox enter al-note-dev -- flutter test --no-pub test/documents/pdfrx_patch_test.dart test/documents/phase8_pdf_test.dart --reporter expanded
distrobox enter al-note-dev -- flutter build web --no-pub --release --no-web-resources-cdn --target test/documents/pdfrx_web_parity_main.dart --output build/pdf-parity
distrobox enter al-note-dev -- python3 tool/check_pdf_browser.py --app build/pdf-parity --output /tmp/al-note-correction1-browser
python3 tool/check_pdf_vendor.py --archives /tmp/al-note-phase8-vendor
```

The browser runner uses only Python's standard library, an ephemeral local HTTP
server and the container's installed Chrome. It supplies local range responses,
serves the built app without modifying it, and retains JSON results and Chrome
logs in the output directory. Fault injection lives only in test assets. The
vendor checker reads the exact official `pdfrx-2.4.8.tar.gz` and
`pdfrx_engine-0.4.7.tar.gz` archives without extracting or executing their content.
The auditor's already verified archive copies were reused for this run.

## Verification record

- Focused native geometry/adapter/model suite: 34 passed before the added package
  variant; the final model/persistence rerun passed 25 tests.
- Fatal-info app analysis during development: no issues.
- Real Chrome parity and initialization cleanup: passed, with counts above.
- Offline vendor comparison: passed for 92 retained files and all 136 omissions.
- Final Dart formatting check: nine authored/modified files, zero changes;
  final-newline/trailing-whitespace checks passed across all 19 correction files
  (only changed lines checked in the mixed-line-ending vendor worker).
- Final `flutter analyze --no-pub --fatal-infos`: no issues (7.7 seconds).
- Full `flutter test --no-pub --reporter expanded`, run once: **720 passed**
  (1 minute 44 seconds).
- `flutter build linux --debug --no-pub`: passed.
- `flutter build web --release --no-pub --no-web-resources-cdn`: passed.
  The build reported an existing missing CupertinoIcons font-family warning;
  the MaterialIcons subset and Web build completed successfully.
- Marked Flutter Web parity release harness build: passed (37.8 seconds);
  real Chrome checks passed using that build. Native/Web result rows compare
  byte-for-value identically after JSON decoding.

Logs and JSON are under `/tmp/al-note-correction1-*`. The app analyzer excludes
`third_party/**`; passing app analysis is not a claim to analyze all upstream
vendor sources. Vendor verification here checks byte correspondence, focused
patches, actual native compilation and browser runtime behavior.

## Vendor provenance and exact correction scope

The [vendor inventory](../dependency-review/pdfrx-vendor.json) records exact
archive, MIT-license and five patched-file SHA-256 hashes, plus every pruned
upstream path. It derives from the auditor's `vendor.json`; pdfrx omits 128 paths
and pdfrx_engine omits eight. The four vendor files touched by this correction
are the native reader, page evidence contract, worker and Dart Web bridge. The
previous proxy patch remains unchanged and its hash remains recorded. WASM and
unmodified bridge assets remain byte-identical to upstream archives. No CI,
package versions, trust/picker, duplication or opacity implementation was edited.

Correction-only byte changes (separate from the pre-existing working tree):

- `docs/dependency-review/README.md`
- `docs/dependency-review/pdfrx-vendor.json`
- `docs/testing-release/phase8-correction1.md`
- `lib/documents/pdf/README.md`
- `lib/documents/pdf/pdf_model.dart`
- `lib/documents/pdf/src/pdfrx_pdf_backend_adapter.dart`
- `test/documents/pdfrx_patch_test.dart`
- `test/documents/pdfrx_web_parity_main.dart`
- `test/documents/phase8_pdf_test.dart`
- `test/fixtures/phase8/web_cleanup.html`
- `test/fixtures/phase8/web_cleanup_worker.js`
- `test/fixtures/phase8/web_parity_bridge.js`
- `test/support/pdf_geometry_checks.dart`
- `third_party/pdfrx-2.4.8/assets/pdfium_worker.js`
- `third_party/pdfrx-2.4.8/lib/src/wasm/pdfrx_wasm.dart`
- `third_party/pdfrx_engine-0.4.7/lib/src/native/pdfrx_pdfium.dart`
- `third_party/pdfrx_engine-0.4.7/lib/src/pdf_page.dart`
- `tool/check_pdf_browser.py`
- `tool/check_pdf_vendor.py`

Final Git status remains on `phase-8-pdf-system` at the starting HEAD, with no
staged changes. The complete status snapshot is
`/tmp/al-note-correction1-git-status.txt`: 241 modified tracked paths and 112
untracked files. This includes the preserved pre-existing changes and mode-only
status entries; it is not the correction's file count. The correction changes
exactly the 19 files above, adds no deletions, and leaves CI byte-identical to the
starting snapshot. Machine-readable correction scope is
`/tmp/al-note-correction1-changed.json`.

## Remaining blockers and limits

Trust/picker admission and host read budgeting, annotated-page duplication, and
source visibility/opacity remain for subsequent corrections. No changes here
resolve native binary-download authentication, third-party notice/source
correspondence, untrusted parser containment/budgets or release acceptance.
No package/Flutter upgrades, public fork, commit, push, PR, merge or tag were made.
Windows/Android builds and arbitrary third-party PDFs were outside this bounded
verification. Stop for Main AI review; the milestone remains blocked.
