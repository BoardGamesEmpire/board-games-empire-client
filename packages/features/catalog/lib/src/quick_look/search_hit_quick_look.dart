import 'package:flutter/material.dart';
import 'package:game_catalog/src/quick_look/quick_look_layout.dart';
import 'package:game_catalog/src/screens/game_detail_screen.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';

/// Opens [hit]'s [SearchHitQuickLook] over the page (#713), through
/// [showBgePopup]: a sheet on a phone and a dialog on a wider window, on the
/// root navigator. The pop-up is named by the hit's title. [sections],
/// [actions], [footer] and [host] are [SearchHitQuickLook]'s.
Future<void> showSearchHitQuickLook(
  BuildContext context, {
  required GameSearchHit hit,
  String? sourceName,
  List<Widget> sections = const [],
  List<Widget> actions = const [],
  Widget? footer,
  QuickLookHost? host,
}) => showBgePopup<void>(
  context,
  semanticLabel: hit.title,
  builder: (_) => SearchHitQuickLook(
    hit: hit,
    sourceName: sourceName,
    sections: sections,
    actions: actions,
    footer: footer,
    host: host,
  ),
);

/// A search hit's important facts in a pop-up (#713), drawn from the hit
/// alone: nothing is read, so there is no banner.
///
/// This is for a DataGateway result the server doesn't hold. It has the
/// title, thumbnail, year, players, content type and platforms the search
/// found, and its Markdown summary as the description, shown whole. The title
/// is plain text, not a link: the game has no page here yet (#798).
///
/// [sourceName] is listed among the facts, as a search row lists it.
/// [sections] sit below the description, and [actions] at the scroll view's
/// foot. [footer] is pinned under the scroll view, and [host] wraps it all,
/// for state a section and the footer share. That is how the caller's
/// import goes in (#1037): a `GameImportPanel` as the host, its
/// `GameImportSection` among the sections, and its `GameImportButton`
/// pinned.
///
/// Host it through [showSearchHitQuickLook]: like `GameQuickLook`, it needs
/// the bounded box the pop-up gives it.
class SearchHitQuickLook extends StatelessWidget {
  const SearchHitQuickLook({
    required this.hit,
    this.sourceName,
    this.sections = const [],
    this.actions = const [],
    this.footer,
    this.host,
    this.openLink = GameDetailScreen.openLinkExternally,
    super.key,
  });

  static const Key factsKey = QuickLookLayout.factsKey;
  static const Key platformsKey = QuickLookLayout.platformsKey;

  /// The pinned footer's band: there with no height while nothing is
  /// pinned.
  static const Key footerKey = QuickLookLayout.footerKey;

  final GameSearchHit hit;

  /// The name of the source that found the hit, listed among its facts.
  final String? sourceName;

  /// The caller's own sections, below the description.
  final List<Widget> sections;

  /// The caller's own actions, at the foot.
  final List<Widget> actions;

  /// The caller's pinned action, under the scroll view (#1037). Null pins
  /// nothing.
  final Widget? footer;

  /// Wraps what the quick look draws, for state the [sections] and the
  /// [footer] share. Null wraps nothing.
  final QuickLookHost? host;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) {
    final l10n = GameFiltersLocalizations.of(context);
    final sourceName = this.sourceName;
    final host = this.host;
    final layout = QuickLookLayout(
      title: hit.title,
      // The year is the header's ("Published 2019"), so it is left out of
      // the facts, which would print it twice.
      year: hit.yearPublished,
      coverUrl: hit.thumbnailUrl,
      facts: [
        ...rowFacts(
          l10n,
          minPlayers: hit.minPlayers,
          maxPlayers: hit.maxPlayers,
          contentType: hit.contentType,
        ),
        if (sourceName != null) sameFact(sourceName),
      ],
      platforms: [
        for (final (index, platform) in hit.platforms.indexed)
          QuickLookPlatform(
            key: ValueKey('hit_platform_$index'),
            name: platform.name,
          ),
      ],
      description: hit.summary,
      sections: sections,
      actions: actions,
      footer: footer,
      openLink: openLink,
    );
    return host == null ? layout : host(context, layout);
  }
}
