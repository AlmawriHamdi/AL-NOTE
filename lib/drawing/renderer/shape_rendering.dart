// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/affine_transform_2d.dart';
import '../../core/geometry/geometry_values.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../documents/document_model.dart';
import '../viewport.dart';
import 'rendering_scene.dart';

extension<T, E> on Result<T, E> {
  E get error => (this as Err<T, E>).error;
}

/// Built-in Shape rendering from AL NOTE-owned authoritative geometry.
final class ShapeRenderingDefinition implements ObjectRenderingDefinition {
  /// Creates a renderer with explicit payload and curve-work limits.
  const ShapeRenderingDefinition({required this.shapeLimits});

  final ShapeLimits shapeLimits;
  @override
  ObjectTypeKey get typeKey => shapeObjectTypeKey;

  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    if (object.typeKey != shapeObjectTypeKey ||
        object.typeSchemaVersion != shapeSchemaVersion) {
      return Err(_failure('invalid_object'));
    }
    final decoded = ShapePayload.decode(object.payload, limits: shapeLimits);
    if (decoded is! Ok<ShapePayload, StructuredFailure>) {
      return Err(_failure('invalid_object'));
    }
    return renderTransient(
      payload: decoded.value,
      localToPage: object.transform,
      viewport: viewport,
      layerOpacity: layerOpacity,
      plane: plane,
      limits: limits,
    );
  }

  /// Renders validated view-local Shape evidence without an Object identity.
  Result<List<ScenePrimitive>, StructuredFailure> renderTransient({
    required ShapePayload payload,
    required AffineTransform2D localToPage,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    if (!layerOpacity.isFinite ||
        layerOpacity < 0 ||
        layerOpacity > 1 ||
        shapeCurveSegmentsFor(shapeLimits) > limits.maximumPointsPerPrimitive) {
      return Err(_failure('invalid_object'));
    }
    final derived = ShapeDerivedGeometry.derive(
      payload: payload,
      shapeLimits: shapeLimits,
      curveSegments: shapeCurveSegmentsFor(shapeLimits),
    );
    if (derived is! Ok<ShapeDerivedGeometry, StructuredFailure>) {
      return Err(derived.error);
    }
    final localToView = _localToView(localToPage, viewport);
    if (localToView == null) return Err(_failure('transform_unavailable'));
    final opacity = layerOpacity * payload.style.opacity;
    final primitives = <ScenePrimitive>[];
    if (opacity == 0) return const Ok([]);

    if (derived.value.fillPath.isNotEmpty) {
      final added = _addPolygon(
        primitives,
        derived.value.fillPath,
        payload.style.fillColor.argb,
        payload.style.fillRule == ShapeFillRule.evenOdd
            ? RenderFillRule.evenOdd
            : RenderFillRule.nonZero,
        localToPage,
        viewport,
        localToView,
        plane,
        opacity,
        limits,
      );
      if (added is Err<void, StructuredFailure>) return Err(added.error);
    }
    if (derived.value.strokePolygons.isNotEmpty) {
      final added = _addPolygonGroup(
        primitives,
        derived.value.strokePolygons,
        payload.style.strokeColor.argb,
        localToPage,
        viewport,
        localToView,
        plane,
        opacity,
        limits,
        _shapeGroupTotalPointLimit(shapeLimits),
      );
      if (added is Err<void, StructuredFailure>) return Err(added.error);
    }
    return Ok(List<ScenePrimitive>.unmodifiable(primitives));
  }
}

Result<void, StructuredFailure> _addPolygonGroup(
  List<ScenePrimitive> output,
  List<List<Point2>> contours,
  int argb,
  AffineTransform2D localToPage,
  ViewportSnapshot viewport,
  List<double> localToView,
  RenderPlane plane,
  double opacity,
  RenderingLimits limits,
  int maximumTotalPoints,
) {
  if (output.length >= limits.maximumPrimitives ||
      contours.length > limits.maximumPrimitives ||
      contours.any(
        (contour) => contour.length > limits.maximumPointsPerPrimitive,
      )) {
    return Err(_failure('primitive_limit'));
  }
  final color = RenderColor.create(argb);
  final bounds = _viewContourBounds(contours, localToPage, viewport);
  if (color is! Ok<RenderColor, StructuredFailure> || bounds == null) {
    return Err(_failure('transform_unavailable'));
  }
  final primitive = FilledPolygonGroupPrimitive.create(
    plane: plane,
    opacity: opacity,
    color: color.value,
    contours: contours,
    maximumContours: limits.maximumPrimitives,
    maximumPointsPerContour: limits.maximumPointsPerPrimitive,
    maximumTotalPoints: maximumTotalPoints,
    localToViewCoefficients: localToView,
    transformedBounds: bounds,
  );
  if (primitive is! Ok<FilledPolygonGroupPrimitive, StructuredFailure>) {
    return Err(_failure('primitive_unavailable'));
  }
  output.add(primitive.value);
  return const Ok(null);
}

int _shapeGroupTotalPointLimit(ShapeLimits limits) {
  final curveSegments = shapeCurveSegmentsFor(limits);
  if (limits.maximumDerivedSegments >
      FilledPolygonGroupPrimitive.maximumSupportedTotalPoints ~/
          curveSegments) {
    return FilledPolygonGroupPrimitive.maximumSupportedTotalPoints;
  }
  return limits.maximumDerivedSegments * curveSegments;
}

Result<void, StructuredFailure> _addPolygon(
  List<ScenePrimitive> output,
  List<Point2> points,
  int argb,
  RenderFillRule fillRule,
  AffineTransform2D localToPage,
  ViewportSnapshot viewport,
  List<double> localToView,
  RenderPlane plane,
  double opacity,
  RenderingLimits limits,
) {
  if (output.length >= limits.maximumPrimitives ||
      points.length > limits.maximumPointsPerPrimitive) {
    return Err(_failure('primitive_limit'));
  }
  final color = RenderColor.create(argb);
  final bounds = _viewBounds(points, localToPage, viewport);
  if (color is! Ok<RenderColor, StructuredFailure> || bounds == null) {
    return Err(_failure('transform_unavailable'));
  }
  final primitive = FilledPolygonPrimitive.create(
    plane: plane,
    opacity: opacity,
    color: color.value,
    fillRule: fillRule,
    points: points,
    maximumPoints: limits.maximumPointsPerPrimitive,
    localToViewCoefficients: localToView,
    transformedBounds: bounds,
  );
  if (primitive is! Ok<FilledPolygonPrimitive, StructuredFailure>) {
    return Err(_failure('primitive_unavailable'));
  }
  output.add(primitive.value);
  return const Ok(null);
}

List<double>? _localToView(
  AffineTransform2D localToPage,
  ViewportSnapshot viewport,
) {
  final c = localToPage.storageCoefficients;
  final values = <double>[
    c[0] * viewport.zoom,
    c[1] * viewport.zoom,
    c[2] * viewport.zoom,
    c[3] * viewport.zoom,
    (c[4] - viewport.pageOrigin.x) * viewport.zoom,
    (c[5] - viewport.pageOrigin.y) * viewport.zoom,
  ];
  return values.every((value) => value.isFinite)
      ? List<double>.unmodifiable(values)
      : null;
}

Rect2? _viewBounds(
  List<Point2> points,
  AffineTransform2D localToPage,
  ViewportSnapshot viewport,
) {
  if (points.isEmpty) return null;
  double? left, right, top, bottom;
  for (final point in points) {
    final page = localToPage.applyToPoint(point);
    if (page is! Ok<Point2, StructuredFailure>) return null;
    final view = viewport.pageToView(page.value);
    if (view is! Ok<ViewPoint, StructuredFailure>) return null;
    left = left == null || view.value.x < left ? view.value.x : left;
    right = right == null || view.value.x > right ? view.value.x : right;
    top = top == null || view.value.y < top ? view.value.y : top;
    bottom = bottom == null || view.value.y > bottom ? view.value.y : bottom;
  }
  return Rect2.fromEdges(
    left: left!,
    top: top!,
    right: right!,
    bottom: bottom!,
  ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
}

Rect2? _viewContourBounds(
  List<List<Point2>> contours,
  AffineTransform2D localToPage,
  ViewportSnapshot viewport,
) {
  double? left, right, top, bottom;
  for (final contour in contours) {
    for (final point in contour) {
      final page = localToPage.applyToPoint(point);
      if (page is! Ok<Point2, StructuredFailure>) return null;
      final view = viewport.pageToView(page.value);
      if (view is! Ok<ViewPoint, StructuredFailure>) return null;
      left = left == null || view.value.x < left ? view.value.x : left;
      right = right == null || view.value.x > right ? view.value.x : right;
      top = top == null || view.value.y < top ? view.value.y : top;
      bottom = bottom == null || view.value.y > bottom ? view.value.y : bottom;
    }
  }
  if (left == null) return null;
  return Rect2.fromEdges(
    left: left,
    top: top!,
    right: right!,
    bottom: bottom!,
  ).fold<Rect2?>(onOk: (value) => value, onErr: (_) => null);
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.shape.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Shape rendering is invalid or unavailable.',
);
