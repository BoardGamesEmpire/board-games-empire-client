import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_search_bloc.dart';
import 'package:game_catalog/src/bloc/game_search_event.dart';
import 'package:game_catalog/src/bloc/game_search_state.dart';
import 'package:game_catalog/src/quick_look/game_quick_look.dart';
import 'package:game_catalog/src/quick_look/game_quick_look_seed.dart';
import 'package:game_catalog/src/quick_look/search_hit_quick_look.dart';
import 'package:game_catalog/src/search/data_gateway_search_grant.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_game_row.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_catalog/src/widgets/game_import_panel.dart';
import 'package:game_catalog/src/widgets/summary_text.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Searches this server and its DataGateways by title (#42).
///
/// One page of results, in two sections: what this server holds, then what
/// its DataGateways found. Each result opens a quick look over the page, not
/// an import or a page (#713). A game the server holds, from either section,
/// opens its [GameQuickLook], read by its id, whose View full details goes
/// to [onOpen]. A DataGateway result it doesn't hold opens a
/// [SearchHitQuickLook], drawn from the hit alone.
///
/// A DataGateway result's quick look also offers Import, or Re-import for a
/// game the server holds, with the expansions the user ticks: a
/// [GameImportPanel], shown only when [access] allows `create` on `Game` as
/// the quick look opens. The game the import makes opens through [onOpen].
/// Opening a quick look is a read, so every row opens one offline too; only
/// the import waits for the connection.
///
/// ## As results arrive
///
/// Given a [streamSource], the screen opens one channel on the server's
/// socket, and its searches stream in as each source answers (#473). This
/// server's own rows come first, all at once. Each DataGateway's rows join
/// the end of its own run as they arrive, and while the search runs, the
/// data sources section ends in a row saying so: a section's loading tail,
/// not a [BgeLoadingState]. The page's footer says it too, and then how
/// many were found, for a screen reader (see below), so the row in the list
/// is drawn and left out of the semantics tree. Until a row has arrived,
/// both say only that the search goes on, and the result count waits. Both
/// lists are keyed by result, so a row keeps its element, and the focus on
/// it, as rows arrive above it and push it down. A search that ends before
/// every source answered keeps what it found, and says some results may be
/// missing. Over REST the answer arrives whole, as it always did.
///
/// ## What a screen reader hears
///
/// Two things, each through a live region and none of it moving focus from
/// the field the user is typing in: the first results, and the end of the
/// search (#473).
///
/// - **An answer that comes whole is both at once:** one over REST, or from
///   this device. The result count sits in a live region above the results,
///   on screen as the answer lands, so it is announced as "12 results".
/// - **A search that streams says both from the page's footer,** which is
///   always built and on screen. A live region among the results would not
///   be heard once the user had scrolled away from it, and the answers of a
///   stream arrive while they may have. The footer says the search goes on,
///   heard as the first rows arrive, with this server's half or after it,
///   and then the final count, heard once as the search ends. Before the
///   first row it is quiet, as the search was heard as it began. The count
///   above the results says nothing for such a search: the answer says
///   whether it streamed ([GameSearchReady.streamed]).
///
/// The page's scroll view counts the result rows, not the headings, for
/// "result 3 of 12", and the count grows as rows arrive.
///
/// ## When the DataGateways are left out
///
/// A user the server refuses the DataGateways, or a session that never asks
/// them, still gets this server's games (#795). Under the data sources
/// heading, a quiet note takes the place of their rows: the server's own
/// message where one came, kept as sent, and the client's copy of the same
/// words where none did. The page's footer says it too, and that is what a
/// screen reader hears, once, as the answer lands: the note in the list sits
/// after this server's rows, and a page of them takes it out of the
/// semantics tree before it could be heard (see [_SearchFooter]). No
/// still-searching row follows it, in the list or the footer, as no
/// DataGateway is being searched (#473). A refused search that streams says
/// its end from the footer too, above the note.
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
    this.streamSource,
    this.cache,
    this.sourceNames,
    this.gone,
    this.onOpen,
    this.onGone,
    this.access,
    this.grant,
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

  /// The note under the data sources heading saying why none of their rows
  /// show (#795), where they would be.
  static const Key dataGatewaysRefusedKey = Key(
    'catalog_search.data_gateways_refused',
  );

  /// The footer's note saying the same, which is what a screen reader hears
  /// (#795).
  static const Key footerDataGatewaysRefusedKey = Key(
    'catalog_search.footer_data_gateways_refused',
  );
  static const Key missingSourcesKey = Key('catalog_search.missing_sources');
  static const Key unfilterableNoteKey = Key('catalog_search.unfilterable');
  static const Key stillSearchingKey = Key('catalog_search.still_searching');
  static const Key cutShortKey = Key('catalog_search.cut_short');

  /// The footer's word that the search is still running (#473).
  static const Key footerStillSearchingKey = Key(
    'catalog_search.footer_still_searching',
  );

  /// The footer's count of what a streamed search found, once it has ended
  /// (#473).
  static const Key footerCountKey = Key('catalog_search.footer_count');
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
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key serverRowKey(String externalId) =>
      Key('catalog_search.server_$externalId');

  /// Per-row key for a DataGateway's result:
  /// `catalog_search.source_<sourceId>_<externalId>`.
  ///
  /// Held by the list's wrapper, as [serverRowKey] is.
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

  /// Opens the channel on the server's socket that this screen's searches
  /// stream over (#473). Null searches over REST alone, as does a source
  /// whose session's connection has closed by the time the screen is built.
  final GameSearchStreamSource? streamSource;

  /// The user-session games cache, searched when the server cannot be
  /// reached. Null where there is none.
  final GameRepository? cache;

  /// Reads each DataGateway's name, by id. Null where the user may not read
  /// DataGateways; every DataGateway result then goes unnamed.
  final Future<Map<String, String>> Function()? sourceNames;

  /// Each game found gone, wherever it was opened, as it is found: it is
  /// taken down from the results. Null hears of none.
  final Stream<String>? gone;

  /// Opens a game this server holds: from its quick look's View full
  /// details, or once an import has made it. The context is the quick
  /// look's, which a page pushed from it removes once it has arrived. Null
  /// offers no View full details, and an import ends in place.
  final void Function(BuildContext context, String gameId)? onOpen;

  /// Told the id of a game a quick look finds gone. Null tells no one.
  final void Function(String gameId)? onGone;

  /// What this session may do on the server (#456), read as each quick look
  /// opens: `create` on `Game` offers a DataGateway result's import (#713).
  /// Null, as where the session has none to ask, offers none.
  final CallerAccessRepository? access;

  /// Whether this session may ask the DataGateways, and what the server
  /// said when it refused (#795). Null remembers for this screen alone; the
  /// shell passes the session's, so a refusal outlasts the screen.
  ///
  /// A quick look's import asks them for the game's expansions only while
  /// this says it may, and records a refusal here too: the bloc's
  /// [GameSearchBloc.grant] is the one both use.
  final DataGatewaySearchGrant? grant;

  @override
  Widget build(BuildContext context) => BlocProvider<GameSearchBloc>(
    // The bloc owns the channel and closes it with itself, so the channel
    // goes when the screen does.
    create: (_) => GameSearchBloc(
      remote: remote,
      cache: cache,
      stream: _openChannel(),
      sourceNames: sourceNames,
      gone: gone,
      grant: grant,
    ),
    child: _GameSearchPage(
      remote: remote,
      cache: cache,
      onOpen: onOpen,
      onGone: onGone,
      access: access,
    ),
  );

  /// This screen's channel on the server's socket, or null where its
  /// searches go over REST: there is no [streamSource], or its session's
  /// connection has closed, as under a route built just before sign-out
  /// (#473).
  GameSearchChannel? _openChannel() {
    final source = streamSource;
    if (source == null) return null;
    try {
      return source.open();
      // The source throws StateError once its session's connection has
      // closed. That is a race with sign-out, not a fault, and REST can
      // still answer the screen's searches.
      // ignore: avoid_catching_errors
    } on StateError {
      return null;
    }
  }
}

class _GameSearchPage extends StatefulWidget {
  const _GameSearchPage({
    required this.remote,
    this.cache,
    this.onOpen,
    this.onGone,
    this.access,
  });

  final GamesRemoteDataSource remote;
  final GameRepository? cache;
  final void Function(BuildContext context, String gameId)? onOpen;
  final void Function(String gameId)? onGone;
  final CallerAccessRepository? access;

  @override
  State<_GameSearchPage> createState() => _GameSearchPageState();
}

class _GameSearchPageState extends State<_GameSearchPage> {
  /// The narrowest row, scaled by the text size, that holds the Filters
  /// button beside the field and leaves the field room for its label.
  static const double _besideFieldWidth = 320;

  /// The refusal note's sliver (#795). Keyed, so the note keeps its node as
  /// slivers arrive above it, and a screen reader's place on it stays.
  static const Key _refusalSliverKey = Key(
    'catalog_search.data_gateways_refused_sliver',
  );

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
    final inset = tokens.spaceLg;

    return BlocBuilder<GameSearchBloc, GameSearchState>(
      builder: (context, state) => BgePage.slivers(
        title: Text(l10n.catalogSearchTitle),
        width: BgePageWidth.pane,
        semanticChildCount: switch (state) {
          GameSearchReady(:final resultCount) when resultCount > 0 =>
            resultCount,
          _ => null,
        },
        // The bottom inset ends the slivers instead. The page would put it
        // around the footer, which would then be a band with nothing in it.
        padding: EdgeInsets.fromLTRB(inset, inset, inset, 0),
        // On every build, in every state: BgePage builds a different tree
        // with a footer than without one, so a footer that came and went
        // would lose the scroll position and focus.
        footer: _SearchFooter(state: state),
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
          const SliverToBoxAdapter(child: BgeGap.lg()),
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
        // The announcement for an answer that came whole, over REST or from
        // this device: a live region whose label changes with each answer,
        // so a screen reader reads the count when results land.
        //
        // Not for a search that streamed (#473). Its answers arrive while
        // the user may have scrolled on, and a live region among the slivers
        // leaves the semantics tree once it is out of view and past the
        // cache extent, so the footer says what they say. While answers are
        // arriving the count would only change, and until a row has arrived
        // it waits, as "No results" would say the opposite of what is
        // happening.
        if (!ready.searching || ready.resultCount > 0)
          SliverToBoxAdapter(
            child: Semantics(
              liveRegion: !ready.streamed,
              child: Text(
                l10n.catalogSearchResultCount(ready.resultCount),
                key: GameSearchScreen.countKey,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
        // Nothing found yet is not an answer while the data sources are
        // still searching (#473).
        if (ready.resultCount == 0 && !ready.searching)
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
          BgeKeyedSliverList<GameSearchHit>(
            items: ready.onServer,
            keyOf: (hit) => GameSearchScreen.serverRowKey(hit.externalId),
            itemBuilder: _serverRow,
          ),
        ],
        // A refused search asked no DataGateways, so nothing is still being
        // searched there: its section is the heading and why (#795).
        if (ready.dataGatewaysRefused && !ready.fromCache) ...[
          SliverToBoxAdapter(
            child: CatalogSectionHeading(l10n.catalogSearchFromSources),
          ),
          SliverToBoxAdapter(
            // Keyed, so the note keeps its node as the count and the
            // no-results line arrive above it when the search ends (#473).
            key: _refusalSliverKey,
            child: Padding(
              padding: EdgeInsets.only(bottom: tokens.spaceMd),
              // Read where the DataGateways' rows would be, and heard from
              // the footer, which says the same (#795).
              child: Text(
                ready.refusalMessage ?? l10n.catalogSearchDataGatewaysRefused,
                key: GameSearchScreen.dataGatewaysRefusedKey,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ] else if (ready.fromSources.isNotEmpty || ready.searching) ...[
          // Headed while the search runs, before any of their rows, so the
          // still-searching row sits where they will (#473).
          SliverToBoxAdapter(
            child: CatalogSectionHeading(l10n.catalogSearchFromSources),
          ),
          if (ready.fromSources.isNotEmpty)
            BgeKeyedSliverList<GameSearchSourceHit>(
              items: ready.fromSources,
              keyOf: (result) => GameSearchScreen.sourceRowKey(
                result.source.id,
                result.hit.externalId,
              ),
              itemBuilder: _sourceRow,
              // The rows above hold the first indexes: one count across both
              // lists, as the page's semanticChildCount says.
              semanticIndexOffset: ready.onServer.length,
            ),
          // The section's loading tail, drawn here and said by the footer:
          // read here too, its words would come twice.
          if (ready.searching)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
                child: ExcludeSemantics(
                  child: _StillSearchingRow(
                    key: GameSearchScreen.stillSearchingKey,
                    noneYet: ready.resultCount == 0,
                  ),
                ),
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
        // Once the search has ended: an answer cut short can arrive before
        // its end, and the note says the search ended (#473).
        if (ready.cutShort && !ready.searching)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: tokens.spaceMd),
              child: const _CutShortNote(),
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
    return CatalogGameRow(
      title: hit.title,
      thumbnailUrl: hit.thumbnailUrl,
      facts: _facts(l10n, hit),
      // Every result this server sends has its game id.
      onTap: hit.gameId == null ? null : () => _openServerHit(hit),
    );
  }

  Widget _sourceRow(BuildContext context, GameSearchSourceHit result) {
    final l10n = GameFiltersLocalizations.of(context);
    final hit = result.hit;
    final sourceName = result.source.name;
    final summary = hit.summary == null ? null : summaryPlainText(hit.summary!);
    return CatalogGameRow(
      title: hit.title,
      thumbnailUrl: hit.thumbnailUrl,
      facts: [
        ..._facts(l10n, hit),
        if (sourceName != null) sameFact(sourceName),
      ],
      summary: summary == null || summary.isEmpty ? null : summary,
      onTap: () => _openSourceHit(result),
    );
  }

  /// Opens the quick look of a result this server holds, by its game id,
  /// with [sections] under its description.
  ///
  /// Each quick look opens from the screen's context rather than the row's,
  /// which can be taken down beneath it, as a game found gone is.
  void _openServerHit(GameSearchHit hit, {List<Widget> sections = const []}) =>
      unawaited(
        showGameQuickLook(
          context,
          seed: GameQuickLookSeed.fromHit(hit),
          remote: widget.remote,
          cache: widget.cache,
          onGone: widget.onGone,
          onViewDetails: widget.onOpen,
          sections: sections,
        ),
      );

  /// Opens a DataGateway result's quick look: the ordinary one where the
  /// server holds the game, and one drawn from the hit where it doesn't.
  /// Either offers the import where the session may import games, read now,
  /// as the quick look opens.
  void _openSourceHit(GameSearchSourceHit result) {
    final hit = result.hit;
    final mayImport =
        widget.access?.current.allows(ResourceType.game, AccessAction.create) ??
        false;
    final sections = [if (mayImport) _importPanel(result)];
    if (hit.isOnServer) {
      _openServerHit(hit, sections: sections);
      return;
    }
    unawaited(
      showSearchHitQuickLook(
        context,
        hit: hit,
        sourceName: result.source.name,
        sections: sections,
      ),
    );
  }

  /// The import of [result], with the expansions the user ticks where this
  /// session may ask the DataGateways. It shares the search's grant, so a
  /// refusal either meets is kept for both (#795).
  Widget _importPanel(GameSearchSourceHit result) {
    final grant = context.read<GameSearchBloc>().grant;
    final GameSearchSourceHit(:source, :hit) = result;
    final sourceName = source.name;
    final open = widget.onOpen;
    return GameImportPanel(
      remote: widget.remote,
      gatewayId: source.id,
      hit: hit,
      mayChooseExpansions: grant.mayAsk,
      grant: grant,
      sourceNames: {source.id: ?sourceName},
      // The pop-up's context, which the game's page removes once it has
      // arrived over it (#707).
      onImported: (popup, gameId) => open?.call(popup, gameId),
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

/// A small spinner, and a line saying the results shown are the first and
/// more may come, or, while nothing has been found, only that the search
/// goes on (#473).
///
/// Drawn twice while a search streams. As the data sources section's last
/// row it is the section's loading tail, not a [BgeLoadingState]: that
/// stands in for a whole surface with nothing to show yet, and this sits
/// in a section, under any results. There it is left out of the semantics
/// tree, as the footer says the same words. In the page's footer it
/// [announces] the first results: see [_SearchFooter].
class _StillSearchingRow extends StatelessWidget {
  const _StillSearchingRow({
    required this.noneYet,
    this.announces = false,
    super.key,
  });

  /// Whether nothing has been found yet.
  final bool noneYet;

  /// Whether this is the live region that says the first results have
  /// come: the footer's, once a row has arrived. Before then it is quiet,
  /// as the search was heard as it began.
  final bool announces;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    return Semantics(
      liveRegion: announces && !noneYet,
      child: Row(
        children: [
          // The line beside it says what it means.
          ExcludeSemantics(
            child: SizedBox.square(
              // Scaled with the line beside it, which it reads as part of,
              // rather than a speck beside 200% text.
              dimension: BgeTextScale.clampedOf(
                context,
              ).scale(tokens.spaceMd),
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          const BgeGap.sm(axis: Axis.horizontal),
          Expanded(
            child: Text(
              noneYet
                  ? l10n.catalogSearchStillSearchingNoneYet
                  : l10n.catalogSearchStillSearching,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// The page's footer (#795, #473): why a search shows only this server's
/// games, and what a streamed search says, the first results and the end,
/// said to a screen reader wherever the page is scrolled.
///
/// A live region among the slivers is in the semantics tree only while it
/// is near the view: past the cache extent the page drops it, and out of
/// view within it Android hears nothing. The note under the data sources
/// heading comes after this server's rows, and a page of them puts it there
/// before the answer lands; a stream's answers arrive while the user may
/// have scrolled far down a page of results. So all of it is said here,
/// where it is always built and on screen, and moves no row. Each thing it
/// says is a line of its own, one under another.
///
/// - **A search refused the DataGateways** shows the note from its answer
///   until the next search starts or the text is cleared, as a live region
///   heard once. The answer shown again, as games are found gone, the
///   DataGateways' names arrive or more of a stream's answers come, keeps
///   its node, so it isn't heard again. The next search's note is a node of
///   its own, heard as that answer lands: the note goes while the search
///   loads, and is keyed by the text searched for, which tells two answers
///   apart where no frame of loading came between them. Such a search asks
///   no DataGateway, so it is not said to be searching them, as its section
///   isn't (#795).
/// - **While a stream runs,** it says the search goes on. Once a row has
///   arrived that is a live region, heard once, with the first results: its
///   words don't change while more arrive, and it keeps its node. Before
///   then it is quiet, so the first row's arrival makes it a new node, heard
///   once on every platform. The web says nothing for a node repeating the
///   last words it said, as one would if the rows found were taken down and
///   others arrived.
/// - **When a stream ends,** it holds the final count, as a new live region,
///   heard once. It stays until the next search starts or the text is
///   cleared, and follows the count as games are found gone, as the count
///   above the results does for an answer that came whole. Where there is a
///   note it goes above it, which keeps its node and is not heard again: the
///   note can be long, and the footer holds at most half the body, so a
///   count under it could be out of the footer's view, where Android does
///   not hear it (at 320dp and twice the text size, it was).
/// - **Otherwise it renders nothing,** and pads itself only while it says
///   something, so the page leaves no empty band. An answer that came whole
///   is said by the count above the results, as it always was.
///
/// Given to the page on every build: [BgePage] builds a different tree with
/// a footer than without one.
class _SearchFooter extends StatelessWidget {
  const _SearchFooter({required this.state});

  final GameSearchState state;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final l10n = GameCatalogLocalizations.of(context);
    final said = [
      if (state case GameSearchReady(
        streamed: true,
        searching: false,
        :final resultCount,
      ))
        Semantics(
          key: GameSearchScreen.footerCountKey,
          liveRegion: true,
          child: Text(
            l10n.catalogSearchResultCount(resultCount),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      if (state case GameSearchReady(
        dataGatewaysRefused: true,
        fromCache: false,
        :final query,
        :final refusalMessage,
      ))
        KeyedSubtree(
          key: GameSearchScreen.footerDataGatewaysRefusedKey,
          child: Semantics(
            // A node of its own for each search's answer.
            key: ValueKey<String>(query),
            liveRegion: true,
            child: Text(
              refusalMessage ?? l10n.catalogSearchDataGatewaysRefused,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      if (state case GameSearchReady(
        searching: true,
        dataGatewaysRefused: false,
        :final resultCount,
      ))
        KeyedSubtree(
          // A new node when the first row arrives.
          key: ValueKey<bool>(resultCount == 0),
          child: _StillSearchingRow(
            key: GameSearchScreen.footerStillSearchingKey,
            noneYet: resultCount == 0,
            announces: true,
          ),
        ),
    ];
    if (said.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: tokens.spaceSm, bottom: tokens.spaceLg),
      // Each line at the page's measure, starting where the page's do.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spaceSm,
        children: said,
      ),
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

/// The quiet note under the results when the search ended before every
/// source answered (#473): the connection dropped, nothing came for too
/// long, or the server's search of the DataGateways failed as a whole. What
/// was found stands, and some results may be missing.
///
/// Beside [_MissingSourcesNote], which names the DataGateways the server
/// reported as not answering; this covers those it never reported on. Not a
/// live region: the footer's final count is what is heard as the search
/// ends, and this is there to be read with the results.
class _CutShortNote extends StatelessWidget {
  const _CutShortNote();

  @override
  Widget build(BuildContext context) => Text(
    GameCatalogLocalizations.of(context).catalogSearchCutShort,
    key: GameSearchScreen.cutShortKey,
    style: Theme.of(context).textTheme.bodySmall,
  );
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
