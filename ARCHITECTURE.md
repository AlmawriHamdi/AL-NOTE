# AL NOTE Architecture

This document records architecture approved by the Main Architect, the subsystem roadmap, and the stable decision ledger.

## Subsystem Status

| Subsystem | Status | Notes |
|---|---|---|
| Object System | Accepted with modifications | Defines the persistent, platform-independent page-object model |
| Layer System | Accepted with modifications | Owns layer structure, object membership, and ordering |
| Selection and Transform System | Accepted with modifications | Owns temporary page-scoped selection and transform previews |
| Command, Undo, and Redo System | Next subsystem | Will own persistent document mutations and history |

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

## Roadmap

The Command, Undo, and Redo System is the next subsystem.
