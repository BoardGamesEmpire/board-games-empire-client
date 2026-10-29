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
import '../widgets/catalog_chip_label.dart';
import '../widgets/catalog_facts.dart';
import '../widgets/catalog_game_row.dart';
import '../widgets/catalog_slivers.dart';
import 'game_search_filter_sheet.dart';

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
/// clears it. The filter lasts while the screen is open.
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
  static const Key filtersButtonKey = Key('catalog_search.filters');
  static const Key filterSheetKey = Key('catalog_search.filter_sheet');
  static const Key clearAllKey = Key('catalog_search.filters_clear_all');

  /// The filter sheet's chip for [type].
  static Key filterKey(ContentType type) =>
      Key('catalog_search.filter_${type.name}');

  /// The filter sheet's chip for [type].
  static Key platformFilterKey(PlatformType type) =>
      Key('catalog_search.platform_${type.name}');

  /// The chip under the field for one filter in use: `content_<name>`,
  /// `platform_<name>`, `year`, `players` or `time`.
  static Key inUseKey(String id) => Key('catalog_search.in_use_$id');

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
  static const List<ContentType> filterTypes = [
    ContentType.baseGame,
    ContentType.expansion,
    ContentType.standaloneExpansion,
    ContentType.expandedEdition,
    ContentType.accessory,
    ContentType.bundle,
    ContentType.dlc,
    ContentType.mod,
    ContentType.port,
    ContentType.remake,
    ContentType.remaster,
  ];

  /// The platform types the filter offers, in the backend's order: every
  /// one but unknown, which names none.
  static const List<PlatformType> platformFilterTypes = [
    PlatformType.tabletop,
    PlatformType.console,
    PlatformType.portable,
    PlatformType.pc,
    PlatformType.mobile,
    PlatformType.arcade,
    PlatformType.other,
  ];

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
                      child: OutlinedButton.icon(
                        key: GameSearchScreen.filtersButtonKey,
                        onPressed: () => showGameSearchFilterSheet(context),
                        icon: const Icon(Icons.tune),
                        label: Text(
                          l10n.catalogSearchFiltersButton(
                            _filtersInUse(l10n, state.filter).length,
                          ),
                        ),
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
              child: _FiltersInUse(filter: state.filter),
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
          : () => open(context, gameId),
    );
  }

  Widget _sourceRow(BuildContext context, GameSearchSourceHit result) {
    final l10n = GameCatalogLocalizations.of(context);
    final hit = result.hit;
    final gameId = hit.gameId;
    final open = widget.onOpen;
    final import = widget.onImport;

    // A game the server already holds opens like one from this server;
    // anything else is an import. The import gets the screen's context, not
    // the row's: it outlasts the tap, and the row can go while it runs.
    final VoidCallback? onTap = gameId != null
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
    );
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

/// One filter in use, as its chip under the field shows it: [without] is
/// the filter once it is cleared.
typedef _InUse = ({String id, String label, GameSearchFilter without});

/// Every filter in use, in the sheet's order: one per chosen content type,
/// one per chosen platform type. The Filters button counts them.
List<_InUse> _filtersInUse(
  GameCatalogLocalizations l10n,
  GameSearchFilter filter,
) {
  final GameSearchFilter(:contentTypes, :platformTypes) = filter;
  return [
    for (final type in GameSearchScreen.filterTypes)
      if (contentTypes.contains(type))
        (
          id: 'content_${type.name}',
          label: contentTypeLabel(l10n, type)!,
          without: filter.copyWith(
            contentTypes: {...contentTypes}..remove(type),
          ),
        ),
    for (final type in GameSearchScreen.platformFilterTypes)
      if (platformTypes.contains(type))
        (
          id: 'platform_${type.name}',
          label: platformTypeLabel(l10n, type)!,
          without: filter.copyWith(
            platformTypes: {...platformTypes}..remove(type),
          ),
        ),
  ];
}

/// The filters in use, as chips under the field (#474). Tapping one, or its
/// remove button, clears it and searches again.
class _FiltersInUse extends StatelessWidget {
  const _FiltersInUse({required this.filter});

  final GameSearchFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final inUse = _filtersInUse(l10n, filter);
    if (inUse.isEmpty) return const SizedBox.shrink();

    void clear(GameSearchFilter without) =>
        context.read<GameSearchBloc>().add(GameSearchFilterChanged(without));

    return Wrap(
      spacing: tokens.spaceSm,
      runSpacing: tokens.spaceSm,
      children: [
        for (final (:id, :label, :without) in inUse)
          InputChip(
            key: GameSearchScreen.inUseKey(id),
            label: CatalogChipLabel(label),
            onPressed: () => clear(without),
            onDeleted: () => clear(without),
            deleteButtonTooltipMessage: l10n.catalogSearchFilterRemove(label),
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
