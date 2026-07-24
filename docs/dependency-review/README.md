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
