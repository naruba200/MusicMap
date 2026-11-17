// App-wide themes (DESIGN.md, the design authority).
//
// The old dark Material 3 look (deep-purple seed, follows system) is
// gone: the app renders in the selected named theme (default
// Editorial) and the selected design (default Compact). Theme and
// Design are independent axes; MaterialApp is given the same
// ThemeData for theme and darkTheme so the selected theme always
// wins over the system brightness.

import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';

/// Fonts are fetched once from Google Fonts and cached on-device
/// (google_fonts); see the Phase A report for why bundled font files
/// were not the route. The theme only names the families: Archivo for
/// display/body, Noto Sans JP as the fallback so the stamp kanji and
/// Japanese section accents render in the matching grotesque.
///
/// To switch to bundled fonts later: drop the TTFs in assets/fonts,
/// declare them in pubspec.yaml, and replace the GoogleFonts calls in
/// [_textTheme] and [stampKanjiStyle] with plain TextStyles carrying
/// fontFamily 'Archivo' / 'Noto Sans JP'. Nothing else references the
/// font source.
abstract final class AppTheme {
  static const String displayFontFamily = 'Archivo';
  static const String japaneseFontFamily = 'Noto Sans JP';

  static ThemeData themeData(
    AppThemeName name,
    AppDesign design, {
    bool reduceMotion = false,
  }) {
    final p = name.palette;
    final brightness =
        name.isDark ? Brightness.dark : Brightness.light;
    final textTheme = _textTheme(p, brightness);

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      // Dark surfaces keep the exact palette colors; Material's
      // elevation overlay tint would shift them.
      applyElevationOverlayColor: false,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: p.accent,
        onPrimary: p.paper,
        secondary: p.accent,
        onSecondary: p.paper,
        error: p.accent,
        onError: p.paper,
        surface: p.paper2,
        onSurface: p.ink,
        surfaceContainerHighest: p.paper2,
        onSurfaceVariant: p.inkSoft,
        outline: p.hairline,
        outlineVariant: p.hairline,
        inverseSurface: p.ink,
        onInverseSurface: p.paper,
      ),
      scaffoldBackgroundColor: p.paper,
      canvasColor: p.paper,
      cardColor: p.paper2,
      dividerColor: p.hairline,
      focusColor: p.accent.withValues(alpha: 0.12),
      hoverColor: p.accent.withValues(alpha: 0.08),
      splashColor: p.accent.withValues(alpha: 0.12),
      // Rows flash paper 2 on tap (DESIGN.md: Press states): the
      // highlight is the raised surface color, not an accent tint,
      // so a pressed row reads as the paper lifting, not as a
      // colored stain. The splash ripple above keeps the accent.
      highlightColor: p.paper2,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      extensions: [
        MusicManDesignTokens.forDesign(
          design,
          isDark: name.isDark,
          reduceMotion: reduceMotion,
        ),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: p.paper,
        foregroundColor: p.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.paper,
        elevation: 0,
        indicatorColor: p.paper2,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? p.accent
                : p.inkSoft,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? p.accent
                : p.inkSoft,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: p.paper2,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: p.hairline),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: p.hairline,
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.paper2,
        selectedColor: p.accent,
        disabledColor: p.paper2,
        checkmarkColor: p.paper,
        labelStyle: textTheme.bodyMedium,
        secondaryLabelStyle:
            textTheme.bodyMedium?.copyWith(color: p.paper),
        side: BorderSide(color: p.hairline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.paper,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.paper,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          // Small text in the accent color uses the accent-text role,
          // so it passes 4.5:1 (DESIGN.md).
          foregroundColor: p.accentText,
          textStyle: textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.ink,
          side: BorderSide(color: p.hairline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: p.paper,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.paper
              : p.inkSoft,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accent
              : p.hairline,
        ),
        trackOutlineColor:
            WidgetStateProperty.all(p.hairline),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? p.accent
                : p.paper2,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? p.paper
                : p.ink,
          ),
          side: WidgetStateProperty.all(
            BorderSide(color: p.hairline),
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          textStyle: WidgetStateProperty.all(
            textTheme.labelLarge
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.paper2,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.ink,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: p.paper),
        actionTextColor: p.paper,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.paper2,
        labelStyle: textTheme.bodyMedium
            ?.copyWith(color: p.inkSoft),
        hintStyle:
            textTheme.bodyMedium?.copyWith(color: p.inkSoft),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: p.accent),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.inkSoft,
        textColor: p.ink,
      ),
      iconTheme: IconThemeData(color: p.ink),
      primaryIconTheme: IconThemeData(color: p.ink),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.accent,
        inactiveTrackColor: p.hairline,
        thumbColor: p.accent,
        overlayColor: p.accent.withValues(alpha: 0.12),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.paper2,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(4),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.paper2,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        textStyle: textTheme.bodyMedium,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.accent,
        unselectedLabelColor: p.inkSoft,
        indicatorColor: p.accent,
        labelStyle:
            textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w500),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accent
              : p.paper2,
        ),
        checkColor: WidgetStateProperty.all(p.paper),
        side: BorderSide(color: p.hairline),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accent
              : p.inkSoft,
        ),
      ),
    );
  }

  /// Archivo for display and body (DESIGN.md: Typography). Display
  /// and headlines at 700/800, section titles at 600, body and
  /// labels at the Material defaults (400/500). Numbers use tabular
  /// figures so chart positions, counts, and times line up.
  ///
  /// The weights are set on the base theme BEFORE the GoogleFonts
  /// call: google_fonts picks the font variant per style from its
  /// weight, so weighting after would leave every style on the
  /// regular variant and headlines would render faux-bold.
  static TextTheme _textTheme(MusicManPalette p, Brightness brightness) {
    const tabular = [FontFeature.tabularFigures()];
    final base = ThemeData(brightness: brightness).textTheme;
    final weighted = base.copyWith(
      displayLarge: base.displayLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
      displayMedium: base.displayMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
      displaySmall: base.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      headlineLarge: base.headlineLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.25,
      ),
      headlineMedium: base.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.bodyMedium?.copyWith(fontFeatures: tabular),
      bodySmall: base.bodySmall?.copyWith(fontFeatures: tabular),
      labelMedium: base.labelMedium?.copyWith(fontFeatures: tabular),
      labelSmall: base.labelSmall?.copyWith(fontFeatures: tabular),
    );
    return GoogleFonts.archivoTextTheme(weighted).apply(
      bodyColor: p.ink,
      displayColor: p.ink,
      fontFamilyFallback: const [japaneseFontFamily],
    );
  }

  /// The stamp kanji style (DESIGN.md: Identity motif): Noto Sans JP
  /// 700 inside a small accent square, one kanji per screen section.
  /// Used by Phase B screens; defined here so the family lives in
  /// one place.
  static TextStyle stampKanjiStyle({
    required Color color,
    double fontSize = 16,
  }) =>
      GoogleFonts.notoSansJp(
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        color: color,
      );
}
