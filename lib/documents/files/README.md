# Storage, Serialization, and AL NOTE File Format

**Status:** Accepted with modifications

## Purpose

The Storage, Serialization, and AL NOTE File Format subsystem converts captured immutable document states and their resources into durable, portable, verifiable packages and reconstructs them without silently losing persistent information.

## Canonical Format

One `.alnote` format is used for:

- Notebook
- Standalone Page
- Standalone PDF

The canonical container is an AL NOTE-specific, ODF-inspired ZIP package.

Package version 1 uses deterministic UTF-8 JSON for structured records.

Recommended logical structure:

```text
mimetype
manifest.json
document.json
sections/<section-uuid>.json
pages/<page-uuid>.json
resources/<sha256-prefix>/<sha256>
extensions/<namespace>/...
previews/...
```

Package version 1 does not include a `signatures/` area.

Objects normally remain inside their owning Page record.

Collection order in JSON arrays remains authoritative. Numeric z-indexes are not authoritative.

## Resource Rules

Each resource has:

- Document-scoped logical resource UUID
- SHA-256 hash for exact bytes
- Media type
- Decoded byte length
- Package entry path
- Resource role
- Resource schema version where applicable

The UUID identifies the logical document reference.

SHA-256 identifies and verifies the exact immutable bytes associated with that reference in a captured snapshot.

Version 1 embeds all resources required to reproduce the document, including:

- Original PDFs
- Images
- Required attachments

External resource links are deferred.

Multiple UUIDs may reference the same content hash. Only one byte entry is required.

Unknown data participates in reachability. Any resource whose reachability cannot be safely determined must be retained.

## Manifest Rules

The manifest records:

- Package format version
- Document-root schema version
- Root document type
- Document UUID
- Entry point
- Required and optional features
- Structured-record catalog
- Resource catalog
- Entry media types
- Decoded sizes
- SHA-256 hashes
- Extension namespaces
- Compatibility requirements

The manifest catalogs authoritative entries except itself.

SHA-256 provides integrity and corruption detection. It does not provide authorship or authenticity.

Previews and producer information are non-authoritative and excluded from persistent content identity.

## Versioning

Separate versions are maintained for:

1. Package and container format
2. Document-root schema
3. Layer envelope or layer-type schema
4. Common object envelope
5. Each object-type payload

Application version must not substitute for schema versions.

## Unknown Data

The subsystem preserves:

- Unknown fields in known records
- Unknown object types
- Unsupported object payload versions
- Unknown layers
- Plugin-defined records
- Unknown safe package entries
- Associated resources and extension data

Unknown data remains inert and non-executable.

If exact reachability or interpretation cannot be established, preserve rather than delete.

## Migration Ownership

Storage owns:

- Preservation-capable parsing
- Migration planning and orchestration
- Complete-result validation
- Package replacement

Document subsystems and registered type handlers own the meaning of their schema migrations.

Migrations:

- Never modify the original package in place
- Operate in memory or through a separate temporary package
- Validate the complete result
- Preserve unknown data
- Replace the original only through an explicit successful save
- Leave the original untouched after failure

## Loading and Validation

Loading is staged:

1. Identify the package signature.
2. Read bounded `mimetype` and `manifest.json`.
3. Validate versions and required features.
4. Validate normalized paths and reject duplicates.
5. Enforce actual and declared size limits.
6. Validate the document root.
7. Validate identities and ownership.
8. Load Pages and resources lazily.
9. Verify hashes before active use.
10. Decode media through bounded decoders.

Reject or safely contain:

- Path traversal
- Absolute or platform-drive paths
- Duplicate normalized names
- Archive bombs
- Excessive entry counts and decoded sizes
- Excessive JSON nesting or allocations
- Invalid Unicode
- Non-finite numbers
- Excessive coordinate values
- Excessive image dimensions
- Duplicate IDs
- Cycles and multiple ownership
- Missing required roots
- Invalid layer roles
- Dangling resource references

Ambiguous ownership must not be silently repaired.

A repair that drops or rewrites information must create a separate file and disclose its changes.

## Lazy Loading

- Load the manifest and root eagerly.
- Load Pages on demand.
- Load binary resources as streams or seekable ranges where supported.
- Keep objects inside their Page unless profiling later justifies finer sharding.
- Extracted caches are rebuildable and non-authoritative.
- Rendering caches, thumbnails, indexes, and smoothed geometry remain non-authoritative.

## Saving

A save captures one immutable document state and its resolved resource handles.

Where supported:

1. Validate the snapshot.
2. Write a complete sibling temporary package.
3. Flush it.
4. Validate the output.
5. Use the strongest atomic replacement primitive.
6. Report success only after replacement succeeds.

ZIP entries must never be modified in place.

The previous valid generation must never be removed before replacement is complete.

When atomic replacement is unavailable:

- Use the strongest platform capability available.
- Preserve the previous generation.
- Report reduced durability honestly.

On Web:

- Browser download is treated as creation or export of a package.
- App-managed storage may use transactional browser storage.
- Quota failure, cancellation, and lifecycle interruption must be reported.

Save As normally preserves the document and internal entity UUIDs.

Creating an independent duplicate document is a separate operation.

## External Changes and Concurrency

Use:

- Advisory writer coordination where supported
- External destination fingerprints
- Conflict detection before overwriting

The system must never depend on locking alone.

Blind overwriting of an externally modified file is not allowed.

## Ownership Boundaries

`lib/documents/files/` owns:

- Package contracts
- Manifest and catalog model
- Serialization orchestration
- Resource repository contracts
- Validation and safety limits
- Migration orchestration
- Save and load coordination
- Atomic-replacement abstractions
- Unknown-record preservation
- External-change fingerprints

Platform adapters own:

- File handles and streams
- Temporary-file placement
- Flush and replacement primitives
- Provider capabilities
- Locking primitives
- Permission and quota reporting
- Browser storage integration

Storage does not own:

- Undo history
- Autosave scheduling
- Recovery-journal design
- Rendering
- PDF rendering
- Import and export workflows
- Search indexes
- Plugin execution
- Sync protocols
- Encryption implementation
- File-picker UI

Normal undo history is not stored in `.alnote` packages.

## Dependency Status

No Dart storage package is accepted.

The following remain candidates only:

- `archive`
- `json_serializable`
- Freezed
- CBOR libraries
- Immutable collection libraries

SQLite may later support caches, indexes, or recovery, but it is not the canonical AL NOTE file.

## Deferred Matters

- Permanent registered media type
- Numeric security limits
- ZIP64 requirements
- Persistent logical fingerprint
- External resource links
- Compact handwriting encoding
- Advisory-lock metadata
- Digital signatures
- Encryption
- Exact lexical preservation of unknown JSON
- Formal salvage and repair format
- Future sync hash boundaries
- Exact ZIP and JSON dependencies

## Open-Source Record

- Rnote is GPL-3.0-or-later and offers useful persistence concepts, but its format should not be adopted wholesale.
- Xournal++ is currently identified as GPL-2.0; direct code reuse requires file-level and dependency licensing review.
- ODF provides useful ZIP-package concepts without requiring AL NOTE to adopt ODF schemas.
- SQLite is public domain but is not selected as the canonical format.
- Dart `archive` is MIT and remains a prototype candidate.
- `json_serializable` is BSD-3-Clause and may only be used with explicit unknown-field preservation.
- Freezed is MIT and is only an optional implementation aid.
- Protocol Buffers and FlatBuffers are rejected for canonical version-1 records.
- No storage dependency is accepted yet.
