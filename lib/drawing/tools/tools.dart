// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/geometry/transform_operations.dart';
import '../../core/identity/namespaced_identifier.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../core/versioning/schema_version.dart';
import '../../documents/commands.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../viewport.dart';

/// Stable namespaced drawing-tool identity.
final class ToolId implements Comparable<ToolId> {
  /// Creates from a validated identifier.
  const ToolId.fromIdentifier(this.identifier);

  /// Parses an identifier.
  static Result<ToolId, StructuredFailure> parse(String source) =>
      NamespacedIdentifier.parse(source).map(ToolId.fromIdentifier);

  /// Wrapped identifier.
  final NamespacedIdentifier identifier;

  /// Stable value.
  String get value => identifier.value;
  @override
  int compareTo(ToolId other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) =>
      other is ToolId && other.identifier == identifier;
  @override
  int get hashCode => Object.hash(ToolId, identifier);
}

/// Immutable drawing-tool definition metadata.
final class ToolDefinition {
  /// Creates a definition.
  const ToolDefinition({required this.id, required this.supportsPressure});

  /// Stable identity.
  final ToolId id;

  /// Pressure support evidence.
  final bool supportsPressure;
}

/// Immutable bounded drawing-tool registry.
final class ToolRegistry {
  ToolRegistry._(this.definitions);

  /// Safely captures unique metadata.
  static Result<ToolRegistry, StructuredFailure> create(
    Iterable<ToolDefinition> source, {
    required int maximumTools,
  }) {
    if (maximumTools < 0) return Err(_failure('invalid_limit'));
    final map = <ToolId, ToolDefinition>{};
    try {
      final iterator = source.iterator;
      while (iterator.moveNext()) {
        if (map.length >= maximumTools) return Err(_failure('tool_limit'));
        final item = iterator.current;
        if (map.containsKey(item.id)) return Err(_failure('duplicate_tool'));
        map[item.id] = ToolDefinition(
          id: item.id,
          supportsPressure: item.supportsPressure,
        );
      }
    } on Object {
      return Err(_failure('tool_metadata_unavailable'));
    }
    return Ok(ToolRegistry._(Map.unmodifiable(map)));
  }

  /// Captured definitions.
  final Map<ToolId, ToolDefinition> definitions;
}

/// Immutable active-tool revision snapshot.
final class ToolActivationSnapshot {
  /// Creates activation evidence.
  const ToolActivationSnapshot({
    required this.definition,
    required this.revision,
  });

  /// Captured definition.
  final ToolDefinition definition;

  /// Temporary activation revision.
  final Revision revision;
}

/// Validated immutable Pen preset containing resolved persistent behavior.
final class PenPreset {
  const PenPreset._(this.style);

  /// Creates a preset from an already validated persistent style.
  static PenPreset fromStyle(StrokeStyle style) => PenPreset._(style);

  /// Resolved style captured at gesture start.
  final StrokeStyle style;
}

/// Temporary immutable Pen preview; never part of a Document root.
final class PenPreview {
  /// Creates a defensively copied preview.
  PenPreview._({required Iterable<StrokeSample> samples, required this.style})
    : samples = List.unmodifiable(samples);

  /// Page-space samples.
  final List<StrokeSample> samples;

  /// Captured resolved style.
  final StrokeStyle style;
}

/// Closed terminal state for a Pen session.
enum PenSessionState { active, requestReady, cancelled, rejected }

/// One isolated Pen gesture that can only produce a Command request.
final class PenGestureSession {
  PenGestureSession._({
    required this.documentId,
    required this.pageId,
    required this.layerId,
    required this.preconditions,
    required this.viewport,
    required this.pointerId,
    required this.preset,
    required this.maximumSamples,
    required this.handwritingLimits,
    required this.uuidGenerator,
    required this.maximumCommandOperations,
  });

  /// Begins a one-primary-pointer session and captures every authoritative dependency.
  static Result<PenGestureSession, StructuredFailure> start({
    required NormalizedPointerEvent down,
    required DocumentCoordinatorSnapshot document,
    required PageId pageId,
    required LayerId layerId,
    required ViewportSnapshot viewport,
    required PenPreset preset,
    required int maximumSamples,
    required HandwritingLimits handwritingLimits,
    required UuidGenerator uuidGenerator,
    required int maximumCommandOperations,
  }) {
    if (down.phase != PointerPhase.down || maximumSamples <= 0)
      return Err(_failure('invalid_pen_start'));
    if (document.root.id != document.revisions.documentId) {
      return Err(_failure('inconsistent_pen_document'));
    }
    final pageRevision = document.revisions.pages[pageId],
        membership = document.revisions.layerMembership[layerId];
    if (pageRevision == null || membership == null)
      return Err(_failure('missing_pen_target'));
    final page = document.root.pages
        .where((value) => value.id == pageId)
        .firstOrNull;
    final layer = page?.layers
        .where((value) => value.id == layerId)
        .firstOrNull;
    if (layer is! ContentLayer || !layer.visible || layer.locked) {
      return Err(_failure('pen_target_not_editable'));
    }
    final session = PenGestureSession._(
      documentId: document.root.id,
      pageId: pageId,
      layerId: layerId,
      preconditions: RevisionPreconditions(
        pages: {pageId: pageRevision},
        layerMembership: {layerId: membership},
      ),
      viewport: viewport,
      pointerId: down.pointerId,
      preset: preset,
      maximumSamples: maximumSamples,
      handwritingLimits: handwritingLimits,
      uuidGenerator: uuidGenerator,
      maximumCommandOperations: maximumCommandOperations,
    );
    return session._append(down).map((_) => session);
  }

  /// Captured document identity.
  final DocumentId documentId;

  /// Captured Page identity.
  final PageId pageId;

  /// Captured active Layer identity.
  final LayerId layerId;

  /// Exact scoped command preconditions.
  final RevisionPreconditions preconditions;

  /// Captured conversion snapshot.
  final ViewportSnapshot viewport;

  /// Owned logical pointer.
  final int pointerId;

  /// Captured preset.
  final PenPreset preset;

  /// Sample ceiling.
  final int maximumSamples;

  /// Payload ceilings.
  final HandwritingLimits handwritingLimits;

  /// Injected deterministic UUID source.
  final UuidGenerator uuidGenerator;

  /// Command operation ceiling.
  final int maximumCommandOperations;
  final List<StrokeSample> _samples = [];
  PenSessionState _state = PenSessionState.active;
  int? _initialTime;
  int _previewSampleCopyCount = 0;

  /// Current terminal/activity state.
  PenSessionState get state => _state;

  /// Current disposable preview, absent after any terminal outcome.
  PenPreview? get preview => _state == PenSessionState.active
      ? PenPreview._(samples: _samples, style: preset.style)
      : null;

  /// Latest one- or two-sample preview segment without copying prior input.
  PenPreview? get previewTail {
    if (_state != PenSessionState.active || _samples.isEmpty) return null;
    final start = _samples.length > 1 ? _samples.length - 2 : 0;
    final values = _samples.sublist(start);
    _previewSampleCopyCount += values.length;
    return PenPreview._(samples: values, style: preset.style);
  }

  /// Accepted sample count without materializing preview evidence.
  int get sampleCount => _samples.length;

  /// Total samples copied into bounded tail-preview evidence.
  int get previewSampleCopyCount => _previewSampleCopyCount;

  /// Incrementally consumes normalized assigned input.
  Result<void, StructuredFailure> update(
    NormalizedPointerEvent event, {
    required Revision viewportRevision,
  }) {
    if (_state != PenSessionState.active ||
        event.pointerId != pointerId ||
        viewportRevision != viewport.revision) {
      cancel();
      return Err(_failure('stale_pen_session'));
    }
    if (event.phase == PointerPhase.cancel) {
      cancel();
      return const Ok(null);
    }
    if (event.phase != PointerPhase.move && event.phase != PointerPhase.up)
      return Err(_failure('invalid_pen_phase'));
    final result = _append(event);
    if (result is Err<void, StructuredFailure>) {
      cancel();
      return result;
    }
    return const Ok(null);
  }

  Result<void, StructuredFailure> _append(NormalizedPointerEvent event) {
    final page = viewport
        .viewToPage(event.viewPosition)
        .fold<Point2?>(onOk: (v) => v, onErr: (_) => null);
    _initialTime ??= event.timeMicros;
    final relative = event.timeMicros - _initialTime!;
    if (page == null || relative < 0)
      return Err(_failure('invalid_pen_sample'));
    final sample = StrokeSample.create(
      position: page,
      timeMicros: relative,
      limits: handwritingLimits,
      pressure: event.pressure,
      tilt: event.tilt,
      orientation: event.orientation,
    );
    if (sample is Err<StrokeSample, StructuredFailure>)
      return Err(_failure('invalid_pen_sample'));
    final accepted = (sample as Ok<StrokeSample, StructuredFailure>).value;
    final previous = _samples.lastOrNull;
    if (previous != null && previous.position == accepted.position) {
      return const Ok(null);
    }
    if (_samples.length >= maximumSamples) return Err(_failure('sample_limit'));
    _samples.add(accepted);
    return const Ok(null);
  }

  /// Finalizes a valid Up event into one atomic insertion request.
  Result<AtomicObjectCollectionEditRequest, StructuredFailure> finish(
    NormalizedPointerEvent up, {
    required DocumentCoordinatorSnapshot latestDocument,
    required Revision viewportRevision,
    required int? pointerOwnerAtTerminal,
  }) {
    if (up.phase != PointerPhase.up)
      return Err(_failure('invalid_pen_terminal'));
    final updateResult = update(up, viewportRevision: viewportRevision);
    if (updateResult is Err<void, StructuredFailure>) {
      _state = PenSessionState.rejected;
      return Err(updateResult.error);
    }
    final latestPage = latestDocument.root.pages
        .where((value) => value.id == pageId)
        .firstOrNull;
    final latestLayer = latestPage?.layers
        .where((value) => value.id == layerId)
        .firstOrNull;
    if (latestDocument.root.id != documentId ||
        latestDocument.root.id != latestDocument.revisions.documentId ||
        latestDocument.revisions.pages[pageId] != preconditions.pages[pageId] ||
        latestDocument.revisions.layerMembership[layerId] !=
            preconditions.layerMembership[layerId] ||
        latestLayer is! ContentLayer ||
        !latestLayer.visible ||
        latestLayer.locked ||
        pointerOwnerAtTerminal != pointerId ||
        viewportRevision != viewport.revision) {
      _state = PenSessionState.rejected;
      _samples.clear();
      return Err(_failure('stale_pen_session'));
    }
    final occupied = <String>{latestDocument.root.id.uuid.value};
    if (latestDocument.root is NotebookDocument) {
      occupied.addAll(
        (latestDocument.root as NotebookDocument).sections.map(
          (value) => value.id.uuid.value,
        ),
      );
    }
    for (final page in latestDocument.root.pages) {
      occupied.add(page.id.uuid.value);
      for (final layer in page.layers) {
        occupied.add(layer.id.uuid.value);
        for (final object in layer.objects) {
          occupied.add(object.id.uuid.value);
          if (object.typeKey == handwritingObjectTypeKey &&
              object.typeSchemaVersion == handwritingSchemaVersion) {
            final payload =
                HandwritingPayload.decode(
                  object.payload,
                  limits: handwritingLimits,
                ).fold<HandwritingPayload?>(
                  onOk: (value) => value,
                  onErr: (_) => null,
                );
            if (payload == null) {
              _state = PenSessionState.rejected;
              return Err(_failure('invalid_pen_document'));
            }
            occupied.addAll(
              payload.strokes.map((value) => value.id.uuid.value),
            );
          }
        }
      }
    }
    final generated = <String>{};
    final objectUuid = _generateUnique(generated),
        strokeUuid = _generateUnique(generated),
        correlationUuid = _generateUnique(generated);
    if (objectUuid == null || strokeUuid == null || correlationUuid == null) {
      _state = PenSessionState.rejected;
      return Err(_failure('uuid_generation_or_collision'));
    }
    if ([
      objectUuid,
      strokeUuid,
      correlationUuid,
    ].any((value) => !occupied.add(value.value))) {
      _state = PenSessionState.rejected;
      return Err(_failure('uuid_generation_or_collision'));
    }
    final objectId = ObjectId.fromUuid(objectUuid);
    if (latestDocument.root.pages
        .expand((p) => p.layers)
        .expand((l) => l.objects)
        .any((o) => o.id == objectId)) {
      _state = PenSessionState.rejected;
      return Err(_failure('uuid_collision'));
    }
    final stroke = HandwritingStroke.create(
      id: StrokeId.fromUuid(strokeUuid),
      samples: _samples,
      style: preset.style,
      limits: handwritingLimits,
    );
    if (stroke is Err<HandwritingStroke, StructuredFailure>) {
      _state = PenSessionState.rejected;
      return Err(stroke.error);
    }
    final payload = HandwritingPayload.create(
      strokes: [(stroke as Ok<HandwritingStroke, StructuredFailure>).value],
      limits: handwritingLimits,
    );
    if (payload is Err<HandwritingPayload, StructuredFailure>) {
      _state = PenSessionState.rejected;
      return Err(payload.error);
    }
    final identity = AffineTransform2D.fromOperation(
      const IdentityTransformOperation2D(),
    ).fold<AffineTransform2D?>(onOk: (v) => v, onErr: (_) => null);
    final envelopeVersion = SchemaVersion.create(
      1,
    ).fold<SchemaVersion?>(onOk: (v) => v, onErr: (_) => null);
    if (identity == null || envelopeVersion == null) {
      _state = PenSessionState.rejected;
      return Err(_failure('internal_contract'));
    }
    final envelope = ObjectEnvelope.create(
      id: objectId,
      typeKey: handwritingObjectTypeKey,
      envelopeVersion: envelopeVersion,
      typeSchemaVersion: handwritingSchemaVersion,
      transform: identity,
      visible: true,
      locked: false,
      payload: (payload as Ok<HandwritingPayload, StructuredFailure>).value
          .encode(),
      extensionData: PreservedMap.empty(),
    );
    if (envelope is Err<ObjectEnvelope, StructuredFailure>) {
      _state = PenSessionState.rejected;
      return Err(envelope.error);
    }
    final request = AtomicObjectCollectionEditRequest.create(
      documentId: documentId,
      pageId: pageId,
      metadata: CommandMetadata(
        family: CommandFamily.objectCollectionEdit,
        correlationId: CommandCorrelationId.fromUuid(correlationUuid),
        description: 'Draw stroke',
      ),
      preconditions: preconditions,
      additions: [
        ObjectCollectionAddition(
          layerId: layerId,
          object: (envelope as Ok<ObjectEnvelope, StructuredFailure>).value,
        ),
      ],
      maximumOperations: maximumCommandOperations,
    );
    _state = request is Ok
        ? PenSessionState.requestReady
        : PenSessionState.rejected;
    _samples.clear();
    return request;
  }

  /// Cancels idempotently and discards preview state.
  void cancel() {
    if (_state == PenSessionState.active) _state = PenSessionState.cancelled;
    _samples.clear();
  }

  UuidIdentifier? _generateUnique(Set<String> generated) {
    try {
      final result = uuidGenerator.generateV4();
      if (result is! Ok<UuidIdentifier, StructuredFailure>) return null;
      final uuid = result.value;
      if (!generated.add(uuid.value)) return null;
      return uuid;
    } on Object {
      return null;
    }
  }
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.tools.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Drawing tool input is invalid.',
);
