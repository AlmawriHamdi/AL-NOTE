# Search and Indexing

Status: **Accepted with modifications**

## Central Rule

Searchable projections and indexes are derived views of immutable authoritative content.

They are never authoritative document state and must remain replaceable, rebuildable, or discardable.

## Ownership

Search and Indexing owns:

- Immutable searchable-projection contracts
- Projection collection and validation
- Index construction
- Incremental projection replacement
- Index generations and lifecycle
- Query parsing and validation
- Query execution
- Deterministic ranking
- Result and occurrence identities
- Snippet generation
- Highlight mappings
- Query cancellation and supersession
- Freshness and completeness reporting
- Optional derived-index persistence contracts
- Index schema and integrity validation

It does not own:

- Authoritative Object payloads
- Document mutation or Commands
- Undo history
- Document Session lifecycle
- Storage loading or publication
- PDF parsing or passwords
- Recognition or OCR
- Plugin execution
- Settings persistence
- Recovery
- Final UI presentation
- Security policy
- Export publication
- Filesystem discovery
- Sync or remote Search

## Version-1 Scope

Version 1 guarantees Search over:

- Current Page
- Current document
- All open Document Sessions

Deferred scopes include:

- Closed-document collections
- Recent-document collections
- User-selected folders
- Entire-filesystem crawling
- Remote sources
- Cloud Search
- Synchronized indexes

Open-Session Search aggregates independent per-Session results.

Failure or partial indexing in one Session does not invalidate valid results from another.

There is no globally atomic index generation across independent Sessions.

## Searchable Content

Version 1 may search:

- Text Object Unicode content
- Notebook names
- Section names
- Page names
- Layer names
- Document titles
- Accepted descriptive metadata
- User-authored searchable Object metadata
- User-visible source display names
- PDF-derived text supplied by PDF System
- Authoritative Shape text only if already present in the accepted Shape model

Search does not create a new Shape-text model.

Tags remain deferred without an accepted authoritative tag model.

Version 1 does not treat these as recognized searchable text:

- Handwriting strokes
- Image pixels
- Image-only PDF pages
- Unknown Object payloads
- Recognition suggestions
- Non-authoritative accessibility descriptions
- Cached labels
- Passwords or secrets
- Recovery metadata
- Internal resource paths
- Plugin package metadata not incorporated into document content

Unknown Objects expose only generic AL NOTE-owned metadata.

Search cannot interpret opaque payloads.

Layer locking controls editing and does not prohibit searching.

Hidden-layer inclusion is an explicit deterministic query option. Hidden Layers are excluded by default.

## Searchable Projections

Immutable bounded projections contain:

- Projection schema version
- Document content-state identity
- Projection identity
- Source kind and stable identity
- Document identity
- Section, Page, Layer, and Object identities where applicable
- Field identity
- Authoritative source revision
- Original projected text or bounded segment
- Visibility and searchability attributes
- Ordered source-range mappings
- Provenance
- Capability state
- Continuation identity for chunked projections

Built-in Object implementations expose projections through AL NOTE-owned contracts beside their owning Object types.

Search does not permanently understand every Object payload format.

Document-structure owners provide metadata projections.

PDF System provides PDF projections.

Projection providers enforce resource limits.

Unsupported, unknown, unavailable, or missing handlers produce structured omission reasons.

Projection schema changes invalidate derived indexes. Indexes rebuild rather than becoming authoritative migration input.

## PDF Search

PDF System exclusively owns:

- PDF parsing
- Password handling
- PDF-engine calls
- Text extraction
- Page bindings
- Source locators
- Extraction limits
- Extraction capability reporting

Search consumes Page-scoped PDF projections.

Extracted PDF text is derived from authoritative source bytes. It is not authoritative document content.

PDF projections identify:

- PDF resource
- Bound AL NOTE Page
- PDF Page
- Extraction contract or engine version
- Text or selection locator
- Mapping confidence
- Reading-order confidence
- Extraction freshness

Search distinguishes:

- Searchable embedded text
- Image-only Page
- Locked PDF
- Unsupported extraction
- Malformed Page
- Partial extraction
- Approximate highlight mapping

Memory-only PDF unlocking remains owned by Sessions and PDF System.

Unlocked protected-PDF text remains memory-only unless a future Security decision permits equivalently protected persistent caching.

Locking again or ending the authorized Session invalidates unlocked projections and transient entries.

## Hybrid Architecture

Version 1 uses three layers:

1. Bounded direct scanning
2. AL NOTE-owned in-memory inverted index
3. Optional persistent derived caches

### Direct Scanning

Direct scanning is:

- Required
- The semantic reference implementation
- The cold-start fallback
- Suitable for small scopes
- Suitable for changed projections awaiting indexing
- The oracle for conformance tests

### In-Memory Index

The in-memory index is:

- Implemented in shared Dart
- Maintained per open Document Session
- Incrementally replaceable
- Backend-neutral
- Resource-bounded
- Based on the same semantics as direct scanning

### Optional Persistent Caches

Persistent indexes are:

- Capability-dependent
- Outside `.alnote`
- Application-private
- Versioned and integrity-checked
- Sensitive derived data
- Bound to opaque cache-document identity
- Bound to content-state identity
- Bound to projection, normalization, and backend versions
- Safe to delete and rebuild
- Never required to open documents

Source paths do not appear in cache filenames, logs, or diagnostics.

Cache failure falls back to scanning or memory indexing.

## Dependency Status

No Search backend or dependency is accepted.

Deferred studies and references include:

- SQLite FTS5 as a possible native persistent backend
- MiniSearch as a Web architectural reference
- Tantivy for possible large native collections
- Lucene as an architectural reference
- Joplin as a behavioral reference
- Xournal++ as a PDF-search behavioral reference

Hivez is rejected for version 1 because its storage coupling, adoption, semantic control, and maturity do not justify foundational use.

Integration libraries and transitive dependencies require licensing and security review.

## Incremental Indexing

After committed Commands, Search consumes bounded committed-change information and an immutable post-Command snapshot.

It handles:

- Added, replaced, deleted, and moved Objects
- Structural changes
- Page and Layer changes
- Metadata changes
- Undo and redo
- Import publication
- External reload
- Recovery reconstruction

Search observes committed state but cannot publish Commands.

Incomplete change descriptions cause broader bounded rebuilding.

Save does not reindex unchanged content.

Save As creates a distinct persistent-cache association.

External reload invalidates old source-epoch or content-identity generations.

Recovery indexes only its reconstructed committed root.

## Atomic Publication

Index construction uses immutable document snapshots.

For each independently indexed document or source:

1. Capture immutable content state.
2. Generate bounded projections.
3. Build a complete candidate delta or generation.
4. Validate source and content identities.
5. Publish atomically.

Incomplete builds never publish as current.

Independent Sessions use independent generations.

Queries may combine stable indexed content with bounded direct scans, but coverage must be reported accurately.

## Independent State Axes

Search keeps these axes separate:

- Lifecycle: idle, building, ready, cancelling, failed
- Freshness: current or stale relative to a content identity
- Completeness: complete or partial with covered and omitted scope
- Capability: available, unsupported, locked, missing handler, limited, unavailable
- Persistence: memory-only, cache-valid, cache-invalid, rebuilding, unavailable

A result may be usable, stale, partial, and degraded simultaneously.

Search never reports authoritative “no results” when content was locked, omitted, unsupported, unavailable, or unindexed.

## Query Model

Queries are typed immutable values.

Version 1 supports:

- Plain text
- Quoted phrases
- All-token matching by default
- Explicit any-token matching
- Final-token prefix matching
- Case-insensitive matching by default
- Explicit case-sensitive matching
- Explicit diacritic-sensitive or insensitive behavior
- Bounded document, Section, Page, Layer, field, and Object-type filters
- Explicit hidden-layer inclusion

UI controls may construct typed filters without typed syntax.

Malformed quotes, unsupported operators, excessive tokens, and invalid filters return structured errors.

Deferred query features include:

- Boolean expression trees
- Parenthesized expressions
- Arbitrary wildcards
- Regular expressions
- Fuzzy matching
- Proximity syntax
- Stemming
- Semantic or vector Search
- User-defined ranking expressions

Unsupported syntax is never silently reinterpreted.

## Unicode and Mapping

One AL NOTE-owned normalization contract is shared by scanning and every backend.

It:

- Preserves authoritative strings unchanged
- Builds separate normalized representations
- Uses a documented modern Unicode version
- Uses deterministic canonical normalization
- Uses locale-independent case folding
- Treats diacritic removal as explicit
- Maintains offset mappings
- Maps results back to original ranges
- Expands highlights to grapheme boundaries
- Preserves logical RTL ranges
- Leaves presentation direction to UI
- Provides deterministic fallback for scripts without whitespace boundaries

Universal linguistic tokenization or stemming is not promised.

Unicode and normalization versions are index compatibility identities.

## Ranking

Ranking is deterministic and documented.

It may consider:

- Exact phrases
- Complete-token matches
- Prefix matches
- Explicit field weights
- Match count and density
- Explicit current-scope proximity
- Document, Section, Page, Layer, and Object order
- Stable source identity and offset as final tie-breakers

Recency does not silently alter ranking.

Backend scores never become the public semantic contract.

## Result Identity

Immutable result occurrences include:

- Query revision
- Session or durable-document locator
- Content-state identity
- Command revision where applicable
- Index generation
- Source, Page, Layer, and Object identities
- PDF resource and Page identities where applicable
- Field and projection identities
- Match kind and normalized range
- Authoritative or derived source range
- Bounded snippet and snippet range
- Deterministic score
- Freshness, completeness, and resolvability

Aggregate results carry independent per-Session content identities, generations, coverage, and omissions.

Navigation re-resolves targets against current Session state.

Stale or missing targets return structured outcomes.

## Query Coordination

Every query receives a distinguishable request identity.

Active queries pin immutable projections or generations.

Cancellation is cooperative and checked between bounded chunks.

Superseded queries are cancelled where possible.

Late results are discarded unless their identity remains active.

Queries do not wait indefinitely for indexing.

They may use a current generation, explicitly stale generation, direct scanning, partial results, or an unavailable outcome.

Selected behavior and coverage remain explicit.

## Sessions, Storage, and Recovery

Sessions coordinate document indexing jobs, content identity, source epoch, memory pressure, cancellation, and close behavior.

Search owns index construction and query semantics.

Storage remains authoritative for loading documents and resources.

Search may request bounded lazy loading through existing contracts.

Closing releases transient indexes according to resource policy.

Persistent-cache reuse validates every identity, version, integrity field, and Security policy.

Recovery never depends on Search indexes, snippets, history, results, or caches.

Search rebuilds from Recovery’s reconstructed committed root.

Index loss cannot cause document-content loss.

## Privacy and Security

Indexes and snippets may be equivalent to plaintext document copies.

Rules include:

- Persistent caches use private locations.
- Queries, snippets, extracted text, and indexed content stay out of ordinary logs.
- Query history is disabled by default.
- Enabled history requires explicit Settings policy and remains sensitive.
- Passwords, secrets, internal paths, and PDF passwords are never indexed.
- Crash reports and notifications exclude snippets.
- Safe mode may disable caches and unavailable projections.
- Persistent plaintext indexes are prohibited for encrypted documents without equivalent protection.
- Persistent unlocked-PDF text is prohibited without equivalent protection and explicit policy.
- Cache cleanup is best effort and does not claim secure flash erasure.

Removal, factory reset, policy changes, and eviction trigger scoped cleanup.

## Limits

Central limits apply to projections, text, tokens, occurrences, document size, PDF extraction, query complexity, results, snippets, highlights, jobs, memory, caches, work slices, and cancellation latency.

Exact numerical values remain deferred.

Omitted content is reported.

## Platform Capabilities

Behavior is capability-based.

Linux and Windows may support private caches and process-lifetime background work.

Android tolerates suspension, termination, memory pressure, and limited background execution.

Web guarantees an in-memory baseline and treats persistence as optional, quota-limited, evictable, and potentially shared.

Multiple processes and tabs use coordination, isolated caches, or read-only reuse. Ambiguity causes safe rebuilding.

## Accessibility and UI Contracts

Search exposes presentation-neutral query descriptions, scope, counts, progress, freshness, completeness, omissions, warnings, labels, highlights, navigation, empty-state reasons, cancellation, and retry Actions.

UI retains keyboard interaction, announcements, focus, scaling, RTL, reduced motion, warnings, and final presentation.

## Failure and Cancellation

Structured outcomes include invalid queries, unsupported features, limits, cancellation, supersession, stale or corrupt indexes, rebuild requirements, unavailable Sessions, locked PDFs, missing handlers, partial indexing, quota and permission failures, projection violations, backend failure, and stale navigation.

Corrupt caches are quarantined or discarded.

Search falls back to authoritative scanning or rebuilding where possible.

## Lifecycle

Derived indexes remain disposable through first open, incremental updates, Save, Save As, rename, close, reopen, Recovery, external changes, corruption, upgrades, schema changes, normalization changes, backend changes, removal, eviction, and factory reset.

## Testing

Tests cover query parsing, Unicode, case folding, diacritics, graphemes, RTL, CJK, stable ranking, mappings, incremental changes, undo, redo, Save As, reload, Recovery, stale results, navigation, supersession, cancellation, corruption, eviction, large documents, PDFs, unknown Objects, missing handlers, browser quota, multiple processes, privacy, limits, and cross-platform behavior.

Property and fuzz testing cover parsers, normalization mappings, projections, caches, snippets, and incremental operations.

Direct scanning is the semantic oracle.

## Repository Ownership

Search and Indexing architecture belongs under:

`lib/search/`

This documentation commit creates no implementation subdivisions.

## Deferred Matters

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
- Persistent backend selection
- Final Search UI
