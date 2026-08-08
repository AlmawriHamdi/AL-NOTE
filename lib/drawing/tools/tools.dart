// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

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
import '../geometry.dart';
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

/// Result of deterministic visible-geometry erasing.
final class StrokeSplitResult {
  StrokeSplitResult._({
    required List<HandwritingStroke> strokes,
    required this.intersectionCount,
    required this.outputSampleCount,
    required this.affected,
  }) : strokes = List.unmodifiable(strokes);

  /// Largest caller-supplied split-result collection accepted at this boundary.
  static const int maximumSupportedStrokes = 1000000;

  /// Safely captures immutable split evidence under an explicit Stroke cap.
  static Result<StrokeSplitResult, StructuredFailure> create({
    required Iterable<HandwritingStroke> strokes,
    required int maximumStrokes,
    int intersectionCount = 0,
    int outputSampleCount = 0,
    bool affected = false,
  }) {
    if (maximumStrokes <= 0 ||
        maximumStrokes > maximumSupportedStrokes ||
        maximumStrokes > Revision.maximumValue) {
      return Err(_failure('invalid_split_limit'));
    }
    if (intersectionCount < 0 ||
        intersectionCount > Revision.maximumValue ||
        outputSampleCount < 0 ||
        outputSampleCount > Revision.maximumValue ||
        (!affected && (intersectionCount != 0 || outputSampleCount != 0))) {
      return Err(_failure('invalid_split_evidence'));
    }
    final captured = <HandwritingStroke>[];
    try {
      final iterator = strokes.iterator;
      while (true) {
        final more = iterator.moveNext();
        if (!more) break;
        if (captured.length >= maximumStrokes) {
          return Err(_failure('split_limit'));
        }
        captured.add(iterator.current);
      }
    } on Object {
      return Err(_failure('split_unavailable'));
    }
    if ((!affected && captured.length != 1) ||
        (affected && !_coherentAffectedSplit(captured, outputSampleCount))) {
      return Err(_failure('invalid_split_result'));
    }
    return Ok(
      StrokeSplitResult._(
        strokes: captured,
        intersectionCount: intersectionCount,
        outputSampleCount: outputSampleCount,
        affected: affected,
      ),
    );
  }

  /// Ordered survivors.
  final List<HandwritingStroke> strokes;

  /// Entry/exit boundaries produced by classification.
  final int intersectionCount;

  /// Samples retained or synthesized across affected output fragments.
  final int outputSampleCount;

  /// Whether visible geometry was erased.
  final bool affected;
}

bool _coherentAffectedSplit(
  List<HandwritingStroke> strokes,
  int outputSampleCount,
) {
  var actualSamples = 0;
  for (final stroke in strokes) {
    if (actualSamples > Revision.maximumValue - stroke.samples.length) {
      return false;
    }
    actualSamples += stroke.samples.length;
  }
  return actualSamples == outputSampleCount;
}

Result<Set<StrokeId>, StructuredFailure> _captureExistingStrokeIds(
  Iterable<StrokeId> source,
  int maximum,
) {
  if (maximum <= 0 ||
      maximum > StrokeSplitResult.maximumSupportedStrokes ||
      maximum > Revision.maximumValue) {
    return Err(_failure('invalid_existing_id_limit'));
  }
  final values = <StrokeId>{};
  try {
    final iterator = source.iterator;
    while (true) {
      final more = iterator.moveNext();
      if (!more) break;
      if (values.length >= maximum) {
        return Err(_failure('existing_id_limit'));
      }
      if (!values.add(iterator.current)) {
        return Err(_failure('duplicate_existing_id'));
      }
    }
  } on Object {
    return Err(_failure('existing_ids_unavailable'));
  }
  return Ok(Set.unmodifiable(values));
}

List<StrokeErasureInterval> _mergeStrokeIntervals(
  List<StrokeErasureInterval> first,
  List<StrokeErasureInterval> second,
) {
  final values = <StrokeErasureInterval>[...first, ...second]
    ..sort((left, right) => left.start.compareTo(right.start));
  final merged = <StrokeErasureInterval>[];
  for (final value in values) {
    if (merged.isEmpty || value.start > merged.last.end) {
      merged.add(value);
      continue;
    }
    if (value.end > merged.last.end) {
      merged[merged.length - 1] = _okStrokeInterval(
        merged.last.start,
        value.end,
      );
    }
  }
  return List.unmodifiable(merged);
}

StrokeErasureInterval _okStrokeInterval(double start, double end) =>
    StrokeErasureInterval.create(start: start, end: end).fold(
      onOk: (value) => value,
      onErr: (_) => throw StateError('Owned interval merge must remain valid.'),
    );

/// Splits at deterministic entry/exit boundaries of the Page-space swept
/// eraser and complete transformed visible stroke geometry. Original samples
/// are retained byte-for-byte; boundary samples interpolate numeric sensor and
/// time evidence and deliberately carry no unknown metadata. Maximal surviving
/// runs become fragments in source order and receive one collision-checked ID.
Result<StrokeSplitResult, StructuredFailure> splitStrokeByEraser({
  required HandwritingStroke source,
  required Iterable<Point2> eraserPath,
  required double radius,
  required AffineTransform2D localToPage,
  required StrokeGeometryResolver geometryResolver,
  required UuidGenerator strokeIdGenerator,
  required Iterable<StrokeId> existingIds,
  required int maximumExistingIds,
  required int maximumEraserPoints,
  required int maximumIntersections,
  required int maximumFragments,
  required int maximumOutputSamples,
  required HandwritingLimits handwritingLimits,
}) {
  final path = SweptPath.create(eraserPath, maximumPoints: maximumEraserPoints);
  if (path is! Ok<SweptPath, StructuredFailure>) {
    return Err(_failure('invalid_eraser_path'));
  }
  final capturedIds = _captureExistingStrokeIds(
    existingIds,
    maximumExistingIds,
  );
  if (capturedIds is! Ok<Set<StrokeId>, StructuredFailure>) {
    return Err(_failure('existing_ids_unavailable'));
  }
  return _splitStrokeByEraser(
    source: source,
    eraserPath: path.value,
    radius: radius,
    localToPage: localToPage,
    geometryResolver: geometryResolver,
    strokeIdGenerator: strokeIdGenerator,
    existingIds: capturedIds.value,
    maximumIntersections: maximumIntersections,
    maximumFragments: maximumFragments,
    maximumOutputSamples: maximumOutputSamples,
    handwritingLimits: handwritingLimits,
    allocateIdentities: true,
  );
}

/// Plans one stroke split without allocating persistent fragment identities.
///
/// Returned fragments are transient evidence only. Callers must allocate and
/// validate fresh identities at the terminal publication boundary.
Result<StrokeSplitResult, StructuredFailure> previewStrokeSplitByEraser({
  required HandwritingStroke source,
  required TransformedStrokeGeometry sourceGeometry,
  required Iterable<Point2> eraserPath,
  required double radius,
  required AffineTransform2D localToPage,
  required StrokeGeometryResolver geometryResolver,
  required int maximumEraserPoints,
  required int maximumIntersections,
  required int maximumFragments,
  required int maximumOutputSamples,
  required HandwritingLimits handwritingLimits,
}) {
  final path = SweptPath.create(eraserPath, maximumPoints: maximumEraserPoints);
  if (path is! Ok<SweptPath, StructuredFailure>) {
    return Err(_failure('invalid_eraser_path'));
  }
  return _splitStrokeByEraser(
    source: source,
    sourceGeometry: sourceGeometry,
    eraserPath: path.value,
    radius: radius,
    localToPage: localToPage,
    geometryResolver: geometryResolver,
    strokeIdGenerator: const _ForbiddenUuidGenerator(),
    existingIds: const {},
    maximumIntersections: maximumIntersections,
    maximumFragments: maximumFragments,
    maximumOutputSamples: maximumOutputSamples,
    handwritingLimits: handwritingLimits,
    allocateIdentities: false,
  );
}

Result<StrokeSplitResult, StructuredFailure> _splitStrokeByEraser({
  required HandwritingStroke source,
  TransformedStrokeGeometry? sourceGeometry,
  required SweptPath eraserPath,
  required double radius,
  required AffineTransform2D localToPage,
  required StrokeGeometryResolver geometryResolver,
  required UuidGenerator strokeIdGenerator,
  required Set<StrokeId> existingIds,
  required int maximumIntersections,
  required int maximumFragments,
  required int maximumOutputSamples,
  required HandwritingLimits handwritingLimits,
  required bool allocateIdentities,
}) {
  if (!radius.isFinite ||
      radius < 0 ||
      maximumIntersections < 0 ||
      maximumIntersections > Revision.maximumValue ||
      maximumFragments < 0 ||
      maximumFragments > Revision.maximumValue ||
      maximumOutputSamples < 0 ||
      maximumOutputSamples > Revision.maximumValue)
    return Err(_failure('invalid_eraser'));
  final path = eraserPath.points;
  if (sourceGeometry != null) {
    final query = sourceGeometry.intersectsSweptPath(eraserPath, radius);
    if (query is! Ok<bool, StructuredFailure>) {
      return Err(_failure('eraser_geometry_unavailable'));
    }
    if (!query.value) {
      return StrokeSplitResult.create(strokes: [source], maximumStrokes: 1);
    }
  }
  final runs = <List<StrokeSample>>[];
  List<StrokeSample>? run;
  var intersections = 0;
  var outputSamples = 0;

  void append(StrokeSample sample) {
    run ??= <StrokeSample>[];
    if (run!.isEmpty) runs.add(run!);
    if (run!.isEmpty || run!.last != sample) {
      run!.add(sample);
      outputSamples += 1;
    }
  }

  final gestureSegments = <SweptPath>[];
  if (path.length == 1) {
    gestureSegments.add(eraserPath);
  } else {
    for (var index = 1; index < path.length; index += 1) {
      final segment = SweptPath.create([
        path[index - 1],
        path[index],
      ], maximumPoints: 2);
      if (segment is! Ok<SweptPath, StructuredFailure>) {
        return Err(_failure('invalid_eraser_path'));
      }
      gestureSegments.add(segment.value);
    }
  }
  final erasedBySegment = <int, List<StrokeErasureInterval>>{};
  final sourceSegmentCount = source.samples.length == 1
      ? 1
      : source.samples.length - 1;
  for (var segment = 0; segment < sourceSegmentCount; segment += 1) {
    final first = source.samples.length == 1
        ? source.samples.single
        : source.samples[segment];
    final second = source.samples.length == 1
        ? source.samples.single
        : source.samples[segment + 1];
    var accumulated = <StrokeErasureInterval>[];
    for (final gesture in gestureSegments) {
      final classified = geometryResolver.classifySourceSegmentErasure(
        first: first,
        second: second,
        style: source.style,
        localToPage: localToPage,
        eraserSegment: gesture,
        radius: radius,
        handwritingLimits: handwritingLimits,
      );
      if (classified is! Ok<List<StrokeErasureInterval>, StructuredFailure>) {
        return Err(_failure('eraser_classification_unavailable'));
      }
      accumulated = _mergeStrokeIntervals(accumulated, classified.value);
      if (accumulated.length > maximumIntersections) {
        return Err(_failure('eraser_intersection_limit'));
      }
    }
    if (accumulated.isNotEmpty) erasedBySegment[segment] = accumulated;
  }
  if (erasedBySegment.isEmpty) {
    return StrokeSplitResult.create(strokes: [source], maximumStrokes: 1);
  }
  if (source.samples.length > 1) {
    for (var segment = 0; segment < sourceSegmentCount; segment += 1) {
      final first = source.samples[segment];
      final second = source.samples[segment + 1];
      final erased = erasedBySegment[segment] ?? const [];
      var cursor = 0.0;
      for (final interval in erased) {
        if (interval.start > cursor) {
          final start = _boundarySample(
            first,
            second,
            cursor,
            handwritingLimits,
          );
          final end = _boundarySample(
            first,
            second,
            interval.start,
            handwritingLimits,
          );
          if (start == null || end == null) {
            return Err(_failure('invalid_eraser_boundary'));
          }
          append(start);
          append(end);
        }
        if (interval.start > 0) intersections += 1;
        if (interval.end < 1) intersections += 1;
        if (intersections > maximumIntersections) {
          return Err(_failure('eraser_intersection_limit'));
        }
        run = null;
        cursor = math.max(cursor, interval.end);
      }
      if (cursor < 1) {
        final start = _boundarySample(first, second, cursor, handwritingLimits);
        if (start == null) return Err(_failure('invalid_eraser_boundary'));
        append(start);
        append(second);
      }
    }
  }
  if (runs.length > maximumFragments || outputSamples > maximumOutputSamples) {
    return Err(_failure('eraser_output_limit'));
  }
  final allocated = <StrokeId>{};
  final fragments = <HandwritingStroke>[];
  for (final samples in runs) {
    StrokeId? id = source.id;
    if (allocateIdentities) {
      try {
        final result = strokeIdGenerator.generateV4();
        if (result is Ok<UuidIdentifier, StructuredFailure>) {
          id = StrokeId.fromUuid(result.value);
        } else {
          id = null;
        }
      } on Object {
        id = null;
      }
      if (id == null ||
          id == source.id ||
          existingIds.contains(id) ||
          !allocated.add(id)) {
        return Err(_failure('stroke_id_collision'));
      }
    }
    final fragment = HandwritingStroke.create(
      id: id,
      samples: samples,
      style: source.style,
      limits: handwritingLimits,
      unknownFields: source.unknownFields,
    );
    if (fragment is Err<HandwritingStroke, StructuredFailure>)
      return Err(fragment.error);
    fragments.add((fragment as Ok<HandwritingStroke, StructuredFailure>).value);
  }
  return StrokeSplitResult.create(
    strokes: fragments,
    maximumStrokes: math.max(1, maximumFragments),
    intersectionCount: intersections,
    outputSampleCount: outputSamples,
    affected: true,
  );
}

/// Builds one atomic partial-erase request without mutating the document.
///
/// All geometry is classified in Page space. Candidate replacements/removals
/// and fresh fragment identities are completed before a request is returned.
Result<AtomicObjectCollectionEditRequest, StructuredFailure>
createPartialEraseRequest({
  required DocumentCoordinatorSnapshot document,
  required PageId pageId,
  required Iterable<Point2> pagePath,
  required double pageRadius,
  required UuidGenerator uuidGenerator,
  required HandwritingLimits handwritingLimits,
  required StrokeGeometryResolver geometryResolver,
  required int maximumEraserPoints,
  required int maximumIntersections,
  required int maximumFragments,
  required int maximumOutputSamples,
  required int maximumCommandOperations,
}) {
  if (!pageRadius.isFinite ||
      pageRadius < 0 ||
      maximumEraserPoints <= 0 ||
      maximumEraserPoints > Revision.maximumValue ||
      maximumIntersections < 0 ||
      maximumIntersections > Revision.maximumValue ||
      maximumFragments < 0 ||
      maximumFragments > Revision.maximumValue ||
      maximumOutputSamples < 0 ||
      maximumOutputSamples > Revision.maximumValue ||
      maximumCommandOperations <= 0 ||
      maximumCommandOperations > Revision.maximumValue) {
    return Err(_failure('invalid_eraser'));
  }
  final path = SweptPath.create(pagePath, maximumPoints: maximumEraserPoints);
  if (path is! Ok<SweptPath, StructuredFailure>) {
    return Err(_failure('invalid_eraser_path'));
  }
  if (document.root.id != document.revisions.documentId ||
      document.revisions.pages.keys.toSet().length !=
          document.root.pages.length ||
      !document.revisions.pages.keys.toSet().containsAll(
        document.root.pages.map((value) => value.id),
      )) {
    return Err(_failure('missing_eraser_revision'));
  }
  final page = document.root.pages
      .where((value) => value.id == pageId)
      .firstOrNull;
  if (page == null) return Err(_failure('missing_eraser_page'));
  final pageRevision = document.revisions.pages[pageId];
  if (pageRevision == null) return Err(_failure('missing_eraser_revision'));
  final liveObjects = document.root.pages
      .expand((value) => value.layers)
      .expand((value) => value.objects)
      .map((value) => value.id)
      .toSet();
  final liveLayers = document.root.pages
      .expand((value) => value.layers)
      .map((value) => value.id)
      .toSet();
  if (document.revisions.objects.keys.toSet().length != liveObjects.length ||
      !document.revisions.objects.keys.toSet().containsAll(liveObjects) ||
      document.revisions.layerMembership.keys.toSet().length !=
          liveLayers.length ||
      !document.revisions.layerMembership.keys.toSet().containsAll(
        liveLayers,
      )) {
    return Err(_failure('missing_eraser_revision'));
  }
  final existingStrokeIds = <StrokeId>{};
  for (final object
      in document.root.pages
          .expand((value) => value.layers.whereType<ContentLayer>())
          .expand((value) => value.objects)) {
    if (object.typeKey != handwritingObjectTypeKey ||
        object.typeSchemaVersion != handwritingSchemaVersion)
      continue;
    final payload = HandwritingPayload.decode(
      object.payload,
      limits: handwritingLimits,
    ).fold<HandwritingPayload?>(onOk: (value) => value, onErr: (_) => null);
    if (payload == null) return Err(_failure('invalid_eraser_object'));
    for (final stroke in payload.strokes) {
      if (!existingStrokeIds.add(stroke.id)) {
        return Err(_failure('duplicate_stroke_identity'));
      }
    }
  }
  final plans = <_PlannedObjectErase>[];
  var totalIntersections = 0;
  var totalFragments = 0;
  var totalOutputSamples = 0;
  for (final layer in page.layers) {
    if (layer is! ContentLayer) continue;
    if (!layer.visible || layer.locked) continue;
    for (final object in layer.objects) {
      if (!object.visible ||
          object.locked ||
          object.typeKey != handwritingObjectTypeKey ||
          object.typeSchemaVersion != handwritingSchemaVersion)
        continue;
      final payload = HandwritingPayload.decode(
        object.payload,
        limits: handwritingLimits,
      ).fold<HandwritingPayload?>(onOk: (value) => value, onErr: (_) => null);
      if (payload == null) continue;
      final strokePlans = <StrokeSplitResult>[];
      var changed = false;
      for (final stroke in payload.strokes) {
        final split = _splitStrokeByEraser(
          source: stroke,
          eraserPath: path.value,
          radius: pageRadius,
          localToPage: object.transform,
          geometryResolver: geometryResolver,
          strokeIdGenerator: const _ForbiddenUuidGenerator(),
          existingIds: existingStrokeIds,
          maximumIntersections: maximumIntersections,
          maximumFragments: maximumFragments,
          maximumOutputSamples: maximumOutputSamples,
          handwritingLimits: handwritingLimits,
          allocateIdentities: false,
        );
        if (split is Err<StrokeSplitResult, StructuredFailure>)
          return Err(split.error);
        final value = (split as Ok<StrokeSplitResult, StructuredFailure>).value;
        strokePlans.add(value);
        changed = changed || value.affected;
        totalIntersections =
            _checkedBudgetAdd(
              totalIntersections,
              value.intersectionCount,
              maximumIntersections,
            ) ??
            -1;
        totalFragments =
            _checkedBudgetAdd(
              totalFragments,
              value.affected ? value.strokes.length : 0,
              maximumFragments,
            ) ??
            -1;
        totalOutputSamples =
            _checkedBudgetAdd(
              totalOutputSamples,
              value.outputSampleCount,
              maximumOutputSamples,
            ) ??
            -1;
        if (totalIntersections < 0 ||
            totalFragments < 0 ||
            totalOutputSamples < 0) {
          return Err(_failure('eraser_cumulative_limit'));
        }
      }
      if (!changed) continue;
      final objectRevision = document.revisions.objects[object.id];
      final membership = document.revisions.layerMembership[layer.id];
      if (objectRevision == null || membership == null)
        return Err(_failure('missing_eraser_revision'));
      plans.add(
        _PlannedObjectErase(
          layer: layer,
          object: object,
          payload: payload,
          strokePlans: strokePlans,
          objectRevision: objectRevision,
          membershipRevision: membership,
        ),
      );
      if (plans.length > maximumCommandOperations) {
        return Err(_failure('eraser_operation_limit'));
      }
    }
  }
  if (plans.isEmpty) return Err(_failure('nothing_erased'));

  final replacements = <ObjectEnvelope>[];
  final removals = <ObjectId>[];
  final objectRevisions = <ObjectId, Revision>{};
  final membershipRevisions = <LayerId, Revision>{};
  final occupiedUuids = <String>{document.root.id.uuid.value};
  occupiedUuids.addAll(
    document.root.pages.expand((value) sync* {
      yield value.id.uuid.value;
      for (final layer in value.layers) {
        yield layer.id.uuid.value;
        for (final object in layer.objects) yield object.id.uuid.value;
      }
    }),
  );
  occupiedUuids.addAll(existingStrokeIds.map((value) => value.uuid.value));
  for (final plan in plans) {
    final survivors = <HandwritingStroke>[];
    for (var index = 0; index < plan.payload.strokes.length; index += 1) {
      final source = plan.payload.strokes[index];
      final split = plan.strokePlans[index];
      if (!split.affected) {
        survivors.add(source);
        continue;
      }
      for (final planned in split.strokes) {
        UuidIdentifier? uuid;
        try {
          final generated = uuidGenerator.generateV4();
          if (generated is Ok<UuidIdentifier, StructuredFailure>) {
            uuid = generated.value;
          }
        } on Object {
          uuid = null;
        }
        final id = uuid == null ? null : StrokeId.fromUuid(uuid);
        if (id == null ||
            id == source.id ||
            existingStrokeIds.contains(id) ||
            !existingStrokeIds.add(id) ||
            !occupiedUuids.add(uuid!.value)) {
          return Err(_failure('stroke_id_collision'));
        }
        final fragment = HandwritingStroke.create(
          id: id,
          samples: planned.samples,
          style: source.style,
          limits: handwritingLimits,
          unknownFields: source.unknownFields,
        );
        if (fragment is Err<HandwritingStroke, StructuredFailure>) {
          return Err(fragment.error);
        }
        survivors.add(
          (fragment as Ok<HandwritingStroke, StructuredFailure>).value,
        );
      }
    }
    objectRevisions[plan.object.id] = plan.objectRevision;
    membershipRevisions[plan.layer.id] = plan.membershipRevision;
    if (survivors.isEmpty) {
      removals.add(plan.object.id);
      continue;
    }
    final nextPayload = HandwritingPayload.create(
      strokes: survivors,
      limits: handwritingLimits,
      unknownFields: plan.payload.unknownFields,
    );
    if (nextPayload is Err<HandwritingPayload, StructuredFailure>) {
      return Err(nextPayload.error);
    }
    final replacement = ObjectEnvelope.create(
      id: plan.object.id,
      typeKey: plan.object.typeKey,
      envelopeVersion: plan.object.envelopeVersion,
      typeSchemaVersion: plan.object.typeSchemaVersion,
      transform: plan.object.transform,
      visible: plan.object.visible,
      locked: plan.object.locked,
      payload: (nextPayload as Ok<HandwritingPayload, StructuredFailure>).value
          .encode(),
      extensionData: plan.object.extensionData,
    );
    if (replacement is Err<ObjectEnvelope, StructuredFailure>) {
      return Err(replacement.error);
    }
    replacements.add(
      (replacement as Ok<ObjectEnvelope, StructuredFailure>).value,
    );
  }
  Result<UuidIdentifier, StructuredFailure>? correlation;
  try {
    correlation = uuidGenerator.generateV4();
  } on Object {
    correlation = null;
  }
  if (correlation is! Ok<UuidIdentifier, StructuredFailure> ||
      !occupiedUuids.add(correlation.value.value)) {
    return Err(_failure('uuid_generation_or_collision'));
  }
  return AtomicObjectCollectionEditRequest.create(
    documentId: document.root.id,
    pageId: pageId,
    metadata: CommandMetadata(
      family: CommandFamily.objectCollectionEdit,
      correlationId: CommandCorrelationId.fromUuid(correlation.value),
      description: 'Partially erase handwriting',
    ),
    preconditions: RevisionPreconditions(
      pages: {pageId: pageRevision},
      objects: objectRevisions,
      layerMembership: membershipRevisions,
    ),
    removals: removals,
    replacements: replacements,
    replacementChangeCategories: ObjectReplacementChangeCategories(
      geometry: replacements.isNotEmpty,
      appearance: false,
      text: false,
      metadata: replacements.isNotEmpty,
    ),
    maximumOperations: maximumCommandOperations,
  );
}

final class _PlannedObjectErase {
  const _PlannedObjectErase({
    required this.layer,
    required this.object,
    required this.payload,
    required this.strokePlans,
    required this.objectRevision,
    required this.membershipRevision,
  });
  final DocumentLayer layer;
  final ObjectEnvelope object;
  final HandwritingPayload payload;
  final List<StrokeSplitResult> strokePlans;
  final Revision objectRevision;
  final Revision membershipRevision;
}

final class _ForbiddenUuidGenerator implements UuidGenerator {
  const _ForbiddenUuidGenerator();
  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() =>
      throw StateError('UUID allocation is forbidden during eraser planning.');
}

int? _checkedBudgetAdd(int left, int right, int maximum) {
  if (left < 0 || right < 0 || left > maximum - right) return null;
  return left + right;
}

Result<StrokeSample, StructuredFailure> _interpolateSample(
  StrokeSample first,
  StrokeSample second,
  double t,
  HandwritingLimits limits,
) {
  double? interpolateOptional(double? a, double? b) =>
      a == null || b == null ? null : a + (b - a) * t;
  final point = Point2.create(
    x: first.position.x + (second.position.x - first.position.x) * t,
    y: first.position.y + (second.position.y - first.position.y) * t,
  );
  if (point is Err<Point2, StructuredFailure>) return Err(point.error);
  return StrokeSample.create(
    position: (point as Ok<Point2, StructuredFailure>).value,
    timeMicros: (first.timeMicros + (second.timeMicros - first.timeMicros) * t)
        .round(),
    limits: limits,
    pressure: interpolateOptional(first.pressure, second.pressure),
    tilt: interpolateOptional(first.tilt, second.tilt),
    orientation: interpolateOptional(first.orientation, second.orientation),
    unknownFields: PreservedMap.empty(),
  );
}

StrokeSample? _boundarySample(
  StrokeSample first,
  StrokeSample second,
  double t,
  HandwritingLimits limits,
) {
  if (t <= 0) return first;
  if (t >= 1) return second;
  return _interpolateSample(
    first,
    second,
    t,
    limits,
  ).fold<StrokeSample?>(onOk: (value) => value, onErr: (_) => null);
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.tools.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Drawing tool input is invalid.',
);
