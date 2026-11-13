import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/screens/home_sections.dart';
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The authenticated landing surface (#129): a real home, replacing the
/// temporary `HomePlaceholderScreen` (#37).
///
/// Presentation-only. The navigation menu is not the page's: the navigation
/// shell hosts it above every signed-in page (#414). The button that opens
/// it is the navigation rail's where the rail shows, at medium and up with
/// two or more destinations, and otherwise this page's, in its app bar.
///
/// The page's content is the sections (#613), each built in its own feature
/// package and handed in through a slot. [HomeSections] decides their order
/// and which two pair up. With every slot null, which means a composition that
/// can offer none of them, the page shows a welcome line rather than nothing.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    this.notice,
    this.upcomingEvents,
    this.stats,
    this.newestGames,
    this.somethingToPlay,
    super.key,
  });

  /// Shown above the page's content when given: the notice that leads to
  /// the changes that couldn't sync (#190), which draws nothing while none
  /// are stuck.
  final Widget? notice;

  /// The upcoming events section.
  final Widget? upcomingEvents;

  /// The caller's stats section.
  final Widget? stats;

  /// The shelf of newly added games.
  final Widget? newestGames;

  /// The "something to play" shelf.
  final Widget? somethingToPlay;

  /// Key on the sections' column, which is absent with every slot null.
  static const Key sectionsKey = Key('home_sections');

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final hasSections =
        upcomingEvents != null ||
        stats != null ||
        newestGames != null ||
        somethingToPlay != null;

    return BgePage(
      width: hasSections ? BgePageWidth.pane : BgePageWidth.form,
      centerVertically: !hasSections,
      title: Text(l10n.homeTitle),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: hasSections
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.center,
        children: [
          ?notice,
          if (hasSections)
            HomeSections(
              key: sectionsKey,
              upcomingEvents: upcomingEvents,
              stats: stats,
              newestGames: newestGames,
              somethingToPlay: somethingToPlay,
            )
          else
            const _WelcomeLine(),
        ],
      ),
    );
  }
}

/// What the page shows with no sections to show.
class _WelcomeLine extends StatelessWidget {
  const _WelcomeLine();

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.dashboard_customize_outlined,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const BgeGap.md(),
        Semantics(
          header: true,
          child: Text(
            l10n.homeEmptyStateTitle,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        const BgeGap.sm(),
        Text(
          l10n.homeEmptyStateBody,
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
