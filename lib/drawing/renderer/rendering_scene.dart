// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../core/geometry/geometry_values.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';
import '../../documents/document_model.dart';
import '../../documents/objects/handwriting.dart';
import '../geometry.dart';
import '../viewport.dart';

/// Conceptual scene plane kept separate from authoritative content.
enum RenderPlane { committed, toolPreview, selection, hover, accessibility }

/// Explicit scene and registry-output ceilings.
final class RenderingLimits {
  const RenderingLimits._({
    required this.maximumPrimitives,
    required this.maximumPointsPerPrimitive,
    required this.maximumDamageRegions,
    required this.maximumPreviewOverlays,
    required this.maximumSelectionOverlays,
  });

  /// Creates positive Web-safe scene ceilings.
  static Result<RenderingLimits, StructuredFailure> create({
    required int maximumPrimitives,
    required int maximumPointsPerPrimitive,
    required int maximumDamageRegions,
    required int maximumPreviewOverlays,
    required int maximumSelectionOverlays,
  }) {
    final values = <int>[
      maximumPrimitives,
      maximumPointsPerPrimitive,
      maximumDamageRegions,
      maximumPreviewOverlays,
      maximumSelectionOverlays,
    ];
    if (values.any((value) => value < 0 || value > Revision.maximumValue) ||
        maximumPrimitives == 0 ||
        maximumPointsPerPrimitive < 3 ||
        maximumDamageRegions == 0) {
      return Err(_failure('invalid_limits', FailureCategory.validation));
    }
    return Ok(
      RenderingLimits._(
        maximumPrimitives: maximumPrimitives,
        maximumPointsPerPrimitive: maximumPointsPerPrimitive,
        maximumDamageRegions: maximumDamageRegions,
        maximumPreviewOverlays: maximumPreviewOverlays,
        maximumSelectionOverlays: maximumSelectionOverlays,
      ),
    );
  }

  /// Total primitive ceiling across every plane.
  final int maximumPrimitives;

  /// Point ceiling for each polygon.
  final int maximumPointsPerPrimitive;

  /// Total damage-region ceiling.
  final int maximumDamageRegions;

  /// Tool-preview primitive ceiling.
  final int maximumPreviewOverlays;

  /// Selection-overlay primitive ceiling.
  final int maximumSelectionOverlays;
}

/// Immutable validated portable ARGB color.
final class RenderColor {
  const RenderColor._(this.argb);

  /// Creates a color in the unsigned 32-bit ARGB range.
  static Result<RenderColor, StructuredFailure> create(int argb) {
    if (argb < 0 || argb > 0xffffffff) {
      return Err(_failure('invalid_color', FailureCategory.validation));
    }
    return Ok(RenderColor._(argb));
  }

  /// Packed ARGB value.
  final int argb;
}

/// Base family of validated portable scene primitives.
sealed class ScenePrimitive {
  const ScenePrimitive._({
    required this.plane,
    required this.bounds,
    required this.opacity,
  });

  /// Conceptual scene plane.
  final RenderPlane plane;

  /// View-space bounds.
  final Rect2 bounds;

  /// Effective finite opacity in `[0, 1]`.
  final double opacity;
}

/// A filled view-space polygon used for transform-correct stroke geometry.
final class FilledPolygonPrimitive extends ScenePrimitive {
  FilledPolygonPrimitive._({
    required super.plane,
    required super.bounds,
    required super.opacity,
    required this.color,
    required List<Point2> points,
  }) : points = List<Point2>.unmodifiable(points),
       super._();

  /// Safely captures a finite polygon under [maximumPoints].
  static Result<FilledPolygonPrimitive, StructuredFailure> create({
    required RenderPlane plane,
    required double opacity,
    required RenderColor color,
    required Iterable<Point2> points,
    required int maximumPoints,
  }) {
    if (!opacity.isFinite || opacity < 0 || opacity > 1 || maximumPoints < 3) {
      return Err(_failure('invalid_primitive', FailureCategory.validation));
    }
    final captured = _capture(points, maximumPoints, 'primitive_points');
    if (captured is Err<List<Point2>, StructuredFailure>)
      return Err(captured.error);
    final values = (captured as Ok<List<Point2>, StructuredFailure>).value;
    if (values.length < 3)
      return Err(_failure('invalid_primitive', FailureCategory.validation));
    final bounds = _bounds(values);
    if (bounds == null)
      return Err(_failure('invalid_primitive', FailureCategory.validation));
    return Ok(
      FilledPolygonPrimitive._(
        plane: plane,
        bounds: bounds,
        opacity: opacity,
        color: color,
        points: values,
      ),
    );
  }

  /// Fill color.
  final RenderColor color;

  /// Ordered immutable view-space polygon vertices.
  final List<Point2> points;
}

/// Safe inert placeholder for unavailable registered rendering behavior.
final class PlaceholderPrimitive extends ScenePrimitive {
  const PlaceholderPrimitive._({
    required super.plane,
    required super.bounds,
    required super.opacity,
  }) : super._();

  /// Creates a placeholder only from finite validated safe bounds.
  static Result<PlaceholderPrimitive, StructuredFailure> create({
    required RenderPlane plane,
    required Rect2 bounds,
    required double opacity,
  }) {
    if (!opacity.isFinite || opacity < 0 || opacity > 1) {
      return Err(_failure('invalid_placeholder', FailureCategory.validation));
    }
    return Ok(
      PlaceholderPrimitive._(plane: plane, bounds: bounds, opacity: opacity),
    );
  }
}

/// AL NOTE-owned rendering behavior source for one Object type.
abstract interface class ObjectRenderingDefinition {
  /// Permanent Object type key; registry capture reads this exactly once.
  ObjectTypeKey get typeKey;

  /// Produces bounded primitives for an already supported valid Object.
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  });
}

/// Immutable bounded nonglobal rendering registry.
final class RenderingRegistry {
  RenderingRegistry._(this.definitions);

  /// Incrementally captures immutable metadata without trusting iterable length.
  static Result<RenderingRegistry, StructuredFailure> create(
    Iterable<ObjectRenderingDefinition> source, {
    required int maximumDefinitions,
  }) {
    if (maximumDefinitions < 0 || maximumDefinitions > Revision.maximumValue) {
      return Err(
        _failure('invalid_registry_limit', FailureCategory.validation),
      );
    }
    final captured = <_CapturedRenderingDefinition>[];
    try {
      final iterator = source.iterator;
      while (iterator.moveNext()) {
        if (captured.length >= maximumDefinitions) {
          return Err(_failure('registry_limit', FailureCategory.resource));
        }
        final delegate = iterator.current;
        final key = delegate.typeKey;
        captured.add(_CapturedRenderingDefinition(delegate, key));
      }
    } on Object {
      return Err(
        _failure('registry_metadata_unavailable', FailureCategory.dependency),
      );
    }
    captured.sort((left, right) => left.typeKey.compareTo(right.typeKey));
    final map = <ObjectTypeKey, ObjectRenderingDefinition>{};
    for (final definition in captured) {
      if (map.containsKey(definition.typeKey)) {
        return Err(_failure('duplicate_renderer', FailureCategory.validation));
      }
      map[definition.typeKey] = definition;
    }
    return Ok(RenderingRegistry._(Map.unmodifiable(map)));
  }

  /// Captured definitions in deterministic type-key order.
  final Map<ObjectTypeKey, ObjectRenderingDefinition> definitions;
}

final class _CapturedRenderingDefinition implements ObjectRenderingDefinition {
  const _CapturedRenderingDefinition(this._delegate, this.typeKey);
  final ObjectRenderingDefinition _delegate;
  @override
  final ObjectTypeKey typeKey;

  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    try {
      final result = _delegate.render(
        object: object,
        viewport: viewport,
        layerOpacity: layerOpacity,
        plane: plane,
        limits: limits,
      );
      if (result is Err<List<ScenePrimitive>, StructuredFailure>) {
        return Err(
          _failure('renderer_unavailable', FailureCategory.dependency),
        );
      }
      final values =
          (result as Ok<List<ScenePrimitive>, StructuredFailure>).value;
      final captured = _capture(
        values,
        limits.maximumPrimitives,
        'renderer_primitives',
      );
      if (captured is Err<List<ScenePrimitive>, StructuredFailure>)
        return Err(captured.error);
      return Ok(
        (captured as Ok<List<ScenePrimitive>, StructuredFailure>).value,
      );
    } on Object {
      return Err(_failure('renderer_unavailable', FailureCategory.dependency));
    }
  }
}

/// Built-in handwriting rendering definition using shared affine geometry.
final class HandwritingRenderingDefinition
    implements ObjectRenderingDefinition {
  /// Creates the definition with explicit payload and geometry limits.
  const HandwritingRenderingDefinition({
    required this.handwritingLimits,
    required this.geometryResolver,
    this.geometryCache,
  });

  /// Handwriting decode ceilings.
  final HandwritingLimits handwritingLimits;

  /// Shared geometry resolver.
  final StrokeGeometryResolver geometryResolver;

  /// Optional bounded cache shared with interaction subsystems.
  final HandwritingGeometryCache? geometryCache;

  @override
  ObjectTypeKey get typeKey => handwritingObjectTypeKey;

  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    if (object.typeKey != handwritingObjectTypeKey ||
        object.typeSchemaVersion != handwritingSchemaVersion ||
        !layerOpacity.isFinite ||
        layerOpacity < 0 ||
        layerOpacity > 1) {
      return Err(_failure('invalid_object', FailureCategory.validation));
    }
    final prepared = geometryCache?.prepare(
      object: object,
      handwritingLimits: handwritingLimits,
      geometryResolver: geometryResolver,
    );
    final decoded = prepared == null
        ? HandwritingPayload.decode(object.payload, limits: handwritingLimits)
        : prepared.map((value) => value.payload);
    if (decoded is Err<HandwritingPayload, StructuredFailure>) {
      return Err(_failure('invalid_object', FailureCategory.validation));
    }
    final primitives = <ScenePrimitive>[];
    final payload =
        (decoded as Ok<HandwritingPayload, StructuredFailure>).value;
    for (
      var strokeIndex = 0;
      strokeIndex < payload.strokes.length;
      strokeIndex += 1
    ) {
      final stroke = payload.strokes[strokeIndex];
      final geometry =
          prepared is Ok<PreparedHandwritingGeometry, StructuredFailure>
          ? Ok<TransformedStrokeGeometry, StructuredFailure>(
              prepared.value.geometries[strokeIndex],
            )
          : geometryResolver.resolve(
              stroke: stroke,
              localToPage: object.transform,
            );
      if (geometry is Err<TransformedStrokeGeometry, StructuredFailure>) {
        return Err(
          _failure('geometry_unavailable', FailureCategory.dependency),
        );
      }
      final color = RenderColor.create(stroke.style.argb);
      if (color is Err<RenderColor, StructuredFailure>) return Err(color.error);
      for (final element
          in (geometry as Ok<TransformedStrokeGeometry, StructuredFailure>)
              .value
              .elements) {
        if (primitives.length >= limits.maximumPrimitives) {
          return Err(_failure('primitive_limit', FailureCategory.resource));
        }
        final viewPoints = <Point2>[];
        for (final point in element.vertices) {
          final view = viewport.pageToView(point);
          if (view is Err<ViewPoint, StructuredFailure>) {
            return Err(
              _failure('viewport_unavailable', FailureCategory.dependency),
            );
          }
          final value = (view as Ok<ViewPoint, StructuredFailure>).value;
          viewPoints.add(_point(value.x, value.y));
        }
        final primitive = FilledPolygonPrimitive.create(
          plane: plane,
          opacity: layerOpacity * stroke.style.opacity,
          color: (color as Ok<RenderColor, StructuredFailure>).value,
          points: viewPoints,
          maximumPoints: limits.maximumPointsPerPrimitive,
        );
        if (primitive is Err<FilledPolygonPrimitive, StructuredFailure>)
          return Err(primitive.error);
        primitives.add(
          (primitive as Ok<FilledPolygonPrimitive, StructuredFailure>).value,
        );
      }
    }
    return Ok(List.unmodifiable(primitives));
  }
}

/// Immutable generation-tagged portable scene.
final class RenderSnapshot {
  RenderSnapshot._({
    required this.documentRevision,
    required this.viewportRevision,
    required this.pageClip,
    required List<ScenePrimitive> primitives,
    required List<Rect2> damageRegions,
  }) : primitives = List.unmodifiable(primitives),
       damageRegions = List.unmodifiable(damageRegions);

  /// Validates and captures a complete bounded scene.
  static Result<RenderSnapshot, StructuredFailure> create({
    required Revision documentRevision,
    required Revision viewportRevision,
    required Rect2 pageClip,
    required Iterable<ScenePrimitive> primitives,
    required Iterable<Rect2> damageRegions,
    required RenderingLimits limits,
  }) {
    final capturedPrimitives = _capture(
      primitives,
      limits.maximumPrimitives,
      'primitive_count',
    );
    final capturedDamage = _capture(
      damageRegions,
      limits.maximumDamageRegions,
      'damage_count',
    );
    if (capturedPrimitives is Err<List<ScenePrimitive>, StructuredFailure>)
      return Err(capturedPrimitives.error);
    if (capturedDamage is Err<List<Rect2>, StructuredFailure>)
      return Err(capturedDamage.error);
    final values =
        (capturedPrimitives as Ok<List<ScenePrimitive>, StructuredFailure>)
            .value;
    if (values.where((value) => value.plane == RenderPlane.toolPreview).length >
            limits.maximumPreviewOverlays ||
        values.where((value) => value.plane == RenderPlane.selection).length >
            limits.maximumSelectionOverlays) {
      return Err(_failure('overlay_limit', FailureCategory.resource));
    }
    return Ok(
      RenderSnapshot._(
        documentRevision: documentRevision,
        viewportRevision: viewportRevision,
        pageClip: pageClip,
        primitives: values,
        damageRegions:
            (capturedDamage as Ok<List<Rect2>, StructuredFailure>).value,
      ),
    );
  }

  /// Authoritative document revision evidence.
  final Revision documentRevision;

  /// Temporary viewport revision evidence.
  final Revision viewportRevision;

  /// View-space Page clip.
  final Rect2 pageClip;

  /// Primitives in authoritative order followed by overlay planes.
  final List<ScenePrimitive> primitives;

  /// View-space repaint damage.
  final List<Rect2> damageRegions;
}

/// Immutable committed primitives grouped by their authoritative Object ID.
final class CommittedObjectScene {
  /// Creates immutable Object-local committed rendering evidence.
  CommittedObjectScene._({
    required this.objectId,
    required Iterable<ScenePrimitive> primitives,
  }) : primitives = List<ScenePrimitive>.unmodifiable(primitives);

  /// Identity of the Object that produced [primitives].
  final ObjectId objectId;

  /// Committed primitives produced for this Object in registry order.
  final List<ScenePrimitive> primitives;
}

/// Immutable view-local committed scene that can be composed with overlays.
final class CommittedPageScene {
  /// Creates immutable committed evidence produced by [PageSceneBuilder].
  CommittedPageScene._({
    required this.documentRevision,
    required this.viewportRevision,
    required this.pageClip,
    required Iterable<CommittedObjectScene> objects,
  }) : objects = List<CommittedObjectScene>.unmodifiable(objects);

  /// Authoritative document revision used to render this scene.
  final Revision documentRevision;

  /// Viewport revision used to render this scene.
  final Revision viewportRevision;

  /// View-space Page clip used for committed rendering.
  final Rect2 pageClip;

  /// Bounded Object-to-primitive evidence in Page/Layer/Object order.
  final List<CommittedObjectScene> objects;
}

/// Pure scene builder using Object and Rendering registries.
final class PageSceneBuilder {
  /// Creates a builder with explicit registries and limits.
  const PageSceneBuilder({
    required this.objectRegistry,
    required this.renderingRegistry,
    required this.limits,
  });

  /// Authoritative Object validity registry.
  final ObjectRegistry objectRegistry;

  /// Rendering behavior registry.
  final RenderingRegistry renderingRegistry;

  /// Scene ceilings.
  final RenderingLimits limits;

  /// Builds committed content and bounded temporary overlays.
  Result<RenderSnapshot, StructuredFailure> build({
    required DocumentPage page,
    required ViewportSnapshot viewport,
    required Revision documentRevision,
    Iterable<ScenePrimitive> previews = const [],
    Iterable<ScenePrimitive> selections = const [],
    Iterable<ObjectId> excludedObjectIds = const [],
  }) {
    final committed = buildCommitted(
      page: page,
      viewport: viewport,
      documentRevision: documentRevision,
    );
    if (committed is Err<CommittedPageScene, StructuredFailure>) {
      return Err(committed.error);
    }
    return compose(
      committed: (committed as Ok<CommittedPageScene, StructuredFailure>).value,
      previews: previews,
      selections: selections,
      excludedObjectIds: excludedObjectIds,
    );
  }

  /// Builds bounded committed rendering without transient overlay evidence.
  Result<CommittedPageScene, StructuredFailure> buildCommitted({
    required DocumentPage page,
    required ViewportSnapshot viewport,
    required Revision documentRevision,
  }) {
    final origin = viewport
        .pageToView(_point(0, 0))
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    final far = viewport
        .pageToView(_point(page.size.width, page.size.height))
        .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
    if (origin == null || far == null) {
      return Err(_failure('invalid_clip', FailureCategory.validation));
    }
    final clip = _rect(
      math.min(origin.x, far.x),
      math.min(origin.y, far.y),
      math.max(origin.x, far.x),
      math.max(origin.y, far.y),
    );
    final objects = <CommittedObjectScene>[];
    var primitiveCount = 0;
    for (final layer in page.layers) {
      if (layer is! ContentLayer) continue;
      if (!layer.visible || layer.opacity == 0) continue;
      for (final object in layer.objects) {
        if (!object.visible) continue;
        if (object.typeKey == handwritingObjectTypeKey &&
            object.typeSchemaVersion != handwritingSchemaVersion) {
          continue;
        }
        final resolution = objectRegistry.resolve(object);
        if (resolution is! SupportedObjectResolution) continue;
        final definition = renderingRegistry.definitions[object.typeKey];
        if (definition == null) continue;
        final objectPrimitives = <ScenePrimitive>[];
        final rendered = definition.render(
          object: object,
          viewport: viewport,
          layerOpacity: layer.opacity,
          plane: RenderPlane.committed,
          limits: limits,
        );
        if (rendered is Ok<List<ScenePrimitive>, StructuredFailure>) {
          for (final primitive in rendered.value) {
            if (_intersects(primitive.bounds, clip)) {
              objectPrimitives.add(primitive);
            }
          }
        } else {
          final placeholderBounds = _safePlaceholderBounds(
            resolution,
            viewport,
          );
          if (placeholderBounds != null) {
            final placeholder = PlaceholderPrimitive.create(
              plane: RenderPlane.committed,
              bounds: placeholderBounds,
              opacity: layer.opacity,
            );
            if (placeholder is Ok<PlaceholderPrimitive, StructuredFailure>) {
              objectPrimitives.add(placeholder.value);
            }
          }
        }
        if (objectPrimitives.isNotEmpty) {
          primitiveCount += objectPrimitives.length;
          if (primitiveCount > limits.maximumPrimitives) {
            return Err(_failure('primitive_count', FailureCategory.resource));
          }
          objects.add(
            CommittedObjectScene._(
              objectId: object.id,
              primitives: objectPrimitives,
            ),
          );
        }
      }
    }
    return Ok(
      CommittedPageScene._(
        documentRevision: documentRevision,
        viewportRevision: viewport.revision,
        pageClip: clip,
        objects: objects,
      ),
    );
  }

  /// Composes cached committed evidence with bounded exclusions and overlays.
  Result<RenderSnapshot, StructuredFailure> compose({
    required CommittedPageScene committed,
    Iterable<ScenePrimitive> previews = const [],
    Iterable<ScenePrimitive> selections = const [],
    Iterable<ObjectId> excludedObjectIds = const [],
  }) {
    final capturedPreviews = _capture(
      previews,
      limits.maximumPreviewOverlays,
      'preview_count',
    );
    final capturedSelections = _capture(
      selections,
      limits.maximumSelectionOverlays,
      'selection_count',
    );
    if (capturedPreviews is Err<List<ScenePrimitive>, StructuredFailure>)
      return Err(capturedPreviews.error);
    if (capturedSelections is Err<List<ScenePrimitive>, StructuredFailure>)
      return Err(capturedSelections.error);
    final capturedExclusions = _capture(
      excludedObjectIds,
      limits.maximumPrimitives,
      'exclusion_count',
    );
    if (capturedExclusions is Err<List<ObjectId>, StructuredFailure>) {
      return Err(capturedExclusions.error);
    }
    final previewValues =
        (capturedPreviews as Ok<List<ScenePrimitive>, StructuredFailure>).value;
    final selectionValues =
        (capturedSelections as Ok<List<ScenePrimitive>, StructuredFailure>)
            .value;
    final exclusions =
        (capturedExclusions as Ok<List<ObjectId>, StructuredFailure>).value
            .toSet();
    if (previewValues.any((value) => value.plane != RenderPlane.toolPreview) ||
        selectionValues.any((value) => value.plane != RenderPlane.selection)) {
      return Err(_failure('invalid_overlay_plane', FailureCategory.validation));
    }
    final primitives = <ScenePrimitive>[];
    for (final object in committed.objects) {
      if (!exclusions.contains(object.objectId)) {
        primitives.addAll(object.primitives);
      }
    }
    primitives.addAll(previewValues);
    primitives.addAll(selectionValues);
    return RenderSnapshot.create(
      documentRevision: committed.documentRevision,
      viewportRevision: committed.viewportRevision,
      pageClip: committed.pageClip,
      primitives: primitives,
      damageRegions: primitives.map((value) => value.bounds),
      limits: limits,
    );
  }

  /// Composes only bounded transient overlays over a committed Page clip.
  Result<RenderSnapshot, StructuredFailure> composeOverlays({
    required CommittedPageScene committed,
    Iterable<ScenePrimitive> previews = const [],
    Iterable<ScenePrimitive> selections = const [],
  }) {
    final capturedPreviews = _capture(
      previews,
      limits.maximumPreviewOverlays,
      'preview_count',
    );
    final capturedSelections = _capture(
      selections,
      limits.maximumSelectionOverlays,
      'selection_count',
    );
    if (capturedPreviews is Err<List<ScenePrimitive>, StructuredFailure>) {
      return Err(capturedPreviews.error);
    }
    if (capturedSelections is Err<List<ScenePrimitive>, StructuredFailure>) {
      return Err(capturedSelections.error);
    }
    final previewValues =
        (capturedPreviews as Ok<List<ScenePrimitive>, StructuredFailure>).value;
    final selectionValues =
        (capturedSelections as Ok<List<ScenePrimitive>, StructuredFailure>)
            .value;
    if (previewValues.any((value) => value.plane != RenderPlane.toolPreview) ||
        selectionValues.any((value) => value.plane != RenderPlane.selection)) {
      return Err(_failure('invalid_overlay_plane', FailureCategory.validation));
    }
    final primitives = <ScenePrimitive>[...previewValues, ...selectionValues];
    return RenderSnapshot.create(
      documentRevision: committed.documentRevision,
      viewportRevision: committed.viewportRevision,
      pageClip: committed.pageClip,
      primitives: primitives,
      damageRegions: primitives.map((value) => value.bounds),
      limits: limits,
    );
  }
}

Rect2? _safePlaceholderBounds(
  SupportedObjectResolution resolution,
  ViewportSnapshot viewport,
) {
  try {
    final local = resolution.definition
        .intrinsicGeometry(
          resolution.envelope.payload,
          resolution.envelope.typeSchemaVersion,
        )
        .fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
    if (local == null) return null;
    final corners = <Point2>[
      local.topLeft,
      _point(local.right, local.top),
      local.bottomRight,
      _point(local.left, local.bottom),
    ];
    final view = <Point2>[];
    for (final corner in corners) {
      final page = resolution.envelope.transform
          .applyToPoint(corner)
          .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
      final converted = page == null
          ? null
          : viewport
                .pageToView(page)
                .fold<ViewPoint?>(onOk: (value) => value, onErr: (_) => null);
      if (converted == null) return null;
      view.add(_point(converted.x, converted.y));
    }
    return _bounds(view);
  } on Object {
    return null;
  }
}

Result<List<T>, StructuredFailure> _capture<T>(
  Iterable<T> source,
  int maximum,
  String leaf,
) {
  if (maximum < 0 || maximum > Revision.maximumValue) {
    return Err(_failure('invalid_limit', FailureCategory.validation));
  }
  final values = <T>[];
  try {
    final iterator = source.iterator;
    while (true) {
      final next = iterator.moveNext();
      if (!next) break;
      if (values.length >= maximum) {
        return Err(_failure(leaf, FailureCategory.resource));
      }
      values.add(iterator.current);
    }
  } on Object {
    return Err(_failure('invalid_iterable', FailureCategory.dependency));
  }
  return Ok(List.unmodifiable(values));
}

Rect2? _bounds(List<Point2> points) {
  if (points.isEmpty) return null;
  var left = points.first.x, right = left, top = points.first.y, bottom = top;
  for (final point in points.skip(1)) {
    left = math.min(left, point.x);
    right = math.max(right, point.x);
    top = math.min(top, point.y);
    bottom = math.max(bottom, point.y);
  }
  return Rect2.fromEdges(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
}

bool _intersects(Rect2 first, Rect2 second) =>
    first.right >= second.left &&
    first.left <= second.right &&
    first.bottom >= second.top &&
    first.top <= second.bottom;
Point2 _point(double x, double y) =>
    (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;
Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
            as Ok<Rect2, StructuredFailure>)
        .value;
StructuredFailure _failure(String leaf, FailureCategory category) =>
    StructuredFailure(
      code: 'drawing.renderer.$leaf',
      category: category,
      retryDisposition: RetryDisposition.never,
      message: 'Rendering data or behavior is invalid or unavailable.',
    );
