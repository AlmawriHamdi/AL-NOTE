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
