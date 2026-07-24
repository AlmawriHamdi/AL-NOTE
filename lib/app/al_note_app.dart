// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

/// The feature-free application shell used by the Phase 0 baseline.
class AlNoteApp extends StatelessWidget {
  /// Creates the AL NOTE application shell.
  const AlNoteApp({super.key});

  @override
  Widget build(final BuildContext context) {
    return WidgetsApp(
      builder: (final BuildContext context, final Widget? child) {
        return const ColoredBox(
          color: Color(0xFFF7F8FA),
          child: Center(
            child: Text(
              'AL NOTE',
              style: TextStyle(color: Color(0xFF1B365D), fontSize: 24),
            ),
          ),
        );
      },
      color: const Color(0xFF1B365D),
      debugShowCheckedModeBanner: false,
      title: 'AL NOTE',
    );
  }
}
