import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/bloc/game_collection_list_bloc.dart';
import 'package:game_collection/src/bloc/game_collection_list_event.dart';
import 'package:game_collection/src/bloc/game_collection_list_state.dart';
import 'package:game_collection/src/picker/collection_entry_picker.dart';
import 'package:game_collection/src/screens/collection_list_controls.dart';
import 'package:game_collection/src/screens/collection_list_items.dart';
import 'package:game_collection/src/screens/collection_rows.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The collection list (#44): every game the signed-in user owns, read
/// reactively from the local cache.
///
/// The household list's shape (`HouseholdListScreen`): the caller resolves
/// the repository, the optional hydration stream and the callbacks, and the
/// screen owns its bloc. Loading, empty, rows and error come from a sealed
/// state; a failed refresh is a banner over whatever the cache holds, with
/// a retry where the composition can run one, and it stays up until a pass
/// completes. Only a retry the user pressed is narrated; passes started by
/// entry, reconnect or resume are not.
///
/// ## Refreshing by hand, by pull or by button (#717)
///
/// A pull down on the list and the app bar's refresh button send the
/// banner's own retry event, so a pass started either way is the one the
/// banner reports, exactly as if its retry had been pressed. A pass already
/// running is joined, not doubled, and the pull's spinner ends with it. The
/// button is the route for a mouse, a keyboard and a screen reader, none of
/// which can pull. Both work on every surface, and neither is offered where
/// there is no [onRetry]. The button's label says a pass is running on every
/// surface too, since the error and loading surfaces have no banner to say
/// it; over the rows, the banner stays the one narrator.
///
/// ## The page is thin (#44)
///
/// The list itself is [GameCollectionListSliver], and this screen is a
/// `BgePage` around it, with a header at its head, plus the bloc it reads.
/// #46's two-pane form can host the sliver beside the detail screen without
/// this page's app bar or header.
///
/// ## Search, filters and sort (#715)
///
/// The header is a search field, the Filters button with the sheet it
/// opens, the sort button with its menu, the layout toggle, a chip for each
/// filter in use, and, while anything narrows the list, how many games it
/// shows of how many are owned, read out as it changes. The filter and the
/// sort are the bloc's, so they last as long as the screen.
///
/// A filter that leaves nothing shows "No games match" with Clear filters,
/// which resets the search and the filters but not the sort. An empty
/// collection keeps its own state, with Browse, whatever is typed.
///
/// ## Rows are content until there is somewhere to go (#44)
///
/// Without [onOpen] a row is inert content, not a focus stop: a tap that
/// leads nowhere is worse than no tap (#269). #46 wires it. A base game's
/// row still carries the control that shows its expansions, the only way to
/// them, and a box of more than four takes focus itself, so that a keyboard
/// can scroll its rows (#1048).
///
/// ## List or thumbnails (#710)
///
/// A toggle in the header shows the entries as rows or as a grid of covers,
/// and [layouts] remembers the choice for the user. A cover opens its entry
/// as a row does, and like a row it is inert without [onOpen]. The toggle
/// isn't in the app bar: beside the back button, it cut the title short on a
/// 320dp phone.
///
/// ## A game owned more than once is one stack (#709)
///
/// An entry is per platform game and medium, so a game owned on Tabletop and
/// on Steam is two entries. The list and the grid show it once, as a stack:
/// its cover marked with how many entries there are, and named with their
/// platforms. A tap on a stack opens a picker of its entries
/// ([showCollectionEntryPicker]), whose tiles open them through [onOpen]. A
/// game owned once is a row or a cover of its own, as before, and opens its
/// entry directly. Without [onOpen] a stack is inert, as a row is.
///
/// ## An expansion is shown under its base game (#711)
///
/// An owned expansion's row sits under its owned base game's row, folded
/// away behind the badge at the end of that row until the user shows it
/// (#1048). Any number of base games can be open at once, and a base game
/// with more than four shows them in a box that scrolls inside the page.
/// In thumbnails, a badge on the base game's cover opens a strip of its
/// expansions' covers under that cover's row, one at a time.
///
/// ## An empty collection points at the catalog (#45)
///
/// Games are added from a game's detail, so the empty state offers
/// [onBrowse], which opens the catalog. Null, it offers nothing to press, as
/// the household list offers no create without a way to send one.
///
/// ## Entries the server hasn't had (#47)
///
/// A row whose entry has a change the server hasn't had says so in a
/// [BgeSyncBadge] under its details, and a cover with a mark and its label,
/// which says the words where the row reads them: "Not yet synced" while the
/// change waits, "Couldn't sync" once its queued op is stuck and won't send
/// on its own. Only the [BgeSyncStatusScope] above the screen knows an op is
/// stuck; without one, an entry still says it is waiting, from its own flags.
/// A stack says the worst of its copies' states, once.
class GameCollectionListScreen extends StatelessWidget {
  const GameCollectionListScreen({
    required this.repository,
    this.hydration,
    this.onOpen,
    this.onBrowse,
    this.onRetry,
    this.onEnter,
    this.layouts,
    super.key,
  });

  /// Key on the first-fill spinner.
  static const Key loadingKey = Key('collection_list.loading');

  /// Key on the empty state.
  static const Key emptyKey = Key('collection_list.empty');

  /// Key on the empty state's browse button.
  static const Key browseKey = Key('collection_list.browse');

  /// Key on the couldn't-refresh banner.
  static const Key refreshBannerKey = Key('collection_list.refresh_banner');

  /// Key on the banner's retry button.
  static const Key refreshRetryKey = Key('collection_list.refresh_retry');

  /// Key on the app bar's refresh button (#717).
  static const Key refreshButtonKey = Key('collection_list.refresh_button');

  /// Key on the failed-read surface.
  static const Key errorKey = Key('collection_list.error');

  /// Key on every thumbnail placeholder.
  static const Key thumbnailPlaceholderKey = Key(
    'collection_list.thumbnail_placeholder',
  );

  /// Key on the list or thumbnails toggle.
  static const Key layoutToggleKey = Key('collection_list.layout_toggle');

  /// Key on the search field's text field (#715).
  static const Key searchKey = Key('collection_list.search');

  /// Key on the button that opens the sort menu (#715).
  static const Key sortButtonKey = Key('collection_list.sort');

  /// Per-order key on the sort menu's items: `collection_list.sort_<name>`.
  static Key sortKey(CollectionSort sort) =>
      Key('collection_list.sort_${sort.name}');

  /// Key on the count of games shown while a filter narrows them (#715).
  static const Key resultCountKey = Key('collection_list.result_count');

  /// Key on the state shown when nothing fits the search and filters.
  static const Key noMatchesKey = Key('collection_list.no_matches');

  /// Key on that state's Clear filters button.
  static const Key clearFiltersKey = Key('collection_list.clear_filters');

  static final BgeLogger _log = BgeLogger('bge.collection.list.layout');

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

  /// Per-tile key: `collection_list.tile_<entryId>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverGrid] puts around each tile, as
  /// [rowKey] is for rows.
  static Key tileKey(String entryId) => Key('collection_list.tile_$entryId');

  /// Per-row key of an expansion shown under its base game:
  /// `collection_list.nested_row_<parentGameId>_<entryId>`.
  ///
  /// An expansion of two owned base games is drawn under each, so the key
  /// names the base game it is under (#711).
  static Key nestedRowKey(String parentGameId, String entryId) =>
      Key('collection_list.nested_row_${parentGameId}_$entryId');

  /// Per-stack key of an expansion owned more than once and shown under its
  /// base game: `collection_list.nested_stack_<parentGameId>_<gameId>`.
  static Key nestedStackKey(String parentGameId, String gameId) =>
      Key('collection_list.nested_stack_${parentGameId}_$gameId');

  /// Per-row key: `collection_list.row_<entryId>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String entryId) => Key('collection_list.row_$entryId');

  /// Per-stack key: `collection_list.stack_<gameId>`, on the one row of a
  /// game owned more than once (#709).
  ///
  /// Held by the list's wrapper, as [rowKey] is. A game owned once keeps its
  /// entry's [rowKey].
  static Key stackKey(String gameId) => Key('collection_list.stack_$gameId');

  /// Per-stack tile key: `collection_list.stack_tile_<gameId>`, the grid's
  /// [stackKey].
  static Key stackTileKey(String gameId) =>
      Key('collection_list.stack_tile_$gameId');

  /// Per-tile key of an expansion's cover in the strip unfolded under its
  /// base game's: `collection_list.nested_tile_<parentGameId>_<entryId>`.
  ///
  /// Held by the wrapper around the cover, as [tileKey] is. It names the
  /// base game, as [nestedRowKey] does (#711).
  static Key nestedTileKey(String parentGameId, String entryId) =>
      Key('collection_list.nested_tile_${parentGameId}_$entryId');

  /// Per-stack tile key of an expansion owned more than once, in the strip
  /// unfolded under its base game's:
  /// `collection_list.nested_stack_tile_<parentGameId>_<gameId>`.
  static Key nestedStackTileKey(String parentGameId, String gameId) =>
      Key('collection_list.nested_stack_tile_${parentGameId}_$gameId');

  /// Per-row thumbnail key: `collection_list.thumbnail_<entryId>`.
  static Key thumbnailKey(String entryId) =>
      Key('collection_list.thumbnail_$entryId');

  /// The user-session collection repository. Read-only here.
  final GameCollectionRepository repository;

  /// What the hydrate is doing, when this composition runs one. Null reads
  /// as settled rather than as loading forever.
  final Stream<Hydration>? hydration;

  /// Opens one entry, or null where there is nowhere to open it. Takes the
  /// id rather than the row, because the destination re-reads the cache.
  ///
  /// For an entry in a stack, a tile of the stack's picker calls it, with
  /// the tile's own context, in a pop-up on the root navigator (#709).
  final void Function(BuildContext context, String entryId)? onOpen;

  /// Opens the catalog from the empty state, or null where this composition
  /// has none. Called with this screen's own context, as the household list's
  /// `onCreate` is: the feature package does not know the route table.
  final void Function(BuildContext context)? onBrowse;

  /// Runs one more hydrate pass, or null where this composition has none.
  /// Absent, the banner still reports a failed refresh and offers nothing to
  /// press.
  final Future<void> Function()? onRetry;

  /// Asks for a stale re-hydrate when this screen is entered (#44).
  /// Fire-and-forget: the caller owns the error handling, and what it
  /// starts is not narrated.
  final VoidCallback? onEnter;

  /// Where the list or thumbnails choice is kept, or null where there is no
  /// user session. Without it the toggle still works, for this visit.
  final ListLayoutRepository? layouts;

  @override
  Widget build(BuildContext context) {
    final layouts = this.layouts;
    return BlocProvider<GameCollectionListBloc>(
      create: (_) {
        final bloc = GameCollectionListBloc(
          repository: repository,
          hydration: hydration,
          onRetry: onRetry,
        );
        // Here, not in the route builder: `create` runs once per entry,
        // whereas go_router re-runs a route's builder on every router
        // rebuild (#300). After the bloc, so its subscription is in
        // place before the pass can report anything.
        onEnter?.call();
        return bloc;
      },
      // A different user's repository reads again, rather than keeping the
      // previous user's answer.
      child: BgeRememberedLayout(
        key: ObjectKey(layouts),
        read: layouts == null
            ? null
            : () => layouts.readThumbnails(ListLayoutScreen.collection),
        write: layouts == null
            ? null
            : ({required thumbnails}) => layouts.writeThumbnails(
                ListLayoutScreen.collection,
                thumbnails: thumbnails,
              ),
        onError: _layoutFailed,
        builder: (context, onChanged, {required thumbnails}) =>
            _GameCollectionListPage(
              thumbnails: thumbnails,
              onLayoutChanged: onChanged,
              onOpen: onOpen,
              onBrowse: onBrowse,
            ),
      ),
    );
  }
}

class _GameCollectionListPage extends StatefulWidget {
  const _GameCollectionListPage({
    required this.thumbnails,
    required this.onLayoutChanged,
    this.onOpen,
    this.onBrowse,
  });

  /// Null until the remembered choice is read.
  final bool? thumbnails;
  final ValueChanged<bool> onLayoutChanged;
  final void Function(BuildContext context, String entryId)? onOpen;
  final void Function(BuildContext context)? onBrowse;

  @override
  State<_GameCollectionListPage> createState() =>
      _GameCollectionListPageState();
}

class _GameCollectionListPageState extends State<_GameCollectionListPage> {
  /// The header, told when Clear filters, below it, resets the filters, so
  /// its search field empties and its Filters button takes focus (#715).
  final _controls = GlobalKey<CollectionListControlsState>();

  /// The base games whose expansions the list shows under them (#1048).
  /// The page's, as it counts the rows the sliver draws.
  final _open = BgeOpenRows();

  @override
  void initState() {
    super.initState();
    _open.addListener(_onOpenChanged);
  }

  @override
  void dispose() {
    _open
      ..removeListener(_onOpenChanged)
      ..dispose();
    super.dispose();
  }

  void _onOpenChanged() => setState(() {});

  /// Asks for a pass on a pull, and answers the pull's spinner when the pass
  /// it started or joined ends (#717).
  ///
  /// A fresh completer each time: the bloc completes it, and a completer
  /// completes once.
  Future<void> _refresh(BuildContext context) {
    final done = Completer<void>();
    context.read<GameCollectionListBloc>().add(
      GameCollectionListRetryRequested(done: done),
    );
    return done.future;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final thumbnails = widget.thumbnails;
    final canRetry = context.read<GameCollectionListBloc>().canRetry;
    // The row count, for "item 3 of 9". The page owns the scroll view, so
    // the page passes it (#210). A row or a cover per game, as a game owned
    // more than once is one stack (#709). The list draws the rows shown: an
    // open base game's expansions' too (#711), and a box of them as one,
    // whose rows count among themselves (#1048). The grid draws the
    // top-level covers, as a strip's are a row of their own, so it counts
    // those. Under a filter, the rows it shows (#715). While the device's
    // first sync runs, an expansion whose base game has not landed is held,
    // and not counted (#810). With every game held, no row is drawn and the
    // loading state stands in, as for an empty list.
    final list = thumbnails == false;
    final open = _open.open;
    final rowCount = context.select<GameCollectionListBloc, int?>((bloc) {
      final count = switch (bloc.state) {
        GameCollectionListReady(:final items, :final all, :final complete) =>
          list
              ? collectionRows(
                  items,
                  all: all,
                  complete: complete,
                  open: open,
                ).length
              : placeCollection(items, all: all, complete: complete).length,
        _ => 0,
      };
      return count == 0 ? null : count;
    });

    return BgePage.slivers(
      title: Text(l10n.collectionListTitle),
      // A list surface, so the wider measure.
      width: BgePageWidth.pane,
      // Not while the choice is read, when no row is built.
      semanticChildCount: thumbnails == null ? null : rowCount,
      // Set or not for the screen's whole life, as the bloc's `canRetry` is:
      // a page that gains or loses it rebuilds its scroll view.
      onRefresh: canRetry ? () => _refresh(context) : null,
      // Where there is no pass to run, there is no button either: one that
      // did nothing is worse than none (#717). The page is built outside the
      // list's builder, so the button reads the pass on its own.
      actions: canRetry
          ? [
              BlocSelector<
                GameCollectionListBloc,
                GameCollectionListState,
                bool
              >(
                // From any state: the button says a pass it started is
                // running on the loading and error surfaces too, where no
                // banner does (#717).
                selector: (state) => state.refreshing,
                builder: (context, refreshing) => BgeRefreshButton(
                  buttonKey: GameCollectionListScreen.refreshButtonKey,
                  label: l10n.collectionRefreshAction,
                  inProgressLabel: l10n.collectionRefreshInProgress,
                  refreshing: refreshing,
                  onPressed: () => context.read<GameCollectionListBloc>().add(
                    const GameCollectionListRetryRequested(),
                  ),
                ),
              ),
            ]
          : null,
      slivers: [
        // In every state, and first, above the refresh banner, so that it
        // keeps its place and its focus as the list below it changes (#607).
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
            child: CollectionListControls(
              key: _controls,
              thumbnails: thumbnails ?? false,
              onLayoutChanged: widget.onLayoutChanged,
            ),
          ),
        ),
        GameCollectionListSliver(
          thumbnails: thumbnails,
          onOpen: widget.onOpen,
          onBrowse: widget.onBrowse,
          onFiltersCleared: (held) =>
              _controls.currentState?.filtersCleared(held: held),
          openRows: _open,
        ),
      ],
    );
  }
}

/// The collection list's content, as one sliver (#44).
///
/// Reads a [GameCollectionListBloc] from context. [GameCollectionListScreen]
/// provides one inside a page; a host such as #46's two-pane form provides
/// its own and puts this in its own scroll view. The host owns that scroll
/// view, so it also owns its `semanticChildCount`, and [openRows], which it
/// counts the rows the list shows by.
class GameCollectionListSliver extends StatelessWidget {
  const GameCollectionListSliver({
    required this.openRows,
    this.thumbnails = false,
    this.onOpen,
    this.onBrowse,
    this.onFiltersCleared,
    super.key,
  });

  /// Shows the entries as a grid of covers rather than as rows (#710).
  ///
  /// Null while the host is still reading the user's choice. The entries are
  /// held back rather than shown in the wrong layout, and the loading state
  /// stands in for them: the same one, in the same place, as a first fill's,
  /// so a screen reader that hears "Loading" as the screen opens doesn't hear
  /// it again when the choice lands during the fill. An error or an empty
  /// collection is the same in either layout, so it shows as soon as it is
  /// known.
  final bool? thumbnails;

  /// See [GameCollectionListScreen.onOpen].
  final void Function(BuildContext context, String entryId)? onOpen;

  /// See [GameCollectionListScreen.onBrowse].
  final void Function(BuildContext context)? onBrowse;

  /// Called once Clear filters, in the state shown when nothing fits the
  /// search and the filters, has reset them (#715): for a host whose search
  /// field shows the query, to empty it and hand focus on, as Clear filters
  /// leaves the list. It is given Clear filters' focus node when that held
  /// focus at the press, else null.
  final ValueChanged<FocusNode?>? onFiltersCleared;

  /// The base games whose expansions the list shows under them, by game id
  /// (#1048), which the host owns and disposes. It counts the rows shown by
  /// it: a base game's nested rows count while it is open, and a box of
  /// them counts once (`collectionRows`). The host builds the sliver again
  /// when it changes, as it builds its count again.
  ///
  /// Every base game starts folded, and any number can be open. The set
  /// outlives a sync, a refresh, a failed read and a filter, which hides
  /// what is open without folding it. A base game that goes, or loses its
  /// last expansion, comes back folded. A switch to thumbnails folds every
  /// game: the grid opens one strip at a time, so the list's set has
  /// nothing there to map to.
  final BgeOpenRows openRows;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final canRetry = context.read<GameCollectionListBloc>().canRetry;
    final thumbnails = this.thumbnails;
    final onOpen = this.onOpen;
    final open = openRows;
    // Back in the list after thumbnails, every game is folded again.
    if (thumbnails ?? false) open.foldAll();
    final loading = BgeStateSliver(
      child: BgeLoadingState(
        key: GameCollectionListScreen.loadingKey,
        label: l10n.collectionListLoading,
      ),
    );

    return BlocBuilder<GameCollectionListBloc, GameCollectionListState>(
      builder: (context, state) {
        // Nothing fits the search and the filters, so no game is placed to
        // keep the set by, but the whole collection is read, and says which
        // base games still nest games: one that lost its last expansion
        // meanwhile comes back folded as the search clears.
        if (state
            case GameCollectionListReady(
              :final items,
              :final all,
              :final complete,
            )
            when thumbnails == false && items.isEmpty && all.isNotEmpty) {
          open.retain(collectionNestingGameIds(all, complete: complete));
        }
        return SliverMainAxisGroup(
          slivers: [
            // Not while the choice is read, when the loading state alone
            // stands in for the list.
            if (state
                case GameCollectionListReady(
                  :final refreshFailed,
                  :final refreshing,
                )
                when thumbnails != null && (refreshFailed || refreshing))
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: BgeTokens.of(context).spaceMd,
                  ),
                  child: BgeRefreshBanner(
                    key: GameCollectionListScreen.refreshBannerKey,
                    retryKey: GameCollectionListScreen.refreshRetryKey,
                    failedMessage: l10n.collectionListRefreshFailed,
                    inProgressLabel: l10n.collectionRefreshInProgress,
                    retryLabel: l10n.collectionRefreshRetry,
                    refreshing: refreshing,
                    onRetry: canRetry
                        ? () => context.read<GameCollectionListBloc>().add(
                            const GameCollectionListRetryRequested(),
                          )
                        : null,
                  ),
                ),
              ),
            switch (state) {
              GameCollectionListLoading() => loading,
              GameCollectionListError() => _ErrorSliver(
                message: l10n.collectionListError,
              ),
              // Kept apart (#715): no games at all, and games of which nothing
              // fits the search and the filters. Either is the same in both
              // layouts, so it shows before the choice is read.
              GameCollectionListReady(:final all) when all.isEmpty =>
                _EmptySliver(onBrowse: onBrowse),
              GameCollectionListReady(:final items) when items.isEmpty =>
                _NoMatchesSliver(onCleared: onFiltersCleared),
              // Every game that fits is an expansion held for its base game
              // while the device's first sync runs (#810): the list is still
              // filling.
              GameCollectionListReady(:final items, :final all, complete: false)
                  when placeCollection(
                    items,
                    all: all,
                    complete: false,
                  ).isEmpty =>
                loading,
              _ when thumbnails == null => loading,
              GameCollectionListReady(
                :final items,
                :final all,
                :final complete,
              ) =>
                _PlacedCollection(
                  thumbnails: thumbnails,
                  items: items,
                  all: all,
                  complete: complete,
                  open: open,
                  onOpen: onOpen,
                ),
            },
          ],
        );
      },
    );
  }
}

/// The games placed (#711), as covers or as rows, in one scope for the list
/// and the grid, so a game's focus follows it as its item changes form: one
/// entry or a stack, top level, under its base game or in a box (#769,
/// #1048).
///
/// What the filter left, [items], is placed against the whole collection,
/// [all], which decides which expansions are missing their base game
/// (#715). It is placed once a build, for the sliver to draw and for the
/// scope to ask whether a game is still in its place: a focused item that
/// left with no item built in its place, its game still there, scrolled out
/// of the lazy list, and hands its focus to no other copy of the game
/// (#819). The scope asks only once a focused item has left, so the lookup
/// builds its set then.
///
/// In the list, [open] keeps only the base games that the whole collection
/// still nests games under, or that the filter's placement does
/// (`collectionNestingGameIds`), so one that goes, or loses its last
/// expansion, comes back folded, and a filter that hides one folds nothing
/// (#1048). This is built only for a placement with something in it, so a
/// list that is empty for a moment, loading, failed, or held whole by a
/// first sync (#810), keeps the set as it was. One that matches nothing
/// keeps it against the whole collection, in the sliver.
class _PlacedCollection extends StatelessWidget {
  const _PlacedCollection({
    required this.thumbnails,
    required this.items,
    required this.all,
    required this.complete,
    required this.open,
    this.onOpen,
  });

  final bool thumbnails;
  final List<GameCollectionListItem> items;
  final List<GameCollectionListItem> all;
  final bool complete;
  final BgeOpenRows open;
  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final onOpen = this.onOpen;
    // Whether a game is shown at the place its BgeFocusHandoff names.
    final bool Function(Object identity, Object? place) isShown;
    final Widget sliver;
    if (thumbnails) {
      final placed = placeCollection(items, all: all, complete: complete);
      isShown = BgeUnfoldingCovers.isShownIn(
        placed,
        idOf: (top) => top.item.first.gameId,
        stripIdsOf: (top) => [
          for (final group in top.expansions) group.first.gameId,
        ],
      );
      sliver = CollectionCovers(placed: placed, onOpen: onOpen);
    } else {
      open.retain(
        collectionNestingGameIds(all, items: items, complete: complete),
      );
      final rows = collectionRows(
        items,
        all: all,
        complete: complete,
        titleOf: (item) => collectionItemTitle(l10n, item),
        open: open.open,
      );
      final handoffs = _handoffs(inert: onOpen == null);
      isShown = handoffs.isShownIn(rows);
      sliver = _CollectionList(
        rows: rows,
        handoffs: handoffs,
        onToggle: open.toggle,
        onOpen: onOpen,
      );
    }
    return BgeFocusHandoffScope(isShown: isShown, child: sliver);
  }
}

/// The game of [row]: the first of its entries'.
String _gameIdOf(CollectionRow row) => row.group.first.gameId;

/// The hand-offs of the list's games (#1048), by game: a box is a stop of
/// its own, and an item of the hand-off, where its rows open nothing,
/// [inert], and so take no focus. A nested row names its base game, its
/// `parentGameId`, as its place.
BgeFoldedHandoffs<CollectionRow> _handoffs({required bool inert}) =>
    BgeFoldedHandoffs(idOf: _gameIdOf, boxIsStop: inert);

/// The key of [row]'s row: an entry's or a stack's, at top level or under
/// its base game.
Key _rowKeyOf(CollectionRow row) => switch ((row.group, row.parentGameId)) {
  ([final item], null) => GameCollectionListScreen.rowKey(item.entry.id),
  (_, null) => GameCollectionListScreen.stackKey(_gameIdOf(row)),
  ([final item], final parent?) => GameCollectionListScreen.nestedRowKey(
    parent,
    item.entry.id,
  ),
  (_, final parent?) => GameCollectionListScreen.nestedStackKey(
    parent,
    _gameIdOf(row),
  ),
};

/// The key of the box of base game [gameId]'s nested rows, in the list.
Key _nestedBoxKey(String gameId) => Key('collection_list.nested_box_$gameId');

/// The games as rows (#44): each top-level game, and under a base game the
/// rows of its expansions, which the badge at the end of its row shows and
/// hides (#711, #1048). Up to [BgeNestedRowsBox.inlineLimit] of them are
/// laid out in the list, and more in a box that scrolls inside the page.
///
/// Each row is in its game's [BgeFocusHandoff], so a game's focus follows it
/// between top level, under its base game and in a box (#769, #711). While a
/// base game is folded, its row names its expansions as folded behind its
/// badge, so a focused one whose rows fold, in the list or in a box, or
/// that moves under it, is handed to the badge, never to the top of the
/// list (#813, #1048).
///
/// A base game's row carries its badge whether or not the rows open
/// anything: an inert row's badge is the only way to its expansions. In a
/// box, rows that open nothing take no focus, so the box takes it itself,
/// for the keyboard to scroll them by. That box is an item of the hand-off
/// too, under an identity of its own, so that focus on it goes to the badge
/// when the rows fold, or when they drop to the few the list lays out
/// itself, none of which can take it. Rows that open take focus, and their
/// own items hand it on, so their box is no item. A box keeps its state, its
/// rows' offset among it, as its rows come to open entries or stop, and it
/// comes to be an item or stops: a key of its own carries it across.
class _CollectionList extends StatefulWidget {
  const _CollectionList({
    required this.rows,
    required this.handoffs,
    required this.onToggle,
    this.onOpen,
  });

  final List<BgeFoldedRow<CollectionRow>> rows;

  /// The games' hand-offs, whose box is a stop where [onOpen] is null.
  final BgeFoldedHandoffs<CollectionRow> handoffs;

  /// Shows or hides the expansions of the base game with this id.
  final ValueChanged<Object> onToggle;

  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  State<_CollectionList> createState() => _CollectionListState();
}

class _CollectionListState extends State<_CollectionList> {
  /// Each open box's own key, by its base game, for as long as the list
  /// holds the box: see [_CollectionList].
  final _boxKeys = <String, GlobalKey>{};

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final rows = widget.rows;
    final handoffs = widget.handoffs;
    final onOpen = widget.onOpen;
    final boxes = {
      for (final row in rows)
        if (row is BgeNestedBox<CollectionRow>) _gameIdOf(row.parent),
    };
    _boxKeys.removeWhere((gameId, _) => !boxes.contains(gameId));
    return BgeKeyedSliverList<BgeFoldedRow<CollectionRow>>(
      items: rows,
      keyOf: (row) => switch (row) {
        BgeNestedBox(:final parent) => _nestedBoxKey(_gameIdOf(parent)),
        _ => _rowKeyOf(row.items.single),
      },
      itemBuilder: (context, row) => switch (row) {
        BgeTopRow(:final item, :final nested, :final open) => handoffs.topRow(
          row,
          child: collectionRowFor(
            item,
            onOpen: onOpen,
            expansions: nested.isEmpty
                ? null
                : BgeCoverExpansions(
                    count: nested.length,
                    expanded: open,
                    onToggle: () => widget.onToggle(_gameIdOf(item)),
                    label: l10n.collectionExpansionsBadge(
                      collectionItemTitle(l10n, item.group.first),
                      nested.length,
                    ),
                    showLabel: l10n.collectionShowExpansions,
                    hideLabel: l10n.collectionHideExpansions,
                  ),
          ),
        ),
        BgeNestedRow(:final item) => _nested(item),
        BgeNestedBox(:final parent, :final items) => handoffs.box(
          row,
          child: _box(l10n, parent, items),
        ),
      },
    );
  }

  /// An expansion's row under its base game's, in the list or in a box. In
  /// a box the row carries its own key, which the list's wrapper holds
  /// otherwise, so that a finder by it reaches the row either way.
  Widget _nested(CollectionRow row, {Key? key}) => BgeFocusHandoff(
    key: key,
    identity: _gameIdOf(row),
    place: row.parentGameId,
    child: collectionRowFor(row, onOpen: widget.onOpen),
  );

  /// More expansions than the list lays out, in a box that scrolls inside
  /// the page, named for its base game (#1048).
  Widget _box(
    GameCollectionLocalizations l10n,
    CollectionRow parent,
    List<CollectionRow> items,
  ) => BgeNestedRowsBox(
    key: _boxKeys.putIfAbsent(_gameIdOf(parent), GlobalKey.new),
    semanticLabel: l10n.collectionExpansionsStrip(
      collectionItemTitle(l10n, parent.group.first),
    ),
    // Rows that open nothing take no focus, and a keyboard would have
    // nothing to scroll the box by (WCAG 2.1.1).
    focusable: widget.handoffs.boxIsStop,
    rows: [for (final item in items) _nested(item, key: _rowKeyOf(item))],
  );
}

/// No games. Games are added from a game's detail, so it offers [onBrowse],
/// which opens the catalog (#45), and nothing to press without one.
class _EmptySliver extends StatelessWidget {
  const _EmptySliver({this.onBrowse});

  final void Function(BuildContext context)? onBrowse;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final browse = onBrowse;

    return BgeStateSliver(
      child: BgeEmptyState(
        key: GameCollectionListScreen.emptyKey,
        title: l10n.collectionListEmptyTitle,
        body: l10n.collectionListEmptyBody,
        action: browse == null
            ? null
            : FilledButton.tonal(
                key: GameCollectionListScreen.browseKey,
                onPressed: () => browse(context),
                child: Text(l10n.collectionListBrowse),
              ),
      ),
    );
  }
}

/// Games, of which nothing fits the search and the filters (#715). Clear
/// filters resets both, but not the sort, and calls [onCleared] with its
/// own focus node if it held focus at the press.
class _NoMatchesSliver extends StatefulWidget {
  const _NoMatchesSliver({this.onCleared});

  final ValueChanged<FocusNode?>? onCleared;

  @override
  State<_NoMatchesSliver> createState() => _NoMatchesSliverState();
}

class _NoMatchesSliverState extends State<_NoMatchesSliver> {
  final _clearFocus = FocusNode(debugLabel: 'Collection clear filters');

  @override
  void dispose() {
    _clearFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    return BgeStateSliver(
      child: BgeEmptyState(
        key: GameCollectionListScreen.noMatchesKey,
        title: l10n.collectionNoMatchesTitle,
        body: l10n.collectionNoMatchesBody,
        action: FilledButton.tonal(
          key: GameCollectionListScreen.clearFiltersKey,
          focusNode: _clearFocus,
          onPressed: () {
            final held = _clearFocus.hasFocus ? _clearFocus : null;
            context.read<GameCollectionListBloc>().add(
              const GameCollectionListFilterChanged(CollectionFilter()),
            );
            widget.onCleared?.call(held);
          },
          child: Text(l10n.collectionClearFilters),
        ),
      ),
    );
  }
}

class _ErrorSliver extends StatelessWidget {
  const _ErrorSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => BgeStateSliver(
    child: BgeInlineBanner(
      key: GameCollectionListScreen.errorKey,
      tone: BgeBannerTone.error,
      message: message,
    ),
  );
}
