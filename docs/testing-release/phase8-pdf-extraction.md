# Phase 8 — bounded PDF extraction candidate

Status: the bounded private Linux candidate was independently approved on
2026-09-23. Its separately authorized CI-resource publication/provisioning is
recorded in [the publication handoff](phase8-pdf-extraction-publication.md).
This is not application release enablement, adoption approval or Phase 8 closeout.
The package/material discussion below records the prepublication implementation
handoff; the publication handoff supersedes its distribution-status statements.

## Scope and semantics

The existing private Linux backend now implements per-page text and link extraction
in its isolated worker. The app never opens a native PDF handle. The supported
`useNativeDocumentHandle` callback temporarily suspends pdfrx's worker while the
isolated process reads PDFium text/link APIs, then closes page/text handles in
`finally`. The existing PDFium, sandbox guard, transport, package integrity,
admission policy, SDK, dependencies and persistent document schema are unchanged.

Text results contain Unicode scalars, an increasing full-page scalar index and
optional page-local glyph bounds. PDFium's UTF-16 surrogate records are combined
only when the pair and identical geometry validate. Coordinates use the existing
authoritative resolved source bounds/rotation and `PdfPageCoordinates`; glyphs
are intersected with those bounds and the requested normalized region. Cropping
does not rewrite source geometry. Reading order is advisory, not reconstructed.
Generated tab/newline/space separators can have no geometry; a partial-region
request containing these returns unsupported rather than guessing their location.
An empty/scanned page returns a complete empty embedded-text result; there is no OCR.

Link results contain validated page-local bounds and either an actual in-document
page index or inert external-reference classification. HTTP/HTTPS classification
requires explicit `allowExternalHttpMetadata`; parent and worker independently
validate bounded URI metadata. URL targets are discarded before the result crosses
into the app. Launch, JavaScript, remote/file/custom schemes, malformed targets and
unknown/missing primary actions reject the whole result. No action is executed,
no destination is activated, and no browser or network capability is added. This
is extraction through supported engine APIs, not a full PDF syntax/action-graph
sanitizer or an export certification.

All results are derived: no persistence, document command, UUID generation,
history entry, text editor commit, content identity change or observer publication.
The real Canvas regression checks root/resource/content identities, history and
observer counts around extraction. Existing draft/observer/history tests remain.
Failure messages are fixed and redacted; neither text, URI nor native exception
messages are surfaced. The initial camel-case `limitExceeded` failure code violated
the application's lowercase namespace contract; it now maps to `limit_exceeded`
(and `passwordRequired` to `password_required`) without weakening rejection checks.

## Bounds, cancellation and completeness

| Boundary | Hard ceiling; caller may reduce it |
| --- | --- |
| Input / document pages | Existing 50,000,000 bytes / 1,000 pages |
| Text | 8,192 Unicode scalars; at most twice that many native UTF-16 records |
| Links / annotations inspected | 256 / 4,096 |
| URI | 2,048 UTF-8 bytes, plus one native terminator |
| Coordinates | finite, absolute source coordinates at most 1,000,000 |
| Extraction response | 2 MiB JSON frame; existing bounded ready frame plus framing |
| Worker | Existing 30-second deadline, 1 GiB cgroup, process/task limits |

Counts are checked before app-owned result retention and native URI-buffer
allocation. Native engine parsing/text-page allocations remain inside existing
process resource/deadline limits; no preallocation guarantee is claimed for the
engine's internal allocations. Exact scalar/index/count types, operation/page/id,
geometry, complete flag, actual destination page range and closed record shapes
are independently validated by the parent. Oversized, malformed, truncated,
extra, incomplete, nonzero-exit and failed-input responses publish no prefix.
The parent confirms complete input transmission and worker/cgroup cleanup before
projection/publication, then compares saved source geometry exactly.

Extraction takes the existing single-operation ownership slot or returns a
retryable busy result without reading/copying/queuing input. It never replaces
the one pending latest render. Cancellation holds ownership through existing
cleanup confirmation; superseded render interest reads no source. Permanent
failures do not retry automatically. Consumers retain responsibility for cancelling
an extraction when their document/reference/request becomes obsolete; no UI request
or extraction cache is added in this task.

## Candidate and distribution handoff

Evidence directory: `build/pdf-extraction-review/` (ignored, preserved locally).
The pre-extraction 535-file source snapshot, hashes and accepted package copies
are retained there. Restore specific extraction changes from that snapshot for
rollback; never reset to HEAD, which omits earlier accepted uncommitted work.

Only `worker` differs among 114 package resources. The 79,952-byte growth is detailed
exactly in `candidate-review-3.json`; no native/resource/notice change was accepted.

- Accepted manifest: `82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298`.
- Candidate manifest: `65ab051ea8c3d74ad0307f53c9d45cb55a90ddcb80bec3e2c923403ab43f3157`.
- Candidate worker: 7,117,208 bytes; `e27484e7a4b2a47b301a67247a3ad1f6f5e31e9bd99bcbcf17cb42d182add6f1`.
- Binary TAR: 21,760,000 bytes; `249e08ec2c895c20651c3e13fe81318490f71a62640cffa4455b000097808b01`.
- Worker source TAR.GZ: 3,469,137 bytes; `c7cf0199ac21b5199dae8bc67a94efe2f8455fc4703acbd34d3ea5a873220a89`.

The exact unpublished proposed identity is `ci-resources-linux-pdf-65ab051ea8c3d74a`.
`distribution-candidate.json` gives its proposed URL, length, archive and manifest
hashes. A proposed URL is not remote availability. `prepare_distribution.py`
creates canonical USTAR and verifies fresh offline provisioning with the unchanged
strict provisioner. `distribution-materials.json` records binary/source materials.
The relocatable worker source archive has 5,739 files including exact worker/helper,
26 existing resolved packages, licenses, lock/toolchain context and native build
recipes. Every reused package source file was compared with the current checkout;
its source-file index was verified and the extracted closure compiled without pub
resolution (`relocated-source-build.log`). Different build paths can change AOT
bytes; this is source correspondence, not bit-identical reproducibility.

The unchanged native source archive is retained locally with digest
`4a64961831f663960560527576684e17cceacfb1eceb0d4d36a8eff1f09242e1`.
The exact glibc/gcc source RPM identities and immutable published URLs are recorded
in the materials inventory. Their former `/tmp` copies no longer exist; they were
not downloaded or re-audited in this task. Any later publication must preserve
access to these exact corresponding native/runtime sources and licenses, along
with the new worker source archive. The existing accepted release/assets remain
untouched. Flutter archive provenance signatures remain **UNVERIFIED** under the
prior user-approved HTTPS/checksum exception; worker/package hashes remain enforced.

The manifest, Dart pin and CMake pin agree on the candidate. The repository's
`distribution.json` deliberately remains the immutable accepted release record.
Consequently fresh default remote CI provisioning **fails closed** against the new
manifest until a separately authorized publication and distribution-record update.
Do not approve new hashes automatically or substitute fixture PDFium. No remote CI
success, release id, publication or trigger is claimed. After independent approval:
review the exact candidate/source materials; obtain publication authorization;
publish a distinct immutable resource release; verify its downloaded bytes; update
only the distribution record; rerun fresh provisioning/build verification.

## Verification

All logs below are in `build/pdf-extraction-review/`. The full suite ran once after
the last source/test edit; subsequent edits are documentation/evidence only.

| Personally run check | Result / evidence |
| --- | --- |
| Full suite, default gates | **978 passed, 36 skipped**, 3m30s; `full-suite-final.log` |
| Extraction protocol + actual-host extraction | **34 passed**; `extraction-focused-final.log` |
| Actual-host Canvas opening/import/Objects/clipping/disposal | **6 passed** across `host-canvas-final.log` and `host-canvas-state-rerun.log` |
| Existing host protocol/integrity/cleanup/private opening + staging | **8 passed** across `host-existing-final.log` and `host-staging-rerun.log` |
| Provisioning boundaries | **30 passed**; `provisioning-tests-final.log` |
| Formatting | **228 files, zero changes**; `format-final.log` |
| Strict Dart and Flutter fatal-info analysis | **No issues**; `analysis-final.log`, `flutter-analysis-final.log` |
| Candidate + fresh offline + installed package verification | **All pinned resources verified**; manifest identity above, `installed-verification-final.log` |
| Relocated source archive build | **Passed**, no dependency resolution; `relocated-source-build.log` |
| Linux debug, private test gate | **Passed**; `linux-build-final.log` |
| Web release / Wasm dry-run compile | **Passed**; `web-build-final.log` |
| Installed-package actual-host extraction | **3 passed**; `installed-host-extraction.log` |

The 36 default-suite skips are not passes. Separate implementation logs cover 30
of them; the independent audit executed one more. Five exact legacy cases remain
unverified, listed explicitly in the publication handoff. Related focused checks
do not substitute for those cases or their performance measurements. The first combined existing-host invocation enabled
both fixture and private gates: seven cases passed, while the fixture-trust staging
case was correctly quarantined. Rerunning that case with its intended fixture-only
gate passed; no production change. Cleanup tests observed two controller-outage
rounds with four PIDs each, all PIDs absent and cgroups empty before recovery.
The new hostile extraction cases also check empty running-service sets and retained
cleanup ownership. Cold staging cancellation measured 3, 6 and 6 ms. These are
regression observations, not a new performance claim or a fix for Save/Reopen.

Development failures are retained rather than relabeled: candidate 1 rejected the supplementary
Unicode character; candidate 2 lost limit failure classification; the first new
Canvas assertion incorrectly required identity of separately allocated snapshot
wrappers. The fixes validate the actual Unicode representation, failure namespace,
and authoritative snapshot fields respectively.

## Limitations preserved

No Search/OCR/UI/navigation, text editing, outline operation, password entry,
PDF export or broader PDF admission. Android PDF remains postponed; Windows/Web
ordinary PDF remains disabled. No platform/runtime acceptance outside personally
executed checks is implied. The two forced history-disposal probes from F1 remain
**INCONCLUSIVE**, not passes or confirmed feature defects.

This task does not resolve the separately reported Save/Reopen performance findings:
8 MB Reopen: 2.20-second UI stall; 50 MB Save rejection: 4.69-second UI stall;
2.21 GB high-water process RSS across that run (not attributed to one operation).
Opening's 50 MB cap and storage's separate 10 MB limits remain distinct.

## Changed files relative to the preserved pre-extraction worktree

- Contract/result additions: `lib/documents/pdf/pdf_backend.dart`.
- Isolated backend/protocol/supervisor: `lib/documents/pdf/src/linux/linux_pdf_backend.dart`,
  `linux_pdf_protocol.dart`, `linux_pdf_supervisor.dart`, new `linux_pdf_extraction.dart`.
- Worker: `tool/linux_pdf/worker.dart`, new `tool/linux_pdf/extraction.dart`.
- Reviewed local pins: `tool/linux_pdf/packaged_resources.json`,
  `lib/documents/pdf/src/linux/linux_pdf_resource_pin.dart`, `linux/CMakeLists.txt`.
- Regressions: new `test/documents/pdf_extraction_protocol_test.dart`,
  `pdf_linux_extraction_test.dart`, `test/support/pdf_extraction_fixture.dart`;
  extended `test/support/pdf_object_insertion_checks.dart`.
- Documentation: `lib/documents/pdf/README.md` and this report.

`scope-final.json` records these 10 modified / 6 new files with no baseline deletion.
No SDK/dependency/lockfile, native source, admission, CI workflow or published
resource record changes. The broad Git status predates this task and is preserved.

## Auditor commands

Use `/home/Hamdi/Projacts/AL-NOTE` as the working directory and the explicit SDK.
Actual isolated-host tests run **outside distrobox**, with working user systemd,
cgroups and bubblewrap. Development builds/full suite run through `al-note-dev`.

```sh
/home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub --concurrency=1 \
  --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true \
  --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true \
  test/documents/pdf_linux_extraction_test.dart \
  test/documents/pdf_extraction_protocol_test.dart --reporter expanded

/home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub --concurrency=1 \
  --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true \
  --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true test/widget_test.dart \
  --name 'private Linux PDF|private Linux notebook PDF import|Linux integrated' \
  --reporter expanded

python3 tool/linux_pdf/verify_package.py build/linux-pdf-resources
python3 tool/linux_pdf/verify_package.py build/pdf-extraction-review/offline-provisioned
python3 -m unittest discover -s tool -p 'test_pdf*.py'
```

The source/material preparer uses exclusive outputs: do not rerun it over existing
candidate archives. Inspect the recorded script and hashes; use a fresh review
output directory for independent reconstruction. Native rebuilds or engine audits
are unnecessary for this Dart-worker-only candidate.


## Isolated build output and launch

An existing app was running from `build/linux/x64/debug/bundle/al_note`. Its
binary, worker and manifest hashes were recorded and rechecked unchanged after
this build. The task-specific Flutter config selects
`build/pdf-extraction-review/platform-build`; user/global Flutter settings were
not changed. No `flutter clean` or broad build deletion was used. The generated
Linux config/registrant files also retained their original hashes.

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && XDG_CONFIG_HOME=/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-review/flutter-config /home/Hamdi/Development/flutter-3.47.4/bin/flutter build linux --debug --no-pub --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true'

/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-review/platform-build/linux/x64/debug/bundle/al_note
```

Launch is an optional private-test app command, not a claim that this candidate
was manually accepted. Extraction itself has no new user interface. Android and
Windows execution/builds were not repeated for this isolated Linux worker change.
Web compilation checks only the additive shared contract compatibility; it does
not enable ordinary PDF or constitute browser runtime acceptance.

Web command (run through `al-note-dev` from the same repository):

```sh
XDG_CONFIG_HOME=/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-review/flutter-config /home/Hamdi/Development/flutter-3.47.4/bin/flutter build web --release --no-pub --output=build/pdf-extraction-review/web-build
```

The Web build reported a missing CupertinoIcons font-family warning and completed;
no fonts, dependencies, renderer policy or expected pixels were changed to suppress
it. No browser-runtime or Windows execution is claimed.

The installed-package rerun copies the unchanged extraction test bodies into the
ignored evidence directory and substitutes only the bundle path and relative
support imports. It checks Unicode/geometry, scalar limits and URI limits against
`platform-build/linux/x64/debug/bundle/data/pdf_linux`. This does not alter the
production factory, manifest verification or permanent regression assertions.
The full suite was not rerun after documentation/evidence-only additions; no
production or permanent-test edits followed that full-suite run.

Final host cleanup found no `alnote-pdf-*.service` units and no PDF staging entries.
The Git index is unchanged from the pre-extraction inventory.
