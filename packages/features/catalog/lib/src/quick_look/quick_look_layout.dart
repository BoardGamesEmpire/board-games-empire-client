import 'package:flutter/material.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_catalog/src/widgets/cover_beside_title.dart';
import 'package:game_catalog/src/widgets/game_description.dart';
import 'package:game_filters/game_filters.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One platform chip a quick look lists. The [key] is the caller's, so a
/// chip keeps its place as the list changes.
@immutable
class QuickLookPlatform {
  const QuickLookPlatform({required this.key, required this.name});

  final Key key;
  final String name;
}

/// What a quick look draws (#707), given what it has to show: the cover
/// beside the title, the facts, the platforms, a banner, the whole
/// description, the caller's sections and its actions.
///
/// Stateless, and package-internal: `GameQuickLook` holds the read and
/// feeds this, and `SearchHitQuickLook` draws a search hit through it with
/// no read at all. It brings its own scroll view, and its header's
/// `LayoutBuilder` throws under intrinsic sizing, so it needs the bounded
/// box the pop-up gives it.
class QuickLookLayout extends StatelessWidget {
  const QuickLookLayout({
    required this.title,
    required this.openLink,
    this.subtitle,
    this.year,
    this.coverUrl,
    this.facts = const [],
    this.platforms = const [],
    this.banner,
    this.description,
    this.sections = const [],
    this.actions = const [],
    this.onViewDetails,
    super.key,
  });

  static const Key viewDetailsKey = Key('catalog.quick_look.view_details');
  static const Key factsKey = Key('catalog.quick_look.facts');
  static const Key platformsKey = Key('catalog.quick_look.platforms');

  /// Keeps the description in place, its images loaded, as the platforms and
  /// the banner arrive above it.
  static const Key descriptionKey = ValueKey('description');

  /// The cover's side: smaller than the detail page's, as the quick look
  /// is a glance.
  static const double _coverExtent = 96;

  final String title;
  final String? subtitle;

  /// The publish year, shown under the title.
  final int? year;
  final String? coverUrl;
  final List<GameFact> facts;
  final List<QuickLookPlatform> platforms;

  /// Drawn between the platforms and the description.
  final Widget? banner;

  /// Markdown, drawn whole, as the detail page does (#1091). Null or blank
  /// draws none.
  final String? description;

  /// The caller's own sections, below the description.
  final List<Widget> sections;

  /// The caller's own actions, before View full details.
  final List<Widget> actions;

  /// Null offers no View full details.
  final VoidCallback? onViewDetails;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final description = this.description;
    final banner = this.banner;
    final viewDetails = onViewDetails;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          if (facts.isNotEmpty) ...[
            const BgeGap.md(),
            CatalogFactsText(facts, key: factsKey),
          ],
          if (platforms.isNotEmpty) ...[
            CatalogSectionHeading(l10n.catalogDetailAvailableOn),
            // Chips with no action: adding the game on a platform is the
            // detail page's.
            Wrap(
              key: platformsKey,
              spacing: tokens.spaceSm,
              runSpacing: tokens.spaceSm,
              children: [
                for (final platform in platforms)
                  Chip(
                    key: platform.key,
                    label: GameFilterChipLabel(platform.name),
                  ),
              ],
            ),
          ],
          if (banner != null) ...[const BgeGap.md(), banner],
          // Not under a MergeSemantics, which would read the paragraphs out
          // as one: a screen reader swipes to each on its own.
          if (description != null && description.trim().isNotEmpty) ...[
            const BgeGap.md(),
            GameDescription(
              key: descriptionKey,
              markdown: description,
              onOpenLink: openLink,
            ),
          ],
          if (sections.isNotEmpty) ...[const BgeGap.md(), ...sections],
          if (actions.isNotEmpty || viewDetails != null) ...[
            const BgeGap.md(),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: tokens.spaceSm,
              overflowSpacing: tokens.spaceSm,
              children: [
                ...actions,
                if (viewDetails != null)
                  FilledButton.tonal(
                    key: viewDetailsKey,
                    onPressed: viewDetails,
                    child: Text(l10n.catalogQuickLookViewDetails),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// The cover beside the title, with the subtitle and the publish year
  /// under the title, or the cover above them all where the title would
  /// have too little room beside it: see [CoverBesideTitle].
  Widget _header(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    final year = this.year;
    final titleStyle = theme.textTheme.titleLarge;
    final titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text(title, style: titleStyle)),
        if (subtitle != null && subtitle.isNotEmpty)
          Text(subtitle, style: theme.textTheme.titleSmall),
        if (year != null) ...[
          const BgeGap.xs(),
          Text(
            l10n.catalogDetailPublished(
              yearText(GameFiltersLocalizations.of(context), year),
            ),
          ),
        ],
      ],
    );

    return CoverBesideTitle(
      cover: BgeThumbnail(
        url: coverUrl,
        extent: _coverExtent,
        placeholderIcon: Icons.casino_outlined,
        whole: true,
      ),
      coverExtent: _coverExtent,
      titles: titles,
      titleFontSize: titleStyle?.fontSize ?? BgeTypography.titleLarge,
    );
  }
}
