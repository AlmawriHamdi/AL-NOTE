# Drawing Tool System

Status: **Accepted with modifications**

## Purpose

The Drawing Tool System converts normalized input already assigned by Interaction Mapping into:

- Temporary previews
- Safe gesture outcomes
- Validated atomic Command Requests
- Delegation to Selection, Stroke, Hit-Testing, and Viewport systems

Tools never directly mutate persistent document state.

## Core Model

The conceptual model contains:

1. Immutable Tool Definition
2. Tool Preset
3. Lightweight Tool Activation
4. Mutable isolated Gesture Session
5. Temporary Tool Preview
6. Command Request
7. One logical Tool Registry

These are architectural concepts, not prescribed implementation classes or Dart filenames.

## Tool Identity

Tools use stable namespaced string identities.

- `alnote.*` is reserved for built-in tools.
- Plugin namespace allocation belongs to the future Plugin System.
- No specific plugin identity syntax is permanently required yet.
- Tool identity represents behavior, not an individual preset.
- Tool identities are normally runtime data, not canonical document data.

## Input and Pointer Boundaries

Interaction Mapping selects the tool or action.

Tools receive only normalized input assigned to them. They do not own general touch, stylus, mouse, keyboard, or gesture arbitration.

Gesture sessions default to one primary pointer.

- The Drawing Engine coordinates pointer capture.
- Platform adapters perform native capture.
- Multipointer specialist tools remain deferred.

A gesture cancels safely on:

- Capture loss
- Pointer cancellation
- Document closure
- Page changes
- Application suspension
- Invalid input
- Unavailable coordinate conversion
- Plugin failure

Changing the active tool normally affects the next gesture. An existing gesture retains its original tool and preset snapshot unless cancellation is required.

## Preview Boundary

Tool previews:

- Use page or document coordinates
- Remain outside persistent objects
- Never enter Command History, storage, or recovery
- Are disposable
- Render through shared graphics contracts
- Cannot masquerade as committed content

Finite coordinates outside page bounds are not automatically invalid. Tools follow accepted Page and Object recoverability policies.

Rendering may clip previews and committed content to visible page bounds.

## Command Integration

A completed gesture proposes one atomic Command Request.

Tools never directly mutate persistent objects, layers, or documents.

Input is validated before submission. The Command System performs final validation during serialized publication.

A stale or rejected request produces no persistent change. Tools must not silently replay rejected gestures against newer state.

Asynchronous preparation is allowed, but publication remains atomic.

## Built-In Tool Boundaries

Pen, Pencil, Marker, and Highlighter use shared Stroke System services.

They differ through validated behavior and appearance profiles. They do not implement separate smoothing or outline engines.

Stroke Eraser uses Hit-Testing to identify complete strokes.

Partial Eraser uses stroke-intersection and splitting services.

One eraser gesture produces one atomic request or no persistent change.

Selection Tool delegates to `lib/drawing/selection/`.

Pan and navigation are Interaction Mapping actions that invoke Viewport operations, not Drawing Tools.

Shape, Text, Image, and PDF insertion tools use placement-session boundaries. Their owning object and import systems define their persistent payloads.

## Persistent Stroke Independence

Committed strokes contain:

- Authoritative raw samples
- Available pressure, tilt, orientation, timestamps, and pointer data
- Resolved appearance properties
- Resolved behavior parameters required for later rendering or processing
- Required transforms and object data

A committed stroke remains renderable and editable without:

- The original Tool Preset
- The active tool
- An installed plugin tool
- Runtime gesture state

Optional tool or profile identifiers may be retained as provenance, but cannot be the only source of appearance or behavior.

## Settings Boundary

The following are not stored in `.alnote` document data:

- Active tool
- Tool activation
- Gesture sessions
- Pointer capture
- Previews
- Hover state
- Temporary hit results
- Uncommitted samples
- User preset names
- Toolbar placement
- Shortcuts
- Recently used settings

Tool-preset persistence belongs to the future Settings System.

## Plugin Boundary

Plugin tools receive only restricted services such as:

- Assigned normalized input
- Read-only document queries
- Coordinate conversion
- Temporary preview submission
- Approved Stroke and Geometry services
- Restricted Command Request submission
- Cancellation and resource limits

Plugin tools cannot receive:

- Mutable document collections
- Direct Command History mutation
- Platform graphics APIs
- Unrestricted storage access
- File-load execution
- A path around Command validation

Plugin failure cancels and isolates the gesture.

## Persistence and Recovery

Only completed object results committed through Commands are persistent.

Incomplete gestures, previews, pointer capture, and active-tool state are not persisted.

Recovery records only committed persistent results.

## Folder Ownership

`lib/drawing/tools/` owns the architecture for:

- Tool definitions
- Tool identity
- Tool capability declarations
- Preset snapshots
- Gesture-session lifecycle
- Restricted tool context
- Tool outcomes
- Tool registration boundaries

No implementation subfolders are defined yet.

## Dependency Status

No Drawing Tool dependency is accepted.

Brush, stroke-outline, and input packages must remain behind AL NOTE-owned boundaries and require later evaluation.

## Open-Source Record

- Rnote is GPL-3.0-or-later and is an architectural reference.
- Xournal++ is a behavioral reference; direct reuse requires file-level licensing review.
- Krita is a conceptual reference for presets and input actions but is too complex for adoption.
- libmypaint is ISC-licensed but raster-oriented and unsuitable for the initial vector-first engine.
- MyPaint is a behavioral reference only.
- `perfect-freehand` is MIT-licensed and may be evaluated behind the Stroke System, not adopted as the Tool System.
- Dart `perfect_freehand`, Scribble, and similar Flutter packages require benchmarking, provenance, maintenance, and compatibility review.
- No Drawing Tool dependency is accepted.

## Deferred Matters

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
