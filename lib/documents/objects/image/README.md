# Image Object System

Status: **Accepted with modifications**

## Purpose

The Image Object System provides persistent raster images as transformable Page Objects.

It owns:

- The built-in `alnote.image` type
- Image-specific persistent payload fields
- Image validation and migration rules
- Resource-reference requirements
- Orientation and crop semantics
- Image import and export contracts
- Rendering, decoding, and hit-testing boundaries
- Compatibility boundaries for future OCR and Sync

It does not own:

- Generic resource bytes or manifest metadata
- Layer membership or background-layer constraints
- Common Object transforms
- Command execution
- Rendering backends
- Decoder or cache implementation
- OCR execution
- Synchronization
- Cloud storage
- Destructive image editing

## Object Type and Envelope

The built-in Image Object identity is:

`alnote.image`

Each Image Object references one immutable generic document resource.

The common Object envelope owns the Image payload's `typeSchemaVersion`. The Image payload does not duplicate that version field.

Unknown type-specific Image fields are preserved inside the Image payload record according to Storage rules. This does not duplicate the common envelope's extension-data field.

## Persistent Payload

The Image payload persists:

- Resource UUID
- Verified encoded pixel width and height
- Oriented intrinsic document width and height
- Explicit display orientation
- Normalized crop rectangle
- Rendering intent
- Optional user-authored alternative text
- Preserved safe unknown type-specific fields

The generic resource manifest, not the Image payload, owns:

- Resource content hash
- Encoded media type
- Encoded byte size
- Generic resource metadata
- Integrity and retention information

Remote URLs and cloud locators do not belong in the version-1 Image payload.

## Authoritative and Derived Data

Authoritative data includes:

- Original encoded resource bytes
- Persistent Image payload fields
- Resource UUID reference
- Explicit orientation
- Normalized crop
- Rendering intent
- Alternative text
- Common Object transform

Derived and rebuildable data includes:

- Decoded pixels
- Thumbnails
- Mipmaps
- Tiles
- Alpha masks
- Color conversions
- Device-specific surfaces
- Render caches
- Precise hit-test masks
- OCR results
- OCR indexes

Derived data is never required to reconstruct the authoritative Image Object.

## Version 1 Formats

PNG and JPEG are the only guaranteed version-1 formats for:

- Import
- Storage
- Display
- Export

Additional formats require later conformance approval across Linux, Windows, Android, and Web.

Animated formats and animation behavior are not part of version 1.

## Orientation and Coordinate Pipeline

The original encoded bytes remain unchanged while display orientation is persisted explicitly.

Encoded pixel dimensions are measured before orientation.

Decoders must not apply orientation a second time when AL NOTE applies the persistent display orientation.

The coordinate pipeline is:

1. Encoded source-pixel space
2. Explicit orientation
3. Oriented-source space
4. Normalized crop
5. Intrinsic local document dimensions
6. Common local-to-page Object transform
7. Viewport and rendering transforms

Crop coordinates use normalized oriented-source space.

All geometry values must be finite and bounded.

## Nondestructive Crop and Transform

Cropping is nondestructive.

A crop changes the visible source region without changing the original resource bytes.

Movement, rotation, and positive scaling use the common Object transform.

Text-box-like resizing does not apply to Image Objects. Resizing changes the common transform or accepted object geometry while preserving the source resource.

Reflection and destructive image editing remain deferred.

## Default Physical Size

Default physical size uses trustworthy, bounded resolution metadata when available.

If resolution metadata is missing, invalid, or unreasonable, use 96 DPI.

Default placement:

- Preserves aspect ratio
- Scales down to fit the page when necessary
- Does not automatically upscale a smaller image
- Remains bounded by Page and security limits

## Resource Sharing and Lifecycle

Duplicating an Image Object creates a new Object UUID while sharing the same immutable resource bytes.

Multiple Image Objects may reference one logical resource.

The Resource System owns:

- Immutable resource identity
- Content hashing
- Reference tracking
- Retention
- Reclamation
- Deduplication policy

Deleting one Image Object does not delete bytes still reachable from another object, recovery generation, active write, or other valid owner.

## Import Transaction

Import prepares and validates bounded encoded bytes before publication.

Preparation may include:

- Reading bytes through an approved source boundary
- Applying encoded-size limits
- Detecting and validating PNG or JPEG
- Measuring encoded pixel dimensions
- Reading bounded orientation and resolution metadata
- Computing resource identity and hash
- Selecting default physical size
- Building a validated Image payload
- Preparing the resource insertion

One atomic Command publishes the resource and Image Object.

Cancellation, validation failure, stale state, or Command rejection publishes no document mutation.

Temporary import data is disposable and remains outside document history and recovery.

## Background Images

Movable images and background images use the same `alnote.image` Object type.

The Image payload does not contain an `isBackground` field.

Background placement and constraints belong to the Layer System.

This preserves one Image model while allowing layer-owned behavior such as placement below content, locking, and restricted movement.

## Rendering and Decoding Boundaries

Persistent Image data does not contain decoder, renderer, cache, or platform surface state.

Platform-independent contracts cover:

- Bounded decode requests
- Decode results
- Orientation application
- Crop sampling
- Color conversion
- Resolution selection
- Cache identity
- Rendering intent
- Cancellation
- Failure diagnostics

Flutter and Skia codecs may provide the initial rendering and bounded-decoding baseline, subject to AL NOTE validation.

Decoding untrusted image bytes must occur behind bounded, cancellable contracts.

## Hit Testing

Basic hit testing may begin with the transformed visible crop bounds.

Precise alpha-aware hit testing is derived and optional.

Hit testing:

- Converts Page coordinates through the inverse common transform
- Applies local crop and orientation semantics
- Does not mutate persistent data
- Must remain usable when precise masks are unavailable
- Uses bounded derived caches when required

## Missing and Invalid Resources

Missing, corrupt, unsupported, or quarantined resources do not remove the Image Object.

The application renders a stable placeholder that preserves:

- Object bounds
- Common transform
- Crop
- Layer membership
- Selection behavior
- Resource identity
- Alternative text where appropriate

The placeholder must not silently substitute unrelated bytes.

Recovery or repair remains explicit.

## Export and Privacy

Normal external exports strip sensitive source metadata by default.

Potentially sensitive metadata includes:

- Camera and device details
- Location
- Author information
- Editing-software history
- Embedded thumbnails
- Unneeded private tags

Explicitly exporting the original resource may preserve its original metadata.

Sharing privacy rules for source metadata retained inside `.alnote` packages require later Security and Privacy architecture.

Export must not claim metadata was removed unless the exported bytes were actually sanitized.

## Future OCR Compatibility

OCR is an official post-v1 goal and remains outside the Image Object.

Version 1 preserves what later OCR requires:

- Original image pixels
- Immutable resource UUID and hash
- Stable Object identity
- Explicit orientation
- Normalized crop
- Stable coordinates and transforms
- Versioned payload and Object revisions

Future OCR data identifies at least:

- Image Object UUID
- Resource UUID and hash
- Image payload revision
- Orientation
- Crop
- Transform revision
- OCR engine and model version
- Source-space text regions
- Confidence and language metadata where appropriate

OCR results are derived and must be invalidated when their source identity or relevant revisions change.

No OCR engine or dependency is selected here.

## Future Sync Compatibility

Optional Sync and Cloud architecture is an official post-v1 goal.

Version 1 preserves:

- Immutable resource bytes addressed by content hash
- Logical resources addressed by UUID
- Stable Object UUIDs
- Versioned schemas
- Preserved unknown data
- Explicit extension boundaries

Future Sync may transfer immutable bytes by hash while tracking logical resources by UUID.

Remote URLs, provider identifiers, and cloud locators do not belong in the version-1 Image payload.

No synchronization or cloud dependency is selected here.

## Recognition and Mathematics Boundary

Handwriting Recognition, OCR, Math Recognition, the Symbolic Math Engine, and optional Sync or Cloud are not required for the first build.

Version 1 must avoid blocking their later addition.

Handwritten mathematics will eventually use cooperating boundaries:

Stored handwriting → Math Recognition → structured mathematics → Symbolic Math Engine → evaluated or solved result

These post-v1 systems remain separate and require their own specialist architecture, open-source evaluation, and licensing review.

## Plugin Decoder Boundary

Plugins cannot become a path around validation or resource limits.

Plugin decoders:

- Receive only bounded approved bytes or resource handles
- Operate through restricted decode contracts
- Cannot mutate the authoritative resource
- Cannot write persistent Image fields directly
- Cannot execute during ordinary file discovery
- Must return validated derived results
- Must support cancellation and resource limits
- Cannot make version-1 PNG or JPEG support depend on plugin availability

Plugin-provided formats require later portability, security, maintenance, and licensing approval.

## Security and Resource Limits

Configurable limits apply to:

- Encoded byte size
- Pixel width and height
- Total decoded pixels
- Decode memory
- Decode time
- Metadata size
- Profile size
- Frame count for any future animated format
- Cache memory
- Export dimensions
- Import concurrency

Security behavior includes:

- Treat all encoded images and metadata as hostile input.
- Reject malformed or inconsistent dimensions.
- Prevent integer overflow and decompression bombs.
- Bound metadata parsing.
- Harden color-profile and font-like embedded-data handling.
- Cancel work that exceeds time or memory budgets.
- Quarantine suspicious resources without deleting their references.
- Avoid external network access during decoding.
- Preserve objects with placeholders when decoding cannot proceed.
- Never execute embedded content.

## Serialization Implications

- The common Object envelope carries `typeSchemaVersion`.
- The Image payload does not duplicate the schema version.
- Serialization uses deterministic UTF-8 JSON.
- Resource references use UUIDs.
- Pixel dimensions and geometry are finite and bounded.
- Orientation uses a stable built-in representation.
- Crop uses normalized oriented-source coordinates.
- Unknown safe type-specific fields remain preserved within the payload.
- Generic resource hashes and media metadata remain in the resource manifest.
- Derived decode, cache, color, hit-test, and OCR data are never serialized as authoritative Image state.
- Unsupported newer payloads remain preserved and inert when they cannot be safely interpreted.

## Folder Ownership

`lib/documents/objects/image/` conceptually owns:

- Persistent Image payload semantics
- Image validation and migrations
- Orientation and crop contracts
- Import and export boundaries
- Resource-reference requirements
- Decode and rendering contracts
- Missing-resource behavior
- Future OCR and Sync compatibility boundaries

No implementation subfolders are defined yet.

Renderer, decoder, cache, hit-testing, resource, OCR, and Sync implementations remain in their owning areas.

## Dependency Status

No external Image dependency is accepted yet.

## Open-Source Record

- Flutter and Skia codecs are the initial rendering and bounded-decoding baseline, subject to AL NOTE validation.
- The Dart `image` package is MIT and may be evaluated for controlled metadata, conversion, and testing work.
- libvips is LGPL-2.1-or-later and may be considered later for low-memory desktop or server processing.
- ImageMagick is GPLv3-compatible but should not be embedded as the unrestricted core decoder.
- Rnote is an architectural reference.
- Xournal++ is a behavioral reference; direct reuse requires file-level license review.
- No external Image dependency is accepted yet.

## Deferred Matters

- GIF, WebP, and BMP portability
- Animation
- SVG
- HEIF and HEIC
- AVIF
- TIFF
- HDR and wide-gamut policy
- Reflection
- Destructive editing and filters
- External resource links
- Exact decoder dependencies
- Exact resource limits
- Exact color-management policy
- Exact metadata-sanitization implementation
- OCR implementation and dependencies
- Sync and Cloud implementation and dependencies
