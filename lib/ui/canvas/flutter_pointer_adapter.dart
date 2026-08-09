// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../core/interaction.dart';
import '../../core/outcomes/result.dart';
import '../../core/outcomes/structured_failure.dart';

/// Flutter-only adapter that normalizes pointer events at the Canvas boundary.
final class FlutterPointerAdapter {
  /// Creates portable input without allowing Flutter types to cross the adapter.
  Result<NormalizedPointerEvent, StructuredFailure> normalize(
    PointerEvent event,
  ) {
    final position = ViewPoint.create(
      x: event.localPosition.dx,
      y: event.localPosition.dy,
    );
    if (position is Err<ViewPoint, StructuredFailure>)
      return Err(position.error);
    final source = switch (event.kind) {
      PointerDeviceKind.mouse => PointerSource.mouse,
      PointerDeviceKind.stylus ||
      PointerDeviceKind.invertedStylus => PointerSource.stylus,
      PointerDeviceKind.touch => PointerSource.touch,
      _ => PointerSource.unknown,
    };
    final subtype = event.kind == PointerDeviceKind.invertedStylus
        ? StylusSubtype.eraser
        : source == PointerSource.stylus
        ? StylusSubtype.tip
        : StylusSubtype.unknown;
    final phase = switch (event) {
      PointerDownEvent() => PointerPhase.down,
      PointerMoveEvent() => PointerPhase.move,
      PointerUpEvent() => PointerPhase.up,
      PointerHoverEvent() => PointerPhase.hover,
      PointerCancelEvent() => PointerPhase.cancel,
      _ => null,
    };
    if (phase == null) {
      return Err(
        StructuredFailure(
          code: 'ui.canvas.unsupported_pointer_event',
          category: FailureCategory.validation,
          retryDisposition: RetryDisposition.never,
          message: 'Pointer input is unsupported.',
        ),
      );
    }
    final rawPressure = event.pressure;
    final pressure =
        rawPressure.isFinite && rawPressure >= 0 && rawPressure <= 1
        ? rawPressure
        : null;
    return NormalizedPointerEvent.create(
      pointerId: event.pointer,
      source: source,
      stylusSubtype: subtype,
      phase: phase,
      viewPosition: (position as Ok<ViewPoint, StructuredFailure>).value,
      buttons: PointerButtons(
        event.buttons == 0 && source == PointerSource.stylus
            ? 1
            : event.buttons,
      ),
      pressure: pressure,
      tilt: event.tilt.isFinite ? event.tilt : null,
      orientation: event.orientation.isFinite ? event.orientation : null,
      pressureSupported: event.pressureMax > event.pressureMin,
      modifiers: InputModifiers(
        shift: HardwareKeyboard.instance.isShiftPressed,
        control: HardwareKeyboard.instance.isControlPressed,
        alt: HardwareKeyboard.instance.isAltPressed,
        meta: HardwareKeyboard.instance.isMetaPressed,
      ),
      sensorConfidence: source == PointerSource.unknown ? 0 : 1,
      timeMicros: event.timeStamp.inMicroseconds,
      cancellationReason: phase == PointerPhase.cancel
          ? InteractionCancellationReason.captureLoss
          : null,
    );
  }
}
