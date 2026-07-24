// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:al_note/app/al_note_app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies that the Phase 0 application shell renders successfully.
void main() {
  testWidgets('renders the Phase 0 application shell', (
    final WidgetTester tester,
  ) async {
    await tester.pumpWidget(const AlNoteApp());

    expect(find.byType(WidgetsApp), findsOneWidget);
    expect(find.text('AL NOTE'), findsOneWidget);
  });
}
