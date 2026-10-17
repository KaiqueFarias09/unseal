import 'package:unseal_example/unseal_example_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads the bundled book summary', (final tester) async {
    await tester.pumpWidget(const UnsealExampleApp());

    expect(find.text('unseal example'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Format: epub'), findsOneWidget);
    expect(find.textContaining('Content files:'), findsOneWidget);
  });
}
