# Settings and Preferences

Status: **Accepted with modifications**

## Purpose

Settings stores user-configurable defaults, preferences, profiles, and presets.

Settings changes do not dirty documents and do not enter document undo or redo.

## Central Boundary

Settings never becomes:

- Document content
- Session state
- View state
- Workspace restoration
- Recovery data
- Command History
- Credential storage
- Mandatory security policy
- Platform capability state
- Build-time configuration

Settings may choose among safe policies but cannot weaken mandatory invariants.

## Version-1 Scopes

Version 1 supports two persistent scopes:

1. User scope
2. Device-local scope

User scope represents choices intended to conceptually follow the user, although version 1 does not implement accounts or Sync.

Device-local scope contains choices tied to the current installation, hardware, or platform capabilities.

Persistent workspace scope remains deferred until workspace identity, portability, and precedence are designed.

Built-in defaults are code-owned definitions rather than stored overrides.

## State Separation

Keep these separate:

- Built-in defaults
- User overrides
- Device-local overrides
- Temporary preview overlays
- Session state
- View state
- Workspace restoration
- Document content
- Build-time configuration
- Security policy
- Platform capability signals
- Secret material

A general panel-layout preference may be a Setting.

Whether a specific panel is currently open in a restored window remains view or restoration state.

## Stable Setting Identity

Built-in Settings use stable namespaced string keys under:

`alnote.settings.*`

Examples include:

- `alnote.settings.appearance.theme`
- `alnote.settings.interaction.activeProfile`
- `alnote.settings.tools.defaultTool`
- `alnote.settings.export.defaultPreset`

The `org.alnote.*` namespace is not used.

The `alnote.*` namespace remains reserved for built-in AL NOTE identities.

Future plugin Settings use namespaces allocated and validated by the Plugin System.

This subsystem does not establish final plugin namespace syntax.

Plugins must never write into `alnote.*` or another plugin’s namespace.

## Typed Definitions

Every registered Setting has a code-owned definition describing:

- Stable key
- Value type
- Setting schema version
- Default-value provider
- Permitted scopes
- Validator
- Normalizer
- Sensitivity classification
- Application timing
- Preview support
- Synchronization eligibility
- Restart requirement
- Deprecation state
- Migration chain
- Resource limits
- Owning domain

Stored records contain versioned overrides rather than authoritative copies of defaults.

## Resolution

Mutable preference layers resolve from highest to lowest priority:

1. Temporary validated preview
2. Device-local override
3. User override
4. Built-in default

A definition controls which scopes it permits.

After resolution, AL NOTE enforces:

- Mandatory security rules
- Preservation requirements
- Platform capabilities
- Accessibility constraints
- Resource limits

These constraints are not ordinary override layers and cannot be disabled through Settings.

Reset removes an override and reveals the next valid inherited value. It does not copy the current default into storage.

## Logical Repository

AL NOTE uses one logical Settings repository containing separate domain records.

Conceptual records include:

- Store metadata and revision
- Appearance and accessibility
- Interaction Mapping profiles
- Tool presets and defaults
- Import and Export presets
- Document-creation defaults
- Recovery preferences
- Namespaced plugin records

The repository avoids:

- One enormous unstructured object
- One physical file for each individual Setting

Each logical record has:

- Schema version
- Record revision
- Integrity metadata
- Unknown-field preservation

Exact physical storage remains an adapter concern.

## Persistence Contracts

AL NOTE owns platform-independent contracts for:

- Settings repository
- Immutable Settings snapshot
- Settings transaction
- Typed change feed
- Persistence adapter
- External-change detection
- Secret-reference resolver

Publication conceptually performs:

1. Read the current revision.
2. Validate the proposed transaction.
3. Begin the adapter transaction.
4. Recheck the expected revision.
5. Write all affected records.
6. Commit atomically or transactionally.
7. Publish a typed change notification.

Adapters report their actual durability and atomicity capabilities.

They must not falsely claim durable success.

## Backend Status

SQLite is a leading native candidate.

IndexedDB is a leading Web candidate.

Neither backend is accepted.

No SQLite Flutter package, Web wrapper, native binary, or persistence dependency is accepted until its exact version, licensing, maintenance, security, concurrency, and platform behavior are audited.

Flutter `shared_preferences` is not accepted as the canonical Settings store because it is primitive-oriented and lacks the structured transaction, durability, migration, and concurrency guarantees required here.

It may later be considered only for noncritical bootstrap hints.

## Validation

Settings are validated when:

- Reading stored records
- Applying drafts
- Importing preference profiles
- Receiving external changes
- Loading plugin-owned records after a plugin becomes available

Validation includes type, scope, namespace, security, resource, and domain constraints.

Invalid values never become active merely because they were stored successfully.

## Migration

Settings migrations are:

- Version-to-version
- Deterministic
- Bounded
- Independently tested
- Applied to a copy or within a transaction
- Published only after complete validation

A verified last-known-good state is preserved where supported.

Malformed values are quarantined or isolated.

Unsupported newer records remain preserved but inactive.

Obsolete records remain until a reviewed migration or removal policy permits deletion.

## Unknown and Plugin Settings

Unknown keys and fields survive load-save cycles structurally equivalently.

Unknown records:

- Remain inactive
- Never become executable behavior
- Are not interpreted without an approved definition
- Remain bounded by resource limits

When a plugin is absent:

- Its stored Settings remain preserved.
- Its stored Settings remain inactive.
- Ordinary reset does not silently delete them.
- Removing unavailable plugin data requires a separate confirmed action.

A plugin may reset only its assigned namespace.

## Change Observation

Domain systems consume immutable Settings snapshots or typed change events through platform-independent contracts.

They do not depend on Flutter widgets.

Each definition declares an application time:

- Immediate
- Next input sequence or gesture
- Next operation
- Next Tool activation or gesture
- Reopen view
- Application restart

Settings changes do not retroactively alter operations already in progress.

## Draft Editing

Settings editing uses a private draft transaction:

1. Capture an immutable base snapshot and revision.
2. Modify draft values.
3. Validate the draft.
4. Optionally install bounded preview overlays.
5. Apply transactionally or cancel.

Settings UI does not directly call live domain systems.

## Preview

Preview overlays:

- Are temporary
- Apply only to explicitly previewable Settings
- Are validated before installation
- Cannot bypass safety constraints
- Do not become stored values until Apply succeeds

Apply validates and commits the draft.

Cancel removes all preview effects.

## Reset

Individual reset removes one override.

Category reset removes known overrides in that category.

Factory reset removes known built-in overrides.

Factory reset preserves unknown plugin data unless its separate removal is explicitly confirmed.

Reset reveals inherited values instead of copying current defaults into storage.

## Interaction Mapping Profiles

Binding profiles are structured, versioned Settings entities with stable UUIDs.

They reference:

- Input conditions
- Stable semantic Action identities
- Valid contexts
- Approved parameters

Validation rejects:

- Malformed conditions
- Invalid Action identities
- Unsafe bindings
- Duplicate conflicts
- Unreachable bindings
- Safety-rule violations

An input sequence captures the effective profile snapshot when it begins.

Gesture ownership freezes after commitment according to the accepted Interaction Mapping architecture.

Profile edits affect later input sequences rather than the active sequence.

Keyboard mappings use the same semantic Action identities with keyboard-specific normalization and conflict validation.

## Tool Presets

Tool presets are structured, versioned records containing:

- Stable preset UUID
- Tool type identity
- Display name
- Tool-owned parameter payload
- Schema version
- Optional provenance
- Preserved unknown fields

An active Tool gesture retains the preset snapshot captured at gesture start.

Changing or deleting a stored preset does not alter the active gesture.

Committed strokes continue to store resolved, self-sufficient appearance data.

An idle selected Tool may adopt newly resolved defaults according to its declared application timing.

## Appearance and Accessibility

Settings may contain:

- Theme
- Density
- Locale
- Contrast preference
- Text-scale policy
- Reduced-motion preference

Platform accessibility signals are capabilities and constraints rather than stored Settings.

Rules:

- Stronger operating-system accessibility requirements are respected.
- AL NOTE preferences may strengthen accessibility.
- Preferences cannot remove keyboard access.
- Preferences cannot hide required focus indicators.
- Preferences cannot disable essential warnings.
- Preferences cannot defeat meaningful system text scaling.
- Mandatory touch-target and safety rules remain enforced.

## Recovery Preferences

Settings may contain Recovery preferences within accepted safe bounds.

Recovery remains enabled by default according to accepted Recovery architecture.

Settings cannot transform Recovery into canonical Save.

Recovery artifacts and recovered document content never enter Settings.

## Document-Creation Defaults

Settings may contain:

- New-Page defaults
- Default paper or background choices
- Default new-document organization

New-document defaults are copied into a validated creation plan.

After creation, resulting Page and document properties become persistent document data.

Later preference changes do not silently rewrite existing documents.

## Import and Export Defaults

Settings may provide defaults such as:

- Preferred export format
- DPI
- JPEG background
- Metadata preference
- Selected export preset
- Import placement defaults

Every operation still constructs an explicit validated plan.

Settings cannot:

- Skip preflight
- Override resource limits
- Disable preservation
- Bypass PDF security
- Approve destructive publication automatically
- Change an already-running operation

Plans capture resolved defaults at operation start.

## Preference-Profile Import and Export

Settings owns preference-profile:

- Schema
- Encoding
- Validation
- Preview
- Application

Preference-profile files are not `.alnote` documents.

They do not enter the document Import and Export format registry.

Settings reuses approved platform source, destination, temporary-publication, and picker capabilities.

Preference-profile formats are:

- Versioned
- Deterministic where practical
- Human-inspectable
- Bounded
- Secret-free

Imported profiles are untrusted and require:

- Bounded parsing
- Schema validation
- Namespace validation
- Conflict handling
- Preview of affected categories
- Explicit confirmation
- Rejection of prohibited safety overrides

Unknown plugin Settings may be preserved but remain inactive.

## Secrets

Ordinary Settings never contain:

- PDF passwords
- Credentials
- Authentication tokens
- Cloud tokens
- Encryption keys
- Recovery contents
- Clipboard contents
- Document content
- Command History

A Setting may store an opaque secret reference containing:

- Secret-provider identity
- Non-secret record identity
- Intended purpose
- Optional account label

Secret material remains in a Security-owned platform secret store.

Settings resolves secret references only through a narrow contract.

Preference-profile exports omit secret references by default and never export secret material.

## Concurrency

Within one process, every view and window shares one authoritative Settings service and immutable current snapshot.

Across processes or browser tabs, Settings uses optimistic revision-based concurrency.

Every transaction includes its expected base revision.

A stale transaction conflicts.

Deterministic non-overlapping changes may be rebased and retried.

Overlapping or semantic conflicts require structured resolution.

Timestamp-based or silent last-writer-wins is prohibited.

Correctness does not depend solely on filesystem locks.

Only complete validated external transactions become active.

## Failure and Corruption

On load failure:

- Return a structured failure.
- Preserve the damaged source.
- Attempt verified last-known-good recovery.
- Otherwise operate temporarily with built-in defaults.
- Do not overwrite the damaged store automatically.
- Isolate damaged logical records where possible.

Repair, reset, or migration publishes a new valid revision only after validation.

Damaged Settings may be made available for privacy-aware diagnostics or explicit export.

## Security and Limits

Configurable limits apply to:

- Total encoded size
- Number of Settings
- Nested depth
- Key length
- String length
- Profiles
- Presets
- Bindings
- Imported-profile size
- Migration steps
- Plugin namespace size
- Change-event rate

Reject:

- Duplicate canonical keys
- Invalid Unicode
- Excessive nesting
- Oversized payloads
- Unsupported numeric ranges
- Namespace impersonation
- Prohibited safety overrides

Settings may choose among safe policies but cannot weaken mandatory invariants.

## Future Sync

Eligible user-scope records prepare for future Sync with:

- Stable record identity
- Explicit scope
- Revision metadata
- Modification provenance
- Synchronization eligibility
- Deterministic encoding

This architecture does not implement:

- Remote transport
- Automatic merge
- Accounts

Device-local Settings and secret references are not synchronizable.

Sync metadata remains outside user-visible value payloads.

## Testing

Required tests include:

- Default resolution
- Scope precedence
- Validation
- Application timing
- Preview cancellation
- Individual reset
- Category reset
- Factory reset
- Migration fixtures
- Unknown-field preservation
- Missing-plugin preservation
- Corruption isolation
- Interrupted writes
- Stale-writer conflicts
- Multi-window observation
- Multi-process coordination
- Browser-tab coordination
- Imported-profile fuzzing
- Resource limits
- Accessibility invariants
- Security invariants
- Secret-export exclusion

Every persistence adapter must pass the same conformance suite.

## Repository Ownership

Detailed Settings architecture belongs under:

`lib/app/settings/`

Conceptually:

- `lib/app/settings/` owns Settings definitions, resolution, validation, migration, transactions, snapshots, and repository contracts.
- Platform persistence implementations remain behind adapters.
- Interaction Mapping and Drawing Tools retain domain meaning and validation extensions.
- Settings owns persistence and resolution for their profiles and presets.
- UI owns Settings presentation only.

No category implementation subdirectories are created by this documentation decision.

## Dependency Status

No Settings persistence dependency or backend is accepted.

SQLite, IndexedDB, and narrowly scoped platform preference stores remain candidates.

Every future dependency requires:

- Pinned-version review
- Transitive-license audit
- Bundled-binary audit
- Security review
- Maintenance review
- Platform review

## Open-Source Record

- Flutter `shared_preferences` is BSD-3-Clause and cross-platform but is intended for simple key-value data and does not guarantee durable completion; it is not accepted as the canonical Settings store.
- SQLite is public domain and is a leading native transactional candidate, but no Flutter binding or bundled binary is accepted.
- IndexedDB is the leading transactional Web candidate, but no Dart or Flutter adapter is accepted.
- Platform preference stores may be considered only for narrow noncritical uses.
- Rnote is GPL-3.0-or-later and is a conceptual Settings and Tool-preset reference.
- Xournal++ is a conceptual Settings, stylus, and PDF-workflow reference; direct reuse requires exact file-level licensing review.
- Krita is a conceptual Tool-preset, backup, and configuration-reset reference.
- LibreOffice is a conceptual layered-configuration reference and is unsuitable for direct reuse.
- No Settings dependency is accepted.

## Deferred Matters

- Persistent workspace scope
- Remote Settings synchronization
- Account profiles
- Cross-device conflict merging
- Complete secret-store architecture
- Plugin trust, sandboxing, and lifecycle
- Exact Settings encoding
- Exact database backend and package
- Final numeric limits
- Final default values
- Settings-screen design
