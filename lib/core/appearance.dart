// Design system data model (DESIGN.md, the design authority).
//
// The seven color roles, the six named themes, the Compact/Complex
// design axis, and the motion/elevation/radius tokens. This file holds
// data only; lib/core/theme.dart turns it into a ThemeData.

import 'package:material_ui/material_ui.dart';

/// The seven color roles every theme carries (DESIGN.md: Theme system).
/// One accent per theme, always; cover art is the only other color on
/// screen, and it arrives from the music, not from the interface.
class MusicManPalette {
  /// Page background.
  final Color paper;

  /// Raised surface: cards, sheets, the player.
  final Color paper2;

  /// Headlines, body text, icons.
  final Color ink;

  /// Secondary text, captions, timestamps.
  final Color inkSoft;

  /// Borders and rules only, never text.
  final Color hairline;

  /// The one accent: stamps, the play button, the active state, the
  /// single focal gesture per screen.
  final Color accent;

  /// The accent darkened (light themes) or lightened (dark themes)
  /// for small text, so accent-colored small text passes 4.5:1.
  final Color accentText;

  const MusicManPalette({
    required this.paper,
    required this.paper2,
    required this.ink,
    required this.inkSoft,
    required this.hairline,
    required this.accent,
    required this.accentText,
  });
}

/// The six named themes (DESIGN.md). Theme and Design are independent
/// axes: changing one never changes the other.
enum AppThemeName {
  editorial(
    displayName: 'Editorial',
    isDark: false,
    palette: MusicManPalette(
      paper: Color(0xFFF5F1E8),
      paper2: Color(0xFFEFE9DC),
      ink: Color(0xFF1A1A1A),
      inkSoft: Color(0xFF55524A),
      hairline: Color(0xFFD8D2C4),
      accent: Color(0xFFD43D2A),
      accentText: Color(0xFFA82A1C),
    ),
  ),
  tako(
    displayName: 'Tako',
    isDark: true,
    palette: MusicManPalette(
      paper: Color(0xFF221A33),
      paper2: Color(0xFF2C2140),
      ink: Color(0xFFF2EEF5),
      inkSoft: Color(0xFFC4B8D4),
      hairline: Color(0xFF453A5C),
      accent: Color(0xFFDE4F27),
      accentText: Color(0xFFE86A4A),
    ),
  ),
  cappuccino(
    displayName: 'Cappuccino',
    isDark: false,
    palette: MusicManPalette(
      paper: Color(0xFFF3EBDD),
      paper2: Color(0xFFEADFCB),
      ink: Color(0xFF2B2118),
      inkSoft: Color(0xFF6B5B49),
      hairline: Color(0xFFD9CBB2),
      accent: Color(0xFFA96F2C),
      accentText: Color(0xFF7E4F1A),
    ),
  ),
  matcha(
    displayName: 'Matcha',
    isDark: false,
    palette: MusicManPalette(
      paper: Color(0xFFEFF3E4),
      paper2: Color(0xFFE4EAD2),
      ink: Color(0xFF1E3320),
      inkSoft: Color(0xFF4F6248),
      hairline: Color(0xFFD2DCC0),
      accent: Color(0xFF4A7C2E),
      accentText: Color(0xFF35611F),
    ),
  ),
  sakura(
    displayName: 'Sakura',
    isDark: false,
    palette: MusicManPalette(
      paper: Color(0xFFF9EDEF),
      paper2: Color(0xFFF3DFE4),
      ink: Color(0xFF3D2430),
      inkSoft: Color(0xFF6E5560),
      hairline: Color(0xFFE3C9D1),
      accent: Color(0xFFC2456B),
      accentText: Color(0xFF9C2F50),
    ),
  ),
  midnight(
    displayName: 'Midnight',
    isDark: true,
    palette: MusicManPalette(
      paper: Color(0xFF141B2D),
      paper2: Color(0xFF1C2539),
      ink: Color(0xFFE9EAF0),
      inkSoft: Color(0xFFA9B2C6),
      hairline: Color(0xFF2E3A52),
      accent: Color(0xFFE3C878),
      accentText: Color(0xFFE3C878),
    ),
  );

  const AppThemeName({
    required this.displayName,
    required this.isDark,
    required this.palette,
  });

  final String displayName;
  final bool isDark;
  final MusicManPalette palette;

  /// Parses a stored theme name; anything unknown falls back to the
  /// default (Editorial) instead of crashing on a stale value.
  static AppThemeName tryParse(String? raw) {
    if (raw == null) return AppThemeName.editorial;
    for (final theme in AppThemeName.values) {
      if (theme.name == raw) return theme;
    }
    return AppThemeName.editorial;
  }
}

/// The design axis (DESIGN.md): Compact is the calm design (MOTION 0),
/// Complex adds depth, motion, and interaction (MOTION 2). Function is
/// identical in both; only the animation changes.
enum AppDesign {
  compact(displayName: 'Compact'),
  complex(displayName: 'Complex');

  const AppDesign({required this.displayName});

  final String displayName;

  /// Parses a stored design name; anything unknown falls back to the
  /// default (Compact) instead of crashing on a stale value.
  static AppDesign tryParse(String? raw) {
    if (raw == null) return AppDesign.compact;
    for (final design in AppDesign.values) {
      if (design.name == raw) return design;
    }
    return AppDesign.compact;
  }
}

/// Motion, elevation, and radius tokens for one design, read from the
/// theme by screens that animate or lift. Compact is strictly MOTION 0:
/// every duration is zero and only the playing cover carries a shadow.
/// Complex is MOTION 2: short eases that answer the touch, and the
/// three-level elevation scale (flat / raised / floating).
class MusicManDesignTokens extends ThemeExtension<MusicManDesignTokens> {
  const MusicManDesignTokens({
    required this.design,
    required this.screenTransition,
    required this.playerRise,
    required this.tabSwitch,
    required this.micro,
    required this.progressTick,
    required this.cardRadius,
    required this.coverRadius,
    required this.chipRadius,
    required this.flatElevation,
    required this.raisedElevation,
    required this.floatingElevation,
    required this.flatShadow,
    required this.raisedShadow,
    required this.floatingShadow,
  });

  final AppDesign design;

  /// Pushed screens slide in from the right (DESIGN.md: about 200 ms).
  final Duration screenTransition;

  /// The full player rises from the bottom (DESIGN.md: about 220 ms).
  final Duration playerRise;

  /// Tab-switch slide completion after a swipe (DESIGN.md: about
  /// 220 ms). The drag preview itself follows the finger directly;
  /// only the release completion is animated, and only in Complex.
  final Duration tabSwitch;

  /// Micro-motion: toggle slides, heart pops, chip settles. A short
  /// ease (150 ms, chosen here; DESIGN.md names the gestures, not a
  /// number). Zero in Compact.
  final Duration micro;

  /// Progress-rule animation step (DESIGN.md: progress ticks at
  /// 250 ms). In Compact the rule updates as instant state changes.
  final Duration progressTick;

  /// Cards and buttons: 4px. Print has sharp corners.
  final double cardRadius;

  /// Cover art and chips: 2px.
  final double coverRadius;
  final double chipRadius;

  /// Elevation levels. Compact keeps the one-shadow rule: flat and
  /// raised sit at 0, only the floating level (the playing cover)
  /// lifts. Complex uses all three levels.
  final double flatElevation;
  final double raisedElevation;
  final double floatingElevation;

  /// The shadows for each level. Dark themes get stronger black
  /// shadows, since the same opacity reads weaker on a dark sheet.
  final List<BoxShadow> flatShadow;
  final List<BoxShadow> raisedShadow;
  final List<BoxShadow> floatingShadow;

  factory MusicManDesignTokens.forDesign(
    AppDesign design, {
    required bool isDark,
  }) {
    switch (design) {
      case AppDesign.compact:
        return MusicManDesignTokens(
          design: design,
          screenTransition: Duration.zero,
          playerRise: Duration.zero,
          tabSwitch: Duration.zero,
          micro: Duration.zero,
          progressTick: Duration.zero,
          cardRadius: 4,
          coverRadius: 2,
          chipRadius: 2,
          flatElevation: 0,
          raisedElevation: 0,
          floatingElevation: 4,
          flatShadow: const [],
          raisedShadow: const [],
          floatingShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        );
      case AppDesign.complex:
        return MusicManDesignTokens(
          design: design,
          screenTransition: const Duration(milliseconds: 200),
          playerRise: const Duration(milliseconds: 220),
          tabSwitch: const Duration(milliseconds: 220),
          micro: const Duration(milliseconds: 150),
          progressTick: const Duration(milliseconds: 250),
          cardRadius: 4,
          coverRadius: 2,
          chipRadius: 2,
          flatElevation: 0,
          raisedElevation: 2,
          floatingElevation: 6,
          flatShadow: const [],
          raisedShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.12),
              blurRadius: 6,
              offset: const Offset(0, 1),
            ),
          ],
          floatingShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.16),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        );
    }
  }

  @override
  MusicManDesignTokens copyWith({
    AppDesign? design,
    Duration? screenTransition,
    Duration? playerRise,
    Duration? tabSwitch,
    Duration? micro,
    Duration? progressTick,
    double? cardRadius,
    double? coverRadius,
    double? chipRadius,
    double? flatElevation,
    double? raisedElevation,
    double? floatingElevation,
    List<BoxShadow>? flatShadow,
    List<BoxShadow>? raisedShadow,
    List<BoxShadow>? floatingShadow,
  }) {
    return MusicManDesignTokens(
      design: design ?? this.design,
      screenTransition: screenTransition ?? this.screenTransition,
      playerRise: playerRise ?? this.playerRise,
      tabSwitch: tabSwitch ?? this.tabSwitch,
      micro: micro ?? this.micro,
      progressTick: progressTick ?? this.progressTick,
      cardRadius: cardRadius ?? this.cardRadius,
      coverRadius: coverRadius ?? this.coverRadius,
      chipRadius: chipRadius ?? this.chipRadius,
      flatElevation: flatElevation ?? this.flatElevation,
      raisedElevation: raisedElevation ?? this.raisedElevation,
      floatingElevation: floatingElevation ?? this.floatingElevation,
      flatShadow: flatShadow ?? this.flatShadow,
      raisedShadow: raisedShadow ?? this.raisedShadow,
      floatingShadow: floatingShadow ?? this.floatingShadow,
    );
  }

  @override
  MusicManDesignTokens lerp(
    ThemeExtension<MusicManDesignTokens>? other,
    double t,
  ) {
    if (other is! MusicManDesignTokens) return this;

    Duration lerpDuration(Duration a, Duration b) =>
        Duration(
          microseconds:
              (a.inMicroseconds + (b.inMicroseconds - a.inMicroseconds) * t)
                  .round(),
        );

    double lerpDouble(double a, double b) => a + (b - a) * t;
    List<BoxShadow> lerpShadows(
      List<BoxShadow> a,
      List<BoxShadow> b,
    ) {
      if (a.isEmpty && b.isEmpty) return const [];
      final length = a.length > b.length ? a.length : b.length;
      return [
        for (var i = 0; i < length; i++)
          BoxShadow.lerp(
            i < a.length ? a[i] : const BoxShadow(),
            i < b.length ? b[i] : const BoxShadow(),
            t,
          )!,
      ];
    }

    return MusicManDesignTokens(
      design: t < 0.5 ? design : other.design,
      screenTransition:
          lerpDuration(screenTransition, other.screenTransition),
      playerRise: lerpDuration(playerRise, other.playerRise),
      tabSwitch: lerpDuration(tabSwitch, other.tabSwitch),
      micro: lerpDuration(micro, other.micro),
      progressTick: lerpDuration(progressTick, other.progressTick),
      cardRadius: lerpDouble(cardRadius, other.cardRadius),
      coverRadius: lerpDouble(coverRadius, other.coverRadius),
      chipRadius: lerpDouble(chipRadius, other.chipRadius),
      flatElevation: lerpDouble(flatElevation, other.flatElevation),
      raisedElevation:
          lerpDouble(raisedElevation, other.raisedElevation),
      floatingElevation:
          lerpDouble(floatingElevation, other.floatingElevation),
      flatShadow: lerpShadows(flatShadow, other.flatShadow),
      raisedShadow: lerpShadows(raisedShadow, other.raisedShadow),
      floatingShadow: lerpShadows(floatingShadow, other.floatingShadow),
    );
  }
}
