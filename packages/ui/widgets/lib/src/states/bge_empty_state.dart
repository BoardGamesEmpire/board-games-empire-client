import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What a surface says when there is nothing to show: an optional icon, a
/// title, an optional body, and an optional action below them (#49).
///
/// ```dart
/// BgeEmptyState(
///   icon: Icons.event_busy_outlined,
///   title: l10n.eventsEmptyTitle,
///   body: l10n.eventsEmptyBody,
///   action: FilledButton(onPressed: onPlan, child: Text(l10n.eventsPlan)),
/// )
/// ```
///
/// Content, not a page: the caller supplies the page, or a `BgeStateSliver`
/// on a sliver one. Pairs with `BgeErrorState` and `BgeLoadingState`.
///
/// ## Accessibility
///
/// - **Title and body are one live region.** Assistive tech reads the whole
///   answer when it appears, as one announcement, without focus having to land
///   on it.
/// - **The icon says nothing.** It carries no semantic label; the title
///   already states what it depicts.
/// - **The action is not autofocused**, unlike `BgeErrorState`'s retry. An
///   empty list is an answer, not a failure waiting on the user, and moving
///   focus there would pull it off whatever the user was doing.
class BgeEmptyState extends StatelessWidget {
  /// Creates an empty state.
  const BgeEmptyState({
    required this.title,
    this.body,
    this.icon,
    this.action,
    super.key,
  });

  /// What is missing. Already localized.
  final String title;

  /// What the user can do about it. Already localized.
  final String? body;

  /// Depicts the emptiness. Shown at 48dp and never announced.
  final IconData? icon;

  /// The caller's own control, such as a button, below the text. Carries its
  /// own semantics and is not focused when it appears.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = this.icon;
    final body = this.body;
    final action = this.action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          ExcludeSemantics(
            child: Icon(
              icon,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const BgeGap.md(),
        ],
        MergeSemantics(
          child: Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                if (body != null) ...[
                  const BgeGap.sm(),
                  Text(
                    body,
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (action != null) ...[const BgeGap.md(), action],
      ],
    );
  }
}
