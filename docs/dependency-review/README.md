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
