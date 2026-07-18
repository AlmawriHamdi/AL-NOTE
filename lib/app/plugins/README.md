# Plugin System

Status: **Accepted with modifications**

## Central Rule

External version-1 plugins are bounded, validated, declarative packages.

They configure existing AL NOTE-owned behavior but cannot execute plugin-supplied code.

Trusted Dart extensions may use internal registries, but they are compiled, reviewed, tested, licensed, and shipped with AL NOTE. They are not runtime external plugins.

A future capability-mediated WebAssembly boundary may be studied separately. No executable plugin runtime or supporting dependency is accepted.

## Ownership

The Plugin System owns:

- Package identity and validation
- Manifest interpretation
- Publisher and signing-key identity records
- Installation, enablement, disablement, update, rollback, and removal coordination
- Plugin namespace enforcement
- Declarative contribution validation
- Atomic registry publication
- Compatibility and capability reporting
- Plugin lifecycle records
- Failure isolation and safe mode
- Privacy-safe structured audit events

It does not own:

- Document mutation or Commands
- Undo history
- Object rendering or hit testing
- Import or Export execution
- Settings persistence
- UI composition policy
- Platform files, secrets, or networking
- Security audit-event storage
- Sync or marketplace services

Existing subsystem ownership remains authoritative.

## Version-1 Contributions

Allowed declarations include:

- Tool presets using existing core Tools
- Interaction Mapping profiles and binding presets
- Typed Settings definitions using host-supported types
- Semantic Action descriptors referencing existing host Actions
- Menu, toolbar, and command-palette placement requests
- Import and Export presets using core handlers
- Non-authoritative object-type presentation metadata
- Document and Page templates using supported content
- Plugin-owned localized strings
- Bounded static icons and assets

Every declaration is validated and interpreted by AL NOTE-owned code.

Declarations cannot introduce arbitrary behavior.

## Prohibited Contributions

External version-1 plugins cannot provide:

- Runtime Dart code
- Native libraries
- Processes, scripts, or installation scripts
- WebAssembly modules
- Flutter widgets
- Raw HTML or JavaScript
- Object renderers
- Geometry or hit-testing implementations
- Executable Tools
- Import or Export handlers
- Search, indexing, or recognition providers
- Storage codecs
- Executable migrations
- Background tasks
- Native integrations
- Direct document or registry mutation
- Filesystem, clipboard, network, secret, camera, microphone, or platform access

Object presentation metadata may contain labels, descriptions, icons, and other non-authoritative information. It is not a renderer, validator, decoder, or editor.

## Trusted Compile-Time Extensions

Trusted Dart extensions:

- Are compiled into AL NOTE
- Are reviewed as application source
- May implement internal extension contracts
- Use stable registries where practical
- Follow normal testing, licensing, and release processes
- Cannot be installed or updated as runtime plugins
- Do not weaken domain boundaries

They are not sandboxed third-party runtime plugins.

## Future Executable Boundary

A future capability-mediated WebAssembly design is reserved but not accepted.

It would require separate decisions covering:

- Runtime selection
- Determinism
- Memory and CPU accounting
- Host-call mediation
- Capability grants
- Cancellation and termination
- Platform availability
- State migration
- Security and supply-chain review
- Conformance testing
- Failure containment

No WebAssembly runtime is selected.

Runtime Dart, native libraries, and process spawning remain prohibited.

## Package Format

External packages use the conventional extension:

`.alnote-plugin`

The format is a bounded deterministic, conceptually ZIP-based archive. The archive dependency remains deferred.

A package contains:

- One manifest at a fixed path
- Declared static resources
- Optional localization
- Optional declarative contribution records
- Optional licensing and notices

Packages contain no executable installation scripts.

Validation rejects or bounds:

- Duplicate logical paths
- Absolute paths
- Parent traversal
- Symlinks and special entries
- Case-folding collisions
- Unicode-normalization collisions
- Undeclared files
- Unsupported compression
- Excessive entries or expanded sizes
- Suspicious compression ratios
- Oversized manifests and assets
- Malformed records
- Hash mismatches

Installation stages and completely validates a package before publication.

## Artifact and Signed Identity

Two identities remain separate:

1. Raw-artifact digest of exact archive bytes
2. Canonical signed-content identity from the manifest and declared-path digest set

Signing input avoids signature self-reference and archive-metadata ambiguity.

Ordinary ZIP-byte reproduction is not the canonical signature scheme.

Canonicalization, signature envelope, and algorithms remain deferred.

## Manifest

The manifest provides:

- Schema version
- Stable plugin identifier and version
- Display metadata
- Publisher identity
- Supported host API range
- Contribution declarations
- Resource declarations
- Required host features
- Licensing
- Notices and provenance
- Optional signing metadata

Unknown required features cause incompatibility.

Safe unknown optional fields may be preserved.

Validation is deterministic and resource-bounded.

## Identity and Namespaces

Plugin IDs are:

- Stable
- Lowercase ASCII
- Reverse-domain-style
- Independent of display names
- Roots of plugin-owned namespaces

`alnote.*` is reserved.

Plugins remain inside their assigned namespace unless referencing explicitly extensible host identities.

Publisher-key bindings, curated ownership, and explicit conflict handling prevent silent namespace takeover.

Display-name matches never establish identity.

## Dependency Policy

Version-1 packages are self-contained.

Plugin-to-plugin dependencies, shared runtime libraries, dependency resolution, cycles, and cross-plugin activation are deferred.

Plugins may reference stable host APIs but cannot require another plugin.

## Installation, Trust, and Activation

These states remain separate:

- Installation: structural checks passed and package was stored
- Signature verification: signature matched its key and signed identity
- Trust: user, administrator, or distribution policy
- Permission: authorization for a capability
- Activation: validated declarations entered an active registry generation

A valid signature does not prove safety or trust.

Unsigned and untrusted-package policies must be explicit and cannot silently elevate trust.

## Capability Boundary

Declarative version-1 plugins receive no runtime capabilities.

They cannot read documents, Selection, Sessions, clipboard, secrets, files, networks, user identity, or other plugin data.

They cannot perform background work.

Future executable permissions must be deny-by-default, narrow, explicit, revocable, auditable, and bound to exact plugin, publisher-key, version, artifact, and capability identities.

Future resource tokens must be operation-scoped, resource-scoped, expiring, unforgeable, and nonpersistent.

This future model is not active in version 1.

## Atomic Registries

Contributions compile into immutable registry generations.

Activation:

1. Stages every contribution.
2. Resolves host references.
3. Validates identity, compatibility, limits, and conflicts.
4. Constructs a complete candidate generation.
5. Publishes it atomically.

Partial activation is prohibited.

Failure leaves the previous generation authoritative.

Precedence is deterministic, and plugins cannot replace protected core definitions.

## Generation Pinning

Long-running operations pin the exact plugin version, artifact identity, and registry generation that affected their start.

Examples include gestures, editors, Import or Export preparation, previews, rendering jobs, and Settings drafts.

Idle Sessions do not remain permanently pinned.

After atomic updates, idle Sessions observe the current generation and deterministically enter or recover from degraded states.

## Lifecycle and Rollback

Installation and updates are transactional:

- Stage new versions beside active versions.
- Validate before activation.
- Preserve the old version until success.
- Switch active versions atomically.
- Roll back after activation failure.
- Preserve structured failure information.
- Renew authorization for broadened future permissions.
- Treat publisher-key changes as identity-sensitive.
- Permit disabling without deleting state.
- Support safe-mode startup without external activation.

Automatic network updates are not accepted.

## Removal and Preservation

Disabling or uninstalling never deletes document content.

Plugin-related document records remain preserved through unknown-content mechanisms.

Plugin Settings remain inactive and preserved unless explicitly removed.

Derived caches may be deleted.

The system distinguishes package removal, Settings removal, cache removal, and other application-data removal.

Destructive removal is explicit and scoped.

## Persistent Records and Migration

Plugin-owned records use:

- Stable namespaced identities
- Explicit schema versions
- Bounded host-supported forms
- Preservation-capable Storage contracts

Missing plugins leave records inert and preserved.

Version 1 permits only host-supported structural migrations described and validated without executing plugin code.

Future executable migrations would require isolation, bounded input, proposed replacements, core validation, and normal Storage or Command publication.

## Settings and UI

Plugin Settings use host-supported types, validation, layering, transactions, previews, namespaces, and inactive-record preservation.

Plugins cannot provide validators, widgets, persistence backends, or secret storage.

UI contributions are declarative and host-rendered.

Plugins cannot inject widgets, layouts, scripts, raw HTML, or trusted security text.

The UI retains control over layout, accessibility, focus, localization, adaptation, and visibility.

## Domain Boundaries

Plugins cannot mutate documents directly.

UI entries reference registered host Actions.

Persistent changes use Commands.

Bindings use Interaction Mapping.

Presets use core Tools.

Import and Export presets use core handlers and validated plans.

## Failure and Limits

Lifecycle operations return structured results for invalid packages, incompatibility, identity conflict, signature failure, trust denial, contribution conflict, limits, activation failure, cancellation, rollback, and degradation.

Package parsing and activation enforce centralized limits and failure isolation.

## Cross-Platform Behavior

Compatibility is capability-based.

The host reports supported manifests, contributions, APIs, capabilities, and limits.

Required unsupported contributions fail. Optional ones may remain inactive.

Packages remain preservable across platforms.

Identical future executable support is not promised on every platform.

## Licensing and Supply Chain

Manifests declare SPDX-oriented licensing where practical.

Packages include applicable licenses, notices, dependency inventory, and asset or binary provenance.

Curated distribution requires documented GPL-v3-or-later compatibility review.

SPDX identifiers alone do not determine legal compatibility.

Sideloading does not imply AL NOTE endorsement.

No incompatible package is knowingly redistributed through a curated channel.

## Offline Operation

Local installation, validation, digest checks, cached signature verification, activation, disabling, and rollback work offline when inputs are present.

Network access is not an activation prerequisite.

Marketplace discovery, revocation refresh, transparency services, and automatic updates remain deferred.

## Audit Events

The Plugin System emits privacy-safe structured events for installation, signature outcomes, trust, activation, updates, rollback, key changes, disablement, uninstallation, and safe mode.

Events avoid document content, secrets, and unnecessary personal data.

Security owns event storage, retention, access, and export policy.

## Testing

Required tests cover archive attacks, bombs, manifests, identities, signatures, namespaces, versions, atomic activation, rollback, safe mode, permissions, key changes, preservation, platform differences, deterministic registries, limits, and parser fuzzing.

## Repository Ownership

Plugin System architecture belongs under:

`lib/app/plugins/`

This documentation commit creates no implementation subdivisions.

No plugin, archive, signature, cryptography, WebAssembly, marketplace, or sandboxing dependency is accepted.

## Deferred Matters

- Executable external plugins
- WebAssembly runtime and host API
- Runtime Dart and native loading
- Plugin dependencies and resolution
- Marketplace, discovery, and updates
- Certificate authorities and transparency
- Signing algorithms and envelope
- Archive and cryptography dependencies
- Canonicalization encoding
- SBOM format
- Automated license decisions
- Executable migrations
- Plugin renderers, Tools, and handlers
- Search, indexing, and recognition providers
- Sync-distributed plugins
- Numerical limits
- Audit storage and retention
- Plugin-management UI
- Formal sandbox-security claims
