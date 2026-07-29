// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/identity/uuid_generator.dart';
import '../../core/identity/uuid_identifier.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/security/resource_limits.dart';
import '../../core/versioning/revision.dart';
import '../../core/versioning/schema_version.dart';
import '../../documents/commands.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../../drawing/geometry.dart';
import '../../drawing/hit_testing.dart';
import '../../drawing/renderer.dart';
import '../../drawing/tools.dart';
import 'flutter_pointer_adapter.dart';

/// Fully validated immutable dependency and resource configuration for Canvas.
final class Phase6CanvasRuntime {
  const Phase6CanvasRuntime._({
    required this.uuidGenerator,
    required this.handwritingLimits,
    required this.geometryResolver,
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
    required this.maximumHitResults,
    required this.maximumLassoPoints,
    required this.maximumSelectionTargets,
    required this.maximumCommandOperations,
    required this.maximumListeners,
    required this.maximumPenSamples,
    required this.maximumEraserPoints,
    required this.maximumEraserIntersections,
    required this.maximumEraserFragments,
    required this.maximumEraserOutputSamples,
  });

  /// Creates the complete runtime and generates initial persistent identities.
  static Result<Phase6CanvasRuntime, StructuredFailure> create({
    required UuidGenerator uuidGenerator,
    required HandwritingLimits handwritingLimits,
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
    required int maximumEraserIntersections,
    required int maximumEraserFragments,
    required int maximumEraserOutputSamples,
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
      maximumEraserIntersections,
      maximumEraserFragments,
      maximumEraserOutputSamples,
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
        maximumRenderingDefinitions < 1 ||
        maximumHitTestingDefinitions < 1 ||
        maximumTools < 4 ||
        maximumActions < 4 ||
        maximumBindings < 9 ||
        maximumPenSamples > handwritingLimits.maximumSamplesPerStroke ||
        requiredElements == null ||
        requiredElements - 1 > geometryLimits.maximumElements ||
        requiredVertices == null ||
        requiredVertices > geometryLimits.maximumVertices ||
        renderingLimits.maximumPointsPerPrimitive <
            geometryLimits.ellipseVertexCount) {
      return Err(_failure('invalid_limits'));
    }
    final geometry = StrokeGeometryResolver(geometryLimits);
    final objectRegistry = ObjectRegistry.create([
      HandwritingObjectTypeDefinition(handwritingLimits),
    ]).fold<ObjectRegistry?>(onOk: (value) => value, onErr: (_) => null);
    if (objectRegistry == null || objectRegistry.definitions.length != 1) {
      return Err(_failure('initialization_failed'));
    }
    final components = _createRuntimeComponents(
      handwritingLimits: handwritingLimits,
      geometry: geometry,
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
        geometryResolver: geometry,
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
        maximumHitResults: maximumHitResults,
        maximumLassoPoints: maximumLassoPoints,
        maximumSelectionTargets: maximumSelectionTargets,
        maximumCommandOperations: maximumCommandOperations,
        maximumListeners: maximumListeners,
        maximumPenSamples: maximumPenSamples,
        maximumEraserPoints: maximumEraserPoints,
        maximumEraserIntersections: maximumEraserIntersections,
        maximumEraserFragments: maximumEraserFragments,
        maximumEraserOutputSamples: maximumEraserOutputSamples,
      ),
    );
  }

  final UuidGenerator uuidGenerator;
  final HandwritingLimits handwritingLimits;
  final StrokeGeometryResolver geometryResolver;
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
  final int maximumHitResults;
  final int maximumLassoPoints;
  final int maximumSelectionTargets;
  final int maximumCommandOperations;
  final int maximumListeners;
  final int maximumPenSamples;
  final int maximumEraserPoints;
  final int maximumEraserIntersections;
  final int maximumEraserFragments;
  final int maximumEraserOutputSamples;

  /// Creates a fresh coordinator for a successfully reopened exact root.
  Result<DocumentMutationCoordinator, CommandFailure> createCoordinator(
    DocumentRoot root,
  ) => DocumentMutationCoordinator.create(
    initialRoot: root,
    validator: DocumentValidator(objectRegistry),
    uuidGenerator: uuidGenerator,
    historyLimits: historyLimits,
    retainedCostEstimator: historyCostEstimator,
    maximumListeners: maximumListeners,
  );
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
  required StrokeGeometryResolver geometry,
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
      ),
    ],
    maximumDefinitions: maximumRenderingDefinitions,
  ).fold<RenderingRegistry?>(onOk: (value) => value, onErr: (_) => null);
  final hitTestingRegistry = HitTestingRegistry.create(
    [
      HandwritingHitTestingDefinition(
        handwritingLimits: handwritingLimits,
        geometryResolver: geometry,
      ),
    ],
    maximumDefinitions: maximumHitTestingDefinitions,
    maximumBehaviorResults: maximumHitBehaviorResults,
  ).fold<HitTestingRegistry?>(onOk: (value) => value, onErr: (_) => null);
  const toolNames = ['pen', 'wholeeraser', 'partialeraser', 'selection'];
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
  'partialeraser' => 'partialEraser',
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
