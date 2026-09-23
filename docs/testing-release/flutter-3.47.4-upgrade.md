# Flutter 3.47.4 / Dart 3.13.3 upgrade candidate

Status: implemented and automated verification complete on 2026-09-14.
Candidate ready for Main AI and independent review; **not declared adopted**.
No commits, pushes, PR changes, tags, merges or publication.

## Artifact and preservation

The exact [official Linux x64 archive](https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.4-stable.tar.xz)
was rehashed against the user-approved digest and fresh
[official metadata](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)
before execution:

- Flutter 3.47.4, framework `9584c6713b324636289d067944a46fd6b49df14b`.
- Engine `06a2e2a110089dff50fe635cffd2a61e1b24fbcd`.
- Bundled Dart 3.13.3, source `1d1a730ef918d602aedafc939a4cf5940e7589ab`.
- Archive SHA-256 `5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3`.

**Provenance signatures remain UNVERIFIED.** The user explicitly approved
this exact official HTTPS archive with a matching published checksum. This
exception does not authenticate signatures or establish verified build provenance,
and does not relax PDF worker/package verification. The blocked signing-key
search was not repeated.

Installed separately at `/home/Hamdi/Development/flutter-3.47.4`; the existing
`flutter-3.44.6` remains installed. All commands use the logical repository path
`/home/Hamdi/Projacts/AL-NOTE` and explicit SDK paths.

Evidence root: `build/sdk-upgrade-3.47.4/evidence/` (local, ignored by Git).
The sibling `baseline/` is a reflink snapshot of the entire pre-upgrade worktree,
including tracked/untracked work, generated state, Git metadata, protected engine
sources/tools and accepted packages. It records 110,312 file/link entries and
9,134,288,412 logical bytes in `baseline-files.json`. This same-disk snapshot is
for rollback, not disk-loss protection. Old SDK configuration is separately saved
in `baseline-sdk-config/` with `sdk-config-files.json`. Resume verification found
zero baseline mismatches and zero intervening changes. `source-before-migration.json`
records the 514 unique tracked/untracked source files used for upgrade-only diffs.
Actual host process checks preceded mutations; editor services were left alone.

## Narrow migration

SDK constraints, `.flutter-version`, `.dart-version`, `tool/flutter_toolchain.json`
and CI now identify the candidate. Android CI explicitly selects its existing
JDK 17. Windows CI tests, analysis, formatting and build remain enabled.

| Dependency | Before → after | Required reason |
|---|---|---|
| matcher | 0.12.19 → 0.12.20 | Exact Flutter test pin |
| test_api | 0.7.11 → 0.7.12 | Exact Flutter test pin |
| meta | 1.18.0 → 1.18.3 | SDK minimum ^1.18.3 |
| vector_math | 2.2.0 → 2.4.0 | SDK minimum ^2.4.0 |

Initial resolution selected newer compatible meta/vector_math versions; targeted
downgrade of only those two retained the minimum required versions. Enforced
lockfile resolution then passed. No other locked dependency changed. PDF vendor
overrides/patches, PDFium, guard, transport and admission policy are unchanged.
No optional dependency upgrades were made.

The tool automatically added generated build/platform exclusions to
`analysis_options.yaml`; strict rules remain intact and app/tests stay analyzed.
Two obsolete `final` formal-parameter modifiers were removed from
`lib/app/al_note_app.dart` and `test/widget_test.dart` for Dart 3.13 parsing.
The new formatter changed 91 files in lib/test. An analyzer AST comparison across
all 213 formatted inputs at the formatter stage matches the snapshot after those two modifier removals;
no behavioral or expected-pixel changes were made. Vendor code was not formatted.
`.metadata`, Android build-tool files and plugin registrants match the pre-upgrade
snapshot despite their pre-existing Git changes.

The old SDK had a local fixture-test PDFium symlink that the pristine new SDK
lacked. Initial focused tests therefore failed to load fixture PDFium. The same
link was installed in the new SDK, after checking the target against the baseline:
`d106072a29b3689a5d6739948f98a97fe3ec82f5a1c309dc44e86f6c549fb44e`.
This local test-host setup is separate from the isolated production PDF package
and is not part of the official SDK archive. No fixture engine was upgraded.

The Android JVM helper initially selected a cached `-javadoc.jar`, causing
`NoClassDefFoundError: org/jetbrains/annotations/NotNull`, and selected an old
Flutter embedding lexicographically. `tool/check_pdf_android_native.py` now
excludes source/Javadoc classifiers and uses the engine revision from the project
pin. The rerun passed all 17 cases with the candidate embedding. This is a test
harness correction, not an Android application or dependency change.

## Worker and package

A separate Dart 3.13.3 AOT candidate was compiled and packaged before changing
pins. All 114 resource entries were checked; 111 are byte-identical. Differences:

| Resource | Candidate size | Candidate SHA-256 |
|---|---:|---|
| worker | 7,037,256 | `486252705aa92048472ea83a9956b9996e6cd1f2b724f0a9a2f9ec127bde473a` |
| vector_math LICENSE | 1,497 | `420f7739f169097f0aad1242045169cd643c8f1d94e62866fad265ae4c369b7d` |
| sky_engine LICENSE | 1,269,349 | `3c0040023a5789bf56d6bf41fd44f08b21758523d41f128fb7dd6beb398d1191` |

Worker size was 7,254,616 bytes. Both notices are unmodified copies from the
resolved upstream package/SDK. The reviewed vector_math diff updates its BSD
header and removes obsolete SimplexNoise attribution; the SDK aggregate diff
includes Vulkan placement, ICU notices, Inigo Quilez attribution, Dart fallback
root removal and copyright updates. Full notice diffs and resource review are
retained in the evidence directory. Engine source, native libraries, guard,
transport and other notices match the accepted package.

Candidate manifest SHA-256:
`82d1b451f94b2fa641a6931a899cfae781e23659fe5e1d17eb303d9a2d0fe298`.
The JSON manifest, Dart pin and CMake pin were updated together after review.
Normal packaging reproduced the reviewed manifest. The old canonical package is
preserved at `build/sdk-upgrade-3.47.4/accepted-package-before-switch/`, in addition
to the full snapshot, with manifest
`34c8908a55689bdd7f8a8795c0e32fe59eccf86dfea8aa71972649be38ab4824`.
Candidate/canonical/installed and both retained old copies passed all 114 hash
and length checks (`package-install-check.json`). Independent acceptance remains
pending; this local candidate is not declared adopted.

## Verification

Tests/builds personally run:

| Check | Result | Local evidence |
|---|---|---|
| Focused Text/IME, Pen, Selection, history, draft/observer, PDF/open/import | 383 passed, 1 host-only skip | `focused-rerun.log` |
| Full suite, once at final code/dependency state | 888 passed, 14 expected skips, 3 min 24 s | `full-suite.log` |
| Real-host protocol/cleanup/raster | 14 passed | `host-protocol-cleanup.log` |
| Private Linux opening, native image, near-limit cancellation | 4 passed | `private-after.log` |
| Installed package plus host Canvas/import/draft/disposal | 8 passed | `host-installed-canvas.log` |
| Relocated package, path with spaces | 3 passed; all 114 resource hashes verified | `host-relocated.log`, `relocated-check.json` |
| Native desktop startup | 3 old + 3 candidate launches, all reaped | `desktop-startup.json` |
| Formatting | 213 files, zero changes | `format-final.log` |
| Fatal-info analysis | No issues | `analysis-final.log` |
| Linux debug, private PDF flag | Passed | `linux-build.log` |
| Android debug APK | Passed, 264.1 s Gradle task | `android-build.log` |
| Android JVM transfer core | 17 passed with candidate embedding | `android-native-rerun.log` |
| Web release | Passed, 52.8 s; Wasm dry-run also passed | `web-build.log` |

Android retains AGP 9.0.1, Gradle 9.1.0, KGP 2.3.20, JDK 17, API 36/36,
minimum API 24 and NDK 28.2.13676358. The conditional alternative build-tool
migration was unnecessary. The Web build reported a Cupertino font-family
warning; no application Cupertino icon references were found. No renderer override
was added. CI jobs were not triggered. Local fixture tests depend on the recorded
SDK library symlink; fresh-runner fixture provisioning remains unverified.
Windows CI is preserved but has not been executed here.
No Android devices were connected (`adb devices -l`). Android device/provider/IME tests and physical desktop stylus/GPU acceptance are
not represented by the JVM and widget tests.

Initial focused run: 347 passed, 27 failures, 1 skip due to the missing fixture
library; rerun succeeded after restoring the baseline test-host link. Initial
Android JVM invocation failed because it selected a Javadoc jar; rerun succeeded
after the helper correction. An optional vendor-check invocation without its
required archive argument exited with usage only; no vendor audit or downloads
were performed. Vendor preservation is checked against the worktree snapshot.

The full suite was run once after the final code/dependency/helper changes.
Subsequent work changed only documentation/evidence; no full-suite rerun was
needed. Host-only tests and timing probes were run afterward. No engine rebuild,
new engine/provenance audit, Windows execution, Web browser runtime check, Android
device execution or pixel-baseline regeneration was performed. Final package
checks again found zero mismatches in canonical, installed and retained old
packages; the final systemd PDF worker-unit list was empty.

## Exact change and generated-artifact scope

`source-changes.json` and `upgrade-source.patch` in the evidence directory compare
against the preserved working tree, **not HEAD**. `formatting-only.patch` and
`compatibility-and-pins.patch` separate formatter churn from the remaining edits.
They identify 105 upgrade-owned
source paths: 90 formatting-only files, one formatting-plus-parser file
(`test/widget_test.dart`), one parser-only file (`lib/app/al_note_app.dart`),
the Dart package digest pin, and these 12 remaining paths:

- `.dart-version`, `.flutter-version`, `.github/workflows/verify.yml`.
- `analysis_options.yaml`, `pubspec.yaml`, `pubspec.lock`.
- `tool/flutter_toolchain.json`, `tool/check_pdf_android_native.py`.
- `tool/linux_pdf/packaged_resources.json`, `linux/CMakeLists.txt`.
- `docs/dependency-review/README.md`, this report (new).

The existing branch and HEAD are unchanged. Pre-existing edits to `.metadata`,
Android build files, Linux/Windows plugin registrants and all vendor files remain
intact. `protected-final-check.json` verifies the unchanged controlled library,
protected tool files and all eight recorded old SDK configuration files.

Generated changes include SDK/package resolution state in `.dart_tool` and
`.flutter-plugins-dependencies`; `android/local.properties`; Linux ephemeral
headers/configuration and CMake outputs; the new canonical/installed PDF package;
Linux debug bundle, Android APK/native intermediates and Web release output.
`build-artifacts.json` records primary output hashes. The old
`build/linux-pdf-tools/worker` was preserved; the candidate executable is separate.
No protected engine build tree was deleted or rebuilt, and no `flutter clean`
was used. Global PATH/editor services were not switched; use the explicit SDK
commands below until review determines adoption.

## Measurements and runtime limits

Comparable inputs were run without concurrent task builds. These are small,
non-randomized local samples with uncontrolled OS caches/background activity;
they establish observations, not a causal speedup or a resolved performance bug.

| Measurement | Flutter 3.44.6 | Flutter 3.47.4 |
|---|---:|---:|
| Production widget startup, median of 3 (ms) | 1,197.9 | 933.2 |
| First 30-move stylus stroke through widget harness, median of 3 (ms) | 1,223.7 | 1,388.2 |
| Native debug process to VM-service readiness, median of 3 (ms) | 578.9 | 632.0 |
| 50 MB private PDF open (ms), one measured run | 5,221 | 4,712 |
| Same open through native image preparation (ms) | 7,527 | 6,607 |
| Same path maximum event-loop gap (ms) | 147.9 | 138.0 |
| Same process lifetime high-water RSS (bytes) | 510,754,816 | 513,486,848 |

Three old and three candidate widget probe invocations each passed. Four old-SDK
private-host baseline tests also passed before migration.

The widget probe uses production `app.main()`, fixed virtual frame steps and
existing debug diagnostics. It is not physical stylus latency. Native process
readiness is not first-visible-frame latency, and fresh processes do not imply
cold disk/GPU caches. All six desktop launches remained alive until deliberate
termination and were reaped. The candidate actually selected default Impeller
(OpenGLESSDF); no renderer override was used. Both SDKs logged the same ATK embed
and cursor-theme warnings. Physical input and visual GPU conformance remain for
manual review. First-stroke and native readiness medians were slower in these
small samples; no Pen fix or performance improvement is asserted.

The candidate real-host raster test retained exact native pixel readback at
400, 800, 1600, 3200 and 4096 square pixels. Maximum event-loop gaps were
20.964, 24.420, 14.348, 58.320 and 84.757 ms; 4096-square render-to-image
completion took 770.791 ms. These are measured handoff results, not just counters.
Controller-outage tests confirmed two rounds of four descendant PIDs cleaned up
(`empty=true`, `reaped=true`) before recovery. Superseded cold staging cancelled
in 5/2/3 ms. See `host-protocol-cleanup.log`, `performance-comparison.json`,
`private-before.log`, `private-after.log`, `canvas-before/after-*.log` and
`desktop-startup.json` for raw measurements.

Separate accepted findings remain unresolved: 8 MB Reopen caused a 2.20-second
UI stall; 50 MB Save rejection caused a 4.69-second UI stall; the earlier run's
2.21 GB process high-water RSS was not proven allocation by one operation.
Opening permits 50 MB while storage has separate 10 MB limits. This SDK upgrade
does not claim to fix those issues. Android PDF remains deferred; Web/Windows
ordinary-PDF admission and release/untrusted-input quarantine are unchanged.

## Rollback and manual acceptance

Before rollback, stop candidate application/build/test activity and preserve any
edits made after this handoff. Restore only upgrade-owned source paths from the
pre-upgrade `baseline/`, using the before/after hash inventory to detect intervening
edits. Never reset to HEAD or overwrite the live `.git`. Restore the three package
pins and accepted package together. Restore affected SDK-specific generated state
from the snapshot or narrowly regenerate it with the old SDK; leave controlled
PDF engine sources/tools untouched. Restore old `android/local.properties` and
any changed local SDK configuration. Use explicit `flutter-3.44.6` paths. Both SDKs
can remain installed; no broad clean is necessary.

Manual acceptance after automated checks: cold desktop startup and first stylus
stroke/pressure; Text/IME composition and draft retention; Pen, Selection,
Undo/Redo; private Linux PDF opening/notebook import, cancellation/navigation and
save/reopen. Android device/IME/GPU and Windows execution require their platforms.
Existing Pen and Save/Reopen performance findings are not claimed fixed.

## Reproduction commands

Commands personally run use the existing `al-note-dev` container for builds and
the actual host for the isolated worker. Do not run the private PDF application
inside the container, where the host isolation controller is unavailable.

```sh
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && /home/Hamdi/Development/flutter-3.47.4/bin/flutter build linux --debug --no-pub --dart-define=ALNOTE_LINUX_PRIVATE_PDF_TEST=true'
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && /home/Hamdi/Development/flutter-3.47.4/bin/flutter build apk --debug --no-pub'
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && /home/Hamdi/Development/flutter-3.47.4/bin/flutter build web --release --no-pub'
distrobox enter al-note-dev -- bash -c 'cd /home/Hamdi/Projacts/AL-NOTE && python3 tool/check_pdf_android_native.py'

# Launch the installed private Linux debug candidate on the host:
cd /home/Hamdi/Projacts/AL-NOTE
./build/linux/x64/debug/bundle/al_note
```

The exact worker compile/package commands are retained in
`build/sdk-upgrade-3.47.4/evidence/package-build-commands.txt`. The package destination
must be absent; preserve an existing package before reproducing packaging.

A guarded source rollback helper is provided in the evidence directory. Its
no-argument dry run verifies every current after-hash and every baseline before-hash
before allowing any restoration. After stopping candidate activity:

```sh
cd /home/Hamdi/Projacts/AL-NOTE
python3 build/sdk-upgrade-3.47.4/evidence/rollback-source.py
# After reviewing the dry run, --apply restores only the recorded source delta
# and first archives the candidate source. It does not change Git metadata.
python3 build/sdk-upgrade-3.47.4/evidence/rollback-source.py --apply
```

Complete rollback by archiving the current `build/linux-pdf-resources` and copying
`accepted-package-before-switch` back there. Archive and restore the baseline
`.dart_tool`, `.flutter-plugins-dependencies`, `linux/flutter/ephemeral`,
`build/linux` (including the old installed bundle), and `android/local.properties`.
If old Android/Web outputs are needed, similarly restore `build/app` and `build/web`
from the snapshot. Use `cp -a --reflink=always` into absent destinations after moving
the candidate aside; this preserves both versions without broad deletion. Other
SDK-generated caches can be narrowly archived and regenerated with the old SDK.
Never restore the entire build directory over protected resources or copy `.git`.
