import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_browse_bloc.dart';
import '../bloc/game_browse_event.dart';
import '../bloc/game_browse_state.dart';
import '../quick_look/game_quick_look_seed.dart';
import '../widgets/catalog_facts.dart';
import '../widgets/catalog_game_row.dart';
import '../widgets/catalog_slivers.dart';

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
            : (thumbnails) =>
                  layouts.writeThumbnails(ListLayoutScreen.games, thumbnails),
        onError: _layoutFailed,
        builder: (context, thumbnails, onChanged) => _GameBrowsePage(
          thumbnails: thumbnails,
          onLayoutChanged: onChanged,
          onOpen: onOpen,
          onSearch: onSearch,
          onQuickLook: onQuickLook,
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

        return BgePage.slivers(
          title: Text(l10n.catalogBrowseTitle),
          width: BgePageWidth.pane,
          // "Game 3 of 50": the rows loaded so far, once they are built.
          semanticChildCount: switch (state) {
            GameBrowseReady(:final games)
                when games.isNotEmpty && thumbnails != null =>
              games.length,
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
                    if (thumbnails)
                      BgeKeyedSliverGrid<Game>(
                        items: games,
                        keyOf: (game) => GameBrowseScreen.tileKey(game.id),
                        gridDelegate: bgeCoverGridDelegate(context),
                        itemBuilder: (context, game) =>
                            _BrowseTile(game: game, onQuickLook: onQuickLook),
                      )
                    else
                      BgeKeyedSliverList<Game>(
                        items: games,
                        keyOf: (game) => GameBrowseScreen.rowKey(game.id),
                        itemBuilder: (context, game) =>
                            _BrowseRow(game: game, onOpen: onOpen),
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
List<CatalogFact> _gameFacts(GameCatalogLocalizations l10n, Game game) =>
    rowFacts(
      l10n,
      year: game.publishYear,
      minPlayers: game.minPlayers,
      maxPlayers: game.maxPlayers,
      contentType: game.contentType,
    );

/// A game's cover alone, named as its row is: the title and the row's facts,
/// since no text is drawn to tell two covers apart (#710).
class _BrowseTile extends StatelessWidget {
  const _BrowseTile({required this.game, this.onQuickLook});

  final Game game;
  final void Function(BuildContext context, GameQuickLookSeed seed)?
  onQuickLook;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final open = onQuickLook;
    return BgeCoverTile(
      extent: null,
      label: [
        gameTitle(l10n, game.title, game.subtitle),
        ..._gameFacts(l10n, game).map((fact) => fact.spoken),
      ].join(l10n.catalogDetailSpokenSeparator),
      imageUrl: game.thumbnail,
      onTap: open == null
          ? null
          : () => open(context, GameQuickLookSeed.fromGame(game)),
    );
  }
}

class _BrowseRow extends StatelessWidget {
  const _BrowseRow({required this.game, this.onOpen});

  final Game game;
  final void Function(BuildContext context, String gameId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final open = onOpen;
    return CatalogGameRow(
      title: gameTitle(l10n, game.title, game.subtitle),
      thumbnailUrl: game.thumbnail,
      facts: _gameFacts(l10n, game),
      onTap: open == null ? null : () => open(context, game.id),
    );
  }
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
