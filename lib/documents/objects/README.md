# Object System

**Status:** Accepted with modifications

## Purpose

The Object System defines the persistent, platform-independent model for everything placed on a page, including handwriting, text, images, shapes, PDFs, and future plugin-defined objects.

## Common Object Data

Every object has:

- Document-unique UUID
- Permanent namespaced type key
- Type schema version
- Local-to-page transform
- Object visibility
- Object locking
- Restricted common metadata
- Type-specific payload
- Forward-compatible extension data

Objects do not store:

- Selection state
- Hover state
- Parent page references
- Parent layer references
- Z-index
- Screen coordinates
- Platform rendering objects
- Authoritative rendering caches

## Ownership

- The Object System owns object identity, type identity, common persistent state, payload boundaries, transforms, and validation contracts.
- Object types own intrinsic geometry, payload validation, and schema migrations.
- The Layer System owns membership and ordering.
- The Drawing Renderer owns rendering execution.
- The Hit-Testing System owns hit-testing execution.
- The Storage System owns encoding, decoding, and migration orchestration.
- The Command System later owns applying and reversing object replacements.
- The Plugin System later owns plugin loading, trust, permissions, and registration lifecycle.

## Editing Model

Object state is externally immutable and replacement-oriented.

Editing creates a new object revision with the same Object ID.

Structural sharing and copy-on-write storage are allowed so large handwriting payloads do not require full copying.

## Geometry

Objects use intrinsic local geometry combined with a local-to-page transform.

Exact transform encoding is deferred.

Authoritative page bounds are calculated rather than stored.

Rebuildable cached bounds are allowed but are never persistent source data.

## Registries

Separate registries are keyed by the same object type key.

### Object Type Registry

The Object Type Registry provides:

- Validation
- Capabilities
- Schema support
- Migrations
- Intrinsic geometry contracts

### Rendering Registry

The Rendering Registry provides rendering adapters.

### Hit-Testing Registry

The Hit-Testing Registry provides precise hit-testing adapters.

The core Object System must not depend on rendering or hit-testing implementations.

## Locking and Visibility

Effective locking combines object and layer locking.

Effective visibility combines object and layer visibility.

Locked objects remain rendered and exported but cannot normally be edited or erased.

Hidden objects remain stored but are excluded from normal rendering, export, hit testing, selection, and erasing.

## Unknown Objects

Unknown or unavailable object types must:

- Remain stored
- Preserve their IDs and type keys
- Preserve their original payload and extension fields
- Remain inert
- Display a safe placeholder when appropriate
- Never execute embedded data
- Never be silently deleted or converted

## Duplication

Duplicated objects receive new UUIDs.

Internal references must be remapped.

Clipboard paste positioning is outside the Object System.

## Hit Testing

Hit testing operates in page coordinates.

Screen-space interaction tolerance is converted into page units through the Viewport.

## Grouping

Grouping is deferred.

Do not create a `composite/` folder or define group ownership yet.

## Deferred Questions

- Exact transform encoding
- Numeric precision and coordinate limits
- Common metadata fields
- Group ownership and nesting
- Image and PDF resource references
- Exact serialization format
- Plugin packaging and security
- Synchronization provenance
