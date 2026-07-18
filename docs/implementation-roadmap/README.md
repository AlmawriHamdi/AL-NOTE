# AL NOTE Codex Implementation Roadmap

## Status

Version-1 architecture baseline frozen for implementation.

The Final Architecture Consistency Audit passed. Every version-1 subsystem is Accepted with modifications, the decision ledger is continuous from D-006 through D-500, and no blocking architectural contradiction was found.

Recognition, Math Recognition, Symbolic Math, Sync, and Cloud remain post-v1.

## Working Rules

Codex must:

- Read `ARCHITECTURE.md` and relevant subsystem READMEs before each phase.
- Implement one bounded phase or vertical slice at a time.
- Preserve accepted ownership and dependency direction.
- Add tests with implementation.
- Avoid unrelated refactoring.
- Never add a dependency as an incidental convenience.
- Present dependency additions as separately reviewable changes.
- Keep platform APIs behind adapters.
- Keep document mutation behind Commands.
- Use immutable authoritative state.
- Return structured failures and cancellation.
- Preserve unknown content.
- Keep generated and derived data non-authoritative.
- Avoid premature Recognition, Sync, Cloud, and executable plugins.
- Verify every phase before proceeding.

## Implementation Readiness

Exact implementation selections remain required for:

- Flutter and Dart SDK versions
- Immutable collection strategy
- ZIP and deterministic JSON implementation
- Native and Web private-storage backends
- Recovery encoding and timing values
- Fonts and text-editing integration
- Image encoding support
- PDF engine and PDF composer
- Plugin archive and signing implementation
- File pickers, sharing, and richer platform integrations
- Exact security and resource limits
- Packaging and signing tools

These are controlled implementation decisions under the accepted architecture. They do not reopen subsystem ownership.

Every dependency requires license, provenance, maintenance, platform, Security, and packaged-build review before adoption.

## Phase 0 — Repository and Toolchain Baseline

### Purpose

Create the buildable Flutter and Dart foundation without implementing application features.

### Deliverables

- Initialize Flutter support for Linux, Windows, Android, and Web.
- Preserve all existing architecture and license files.
- Pin the Flutter and Dart toolchain.
- Create the initial `pubspec.yaml` and lockfile.
- Add strict static-analysis configuration.
- Establish source and test roots.
- Add a minimal AL NOTE application shell.
- Add a basic format, analysis, and test workflow using full-SHA-pinned Actions.
- Record the dependency and license-review procedure.
- Confirm GPL-3.0-or-later metadata.
- Confirm the starter application builds on available target environments.

### Restrictions

- No PDF engine
- No storage backend
- No state-management package
- No third-party UI framework
- No feature implementation

### Exit Condition

The repository is a reproducible, analyzable, tested Flutter project with preserved architecture documentation.

## Phase 1 — Core Primitives and Contracts

Implement:

- Stable identifiers and UUID boundaries
- Version values
- Revision and content identities
- Immutable result types
- Structured failure and cancellation
- Security classifications
- Resource-limit contracts
- Clock and random-source abstractions
- Geometry primitives
- Transforms
- Common validation contracts
- Testing fakes

### Exit Condition

Portable foundational types are tested and contain no platform or UI dependencies.

## Phase 2 — Authoritative Document Model

Implement:

- Document forms
- Notebook
- Section
- Page
- Layer
- Object envelope
- Object Registry
- Unknown Object preservation
- Unknown Layer preservation
- Resource identities and references
- Built-in placeholder behavior
- Deterministic validation
- Immutable replacement

Start with minimal built-in test Object types rather than full Text, Image, Shape, or PDF behavior.

### Exit Condition

Documents can be constructed, validated, replaced immutably, duplicated safely, and round-tripped through in-memory representations.

## Phase 3 — Commands, History, Selection, and Transforms

Implement:

- Document-scoped Command coordinator
- Typed Command Requests
- Revision and stale-state validation
- Atomic state publication
- Structured change descriptions
- Linear Undo and Redo
- Coalescing boundaries
- Dirty-state identity
- Temporary Selection
- Transform previews
- Atomic multi-object transform commits

### Exit Condition

A document can be edited, undone, redone, selected, and transformed exclusively through Commands.

## Phase 4 — Storage, Resources, and `.alnote`

Before implementation, audit and select ZIP and JSON dependencies or SDK mechanisms.

Implement:

- Deterministic `.alnote` ZIP package
- UTF-8 JSON records
- Manifest
- Resource UUID and SHA-256 identities
- Page and Section record boundaries
- Bounded hostile-input validation
- Unknown-data preservation
- Migration orchestration
- Complete replacement Save
- Temporary-output validation
- Native and Web resource contracts
- Golden format fixtures

### Exit Condition

A document can be saved, reopened, validated, migrated, and preserved byte-deterministically across supported test environments.

## Phase 5 — Sessions, Recovery, Settings, Jobs, and Platform Contracts

Implement in bounded subphases:

1. Application State and logical Document Sessions
2. Recovery checkpoints and journal
3. Settings definitions and transactional repository contracts
4. Portable Job System
5. Platform capability registry and adapter contracts
6. In-memory and deterministic testing adapters
7. Native and Web storage implementations after backend audit

### Exit Condition

Multiple Sessions can safely coordinate state, Recovery, Settings, Jobs, lifecycle, and platform capabilities.

## Phase 6 — Rendering, Viewport, Input, and Handwriting Vertical Slice

Implement:

- Drawing renderer contracts
- Viewport transforms
- Hit testing
- Raw input normalization
- Interaction Mapping
- Drawing Tool registry
- Gesture sessions
- Pen Tool
- Stroke Object
- Stroke preview
- Erasing and splitting
- Command publication
- Basic Canvas UI

Required vertical slice:

1. Create a document.
2. Draw a stroke.
3. Display the stroke.
4. Select or erase it.
5. Undo and Redo.
6. Save the document.
7. Reopen it with identical authoritative content.

### Exit Condition

AL NOTE has its first complete usable handwriting path.

## Phase 7 — Built-In Shape, Image, and Text Objects

Implement each Object type separately.

### Shape

- Built-in shape kinds
- Intrinsic geometry
- Styles
- Hit testing
- Rendering
- Commands and transforms

### Image

- PNG and JPEG
- Immutable resources
- Orientation
- Crop
- Metadata privacy
- Bounded decoding
- Placeholders

### Text

- Constrained rich-text model
- Paragraphs and runs
- Text boxes
- Editor sessions
- IME
- Fonts and fallback after audit
- Layout contracts
- Clipboard sanitization
- Accessibility and Search projections

### Exit Condition

Shape, Image, and Text Objects function through the same Object, Command, Storage, rendering, and Security boundaries.

## Phase 8 — PDF System

PDF implementation cannot begin until a mature backend is selected through a separate audit.

Do not write a PDF parser or renderer from scratch.

Implement:

- Immutable PDF resources
- Source layers
- PDF Page Objects
- Coordinate conversion
- Password-required outcomes
- Rendering adapters
- Text-extraction adapters
- Safe link metadata
- Disabled executable actions
- Missing and corrupt placeholders
- Import workflows
- Sanitized export construction
- Cancellation and limits

### Exit Condition

Standalone PDFs, PDF-backed notebook Pages, annotations, and sanitized exports pass conformance tests on supported targets.

## Phase 9 — Import, Export, Search, and Declarative Plugins

### Import and Export

Implement:

- Prepared Import Plans
- Staged-resource tokens
- Export Snapshots
- Preflight
- PDF, PNG, and JPEG
- Safe destination publication

### Search

Implement:

- Direct-scanning semantic oracle
- In-memory index
- Text and metadata Search
- PDF-derived projections
- Freshness and completeness reporting

### Plugins

Implement:

- Bounded `.alnote-plugin` packages
- Declarative validation
- Registry generations
- Installation and rollback
- Safe mode
- Settings and UI descriptors
- No external executable code

### Exit Condition

Import, Export, Search, and Plugins integrate without bypassing Commands, Security, Sessions, Jobs, or platform adapters.

## Phase 10 — Full Application UI and Platform Integration

Implement:

- Adaptive application shell
- Document Views
- Tabs or equivalent Session surfaces
- Toolbars
- Tool options
- Settings UI
- Search UI
- Import and Export UI
- Recovery and conflict decisions
- Read-only and degraded states
- Accessibility
- Localization and RTL
- Pickers
- Clipboard
- Drag-and-drop where supported
- Sharing
- Lifecycle
- External activation
- Single-primary-window baseline

### Exit Condition

All version-1 workflows are usable through an accessible, adaptive interface.

## Phase 11 — Hardening and Release Qualification

Implement and verify:

- Full test taxonomy
- Platform conformance
- Browser matrix
- Security and fuzz tests
- Recovery fault injection
- Performance baselines
- Accessibility qualification
- Dependency and license inventory
- SBOM
- Provenance
- Flatpak
- Linux portable archive
- Signed MSIX
- Windows portable ZIP
- Signed Android APK
- Conditional App Bundle
- Versioned Web bundle
- Release manifest
- Signing separation
- Remote artifact verification

### Exit Condition

A release candidate satisfies the accepted Testing, Packaging, CI, and Release architecture.

## Implementation Gates

The following require explicit review before their phase:

- Any new dependency
- Any bundled binary
- PDF backend
- Storage backend
- Archive implementation
- Text editor or layout package
- Font bundle
- Image codec
- Cryptographic package
- Secure-storage package
- Platform plugin
- State-management package
- Packaging or signing tool

## First Codex Assignment

After this roadmap is committed and verified, the first Codex assignment is:

**Phase 0 — Repository and Toolchain Baseline**

Codex must not begin Phase 1 during the Phase 0 assignment.
