// SPDX-License-Identifier: GPL-3.0-or-later

import '../identity/namespaced_identifier.dart';
import '../outcomes/result.dart';
import '../outcomes/structured_failure.dart';
import '../versioning/revision.dart';

/// Immutable logical-pixel coordinate in a view, distinct from Page space.
final class ViewPoint {
  const ViewPoint._(this.x, this.y);

  /// Creates a finite view coordinate.
  static Result<ViewPoint, StructuredFailure> create({
    required double x,
    required double y,
  }) {
    if (!x.isFinite || !y.isFinite) return Err(_failure('invalid_view_point'));
    return Ok(ViewPoint._(x, y));
  }

  /// Horizontal logical pixels.
  final double x;

  /// Vertical logical pixels.
  final double y;

  @override
  bool operator ==(Object other) =>
      other is ViewPoint && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(ViewPoint, x, y);
}

/// Closed pointer-source family.
enum PointerSource { mouse, stylus, touch, unknown }

/// Closed stylus subtype evidence.
enum StylusSubtype { tip, eraser, unknown }

/// Closed normalized pointer phase.
enum PointerPhase { down, move, up, hover, cancel }

/// Closed cancellation reasons retained without platform payloads.
enum InteractionCancellationReason {
  captureLoss,
  focusLoss,
  suspension,
  pageChange,
  toolChange,
  invalidInput,
  resourceLimit,
  explicit,
}

/// Immutable normalized button state.
final class PointerButtons {
  /// Creates a nonnegative Web-safe bit field.
  const PointerButtons(this.bits);

  /// Portable button bits.
  final int bits;

  /// Primary-button evidence.
  bool get primary => bits & 1 != 0;
}

/// Immutable normalized modifier state.
final class InputModifiers {
  /// Creates modifier evidence.
  const InputModifiers({
    this.shift = false,
    this.control = false,
    this.alt = false,
    this.meta = false,
  });

  /// Shift is pressed.
  final bool shift;

  /// Control is pressed.
  final bool control;

  /// Alt is pressed.
  final bool alt;

  /// Meta is pressed.
  final bool meta;
}

/// Immutable normalized pointer input independent of Flutter/platform events.
final class NormalizedPointerEvent {
  const NormalizedPointerEvent._({
    required this.pointerId,
    required this.source,
    required this.stylusSubtype,
    required this.phase,
    required this.viewPosition,
    required this.buttons,
    required this.modifiers,
    required this.pressure,
    required this.tilt,
    required this.orientation,
    required this.timeMicros,
    required this.pressureSupported,
    required this.sensorConfidence,
    required this.cancellationReason,
  });

  /// Validates and creates a normalized event.
  static Result<NormalizedPointerEvent, StructuredFailure> create({
    required int pointerId,
    required PointerSource source,
    StylusSubtype stylusSubtype = StylusSubtype.unknown,
    required PointerPhase phase,
    required ViewPoint viewPosition,
    required PointerButtons buttons,
    InputModifiers modifiers = const InputModifiers(),
    double? pressure,
    double? tilt,
    double? orientation,
    required int timeMicros,
    bool pressureSupported = false,
    double sensorConfidence = 1,
    InteractionCancellationReason? cancellationReason,
  }) {
    if (pointerId < 0 ||
        pointerId > 9007199254740991 ||
        timeMicros < 0 ||
        timeMicros > 9007199254740991 ||
        buttons.bits < 0 ||
        buttons.bits > 9007199254740991 ||
        (pressure != null &&
            (!pressure.isFinite || pressure < 0 || pressure > 1)) ||
        (tilt != null &&
            (!tilt.isFinite ||
                tilt < -1.5707963267948966 ||
                tilt > 1.5707963267948966)) ||
        (orientation != null &&
            (!orientation.isFinite ||
                orientation < -6.283185307179586 ||
                orientation > 6.283185307179586)) ||
        !sensorConfidence.isFinite ||
        sensorConfidence < 0 ||
        sensorConfidence > 1 ||
        (phase == PointerPhase.cancel) != (cancellationReason != null))
      return Err(_failure('invalid_pointer_event'));
    return Ok(
      NormalizedPointerEvent._(
        pointerId: pointerId,
        source: source,
        stylusSubtype: stylusSubtype,
        phase: phase,
        viewPosition: viewPosition,
        buttons: buttons,
        modifiers: modifiers,
        pressure: pressure,
        tilt: tilt,
        orientation: orientation,
        timeMicros: timeMicros,
        pressureSupported: pressureSupported,
        sensorConfidence: sensorConfidence,
        cancellationReason: cancellationReason,
      ),
    );
  }

  /// Logical pointer identity.
  final int pointerId;

  /// Source family.
  final PointerSource source;

  /// Stylus subtype evidence.
  final StylusSubtype stylusSubtype;

  /// Normalized phase.
  final PointerPhase phase;

  /// View logical-pixel position.
  final ViewPoint viewPosition;

  /// Portable buttons.
  final PointerButtons buttons;

  /// Portable modifiers.
  final InputModifiers modifiers;

  /// Optional normalized pressure.
  final double? pressure;

  /// Optional tilt.
  final double? tilt;

  /// Optional orientation.
  final double? orientation;

  /// Monotonic source time.
  final int timeMicros;

  /// Whether pressure is a reported capability.
  final bool pressureSupported;

  /// Normalized sensor-confidence evidence.
  final double sensorConfidence;

  /// Cancellation reason, present exactly for cancel events.
  final InteractionCancellationReason? cancellationReason;
}

/// Stable namespaced interaction action identity.
final class InteractionActionId implements Comparable<InteractionActionId> {
  /// Creates from a validated identifier.
  const InteractionActionId.fromIdentifier(this.identifier);

  /// Parses a stable action identity.
  static Result<InteractionActionId, StructuredFailure> parse(String value) =>
      NamespacedIdentifier.parse(value).map(InteractionActionId.fromIdentifier);

  /// Wrapped identifier.
  final NamespacedIdentifier identifier;

  /// Stable text.
  String get value => identifier.value;
  @override
  int compareTo(InteractionActionId other) => value.compareTo(other.value);
  @override
  bool operator ==(Object other) =>
      other is InteractionActionId && other.identifier == identifier;
  @override
  int get hashCode => Object.hash(InteractionActionId, identifier);
}

/// Immutable safe action metadata.
final class InteractionActionDefinition {
  /// Creates an action definition.
  const InteractionActionDefinition({
    required this.id,
    required this.navigation,
    required this.temporary,
  });

  /// Stable identity.
  final InteractionActionId id;

  /// Whether this is viewport navigation and must bypass drawing tools.
  final bool navigation;

  /// Whether temporary routing may activate it.
  final bool temporary;
}

/// Immutable action registry with caller-injected capture ceiling.
final class InteractionActionRegistry {
  InteractionActionRegistry._(this.definitions);

  /// Safely creates a deterministic unique registry.
  static Result<InteractionActionRegistry, StructuredFailure> create(
    Iterable<InteractionActionDefinition> source, {
    required int maximumActions,
  }) {
    final captured = _capture(source, maximumActions);
    if (captured is Err<List<InteractionActionDefinition>, StructuredFailure>)
      return Err(captured.error);
    final values =
        (captured as Ok<List<InteractionActionDefinition>, StructuredFailure>)
            .value;
    final map = <InteractionActionId, InteractionActionDefinition>{};
    for (final item in values) {
      if (map.containsKey(item.id)) return Err(_failure('duplicate_action'));
      map[item.id] = item;
    }
    return Ok(InteractionActionRegistry._(Map.unmodifiable(map)));
  }

  /// Registered definitions.
  final Map<InteractionActionId, InteractionActionDefinition> definitions;
}

/// Declarative match conditions for one action.
final class InteractionBinding {
  /// Creates an immutable binding.
  const InteractionBinding({
    required this.actionId,
    required this.source,
    this.stylusSubtype,
    required this.requiresPrimaryButton,
    this.activeTool,
  });

  /// Resolved action.
  final InteractionActionId actionId;

  /// Required source.
  final PointerSource source;

  /// Optional stylus subtype.
  final StylusSubtype? stylusSubtype;

  /// Whether primary button must be active.
  final bool requiresPrimaryButton;

  /// Optional active-tool stable name.
  final String? activeTool;

  /// Whether the event/context match.
  bool matches(
    NormalizedPointerEvent event,
    InteractionContextSnapshot context,
  ) =>
      source == event.source &&
      (stylusSubtype == null || stylusSubtype == event.stylusSubtype) &&
      (!requiresPrimaryButton ||
          event.buttons.primary ||
          event.source == PointerSource.stylus) &&
      (activeTool == null || activeTool == context.activeTool);

  bool _conflicts(InteractionBinding other) =>
      source == other.source &&
      stylusSubtype == other.stylusSubtype &&
      requiresPrimaryButton == other.requiresPrimaryButton &&
      activeTool == other.activeTool;
}

/// Immutable deterministic bounded binding profile.
final class BindingProfile {
  BindingProfile._(this.bindings);

  /// Creates a profile and fails closed on indistinguishable bindings.
  static Result<BindingProfile, StructuredFailure> create(
    Iterable<InteractionBinding> source, {
    required int maximumBindings,
  }) {
    final captured = _capture(source, maximumBindings);
    if (captured is Err<List<InteractionBinding>, StructuredFailure>)
      return Err(captured.error);
    final values =
        (captured as Ok<List<InteractionBinding>, StructuredFailure>).value;
    for (var i = 0; i < values.length; i++)
      for (var j = i + 1; j < values.length; j++)
        if (values[i]._conflicts(values[j]))
          return Err(_failure('binding_conflict'));
    return Ok(BindingProfile._(List.unmodifiable(values)));
  }

  /// Declarative bindings.
  final List<InteractionBinding> bindings;
}

/// Immutable routing context captured for deterministic resolution.
final class InteractionContextSnapshot {
  /// Creates routing context.
  const InteractionContextSnapshot({
    required this.activeTool,
    required this.pageRevision,
    required this.suspended,
  });

  /// Active tool stable name.
  final String activeTool;

  /// Current Page revision evidence.
  final Revision pageRevision;

  /// Whether input is suspended.
  final bool suspended;
}

/// Deterministic binding resolver and conservative touch suppressor.
final class InteractionResolver {
  /// Creates a resolver.
  const InteractionResolver({required this.registry, required this.profile});

  /// Known actions.
  final InteractionActionRegistry registry;

  /// Active immutable profile.
  final BindingProfile profile;

  /// Resolves exactly one action or fails closed.
  Result<InteractionActionDefinition?, StructuredFailure> resolve(
    NormalizedPointerEvent event,
    InteractionContextSnapshot context,
  ) {
    if (context.suspended ||
        event.source == PointerSource.touch ||
        event.source == PointerSource.unknown)
      return const Ok(null);
    final matches = profile.bindings
        .where((binding) => binding.matches(event, context))
        .toList(growable: false);
    if (matches.length > 1) return Err(_failure('ambiguous_binding'));
    if (matches.isEmpty) return const Ok(null);
    final action = registry.definitions[matches.single.actionId];
    if (action == null) return Err(_failure('unknown_action'));
    return Ok(action);
  }
}

/// One-primary-pointer ownership state machine.
final class PointerOwnership {
  int? _owner;

  /// Current owner or null.
  int? get owner => _owner;

  /// Claims an idle owner slot.
  bool claim(int pointerId) {
    if (_owner != null) return false;
    _owner = pointerId;
    return true;
  }

  /// Whether [pointerId] owns the gesture.
  bool owns(int pointerId) => _owner == pointerId;

  /// Releases only the current owner and permits identity reuse.
  bool release(int pointerId) {
    if (_owner != pointerId) return false;
    _owner = null;
    return true;
  }

  /// Cancels any ownership.
  void cancel() => _owner = null;
}

/// One event routed under the action and Tool snapshot captured at Down.
final class RoutedInteraction {
  const RoutedInteraction({
    required this.event,
    required this.action,
    required this.activeTool,
    required this.pageRevision,
  });

  /// Validated event.
  final NormalizedPointerEvent event;

  /// Registry-owned action retained for the complete gesture.
  final InteractionActionDefinition action;

  /// Active Tool name captured at Down.
  final String activeTool;

  /// Page revision captured at Down.
  final Revision pageRevision;
}

/// Portable one-primary-pointer gesture routing and ownership state machine.
final class InteractionGestureRouter {
  /// Creates routing with injected mappings and ownership.
  InteractionGestureRouter({required this.resolver, required this.ownership});

  /// Binding resolver.
  final InteractionResolver resolver;

  /// Pointer ownership boundary.
  final PointerOwnership ownership;
  InteractionActionDefinition? _action;
  String? _activeTool;
  Revision? _pageRevision;
  int? _lastTimeMicros;

  /// Routes an event, claiming only accepted Down and releasing every terminal.
  Result<RoutedInteraction?, StructuredFailure> route(
    NormalizedPointerEvent event,
    InteractionContextSnapshot context,
  ) {
    if (event.phase == PointerPhase.hover) return const Ok(null);
    if (event.phase == PointerPhase.down) {
      if (ownership.owner != null) return const Ok(null);
      final resolved = resolver.resolve(event, context);
      if (resolved is Err<InteractionActionDefinition?, StructuredFailure>) {
        return Err(_failure('routing_unavailable'));
      }
      final action =
          (resolved as Ok<InteractionActionDefinition?, StructuredFailure>)
              .value;
      if (action == null || !ownership.claim(event.pointerId))
        return const Ok(null);
      _action = action;
      _activeTool = context.activeTool;
      _pageRevision = context.pageRevision;
      _lastTimeMicros = event.timeMicros;
      return Ok(
        RoutedInteraction(
          event: event,
          action: action,
          activeTool: context.activeTool,
          pageRevision: context.pageRevision,
        ),
      );
    }
    if (!ownership.owns(event.pointerId)) return const Ok(null);
    final action = _action;
    final tool = _activeTool;
    final page = _pageRevision;
    final last = _lastTimeMicros;
    if (action == null ||
        tool == null ||
        page == null ||
        last == null ||
        event.timeMicros < last) {
      cancel();
      return Err(_failure('invalid_gesture_sequence'));
    }
    _lastTimeMicros = event.timeMicros;
    final routed = RoutedInteraction(
      event: event,
      action: action,
      activeTool: tool,
      pageRevision: page,
    );
    return Ok(routed);
  }

  /// Releases the owner exactly once after the terminal event is consumed.
  bool completeTerminal(int pointerId) {
    if (!ownership.owns(pointerId)) return false;
    _release(pointerId);
    return true;
  }

  /// Cancels for focus loss, suspension, Page change, or capture loss.
  void cancel() {
    final owner = ownership.owner;
    if (owner != null) ownership.release(owner);
    _clear();
  }

  void _release(int pointerId) {
    ownership.release(pointerId);
    _clear();
  }

  void _clear() {
    _action = null;
    _activeTool = null;
    _pageRevision = null;
    _lastTimeMicros = null;
  }
}

Result<List<T>, StructuredFailure> _capture<T>(
  Iterable<T> source,
  int maximum,
) {
  if (maximum < 0 || maximum > 9007199254740991)
    return Err(_failure('invalid_limit'));
  final values = <T>[];
  try {
    final iterator = source.iterator;
    while (iterator.moveNext()) {
      if (values.length >= maximum) return Err(_failure('limit_exceeded'));
      values.add(iterator.current);
    }
  } on Object {
    return Err(_failure('invalid_iterable'));
  }
  return Ok(List.unmodifiable(values));
}

StructuredFailure _failure(String leaf) => StructuredFailure(
  code: 'core.interaction.$leaf',
  category: FailureCategory.validation,
  retryDisposition: RetryDisposition.never,
  message: 'Interaction input is invalid.',
);
