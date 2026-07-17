# Command, Undo, and Redo System

**Status:** Accepted with modifications

## Purpose

The Command, Undo, and Redo System is the only normal path for changing persistent AL NOTE document state.

It guarantees:

- Final validation before publication
- All-or-nothing transactions
- Document-wide undo and redo
- Safe restoration
- Stale-request detection
- Plugin-independent history
- Structured committed-change descriptions

## Command Model

The command model has two conceptual stages.

### Command Request

A Command Request contains:

- Stable namespaced command family
- Target Document ID
- Target entity IDs
- User-visible description
- Intent and parameters
- Required revision preconditions
- Optional grouping and coalescing metadata
- Correlation ID

### Prepared Transaction

A Prepared Transaction contains:

- Exact affected before-state fragments
- Exact affected after-state fragments
- Ownership and ordering changes
- Resource-reference changes
- ID-remapping table when required
- Structured change description
- Estimated retained history cost
- Undo and redo metadata

Tools and plugins may propose intent and candidate replacements.

Only the Document Mutation Coordinator may construct or accept the final trusted transaction.

## History Representation

History uses a hybrid of:

- Structurally shared immutable before and after states
- Operation metadata
- Resource-retention information
- Stable ID-remapping tables

Inverse operations and plugin callbacks are not authoritative undo data.

History must remain usable when a plugin is unavailable.

## Exclusive Mutation Gateway

A document-scoped Document Mutation Coordinator exclusively publishes persistent document state.

Objects, layers, tools, selection, plugins, and storage adapters cannot provide alternate normal mutation paths.

All persistent user edits pass through the coordinator.

## Execution Lifecycle

1. A tool or application service constructs intent.
2. Expensive computation or decoding may run asynchronously.
3. The request enters the document’s serialized mutation queue.
4. The coordinator reads the latest state.
5. It checks declared revisions, authorization, capabilities, ownership, and invariants.
6. It constructs or verifies the complete candidate state.
7. It publishes one immutable document-root replacement.
8. It records one history entry.
9. It emits one committed-change description.

Commands for one document never publish concurrently.

The final publication step must remain short and synchronous.

## Atomicity

The complete candidate root is built before publication.

A transaction either commits completely or changes nothing.

One transaction may affect:

- Multiple objects
- Multiple layers
- Multiple Pages
- Sections
- Notebook structure
- Resource references

All affected entities must belong to one logical document.

Cross-document atomic transactions are deferred.

Compound commands produce:

- One validation result
- One root publication
- One history entry
- One change notification

Nested builders may contribute operations but cannot publish independently.

## Validation and Authorization

Final validation occurs inside the serialized mutation boundary.

Separate command policies distinguish the following operation types.

### Interactive Content Edits

Interactive content edits require:

- Visible targets
- Unlocked targets
- Required capabilities
- Valid ownership
- Valid geometry

### Document-Management Operations

Document-management operations may include:

- Showing hidden content
- Unlocking locked content
- Safe read-only duplication
- Renaming or reordering when accepted policies permit

These operations must not be rejected merely because the target is currently hidden or locked.

Locked content still rejects modification, clearing, and deletion.

### Recovery and Migration

Recovery and migration use explicit privileged origins.

Privileged operations:

- Must remain validated
- Must be reported
- Cannot silently bypass normal rules
- May establish a new session baseline instead of a user undo entry

## Revision Model

Session-only revision tokens are maintained for:

- Document sequencing
- Objects
- Layers and ownership collections
- Pages and larger structures
- Resource catalog

A request declares only the revisions its result depends on.

The global document revision:

- Increments after every commit, undo, and redo
- Orders notifications and states
- Is required as a precondition only for document-wide dependencies

An unrelated edit must not automatically invalidate a command that depends on unaffected entities.

On a revision mismatch:

- Reject the complete command
- Commit nothing
- Return structured stale information
- Require recomputation

Automatic rebasing is deferred.

## Undo and Redo

History belongs to the open editing session for one logical document.

Multiple views of the same in-memory document share the same history.

History is linear:

- Undo moves backward.
- Redo moves forward.
- A new command after undo discards the redo tail.
- Branching history is deferred.

Undo restores recorded before-state.

Redo restores recorded after-state.

Both operations:

- Pass through the mutation coordinator
- Restore original IDs
- Restore original ordering
- Increment the session document revision
- Emit committed-change descriptions

If history preconditions unexpectedly fail:

- Change nothing
- Disable traversal through the inconsistent history
- Report the failure
- Require explicit reset, reload, or recovery
- Never skip the broken entry

## Grouping and Coalescing

Preview updates do not create history entries.

One completed gesture creates one transaction.

Coalescing requires:

- Same document
- Same command family
- Same explicit merge key
- Same logical target
- Adjacent history entries
- An editor-defined session or time boundary
- No save barrier, focus change, selection change, or structural change
- Preservation of the first before-state and latest after-state

Timing alone is insufficient.

Expected behavior:

- Separate handwriting strokes normally remain separate undo entries.
- One partial-eraser gesture is one entry.
- Text insertion may coalesce within one editing session.
- Backspace coalesces separately from insertion.
- Imports, layer deletion, duplication, and multi-object transforms do not automatically coalesce.

## Required Operation Behavior

### Handwriting Stroke

A completed stroke creates one replacement Handwriting Object or one new Handwriting Object.

Undo restores the previous object or removes the new object.

### Partial Eraser

One gesture replaces all affected Handwriting Objects atomically.

Undo restores the original whole objects.

### Cross-Layer Movement

All source and destination collection changes commit atomically.

Undo restores original memberships and positions.

### Selected-Stroke Transform

The Handwriting handler produces one replacement Handwriting Object.

History stores complete before and after object values.

### Layer Deletion

History retains the complete deleted layer subtree.

Undo restores:

- Layer ID
- Object IDs
- Order
- Payloads
- Extension data
- Resource references

If deletion created a replacement content layer, undo removes that generated replacement while restoring the original.

### Duplication

Redo restores the same allocated duplicate IDs. It does not generate new IDs.

### Text Editing

Text changes may coalesce only within one explicit editing session and merge policy.

### Import

File access and decoding occur outside commands.

The final transaction atomically inserts prepared document values and resource references.

## Dirty State and Saving

Dirty state is not determined from the history cursor.

Every committed immutable root receives a session content-state identity.

The session tracks:

- Current content-state identity
- Last successfully saved content-state identity
- State currently being saved

A document is clean only when the current identity equals the saved identity.

If editing continues during an asynchronous save:

- A successful save marks the captured state as saved.
- A newer current state remains dirty.
- Save failure does not move the checkpoint.

The content-state identity is session-only. Persistent fingerprints are deferred to Storage.

Save, Save As, export, and printing are not undoable document commands.

## Resource Boundary

History retains stable resource IDs or leases.

The future Resource System owns:

- Physical resource storage
- Reachability analysis
- Garbage collection
- Exact retention implementation

Resources may remain retained by:

- Current document state
- Undo history
- Redo history
- Pending transactions
- Active save or recovery snapshots

The architecture does not commit to simple reference counting yet.

## External Effects

Reversible domain commands must not perform:

- File reading or writing
- Network access
- Printing
- Clipboard I/O
- Launching external applications
- Platform API work

External preparation happens first. Document commit happens last.

## Committed-Change Description

Every successful commit emits one immutable description containing:

- Document ID
- Previous and new document revisions
- Origin
- Command family and description
- Added, removed, replaced, and moved entity IDs
- Affected Page and Layer IDs
- Membership and order changes
- Resource-reference changes
- Optional old and new page-space bounds
- Geometry, appearance, text, structure, resource, and metadata flags
- History and checkpoint implications
- Transaction correlation ID

Observers include:

- Rendering
- Hit testing
- Selection reconciliation
- Autosave
- Indexing
- UI

Observers cannot cancel or modify the committed transaction.

Observers cannot synchronously reenter mutation. Follow-up edits must be queued as new requests.

Observer failure does not roll back a valid commit.

## Plugin and Unknown-Object Behavior

History stores opaque values, never executable plugin callbacks.

When a plugin is missing:

- Undo and redo restore opaque snapshots.
- Common structural operations may remain available.
- Type-specific editing remains disabled.
- Redo never executes missing plugin code.
- Unknown payloads remain data-equivalent through history and future storage.

## History Storage and Recovery

Normal undo history is session-only and is not serialized in the AL NOTE document file.

Future crash recovery is separate and may journal:

- Successfully committed state transitions
- Durable transaction records
- Immutable snapshots

The Storage and Recovery systems will choose the durable format.

Raw UI command requests are not sufficient recovery records.

## Memory Limits

Use configurable command-count and estimated-retained-byte limits.

- Structural sharing should reduce retained memory.
- Resource blobs are referenced rather than copied.
- Undo and redo share one budget.
- Oldest reachable entries are discarded first.
- Coalescing reduces repetitive history.
- Pending operations and saves retain required resources.

If a command cannot retain enough undo data:

- Cancel it, or
- Obtain explicit application-level approval before a non-undoable commit

Undo data must never be silently discarded after presenting the operation as undoable.

Disk-backed history and very-large-entry policy remain deferred.

## Folder Ownership

Only `lib/documents/commands/` is authorized.

It owns conceptual responsibility for:

- Command contracts
- Mutation coordination
- Prepared transactions
- History
- Revision tracking
- Committed-change descriptions

Implementation subfolders are not defined yet.

## Deferred Matters

- Cross-document atomicity
- Collaboration rebasing
- Persistent or disk-backed history
- Crash-recovery journal format
- Exact resource storage and reclamation strategy
- Immutable collection dependency
- Very-large-command spill policy
- Persistent content fingerprint
- Exact revision implementation

## Open-Source Record

- Rnote is GPL-3.0-or-later; adapt command and history concepts only.
- Xournal++ is GPL-2.0-or-later; direct reuse requires file and dependency auditing.
- Krita provides useful history, merging, and memory-limit concepts but is substantially more complex.
- The Dart `undo` package is Apache-2.0 but is unsuitable as AL NOTE’s command core.
- `built_collection` remains a benchmarking candidate.
- `fast_immutable_collections` is BSD-2-Clause and remains a benchmarking candidate.
- No command or immutable-collection dependency is accepted yet.
