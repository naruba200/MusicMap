// Widget smoke tests.
//
// The M0–M3 milestone placeholder screens (and their PlaceholderBody
// widget) were replaced by real screens, so the old placeholder test was
// removed (2026-10-19). Full widget tests with mocked repositories are
// tracked in spec §15; this file keeps a smoke test so the widget harness
// stays green in the meantime.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/core/time_ago.dart';

void main() {
  testWidgets('app midnight theme builds and timeAgo renders',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.themeData(
            AppThemeName.midnight, AppDesign.compact),
        home: Scaffold(body: Text(timeAgo(DateTime.now()))),
      ),
    );
    expect(find.text('just now'), findsOneWidget);
  });
}
