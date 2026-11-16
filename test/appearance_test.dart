// Phase A design-system tests: theme palettes (exact DESIGN.md hexes),
// WCAG contrast floors, design tokens, settings persistence, the
// appearance notifier (including the long-press preview), and the
// Settings Appearance section (tap a swatch, flip the design toggle).

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/core/appearance.dart';
import 'package:music_man/core/theme.dart';
import 'package:music_man/data/repositories/settings_repository.dart';
import 'package:music_man/presentation/providers/appearance_provider.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/widgets/appearance_section.dart';

// -- WCAG contrast (relative luminance, sRGB) -------------------------------

double _luminance(Color c) {
  double channel(double s) =>
      s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('theme palettes match DESIGN.md', () {
    // The expected hexes are duplicated from DESIGN.md on purpose:
    // this pins them, so an accidental edit to a palette fails here.
    const expected = {
      AppThemeName.editorial: (
        paper: 0xFFF5F1E8,
        paper2: 0xFFEFE9DC,
        ink: 0xFF1A1A1A,
        inkSoft: 0xFF55524A,
        hairline: 0xFFD8D2C4,
        accent: 0xFFD43D2A,
        accentText: 0xFFA82A1C,
      ),
      AppThemeName.tako: (
        paper: 0xFF221A33,
        paper2: 0xFF2C2140,
        ink: 0xFFF2EEF5,
        inkSoft: 0xFFC4B8D4,
        hairline: 0xFF453A5C,
        accent: 0xFFDE4F27,
        accentText: 0xFFE86A4A,
      ),
      AppThemeName.cappuccino: (
        paper: 0xFFF3EBDD,
        paper2: 0xFFEADFCB,
        ink: 0xFF2B2118,
        inkSoft: 0xFF6B5B49,
        hairline: 0xFFD9CBB2,
        accent: 0xFFA96F2C,
        accentText: 0xFF7E4F1A,
      ),
      AppThemeName.matcha: (
        paper: 0xFFEFF3E4,
        paper2: 0xFFE4EAD2,
        ink: 0xFF1E3320,
        inkSoft: 0xFF4F6248,
        hairline: 0xFFD2DCC0,
        accent: 0xFF4A7C2E,
        accentText: 0xFF35611F,
      ),
      AppThemeName.sakura: (
        paper: 0xFFF9EDEF,
        paper2: 0xFFF3DFE4,
        ink: 0xFF3D2430,
        inkSoft: 0xFF6E5560,
        hairline: 0xFFE3C9D1,
        accent: 0xFFC2456B,
        accentText: 0xFF9C2F50,
      ),
      AppThemeName.midnight: (
        paper: 0xFF141B2D,
        paper2: 0xFF1C2539,
        ink: 0xFFE9EAF0,
        inkSoft: 0xFFA9B2C6,
        hairline: 0xFF2E3A52,
        accent: 0xFFE3C878,
        accentText: 0xFFE3C878,
      ),
    };

    test('all six themes exist with the DESIGN.md hexes', () {
      expect(AppThemeName.values.length, 6);
      for (final entry in expected.entries) {
        final p = entry.key.palette;
        final e = entry.value;
        expect(p.paper, Color(e.paper), reason: '${entry.key} paper');
        expect(p.paper2, Color(e.paper2), reason: '${entry.key} paper2');
        expect(p.ink, Color(e.ink), reason: '${entry.key} ink');
        expect(p.inkSoft, Color(e.inkSoft),
            reason: '${entry.key} inkSoft');
        expect(p.hairline, Color(e.hairline),
            reason: '${entry.key} hairline');
        expect(p.accent, Color(e.accent), reason: '${entry.key} accent');
        expect(p.accentText, Color(e.accentText),
            reason: '${entry.key} accentText');
      }
    });

    test('dark themes are Tako and Midnight only', () {
      expect(
        AppThemeName.values.where((t) => t.isDark).toSet(),
        {AppThemeName.tako, AppThemeName.midnight},
      );
    });

    test('unknown stored theme/design names fall back to the defaults',
        () {
      expect(AppThemeName.tryParse('bogus'), AppThemeName.editorial);
      expect(AppThemeName.tryParse(null), AppThemeName.editorial);
      expect(AppDesign.tryParse('bogus'), AppDesign.compact);
      expect(AppDesign.tryParse(null), AppDesign.compact);
    });
  });

  group('contrast floors (DESIGN.md, WCAG)', () {
    for (final theme in AppThemeName.values) {
      test('${theme.displayName} passes every floor', () {
        final p = theme.palette;
        // Normal text (AA 4.5:1); DESIGN.md floors are stricter.
        expect(_contrast(p.ink, p.paper), greaterThanOrEqualTo(12.0),
            reason: 'ink on paper');
        expect(_contrast(p.inkSoft, p.paper), greaterThanOrEqualTo(5.5),
            reason: 'ink soft on paper');
        expect(_contrast(p.accentText, p.paper),
            greaterThanOrEqualTo(5.2),
            reason: 'accent text on paper');
        // Large text / graphic marks (AA large 3:1).
        expect(_contrast(p.accent, p.paper), greaterThanOrEqualTo(3.4),
            reason: 'accent on paper');
        expect(_contrast(p.paper, p.accent), greaterThanOrEqualTo(3.4),
            reason: 'paper text on accent (stamp kanji)');
        expect(_contrast(p.accent, p.paper2), greaterThanOrEqualTo(3.1),
            reason: 'accent on paper 2');
      });
    }
  });

  group('design tokens', () {
    test('Compact is strictly MOTION 0 with the one-shadow rule', () {
      final t = MusicManDesignTokens.forDesign(AppDesign.compact,
          isDark: false);
      expect(t.screenTransition, Duration.zero);
      expect(t.playerRise, Duration.zero);
      expect(t.tabSwitch, Duration.zero);
      expect(t.micro, Duration.zero);
      expect(t.progressTick, Duration.zero);
      expect(t.flatElevation, 0);
      expect(t.raisedElevation, 0);
      expect(t.floatingElevation, 4);
      expect(t.flatShadow, isEmpty);
      expect(t.raisedShadow, isEmpty);
      expect(t.floatingShadow.length, 1);
    });

    test('Complex is MOTION 2 with the three-level elevation scale',
        () {
      final t = MusicManDesignTokens.forDesign(AppDesign.complex,
          isDark: false);
      expect(t.screenTransition, const Duration(milliseconds: 200));
      expect(t.playerRise, const Duration(milliseconds: 220));
      expect(t.tabSwitch, const Duration(milliseconds: 220));
      expect(t.micro, const Duration(milliseconds: 150));
      expect(t.progressTick, const Duration(milliseconds: 250));
      expect(t.flatElevation, 0);
      expect(t.raisedElevation, 2);
      expect(t.floatingElevation, 6);
      expect(t.flatShadow, isEmpty);
      expect(t.raisedShadow.length, 1);
      expect(t.floatingShadow.length, 1);
    });

    test('radii are sharp in both designs: 4px cards, 2px covers',
        () {
      for (final design in AppDesign.values) {
        final t = MusicManDesignTokens.forDesign(design, isDark: false);
        expect(t.cardRadius, 4);
        expect(t.coverRadius, 2);
        expect(t.chipRadius, 2);
      }
    });

    test('dark themes get stronger black shadows', () {
      final light = MusicManDesignTokens.forDesign(AppDesign.complex,
          isDark: false);
      final dark = MusicManDesignTokens.forDesign(AppDesign.complex,
          isDark: true);
      expect(dark.floatingShadow.single.color.a,
          greaterThan(light.floatingShadow.single.color.a));
      expect(dark.raisedShadow.single.color.a,
          greaterThan(light.raisedShadow.single.color.a));
    });
  });

  group('ThemeData smoke', () {
    for (final theme in AppThemeName.values) {
      for (final design in AppDesign.values) {
        test('${theme.displayName} + ${design.displayName} builds', () {
          final data = AppTheme.themeData(theme, design);
          expect(
            data.brightness,
            theme.isDark ? Brightness.dark : Brightness.light,
          );
          expect(data.scaffoldBackgroundColor, theme.palette.paper);
          expect(data.colorScheme.primary, theme.palette.accent);
          expect(data.colorScheme.onSurface, theme.palette.ink);
          expect(data.colorScheme.onSurfaceVariant,
              theme.palette.inkSoft);
          expect(data.dividerColor, theme.palette.hairline);
          // Archivo for body, Noto Sans JP as the fallback for the
          // stamp kanji and Japanese accents. google_fonts registers
          // each weight as its own family (Archivo_regular,
          // Archivo_600, Archivo_800, ...).
          expect(data.textTheme.bodyLarge?.fontFamily, 'Archivo_regular');
          expect(data.textTheme.displayLarge?.fontFamily, 'Archivo_800');
          expect(data.textTheme.titleLarge?.fontFamily, 'Archivo_600');
          expect(data.textTheme.bodyLarge?.fontFamilyFallback,
              contains('Noto Sans JP'));
          // Display/headlines 700/800, section titles 600.
          expect(data.textTheme.displayLarge?.fontWeight,
              FontWeight.w800);
          expect(data.textTheme.headlineMedium?.fontWeight,
              FontWeight.w700);
          expect(data.textTheme.titleLarge?.fontWeight,
              FontWeight.w600);
          final tokens = data.extension<MusicManDesignTokens>()!;
          expect(tokens.design, design);
        });
      }
    }

    test('stamp kanji style is Noto Sans JP 700', () {
      final style = AppTheme.stampKanjiStyle(
        color: const Color(0xFFF5F1E8),
      );
      expect(style.fontFamily, 'NotoSansJP_700');
      expect(style.fontWeight, FontWeight.w700);
    });
  });

  group('settings persistence + appearance notifier', () {
    late Directory dir;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_appearance');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    Future<SettingsRepository> freshRepo() async {
      final box = await Hive.openBox('appearance_settings');
      await box.clear();
      return SettingsRepository(box);
    }

    test('theme and design persist with Editorial + Compact defaults',
        () async {
      final repo = await freshRepo();
      expect(repo.themeName, 'editorial');
      expect(repo.design, 'compact');
      await repo.setThemeName('tako');
      await repo.setDesign('complex');
      expect(repo.themeName, 'tako');
      expect(repo.design, 'complex');
    });

    test('notifier reads stored values and updates on set', () async {
      final repo = await freshRepo();
      final notifier = AppearanceNotifier(repo);
      expect(notifier.state.theme, AppThemeName.editorial);
      expect(notifier.state.design, AppDesign.compact);

      await notifier.setTheme(AppThemeName.sakura);
      expect(notifier.state.theme, AppThemeName.sakura);
      expect(repo.themeName, 'sakura');
      // Setting the theme never touches the design.
      expect(notifier.state.design, AppDesign.compact);

      await notifier.setDesign(AppDesign.complex);
      expect(notifier.state.design, AppDesign.complex);
      expect(repo.design, 'complex');
      expect(notifier.state.theme, AppThemeName.sakura);
    });

    test('unknown stored values fall back to the defaults', () async {
      final repo = await freshRepo();
      final box = await Hive.openBox('appearance_settings');
      await box.put('theme', 'not-a-theme');
      await box.put('design', 'not-a-design');
      final notifier = AppearanceNotifier(repo);
      expect(notifier.state.theme, AppThemeName.editorial);
      expect(notifier.state.design, AppDesign.compact);
    });

    test('long-press preview overrides the theme without storing it',
        () async {
      final repo = await freshRepo();
      final notifier = AppearanceNotifier(repo);
      notifier.previewTheme(AppThemeName.midnight);
      expect(notifier.state.effectiveTheme, AppThemeName.midnight);
      expect(notifier.state.theme, AppThemeName.editorial);
      expect(repo.themeName, 'editorial');
      notifier.clearPreview();
      expect(notifier.state.effectiveTheme, AppThemeName.editorial);
      expect(notifier.state.previewTheme, isNull);
    });

    test('applying a theme clears any preview', () async {
      final repo = await freshRepo();
      final notifier = AppearanceNotifier(repo);
      notifier.previewTheme(AppThemeName.matcha);
      await notifier.setTheme(AppThemeName.cappuccino);
      expect(notifier.state.previewTheme, isNull);
      expect(notifier.state.effectiveTheme, AppThemeName.cappuccino);
    });
  });

  group('AppearanceSection widget', () {
    late Directory dir;
    late SettingsRepository repo;
    late ProviderContainer container;
    int boxCounter = 0;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('music_man_appearance');
      Hive.init(dir.path);
    });

    tearDownAll(() async {
      // NOTE: Hive.close() hangs in widget tests once a box has been
      // written to (its close awaits a flush that never fires under
      // the test binding) — the same close works fine in the
      // plain-Dart groups above. Skip it here: the temp dir is
      // deleted below and the test process exits right after.
      await dir.delete(recursive: true);
    });

    setUp(() async {
      // Fresh boxes per test instead of clearing shared ones:
      // opening a box inside the test body hangs in the widget
      // test's fake async, and clearing a box hangs even under
      // runAsync. setUp runs outside the fake clock, so opening the
      // box here works.
      final n = boxCounter++;
      final box = await Hive.openBox('appearance_$n');
      repo = SettingsRepository(box);
      container = ProviderContainer(
        overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
    });

    Future<void> pumpHarness(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _AppearanceHarness(),
        ),
      );
      await tester.pump();
    }

    // Lets a real Hive write finish after a tap (runAsync: the
    // widget test's fake clock does not advance real I/O), then
    // pumps so the UI reflects the stored choice.
    Future<void> settleHiveWrite(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
    }

    testWidgets('all six themes and both designs are offered',
        (tester) async {
      await pumpHarness(tester);
      expect(container.read(appearanceProvider).theme,
          AppThemeName.editorial);
      expect(container.read(appearanceProvider).design, AppDesign.compact);
      for (final theme in AppThemeName.values) {
        expect(find.text(theme.displayName), findsOneWidget);
      }
      expect(find.text('Compact'), findsOneWidget);
      expect(find.text('Complex'), findsOneWidget);
    });

    testWidgets('tapping a swatch applies the theme and re-skins',
        (tester) async {
      await pumpHarness(tester);
      await tester.tap(find.text('Tako'));
      await settleHiveWrite(tester);

      expect(container.read(appearanceProvider).theme, AppThemeName.tako);
      expect(repo.themeName, 'tako');
      // The whole app re-skins: the harness MaterialApp now carries
      // the Tako accent.
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.theme?.colorScheme.primary, const Color(0xFFDE4F27));
      expect(app.theme?.scaffoldBackgroundColor,
          const Color(0xFF221A33));
    });

    testWidgets('design toggle switches Compact and Complex',
        (tester) async {
      await pumpHarness(tester);
      await tester.tap(find.text('Complex'));
      await settleHiveWrite(tester);
      expect(container.read(appearanceProvider).design, AppDesign.complex);
      expect(repo.design, 'complex');
      final tokens = tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .theme
          ?.extension<MusicManDesignTokens>();
      expect(tokens?.design, AppDesign.complex);

      await tester.tap(find.text('Compact'));
      await settleHiveWrite(tester);
      expect(container.read(appearanceProvider).design, AppDesign.compact);
    });

    testWidgets('long-press previews the theme, release reverts',
        (tester) async {
      await pumpHarness(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Midnight')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(container.read(appearanceProvider).effectiveTheme,
          AppThemeName.midnight);
      // The stored choice is untouched while previewing.
      expect(repo.themeName, 'editorial');
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.theme?.colorScheme.primary, const Color(0xFFE3C878));

      await gesture.up();
      await tester.pump();
      expect(container.read(appearanceProvider).previewTheme, isNull);
      expect(container.read(appearanceProvider).effectiveTheme,
          AppThemeName.editorial);
    });
  });
}

/// Minimal app root around the Appearance section: the MaterialApp
/// theme follows the appearance provider, like main.dart's MusicManApp.
class _AppearanceHarness extends ConsumerWidget {
  const _AppearanceHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final themeData = AppTheme.themeData(
      appearance.effectiveTheme,
      appearance.design,
    );
    return MaterialApp(
      theme: themeData,
      darkTheme: themeData,
      home: const Scaffold(body: AppearanceSection()),
    );
  }
}
