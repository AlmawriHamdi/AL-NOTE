# Security and Privacy Architecture

Status: **Accepted with modifications**

## Central Rule

Security and Privacy defines mandatory cross-cutting policy and portable protection contracts.

Existing subsystems retain ownership of document mutation, parsing, persistence, Recovery, Sessions, UI, Search, Import, Export, and plugin lifecycle.

## Ownership

Security and Privacy owns:

- Mandatory security and privacy policy
- Data classification
- Portable cryptographic-service contracts
- Portable secret-store contracts
- Authorization-token validation requirements
- Audit-event schema and storage policy
- Diagnostic-redaction policy
- Mandatory resource-ceiling policy
- Safe-mode security policy
- Security-event coordination
- Supply-chain security requirements
- Structured security failures

Existing subsystem owners enforce these mandatory constraints inside their domains.

Security does not replace:

- Storage parsing, loading, saving, and publication
- Command-owned document mutation
- Recovery journals and reconstruction
- Session lifecycle and unlock state
- PDF parsing, passwords, and extraction
- Import and Export plans and publication
- Search indexing and queries
- Settings persistence
- UI presentation
- Plugin package lifecycle
- Concrete platform adapters

## Threat Model

All external and persisted inputs remain untrusted until validated, including:

- `.alnote` files
- Imports, PDFs, images, and fonts
- Clipboard and drag-and-drop payloads
- Plugin packages
- Settings and Recovery records
- Search caches
- Workspace restoration
- Temporary files
- Platform responses
- Corrupted or externally modified application data

AL NOTE mitigates:

- Malformed input
- Archive traversal and bombs
- Duplicate and colliding paths
- Excessive nesting
- Resource exhaustion
- Stale authorization
- Accidental overwrite
- Confused-deputy operations
- Application-created cache and log leakage
- Common publication races
- Dependency and build risks under project control

The operating system or browser partly owns:

- User separation and file permissions
- Device locking and disk encryption
- Process and clipboard isolation
- Screenshots, backups, swap, and crash dumps
- Browser-origin enforcement and extensions
- Platform update security

Future work is required for parser process isolation, executable-plugin sandboxing, Sync, remote-service threats, accounts, and Cloud security.

AL NOTE does not claim protection against a compromised OS, browser, account, application process, administrator, or physically unlocked device.

No absolute security claims are made.

## Data Classification

Security defines:

- Public
- Internal
- Sensitive content
- Derived sensitive
- Temporary sensitive
- Secret
- Security audit
- Untrusted plugin metadata
- Anonymous operational metrics

Notes, titles, PDFs, images, and paths are sensitive content.

Indexes, snippets, thumbnails, and extracted PDF text are derived sensitive.

Import staging and Export buffers are temporary sensitive.

Passwords, keys, credentials, and bearer tokens are secret.

Plugin manifests and signatures remain untrusted metadata even when public.

Classification follows data through copies, caches, serialization, Recovery, Export, temporary storage, backups, and future Sync.

Derived data cannot receive weaker protection merely because it is rebuildable.

## Version-1 Encryption Position

Version 1 does not advertise application-level encrypted `.alnote` documents.

Operating-system disk encryption is defense in depth, not portable document encryption.

Deferred designs include whole-container, per-resource, chunked, and hybrid encryption; password or device recipients; and multiple key slots.

Only backend-neutral future boundaries are preserved:

- Detect unsupported protected containers before semantic parsing
- Transform outside ordinary document parsing
- Authenticate before publication
- Support streaming protected resources
- Preserve opaque future suite and recipient identities
- Return structured unsupported-protection outcomes
- Never fall back to plaintext after protection failure

This decision does not reserve concrete `.alnote` fields or select algorithms, KDFs, nonces, framing, key slots, password changes, metadata exposure, or encrypted Recovery and Search.

Those require a separate reviewed encrypted-container architecture.

## Secret-Store Contract

The portable asynchronous secret-store contract uses opaque references.

Conceptual operations include:

- Create
- Resolve
- Replace
- Revoke
- Inspect capability

Opaque references:

- Are not secrets
- Are namespaced
- Reveal no secret material
- Do not expose unrelated secret existence
- May become invalid
- May be stored in Settings only as references
- Do not prove current secret availability

Structured outcomes include unavailable, locked, denied, cancelled, invalidated, quota exceeded, permanently lost, and platform restricted.

Plaintext fallback is prohibited.

Tests may use an explicitly ephemeral non-production in-memory adapter.

## Platform Secret Capabilities

Possible adapter foundations include:

- Windows current-user DPAPI or another reviewed user-scoped facility
- Android Keystore
- Linux Secret Service
- Web Crypto with origin storage
- User-entered memory-only secrets

Availability and guarantees are not universal or equivalent.

Hardware backing, exportability, user presence, backup, portability, migration, revocation, and multi-process behavior remain capability-dependent.

Web Crypto does not make browser storage equivalent to a native secret store or protect against compromised same-origin code.

## Cryptographic Contracts

Replaceable contracts cover:

- Secure random generation
- Hashing
- Authenticated encryption
- Password-based key derivation
- Digital-signature verification
- Key wrapping where required
- Constant-time comparison where meaningful
- Secure opaque-token generation

Requirements include:

- Reviewed algorithms
- Versioned suites and parameters
- Domain separation
- Structural nonce safety
- Associated-data binding
- Authentication before semantic use or publication
- Explicit failure
- No unauthenticated plaintext publication
- Test vectors
- Cross-platform conformance
- Key-purpose restrictions
- Rotation and revocation policy
- No homemade cryptography

No algorithm suite is accepted.

Argon2id, AES-GCM, ChaCha20-Poly1305, XChaCha20-Poly1305, platform primitives, `package:cryptography`, and libsodium remain studies.

## Password and Key Handling

Requirements include:

- Random salts for future password derivation
- Versioned KDF parameters
- Minimum and maximum work policies
- Bounded calibration
- Short practical secret lifetimes
- UI-independent structured unlock requests
- No automatic clipboard copying
- No secrets in documents, Recovery, restoration, history, logs, caches, Search, or ordinary Settings
- Explicit Session locking
- Capability-dependent inactivity and suspension locking
- Browser refresh invalidating memory-only unlock state
- Best-effort mutable-buffer zeroization

Dart garbage collection prevents guaranteed erasure of every copy.

Successful universal zeroization is not claimed.

## Authorization Tokens

Common token rules apply to overwrite authorization, Import staging, Export publication, destructive operations, secret access, protected resources, and future executable plugins.

Tokens bind as applicable to:

- Issuer and intended subsystem
- Subject or Session
- Exact resource and operation
- Revision and external fingerprint
- Platform capability
- Issue time and expiration
- Freshness
- Reuse policy
- Revocation generation
- Random unforgeable identity

Tokens are opaque, normally memory-only, minimally logged, and revalidated immediately before irreversible action.

Expired, stale, replayed, mismatched, revoked, or capability-invalid tokens are rejected.

Authentication, consent, authorization, and platform capability remain separate checks.

## Privacy Defaults

Version 1 has:

- No telemetry
- No automatic crash upload
- No diagnostic upload
- No automatic network reporting
- Search-query history disabled by default
- Privacy-safe Export metadata defaults
- User-controlled recent documents and restoration
- Bounded private thumbnails, Recovery, and Search storage
- Minimal clipboard formats
- No plugin access to runtime document or user data
- No network requirement

Future telemetry requires separate architecture, explicit consent, minimal collection, independent disabling, and verified exclusion of content and secrets.

## Logging and Diagnostics

Logging classes may include operational, performance, security, user-exported diagnostic, and development-only verbose.

Every class uses mandatory redaction.

Never log:

- Document content
- Sensitive titles
- Queries or snippets
- Passwords, keys, tokens, or credentials
- Raw clipboard data
- Full paths
- Usernames or device names
- Private imported metadata
- Unbounded plugin manifests

Permitted bounded fields include stable error codes, counts, sizes, capability states, coarse platform categories, ephemeral per-run correlation identities, and sanitized stage names.

Persistent identity hashes are avoided because they may enable correlation.

Stack traces are scrubbed.

Production Web builds emit no sensitive console content.

## Audit Events

Security owns audit schema, storage policy, retention, capacity, access, export, cleanup, integrity, and multiple-writer coordination.

Events may cover plugin trust, signature failures, publisher-key changes, protected-resource unlock, secret-store failure, future encryption failure, overwrite authorization, policy changes, malformed-input rejection, and safe mode.

Events exclude paths, titles, content, queries, snippets, secrets, persistent tracking identities, detailed credentials, and private resource identities unless strictly required and protected.

Retention and capacity are bounded.

Wall-clock timestamps are advisory.

Multiple writers use atomic append, isolated segments, or equivalent coordination.

Audit failure cannot authorize an operation otherwise denied.

Audit storage must not become surveillance history.

## Resource-Limit Policy

Security owns immutable mandatory policy snapshots with separate ceilings for:

- Stored and expanded size
- Entries, nesting, and compression ratios
- Documents, Pages, Layers, Objects, and references
- Images and decoded bytes
- PDF parsing and rendering
- Text and shaping
- Search corpus, queries, and results
- Recovery and undo history
- Plugin packages
- Concurrent CPU, decoder, indexing, and I/O jobs
- Temporary storage
- Clipboard and drag payloads
- Import and Export plans

Subsystems enforce applicable limits inside their boundaries.

Settings cannot raise mandatory ceilings.

Platforms may lower them, and users may select lower values.

Failures identify the policy dimension without exposing content.

One unstructured global maximum is prohibited.

Exact values remain deferred.

## Input and File Safety

Requirements include:

- Content-based detection
- Extensions only as hints
- Canonical relative archive paths
- Rejection of absolute paths, traversal, symlinks, and special entries
- Duplicate normalized-path and Unicode or case-collision detection
- Preflight plus streaming enforcement
- Bounded recursion, allocation, dimensions, and processing
- Inert unknown-field preservation
- Private randomized staging
- Revalidation before publication
- Source- and revision-bound external fingerprints
- Existing safe-replacement boundaries
- No paths constructed directly from untrusted archive names
- Parser contracts compatible with future isolation

Existing parsers and publishers retain ownership.

## Clipboard, Drag-and-Drop, and Sharing

Clipboard, drag, and sharing data remains untrusted regardless of origin markers, hashes, tags, or platform hints.

Requirements include:

- Versioned bounded internal formats
- Minimal plain-text fallback
- Exclusion of secrets and hidden metadata
- Normal Import validation for rich data and files
- Command-only Cut and Paste mutations
- No source deletion after clipboard ownership loss
- Immutable Export snapshots for sharing
- Capability-based clipboard clearing
- Honest warnings about clipboard retention
- Bounded expiring private staging

## Temporary Data

Every temporary-data owner declares:

- Purpose and classification
- Private platform location
- Randomized name
- Ownership identity
- Restrictive permissions where supported
- Quota and maximum lifetime
- Cleanup triggers
- Publication boundary
- Failure behavior

Startup cleanup validates ownership and active use.

Active resources are never deleted based only on age.

Cleanup is best effort.

Secure deletion from flash, browser storage, snapshots, or backups is not claimed.

Protected sources cannot create persistent plaintext derived data without equivalent protection.

## Platform Capability Model

Security behavior is capability-based across Linux, Windows, Android, and Web.

Capabilities include secure storage, permissions, sandboxing, isolation, device locking, user presence, hardware keys, backup, screenshots, clipboard, background work, multiple writers, update integrity, and private storage.

Security guarantees correct use of available adapters, not identical protection everywhere.

## Web Security

Web requirements include:

- Secure-context deployment
- Reviewed origin policy
- No raw document or plugin HTML
- Contextual output encoding
- No arbitrary scripts, workers, imports, or executable plugin content
- Cross-context message validation
- Sensitive browser storage treated as readable after same-origin compromise
- Minimal service-worker scope and allowlisted caching
- No sensitive content in general HTTP caches
- Prompt Blob and Object URL revocation
- Bounded revalidated File System Access handles
- Secret-free multi-tab coordination
- Site-data eviction handling
- XSS regression testing

A restrictive CSP must be tested against the actual Flutter Web build and hosting configuration.

One exact CSP is not prescribed before deployment testing.

Weakening such as `unsafe-inline`, `unsafe-eval`, or arbitrary remote scripts is avoided where possible; unavoidable exceptions require review and narrow scope.

Trusted Types should be studied before enforcement.

Browser storage is not described as a native secure store.

## Supply-Chain Security

Requirements include:

- Dependency minimization
- Transitive-graph review
- Committed lockfiles and registry checksums
- Source and artifact verification
- Least-privilege CI
- Isolated publishing credentials
- No secrets exposed to untrusted pull-request code
- Pinned CI actions and toolchains
- Review of native binaries, WebAssembly, scripts, generated code, and assets
- Vulnerability and license scanning
- Machine-readable release SBOM
- Verifiable build provenance
- Reproducibility checks where practical
- Vulnerability disclosure and intake
- Patch and revocation procedures

Release authentication remains distribution-specific.

No universal signing mechanism is promised.

SBOM format, provenance level, signing, and release pipeline remain deferred.

## Safe Mode

Safe mode is deterministic and entered through explicit user choice or validated failure and Security policies.

It may disable external plugins, ignore caches, avoid restoration or reopening, suppress background work, apply stricter limits, and leave suspicious documents closed.

Read-only opening still requires ordinary validation.

Recovery and Export remain behind normal boundaries.

Safe mode cannot bypass validation, treat malformed data as safe, silently delete or rewrite content, migrate data, publish repairs, or destroy evidence.

Its cause, restrictions, and exit conditions remain visible and accessible.

## Security UX and Accessibility

Security decisions use host-owned structured requests containing trusted operation identity, resource category, consequences, expiration, freshness, and safe cancellation.

Plugin text cannot provide trusted security dialogs or permission descriptions.

Requirements include keyboard and screen-reader access, text scaling, reflow, localization, RTL, non-color-only warnings, no preselected dangerous choice, no dark patterns, explicit key-loss consequences, freshness-bound confirmation, and cancellation without persistent mutation.

UI retains final presentation ownership.

## Failure and Cancellation

Structured outcomes include unavailable, locked, cancelled, wrong credential, unsupported suite, corrupt protected data, authentication failure, unavailable or revoked keys, policy denial, capability failure, resource limit, invalid or expired tokens, stale authorization, audit failure, incomplete cleanup, quota failure, platform restriction, and dependency-integrity failure.

Messages avoid confirming protected identities or secret existence unnecessarily.

Cancellation is not an error.

Cancellation never produces partial publication, authorization, or plaintext fallback.

## Testing and Assurance

Automated testing covers contracts, adapters, future test vectors, properties, serialization, fuzzing, archive attacks, limits, tokens, TOCTOU, concurrency, redaction, fault injection, Web CSP and XSS, dependency and secret scanning, licensing, artifacts, and accessibility.

Independent review is required for threat models, future encrypted containers, cryptography, native and Web boundaries, parser isolation, releases, destructive or key-loss UX, and incident-response exercises.

Following OWASP or other guidance does not itself prove security or conformance.

## Repository Ownership

Portable Security and Privacy architecture belongs under:

`lib/core/security/`

Concrete implementations remain platform adapters.

This documentation commit creates no implementation subdivisions.

## Dependency Status

No Security, cryptography, secure-storage, audit, SBOM, or supply-chain dependency is accepted.

Studies include `package:cryptography`, libsodium, secure-storage packages, Argon2id implementations, SPDX tools, and CycloneDX tools.

Platform foundations include Android Keystore, Windows current-user DPAPI, Linux Secret Service, and Web Crypto.

Guidance includes OWASP ASVS, OWASP MASVS, OWASP File Upload guidance, NIST cryptographic guidance, SLSA, and W3C Web security specifications.

## Deferred Matters

- Encrypted `.alnote` containers and field layout
- Algorithm suites, KDFs, nonces, and framing
- Key slots, recipients, password changes, and rotation
- Encrypted Recovery and Search indexes
- Protected thumbnails
- Hardware-key migration
- Cryptographic and secure-storage dependencies
- Parser process isolation
- Executable-plugin sandboxing
- Accounts, Sync, Cloud, authentication, and protocols
- Telemetry
- Exact resource limits
- Audit encoding
- SBOM format
- Release signing and provenance
- Incident-response operations
- Final Security UI
