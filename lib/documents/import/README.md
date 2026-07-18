# Import System

Status: **Accepted with modifications**

## Purpose

The Import System safely converts external content into validated AL NOTE document changes.

It owns:

- External source-acquisition contracts
- Content-based format detection
- Import orchestration
- Prepared Import Plans
- Destination planning
- Import progress and cancellation
- Structured failure reports
- Importer registry contracts
- Restricted plugin-importer contracts

It does not own:

- `.alnote` Open, Save, Save As, validation, or migration
- Autosave and Recovery
- PDF parsing or rendering
- Image decoding internals
- Document mutation
- Command execution
- Platform picker UI
- Plugin loading or sandboxing
- OCR, recognition, mathematics, or synchronization

## Operation Boundaries

- Open `.alnote` belongs to Storage.
- Save and Save As `.alnote` belong to Storage.
- Open standalone PDF belongs to PDF plus the future Document Sessions System.
- Import or Insert external content belongs to Import.
- Export to PDF, PNG, or JPEG belongs to Export.
- Sharing completed output belongs to platform adapters after Export.

Share is not an import or export format.

## Version-1 Formats

Guaranteed version-1 import formats are:

- PDF — `alnote.format.pdf`
- PNG — `alnote.format.png`
- JPEG — `alnote.format.jpeg`

These stable identifiers use the `alnote.format.*` namespace.

The `org.alnote.format.*` namespace is not used.

## Import Pipeline

The conceptual pipeline is:

Source acquisition
→ Content-based detection
→ Format validation and preparation
→ Prepared Import Plan
→ Destination selection
→ Freshness and resource validation
→ Atomic Command publication

## Source Acquisition

Platform adapters expose capabilities for:

- Selecting readable sources
- Reading bounded streams
- Reporting source capabilities
- Canceling source acquisition
- Reporting platform limitations

Import does not assume filesystem paths on Android or Web.

Extensions and MIME types are hints only.

Actual content is inspected before a format is accepted.

## Content Detection

Detection:

- Uses bounded content inspection
- Distinguishes supported, unsupported, malformed, and ambiguous input
- Does not trust filename extensions alone
- Does not execute source content
- Does not access external networks implicitly
- Produces a stable format identity or structured failure

Built-in format identifiers cannot be replaced by plugins.

## Prepared Import Plans

A Prepared Import Plan is:

- Immutable
- Temporary
- Nonpersistent
- Validated
- Bound to detected source content
- Bound to declared transaction groups
- Bound to destination requirements
- Safe to discard

Import preparation never mutates the document.

Plans may contain:

- Detected format
- Source fingerprint
- Prepared Page or Object descriptions
- Required resource tokens
- Destination requirements
- Transaction grouping
- Expected document revision
- Warnings
- Estimated work
- Required capabilities

Plans never contain unrestricted platform handles or executable content.

## Resource Staging

Staged resources use bounded, expiring, host-owned tokens.

Tokens:

- Are temporary capabilities
- Are not document resource UUIDs
- Cannot provide unrestricted filesystem access
- Expire after cancellation, completion, or timeout
- Are validated again before publication

Resource staging and deduplication follow accepted Storage resource-manifest and immutable-resource boundaries.

No new Resource subsystem is created.

## Destination Planning

Final destinations use stable:

- Section IDs
- Page IDs
- Layer IDs

Display positions and current UI selection are insufficient as persistent destinations.

A stale plan must not silently target another Section, Page, or Layer.

Destination validation occurs again immediately before publication.

## Transaction Grouping

One PDF's selected Pages form one atomic import by default.

Independent source files default to separate transactions.

Partial success is allowed only between declared transaction groups.

Within one transaction group, publication is all-or-nothing.

Structured results identify every completed, failed, canceled, and unattempted group.

## Command Publication

Import publication occurs exclusively through the Command System.

Before publication, validate:

- Expected document revision
- Destination identities
- Resource tokens
- Resource fingerprints
- Format-handler availability
- Security limits
- Prepared content

Cancellation or failure before publication leaves the document unchanged.

A rejected or stale plan is not silently replayed against newer document state.

## Format Ownership

Import owns orchestration, not format internals.

- PDF System owns PDF parsing, page references, source layers, and PDF preparation.
- Image System owns PNG and JPEG validation, dimensions, orientation, and image payload preparation.
- Storage owns immutable resources and manifest rules.
- Commands own persistent publication.

## Progress and Cancellation

Cancellation is cooperative.

Import cancellation before Command publication:

- Leaves the document unchanged
- Revokes staged resource tokens
- Reclaims temporary data
- Stops further preparation where practical
- Returns a structured result

Cancellation does not undo already completed independent transaction groups.

## Failure and Degradation

Failures use stable structured error codes.

A result may describe:

- Success
- Cancellation
- Unsupported format
- Invalid input
- Security-limit failure
- Destination conflict
- Stale plan
- Handler unavailable
- Resource failure
- Partial success between transaction groups

Silent omission of content is forbidden.

Degraded conversion requires authorization and a structured report.

## Plugin Importers

Plugin importers remain declarative and constrained.

They cannot:

- Mutate documents
- Publish Commands
- Select unrestricted files directly
- Access networks without separate authorization
- Bypass security or resource limits
- Access native renderers directly
- Replace built-in format identifiers
- Retain unrestricted source handles
- Execute imported content

Plugin output must become a validated Prepared Import Plan handled by central orchestration.

## Security and Limits

Configurable limits apply to:

- Source bytes
- Source file count
- PDF Page count
- Image dimensions
- Image pixel count
- Metadata size
- Archive entries
- Archive expansion
- Temporary storage
- Memory
- Processing time
- Concurrent jobs
- Plugin output
- Prepared-plan size

All external content is hostile input.

Temporary resources are bounded and reclaimed.

## Dependency Status

No external Import dependency is accepted.

Every future dependency and bundled binary requires pinned transitive-license, security, maintenance, and platform audits.

## Open-Source Record

Candidates only:

- Flutter `file_selector`
- `file_picker`
- Dart `image`
- Dart `archive`
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

- Additional import formats
- Cloud sources
- Remote sources
- Archive import
- SVG import
- Office-document import
- Import presets
- Cross-document import transactions
- Advanced partial-success policy
- Exact picker dependency
- Exact importer dependencies
- OCR-assisted import
- Recognition-generated content
