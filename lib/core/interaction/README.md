# Interaction Mapping System

Status: **Accepted with modifications**

## Purpose

The Interaction Mapping System converts normalized input into one authorized semantic action while respecting:

- Device capabilities
- Application context
- User bindings
- Gesture arbitration
- Pointer ownership
- Safety rules
- Accessibility
- Active interaction sessions

Once an interaction commits to an action, its binding, action parameters, relevant context, Tool, and preset snapshots remain fixed until completion or cancellation.

Lifecycle state may change, but the routing decision cannot be silently reinterpreted.

## Ownership

The Interaction Mapping System owns:

- Stable action identities
- Logical action-registry contracts
- Binding profiles
- Binding validation
- Conflict detection
- Input-context snapshots
- Gesture arbitration
- Logical pointer ownership
- Stylus and touch coexistence policy
- Shared palm-rejection fallback policy
- Mouse, wheel, trackpad, and keyboard mapping
- Temporary overrides
- Lifecycle cancellation
- Safe fallback policy
- Settings-facing schemas
- Controlled action dispatch contracts

It does not own:

- Raw platform input collection
- Pointer normalization
- Drawing Tool behavior
- Stroke generation
- Viewport calculations
- Selection algorithms
- Persistent document mutation
- Command execution
- UI layout
- Settings storage
- Plugin loading or sandboxing
- Rendering

## Core Concepts

- Normalized Input describes what physically occurred.
- A Binding declaratively matches input and context to an action.
- An Interaction Action is a stable semantic operation.
- A Gesture Recognizer interprets unresolved event sequences.
- A Gesture Session owns routing and lifecycle for a recognized interaction.
- A Tool Session is Drawing Tool-owned state created after routing.
- A Viewport Action requests an operation owned by Viewport.

A Gesture Session and Tool Session are different concepts.

## Action Identity and Registry

Actions use stable namespaced string identities.

- `alnote.*` is reserved for built-in actions.
- Exact plugin namespace allocation belongs to the Plugin System.
- Example action names are illustrative, not permanently required syntax.
- One logical registry exposes built-in and available plugin actions.
- Registry entries describe and validate actions without executing persistent mutations.
- Owner subsystems provide handlers through neutral contracts.
- Missing actions remain represented as unavailable where preservation is useful.
- Plugins cannot register under `alnote.*` or another plugin's namespace.

Action descriptions may declare:

- Identity
- Localization key
- Owning subsystem
- Invocation kind
- Parameter schema
- Context and capability requirements
- Continuous, discrete, or temporary behavior
- Compatibility with concurrent actions
- Availability
- Cancellation behavior
- Accessibility alternatives

## Binding Profiles

Bindings are declarative data containing concepts such as:

- Binding identity
- Enabled state
- Input source
- Pointer or tool subtype
- Gesture kind
- Contact count when available
- Required and forbidden buttons
- Required and forbidden modifiers
- Trigger phase
- Context predicate
- Target action
- Validated parameters
- Capability requirements
- Conflict or unavailable state

Profiles are versioned user Settings and may contain:

- Profile identity
- Display name
- Ordered bindings
- Disabled defaults
- Platform-family hints
- Capability conditions
- Palm and stylus or touch preferences
- Multi-touch policy
- Safe-fallback metadata
- Preserved unknown actions and safe fields

Profiles are never stored in `.alnote` documents.

## Recognition and Resolution

Recognition and binding resolution are coordinated, not one rigid sequential pipeline.

1. Normalized input, context, capabilities, and the active profile identify eligible binding candidates.
2. Eligible candidates determine which recognizers participate.
3. Recognizers and arbitration evaluate the unresolved event sequence.
4. One compatible binding and action wins.
5. The routing decision and relevant snapshots become fixed.
6. Controlled dispatch begins.

The system delays commitment only as long as necessary.

After commitment:

- Contact-count changes do not reinterpret the action.
- A committed one-finger action does not silently become a two-finger action.
- A committed two-finger action does not silently become a three-finger action.
- Additional pointers may be rejected, suppressed, or routed to an explicitly compatible concurrent action.

## Context and Precedence

Resolution uses a relevant immutable context snapshot.

Precedence is protected approximately as follows:

1. OS or browser reservations and safety restrictions
2. Active modal or capture owner
3. Focused text editor and IME
4. Existing gesture and pointer ownership
5. Explicit user bindings
6. Built-in contextual defaults
7. Plugin-provided defaults
8. Platform-family defaults
9. Mandatory safe fallback

A user-created binding targeting a plugin action remains an explicit user binding. It is not demoted merely because its target belongs to a plugin.

Equal-specificity conflicts in the same tier are invalid and are not silently resolved by list order.

## Pointer Ownership and Capture

Every pointer has one logical owner.

Possible owners include:

- Pending recognizer
- Tool session
- Viewport session
- Selection session
- UI or modal subsystem
- Rejected or palm-suppressed state

A multi-touch gesture may own multiple pointers as one group. No pointer may belong to conflicting actions.

- Interaction Mapping owns logical routing.
- Drawing Engine coordinates drawing-surface capture.
- Platform adapters perform native capture.
- Capture loss cancels or safely ends the affected interaction.
- Pointer IDs may be reused only after previous ownership closes.

## Stylus, Touch, and Palm Rejection

Supported defaults may include:

- Stylus tip writes.
- Stylus eraser end erases.
- Touch performs navigation.
- Palm-like contacts are suppressed.
- Touch drawing is disabled while reliable stylus contact or proximity is active unless the profile says otherwise.

Platform adapters report available palm rejection, cancellation, proximity, geometry, confidence, and capability information.

Interaction Mapping owns conservative shared fallback policy. Drawing Tools never decide whether input is a palm.

Shared heuristics may consider:

- Stylus proximity or contact
- Contact size or confidence
- Distance from stylus
- Timing relative to stylus activity
- Device reliability

Heuristics must not claim certainty or expose suppressed input to Tools.

## Stylus and Touch Concurrency

Compatible stylus Tool and touch Viewport sessions require guaranteed coordinate continuity.

The safe initial policy is:

- Do not apply Viewport transformations during an active committed stroke unless tested integration preserves continuous document coordinates.
- Touch during an active stroke may be suppressed, delayed, or assigned to a non-transforming compatible action.
- Touch navigation may operate while the stylus is hovering or inactive.
- Future tested policies may permit simultaneous drawing and navigation.
- Exact concurrency defaults remain deferred to testing and Settings.

A Viewport change must never distort or introduce discontinuities into a stored stroke.

## Mouse and Trackpad

Mouse and trackpad input is represented semantically.

Possible mappings include:

- Primary button to active Tool or Selection
- Secondary button to context or temporary action
- Middle button to Pan
- Wheel to Scroll or Pan
- Modifier plus wheel to Zoom
- Trackpad Pan
- Trackpad Pinch
- Optional rotation
- Momentum or inertial phases where available

Trackpad physical finger counts are not assumed to be available.

Browser or OS-reserved gestures are unavailable capabilities rather than ordinary binding failures.

## Keyboard and Text Editing

Keyboard mapping is focus-aware.

- Text editing and IME composition take priority.
- Printable text is not consumed as canvas shortcuts.
- Password and secure-text contexts block global character bindings.
- Lost key-up events are handled by focus-loss cancellation.
- Repeated key-down does not repeatedly create held overrides.
- Platform Command or Control differences belong to default-profile adaptation.

While a text editor owns focus, undo and redo go to that focused editor or its accepted text-editing command integration. They do not automatically dispatch as document-wide undo.

Outside focused editing, normal document undo and redo dispatch may apply.

## Temporary Overrides

Temporary overrides use tokens.

Examples include:

- Space-to-pan
- Stylus-button eraser
- Modifier-to-select

Rules:

- Pressing creates an override token.
- The override affects future gestures.
- Active gestures are not reinterpreted.
- Releasing prevents new overridden gestures.
- Tokens clear on release, focus loss, device disconnect, stylus range loss, profile replacement, or cancellation.
- Nested overrides use deterministic priority.
- Lost release events cannot leave overrides permanently active.

## Cancellation

Affected interactions cancel on:

- Focus loss
- Application suspension
- Capture loss
- Page or document change
- Modal opening
- Device disconnect
- Adapter cancellation
- Owner failure
- Invalidated target subsystem

Cancellation:

- Discards pending recognizer candidates
- Cancels Tool previews and uncommitted work
- Stops Viewport sessions safely
- Clears untrusted held overrides
- Never commits a partial document mutation
- Does not roll back already committed commands

Profile changes affect future gestures only.

## Accessibility and Recovery Paths

Every essential operation requires a non-gesture alternative.

Alternatives are provided for:

- Pan
- Zoom
- Tool selection
- Selection
- Undo and redo
- Cancel or exit
- Open Interaction Settings
- Restore defaults

Profiles preserve recoverable access to navigation, cancel or exit, Interaction Settings, and restoring defaults.

Invalid customization cannot remove every recovery path.

## Settings Boundary

Settings will persist:

- Profiles and versions
- Active-profile selection
- User bindings
- Disabled defaults
- Palm and coexistence preferences
- Platform or device overrides
- Preserved unavailable plugin bindings

Interaction Mapping defines validation and schema contracts but not the Settings storage format.

Profiles support:

- Validation before activation
- Explicit migrations
- Conflict preview
- Reset
- Versioned non-executable import and export
- Safe unknown-field preservation
- Atomic activation after validation
- Last-known-good or default fallback

## Plugin Boundary

Plugin actions use the logical registry under restricted namespaces.

Plugins receive only sanitized context and controlled dispatch capabilities.

They cannot receive:

- Unrestricted platform events
- Other pointers' streams
- Raw device identifiers
- Arbitrary keyboard input
- Rendering APIs
- Mutable document state
- A path around Tools, Viewport, Selection, or Commands

Plugin actions may return only controlled results such as:

- Invoke a registered Tool
- Submit a validated Command Request
- Request an allowed Viewport operation
- Request a registered application action
- Decline or fail

Any persistent effect still passes through the Command System.

Plugin failure cancels the invocation without rerouting it mid-gesture.

Missing plugin actions remain visible as unavailable bindings when safely preservable.

## Security and Privacy

- Input remains transient.
- Raw input histories are not stored in profiles or documents.
- Typed content is not exposed to canvas or plugin actions.
- Device identity remains coarse or pseudonymous unless explicitly needed.
- Imported profiles are non-executable data.
- Plugin parameters are schema-validated.
- Dispatch follows least authority.
- Diagnostics avoid stroke paths and typed content by default.

## Platform Boundaries

Platform adapters provide normalized input and capability descriptions.

Shared resolution is based on capabilities and conventions rather than scattered operating-system checks.

Flutter input, Gesture Arena, Focus, Shortcuts, and Actions may provide framework mechanics, but AL NOTE owns profile semantics, arbitration policy, and action identity.

Native adapters may supplement Flutter when required.

## Folder Ownership and Dependencies

`lib/core/interaction/` owns:

- Action identities and registry contracts
- Bindings and profiles
- Context snapshots
- Resolution and precedence
- Gesture arbitration
- Logical pointer ownership
- Temporary overrides
- Lifecycle cancellation
- Validation and fallback policy
- Settings-facing schemas
- Neutral controlled-dispatch contracts

`lib/drawing/input/` continues to own normalized drawing-surface input contracts and capture bridging.

Dependency boundaries are:

- `lib/core/interaction/` does not import concrete Tool, Viewport, Selection, Command, or plugin implementations.
- Owner subsystems expose or register neutral action descriptions and handler adapters.
- Application composition wires handlers to the registry.
- Documents do not depend on Interaction Mapping.
- Settings persistence does not become part of the resolver.

No implementation subfolders are defined yet.

## Dependency Status

No new Interaction Mapping dependency is accepted.

## Open-Source Record

- Flutter is BSD-3-Clause and is the framework foundation.
- Flutter's recognizers and Gesture Arena do not replace AL NOTE's mapping profiles or cross-device policy.
- Rnote is GPL-3.0-or-later and is a behavioral reference.
- Xournal++ is displayed as GPL-2.0; direct reuse requires file-level and dependency auditing.
- Krita describes the application as GPLv3 and is a conceptual profile and action reference; direct code reuse requires file-level auditing.
- W3C Pointer Events is the Web behavioral reference.
- Android stylus APIs are platform references behind adapters.
- Windows Pointer and Ink remain behind a Windows adapter if needed.
- libinput is a Linux behavioral reference, not a shared-logic dependency.
- No new Interaction Mapping dependency is accepted.

## Deferred Matters

- Exact profile serialization
- Settings synchronization
- Device-profile identity
- Profile-editing UI
- Gesture thresholds
- Palm heuristics
- Complete default bindings
- Stylus and touch concurrency defaults
- Plugin permissions and loading
- Accessibility API integration
- Device calibration
- Rotation gestures
- Diagnostic logging and device inspection
- Per-workspace versus global profiles
- Exact native adapter requirements
- Exact Interaction Mapping dependencies
