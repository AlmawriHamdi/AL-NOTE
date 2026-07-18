# AL NOTE Architecture

This document records architecture approved by the Main Architect, the subsystem roadmap, and the stable decision ledger.

## Subsystem Status

| Subsystem | Status | Notes |
|---|---|---|
| Object System | Accepted with modifications | Defines the persistent, platform-independent page-object model |
| Layer System | Accepted with modifications | Owns layer structure, object membership, and ordering |
| Selection and Transform System | Accepted with modifications | Owns temporary page-scoped selection and transform previews |
| Command, Undo, and Redo System | Accepted with modifications | Exclusively coordinates persistent mutations and session history |
| Storage, Serialization, and AL NOTE File Format | Accepted with modifications | Owns durable packages, serialization, resources, and file safety |
| Autosave and Recovery | Accepted with modifications | Owns recovery scheduling, checkpoints, journals, reconstruction, and cleanup |
| Drawing Tool System | Accepted with modifications | Converts assigned normalized input into previews and atomic Command Requests |
| Interaction Mapping System | Accepted with modifications | Owns semantic action mapping, arbitration, pointer ownership, and binding profiles |
| Text Object System | Accepted with modifications | Owns persistent Unicode text, constrained formatting, layout, and editing contracts |
| Image Object System | Accepted with modifications | Owns persistent image payloads, resource references, orientation, crop, and image boundaries |
| Shape Object System | Accepted with modifications | Owns built-in shape kinds, intrinsic geometry, styles, validation, and migrations |
| PDF System | Accepted with modifications | Owns immutable PDF sources, page references, bindings, and engine-neutral PDF contracts |
| Import and Export System | Accepted with modifications | Owns external-content orchestration, immutable plans and snapshots, and safe publication |
| Application State and Document Sessions | Accepted with modifications | Owns logical document sessions, shared state, view associations, lifecycle coordination, and restoration |
| User Interface Architecture | Accepted with modifications | Owns adaptive presentation, semantic Action surfaces, focus, accessibility, and platform-responsive UI composition |
| Settings and Preferences | Accepted with modifications | Owns typed preferences, scopes, profiles, presets, validation, migration, transactions, and change observation |
| Plugin System | Accepted with modifications | Owns bounded declarative packages, identities, validation, trust coordination, atomic registries, lifecycle, and preservation |
| Search and Indexing | Accepted with modifications | Owns derived searchable projections, scanning, memory indexing, query semantics, ranking, results, and freshness reporting |
| Security and Privacy Architecture | Next subsystem | Will define security policy, threat boundaries, sensitive-data handling, audit ownership, and privacy controls |
| Recognition, Mathematics, and Optional Sync/Cloud | Post-v1 | Official future goals preserved by version-1 architecture without premature implementation |

## Object System

The Object System defines the persistent, platform-independent model for everything placed on a page, including handwriting, text, images, shapes, PDFs, and future plugin-defined objects.

### Accepted Ownership Boundaries

- The Object System owns object identity, type identity, common persistent state, payload boundaries, transforms, and validation contracts.
- Object types own intrinsic geometry, payload validation, and schema migrations.
- The Layer System owns membership and ordering.
- The Drawing Renderer owns rendering execution.
- The Hit-Testing System owns hit-testing execution.
- The Storage System owns encoding, decoding, and migration orchestration.
- The Command System will later own applying and reversing object replacements.
- The Plugin System will later own plugin loading, trust, permissions, and registration lifecycle.

The detailed Object System architecture is recorded in [lib/documents/objects/README.md](lib/documents/objects/README.md).

## Layer System

The Layer System provides the authoritative structure:

**Page → ordered layers → ordered objects**

### Accepted Ownership Boundaries

- The Layer System owns layer identity and persistent common state.
- Pages exclusively own their ordered layers.
- Layers directly own their ordered object values.
- The Layer System owns layer order and object order within layers.
- It owns safe object movement between layers.
- It owns effective layer visibility and locking.
- It owns layer lifecycle and validation.
- It does not own rendering, selection interaction, undo history, storage encoding, plugin loading, or UI state.

The detailed Layer System architecture is recorded in [lib/documents/layers/README.md](lib/documents/layers/README.md).

## Selection and Transform System

The Selection and Transform System provides temporary, page-scoped selection and transformation without placing interaction state inside persistent document objects.

### Accepted Ownership Boundaries

- It resolves point, rectangle, and lasso selection.
- It owns temporary page-editing selection state.
- It calculates selection geometry and interaction overlays.
- It previews movement, resizing, and rotation without mutating persistent documents.
- It enforces capabilities, visibility, locking, and Page boundaries.
- It prepares atomic requests for the future Command System.
- It supports whole-object and handwriting-stroke sub-target selection.
- It does not own persistent document mutation.
- Documents must not depend on Selection.

The detailed Selection and Transform System architecture is recorded in [lib/drawing/selection/README.md](lib/drawing/selection/README.md).

## Command, Undo, and Redo System

The Command, Undo, and Redo System is the only normal path for changing persistent AL NOTE document state.

### Accepted Ownership Boundaries

- A document-scoped mutation coordinator exclusively publishes persistent state.
- It owns Command Request and Prepared Transaction contracts.
- It owns final validation inside the serialized mutation boundary.
- It owns atomic document-root publication.
- It owns session-only linear undo and redo history.
- It owns scoped revision tracking and stale-request detection.
- It owns committed-change descriptions.
- It tracks session content-state identities for dirty-state comparison.
- It retains history references to resources without owning physical resource storage.
- External effects and asynchronous preparation occur outside reversible domain commands.

The detailed Command, Undo, and Redo architecture is recorded in [lib/documents/commands/README.md](lib/documents/commands/README.md).

## Storage, Serialization, and AL NOTE File Format

The Storage subsystem converts captured immutable document states and their resources into durable, portable, verifiable `.alnote` packages and reconstructs them without silently losing persistent information.

### Accepted Ownership Boundaries

- It owns the AL NOTE-specific, ODF-inspired ZIP package contract.
- It owns deterministic version-1 UTF-8 JSON serialization.
- It owns the manifest, structured-record catalog, and resource catalog.
- It owns resource repository contracts using logical UUIDs and SHA-256 hashes.
- It owns preservation-capable parsing and unknown-record preservation.
- It owns migration planning, orchestration, and complete-result validation.
- It owns staged loading, bounded validation, and lazy Page and resource loading.
- It owns save and load coordination and atomic-replacement abstractions.
- It owns external-change fingerprints.
- Platform adapters own platform file, stream, replacement, locking, permission, quota, and browser-storage primitives.
- It does not own undo history, autosave scheduling, recovery journals, rendering, import/export workflows, plugin execution, sync, encryption, or file-picker UI.

The detailed Storage architecture is recorded in [lib/documents/files/README.md](lib/documents/files/README.md).

## Autosave and Recovery

Autosave and Recovery protects committed document work through complete durable checkpoints, short append-only journals, retained resources, and versioned recovery manifests.

### Accepted Ownership Boundaries

- Recovery is enabled by default and remains separate from canonical `.alnote` saving.
- Journal entries contain committed persistent after-state replacements, not commands, UI events, previews, or undo history.
- Each logical in-memory document has one serialized recovery writer shared by coordinated views.
- Scheduling combines quiet-period debounce, maximum dirty-state age, checkpoint thresholds, and lifecycle flushes.
- Durable generations, journal sequences, hashes, transaction UUIDs, and commit markers define recovery order.
- Previous valid generations remain until replacement publication is validated and durable.
- Startup reconstruction uses the newest valid checkpoint and its newest valid journal prefix.
- Restored work opens dirty with a new Command History baseline and never automatically overwrites a canonical file.
- Conflicting or uncertain recovery opens as a separate recovered document.
- Recovery retains every resource reachable from valid generations and active recovery work.
- Uncoordinated processes or browser tabs create separate recovery branches rather than merging automatically.
- Cleanup requires a covered normal save, explicit discard, or confirmed save of a recovered candidate.
- Platform adapters own storage locations, durability primitives, locking, leases, quota reporting, and lifecycle notifications.
- Recovery artifacts receive private-document security and hostile-input protections.
- Recovery architecture belongs under `lib/documents/recovery/`.
- No recovery implementation dependency or backend is accepted yet.

The detailed Autosave and Recovery architecture is recorded in [lib/documents/recovery/README.md](lib/documents/recovery/README.md).

## Drawing Tool System

The Drawing Tool System converts normalized input already assigned by Interaction Mapping into temporary previews, safe gesture outcomes, validated atomic Command Requests, and delegation to specialized systems.

### Accepted Ownership Boundaries

- Tools never directly mutate persistent document state.
- Immutable tool definitions create isolated mutable gesture sessions from preset snapshots.
- Tools use stable namespaced identities and one logical registry.
- `alnote.*` is reserved for built-in tools; plugin namespace allocation remains deferred.
- Interaction Mapping selects tools and assigns normalized input.
- Tools do not own general pointer, keyboard, or gesture arbitration.
- Gesture sessions default to one primary pointer.
- The Drawing Engine coordinates pointer capture while platform adapters perform native capture.
- Tool changes normally affect the next gesture; active gestures retain their original tool and preset snapshot.
- Previews use page or document coordinates and remain outside persistent objects, history, storage, and recovery.
- Completed gestures propose atomic Command Requests.
- Stale or rejected requests produce no persistent change and are not silently replayed.
- Pen variants share Stroke System services and differ through validated behavior and appearance profiles.
- Erasers use Hit-Testing and stroke-splitting services and commit atomically.
- Selection delegates to the Selection System.
- Pan and navigation belong to Interaction Mapping and Viewport.
- Insertion tools use placement sessions while owning object and import systems define persistent payloads.
- Committed strokes contain resolved, self-sufficient appearance and behavior data.
- Active tools, sessions, previews, presets, and other interface state are not document data.
- Plugin tools receive restricted services and cannot bypass Command validation.
- Recovery records only completed persistent results committed through Commands.
- Drawing Tool architecture belongs under `lib/drawing/tools/`.
- No Drawing Tool dependency is accepted yet.

The detailed Drawing Tool System architecture is recorded in [lib/drawing/tools/README.md](lib/drawing/tools/README.md).

## Interaction Mapping System

The Interaction Mapping System converts normalized input into one authorized semantic action while respecting device capabilities, application context, user bindings, arbitration, pointer ownership, safety, accessibility, and active sessions.

### Accepted Ownership Boundaries

- Interaction Mapping remains separate from raw platform input collection and normalization.
- Actions use stable namespaced identities and one logical registry.
- `alnote.*` is reserved for built-in actions.
- Binding profiles are versioned Settings data and never document data.
- Bindings may combine device, gesture, buttons, modifiers, context, and capabilities.
- Candidate selection, recognition, arbitration, and resolution are coordinated.
- Once an interaction commits, its binding, parameters, context, Tool, and preset snapshots remain fixed.
- Every pointer has one logical owner; multi-touch gestures may own pointer groups.
- Safety restrictions, focus, and existing ownership precede customizable bindings.
- Equal-specificity conflicts in the same tier are invalid.
- Platform palm rejection precedes conservative shared fallback policy.
- Drawing Tools never determine whether input is a palm.
- Stylus and touch concurrency requires guaranteed document-coordinate continuity.
- Viewport changes must never distort or introduce discontinuities into stored strokes.
- Keyboard dispatch is focus-aware.
- Focused text editors retain their accepted undo and redo context.
- Temporary overrides use tokens and affect only future gestures.
- Lifecycle disruption cancels uncommitted interactions without partial mutation.
- Essential actions retain accessible alternatives, recovery paths, and reset access.
- Plugin actions use restricted namespaces, sanitized context, and controlled dispatch.
- Shared behavior resolves from capabilities while native details remain in platform adapters.
- Interaction architecture belongs under `lib/core/interaction/` and uses neutral contracts.
- `lib/drawing/input/` retains normalized drawing-surface input and capture-bridging ownership.
- No new Interaction Mapping dependency is accepted.

The detailed Interaction Mapping architecture is recorded in [lib/core/interaction/README.md](lib/core/interaction/README.md).

## Text Object System

The Text Object System provides searchable, accessible, editable Unicode text as transformable Page Objects using the built-in identity `alnote.text`.

### Accepted Ownership Boundaries

- Text Objects use the accepted common Object envelope without duplicating the type-schema version.
- Version 1 uses constrained rich text with ordered paragraphs and styled runs.
- Logical Unicode text and explicit paragraph boundaries are authoritative.
- Soft wrapping, glyphs, caret maps, and layout fragments are derived.
- Character styles provide controlled built-in formatting.
- Paragraph styles include alignment, direction, line height, and optional BCP 47 language hints.
- Persistent ranges use paragraph position, Unicode-scalar boundaries, and expected object revision.
- Ordinary editing respects extended grapheme-cluster boundaries.
- Text boxes support bounded auto-size, fixed-width automatic-height, and fixed-box modes.
- Box resizing reflows text while common transform scaling does not.
- Fonts use open-licensed bundled baselines, legal embedded resources, system requests, and controlled fallback.
- Arbitrary system fonts are never embedded automatically.
- AL NOTE owns a platform-independent layout contract over maintained Unicode-aware services.
- Editor sessions own temporary drafts, caret, selection, IME, and layout state.
- Persistent edits commit through Commands with bounded latency.
- Command History provides semantic typing coalescing without weakening Recovery.
- Stale edits are rejected and preserved without automatic merge or rebase.
- Clipboard input is sanitized before Command submission.
- Rendering, Search, accessibility, hit-testing, and export consume controlled Text contracts.
- Corrupt or unknown payloads remain preserved; fallback display does not silently rewrite them.
- Version 1 authoritative styles and layout semantics are built-in only.
- Structured mathematics remains separate from ordinary Unicode Text Objects.
- Text Object architecture belongs under `lib/documents/objects/text/`.
- No external editor library is accepted.

The detailed Text Object System architecture is recorded in [lib/documents/objects/text/README.md](lib/documents/objects/text/README.md).

## Image Object System

The Image Object System provides persistent raster images as transformable Page Objects using the built-in identity `alnote.image`.

### Accepted Ownership Boundaries

- Each Image Object references one immutable generic document resource.
- The common Object envelope owns `typeSchemaVersion`; the Image payload does not duplicate it.
- The payload records the resource UUID, verified encoded dimensions, oriented intrinsic size, explicit orientation, normalized crop, rendering intent, and optional user-authored alternative text.
- Resource hashes and generic media metadata remain owned by the resource manifest.
- Unknown type-specific Image fields remain preserved inside the payload according to Storage rules.
- Original encoded bytes and persistent Image fields are authoritative.
- Decoded pixels, thumbnails, caches, color conversions, alpha masks, and OCR results are derived.
- PNG and JPEG are the only guaranteed version-1 image formats.
- Explicit orientation preserves original bytes and prevents double auto-orientation.
- Crop coordinates use normalized oriented-source space before the common Object transform.
- Cropping is nondestructive.
- Movement, rotation, and positive scaling use the common Object transform.
- Default physical size uses trustworthy bounded resolution metadata or 96 DPI.
- Default placement preserves aspect ratio, fits down to the Page, and does not automatically upscale.
- Background and movable images use the same Image Object type.
- Background constraints belong to the Layer System rather than an `isBackground` payload field.
- Import validates bounded bytes before an atomic Command publishes the resource and object.
- Duplicate Image Objects receive new Object UUIDs while sharing immutable resource bytes.
- Rendering, decoding, caching, color conversion, and precise hit testing remain derived and behind controlled contracts.
- Missing, corrupt, unsupported, or quarantined resources preserve the object and display a stable placeholder.
- Normal external export strips sensitive source metadata by default.
- Future OCR remains outside the Image Object and uses explicit source identity and revision information.
- Future Sync addresses immutable bytes by hash and logical resources by UUID.
- Remote URLs and cloud locators do not belong in the version-1 Image payload.
- No external Image dependency is accepted.

The detailed Image Object System architecture is recorded in [lib/documents/objects/image/README.md](lib/documents/objects/image/README.md).

## Post-v1 Compatibility Boundaries

Handwriting Recognition and OCR, Math Recognition, the Symbolic Math Engine, and optional Sync or Cloud are official post-v1 goals. They are not required for the first build.

Version 1 preserves:

- Raw vector strokes
- Original image pixels
- Stable coordinates and transforms
- Immutable resource identities
- Versioned schemas
- Unknown data
- Extension boundaries

This preservation allows future systems to be added without implementing them prematurely.

Handwritten mathematics will eventually use cooperating boundaries:

Stored handwriting → Math Recognition → structured mathematics → Symbolic Math Engine → evaluated or solved result

These future subsystems remain undesigned. Their specialist assignments must perform open-source and licensing evaluation before proposing internal architecture or dependencies.

## Shape Object System

The Shape Object System provides editable, deterministic, vector-quality geometric Page Objects using the built-in Object type `alnote.shape`.

### Accepted Ownership Boundaries

- Built-in shapes use permanent string-based `shapeKind` identifiers.
- Version 1 supports `line`, `rectangle`, `ellipse`, `polygon`, and `polyline`.
- Arrows, rounded rectangles, and circles are variations rather than separate persistent kinds.
- Lines, rectangles, and ellipses retain parametric geometry.
- Polygons and polylines retain ordered vertices.
- General authoritative paths remain deferred.
- The Shape payload contains intrinsic geometry, explicit stroke and fill records, Shape opacity, and preserved unknown fields.
- The common Object envelope owns `typeSchemaVersion`; the Shape payload does not duplicate it.
- Styles use backend-neutral finite RGBA values, enabled states, solid fills, caps, joins, miter limits, and bounded dash semantics.
- Rectangles may use one uniform nonnegative corner radius.
- Arrowheads are bounded endpoint decorations rather than separate Objects or geometry kinds.
- Whole-object Selection transforms update only the common Object transform.
- Direct Shape editing replaces intrinsic geometry through Commands.
- Whole-object transforms affect the composed geometry and appearance without automatically baking transforms.
- Geometry, visual, and interaction bounds remain distinct.
- Interaction tolerance is transient and never serialized.
- Hit testing uses Page-space broad-phase rejection followed by inverse-transform local tests.
- Rendering and export consume backend-neutral semantic Shape data.
- Rasterization is a last resort and never replaces persistent geometry.
- Persistent changes use replacement-oriented Commands.
- Duplication creates a new Object UUID while copying geometry, style, transform, and unknown fields.
- Version-1 vertices have no independent identity.
- Degenerate, unsupported, unknown, and unsafe data remain distinguished.
- Unknown Shape kinds are preserved and never silently converted to fallback rectangles.
- Plugin-defined shapes use their own namespaced Object type keys.
- Plugins cannot add private kinds under `alnote.shape`.
- Configurable validation limits bound geometry and processing work.
- Shape payloads, validation, and migration belong under `lib/documents/objects/shape/`.
- Rendering and hit-testing implementations remain in their accepted Drawing areas.
- No external Shape or geometry dependency is accepted.

The detailed Shape Object System architecture is recorded in [lib/documents/objects/shape/README.md](lib/documents/objects/shape/README.md).

## PDF System

The PDF System preserves original PDF bytes as immutable resources while all new editable annotations remain ordinary AL NOTE Page Objects stored separately from the source.

### Accepted Ownership Boundaries

- Standalone PDFs use the existing Standalone PDF document form and a document-level immutable source binding.
- Each displayed PDF page becomes an ordinary AL NOTE Page with one constrained source layer and editable layers above it.
- Source layers and movable PDF Page Objects share a versioned `PdfPageReference`.
- Page references persist resource UUID, zero-based page index, resolved source box, effective rotation, displayed dimensions, and unknown fields.
- PDF source layers use the stable `alnote.pdf.source` binding.
- The PDF System owns binding semantics while the Layer System retains general layer ownership.
- Movable PDF pages use Object type `alnote.pdf.page`.
- Version 1 creates one independent Object per selected source page.
- PDF-local coordinates use points with top-left origin, positive Y downward, and effective rotation applied.
- Valid CropBox is the default, with MediaBox fallback.
- Source-layer mapping, box, rotation, and dimensions remain fixed after creation.
- Multiple Pages, layers, and Objects may share one immutable PDF resource.
- Existing native PDF annotations remain preserved in original bytes and render read-only through safe appearances.
- Active content and unsafe PDF actions remain disabled.
- Passwords and unlocking state remain session-only secrets.
- Rendering, extraction, links, outlines, accessibility interpretations, tiles, and backend handles remain derived.
- PDF preparation is asynchronous, followed by atomic Command publication.
- Normal export creates a new sanitized PDF and never modifies the original resource.
- Safe vector source content is reused where practical.
- Native appearances and AL NOTE Objects are flattened exactly once.
- Unsafe actions, embedded files, unsupported interactivity, and original signature claims are omitted.
- Missing, locked, corrupt, unsupported, quarantined, or backend-unavailable PDFs preserve all references and annotations through placeholders.
- Persistent PDF changes use Commands; rendering, extraction, passwords, and caches do not enter history.
- Backends and plugins use engine-neutral restricted contracts.
- Parsing, rendering, extraction, and export enforce configurable resource limits.
- AL NOTE reuses a mature PDF engine rather than implementing a parser or renderer.
- No PDF backend or export dependency is accepted yet.
- PDF architecture belongs under `lib/documents/pdf/`.

The detailed PDF System architecture is recorded in [lib/documents/pdf/README.md](lib/documents/pdf/README.md).

## Import and Export System

The Import and Export System orchestrates safe external-content ingestion and privacy-aware output generation without owning format internals or directly mutating documents.

### Accepted Ownership Boundaries

- Open, Save, and Save As `.alnote` remain owned by Storage.
- Opening standalone PDFs belongs to PDF plus the future Document Sessions System.
- Import and Insert external content belong to Import.
- PDF, PNG, and JPEG output generation belongs to Export.
- Sharing completed artifacts belongs to platform adapters after Export.
- Share is not an export format.
- Guaranteed version-1 formats are PDF, PNG, and JPEG.
- Stable identifiers use `alnote.format.pdf`, `alnote.format.png`, and `alnote.format.jpeg`.
- Import detection inspects actual content and treats extensions and MIME types only as hints.
- Import preparation produces immutable, temporary, nonpersistent Prepared Import Plans.
- Staged resources use bounded, expiring, host-owned tokens.
- Final destinations use stable Section, Page, and Layer identities.
- Import publication occurs exclusively through Commands.
- One PDF's selected Pages form one atomic import by default.
- Independent source files default to separate transactions.
- Partial success is allowed only between declared transaction groups.
- Export operates on one immutable document revision.
- Live edits do not alter an export already in progress.
- Export pins its resolved renderer and type-handler set for the job's lifetime.
- Export does not mutate the document or enter Command History.
- Selected-object export is Page-scoped in version 1.
- PDF construction and sanitization remain owned by the PDF System.
- PNG is the default raster format.
- JPEG requires an explicit opaque background and defaults to white.
- Raster export defaults to 144 DPI and remains screen-independent.
- Multipage raster export defaults to one output file per Page.
- Separate output files are not globally atomic.
- ZIP may be offered when one destination artifact is required.
- Output uses temporary generation and safe destination commit where supported.
- Platform adapters expose source, destination, temporary-output, commit, and sharing capabilities.
- Shared logic does not assume filesystem paths on Android or Web.
- Cancellation, failure, partial publication, and degradation use structured results.
- Silent omission of content is forbidden.
- Export metadata uses privacy-safe defaults; author metadata is opt-in.
- Plugin importers and exporters remain declarative and constrained.
- No external Import or Export dependency is accepted.

Detailed architecture is recorded in:

- [lib/documents/import/README.md](lib/documents/import/README.md)
- [lib/documents/export/README.md](lib/documents/export/README.md)

## Application State and Document Sessions

Application State coordinates logical open documents, attached views, focused-view state, lifecycle distribution, application-wide limits, and bounded workspace restoration.

### Accepted Ownership Boundaries

- One Document Session represents one logical open working document.
- Application State owns the Session registry, view associations, focused-view coordination, lifecycle distribution, and application-wide limits.
- A Session coordinates the immutable document root, Commands, document-wide history, saved-state identity, Storage source, external fingerprint, Recovery writer, PDF unlock state, asynchronous operations, and attached views.
- Persistent document, Session, view, application, Settings, Recovery, and restoration state remain separate.
- Runtime Session IDs, restoration metadata, history, selections, Tools, viewports, passwords, caches, and fingerprints never enter persistent `.alnote` content.
- Canonically equivalent sources normally share one logical Session unless a separate copy is explicitly requested.
- Multiple views may share one Session while navigation, selection, Tools, editors, viewports, input ownership, and previews remain view-specific.
- Commands from every attached view publish one shared immutable root; undo and redo remain document-scoped.
- Active references are repaired deterministically using stable identities, previous ordering, valid parentage, and explicit no-target states.
- Lifecycle, readiness, access, fidelity, and external-source state remain independent axes.
- Dirty state depends only on current and saved content-state identity.
- Save and Save As publish immutable captured states while newer editing may continue.
- Canonical publications are serialized per Session.
- Export remains non-mutating and uses one immutable snapshot.
- Import destinations, capabilities, staged resources, and freshness are revalidated before Command publication.
- External-source state remains separate from dirty state and never causes silent overwrite or reload.
- Read-only and degraded remain independent.
- PDF unlocking secrets remain per-resource, Session-scoped, and memory-only.
- Close and conflict handling use structured, freshness-validated decision requests independent of UI presentation.
- Recovery protects committed work while workspace restoration reconstructs Sessions and views.
- Platform lifecycle callbacks remain best-effort adapter signals rather than durability guarantees.
- Operations use structured results, cooperative cancellation, and freshness validation.
- Resource use, restoration, concurrency, and dependencies remain bounded by centralized security policies.
- No state-management or window-management dependency is accepted.

The detailed architecture is recorded in [lib/documents/sessions/README.md](lib/documents/sessions/README.md).

## User Interface Architecture

The User Interface presents immutable application, Session, and view state and emits the semantic Actions already accepted by Interaction Mapping.

### Accepted Ownership Boundaries

- Flutter Widgets and presentation controllers never directly mutate persistent documents.
- UI and concrete platform adapters are outer layers that depend inward on AL NOTE-owned contracts.
- Application composition selects and injects concrete platform implementations.
- The UI owns visual composition, adaptive layout, presentation state, focus scopes, Action presentation, accessibility semantics, progress, status, and structured-decision presentation.
- The UI does not own persistent document truth, Document Sessions, Command rules, gesture arbitration, Tool behavior, Storage, Recovery, Import, Export, persistent Settings, or platform-service implementations.
- Document View is the reusable view-specific presentation unit for tabs, panes, windows, and mobile document surfaces.
- Session-wide state remains separate from view, window, panel, overlay, focus, and preference state.
- Compact, medium, and expanded layouts are chosen from available space and capabilities rather than operating-system identity.
- Notebook, Page, Layer, selection, and Tool surfaces invoke shared semantic Actions across all layouts.
- UI descriptors add labels, icons, enablement, selection state, scopes, and placement hints without creating a competing Action registry.
- Persistent UI operations publish through validated Command Requests.
- Copy remains non-mutating; cut and destructive paste replacements publish through Commands.
- Active editors have first shortcut precedence and retain standard editing shortcuts.
- Canvas input passes through normalization, Interaction Mapping, gesture ownership, and Tool or Action routing.
- Canvas widgets do not duplicate drawing gesture arbitration.
- Content, previews, Selection, feedback, contextual controls, and accessibility focus occupy separate non-mutating presentation planes.
- A future overlay plane may support snapping, but snapping remains deferred.
- Tools expose only backend-neutral declarative option descriptors, never unrestricted Flutter widgets.
- Structured-decision presentation preserves tokens, permitted resolutions, freshness, expiration, cancellation, and validation.
- Read-only, loading, saving, Recovery, degraded, external-change, missing-resource, and unknown-content states receive explicit non-destructive presentation.
- WCAG 2.2 AA is the Web design and testing target, but formal conformance is not claimed without an audit.
- Canvas semantics do not falsely represent handwriting as recognized text.
- Localization, RTL, theme, density, text scale, reduced motion, and responsive arrangement remain outside document content.
- Drag-and-drop, clipboard, pickers, and sharing cross typed subsystem boundaries.
- High-frequency repaint, virtualization, lazy thumbnails, culling, bounded prefetch, and throttling prevent broad unnecessary rebuilding.
- Platform adapters expose capabilities rather than domain policy.
- Multiple-window and split-view support remain capability-dependent.
- Future plugin UI contributions remain declarative and constrained.
- No third-party state-management, docking, windowing, shortcut, or UI-extension dependency is accepted.

The detailed User Interface architecture is recorded in [lib/ui/README.md](lib/ui/README.md).

## Settings and Preferences

Settings stores user-configurable defaults, preferences, profiles, and presets without becoming document, Session, Recovery, credential, security-policy, capability, or build-time state.

### Accepted Ownership Boundaries

- Version 1 supports persistent user and device-local scopes; persistent workspace scope remains deferred.
- Built-in Settings use stable `alnote.settings.*` keys and code-owned typed definitions.
- Plugin namespace allocation remains deferred to the Plugin System.
- Effective values resolve validated preview, permitted device override, user override, and built-in default before mandatory constraints are enforced.
- One logical repository contains separately versioned domain records.
- AL NOTE owns transactional repository, snapshot, change-feed, external-change, adapter, and secret-reference contracts.
- Stored records contain versioned overrides rather than authoritative copies of defaults.
- Validation applies during loading, drafts, imports, external changes, and plugin-record activation.
- Migrations are deterministic, bounded, transactional, tested, and last-known-good preserving.
- Unknown and absent-plugin Settings remain bounded, preserved, inactive, and non-executable.
- Consumers receive immutable snapshots and typed changes with declared application timing.
- Preview, Apply, Cancel, and Reset use private validated draft transactions.
- Interaction profiles and Tool presets capture immutable snapshots for active sequences and gestures.
- Appearance and accessibility preferences cannot weaken mandatory accessibility requirements.
- Recovery and creation defaults remain preferences; applied creation defaults become document content.
- Import and Export defaults enter explicit validated operation plans.
- Preference profiles use a separate bounded, versioned, secret-free format.
- Ordinary Settings never store secrets; only opaque Security-owned references may be retained.
- Cross-process and cross-tab writes use optimistic revisions without silent last-writer-wins.
- Corruption is preserved for recovery or diagnosis and is never silently overwritten.
- Settings parsing, storage, migration, imports, namespaces, and events are resource-bounded.
- Eligible user records preserve boundaries for future Sync without implementing transport or merge.
- No Settings backend or dependency is accepted.

The detailed Settings architecture is recorded in [lib/app/settings/README.md](lib/app/settings/README.md).

## Plugin System

Version-1 external plugins are bounded, validated, declarative packages that configure existing AL NOTE-owned behavior without executing plugin-supplied code.

### Accepted Ownership Boundaries

- The Plugin System owns package identity, manifest validation, publisher identity, lifecycle coordination, namespace enforcement, declarative contribution validation, atomic registry publication, compatibility, failure isolation, safe mode, and structured audit events.
- External plugins cannot provide runtime Dart, native libraries, processes, scripts, WebAssembly, widgets, renderers, hit testing, Tools, handlers, executable migrations, background tasks, or direct platform access.
- Trusted Dart extensions are reviewed and compiled into AL NOTE; they are not runtime external plugins.
- `.alnote-plugin` packages use a bounded deterministic archive contract with complete staged validation.
- Raw archive identity remains separate from canonical signed-content identity.
- Plugin identities use controlled reverse-domain namespaces while `alnote.*` remains reserved.
- Version-1 packages are self-contained and cannot depend on other plugins.
- Installation, signature verification, trust, permission, and activation remain distinct.
- Declarative plugins receive no runtime capabilities.
- Contributions publish only as complete immutable registry generations.
- Active operations pin affected plugin versions and registry generations; idle Sessions adopt the current generation.
- Installation and updates are transactional, retain rollback candidates, and support safe mode.
- Disabling or uninstalling never deletes document content or silently removes inactive Settings.
- Missing plugins leave namespaced persistent records inert and preserved.
- Version 1 permits only host-supported structural migrations.
- Settings and UI contributions use host-owned typed and declarative contracts.
- Document mutation continues through Commands and existing domain boundaries.
- Compatibility is capability-based and may vary by platform.
- Local validation, activation, disabling, and rollback work offline when required inputs are present.
- Licensing, notices, provenance, and curated GPL compatibility review are required.
- A future capability-mediated WebAssembly boundary remains deferred.
- No external Plugin System dependency is accepted.

The detailed Plugin System architecture is recorded in [lib/app/plugins/README.md](lib/app/plugins/README.md).

## Search and Indexing

Searchable projections and indexes are derived, rebuildable views of immutable authoritative content and never become authoritative document state.

### Accepted Ownership Boundaries

- Version 1 guarantees Search over the current Page, current document, and all open Document Sessions.
- Closed-document collections, filesystem crawling, remote Search, Cloud Search, and synchronized indexes remain deferred.
- Text and accepted metadata are authoritative searchable sources.
- PDF-derived text remains a provenance-bearing derived projection supplied by PDF System.
- Handwriting, image pixels, image-only PDFs, and recognition suggestions are not treated as recognized text.
- Built-in content owners expose immutable bounded projections through AL NOTE-owned contracts.
- Unknown, unsupported, unavailable, and missing-handler content receives structured omission reasons.
- Version 1 uses bounded direct scanning as its semantic reference and a pure-Dart in-memory inverted index as its primary optimization.
- Optional persistent indexes are sensitive disposable caches outside `.alnote`.
- No external Search backend or dependency is accepted.
- Query semantics are typed, bounded, and backend-independent.
- Normalization preserves mappings to original grapheme-safe source ranges.
- Ranking and tie-breaking are deterministic.
- Open-Session Search aggregates independent per-Session identities and generations without global atomicity.
- Search observes committed immutable transitions and never publishes Commands.
- Candidate generations publish atomically per independently indexed document or source.
- Lifecycle, freshness, completeness, availability, and persistence remain independent axes.
- Locked, omitted, unsupported, unavailable, stale, or partial content cannot be misreported as authoritative no-results.
- Queries use request identities, pin immutable inputs, cooperate with cancellation, and reject superseded late results.
- Sessions coordinate document jobs and source freshness while Search owns query and indexing semantics.
- Recovery never depends on Search data.
- Indexes, snippets, queries, and extracted text are sensitive.
- Persistent plaintext indexes require equivalent protection for encrypted documents and unlocked protected PDFs.
- All projection, indexing, query, result, cache, concurrency, and cancellation work is bounded.
- Platform behavior is capability-based.
- Direct scanning is the conformance oracle.

The detailed Search and Indexing architecture is recorded in [lib/search/README.md](lib/search/README.md).

## Decision Ledger

| ID | Subsystem | Decision | Status | Dependencies |
|---|---|---|---|---|
| D-006 | Objects | Page objects use a small persistent model with external behavior registries | Accepted | Documents |
| D-007 | Objects | Object IDs are document-unique UUIDs and types use namespaced strings | Accepted | D-006 |
| D-008 | Objects | Edits replace immutable-facing revisions; structural sharing is allowed | Accepted | D-006 |
| D-009 | Objects | Layers exclusively own object membership and ordering | Accepted | D-006 |
| D-010 | Objects | Intrinsic geometry combines with a local-to-page transform | Accepted | Geometry |
| D-011 | Objects | Unknown objects remain inert, preserved, and safely represented | Accepted | Storage, Plugins |
| D-012 | Objects | Rendering and hit-testing use registries separate from the core Object Registry | Accepted | Drawing |
| D-013 | Objects | Duplicated objects receive new IDs and remap internal references | Accepted | Clipboard, Commands |
| D-014 | Objects | Full grouping ownership and structure are deferred | Deferred | Layers, Selection |
| D-015 | Layers | Pages own ordered layer values; layers own ordered object values | Accepted | Objects |
| D-016 | Layers | Layer IDs are document-unique UUIDs and collection position defines order | Accepted | D-015 |
| D-017 | Layers | Ordinary content layers support mixed object types | Accepted | D-015 |
| D-018 | Layers | Effective visibility uses AND; effective locking uses OR | Accepted | Objects |
| D-019 | Layers | Every page retains at least one content-capable layer | Accepted | Pages |
| D-020 | Layers | Background and PDF sources use constrained source layers below content | Accepted | Documents, PDF |
| D-021 | Layers | Opacity is common; blend modes and export policy are deferred | Accepted | Rendering, Export |
| D-022 | Layers | Unknown layers and their data remain preserved and inert | Accepted | Storage, Plugins |
| D-023 | Layers | Active-layer selection is non-persistent session state | Accepted | Sessions |
| D-024 | Layers | Nested layers and layer groups are unsupported for now | Deferred | Selection, Grouping |
| D-025 | Selection | Selection is temporary page-editing session state | Accepted | Sessions |
| D-026 | Selection | Targets use Page ID, Object ID, and optional stable sub-target identity | Accepted | Objects |
| D-027 | Selection | Selection may cross layers within one page while preserving membership and order | Accepted | Layers |
| D-028 | Selection | Initial selection supports objects and handwriting-stroke sub-targets | Accepted | Handwriting |
| D-029 | Selection | Region selection uses precise, policy-driven containment or intersection tests | Accepted | Hit Testing |
| D-030 | Transform | Public transforms use controlled affine operations | Accepted | Geometry |
| D-031 | Transform | Preview is temporary; commits replace all affected objects atomically | Accepted | Commands |
| D-032 | Transform | Every selected target must support a requested shared transform | Accepted | Capabilities |
| D-033 | Transform | Partial overflow is allowed, but transformed content must remain recoverable from the page | Accepted | Pages |
| D-034 | Selection | Hidden and locked objects are excluded; unknown objects are non-transformable | Accepted | Objects, Layers |
| D-035 | Selection | Selection and transform-session ownership belongs under `lib/drawing/selection/` | Accepted | Drawing |
| D-036 | Commands | Exact revision and stale-state token mechanism is deferred | Deferred | Command System |
| D-037 | Commands | One document-scoped coordinator exclusively publishes persistent state | Accepted | Documents |
| D-038 | Commands | Requests express intent; history uses structurally shared before/after state plus metadata | Accepted | D-037 |
| D-039 | Commands | Preparation may be asynchronous; final commit is serialized and atomic | Accepted | D-037 |
| D-040 | Commands | Transactions may span one logical document; cross-document atomicity is deferred | Accepted | Documents |
| D-041 | History | Each open-document session owns one linear undo/redo history | Accepted | Sessions |
| D-042 | History | Undo and redo restore recorded states, original IDs, ordering, and opaque data | Accepted | D-038 |
| D-043 | History | Coalescing requires explicit semantic merge keys and boundaries | Accepted | D-041 |
| D-044 | Commands | Stale checks use scoped session revision tokens; global revision is not always required | Accepted | D-037 |
| D-045 | History | Dirty state compares current content-state identity with the last successful save | Accepted | Storage |
| D-046 | Commands | Every successful commit emits one immutable structured change description | Accepted | Rendering, Autosave |
| D-047 | History | Normal undo history remains session-only; recovery journaling is separate | Accepted | Recovery |
| D-048 | Resources | History retains resource IDs or leases; physical reclamation belongs to the Resource System | Accepted | Resources |
| D-049 | Commands | Authorization distinguishes content edits, management actions, and privileged recovery | Accepted | Objects, Layers |
| D-050 | Commands | Command architecture belongs under `lib/documents/commands/` | Accepted | Documents |
| D-051 | Core | Immutable collection dependency selection requires representative benchmarks | Deferred | Performance |
| D-052 | History | Disk-backed history and very-large-entry policy are deferred | Deferred | Storage, Platforms |
| D-053 | Storage | All document forms use one `.alnote` ZIP package | Accepted | Documents |
| D-054 | Serialization | Package version 1 uses deterministic UTF-8 JSON records | Accepted | D-053 |
| D-055 | Serialization | Records are divided at document, section, and page boundaries | Accepted | D-053 |
| D-056 | Resources | Version 1 embeds required resources as separate ZIP entries | Accepted | D-053 |
| D-057 | Resources | Resources use logical UUIDs plus SHA-256 content identity | Accepted | D-056 |
| D-058 | Storage | The manifest catalogs authoritative entries, sizes, media types, and hashes | Accepted | D-053 |
| D-059 | Versioning | Package, root, layer, object-envelope, and type-payload versions remain separate | Accepted | Objects, Layers |
| D-060 | Preservation | Unknown data and potentially reachable resources must be preserved | Accepted | Objects, Layers, Plugins |
| D-061 | Serialization | Logical serialization is deterministic | Accepted | D-054 |
| D-062 | Storage | Loading may be lazy at page and resource boundaries | Accepted | D-055 |
| D-063 | Storage | Saving creates and validates a complete replacement package | Accepted | Commands |
| D-064 | Migration | Migrations never modify the original package in place | Accepted | D-059 |
| D-065 | Compatibility | Unsupported newer content is editable only when safely understood | Accepted | D-059, D-060 |
| D-066 | Security | Packages are hostile input and require bounded validation | Accepted | D-053 |
| D-067 | Storage | Advisory writer coordination is combined with external-file fingerprints | Accepted | Platforms |
| D-068 | Storage | Storage architecture belongs under `lib/documents/files/` | Accepted | Documents |
| D-069 | Storage | External links, signatures, encryption, and final media-type registration are deferred | Deferred | Security, Platforms |
| D-070 | Storage | Exact ZIP and JSON implementation dependencies are deferred pending testing | Deferred | Performance, Platforms |
| D-071 | Recovery | Recovery uses complete checkpoints plus a short append-only journal | Accepted | Storage, Commands |
| D-072 | Recovery | Recovery is enabled by default and stored separately from canonical files | Accepted | D-071 |
| D-073 | Recovery | Journal entries contain committed persistent results, not commands or UI events | Accepted | Commands |
| D-074 | Recovery | One serialized recovery writer serves each logical in-memory document | Accepted | Sessions |
| D-075 | Autosave | Recovery uses debounce, maximum-latency, and lifecycle triggers | Accepted | D-074 |
| D-076 | Recovery | Previous valid generations remain until replacement is durable | Accepted | Storage |
| D-077 | Recovery | Durable sequence numbers and hashes define recovery order | Accepted | D-071 |
| D-078 | Recovery | Recovery records source identity and canonical destination fingerprints | Accepted | Storage |
| D-079 | Recovery | Restoration uses the newest valid checkpoint and valid journal prefix | Accepted | D-076, D-077 |
| D-080 | Recovery | Restored recovery opens dirty with a new history baseline | Accepted | Commands |
| D-081 | Recovery | Uncertain or conflicting recovery opens as a separate document | Accepted | Sessions, Storage |
| D-082 | Resources | Recovery retains every resource reachable from valid generations | Accepted | Resources |
| D-083 | Recovery | Coordinated views share ownership; uncoordinated sessions create branches | Accepted | Sessions, Platforms |
| D-084 | Recovery | Cleanup requires a covered save or explicit discard | Accepted | Storage |
| D-085 | Recovery | Recovery architecture belongs under `lib/documents/recovery/` | Accepted | Documents |
| D-086 | Security | Recovery artifacts receive document privacy and hostile-input protections | Accepted | Security, Storage |
| D-087 | Recovery | Exact format, backend, timings, leases, retention periods, and dependencies are deferred | Deferred | Testing, Platforms, Settings |
| D-088 | Drawing Tools | Immutable tool definitions create isolated mutable gesture sessions | Accepted | Drawing Engine |
| D-089 | Drawing Tools | Tools use stable namespaced identities and one logical registry | Accepted | Plugins |
| D-090 | Drawing Tools | Interaction Mapping assigns normalized input; tools do not own general arbitration | Accepted | Input, Interaction |
| D-091 | Drawing Tools | Sessions default to one primary pointer and the engine coordinates capture | Accepted | Input, Platforms |
| D-092 | Drawing Tools | Previews are temporary page-coordinate rendering data | Accepted | Renderer |
| D-093 | Drawing Tools | Completed gestures submit atomic Command Requests and never mutate documents directly | Accepted | Commands |
| D-094 | Drawing Tools | Pen variants are behavior profiles over the shared Stroke System | Accepted | Strokes |
| D-095 | Drawing Tools | Persistent results contain resolved self-sufficient properties | Accepted | Objects, Storage |
| D-096 | Drawing Tools | Erasers use hit-testing and splitting services and commit atomically | Accepted | Hit Testing, Strokes, Commands |
| D-097 | Drawing Tools | Selection delegates to Selection; Pan belongs to Interaction and Viewport | Accepted | Selection, Viewport |
| D-098 | Drawing Tools | Insertion tools use placement sessions while payload ownership remains elsewhere | Accepted | Text, Images, Shapes, PDF |
| D-099 | Drawing Tools | Plugin tools use restricted contracts and cannot bypass Commands | Accepted | Plugins, Commands |
| D-100 | Drawing Tools | Active tools, sessions, previews, and presets are not document data | Accepted | Settings, Storage |
| D-101 | Drawing Tools | Drawing Tool architecture belongs under `lib/drawing/tools/` | Accepted | Drawing |
| D-102 | Drawing Tools | Brush algorithms, compositing, multipointer behavior, limits, and dependencies remain deferred | Deferred | Interaction, Rendering, Testing |
| D-103 | Interaction | Interaction Mapping remains separate from raw input normalization | Accepted | Input |
| D-104 | Interaction | Actions use stable namespaced identities and one logical registry | Accepted | Plugins |
| D-105 | Interaction | Versioned binding profiles are Settings data, never document data | Accepted | Settings |
| D-106 | Interaction | Bindings combine device, gesture, chord, context, and capabilities | Accepted | Input |
| D-107 | Interaction | Routing decisions and relevant snapshots freeze at gesture commitment | Accepted | Drawing Tools |
| D-108 | Interaction | Every pointer has one logical owner; multitouch gestures may own pointer groups | Accepted | Input |
| D-109 | Interaction | Candidate selection, recognition, arbitration, and binding resolution are coordinated | Accepted | D-106 |
| D-110 | Interaction | Safety, focus, and existing ownership precede customizable bindings | Accepted | UI, Settings |
| D-111 | Interaction | Stylus and touch concurrency requires guaranteed coordinate continuity | Accepted | Viewport, Drawing Tools |
| D-112 | Interaction | Platform palm rejection precedes conservative shared fallback policy | Accepted | Platforms |
| D-113 | Interaction | Temporary overrides use tokens and affect only future gestures | Accepted | Input |
| D-114 | Interaction | Lifecycle disruption cancels uncommitted interactions without partial mutation | Accepted | Commands |
| D-115 | Interaction | Keyboard dispatch is focus-aware and focused editors own their undo context | Accepted | Text, UI |
| D-116 | Interaction | Essential actions retain accessible fallback and reset paths | Accepted | Accessibility, Settings |
| D-117 | Interaction | Shared behavior resolves from capabilities while native details remain in adapters | Accepted | Platforms |
| D-118 | Interaction | Plugin actions use restricted dispatch and unavailable bindings are preserved | Accepted | Plugins |
| D-119 | Interaction | Interaction architecture belongs under `lib/core/interaction/` using neutral contracts | Accepted | Core |
| D-120 | Interaction | Exact defaults, thresholds, calibration, diagnostics, native work, and dependencies remain deferred | Deferred | Settings, Testing, Platforms |
| D-121 | Text | Built-in Text Objects use `alnote.text` and the common Object envelope | Accepted | Objects |
| D-122 | Text | Version 1 uses constrained rich text with ordered paragraphs and styled runs | Accepted | D-121 |
| D-123 | Text | Logical Unicode text and explicit paragraph boundaries are authoritative; soft wraps are derived | Accepted | Serialization |
| D-124 | Text | Version 1 ranges use paragraph position, Unicode-scalar boundaries, and expected object revision | Accepted | Commands |
| D-125 | Text | Text boxes support bounded auto-size, fixed-width auto-height, and fixed-box modes | Accepted | Geometry |
| D-126 | Text | Box resizing reflows text while common transform scaling does not | Accepted | Objects, Selection |
| D-127 | Text | Glyphs, wraps, caret maps, and layout fragments are derived data | Accepted | Rendering |
| D-128 | Text | Fonts use bundled open-licensed baselines, legal embedded resources, and controlled fallback | Accepted | Resources, Storage |
| D-129 | Text | AL NOTE owns a platform-independent layout contract over maintained text services | Accepted | Rendering, Platforms |
| D-130 | Text | Editor sessions own drafts, caret, ranges, IME, and temporary editing state | Accepted | Interaction, Sessions |
| D-131 | Text | Persistent edits commit with bounded latency and History provides semantic coalescing | Accepted | Commands, Recovery |
| D-132 | Text | Stale edits are rejected and preserved without automatic merge or rebase | Accepted | Commands |
| D-133 | Text | Clipboard input is sanitized into plain, internal, or constrained built-in rich text | Accepted | Security, Import |
| D-134 | Text | Rendering, Search, accessibility, hit-testing, and export consume controlled Text contracts | Accepted | Drawing, Search, Export |
| D-135 | Text | Corrupt or unknown Text payloads remain preserved; repair is explicit | Accepted | Storage, Recovery |
| D-136 | Text | Version 1 authoritative Text styles and layout semantics are built-in only | Accepted | Plugins |
| D-137 | Text | Structured mathematics remains separate from ordinary Unicode Text Objects | Accepted | Math Recognition, Symbolic Math |
| D-138 | Text | Text Object architecture belongs under `lib/documents/objects/text/` | Accepted | Objects |
| D-139 | Text | Exact fonts, editor libraries, layout profile, advanced formatting, and dependencies remain deferred | Deferred | Testing, Platforms, Settings |
| D-140 | Roadmap | Handwriting Recognition/OCR, Math Recognition, the Symbolic Math Engine, and optional Sync/Cloud are official post-v1 goals and are not required for the first build. | Accepted | Existing document architecture |
| D-141 | Roadmap | V1 must preserve raw strokes, original image pixels, stable coordinates and transforms, immutable resource identities, versioned schemas, unknown data, and extension boundaries needed by post-v1 recognition, mathematics, and synchronization systems, without implementing those systems prematurely. | Accepted | D-140 |
| D-142 | Images | Use built-in type key `alnote.image`; each Image Object references one immutable generic document resource. | Accepted | Object System, Storage |
| D-143 | Images | The Image payload is versioned by the common Object envelope's `typeSchemaVersion` and does not duplicate that version field. | Accepted | D-142 |
| D-144 | Images | Persist the resource UUID, verified encoded pixel dimensions, oriented intrinsic document size, explicit orientation, normalized crop, rendering intent, and optional user-authored alt text. The resource hash and media metadata remain owned by the resource manifest. | Accepted | D-142, D-143 |
| D-145 | Images | Original encoded bytes and persistent Image fields are authoritative; decoded pixels, thumbnails, mipmaps, tiles, alpha masks, color conversions, and OCR results are derived. | Accepted | D-142 |
| D-146 | Images | PNG and JPEG are the only guaranteed v1 import, storage, display, and export formats. Additional and animated formats require later four-platform conformance approval. | Accepted | D-145 |
| D-147 | Images | Persist explicit display orientation while preserving original resource bytes; prevent decoder auto-orientation from applying the transform twice. | Accepted | D-144 |
| D-148 | Images | Encoded pixel dimensions are measured before orientation. Crop coordinates use normalized oriented-source space, followed by the common local-to-page Object transform. | Accepted | D-147 |
| D-149 | Images | Cropping is nondestructive. Movement, rotation, and positive scaling use the common Object transform; reflection and destructive editing remain deferred. | Accepted | D-148, Selection System |
| D-150 | Images | Default physical size uses trustworthy bounded resolution metadata, otherwise 96 DPI, preserves aspect ratio, and scales down to fit the page without automatic upscaling. | Accepted | D-144 |
| D-151 | Images | Movable and background images use the same Image Object type; constrained background placement is owned by the Layer System rather than an `isBackground` payload field. | Accepted | Layer System |
| D-152 | Images | Import prepares and validates bounded bytes before an atomic Command inserts the resource and Image Object. Cancellation or rejection publishes no document mutation. | Accepted | Command System, Storage |
| D-153 | Images | Duplicated Image Objects receive new Object UUIDs while sharing immutable resource bytes; resource retention and reclamation remain Resource System responsibilities. | Accepted | Object System, Command System |
| D-154 | Images | Rendering, decoding, caching, color conversion, and precise hit testing remain outside persistent Image data and behind platform-independent contracts. | Accepted | Drawing Engine |
| D-155 | Images | Missing, corrupt, unsupported, or quarantined resources preserve the Image Object and render a stable placeholder rather than disappearing. | Accepted | Storage, Drawing Engine |
| D-156 | Images | Normal external exports strip sensitive source metadata by default; explicitly exporting the original resource may preserve it. Sharing privacy for `.alnote` source metadata requires later Security and Privacy policy. | Accepted | Export, Security |
| D-157 | Images | Future OCR data remains outside the Image Object and identifies the Object, resource UUID/hash, payload revision, orientation, crop, transform revision, engine version, and source-space regions. | Accepted | D-141 |
| D-158 | Images | Future Sync addresses immutable bytes by hash and logical resources by UUID; remote URLs and cloud locators do not belong in the v1 Image payload. | Accepted | D-141 |
| D-159 | Images | GIF/WebP/BMP portability, animation, SVG, HEIF/HEIC, AVIF, TIFF, HDR, destructive filters, and external resource links remain deferred. | Deferred | D-146 |
| D-160 | Shapes | Built-in shapes use one core-controlled Object type key, `alnote.shape`, with permanent string-based `shapeKind` identifiers. | Accepted | Object System |
| D-161 | Shapes | Version 1 supports `line`, `rectangle`, `ellipse`, `polygon`, and `polyline`; arrows, rounded rectangles, and circles are variations rather than separate persistent kinds. | Accepted | D-160 |
| D-162 | Shapes | Lines, rectangles, and ellipses retain parametric geometry; polygons and polylines retain ordered vertices; authoritative general paths are deferred. | Accepted | D-161 |
| D-163 | Shapes | The Shape payload contains `shapeKind`, intrinsic geometry, explicit stroke and fill records, Shape opacity, and preserved unknown fields; the common Object envelope owns `typeSchemaVersion`. | Accepted | D-160, Object System |
| D-164 | Shapes | Shape styles are backend-neutral and use finite RGBA color values, enabled states, solid fills, stroke width, caps, joins, miter limit, and bounded dash semantics. | Accepted | Drawing graphics contracts |
| D-165 | Shapes | Version-1 rectangles may use one uniform nonnegative corner radius; per-corner and elliptical corner radii remain deferred. | Accepted | D-161, D-162 |
| D-166 | Shapes | Arrowheads are bounded endpoint decorations on lines or polylines, use stable core-controlled kinds, derive default size from stroke width, and are not separate Object or geometry kinds. | Accepted | D-161, D-164 |
| D-167 | Shapes | Selection-based whole-object transforms update only the common Object transform; direct Shape geometry editing replaces intrinsic geometry through Commands. | Accepted | Selection System, Command System |
| D-168 | Shapes | Whole-object transforms apply to the composed geometry and appearance, while direct geometry edits leave stroke width, dash lengths, opacity, and arrowhead sizing unchanged. Automatic transform baking is deferred. | Accepted | D-167 |
| D-169 | Shapes | Geometry, visual, and interaction bounds remain distinct; interaction tolerance is transient and caches are non-authoritative. | Accepted | Object System, Drawing Engine |
| D-170 | Shapes | Hit testing uses page-space broad-phase rejection followed by inverse-transform local-space tests for fills, strokes, and arrowheads. | Accepted | Hit-Testing System |
| D-171 | Shapes | Rendering and export receive backend-neutral semantic Shape geometry and styles; vector conversion is allowed when required, while rasterization is a last resort and never replaces persistent source geometry. | Accepted | Drawing Engine, Export |
| D-172 | Shapes | Persistent Shape changes use replacement-oriented Commands; duplication creates a new Object UUID while copying geometry, style, transform, and unknown fields. Version-1 vertices have no independent identity. | Accepted | Object System, Command System |
| D-173 | Shapes | Degenerate, unsupported, and unknown Shape data is distinguished from unsafe data and preserved without silently converting it into another Shape kind. | Accepted | Storage, Object System |
| D-174 | Shapes | Plugin-defined shapes use their own namespaced Object type keys and may reuse approved public geometry/style contracts; plugins cannot add private kinds beneath `alnote.shape`. | Accepted | Object System, future Plugin System |
| D-175 | Shapes | Shape validation enforces configurable bounds on coordinates, vertices, stroke widths, dash data, arrowheads, migration expansion, and geometry-processing work. | Accepted | Storage, Security |
| D-176 | Shapes | Shape payload contracts, validation, and migration belong conceptually under `lib/documents/objects/shape/`; rendering and hit-testing implementations remain in their accepted Drawing subsystem areas. | Accepted | Repository architecture |
| D-177 | Shapes | No external Shape or geometry dependency is accepted; Flutter, Skia, SVG, `vector_math`, and path packages remain references or evaluation candidates behind AL NOTE-owned contracts. | Accepted | Open-source evaluation |
| D-178 | Shapes | General paths, curves, advanced fills, effects, Boolean operations, constraints, connectors, stable vertex identities, text-bearing shapes, and Shape Recognition remain deferred. | Deferred | Future Shape extensions |
| D-179 | PDF | Original PDF bytes remain immutable resources, while all new editable annotations remain ordinary AL NOTE Objects. | Accepted | Resources, Objects |
| D-180 | PDF | Source layers and movable PDF Objects share one versioned `PdfPageReference` containing resource UUID, zero-based page index, resolved source box, effective rotation, displayed dimensions, and preserved unknown fields. | Accepted | D-179 |
| D-181 | PDF | A standalone PDF uses the existing Standalone PDF document form, a document-level source binding, and ordinary AL NOTE Pages whose constrained source layers reference the immutable PDF. | Accepted | Document Engine, D-180 |
| D-182 | PDF | PDF source layers use a stable `alnote.pdf.source` binding; the PDF System owns binding semantics while the Layer System retains layer identity, ordering, locking, visibility, and lifecycle ownership. | Accepted | Layer System |
| D-183 | PDF | Movable PDF pages use Object type `alnote.pdf.page`; version 1 creates one Object per selected source page and defers movable multipage containers. | Accepted | Object System, D-180 |
| D-184 | PDF | Canonical PDF-local coordinates use PDF points with top-left origin, positive Y downward, and effective page rotation already applied. | Accepted | Geometry |
| D-185 | PDF | Page references persist the selected box kind, resolved source-user-space box coordinates, normalized effective rotation, and displayed dimensions; valid CropBox is default with MediaBox fallback. | Accepted | D-180, D-184 |
| D-186 | PDF | Version-1 source-layer page mapping, box, rotation, and dimensions remain fixed after page creation; later remapping requires separately designed annotation-preservation behavior. | Accepted | Pages, Commands |
| D-187 | PDF | Multiple Pages, source layers, and PDF Page Objects may share the same immutable PDF resource; duplication creates new Object or Page identities without duplicating bytes. | Accepted | Resources, Commands |
| D-188 | PDF | Existing native PDF annotations remain preserved in original bytes, render read-only when safe appearances exist, and are not automatically converted into AL NOTE Objects. | Accepted | D-179 |
| D-189 | PDF | JavaScript, launch actions, form actions, multimedia, 3D content, and embedded-file execution are disabled; safe links are exposed only as validated navigation metadata. | Accepted | Security |
| D-190 | PDF | PDF passwords and unlocking state are session-only secrets and never enter storage, logs, history, recovery, or disk caches. | Accepted | Security, Sessions |
| D-191 | PDF | Rendering, text extraction, links, outlines, accessibility data, thumbnails, tiles, and backend handles are separate derived capabilities and never authoritative PDF state. | Accepted | Drawing Engine, Search |
| D-192 | PDF | Opening standalone PDFs, importing notebook pages, and inserting movable PDF pages use asynchronous preparation followed by atomic resource-and-document publication through Commands. | Accepted | Commands, Import |
| D-193 | PDF | Normal PDF export creates a new sanitized PDF, reuses safe vector source-page content where possible, flattens native appearances and AL NOTE Objects exactly once, and uses bounded raster fallback only when required. | Accepted | Export, Security |
| D-194 | PDF | Normal export omits executable content, unsafe actions, embedded files, interactive forms, unsupported native annotation dictionaries, and original digital-signature claims; output encryption is not inherited automatically. | Accepted | D-193 |
| D-195 | PDF | Internal links may be recreated after validation; external HTTP/HTTPS links require explicit policy, while file, shell, launch, and custom URI actions remain blocked. | Accepted | Security, Export |
| D-196 | PDF | Missing, locked, corrupt, unsupported, quarantined, or backend-unavailable PDFs preserve Pages, source layers, Objects, dimensions, references, and annotations through stable placeholders. | Accepted | Storage, Drawing Engine |
| D-197 | PDF | Persistent PDF resource, binding, Page, layer, box, crop, and Object changes use Commands; password entry, rendering, extraction, and caches do not enter history. | Accepted | Command System |
| D-198 | PDF | PDF contracts remain engine-neutral; plugins and backends cannot place engine handles in persistent data, execute PDF actions, bypass validation, or publish mutations directly. | Accepted | Plugins, Drawing Engine |
| D-199 | PDF | PDF parsing, rendering, extraction, and export enforce configurable byte, page, dimension, recursion, object, decompression, font, image, memory, time, and concurrency limits in cancellable workers where practical. | Accepted | Security, Platforms |
| D-200 | PDF | AL NOTE must reuse a mature PDF engine rather than create a parser or renderer; PDFium, `pdfrx`, and PDF.js are leading candidates, but no backend dependency is accepted until audits and conformance tests pass. | Accepted | Open-source evaluation |
| D-201 | PDF | PDF model, coordinate, binding, rendering-contract, extraction-contract, import/export-contract, security, and backend-interface ownership belongs conceptually under `lib/documents/pdf/`; platform implementations remain behind adapters. | Accepted | Repository architecture |
| D-202 | PDF | Editable native annotations, forms, signatures, multipage movable containers, OCR, archival conformance, advanced color, source-layer remapping, password persistence, output encryption, and exact rendering/export dependencies remain deferred. | Deferred | Future PDF extensions |
| D-203 | Import/Export | Open, Save, and Save As remain separate from Import and Export | Accepted | Storage |
| D-204 | Import/Export | Import and Export own orchestration, not format internals | Accepted | PDF, Image, Drawing |
| D-205 | Import/Export | PDF, PNG, and JPEG are guaranteed version-1 formats | Accepted | PDF, Image |
| D-206 | Import/Export | Stable format identifiers use the `alnote.format.*` namespace | Accepted | Object identity conventions |
| D-207 | Import | Detection inspects content and never trusts extensions alone | Accepted | Security |
| D-208 | Import | Imports use immutable transient Prepared Import Plans | Accepted | Storage, Commands |
| D-209 | Import | Staged resources use bounded, expiring host-owned tokens | Accepted | Storage resources |
| D-210 | Import | Final destinations use stable Page, Section, and Layer identities | Accepted | Documents, Layers |
| D-211 | Import | One PDF's selected Pages form one atomic import by default | Accepted | PDF, Commands |
| D-212 | Import | Independent input files default to separate transactions | Accepted | Commands |
| D-213 | Import | Import publication occurs exclusively through Commands | Accepted | Command System |
| D-214 | Export | Every export uses one immutable document snapshot revision | Accepted | Documents, Resources |
| D-215 | Export | Export Plans perform preflight before expensive processing | Accepted | Drawing, PDF, Image |
| D-216 | Export | Export does not mutate documents or enter Command History | Accepted | Commands |
| D-217 | Export | Selected-object export is page-scoped in version 1 | Accepted | Selection |
| D-218 | Export | PDF construction and sanitization remain owned by the PDF System | Accepted | PDF |
| D-219 | Export | Raster export uses explicit resolution and background policies | Accepted | Drawing, Image |
| D-220 | Export | JPEG always uses an explicit opaque background | Accepted | Image |
| D-221 | Export | Multipage raster export defaults to one file per Page | Accepted | Platform adapters |
| D-222 | Export | ZIP is optional when one destination artifact is required | Accepted | Platform adapters |
| D-223 | Export | Separate output files are not treated as globally atomic | Accepted | Platform adapters |
| D-224 | Import/Export | Platform adapters expose capabilities rather than conversion policy | Accepted | Platform integration |
| D-225 | Export | Output uses temporary generation and safe commit where available | Accepted | Platform integration |
| D-226 | Import/Export | Cancellation, failure, and degradation use structured results | Accepted | Commands, Platform integration |
| D-227 | Export | Export metadata uses privacy-safe defaults | Accepted | Security, Privacy |
| D-228 | Import/Export | Plugin importers and exporters remain declarative and constrained | Accepted | Plugin System |
| D-229 | Import/Export | Additional formats, cloud sources, and advanced export features are postponed | Deferred | Post-v1 systems |
| D-230 | Sessions | Application State owns the registry of logical Document Sessions, view associations, focused-view coordination, lifecycle distribution, and application-wide limits. | Accepted | Application architecture |
| D-231 | Sessions | Runtime Session IDs are opaque, process-lifetime identities distinct from document, source, view, and durable restoration identities. | Accepted | Security |
| D-232 | Sessions | Durable workspace restoration uses separate versioned Restoration Entry identities; restored documents receive new runtime Session IDs. | Accepted | Recovery, Storage |
| D-233 | Sessions | Opening an already-open canonical source normally reuses its logical session; separate working copies require an explicit operation. | Accepted | Storage |
| D-234 | Sessions | Multiple views may share one logical session, immutable root, Commands, history, saved state, Recovery writer, source state, and document-scoped jobs. | Accepted | Commands, Recovery |
| D-235 | Sessions | Navigation, active Tool, selection, viewport, input ownership, editors, and previews remain view-specific temporary state. | Accepted | Drawing, Interaction |
| D-236 | Sessions | Persistent document, session, view, application, Settings, Recovery, and restoration state remain separate ownership domains. | Accepted | Global boundaries |
| D-237 | Sessions | Active view references are repaired deterministically by stable identity, previous ordering, valid parentage, and explicit no-target states. | Accepted | Pages, Layers |
| D-238 | Sessions | Lifecycle, readiness, access, fidelity, and external-source state are independent axes rather than one combined enumeration. | Accepted | Session model |
| D-239 | Sessions | Command revisions, content identities, session revisions, view revisions, saved identities, Recovery sequences, source epochs, and job freshness remain distinct. | Accepted | Commands, Recovery |
| D-240 | Sessions | Dirty state is determined only by comparing the current content-state identity with the last successfully saved content-state identity. | Accepted | Commands, Storage |
| D-241 | Sessions | Save and Save As operate on immutable captured states while later edits may continue; successful publication marks only the captured state as saved. | Accepted | Storage, Commands |
| D-242 | Sessions | Canonical publications are serialized per logical session; stale or failed Save As operations cannot rebind the session source. | Accepted | Storage |
| D-243 | Sessions | Import destinations and staged resources are revalidated immediately before Command publication; stale plans fail unless deterministic revalidation is authorized. | Accepted | Import, Commands |
| D-244 | Sessions | Export uses one immutable snapshot and never changes document state, dirty state, Recovery, or Command History. | Accepted | Export |
| D-245 | Sessions | External-source changes remain separate from dirty state and prohibit silent reload or overwrite; overwrite authorization is fingerprint-bound and expiring. | Accepted | Storage, Security |
| D-246 | Sessions | Unsaved-change and conflict handling use structured, freshness-validated decision requests independent of UI presentation. | Accepted | UI, Storage |
| D-247 | Sessions | Recovery protects committed document work while bounded workspace restoration reconstructs sessions and views; neither replaces the other. | Accepted | Recovery |
| D-248 | Sessions | Read-only and degraded states are independent; non-writable or locked sources do not automatically prohibit safe in-memory annotation editing. | Accepted | PDF, Storage |
| D-249 | Sessions | PDF unlocking state is session-scoped per resource, memory-only, and excluded from documents, Recovery, restoration, history, logs, and disk caches. | Accepted | PDF, Security |
| D-250 | Sessions | Platform lifecycle and restoration APIs remain best-effort adapters; forced termination safety depends on previously completed Recovery data. | Accepted | Recovery, Platforms |
| D-251 | Sessions | Session restoration, concurrency, resource use, cancellation, stale results, and dependencies are bounded by centralized security and capability policies. | Accepted | Security, Platforms |
| D-252 | UI | UI uses Widgets, presentation controllers, semantic Action dispatch, and application/domain contracts without directly mutating documents. | Accepted | Sessions, Commands |
| D-253 | UI | UI and concrete platform adapters are outer layers that depend inward on AL NOTE-owned contracts; domain subsystems never depend on concrete adapters. | Accepted | Global architecture |
| D-254 | UI | Document View is the reusable view-specific presentation unit for tabs, panes, windows, and mobile document surfaces. | Accepted | Sessions |
| D-255 | UI | Session-wide state remains separate from window, view, overlay, and preference presentation state. | Accepted | Sessions, Settings |
| D-256 | UI | Layout adapts by available space, capabilities, input modes, text scale, and accessibility settings rather than operating-system identity. | Accepted | Platforms |
| D-257 | UI | The application shell presents workspaces, windows, views, status, decisions, localization, theme, and accessibility without owning Document Sessions. | Accepted | Application State |
| D-258 | UI | Notebook, Page, Layer, selection, and Tool navigation use shared semantic Actions across compact, medium, and expanded layouts. | Accepted | Documents, Interaction |
| D-259 | UI | UI surfaces reuse the accepted semantic Action identities; UI descriptors add presentation metadata without creating a competing Action registry. | Accepted | Interaction Mapping |
| D-260 | UI | Persistent UI operations publish only through validated Command Requests; UI and widget-local history never replace document Commands. | Accepted | Commands |
| D-261 | UI | Windows and Document Views use explicit focus scopes, deterministic focus restoration, and editor-first shortcut precedence. | Accepted | Interaction Mapping, Accessibility |
| D-262 | UI | Canvas input passes through normalization and Interaction Mapping without duplicate widget-level drawing arbitration. | Accepted | Input, Interaction Mapping |
| D-263 | UI | Page content, Tool previews, Selection, feedback, contextual controls, and accessibility focus use separate non-mutating presentation planes; snapping remains deferred. | Accepted | Drawing, Selection |
| D-264 | UI | Structured decision presenters preserve tokens, resolutions, freshness, cancellation, and validation while remaining independent of session-core UI. | Accepted | Sessions |
| D-265 | UI | Read-only, loading, saving, Recovery, degraded, external-change, missing-resource, and unknown-content states receive explicit non-destructive presentation. | Accepted | Sessions, Recovery |
| D-266 | UI | WCAG 2.2 AA is the Web design and testing target; Canvas semantics provide meaningful document, Page, Tool, selection, Object, and warning representation without false recognition claims. | Accepted | Accessibility |
| D-267 | UI | Localization, RTL layout, theme, density, text scale, reduced motion, and responsive arrangement remain presentation concerns outside document content. | Accepted | Settings |
| D-268 | UI | Drag/drop, clipboard, pickers, and sharing use typed boundaries; cut and destructive paste mutations publish through Commands. | Accepted | Import, Export, Storage, Commands |
| D-269 | UI | Localized rebuilding, high-frequency repaint isolation, virtualization, lazy thumbnails, culling, bounded prefetch, and throttling are required performance boundaries. | Accepted | Drawing, Sessions |
| D-270 | UI | Windowing, native menus, pickers, clipboard, drag/drop, sharing, accessibility preferences, and browser restrictions remain capability-based platform adapters. | Accepted | Platforms |
| D-271 | UI | Multiple-window and split-view support remain capability-dependent; the architecture supports them without requiring identical version-1 behavior on every platform. | Accepted | Sessions, Platforms |
| D-272 | UI | Future plugin UI contributions are declarative and constrained; unrestricted widget injection and platform or Session access are prohibited. | Accepted | Plugin System |
| D-273 | UI | UI contracts remain testable with fakes, and no third-party state-management, docking, windowing, shortcut, or UI-extension dependency is accepted. | Accepted | Testing, Open-source evaluation |
| D-274 | Settings | Settings owns typed user preferences, device-local overrides, profiles, presets, validation, migration, transactions, and change observation without becoming document, Session, Recovery, or security-policy state. | Accepted | Global boundaries |
| D-275 | Settings | Version 1 supports persistent user and device-local scopes; persistent workspace scope remains deferred. | Accepted | Sessions, Future Sync |
| D-276 | Settings | Built-in Settings use stable `alnote.settings.*` keys; plugin namespace allocation remains owned by the future Plugin System. | Accepted | Identity conventions, Plugins |
| D-277 | Settings | Every Setting has a code-owned typed definition covering version, default, permitted scopes, validation, sensitivity, timing, limits, migration, and ownership. | Accepted | Validation |
| D-278 | Settings | Effective values resolve preview, permitted device override, user override, and built-in default, then apply mandatory security, preservation, capability, accessibility, and resource constraints. | Accepted | Security, Platforms |
| D-279 | Settings | One logical repository uses separately versioned domain records rather than one unstructured object or one physical file per Setting. | Accepted | Persistence |
| D-280 | Settings | Settings persistence uses AL NOTE-owned transactional repository and adapter contracts that report actual durability and atomicity capabilities. | Accepted | Platforms |
| D-281 | Settings | `shared_preferences` is not the canonical structured Settings store and may only be reconsidered for noncritical bootstrap hints. | Accepted | Open-source evaluation |
| D-282 | Settings | Stored values, drafts, imports, external changes, and plugin records are validated; migrations are deterministic, bounded, transactional, and last-known-good preserving. | Accepted | Persistence, Plugins |
| D-283 | Settings | Unknown and absent-plugin Settings remain bounded, preserved, inactive, and non-executable until an approved owner validates them. | Accepted | Plugins, Security |
| D-284 | Settings | Consumers observe immutable snapshots and typed changes; every Setting declares safe application timing and cannot retroactively alter active operations. | Accepted | Application State |
| D-285 | Settings | Preview, Apply, Cancel, and Reset operate through private validated draft transactions; reset removes overrides rather than storing copied defaults. | Accepted | UI |
| D-286 | Settings | Interaction Mapping profiles are structured Settings; input sequences capture a profile snapshot at start and gesture ownership freezes after commitment. | Accepted | Interaction Mapping |
| D-287 | Settings | Tool presets are versioned Settings records; active gestures retain their starting preset snapshot and committed content remains self-sufficient. | Accepted | Drawing Tools |
| D-288 | Settings | Appearance and accessibility preferences remain outside documents and cannot weaken operating-system accessibility requirements or mandatory UI accessibility rules. | Accepted | UI, Accessibility |
| D-289 | Settings | Recovery and document-creation defaults remain preferences; applied creation defaults become document data while Recovery data never becomes Settings. | Accepted | Recovery, Documents |
| D-290 | Settings | Import and Export defaults are captured into explicit validated plans and cannot bypass preflight, safety, preservation, or limits. | Accepted | Import, Export |
| D-291 | Settings | Ordinary Settings never contain secrets; only opaque secret references may be stored and resolved through a Security-owned contract. | Accepted | Security |
| D-292 | Settings | Cross-process and cross-tab commits use optimistic revisions; deterministic non-overlapping changes may rebase, while conflicts require structured resolution and never silent last-writer-wins. | Accepted | Platforms |
| D-293 | Settings | Preference profiles use a separate bounded, versioned, secret-free format owned by Settings and reuse platform source and destination capabilities without becoming document formats. | Accepted | Platforms, Security |
| D-294 | Settings | Settings parsing, storage, imports, migrations, namespaces, and change feeds are resource-bounded and cannot weaken mandatory invariants. | Accepted | Security |
| D-295 | Settings | Eligible user-scope records preserve stable identity, scope, revisions, provenance, and deterministic encoding for future Sync without implementing transport or merge. | Accepted | Future Sync |
| D-296 | Settings | Load failure preserves damaged data, attempts verified last-known-good recovery, otherwise uses temporary defaults, and never silently overwrites corruption. | Accepted | Persistence |
| D-297 | Settings | Individual and category reset remove known overrides; factory reset preserves unknown plugin records unless their separate removal is explicitly confirmed. | Accepted | Plugins, UI |
| D-298 | Settings | Every persistence adapter must pass shared tests for resolution, validation, migration, corruption, concurrency, import, security, and failure behavior. | Accepted | Testing |
| D-299 | Settings | Platform-independent Settings ownership belongs under `lib/app/settings/`; concrete persistence remains behind platform adapters. | Accepted | Repository architecture |
| D-300 | Settings | No Settings backend or dependency is accepted; SQLite, IndexedDB, and narrowly scoped platform stores remain audited candidates. | Accepted | Open-source evaluation |
| D-301 | Plugins | Version-1 external plugins are bounded declarative packages and cannot execute plugin-supplied code. | Accepted | Security |
| D-302 | Plugins | Trusted Dart extensions are compiled and shipped as part of AL NOTE rather than loaded as runtime external plugins. | Accepted | Application build |
| D-303 | Plugins | Arbitrary runtime Dart, native dynamic libraries, installation scripts, and process spawning are prohibited. | Accepted | Security |
| D-304 | Plugins | A capability-mediated WebAssembly boundary is reserved for future study, with no executable runtime or dependency accepted. | Deferred | Future plugins |
| D-305 | Plugins | Version-1 contributions are limited to validated declarations that configure existing host-owned behavior. | Accepted | Extension registries |
| D-306 | Plugins | External declarative plugins cannot provide executable object behavior, rendering, hit testing, Tools, handlers, migrations, widgets, or search. | Accepted | Domain boundaries |
| D-307 | Plugins | External packages use a bounded deterministic `.alnote-plugin` archive contract with staged complete validation. | Accepted | Storage, Security |
| D-308 | Plugins | Exact archive-byte identity is separate from canonical signed-content identity. | Accepted | Signing |
| D-309 | Plugins | Plugin manifests carry stable identity, compatibility, contribution, licensing, provenance, and resource declarations. | Accepted | Package format |
| D-310 | Plugins | Plugin and contribution identities use controlled reverse-domain namespaces, with `alnote.*` reserved. | Accepted | Identity conventions |
| D-311 | Plugins | Version-1 plugins are self-contained; plugin-to-plugin dependencies and dependency resolution are deferred. | Deferred | Future plugins |
| D-312 | Plugins | Installation, signature verification, trust, permission, and activation are distinct states. | Accepted | Security |
| D-313 | Plugins | Signatures establish key and artifact continuity but do not establish safety or trust. | Accepted | Security |
| D-314 | Plugins | Declarative version-1 plugins receive no runtime document, filesystem, network, clipboard, secret, or background capabilities. | Accepted | Security |
| D-315 | Plugins | Future executable capabilities must be deny-by-default, scoped, revocable, auditable, expiring where applicable, and bound to exact identities. | Deferred | Future security |
| D-316 | Plugins | Package staging performs bounded structural, path, resource, compatibility, and integrity validation without execution or network access. | Accepted | Security |
| D-317 | Plugins | Plugin contributions publish only as complete immutable atomic registry generations. | Accepted | Registries |
| D-318 | Plugins | Active operations pin exact plugin versions and registry generations, while idle Sessions adopt the current generation. | Accepted | Sessions |
| D-319 | Plugins | Installation and updates are transactional, retain rollback candidates, support safe mode, and require renewed authorization for identity-sensitive changes. | Accepted | Lifecycle |
| D-320 | Plugins | Disabling or uninstalling a plugin never deletes document content and preserves inactive Settings unless explicitly removed. | Accepted | Storage, Settings |
| D-321 | Plugins | Persistent plugin-owned records use stable namespaced identities and remain inert and preserved when their plugin is unavailable. | Accepted | Storage |
| D-322 | Plugins | Version 1 permits only host-supported structural migrations; executable migrations require a future isolated proposal-and-validation design. | Accepted | Migration |
| D-323 | Plugins | Plugin Settings use host-supported typed definitions, validation, transactions, persistence, and namespace controls. | Accepted | Settings |
| D-324 | Plugins | Plugin UI contributions are declarative, host-rendered, accessibility-controlled, plugin-string-scoped, and unable to impersonate trusted security UI. | Accepted | UI, Security |
| D-325 | Plugins | Plugin contributions preserve host Action, Interaction Mapping, Tool, Command, Import, Export, and document-mutation boundaries. | Accepted | Domain architecture |
| D-326 | Plugins | Plugin lifecycle operations use structured failure and cancellation with centralized resource limits and failure containment. | Accepted | Security |
| D-327 | Plugins | Plugin compatibility and activation are capability-based and may vary explicitly by platform. | Accepted | Platforms |
| D-328 | Plugins | Plugin packaging records SPDX-oriented licensing, notices, dependency and asset provenance, with curated distribution requiring documented GPL compatibility review. | Accepted | Licensing |
| D-329 | Plugins | Local installation, validation, activation, disabling, and rollback operate offline when required inputs are locally available. | Accepted | Platforms |
| D-330 | Plugins | The Plugin System emits privacy-safe structured audit events while Security owns their storage, retention, and access policy. | Accepted | Security |
| D-331 | Plugins | Package parsing, activation, lifecycle, preservation, and capability behavior require adversarial and cross-platform conformance testing. | Accepted | Testing |
| D-332 | Plugins | `lib/app/plugins/` owns Plugin System architecture, with no external plugin-system dependency accepted. | Accepted | Repository architecture |
| D-333 | Search | Searchable projections and indexes are derived, rebuildable views and never authoritative document state. | Accepted | Global boundaries |
| D-334 | Search | Version 1 guarantees Search over the current Page, current document, and all open Document Sessions. | Accepted | Sessions |
| D-335 | Search | Closed-document collections, filesystem crawling, remote search, Cloud search, and synchronized indexes remain deferred. | Deferred | Future Search |
| D-336 | Search | Version-1 Search indexes authoritative Text and metadata, while PDF text remains a provenance-bearing derived projection and recognition-derived text remains excluded. | Accepted | Text, PDF |
| D-337 | Search | Built-in content owners expose immutable bounded searchable projections through AL NOTE-owned contracts. | Accepted | Objects |
| D-338 | Search | Unknown, unsupported, unavailable, and missing-handler content is omitted with structured reasons rather than interpreted by Search. | Accepted | Preservation |
| D-339 | Search | PDF text extraction remains owned by PDF System, and unlocked protected-PDF text cannot enter persistent plaintext indexes without equivalent protection and explicit policy. | Accepted | PDF, Security |
| D-340 | Search | Version 1 uses bounded direct scanning as its semantic reference and an AL NOTE-owned pure-Dart in-memory inverted index as its primary optimization. | Accepted | Search engine |
| D-341 | Search | Persistent indexes are optional capability-dependent sensitive caches outside `.alnote`, bound to opaque document and compatibility identities and always safely rebuildable. | Accepted | Storage, Security |
| D-342 | Search | No Search backend or dependency is accepted; SQLite FTS5, MiniSearch, Tantivy, Lucene, Joplin, and Xournal++ remain studies or references, while Hivez is rejected for version 1. | Accepted | Open-source evaluation |
| D-343 | Search | Public query semantics use a typed bounded backend-independent model supporting text, phrases, final-token prefixes, sensitivity controls, and scoped filters. | Accepted | Query model |
| D-344 | Search | Boolean expression trees, arbitrary wildcards, regex, fuzzy matching, proximity syntax, stemming, and semantic search remain deferred. | Deferred | Future Search |
| D-345 | Search | One versioned normalization contract preserves mappings from matching representations to original grapheme-safe source ranges. | Accepted | Unicode |
| D-346 | Search | Ranking and tie-breaking are deterministic, documented, and independent of backend-specific scores. | Accepted | Query model |
| D-347 | Search | Immutable result occurrences carry query, content, source, projection, range, generation, freshness, completeness, and resolvability identities. | Accepted | Results |
| D-348 | Search | Open-Session Search aggregates independent per-Session results and generations without claiming global atomicity. | Accepted | Sessions |
| D-349 | Search | Search incrementally observes committed immutable document transitions and performs broader rebuilding when change descriptions are incomplete. | Accepted | Commands |
| D-350 | Search | Candidate index changes publish atomically per independently indexed document or source and never expose incomplete builds as current. | Accepted | Index lifecycle |
| D-351 | Search | Search lifecycle, freshness, completeness, availability, and persistence state remain independent axes. | Accepted | Search state |
| D-352 | Search | Stale, partial, locked, unsupported, omitted, or unavailable content is disclosed and cannot be misreported as an authoritative no-results outcome. | Accepted | Results |
| D-353 | Search | Queries use explicit request revisions, pin immutable inputs, cooperate with cancellation, and discard superseded late results. | Accepted | Sessions |
| D-354 | Search | Sessions coordinate document-scoped Search jobs and source freshness while Search owns indexing and query semantics. | Accepted | Sessions |
| D-355 | Search | Save does not establish Search freshness, while Save As creates a distinct validated persistent-cache association. | Accepted | Storage |
| D-356 | Search | Recovery never depends on Search data, and Search rebuilds only from Recovery’s reconstructed committed document root. | Accepted | Recovery |
| D-357 | Search | Indexes, queries, snippets, and extracted text are sensitive; ordinary logging excludes them and query history is disabled by default. | Accepted | Security, Privacy |
| D-358 | Search | Persistent plaintext indexes are prohibited for encrypted documents or unlocked protected PDFs unless equivalent protection is explicitly established. | Accepted | Security, PDF |
| D-359 | Search | Projection, extraction, indexing, query, result, cache, concurrency, and cancellation work is centrally resource-bounded. | Accepted | Security |
| D-360 | Search | Search persistence and execution are capability-based across Linux, Windows, Android, and Web, including explicit multi-process and multi-tab coordination. | Accepted | Platforms |
| D-361 | Search | Search exposes presentation-neutral progress, freshness, completeness, warning, result, navigation, cancellation, and accessibility contracts. | Accepted | UI, Accessibility |
| D-362 | Search | Search failures and cancellation use structured outcomes; corrupt derived caches are discarded or quarantined without risking document content. | Accepted | Failure handling |
| D-363 | Search | Direct scanning acts as the semantic oracle for indexed-backend conformance, supplemented by adversarial, property, fuzz, Unicode, and cross-platform tests. | Accepted | Testing |
| D-364 | Search | Search and Indexing architecture belongs under `lib/search/`, with no external Search dependency accepted. | Accepted | Repository architecture |

## Deferred Object System Questions

- Exact transform encoding
- Numeric precision and coordinate limits
- Common metadata fields
- Group ownership and nesting
- Image and PDF resource references
- Exact serialization format
- Plugin packaging and security
- Synchronization provenance

## Deferred Layer System Questions

- Nested layers and layer groups
- Arbitrary blend modes
- Export and print participation policy
- Exact PDF and background source binding
- Resource ownership
- Cross-page object moves
- Plugin loading and security
- File encoding
- Full grouping ownership

## Open-Source Record

- Rnote is GPL-3.0-or-later; adapt relevant retained-document concepts only.
- Xournal++ is GPL-2.0-or-later; concepts may be studied, but direct reuse requires file and dependency auditing.
- Krita provides useful layer concepts, but its node system is too complex for AL NOTE.
- Dart `built_collection` may be evaluated behind AL NOTE-owned interfaces but must not become a permanent serialized contract.

## Deferred Selection and Transform Questions

- Other sub-object editing types
- Custom pivots
- Snapping and alignment guides
- Direction-dependent rectangle selection
- Overlap cycling
- Group selection behavior
- Reflection
- Skew
- Perspective transforms
- Exact transform serialization
- Exact revision and stale-state token mechanism
- Read-only inspection ownership

## Selection and Transform Open-Source Record

- Rnote is GPL-3.0-or-later; adapt note-oriented selection concepts.
- Xournal++ is GPL-2.0-or-later; direct reuse requires file and dependency auditing.
- Krita provides useful transform-session and preview concepts, but its advanced transformation scope is excessive for AL NOTE.
- Flutter transformation primitives may support viewport and temporary UI mechanics but do not replace the document Selection System.
- Dart `vector_math` may be reused behind AL NOTE-controlled transform validation contracts.

## Deferred Command, Undo, and Redo Questions

- Cross-document atomicity
- Collaboration rebasing
- Persistent or disk-backed history
- Crash-recovery journal format
- Exact resource storage and reclamation strategy
- Immutable collection dependency
- Very-large-command spill policy
- Persistent content fingerprint
- Exact revision implementation

## Command, Undo, and Redo Open-Source Record

- Rnote is GPL-3.0-or-later; adapt command and history concepts only.
- Xournal++ is GPL-2.0-or-later; direct reuse requires file and dependency auditing.
- Krita provides useful history, merging, and memory-limit concepts but is substantially more complex.
- The Dart `undo` package is Apache-2.0 but is unsuitable as AL NOTE’s command core.
- `built_collection` remains a benchmarking candidate.
- `fast_immutable_collections` is BSD-2-Clause and remains a benchmarking candidate.
- No command or immutable-collection dependency is accepted yet.

## Deferred Storage and File Format Questions

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

## Storage and File Format Open-Source Record

- Rnote is GPL-3.0-or-later and offers useful persistence concepts, but its format should not be adopted wholesale.
- Xournal++ is currently identified as GPL-2.0; direct code reuse requires file-level and dependency licensing review.
- ODF provides useful ZIP-package concepts without requiring AL NOTE to adopt ODF schemas.
- SQLite is public domain but is not selected as the canonical format.
- Dart `archive` is MIT and remains a prototype candidate.
- `json_serializable` is BSD-3-Clause and may only be used with explicit unknown-field preservation.
- Freezed is MIT and is only an optional implementation aid.
- Protocol Buffers and FlatBuffers are rejected for canonical version-1 records.
- No storage dependency is accepted yet.

## Deferred Autosave and Recovery Questions

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

## Autosave and Recovery Open-Source Record

- Xournal++ provides useful handwriting autosave concepts, but direct reuse requires licensing review.
- Krita demonstrates separate autosave files, recovery for saved and unsaved documents, and restoring recovered work as modified.
- LibreOffice demonstrates separation of AutoRecovery from normal saving.
- SQLite WAL provides useful commit and checkpoint concepts, and SQLite is public domain.
- No recovery implementation dependency is accepted.

## Deferred Drawing Tool System Questions

- Exact Interaction Mapping rules
- Gesture arbitration
- Pressure curves and brush algorithms
- Highlighter compositing
- Detailed stroke payload encoding
- Shape, Text, Image, and PDF payloads
- Plugin sandboxing
- Preset storage and synchronization
- Resource-limit values
- Multipointer specialist tools
- User-facing stale-command behavior
- Exact Drawing Tool dependencies

## Drawing Tool System Open-Source Record

- Rnote is GPL-3.0-or-later and is an architectural reference.
- Xournal++ is a behavioral reference; direct reuse requires file-level licensing review.
- Krita is a conceptual reference for presets and input actions but is too complex for adoption.
- libmypaint is ISC-licensed but raster-oriented and unsuitable for the initial vector-first engine.
- MyPaint is a behavioral reference only.
- `perfect-freehand` is MIT-licensed and may be evaluated behind the Stroke System, not adopted as the Tool System.
- Dart `perfect_freehand`, Scribble, and similar Flutter packages require benchmarking, provenance, maintenance, and compatibility review.
- No Drawing Tool dependency is accepted.

## Deferred Interaction Mapping Questions

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

## Interaction Mapping Open-Source Record

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

## Deferred Text Object System Questions

- Lists and indentation
- Hyperlinks
- Text highlighting
- Semantic headings
- Superscript and subscript
- Collaborative text anchors
- Automatic stale-draft merging
- Embedded-font subsetting
- Exact bundled fonts
- Advanced OpenType features
- Vertical writing
- Spell-check configuration
- Text flow between objects
- Inline objects
- Structured mathematics
- Deterministic export layout profile
- Exact editor and layout dependencies
- Exact resource limits
- Full language-tagging policy

## Text Object System Open-Source Record

- Flutter is BSD-3-Clause and may provide editing, IME, and engine integration behind adapters.
- Skia uses a permissive BSD-style license and is a layout and rendering reference.
- HarfBuzz is MIT-licensed and is a shaping reference.
- ICU and Unicode algorithms provide permissively licensed behavioral baselines.
- Rnote is GPL-3.0-or-later and is a note-application reference.
- Xournal++ is displayed as GPL-2.0; direct reuse requires file-level licensing review.
- ProseMirror is MIT-licensed, but its browser document model is too broad.
- Quill and Delta offer useful change concepts but are not the version-1 persistent format.
- Flutter Quill is MIT-licensed and may be evaluated only as an editing adapter.
- AppFlowy Editor currently reports dual AGPL-3.0/MPL-2.0 licensing and is not selected.
- Super Editor and Fleather require exact license, maintenance, IME, and platform verification before adoption.
- No external editor library is accepted.
- No editor library may define AL NOTE's persistent Text format.

## Deferred Image Object System Questions

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

## Image Object System Open-Source Record

- Flutter and Skia codecs are the initial rendering and bounded-decoding baseline, subject to AL NOTE validation.
- The Dart `image` package is MIT and may be evaluated for controlled metadata, conversion, and testing work.
- libvips is LGPL-2.1-or-later and may be considered later for low-memory desktop or server processing.
- ImageMagick is GPLv3-compatible but should not be embedded as the unrestricted core decoder.
- Rnote is an architectural reference.
- Xournal++ is a behavioral reference; direct reuse requires file-level license review.
- No external Image dependency is accepted yet.

## Deferred Shape Object System Questions

- General and compound paths
- Bézier curves and splines
- Arcs, stars, callouts, and connectors
- Gradients, patterns, textures, and effects
- Per-corner or elliptical rectangle radii
- Stable vertex UUIDs
- Stroke alignment
- Variable-width strokes
- Non-scaling stroke modes
- Boolean geometry
- Parametric constraints
- Text inside shapes
- Recognition-generated shapes
- Transform baking
- Parametric-to-path conversion

## Shape Object System Open-Source Record

- Rnote is GPL-3.0-or-later and is an architectural reference.
- Xournal++ is displayed as GPL-2.0; direct reuse requires exact file-level licensing review.
- Krita is GPL v3 and is a conceptual reference whose full vector model is too complex for version 1.
- Flutter `Path` and `Paint` are rendering-adapter concepts only.
- Skia is BSD-3-Clause and is a rendering reference, not a persistent-data API.
- SVG provides useful semantic and export terminology but is not AL NOTE's internal file model.
- `vector_math` is BSD-3-Clause and may be evaluated behind AL NOTE-owned geometry contracts.
- `path_parsing` is MIT and may later be evaluated for import and export adapters.
- No external Shape dependency is accepted.

## Deferred PDF System Questions

- Editable native PDF annotations
- AcroForm and XFA editing
- Digital signatures
- Multipage movable Objects
- OCR
- Corrected reading order
- Search indexing
- PDF/A and PDF/X conformance
- Professional print color management
- Password persistence
- Output encryption
- Incremental modification of original PDFs
- Source-layer box or rotation remapping
- PDF resource subsetting
- Exact backend dependency
- Exact export composer dependency
- Interactive native annotation export

## PDF System Open-Source Record

- PDFium uses permissive core licensing with bundled third-party notices that require a complete audit.
- PDF.js is Apache-2.0 and is a strong Web backend candidate.
- `pdfrx` is an MIT Flutter wrapper around PDFium and is the leading four-platform integration candidate, subject to binary provenance, security, API, and license audits.
- MuPDF is AGPL or commercial and is rejected as the default unless AL NOTE intentionally accepts the additional AGPL obligations.
- Poppler is a useful desktop reference but not the preferred four-platform default.
- The Dart `pdf` package is Apache-2.0 and is an export-generation candidate, but source-page reuse and sanitization capabilities require testing.
- qpdf is Apache-2.0 and is a content-preserving transformation reference or possible native helper, but it is not a universal Web dependency.
- Rnote is a GPL-3.0-or-later architectural reference.
- Xournal++ is a behavioral reference requiring file-level license review.
- Syncfusion PDF is not an open-source dependency and is rejected.
- No PDF dependency is accepted yet.
- AL NOTE will not implement a PDF parser or renderer from scratch.

## Deferred Import and Export Questions

- Additional import and export formats
- Cloud sources and destinations
- Remote acquisition and publication
- Archive import
- SVG import and export
- Office-document import
- Advanced presets
- Cross-document import transactions
- Editable PDF annotation export
- PDF archival conformance
- Animated output
- Global atomicity for multiple separate files
- Exact picker and sharing dependencies
- Exact image encoder dependency
- Exact PDF composer dependency
- OCR-assisted import
- Recognition-aware export
- Sync-integrated import and export

## Import and Export Open-Source Record

The following remain candidates only:

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

Every dependency and bundled binary requires a pinned transitive-license, security, maintenance, and platform audit before acceptance.

No external Import or Export dependency is accepted.

## Deferred Application State and Document Sessions Questions

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

## Application State and Document Sessions Open-Source Record

- Flutter is BSD-3-Clause and may provide lifecycle, focus, exit-request, and restoration primitives behind AL NOTE-owned adapters.
- Flutter lifecycle callbacks are not durability guarantees.
- Rnote is GPL-3.0-or-later and is a conceptual multi-document handwriting reference.
- Xournal++ is GPL-2.0-or-later and is a conceptual autosave and handwriting-document reference; direct reuse requires file-level auditing.
- Krita is GPLv3-compatible and is a conceptual multi-view, recovery, and document-lifecycle reference.
- LibreOffice provides useful Save, AutoRecovery, and multi-document concepts, but direct reuse is unsuitable and individual licensing still requires auditing.
- No state-management or window-management dependency is accepted.

## Deferred User Interface Architecture Questions

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

## User Interface Architecture Open-Source Record

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

## Deferred Settings and Preferences Questions

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

## Settings and Preferences Open-Source Record

- Flutter `shared_preferences` is BSD-3-Clause and cross-platform but is intended for simple key-value data and does not guarantee durable completion; it is not accepted as the canonical Settings store.
- SQLite is public domain and is a leading native transactional candidate, but no Flutter binding or bundled binary is accepted.
- IndexedDB is the leading transactional Web candidate, but no Dart or Flutter adapter is accepted.
- Platform preference stores may be considered only for narrow noncritical uses.
- Rnote is GPL-3.0-or-later and is a conceptual Settings and Tool-preset reference.
- Xournal++ is a conceptual Settings, stylus, and PDF-workflow reference; direct reuse requires exact file-level licensing review.
- Krita is a conceptual Tool-preset, backup, and configuration-reset reference.
- LibreOffice is a conceptual layered-configuration reference and is unsuitable for direct reuse.
- No Settings dependency is accepted.

## Deferred Plugin System Questions

- Executable external plugins
- WebAssembly runtime selection and host API
- Runtime Dart and native plugin loading
- Plugin-to-plugin dependencies and resolution
- Marketplace, catalog, discovery, and online updates
- Certificate authorities and transparency services
- Signing algorithms, envelope, and canonicalization
- Archive and cryptography dependencies
- Exact SBOM format and automated license decisions
- Executable plugin migrations
- Plugin-defined renderers, hit testing, Tools, handlers, Search, indexing, and recognition
- Sync-distributed plugins
- Final numerical limits
- Security audit storage and retention
- Final plugin-management UI
- Formal sandbox-security claims

## Plugin System Open-Source Record

- Version-1 external plugins are declarative and use only AL NOTE-owned interpreters.
- Trusted Dart extensions remain compiled application source.
- A future WebAssembly boundary may be studied, but no runtime is selected.
- `.alnote-plugin` is conceptually ZIP-based, but no archive dependency is accepted.
- SPDX-oriented declarations support review but do not automatically determine legal compatibility.
- No plugin, archive, signature, cryptography, WebAssembly, marketplace, or sandboxing dependency is accepted.

## Deferred Search and Indexing Questions

- Closed and registered document collections
- User-folder and filesystem indexing
- Remote, Cloud, and synchronized Search
- Tags without an authoritative model
- OCR and handwriting, Math, or symbol recognition
- Recognition provenance
- Semantic and vector Search
- Boolean, proximity, fuzzy, regex, and stemming features
- Language-specific analyzers
- Executable plugin Search providers
- Encrypted persistent-index design
- Search-result Export
- Exact resource limits
- SQLite FTS5, Tantivy, and other persistent backend adoption
- Final Search UI

## Search and Indexing Open-Source Record

- SQLite FTS5 remains a possible future native persistent-backend study.
- MiniSearch is a Web architectural reference.
- Tantivy remains a possible future large native-collection study.
- Lucene is an architectural reference.
- Joplin is a behavioral reference.
- Xournal++ is a PDF-search behavioral reference.
- Hivez is rejected for version 1 because its storage coupling, adoption, semantic control, and maturity do not justify foundational use.
- No third-party Search dependency is accepted.

## Roadmap

- Search and Indexing — Accepted with modifications
- Security and Privacy Architecture — Next subsystem
- Recognition, Math Recognition, Symbolic Math, and optional Sync/Cloud — Post-v1
