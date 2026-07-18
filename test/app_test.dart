import 'package:al_note/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the AL NOTE startup shell', (WidgetTester tester) async {
    await tester.pumpWidget(const AlNoteApp());

    expect(find.text('AL NOTE'), findsOneWidget);
    expect(find.text('Repository and toolchain baseline'), findsOneWidget);
  });
}
