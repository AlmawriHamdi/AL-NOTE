# Extraction CI-resource publication and fresh provisioning

Status: **published, immutable, and freshly provisioned/built/checked locally**.
Stop for independent publication/provisioning recheck.
This task publishes the independently approved bounded private Linux extraction
resources only. It is not an application release, SDK adoption, broader PDF
admission, or Phase 8 completion.

## Exact scope and preservation

Only `tool/linux_pdf/distribution.json`, this handoff and the prior extraction
handoff changed. No implementation, test assertion,
manifest/Dart/CMake pin, SDK, dependency, lockfile, worker/native binary, CI workflow,
Git index, branch or HEAD change is authorized here. The existing running app,
accepted earlier resource release/package, both SDK installations and earlier
rollback snapshots remain preserved. Publication evidence and a fresh source/cache/
build tree are under `build/pdf-extraction-publication/`.

The 541-file current source/hash/index inventory and recoverable snapshot were
recorded before this task. Work is based on the current uncommitted worktree,
not a reset or clone of HEAD. All package pins remain on approved manifest
`65ab051ea8c3d74ad0307f53c9d45cb55a90ddcb80bec3e2c923403ab43f3157`.

## Publication identity and contents

Repository: `AlmawriHamdi/AL-NOTE`.
Tag: `ci-resources-linux-pdf-65ab051ea8c3d74a`.
Exact tag target: `921e43f41a31b0649a2ae890c993fd4e406ad39a`.
Release ID: `394888285`.
Label: **Build resources—not an application release.**
The release is a prerelease and is not marked latest. Repository immutability was
already enabled; no repository setting was changed. The final API response confirms `draft=false`, `immutable=true` and
`prerelease=true`; publication time is `2026-09-23T17:20:51Z`.

The tag target identifies the repository baseline, not the matching current
uncommitted worker source. GitHub-generated tag source archives do **not** contain
that matching source. The separately attached worker/helper/resolved-package source
archive is required. Its BUILDING.md retains its historical prepublication wording;
the release record and current BUILD-MATERIALS.md establish distribution status.

Eight assets are required: binary resource TAR, exact worker source TAR.GZ,
unchanged native PDFium source TAR.GZ, exact glibc and GCC source RPMs,
BUILD-MATERIALS.md, packaged-resources.json and SHA256SUMS. No application binary
is included. All 114 runtime/notice resources were reverified, and only `worker`
differs from the accepted earlier package. Native/runtime source archives are
supplied again, preserving durable corresponding-source access without modifying
the earlier release.

The 5,739-file worker source archive and its index were checked against all 26
resolved package sources and current worker/helper/build context. Five archive
entries differ from the accepted earlier worker source: worker.dart, the new
extraction.dart, the manifest, BUILDING.md and its index. The exact unchanged native
archive retains its previously reviewed four safe upstream relative links, public
Fuchsia test signing-key fixture and explicitly recorded optional unmaterialized
FreeType dlg gitlink. No renewed engine audit or native rebuild was performed.

The bounded content/privacy inventory found no private credential patterns in the
worker source archive. The AOT binary retains nonsecret source URIs for worker.dart
and extraction.dart under the original build path. This is not a universal absence
proof. Source correspondence is not bit-identical reproducibility or authenticated
build provenance. Flutter archive provenance signatures remain **UNVERIFIED** under
the earlier user-approved HTTPS/checksum exception; resource integrity is unchanged.

## Workflow and remote-state safeguards

The default-branch and exact tag-target workflow inventories each contained only
Verify, triggered by pull requests and pushes to `main`; no tag/release trigger.
The proposed tag did not exist before this task. Only this tag is created; no tag
is moved, no branch is pushed, and the accepted earlier immutable release is not
edited. All eight draft assets were downloaded and verified, including all 114 packaged
resources, before publication. Final remote checks confirmed the earlier release,
its asset IDs/bytes and previous resource refs unchanged, with no new CI run IDs.

The preflight corrected two API assumptions without weakening a gate: the repository
endpoint needs no trailing slash, and immutability is the explicit JSON `enabled`
boolean rather than an assumed HTTP 204. The published-release-by-tag endpoint
returned 404 for the created draft; it was recovered by its exact release ID,
without recreating the draft/tag or replacing assets.

## Fresh verification procedure

The fresh source is a hash-checked copy of the current worktree's 541 source files,
with no `.git`, `.dart_tool`, generated Linux state, prepopulated `build`, or PDF
resource package. A new empty `PUB_CACHE` and task-local Flutter configuration are
used. The already-pinned Flutter 3.47.4/Dart 3.13.3 SDK and its engine artifacts are
reused; this is not a new SDK download. `flutter pub get --enforce-lockfile` preserved
the exact pubspec and lockfile; available optional upgrades were not taken.

Anonymous remote package acquisition and all 114 resource checks passed. The Linux
debug build then passed against that downloaded package; installed-resource
verification passed and all **20** selected actual-host extraction cases passed.
The existing production regression bodies were copied only into the fresh ignored
build tree, with relative support imports and package location adjusted. No assertion,
factory or integrity guard was changed.
The provisioner remains unchanged: exact archive bytes and all required files must
match the approved manifest before publication into the fresh build tree.

## Five unverified legacy checks retained explicitly

The independent audit reconciled 31 of the 36 skipped full-suite cases with separate
candidate execution. These five exact legacy cases still have no separately executed
candidate result in the supplied evidence and are not reported as passes here:

1. Linux heavy inspection and active native cancellation.
2. Linux package missing or corrupt manifest rejects before launch.
3. Linux verified cache keeps private bytes and invalidates package changes.
4. Linux large raster full handoff keeps event loop responsive and pixels exact.
5. Private Linux near-limit source heartbeat cancellation and memory evidence.

Focused acquisition/extraction/integrity checks do not substitute for those exact
legacy cases or their measurements. This publication does not repeat the full suite,
engine audits, broad geometry matrices or other-platform builds. Android/Windows/
device/browser runtime acceptance remains unexecuted. The two earlier forced
history-disposal probes remain **INCONCLUSIVE**. Pen/zoom and Save/Reopen limitations
remain unresolved, including the 8 MB Reopen 2.20-second stall, 50 MB rejected Save
4.69-second stall and 2.21 GB run-wide high-water RSS (not attributed to one operation).
Opening's 50 MB ceiling does not change storage's separate 10 MB limits.

## Asset inventory

| Asset | GitHub asset ID | Bytes | SHA-256 |
| --- | --- | --- | --- |
| BUILD-MATERIALS.md | 584245651 | 8987 | `66fdf56ee0ed7ac030e78de22b631848fe8d9a516c418712cac96c4dfdcc39e6` |
| SHA256SUMS | 584245708 | 685 | `4616178668a063f7e6c5fe88e45560491a5f08be7de7e241da911b22a396e10f` |
| alnote-linux-pdf-65ab051ea8c3d74a.tar | 584239040 | 21760000 | `249e08ec2c895c20651c3e13fe81318490f71a62640cffa4455b000097808b01` |
| alnote-pdf-worker-source-65ab051ea8c3d74a.tar.gz | 584239570 | 3469137 | `c7cf0199ac21b5199dae8bc67a94efe2f8455fc4703acbd34d3ea5a873220a89` |
| alnote-pdfium-source-f91ca5a72358.tar.gz | 584239672 | 148766980 | `4a64961831f663960560527576684e17cceacfb1eceb0d4d36a8eff1f09242e1` |
| gcc-16.1.1-2.fc44.src.rpm | 584242961 | 103809724 | `7d1db2017857bdfdb5e19e75fa13f197d4378a2c141e336a983b310428f157f5` |
| glibc-2.43-7.fc44.src.rpm | 584242426 | 21921870 | `c1e8fc014d8948edf6cfaedd8f80eac37d3ed8805cce2daa400ef11cdd6689c1` |
| packaged-resources.json | 584245691 | 17915 | `65ab051ea8c3d74ad0307f53c9d45cb55a90ddcb80bec3e2c923403ab43f3157` |


## Personally run publication/provisioning evidence

All evidence below is in `build/pdf-extraction-publication/`.

| Check | Result / evidence |
| --- | --- |
| Approved package, rollback package, archives and synchronized pins | Passed; `package-preflight.json` |
| Source index/current correspondence and bounded privacy inventory | 5,739 files, 26 packages; `material-preflight.json` |
| Exact runtime source recovery | Both RPM lengths/hashes matched; `runtime-source-download.log` |
| Download every draft asset; validate canonical archive/all resources | Eight assets and 114 resources passed; `draft-downloaded-verification.json` |
| Published immutable release | ID 394888285, immutable true; `release-published.json` |
| Earlier release/refs/assets preserved and no triggered CI | Passed; `remote-preservation.json` |
| Fresh dependency cache resolution | Exact lockfile retained; `fresh-pub-get.log` |
| Anonymous fresh acquisition with no offline override/package/build | Passed; `fresh-anonymous-provision.json` |
| Focused acquisition negatives | **30 passed**; `acquisition-negatives.log` |
| Fresh Linux debug build | Passed; `fresh-linux-build.log` |
| Fresh installed package | All 114 resources passed; `fresh-installed-verification.log` |
| Actual-host installed extraction | **20 passed**, 30 seconds; `fresh-installed-extraction.log` |

Anonymous acquisition executed the unchanged provisioner's real CLI entrypoint.
A Python audit hook confirmed HTTPS requests to github.com and
release-assets.githubusercontent.com without Authorization/Proxy-Authorization
headers. No GitHub CLI, local archive argument or prepopulated package was used for
that acquisition. GitHub authentication was used only for the authorized release
operations and read-only remote checks.

The 30 acquisition tests use synthetic inert archives to cover absent/corrupt/
short/oversized input, hashes, record mismatch, unsafe members, special files,
network failure, exclusive publication and cache verification. They are not a
claim that the five specifically named legacy Flutter cases above were executed.

No unrelated full-suite, analysis/formatter pass, engine audit, broad host/geometry
matrix or other-platform build was repeated: the only repository changes are JSON
and documentation. The approved implementation, permanent tests and all package pins
are unchanged. A log redirection initially used the parent-relative path while in
the fresh source directory; only that verifier command was rerun with the correct
path. The actual installed extraction invocation passed without a test/source fix.

## Recheck commands and environment

Main repository: `/home/Hamdi/Projacts/AL-NOTE`.
Fresh source: `/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-publication/fresh/source`.
Fresh cache: `/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-publication/fresh/pub-cache`.
Fresh config: `/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-publication/fresh/config`.
The SDK is `/home/Hamdi/Development/flutter-3.47.4`; 3.44.6 remains installed.

From a new clean source copy, the ordinary provisioning/build sequence is:

```sh
PUB_CACHE=/path/to/new/pub-cache /home/Hamdi/Development/flutter-3.47.4/bin/flutter pub get --enforce-lockfile
python3 tool/linux_pdf/provision_package.py
python3 tool/linux_pdf/verify_package.py build/linux-pdf-resources
/home/Hamdi/Development/flutter-3.47.4/bin/flutter build linux --debug --no-pub --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true
python3 tool/linux_pdf/verify_package.py build/linux/x64/debug/bundle/data/pdf_linux
python3 -m unittest discover -s tool -p 'test_pdf*.py'
```

The actual commands used the exact fresh cache/config paths above. Pub resolution
and build ran through `distrobox enter al-note-dev -- bash -c`, with `cd` to the
fresh source. Actual-host extraction ran outside distrobox from that same source:

```sh
PUB_CACHE=/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-publication/fresh/pub-cache XDG_CONFIG_HOME=/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-publication/fresh/config /home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub --concurrency=1 --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true --dart-define=ALNOTE_LINUX_PRIVATE_HOST_TEST=true build/installed_extraction_test.dart --name 'HOST extraction behavior|HOST extraction Unicode' --reporter expanded
```

Optional host launch of this fresh private-test bundle:

```sh
/home/Hamdi/Projacts/AL-NOTE/build/pdf-extraction-publication/fresh/source/build/linux/x64/debug/bundle/al_note
```

This is an available command, not manual acceptance or a claim that the running
original app was replaced. The current GitHub branch/CI was not pushed or triggered;
the distribution/documentation edits remain local for review. Fresh local anonymous
provisioning/build evidence does not claim a GitHub Actions execution.

[Published release](https://github.com/AlmawriHamdi/AL-NOTE/releases/tag/ci-resources-linux-pdf-65ab051ea8c3d74a).
[GitHub immutability semantics](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes).

Final preservation checks confirmed the original app PID 135947, executable and
process-start identity unchanged, with original binary/worker/manifest hashes intact.
Both accepted rollback package copies and the pre-extraction source snapshot verify.
The Git index and HEAD remain unchanged. The fresh source's only changed baseline
file is the explicitly updated distribution record; pubspec/lock and app source
remain exact. Final host inventory: zero PDF service units, runtime processes or
staging directories. No `flutter clean`, original build deletion, commits, branch
pushes, PR changes or unrelated tags occurred.
