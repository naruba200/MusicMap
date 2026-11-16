// Appearance state (Phase A redesign): the selected theme and design,
// persisted in the settings Hive box and watched by the app root so a
// change re-skins the whole app live.
//
// Theme and Design are independent axes: setTheme never touches the
// design and setDesign never touches the theme. A long-press preview
// (previewTheme) temporarily overrides the effective theme and is
// cleared on release without touching the stored choice.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/appearance.dart';
import '../../data/repositories/settings_repository.dart';
import 'providers.dart';

/// The stored appearance choice, plus an optional transient preview.
class AppearanceSettings {
  const AppearanceSettings({
    required this.theme,
    required this.design,
    this.previewTheme,
  });

  final AppThemeName theme;
  final AppDesign design;

  /// Non-null while a theme swatch is long-pressed in Settings; the
  /// app renders in the preview theme until it is cleared.
  final AppThemeName? previewTheme;

  /// The theme the app actually renders in.
  AppThemeName get effectiveTheme => previewTheme ?? theme;

  AppearanceSettings copyWith({
    AppThemeName? theme,
    AppDesign? design,
    AppThemeName? previewTheme,
    bool clearPreview = false,
  }) =>
      AppearanceSettings(
        theme: theme ?? this.theme,
        design: design ?? this.design,
        previewTheme:
            clearPreview ? null : (previewTheme ?? this.previewTheme),
      );
}

class AppearanceNotifier extends StateNotifier<AppearanceSettings> {
  AppearanceNotifier(this._repo)
      : super(
          AppearanceSettings(
            theme: AppThemeName.tryParse(_repo.themeName),
            design: AppDesign.tryParse(_repo.design),
          ),
        );

  final SettingsRepository _repo;

  Future<void> setTheme(AppThemeName theme) async {
    await _repo.setThemeName(theme.name);
    state = state.copyWith(theme: theme, clearPreview: true);
  }

  Future<void> setDesign(AppDesign design) async {
    await _repo.setDesign(design.name);
    state = state.copyWith(design: design);
  }

  /// Shows the whole app in [theme] until [clearPreview] runs. The
  /// stored choice is untouched.
  void previewTheme(AppThemeName theme) {
    if (state.previewTheme == theme) return;
    state = state.copyWith(previewTheme: theme);
  }

  void clearPreview() {
    if (state.previewTheme == null) return;
    state = state.copyWith(clearPreview: true);
  }
}

final appearanceProvider =
    StateNotifierProvider<AppearanceNotifier, AppearanceSettings>(
  (ref) => AppearanceNotifier(ref.watch(settingsRepositoryProvider)),
);
