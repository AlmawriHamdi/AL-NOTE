# Separate HDD backup inventory — 2026-09-23

**Inventory only: no HDD destination was supplied and no HDD copy is claimed.**
All paths below stay local and are excluded from the backup branch. Preserve
ownership, permissions, symlinks and hashes on an appropriate filesystem; review
private content before any external upload. Sizes are approximate allocated space
from this host, not transfer estimates; reflinks, hard links and nested snapshots
can change actual copy size substantially.

Repository-relative paths use `/home/Hamdi/Projacts/AL-NOTE`.

| Local material | Approximate size | Why preserve separately |
| --- | --- | --- |
| `build/sdk-upgrade-3.47.4/` | 11 GB | Pre-upgrade worktree/Git/protected-build reflink snapshot, old SDK config, hash inventories, retained SDK archive and evidence. Includes potentially private Git/config data; never upload wholesale. |
| `build/linux-pdf-controlled/` | 5.1 GB | Controlled PDFium checkout, native build tools, source revisions, patches and outputs. |
| `build/linux-pdf-tools/` | 14 MB | Local worker/guard/transport/probe outputs. |
| `build/linux-pdf-resources/` | 21 MB | Current verified extraction package; remotely recoverable from the exact current release. |
| `build/linux-pdf-resources-before-private/`, `-initial/`, `-pre-transport/` | 22 / 20 / 22 MB | Earlier rollback packages; these suffixes refer to the full `linux-pdf-resources` prefix. |
| `build/pdf-extraction-review/` | 448 MB | Pre-extraction source TAR/hash inventory, accepted package rollback, candidate binary/source archives, relocated builds, review and test logs. |
| `build/pdf-extraction-publication/` | 974 MB | Pre-publication source TAR, exact asset downloads, runtime source RPMs, fresh source/cache/build, anonymous acquisition and installed-host evidence. |
| `build/ci-resource-publication/` | 167 MB | Earlier immutable release assets, native/source inventories and publication/provisioning logs. |
| `build/sdk-ci-r1-r2/` | 15 MB | Explicit fixture setup and initial clean-environment CI correction evidence. |
| `build/pdf-object-review/`, `build/pdf-object-f1-review/` | 800 / 356 KB | Source scopes, geometry/history/host logs and correction evidence. |
| `build/pdf-host-check/`, `build/pdf-parity/`, `build/pdf-fixture/` | 45 / 46 / 7.3 MB | Host/browser evidence and independently pinned fixture runtime. |
| `build/pre-cachyos-backup/` | Growing, initially 2.9 MB | Original index/status/diff, inventory/security review and final Git/remote verification records for this backup. |
| `/tmp/al-note-pdf-objects-independent/` | 4.4 MB | Original failing/positive probes, logs, source hashes and raw independent evidence. |
| `/tmp/al-note-pdf-objects-f1-independent/` | 1.9 MB | Unchanged-reproducer reruns, independent geometry oracle and raw recheck evidence. |
| `/tmp/al-note-pdf-extraction-independent/` | 7.7 MB | Actual-host extraction, diagnostic worker/probes, source/package checks, skip reconciliation and logs. |
| `/home/Hamdi/Development/flutter-3.44.6/` | 1.7 GB | Old SDK rollback. |
| `/home/Hamdi/Development/flutter-3.47.4/` | 2.3 GB | Adopted SDK, also recoverable from the exact approved archive. |

Preserve both releases' complete eight-asset sets for offline recovery, including
native source and glibc/GCC source RPMs. Their hashes and origins are in the
[earlier publication report](../testing-release/sdk-347-ci-resource-publication.md)
and [extraction publication report](../testing-release/phase8-pdf-extraction-publication.md).
Verify copied bytes against those pins and the saved per-file inventories.

Other local material to review for the HDD copy: the repository `.git` directory
(local refs, reflogs and configuration), Android SDK/JDK/configuration and Gradle
wrapper files ignored by the project, the `al-note-dev` container/environment
definition, editor/Codex attachments or user-exported chat history, and any personal
notebook data. Their credentials/configuration are private, and this task neither
copies nor uploads them. Recreate `android/local.properties` for the new host.
Keep existing Gradle/build-tool versions. Chat export and personal-data backup are
separate user actions; the migration handoff is not a chat backup.

Broad application outputs (`build/app` about 2.1 GB, `build/linux` 144 MB,
`build/web` 51 MB), `.dart_tool`, Pub/Gradle/test caches and ephemeral Flutter
platform files are excluded from Git. They may be retained on HDD for rollback
or evidence, but should be regenerated in a fresh build location on CachyOS.
Do not delete protected engine/resources/evidence with a broad clean operation.

For the separate copy, first stop or coordinate writes, make a dated destination,
copy selected directories without following symlinks outside their roots, and
verify hashes plus a sample restore. Keep the original disk/snapshot until that
restore and the remote source commit have been verified. Do not infer that a
successful Git push preserves any of the excluded material above.
