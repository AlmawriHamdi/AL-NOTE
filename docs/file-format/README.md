# AL NOTE File Format Version 1

## Identity and scope

The provisional version-1 media type is
`application/vnd.al-note+zip`. It is an internal format identifier and is not a
claim of IANA registration. One `.alnote` package represents a Notebook,
Standalone Page, or Standalone PDF document. Package, document-root, Layer,
Object-envelope, Object-payload, and resource-role schema versions are
independent positive integers; application SemVer is never substituted for a
schema version.

Version 1 is neither encrypted nor signed. SHA-256 and ZIP CRC prove exact-byte
integrity and corruption evidence only. They do not prove authorship,
authenticity, authorization, or trust.

## Canonical ZIP container

Entries are emitted in this exact order:

```text
mimetype
manifest.json
document.json
sections/<section-uuid>.json       (lowercase UUID order)
pages/<page-uuid>.json             (lowercase UUID order)
resources/<first-two-hash-hex>/<full-sha256>  (path order)
extensions/<namespace>/...         (path order)
```

There are no directory entries. Every entry uses ZIP stored/no-compression
mode, DOS time `1980-01-01 00:00:00`, and fixed regular-file mode `0100644`.
The archive and entries have no comments, encryption, passwords, symlink or
special-file metadata, or nondeterministic extra data. `mimetype` is the exact
ASCII media type with no BOM, newline, or terminator. Identical snapshots
therefore produce byte-identical packages.

Version 1 is ZIP32 only. Writers reject any entry count, entry size, offset,
central directory, or complete package not representable by ZIP32. Readers
preflight central and local headers before decompression and accept only stored
or deflate entries. ZIP64, multi-disk, encryption, unsupported compression,
data descriptors, comments, extra fields, ambiguous headers, symlinks, devices,
directories, and special entries reject. Central and local names, flags,
methods, CRCs, compressed sizes, and decoded sizes must match exactly. Every
local-header/data range is unique, non-overlapping, and wholly before the
central directory.

## Path grammar

Entry names are relative lowercase ASCII with `/`. Backslashes, absolute and
drive paths, empty, `.` or `..` segments, repeated separators, control/NUL
characters, non-ASCII names, uppercase aliases, duplicates, case-fold
collisions, reserved-name collisions, excessive length/segments, and names
outside the version-1 structure reject. Archive names are never converted to
platform paths. ZIP format version 1 has a representability invariant of at
most 16 path segments, counted as `/`-separated components. Every operation
also requires the caller-supplied count ceiling
`alnote.storage.entry_path_segments`; the effective ceiling is the tighter of
that policy and the format invariant. The value 16 is not a production policy
default. Windows device basenames (`con`, `prn`, `aux`, `nul`,
`com1` through `com9`, and `lpt1` through `lpt9`) are reserved on every
platform. Page and Section path components are canonical non-nil/non-max UUIDs,
not merely UUID-shaped text.

Unknown safe entries are allowed only under
`extensions/<lowercase-namespace>/...`. They remain inert bytes: AL NOTE does
not execute, import, extract, or interpret them.
Feature and namespace identifiers use the bounded grammar
`[a-z][a-z0-9_-]{0,63}`. Namespace declarations must be sorted, unique, and
exactly match the namespaces used by extension paths.

## Canonical JSON

Structured records use strict UTF-8 without BOM or malformed-character
replacement. The AL NOTE parser applies explicit byte, depth, value, and string
ceilings; detects duplicate keys; validates escapes and surrogate pairs;
rejects trailing data, invalid record types, non-finite values, unsafe integers,
and malformed number forms. Integer and double forms remain distinct.

Canonical output sorts every object key by Dart string ordering, preserves
array order, emits Web-safe integers and finite doubles, uses SDK JSON escaping,
and contains no whitespace or BOM. Unknown JSON is preserved structurally and
re-encoded canonically; original lexical spelling is not preserved.

## Manifest

`manifest.json` records package version, document-root schema version, document
form and UUID, `document.json` entry point, required and optional features,
structured-entry and logical-resource catalogs, media types, decoded byte
sizes, SHA-256 values, resource roles and schema versions, extension
namespaces, and structurally preserved unknown fields. It catalogs every
authoritative entry except itself. Catalog lists are unique and deterministic.
Unknown required features reject. Unknown optional features and declared safe
extension data remain preserved and inert.
Unknown fields within every structured-entry and logical-resource catalog item
are also preserved as inert structured data. They cannot alter decoding,
selection, paths, limits, or behavior. On canonical re-encoding, validated
known catalog fields always override conflicting preservation input.
The `mimetype` catalog record is independently checked for its exact media
type, schema version, decoded length, and SHA-256 digest. Known structured
records require `application/json` and schema version 1. Opaque extension
records preserve their exact validated media type and positive schema version
with their bytes.

## Structured records

`document.json` stores root metadata and authoritative ordered references. A
Notebook references ordered Section UUIDs; a Standalone Page references one
Page UUID; a Standalone PDF references ordered Page UUIDs and one logical source
resource UUID. Each Section record stores its UUID, name, schema version,
ordered Page UUIDs, and preserved fields.

Each Page record stores UUID, name, positive finite dimensions, ordered Layers,
and preserved fields. A Layer envelope stores UUID, permanent type, envelope
and type schema versions, name, closed core role, visibility, locking, opacity,
ordered Objects, type data, and preserved fields. An Object envelope stores
UUID, permanent type, envelope and payload schema versions, visibility,
locking, payload, preserved fields, and affine transform.

Affine coefficients are stored exactly in `[m00,m01,m10,m11,tx,ty]` order.
Restoration uses the existing finite, positive-determinant, non-reflection,
representable-inverse, and conditioning validation. Reflected, singular,
non-finite, or ill-conditioned values reject; accepted values round-trip by
exact equality.

Application SemVer, runtime revisions, content identities, Commands, Undo/Redo,
save-capture identities, Selection, transform previews, viewport and Session
state, UI state, caches, thumbnails, and indexes are excluded.

## Resources and extensions

Each logical resource record contains a canonical document-scoped UUID, exact
32-byte SHA-256 digest, decoded length, media type, namespaced role, positive
role schema version, digest-derived package path, and immutable bytes. Multiple
logical UUIDs may share one digest/path. Size, hash, path/hash, presence,
identity uniqueness, metadata consistency, byte consistency, and required
references are independently validated. Version 1 embeds all resources and has
no external resource links. Unknown reachability retains every manifest
resource; version 1 performs no resource garbage collection.

## Limits and hostile input

Every operation requires a caller-supplied immutable resource-limit snapshot;
the format supplies no numeric production defaults. Stable keys cover package,
entry, path-segment, compressed/decoded/total bytes, ratio, JSON, document
counts, unknown entries, migration steps, and migration expansion. Missing keys and unit
mismatches fail closed. Counts, sums, ratios, and expansions use checked
Web-safe arithmetic. Validation occurs before allocation/decompression where
possible and again while consuming. Failures disclose only a stable policy
dimension, never names, titles, payloads, bytes, rejected strings, archive
messages, exception text, or secrets.
All public byte inputs validate each integer as an octet. Iterable readers copy
incrementally and stop as soon as the package ceiling is exceeded; source and
iteration exceptions are contained behind fixed failures.
The ZIP local area is fully owned: the first local header starts at byte zero,
all local header/data ranges are contiguous after offset ordering, and the last
range ends exactly at the central directory. Prefixes, gaps, padding, and
hidden local-area trailers reject rather than disappearing on Save.

## Loading, preservation, and compatibility

Loading bounds and preflights the ZIP, validates paths/types, reads and verifies
`mimetype`, manifest, root, and Section records, then publishes immutable Page
and resource handles. Page JSON and resource bytes are not interpreted or
returned until their handle is invoked. Each lazy load repeats exact size,
CRC/SHA, and schema validation. Complete materialization builds one candidate
DocumentRoot and validates it with the Object Registry and DocumentValidator;
failure or cancellation publishes no partial root.
Root and Section schemas, identities, and references are validated before an
opened package is published. Section and lazy Page record identities must equal
their path identities. Notebook references must own every cataloged Section and
Page; standalone forms reject ignored Section or Page records.

Unknown fields, Object types, unsupported Object schemas, unknown Layers,
optional features, safe extension entries, resources, and manifest data remain
preserved and inert. Decoding invokes no rendering, hit testing, Commands,
platform services, plugins, storage paths, or future behavior.

## Migration

Migration registries are nonglobal and contain trusted AL NOTE-owned exact
adjacent transitions for package/document records and known Object payloads.
Planning is deterministic and rejects reverse paths, gaps, duplicates, cycles,
and ambiguity. Handlers receive immutable preserved data and perform no I/O or
package-provided execution. Step and expansion limits apply. Handler failures
and exceptions become fixed redaction-safe failures. Original package bytes
remain untouched; migrated bytes exist only after a later explicit successful
save of a completely validated candidate.
Each completed candidate is bound exactly to both the handler-produced record
and the plan's declared scope and transition. Object-payload planning uses
`ObjectTypeKey` values throughout rather than raw type strings. Package plans
may change only their declared package record/version and leave the complete
DocumentRoot exact. Document-root plans may change only the handler-produced
root record/schema while Section membership and all Section, Page, Layer, and
Object records remain exact. Object-payload plans may change only the declared
target Object's payload and payload schema: its identity, type, envelope
version, transform, visibility, locking, extension data, containment, and
ordering remain exact, as do every ancestor and non-target Object. Resources
and all package preservation state, including unknown nested catalog fields,
remain exact for every scope.

## Complete replacement Save

Save captures one immutable snapshot, validates the document/resources,
encodes a complete package, writes only isolated staging, explicitly flushes
when supported, reads and completely validates staged output, rechecks the
expected external fingerprint, and commits replacement only after every prior
step succeeds. The final staging commit receives that expected fingerprint and
the destination adapter atomically compares it as part of replacement; the
earlier check is only a precheck. Failure or cancellation aborts staging. The previous valid
generation remains until commit. Atomicity and durability are reported only
from explicit destination evidence; write or close alone never proves
durability. Reduced-capability destinations report reduced durability honestly.
Blind overwrite after a fingerprint mismatch is forbidden. Save As retains all
document and internal UUIDs; independent duplication is a separate operation.
Every destination boundary is exception-contained and adapter failures are
replaced with coordinator-owned diagnostics. A supported flush must report
`flushed == true`. Cleanup is best effort; the primary failure deterministically
takes precedence over cleanup failure.

## Explicit exclusions

Version 1 has no signatures, encryption, credentials, recovery records,
history, recovery journal, autosave, external links, ZIP64, executable plugin
content, runtime networking, formal salvage, destructive repair, Search data,
rendering caches, or UI/session state.
