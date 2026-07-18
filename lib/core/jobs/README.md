# Performance, Concurrency, and Background Work

Status: **Accepted with modifications**

## Central Rule

A portable typed Job System coordinates substantial asynchronous work, resource admission, cancellation, fairness, and freshness.

It schedules work but never replaces subsystem ownership or authorizes result publication.

## Ownership

The Job System owns:

- Portable Job metadata and lifecycle
- Scheduling and admission
- Priority and fairness
- CPU-worker and I/O-concurrency limits
- Cancellation propagation
- Deadlines and expiration
- Structured scopes
- Backpressure
- Typed supersession and coalescing
- Resource reservations
- Memory-pressure coordination
- Progress transport and throttling
- Lifecycle-aware execution
- Performance diagnostics
- Scheduler testing contracts

Existing subsystems retain ownership of workload inputs and outputs, domain correctness, Commands, publication, rendering, Save, Recovery, Import, Export, Search, PDF, plugins, Settings, caches, freshness validation, acceptance, Security classification, and Session or view meaning.

The Job System determines when and where work runs.

It does not determine what a result means or whether it may be published.

## Appropriate Job Usage

Not every `Future`, asynchronous call, or bounded calculation becomes a Job.

Use Jobs when work needs:

- Scheduling priority
- Resource admission
- Worker execution
- Cancellation propagation
- Progress
- Supersession
- Backpressure
- Lifecycle coordination
- Cross-Session fairness
- Freshness validation
- Retry policy

Small bounded operations remain ordinary typed subsystem calls.

Job kinds are centrally registered with permitted scheduling classes, resource categories, and publication behavior.

Subsystems cannot create arbitrary unregistered high-priority Jobs.

## Execution Model

Supported execution mechanisms are:

1. UI-isolate and Flutter-frame coordination
2. Cooperative asynchronous I/O
3. Short-lived native worker isolates
4. Bounded long-lived native worker pools
5. Web Workers behind platform adapters
6. Cooperative event-loop chunking

Asynchrony, concurrency, parallelism, process-lifetime background work, and persistence after termination remain distinct.

Version 1 does not guarantee work after process termination, mobile process death, browser refresh, tab closure, forced termination, or operating-system shutdown.

Native library threads remain behind typed adapters.

Native subprocess execution remains deferred.

## UI and Frame Ownership

Flutter retains UI-isolate, frame, input, widget, painting, and platform-event-loop ownership.

The Job System may admit, prioritize, schedule, offload, throttle, and cancel work.

Requirements include:

- No unbounded UI-isolate work
- No large synchronous decoding, parsing, archiving, indexing, or layout on input paths
- Bounded work per callback
- Incremental, offloaded, or chunked large operations
- Bounded queues
- Viewport-first scheduling
- Cancellable prefetch
- Identity-compatible immutable-result reuse

## Job Requests

An immutable Job Request envelope contains:

- Job identity
- Registered typed Job kind
- Owning subsystem
- Application, Session, view, operation, or parent scope
- Typed payload-contract identity
- Snapshot and revision identities
- Scheduling class
- Resource estimate
- Required platform capabilities
- Security-policy snapshot or required subset
- Deadline or expiration
- Typed supersession key where permitted
- Progress policy
- Result-publication contract
- Retry classification
- Idempotency classification

Subsystems define their own typed payloads.

One universal untyped payload that bypasses domain validation is prohibited.

## Job Results

Keep these dimensions separate:

- Outcome: completed, cancelled, superseded, failed
- Completeness: complete or partial
- Degradation: normal or degraded
- Freshness: current, stale, or requiring validation
- Publication: unpublished, accepted, rejected, or owner-published

Results include request and input identities, output identity, freshness evidence, resource use, omitted work, warnings, retry classification, and temporary-resource disposition.

Completion does not prove freshness, authorization, acceptance, or publication.

## Structured Concurrency

Every Job belongs to an explicit scope:

- Application
- Session
- View
- User operation
- Parent Job

Parent cancellation propagates to children.

Parents normally join required children.

Required-child failures follow typed parent policy.

Optional-child failures may cause degradation.

Timeouts cancel unfinished work.

Reservations belong to scopes and release exactly once.

Session, view, and application closure cancel their scoped work.

Detached work is rare, application-owned, independently cancellable, bounded, and unable to retain Sessions, views, secrets, snapshots, handles, or temporary files indefinitely.

## Scheduling Classes

Centrally controlled scheduling classes are:

1. Input-critical
2. Frame-critical
3. User-blocking
4. Persistence-critical
5. User-visible
6. Background maintenance
7. Opportunistic

Classes express intent, not hard real-time execution, preemption, fixed latency, dedicated cores, or immunity from operating-system scheduling.

Each registered Job kind has permitted classes.

Subsystems cannot invent priorities or arbitrarily promote work.

## Fairness

Fair scheduling requires:

- Global worker limits
- Per-Session queue shares
- Per-Session concurrency caps
- Round-robin fairness where appropriate
- FIFO among equivalent work
- Aging or reserved service for lower classes
- Reserved bounded persistence capacity
- Lower but nonzero service for inactive Sessions

No Session may monopolize all workers indefinitely.

Input and frame work should not be newly queued behind maintenance work.

Already-running non-preemptible operations may delay higher classes; this risk must be measured and minimized.

Persistence remains serialized and cannot bypass validation.

## Stylus and Input Work

Drawing Tools and Interaction Mapping retain ownership.

Job scheduling provides reserved input capacity, bounded batching, semantics-preserving coalescing, lightweight previews, frame-aligned delivery, separate preview and Command preparation, gesture cancellation, and bounded stroke buffers.

Required stylus samples cannot be silently discarded.

Prediction remains disposable presentation data and cannot become authoritative stroke content outside accepted Drawing and Command boundaries.

## Rendering and Viewports

Typical classifications include active stroke overlays as input-critical, visible overlays as frame-critical, visible rendering as frame-critical or user-visible, visible PDFs as user-visible, current Text layout as frame-critical where needed, adjacent prefetch as opportunistic, and thumbnails or cache rebuilding as maintenance.

Render requests carry complete Session, view, content, revision, viewport, zoom, pixel ratio, Settings, registry, Security, and request identities.

Rendering owners reject stale results.

View closure cancels exclusive work.

Shared computation requires an identity-complete key and live consumers.

Each consumer validates freshness independently.

## Native Isolates

On Dart Native, `Isolate.run` may support substantial one-shot CPU work.

Long-lived isolates require benchmarks.

Isolates communicate through messages and do not share mutable Session or UI state.

Worker counts remain bounded.

`Isolate.run` is an execution primitive, not the Job System. It does not provide the full priority, cancellation, admission, progress, fairness, freshness, and retry model.

Cancellation is cooperative or uses controlled worker termination.

Worker termination alone does not prove native resources were safely cancelled.

## Flutter `compute`

Flutter `compute` may be used selectively for compatible one-shot work.

It is not the architectural scheduler.

Native implementations may use isolates.

On Web it runs on the current event loop and does not provide parallel execution.

Shared APIs do not imply equal performance or isolation.

## Web Workers and Chunking

Web Workers require separately compiled entry points, typed messages, platform adaptation, CSP-compatible loading, bounded startup and transfers, error handling, capability detection, and deployment verification.

Web Workers are not identical to Dart isolates.

Cooperative chunking is the universal fallback.

Hidden tabs may be throttled.

Refresh and tab closure terminate process-lifetime work.

## Transferable Data

`TransferableTypedData` may optimize large native transfers after benchmarking.

It is single-use, has construction and materialization costs, is not universally available through one Web contract, is not a Security boundary, and does not prove that other copies do not exist.

Workers receive only validated, authorized, bounded inputs.

## Worker Pools

Long-lived pools require measured benefit over one-shot workers.

Pools are bounded, capability-derived, budgeted, monitored, restartable, isolated from mutable Sessions, drained during shutdown, and tested for leaks.

One unbounded isolate per queued Job is prohibited.

Native-library concurrency and cancellation must be reported through adapters and included in admission.

## Worker Inputs

Workers may receive immutable typed data, required policy subsets, staged byte resources, narrow operation-scoped capabilities, and explicit result contracts.

Workers cannot receive mutable Sessions, UI objects, unrestricted platform services, general secret-store handles, broad filesystem authority, persistent authorization tokens, or executable plugin code.

Capabilities remain scoped, expiring, and validated.

## Preparation and Publication

Preparation and publication remain separate:

1. Capture immutable inputs and policy.
2. Reserve bounded resources.
3. Produce or validate staged output.
4. Revalidate destination, revision, authorization, cancellation, and policy.
5. Enter the owner’s publication queue.
6. Publish through the owner’s atomicity contract.
7. Return structured results.
8. Release temporary resources.

Document publication remains serialized per Session.

Destination-level coordination applies where needed.

No global atomicity is claimed across files, processes, tabs, stores, or external destinations.

Final acceptance belongs to the owning subsystem.

## Lifecycle

Recognized states include foreground, background, hidden, suspended, memory pressure, closing, and safe mode.

Behavior includes stopping prefetch, reducing workers, prioritizing bounded Recovery opportunities, assuming immediate suspension, stopping nonessential admission while closing, applying safe-mode restrictions, and attempting only bounded graceful finalization.

Graceful shutdown is best effort.

Completed Recovery data—not final callbacks—protects forced-termination work.

## Background Work Classes

Work is classified as:

- Foreground-required
- Process-lifetime background
- Best-effort platform background
- Deferred until next launch
- Future persistent operating-system work

Version 1 does not require foreground services, persistent Android Jobs, long-lived Web background execution, or work surviving process termination.

Process-lifetime work may include Search indexing, thumbnails, cache maintenance, cleanup, and other rebuildable tasks.

## Restart Checkpoints

Restartable work may persist bounded declarative data:

- Work kind and schema
- Input or source identity
- Progress checkpoint
- Staged-resource identity
- Idempotency
- Need for reauthorization
- Policy compatibility identity

Never persist closures, arbitrary Job objects, worker memory, secrets, live handles, stale tokens, or mutable Session references.

Checkpoints remain untrusted and are validated when loaded.

## Cancellation

Cancellation may result from parent or user cancellation, Session or view closure, supersession, timeout, policy or registry change, memory pressure, lifecycle change, or shutdown.

Cancellation is observed at bounded semantic boundaries such as chunks, PDF Pages, render tiles, Search batches, projections, Import entries, expensive allocations, publication, and delivery.

Cancellation produces a cancellation result, stops child creation, cleans temporary resources, avoids partial publication, leaves caches valid or absent, and never becomes success.

Non-cancellable publication boundaries finish according to owner contracts.

Uninterruptible native outputs are ignored after cancellation and release resources when they return.

## Supersession and Coalescing

Typed supersession may apply to Search queries, viewport rendering, thumbnails, prefetch, Settings previews, index projections, Autosave triggers, and Recovery triggers.

Coalescing retains the newest required revision, earliest deadline, durability information, and every non-droppable committed transition.

Commands, final Save or Export publication, required Recovery, required audit records, and destructive publication cleanup cannot be casually superseded.

Shared work continues while valid consumers remain.

## Backpressure

Every producer-consumer boundary defines a bounded queue, admission rule, overload behavior, cancellation, and diagnostics.

Overload responses may batch, coalesce, drop obsolete derived work, lower transient quality, pause, split, defer, reject, or return structured overload.

Committed transitions, required Recovery, required publication results, and Security-required audit events are never silently dropped.

If required audit admission fails, the protected operation fails closed.

## Resource Admission

Admission consumes immutable Security-policy snapshots.

Reservations identify owner, scope, category, estimate, actual use where possible, expiration, and release state.

Budgets cover CPU, workers, I/O, memory, decoded images, PDF surfaces, temporary storage, Search, staging, Recovery, caches, and clipboard staging.

Admission may accept, queue, lower quality, split, defer, or reject.

Overcommit is explicit and bounded and is prohibited where Security forbids it.

Reservations release exactly once.

## Memory Pressure

Deterministic degradation proceeds by stopping prefetch, rejecting opportunistic work, cancelling queued opportunistic work, evicting caches, releasing inactive resources, lowering render quality, pausing Search and thumbnails, reducing workers, cancelling background work, preserving active input, preserving authoritative state, preserving required Recovery, and reporting inability to continue safely.

Authoritative content and required unsaved state are never silently discarded.

## Progress

Progress is structured, presentation-neutral, typed, throttled, coalesced, bounded, and redacted.

It may contain Job and phase identities, totals, completed units, weighted phases, completeness, degradation, cancellation availability, and aggregate child progress.

It excludes titles, paths, Search text, snippets, secrets, and sensitive names.

## Freshness

Results carry every required Job, Session, view, content, Command, source, Page, Object, viewport, registry, Settings, Security, and destination identity.

The receiving owner validates immediately before display, cache insertion, Command proposal, publication, or reuse.

Worker completion is never freshness proof.

Stale results become structured stale or superseded outcomes and are not blindly retried.

## Multiple Sessions and Views

Global limits, per-Session shares and caps, active weighting, nonzero inactive service, and independent publication queues are required.

Focus changes affect scheduling weight, not correctness.

Views share immutable results only when all required identities match.

## Multiple Processes and Tabs

Version 1 uses optimistic revisions, short leases where supported, process- or tab-specific caches, safe read-only sharing, rebuildable data, conflict reporting, and capability reporting.

Cross-process document locking remains deferred.

Global cache consistency, atomicity, single-writer behavior, and shared worker ownership are not claimed.

## Failure and Retry

Structured failures include cancellation, supersession, timeout, unavailable capability, resource denial, memory pressure, worker failure, invalid input, stale result, publication conflict, I/O failure, partial result, and platform termination.

Retry requires explicit retryability, idempotency, fresh authorization and policy, bounded attempts and backoff, cancellation awareness, and no superseding request.

Invalid input, Security denial, non-idempotent publication, permanent failures, and superseded stale work are not retried.

Retry storms are prevented.

## Diagnostics

Local redacted measurements may include duration, queue delay, utilization, frame misses, cancellation latency, cache hits, memory estimates, queue depth, counts, overload, retries, and degradation.

Diagnostics exclude content, titles, paths, queries, snippets, persistent document identities, secrets, and raw plugin data.

Version 1 has no telemetry or automatic upload.

## Testing and Benchmarking

Tests use fake schedulers and clocks, deterministic priority and fairness tests, cancellation, races, supersession, coalescing, worker failure, fault injection, memory pressure, lifecycle simulation, Session fairness, view sharing, tab coordination, publication serialization, reservation properties, backpressure stress, and leak detection.

Benchmarks cover stylus latency, frame timing, workers, transfers, images, PDFs, documents, Search, Save, Recovery, Import, Export, Sessions, and Web chunking.

Correctness tests do not depend only on timing sleeps.

Targets are measured per platform before release.

## Repository Ownership

Portable Job System architecture belongs under:

`lib/core/jobs/`

Concrete executors remain platform adapters.

This documentation commit creates no implementation subdivisions.

## Dependency Status

No external scheduler, worker-pool, cancellation, admission, or background-work dependency is accepted.

Accepted foundations include Dart `Future`, `Stream`, async/await, isolate APIs, Flutter frame APIs, and platform Web Worker facilities through adapters.

`package:async`, `package:pool`, and Android WorkManager remain studies.

Flutter `compute`, Kotlin structured concurrency, Rnote, and Xournal++ are references.

`TransferableTypedData` is a benchmark-gated SDK optimization.

## Deferred Matters

- Worker counts, queue sizes, memory budgets, and performance targets
- Persistent Android Jobs and foreground services
- Native subprocess workers
- Cross-process locking and cache coherence
- Shared cross-tab workers
- Desktop process isolation
- Advanced GPU scheduling
- Recognition, Sync, Cloud, and executable-plugin workloads
- Final deployment configuration
- External scheduler selection
