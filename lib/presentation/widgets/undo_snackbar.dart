// Shared toast helpers (DESIGN.md micro-interaction: "Toast with
// Undo"). A toast names the action and offers Undo; Undo reverses
// it. Toasts are shown through the shell's ScaffoldMessenger, so
// they appear above the mini-player strip (the shell Scaffold owns
// the bottom bar, and a SnackBar floats above it).

import 'package:material_ui/material_ui.dart';

/// Shows a toast naming [message] with an Undo button that runs
/// [onUndo]. Replaces any toast currently showing, so a fast run of
/// actions never stacks toasts.
void showUndoSnackBar(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
}) {
  showUndoSnackBarForMessenger(
    ScaffoldMessenger.of(context),
    message: message,
    onUndo: onUndo,
  );
}

/// The messenger form: use it when the context may be unmounted by
/// the time the toast is shown (the drag drop bar is removed when
/// the drag ends, so its context is gone before the save lands).
/// The messenger itself outlives the bar.
void showUndoSnackBarForMessenger(
  ScaffoldMessengerState messenger, {
  required String message,
  required VoidCallback onUndo,
}) {
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: SnackBarAction(label: 'Undo', onPressed: onUndo),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// A plain toast with no action, for confirmations that cannot be
/// undone (for example a share that fell back to the clipboard).
void showToast(BuildContext context, String message) {
  showToastForMessenger(ScaffoldMessenger.of(context), message);
}

/// The messenger form of [showToast], for the same reason as
/// [showUndoSnackBarForMessenger].
void showToastForMessenger(
    ScaffoldMessengerState messenger, String message) {
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ),
  );
}
