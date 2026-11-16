// Editorial screen route (DESIGN.md: Motion).
//
// Pushed screens slide in from the right with a short ease (about
// 200 ms) in Complex; in Compact the design is strictly MOTION 0, so
// the new screen appears instantly with no animation. The duration
// comes from the design tokens, so the two designs stay in sync with
// the rest of the app. No other visual change: same page, same
// reverse behavior.

import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';

/// Builds the route for a pushed screen, gated on the current design.
///
/// Reads the design tokens at construction: the transition duration
/// is zero in Compact and 200 ms in Complex. When the duration is
/// zero the child is returned with no animation; otherwise it slides
/// in from the right with a short ease, matching DESIGN.md.
Route<T> editorialRoute<T>(BuildContext context, WidgetBuilder builder) {
  final duration = Theme.of(context)
          .extension<MusicManDesignTokens>()
          ?.screenTransition ??
      Duration.zero;
  return PageRouteBuilder<T>(
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    pageBuilder: (context, animation, secondaryAnimation) =>
        builder(context),
    transitionsBuilder:
        (context, animation, secondaryAnimation, child) {
      if (duration == Duration.zero) return child;
      final slide = Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOut),
      );
      return SlideTransition(position: slide, child: child);
    },
  );
}
