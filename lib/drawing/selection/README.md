# Selection and Transform System

**Status:** Accepted with modifications

## Purpose

The Selection and Transform System provides temporary, page-scoped selection and transformation without placing interaction state inside persistent document objects.

It:

- Resolves point, rectangle, and lasso selection
- Maintains temporary selection state
- Calculates selection geometry and affordances
- Previews movement, resizing, and rotation
- Enforces capabilities, visibility, locking, and boundaries
- Produces atomic requests for the future Command System

## State Ownership

Selection state belongs to the active page-editing session.

It may contain:

- Active Page ID
- Ordered selection targets
- Primary target
- Selection revision
- Selection operation mode
- Optional transform session
- Derived bounds and overlay geometry

Selection state must never be:

- Stored inside objects
- Stored inside layers
- Serialized
- Treated as document content

Only one Page may have an active editable selection at a time.

## Selection Target Identity

Selection target identity uses:

- Page ID
- Object UUID
- Optional sub-target kind
- Optional sub-target ID

Layer ID may be cached only as resolved session metadata. It is not permanent identity and must be refreshed after layer movement.

A persistent object revision field is not required yet.

## Handwriting Stroke Selection

The initial system must support:

- Whole-object selection
- Individual handwriting-stroke selection
- Multiple-stroke selection
- Lasso selection of strokes

Each handwriting stroke requires a stable sub-element ID within its containing Handwriting Object.

A selected stroke:

- Remains owned by its Handwriting Object
- Is not a separate Page Object
- Is not independently serialized as a Page Object
- Does not own layer membership

Transforming selected strokes produces one replacement revision of the containing Handwriting Object.

The Selection System identifies selected stroke IDs but does not directly edit handwriting payload data.

The Handwriting Object handler:

1. Validates the selected stroke IDs.
2. Applies the proposed transform to those strokes.
3. Produces a candidate replacement Handwriting Object.
4. Preserves unselected strokes.
5. Returns the replacement for atomic Command execution.

Text ranges, shape nodes, image regions, and other sub-target types remain deferred.

## Selection Lifecycle

1. A tool provides semantic page-coordinate selection intent.
2. The Selection System queries hit testing.
3. Hidden, locked, unsupported, and stale candidates are excluded.
4. The selection is replaced, added to, removed from, or toggled.
5. Targets are resolved against the latest Page state.
6. Derived bounds and overlays are calculated.
7. A transform session captures immutable base states.
8. Preview remains temporary.
9. Commit submits one atomic Command request.
10. Cancel discards the preview without document mutation.

## Point Selection

- Viewport conversion produces Page coordinates.
- Broad-phase and precise hit testing are used.
- The topmost eligible target is selected according to layer and object order.
- Empty-space selection clears the selection unless the tool requests preservation.
- Overlap cycling is deferred.

## Rectangle and Lasso Selection

Both support:

- Containment
- Intersection

Initial defaults:

- Rectangle: containment
- Whole-object lasso: containment
- Handwriting-stroke lasso: precise stroke intersection or a handler-provided selection threshold

Broad-phase bounds may reject obvious misses, but final selection uses precise geometry.

## Multi-Selection

Selection may span multiple ordinary layers on the same Page.

Selection may not span multiple Pages.

Transforms must:

- Preserve each object’s layer membership
- Preserve object order
- Avoid temporary persistent groups
- Apply one shared page-space operation
- Commit all resulting replacements atomically

A shared transform affordance is enabled only when every selected target supports that operation.

The system must not silently transform only the capable subset.

## Transform Model

The system exposes controlled operations:

- Translation
- Rotation around a page-space pivot
- Positive scaling around a page-space pivot
- Optional uniform scaling
- Optional axis constraints

Matrices may be used internally.

The initial system does not support:

- Negative scaling
- Reflection
- Zero or near-zero scale
- Skew or shear
- Perspective transforms
- Non-finite values
- Unsafe magnitudes

Exact persistent transform encoding remains deferred.

## Preview and Commit

A transform preview contains:

- Captured base Page and object states
- Selected target IDs
- Proposed page-space operation
- Pivot and constraints
- Candidate replacements or transforms
- Validation state
- Old and new damage bounds

Persistent document data remains unchanged during preview.

Commit submits one all-or-nothing request to the future Command System.

A stale target or failed validation rejects the complete transform. The system must never commit only a valid subset.

## Capabilities and Locking

- `Selectable` is required for normal object selection.
- `Movable`, `Resizable`, and `Rotatable` govern transform affordances.
- Type handlers may provide additional constraints.
- Hidden objects are excluded.
- Locked objects and objects in locked layers are excluded.
- Layer locking overrides object capabilities.
- A future read-only inspection mode may inspect locked or unknown objects, but it is not part of normal editable selection.

## Page Boundaries

Partial overflow outside fixed Page boundaries is allowed.

A committed transform must retain a valid recoverable intersection with the Page.

Rendering and export remain clipped to Page boundaries.

Objects must not become completely unreachable through an ordinary transform.

## Unknown Objects

Unknown objects remain preserved and inert.

They:

- Do not expose transform handles
- Cannot be moved, resized, rotated, erased, or geometry-edited
- May later be inspectable read-only when safe bounds exist
- Must not treat bounds-only data as proof that transformation is safe

## Reconciliation

- Deleted target: remove it.
- Hidden target: remove it.
- Newly locked target: remove it and cancel active transforms.
- Target moved between layers: retain it if eligible and refresh layer metadata.
- Object replacement with the same UUID: retain it if still selectable.
- Capability change: recalculate affordances.
- Page removal: clear selection.
- Revision mismatch: reject the complete commit.
- Invalid geometry: preserve the document but exclude transformation.
- Non-finite preview: reject the update and retain the last valid preview.

## Rendering Boundaries

Selection outlines, handles, pivots, lasso paths, and previews are temporary overlays.

Use:

- Interaction bounds for point-selection tolerance
- Precise geometry for rectangle and lasso selection
- Visual bounds for visible frames and handles
- Page-axis-aligned aggregate frames for initial multi-selection

Selection changes invalidate overlays only.

Successful commits invalidate persistent rendering and hit-test caches for old and new authoritative bounds.

## Dependency Direction

- Tools provide semantic intent.
- Viewport performs coordinate conversion.
- Hit Testing supplies candidates.
- Object Type Registry supplies capabilities, geometry, and validation.
- Layers resolve membership, visibility, locking, and order.
- Selection prepares temporary previews and Command requests.
- Commands alone mutate persistent document state.
- Rendering consumes selection state read-only.
- Documents must not depend on Selection.

## Deferred Matters

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

## Open-Source Record

- Rnote is GPL-3.0-or-later; adapt note-oriented selection concepts.
- Xournal++ is GPL-2.0-or-later; direct reuse requires file and dependency auditing.
- Krita provides useful transform-session and preview concepts, but its advanced transformation scope is excessive for AL NOTE.
- Flutter transformation primitives may support viewport and temporary UI mechanics but do not replace the document Selection System.
- Dart `vector_math` may be reused behind AL NOTE-controlled transform validation contracts.
