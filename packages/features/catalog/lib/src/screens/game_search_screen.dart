import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_search_bloc.dart';
import 'package:game_catalog/src/bloc/game_search_event.dart';
import 'package:game_catalog/src/bloc/game_search_state.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_game_row.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Searches this server and its DataGateways by title (#42).
///
/// One page of results, in two sections: what this server holds, then what
/// its DataGateways found. Each result the server holds opens its detail.
/// A DataGateway result it does not hold goes to [onImport], which imports it
/// (#43); without one, those rows are inert content.
///
/// ## What a screen reader hears
///
/// The result count sits in a live region above the results, so a search
/// that lands is announced as "12 results" without moving focus from the
/// field the user is typing in. The page's scroll view counts the result
/// rows, not the headings, for "result 3 of 12".
///
/// ## Filters
///
/// A Filters button beside the field opens a sheet holding every control
/// (#474), and each filter in use shows as a chip under the field, which
/// clears it. The filter lasts while the screen is open. The sheet, the
/// button and the chips are `game_filters`' (#715), with their default
/// options: the screen holds the search's filter in its bloc, wraps it in a
/// [CollectionFilter] for them, and searches with the
/// [CollectionFilter.game] of what they hand back.
class GameSearchScreen extends StatelessWidget {
  const GameSearchScreen({
    required this.remote,
    this.cache,
    this.sourceNames,
    this.gone,
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
  static const Key unfilterableNoteKey = Key('catalog_search.unfilterable');
  static const Key platformOfflineNoteKey = Key(
    'catalog_search.platform_offline',
  );

  // The filter controls' keys are `GameFilterKeys`' (#715); these name them
  // for the search's callers and tests.
  static const Key filtersButtonKey = GameFilterKeys.button;
  static const Key filterSheetKey = GameFilterKeys.sheet;
  static const Key clearAllKey = GameFilterKeys.clearAll;

  /// The filter sheet's chip for [type].
  static Key filterKey(ContentType type) => GameFilterKeys.contentType(type);

  /// The filter sheet's chip for [type].
  static Key platformFilterKey(PlatformType type) =>
      GameFilterKeys.platformType(type);

  /// The chip under the field for one filter in use: `content_<name>`,
  /// `platform_<name>`, `year`, `players` or `time`.
  static Key inUseKey(String id) => GameFilterKeys.inUse(id);

  /// A range's From or To field in the filter sheet: [range] is `year`,
  /// `players` or `time`, and [end] is `from` or `to`.
  static Key rangeFieldKey(String range, String end) =>
      GameFilterKeys.rangeField(_range(range), from: _from(end));

  /// The filter sheet's switch that keeps games with no value for [range].
  static Key includeUnknownKey(String range) =>
      GameFilterKeys.includeUnknown(_range(range));

  /// The filter sheet's choice of [band] for the play time.
  static Key bandKey(GameLengthBand band) => GameFilterKeys.band(band);

  /// The range a key's `year`, `players` or `time` names.
  static CollectionFacet _range(String range) => switch (range) {
    'year' => CollectionFacet.publishYear,
    'players' => CollectionFacet.playerCount,
    'time' => CollectionFacet.playTime,
    _ => throw ArgumentError.value(range, 'range', 'names no range'),
  };

  /// Whether a key's [end] is `from`, not `to`.
  static bool _from(String end) => switch (end) {
    'from' => true,
    'to' => false,
    _ => throw ArgumentError.value(end, 'end', 'is neither from nor to'),
  };

  /// Per-row key for a result this server holds:
  /// `catalog_search.server_<externalId>`.
  static Key serverRowKey(String externalId) =>
      Key('catalog_search.server_$externalId');

  /// Per-row key for a DataGateway's result:
  /// `catalog_search.source_<sourceId>_<externalId>`.
  static Key sourceRowKey(String sourceId, String externalId) =>
      Key('catalog_search.source_${sourceId}_$externalId');

  /// The content types the filter offers, in this order: the board-game
  /// kinds, then the video-game ones.
  static const List<ContentType> filterTypes =
      GameFilterOptions.searchContentTypes;

  /// The platform types the filter offers, in the backend's order: every
  /// one but unknown, which names none.
  static const List<PlatformType> platformFilterTypes =
      GameFilterOptions.searchPlatformTypes;

  final GamesRemoteDataSource remote;

  /// The user-session games cache, searched when the server cannot be
  /// reached. Null where there is none.
  final GameRepository? cache;

  /// Reads each DataGateway's name, by id. Null where the user may not read
  /// DataGateways; every DataGateway result then goes unnamed.
  final Future<Map<String, String>> Function()? sourceNames;

  /// Each game found gone, wherever it was opened, as it is found: it is
  /// taken down from the results. Null hears of none.
  final Stream<String>? gone;

  /// Opens a game this server holds. Null leaves those rows inert.
  final void Function(BuildContext context, String gameId)? onOpen;

  /// Imports a DataGateway result this server does not hold (#43). Null
  /// leaves those rows inert.
  ///
  /// The context is the screen's, which stays mounted while the results
  /// change beneath an import.
  final void Function(BuildContext context, String sourceId, GameSearchHit hit)?
  onImport;

  @override
  Widget build(BuildContext context) => BlocProvider<GameSearchBloc>(
    create: (_) => GameSearchBloc(
      remote: remote,
      cache: cache,
      sourceNames: sourceNames,
      gone: gone,
    ),
    child: _GameSearchPage(onOpen: onOpen, onImport: onImport),
  );
}

class _GameSearchPage extends StatefulWidget {
  const _GameSearchPage({this.onOpen, this.onImport});

  final void Function(BuildContext context, String gameId)? onOpen;
  final void Function(BuildContext context, String sourceId, GameSearchHit hit)?
  onImport;

  @override
  State<_GameSearchPage> createState() => _GameSearchPageState();
}

class _GameSearchPageState extends State<_GameSearchPage> {
  /// The narrowest row, scaled by the text size, that holds the Filters
  /// button beside the field and leaves the field room for its label.
  static const double _besideFieldWidth = 320;

  final TextEditingController _query = TextEditingController();

  /// The Filters button's, which takes focus when the last chip under the
  /// field is removed, however the press arrived, if focus is free then
  /// (#715).
  final _filtersFocus = FocusNode(debugLabel: 'GameSearchScreen filters');

  @override
  void dispose() {
    _query.dispose();
    _filtersFocus.dispose();
    super.dispose();
  }

  void _changed(String text) =>
      context.read<GameSearchBloc>().add(GameSearchQueryChanged(text));

  void _clear() {
    _query.clear();
    _changed('');
  }

  /// Searches with a filter the sheet or a chip hands back: the part of it
  /// the server narrows by.
  static void _filterChanged(GameSearchBloc bloc, CollectionFilter filter) =>
      bloc.add(GameSearchFilterChanged(filter.game));

  /// Opens the filter sheet on the filter as the bloc holds it.
  static Future<void> _openFilters(BuildContext context) {
    // The sheet's route sits above the screen's provider, so the bloc is
    // held here. A field closing with the sheet commits too, after the
    // screen and its bloc may have gone.
    final bloc = context.read<GameSearchBloc>();
    return showGameFilterSheet(
      context,
      initial: CollectionFilter(game: bloc.state.filter),
      onChanged: (filter) {
        if (bloc.isClosed) return;
        _filterChanged(bloc, filter);
      },
    );
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
            // The Filters button sits beside the field where both have room,
            // and under it where they don't, as at a large text size, so the
            // field is never squeezed to its icons. One Flex either way keeps
            // the field, and its focus, when the layout changes.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final beside =
                    constraints.maxWidth >=
                    MediaQuery.textScalerOf(context).scale(_besideFieldWidth);
                return Flex(
                  direction: beside ? Axis.horizontal : Axis.vertical,
                  crossAxisAlignment: beside
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      flex: beside ? 1 : 0,
                      fit: FlexFit.tight,
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
                    BgeGap.sm(axis: beside ? Axis.horizontal : Axis.vertical),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: 1,
                      heightFactor: 1,
                      child: GameFiltersButton(
                        focusNode: _filtersFocus,
                        count: gameFiltersInUseCount(
                          CollectionFilter(game: state.filter),
                        ),
                        onPressed: () => _openFilters(context),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                top: tokens.spaceSm,
                bottom: tokens.spaceMd,
              ),
              child: GameFiltersInUse(
                filter: CollectionFilter(game: state.filter),
                onChanged: (filter) =>
                    _filterChanged(context.read<GameSearchBloc>(), filter),
                onEmptied: _filtersFocus.requestFocus,
              ),
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
        BgeStateSliver(
          child: BgeEmptyState(
            key: GameSearchScreen.idleKey,
            title: l10n.catalogSearchIdle,
          ),
        ),
      ],
      GameSearchLoading() => [
        BgeStateSliver(
          child: BgeLoadingState(
            key: GameSearchScreen.loadingKey,
            label: l10n.catalogSearchLoading,
          ),
        ),
      ],
      GameSearchFailed() => [
        BgeStateSliver(
          child: CatalogErrorState(
            key: GameSearchScreen.errorKey,
            title: l10n.catalogSearchFailedTitle,
            body: l10n.catalogSearchFailedBody,
            onRetry: retry,
          ),
        ),
      ],
      GameSearchDenied() => [
        BgeStateSliver(
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
        // The cache holds no platform types (#474), so say why nothing
        // matches rather than let it read as no results.
        if (ready.fromCache && ready.filter.platformTypes.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: tokens.spaceMd),
              child: Text(
                l10n.catalogSearchPlatformOffline,
                key: GameSearchScreen.platformOfflineNoteKey,
                style: Theme.of(context).textTheme.bodySmall,
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
              child: BgeEmptyState(
                key: GameSearchScreen.noResultsKey,
                title: l10n.catalogSearchNoResults(ready.query),
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
        if (ready.unfilterableSources.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: tokens.spaceMd),
              child: _UnfilterableNote(
                skipped: ready.unfilterableSources,
                filter: ready.filter,
              ),
            ),
          ),
      ],
    };
  }

  Widget _serverRow(BuildContext context, GameSearchHit hit) {
    final l10n = GameFiltersLocalizations.of(context);
    final open = widget.onOpen;
    final gameId = hit.gameId;
    return CatalogGameRow(
      key: GameSearchScreen.serverRowKey(hit.externalId),
      title: hit.title,
      thumbnailUrl: hit.thumbnailUrl,
      facts: _facts(l10n, hit),
      onTap: open == null || gameId == null
          ? null
          : () => open(context, gameId),
    );
  }

  Widget _sourceRow(BuildContext context, GameSearchSourceHit result) {
    final l10n = GameFiltersLocalizations.of(context);
    final hit = result.hit;
    final gameId = hit.gameId;
    final open = widget.onOpen;
    final import = widget.onImport;

    // A game the server already holds opens like one from this server;
    // anything else is an import. The import gets the screen's context, not
    // the row's: it outlasts the tap, and the row can go while it runs.
    final onTap = gameId != null
        ? (open == null ? null : () => open(context, gameId))
        : (import == null
              ? null
              : () => import(this.context, result.source.id, hit));

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
      // Only an import writes; opening a game the server holds does not.
      onlineOnly: gameId == null && import != null,
    );
  }

  static List<GameFact> _facts(
    GameFiltersLocalizations l10n,
    GameSearchHit hit,
  ) => rowFacts(
    l10n,
    year: hit.yearPublished,
    minPlayers: hit.minPlayers,
    maxPlayers: hit.maxPlayers,
    contentType: hit.contentType,
  );
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

/// The quiet note under the results naming the DataGateways the filter
/// skipped (#580): they can't apply its player count or play time. It names
/// the filter that caused it and the way back, the switch that keeps games
/// with no value.
///
/// It names them when it can name every one, and counts them otherwise, as
/// [_MissingSourcesNote] does.
class _UnfilterableNote extends StatelessWidget {
  const _UnfilterableNote({required this.skipped, required this.filter});

  final List<GameSearchSource> skipped;
  final GameSearchFilter filter;

  /// Whether [range] skips a DataGateway that can't apply it: the server
  /// asks every one when the range keeps unknown values.
  static bool _skips(GameSearchRange range) =>
      range.narrows && !range.includeUnknown;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final names = [for (final source in skipped) ?source.name];
    final count = skipped.length;
    final (players, time) = (
      _skips(filter.playerCount),
      _skips(filter.playTime),
    );

    // With both ranges skipping, the server names the sources but not which
    // range skipped each, so the note says either or both, and asks for both
    // switches: that alone is sure to bring every one back.
    final String text;
    if (names.length == count) {
      final sources = names.join(l10n.catalogSearchSourceSeparator);
      text = switch ((players, time)) {
        (true, false) => l10n.catalogSearchUnfilterableNamedPlayers(
          sources,
          count,
        ),
        (false, true) => l10n.catalogSearchUnfilterableNamedTime(
          sources,
          count,
        ),
        _ => l10n.catalogSearchUnfilterableNamedBoth(sources, count),
      };
    } else {
      text = switch ((players, time)) {
        (true, false) => l10n.catalogSearchUnfilterableUnnamedPlayers(count),
        (false, true) => l10n.catalogSearchUnfilterableUnnamedTime(count),
        _ => l10n.catalogSearchUnfilterableUnnamedBoth(count),
      };
    }

    return Text(
      text,
      key: GameSearchScreen.unfilterableNoteKey,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
