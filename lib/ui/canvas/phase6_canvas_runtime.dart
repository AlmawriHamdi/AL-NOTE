// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/services.dart';

import '../../core/geometry/geometry_values.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/cancellation.dart';
import '../../core/outcomes/operation_outcome.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import '../../core/versioning/revision.dart';
import '../../core/versioning/schema_version.dart';
import '../../documents/commands.dart';
import '../../documents/document_model.dart';
import '../../documents/files.dart';
import '../../documents/objects/handwriting.dart';
import '../../drawing/geometry.dart';
import '../../drawing/hit_testing.dart';
import '../../drawing/renderer.dart';
import '../../drawing/tools.dart';
import 'flutter_pointer_adapter.dart';
import 'phase6_diagnostics.dart';

/// Injected, exception-contained boundary for the debug diagnostics clipboard.
abstract interface class Phase6DebugClipboard {
  /// Copies bounded diagnostic [text] and returns only structured evidence.
  Future<Result<void, StructuredFailure>> copyText(String text);
}

/// Injectable accounting evidence for Canvas-owned native pictures.
abstract interface class Phase6NativePictureObserver {
  /// Records creation of one owned native picture.
  void pictureCreated();

  /// Records disposal of one owned native picture.
  void pictureDisposed();
}

/// Production observer that intentionally retains no accounting state.
final class Phase6NoopNativePictureObserver
    implements Phase6NativePictureObserver {
  /// Creates the stateless observer.
  const Phase6NoopNativePictureObserver();

  @override
  void pictureCreated() {}

  @override
  void pictureDisposed() {}
}

/// Flutter system-clipboard adapter used by the production Canvas runtime.
final class Phase6SystemDebugClipboard implements Phase6DebugClipboard {
  /// Creates the stateless system clipboard adapter.
  const Phase6SystemDebugClipboard();

  @override
  Future<Result<void, StructuredFailure>> copyText(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return const Ok(null);
    } on Object {
      return Err(_failure('diagnostics_copy_failed'));
    }
  }
}

/// Fixed redaction-safe failure stages for an in-memory package reopen.
enum Phase6ReopenFailureStage {
  /// Package bytes could not be opened and verified.
  read,

  /// The opened package could not materialize a complete document.
  materialization,

  /// Materialized content differed from the exact saved root.
  mismatch,

  /// A coordinator could not be constructed for the materialized root.
  coordinator,
}

/// Result of the staged in-memory package reopen pipeline.
sealed class Phase6ReopenOutcome {
  const Phase6ReopenOutcome();
}

/// Successfully materialized document and newly constructed coordinator.
final class Phase6ReopenSuccess extends Phase6ReopenOutcome {
  /// Creates successful trusted reopen evidence.
  const Phase6ReopenSuccess({required this.root, required this.coordinator});

  /// Decoded and materialized document instance.
  final DocumentRoot root;

  /// Fresh coordinator constructed from [root].
  final DocumentMutationCoordinator coordinator;
}

/// Redaction-safe staged reopen failure.
final class Phase6ReopenFailure extends Phase6ReopenOutcome {
  /// Creates failure evidence containing only its fixed [stage].
  const Phase6ReopenFailure(this.stage);

  /// Pipeline stage that rejected the reopen.
  final Phase6ReopenFailureStage stage;
}

/// Injected boundary for reopening verified in-memory `.alnote` bytes.
abstract interface class Phase6ReopenGateway {
  /// Opens, materializes, compares, and constructs without publishing state.
  Phase6ReopenOutcome reopen({
    required List<int> bytes,
    required DocumentRoot savedRoot,
  });
}

/// Fully validated immutable dependency and resource configuration for Canvas.
final class Phase6CanvasRuntime {
  const Phase6CanvasRuntime._({
    required this.uuidGenerator,
    required this.handwritingLimits,
    required this.shapeLimits,
    required this.shapeInteractionLimits,
    required this.imageLimits,
    required this.textLimits,
    required this.penStyle,
    required this.geometryResolver,
    required this.geometryCache,
    required this.renderingLimits,
    required this.objectRegistry,
    required this.renderingRegistry,
    required this.hitTestingRegistry,
    required this.toolRegistry,
    required this.actionRegistry,
    required this.bindingProfile,
    required this.pointerAdapter,
    required this.historyLimits,
    required this.historyCostEstimator,
    required this.storageLimits,
    required this.initialRoot,
    required this.initialCoordinator,
    required this.reopenGateway,
    required this.maximumHitResults,
    required this.maximumLassoPoints,
    required this.maximumSelectionTargets,
    required this.maximumCommandOperations,
    required this.maximumListeners,
    required this.maximumPenSamples,
    required this.maximumEraserPoints,
    required this.diagnosticTrace,
    required this.debugClipboard,
    required this.nativePictureObserver,
  });

  /// Creates the complete runtime and generates initial persistent identities.
  static Result<Phase6CanvasRuntime, StructuredFailure> create({
    required UuidGenerator uuidGenerator,
    required HandwritingLimits handwritingLimits,
    required ShapeLimits shapeLimits,
    required ShapeInteractionLimits shapeInteractionLimits,
    required ImageLimits imageLimits,
    required TextLimits textLimits,
    required StrokeStyle penStyle,
    required StrokeGeometryLimits geometryLimits,
    required RenderingLimits renderingLimits,
    required HistoryLimits historyLimits,
    required ResourceLimitSnapshot storageLimits,
    required int maximumHitResults,
    required int maximumLassoPoints,
    required int maximumRenderingDefinitions,
    required int maximumHitTestingDefinitions,
    required int maximumHitBehaviorResults,
    required int maximumTools,
    required int maximumActions,
    required int maximumBindings,
    required int maximumSelectionTargets,
    required int maximumCommandOperations,
    required int maximumListeners,
    required int maximumPenSamples,
    required int maximumEraserPoints,
    required Phase6DiagnosticTrace diagnosticTrace,
    required Phase6DebugClipboard debugClipboard,
    required Phase6NativePictureObserver nativePictureObserver,
    Phase6ReopenGateway? reopenGateway,
  }) {
    final ceilings = <int>[
      maximumHitResults,
      maximumLassoPoints,
      maximumRenderingDefinitions,
      maximumHitTestingDefinitions,
      maximumHitBehaviorResults,
      maximumTools,
      maximumActions,
      maximumBindings,
      maximumSelectionTargets,
      maximumCommandOperations,
      maximumListeners,
      maximumPenSamples,
      maximumEraserPoints,
    ];
    final requiredElements = _multiplyCost(
      maximumPenSamples,
      2,
      Revision.maximumValue,
    );
    final requiredCircleVertices = _multiplyCost(
      maximumPenSamples,
      geometryLimits.ellipseVertexCount,
      Revision.maximumValue,
    );
    final requiredBodyVertices = _multiplyCost(
      maximumPenSamples - 1,
      4,
      Revision.maximumValue,
    );
    final requiredVertices =
        requiredCircleVertices == null || requiredBodyVertices == null
        ? null
        : _addCost(
            requiredCircleVertices,
            requiredBodyVertices,
            Revision.maximumValue,
          );
    if (ceilings.any((value) => value <= 0 || value > Revision.maximumValue) ||
        maximumRenderingDefinitions < 4 ||
        maximumHitTestingDefinitions < 4 ||
        maximumTools < 5 ||
        maximumActions < 5 ||
        maximumBindings < 11 ||
        maximumPenSamples > handwritingLimits.maximumSamplesPerStroke ||
        requiredElements == null ||
        requiredElements - 1 > geometryLimits.maximumElements ||
        requiredVertices == null ||
        requiredVertices > geometryLimits.maximumVertices ||
        renderingLimits.maximumPointsPerPrimitive <
            geometryLimits.ellipseVertexCount ||
        renderingLimits.maximumPointsPerPrimitive <
            shapeLimits.maximumVertices) {
      return Err(_failure('invalid_limits'));
    }
    final geometry = StrokeGeometryResolver(geometryLimits);
    final geometryCache = HandwritingGeometryCache(
      maximumObjects: maximumHitResults,
      maximumStrokes: maximumHitResults,
    );
    final objectRegistry = ObjectRegistry.create([
      HandwritingObjectTypeDefinition(handwritingLimits),
      ShapeObjectTypeDefinition(shapeLimits),
      ImageObjectTypeDefinition(imageLimits),
      TextObjectTypeDefinition(textLimits),
    ]).fold<ObjectRegistry?>(onOk: (value) => value, onErr: (_) => null);
    if (objectRegistry == null || objectRegistry.definitions.length != 4) {
      return Err(_failure('initialization_failed'));
    }
    final components = _createRuntimeComponents(
      handwritingLimits: handwritingLimits,
      shapeLimits: shapeLimits,
      shapeInteractionLimits: shapeInteractionLimits,
      imageLimits: imageLimits,
      textLimits: textLimits,
      geometry: geometry,
      geometryCache: geometryCache,
      maximumRenderingDefinitions: maximumRenderingDefinitions,
      maximumHitTestingDefinitions: maximumHitTestingDefinitions,
      maximumHitBehaviorResults: maximumHitBehaviorResults,
      maximumTools: maximumTools,
      maximumActions: maximumActions,
      maximumBindings: maximumBindings,
    );
    if (components == null) return Err(_failure('initialization_failed'));
    final renderingRegistry = components.renderingRegistry;
    final hitRegistry = components.hitTestingRegistry;
    final toolRegistry = components.toolRegistry;
    final actionRegistry = components.actionRegistry;
    final profile = components.bindingProfile;

    final identities = _CollisionTrackingUuidGenerator(uuidGenerator);
    final generated = <UuidIdentifier>[];
    final seen = <String>{};
    for (var index = 0; index < 4; index += 1) {
      Result<UuidIdentifier, StructuredFailure> result;
      try {
        result = identities.generateV4();
      } on Object {
        return Err(_failure('identity_generation_failed'));
      }
      if (result is! Ok<UuidIdentifier, StructuredFailure> ||
          !seen.add(result.value.value)) {
        return Err(_failure('identity_generation_failed'));
      }
      generated.add(result.value);
    }
    final schema = SchemaVersion.create(
      1,
    ).fold<SchemaVersion?>(onOk: (value) => value, onErr: (_) => null);
    final size = Size2.create(
      width: 640,
      height: 800,
    ).fold<Size2?>(onOk: (value) => value, onErr: (_) => null);
    final resources = ResourceCatalog.create(
      const [],
    ).fold<ResourceCatalog?>(onOk: (value) => value, onErr: (_) => null);
    if (schema == null || size == null || resources == null) {
      return Err(_failure('initialization_failed'));
    }
    final empty = PreservedMap.empty();
    final layer = ContentLayer.create(
      id: LayerId.fromUuid(generated[3]),
      envelopeVersion: schema,
      typeSchemaVersion: schema,
      name: 'Notes',
      visible: true,
      locked: false,
      opacity: 1,
      objects: const [],
      typeData: empty,
      extensionData: empty,
    ).fold<ContentLayer?>(onOk: (value) => value, onErr: (_) => null);
    final page = layer == null
        ? null
        : DocumentPage.create(
            id: PageId.fromUuid(generated[2]),
            name: 'Page 1',
            size: size,
            layers: [layer],
            extensionData: empty,
          ).fold<DocumentPage?>(onOk: (value) => value, onErr: (_) => null);
    final section = page == null
        ? null
        : DocumentSection.create(
            id: SectionId.fromUuid(generated[1]),
            name: 'Notebook',
            pages: [page],
            extensionData: empty,
          ).fold<DocumentSection?>(onOk: (value) => value, onErr: (_) => null);
    final root = section == null
        ? null
        : NotebookDocument.create(
            id: DocumentId.fromUuid(generated[0]),
            schemaVersion: schema,
            title: 'AL NOTE',
            resources: resources,
            extensionData: empty,
            sections: [section],
          ).fold<NotebookDocument?>(onOk: (value) => value, onErr: (_) => null);
    if (root == null) return Err(_failure('initialization_failed'));

    final estimator = HandwritingHistoryCostEstimator(
      handwritingLimits,
      maximumAccountingValue: Revision.maximumValue,
    );
    final coordinator =
        DocumentMutationCoordinator.create(
          initialRoot: root,
          requireCompleteInitialResources: true,
          validator: DocumentValidator(objectRegistry),
          uuidGenerator: identities,
          historyLimits: historyLimits,
          retainedCostEstimator: estimator,
          maximumListeners: maximumListeners,
        ).fold<DocumentMutationCoordinator?>(
          onOk: (value) => value,
          onErr: (_) => null,
        );
    if (coordinator == null) return Err(_failure('initialization_failed'));
    return Ok(
      Phase6CanvasRuntime._(
        uuidGenerator: identities,
        handwritingLimits: handwritingLimits,
        shapeLimits: shapeLimits,
        shapeInteractionLimits: shapeInteractionLimits,
        imageLimits: imageLimits,
        textLimits: textLimits,
        penStyle: penStyle,
        geometryResolver: geometry,
        geometryCache: geometryCache,
        renderingLimits: renderingLimits,
        objectRegistry: objectRegistry,
        renderingRegistry: renderingRegistry,
        hitTestingRegistry: hitRegistry,
        toolRegistry: toolRegistry,
        actionRegistry: actionRegistry,
        bindingProfile: profile,
        pointerAdapter: FlutterPointerAdapter(),
        historyLimits: historyLimits,
        historyCostEstimator: estimator,
        storageLimits: storageLimits,
        initialRoot: root,
        initialCoordinator: coordinator,
        reopenGateway:
            reopenGateway ??
            _DefaultPhase6ReopenGateway(
              objectRegistry: objectRegistry,
              storageLimits: storageLimits,
              createCoordinator: (candidate) =>
                  DocumentMutationCoordinator.create(
                    initialRoot: candidate.document,
                    initialResources: candidate.resources,
                    requireCompleteInitialResources: true,
                    validator: DocumentValidator(objectRegistry),
                    uuidGenerator: identities,
                    historyLimits: historyLimits,
                    retainedCostEstimator: estimator,
                    maximumListeners: maximumListeners,
                  ),
            ),
        maximumHitResults: maximumHitResults,
        maximumLassoPoints: maximumLassoPoints,
        maximumSelectionTargets: maximumSelectionTargets,
        maximumCommandOperations: maximumCommandOperations,
        maximumListeners: maximumListeners,
        maximumPenSamples: maximumPenSamples,
        maximumEraserPoints: maximumEraserPoints,
        diagnosticTrace: diagnosticTrace,
        debugClipboard: debugClipboard,
        nativePictureObserver: nativePictureObserver,
      ),
    );
  }

  final UuidGenerator uuidGenerator;
  final HandwritingLimits handwritingLimits;

  /// Built-in Shape validation limits.
  final ShapeLimits shapeLimits;

  /// Synchronous Shape derivation and predicate work ceiling.
  final ShapeInteractionLimits shapeInteractionLimits;

  /// Built-in Image validation limits.
  final ImageLimits imageLimits;

  /// Built-in Text validation and layout limits.
  final TextLimits textLimits;

  /// Resolved persistent Pen appearance shared by preview and commit.
  final StrokeStyle penStyle;
  final StrokeGeometryResolver geometryResolver;
  final HandwritingGeometryCache geometryCache;
  final RenderingLimits renderingLimits;
  final ObjectRegistry objectRegistry;
  final RenderingRegistry renderingRegistry;
  final HitTestingRegistry hitTestingRegistry;
  final ToolRegistry toolRegistry;
  final InteractionActionRegistry actionRegistry;
  final BindingProfile bindingProfile;
  final FlutterPointerAdapter pointerAdapter;
  final HistoryLimits historyLimits;
  final HistoryRetainedCostEstimator historyCostEstimator;
  final ResourceLimitSnapshot storageLimits;
  final NotebookDocument initialRoot;
  final DocumentMutationCoordinator initialCoordinator;

  /// Staged package reopen boundary used by the Canvas.
  final Phase6ReopenGateway reopenGateway;
  final int maximumHitResults;
  final int maximumLassoPoints;
  final int maximumSelectionTargets;
  final int maximumCommandOperations;
  final int maximumListeners;
  final int maximumPenSamples;
  final int maximumEraserPoints;

  /// Injected bounded debug/test diagnostic trace.
  final Phase6DiagnosticTrace diagnosticTrace;

  /// Injected exception-contained debug clipboard boundary.
  final Phase6DebugClipboard debugClipboard;

  /// Injected accounting observer for every Canvas-owned native picture.
  final Phase6NativePictureObserver nativePictureObserver;

  /// Creates a fresh coordinator for a successfully reopened exact root.
  Result<DocumentMutationCoordinator, CommandFailure> createCoordinator(
    DocumentRoot root, {
    Iterable<DocumentResourceSnapshot> resources = const [],
  }) => DocumentMutationCoordinator.create(
    initialRoot: root,
    initialResources: resources,
    requireCompleteInitialResources: true,
    validator: DocumentValidator(objectRegistry),
    uuidGenerator: uuidGenerator,
    historyLimits: historyLimits,
    retainedCostEstimator: historyCostEstimator,
    maximumListeners: maximumListeners,
  );
}

final class _DefaultPhase6ReopenGateway implements Phase6ReopenGateway {
  const _DefaultPhase6ReopenGateway({
    required this.objectRegistry,
    required this.storageLimits,
    required this.createCoordinator,
  });

  final ObjectRegistry objectRegistry;
  final ResourceLimitSnapshot storageLimits;
  final Result<DocumentMutationCoordinator, CommandFailure> Function(
    AlnotePackageSnapshot snapshot,
  )
  createCoordinator;

  @override
  Phase6ReopenOutcome reopen({
    required List<int> bytes,
    required DocumentRoot savedRoot,
  }) {
    OperationOutcome<OpenedAlnotePackage, StructuredFailure> opened;
    try {
      opened = AlnotePackageReader(objectRegistry: objectRegistry).openBytes(
        bytes,
        limits: storageLimits,
        cancellationToken: CancellationController().token,
      );
    } on Object {
      return const Phase6ReopenFailure(Phase6ReopenFailureStage.read);
    }
    if (opened is! Completed<OpenedAlnotePackage, StructuredFailure>) {
      return const Phase6ReopenFailure(Phase6ReopenFailureStage.read);
    }
    OperationOutcome<AlnotePackageSnapshot, StructuredFailure> materialized;
    try {
      materialized = opened.value.materializeSnapshot(
        cancellationToken: CancellationController().token,
      );
    } on Object {
      return const Phase6ReopenFailure(
        Phase6ReopenFailureStage.materialization,
      );
    }
    if (materialized is! Completed<AlnotePackageSnapshot, StructuredFailure>) {
      return const Phase6ReopenFailure(
        Phase6ReopenFailureStage.materialization,
      );
    }
    if (materialized.value.document != savedRoot) {
      return const Phase6ReopenFailure(Phase6ReopenFailureStage.mismatch);
    }
    Result<DocumentMutationCoordinator, CommandFailure> coordinator;
    try {
      coordinator = createCoordinator(materialized.value);
    } on Object {
      return const Phase6ReopenFailure(Phase6ReopenFailureStage.coordinator);
    }
    if (coordinator is! Ok<DocumentMutationCoordinator, CommandFailure>) {
      return const Phase6ReopenFailure(Phase6ReopenFailureStage.coordinator);
    }
    return Phase6ReopenSuccess(
      root: materialized.value.document,
      coordinator: coordinator.value,
    );
  }
}

typedef _RuntimeComponents = ({
  RenderingRegistry renderingRegistry,
  HitTestingRegistry hitTestingRegistry,
  ToolRegistry toolRegistry,
  InteractionActionRegistry actionRegistry,
  BindingProfile bindingProfile,
});

_RuntimeComponents? _createRuntimeComponents({
  required HandwritingLimits handwritingLimits,
  required ShapeLimits shapeLimits,
  required ShapeInteractionLimits shapeInteractionLimits,
  required ImageLimits imageLimits,
  required TextLimits textLimits,
  required StrokeGeometryResolver geometry,
  required HandwritingGeometryCache geometryCache,
  required int maximumRenderingDefinitions,
  required int maximumHitTestingDefinitions,
  required int maximumHitBehaviorResults,
  required int maximumTools,
  required int maximumActions,
  required int maximumBindings,
}) {
  final renderingRegistry = RenderingRegistry.create(
    [
      HandwritingRenderingDefinition(
        handwritingLimits: handwritingLimits,
        geometryResolver: geometry,
        geometryCache: geometryCache,
      ),
      ShapeRenderingDefinition(shapeLimits: shapeLimits),
      ImageRenderingDefinition(imageLimits),
      TextRenderingDefinition(textLimits),
    ],
    maximumDefinitions: maximumRenderingDefinitions,
  ).fold<RenderingRegistry?>(onOk: (value) => value, onErr: (_) => null);
  final hitTestingRegistry = HitTestingRegistry.create(
    [
      HandwritingHitTestingDefinition(
        handwritingLimits: handwritingLimits,
        geometryResolver: geometry,
        geometryCache: geometryCache,
      ),
      ShapeHitTestingDefinition(
        shapeLimits: shapeLimits,
        interactionLimits: shapeInteractionLimits,
      ),
      ImageHitTestingDefinition(imageLimits),
      TextHitTestingDefinition(textLimits),
    ],
    maximumDefinitions: maximumHitTestingDefinitions,
    maximumBehaviorResults: maximumHitBehaviorResults,
  ).fold<HitTestingRegistry?>(onOk: (value) => value, onErr: (_) => null);
  const toolNames = ['pen', 'wholeeraser', 'selection', 'shape', 'text'];
  final tools = <ToolDefinition>[];
  final actions = <InteractionActionDefinition>[];
  final bindings = <InteractionBinding>[];
  for (final name in toolNames) {
    final toolId = ToolId.parse(
      'alnote.tools.$name',
    ).fold<ToolId?>(onOk: (value) => value, onErr: (_) => null);
    final actionId = InteractionActionId.parse(
      'alnote.actions.$name',
    ).fold<InteractionActionId?>(onOk: (value) => value, onErr: (_) => null);
    if (toolId == null || actionId == null) return null;
    tools.add(ToolDefinition(id: toolId, supportsPressure: name == 'pen'));
    actions.add(
      InteractionActionDefinition(
        id: actionId,
        navigation: false,
        temporary: name == 'wholeeraser',
      ),
    );
    bindings.addAll([
      InteractionBinding(
        actionId: actionId,
        source: PointerSource.mouse,
        requiresPrimaryButton: true,
        activeTool: _displayToolName(name),
      ),
      InteractionBinding(
        actionId: actionId,
        source: PointerSource.stylus,
        stylusSubtype: StylusSubtype.tip,
        requiresPrimaryButton: true,
        activeTool: _displayToolName(name),
      ),
    ]);
  }
  bindings.add(
    InteractionBinding(
      actionId: actions[1].id,
      source: PointerSource.stylus,
      stylusSubtype: StylusSubtype.eraser,
      requiresPrimaryButton: true,
    ),
  );
  final toolRegistry = ToolRegistry.create(
    tools,
    maximumTools: maximumTools,
  ).fold<ToolRegistry?>(onOk: (value) => value, onErr: (_) => null);
  final actionRegistry =
      InteractionActionRegistry.create(
        actions,
        maximumActions: maximumActions,
      ).fold<InteractionActionRegistry?>(
        onOk: (value) => value,
        onErr: (_) => null,
      );
  final bindingProfile = BindingProfile.create(
    bindings,
    maximumBindings: maximumBindings,
  ).fold<BindingProfile?>(onOk: (value) => value, onErr: (_) => null);
  if (renderingRegistry == null ||
      hitTestingRegistry == null ||
      toolRegistry == null ||
      actionRegistry == null ||
      bindingProfile == null) {
    return null;
  }
  return (
    renderingRegistry: renderingRegistry,
    hitTestingRegistry: hitTestingRegistry,
    toolRegistry: toolRegistry,
    actionRegistry: actionRegistry,
    bindingProfile: bindingProfile,
  );
}

/// Conservative checked retained-history estimator for preserved payload data.
final class HandwritingHistoryCostEstimator
    implements HistoryRetainedCostEstimator {
  const HandwritingHistoryCostEstimator(
    this.handwritingLimits, {
    required this.maximumAccountingValue,
  });
  final HandwritingLimits handwritingLimits;
  final int maximumAccountingValue;

  @override
  Result<HistoryRetainedCost, StructuredFailure> estimate(
    HistoryCostEstimateInput input,
  ) {
    if (maximumAccountingValue < 0 ||
        maximumAccountingValue > Revision.maximumValue) {
      return Err(_failure('history_cost_overflow'));
    }
    var total = 0;
    for (final root in [input.beforeRoot, input.afterRoot]) {
      for (final object
          in root.pages
              .expand((page) => page.layers)
              .expand((layer) => layer.objects)) {
        final payloadCost = _preservedCost(
          object.payload,
          maximumAccountingValue,
        );
        final extensionCost = _preservedCost(
          object.extensionData,
          maximumAccountingValue,
        );
        if (payloadCost == null || extensionCost == null) {
          return Err(_failure('history_cost_overflow'));
        }
        total = _addCost(total, 256, maximumAccountingValue) ?? -1;
        total = _addCost(total, payloadCost, maximumAccountingValue) ?? -1;
        total = _addCost(total, extensionCost, maximumAccountingValue) ?? -1;
        if (total < 0) return Err(_failure('history_cost_overflow'));
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
          if (payload == null) return Err(_failure('history_cost_unavailable'));
          var structural = 64;
          for (final stroke in payload.strokes) {
            structural =
                _addCost(structural, 224, maximumAccountingValue) ?? -1;
            final sampleCost = _multiplyCost(
              stroke.samples.length,
              128,
              maximumAccountingValue,
            );
            if (structural < 0 || sampleCost == null) {
              return Err(_failure('history_cost_overflow'));
            }
            structural =
                _addCost(structural, sampleCost, maximumAccountingValue) ?? -1;
            if (structural < 0) return Err(_failure('history_cost_overflow'));
          }
          total = _addCost(total, structural, maximumAccountingValue) ?? -1;
          if (total < 0) return Err(_failure('history_cost_overflow'));
        }
      }
    }
    return HistoryRetainedCost.create(total);
  }
}

int? _preservedCost(PreservedData root, int maximum) {
  var total = 0;
  final parents = <Iterator<({String? key, PreservedData value})>>[];
  var current = root;
  try {
    while (true) {
      Iterator<({String? key, PreservedData value})>? children;
      switch (current) {
        case PreservedNull():
          total = _addCost(total, 8, maximum) ?? -1;
        case PreservedBoolean():
          total = _addCost(total, 8, maximum) ?? -1;
        case PreservedInteger():
          total = _addCost(total, 16, maximum) ?? -1;
        case PreservedDouble():
          total = _addCost(total, 16, maximum) ?? -1;
        case PreservedString(:final value):
          total = _addCost(total, 16, maximum) ?? -1;
          total = _addUtf8Cost(total, value, maximum) ?? -1;
        case PreservedList(:final values):
          total = _addCost(total, 24, maximum) ?? -1;
          final slots = _multiplyCost(values.length, 8, maximum);
          if (slots == null) return null;
          total = _addCost(total, slots, maximum) ?? -1;
          children = values.map((value) => (key: null, value: value)).iterator;
        case PreservedMap(:final values):
          total = _addCost(total, 32, maximum) ?? -1;
          final slots = _multiplyCost(values.length, 24, maximum);
          if (slots == null) return null;
          total = _addCost(total, slots, maximum) ?? -1;
          children = values.entries
              .map((entry) => (key: entry.key, value: entry.value))
              .iterator;
      }
      if (total < 0) return null;
      if (children != null && children.moveNext()) {
        parents.add(children);
        final child = children.current;
        if (child.key != null) {
          total = _addUtf8Cost(total, child.key!, maximum) ?? -1;
          if (total < 0) return null;
        }
        current = child.value;
        continue;
      }
      while (parents.isNotEmpty) {
        final parent = parents.last;
        if (!parent.moveNext()) {
          parents.removeLast();
          continue;
        }
        final child = parent.current;
        if (child.key != null) {
          total = _addUtf8Cost(total, child.key!, maximum) ?? -1;
          if (total < 0) return null;
        }
        current = child.value;
        break;
      }
      if (parents.isEmpty) return total;
    }
  } on Object {
    return null;
  }
}

int? _addUtf8Cost(int total, String value, int maximum) {
  for (var index = 0; index < value.length; index += 1) {
    final unit = value.codeUnitAt(index);
    int bytes;
    if (unit <= 0x7f) {
      bytes = 1;
    } else if (unit <= 0x7ff) {
      bytes = 2;
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      final hasLow =
          index + 1 < value.length &&
          value.codeUnitAt(index + 1) >= 0xdc00 &&
          value.codeUnitAt(index + 1) <= 0xdfff;
      if (hasLow) {
        bytes = 4;
        index += 1;
      } else {
        bytes = 3;
      }
    } else {
      // BMP code points and unpaired low surrogates use three bytes. Dart's
      // UTF-8 codec replaces the latter with U+FFFD, also encoded as 3 bytes.
      bytes = 3;
    }
    total = _addCost(total, bytes, maximum) ?? -1;
    if (total < 0) return null;
  }
  return total;
}

int? _addCost(int left, int right, int maximum) {
  if (left < 0 || right < 0 || left > maximum - right) return null;
  return left + right;
}

int? _multiplyCost(int left, int right, int maximum) {
  if (left < 0 || right < 0 || (left != 0 && right > maximum ~/ left)) {
    return null;
  }
  return left * right;
}

String _displayToolName(String stable) => switch (stable) {
  'wholeeraser' => 'wholeEraser',
  _ => stable,
};

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'ui.canvas.runtime.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Canvas runtime initialization failed.',
);

final class _CollisionTrackingUuidGenerator implements UuidGenerator {
  _CollisionTrackingUuidGenerator(this.delegate);
  final UuidGenerator delegate;
  final Set<String> _issued = <String>{};

  @override
  Result<UuidIdentifier, StructuredFailure> generateV4() {
    try {
      final result = delegate.generateV4();
      if (result is! Ok<UuidIdentifier, StructuredFailure> ||
          !_issued.add(result.value.value)) {
        return Err(_failure('identity_collision'));
      }
      return result;
    } on Object {
      return Err(_failure('identity_generation_failed'));
    }
  }
}
