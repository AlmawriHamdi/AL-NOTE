# Reviewed CI resource publication and R2 completion

**Implemented and verified; awaiting independent R1/R2 review.** The previously
blocked upload connection became available in `al-note-dev`; no new publication
authorization was requested. The reviewed package and matching source materials
are published in the dedicated [CI-resource release](https://github.com/AlmawriHamdi/AL-NOTE/releases/tag/ci-resources-linux-pdf-82d1b451f94b2fa6).
This is **Build resources—not an application release.** No SDK adoption or
ordinary-PDF enablement is implied.

## Release identity and source delivery

- Release ID: `389987380`; dedicated prerelease, not marked latest.
- Tag: `ci-resources-linux-pdf-82d1b451f94b2fa6`.
- Exact tag target: `921e43f41a31b0649a2ae890c993fd4e406ad39a`.
- Repository release immutability was enabled before publication. The published
  release reports `immutable: true`. No tag or asset was overwritten or moved.
- The binary represents reviewed **currently uncommitted** source. The tag and
  GitHub-generated tag source archives do not contain that source. The separate
  worker/native source assets below supply the matching materials.

All eight assets were uploaded to a draft, compared against their GitHub
size/digest fields, then downloaded and independently hashed before publishing.
All eight are publicly accessible without credentials. The manifest still pins
exactly 114 resources:
`82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298`.

| Published asset | Bytes | SHA-256 |
|---|---:|---|
| [alnote-linux-pdf-82d1b451f94b2fa6.tar](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/alnote-linux-pdf-82d1b451f94b2fa6.tar) | 21678080 | `cfc4172f8431ea7579b38bd32943361af202a97800b91cbf964565af4a4188b7` |
| [alnote-pdf-worker-source-82d1b451f94b2fa6.tar.gz](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/alnote-pdf-worker-source-82d1b451f94b2fa6.tar.gz) | 3465359 | `c9487f113ec0482caf6c63560287e58e4e3ff90bb7a7b4c0e6173af0c3e295d2` |
| [alnote-pdfium-source-f91ca5a72358.tar.gz](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/alnote-pdfium-source-f91ca5a72358.tar.gz) | 148766980 | `4a64961831f663960560527576684e17cceacfb1eceb0d4d36a8eff1f09242e1` |
| [glibc-2.43-7.fc44.src.rpm](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/glibc-2.43-7.fc44.src.rpm) | 21921870 | `c1e8fc014d8948edf6cfaedd8f80eac37d3ed8805cce2daa400ef11cdd6689c1` |
| [gcc-16.1.1-2.fc44.src.rpm](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/gcc-16.1.1-2.fc44.src.rpm) | 103809724 | `7d1db2017857bdfdb5e19e75fa13f197d4378a2c141e336a983b310428f157f5` |
| [BUILD-MATERIALS.md](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/BUILD-MATERIALS.md) | 7125 | `2c02a8957c75782ac20fcda2b613b15de136e6616b960a244cff8bbff463401a` |
| [packaged-resources.json](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/packaged-resources.json) | 17915 | `82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298` |
| [SHA256SUMS](https://github.com/AlmawriHamdi/AL-NOTE/releases/download/ci-resources-linux-pdf-82d1b451f94b2fa6/SHA256SUMS) | 685 | `daded5d31d55dc9306798e80d9cc23ee1fff9bf8b68b9c44f68f0095f6d6d7bd` |

The worker source archive contains the actual worker, guard and transport sources;
26 resolved Dart source packages, including hook imports and the patched engine;
licenses; a relocatable package configuration; exact source hashes; native patch;
and original build context. The native source archive exports the actual tracked
sources of all 27 recorded native repositories with the two approved PDFium
patch changes. Git configuration, ignored outputs and private build logs are absent.

The unchanged packaged glibc/libgcc runtimes match the installed source-package
identities. Exact Fedora source RPMs were obtained through official Koji HTTPS,
including upstream source tarballs, specs, auxiliary scripts and every referenced
patch. They accompany the binary at the same release; license notices alone are
not being substituted for corresponding source. RPM header/payload digest checks
passed; source-RPM signature authentication is not claimed. `BUILD-MATERIALS.md`
records origins, component licenses and build recipes. The AL NOTE sources retain
GPL-3.0-or-later; upstream sources retain their applicable licenses. This delivery
is a source-correspondence claim, not a bit-reproducible native-build claim.

Privacy/content checks found exactly the expected binary archive members, all
regular files with normalized TAR metadata and no extra files or links. The
unchanged worker retains two copies of
`file:///home/Hamdi/Projacts/AL-NOTE/tool/linux_pdf/worker.dart`; this nonsecret
build metadata was disclosed and not stripped or repinned. No private-key PEM
header or GitHub token-shaped value was found in the binary package. Pattern
scanning is not a universal absence proof. The worker source archive has no
matching findings or symlinks. The native source snapshot preserves four safe
relative upstream source links and a public upstream Fuchsia test signing-key
fixture verified against its tracked revision. These are source-only materials,
never accepted as runtime archive members. The original unmaterialized optional
FreeType `subprojects/dlg` gitlink is recorded; none of the 614 original controlled
Ninja files references it.

## Exact implementation scope

`tool/linux_pdf/distribution.json` pins the published URL, release/tag identity,
archive length/hash and unchanged resource-manifest digest.
`tool/linux_pdf/provision_package.py` bounds the archive to 64 MiB, uses bounded
reads and a download deadline, verifies exact archive bytes before parsing, then
checks every resource in private staging. It rejects missing, corrupt, duplicate,
extra, symlink, special, unsafe and noncanonical members, including hidden GNU
extension headers and trailing data. A Linux atomic no-replace rename publishes
the verified directory. Failure removes staging; existing corrupt destinations
reject and are not silently overwritten. A filesystem ancestor such as Bazzite's
`/home` symlink is resolved; a symlinked package itself always rejects.

The local verifier additionally rejects unexpected empty directories. No approved
manifest, Dart/CMake pin, native byte, runtime guard or admission policy changed.
CI adds exactly two Linux steps: the focused Python provisioning tests and remote
package provisioning before the existing Linux build. Removing those two steps
reproduces the prior workflow hash exactly, preserving all platform gates. R1's
fixture acquisition/explicit `Pdfrx.pdfiumModulePath` setup remains separate.

Incremental authored changes relative to publication preparation:

- New: `tool/linux_pdf/distribution.json`, `tool/linux_pdf/provision_package.py`,
  `tool/test_pdf_package_acquisition.py`, and this report.
- Narrow edits: `.github/workflows/verify.yml`, `tool/linux_pdf/verify_package.py`,
  `tool/test_pdf_provisioning.py`, and `sdk-347-ci-provisioning.md`.

The prior R1 changes and all earlier uncommitted work remain preserved. No Git
commit, push, branch change, PR update, native rebuild, dependency upgrade, broad
build deletion or application feature change occurred. The sole new remote tag
and immutable resource release were explicitly authorized.

## Fresh verification actually run

Fresh root: `/tmp/alnote-r2-remote-fresh-iz0hp70l`. Its source checkout began with
527 source files, no `build` or `.dart_tool`, and an empty separate `PUB_CACHE`.
The SDK was the previously extracted approved Flutter 3.47.4 archive at
`/tmp/alnote-sdk-ci-fresh-ac1u9cwk/flutter`; it has no manually added fixture-library
symlink. Only that SDK was reused. Existing `al-note-dev` system build prerequisites
were reused; this is not a newly provisioned VM or an executed GitHub Actions job.

| Personally run at the final tooling/code state | Result |
|---|---|
| Fresh dependency resolution with `--enforce-lockfile` | Passed; lockfile unchanged |
| Fixture acquisition from pinned upstream HTTPS | Passed; explicit verified path |
| Python provisioning/acquisition negatives | 30 passed |
| Fixture bootstrap and native patched-PDFium tests | 12 passed, including the 40-case marked geometry matrix |
| Fatal-info analysis | Passed |
| CI formatting scope, `lib test` | 216 files, zero changes |
| Anonymous download of the published isolated archive | Passed; no local package copy |
| Every acquired resource and manifest | All 114 resources verified |
| Linux debug build and install | Passed |
| Every installed package resource | All 114 resources verified |
| Public access to all eight binary/source/material assets | Passed without credentials |
| GitHub workflow-run comparison before/after publication | Unchanged: 37 runs; identical recent run IDs |

All 527 fresh source-file hashes remained unchanged after the checks/build. The
SDK fixture symlink remained absent. The generated bundle is at
`/tmp/alnote-r2-remote-fresh-iz0hp70l/AL-NOTE/build/linux/x64/debug/bundle/al_note`.
The isolated archive was obtained by the default provisioner from the public
release URL, not seeded from the local package or authenticated draft download.

The original R1 missing-SDK-library reproducer and prior 890-pass full suite are
recorded in the preceding report; they were not rerun in this publication pass.
The full suite and unrelated engine/host audits, Android/Web builds and Windows
execution were deliberately not repeated. A prior broader formatter check also
reported an existing difference in `tool/linux_pdf/measure_integration.dart`;
that out-of-scope file was not edited. The CI formatting scope passes. Only
report/evidence edits followed the successful final code checks.

Evidence: `build/ci-resource-publication/remote-fresh-results.json` contains every
exact command, duration and exit status; corresponding logs and
`remote-fresh-final-check.json` record the fresh-state assertions.
`draft-roundtrip.json`, `upload-inventory.json`, `published-release-final.json`,
`published-tag.json`, `public-assets-access.json` and the workflow-run snapshots
record remote evidence. Earlier source/license inventories and rollback resources
remain intact.

## Reproducible setup and limitations

From a checkout containing these uncommitted changes, with the accepted SDK
selected (on this host execute inside `al-note-dev`):

```sh
/home/Hamdi/Development/flutter-3.47.4/bin/flutter pub get --enforce-lockfile
python3 tool/provision_pdf_fixture.py
python3 -m unittest discover -s tool -p 'test_pdf*.py'
/home/Hamdi/Development/flutter-3.47.4/bin/flutter test --no-pub test/documents/pdf_fixture_setup_test.dart test/documents/pdfrx_patch_test.dart
python3 tool/linux_pdf/provision_package.py
python3 tool/linux_pdf/verify_package.py build/linux-pdf-resources
/home/Hamdi/Development/flutter-3.47.4/bin/flutter build linux --debug --no-pub
python3 tool/linux_pdf/verify_package.py build/linux/x64/debug/bundle/data/pdf_linux
```

Acquisition rechecks an existing destination instead of silently repairing corrupt
resources. `--archive PATH` accepts an offline archive under identical verification;
`--directory PATH` selects a new destination. Neither approves new hashes.

The immutable publication is public and cannot recall downloaded copies; assets
and its tag cannot be edited while the immutable release exists. A different
future package requires a separately reviewed new identity. CI source changes
remain uncommitted and were not pushed to trigger verification. Independent
R1/R2 review is still required. Windows execution, physical input/GPU acceptance,
Android PDF and ordinary-PDF scope remain unchanged. Existing Save/Reopen stalls
are not resolved by provisioning. SDK provenance signatures remain **UNVERIFIED**
under the user's narrow HTTPS/archive-checksum exception; package integrity and
isolation checks remain intact.
