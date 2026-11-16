// Shared editorial building blocks (DESIGN.md: Identity motif, States).
//
// Every screen is built from these instead of inventing its own
// headers and states, so the magazine voice stays the same across
// the app: one stamp motif, one loading rule, one empty/error shape.

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// The vermillion stamp: a small accent square holding one kanji
/// (DESIGN.md: Identity motif). Decorative, so it stays out of the
/// semantics tree; the section title next to it carries the meaning.
class StampSquare extends StatelessWidget {
  final String kanji;
  final double size;

  const StampSquare({super.key, required this.kanji, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        color: scheme.primary,
        alignment: Alignment.center,
        child: Text(
          kanji,
          style: AppTheme.stampKanjiStyle(
            color: scheme.onPrimary,
            fontSize: size * 0.57,
          ),
        ),
      ),
    );
  }
}

/// A screen section header: stamp + title, an optional Japanese accent
/// word in accent text, and an optional trailing action. The title is
/// the section's heading; the stamp is the signature, not the label.
class SectionHeader extends StatelessWidget {
  final String kanji;
  final String title;
  final String? accentWord;
  final Widget? trailing;

  const SectionHeader({
    super.key,
    required this.kanji,
    required this.title,
    this.accentWord,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        StampSquare(kanji: kanji),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (accentWord != null) ...[
          const SizedBox(width: 8),
          Text(
            accentWord!,
            style: AppTheme.stampKanjiStyle(
              color: scheme.primary,
              fontSize: 14,
            ),
          ),
        ],
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing!,
        ],
      ],
    );
  }
}

/// Loading state (DESIGN.md: States): a thin vermillion rule and the
/// thing being loaded, in plain language. Never a bare spinner.
class EditorialLoadingState extends StatelessWidget {
  final String message;

  const EditorialLoadingState({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 12),
          Text(
            message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Empty state (DESIGN.md: States): why it is empty and the one
/// action that fills it. No bare "No data".
class EditorialEmptyState extends StatelessWidget {
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EditorialEmptyState({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

/// Error state (DESIGN.md: States): what failed, what to do next,
/// and Retry. Never a blank screen.
class EditorialErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const EditorialErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
