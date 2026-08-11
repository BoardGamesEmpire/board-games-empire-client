import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The tone of a [BgeInlineBanner], which selects its color pair and icon.
enum BgeBannerTone {
  /// Something failed and the user needs to know. Uses the error roles.
  error,

  /// Neutral context or explanation.
  info,

  /// Something needs attention but nothing has failed.
  ///
  /// Uses the ember (tertiary) roles. Deliberately distinct from [error] in
  /// hue — the palette holds those ~54° apart precisely so a warning does not
  /// read as a failure. See `BgeColorSchemes`.
  warning,

  /// An action succeeded.
  success,
}

/// An inline message block: a tinted, rounded container with an icon, an
/// optional title, and a message (#165).
///
/// ```dart
/// BgeInlineBanner(
///   tone: BgeBannerTone.error,
///   title: l10n.serverAddErrorTitle,
///   message: failureMessage,
/// )
/// ```
///
/// Replaces three hand-rolled banners that had drifted apart — radius 8 in one
/// place and 12 in another, different padding in each, and one setting a raw
/// `TextStyle(color:)` instead of taking a role from the text theme.
///
/// ## Accessibility
///
/// - The whole banner is a **live region** by default ([announce]), so
///   assistive tech reads it when it appears rather than waiting for the user
///   to navigate onto it. Call sites previously had to remember to wrap this
///   themselves, and inconsistently did.
/// - It merges into **one** semantics node: a screen reader gets "error:
///   this URL is not a BGE server", not a decorative icon followed by two
///   fragments.
/// - **The icon is not decorative.** Tone here is conveyed by color *and*
///   icon, which is the project's stated answer to color-vision deficiency.
///   A banner that signalled failure by being red alone would be unusable for
///   the users most likely to be reading an error message carefully.
class BgeInlineBanner extends StatelessWidget {
  /// Creates an inline banner.
  const BgeInlineBanner({
    required this.message,
    this.tone = BgeBannerTone.info,
    this.title,
    this.action,
    this.announce = true,
    super.key,
  });

  /// The body text. Already localized — this package takes strings, not keys.
  final String message;

  /// Which color pair and icon to use.
  final BgeBannerTone tone;

  /// Optional bolder heading above [message].
  final String? title;

  /// Optional trailing action, e.g. a retry button.
  final Widget? action;

  /// Whether the banner announces itself on appearance. Leave true unless the
  /// surrounding screen already announces the same information.
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final (background, foreground, icon) = _resolve(theme.colorScheme);

    // The merge and the live region cover the ICON + TEXT only. [action] is
    // deliberately outside both: merging a button into the banner's node
    // strips its own semantics — a retry control stops being separately
    // focusable and activatable, and a screen-reader user gets one long
    // unactionable string where there was an error and a way out of it.
    // `UnverifiedSessionBanner` scopes it the same way, with its dismiss
    // IconButton outside the merged region.
    final message = MergeSemantics(
      child: Semantics(
        liveRegion: announce,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground, size: tokens.spaceLg),
            const BgeGap.md(axis: Axis.horizontal),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (title != null) ...[
                    Text(
                      title!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                    const BgeGap.xs(),
                  ],
                  Text(
                    this.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: message),
        if (action != null) ...[
          const BgeGap.sm(axis: Axis.horizontal),
          action!,
        ],
      ],
    );

    return Container(
      padding: EdgeInsets.all(tokens.spaceMd),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
      ),
      child: body,
    );
  }

  (Color background, Color foreground, IconData icon) _resolve(
    ColorScheme scheme,
  ) => switch (tone) {
    BgeBannerTone.error => (
      scheme.errorContainer,
      scheme.onErrorContainer,
      Icons.error_outline,
    ),
    BgeBannerTone.info => (
      scheme.secondaryContainer,
      scheme.onSecondaryContainer,
      Icons.info_outline,
    ),
    BgeBannerTone.warning => (
      scheme.tertiaryContainer,
      scheme.onTertiaryContainer,
      Icons.warning_amber_outlined,
    ),
    BgeBannerTone.success => (
      scheme.primaryContainer,
      scheme.onPrimaryContainer,
      Icons.check_circle_outline,
    ),
  };
}
