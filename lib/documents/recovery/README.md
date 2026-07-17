# Autosave and Recovery Architecture

Status: **Accepted with modifications**

## Purpose

Autosave and Recovery protects committed document work after crashes, forced termination, lifecycle suspension, power loss, or browser closure.

Recovery remains separate from:

- Canonical `.alnote` saving
- Normal undo and redo
- Cloud synchronization
- Temporary drawing previews

## Recovery Model

Recovery uses a hybrid system containing:

1. A complete durable recovery checkpoint
2. A short append-only journal after that checkpoint
3. Required retained resources
4. A versioned recovery manifest

Recovery checkpoints contain complete recoverable persistent document state.

Journal entries contain serialized persistent after-state replacements and required resource changes. They must not contain:

- Raw pointer events
- UI requests
- Uncommitted strokes
- Command callbacks
- Plugin callbacks
- Behavior-dependent command replay
- Normal undo history

If a change cannot be represented safely as replacement records, Recovery creates a new checkpoint.

## Recovery Storage

Recovery is enabled by default and stored in app-managed persistent storage separate from canonical `.alnote` files.

Version 1 does not automatically replace canonical files. Any future automatic canonical-saving preference must use the normal Save pipeline and belongs to later Settings and Session architecture.

Recovery artifacts are not normal user documents and do not redefine canonical saved-state identity.

## Scheduling

A successful persistent document commit makes recovery work pending.

Scheduling uses:

- Quiet-period debounce
- Maximum dirty-state age
- Periodic checkpointing
- Journal-size thresholds
- Large-change checkpoint triggers
- Best-effort lifecycle flushes
- Explicit recovery flush requests

Lifecycle triggers include application backgrounding, mobile suspension, browser visibility loss, document closing, and anticipated shutdown.

Exact intervals remain configurable policy values rather than permanent format rules.

An in-progress stroke is not recoverable until its document transaction commits. Recovery writes must not interrupt pointer processing or drawing.

## Write Coordination

Each logical in-memory document has:

- One serialized recovery writer
- At most one active recovery write
- One coalesced pending boundary representing the newest committed state

Multiple views of the same in-memory document share this writer and recovery owner. Editing may continue while a captured state is written.

When pending work is coalesced, Recovery must construct a valid persistent delta from the last durable boundary to the newest captured state or create a new checkpoint. It must not skip required state transitions.

Recovery success never marks the canonical document as saved.

## Durable Ordering

Session content-state identities may be recorded as advisory metadata, but they are not durable cross-restart identifiers.

Durable recovery order uses:

- Recovery generation
- Monotonic journal sequence
- Base and resulting recovery hashes
- Transaction UUID
- Explicit commit markers

Timestamps are used only for display, diagnostics, and cleanup policy. They do not define journal order.

## Durability

A journal transaction is durable only after:

1. Required records and resources are durable.
2. Lengths and hashes are recorded.
3. Its commit marker is durable.
4. The platform adapter confirms its strongest available guarantee.

Incomplete trailing transactions are ignored.

Checkpoint replacement uses:

1. A new generation
2. Complete validation
3. Durable manifest publication
4. Atomic pointer switching where supported
5. Retention of the previous valid generation until publication succeeds

Where atomic switching is unavailable, generation-numbered records and a committed pointer record are used.

Checksums detect corruption but do not prove authenticity.

## Recovery Identity

Each recovery set records:

- Recovery-set UUID
- Document UUID
- Recovery-owner or session UUID
- Original destination when known
- Original destination fingerprint
- Last observed canonical-file fingerprint
- Recovery-format version
- Canonical-format version
- Checkpoint generation
- Journal sequence
- Required resource UUIDs and hashes
- Checkpoint and journal hashes
- Clean-shutdown status
- Recovery completion status
- Optional display metadata

Paths are metadata, not identity. New unsaved documents receive document and recovery UUIDs immediately.

## Startup Discovery

On startup, discover recovery sets that:

- Lack a valid clean-shutdown resolution
- Contain recoverable work beyond their recorded saved baseline
- Belong to unsaved documents
- Were not explicitly discarded
- Have not been safely cleaned up

Reconstruction proceeds as follows:

1. Select the newest valid checkpoint.
2. Validate its manifest, bounds, hashes, and resources.
3. Apply complete journal transactions in sequence.
4. Stop at the first invalid or incomplete transaction.
5. Use the newest valid prefix.
6. Run normal document and hostile-input validation.
7. Report any lost or corrupted tail explicitly.

A damaged newest checkpoint must not destroy the previous valid checkpoint.

## Restoration

A restored candidate:

- Opens as a dirty document
- Establishes a new Command History baseline
- Does not reconstruct the old undo stack
- Requires a normal explicit Save to update a canonical file
- Never automatically overwrites the original file

If identity, ownership, validation, plugin interpretation, external modification, or session coordination is uncertain, recovery opens as a separate recovered document.

Recovery restoration may initialize in-memory document state, but filesystem replacement always requires the normal Save process.

## External Changes

Recovery metadata is compared with the canonical destination fingerprint.

If the original file changed externally:

- Do not overwrite it
- Do not silently merge
- Open the recovered candidate separately
- Require later explicit conflict resolution or Save As

Persistent logical document fingerprints remain deferred.

## Unknown and Plugin Data

Recovery preserves:

- Unknown objects
- Unknown layers
- Unknown fields
- Unknown safe entries
- Plugin payloads
- Resource references
- Required resource bytes

Plugin availability is not required for preservation. Unknown content remains inert and cannot execute scripts, commands, or plugin code.

## Resource Retention

A resource may be deleted only when unreachable from:

- Active checkpoints
- Fallback checkpoints
- Valid journal entries
- Active writes
- Other recovery sets sharing the resource
- Recovered candidates not yet saved or discarded

Garbage collection occurs only after successful checkpoint publication and reachability reconciliation.

Unknown reachability requires preservation.

## Multiple Sessions

Recovery ownership uses:

- Owner session UUID
- Lease generation
- Renewal information
- Monotonic sequence allocation
- Safe stale-owner takeover

If reliable coordination is unavailable, each process or browser tab writes a separate recovery branch.

Competing branches are presented separately and never merged automatically. The recovery journal must not become a future synchronization log.

## Cleanup

Recovery may be removed only after:

- A normal save covers the same or newer recoverable state and the document closes cleanly
- The user explicitly discards the work
- A recovered candidate is saved elsewhere and completion is confirmed

Declining to restore is not automatically the same as permanently discarding.

Unsaved-document recovery must not be silently deleted solely because it is old. At least one valid generation remains until its replacement is validated and durable.

## Failure Handling

Recovery status is maintained per document:

- Current
- Pending
- Delayed
- Failed

Transient failures use capped exponential retry. Repeated failures produce one persistent status instead of repeated dialogs.

Notify promptly when:

- No valid recovery generation exists
- Maximum dirty-state protection age is exceeded
- Storage is permanently unavailable
- Permission is lost
- Browser quota is exhausted

Failure must not block editing, but the application must not claim recovery is current.

## Platform Boundaries

Shared recovery logic owns:

- Scheduling policy
- Recovery manifests
- Journal and checkpoint coordination
- Validation
- Reconstruction
- Resource reachability
- Recovery ownership protocol
- Status reporting

Platform adapters own:

- App-managed storage locations
- Durable write primitives
- Atomic or generation switching
- Locking and leases
- Quota reporting
- Lifecycle notifications
- Browser persistence requests
- Secure private-directory permissions

Platform storage uses:

- Application state or data directories on Linux
- Per-user application data on Windows
- App-private persistent storage on Android
- Transactional browser storage such as IndexedDB on Web

Temporary directories are not the primary recovery location.

## Privacy and Security

Recovery artifacts may contain the complete private document.

They require:

- App-private storage where available
- Restricted filesystem permissions where available
- Bounded hostile-input validation
- No automatic external-link access
- No plugin execution during discovery
- No private document payloads in logs
- Explicit treatment by future retention, encryption, and OS-backup policies

Recovery encryption remains deferred to Security and Privacy architecture.

## Ownership

`lib/documents/recovery/` owns conceptual responsibility for:

- Shared recovery policy
- Scheduling
- Recovery manifests
- Checkpoints and journals
- Validation and reconstruction
- Recovery ownership
- Recovery status
- Cleanup coordination

No implementation subfolders are defined yet.

## Dependency Status

No recovery database or Dart package is accepted.

SQLite WAL is a useful checkpoint-and-journal reference, and SQLite remains a possible backend candidate.

Dart and Web persistence libraries require later evaluation. Recovery backend choice must remain behind AL NOTE-owned contracts.

## Open-Source Record

- Xournal++ provides useful handwriting autosave concepts, but direct reuse requires licensing review.
- Krita demonstrates separate autosave files, recovery for saved and unsaved documents, and restoring recovered work as modified.
- LibreOffice demonstrates separation of AutoRecovery from normal saving.
- SQLite WAL provides useful commit and checkpoint concepts, and SQLite is public domain.
- No recovery implementation dependency is accepted.

## Deferred Matters

- Exact recovery artifact encoding
- Native and Web storage backend
- Exact debounce and maximum-latency values
- Checkpoint frequency and journal-size thresholds
- Lease renewal and stale-owner timing
- Recovery retention periods
- Storage-pressure cleanup limits
- Persistent logical document fingerprints
- Canonical automatic-saving preference
- Encryption and OS-backup policy
- Exact Dart and Web dependencies
