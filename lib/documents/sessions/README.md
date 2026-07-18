# Application State and Document Sessions

Status: **Accepted with modifications**

## Purpose

Application State coordinates AL NOTE’s open logical documents, attached views, application lifecycle, shared resource limits, and bounded workspace restoration.

A Document Session represents one logical open working document.

This subsystem coordinates document work without absorbing ownership from Commands, Storage, Recovery, PDF, Import, Export, Drawing, Interaction Mapping, or the future User Interface architecture.

## Application State Ownership

Application State owns:

- The registry of logical Document Sessions
- View-to-session associations
- Focused-view coordination
- Application lifecycle distribution
- Application-wide resource and job limits
- Bounded workspace-restoration coordination

A failure in one Document Session must not fail the application registry or unrelated sessions.

## Document Session Ownership

Each Document Session coordinates:

- The current immutable document root
- The Command coordinator
- Document-wide linear undo and redo history
- Current content-state identity
- Saved content-state identity
- Storage source binding
- External-source fingerprint
- Recovery writer
- Per-resource PDF unlock sessions
- Read-only state
- Degraded state
- Asynchronous operations
- Attached views
- Session-wide job coordination

A Document Session does not replace the systems it coordinates.

## State Separation

The following ownership domains remain distinct:

- Persistent document state
- Document Session state
- View and window state
- Application state
- User Settings
- Recovery data
- Workspace-restoration metadata

Persistent `.alnote` packages contain document content only.

They do not contain:

- Runtime Session IDs
- Workspace-restoration metadata
- Command History
- Selection
- Active Tool
- Temporary Tool overrides
- Viewport or zoom
- Editor or transform previews
- PDF passwords
- Derived caches
- Storage fingerprints

## Runtime and Durable Identities

Each open logical Document Session receives a random opaque runtime `SessionId`.

A `SessionId`:

- Exists only during the active runtime session
- Is distinct from document IDs
- Is distinct from source identities and paths
- Is distinct from view IDs
- Is not persistent document identity
- Is not durable restoration identity
- Is not reused when a document is restored

Durable workspace restoration uses a separate versioned `RestorationEntryId`.

Each attached view has its own `ViewId`.

Restored documents receive new runtime Session IDs.

## Canonical Source Deduplication

Opening a source already represented by an open logical session normally focuses an existing view or attaches another view to that session.

Source equivalence uses Storage-owned normalized source identity and platform identity where available. Path-string comparison alone is insufficient.

An explicit **open separate copy** operation may create an independent Document Session.

A separate copy has independent:

- Commands
- History
- Dirty state
- Recovery ownership
- Asynchronous operations

## Multiple Views

Multiple views or windows may share one logical Document Session.

Shared session-wide state includes:

- Immutable document root
- Commands and history
- Dirty and saved state
- Storage source and fingerprint
- Recovery writer
- Per-resource PDF unlock map
- Session-wide operations and jobs
- Revision-keyed caches owned by their proper subsystems

View-specific temporary state includes:

- Active Section
- Active Page
- Active Layer
- Active Tool
- Temporary Tool overrides
- Selection
- Editor sessions
- Transform sessions
- Viewport and zoom
- Input ownership
- Hover state
- Gestures
- Previews
- View-local render data

A Command committed from any attached view publishes one new immutable document root observed by every attached view.

Undo and redo remain document-scoped rather than view-scoped.

## Active-Reference Repair

After committed document changes or availability changes, view-specific active references are repaired deterministically:

1. Retain the same stable identity when it still exists.
2. Follow a Page or Object that moved.
3. When a Page moved, repair its active Section parent.
4. For a deleted target, prefer the next surviving sibling from the previous order.
5. Otherwise prefer the previous surviving sibling.
6. Otherwise choose the first valid target in the nearest valid parent.
7. Otherwise enter an explicit no-active-target state.
8. For a deleted active Layer, prefer a content-capable, visible, unlocked Layer.
9. If no Layer qualifies, use the first structurally valid Layer.

Selections remove missing targets.

Temporary editor and transform sessions cancel safely when required targets or handlers disappear.

Cancellation of temporary sessions must not publish partial persistent changes.

## Independent Status Axes

Session status is represented through independent axes rather than one combined enumeration.

### Lifecycle

- Opening
- Open
- Closing
- Closed
- Failed

### Readiness

- Loading
- Ready

### Access

- Editable
- Read-only

### Fidelity

- Complete
- Degraded

### External Source

- Unchanged
- Changed
- Missing
- Unverifiable

Ordinary lazy loading does not automatically make a session degraded.

Read-only and degraded remain independent.

## Revision and Freshness Coordination

The following concepts remain distinct:

- Command revision
- Content-state identity
- Session revision
- View revision
- Saved-state identity
- Recovery sequence
- Source epoch
- Operation identity
- Freshness epoch or ticket

Session revision allows observers to detect Session-state changes. It does not determine dirty state.

Asynchronous operations capture sufficient immutable identity, destination, epoch, and cancellation information to reject stale results safely.

Exact numeric representations remain implementation details.

## Dirty State

A session is clean only when:

`current content-state identity == saved-state identity`

A new unsaved document begins dirty.

A document reconstructed from Recovery begins dirty.

Importing into an existing document changes dirty state only through the committed Command result.

Successful Recovery does not mark a document as canonically saved.

Session revision alone never determines dirty state.

## Save

Save captures one immutable content state.

Editing may continue while Storage serializes and publishes the captured state.

After successful publication:

- The captured content-state identity becomes the saved-state identity.
- Storage supplies the new source fingerprint.
- Newer edits remain in the current document root.
- The session remains dirty when newer edits exist.

Only one canonical publication may run for a logical session at a time.

Later Save requests may be queued or safely coalesced.

A running atomic publication must not be interrupted in a way that risks corruption.

## Save As

Save As publishes one immutable captured state to a new source.

The session source is rebound only after:

- Successful publication
- Freshness validation
- Successful acquisition of the new Storage fingerprint

A stale, cancelled, conflicted, or failed Save As does not change the existing source binding.

## Export

Export uses one immutable snapshot.

Edits made after the snapshot was captured do not alter or invalidate the running export.

Export:

- Does not mutate the document
- Does not affect dirty state
- Does not enter Command History
- Does not alter Recovery document state
- Reports the content-state identity it exported

## Import

Import preparation remains asynchronous and non-mutating.

Immediately before Command publication, the session revalidates:

- Destination Section
- Destination Page
- Destination Layer
- Required capabilities
- Current insertion context
- Staged resources
- Prepared-plan freshness

A stale plan may be deterministically revalidated only when its contract explicitly permits that operation.

Otherwise, the plan fails without mutation.

## External Source Changes

Storage-owned external fingerprints are checked:

- When supported platform notifications report a change
- When application focus returns
- Before canonical publication
- Before rebinding a source after Save As

External-source state remains separate from dirty state.

External content is never silently overwritten or silently reloaded.

Conflict handling may permit:

- Open the external version separately
- Reload a clean session with explicit authorization
- Save As
- Fingerprint-bound explicit overwrite
- Cancel

Overwrite authorization applies to one specific fingerprint.

Authorization expires if the fingerprint changes.

## Read-Only and Degraded Sessions

Read-only means persistent mutation is explicitly prohibited by Session policy or safe preservation cannot be guaranteed.

The following conditions do not automatically make the in-memory document read-only:

- The source file lacks write permission
- The source requires Save As
- An original PDF is locked
- A PDF rendering backend is missing

A locked or unavailable PDF source may make the session degraded while ordinary AL NOTE annotations remain editable.

A degraded document may remain editable when unknown or unavailable content can be preserved losslessly.

Unknown Objects, fields, resources, and unsupported content remain preserved inertly.

Saving a degraded session is allowed only when preservation is guaranteed.

## PDF Unlock State

PDF unlock state is maintained per PDF resource within the logical Document Session.

Passwords and other secret unlocking material remain memory-only.

They never enter:

- `.alnote` packages
- Recovery
- Workspace-restoration metadata
- Command History
- Logs
- Disk caches

Multiple views sharing a Document Session may use the same approved in-memory unlock session for a resource.

## Close Coordination

Unsaved-change handling uses structured decision requests rather than UI prompts inside Session core logic.

A decision request contains:

- Current Session facts
- Risk flags
- Permitted resolutions
- A stable decision token
- Expiration requirements
- Freshness requirements

The future UI decides how to present the request.

The Session core validates the returned resolution before acting.

Close rules include:

- Clean sessions may close after required job cleanup.
- Dirty sessions require Save, Save As, Discard, or Cancel as applicable.
- Atomic publication is not interrupted unsafely.
- Read-only dirty sessions normally require Save As, Discard, or Cancel.
- External conflicts prevent silent overwrite.
- Degraded sessions may save only when preservation is guaranteed.
- Recovery does not replace unsaved-change handling.
- Discard does not silently determine Recovery-retention policy.
- Closing the final view does not automatically authorize closing the logical session.

## Recovery and Workspace Restoration

Recovery protects committed document work.

Workspace restoration reconstructs sessions and views.

These responsibilities remain separate.

Bounded restoration metadata may contain:

- Restoration schema version
- `RestorationEntryId`
- Safe source locator or platform-granted bookmark
- Recovery reference
- Document-form hint
- View-to-restoration-entry association
- Stable active navigation identities
- Optional viewport identity
- Optional active Tool identity
- Last-focused view
- Clean-shutdown marker

Restoration metadata must not duplicate canonical document content.

Restoration:

- Grants no new filesystem or network authority
- Stores no passwords or unrestricted tokens
- Reopens entries independently
- Uses bounded parallelism
- Represents missing or denied sources explicitly
- Restores uncertain Recovery results as separate dirty documents
- Avoids accidental duplicate logical sessions
- Restores large workspaces incrementally

## Platform Lifecycle

Flutter lifecycle and restoration facilities remain behind AL NOTE-owned contracts and platform adapters.

Lifecycle callbacks are best-effort signals, not durability guarantees.

Lifecycle handling includes:

- Schedule Recovery for dirty committed states when hidden, inactive, paused, or suspended.
- Checkpoint bounded restoration metadata.
- Reduce reproducible cache pressure.
- Use structured close handling for cancellable desktop exits.
- Depend on previously completed Recovery records for forced termination.
- Treat browser unload handling as best-effort.
- Recheck external fingerprints after resume or focus.
- Never start an unrequested canonical Save merely because the application is suspended.
- Never discard immutable roots or required pending durable state because of memory pressure.

## Failure and Cancellation

Operations return structured outcomes such as:

- Completed
- Cancelled
- Stale
- Conflicted
- Failed
- Completed with warnings

Cancellation is cooperative.

Before publication, cancellation produces no published result.

After atomic publication becomes non-cancellable, cancellation means ignoring the result or closing after completion. It does not interrupt publication unsafely.

Late asynchronous results must pass freshness validation.

A failure in one session does not fail unrelated sessions or the application registry.

## Security and Resource Limits

Configurable centralized limits apply to:

- Simultaneously open sessions
- Views per session
- Concurrent jobs
- Loaded document memory
- Derived cache memory
- Restoration entries
- Recovery storage
- PDF work
- Imported resource counts
- Expanded imported size

Restoration must:

- Reject path traversal and unsafe aliases
- Bound schema and entry sizes
- Avoid automatic network access
- Avoid automatic executable-handler loading
- Preserve platform capability boundaries
- Rate-limit repeated failures
- Restore large workspaces incrementally

No state-management or window-management dependency is accepted.

Every later dependency requires a pinned transitive-license, security, maintenance, and bundled-binary audit.

## Repository Ownership

Detailed Document Session contracts belong under:

`lib/documents/sessions/`

Conceptually:

- Application registry and focus coordination belong under `lib/app/`.
- Document Session contracts belong under `lib/documents/sessions/`.
- Platform-independent lifecycle contracts belong under `lib/core/`.
- Platform lifecycle implementations remain behind adapters.

This architecture does not create additional implementation folders.

## Open-Source Record

- Flutter is BSD-3-Clause and may provide lifecycle, focus, exit-request, and restoration primitives behind AL NOTE-owned adapters.
- Flutter lifecycle callbacks are not durability guarantees.
- Rnote is GPL-3.0-or-later and is a conceptual multi-document handwriting reference.
- Xournal++ is GPL-2.0-or-later and is a conceptual autosave and handwriting-document reference; direct reuse requires file-level auditing.
- Krita is GPLv3-compatible and is a conceptual multi-view, recovery, and document-lifecycle reference.
- LibreOffice provides useful Save, AutoRecovery, and multi-document concepts, but direct reuse is unsuitable and individual licensing still requires auditing.
- No state-management or window-management dependency is accepted.

## Deferred Matters

- Exact Dart types
- State-management package
- Window-management package
- Exact restoration encoding
- Exact numerical resource limits
- Cross-process editing locks
- Remote-source semantics
- Sync and collaboration
- Persistent Settings schema
- UI presentation
- Plugin loading and trust
- Default restoration of viewport and active Tool
- Long-lived background saving on mobile and Web
