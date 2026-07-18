# Testing, Packaging, CI, and Release Architecture

Status: Accepted with modifications

## Central Rule

AL NOTE uses a layered release-proof model:

1. Source verification
2. Cross-platform integration and conformance testing
3. Release-mode package construction
4. Installed-package and artifact verification
5. Independent post-publication verification

Unit tests are necessary but are not release proof. A successful upload command is not proof that a release was correctly published.

## Ownership

This subsystem owns project-wide test policy and terminology, quality gates, supported-platform matrices, CI orchestration, controlled-build policy, packaging and release-candidate qualification, artifact identity, release manifests, SBOM generation, license inventories, checksums, provenance, signing coordination, release channels, publication records, rollback and withdrawal procedures, and exception and waiver records.

Existing subsystems retain their invariants, domain tests, Security policy, format rules, capability contracts, plugin validation, scheduling behavior, UI behavior, and release-approval responsibilities. This architecture verifies those responsibilities without redefining them.

## Future Repository Placement

These locations are future directions and are not created by this architecture record:

- `test/` — unit, component, contract, property, model, serialization, migration, compatibility, widget, golden, accessibility, and fixture tests
- `integration_test/` — workflows, platforms, Recovery, and packaged-application tests
- `conformance/` — adapter, file-format, plugin, and release-artifact suites
- `test_resources/` — bounded synthetic corpora, fonts, fuzzing, and adversarial fixtures
- `benchmark/` — document, rendering, input, Search, storage, and startup measurements
- `.github/workflows/` — later CI implementation
- `packaging/` — later platform packaging definitions
- `tool/` — later CI, release, license, SBOM, and provenance utilities

Generated SBOMs, attestations, signatures, and release reports belong with release artifacts unless they are reviewed configuration or baselines.

## Test Taxonomy

The distinct categories are Unit, Component, Contract, Property-based, Model-based, Serialization, Migration, Compatibility, Golden, Widget, Integration, End-to-end, Adapter conformance, Packaged-application smoke, Performance, Stress and load, Fault injection, Fuzzing and adversarial security, Accessibility and localization, Recovery and crash, and Resource-leak testing.

Each category has explicit ownership and blocking status.

## Tiered Gates

### Pull Request

Formatting, static analysis, unit tests, component tests, contract tests, core serialization tests, widget tests, fast accessibility tests, and dependency-change review.

### Main Branch

Pull-request checks plus integration tests, available adapter conformance, migration fixtures, controlled golden verification, Linux and Windows release-mode integration where available, Chrome and Firefox Web coverage, and Android emulator smoke tests.

### Nightly

Broader platform coverage, fuzzing, fault injection, stress and leak tests, browser-matrix and Recovery tests, performance trends, and package construction.

### Release Candidate

The full declared supported matrix, release-mode builds, packaged smoke tests, Security and license review, SBOM, provenance, Recovery qualification, and installation and upgrade tests.

### Release

Exact-candidate verification, protected signing, final artifact hashing, clean installation, explicit approval, and publication.

### Post-Publication

Independent download, hash and signature verification, provenance verification, installation and launch, and release-manifest comparison.

Flaky or inconclusive tests cannot silently become success.

## Determinism and Isolation

Tests receive controlled clocks, timezones, UUID and random sources, schedulers, timers, filesystems, storage, capability snapshots, lifecycle events, permission decisions, locale, RTL state, pixel ratio, text scale, clipboard, and external activation.

Tests cannot accidentally depend on developer home directories, normal browser profiles, real clipboards, real secret stores, installed fonts, public networks, or uncontrolled desktop services. Network access is denied by default. Each test uses isolated temporary or browser-storage namespaces.

Randomized tests record generator version, seed, minimized failing input, revision, platform, and toolchain. Tests verify cleanup of temporary files, workers, handles, ports, processes, and browser databases.

## Domain and Command Testing

Model and property testing covers immutable state replacement, rejected-command non-mutation, Apply, Undo, Redo, transaction boundaries, stale-command rejection, layer and object ordering, document-unique identities, duplication remapping, unknown-field and unknown-object preservation, dirty-state calculation, shared logical Sessions, multiple views, separate Session isolation, save conflicts, Import publication, and immutable Export inputs.

## File Format and Compatibility

Qualification requires canonical byte fixtures, deterministic repeated serialization, encode/decode round trips, unknown-field and unknown-object preservation, every supported migration, new-reader/old-document tests, declared old-reader/new-document behavior, corruption and truncation tests, manifest and hash validation, archive-traversal protection, decompression limits, cross-platform fixture equivalence, and human-reviewed golden changes.

Application, document-format, object-schema, plugin-package, and platform capability-contract versions remain independent. A machine-readable compatibility declaration records supported ranges and their proving fixtures.

## Recovery and Fault Injection

Tests inject interruption before, during, and after declared boundaries for Commands, Recovery publication, Save, Save As, Import, Export, staging, and cleanup.

Fault cases include storage full, quota exceeded, permission revocation, external source changes, short reads and writes, delays, forced termination, browser refresh, Android process death, corrupt checkpoints, stale leases, and partial publication. Tests cannot claim guarantees stronger than the relevant platform contract.

## Platform and Web Matrices

Coverage is tiered across pull-request, main, nightly, release-candidate, and post-release stages. Qualification covers minimum declared and current stable environments, debug and release modes, packaged and unpackaged execution, sandboxed and ordinary packaging where shipped, x64, and ARM64 only where distributed.

Emulators provide breadth. Representative real devices qualify stylus behavior, lifecycle, performance, and releases. Flutter platform support alone does not prove AL NOTE support. An explicit supported-platform table is published.

Chromium is the primary frequent Web target. Firefox participates in main, nightly, and release qualification. Safari and WebKit remain unverified until maintained qualification infrastructure exists, and no Safari support claim is made without qualification.

Web testing covers secure contexts, HTTPS, IndexedDB, file acquisition, download publication, clipboard permissions, Web Workers, CSP, quotas, refresh, hidden-tab throttling, service-worker cache transitions, and Wasm separately if introduced. Exact browser versions remain deferred.

## Rendering and Golden Policy

Tests control and record fonts, Flutter engine, renderer, PDF backend, image codecs, pixel scale, theme, locale, and color assumptions.

Exact pixel goldens are limited to controlled environments. Cross-platform verification prefers semantic scene comparison, geometry and bounds assertions, object and layer validation, perceptual comparison with reviewed tolerances, export-structure inspection, and targeted raster samples. False cross-platform pixel identity is not required.

## Performance Qualification

Performance records device class, operating system, toolchain, build mode, warm-up, repetitions, sample distributions, and raw measurements.

Measurements cover frame performance, stylus event-to-presentation latency, large documents, Search and indexing, PDF rendering, Save and Recovery, workers and queues, startup, memory, and package size. Statistical thresholds and historical trends are used. Noisy results are inconclusive pending controlled rerun. No hard real-time guarantee is made.

## Accessibility and Localization

Blocking checks cover semantics, keyboard navigation, focus order, shortcut conflicts, labels, text scaling, missing translations, RTL, and severe contrast failures.

Release qualification additionally covers screen readers, high contrast, reduced motion, long translations, runtime locale changes, and platform accessibility settings. WCAG 2.2 AA remains the Web design and testing target without an unaudited formal-conformance claim.

## Security and Adversarial Testing

`.alnote` files, PDFs, images, archives, clipboard and dropped data, plugin packages, Settings, Recovery artifacts, restoration and activation data, deep links, paths, symlinks, platform tokens, and Search indexes are hostile inputs.

Testing covers traversal, symlink substitution, decompression bombs, malformed Unicode, resource exhaustion, corrupt indexes, stale authorization, permission revocation, redaction, log leakage, CSP failure, and native-library failure and vulnerabilities.

Fuzzing uses bounded synthetic corpora and records seeds, tools, revisions, platforms, limits, and minimized failures. Fixed failures become permanent regression tests. Private crash inputs are never uploaded automatically.

## GitHub Actions

GitHub Actions is accepted as the initial hosted CI orchestrator and is a project service, not an application runtime dependency.

Controls require a read-only default `GITHUB_TOKEN`, minimal job-specific permission increases, forked pull requests without secrets, no privileged execution of untrusted code, no unsafe checkout through `pull_request_target` or privileged `workflow_run`, protected release environments, human approval before signing and publication, controlled reusable workflows, concurrency cancellation for superseded pull requests, no cancellation after irreversible signing or publication begins, complete shard-result aggregation, bounded artifact retention, redacted logs, branch protection, and CODEOWNERS or equivalent review over workflow changes.

Every externally sourced Action or reusable workflow is reviewed, pinned to a full immutable commit SHA, verified as originating from the intended repository, and updated only through reviewed changes.

## Signing and Workflow Trust

Signing credentials never enter source control, caches, pull-request workflows, ordinary build artifacts, or unprotected logs. Untrusted code cannot execute in the signing environment.

Signing occurs in a separate protected stage after qualification. Build provenance identifies the qualified unsigned artifact; signing records input and output identities; final release manifests hash final signed artifacts; and signed packages receive installation and smoke testing. Source is not rebuilt merely to sign.

## Toolchain and Supply Chain

Flutter, Dart, Java, Android Gradle tooling, Android SDK and build tools, target SDK, NDK where used, Windows SDK and compiler toolset, Linux compiler and linker, CMake, Ninja, packaging tools, browsers and drivers, JavaScript or Wasm tools if introduced, and runner or container identities are pinned or recorded as closely as practical.

The authoritative Flutter pin remains understandable without requiring a version-manager dependency. Release builds use reviewed locks and fail if dependency resolution changes them. Caches are disposable accelerators. Reproducibility is measured and documented; bit-for-bit reproducibility is not claimed until proven.

Every package, plugin, binary, tool, Action, compiler, and bundled resource records its exact version, checksum, canonical source, owner, license, GPL compatibility, transitive dependencies, binary provenance, supported platforms, maintenance status, vulnerability review, required notices, source obligations, and controlled update procedure.

Automated tools inform human review but do not make architectural acceptance decisions.

Dependabot is accepted as the initial proposal generator for supported ecosystems. Updates require ordinary review and qualification, and automatic merging is not accepted. Renovate remains an alternative study. OSV Scanner remains a candidate pending exact-source, ecosystem, and workflow audit.

CodeQL does not support Dart and is not accepted as AL NOTE's Dart analyzer. It may be evaluated for GitHub Actions workflows and officially supported languages introduced later. It never substitutes for Dart analysis, fuzzing, dependency review, or Security testing.

## SBOM and Provenance

Releases require an SPDX-compatible primary SBOM representation. Exact SPDX version, serialization, and generator remain deferred until implementation audit. CycloneDX may be produced as an optional interoperable representation.

SLSA-compatible provenance evidence is required without claiming certification or an achieved level before verification. GitHub artifact attestations may record and verify build provenance where supported. Attestations prove recorded origin and process evidence, not correctness, security, licensing, reproducibility, quality, architectural acceptance, or certification.

## Packaging Targets

### Linux

Flatpak is the qualified initial target, with a versioned portable archive secondary. Qualification covers sandboxing, portals, Open and Save, drag-and-drop, clipboard, external activation, desktop integration, MIME registration, native libraries, permissions, offline operation, installation, upgrade, downgrade, uninstallation, and GPL correspondence.

Flatpak is not supported until packaged conformance passes. AppImage remains under study; Debian-family packages are deferred. Exact runtime, base application, manifest, repository, signing, and hosting remain deferred.

### Windows

Qualified initial targets are signed MSIX and a versioned portable ZIP. Qualification covers installation, uninstallation, upgrade, downgrade, file associations, activation, package identity, runtime dependencies, native DLL provenance, signing failures, user-data retention, and portable behavior.

MSIX is not supported until packaged conformance passes. Exact tooling, certificate, publisher identity, and distribution channel remain deferred.

### Android

Qualification produces a signed APK and an Android App Bundle only when a selected distribution or testing channel requires it. It records minimum and target SDK policy, manifest review, Storage Access Framework conformance, ABI declarations, native-library provenance, process-death and restoration tests, backup and data-extraction policy, separate development and release keys, monotonic build numbers, and install, upgrade, and downgrade tests.

No application store is selected. Exact SDK levels, signing provider, and channel remain deferred.

### Web

Web produces a hosting-independent, versioned static release bundle with HTTPS, restrictive CSP, correct MIME types, coherent compression, explicit origin assumptions, required Worker and Wasm assets, release manifests, final hashes, license and notice material, a source-map policy, version-coherent service-worker caches, and whole-release rollback.

A new page shell cannot load incompatible assets from an older release. Exact hosting remains deferred.

Package formats do not become supported until packaged conformance passes.

## GPL-3.0-or-later Engineering Controls

Every object-code release links to corresponding source containing or identifying the exact source revision, build and packaging scripts, interface definitions, generated-source instructions, license and copyright text, third-party notices, modified covered dependency source where required, native-binary source correspondence, installation information where applicable, and toolchain and build-input records.

Release manifests connect each binary artifact to corresponding source and SBOM evidence. Direct source publication is preferred over reliance on a written offer. This is an engineering compliance framework, not legal advice.

## Versions and Channels

Application version, platform build numbers, document-format version, object-schema version, plugin-package version, and platform-contract version remain independent.

Application releases use `MAJOR.MINOR.PATCH`, optional pre-release identifiers, and monotonic platform build numbers where required. Strict Semantic Versioning applies to documented public compatibility contracts. Application versioning may follow SemVer operationally without treating every visible change as a library API change.

Channels are Stable, Beta, Development, and Nightly. Nightly builds are unsupported snapshots. Artifact names include product, version, commit, platform, architecture, package type, and non-stable channel.

## Release Manifest and Publication

The release manifest records source revision, version, supported compatibility ranges, artifact names, final signed hashes, corresponding-source identity, SBOM identity, provenance identity, signing-key identifiers, publication locations, and withdrawal state.

The release sequence is:

1. Select and freeze the source revision.
2. Build in controlled environments.
3. Run qualification.
4. Verify dependencies, vulnerabilities, licenses, and notices.
5. Generate the SBOM, corresponding source, and build provenance.
6. Inspect and identify unsigned artifacts.
7. Sign without rebuilding source.
8. Hash and record final signed artifacts.
9. Install and smoke-test signed packages.
10. Record maintainer approval.
11. Publish.
12. Independently fetch every remote artifact.
13. Verify remote hashes, signatures, provenance, installation, and launch.

Only artifacts identified by the authoritative release manifest are official. Publication is incomplete until independent remote verification succeeds.

## Version-1 Updates

Version 1 provides current-version display, release notes, Security advisories, a user-initiated link to the official release page, and manual download and installation.

Version 1 does not provide background update polling, automatic download, automatic installation, or a custom update protocol.

## Rollback, Withdrawal, and Failures

Rollback uses previously qualified artifacts where the platform permits it. Users are warned before downgrade when documents or Settings may exceed the older version's supported range.

Withdrawal marks the release withdrawn, removes recommended-download links, preserves an audit record, publishes an advisory, and revokes signing material only when compromise or equivalent risk requires it. No global atomic rollback or withdrawal is claimed across hosts, stores, mirrors, caches, or downloaded files.

Structured outcomes include test failure, inconclusive or flaky test, unsupported target, toolchain failure, dependency-resolution failure, vulnerability-policy failure, license-policy failure, reproducibility failure, packaging failure, signing failure, missing SBOM, missing provenance, installation failure, publication failure, partial publication, remote-verification failure, withdrawal, and revocation.

## Quality Gates and Waivers

Blocking release gates include build and analysis, required tests, format and migration compatibility, no unresolved release-blocking Security finding, license acceptance, required SBOM and provenance, packaged smoke tests, and remote verification. Coverage percentage alone is not a release-quality decision.

Flaky-test quarantine requires a tracked defect, owner, risk assessment, expiration, and equivalent evidence.

Waivers are narrow, time-bounded, revision-specific, explicitly approved, preserved with release evidence, and revalidated before expiration. Security and licensing waivers require the relevant owner's review.

## Open-Source Record

Accepted foundations and services:

- Flutter and Dart testing foundations
- Flutter `integration_test`
- GitHub Actions as the initial hosted CI orchestrator
- GitHub Dependabot as a reviewed update-proposal service
- SPDX-compatible SBOM representation
- SLSA-compatible provenance model
- GitHub artifact attestations where supported
- Flatpak as a qualified initial Linux packaging target
- MSIX as a qualified initial Windows packaging target
- Android SDK and Gradle release tooling with exact pins
- Hosting-independent Flutter Web release bundles

Under study or deferred:

- CodeQL for supported non-Dart languages and workflow scanning
- OSV Scanner
- Renovate
- Exact SPDX generator and version
- CycloneDX generator
- Property-testing packages
- Fuzzing tools
- Golden helper packages
- Browser automation packages and browser-binary acquisition
- AppImage
- Debian packaging
- Exact MSIX tooling
- Exact signing providers
- Exact Web hosting provider

CodeQL does not support Dart. No automatic dependency merging is accepted. No external Dart testing dependency is accepted. Package formats do not become supported until packaged conformance passes. Attestations and automated scans provide evidence rather than architectural acceptance or certification.

## Deferred Matters

- Automatic update service
- Distribution-store selection
- Exact supported OS and browser versions
- Safari and WebKit qualification infrastructure
- Linux ARM64 artifacts
- AppImage adoption
- Debian-family packaging
- Windows installer formats beyond MSIX
- Exact MSIX tooling and certificate
- Exact Android SDK levels and distribution channel
- Exact Web host
- Exact property-testing and fuzzing tools
- Exact SBOM generator
- Exact provenance and signing tools
- Formal accessibility certification
- Proven reproducibility target
- Wasm toolchain and matrix
- Recognition and Math Recognition
- Symbolic Math
- Sync and Cloud
