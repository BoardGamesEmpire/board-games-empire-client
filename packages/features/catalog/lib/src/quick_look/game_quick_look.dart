import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_detail_bloc.dart';
import '../bloc/game_detail_event.dart';
import '../bloc/game_detail_state.dart';
import '../screens/game_detail_screen.dart';
import '../widgets/catalog_chip_label.dart';
import '../widgets/catalog_facts.dart';
import '../widgets/catalog_slivers.dart';
import '../widgets/folded_description.dart';
import 'game_quick_look_seed.dart';

/// Opens [seed]'s [GameQuickLook] over the page (#707), through
/// [showBgePopup]: a sheet on a phone and a dialog on a wider window, on the
/// root navigator. The pop-up is named by the game's title.
///
/// **View full details opens from the pop-up's own context, not [context].**
/// The widget that opened the quick look can go while it is open: a read the
/// server refuses takes the cover it was opened from down from the home
/// shelves, and "Something to play" can draw new games under it. A push from
/// a context that has gone asserts. The pop-up's context is there for as
/// long as its button can be pressed, and is under the same router, so
/// [onViewDetails] pushes the detail page from it just as it would from
/// [context].
///
/// It doesn't close the quick look either. The page pushed over it removes
/// it once the page has arrived ([BgeRemoveWhenCovered]), so back from that
/// page lands where the quick look was opened, with no quick look.
///
/// Null [onViewDetails] offers no View full details. [sections] and
/// [actions] are [GameQuickLook]'s.
Future<void> showGameQuickLook(
  BuildContext context, {
  required GameQuickLookSeed seed,
  required GamesRemoteDataSource remote,
  GameRepository? cache,
  void Function(String gameId)? onGone,
  void Function(BuildContext context, String gameId)? onViewDetails,
  List<Widget> sections = const [],
  List<Widget> actions = const [],
}) => showBgePopup<void>(
  context,
  semanticLabel: seed.title,
  builder: (popup) => GameQuickLook(
    seed: seed,
    remote: remote,
    cache: cache,
    onGone: onGone,
    onViewDetails: onViewDetails == null
        ? null
        : () => onViewDetails(popup, seed.id),
    sections: sections,
    actions: actions,
  ),
);

/// A game's important facts in a pop-up, without leaving the page (#707):
/// its cover, title and publish year, its players, play time and age, the
/// platforms it is on, and its description folded to a few lines, with
/// **View full details** to open its page.
///
/// ## The seed shows at once
///
/// [seed] is what the caller already holds, and it is drawn on the first
/// frame. The rest comes from a [GameDetailBloc] read, which also tells
/// [onGone] of a game found gone. Until the read lands, the facts and the
/// description are the seed's [GameQuickLookSeed.game], if it has one.
/// Only the read knows the platforms.
///
/// ## A read that doesn't land
///
/// It never becomes an empty pop-up. A read that fails keeps what the seed
/// had, and one answered from this device's cache shows the cached copy,
/// unless the seed is a full row: a cached copy is never newer than that,
/// and only its platforms are shown. Either way a banner says some details couldn't be loaded, with a retry.
/// The retry keeps everything in place while it runs, itself included, so
/// it keeps focus (#607). It says it is trying for at least [retryDwell],
/// however soon its answer comes. A game the server refuses keeps the seed
/// and says it isn't available.
///
/// ## The header follows the read
///
/// The title and subtitle are the read's once it lands, as the facts are, so
/// a stale title in the seed is put right. The cover stays the seed's, which
/// would only flash if swapped for the same picture, unless the seed had
/// none.
///
/// ## No add to the collection
///
/// Nothing here adds the game to the collection, platform chips included,
/// which have no action. Adding is the detail page's, behind View full
/// details.
///
/// ## Callers add to it
///
/// [sections] sit below the description and [actions] beside View full
/// details, so a caller with more to offer about a game, such as an import
/// from search (#713), doesn't fork this.
///
/// ## Opened through [showGameQuickLook]
///
/// Host it through [showGameQuickLook], as #713's search results will, not
/// in a layout of your own. It brings its own scroll view, and its header's
/// `LayoutBuilder` throws under intrinsic sizing, so it needs the bounded
/// box the pop-up gives it.
class GameQuickLook extends StatelessWidget {
  const GameQuickLook({
    required this.seed,
    required this.remote,
    this.cache,
    this.onGone,
    this.onViewDetails,
    this.sections = const [],
    this.actions = const [],
    this.openLink = GameDetailScreen.openLinkExternally,
    super.key,
  });

  static const Key viewDetailsKey = Key('catalog.quick_look.view_details');
  static const Key factsKey = Key('catalog.quick_look.facts');
  static const Key platformsKey = Key('catalog.quick_look.platforms');

  /// The banner over a read that didn't land, with its retry.
  static const Key partialKey = Key('catalog.quick_look.partial');

  /// The banner over a game the server refuses.
  static const Key unavailableKey = Key('catalog.quick_look.unavailable');

  /// How long a retry says it is trying before its answer replaces that,
  /// however soon the answer comes, as `NewestGamesCubit.retryDwell` holds a
  /// shelf's.
  ///
  /// An answer the app already has, such as a read that fails at once
  /// offline and falls back to the cache, would otherwise land in the same
  /// frame as the retry: the banner would build once, with the answer, and
  /// the press would seem to do nothing. An answer that takes longer isn't
  /// held any further.
  static const Duration retryDwell = Duration(milliseconds: 300);

  /// What the caller already holds, shown at once.
  final GameQuickLookSeed seed;
  final GamesRemoteDataSource remote;

  /// The user-session games cache, or null where there is none.
  final GameRepository? cache;

  /// Told the game's id when it turns out to be gone. Null tells no one.
  final void Function(String gameId)? onGone;

  /// Opens the game's detail page. Null offers no View full details: where
  /// there is nowhere to open it, there never will be while this is open.
  final VoidCallback? onViewDetails;

  /// The caller's own sections, below the description.
  final List<Widget> sections;

  /// The caller's own actions, before View full details.
  final List<Widget> actions;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  @override
  Widget build(BuildContext context) => BlocProvider<GameDetailBloc>(
    key: ValueKey<String>(seed.id),
    create: (_) => GameDetailBloc(
      gameId: seed.id,
      remote: remote,
      cache: cache,
      onGone: onGone,
    )..add(const GameDetailLoadRequested()),
    child: _QuickLookBody(
      seed: seed,
      onViewDetails: onViewDetails,
      sections: sections,
      actions: actions,
      openLink: openLink,
    ),
  );
}

class _QuickLookBody extends StatefulWidget {
  const _QuickLookBody({
    required this.seed,
    required this.onViewDetails,
    required this.sections,
    required this.actions,
    required this.openLink,
  });

  final GameQuickLookSeed seed;
  final VoidCallback? onViewDetails;
  final List<Widget> sections;
  final List<Widget> actions;
  final Future<void> Function(Uri uri) openLink;

  @override
  State<_QuickLookBody> createState() => _QuickLookBodyState();
}

class _QuickLookBodyState extends State<_QuickLookBody> {
  /// The cover's side: smaller than the detail page's, as the quick look
  /// is a glance.
  static const double _coverExtent = 96;

  /// The narrowest the title may be beside the cover, in ems of its own
  /// scaled size. Narrower, the cover goes above the title instead.
  ///
  /// Rendered for #707 at 320dp and 2.0 text, the title beside the cover had
  /// 176dp, and "Wingspan" broke in the middle of the word. Eight ems is
  /// about a dozen letters of the title's face, so a long word in a title
  /// fits. In ems, as `BgeInlineBanner.minMessageWidthEms` is, so it follows
  /// the text size: at 1.0 the title stays beside the cover from 320dp up,
  /// and at 2.0 it goes under it on a phone.
  static const double _minTitleWidthEms = 8;

  /// Keeps the description's state, More or Less, as the platforms and the
  /// banner arrive above it.
  static const Key _descriptionKey = ValueKey('description');

  /// The read's last answer shown. A retry reads again from
  /// [GameDetailLoading], and this keeps what was shown on screen meanwhile.
  GameDetailState? _answer;

  /// Whether a retry is showing that it is trying.
  bool _retrying = false;

  /// Runs while a retry has yet to be up for [GameQuickLook.retryDwell].
  Timer? _dwell;

  /// An answer that came while [_dwell] ran, shown when it ends.
  GameDetailState? _held;

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }

  /// Each state the read goes through, one at a time. A builder would see
  /// only the last of those that land in one frame.
  void _onState(BuildContext context, GameDetailState state) {
    if (state is GameDetailLoading) {
      // The first read: the seed is showing.
      if (_answer == null) return;
      _held = null;
      _dwell ??= Timer(GameQuickLook.retryDwell, _dwelt);
      if (!_retrying) setState(() => _retrying = true);
      return;
    }
    if (_dwell != null) {
      _held = state;
      return;
    }
    _show(state);
  }

  void _dwelt() {
    _dwell = null;
    final held = _held;
    _held = null;
    if (held != null && mounted) _show(held);
  }

  void _show(GameDetailState answer) => setState(() {
    _answer = answer;
    _retrying = false;
  });

  @override
  Widget build(BuildContext context) =>
      BlocListener<GameDetailBloc, GameDetailState>(
        listener: _onState,
        child: _content(context, answer: _answer, retrying: _retrying),
      );

  /// What the quick look shows given the read's last [answer], null before
  /// the first. [retrying] while a retry reads again.
  Widget _content(
    BuildContext context, {
    required GameDetailState? answer,
    required bool retrying,
  }) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final seed = widget.seed;
    final ready = answer is GameDetailReady ? answer : null;
    // Offline, the newer of a full seed and the cached copy. Either can be
    // ahead: newest games reads the server and leaves the cache as it was,
    // and a quick look's read caches a newer row than the list it was
    // opened from still holds. A tie keeps the seed, the row tapped.
    final game = switch (ready) {
      GameDetailReady(fromCache: true, game: final cached) =>
        switch (seed.game) {
          final seeded? when !seeded.updatedAt.isBefore(cached.updatedAt) =>
            seeded,
          _ => cached,
        },
      _ => ready?.game ?? seed.game,
    };
    final platformGames = ready?.platformGames ?? const <PlatformGame>[];
    final facts = game == null ? const <CatalogFact>[] : playFacts(l10n, game);
    final description = game?.description;
    final banner = switch (answer) {
      GameDetailFailed() ||
      GameDetailReady(fromCache: true) => CatalogFromCacheBanner(
        key: GameQuickLook.partialKey,
        message: l10n.catalogQuickLookPartial,
        retrying: retrying,
        onRetry: () =>
            context.read<GameDetailBloc>().add(const GameDetailLoadRequested()),
      ),
      GameDetailUnavailable() => BgeInlineBanner(
        key: GameQuickLook.unavailableKey,
        tone: BgeBannerTone.warning,
        title: l10n.catalogDetailUnavailableTitle,
        message: l10n.catalogDetailUnavailableBody,
      ),
      _ => null,
    };
    final viewDetails = widget.onViewDetails;

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
          _header(context, game: game),
          if (facts.isNotEmpty) ...[
            const BgeGap.md(),
            CatalogFactsText(facts, key: GameQuickLook.factsKey),
          ],
          if (platformGames.isNotEmpty) ...[
            CatalogSectionHeading(l10n.catalogDetailAvailableOn),
            // Chips with no action: adding the game on a platform is the
            // detail page's.
            Wrap(
              key: GameQuickLook.platformsKey,
              spacing: tokens.spaceSm,
              runSpacing: tokens.spaceSm,
              children: [
                for (final platformGame in platformGames)
                  Chip(
                    key: ValueKey(platformGame.id),
                    label: CatalogChipLabel(platformGame.platformName),
                  ),
              ],
            ),
          ],
          if (banner != null) ...[const BgeGap.md(), banner],
          // Not under a MergeSemantics, which would read the folded
          // paragraphs out too.
          if (description != null && description.trim().isNotEmpty) ...[
            const BgeGap.md(),
            FoldedDescription(
              key: _descriptionKey,
              markdown: description,
              onOpenLink: widget.openLink,
            ),
          ],
          if (widget.sections.isNotEmpty) ...[
            const BgeGap.md(),
            ...widget.sections,
          ],
          if (widget.actions.isNotEmpty || viewDetails != null) ...[
            const BgeGap.md(),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: tokens.spaceSm,
              overflowSpacing: tokens.spaceSm,
              children: [
                ...widget.actions,
                if (viewDetails != null)
                  FilledButton.tonal(
                    key: GameQuickLook.viewDetailsKey,
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
  /// have too little room beside it: see [_minTitleWidthEms].
  ///
  /// [game] is the read's, or the seed's until it lands; see "The header
  /// follows the read".
  Widget _header(BuildContext context, {required Game? game}) {
    final l10n = GameCatalogLocalizations.of(context);
    final theme = Theme.of(context);
    final seed = widget.seed;
    final title = game?.title ?? seed.title;
    final subtitle = game == null ? seed.subtitle : game.subtitle;
    final year = game?.publishYear;
    final cover =
        seed.thumbnail ?? seed.image ?? game?.thumbnail ?? game?.image;
    final titleStyle = theme.textTheme.titleLarge;
    final titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(header: true, child: Text(title, style: titleStyle)),
        if (subtitle != null && subtitle.isNotEmpty)
          Text(subtitle, style: theme.textTheme.titleSmall),
        if (year != null) ...[
          const BgeGap.xs(),
          Text(l10n.catalogDetailPublished(yearText(l10n, year))),
        ],
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = BgeTokens.of(context).spaceMd;
        final minTitleWidth =
            _minTitleWidthEms *
            MediaQuery.textScalerOf(context)
                .scale(titleStyle?.fontSize ?? BgeTypography.titleLarge);
        final direction =
            constraints.maxWidth - _coverExtent - gap >= minTitleWidth
            ? Axis.horizontal
            : Axis.vertical;
        // One Flex either way, so the cover keeps its element, and its
        // image, when the text size or the width moves it.
        return Flex(
          direction: direction,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BgeThumbnail(
              url: cover,
              extent: _coverExtent,
              placeholderIcon: Icons.casino_outlined,
            ),
            BgeGap.md(axis: direction),
            if (direction == Axis.horizontal)
              Expanded(child: titles)
            else
              titles,
          ],
        );
      },
    );
  }
}
