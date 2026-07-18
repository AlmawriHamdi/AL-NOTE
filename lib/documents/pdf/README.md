# PDF System

Status: **Accepted with modifications**

## Central Rule

Original PDF bytes remain immutable resources.

All new editable annotations remain ordinary AL NOTE Page Objects stored separately from the source PDF.

## Purpose

The PDF System provides secure, engine-neutral PDF viewing, import, annotation, page referencing, extraction, and export boundaries across Linux, Windows, Android, and Web.

It supports:

- Standalone PDF documents
- PDF source layers
- Movable PDF Page Objects
- Shared immutable PDF resources
- Editable AL NOTE annotations
- Safe rendering and extraction contracts
- Sanitized PDF export

It does not implement a PDF parser or renderer from scratch.

## Persistent Concepts

Persistent PDF concepts are:

- Standalone PDF document binding
- Shared `PdfPageReference`
- PDF source-layer binding
- Movable PDF Page Object payload
- Immutable generic PDF resource
- Ordinary AL NOTE annotation Objects

Derived-only concepts include:

- Backend document handles
- Decryption state
- Rendered tiles
- Thumbnails
- Display lists
- Extracted text
- Links
- Outlines
- Accessibility interpretations
- Backend diagnostics
- Decoded fonts and images
- Render and extraction caches

## Standalone PDF Documents

A standalone PDF uses the existing Standalone PDF document form.

Its document-level PDF binding identifies one immutable source resource.

Each displayed source page becomes an ordinary AL NOTE Page containing:

- One constrained PDF source layer
- One or more editable layers above it
- Editable AL NOTE annotation Objects
- A stable source-page reference

Reordering, duplicating, or deleting AL NOTE Pages does not change the original PDF resource.

Notebook-imported PDF pages do not require the notebook itself to become a PDF document.

## Shared Page Reference

Source layers and movable PDF Page Objects share one versioned `PdfPageReference`.

It contains:

- Its own shared-reference schema version
- PDF resource UUID
- Zero-based source page index
- Selected page-box kind
- Resolved source box coordinates in PDF user space
- Effective normalized rotation
- Displayed width and height in PDF points
- Preserved unknown fields

The resolved source box is persisted so different PDF backends cannot silently shift annotation coordinates.

The reference does not contain:

- Resource hash
- Media type
- Encoded byte size
- Password
- Backend handle
- Rendered data
- Object UUID
- Layer UUID
- Rendering intent

Resource hashes and generic metadata remain in the Resource manifest.

## PDF Source Layer

The stable source-layer binding identity is:

`alnote.pdf.source`

A PDF source layer:

- References exactly one PDF page
- Is constrained below editable content layers
- Fills its AL NOTE Page
- Is normally locked
- May be hidden without deleting annotations
- Cannot be freely moved, rotated, skewed, or resized
- Uses its source reference to establish default Page dimensions

The Layer System continues to own:

- Layer UUID
- Layer ordering
- Visibility
- Locking
- Opacity
- Lifecycle
- Object membership

The PDF System owns only the PDF-specific binding payload and interpretation.

Version-1 source mapping, page box, rotation, and dimensions remain fixed after Page creation.

Automatic annotation remapping is not implemented.

## Movable PDF Page Object

The built-in movable PDF page Object identity is:

`alnote.pdf.page`

The Object payload contains:

- One `PdfPageReference`
- Optional normalized clipping rectangle
- Preserved unknown type-specific fields

The common Object envelope owns:

- Object UUID
- `typeSchemaVersion`
- Common transform
- Visibility
- Locking
- Common metadata

The payload does not duplicate `typeSchemaVersion`.

Movement, scaling, and rotation use the common Object transform.

One selected source page creates one movable Object.

Selecting multiple source pages creates multiple independent Objects.

Multipage movable container Objects remain deferred.

## PDF Coordinates

Canonical PDF-local units are PDF points:

- 72 points per inch
- Top-left origin
- Positive X rightward
- Positive Y downward
- Effective Page rotation already applied
- Width and height represent displayed orientation

This local convention does not redefine AL NOTE's global coordinate precision policy.

All coordinate values must be finite and bounded.

## Page Boxes

Version-1 default selection is:

1. Use a valid CropBox.
2. Otherwise use a valid MediaBox.

Supported identifiers may include:

- CropBox
- MediaBox
- TrimBox
- BleedBox
- ArtBox

The page reference persists:

- Selected box kind
- Resolved source-user-space box coordinates
- Effective normalized rotation
- Displayed width and height

A persisted reference never silently substitutes a different box.

Irreconcilable backend disagreements are rejected or isolated.

Alternative boxes may be selected only through later accepted behavior.

## Fixed Source Mapping

Version-1 source-layer page mapping, selected box, rotation, and dimensions remain fixed after Page creation.

Later source remapping requires separately designed annotation-preservation architecture.

The system must not automatically reinterpret existing annotation coordinates against a different PDF page box or rotation.

## Resource Sharing and Duplication

Multiple Pages, source layers, and movable PDF Page Objects may reference the same immutable PDF resource.

Duplicating a Page or Object creates new Page, Layer, or Object identities without duplicating resource bytes.

The Resource System owns:

- Resource UUIDs
- Content hashes
- Retention
- Reachability
- Reclamation
- Deduplication policy

Deleting one reference does not delete bytes reachable from another owner, recovery generation, or active write.

## Native PDF Annotations

Existing native PDF annotations:

- Remain preserved in the immutable original bytes
- Are read-only in AL NOTE
- Render only through safe existing appearances
- Are not automatically converted into AL NOTE Objects
- Must not render twice

Missing or unsafe appearances produce a warning or placeholder instead of executing annotation behavior.

New AL NOTE annotations remain independent editable Objects.

## Forms and Active Content

Version 1:

- Renders safe existing form appearances only
- Does not edit AcroForm or XFA fields
- Never executes JavaScript
- Never performs submit, import, reset, launch, file, or shell actions
- Does not execute multimedia or 3D content
- Does not automatically extract or launch embedded files
- Does not access external network resources while parsing or rendering
- Treats internal links as validated navigation metadata
- Requires explicit policy for external HTTP or HTTPS links
- Blocks file, shell, launch, and custom executable URI schemes

Executable and interactive PDF content remains inert.

## Passwords and Encryption

PDF passwords:

- Exist only in the active session
- Are never persisted
- Are never logged
- Never enter Commands
- Never enter Recovery
- Never enter document history
- Never enter disk caches
- Must be re-entered after restart
- Create temporary backend unlock sessions
- Use bounded attempt handling

Unsupported encryption produces a stable unsupported state.

AL NOTE annotations remain preserved while the source PDF is locked.

Export requests the password again when source access is necessary.

Password persistence and output encryption remain deferred.

## Rendering Contract

PDF rendering uses engine-neutral contracts.

A render request may contain:

- Resource-access capability
- Source page index
- Resolved page box
- Effective rotation
- Requested normalized region or tile
- Output dimensions
- Device scale
- Background and alpha policy
- Native-appearance inclusion mode
- Color intent
- Cancellation token
- Processing budget

A render result contains:

- Approved pixel buffer or neutral surface
- Exact rendered region
- Output dimensions and format
- Structured success, cancellation, or failure
- Backend identity for diagnostics only

Persistent PDF data never contains backend document or rendering handles.

## Caching

Derived cache keys may use:

- Resource content identity
- Source page index
- Resolved box and rotation
- Tile or normalized region
- Output dimensions
- Color intent
- Native-appearance mode
- Backend compatibility version

Rendered tiles, thumbnails, display lists, decoded fonts, decoded images, and backend handles remain derived.

Rendering caches remain under Drawing cache ownership.

## Extraction Boundaries

Separate engine-neutral capabilities cover:

- Rendering
- Text extraction
- Link extraction
- Outline extraction
- Accessibility information

Extracted information is derived and advisory.

Reading order may be unreliable.

Extracted text never silently becomes editable document content.

All extracted geometry maps through the same normalized PDF coordinate system.

OCR, corrected reading order, and search indexing remain separate future systems.

## Links

Validated internal links may be exposed as navigation metadata and recreated during export.

External HTTP and HTTPS links require explicit user and export policy.

The following remain blocked:

- File links
- Shell actions
- Launch actions
- Custom executable URI schemes
- Unsafe embedded destinations

Link extraction never executes an action.

## Import Contracts

Version 1 supports:

1. Open as a standalone PDF.
2. Import selected PDF pages as new notebook Pages.
3. Insert selected source pages as movable PDF Page Objects.

Preparation may run asynchronously.

Atomic publication includes every required:

- Resource
- Document binding
- Page
- Layer
- Object
- Page reference

Cancellation, failure, stale state, or rejection publishes no partial document mutation.

The full immutable source PDF may be shared by all imported pages.

PDF resource subsetting remains deferred.

## Normal PDF Export

Normal version-1 export:

- Always creates a new PDF
- Never modifies the original resource
- Reuses safe original vector page content where possible
- Adds AL NOTE content as flattened page content
- Flattens safe native annotation appearances exactly once
- Omits unsafe native annotation dictionaries and actions
- Embeds required fonts and images
- Uses vector output where supported
- Uses bounded raster fallback only where required
- Reports degraded output
- Does not silently lose Pages or annotations

Normal export sanitizes instead of copying the entire original PDF catalog.

## Export Sanitization

Normal export omits:

- JavaScript
- Launch actions
- Form actions
- Embedded files
- Multimedia
- 3D actions
- Unsafe external references
- Unsupported interactive forms
- Unsupported native annotation dictionaries
- Original digital-signature claims

Output encryption is not inherited automatically.

External HTTP and HTTPS links require explicit export policy.

Editable native annotation export and output encryption remain deferred.

## Digital Signatures

Original signed PDF bytes remain preserved as an immutable `.alnote` resource.

Any export containing added, removed, reordered, flattened, or overlaid content is a new document.

Normal export must not claim that original signatures remain valid.

Digital-signature creation and validation remain deferred.

## Missing or Invalid Resources

PDF Pages, source layers, Objects, dimensions, references, and annotations remain preserved when the source is:

- Missing
- Hash-mismatched
- Locked
- Unsupported
- Corrupt
- Invalidly referenced
- Quarantined
- Over processing limits
- Unavailable through the current backend

Stable placeholders preserve:

- Page or Object identity
- Source page index
- Expected dimensions
- Layer membership
- Common transform
- Annotations
- Resource reference

Annotations are never deleted because their PDF source is unavailable.

## Commands and History

Commands control persistent:

- Resource insertion
- Document binding
- Page creation and deletion
- Layer binding
- Movable Object insertion
- Movable Object crop changes
- Annotation changes
- Persistent PDF reference changes

Password entry, rendering, extraction, links, previews, backend sessions, and caches do not enter history.

Undo and redo restore exact prior resources, Pages, Layers, Objects, ordering, references, and unknown data.

## Plugin and Backend Boundaries

Backends and plugins:

- Use engine-neutral contracts
- Cannot store engine handles persistently
- Cannot execute PDF actions
- Cannot bypass validation or resource limits
- Cannot publish persistent mutations directly
- Cannot obtain unrestricted filesystem access
- Cannot obtain unrestricted network access
- Cannot silently reinterpret page references
- Must support cancellation
- Must return structured failures

Application composition selects approved backend adapters.

## Security and Limits

Configurable limits apply to:

- Encoded bytes
- Page count
- Page dimensions
- Total Page area
- Render pixels
- Concurrent renders
- Memory
- Processing time
- Extracted glyph count
- Annotation and form count
- Object graph depth
- Images and decoded image bytes
- Fonts and decoded font bytes
- Decompression ratio
- Cross-reference depth
- Incremental-update depth
- Embedded-file count and bytes
- Password attempts
- Export complexity

Parsing, rendering, and extraction should run outside the UI isolate and in killable or sandboxed workers where practical.

Untrusted PDF bytes are treated as hostile input.

## Serialization

- Original encoded PDF bytes remain immutable resources.
- Resource references use UUIDs.
- The Resource manifest owns hashes and generic media metadata.
- `PdfPageReference` has its own shared-reference schema version.
- Source-layer binding identity is `alnote.pdf.source`.
- Movable Page Object identity is `alnote.pdf.page`.
- The common Object envelope owns Object `typeSchemaVersion`.
- Coordinates and dimensions are finite and bounded.
- Box kind and resolved coordinates are persisted.
- Effective rotation and displayed dimensions are persisted.
- Safe unknown fields remain preserved.
- Backend handles, passwords, rendering data, and extracted data are never serialized.
- Unsupported newer data remains preserved and inert when necessary.

## Folder Ownership

`lib/documents/pdf/` conceptually owns:

- Persistent PDF bindings
- Shared PDF page references
- Coordinate contracts
- Rendering request and result contracts
- Extraction contracts
- PDF-specific import and export contracts
- Security and password-session contracts
- Backend interfaces
- Backend capability descriptions

No implementation subfolders are defined yet.

Platform implementations remain behind adapters.

Rendering caches remain in Drawing cache ownership.

General resources remain in Storage ownership.

Layer identity, ordering, locking, visibility, and lifecycle remain owned by the Layer System.

## Dependency Status

AL NOTE must reuse a mature PDF engine rather than implement a parser or renderer.

No PDF backend or export dependency is accepted yet.

## Open-Source Record

- PDFium uses permissive core licensing with bundled third-party notices that require a complete audit.
- PDF.js is Apache-2.0 and is a strong Web backend candidate.
- `pdfrx` is an MIT Flutter wrapper around PDFium and is the leading four-platform integration candidate, subject to binary provenance, security, API, and license audits.
- MuPDF is AGPL or commercial and is rejected as the default unless AL NOTE intentionally accepts the additional AGPL obligations.
- Poppler is a useful desktop reference but not the preferred four-platform default.
- The Dart `pdf` package is Apache-2.0 and is an export-generation candidate, but source-page reuse and sanitization capabilities require testing.
- qpdf is Apache-2.0 and is a content-preserving transformation reference or possible native helper, but it is not a universal Web dependency.
- Rnote is a GPL-3.0-or-later architectural reference.
- Xournal++ is a behavioral reference requiring file-level license review.
- Syncfusion PDF is not an open-source dependency and is rejected.
- No PDF dependency is accepted yet.
- AL NOTE will not implement a PDF parser or renderer from scratch.

## Deferred Matters

- Editable native PDF annotations
- AcroForm and XFA editing
- Digital signatures
- Multipage movable Objects
- OCR
- Corrected reading order
- Search indexing
- PDF/A and PDF/X conformance
- Professional print color management
- Password persistence
- Output encryption
- Incremental modification of original PDFs
- Source-layer box or rotation remapping
- PDF resource subsetting
- Exact backend dependency
- Exact export composer dependency
- Interactive native annotation export
