import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A failure that fills its surface and offers a retry: an icon, a title, a
/// body, and a retry button, with room for further actions below it (#102).
///
/// ```dart
/// BgePage(
///   centerVertically: true,
///   child: BgeErrorState(
///     icon: Icons.cloud_off_outlined,
///     title: l10n.authSessionUnreachableTitle(serverName),
///     body: l10n.authSessionUnreachableBody,
///     retryLabel: l10n.authRetryButton,
///     onRetry: onRetry,
///   ),
/// )
/// ```
///
/// Content, not a page: the caller supplies the [BgePage] around it.
///
/// Replaces two views that re-implemented each other and drifted in both
/// directions: the bootstrap failure screen had no autofocus and announced its
/// title alone, while the session-unreachable view stretched its retry across
/// the page and hand-set the button semantics its `FilledButton` already had.
///
/// ## Accessibility
///
/// - **Title and body are one live region.** Assistive tech reads the whole
///   failure when it appears, as one announcement rather than a title followed
///   by a fragment, without focus having to land on it.
/// - **Retry is autofocused**, so a keyboard or switch user can act on the
///   failure immediately.
/// - **The icon says nothing.** It carries no semantic label, so a screen
///   reader hears the announcement and the actions only. The title already
///   states what the icon depicts.
/// - **Tap targets come from the theme** (`MaterialTapTargetSize.padded`,
///   STYLE_GUIDE §5). No local minimum size is set, so the buttons here match
///   every other button in the app.
class BgeErrorState extends StatelessWidget {
  /// Creates an error state.
  const BgeErrorState({
    required this.icon,
    required this.title,
    required this.body,
    required this.retryLabel,
    required this.onRetry,
    this.iconColor,
    this.retryKey,
    this.secondaryActions = const [],
    super.key,
  });

  /// Depicts the failure. Shown at 48dp and never announced.
  final IconData icon;

  /// The color of [icon]. Defaults to `onSurfaceVariant`.
  final Color? iconColor;

  /// What failed. Already localized — this package takes strings, not keys.
  final String title;

  /// What the user can do about it. Already localized.
  final String body;

  /// The retry button's label. Already localized.
  final String retryLabel;

  /// Called when the user taps retry.
  final VoidCallback onRetry;

  /// A key for the retry button, for callers whose tests find it by key.
  final Key? retryKey;

  /// Further actions, stacked below retry in order, such as a destructive
  /// recovery. Each is the caller's own button, carrying its own semantics.
  final List<Widget> secondaryActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 48,
          color: iconColor ?? theme.colorScheme.onSurfaceVariant,
        ),
        const BgeGap.md(),
        MergeSemantics(
          child: Semantics(
            liveRegion: true,
            child: Column(
              children: [
                Text(
                  title,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const BgeGap.sm(),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        const BgeGap.lg(),
        FilledButton(
          key: retryKey,
          autofocus: true,
          onPressed: onRetry,
          child: Text(retryLabel),
        ),
        for (final action in secondaryActions) ...[const BgeGap.sm(), action],
      ],
    );
  }
}
