import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_catalog/src/widgets/cover_beside_title.dart';
import 'package:game_catalog/src/widgets/game_description.dart';
import 'package:game_catalog/src/widgets/owned_platform_chip.dart';
import 'package:game_filters/game_filters.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One platform chip a quick look lists. The [key] is the caller's, so a
/// chip keeps its place as the list changes.
@immutable
class QuickLookPlatform {
  const QuickLookPlatform({required this.key, required this.name, this.owned});

  final Key key;
  final String name;

  /// Whether the user owns the game on this platform (#799). Null where
  /// that isn't known: until the collection answers, after it fails, and
  /// where the session has no collection. The chip then says nothing of
  /// ownership, so a screen reader never hears "not in your collection" of
  /// a copy the user owns.
  final bool? owned;
}

/// What a quick look draws (#707), given what it has to show: the cover
/// beside the title, the facts, the platforms, a banner, the whole
/// description, the caller's sections and its actions.
///
/// With [onViewDetails], the title is the link to the game's page (#798);
/// without it, plain text.
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

  /// The title, where it is the link to the game's page.
  static const Key titleLinkKey = Key('catalog.quick_look.title_link');
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

  /// The caller's own actions, at the foot. None draws no row.
  final List<Widget> actions;

  /// Opens the game's page, from the title. Null leaves the title plain
  /// text: there is nowhere to open.
  final VoidCallback? onViewDetails;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final description = this.description;
    final banner = this.banner;

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
            Wrap(
              key: platformsKey,
              spacing: tokens.spaceSm,
              runSpacing: tokens.spaceSm,
              children: [
                for (final platform in platforms) _platformChip(l10n, platform),
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
          // The title opens the game's page, so the row is the caller's
          // alone (#798).
          if (actions.isNotEmpty) ...[
            const BgeGap.md(),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: tokens.spaceSm,
              overflowSpacing: tokens.spaceSm,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }

  /// [platform]'s chip: the detail page's owned chip where the user owns the
  /// game there, and a plain one otherwise (#799). Named for a screen reader
  /// by whether it is owned, where that's known.
  ///
  /// None has an action: adding the game on a platform, and opening a copy,
  /// are the detail page's (#707). So none pads itself out to a tap target,
  /// and owned and plain chips are the same height in a row.
  Widget _platformChip(
    GameCatalogLocalizations l10n,
    QuickLookPlatform platform,
  ) {
    final name = platform.name;
    Widget plain(String? semanticsLabel) => Chip(
      key: platform.key,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      label: GameFilterChipLabel(name, semanticsLabel: semanticsLabel),
    );
    return switch (platform.owned) {
      true => OwnedPlatformChip(
        key: platform.key,
        name: name,
        semanticsLabel: l10n.catalogQuickLookPlatformOwnedSpoken(name),
      ),
      false => plain(l10n.catalogQuickLookPlatformNotOwnedSpoken(name)),
      null => plain(null),
    };
  }

  /// The cover beside the title, with the subtitle and the publish year
  /// under the title, or the cover above them all where the title would
  /// have too little room beside it: see [CoverBesideTitle].
  Widget _header(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    final year = this.year;
    final onViewDetails = this.onViewDetails;
    final titleStyle = theme.textTheme.titleLarge;
    final titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onViewDetails == null)
          Semantics(header: true, child: Text(title, style: titleStyle))
        else
          _TitleLink(
            title: title,
            style: titleStyle,
            onOpen: onViewDetails,
          ),
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
      titleInset: onViewDetails == null
          ? 0
          : _TitleLink.insetOf(BgeTokens.of(context)).horizontal,
    );
  }
}

/// The quick look's title as the link to the game's page (#798): drawn in
/// the primary colour and underlined, so it reads as a link by its line as
/// well as its colour, and heard as the heading and as a link.
///
/// In high contrast its words take `onSurface`, as `primary` falls short of
/// 7:1 as text on a pop-up's container; the underline still says it is a
/// link.
///
/// iOS and Android read the heading and the link from one node. Elsewhere,
/// on the web and the desktops, a node has one role and a heading wins over
/// a link, which would leave no way to the page: there a level-2 heading
/// holds the link, as HTML's `<h2><a>` does. The desktops don't voice the
/// level yet, so there the link is heard without the heading.
///
/// The whole title, every line it wraps to, is one target at least
/// [BgeTokens.minTapTarget] each way. Enter or a tap opens the page, as a
/// screen reader's activation does. The target is moved back into the
/// margin before the words, where the ring reaches, but that strip, about
/// [BgeTokens.spaceSm] wide, takes no press: hit testing stops at the
/// titles column's bounds, so a press there misses the link. The target is
/// that much wider than the minimum, so what does take a press still meets
/// it. A
/// [BgeFocusRing] rings it from the keyboard; a mouse's or a trackpad's
/// press draws neither the ring nor the ink's focus tint
/// ([BgePointerFocus]).
///
/// It takes no focus from a tap: the page it opens removes the quick look,
/// so focus goes back to what opened the quick look, never to the title.
class _TitleLink extends StatefulWidget {
  const _TitleLink({
    required this.title,
    required this.style,
    required this.onOpen,
  });

  final String title;

  /// The heading's style, which the link colours and underlines.
  final TextStyle? style;

  /// Opens the game's page.
  final VoidCallback onOpen;

  /// The room between the ring and the words, which it would otherwise run
  /// through, as the event quick look's ringed lines have. The header
  /// counts it out of the room beside the cover ([CoverBesideTitle]).
  static EdgeInsets insetOf(BgeTokens tokens) => EdgeInsets.symmetric(
    horizontal: tokens.spaceSm,
    vertical: tokens.spaceXs,
  );

  @override
  State<_TitleLink> createState() => _TitleLinkState();
}

class _TitleLinkState extends State<_TitleLink>
    with BgePointerFocus<_TitleLink> {
  final _focusNode = FocusNode(debugLabel: 'QuickLookTitleLink');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    final colour = MediaQuery.highContrastOf(context)
        ? scheme.onSurface
        : scheme.primary;
    final radius = BorderRadius.circular(tokens.radiusSm);
    final inset = _TitleLink.insetOf(tokens);
    // The target is moved back by that room at its start, so the words
    // start where a plain title's do, in line with the subtitle under them,
    // and the ring goes out into the margin before them, as a browser's
    // focus outline does.
    final start = switch (Directionality.of(context)) {
      TextDirection.ltr => -inset.left,
      TextDirection.rtl => inset.right,
    };

    // One node for the words, the link and the ink's tap and focus; a
    // heading too where it can sit beside the link. There the level is what
    // makes it one: iOS and Android take the heading trait from the level
    // alone, and read the header flag only for scrolling and lists.
    final link = MergeSemantics(
      child: Semantics(
        header: !_headingHoldsLink,
        headingLevel: _headingHoldsLink ? null : 2,
        link: true,
        child: BgeFocusRing(
          borderRadius: radius,
          suppressed: pointerFocus,
          builder: (context, onFocusChange) => Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: QuickLookLayout.titleLinkKey,
              focusNode: _focusNode,
              onTapDown: (details) => notePointerPress(details.kind),
              onTap: widget.onOpen,
              onFocusChange: onFocusChange,
              // The theme's tint, with no strength while the focus is a
              // pointer's.
              focusColor: pointerFocusColor,
              borderRadius: radius,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  // The strip moved into the margin takes no press, so it
                  // comes on top of the width that does.
                  minWidth: tokens.minTapTarget + inset.left,
                  minHeight: tokens.minTapTarget,
                ),
                child: Padding(
                  padding: inset,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: 1,
                    child: Text(
                      widget.title,
                      // The ring and the ink hug the words, not the line.
                      textWidthBasis: TextWidthBasis.longestLine,
                      style: widget.style?.copyWith(
                        color: colour,
                        decoration: TextDecoration.underline,
                        decorationColor: colour,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Transform.translate(
      offset: Offset(start, 0),
      // Inside the move, so a screen reader's outline is where the ring is.
      child: _headingHoldsLink
          // No label of its own: the link names it. A level, not the header
          // flag, which on a node with children is a banner on the web.
          ? Semantics(container: true, headingLevel: 2, child: link)
          : link,
    );
  }

  /// Whether a heading node holds the link node, rather than one node
  /// being both: everywhere but iOS and Android.
  static bool get _headingHoldsLink =>
      // No VM test can reach the web arm: tests run with kIsWeb false.
      // ACCESSIBILITY_AUDIT's manual script, step 8, checks it by hand.
      kIsWeb ||
      switch (defaultTargetPlatform) {
        TargetPlatform.iOS || TargetPlatform.android => false,
        _ => true,
      };
}
