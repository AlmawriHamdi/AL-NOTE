// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/geometry/geometry_values.dart';
import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';
import '../../core/versioning/revision.dart';

/// Immutable strictly positive logical-pixel view extent.
final class ViewExtent {
  const ViewExtent._(this.width, this.height);

  /// Creates a finite, nonempty view extent.
  static Result<ViewExtent, StructuredFailure> create({
    required double width,
    required double height,
  }) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return Err(_failure('invalid_extent'));
    }
    return Ok(ViewExtent._(width, height));
  }

  /// Logical-pixel width.
  final double width;

  /// Logical-pixel height.
  final double height;

  @override
  bool operator ==(Object other) =>
      other is ViewExtent && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// Immutable validated viewport conversion snapshot.
final class ViewportSnapshot {
  const ViewportSnapshot._({
    required this.extent,
    required this.pageOrigin,
    required this.zoom,
    required this.minimumZoom,
    required this.maximumZoom,
    required this.revision,
  });

  /// Creates a finite invertible viewport with injected zoom range.
  static Result<ViewportSnapshot, StructuredFailure> create({
    required ViewExtent extent,
    required Point2 pageOrigin,
    required double zoom,
    required double minimumZoom,
    required double maximumZoom,
    required Revision revision,
  }) {
    if (!zoom.isFinite ||
        !minimumZoom.isFinite ||
        !maximumZoom.isFinite ||
        minimumZoom <= 0 ||
        maximumZoom < minimumZoom ||
        zoom < minimumZoom ||
        zoom > maximumZoom) {
      return Err(_failure('invalid_zoom'));
    }
    return Ok(
      ViewportSnapshot._(
        extent: extent,
        pageOrigin: pageOrigin,
        zoom: zoom,
        minimumZoom: minimumZoom,
        maximumZoom: maximumZoom,
        revision: revision,
      ),
    );
  }

  /// Current logical-pixel extent.
  final ViewExtent extent;

  /// Page-space coordinate located at view origin.
  final Point2 pageOrigin;

  /// Strictly positive logical pixels per Page unit.
  final double zoom;

  /// Injected minimum zoom.
  final double minimumZoom;

  /// Injected maximum zoom.
  final double maximumZoom;

  /// Monotonic temporary revision.
  final Revision revision;

  /// Converts Page coordinates to view logical pixels.
  Result<ViewPoint, StructuredFailure> pageToView(Point2 page) =>
      ViewPoint.create(
        x: (page.x - pageOrigin.x) * zoom,
        y: (page.y - pageOrigin.y) * zoom,
      );

  /// Converts view logical pixels to Page coordinates.
  Result<Point2, StructuredFailure> viewToPage(ViewPoint view) => Point2.create(
    x: pageOrigin.x + view.x / zoom,
    y: pageOrigin.y + view.y / zoom,
  );

  /// Converts a nonnegative finite view tolerance to Page units.
  Result<double, StructuredFailure> viewToleranceToPage(double pixels) {
    if (!pixels.isFinite || pixels < 0 || !(pixels / zoom).isFinite)
      return Err(_failure('invalid_tolerance'));
    return Ok(pixels / zoom);
  }

  /// Visible Page-space rectangle.
  Rect2 get visiblePageRect => _rect(
    pageOrigin.x,
    pageOrigin.y,
    pageOrigin.x + extent.width / zoom,
    pageOrigin.y + extent.height / zoom,
  );

  /// Returns a translated snapshot if [expectedRevision] is current.
  Result<ViewportSnapshot, StructuredFailure> translated({
    required Vector2 pageDelta,
    required Revision expectedRevision,
  }) {
    if (expectedRevision != revision) return Err(_failure('stale_revision'));
    final next = revision.increment().fold<Revision?>(
      onOk: (value) => value,
      onErr: (_) => null,
    );
    final origin = pageOrigin
        .added(pageDelta)
        .fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    if (next == null || origin == null)
      return Err(_failure('revision_or_coordinate_overflow'));
    return create(
      extent: extent,
      pageOrigin: origin,
      zoom: zoom,
      minimumZoom: minimumZoom,
      maximumZoom: maximumZoom,
      revision: next,
    );
  }

  /// Zooms while keeping the Page point beneath [viewPivot] fixed.
  Result<ViewportSnapshot, StructuredFailure> zoomedAbout({
    required double newZoom,
    required ViewPoint viewPivot,
    required Revision expectedRevision,
  }) {
    if (expectedRevision != revision) return Err(_failure('stale_revision'));
    if (!newZoom.isFinite || newZoom < minimumZoom || newZoom > maximumZoom)
      return Err(_failure('invalid_zoom'));
    final fixed = viewToPage(
      viewPivot,
    ).fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    final next = revision.increment().fold<Revision?>(
      onOk: (value) => value,
      onErr: (_) => null,
    );
    if (fixed == null || next == null)
      return Err(_failure('revision_or_coordinate_overflow'));
    final origin = Point2.create(
      x: fixed.x - viewPivot.x / newZoom,
      y: fixed.y - viewPivot.y / newZoom,
    ).fold<Point2?>(onOk: (value) => value, onErr: (_) => null);
    if (origin == null) return Err(_failure('invalid_conversion'));
    return create(
      extent: extent,
      pageOrigin: origin,
      zoom: newZoom,
      minimumZoom: minimumZoom,
      maximumZoom: maximumZoom,
      revision: next,
    );
  }

  /// Explicit-tolerance comparison of numeric viewport state.
  Result<bool, StructuredFailure> approximatelyEquals(
    ViewportSnapshot other, {
    required double tolerance,
  }) {
    if (!tolerance.isFinite || tolerance <= 0)
      return Err(_failure('invalid_tolerance'));
    return Ok(
      (extent.width - other.extent.width).abs() <= tolerance &&
          (extent.height - other.extent.height).abs() <= tolerance &&
          (pageOrigin.x - other.pageOrigin.x).abs() <= tolerance &&
          (pageOrigin.y - other.pageOrigin.y).abs() <= tolerance &&
          (zoom - other.zoom).abs() <= tolerance,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewportSnapshot &&
      other.extent == extent &&
      other.pageOrigin == pageOrigin &&
      other.zoom == zoom &&
      other.minimumZoom == minimumZoom &&
      other.maximumZoom == maximumZoom &&
      other.revision == revision;

  @override
  int get hashCode =>
      Object.hash(extent, pageOrigin, zoom, minimumZoom, maximumZoom, revision);
}

/// Idempotent listener-removal token.
final class ViewportListenerRegistration {
  ViewportListenerRegistration._(this._remove);
  void Function()? _remove;

  /// Removes the listener once; later calls do nothing.
  void remove() {
    final callback = _remove;
    _remove = null;
    callback?.call();
  }
}

/// Bounded nonglobal observable viewport controller.
final class ViewportController {
  /// Creates a controller with an explicit listener ceiling.
  ViewportController({
    required ViewportSnapshot initial,
    required this.maximumListeners,
  }) : _value = initial;

  ViewportSnapshot _value;
  final List<void Function(ViewportSnapshot)> _listeners = [];

  /// Maximum simultaneous listeners.
  final int maximumListeners;

  /// Current immutable snapshot.
  ViewportSnapshot get value => _value;

  /// Registers a listener under the injected ceiling.
  Result<ViewportListenerRegistration, StructuredFailure> addListener(
    void Function(ViewportSnapshot) listener,
  ) {
    if (maximumListeners < 0 || _listeners.length >= maximumListeners)
      return Err(_failure('listener_limit'));
    _listeners.add(listener);
    return Ok(
      ViewportListenerRegistration._(() => _listeners.remove(listener)),
    );
  }

  /// Publishes a snapshot only when it directly advances the current revision.
  Result<ViewportSnapshot, StructuredFailure> publish(ViewportSnapshot next) {
    final expected = _value.revision.increment().fold<Revision?>(
      onOk: (value) => value,
      onErr: (_) => null,
    );
    if (expected == null || next.revision != expected)
      return Err(_failure('stale_revision'));
    _value = next;
    for (final listener in List<void Function(ViewportSnapshot)>.of(
      _listeners,
    )) {
      try {
        listener(next);
      } on Object {
        /* observer isolation */
      }
    }
    return Ok(next);
  }
}

extension on Point2 {
  Result<Point2, StructuredFailure> added(Vector2 delta) =>
      Point2.create(x: x + delta.x, y: y + delta.y);
}

Rect2 _rect(double left, double top, double right, double bottom) =>
    (Rect2.fromEdges(left: left, top: top, right: right, bottom: bottom)
            as Ok<Rect2, StructuredFailure>)
        .value;

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'drawing.viewport.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Viewport input is invalid.',
);
