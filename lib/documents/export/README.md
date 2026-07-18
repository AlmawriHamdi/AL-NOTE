# Export System

Status: **Accepted with modifications**

## Purpose

The Export System coordinates immutable, safe, privacy-aware output generation without mutating AL NOTE documents.

It owns:

- Export scope planning
- Immutable Export Snapshots
- Export Plans and preflight
- Temporary-output coordination
- Safe destination publication
- Progress and cancellation
- Structured failure and degradation reports
- Privacy-safe metadata policy
- Exporter registry contracts
- Restricted plugin-exporter contracts

It does not own:

- `.alnote` Save or Save As
- PDF construction or sanitization internals
- Image encoding internals
- Document mutation
- Command execution
- Rendering backends
- Platform picker UI
- File sharing implementation
- Plugin loading or sandboxing
- Synchronization or cloud storage

## Operation Boundaries

- Save and Save As `.alnote` belong to Storage.
- Export to PDF, PNG, or JPEG belongs to Export.
- PDF construction and sanitization remain owned by PDF.
- Sharing completed output belongs to platform adapters after Export.

Share is not an export format.

## Version-1 Formats

Guaranteed version-1 export formats are:

- PDF — `alnote.format.pdf`
- PNG — `alnote.format.png`
- JPEG — `alnote.format.jpeg`

Stable identifiers use the `alnote.format.*` namespace.

## Export Pipeline

The conceptual pipeline is:

Requested export scope
→ Immutable Export Snapshot
→ Export Plan and preflight
→ Rendering or PDF assembly
→ Temporary output
→ Verification
→ Safe destination publication
→ Structured result report

## Export Scopes

Supported scopes include:

- Entire notebook
- Current Section
- Selected Pages
- Current Page
- Selected Objects on the current Page
- Explicit ordered Page list

Selected-object export is Page-scoped in version 1 because accepted Selection state is Page-scoped.

Page ordering is explicit and stable for the job.

## Immutable Export Snapshot

Every export uses one immutable document revision.

The snapshot resolves:

- Export scope
- Page order
- Persistent Objects and Layers
- Resources
- Visibility and export participation
- Renderer and type-handler set
- Format-specific requirements
- Privacy policy

Live edits do not change an export already in progress.

The job pins its resolved renderer and type-handler set for its lifetime.

Runtime handler availability is not persistent document data.

## Export Plan and Preflight

Preflight occurs before expensive work.

It validates:

- Scope
- Document revision
- Page dimensions
- Required resources
- Handler availability
- Output format
- Destination capabilities
- Estimated output size
- Memory and pixel budgets
- Raster dimensions
- Metadata policy
- Degradation requirements

Unsupported renderers fail by default.

Silent omission of content is forbidden.

## Document and History Boundary

Export is not a document mutation.

Export:

- Does not enter Command History
- Does not alter the dirty state
- Does not modify resources
- Does not modify Objects, Pages, Layers, or ordering
- Does not change the source PDF
- Does not enter Recovery as document state

## PDF Boundary

Export coordinates the job.

The PDF System retains ownership of:

- PDF construction
- PDF sanitization
- Safe source-content reuse
- Coordinate mapping
- Font and image embedding
- Unsafe-action removal
- Signature-claim removal
- Vector preservation
- Bounded raster fallback

The original PDF resource is never modified during export.

## Raster Export

PNG is the default raster format.

JPEG always requires an explicit opaque background.

JPEG defaults to white when no other background color is selected.

Raster export:

- Keeps Page clipping enabled
- Uses screen-independent resolution
- Supports DPI or exact pixel dimensions
- Defaults to 144 DPI
- Validates memory and output size before rendering
- Strips sensitive metadata by default

Zoom level and screen resolution do not define export resolution.

## Multipage Raster Export

Multipage raster export defaults to one output file per Page.

It:

- Preserves Page order
- Uses safe sanitized filenames
- Publishes each file through its own temporary-output operation
- Reports the result for every file

Separate files are not globally atomic.

If some files publish before another fails, the result reports structured partial publication.

ZIP may be offered when the destination accepts only one artifact.

A ZIP artifact may receive atomic publication where supported.

ZIP limits include:

- Entry count
- Path safety
- Expansion
- Compressed and uncompressed size
- Processing time

## Temporary Output and Publication

Output is first written to safe temporary storage.

Before publication:

- Output completion is verified
- Expected artifact count is checked
- Size limits are checked
- Format-specific validation runs where available
- Cancellation is rechecked

Safe destination commit is used where the platform supports it.

Browser downloads must not be described as atomically replacing existing files.

Export cancellation before destination commit leaves that destination unchanged where the adapter supports transactional publication.

## Platform Adapters

Platform adapters expose capabilities for:

- Creating output destinations
- Creating temporary output
- Safely committing output
- Selecting folders where supported
- Sharing completed files
- Reporting platform limitations

The shared Export System does not assume filesystem paths on Android or Web.

Linux provides export-to-file or export-to-folder because file sharing is not universally available.

Platform adapters expose capabilities, not conversion policy.

## Cancellation

Cancellation is cooperative.

On cancellation:

- Stop pending rendering or assembly where practical
- Reclaim temporary resources
- Do not commit untouched destinations
- Report any artifacts already published
- Return a stable structured cancellation result

Atomic publication either completes or rolls back where supported.

## Failure and Degradation

Failures use stable structured error codes.

Results distinguish:

- Success
- Cancellation
- Validation failure
- Handler unavailable
- Rendering failure
- Resource failure
- Destination failure
- Partial publication
- Degraded output

Degraded output requires authorization and a structured report.

Unsupported content is not silently omitted.

## Privacy Defaults

Default exports exclude:

- Internal UUIDs
- Source filesystem paths
- Original filenames unless requested
- Image EXIF
- GPS data
- Device identifiers
- Import timestamps
- PDF active content
- Original signature claims
- Plugin-private metadata

Author metadata is opt-in.

Export reports which metadata policy was applied.

## Plugin Exporters

Plugin exporters remain declarative and constrained.

They cannot:

- Mutate documents
- Publish Commands
- Select unrestricted destinations directly
- Access networks without separate authorization
- Bypass limits
- Access native renderers directly
- Replace built-in identifiers
- Publish output outside the central destination service
- Read plugin-private data belonging to another plugin
- Execute document content

Plugin output is bounded, validated, and published centrally.

## Security and Limits

Configurable limits apply to:

- Output artifact count
- Export Page count
- Export dimensions
- Total pixels
- Metadata size
- Archive entries and expansion
- Temporary storage
- Memory
- Processing time
- Concurrent jobs
- Plugin output
- Filename length
- PDF complexity

Temporary output is private and reclaimed.

Destination filenames are sanitized.

## Dependency Status

No external Export dependency is accepted.

Every future dependency and bundled binary requires pinned transitive-license, security, maintenance, and platform audits.

## Open-Source Record

Candidates only:

- Flutter `file_selector`
- `file_picker`
- `share_plus`
- Dart `image`
- Dart `archive`
- Dart `pdf`
- `pdfrx` and PDFium
- PDF.js
- qpdf
- Rnote
- Xournal++
- libvips
- ImageMagick
- `flutter_svg`

No candidate is accepted by this architecture.

## Deferred Matters

- Additional export formats
- Cloud destinations
- Remote publication
- Advanced export presets
- Editable PDF annotation export
- PDF archival conformance
- SVG export
- Animated output
- Global atomicity for multiple separate files
- Exact sharing dependency
- Exact picker dependency
- Exact image encoder dependency
- Exact PDF composer dependency
- Recognition-aware export
- Sync-integrated export
