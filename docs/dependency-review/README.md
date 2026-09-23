# Dependency and License Review

Every application package, development package, native binary, build plugin,
compiler, SDK, GitHub Action, and bundled resource requires review before it is
added or updated. Convenience alone is not sufficient reason to add a
dependency.

## Required record

A dependency change must be presented separately and record:

- exact version, immutable revision, and checksum where available;
- canonical source, publisher, and maintainers;
- direct purpose and the AL NOTE-owned boundary behind which it is used;
- complete transitive dependency and bundled-binary inventory;
- license and notice obligations, including GPL-3.0-or-later compatibility;
- supported AL NOTE platforms and packaged-build behavior;
- maintenance status, release history, and replacement or removal plan;
- vulnerability, provenance, privacy, and security review;
- required source correspondence and redistribution material;
- verification performed on every supported or affected target.

Unknown provenance, an incompatible license, an unbounded native component, or
an unreviewed transitive dependency blocks adoption. Automated reports provide
evidence; they do not approve a dependency.

## Change procedure

1. State the capability gap and why Flutter, Dart, or existing AL NOTE code
   cannot meet it.
2. Compare maintained alternatives, including implementing a small
   AL NOTE-owned abstraction when appropriate.
3. Produce the required record and identify the reviewing owner.
4. Pin the accepted version or immutable revision and regenerate the lockfile.
5. Inspect the lockfile and platform-generated changes; do not accept unrelated
   upgrades.
6. Run formatting, static analysis, tests, affected platform builds, packaged
   smoke checks where available, license checks, and security checks.
7. Commit the dependency change separately so its evidence is reviewable.

Updates follow the same process. Dependabot may propose an update, but updates
are never merged automatically.

## Phase 0 baseline

The runtime dependency surface is the pinned Flutter SDK. Test support comes
from the Flutter SDK. Phase 0 has no hosted direct application or development
dependencies. Flutter uses BSD-3-Clause licensing, which is compatible with AL
NOTE's GPL-3.0-or-later distribution. The authoritative resolved package
versions and SHA-256 hashes are in `pubspec.lock`.

The verification workflow uses one source-only Action at an immutable commit:

- `actions/checkout` v6.0.2 at
  `de0fac2e4500dabe0009e67214ff5f5447ce83dd`.

It is MIT-licensed. Its immutable source and action definition must be
re-reviewed before the pin changes. The workflow installs Flutter directly
from the official Flutter Git repository and verifies the detached SDK checkout
against commit `ee80f08bbf97172ec030b8751ceab557177a34a6`.

## Phase 1 identity dependency

Phase 1 uses `uuid` only inside a private adapter that formats injected random
bytes as RFC 9562 version 4 UUID text. AL NOTE-owned validation converts that
generated text into `UuidIdentifier`; the package is not used for public
identifier parsing. The package is published by `yuli.dev` from
<https://github.com/Daegalus/dart-uuid>; version `4.6.0` corresponds to tag
commit `d602950818e4b11d097d26f5408b461f38248130`. The package and its resolved
transitive dependencies are pure Dart.

The exact hosted-package graph added by this change is:

```text
uuid 4.6.0 (direct, MIT)
├── crypto 3.0.7 (transitive, BSD-3-Clause)
│   └── typed_data 1.4.0 (transitive, BSD-3-Clause)
│       └── collection 1.19.1 (pre-existing transitive, unchanged)
└── fixnum 1.1.1 (transitive, BSD-3-Clause)
```

The reviewed pub.dev archive SHA-256 checksums are:

| Package | Version | SHA-256 |
| --- | --- | --- |
| `uuid` | `4.6.0` | `9b129329f58692f6e6578329498a8fe9fbe98f090beb764ffbb8ee2eadd01dcd` |
| `crypto` | `3.0.7` | `c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf` |
| `fixnum` | `1.1.1` | `b6dc7065e46c974bc7c5f143080a6764ec7a4be6da1285ececdc37be96de53be` |
| `typed_data` | `1.4.0` | `f9049c039ebfeb4cf7a7104a675823cd72dba8297f264b6637062516699fa006` |

`uuid` remains behind AL NOTE-owned identity contracts so it can be replaced
without changing callers. Package-defined types will not cross the public API.
Generated UUIDs identify entities only: they will not be used as authorization
tokens, secrets, hashes, revisions, or proof of any security property.

The reviewed graph contains no native binaries, Flutter plugins, code
generation, runtime networking, or bundled assets. Its pure-Dart behavior
covers AL NOTE's required Android, Linux, Web, and Windows platforms.

On July 24, 2026, exact-version OSV queries for the Pub ecosystem packages
`uuid 4.6.0`, `crypto 3.0.7`, `fixnum 1.1.1`, `typed_data 1.4.0`, and the
unchanged `collection 1.19.1` returned no OSV records. Absence of returned OSV
records is evidence for this review, not a security guarantee.

## Phase 4 storage dependencies

Phase 4 needs a maintained, hostile-input-aware ZIP implementation that works
from memory on Android, Linux, Web, and Windows, plus exact SHA-256 calculation.
The Dart SDK supplies strict UTF-8 and JSON string escaping but no general ZIP
decoder and no SHA-256 implementation. Manually implementing a general hostile
ZIP decoder was rejected because central/local-header reconciliation, deflate,
CRC, ZIP64, encryption, entry typing, and malformed-container behavior form a
large security-sensitive maintenance surface. `archive 4.0.9` is selected
behind a private memory-only adapter. The adapter independently preflights raw
ZIP metadata, paths, types, ZIP32 bounds, sizes, ratios, and CRC before AL NOTE
uses decoded bytes. It imports only `package:archive/archive.dart`; no package
archive, hash, stream, filesystem, or path type crosses the public API.

JSON code generation (`json_serializable`, Freezed, and `build_runner`) and
third-party JSON or immutable-collection packages were rejected. SDK
`dart:convert` plus an AL NOTE-owned bounded recursive-descent parser provides
duplicate-key detection, strict UTF-8, depth/value/string ceilings, Web-safe
number policy, structural unknown-field preservation, and canonical encoding
without generated code. `crypto 3.0.7`, already resolved and reviewed in Phase
1, is promoted from transitive to direct solely for the private SHA-256 adapter;
its version and checksum are unchanged.

Reviewed provenance and notices:

| Package | Publisher | Repository and immutable source | License and notices | Pub archive SHA-256 |
| --- | --- | --- | --- | --- |
| `archive 4.0.9` | `loki3d.com` | <https://github.com/brendan-duncan/archive>, tag `v4.0.9`, commit `f01d6a340ffe24e0ef46fa682d1b6bcc7b7aef13` | MIT; `LICENSE-other.md` retains permissive MIT, BSD-style JZlib, bzip2, and Pointy Castle notices | `a96e8b390886ee8abb49b7bd3ac8df6f451c621619f52a26e815fdcf568959ff` |
| `posix 6.5.2` | `onepub.dev` | <https://github.com/onepub-dev/dart_posix>, tag `6.5.2`, commit `3c544340f3e4ffc64b20e6959ae8229c98638a0a` | MIT | `bc1bad54ad2b735816e31f8d4600cfde6c7839975085ddfbca48b6c9f7c4044e` |
| `ffi 2.2.0` | `dart.dev` | <https://github.com/dart-lang/native/tree/main/pkgs/ffi>, tag `ffi-v2.2.0`, commit `cc90d34518c8462c0867fc6d1177028e474157ef` | BSD-3-Clause | `6d7fd89431262d8f3125e81b50d3847a091d846eafcd4fdb88dd06f36d705a45` |
| `crypto 3.0.7` | Pub reviewed package | existing reviewed source | BSD-3-Clause | `c8ea0233063ba03258fbcf2ca4d6dadfefe14f02fab57702265467a19f27fadf` |
| `path 1.9.1` | Dart ecosystem | existing resolved source | BSD-3-Clause | `75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5` |
| `meta 1.18.0` | `dart.dev` | existing resolved source | BSD-3-Clause | `1741988757a65eb6b36abe716829688cf01910bbf91c34354ff7ec1c3de2b349` |

The exact relevant resolved graph is:

```text
archive 4.0.9 (direct)
|-- path 1.9.1 (pre-existing, unchanged)
`-- posix 6.5.2 (new)
    |-- ffi 2.2.0 (new)
    |-- meta 1.18.0 (pre-existing, unchanged)
    `-- path 1.9.1 (pre-existing, unchanged)

crypto 3.0.7 (promoted to direct; version/checksum unchanged)
`-- typed_data 1.4.0 (pre-existing)
    `-- collection 1.19.1 (pre-existing)

uuid 4.6.0 and its existing graph are unchanged.
```

Exactly `archive`, `posix`, and `ffi` are newly hosted in the lockfile. The
conditional `posix`/`ffi` portion consists of Dart bindings for native system
APIs and contains no bundled native binary. AL NOTE production code never
imports or calls `posix`, `ffi`, or `path`; archive use remains in the private
memory adapter and does not use `archive_io`, disk extraction, path helpers,
passwords, encryption, or package RNG output. SHA-256 use remains in a separate
private adapter. Both adapters are replaceable without changing the public
surface.

The graph is pure Dart for the required Android, Linux, Web, and Windows
targets. It adds no Flutter plugin, native binary, build hook, generated code,
runtime networking, downloaded asset, or platform-project change. Web build
verification covers the private memory archive path and proves that AL NOTE's
portable code does not import native-only APIs.

On July 27, 2026, exact-version OSV Pub-ecosystem queries returned no records
for `archive 4.0.9`, `posix 6.5.2`, `ffi 2.2.0`, `crypto 3.0.7`, `path 1.9.1`,
or `meta 1.18.0`. Absence of returned records is evidence, not a security
guarantee. Historical archive path-traversal and symlink advisories affected
older releases; their status does not replace AL NOTE's mandatory canonical
path, duplicate/collision, entry-type, header, size, and extraction-safety
validation. AL NOTE never constructs a platform path from an archive name and
never extracts package entries to disk.

## Phase 7 Unicode grapheme dependency

Phase 7 needs Unicode extended-grapheme-cluster boundaries for ordinary Text
Object editing. Dart strings expose UTF-16 code units and Unicode scalar values,
but the SDK does not provide the Unicode grapheme segmentation required to keep
combining sequences, variation selectors, emoji modifiers, flags, and ZWJ
sequences intact. A handwritten segmentation algorithm was rejected because it
would duplicate a large, versioned Unicode conformance surface with substantial
correctness and security risk.

`characters 1.4.1` is published by `dart.dev` from
<https://github.com/dart-lang/core/tree/main/pkgs/characters>. The reviewed
source is tag `characters-v1.4.1`, commit
`b59ecf4ceebe6153e1c0166b7c9a7fdd9458a89d`, and the pub archive SHA-256 is
`faf38497bda5ead2a8c7615f4f7939df04333478bf32e4173fcb06d428b5716b`.
It is BSD-3-Clause licensed and compatible with AL NOTE's
GPL-3.0-or-later distribution.

The package was already resolved transitively at exactly version `1.4.1` with
that checksum. Phase 7 promotes it to a direct dependency without adding,
upgrading, or downgrading any transitive package. It is imported only by a
private AL NOTE-owned grapheme adapter; package-owned types do not cross public
APIs, and the adapter is the replacement boundary.

Version 1.4.1 implements Unicode 16.0.0 grapheme behavior. It is pure Dart and
supports AL NOTE's Android, Linux, Web, and Windows targets. The reviewed
package adds no native binaries, Flutter plugins, code generation, runtime
networking, or bundled assets.

On August 9, 2026, an exact-version OSV query for Pub package
`characters 1.4.1` returned no records. Absence of returned OSV records is
evidence for this review, not a security guarantee.

## Phase 8 provisional PDF development dependency

Phase 8 needs a maintained PDF parser and renderer; Flutter does not include
one, and AL NOTE will not implement a PDF engine. At the user's direction,
`pdfrx 2.4.8` is pinned exactly as a provisional development dependency while
AL NOTE remains unreleased. This is not approval to open arbitrary or untrusted
PDFs and is not a release acceptance of the bundled PDFium engine.

Version `2.4.8` was selected against the reviewed Flutter `3.44.6` baseline.
The Flutter `3.47.4` / Dart `3.13.3` upgrade candidate retains this version and
the existing vendor patches. `pdfrx 2.5.0` is an optional, separate dependency
migration; satisfying its Flutter floor does not approve that migration.
The direct pub archive SHA-256 recorded by the lockfile is
`85a87117ae6358e0ef2cc90d4db9f5e689eabbd7f19ab98c97164584d0be4a4a`.
The canonical source and publisher are
<https://github.com/espresso3389/pdfrx> and `espresso3389.jp`.

The new PDF integration chain is:

```text
pdfrx 2.4.8 (direct, MIT)
|-- pdfrx_engine 0.4.7 (MIT)
|   `-- pdfium_dart 0.2.5 (MIT wrapper; PDFium native assets)
`-- pdfium_flutter 0.2.3 (MIT)
    `-- pdfium_dart 0.2.5
```

The complete newly resolved hosted-package inventory is `args 2.7.0`,
`code_assets 1.2.1`, `hooks 2.0.2`, `http 1.6.0`, `http_parser 4.1.2`,
`image 4.9.2`, `jni 1.0.3`, `jni_flutter 1.0.3`, `jni_util 1.0.0`,
`logging 1.3.0`, `objective_c 9.5.0`, `package_config 3.0.0`,
`path_provider 2.1.6` and its platform packages, `pdfium_dart 0.2.5`,
`pdfium_flutter 0.2.3`, `pdfrx 2.4.8`, `pdfrx_engine 0.4.7`,
`platform 3.1.6`, `plugin_platform_interface 2.1.8`, `pub_semver 2.2.1`,
`record_use 0.6.0`, `rxdart 0.28.0`, `synchronized 3.4.1+2`,
`url_launcher 6.3.2` and its platform packages, `web 1.1.1`,
`xdg_directories 1.1.0`, and `yaml 3.1.4`. Exact versions and pub archive
SHA-256 values for every package are authoritative in `pubspec.lock`.
Pre-existing `archive`, `collection`, `crypto`, `ffi`, `meta`, `path`, and
`vector_math` packages are reused without version changes.

The reviewed Dart and Flutter packages use MIT, BSD-3-Clause, or Apache-2.0
licenses compatible with AL NOTE's GPL-3.0-or-later distribution. PDFium's
permissive core license is not the entire redistribution record: its bundled
third-party notices and exact binary sources remain mandatory before release.

The current `pdfium_dart 0.2.5` build hook names PDFium release
`chromium/7811`, downloads a target archive from the third-party
`bblanchon/pdfium-binaries` GitHub releases during a native build, and does not
verify an expected archive or library checksum. Those provenance and
vulnerability findings are unresolved. Native PDF opening is therefore
restricted to trusted development fixtures until a reviewed patched engine is
in place. No PDF URL constructor, PDF action, JavaScript, attachment, form,
launch action, or arbitrary-file UI may be enabled under this provisional
record.

The September 3, 2026 local build produced the following ignored artifacts.
These hashes identify the bytes that were actually built and tested; they do
not cure the build hook's missing upstream expected-hash verification:

| Target artifact | Bytes | Local SHA-256 |
| --- | ---: | --- |
| Windows x64 `pdfium.dll` | 7,176,704 | `019b6ee6e54e5508002e43c5199b00f6caca26d32dd23c7bb229ff6855cd5394` |
| Android x64 `libpdfium.so` | 6,604,440 | `dd8c2880d41baf4c6406d5d2bf0c1beffe42b45e756ff08a9c612ad35d5a5c64` |
| Android arm64 `libpdfium.so` | 6,386,696 | `ef8c440d29e2a0820a65554487d23020bd88756ee2d6aad8f8fb59bab3b2eb14` |
| Android arm `libpdfium.so` | 4,209,140 | `3d67be8a7f8a4f77e5a91530fbab69e0b27a8f4f4db5d4a0df512fbfaf40bd27` |
| Web `pdfium.wasm` | 5,231,809 | `5b2cbb18e9dc361dae375e971c7e75f7306d39b7749ad4fced475579e6a549df` |

All future use must sit behind AL NOTE-owned backend-neutral contracts. No
`pdfrx`, `pdfrx_engine`, or PDFium type may cross a public, persistent, Command,
Storage, Rendering, Search, or UI contract. The exact pin may later be replaced
by a reviewed upstream release, immutable fork, or locally patched package
without changing document data or callers. Removing the direct dependency and
private adapter remains the rollback path.

This provisional installation has resolved the lockfile and generated the
expected Linux and Windows plugin registrants. Analysis, tests, affected builds,
native-asset download verification, complete PDFium notice/source collection,
runtime hostile-input testing, and the Flutter `3.47` migration remain separate
gates. Nothing in this record authorizes release distribution.

## Phase 8 local file-selection dependency

The local PDF opening slice needs a user-mediated, cross-platform content
selection boundary. Flutter does not provide one in the SDK. Direct filesystem
paths are not a portable substitute: Web selections are memory-backed and
Android selections may be content-backed. At the user's direction,
`file_selector 1.1.0` is pinned exactly. It is published by the Flutter team
from <https://github.com/flutter/packages/tree/main/packages/file_selector>.
The package and every resolved platform implementation are BSD-3-Clause.

The complete hosted-package graph newly added by this pin is:

| Package | Version | Pub archive SHA-256 | Implementation |
| --- | --- | --- | --- |
| `file_selector` | `1.1.0` | `bd15e43e9268db636b53eeaca9f56324d1622af30e5c34d6e267649758c84d9a` | Federated Flutter API |
| `cross_file` | `0.3.5+5` | `f141ea4f277af142a0356955707f6556f37b03947d39d55585981a06ca437bd6` | Portable selected-content handle |
| `file_selector_android` | `0.5.2+10` | `7c76473740e33a11343c8fce88166049230850d2f19cd8a652ea935fcb8c9206` | Android system document picker and content access |
| `file_selector_ios` | `0.5.3+6` | `97269e5307a0ab813b1fa2430bada0a96e0afb74848417f8676f64ba5de0051c` | Resolved federated iOS implementation; not an AL NOTE target |
| `file_selector_linux` | `0.9.4+1` | `da76400e7872ce7637ffdce12749ec24169c25f6195c28372208e65a24bcd2ab` | GTK file chooser plugin |
| `file_selector_macos` | `0.9.5+1` | `d57c62362766b5e7ae739448650b66c6aab7a68ba7ecc65e04018652645ae0f4` | Resolved federated macOS implementation; not an AL NOTE target |
| `file_selector_platform_interface` | `2.7.0` | `35e0bd61ebcdb91a3505813b055b09b79dfdc7d0aee9c09a7ba59ae4bb13dc85` | Federated platform contract |
| `file_selector_web` | `0.9.5` | `73181fbc5257776d8ecaa6a94ab3c8e920ad143b9132a6d984a9271dfc6928d3` | Browser file-input implementation |
| `file_selector_windows` | `0.9.3+6` | `fbefc5fb92c6d3cbe8d284a2cd971b593bb07d2cd6da8557b81a862250b4acec` | Windows native file-dialog plugin |

At the original host-picker review, the graph reused already-resolved `flutter`, `flutter_web_plugins`,
`http 1.6.0`, `meta 1.18.0`, `plugin_platform_interface 2.1.8`, and `web 1.1.1`
without changing their versions. The package SDK constraints are compatible
with Dart `3.12.2` and Flutter `3.44.6`; the tightest resolved requirement is
the Android implementation's Dart `^3.12.0` and Flutter `>=3.44.0` floor.

The subsequent Flutter `3.47.4` / Dart `3.13.3` candidate changes only four
locked packages: `matcher 0.12.19 → 0.12.20` and `test_api 0.7.11 → 0.7.12`
are exact Flutter test requirements; `meta 1.18.0 → 1.18.3` and
`vector_math 2.2.0 → 2.4.0` meet the new SDK's minimum constraints. All other
locked versions and both PDF vendor overrides are retained. See the
[upgrade evidence and review status](../testing-release/flutter-3.47.4-upgrade.md).

The generated Linux and Windows registrants add only their corresponding
`file_selector` plugins. Android and Web use their federated registrations at
build time. The reviewed package archives contain source implementations, not
prebuilt native binaries: Android uses Java and the platform picker, Linux
uses C++/GTK, Windows uses C++ and the system dialog, and Web uses Dart/browser
APIs. The unused resolved Apple implementations contain their platform source.

Correction 2 supersedes the initial host-reading assessment. The pinned Android
implementation (`FileSelectorApiImpl.java`, lines 329–365) allocates `byte[size]`
from provider metadata, reads it completely, and then calls
`FileUtils.getPathFromCopyOfFileFromUri`, which creates a cache copy. Its public
`openFile` API has no byte-budget parameter. AL NOTE now rejects Android fixture
opening before invoking that plugin. Disabling this unsafe route is not an
implementation of Android Open PDF; a separately authorized native reader is
required. No plugin source or dependency version was changed.

Linux 0.9.4+1 and Windows 0.9.3+6 return selected paths from their native dialogs
without reading content. The private desktop adapter uses that path only to open
one read-only Dart file handle, reads at most 64 KiB per operation with a bounded
overflow probe, counts delivered bytes, and closes the handle in `finally`.
It does not invoke `XFile.openRead`, consult file length, or create a disk copy.
Linux native reading is tested; Windows behavior is supported by source
inspection, not physical Windows execution in this correction.

Web 0.9.5 creates an object URL and `cross_file 0.3.5+5` rehydrates it as a Blob;
its `openRead()` materializes the whole slice through FileReader when no end is
specified. AL NOTE's private Web host now uses the standard file-input/Blob APIs
directly through `dart:js_interop`, with no new dependency. It creates no object
URL or XMLHttpRequest and reads bounded Blob slices only. Size metadata can
reject early but never authorizes capture or truncates actual byte counting.
Cancellation aborts an active reader and removes all picker/reader listeners.

The public AL NOTE boundary carries only fixed outcomes, bounded bytes, budgets
and cancellation; no path/name/URI or package type escapes. Filters and local
selection confer no trust. The fixed controlled-fixture digest policy is checked
before workflow inspection, before canvas rendering, and again at the private
parser boundary using the exact immutable bytes. Release composition remains
quarantined. See [Correction 2 evidence and Android design](../testing-release/phase8-correction2.md)
for allocation/copy bounds, actual platform checks and remaining limitations.

On September 3, 2026, exact-version queries to the official OSV API returned
empty results for all nine newly resolved hosted packages in the table above.
An empty OSV result is review evidence, not proof that a package is free of
vulnerabilities. The remaining security exposure is the expected native file
dialog/content-read authority; AL NOTE neither broadens that authority to
arbitrary paths nor treats a picker filter or host declaration as PDF validity.

## Phase 8 exact pdfrx page-box patch

The local PDF vertical slice retains pruned trees from the official pub archives
for `pdfrx 2.4.8` and `pdfrx_engine 0.4.7` under `third_party/`, then applies a
focused source patch. The upstream archive SHA-256 values are respectively
`85a87117ae6358e0ef2cc90d4db9f5e689eabbd7f19ab98c97164584d0be4a4a` and
`4399846809a75aed03881d8b8a19e5e70addd4b46b22fd94a0effd8859258f07`.
Both packages are published by `espresso3389.jp`, sourced from
<https://github.com/espresso3389/pdfrx>, and retain their original MIT license
(vendored license SHA-256
`050ccfd8256df03e5ccaec222c0f87a4e5e2069c69515f027b534a63fb00fe23`).
The path overrides preserve the exact package versions; no unrelated package
version changed.

The patch exposes immutable effective rendering bounds via supported PDFium
`FPDF_GetPageBoundingBox` and effective rotation via `FPDFPage_GetRotation`, on
native and Web. The resulting `resolvedBounds` classification carries no claim
about raw box kind or inheritance provenance. It accepts PDFium's normalized,
inherited, clipped region and rejects unavailable, nonfinite or empty bounds.
The private adapter verifies binary32 subtraction rounding exactly, retains the
source endpoints and persists exact double extents. The receiving model and
saved-geometry comparisons retain strict validation. See the
[geometry contract](../../lib/documents/pdf/README.md#page-boxes).

The worker closes form state and the loaded document before releasing backing
memory/file/range storage on initialization failure, including null-handle
errors. Ownership transfers once, at the end of successful initialization;
range-loading error cleanup cannot close the transferred handle again. Per-
document font/disposer/range maps are cleared without erasing another live
document's font evidence. The Dart bridge closes a returned worker document if
local evidence decoding fails. The earlier native fixed-error-code correction
is retained.

The complete [vendor inventory](pdfrx-vendor.json) records all 92 retained files
by count, the five modified hashes, and every omitted upstream path: 128 files
from pdfrx and eight from pdfrx_engine (analyzer configuration, examples and
tests). Both original MIT licenses and binary assets remain byte-identical to
the archives. Run the offline verifier with the two exact official archives:

```sh
python3 tool/check_pdf_vendor.py --archives /tmp/al-note-phase8-vendor
```

The checker verifies archive digests before comparing every retained byte,
changed-file set and omitted path. No archive code is executed or extracted.

Only these **retained** upstream files differ from their archive versions;
pruned files are exhaustively listed in the inventory:

| Patched file | Patched SHA-256 |
| --- | --- |
| `pdfrx_engine/lib/src/pdf_page.dart` | `664bf61d658c187f4be093a2f4aa1e93298fd0f3e0ea96255d55667532af09ee` |
| `pdfrx_engine/lib/src/pdf_page_proxies.dart` | `38dd44414dfd5b8996761c193c37e967e46768c1ea978336844d0a55977a46b6` |
| `pdfrx_engine/lib/src/native/pdfrx_pdfium.dart` | `f828079f59fd27e0273ddb6d9e3a05fe6da91003f0ca4ecb4b2413639fb7181c` |
| `pdfrx/assets/pdfium_worker.js` | `d6662f8255c1b9f27fc889d4e8c6fe26f39d8855290eef2a840275a6bc6a86e7` |
| `pdfrx/lib/src/wasm/pdfrx_wasm.dart` | `38b6abff4888ddc268b60405f98ea454137a743a3fdd7b25152ad6c9ae6e2b62` |

The public package evidence contains no document bytes, paths, names,
passwords, URIs, exception text, JavaScript/action data, links, forms,
attachments, or other active content. The AL NOTE adapter uses memory-only
`openData`, disables annotation appearance rendering, does not expose pdfrx or
PDFium types, and remains enabled only for explicitly trusted local input in a
debug build. Release and ordinary untrusted input retain the quarantined
backend. The shared-reference enum now adds `resolvedBounds` under schema 1:
old named references are retained and checked against exact geometry; older
builds reject references using the new value. Replacing this engine requires
preserving this geometry contract or explicitly declining unsupported mappings.

[Correction 1 verification](../testing-release/phase8-correction1.md) records
reproducible marked native/Web checks, cleanup counts and remaining blockers.
The native download authentication and release/untrusted-input gates described
above remain unresolved; archive correspondence does not resolve them.
