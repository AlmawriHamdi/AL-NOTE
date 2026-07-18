# Platform Integration and Capability Adapters

## Status

Accepted with modifications.

## Purpose

Platform Integration defines the portable capability contracts through which AL NOTE interacts with Linux, Windows, Android, Web, Flutter plugins, browser APIs, operating-system APIs, FFI, and native libraries.

AL NOTE uses capability-driven ports and adapters. Portable application and domain code depends only on versioned, AL NOTE-owned capability contracts. Concrete platform adapters implement those contracts at the outer platform boundary.

Platform adapters report facts and execute narrowly authorized operations. They do not own domain policy, document mutation, Commands, Save, Import, Export, Recovery, Sessions, Security decisions, UI decisions, or Job scheduling policy.

## Ownership and Repository Boundary

`lib/platform/` is the Platform Integration subsystem root.

The intended future implementation structure is:

- Portable contracts under `lib/platform/contracts/`
- Concrete implementations under `lib/platform/adapters/<platform>/`
- Composition under an application bootstrap or composition root
- Test fakes and conformance suites behind platform-testing boundaries

These implementation directories are not created by this architecture record.

`lib/core/platform/` is rejected because concrete platform integration is an outer layer rather than a foundational domain utility.

Platform Integration owns:

- Capability identities and contract versions
- Capability discovery and immutable snapshots
- Adapter identity and implementation evidence
- Adapter initialization, lifecycle, and disposal contracts
- Platform-fact normalization
- Opaque resource and authorization tokens
- Capability-specific typed requests and results
- Structured failure and degradation reporting
- Contract conformance requirements
- Cross-platform capability matrices

It does not own:

- Document or Object policy
- Persistent document mutation
- Commands, Undo, or Redo
- Open, Save, Import, or Export policy
- Recovery or restoration policy
- Session lifecycle policy
- Security or trust policy
- UI semantics or presentation
- Interaction meaning
- Job admission, priority, or scheduling
- Release pipelines or store publication

## Dependency Direction

Dependencies point inward through these layers:

1. Domain and document model
2. Application use cases and subsystem policy
3. AL NOTE-owned platform capability contracts
4. Concrete platform adapters
5. Flutter plugins, browser APIs, operating-system APIs, FFI, and native libraries

Only the application composition root constructs concrete adapters and registers them against portable contracts.

Domain, document, Command, persistent-format, and portable capability-contract code cannot directly import platform implementations, Flutter plugins, FFI bindings, browser bindings, or operating-system-specific types.

Authorized native adapters may use `dart:io`, FFI, operating-system APIs, or platform plugins. Web adapters may use accepted browser bindings. Those dependencies remain outside portable layers.

## Capability Model

Capabilities use stable identities under the `alnote.platform.*` namespace.

Each capability definition records:

- Major and minor contract versions
- Immutable capability snapshots
- Adapter identity
- Adapter implementation version
- Availability
- Limits and constraints
- Degradation
- Health
- Runtime changes
- Permission state
- Temporary unavailability
- Initialization evidence

A capability snapshot is evidence. It is not authorization and does not reserve a resource.

Availability categories include:

- Supported
- Supported with degradation
- Temporarily unavailable
- Permission required
- Permission denied
- Permission revoked
- Initialization failed
- Unsupported

Capability availability may vary by runtime, browser, packaging model, permissions, desktop environment, installed services, hardware, lifecycle, and user activation. Operating-system-name branching is not an adequate capability model.

Sensitive operations revalidate capability availability, token validity, authorization, and relevant Security policy immediately before execution.

## Version-1 Baseline

Each supported version-1 target provides an available or explicitly degraded route for:

- User-mediated document acquisition
- User-mediated document publication
- Application-private storage
- Temporary-resource staging
- Plain-text clipboard
- Lifecycle observation
- Pointer, keyboard, focus, and accessibility integration
- Required image decoding
- Secure randomness
- User-initiated external HTTPS handoff
- Foreground Job execution
- Structured failure and cancellation reporting

Optional or enhanced capabilities include:

- Persistent resource handles
- Random-access I/O
- Atomic replacement
- Durability evidence
- File observation
- Native share sheets
- Rich clipboard
- External drag-out
- Secret stores
- Native PDF backends
- Web Workers
- Multiple operating-system windows
- Native menus
- Hardware-backed keys

A supported platform is not required to implement every optional capability. Capability matrices describe tested expectations and degradation, not unconditional runtime guarantees.

## Adapter Operation Contracts

Every adapter operation defines:

- An immutable typed request
- A capability-specific typed result
- A common outcome classification where useful
- Cancellation semantics
- A deadline or expiration where applicable
- Security-policy evidence
- Narrow authorization
- Resource ownership
- Disposal and cleanup requirements
- Progress semantics where meaningful
- Partial or degraded success
- Thread, isolate, worker, or event-loop restrictions
- Redacted diagnostics

There is no universal untyped platform request or result. Shared classifications cannot erase capability-specific evidence.

Cancellation distinguishes:

- Cancelled before execution
- Cancellation observed and work stopped
- Cancellation requested while underlying work may continue
- Completion before cancellation took effect

An adapter must not report cancellation as complete when underlying work may still continue.

## Adapter Lifecycle and Composition

At startup, the composition root:

1. Determines the supported runtime family.
2. Constructs candidate adapters.
3. Initializes adapters independently.
4. Records typed initialization failures.
5. Publishes the initial capability snapshot.
6. Starts authorized platform-event subscriptions.

Failure of an optional adapter does not automatically prevent application startup.

The runtime family normally remains fixed, but individual capabilities may become available, degraded, revoked, unhealthy, or unavailable while the application runs.

Adapters expose explicit disposal and cleanup behavior. Disposal failures are structured and redacted.

## Opaque Resources and Destinations

Portable code uses opaque scoped tokens, including:

- Resource tokens
- Destination tokens
- Authorization tokens
- Secret references

Portable code cannot assume that a resource has a stable filesystem path.

Tokens are:

- Opaque
- Non-forgeable
- Scoped
- Bounded
- Expiring where appropriate
- Revocable
- Validated before use

Tokens and raw platform handles cannot be serialized into ordinary document data.

Resource descriptors may report:

- Display-safe metadata
- Media type
- Estimated size
- Read and write support
- Sequential or random access
- Persistence and expiration
- Fingerprint strength
- Observation capability
- Replace and rename support
- Flush and durability evidence
- Lock or lease support
- Permission state
- Symbolic-link information where knowable

These properties are independent evidence rather than implications of a path-like resource.

## Native Filesystem Semantics

Linux and Windows adapters may internally use paths, but portable code does not depend on paths.

Native adapters account for:

- Symbolic-link substitution
- Path traversal
- Race conditions
- External replacement
- Case and normalization differences
- Network and removable filesystems
- Incomplete writes
- Locking limitations
- Atomicity limitations
- Durability limitations

Atomic replacement, rename, flush, durability, locking, identity, and observation are independent capabilities.

A successful write or close does not automatically prove durable storage.

## Android Resources

Android user-selected resources use capability adapters compatible with the Storage Access Framework and document providers.

Content URIs are not converted into assumed filesystem paths.

Persisted permissions are requested only when required. A previously persisted permission may later become invalid or revoked and must be revalidated before use.

## Web Resources

Web acquisition supports:

- Authorized handle-based access when available
- Upload-style acquisition into bounded staging as fallback

Web publication supports:

- Authorized writable handles when available
- Browser download-style publication as fallback

A browser download attempt does not prove durable publication to a user-selected destination.

Web adapters report:

- User-activation requirements
- Secure-context restrictions
- Origin restrictions
- Browser-policy rejection
- Quota conditions
- Eviction risk
- Authorization loss
- Missing atomic replacement, locking, or durability evidence

Persistent browser handles remain opaque and require authorization revalidation.

## Fingerprints and External Changes

Resource fingerprints are structured evidence rather than universal identities.

Fingerprint evidence may include:

- Size
- Modification evidence
- Platform identifier
- Selected content hash
- Full content hash

Fingerprint strength is explicit.

File observation is optional and advisory. Save and Session systems decide how external changes affect application behavior.

## Temporary and Staged Resources

Every staged resource records:

- Owning scope
- Purpose
- Size limit
- Expiration
- Cleanup responsibility
- Recovery classification

Cleanup occurs after success, failure, timeout, or cancellation.

Adapters cannot remove Recovery-owned resources merely because the adapter considers them old.

## Pickers

Separate portable contracts exist for:

- Opening one resource
- Opening multiple resources
- Creating a destination
- Selecting a folder

Picker results return resource or destination tokens rather than assumed paths.

User cancellation is a normal structured result.

Pickers acquire authorization only. Open and Save retain AL NOTE-document policy. Import and Export retain conversion and publication policy.

## Sharing and External Publication

Sharing accepts already prepared resources and narrow authorization.

It reports:

- Presentation
- Handoff
- Cancellation
- Partial handoff
- Unsupported operation
- Failure

Share-sheet handoff does not prove that another application received, stored, or processed the resource.

Destination tokens may expire or require reauthorization.

## Clipboard and Drag-and-Drop

Clipboard contracts support typed representations such as:

- Plain text
- Accepted rich text
- Raster images
- Resource references
- AL NOTE-owned clipboard representations

Clipboard and dropped content are untrusted input.

Limits apply to:

- Bytes
- Image dimensions
- Object counts
- Nesting
- Decompression
- Parsing
- Staging

Large content uses bounded staged resources.

Drag-in returns acquisition offers. Application policy decides whether to open, import, insert, or reject them.

Drag-out is optional and may use immediate bytes, staged resources, promised files, or same-application references.

Clipboard and drag-and-drop adapters cannot create Commands or mutate documents directly.

## Private Storage

The AL NOTE-owned private-storage contract supports:

- Namespaced logical repositories
- Transactions where genuinely available
- Revision conflict detection
- Checksummed records
- Last-known-good preservation
- Corruption reporting
- Storage-pressure reporting
- Schema-independent bounded byte records
- Bounded enumeration and cleanup

Settings owns schemas, validation, layering, migration, preview, Apply, Reset, and conflict policy.

Recovery owns Recovery policy and retention. Sessions own restoration policy.

Logical repositories for Settings, Recovery, restoration, and capability metadata remain independently identifiable even when sharing a physical backend.

No Web or native backend is accepted yet. IndexedDB remains the leading Web candidate. Native application-private directories remain a platform capability. `shared_preferences` remains rejected as the canonical Settings repository.

## Secret and Cryptographic Services

Capability boundaries cover:

- Opaque secret references
- Secure randomness
- Platform secret stores
- Platform cryptographic operations

Potential platform foundations include:

- Android Keystore
- Windows current-user DPAPI
- Linux Secret Service
- Web Crypto

No common security guarantee is inferred across these foundations.

There is no plaintext secret fallback when a protected secret store is unavailable.

Results disclose:

- Locked or unavailable stores
- Authentication requirements
- Invalidation
- Non-migratability
- Backup behavior
- Verified versus merely requested hardware protection

This subsystem does not select an encryption suite or claim encrypted `.alnote` support.

## Lifecycle

Adapters normalize advisory lifecycle facts including:

- Foreground
- Background
- Hidden
- Suspension or suspension warning where supplied
- Resume
- Memory pressure
- Low storage
- Exit request
- Window closing
- External activation
- Restoration opportunity
- Safe mode

Lifecycle events may be absent or late. No subsystem relies on a final callback.

Browser refresh, tab closure, Android process death, forced termination, and operating-system shutdown may prevent final work. Recovery therefore relies on incremental bounded checkpoints.

Exit coordination is bounded and reports whether exit can be delayed or vetoed. Session and Recovery systems retain policy ownership.

## Windows, Views, and Menus

Single-primary-window operation is the version-1 baseline.

Multiple operating-system windows remain optional and capability-dependent. This does not prohibit a later or platform-specific multiple-window implementation.

Multiple views of one Session and split views are UI and application concepts and are not equivalent to operating-system windows.

Window adapters may report:

- Runtime window identity
- Lifecycle events
- Display facts
- Bounds
- Restoration hints
- Close requests
- Native-menu availability
- External file-open activation
- Deep-link activation

No window-management dependency is accepted.

## Input and Accessibility

Flutter is the primary version-1 source for:

- Pointer events
- Touch
- Stylus facts
- Mouse
- Keyboard
- IME
- Focus
- Semantics

Platform adapters may provide narrowly scoped extensions unavailable through portable Flutter APIs.

Adapters normalize facts such as pressure range, tilt support, buttons, reserved shortcuts, reduced motion, high contrast, text scale, accessibility-navigation state, locale, RTL direction, display scale, and pixel ratio.

Interaction Mapping decides input meaning. UI owns semantics, labels, focus order, presentation, and accessible behavior.

## PDF, Image, Font, and Rendering Backends

PDF, image, font, and rendering integrations use backend-neutral AL NOTE-owned capability contracts.

Backend results include:

- Backend identity and version
- Supported operations
- Thread restrictions
- Resource limits
- Cancellation behavior
- Failure and degradation
- Security-relevant evidence

PDF rendering and PDF construction remain separate.

Rendering cache identities include backend identity and version where output compatibility requires it.

Image decoders and encoders enforce byte, pixel, frame, animation, metadata, decompression, memory, and cancellation limits.

Font adapters report availability, loading, substitution, source classification, and embedding restrictions where known.

Platform adapters report rendering and device facts but do not decide document quality or export policy.

No PDF, image, font, or rendering dependency is accepted.

## Jobs, Isolates, and Web Workers

Platform execution adapters expose mechanisms such as:

- Native isolates
- Long-lived workers where accepted by benchmarks
- Web Workers
- Cooperative chunking
- Transferable data
- Native-library concurrency restrictions

The Job System retains ownership of:

- Admission
- Scheduling class
- Priority
- Fairness
- Scope
- Cancellation coordination
- Backpressure
- Freshness
- Publication coordination

Web Worker startup may fail because of CSP, deployment, browser, URL, or worker limitations. Fallback and cancellation limitations are explicit.

## External Links and Networking

Version 1 permits only minimal, user-initiated external HTTPS handoff behind an AL NOTE-owned capability contract.

The adapter validates allowed schemes and reports platform handoff only.

The following remain deferred:

- General networking
- Remote document acquisition
- Accounts
- Authentication callbacks
- Sync
- Cloud
- Automatic update checks

## Packaging Boundary

Platform architecture records requirements for:

- Android permission declarations
- Windows packaging capabilities
- Linux desktop integration
- Web CSP and origin policy
- Storage permissions
- Native-library bundling
- Sandbox entitlements
- Application identities
- File and protocol associations
- Platform privacy disclosures

Exact build pipelines, signing, store publication, artifact release, and release automation belong to Testing, Packaging, CI, and Release Architecture.

## Failures and Degradation

Platform outcomes use common classifications plus capability-specific typed evidence.

Common classifications include:

- Success
- Partial success
- Degraded success
- Unsupported
- Temporarily unavailable
- Permission required
- Permission denied
- Permission revoked
- User cancelled
- Invalid token
- Expired token
- Resource changed
- Destination conflict
- Storage full
- Quota exceeded
- Platform failure
- Initialization failure
- Backend terminated
- Policy rejected
- Deadline exceeded
- Cancelled
- Cancellation pending

Results include retry classification, cleanup state, safe details, and redacted diagnostics.

Raw platform exception strings do not cross into portable layers.

## Testing and Conformance

Every capability contract requires shared conformance testing covering:

- Success
- Unsupported behavior
- Initialization failure
- Permission denial and revocation
- User cancellation
- Deadlines
- Cancellation races
- Partial and degraded success
- Cleanup
- Invalid and expired tokens
- Resource replacement
- Storage and quota pressure
- Lifecycle interruption
- Disposal
- Resource leaks
- Redaction
- Capability snapshot changes

Testing layers include:

1. Pure contract tests with deterministic fakes
2. Fault-injection tests
3. Platform integration tests
4. Native-backend crash tests where practical
5. Browser-matrix tests
6. Packaged-application smoke tests

Fake adapters support controlled time, scheduled events, permission transitions, storage limits, short I/O, delayed completion, corruption, external modification, and operations that ignore cancellation.

Cross-platform capability matrices express tested expectations and documented degradation. They do not create unconditional runtime guarantees.

## Open-Source Record

Accepted foundations:

- Dart and Flutter SDK mechanisms
- Native operating-system APIs behind AL NOTE-owned adapters
- Standards-based browser APIs behind AL NOTE-owned adapters

Candidates remaining under study:

- `file_selector`
- `path_provider`
- `share_plus`
- `url_launcher`
- `super_clipboard`
- `super_drag_and_drop`
- `flutter_secure_storage`
- SQLite bindings
- IndexedDB adapters
- `pdfrx` and PDFium
- PDF.js
- Dart `image`
- Dart `archive`
- `window_manager`
- `desktop_multi_window`

No external Platform Integration dependency is accepted.

Compatible wrapper licensing does not establish the licensing, provenance, or security acceptability of bundled binaries.

Platform support claims require verification in packaged release builds.

Every package and bundled binary requires pinned transitive-license, provenance, security, maintenance, platform, and packaged-release review before adoption.

## Deferred Matters

The following remain deferred:

- Encrypted `.alnote` containers and algorithm selection
- General networking
- Remote acquisition
- Accounts, authentication, Sync, and Cloud
- Automatic update services
- Multiple-window implementation
- Native-menu dependency selection
- File and protocol association details
- Hardware-backed key requirements
- PDFium versus PDF.js adoption
- Canonical database backend
- Rich clipboard and drag-out baseline
- Exact image codecs
- Exact font discovery and embedding policy
- Android persistent background services
- Browser multi-tab coordination
- Exact permissions, entitlements, and packaging configuration
- Exact external dependency selection

## Required Invariants

- Portable code depends only on AL NOTE-owned capability contracts.
- Concrete adapters remain at the outer platform boundary.
- Only the composition root constructs and registers concrete adapters.
- Capability snapshots are evidence, not authorization.
- Sensitive operations revalidate capabilities and authorization.
- Platform tokens remain opaque, scoped, bounded, and revocable.
- Raw platform handles never enter persistent document data.
- Platform adapters never create Commands or mutate documents.
- Platform adapters never take ownership of subsystem policy.
- Capability-specific evidence is not erased by common outcome classifications.
- Cancellation-pending states are reported honestly.
- External input remains untrusted and bounded.
- Security policy applies to tokens, diagnostics, permissions, native binaries, and external input.
- Platform support claims require packaged-release verification.
- No external Platform Integration dependency or native binary is accepted by this decision.
