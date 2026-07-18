# Shape Object System

Status: **Accepted with modifications**

## Purpose

The Shape Object System provides editable, deterministic, vector-quality geometric Page Objects across Linux, Windows, Android, and Web.

## Ownership

The Shape Object System owns:

- Built-in Shape kinds
- Shape payload schemas
- Intrinsic Shape geometry
- Shape-specific appearance
- Validation and normalization
- Shape migration contracts
- Geometry-provider contracts
- Rendering and hit-testing information contracts
- Vector-export descriptions
- Unknown Shape-kind preservation

It does not own:

- Drawing gestures
- Shape Recognition
- Selection UI or handles
- Command execution
- Layer membership or ordering
- Rendering backends
- Text, images, PDFs, or mathematics
- Plugin loading or security
- Flutter or Skia persistent objects

## Type Strategy

Built-in Shapes use one core-controlled Object type key:

`alnote.shape`

Version-1 built-in `shapeKind` identifiers are:

- `line`
- `rectangle`
- `ellipse`
- `polygon`
- `polyline`

A `shapeKind` is a permanent string-based compatibility identifier. It is not a display name, runtime class name, or enum ordinal.

Core AL NOTE exclusively controls built-in `shapeKind` values.

Arrows, rounded rectangles, and circles are variations, not separate persistent Shape kinds.

## Version-1 Geometry

Persistent geometry is:

- Line: start and end points
- Rectangle: local bounds and one optional uniform corner radius
- Ellipse: local bounds
- Polygon: ordered vertices with implicit closure
- Polyline: ordered vertices without implicit closure

A circle is an ellipse whose intrinsic bounds have equal dimensions.

An arrow is a line or polyline with endpoint decorations.

A rounded rectangle remains a rectangle.

Lines, rectangles, and ellipses retain parametric geometry.

Polygons and polylines retain ordered vertices.

The following remain deferred:

- General paths
- Bézier curves
- Splines
- Arcs
- Stars
- Callouts
- Compound paths
- Connectors

Derived paths may be generated for rendering, hit testing, and export, but they are not authoritative persistent data.

## Payload and Versioning

The Shape payload contains:

- Stable `shapeKind`
- Intrinsic geometry
- Explicit stroke record
- Explicit fill record
- Shape opacity
- Preserved unknown type-specific fields

The common Object envelope owns `typeSchemaVersion`.

The Shape payload does not duplicate the schema-version field.

The following are not persisted:

- Derived paths
- Bounds caches
- Tessellation
- Rendering objects
- Selection state
- Screen coordinates
- Parent references
- Layer ordering

## Stroke Style

The backend-neutral stroke record includes an enabled state and may contain:

- Finite RGBA color
- Width in local document units
- Cap
- Join
- Miter limit
- Dash array
- Dash offset

Dash semantics are finite, bounded, deterministic, and platform-independent.

The exact canonical dash encoding remains an implementation-level decision.

## Fill Style

The backend-neutral fill record includes an enabled state and may contain:

- Finite RGBA solid color
- Fill rule: `nonZero` or `evenOdd`

Version 1 supports solid fills only.

Lines and polylines do not paint fills.

Self-intersecting polygons are allowed and use their declared fill rule.

## Opacity

Shape opacity defaults to `1.0`.

Effective opacity is:

`style alpha × Shape opacity × Layer opacity`

No speculative parent opacity is added.

## Rectangle Corner Radius

Version-1 rectangles may use one uniform nonnegative corner radius.

Validation bounds the radius against rectangle geometry.

Per-corner and elliptical corner radii remain deferred.

## Arrowheads

Initial arrowhead kinds may include:

- `none`
- `triangle`
- `open`
- `diamond`
- `circle`

Arrowheads are endpoint decorations on lines or polylines.

They are not separate Objects or geometry kinds.

Default dimensions derive from stroke width and use bounded minimum and maximum values.

Disabled strokes do not render arrowheads.

Cached arrowhead paths are derived and nonpersistent.

Core AL NOTE controls built-in arrowhead-kind identifiers.

## Transform Versus Geometry Editing

Whole-object Selection transforms:

- Update the common Object transform
- Preserve intrinsic Shape geometry
- Preserve Shape style values
- Apply to the composed geometry and appearance
- Do not automatically bake scale into geometry

Direct geometry editing:

- Replaces intrinsic geometry through Commands
- Does not automatically change stroke width
- Does not automatically change dash lengths
- Does not automatically change Shape opacity
- Does not automatically change arrowhead sizing

Direct edits may include:

- Moving a line endpoint
- Changing rectangle bounds
- Changing a rectangle corner radius
- Changing ellipse bounds
- Inserting polygon or polyline vertices
- Moving polygon or polyline vertices
- Removing polygon or polyline vertices

Automatic transform normalization and baking remain deferred.

## Transform Appearance Rule

Whole-object transforms apply to the composed geometry and appearance.

This means a common transform affects the complete rendered Shape, including its stroke and endpoint decorations.

Direct intrinsic-geometry edits leave persistent style values unchanged.

Non-scaling stroke modes remain deferred.

## Bounds

Three bounds remain distinct:

1. Geometry bounds
2. Visual bounds
3. Interaction bounds

Geometry bounds contain intrinsic geometry only.

Visual bounds include:

- Stroke width
- Caps
- Joins
- Miters
- Arrowheads
- Other painted content

Interaction bounds add transient selection tolerance converted from screen space to Page units.

Interaction tolerance is zoom-dependent and never serialized.

Bounds caches are derived and non-authoritative.

## Hit Testing

Hit testing uses:

1. Page-space broad-phase bounds rejection
2. Inverse common transform
3. Local-space precise testing
4. Fill-rule testing
5. Stroke-distance or stroked-outline testing
6. Separate arrowhead testing

Hit-test results may identify:

- Fill
- Stroke
- Endpoint decoration
- Miss

Hit-testing implementations remain in the accepted Drawing subsystem.

Persistent Shape data does not contain hit-test caches or screen-space tolerances.

## Rendering

Rendering contracts receive backend-neutral semantic data:

- Shape kind
- Intrinsic geometry
- Common transform
- Stroke and fill
- Fill rule
- Arrowheads
- Effective opacity
- Clipping and compositing context

Rendering may generate derived paths, outlines, tessellation, or raster caches.

Those derived products never replace persistent Shape geometry.

Flutter `Path`, Flutter `Paint`, Skia objects, and platform rendering objects are adapter details, not persistent data.

## Export

Exporters receive semantic geometry and style where possible.

If an export target cannot express a feature directly, it may convert the Shape into a backend-neutral vector path.

Rasterization is a last resort.

Rasterization never replaces persistent source geometry.

SVG terminology may inform export contracts, but SVG is not AL NOTE's internal Shape model.

## Commands and Persistent Editing

Every persistent Shape change uses a replacement-oriented Command.

Commands replace validated persistent Shape state rather than mutating internal collections in place.

Preview geometry remains temporary and outside storage, recovery, and history until committed.

Rejected or stale Commands produce no persistent change.

## Duplication

Duplicating a Shape:

- Generates a new Object UUID
- Copies intrinsic geometry
- Copies stroke and fill
- Copies Shape opacity
- Copies arrowhead data
- Copies the common transform
- Copies preserved unknown fields

Version-1 vertices do not receive independent identities.

Stable vertex identities remain deferred.

## Degenerate, Unknown, and Unsafe Data

The system distinguishes:

- Valid degenerate geometry
- Recoverably normalizable geometry
- Unsupported but preservable data
- Unsafe data that must remain inert

Rules include:

- Coordinates and numeric values must be finite.
- Measurements must be valid and bounded.
- A polygon normally requires at least three usable vertices.
- A polyline normally requires at least two usable vertices.
- Self-intersecting polygons are allowed.
- Negative rectangle dimensions normalize by reordering bounds.
- Unknown `shapeKind` values are preserved and not interpreted.
- Unknown kinds never become fallback rectangles.
- Unsupported data is not silently converted into another Shape kind.
- Unsafe data is not evaluated.
- Persistent data is not silently discarded.

A stable placeholder may represent preserved unsupported or unsafe Shape data.

## Unknown-Field Preservation

Safe unknown type-specific fields remain preserved in the Shape payload according to Storage rules.

Known-field normalization must not erase preserved unknown fields.

Adjacent migrations must bound data expansion.

Unknown data remains inert when it cannot be safely understood.

## Plugin Boundary

Plugin-defined shapes use their own namespaced Object type keys.

Plugins cannot add private kinds beneath `alnote.shape`.

Plugins may reuse approved public geometry and style contracts through bounded platform-independent data.

Plugin geometry cannot contain:

- Flutter objects
- Skia objects
- Native rendering handles
- Executable content
- Unbounded recursive structures
- A path around validation or Commands

Missing plugins produce preserved unknown Objects.

Plugin loading and security remain owned by the future Plugin System.

## Security and Limits

Configurable safeguards apply to:

- Coordinate magnitude
- Vertex count
- Stroke width
- Dash count
- Dash values
- Arrowhead size
- Unknown payload depth and size
- Migration expansion
- Bounds calculations
- Hit-testing work
- Rendering work
- Export work

Validation occurs before constructing large derived paths, stroked outlines, or tessellations.

Security behavior includes:

- Reject non-finite values.
- Bound geometry-processing time and memory.
- Prevent numeric overflow.
- Prevent unbounded dash or vertex expansion.
- Preserve unsafe payloads inertly when required.
- Never execute Shape content.
- Cancel derived work that exceeds resource budgets.

## Serialization

- The common Object envelope carries `typeSchemaVersion`.
- The Shape payload does not duplicate it.
- Shape serialization uses deterministic UTF-8 JSON.
- `shapeKind` is a stable string.
- Geometry values are finite and bounded.
- Vertex order is authoritative.
- Stroke and fill records are explicit.
- Shape opacity is explicit and bounded.
- Unknown safe fields remain preserved.
- Derived paths, caches, bounds, and tessellation are not serialized.
- Unsupported newer payloads remain preserved and inert when necessary.

## Migration

Shape migrations:

- Operate on the type payload through accepted migration orchestration
- Preserve Object UUID and common envelope state
- Preserve safe unknown fields
- Validate the replacement result
- Bound expansion and processing work
- Never silently convert an unknown kind into a built-in kind
- Never execute embedded content

The original package is not modified in place during migration.

## Folder Ownership

`lib/documents/objects/shape/` conceptually owns:

- Shape payload contracts
- Built-in Shape-kind semantics
- Shape-specific style contracts
- Validation
- Normalization
- Migrations
- Geometry-provider contracts
- Rendering-information contracts
- Hit-testing-information contracts
- Vector-export descriptions
- Unknown Shape-kind preservation

No implementation subfolders are defined yet.

Rendering implementations remain under `lib/drawing/renderer/`.

Hit-testing implementations remain under `lib/drawing/hit_testing/`.

Shared geometry remains under `lib/drawing/geometry/` or another future accepted shared-geometry boundary.

The Shape area does not redefine Drawing Engine architecture.

## Dependency Status

No external Shape or geometry dependency is accepted.

## Open-Source Record

- Rnote is GPL-3.0-or-later and is an architectural reference.
- Xournal++ is displayed as GPL-2.0; direct reuse requires exact file-level licensing review.
- Krita is GPL v3 and is a conceptual reference whose full vector model is too complex for version 1.
- Flutter `Path` and `Paint` are rendering-adapter concepts only.
- Skia is BSD-3-Clause and is a rendering reference, not a persistent-data API.
- SVG provides useful semantic and export terminology but is not AL NOTE's internal file model.
- `vector_math` is BSD-3-Clause and may be evaluated behind AL NOTE-owned geometry contracts.
- `path_parsing` is MIT and may later be evaluated for import and export adapters.
- No external Shape dependency is accepted.

## Deferred Matters

- General and compound paths
- Bézier curves and splines
- Arcs, stars, callouts, and connectors
- Gradients, patterns, textures, and effects
- Per-corner or elliptical rectangle radii
- Stable vertex UUIDs
- Stroke alignment
- Variable-width strokes
- Non-scaling stroke modes
- Boolean geometry
- Parametric constraints
- Text inside shapes
- Recognition-generated shapes
- Transform baking
- Parametric-to-path conversion
