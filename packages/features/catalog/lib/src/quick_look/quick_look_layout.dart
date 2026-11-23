import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_catalog/src/widgets/cover_beside_title.dart';
import 'package:game_catalog/src/widgets/game_description.dart';
import 'package:game_catalog/src/widgets/owned_platform_chip.dart';
import 'package:game_filters/game_filters.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Wraps a quick look's [layout] in what its caller's additions share: the
/// state an import's section and its pinned button both read, for one
/// (#1037).
///
/// The quick look calls it in every state it draws, at one place in its tree,
/// so a host that is a `StatefulWidget` keeps its state from the seed to the
/// read's answer. A game the server refuses keeps the host and draws none of
/// the additions under it (#1040).
typedef QuickLookHost = Widget Function(BuildContext context, Widget layout);

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
/// description, the caller's sections and its actions, and under them all
/// the caller's pinned [footer].
///
/// With [onViewDetails], the title is the link to the game's page (#798);
/// without it, plain text.
///
/// Stateless, and package-internal: `GameQuickLook` holds the read and
/// feeds this, and `SearchHitQuickLook` draws a search hit through it with
/// no read at all. It brings its own scroll view, and it and its header are
/// built by a `LayoutBuilder`, which throws under intrinsic sizing, so it
/// needs the bounded box the pop-up gives it, sheet or dialog.
///
/// ## The pinned footer
///
/// [footer] sits under the scroll view, on screen wherever the body is
/// scrolled to, for an action that counts picks down a long list (#1037).
/// It is the quick look's own slot: a pop-up has no `BgePage`, and so no
/// `BgePage.footer`. It is laid out as that footer is, in a
/// [BgePinnedFooter], and so keeps its rules:
///
/// - **At most half the pop-up's height.** Past that it scrolls within
///   itself, so the body keeps at least half, and nothing in the footer is
///   out of reach at 200% text.
/// - **One tree with a footer and without.** The scroll view keeps its
///   position when the footer comes, goes or empties.
/// - **A footer that gets shorter moves no row.** The counting label drops
///   a line as the last expansion is unticked, and the offline note goes as
///   the connection returns. With the body scrolled to its end, the footer
///   keeps the room it would give back until the body leaves its end.
/// - **Tab takes the body first**, then the footer, wherever the body is
///   scrolled to.
///
/// One thing is the pop-up's own. A footer that comes to draw nothing takes
/// no room at once, its insets included: an import's button goes as the
/// body is redrawn around the progress, so there is no row to hold still,
/// and the room kept would be an empty strip where the button was.
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
    this.footer,
    this.onViewDetails,
    super.key,
  });

  /// The title, where it is the link to the game's page.
  static const Key titleLinkKey = Key('catalog.quick_look.title_link');
  static const Key factsKey = Key('catalog.quick_look.facts');
  static const Key platformsKey = Key('catalog.quick_look.platforms');

  /// The pinned footer's band, under the scroll view: the footer, its
  /// insets, and any room kept for one that got shorter. Always there, with
  /// no height while the footer draws nothing.
  static const Key footerKey = Key('catalog.quick_look.footer');

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

  /// The caller's own sections, below the description, after a gap. When
  /// all of them draw nothing, as `GameImportSection` does with no
  /// checklist and no import yet, the gap goes with them.
  final List<Widget> sections;

  /// The caller's own actions, at the foot of the scroll view. None draws
  /// no row.
  final List<Widget> actions;

  /// Pinned under the scroll view, at the line's end: see "The pinned
  /// footer". Null draws none.
  final Widget? footer;

  /// Opens the game's page, from the title. Null leaves the title plain
  /// text: there is nowhere to open.
  final VoidCallback? onViewDetails;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);

    // One tree with a footer and without, so the scroll view keeps its
    // position as the footer comes and goes.
    return BgePinnedFooter(
      // As tall as its content, which the pop-up is sized to.
      shrinkWrap: true,
      footerKey: footerKey,
      footerPadding: EdgeInsets.symmetric(
        horizontal: tokens.spaceMd,
        vertical: tokens.spaceSm,
      ),
      // It empties as the body is redrawn: see "The pinned footer".
      emptiedFooterKeepsRoom: false,
      // A traversal group each, as `BgePage` gives its content and its
      // footer: Tab orders stops by where they are on screen, and the rows
      // the body has yet to scroll to lie below the footer.
      body: FocusTraversalGroup(child: _body(context)),
      footer: FocusTraversalGroup(
        child: SingleChildScrollView(
          // Never the route's primary scroll view, which is the body's.
          primary: false,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            // As tall as the footer, not as the cap above.
            heightFactor: 1,
            child: footer ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  /// The scroll view, and all of the quick look but its footer.
  Widget _body(BuildContext context) {
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
          if (sections.isNotEmpty)
            _GapAboveUnlessEmpty(
              gap: tokens.spaceMd,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: sections,
              ),
            ),
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

/// [child] with [gap] above it, unless [child] has no height: then neither
/// it nor the gap takes any room, so sections that draw nothing leave no
/// strip under the description.
///
/// A render object, as a widget can't know before layout whether its child
/// draws anything, and the footer's band does the same with its insets
/// (`BgePinnedFooter`).
class _GapAboveUnlessEmpty extends SingleChildRenderObjectWidget {
  const _GapAboveUnlessEmpty({required this.gap, required super.child});

  final double gap;

  @override
  _RenderGapAboveUnlessEmpty createRenderObject(BuildContext context) =>
      _RenderGapAboveUnlessEmpty(gap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGapAboveUnlessEmpty renderObject,
  ) => renderObject.gap = gap;
}

class _RenderGapAboveUnlessEmpty extends RenderShiftedBox {
  _RenderGapAboveUnlessEmpty(this._gap) : super(null);

  double get gap => _gap;
  double _gap;

  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  /// The child's constraints: the room below the gap.
  BoxConstraints _inner(BoxConstraints constraints) => constraints.copyWith(
    minHeight: 0,
    maxHeight: math.max(0, constraints.maxHeight - _gap),
  );

  /// The size for a child of [child]'s size.
  Size _outer(BoxConstraints constraints, Size child) => constraints.constrain(
    Size(child.width, child.height == 0 ? 0 : child.height + _gap),
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return _outer(constraints, child.getDryLayout(_inner(constraints)));
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _withGap(super.computeMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _withGap(super.computeMaxIntrinsicHeight(width));

  double _withGap(double height) => height == 0 ? 0 : height + _gap;

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_inner(constraints), parentUsesSize: true);
    size = _outer(constraints, child.size);
    (child.parentData! as BoxParentData).offset = Offset(
      0,
      child.size.height == 0 ? 0 : _gap,
    );
  }
}
