// Phase B route tests: the editorial screen route gates its motion on
// the design (DESIGN.md: Motion). Compact is strictly MOTION 0, so a
// pushed screen appears instantly; Complex slides in from the right
// with a short ease (about 200 ms).

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/presentation/widgets/editorial_route.dart';

/// Pumps a small app whose only action pushes a page through
/// [editorialRoute], and returns the route that was pushed.
Future<PageRoute<Object?>> _pushThroughRoute(
  WidgetTester tester,
  AppDesign design,
) async {
  late final PageRoute<Object?> pushed;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.themeData(AppThemeName.editorial, design),
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed: () {
                pushed = editorialRoute<Object?>(
                  context,
                  (_) => const Scaffold(
                    body: Text('Pushed page'),
                  ),
                ) as PageRoute<Object?>;
                Navigator.of(context).push(pushed);
              },
              child: const Text('Go'),
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('Go'));
  await tester.pumpAndSettle();
  return pushed;
}

void main() {
  testWidgets('Compact route has a zero transition duration',
      (tester) async {
    final route = await _pushThroughRoute(tester, AppDesign.compact);
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(find.text('Pushed page'), findsOneWidget);
  });

  testWidgets('Complex route slides in over 200 ms', (tester) async {
    final route = await _pushThroughRoute(tester, AppDesign.complex);
    expect(
      route.transitionDuration,
      const Duration(milliseconds: 200),
    );
    expect(
      route.reverseTransitionDuration,
      const Duration(milliseconds: 200),
    );
    expect(find.text('Pushed page'), findsOneWidget);
  });

  testWidgets('pushed page appears in both designs', (tester) async {
    await _pushThroughRoute(tester, AppDesign.compact);
    expect(find.text('Pushed page'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await _pushThroughRoute(tester, AppDesign.complex);
    expect(find.text('Pushed page'), findsOneWidget);
  });
}
