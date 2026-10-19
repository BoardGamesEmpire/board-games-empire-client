import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_search_bloc.dart';
import '../bloc/game_search_event.dart';
import '../bloc/game_search_state.dart';
import '../widgets/catalog_facts.dart';
import '../widgets/catalog_game_row.dart';
import '../widgets/catalog_slivers.dart';

/// Searches this server and its DataGateways by title (#42).
///
/// One page of results, in two sections: what this server holds, then what
/// its DataGateways found. Each result the server holds opens its detail.
/// A DataGateway result it does not hold goes to [onImport], which #43
/// supplies; until then those rows are inert content.
///
/// ## What a screen reader hears
///
/// The result count sits in a live region above the results, so a search
/// that lands is announced as "12 results" without moving focus from the
/// field the user is typing in. The page's scroll view counts the result
/// rows, not the headings, for "result 3 of 12".
class GameSearchScreen extends StatelessWidget {
  const GameSearchScreen({
    required this.remote,
    this.cache,
    this.sourceNames,
    this.onOpen,
    this.onImport,
    super.key,
  });

  static const Key fieldKey = Key('catalog_search.field');
  static const Key clearKey = Key('catalog_search.clear');
  static const Key idleKey = Key('catalog_search.idle');
  static const Key loadingKey = Key('catalog_search.loading');
  static const Key countKey = Key('catalog_search.count');
  static const Key noResultsKey = Key('catalog_search.no_results');
  static const Key fromCacheBannerKey = Key('catalog_search.from_cache');
  static const Key errorKey = Key('catalog_search.error');
  static const Key deniedKey = Key('catalog_search.denied');
  static const Key missingSourcesKey = Key('catalog_search.missing_sources');

  /// The filter chip for [type].
  static Key filterKey(ContentType type) =>
      Key('catalog_search.filter_${type.name}');

  /// Per-row key for a result this server holds:
  /// `catalog_search.server_<externalId>`.
  static Key serverRowKey(String externalId) =>
      Key('catalog_search.server_$externalId');

  /// Per-row key for a DataGateway's result:
  /// `catalog_search.source_<sourceId>_<externalId>`.
  static Key sourceRowKey(String sourceId, String externalId) =>
      Key('catalog_search.source_${sourceId}_$externalId');

  /// The content types the filter offers, in this order.
  ///
  /// The board-game kinds. The video-game ones (DLC, mods, ports, remakes,
  /// remasters) wait for the platform-type filter (#474), which is what
  /// would make them findable.
  static const List<ContentType> filterTypes = [
    ContentType.baseGame,
    ContentType.expansion,
    ContentType.standaloneExpansion,
    ContentType.expandedEdition,
    ContentType.accessory,
    ContentType.bundle,
  ];

  final GamesRemoteDataSource remote;

  /// The user-session games cache, searched when the server cannot be
  /// reached. Null where there is none.
  final GameRepository? cache;

  /// Reads each DataGateway's name, by id. Null where the user may not read
  /// DataGateways; every DataGateway result then goes unnamed.
  final Future<Map<String, String>> Function()? sourceNames;

  /// Opens a game this server holds, and completes when the user comes
  /// back from it: true when it turned out to be gone, and it is taken down
  /// from the results. Null leaves those rows inert.
  final Future<bool> Function(BuildContext context, String gameId)? onOpen;

  /// Imports a DataGateway result this server does not hold (#43). Null
  /// leaves those rows inert.
  final void Function(BuildContext context, String sourceId, GameSearchHit hit)?
  onImport;

  @override
  Widget build(BuildContext context) => BlocProvider<GameSearchBloc>(
    create: (_) =>
        GameSearchBloc(remote: remote, cache: cache, sourceNames: sourceNames),
    child: _GameSearchPage(onOpen: onOpen, onImport: onImport),
  );
}

class _GameSearchPage extends StatefulWidget {
  const _GameSearchPage({this.onOpen, this.onImport});

  final Future<bool> Function(BuildContext context, String gameId)? onOpen;
  final void Function(BuildContext context, String sourceId, GameSearchHit hit)?
  onImport;

  @override
  State<_GameSearchPage> createState() => _GameSearchPageState();
}

class _GameSearchPageState extends State<_GameSearchPage> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _changed(String text) =>
      context.read<GameSearchBloc>().add(GameSearchQueryChanged(text));

  void _clear() {
    _query.clear();
    _changed('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    return BlocBuilder<GameSearchBloc, GameSearchState>(
      builder: (context, state) => BgePage.slivers(
        title: Text(l10n.catalogSearchTitle),
        width: BgePageWidth.pane,
        semanticChildCount: switch (state) {
          GameSearchReady(:final resultCount) when resultCount > 0 =>
            resultCount,
          _ => null,
        },
        slivers: [
          SliverToBoxAdapter(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _query,
              builder: (context, value, _) => TextField(
                key: GameSearchScreen.fieldKey,
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _changed,
                decoration: InputDecoration(
                  labelText: l10n.catalogSearchFieldLabel,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          key: GameSearchScreen.clearKey,
                          tooltip: l10n.catalogSearchClear,
                          icon: const Icon(Icons.clear),
                          onPressed: _clear,
                        ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: tokens.spaceMd),
              child: _Filter(filter: state.filter),
            ),
          ),
          ..._results(context, state),
        ],
      ),
    );
  }

  List<Widget> _results(BuildContext context, GameSearchState state) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    void retry() =>
        context.read<GameSearchBloc>().add(const GameSearchRetryRequested());

    return switch (state) {
      GameSearchIdle() => [
        CatalogMessageSliver(
          child: Text(
            l10n.catalogSearchIdle,
            key: GameSearchScreen.idleKey,
            textAlign: TextAlign.center,
          ),
        ),
      ],
      GameSearchLoading() => [
        CatalogLoadingSliver(
          key: GameSearchScreen.loadingKey,
          message: l10n.catalogSearchLoading,
        ),
      ],
      GameSearchFailed() => [
        CatalogMessageSliver(
          child: CatalogErrorState(
            key: GameSearchScreen.errorKey,
            title: l10n.catalogSearchFailedTitle,
            body: l10n.catalogSearchFailedBody,
            onRetry: retry,
          ),
        ),
      ],
      GameSearchDenied() => [
        CatalogMessageSliver(
          child: CatalogErrorState(
            key: GameSearchScreen.deniedKey,
            icon: Icons.lock_outline,
            title: l10n.catalogDeniedTitle,
            body: l10n.catalogDeniedBody,
            onRetry: retry,
          ),
        ),
      ],
      final GameSearchReady ready => [
        if (ready.fromCache)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: tokens.spaceMd),
              child: CatalogFromCacheBanner(
                key: GameSearchScreen.fromCacheBannerKey,
                message: l10n.catalogSearchFromCache,
                onRetry: retry,
              ),
            ),
          ),
        // The announcement: a live region whose label changes with each
        // answer, so a screen reader reads the count when results land.
        SliverToBoxAdapter(
          child: Semantics(
            liveRegion: true,
            child: Text(
              l10n.catalogSearchResultCount(ready.resultCount),
              key: GameSearchScreen.countKey,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
        if (ready.resultCount == 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: tokens.spaceMd),
              child: Text(
                l10n.catalogSearchNoResults(ready.query),
                key: GameSearchScreen.noResultsKey,
              ),
            ),
          ),
        if (ready.onServer.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: CatalogSectionHeading(
              ready.fromCache
                  ? l10n.catalogSearchOnDevice
                  : l10n.catalogSearchOnServer,
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _serverRow(context, ready.onServer[index]),
              childCount: ready.onServer.length,
            ),
          ),
        ],
        if (ready.fromSources.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: CatalogSectionHeading(l10n.catalogSearchFromSources),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _sourceRow(context, ready.fromSources[index]),
              childCount: ready.fromSources.length,
              // The rows above hold the first indexes: one count across both
              // lists, as the page's semanticChildCount says.
              semanticIndexOffset: ready.onServer.length,
            ),
          ),
        ],
        if (ready.missingSources.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: tokens.spaceMd),
              child: _MissingSourcesNote(missing: ready.missingSources),
            ),
          ),
      ],
    };
  }

  Widget _serverRow(BuildContext context, GameSearchHit hit) {
    final l10n = GameCatalogLocalizations.of(context);
    final open = widget.onOpen;
    final gameId = hit.gameId;
    return CatalogGameRow(
      key: GameSearchScreen.serverRowKey(hit.externalId),
      title: hit.title,
      thumbnailUrl: hit.thumbnailUrl,
      facts: _facts(l10n, hit),
      onTap: open == null || gameId == null
          ? null
          : () => unawaited(_open(context, open, gameId)),
    );
  }

  Widget _sourceRow(BuildContext context, GameSearchSourceHit result) {
    final l10n = GameCatalogLocalizations.of(context);
    final hit = result.hit;
    final gameId = hit.gameId;
    final open = widget.onOpen;
    final import = widget.onImport;

    // A game the server already holds opens like one from this server;
    // anything else is an import.
    final VoidCallback? onTap = gameId != null
        ? (open == null ? null : () => unawaited(_open(context, open, gameId)))
        : (import == null
              ? null
              : () => import(context, result.source.id, hit));

    final sourceName = result.source.name;
    return CatalogGameRow(
      key: GameSearchScreen.sourceRowKey(result.source.id, hit.externalId),
      title: hit.title,
      thumbnailUrl: hit.thumbnailUrl,
      facts: [
        ..._facts(l10n, hit),
        if (sourceName != null) sameFact(sourceName),
      ],
      onTap: onTap,
    );
  }

  Future<void> _open(
    BuildContext context,
    Future<bool> Function(BuildContext context, String gameId) open,
    String gameId,
  ) async {
    final bloc = context.read<GameSearchBloc>();
    final gone = await open(context, gameId);
    if (gone && !bloc.isClosed) bloc.add(GameSearchGameGone(gameId));
  }

  static List<CatalogFact> _facts(
    GameCatalogLocalizations l10n,
    GameSearchHit hit,
  ) => rowFacts(
    l10n,
    year: hit.yearPublished,
    minPlayers: hit.minPlayers,
    maxPlayers: hit.maxPlayers,
    contentType: hit.contentType,
  );
}

/// The content-type filter: one chip per type, any number chosen. None
/// chosen does not narrow. The platform types the filter also carries are
/// kept as they are; offering them is #474.
class _Filter extends StatelessWidget {
  const _Filter({required this.filter});

  final GameSearchFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final selected = filter.contentTypes;

    void toggle(ContentType type, bool on) =>
        context.read<GameSearchBloc>().add(
          GameSearchFilterChanged(
            filter.withContentTypes(
              on ? {...selected, type} : ({...selected}..remove(type)),
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.catalogSearchFilterLabel,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        const BgeGap.sm(),
        Wrap(
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          children: [
            for (final type in GameSearchScreen.filterTypes)
              FilterChip(
                key: GameSearchScreen.filterKey(type),
                label: Text(contentTypeLabel(l10n, type)!),
                selected: selected.contains(type),
                onSelected: (on) => toggle(type, on),
              ),
          ],
        ),
      ],
    );
  }
}

/// The quiet note under the results naming the DataGateways that did not
/// answer, so a missing source does not read as one that found nothing.
///
/// It names them when it can name every one, and counts them otherwise.
class _MissingSourcesNote extends StatelessWidget {
  const _MissingSourcesNote({required this.missing});

  final List<GameSearchSource> missing;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final names = [for (final source in missing) ?source.name];

    return Text(
      names.length == missing.length
          ? l10n.catalogSearchMissingNamed(
              names.join(l10n.catalogSearchSourceSeparator),
            )
          : l10n.catalogSearchMissingUnnamed(missing.length),
      key: GameSearchScreen.missingSourcesKey,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
