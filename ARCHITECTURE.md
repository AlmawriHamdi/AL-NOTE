# AL NOTE Architecture

This document records architecture approved by the Main Architect, the subsystem roadmap, and the stable decision ledger.

## Subsystem Status

| Subsystem | Status | Notes |
|---|---|---|
| Object System | Accepted with modifications | Defines the persistent, platform-independent page-object model |
| Layer System | Accepted with modifications | Owns layer structure, object membership, and ordering |
| Selection and Transform System | Next subsystem | Will define selection and transform behavior |

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

## Roadmap

The Selection and Transform System is the next subsystem.
