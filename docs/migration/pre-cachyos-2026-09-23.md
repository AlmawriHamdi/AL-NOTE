# Pre-CachyOS work-in-progress backup — 2026-09-23

This is an **incomplete source backup**, not Phase 8, release, or manual-acceptance
approval. Feature development is paused for migration. Main AI is the overseer;
implementation and independent audit use separate chats. This document records
decisions and evidence, **not the actual chat history**.

## Baseline and toolchain

Original branch: `phase-8-pdf-system`, preserved at
`921e43f41a31b0649a2ae890c993fd4e406ad39a`. The backup branch is
`backup/pre-cachyos-2026-09-23`; its snapshot includes the reviewed uncommitted and
untracked work, rather than just that old base. See the
[source inventory](evidence/source-inventory-before.json) for all 542 pre-backup
files and their SHA-256 values. Migration documents/evidence are additional files.

The adopted SDK is **Flutter 3.47.4 / bundled Dart 3.13.3**, installed separately
from retained Flutter 3.44.6. [Toolchain pins](../../tool/flutter_toolchain.json)
record framework `9584c6713b324636289d067944a46fd6b49df14b` and engine
`06a2e2a110089dff50fe635cffd2a61e1b24fbcd`. SDK archive SHA-256:
`5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3`.
The user approved this exact official HTTPS archive/checksum exception;
**provenance signatures remain UNVERIFIED**. This does not weaken PDF integrity
or isolation. Keep locked dependencies and vendored patches; no blanket upgrade.

## Status to carry forward

| Area | State / next gate |
| --- | --- |
| Linux private PDF | Independent review and user acceptance passed for the previous host environment; ordinary input still requires private debug admission and isolation. |
| Notebook PDF import | Independent review and user acceptance passed. Adds notebook Pages; separate from standalone PDF opening and movable Object insertion. |
| Movable PDF Objects | Implemented; F1 Page-clipped Selection/Whole Eraser independently approved. That report permits manual acceptance but does not establish its completion. Uses existing layer opacity. |
| Bounded text/link extraction | Local private Linux candidate independently approved; embedded text geometry and inert metadata only. No Search/OCR/link activation/export UI. |
| Extraction resource publication | Immutable release published; implementer verified fresh anonymous provisioning, Linux build, 30 acquisition cases and 20 installed extraction cases. **Independent publication/provisioning recheck remains pending.** |
| Platform priorities | Linux and ordinary Android app support continue. Android PDF implementation is postponed. Windows/Web ordinary-PDF support is post-Version 1; retain their existing app/CI support. |
| Deferred fixes | Pen/startup/first-stroke issue, zoom preservation, and Save/Reopen stalls remain pending. No SDK or capture fix establishes their resolution. |
| Text redesign / plugin conversion | **CANCELLED.** Do not resume it as migration work. |

Save/Reopen remains in-memory, not sanitized PDF export. Retain the independent
measurements: 8 MB Reopen caused a 2.20-second UI stall; a rejected 50 MB Save caused
a 4.69-second stall; 2.21 GB was process high-water RSS across the run, not proven
allocation by one operation. Opening allows up to 50 MB; storage has separate
10 MB limits. Early deterministic oversize rejection and background work for
accepted large saves/reopens remain separate fixes.

The [preserved audits](evidence/README.md) retain five exact unverified legacy
checks and two **INCONCLUSIVE** forced history-disposal probes. No new test/build
run is implied by this backup. Historical reports describe status at their own
dates: fixture-only, Android-reader, SDK-candidate and unpublished-distribution
wording may be superseded by the decisions and publication records above.

## Immutable packages and provisioning

Both releases are labeled **Build resources—not an application release**. Both
tags target `921e43f41a31b0649a2ae890c993fd4e406ad39a`; generated tag archives do
not contain the matching then-uncommitted worker. Preserve the separately attached
worker/native sources, exact runtime source RPMs, BUILD-MATERIALS, notices,
manifest and SHA256SUMS. Each release has eight assets and 114 runtime resources.

| Identity | Earlier accepted rollback | Current extraction |
| --- | --- | --- |
| Release | [ci-resources-linux-pdf-82d1b451f94b2fa6](https://github.com/AlmawriHamdi/AL-NOTE/releases/tag/ci-resources-linux-pdf-82d1b451f94b2fa6), ID 389987380 | [ci-resources-linux-pdf-65ab051ea8c3d74a](https://github.com/AlmawriHamdi/AL-NOTE/releases/tag/ci-resources-linux-pdf-65ab051ea8c3d74a), ID 394888285 |
| Manifest SHA-256 | `82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298` | `65ab051ea8c3d74ad0307f53c9d45cb55a90ddcb80bec3e2c923403ab43f3157` |
| Worker SHA-256 | `486252705aa92048472ea83a9956b9996e6cd1f2b724f0a9a2f9ec127bde473a` | `e27484e7a4b2a47b301a67247a3ad1f6f5e31e9bd99bcbcf17cb42d182add6f1` |
| Binary archive SHA-256 | `cfc4172f8431ea7579b38bd32943361af202a97800b91cbf964565af4a4188b7` | `249e08ec2c895c20651c3e13fe81318490f71a62640cffa4455b000097808b01` |

Current [distribution record](../../tool/linux_pdf/distribution.json),
[resource manifest](../../tool/linux_pdf/packaged_resources.json), Dart pin and
CMake pin agree. Only the worker changed between these packages; do not substitute
the fixture library or rebuild/repin native components merely for OS migration.
Full asset/source hashes are in the [earlier publication report](../testing-release/sdk-347-ci-resource-publication.md)
and [extraction publication report](../testing-release/phase8-pdf-extraction-publication.md).

After restoring source and the exact SDK, install the new host's Flutter/native
build prerequisites. From `/home/Hamdi/Projacts/AL-NOTE` (in the compatible build
environment, formerly `al-note-dev`):

```sh
/home/Hamdi/Development/flutter-3.47.4/bin/flutter pub get --enforce-lockfile
python3 tool/provision_pdf_fixture.py
python3 tool/linux_pdf/provision_package.py
python3 tool/linux_pdf/verify_package.py build/linux-pdf-resources
```

The fixture provisioner verifies the archive and library pins in
`tool/pdf_fixture_resources.json` (upstream `bblanchon/pdfium-binaries`,
`chromium/7811`). Tests use verified explicit `Pdfrx.pdfiumModulePath`, normally
`build/pdf-fixture/libpdfium.so`; no manually modified SDK is required. A custom
verified directory uses `--directory` and `ALNOTE_PDF_FIXTURE_LIBRARY`. The fixture
engine is distinct from the isolated ordinary-PDF engine. Both provisioners
support verified offline archives with `--archive`; corruption must reject, never
automatically change pins. Provision the isolated package before Linux installation.

## CachyOS gate before ordinary PDF use

Passing on the old host does not establish CachyOS compatibility. Verify exact
installed package bytes and executable/runtime loading, host user systemd service
and cgroup-v2 delegation/limits, bubblewrap namespaces and seccomp, no-network/file
containment, process reaping and cleanup-confirmed ownership. Run affected host
protocol/render/extraction and cancellation/controller-failure/recovery checks on
the actual host, including native image rendering, disposal and surviving-descendant
cleanup. A container build alone does not prove this. Missing isolation must fail
closed; do not introduce an in-process fallback or broaden admission.

Only after those gates, the existing private-debug build/launch commands are:

```sh
/home/Hamdi/Development/flutter-3.47.4/bin/flutter build linux --debug --no-pub --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true
python3 tool/linux_pdf/verify_package.py build/linux/x64/debug/bundle/data/pdf_linux
/home/Hamdi/Projacts/AL-NOTE/build/linux/x64/debug/bundle/al_note
```

Retain Android JDK/build-tool pins and perform ordinary Android app verification
on the new setup. Do not infer Android PDF, Windows execution, physical stylus/GPU
acceptance or new-host performance from this backup. Do not run `flutter clean`
against protected local resources or reuse path-stale CMake caches on the new OS.

## Recovery and exclusions

Recover into a **new empty directory**, leaving any existing worktree untouched:

```sh
git clone --single-branch --branch backup/pre-cachyos-2026-09-23 https://github.com/AlmawriHamdi/AL-NOTE.git /home/Hamdi/Projacts/AL-NOTE-restored
git -C /home/Hamdi/Projacts/AL-NOTE-restored rev-parse HEAD
git -C /home/Hamdi/Projacts/AL-NOTE-restored ls-remote origin refs/heads/backup/pre-cachyos-2026-09-23
```

Compare both hashes with the delivered backup commit before continuing. Put the
verified checkout at the consistent repository path above when the old directory
has been separately preserved. Keep the backup branch as a checkpoint; use a new
working branch for later implementation. The original branch ref remains at the
old base; it is not the complete migration snapshot.

The Git snapshot includes authored source, tests, controlled fixtures, vendored
sources/assets/licenses, docs, dependency locks, pins and tooling. The existing
CI workflow triggers PRs and pushes to `main`, so this backup push does not match
its push trigger; CI is not edited to suppress checks.

**Not in Git:** SDKs, isolated/native runtime packages, broad `build/`, caches,
generated ephemeral platform state, `android/local.properties`, ignored Gradle
wrappers, raw audit probes/logs, old rollback snapshots, personal documents,
credentials, application data and chat history. See the [HDD inventory](hdd-inventory.md).
That inventory is not evidence of a completed HDD copy. Preserve it separately
before replacing the OS; local same-disk snapshots alone do not protect against
disk loss. The backup task does not delete or modify those resources.
