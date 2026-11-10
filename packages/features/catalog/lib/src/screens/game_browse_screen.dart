import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_browse_bloc.dart';
import 'package:game_catalog/src/bloc/game_browse_event.dart';
import 'package:game_catalog/src/bloc/game_browse_state.dart';
import 'package:game_catalog/src/quick_look/game_quick_look_seed.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_game_row.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The server's games, a page at a time (#42).
///
/// The caller resolves the remote, the cache and the callbacks, and the
/// screen owns its bloc, as the collection list does (#44). Reached from the
/// home drawer; search and each game's detail are pushed from here.
///
/// The next page loads from a button at the end of the list rather than on
/// scroll: it is reachable by keyboard and by screen reader, and says what it
/// does.
///
/// The list starts in [initialSort], and a menu in the app bar changes it
/// (#615). The choice lasts as long as the screen is open: [initialSort] is
/// read once, when it opens, and nothing keeps the choice for the next time.
///
/// A toggle at the head of the content shows the games as rows or as a grid
/// of covers (#710), and [layouts] remembers the choice for the user. A row
/// opens the game's page; a cover opens its quick look. The toggle isn't in
/// the app bar: beside the back button, search and sort, it left the title a
/// few letters on a 320dp phone.
///
/// An expansion is shown under its base game (#711): its row under the base
/// game's row, and its cover in a strip that a badge on the base game's cover
/// opens under that cover's row.
class GameBrowseScreen extends StatelessWidget {
  const GameBrowseScreen({
    required this.remote,
    this.cache,
    this.gone,
    this.onOpen,
    this.onSearch,
    this.layouts,
    this.onQuickLook,
    this.initialSort = GameSort.title,
    super.key,
  });

  static const Key loadingKey = Key('catalog_browse.loading');
  static const Key emptyKey = Key('catalog_browse.empty');
  static const Key errorKey = Key('catalog_browse.error');
  static const Key deniedKey = Key('catalog_browse.denied');
  static const Key fromCacheBannerKey = Key('catalog_browse.from_cache');
  static const Key moreKey = Key('catalog_browse.more');
  static const Key moreFailedKey = Key('catalog_browse.more_failed');
  static const Key searchKey = Key('catalog_browse.search');
  static const Key sortKey = Key('catalog_browse.sort');
  static const Key layoutToggleKey = Key('catalog_browse.layout_toggle');

  static final BgeLogger _log = BgeLogger('bge.catalog.browse.layout');

  /// A remembered layout that could not be read or written (#710). Logged,
  /// not shown: the screen shows the list, or keeps the choice for this
  /// visit.
  static void _layoutFailed(
    Object error,
    StackTrace stackTrace, {
    required bool writing,
  }) => _log.warn(
    writing
        ? 'Remembering the layout choice failed'
        : 'Reading the remembered layout choice failed',
    error: error,
    stackTrace: stackTrace,
  );

  /// Per-tile key: `catalog_browse.tile_<gameId>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverGrid] puts around each tile, as
  /// [rowKey] is for rows.
  static Key tileKey(String gameId) => Key('catalog_browse.tile_$gameId');

  /// Per-row key: `catalog_browse.row_<gameId>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String gameId) => Key('catalog_browse.row_$gameId');

  /// Per-row key of an expansion shown under a base game:
  /// `catalog_browse.nested_row_<parentGameId>_<gameId>`.
  ///
  /// An expansion under two base games is drawn twice, so its key names the
  /// base game it is under (#711).
  static Key nestedRowKey(String parentGameId, String gameId) =>
      Key('catalog_browse.nested_row_${parentGameId}_$gameId');

  /// Per-tile key of an expansion's cover in the strip unfolded under its
  /// base game's: `catalog_browse.nested_tile_<parentGameId>_<gameId>`.
  ///
  /// Held by the wrapper around the cover, as [tileKey] is. It names the
  /// base game, as [nestedRowKey] does (#711).
  static Key nestedTileKey(String parentGameId, String gameId) =>
      Key('catalog_browse.nested_tile_${parentGameId}_$gameId');

  final GamesRemoteDataSource remote;

  /// The user-session games cache, or null where there is none. Without it
  /// nothing is cached and there is nothing to show offline.
  final GameRepository? cache;

  /// Each game found gone, wherever it was opened, as it is found: its row
  /// is taken down. Null hears of none.
  final Stream<String>? gone;

  /// Opens one game. Null leaves the rows inert.
  final void Function(BuildContext context, String gameId)? onOpen;

  /// Opens the search screen. Null offers no search.
  final void Function(BuildContext context)? onSearch;

  /// Where the list or thumbnails choice is kept, or null where there is no
  /// user session. Without it the toggle still works, for this visit.
  final ListLayoutRepository? layouts;

  /// Opens a game's quick look from its cover. Null leaves the covers inert.
  ///
  /// Called with the tile's own context.
  final void Function(BuildContext context, GameQuickLookSeed seed)?
  onQuickLook;

  /// The order the first read is in.
  final GameSort initialSort;

  @override
  Widget build(BuildContext context) {
    final layouts = this.layouts;
    return BlocProvider<GameBrowseBloc>(
      // go_router keys a page on its path, so going to another `?sort=` builds
      // this screen again in place, and a new sort needs a new bloc. A menu
      // choice survives any other rebuild.
      key: ValueKey<GameSort>(initialSort),
      create: (_) => GameBrowseBloc(
        remote: remote,
        cache: cache,
        gone: gone,
        initialSort: initialSort,
      )..add(const GameBrowseLoadRequested()),
      // A different user's repository reads again, rather than keeping the
      // previous user's answer.
      child: BgeRememberedLayout(
        key: ObjectKey(layouts),
        read: layouts == null
            ? null
            : () => layouts.readThumbnails(ListLayoutScreen.games),
        write: layouts == null
            ? null
            : ({required thumbnails}) => layouts.writeThumbnails(
                ListLayoutScreen.games,
                thumbnails: thumbnails,
              ),
        onError: _layoutFailed,
        builder: (context, onChanged, {required thumbnails}) =>
            BlocListener<GameBrowseBloc, GameBrowseState>(
              listenWhen: (previous, current) => _landedNothingShown(
                previous,
                current,
                thumbnails: thumbnails ?? false,
              ),
              listener: (context, _) => context.read<GameBrowseBloc>().add(
                const GameBrowseMoreRequested(),
              ),
              child: _GameBrowsePage(
                thumbnails: thumbnails,
                onLayoutChanged: onChanged,
                onOpen: onOpen,
                onSearch: onSearch,
                onQuickLook: onQuickLook,
              ),
            ),
      ),
    );
  }
}

class _GameBrowsePage extends StatelessWidget {
  const _GameBrowsePage({
    required this.thumbnails,
    required this.onLayoutChanged,
    this.onOpen,
    this.onSearch,
    this.onQuickLook,
  });

  /// Null until the remembered choice is read.
  final bool? thumbnails;
  final ValueChanged<bool> onLayoutChanged;
  final void Function(BuildContext context, String gameId)? onOpen;
  final void Function(BuildContext context)? onSearch;
  final void Function(BuildContext context, GameQuickLookSeed seed)?
  onQuickLook;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final search = onSearch;
    final thumbnails = this.thumbnails;
    final loading = BgeStateSliver(
      child: BgeLoadingState(
        key: GameBrowseScreen.loadingKey,
        label: l10n.catalogBrowseLoading,
      ),
    );

    return BlocBuilder<GameBrowseBloc, GameBrowseState>(
      builder: (context, state) {
        void retry() =>
            context.read<GameBrowseBloc>().add(const GameBrowseLoadRequested());

        // Placed once per build, for the count and for the covers or the
        // rows drawn (#711). Not while the choice is read, when neither is.
        final placed = switch (state) {
          final GameBrowseReady ready when thumbnails != null => _placeBrowse(
            ready,
          ),
          _ => null,
        };
        final rows = placed == null || thumbnails == true
            ? null
            : _browseRows(placed);

        return BgePage.slivers(
          title: Text(l10n.catalogBrowseTitle),
          width: BgePageWidth.pane,
          // "Game 3 of 50": the items loaded so far, once they are built. In
          // the list, a row for each nested expansion too; in the grid, the
          // top-level covers, as a strip's are a row of their own (#711).
          semanticChildCount: switch (state) {
            GameBrowseReady(:final games) when games.isNotEmpty =>
              rows?.length ?? placed?.length,
            _ => null,
          },
          actions: [
            if (search != null)
              IconButton(
                key: GameBrowseScreen.searchKey,
                tooltip: l10n.catalogSearchTitle,
                icon: const Icon(Icons.search),
                onPressed: () => search(context),
              ),
            // In every state, and never disabled: it is how a list that
            // failed in one order is read in another, and a button that goes
            // disabled drops the focus it holds (#607).
            _SortMenu(sort: state.sort),
          ],
          slivers: [
            // In every state, and first, so that it keeps its place and its
            // focus as the content below it changes (#607). Never disabled:
            // while the choice is read it shows the list, which is what a
            // missing choice means.
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: tokens.spaceMd),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: BgeLayoutToggle(
                    key: GameBrowseScreen.layoutToggleKey,
                    thumbnails: thumbnails ?? false,
                    onChanged: onLayoutChanged,
                    listLabel: l10n.catalogLayoutList,
                    thumbnailsLabel: l10n.catalogLayoutThumbnails,
                  ),
                ),
              ),
            ),
            ...switch (state) {
              GameBrowseLoading() => [loading],
              GameBrowseFailed() => [
                BgeStateSliver(
                  child: CatalogErrorState(
                    key: GameBrowseScreen.errorKey,
                    title: l10n.catalogBrowseFailedTitle,
                    body: l10n.catalogBrowseFailedBody,
                    onRetry: retry,
                  ),
                ),
              ],
              GameBrowseDenied() => [
                BgeStateSliver(
                  child: CatalogErrorState(
                    key: GameBrowseScreen.deniedKey,
                    icon: Icons.lock_outline,
                    title: l10n.catalogDeniedTitle,
                    body: l10n.catalogDeniedBody,
                    onRetry: retry,
                  ),
                ),
              ],
              GameBrowseReady(
                :final games,
                :final hasMore,
                :final fromCache,
                :final retrying,
              ) =>
                [
                  if (fromCache)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: tokens.spaceMd),
                        child: CatalogFromCacheBanner(
                          key: GameBrowseScreen.fromCacheBannerKey,
                          message: l10n.catalogBrowseFromCache,
                          onRetry: retry,
                          retrying: retrying,
                        ),
                      ),
                    ),
                  // Games found gone can empty a list that has more to load.
                  if (games.isEmpty && !hasMore)
                    BgeStateSliver(
                      child: BgeEmptyState(
                        key: GameBrowseScreen.emptyKey,
                        title: l10n.catalogBrowseEmpty,
                      ),
                    )
                  // Only the games wait for the choice, rather than flashing
                  // the wrong layout. A failure or an empty list is the same
                  // in either, so it shows as soon as it is known.
                  else if (thumbnails == null)
                    loading
                  else ...[
                    // One scope for the list and the grid, so a game's focus
                    // follows its item between top level and under its base
                    // game (#769, #711).
                    BgeFocusHandoffScope(
                      child: SliverMainAxisGroup(
                        slivers: [
                          if (thumbnails)
                            _BrowseCovers(
                              placed: placed!,
                              onQuickLook: onQuickLook,
                            )
                          else
                            BgeKeyedSliverList<_BrowseItem>(
                              items: rows!,
                              keyOf: (item) => item.parent == null
                                  ? GameBrowseScreen.rowKey(item.game.id)
                                  : GameBrowseScreen.nestedRowKey(
                                      item.parent!.id,
                                      item.game.id,
                                    ),
                              itemBuilder: (context, item) => BgeFocusHandoff(
                                identity: item.game.id,
                                place: item.parent?.id,
                                child: _BrowseRow(item: item, onOpen: onOpen),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SliverToBoxAdapter(child: _MoreFooter(state: state)),
                  ],
                ],
            },
          ],
        );
      },
    );
  }
}

/// Whether a page has just landed in [current] without a game to show that
/// [previous] didn't show, while the list has more (#711).
///
/// Every game on it can be held, waiting for a base game on a later page: a
/// page of expansions newer than their base games, sorted newest first. The
/// screen then reads the next page itself, rather than leaving an empty
/// screen, or a "Show more games" press that shows nothing, until one lands
/// that shows something or the list ends, when nothing is held.
///
/// In [thumbnails], only a new cover counts: an expansion nested under a
/// folded cover shows only as a higher count on its badge. One that lands
/// in the open strip doesn't count either, so such a page reads one more.
bool _landedNothingShown(
  GameBrowseState previous,
  GameBrowseState current, {
  required bool thumbnails,
}) {
  if (current is! GameBrowseReady ||
      !current.hasMore ||
      current.loadingMore ||
      current.loadMoreFailed ||
      current.retrying) {
    return false;
  }
  int shown(GameBrowseReady state) =>
      _shownCount(state, thumbnails: thumbnails);
  return switch (previous) {
    // The first page, or a retry's: is anything shown at all?
    GameBrowseLoading() => shown(current) == 0,
    GameBrowseReady(retrying: true) => shown(current) == 0,
    // The next page: did it show anything more?
    GameBrowseReady(loadingMore: true) => shown(current) <= shown(previous),
    _ => false,
  };
}

/// How many of [state]'s games are shown: the top-level covers in
/// [thumbnails], else the rows, at top level or nested.
int _shownCount(GameBrowseReady state, {required bool thumbnails}) {
  final placed = _placeBrowse(state);
  if (thumbnails) return placed.length;
  return {
    for (final top in placed) ...[
      top.item.id,
      for (final expansion in top.expansions) expansion.id,
    ],
  }.length;
}

/// Places the loaded games under their base games (#711).
///
/// An expansion that isn't nested under a loaded base game waits while any
/// of its base games is still to load. Once they are loaded, or the list
/// ends (`hasMore` false), it is placed: at top level, marked, if none of
/// them is shown, and at top level, unmarked, if those shown are all nested
/// (`placeExpansions` says why). Offline, `hasMore` is true until the cache's
/// last page is read, so the same rule holds. A page that shows nothing new
/// reads the next one ([_landedNothingShown]).
List<PlacedGame<Game>> _placeBrowse(GameBrowseReady state) => placeExpansions(
  state.games,
  gameIdOf: (game) => game.id,
  baseGamesOf: (game) => game.baseGames,
  contentTypeOf: (game) => game.contentType,
  complete: !state.hasMore,
);

/// One row of the list: a game, with the base game it is nested under, if
/// any.
class _BrowseItem {
  const _BrowseItem(this.game, {this.parent, this.missingBase = false});

  final Game game;
  final Game? parent;
  final bool missingBase;
}

/// [placed] as the rows drawn: each top-level game, then its expansions.
List<_BrowseItem> _browseRows(List<PlacedGame<Game>> placed) => [
  for (final top in placed) ...[
    _BrowseItem(top.item, missingBase: top.missingBase),
    for (final expansion in top.expansions)
      _BrowseItem(expansion, parent: top.item),
  ],
];

/// Which order to list the games in.
///
/// A menu opened from an icon, like the sent invites' filter, rather than a
/// [DropdownMenu], which cut its choice short at 320dp and 2.0 text. An entry
/// wraps instead.
class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort});

  final GameSort sort;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);

    return MenuAnchor(
      // Within the screen. Left unconstrained, the menu takes its widest
      // entry's width and clips past the edge.
      crossAxisUnconstrained: false,
      menuChildren: [
        for (final choice in GameSort.values)
          MenuItemButton(
            // An empty icon on the others keeps their labels in line.
            leadingIcon: Icon(choice == sort ? Icons.check : null),
            overflowAxis: Axis.vertical,
            // The chosen one is a no-op in the bloc: it only closes the menu.
            // The press arrives after a frame, by when the screen may be gone.
            onPressed: () {
              if (!context.mounted) return;
              context.read<GameBrowseBloc>().add(GameBrowseSortChanged(choice));
            },
            // The check is only drawn, so the label says it is chosen.
            // Inside the item, where it merges into the item's own node;
            // around it, it would stand as a node of its own.
            child: Semantics(
              selected: choice == sort,
              child: Text(_sortLabel(l10n, choice)),
            ),
          ),
      ],
      builder: (context, controller, _) => MergeSemantics(
        child: Semantics(
          expanded: controller.isOpen,
          child: IconButton(
            key: GameBrowseScreen.sortKey,
            tooltip: l10n.catalogBrowseSort,
            icon: const Icon(Icons.sort),
            onPressed: controller.isOpen ? controller.close : controller.open,
          ),
        ),
      ),
    );
  }
}

String _sortLabel(GameCatalogLocalizations l10n, GameSort sort) =>
    switch (sort) {
      GameSort.title => l10n.catalogBrowseSortTitle,
      GameSort.newest => l10n.catalogBrowseSortNewest,
    };

/// The facts a game's row shows under its title.
List<GameFact> _gameFacts(GameFiltersLocalizations l10n, Game game) => rowFacts(
  l10n,
  year: game.publishYear,
  minPlayers: game.minPlayers,
  maxPlayers: game.maxPlayers,
  contentType: game.contentType,
);

/// The games as a grid of covers (#710): the top-level games alone, with a
/// badge on a base game's cover that opens a strip of its expansions' covers
/// under its row (#711).
///
/// One game is unfolded at a time ([BgeUnfoldingCovers]). The unfold goes
/// once that game is no longer at top level with expansions, as when it is
/// found gone, so the grid is whole again and the game doesn't come back
/// unfolded.
///
/// Without [onQuickLook] the covers are inert, and carry no badge: a badge
/// that goes while it holds focus gives it to its cover, which an inert
/// cover can't take.
class _BrowseCovers extends StatelessWidget {
  const _BrowseCovers({required this.placed, this.onQuickLook});

  final List<PlacedGame<Game>> placed;
  final void Function(BuildContext context, GameQuickLookSeed seed)?
  onQuickLook;

  @override
  Widget build(BuildContext context) {
    final onQuickLook = this.onQuickLook;
    return BgeUnfoldingCovers<PlacedGame<Game>>(
      items: placed,
      keyOf: (placed) => GameBrowseScreen.tileKey(placed.item.id),
      idOf: (placed) => placed.item.id,
      hasStrip: (placed) => placed.expansions.isNotEmpty,
      itemBuilder: (context, placed, toggle, {required unfolded}) {
        final game = placed.item;
        return BgeFocusHandoff(
          identity: game.id,
          child: _BrowseTile(
            game: game,
            onQuickLook: onQuickLook,
            missingBase: placed.missingBase,
            expansionCount: placed.expansions.length,
            expanded: unfolded,
            onToggle: onQuickLook == null ? null : toggle,
          ),
        );
      },
      stripBuilder: (context, placed) => _BrowseStrip(
        parent: placed.item,
        expansions: placed.expansions,
        onQuickLook: onQuickLook,
      ),
    );
  }
}

/// A base game's expansions, as a row of covers under its cover's row
/// (#711). Each opens its quick look, as a cover in the grid does.
class _BrowseStrip extends StatelessWidget {
  const _BrowseStrip({
    required this.parent,
    required this.expansions,
    this.onQuickLook,
  });

  final Game parent;
  final List<Game> expansions;
  final void Function(BuildContext context, GameQuickLookSeed seed)?
  onQuickLook;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    return BgeShelf(
      heading: l10n.catalogExpansionsStrip(
        gameTitle(l10n, parent.title, parent.subtitle),
      ),
      previousLabel: l10n.catalogShelfPrevious,
      nextLabel: l10n.catalogShelfNext,
      children: [
        for (final game in expansions)
          BgeFocusHandoff(
            key: GameBrowseScreen.nestedTileKey(parent.id, game.id),
            identity: game.id,
            place: 'strip:${parent.id}',
            child: _BrowseTile(
              game: game,
              parent: parent,
              onQuickLook: onQuickLook,
            ),
          ),
      ],
    );
  }
}

/// A game's cover alone, named as its row is: the title and the row's facts,
/// since no text is drawn to tell two covers apart (#710).
///
/// In a strip under its base game, a shelf's size, and named as an
/// expansion of [parent], as its nested row is (#711). At top level, a grid
/// cell's size, marked when it is an expansion shown without its base game,
/// and with a badge for a base game's expansions when [onToggle] is given.
class _BrowseTile extends StatelessWidget {
  const _BrowseTile({
    required this.game,
    this.onQuickLook,
    this.parent,
    this.missingBase = false,
    this.expansionCount = 0,
    this.expanded = false,
    this.onToggle,
  });

  final Game game;
  final void Function(BuildContext context, GameQuickLookSeed seed)?
  onQuickLook;

  /// The base game whose strip the cover is in, or null in the grid.
  final Game? parent;

  /// Whether the game is an expansion shown without its base game.
  final bool missingBase;

  /// How many expansions are under the game.
  final int expansionCount;

  /// Whether they are shown.
  final bool expanded;

  /// Shows or hides them, or null for no badge.
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final open = onQuickLook;
    final parent = this.parent;
    final onToggle = this.onToggle;
    final title = gameTitle(l10n, game.title, game.subtitle);
    return BgeCoverTile(
      extent: parent == null ? null : BgeCoverTile.shelfExtent,
      label: [
        if (parent == null)
          title
        else
          l10n.catalogExpansionOf(
            title,
            gameTitle(l10n, parent.title, parent.subtitle),
          ),
        if (missingBase) _missingBaseNote(context, game),
        ..._gameFacts(
          GameFiltersLocalizations.of(context),
          game,
        ).map((fact) => fact.spoken),
      ].join(l10n.catalogDetailSpokenSeparator),
      imageUrl: game.thumbnail,
      marked: missingBase,
      expansions: expansionCount == 0 || onToggle == null
          ? null
          : BgeCoverExpansions(
              count: expansionCount,
              expanded: expanded,
              onToggle: onToggle,
              label: l10n.catalogExpansionsBadge(title, expansionCount),
              showLabel: l10n.catalogShowExpansions,
              hideLabel: l10n.catalogHideExpansions,
            ),
      onTap: open == null
          ? null
          : () => open(context, GameQuickLookSeed.fromGame(game)),
    );
  }
}

class _BrowseRow extends StatelessWidget {
  const _BrowseRow({required this.item, this.onOpen});

  final _BrowseItem item;
  final void Function(BuildContext context, String gameId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final open = onOpen;
    final game = item.game;
    final parent = item.parent;
    final title = gameTitle(l10n, game.title, game.subtitle);
    return CatalogGameRow(
      title: title,
      nested: parent != null,
      spokenTitle: parent == null
          ? null
          : l10n.catalogExpansionOf(
              title,
              gameTitle(l10n, parent.title, parent.subtitle),
            ),
      note: item.missingBase ? _missingBaseNote(context, game) : null,
      thumbnailUrl: game.thumbnail,
      facts: _gameFacts(GameFiltersLocalizations.of(context), game),
      onTap: open == null ? null : () => open(context, game.id),
    );
  }
}

/// The note on [game], an expansion shown without its base game (#711).
///
/// A game with no link to a base game has none on the server. One with a
/// link has one there, which the server lists only when it is in the
/// caller's own list, so read from the device's saved games its base game
/// was just never saved.
String _missingBaseNote(BuildContext context, Game game) {
  final l10n = GameCatalogLocalizations.of(context);
  final fromCache = context.select<GameBrowseBloc, bool>(
    (bloc) => switch (bloc.state) {
      GameBrowseReady(:final fromCache) => fromCache,
      _ => false,
    },
  );
  return fromCache && game.baseGames.isNotEmpty
      ? l10n.catalogBaseGameNotSaved
      : l10n.catalogBaseGameMissing;
}

/// The end of the list: the next page's button, its progress, or its
/// failure and a retry.
///
/// The button keeps its place while the page loads, disabled and relabelled,
/// rather than giving way to a bare spinner: a control that disappears
/// mid-interaction moves focus.
class _MoreFooter extends StatelessWidget {
  const _MoreFooter({required this.state});

  final GameBrowseReady state;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    void more() =>
        context.read<GameBrowseBloc>().add(const GameBrowseMoreRequested());

    if (!state.hasMore) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(top: tokens.spaceMd),
      child: Column(
        children: [
          if (state.loadMoreFailed)
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.catalogBrowseMoreFailed,
                key: GameBrowseScreen.moreFailedKey,
                textAlign: TextAlign.center,
              ),
            ),
          Semantics(
            liveRegion: state.loadingMore,
            child: OutlinedButton(
              key: GameBrowseScreen.moreKey,
              onPressed: state.loadingMore ? null : more,
              child: Text(
                state.loadingMore
                    ? l10n.catalogBrowseMoreLoading
                    : state.loadMoreFailed
                    ? l10n.catalogRetry
                    : l10n.catalogBrowseMore,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
