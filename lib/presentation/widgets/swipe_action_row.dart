// Reusable swipe quick-action row (DESIGN.md: "Swipe quick actions
// on a song row"). A horizontal drag to the left slides the row
// aside and reveals trailing action buttons behind it; releasing
// past half the reveal snaps open, releasing below it snaps shut.
// Tapping the open row, tapping anywhere else in the list, or
// opening another row closes it. Tapping an action runs it and
// closes the row.
//
// Motion follows the design tokens (DESIGN.md): in Complex the
// reveal slides over tokens.micro; in Compact micro is zero, so
// the reveal appears instantly. While the finger is down the row
// follows it directly (no lag), and only the release snap is
// animated.
//
// Gesture arena: this row's horizontal drag recognizer wins over
// an ancestor's horizontal drag (for example the tab swipe) when
// the drag starts on the row, because the inner recognizer claims
// first. A quick vertical scroll is unaffected: this recognizer
// only claims horizontal movement.
//
// Group 4 reuse: wrap any row (for example a full-player queue
// row) in SwipeActionRow with the actions that row needs. The
// actions are trailing only (swipe left reveals them); pass an
// empty-feeling single action such as Remove for a queue row.
// Use [SwipeActionRow.closeAnyOpen] from a list-level tap handler
// so tapping elsewhere closes an open row.

import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';

/// One trailing action behind a [SwipeActionRow]: an icon plus a
/// short label on a button [actionWidth] wide.
class SwipeAction {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const SwipeAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

/// Fades [child] out as the enclosing [SwipeActionRow] opens, so a
/// row's trailing icons (heart, overflow, move buttons) never sit on
/// top of the revealed actions mid-swipe or snapped open. The fade
/// completes by half reveal: the icons are gone before they can
/// reach the buttons behind the row. Outside a swipe row the child
/// is unchanged (opacity 1). The fade tracks the finger while
/// dragging and eases over the release snap otherwise (the design
/// tokens: zero duration in Compact, so it switches instantly there).
class SwipeTrailingFade extends StatelessWidget {
  final Widget child;

  const SwipeTrailingFade({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final scope = _SwipeRevealScope.of(context);
    final fraction = scope?.fraction ?? 0.0;
    final duration = scope?.duration ?? Duration.zero;
    final opacity = (1.0 - fraction * 2).clamp(0.0, 1.0);
    return AnimatedOpacity(
      opacity: opacity,
      duration: duration,
      child: child,
    );
  }
}

/// The reveal state of the nearest [SwipeActionRow] ancestor: 0 when
/// the row is shut, 1 when its actions are fully revealed.
class _SwipeRevealScope extends InheritedWidget {
  const _SwipeRevealScope({
    required this.fraction,
    required this.duration,
    required super.child,
  });

  final double fraction;
  final Duration duration;

  static _SwipeRevealScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SwipeRevealScope>();

  @override
  bool updateShouldNotify(_SwipeRevealScope oldWidget) =>
      fraction != oldWidget.fraction || duration != oldWidget.duration;
}

class SwipeActionRow extends StatefulWidget {
  final Widget child;

  /// Trailing actions, revealed left to right in list order when
  /// the row slides aside. Must not be empty.
  final List<SwipeAction> actions;

  /// Width of one action button. The full reveal is
  /// actions.length * actionWidth.
  final double actionWidth;

  const SwipeActionRow({
    super.key,
    required this.child,
    required this.actions,
    this.actionWidth = 72,
  }) : assert(actions.length > 0, 'SwipeActionRow needs an action');

  /// Closes whichever row is open, if any. Call it from a
  /// list-level tap handler so tapping elsewhere closes the row.
  static void closeAnyOpen() {
    for (final state in List.of(_openRows)) {
      state.close();
    }
  }

  static final _openRows = <_SwipeActionRowState>{};

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow> {
  double _dx = 0;
  bool _dragging = false;

  double get _maxReveal => widget.actions.length * widget.actionWidth;
  bool get _open => _dx < 0;

  @override
  void dispose() {
    SwipeActionRow._openRows.remove(this);
    super.dispose();
  }

  void _setOpen(bool open) {
    if (open) {
      for (final other in List.of(SwipeActionRow._openRows)) {
        if (other != this) other.close();
      }
      SwipeActionRow._openRows.add(this);
    } else {
      SwipeActionRow._openRows.remove(this);
    }
  }

  /// Slides the row shut (or leaves it shut). Safe to call when
  /// the row is already closed or unmounted.
  void close() {
    if (!mounted || _dx == 0) {
      SwipeActionRow._openRows.remove(this);
      return;
    }
    setState(() => _dx = 0);
    _setOpen(false);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragging = true;
      _dx = (_dx + details.delta.dx).clamp(-_maxReveal, 0.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    _dragging = false;
    final shouldOpen = -_dx > _maxReveal / 2;
    setState(() => _dx = shouldOpen ? -_maxReveal : 0.0);
    _setOpen(shouldOpen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final micro = theme.extension<MusicManDesignTokens>()?.micro ??
        Duration.zero;
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            color: scheme.surface,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final action in widget.actions)
                  SizedBox(
                    width: widget.actionWidth,
                    height: double.infinity,
                    child: InkWell(
                      onTap: () {
                        close();
                        action.onTap();
                      },
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(action.icon,
                              size: 22, color: scheme.onSurface),
                          const SizedBox(height: 2),
                          Text(
                            action.label,
                            style: theme.textTheme.labelSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // The reveal scope rides above the sliding row so the row's
        // own trailing icons (wrapped in SwipeTrailingFade by the
        // row widget) fade as the row slides aside: the row is
        // transparent, so without the fade the heart and overflow
        // would sit on top of the revealed actions mid-swipe.
        _SwipeRevealScope(
          fraction: (-_dx / _maxReveal).clamp(0.0, 1.0),
          duration: _dragging ? Duration.zero : micro,
          // The detector rides inside the transform with the row, so
          // when the row slides aside the detector stops covering the
          // revealed actions: hit testing follows one path, and a
          // detector left spanning the full width would win the hit
          // test over the buttons behind it. An open row swallows its
          // own tap to close instead of playing; a closed row leaves
          // the tap to the child.
          child: AnimatedContainer(
            duration: _dragging ? Duration.zero : micro,
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              onTap: _open ? close : null,
              child: AbsorbPointer(
                absorbing: _open,
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
