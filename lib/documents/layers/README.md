# Layer System

**Status:** Accepted with modifications

## Purpose

The Layer System provides the authoritative structure:

**Page → ordered layers → ordered objects**

It owns:

- Layer identity and persistent common state
- Page-to-layer ownership
- Layer order
- Object membership
- Object order inside layers
- Safe movement between layers
- Effective layer visibility and locking
- Layer lifecycle and validation

It does not own rendering, selection interaction, undo history, storage encoding, plugin loading, or UI state.

## Persistent Layer Contract

Each layer contains:

- Document-unique Layer UUID
- Permanent namespaced type key
- Type schema version
- User-visible name
- Core role
- Visible state
- Locked state
- Opacity from 0 to 1
- Immutable-facing ordered object values
- Versioned type-specific data
- Forward-compatible extension data

Layers do not contain:

- Active-layer state
- Selection state
- Numeric layer index
- Object z-index
- Rendering caches
- Dirty regions
- Platform graphics objects
- Export policy

Export policy is deferred to the Export System.

## Ownership and Ordering

- A Page exclusively owns its ordered layers.
- A Layer belongs to exactly one Page.
- A Layer directly owns its ordered object values.
- An Object belongs to exactly one Layer.
- Objects do not reference their Page or Layer.
- Collection position is the only authoritative order.
- Numeric z-indexes are not stored.
- Derived indexes are allowed but remain rebuildable and non-authoritative.
- Layer and object collections are immutable-facing and replacement-oriented.
- Structural sharing and copy-on-write behavior are permitted.

## Layer Roles

Core roles are restricted to:

- `content`
- `backgroundSource`
- `pdfSource`

Plugin-defined layer types must map to one core-understood role.

Plugins may not introduce unknown core ordering roles.

Handwriting, text, image, and shape are not restrictive layer types. Ordinary content layers may contain mixed object types.

## Minimum Content Layer

Every Page must contain at least one content-capable layer.

That layer may be hidden or locked.

Another layer is not automatically created merely because all content layers are hidden or locked.

Deleting the final content layer is permitted only as one atomic operation that creates a replacement empty content layer.

## Visibility and Locking

Effective object visibility is:

`object.visible AND layer.visible`

Effective object locking is:

`object.locked OR layer.locked`

Layer state never overwrites object-level state.

A locked layer:

- May be shown or hidden
- May be renamed
- May be reordered
- May be duplicated
- Rejects insertion, removal, replacement, and reordering of contained objects
- Cannot be cleared or deleted until explicitly unlocked

Hidden layers remain stored.

## Object Movement

Moving objects between layers is one atomic Page-state transition.

A move must:

1. Confirm source ownership.
2. Confirm destination acceptance.
3. Remove the object once from the source.
4. Insert it once into the destination.
5. Preserve Object ID and object state.
6. Publish one coherent replacement Page state.

Failure leaves the original Page unchanged.

Locked source or destination layers reject ordinary movement.

## Layer Deletion

Deleting an unlocked layer removes its complete contained object subtree.

The Command System must retain that subtree for undo and restoration.

Contained objects must not be silently moved elsewhere.

Restoration should preserve original IDs and ordering whenever possible.

## Duplication

Ordinary layer duplication creates:

- New Layer UUID
- New UUIDs for all contained objects
- Preserved relative object order
- Copied common and type-specific state
- One old-ID-to-new-ID remapping table

Source-layer duplication is not an ordinary layer operation. Background or PDF source layers are copied only through an appropriate page-level operation.

## Background and PDF Source Layers

- At most one background source layer may exist per Page.
- At most one PDF source layer may exist per Page.
- Their canonical order is:

  1. Background source
  2. PDF source
  3. Content layers

- Source layers remain below content layers.
- PDF source layers reference original PDF content but do not own the original bytes.
- PDF annotations remain editable objects in content layers.
- Background sources may reference colors, paper patterns, templates, or images.
- Exact source-binding and resource ownership is deferred to the PDF, Image, and Storage systems.

## Opacity and Composition

- Opacity is a common layer property.
- It must be finite and between 0 and 1.
- Normal source-over composition is the default.
- Arbitrary blend modes are deferred.

## Active Layer

Active-layer selection is Document Session or UI state.

It is not serialized in the persistent Layer contract.

When a layer is removed, the Layer System reports the structural change. The Document Session chooses a new active layer.

## Unknown Layers

Unknown or unavailable layers must:

- Preserve their common envelope
- Preserve ordered objects
- Preserve type key and schema version
- Preserve opaque type and extension data
- Remain in their original order
- Remain inert when specialized behavior is unavailable
- Never execute embedded data
- Never be silently dropped, flattened, or converted

Data-equivalent round-trip preservation is required. Byte-for-byte preservation is required only if supported by the future file format.

## Invariants

1. Layer IDs are document-unique.
2. Object IDs are document-unique.
3. Every Page has at least one content-capable layer.
4. A Layer belongs to one Page.
5. An Object belongs to one Layer.
6. Ordered collections contain no duplicate IDs.
7. Collection position is authoritative order.
8. Layer type keys are permanent and namespaced.
9. Opacity is finite and between 0 and 1.
10. At most one background source and one PDF source exist per Page.
11. Source layers remain below content layers.
12. Derived indexes must agree with containment or be rebuilt.
13. Nested layers are invalid in the current architecture.
14. Invalid edits fail without partially modifying Page state.

## Deferred Matters

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
