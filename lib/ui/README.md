# User Interface Architecture

Status: **Accepted with modifications**

## Purpose

The UI presents immutable application, Session, and view state and emits semantic Actions.

It does not directly mutate persistent documents or replace the accepted responsibilities of Commands, Sessions, Tools, Interaction Mapping, Storage, Recovery, Import, Export, Settings, or platform adapters.

## Central Rule

Flutter widgets and presentation controllers must never:

- Directly mutate persistent documents
- Own Command validation
- Reimplement Tool behavior
- Duplicate gesture arbitration
- Perform Storage or Recovery internally
- Become authoritative document state

Persistent operations always pass through accepted application, Session, and Command boundaries.

## Dependency Direction

The conceptual flow is:

`Flutter Widgets → Presentation Controllers → Semantic Action Dispatcher → Application/Session Contracts → Domain Contracts`

UI and concrete platform adapters are outer layers.

Rules:

- UI depends inward on application and domain contracts.
- Concrete platform adapters depend inward on AL NOTE-owned platform contracts.
- Application composition selects and injects concrete adapters.
- Domain subsystems never import widgets, dialogs, or concrete platform implementations.
- Platform integrations must not become persistent document contracts.

## UI Ownership

The UI owns:

- Visual composition
- Adaptive layout
- Presentation-ready state
- Focus scopes
- Action presentation and enablement
- Accessibility semantics
- Status and progress presentation
- Structured-decision presentation
- Platform-appropriate menus and controls

The UI does not own:

- Persistent document truth
- Document Sessions
- Command execution rules
- Gesture arbitration
- Tool behavior
- Save, Import, Export, or Recovery logic
- Persistent Settings
- Platform-service implementation

## Application Shell

The conceptual Application Shell provides:

- Workspace host
- Window and view hosts
- Shared Action presentation
- Status and notification presentation
- Structured-decision presenter
- Application-level overlay presentation
- Theme inputs
- Localization inputs
- Accessibility inputs
- Density inputs

The shell presents Application State but does not own Document Sessions.

Each capable window may provide:

- Window command surfaces
- Document tabs or navigation
- One or more Document View hosts
- Window-specific panels
- Window-specific overlays and focus
- Status presentation

## Document View

A Document View is the reusable presentation unit for:

- A tab
- A split pane
- A separate window
- A mobile full-screen document surface

It presents one logical Document Session through view-specific state.

View-specific state includes:

- Active Section
- Active Page
- Active Layer
- Active Tool
- Selection
- Viewport
- Editor sessions
- Input ownership
- Focus history
- Temporary overlays
- Panel visibility

Views sharing one Session continue to share:

- Immutable document root
- Commands and history
- Dirty and saved state
- Storage source
- Recovery
- Session-wide jobs

Tabs represent Document Views and do not necessarily represent unique Document Sessions.

## Adaptive Layout

Primary layout selection uses capabilities and available presentation space rather than operating-system names.

Inputs include:

- Available width and height
- Pointer precision
- Hover support
- Touch capability
- Stylus capability
- Text scale
- Accessibility preferences
- Windowing capabilities

### Compact Profile

- One primary surface at a time
- Canvas as the main surface
- Navigation, Layers, and inspectors presented through routes, sheets, or temporary panels
- Reachable Tool controls
- No mandatory permanent sidebar

### Medium Profile

- Canvas with one persistent or collapsible navigation region
- Secondary panels presented through drawers, sheets, or overlays
- Stylus-first arrangements may prioritize Tool controls

### Expanded Profile

- Canvas with independently collapsible navigation and inspector regions
- Tabs where appropriate
- Optional split views
- Menus, shortcuts, context menus, and command palette
- Resizable panels with bounded dimensions

Exact responsive breakpoints remain deferred and are not document data.

## Navigation

The UI progressively exposes the accepted hierarchy:

- Notebook Sections
- Pages and thumbnails
- Current Page navigation
- Layers
- Layer ordering
- Layer visibility
- Layer locking
- Layer opacity
- Current selection inspector
- Tool catalog
- Tool options
- Future Search surface

Compact and expanded layouts invoke the same semantic Actions.

The UI does not create a permanent duplicate Object tree unless a later accepted requirement justifies one.

## Semantic Actions

UI surfaces reuse the stable semantic Action identities accepted by Interaction Mapping.

The UI must not create a competing semantic Action registry.

The UI may project presentation descriptors containing:

- Existing stable Action identity
- Localized label
- Localized description
- Icon reference
- Enabled or disabled state
- Checked or selected state
- Presentation scope
- Placement hints

The same semantic Action identities are used by:

- Buttons
- Menus
- Toolbars
- Context menus
- Command palettes
- Accessibility Actions
- Shortcuts

Shortcut bindings remain coordinated with Interaction Mapping and future Settings.

Flutter Actions, Intents, and Shortcuts may implement presentation mechanics behind AL NOTE-owned contracts.

## Command Boundary

Persistent operations follow:

`UI event → Semantic Action → Application/Session validation → Command Request → Committed immutable state → UI update`

The UI does not maintain separate document history.

Undo and redo delegate to the focused Document Session.

Copy is non-mutating.

Cut and destructive paste replacements must publish through Commands.

## Focus and Keyboard Handling

Each window and Document View has explicit focus scopes for:

- Canvas
- Navigation
- Layers
- Tool controls
- Inspectors
- Text editing
- Dialogs
- Temporary surfaces

Modal surfaces trap focus appropriately and restore focus to a meaningful prior target when closed.

Switching views restores the last valid focus target where possible.

Shortcut precedence is:

1. Active editor
2. Active modal or temporary surface
3. Interaction Mapping context
4. Focused Document View
5. Window
6. Application

Active editors retain standard editing shortcuts.

Tool modes must not silently override editor shortcuts while an editor owns focus.

## Canvas Input

Raw Canvas pointer, touch, and stylus input passes through:

1. Input normalization
2. Interaction Mapping
3. Gesture ownership
4. Tool or semantic Action routing

Canvas widgets must not duplicate drawing gesture arbitration through unrelated widget recognizers.

Ordinary UI controls continue to use normal Flutter interaction mechanisms.

## Canvas and Overlay Composition

The Canvas uses separate conceptual presentation planes for:

1. Page and rendered document content
2. Tool previews
3. Selection and transform visuals
4. Hover and hit-test feedback
5. Contextual controls
6. Accessibility and focus representation
7. Blocking modal presentation where required

Page content uses Page coordinates.

Screen-space controls and accessibility focus use screen coordinates.

Coordinate conversion remains owned by Viewport contracts.

A reserved future overlay plane may support snapping. Snapping behavior itself remains deferred and is not an accepted version-1 feature.

Painting and widget rebuilding must never mutate persistent content.

## Tool Options

Tools may expose backend-neutral declarative option descriptors.

The UI maps approved descriptors to controls.

Tools and plugins must not:

- Inject unrestricted Flutter widgets
- Access the complete widget tree
- Bypass semantic Actions
- Mutate documents directly
- Access unrestricted platform services

The exact descriptor schema remains deferred to implementation and the Plugin System.

## Multiple Documents and Windows

- Tabs represent Document Views, not necessarily unique Sessions.
- Split panes use separate Document Views.
- Windows maintain independent layout, focus, panel, tab, and overlay state.
- Mobile normally presents one foreground Document View.
- Closing one view does not close a shared Session.
- Closing the final view delegates to the accepted structured close process.

Split-view and multiple-window support are capability-dependent.

The architecture permits them without requiring identical version-1 behavior on every platform.

## Structured Decisions

The UI maps structured decision requests to appropriate presentations such as:

- Dialogs
- Sheets
- Banners
- Dedicated conflict surfaces

The presentation preserves:

- Decision tokens
- Permitted resolutions
- Freshness
- Expiration
- Cancellation rules
- Validation results

Session core logic does not present dialogs directly.

## Operation Progress

Progress presentation distinguishes:

- Determinate and indeterminate work
- Foreground and background operations
- Cancellable and non-cancellable operations
- Recoverable failures
- Completed-with-warning results
- Degraded output

Transient notifications must not be the only location for unresolved conflicts or data-loss risks.

## Session Status Presentation

The UI explicitly and independently presents:

- Read-only
- Partially loading
- Saving
- Recovering
- Degraded
- Externally changed
- Missing resource
- Unknown content
- Unavailable handler

Placeholders preserve relevant:

- Identity
- Dimensions
- Bounds
- Explanation

A degraded Session may remain editable.

Unknown content must never be silently removed.

## Accessibility

WCAG 2.2 Level AA is the Web design and testing target and a cross-platform accessibility baseline where applicable.

AL NOTE must not claim formal WCAG conformance until an accessibility audit verifies it.

Accessibility requirements include:

- Accessible names, roles, states, and Actions
- Complete keyboard operation
- Logical focus order
- Visible and unobscured focus
- Color-independent meaning
- High-contrast support
- Text scaling
- Reduced-motion support
- Suitable touch targets
- Non-drag alternatives
- Bounded and meaningful announcements

The Canvas provides semantic representation for:

- Current document and Page
- Page position
- Active Tool and editing mode
- Selection count and summaries
- Editable Text Objects
- Important non-text Objects
- Read-only and degraded warnings
- Navigation and editing Actions

The UI must not falsely represent handwriting as recognized text.

Handwriting remains graphical ink unless trusted recognition data exists separately.

Flutter Semantics provides native accessibility integration.

Web behavior follows established WAI-ARIA patterns without inventing custom roles.

## Localization and Bidirectional Layout

- All user-facing strings use localization resources.
- Plurals, dates, numbers, sizes, and shortcut labels are locale-aware.
- Layout uses start and end directionality.
- Appropriate navigation regions and panels mirror under RTL.
- Page geometry does not automatically mirror.
- Layer ordering does not automatically mirror.
- Directional icons mirror only when semantically correct.
- Platform terminology may vary without changing semantic Action identity.

## Theme, Density, and Scale

These concepts remain distinct:

- Theme controls appearance.
- Density controls UI chrome spacing and sizing.
- Responsive layout controls arrangement.
- Document zoom controls Canvas scale.
- Page backgrounds and Object colors remain document data.

Theme, density, contrast, text scale, and reduced-motion preferences never enter document content.

Persistent preference ownership remains with the future Settings and Preferences subsystem.

## Drag-and-Drop, Clipboard, Pickers, and Sharing

UI platform events become typed requests:

- Dropped content becomes an Import inspection request.
- Pasted content becomes an Import or editor-specific paste request.
- Copy produces a safe clipboard representation without document mutation.
- Cut prepares clipboard data and publishes its mutation through Commands.
- Destructive paste replacement publishes through Commands.
- Open picker delegates to Storage.
- Export destination delegates to Export.
- Share uses an Export snapshot followed by the sharing adapter.

Open, Import, Paste, Export, and Share remain distinct semantic Actions.

Opening a source must not be treated as importing it into the active document.

## Performance

Required performance boundaries include:

- Localized presentation updates
- Separation of high-frequency preview repaint from broad widget rebuilding
- Virtualized long navigation lists
- Lazy thumbnails
- Visible-region Page rendering
- Viewport Object culling
- Bounded prefetch
- Throttled hover updates
- Throttled status updates
- Throttled accessibility updates
- Cancellation of obsolete work
- Immutable rendering snapshots
- Large synthetic notebook tests
- Complex Page tests

Derived thumbnails and presentation caches remain outside persistent documents.

## Platform Adapters

Platform adapters expose capabilities for:

- Windows
- Native menus
- File and directory pickers
- Clipboard formats
- Drag-and-drop
- Sharing
- System theme
- Accessibility preferences
- Lifecycle
- Cursor and hover behavior
- Shortcut-label conventions
- Browser restrictions

Adapters expose capabilities rather than domain policy.

Concrete adapters remain outside and depend inward on AL NOTE-owned contracts.

Application composition selects and injects concrete implementations.

## Future Plugin UI Boundaries

Declarative extension locations may later support:

- Tool catalog entries
- Tool-option descriptors
- Object inspectors
- Import Actions
- Export Actions
- Contextual Actions
- Menus
- Command palette
- Non-modal panels

Extensions declare:

- Stable identities
- Semantic Action bindings
- Labels
- Placement hints
- Capability requirements

Plugins must not receive unrestricted access to:

- The widget tree
- Document Sessions
- Focus manager
- Filesystem
- Platform services

Executable widget injection, loading, permissions, trust, and sandboxing remain deferred to the Plugin System.

## UI Testing

The UI remains testable with:

- Fake Application state
- Fake Session state
- Fake semantic Action dispatcher
- Fake decision requests
- Fake platform capabilities
- Fake pickers
- Fake clipboard
- Fake drag-and-drop
- Fake windows
- Fake sharing
- Deterministic viewport sources
- Deterministic input sources

Required test groups include:

- Presentation-controller tests
- Widget Action tests
- Adaptive profile matrices
- Focus tests
- Shortcut-conflict tests
- Semantics-tree tests
- RTL and localization tests
- Text-scale tests
- Contrast tests
- Reduced-motion tests
- Read-only tests
- Degraded and loading tests
- Golden layout tests
- Limited adapter integration tests
- Large-document performance tests

## Repository Ownership

Detailed User Interface architecture belongs under:

`lib/ui/`

Conceptually:

- `lib/ui/` owns Widgets, presentation controllers, Action presentation, adaptive composition, and semantics.
- `lib/app/` owns application coordination and the Session registry.
- `lib/core/` owns shared platform-independent contracts.
- Existing subsystem directories retain their accepted ownership.

No implementation subdivisions are created by this documentation decision.

## Dependency Status

Flutter is the accepted UI framework.

No third-party dependency is accepted for:

- State management
- Docking
- Windowing
- Shortcuts
- UI extensions

Every future dependency requires:

- Pinned-version review
- Transitive-license audit
- Bundled-binary audit
- Security review
- Maintenance review
- Platform review

## Open-Source Record

- Flutter is BSD-3-Clause and is the accepted UI framework.
- Flutter Widgets, Semantics, Focus, Actions, Shortcuts, localization, and adaptive facilities may be reused behind AL NOTE-owned boundaries.
- Flutter architectural guidance is informative rather than a mandatory domain architecture.
- Rnote is a compatible conceptual reference for stylus-first and adaptive note UI; direct reuse requires exact-file auditing.
- Xournal++ is a conceptual handwriting and PDF workflow reference; direct reuse requires exact licensing review.
- Krita is a conceptual reference for Canvas focus, Tool options, panels, workspaces, and large-canvas behavior.
- LibreOffice is a conceptual reference for command dispatch, accessibility, localization, multiple views, and platform abstraction; direct reuse is unsuitable.
- WCAG 2.2 is the Web accessibility design and testing baseline.
- WAI-ARIA Authoring Practices guide Web semantics where applicable.
- No third-party UI dependency is accepted.

## Deferred Matters

- Final visual design and branding
- Exact responsive breakpoints
- Final default shortcuts
- User-configurable panel arrangements
- State-management package
- Window-management and docking package
- Exact split-view availability
- Exact multiple-window platform support
- Workspace layout restoration
- Search UI
- Plugin loading and trust
- Recognition-derived Canvas descriptions
- Formal accessibility-conformance claim
- Platform-native menu implementation details
- Exact Tool-option descriptor schema
