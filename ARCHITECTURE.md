# AL NOTE Architecture

This document records architecture approved by the Main Architect, the subsystem roadmap, and the stable decision ledger.

## Subsystem Status

| Subsystem | Status | Notes |
|---|---|---|
| Object System | Accepted with modifications | Defines the persistent, platform-independent page-object model |
| Layer System | Accepted with modifications | Owns layer structure, object membership, and ordering |
| Selection and Transform System | Accepted with modifications | Owns temporary page-scoped selection and transform previews |
| Command, Undo, and Redo System | Accepted with modifications | Exclusively coordinates persistent mutations and session history |
| Storage, Serialization, and AL NOTE File Format | Accepted with modifications | Owns durable packages, serialization, resources, and file safety |
| Autosave and Recovery | Accepted with modifications | Owns recovery scheduling, checkpoints, journals, reconstruction, and cleanup |
| Drawing Tool System | Next subsystem | Will define user-facing drawing tools and their interaction contracts |

## Object System

The Object System defines the persistent, platform-independent model for everything placed on a page, including handwriting, text, images, shapes, PDFs, and future plugin-defined objects.

### Accepted Ownership Boundaries

- The Object System owns object identity, type identity, common persistent state, payload boundaries, transforms, and validation contracts.
- Object types own intrinsic geometry, payload validation, and schema migrations.
- The Layer System owns membership and ordering.
- The Drawing Renderer owns rendering execution.
- The Hit-Testing System owns hit-testing execution.
- The Storage System owns encoding, decoding, and migration orchestration.
- The Command System will later own applying and reversing object replacements.
- The Plugin System will later own plugin loading, trust, permissions, and registration lifecycle.

The detailed Object System architecture is recorded in [lib/documents/objects/README.md](lib/documents/objects/README.md).

## Layer System

The Layer System provides the authoritative structure:

**Page → ordered layers → ordered objects**

### Accepted Ownership Boundaries

- The Layer System owns layer identity and persistent common state.
- Pages exclusively own their ordered layers.
- Layers directly own their ordered object values.
- The Layer System owns layer order and object order within layers.
- It owns safe object movement between layers.
- It owns effective layer visibility and locking.
- It owns layer lifecycle and validation.
- It does not own rendering, selection interaction, undo history, storage encoding, plugin loading, or UI state.

The detailed Layer System architecture is recorded in [lib/documents/layers/README.md](lib/documents/layers/README.md).

## Selection and Transform System

The Selection and Transform System provides temporary, page-scoped selection and transformation without placing interaction state inside persistent document objects.

### Accepted Ownership Boundaries

- It resolves point, rectangle, and lasso selection.
- It owns temporary page-editing selection state.
- It calculates selection geometry and interaction overlays.
- It previews movement, resizing, and rotation without mutating persistent documents.
- It enforces capabilities, visibility, locking, and Page boundaries.
- It prepares atomic requests for the future Command System.
- It supports whole-object and handwriting-stroke sub-target selection.
- It does not own persistent document mutation.
- Documents must not depend on Selection.

The detailed Selection and Transform System architecture is recorded in [lib/drawing/selection/README.md](lib/drawing/selection/README.md).

## Command, Undo, and Redo System

The Command, Undo, and Redo System is the only normal path for changing persistent AL NOTE document state.

### Accepted Ownership Boundaries

- A document-scoped mutation coordinator exclusively publishes persistent state.
- It owns Command Request and Prepared Transaction contracts.
- It owns final validation inside the serialized mutation boundary.
- It owns atomic document-root publication.
- It owns session-only linear undo and redo history.
- It owns scoped revision tracking and stale-request detection.
- It owns committed-change descriptions.
- It tracks session content-state identities for dirty-state comparison.
- It retains history references to resources without owning physical resource storage.
- External effects and asynchronous preparation occur outside reversible domain commands.

The detailed Command, Undo, and Redo architecture is recorded in [lib/documents/commands/README.md](lib/documents/commands/README.md).

## Storage, Serialization, and AL NOTE File Format

The Storage subsystem converts captured immutable document states and their resources into durable, portable, verifiable `.alnote` packages and reconstructs them without silently losing persistent information.

### Accepted Ownership Boundaries

- It owns the AL NOTE-specific, ODF-inspired ZIP package contract.
- It owns deterministic version-1 UTF-8 JSON serialization.
- It owns the manifest, structured-record catalog, and resource catalog.
- It owns resource repository contracts using logical UUIDs and SHA-256 hashes.
- It owns preservation-capable parsing and unknown-record preservation.
- It owns migration planning, orchestration, and complete-result validation.
- It owns staged loading, bounded validation, and lazy Page and resource loading.
- It owns save and load coordination and atomic-replacement abstractions.
- It owns external-change fingerprints.
- Platform adapters own platform file, stream, replacement, locking, permission, quota, and browser-storage primitives.
- It does not own undo history, autosave scheduling, recovery journals, rendering, import/export workflows, plugin execution, sync, encryption, or file-picker UI.

The detailed Storage architecture is recorded in [lib/documents/files/README.md](lib/documents/files/README.md).

## Autosave and Recovery

Autosave and Recovery protects committed document work through complete durable checkpoints, short append-only journals, retained resources, and versioned recovery manifests.

### Accepted Ownership Boundaries

- Recovery is enabled by default and remains separate from canonical `.alnote` saving.
- Journal entries contain committed persistent after-state replacements, not commands, UI events, previews, or undo history.
- Each logical in-memory document has one serialized recovery writer shared by coordinated views.
- Scheduling combines quiet-period debounce, maximum dirty-state age, checkpoint thresholds, and lifecycle flushes.
- Durable generations, journal sequences, hashes, transaction UUIDs, and commit markers define recovery order.
- Previous valid generations remain until replacement publication is validated and durable.
- Startup reconstruction uses the newest valid checkpoint and its newest valid journal prefix.
- Restored work opens dirty with a new Command History baseline and never automatically overwrites a canonical file.
- Conflicting or uncertain recovery opens as a separate recovered document.
- Recovery retains every resource reachable from valid generations and active recovery work.
- Uncoordinated processes or browser tabs create separate recovery branches rather than merging automatically.
- Cleanup requires a covered normal save, explicit discard, or confirmed save of a recovered candidate.
- Platform adapters own storage locations, durability primitives, locking, leases, quota reporting, and lifecycle notifications.
- Recovery artifacts receive private-document security and hostile-input protections.
- Recovery architecture belongs under `lib/documents/recovery/`.
- No recovery implementation dependency or backend is accepted yet.

The detailed Autosave and Recovery architecture is recorded in [lib/documents/recovery/README.md](lib/documents/recovery/README.md).

## Decision Ledger

| ID | Subsystem | Decision | Status | Dependencies |
|---|---|---|---|---|
| D-006 | Objects | Page objects use a small persistent model with external behavior registries | Accepted | Documents |
| D-007 | Objects | Object IDs are document-unique UUIDs and types use namespaced strings | Accepted | D-006 |
| D-008 | Objects | Edits replace immutable-facing revisions; structural sharing is allowed | Accepted | D-006 |
| D-009 | Objects | Layers exclusively own object membership and ordering | Accepted | D-006 |
| D-010 | Objects | Intrinsic geometry combines with a local-to-page transform | Accepted | Geometry |
| D-011 | Objects | Unknown objects remain inert, preserved, and safely represented | Accepted | Storage, Plugins |
| D-012 | Objects | Rendering and hit-testing use registries separate from the core Object Registry | Accepted | Drawing |
| D-013 | Objects | Duplicated objects receive new IDs and remap internal references | Accepted | Clipboard, Commands |
| D-014 | Objects | Full grouping ownership and structure are deferred | Deferred | Layers, Selection |
| D-015 | Layers | Pages own ordered layer values; layers own ordered object values | Accepted | Objects |
| D-016 | Layers | Layer IDs are document-unique UUIDs and collection position defines order | Accepted | D-015 |
| D-017 | Layers | Ordinary content layers support mixed object types | Accepted | D-015 |
| D-018 | Layers | Effective visibility uses AND; effective locking uses OR | Accepted | Objects |
| D-019 | Layers | Every page retains at least one content-capable layer | Accepted | Pages |
| D-020 | Layers | Background and PDF sources use constrained source layers below content | Accepted | Documents, PDF |
| D-021 | Layers | Opacity is common; blend modes and export policy are deferred | Accepted | Rendering, Export |
| D-022 | Layers | Unknown layers and their data remain preserved and inert | Accepted | Storage, Plugins |
| D-023 | Layers | Active-layer selection is non-persistent session state | Accepted | Sessions |
| D-024 | Layers | Nested layers and layer groups are unsupported for now | Deferred | Selection, Grouping |
| D-025 | Selection | Selection is temporary page-editing session state | Accepted | Sessions |
| D-026 | Selection | Targets use Page ID, Object ID, and optional stable sub-target identity | Accepted | Objects |
| D-027 | Selection | Selection may cross layers within one page while preserving membership and order | Accepted | Layers |
| D-028 | Selection | Initial selection supports objects and handwriting-stroke sub-targets | Accepted | Handwriting |
| D-029 | Selection | Region selection uses precise, policy-driven containment or intersection tests | Accepted | Hit Testing |
| D-030 | Transform | Public transforms use controlled affine operations | Accepted | Geometry |
| D-031 | Transform | Preview is temporary; commits replace all affected objects atomically | Accepted | Commands |
| D-032 | Transform | Every selected target must support a requested shared transform | Accepted | Capabilities |
| D-033 | Transform | Partial overflow is allowed, but transformed content must remain recoverable from the page | Accepted | Pages |
| D-034 | Selection | Hidden and locked objects are excluded; unknown objects are non-transformable | Accepted | Objects, Layers |
| D-035 | Selection | Selection and transform-session ownership belongs under `lib/drawing/selection/` | Accepted | Drawing |
| D-036 | Commands | Exact revision and stale-state token mechanism is deferred | Deferred | Command System |
| D-037 | Commands | One document-scoped coordinator exclusively publishes persistent state | Accepted | Documents |
| D-038 | Commands | Requests express intent; history uses structurally shared before/after state plus metadata | Accepted | D-037 |
| D-039 | Commands | Preparation may be asynchronous; final commit is serialized and atomic | Accepted | D-037 |
| D-040 | Commands | Transactions may span one logical document; cross-document atomicity is deferred | Accepted | Documents |
| D-041 | History | Each open-document session owns one linear undo/redo history | Accepted | Sessions |
| D-042 | History | Undo and redo restore recorded states, original IDs, ordering, and opaque data | Accepted | D-038 |
| D-043 | History | Coalescing requires explicit semantic merge keys and boundaries | Accepted | D-041 |
| D-044 | Commands | Stale checks use scoped session revision tokens; global revision is not always required | Accepted | D-037 |
| D-045 | History | Dirty state compares current content-state identity with the last successful save | Accepted | Storage |
| D-046 | Commands | Every successful commit emits one immutable structured change description | Accepted | Rendering, Autosave |
| D-047 | History | Normal undo history remains session-only; recovery journaling is separate | Accepted | Recovery |
| D-048 | Resources | History retains resource IDs or leases; physical reclamation belongs to the Resource System | Accepted | Resources |
| D-049 | Commands | Authorization distinguishes content edits, management actions, and privileged recovery | Accepted | Objects, Layers |
| D-050 | Commands | Command architecture belongs under `lib/documents/commands/` | Accepted | Documents |
| D-051 | Core | Immutable collection dependency selection requires representative benchmarks | Deferred | Performance |
| D-052 | History | Disk-backed history and very-large-entry policy are deferred | Deferred | Storage, Platforms |
| D-053 | Storage | All document forms use one `.alnote` ZIP package | Accepted | Documents |
| D-054 | Serialization | Package version 1 uses deterministic UTF-8 JSON records | Accepted | D-053 |
| D-055 | Serialization | Records are divided at document, section, and page boundaries | Accepted | D-053 |
| D-056 | Resources | Version 1 embeds required resources as separate ZIP entries | Accepted | D-053 |
| D-057 | Resources | Resources use logical UUIDs plus SHA-256 content identity | Accepted | D-056 |
| D-058 | Storage | The manifest catalogs authoritative entries, sizes, media types, and hashes | Accepted | D-053 |
| D-059 | Versioning | Package, root, layer, object-envelope, and type-payload versions remain separate | Accepted | Objects, Layers |
| D-060 | Preservation | Unknown data and potentially reachable resources must be preserved | Accepted | Objects, Layers, Plugins |
| D-061 | Serialization | Logical serialization is deterministic | Accepted | D-054 |
| D-062 | Storage | Loading may be lazy at page and resource boundaries | Accepted | D-055 |
| D-063 | Storage | Saving creates and validates a complete replacement package | Accepted | Commands |
| D-064 | Migration | Migrations never modify the original package in place | Accepted | D-059 |
| D-065 | Compatibility | Unsupported newer content is editable only when safely understood | Accepted | D-059, D-060 |
| D-066 | Security | Packages are hostile input and require bounded validation | Accepted | D-053 |
| D-067 | Storage | Advisory writer coordination is combined with external-file fingerprints | Accepted | Platforms |
| D-068 | Storage | Storage architecture belongs under `lib/documents/files/` | Accepted | Documents |
| D-069 | Storage | External links, signatures, encryption, and final media-type registration are deferred | Deferred | Security, Platforms |
| D-070 | Storage | Exact ZIP and JSON implementation dependencies are deferred pending testing | Deferred | Performance, Platforms |
| D-071 | Recovery | Recovery uses complete checkpoints plus a short append-only journal | Accepted | Storage, Commands |
| D-072 | Recovery | Recovery is enabled by default and stored separately from canonical files | Accepted | D-071 |
| D-073 | Recovery | Journal entries contain committed persistent results, not commands or UI events | Accepted | Commands |
| D-074 | Recovery | One serialized recovery writer serves each logical in-memory document | Accepted | Sessions |
| D-075 | Autosave | Recovery uses debounce, maximum-latency, and lifecycle triggers | Accepted | D-074 |
| D-076 | Recovery | Previous valid generations remain until replacement is durable | Accepted | Storage |
| D-077 | Recovery | Durable sequence numbers and hashes define recovery order | Accepted | D-071 |
| D-078 | Recovery | Recovery records source identity and canonical destination fingerprints | Accepted | Storage |
| D-079 | Recovery | Restoration uses the newest valid checkpoint and valid journal prefix | Accepted | D-076, D-077 |
| D-080 | Recovery | Restored recovery opens dirty with a new history baseline | Accepted | Commands |
| D-081 | Recovery | Uncertain or conflicting recovery opens as a separate document | Accepted | Sessions, Storage |
| D-082 | Resources | Recovery retains every resource reachable from valid generations | Accepted | Resources |
| D-083 | Recovery | Coordinated views share ownership; uncoordinated sessions create branches | Accepted | Sessions, Platforms |
| D-084 | Recovery | Cleanup requires a covered save or explicit discard | Accepted | Storage |
| D-085 | Recovery | Recovery architecture belongs under `lib/documents/recovery/` | Accepted | Documents |
| D-086 | Security | Recovery artifacts receive document privacy and hostile-input protections | Accepted | Security, Storage |
| D-087 | Recovery | Exact format, backend, timings, leases, retention periods, and dependencies are deferred | Deferred | Testing, Platforms, Settings |

## Deferred Object System Questions

- Exact transform encoding
- Numeric precision and coordinate limits
- Common metadata fields
- Group ownership and nesting
- Image and PDF resource references
- Exact serialization format
- Plugin packaging and security
- Synchronization provenance

## Deferred Layer System Questions

- Nested layers and layer groups
- Arbitrary blend modes
- Export and print participation policy
- Exact PDF and background source binding
- Resource ownership
- Cross-page object moves
- Plugin loading and security
- File encoding
- Full grouping ownership

## Open-Source Record

- Rnote is GPL-3.0-or-later; adapt relevant retained-document concepts only.
- Xournal++ is GPL-2.0-or-later; concepts may be studied, but direct reuse requires file and dependency auditing.
- Krita provides useful layer concepts, but its node system is too complex for AL NOTE.
- Dart `built_collection` may be evaluated behind AL NOTE-owned interfaces but must not become a permanent serialized contract.

## Deferred Selection and Transform Questions

- Other sub-object editing types
- Custom pivots
- Snapping and alignment guides
- Direction-dependent rectangle selection
- Overlap cycling
- Group selection behavior
- Reflection
- Skew
- Perspective transforms
- Exact transform serialization
- Exact revision and stale-state token mechanism
- Read-only inspection ownership

## Selection and Transform Open-Source Record

- Rnote is GPL-3.0-or-later; adapt note-oriented selection concepts.
- Xournal++ is GPL-2.0-or-later; direct reuse requires file and dependency auditing.
- Krita provides useful transform-session and preview concepts, but its advanced transformation scope is excessive for AL NOTE.
- Flutter transformation primitives may support viewport and temporary UI mechanics but do not replace the document Selection System.
- Dart `vector_math` may be reused behind AL NOTE-controlled transform validation contracts.

## Deferred Command, Undo, and Redo Questions

- Cross-document atomicity
- Collaboration rebasing
- Persistent or disk-backed history
- Crash-recovery journal format
- Exact resource storage and reclamation strategy
- Immutable collection dependency
- Very-large-command spill policy
- Persistent content fingerprint
- Exact revision implementation

## Command, Undo, and Redo Open-Source Record

- Rnote is GPL-3.0-or-later; adapt command and history concepts only.
- Xournal++ is GPL-2.0-or-later; direct reuse requires file and dependency auditing.
- Krita provides useful history, merging, and memory-limit concepts but is substantially more complex.
- The Dart `undo` package is Apache-2.0 but is unsuitable as AL NOTE’s command core.
- `built_collection` remains a benchmarking candidate.
- `fast_immutable_collections` is BSD-2-Clause and remains a benchmarking candidate.
- No command or immutable-collection dependency is accepted yet.

## Deferred Storage and File Format Questions

- Permanent registered media type
- Numeric security limits
- ZIP64 requirements
- Persistent logical fingerprint
- External resource links
- Compact handwriting encoding
- Advisory-lock metadata
- Digital signatures
- Encryption
- Exact lexical preservation of unknown JSON
- Formal salvage and repair format
- Future sync hash boundaries
- Exact ZIP and JSON dependencies

## Storage and File Format Open-Source Record

- Rnote is GPL-3.0-or-later and offers useful persistence concepts, but its format should not be adopted wholesale.
- Xournal++ is currently identified as GPL-2.0; direct code reuse requires file-level and dependency licensing review.
- ODF provides useful ZIP-package concepts without requiring AL NOTE to adopt ODF schemas.
- SQLite is public domain but is not selected as the canonical format.
- Dart `archive` is MIT and remains a prototype candidate.
- `json_serializable` is BSD-3-Clause and may only be used with explicit unknown-field preservation.
- Freezed is MIT and is only an optional implementation aid.
- Protocol Buffers and FlatBuffers are rejected for canonical version-1 records.
- No storage dependency is accepted yet.

## Deferred Autosave and Recovery Questions

- Exact recovery artifact encoding
- Native and Web storage backend
- Exact debounce and maximum-latency values
- Checkpoint frequency and journal-size thresholds
- Lease renewal and stale-owner timing
- Recovery retention periods
- Storage-pressure cleanup limits
- Persistent logical document fingerprints
- Canonical automatic-saving preference
- Encryption and OS-backup policy
- Exact Dart and Web dependencies

## Autosave and Recovery Open-Source Record

- Xournal++ provides useful handwriting autosave concepts, but direct reuse requires licensing review.
- Krita demonstrates separate autosave files, recovery for saved and unsaved documents, and restoring recovered work as modified.
- LibreOffice demonstrates separation of AutoRecovery from normal saving.
- SQLite WAL provides useful commit and checkpoint concepts, and SQLite is public domain.
- No recovery implementation dependency is accepted.

## Roadmap

The Drawing Tool System subsystem is next.
