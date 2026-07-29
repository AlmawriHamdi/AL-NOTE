// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../ui/canvas/phase6_canvas.dart';
import '../ui/canvas/phase6_canvas_runtime.dart';

/// The accessible Phase 6 AL NOTE application shell.
class AlNoteApp extends StatelessWidget {
  /// Creates the AL NOTE application shell.
  const AlNoteApp({required this.runtime, super.key});

  /// Fully validated injected Canvas runtime.
  final Phase6CanvasRuntime runtime;

  @override
  Widget build(final BuildContext context) {
    return MaterialApp(
      home: Phase6Canvas(runtime: runtime),
      debugShowCheckedModeBanner: false,
      title: 'AL NOTE',
    );
  }
}

/// Safe noninteractive state used when production composition fails.
final class AlNoteInitializationFailureApp extends StatelessWidget {
  /// Creates the failure shell.
  const AlNoteInitializationFailureApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(child: Text('AL NOTE could not initialize safely.')),
    ),
  );
}
