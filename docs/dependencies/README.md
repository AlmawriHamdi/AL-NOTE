# Dependency and License Review

AL NOTE is distributed as `GPL-3.0-or-later`. Phase 0 authorizes no third-party runtime dependencies.

## Current dependency inventory

| Package | Scope | Source | License status | Notes |
|---|---|---|---|---|
| Flutter SDK | SDK | flutter.dev / github.com/flutter/flutter | BSD-style Flutter SDK licenses; project output remains GPL-3.0-or-later | Required application framework for approved targets. |
| Dart SDK | SDK | Bundled with Flutter 3.44.6 | BSD-style Dart SDK licenses | Pinned by Flutter 3.44.6. |
| flutter_test | Dev/test SDK package | Flutter SDK | SDK license | Required for the starter widget test. |
| flutter_lints 6.0.0 | Dev analysis | pub.dev | BSD-3-Clause | Development-only static-analysis rules. |

## Review procedure for any future dependency, bundled binary, or platform tool

Before adding a dependency, open a separate review that records:

1. Required package, binary, or platform tool and exact version.
2. Why it is required and which accepted subsystem owns the need.
3. License and GPL-3.0-or-later compatibility.
4. Upstream provenance, repository, release process, and maintenance status.
5. Supported AL NOTE platforms: Linux, Windows, Android, and Web.
6. Security posture, transitive dependencies, native code, network behavior, and supply-chain risks.
7. Packaged-build impact, artifact size, update cadence, and long-term maintenance burden.
8. Alternatives considered, including SDK-only options and deferring the feature.
9. Recommendation and explicit approval before implementation.

No dependency may be added merely for convenience.
