# Text Object System

Status: **Accepted with modifications**

## Purpose

The Text Object System provides searchable, accessible, editable Unicode text as transformable Page Objects.

It owns:

- Persistent text content
- Constrained rich formatting
- Text-box constraints
- Font requests and fallback metadata
- Text-specific validation and migration
- Platform-independent layout contracts
- Editing and Command boundaries
- Logical-text exposure

It does not own:

- Layer membership
- General Object Selection
- Interaction Mapping
- Command execution
- Rendering backends
- Search indexing
- UI widgets
- Settings persistence
- Structured mathematics

## Object Type and Envelope

The built-in Text Object identity is:

`alnote.text`

A Text Object uses the accepted common Page Object envelope.

The envelope already contains:

- Object UUID
- Type identity
- Type-schema version
- Common transform
- Visibility
- Locking
- Common metadata
- Type payload
- Extension data

The type-schema version is not duplicated inside the Text payload.

The Text payload contains:

- Ordered paragraphs
- Ordered styled runs
- Text-box layout mode
- Intrinsic width and optional height
- Internal padding
- Vertical alignment
- Overflow policy
- Default character style
- Default paragraph style
- Font requests
- Preserved safe unknown fields

The following are not persisted:

- Caret
- Text-range selection
- IME composition
- Editor focus
- Spell-check marks
- Glyph IDs or positions
- Soft-wrapped lines
- Screen coordinates
- Editor scroll position
- Layout or font caches

## Version 1 Rich-Text Model

Version 1 uses constrained rich text:

Text Object → ordered paragraphs → ordered styled runs → Unicode text

Character styles support:

- Font-family request
- Font size
- Font weight
- Italic
- Underline
- Strikethrough
- Text color

Paragraph styles support:

- Left, center, right, and justified alignment
- Direction-aware start and end alignment
- Automatic, LTR, or RTL base direction
- Line-height multiplier
- Optional BCP 47 language hint

Version 1 persistent styles use built-in semantics only.

The following remain deferred:

- Lists and indentation
- Semantic headings
- Background highlighting
- Superscript and subscript
- Hyperlinks
- Tables
- Inline images and files
- Arbitrary embedded objects
- Advanced OpenType features
- Ruby annotations
- Vertical writing
- Plugin-defined authoritative styles

Adjacent runs may merge only when their known styles and preserved unknown extension data are equivalent.

Empty runs are editing-state details and are not normally persisted.

## Unicode Model

- Valid Unicode is persisted through deterministic UTF-8 JSON.
- The user's original Unicode normalization form is preserved.
- Paragraphs are stored in logical reading order.
- Explicit paragraph boundaries and newlines are authoritative.
- Soft wrapping is derived.
- Emoji, combining marks, variation selectors, and zero-width-joiner sequences are supported.
- Maintained Unicode-aware components handle bidirectional text, segmentation, shaping, and line breaking.
- Complex Unicode algorithms are not implemented manually.

## Persistent Range Model

Version 1 persistent editing requests identify ranges using:

- Paragraph position within the expected object revision
- Unicode-scalar boundaries
- Expected Text Object revision

Visual caret affinity is temporary editor and layout state, not persistent Command data.

Ordinary editing operates safely at extended grapheme-cluster boundaries.

Adapters may temporarily translate to Flutter UTF-16 offsets. UTF-16 is not the persistent file-format or Command contract.

Persistent paragraph UUIDs and collaboration-stable text anchors remain deferred.

## Text-Box Layout Modes

Version 1 supports:

1. Auto-size
2. Fixed width with automatic height
3. Fixed width and fixed height

Rules:

- Auto-size remains bounded by safety limits.
- Fixed width causes text reflow.
- Fixed-box overflow is visually clipped without deleting content.
- Overflow indicators are temporary editor UI.
- Editing may temporarily scroll within a fixed box.
- Persistent editor scroll position is not required.
- Page overflow follows accepted Page recoverability rules.
- Canceling creation of a new empty Text Object creates no persistent object.
- Deleting all content from an existing Text Object leaves an empty object unless explicitly deleted.

## Resize and Transform

These operations remain distinct:

- Text-box resize changes intrinsic box dimensions and reflows text.
- Common transform scaling visually scales the laid-out object without reflow.
- Rotation belongs to the common Object transform.
- Editing and hit-testing use local coordinates converted through the common transform.
- Non-uniform transform scaling does not redefine font sizes or text content.

## Authoritative and Derived Data

Authoritative data includes:

- Logical Unicode text
- Paragraph boundaries
- Built-in styles
- Optional language and direction hints
- Text-box constraints
- Font requests
- Resource references
- Common Object transform

Derived and rebuildable data includes:

- Glyph IDs
- Glyph positions
- Shaped runs
- Soft line wraps
- Caret stops
- Range geometry
- Actual fallback selections
- Layout fragments
- Raster output
- Layout caches

## Font Model

The controlled font model combines:

- A small open-licensed, redistributable bundled baseline font set
- Optional embedded font resources when redistribution and embedding are legally permitted
- System-font requests
- Generic and script-aware fallback families

Persisted font requests may contain:

- Preferred family
- Style attributes
- Optional embedded font-resource UUID
- Optional resource fingerprint
- Generic fallback category
- Safe substitution hint

They do not contain:

- Absolute system font paths
- Private device identifiers
- Unverified claims that a font license permits embedding

Rules:

- Arbitrary system fonts are never embedded automatically.
- Embedded fonts use accepted Resource System UUID and hash contracts.
- Missing fonts do not alter or delete text.
- Fallback may cause limited reflow.
- Pixel-identical cross-platform layout is not promised.
- Export should prefer bundled or legally embedded fonts for greater stability.
- Malicious font files require hardened validation and safe fallback.

Exact baseline fonts, font subsetting, and embedding-policy implementation remain deferred.

## Layout Contract

AL NOTE owns a platform-independent Text Layout contract, not a custom shaping engine.

The contract receives:

- Paragraphs and style runs
- Font-resolution results
- Effective language and direction hints
- Box constraints
- Resource limits

It returns derived:

- Line and glyph fragments
- Caret stops
- Range geometry
- Logical and visual bounds
- Overflow state
- Hit-test mappings
- Font-substitution diagnostics

Flutter, Skia, HarfBuzz, ICU, and other maintained Unicode-aware services remain behind adapters.

Persistent Text Objects do not depend directly on Flutter widgets, Canvas, or engine-specific glyph structures.

## Editing Session

A focused Text Editor session owns temporary:

- Draft content
- Caret
- Text-range selection
- Selection handles
- IME composition
- Typing style
- Spell-check decorations
- Editor scroll position
- Layout snapshot
- Base object revision
- Pending bounded edit batch

Text caret and range selection do not belong to general Object Selection.

Hidden, locked, deleted, or replaced Text Objects cannot continue ordinary editing without revalidation.

## IME

- Composition updates remain temporary.
- Incomplete composition never enters Commands or Recovery.
- Platform-confirmed composition becomes committed text.
- Cancellation restores the last committed state.
- A crash may lose only active uncommitted composition.
- Canvas shortcuts yield to active text input and IME composition.

## Command and Undo Integration

Every persistent text change passes through the Command System.

Persistence is not delayed until the entire editing session ends merely to create one undo entry.

Use:

- Prompt commits for completed semantic input transactions
- Very short bounded batching where performance requires it
- Explicit maximum commit latency
- Flushes on focus loss, lifecycle changes, object switching, and editor closure
- Command-history coalescing for user-facing undo groups

History coalescing may group:

- Consecutive insertions
- Consecutive backward deletions
- Consecutive forward deletions

It does not merge:

- Insertion with deletion
- Forward deletion with backward deletion
- Paste with ordinary typing
- Formatting with typing
- Unrelated range replacements

A merge group ends on:

- Caret movement
- Selection change
- Formatting change
- Paste
- Focus change
- Composition commit boundary
- Object switch
- Save barrier
- Explicit editor boundary
- Accepted idle policy

Paste and formatting changes form separate semantic Commands.

Undo and redo restore the same Text Object UUID.

Recovery protects only committed text. Bounded commit latency prevents long typing sessions from remaining outside recovery protection.

## Stale Editing Sessions

Each edit uses the expected Text Object revision.

On a stale revision:

- Reject the persistent mutation.
- Preserve the draft in memory.
- Do not automatically merge or rebase.
- Do not silently overwrite the current object.
- Offer explicit recovery choices such as reload, copy draft, or create a recovered Text Object.
- Require later architecture before automatic text merging is introduced.

This preserves the accepted deferral of automatic rebasing.

If a layer becomes hidden or locked, further commits stop and the draft remains preserved until the conflict is resolved.

## Clipboard and Paste

Version 1 may accept:

- Plain Unicode text
- Internal AL NOTE constrained-rich-text data
- A strictly sanitized subset of HTML or platform-attributed text

Rules:

- Prefer the internal format for AL NOTE-to-AL NOTE copying.
- Convert only supported formatting to built-in styles.
- Strip scripts, event handlers, stylesheets, forms, frames, remote resources, and active content.
- Do not fetch remote resources.
- Convert unsupported structures to readable plain text.
- Treat images and files as separate insertion or import operations.
- Do not activate pasted hyperlinks in version 1.
- Validate and limit paste size before persistent allocation.
- Sanitize before Command submission.

The exact HTML parser or sanitization dependency remains deferred.

## Rendering and Hit Testing

Rendering receives a validated Text payload and derived layout result. It cannot mutate the Text Object.

Text layout exposes:

- Intrinsic local bounds
- Visual bounds
- Layout fragments
- Caret stops
- Range geometry
- Point-to-text mapping
- Overflow state
- Font-substitution diagnostics

Rendering applies the common transform after local layout.

Hit testing transforms Page coordinates into Object-local coordinates before querying layout.

Zoom changes rendering quality, not persistent layout units.

## Search, Accessibility, and Export

Logical-text exposure contains:

- Paragraph text in logical order
- Paragraph boundaries
- Optional language and direction hints
- Object and paragraph positions
- Built-in style semantics when useful

Search consumes logical text, not glyph output.

Accessibility receives logical reading order and derived Page-space geometry. Active-editor caret and selection remain temporary accessibility state.

Export receives persistent content, styles, box constraints, font requests and resources, and layout contracts.

## Serialization and Repair

- The common envelope carries the Text type-schema version.
- Text payload serialization uses deterministic UTF-8 JSON.
- Paragraph and run ordering is authoritative.
- Geometry numbers are finite and bounded.
- Resource references use UUIDs.
- Layout caches are never serialized.
- Safe unknown fields are preserved.
- Newer unsupported payloads remain preserved and inert.

For corrupt formatting:

- Ordinary loading does not silently rewrite the Text payload.
- Safe fallback presentation may be generated without changing authoritative bytes.
- The original payload is preserved.
- Degraded behavior is reported.
- Explicit repair or migration creates a validated replacement through an approved recovery or Command path.
- Text content takes priority during explicit recovery, but any data loss is reported.

## Plugin Boundary

Version 1 persistent Text Objects use built-in style and layout semantics only.

Plugins may:

- Read sanitized logical text with permission
- Suggest formatting or transformations
- Add non-authoritative editor decorations
- Request changes through Commands

Plugins may not:

- Receive secure input or active composition without explicit permission
- Mutate Text payloads directly
- Define required shaping behavior
- Make authoritative layout depend on plugin availability
- Execute content embedded in text

Unknown plugin extension data may be preserved but remains non-authoritative and inactive when unavailable.

## Structured Mathematics Boundary

Ordinary Unicode mathematical characters may remain normal Text content.

Structured expressions, equation layout, recognition, evaluation, variable storage, and solving belong to future separate Math Recognition, Math Object, and Symbolic Math architecture.

Structured mathematics is not placed inside the version-1 Text Object model.

## Security and Limits

Configurable limits apply to:

- Text length
- Paragraph count
- Run count
- Style count and size
- Font-resource size
- Paste size
- Layout time and memory
- Font size
- Line height
- Box dimensions

Security behavior includes:

- Reject malformed JSON and invalid numeric values.
- Preserve or quarantine corrupted payloads instead of deleting them.
- Warn about suspicious bidirectional controls in security-sensitive contexts without generally deleting valid controls.
- Harden font parsing.
- Stop layout on resource-budget exhaustion.
- Display a recoverable placeholder when necessary.
- Never execute clipboard or text content.
- Treat future external links as untrusted.

## Folder Ownership

`lib/documents/objects/text/` conceptually owns:

- Persistent Text payload
- Built-in text and paragraph styles
- Text validation and migrations
- Layout contracts
- Editing and Command-integration contracts
- Clipboard sanitization contracts
- Logical-text accessibility exposure

No implementation subfolders are defined yet.

Flutter widgets, platform text-input adapters, and rendering implementations remain in their appropriate application and rendering areas.

## Dependency Status

No external editor library is accepted.

No editor library may define AL NOTE's persistent Text format.

## Open-Source Record

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

## Deferred Matters

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
