// Widget smoke tests for shared screen widgets (replaces the
// flutter-create template test, which referenced a non-existent MyApp).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_map/presentation/screens/screens.dart';

void main() {
  testWidgets('PlaceholderBody renders its label and milestone',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PlaceholderBody(
          icon: Icons.newspaper_outlined,
          label: 'News',
          milestone: 'M4: RSS feed',
        ),
      ),
    );
    expect(find.text('News'), findsOneWidget);
    expect(find.text('M4: RSS feed'), findsOneWidget);
    expect(find.byIcon(Icons.newspaper_outlined), findsOneWidget);
  });

  testWidgets('Not-yet-built screens show their milestone placeholders',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FavoritesScreen(),
      ),
    );
    expect(find.text('Favorites'), findsOneWidget);
  });
}
