// Appearance section for Settings (Phase A redesign): the theme picker
// (six named swatches) and the design toggle (Compact / Complex).
//
// The two axes are independent: picking a theme never touches the
// design and vice versa. The choice is stored on-device (Hive) and
// restored on launch. Tap a swatch to apply it; press and hold to
// preview the whole app in that theme, releasing reverts.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../providers/appearance_provider.dart';

class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _themePicker(context, ref),
        _designToggle(context, ref),
      ],
    );
  }

  Widget _themePicker(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    // The marker follows the effective theme, so a long-press preview
    // shows as the active swatch until release reverts it.
    final active = appearance.effectiveTheme;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Theme', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.25,
            children: [
              for (final themeName in AppThemeName.values)
                _themeSwatch(
                  theme: themeName,
                  selected: themeName == active,
                  onTap: () {
                    // A light tick confirms the apply without looking.
                    HapticFeedback.lightImpact();
                    notifier.setTheme(themeName);
                  },
                  onPreviewStart: () => notifier.previewTheme(themeName),
                  onPreviewEnd: () => notifier.clearPreview(),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Tap a theme to apply it. Press and hold to preview it '
            'across the whole app; releasing goes back.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// One swatch renders in the theme's own palette (not the current
  /// one), so the choice is visible before it is applied: the paper
  /// sheet, the accent stamp square, the name, and a check when
  /// active.
  Widget _themeSwatch({
    required AppThemeName theme,
    required bool selected,
    required VoidCallback onTap,
    required VoidCallback onPreviewStart,
    required VoidCallback onPreviewEnd,
  }) {
    final p = theme.palette;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Theme ${theme.displayName}',
      // The long-press lifecycle lives on the GestureDetector:
      // InkWell has no onLongPressEnd/onLongPressCancel, and it only
      // registers a long-press recognizer when onLongPress is set,
      // so the two do not fight over the gesture.
      child: GestureDetector(
        onLongPressStart: (_) => onPreviewStart(),
        onLongPressEnd: (_) => onPreviewEnd(),
        onLongPressCancel: onPreviewEnd,
        child: Material(
          color: p.paper,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(
              color: selected ? p.accent : p.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(width: 18, height: 18, color: p.accent),
                      const Spacer(),
                      if (selected)
                        Icon(Icons.check, size: 18, color: p.accent),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    theme.displayName,
                    style: TextStyle(
                      color: p.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _designToggle(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Design',
              style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 8),
          SegmentedButton<AppDesign>(
            segments: const [
              ButtonSegment(
                value: AppDesign.compact,
                label: Text('Compact'),
              ),
              ButtonSegment(
                value: AppDesign.complex,
                label: Text('Complex'),
              ),
            ],
            selected: {appearance.design},
            onSelectionChanged: (selected) {
              // A light tick confirms the switch without looking.
              HapticFeedback.lightImpact();
              notifier.setDesign(selected.single);
            },
          ),
        ],
      ),
    );
  }
}
