// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import '../../core/geometry/geometry_values.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../documents/document_model.dart';
import '../viewport.dart';
import 'rendering_scene.dart';

/// Built-in Image rendering definition producing a semantic decode primitive.
final class ImageRenderingDefinition implements ObjectRenderingDefinition {
  /// Creates a definition with explicit image limits.
  const ImageRenderingDefinition(this.imageLimits);

  /// Image payload limits.
  final ImageLimits imageLimits;
  @override
  ObjectTypeKey get typeKey => imageObjectTypeKey;
  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    final payload = ImagePayload.decode(object.payload, limits: imageLimits);
    if (object.typeKey != imageObjectTypeKey ||
        object.typeSchemaVersion != imageSchemaVersion ||
        payload is! Ok<ImagePayload, StructuredFailure>)
      return Err(_failure('invalid_image'));
    final transform = _localToView(object, viewport);
    final bounds = _viewBounds(payload.value.bounds, object, viewport);
    if (transform == null || bounds == null)
      return Err(_failure('transform_unavailable'));
    final primitive = ImageBoxPrimitive.create(
      plane: plane,
      bounds: bounds,
      opacity: layerOpacity,
      payload: payload.value,
      localToViewCoefficients: transform,
    );
    return primitive is Ok<ImageBoxPrimitive, StructuredFailure>
        ? Ok(List<ScenePrimitive>.unmodifiable([primitive.value]))
        : Err(_failure('primitive_unavailable'));
  }
}

/// Built-in Text rendering definition producing a semantic layout primitive.
final class TextRenderingDefinition implements ObjectRenderingDefinition {
  /// Creates a definition with explicit Text limits.
  const TextRenderingDefinition(this.textLimits, this.layoutEngine);

  /// Text payload and layout limits.
  final TextLimits textLimits;

  /// Shared bounded layout authority.
  final TextLayoutEngine layoutEngine;
  @override
  ObjectTypeKey get typeKey => textObjectTypeKey;
  @override
  Result<List<ScenePrimitive>, StructuredFailure> render({
    required ObjectEnvelope object,
    required ViewportSnapshot viewport,
    required double layerOpacity,
    required RenderPlane plane,
    required RenderingLimits limits,
  }) {
    final payload = TextPayload.decode(object.payload, limits: textLimits);
    if (object.typeKey != textObjectTypeKey ||
        object.typeSchemaVersion != textSchemaVersion ||
        payload is! Ok<TextPayload, StructuredFailure>)
      return Err(_failure('invalid_text'));
    final layout = layoutEngine.layout(
      TextLayoutRequest(payload: payload.value),
    );
    if (layout is! Ok<TextLayoutSnapshot, StructuredFailure>) {
      return Err(_failure('layout_unavailable'));
    }
    final transform = _localToView(object, viewport);
    final bounds = _viewBounds(layout.value.visualBounds, object, viewport);
    if (transform == null || bounds == null)
      return Err(_failure('transform_unavailable'));
    final primitive = TextBoxPrimitive.create(
      plane: plane,
      bounds: bounds,
      opacity: layerOpacity,
      payload: payload.value,
      layout: layout.value,
      localToViewCoefficients: transform,
    );
    return primitive is Ok<TextBoxPrimitive, StructuredFailure>
        ? Ok(List<ScenePrimitive>.unmodifiable([primitive.value]))
        : Err(_failure('primitive_unavailable'));
  }
}

List<double>? _localToView(ObjectEnvelope object, ViewportSnapshot viewport) {
  final c = object.transform.storageCoefficients;
  final values = <double>[
    c[0] * viewport.zoom,
    c[1] * viewport.zoom,
    c[2] * viewport.zoom,
    c[3] * viewport.zoom,
    (c[4] - viewport.pageOrigin.x) * viewport.zoom,
    (c[5] - viewport.pageOrigin.y) * viewport.zoom,
  ];
  return values.every((value) => value.isFinite)
      ? List.unmodifiable(values)
      : null;
}

Rect2? _viewBounds(
  Rect2 local,
  ObjectEnvelope object,
  ViewportSnapshot viewport,
) {
  final points = <Point2>[
    local.topLeft,
    _point(local.right, local.top),
    local.bottomRight,
    _point(local.left, local.bottom),
  ];
  final view = <Point2>[];
  for (final point in points) {
    final page = object.transform.applyToPoint(point);
    if (page is! Ok<Point2, StructuredFailure>) return null;
    final converted = viewport.pageToView(page.value);
    if (converted is! Ok<ViewPoint, StructuredFailure>) return null;
    view.add(_point(converted.value.x, converted.value.y));
  }
  var left = view.first.x, right = left, top = view.first.y, bottom = top;
  for (final point in view.skip(1)) {
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

Point2 _point(double x, double y) =>
    (Point2.create(x: x, y: y) as Ok<Point2, StructuredFailure>).value;
StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.content.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Object rendering is invalid or unavailable.',
);
