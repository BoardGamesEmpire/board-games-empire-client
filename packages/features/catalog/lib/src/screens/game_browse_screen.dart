import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_browse_bloc.dart';
import '../bloc/game_browse_event.dart';
import '../bloc/game_browse_state.dart';
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
class GameBrowseScreen extends StatelessWidget {
  const GameBrowseScreen({
    required this.remote,
    this.cache,
    this.gone,
    this.onOpen,
    this.onSearch,
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

  /// Per-row key: `catalog_browse.row_<gameId>`.
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

  @override
  Widget build(BuildContext context) => BlocProvider<GameBrowseBloc>(
    create: (_) =>
        GameBrowseBloc(remote: remote, cache: cache, gone: gone)
          ..add(const GameBrowseLoadRequested()),
    child: _GameBrowsePage(onOpen: onOpen, onSearch: onSearch),
  );
}

class _GameBrowsePage extends StatelessWidget {
  const _GameBrowsePage({this.onOpen, this.onSearch});

  final void Function(BuildContext context, String gameId)? onOpen;
  final void Function(BuildContext context)? onSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final search = onSearch;

    return BlocBuilder<GameBrowseBloc, GameBrowseState>(
      builder: (context, state) {
        void retry() =>
            context.read<GameBrowseBloc>().add(const GameBrowseLoadRequested());

        return BgePage.slivers(
          title: Text(l10n.catalogBrowseTitle),
          width: BgePageWidth.pane,
          // "Game 3 of 50": the rows loaded so far.
          semanticChildCount: switch (state) {
            GameBrowseReady(:final games) when games.isNotEmpty => games.length,
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
          ],
          slivers: switch (state) {
            GameBrowseLoading() => [
              CatalogLoadingSliver(
                key: GameBrowseScreen.loadingKey,
                message: l10n.catalogBrowseLoading,
              ),
            ],
            GameBrowseFailed() => [
              CatalogMessageSliver(
                child: CatalogErrorState(
                  key: GameBrowseScreen.errorKey,
                  title: l10n.catalogBrowseFailedTitle,
                  body: l10n.catalogBrowseFailedBody,
                  onRetry: retry,
                ),
              ),
            ],
            GameBrowseDenied() => [
              CatalogMessageSliver(
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
                  CatalogMessageSliver(
                    child: Text(
                      l10n.catalogBrowseEmpty,
                      key: GameBrowseScreen.emptyKey,
                      textAlign: TextAlign.center,
                    ),
                  )
                else ...[
                  SliverList.builder(
                    itemCount: games.length,
                    itemBuilder: (context, index) =>
                        _BrowseRow(game: games[index], onOpen: onOpen),
                  ),
                  SliverToBoxAdapter(child: _MoreFooter(state: state)),
                ],
              ],
          },
        );
      },
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
      key: GameBrowseScreen.rowKey(game.id),
      title: gameTitle(l10n, game.title, game.subtitle),
      thumbnailUrl: game.thumbnail,
      facts: rowFacts(
        l10n,
        year: game.publishYear,
        minPlayers: game.minPlayers,
        maxPlayers: game.maxPlayers,
        contentType: game.contentType,
      ),
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
