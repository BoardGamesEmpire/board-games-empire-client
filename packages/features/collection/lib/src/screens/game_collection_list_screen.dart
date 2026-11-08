import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_collection/l10n/game_collection_localizations.dart';

import '../bloc/game_collection_list_bloc.dart';
import '../bloc/game_collection_list_event.dart';
import '../bloc/game_collection_list_state.dart';
import '../medium_label.dart';
import '../picker/collection_entry_picker.dart';
import 'collection_groups.dart';
import 'collection_rows.dart';

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
/// ## The page is thin (#44)
///
/// The list itself is [GameCollectionListSliver], and this screen is a
/// `BgePage` around it, with the layout toggle at its head, plus the bloc it
/// reads. #46's two-pane form can host the sliver beside the detail screen
/// without this page's app bar or toggle.
///
/// ## Rows are content until there is somewhere to go (#44)
///
/// Without [onOpen] a row is inert content, not a focus stop: a tap that
/// leads nowhere is worse than no tap (#269). #46 wires it.
///
/// ## List or thumbnails (#710)
///
/// A toggle at the head of the content shows the entries as rows or as a grid
/// of covers, and [layouts] remembers the choice for the user. A cover opens
/// its entry as a row does, and like a row it is inert without [onOpen]. The
/// toggle isn't in the app bar: beside the back button, it cut the title
/// short on a 320dp phone.
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
/// ## An empty collection points at the catalog (#45)
///
/// Games are added from a game's detail, so the empty state offers
/// [onBrowse], which opens the catalog. Null, it offers nothing to press, as
/// the household list offers no create without a way to send one.
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

  /// Key on the failed-read surface.
  static const Key errorKey = Key('collection_list.error');

  /// Key on every thumbnail placeholder.
  static const Key thumbnailPlaceholderKey = Key(
    'collection_list.thumbnail_placeholder',
  );

  /// Key on the list or thumbnails toggle.
  static const Key layoutToggleKey = Key('collection_list.layout_toggle');

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
            : (thumbnails) => layouts.writeThumbnails(
                ListLayoutScreen.collection,
                thumbnails,
              ),
        onError: _layoutFailed,
        builder: (context, thumbnails, onChanged) => _GameCollectionListPage(
          thumbnails: thumbnails,
          onLayoutChanged: onChanged,
          onOpen: onOpen,
          onBrowse: onBrowse,
        ),
      ),
    );
  }
}

class _GameCollectionListPage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    // The row count, for "item 3 of 9". The page owns the scroll view, so
    // the page passes it (#210). A row or a cover per game, as a game owned
    // more than once is one stack (#709). The list draws a row for each
    // nested expansion too (#711), so it counts the rows; the grid still
    // draws every game, so its count is the games, counted without building
    // the groups on every state.
    final list = thumbnails == false;
    final rowCount = context.select<GameCollectionListBloc, int?>(
      (bloc) => switch (bloc.state) {
        GameCollectionListReady(:final items) when items.isNotEmpty =>
          list
              ? collectionRows(items).length
              : {for (final item in items) item.gameId}.length,
        _ => null,
      },
    );

    return BgePage.slivers(
      title: Text(l10n.collectionListTitle),
      // A list surface, so the wider measure.
      width: BgePageWidth.pane,
      // Not while the choice is read, when no row is built.
      semanticChildCount: thumbnails == null ? null : rowCount,
      slivers: [
        // In every state, and first, above the refresh banner, so that it
        // keeps its place and its focus as the list below it changes (#607).
        // Never disabled: while the choice is read it shows the list, which
        // is what a missing choice means.
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: BgeLayoutToggle(
                key: GameCollectionListScreen.layoutToggleKey,
                thumbnails: thumbnails ?? false,
                onChanged: onLayoutChanged,
                listLabel: l10n.collectionLayoutList,
                thumbnailsLabel: l10n.collectionLayoutThumbnails,
              ),
            ),
          ),
        ),
        GameCollectionListSliver(
          thumbnails: thumbnails,
          onOpen: onOpen,
          onBrowse: onBrowse,
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
/// view, so it also owns its `semanticChildCount`.
class GameCollectionListSliver extends StatelessWidget {
  const GameCollectionListSliver({
    this.thumbnails = false,
    this.onOpen,
    this.onBrowse,
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

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final canRetry = context.read<GameCollectionListBloc>().canRetry;
    final thumbnails = this.thumbnails;
    final loading = BgeStateSliver(
      child: BgeLoadingState(
        key: GameCollectionListScreen.loadingKey,
        label: l10n.collectionListLoading,
      ),
    );

    return BlocBuilder<GameCollectionListBloc, GameCollectionListState>(
      builder: (context, state) => SliverMainAxisGroup(
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
                padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
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
            GameCollectionListReady(:final items) when items.isEmpty =>
              _EmptySliver(onBrowse: onBrowse),
            _ when thumbnails == null => loading,
            // One scope for the list and the grid, so a game's focus follows
            // it as its item changes form: one entry or a stack, top level or
            // under its base game (#769, #711).
            GameCollectionListReady(:final items) => BgeFocusHandoffScope(
              child: SliverMainAxisGroup(
                slivers: [
                  if (thumbnails == true)
                    BgeKeyedSliverGrid<List<GameCollectionListItem>>(
                      items: groupByGame(items),
                      keyOf: (group) => switch (group) {
                        [final item] => GameCollectionListScreen.tileKey(
                          item.entry.id,
                        ),
                        _ => GameCollectionListScreen.stackTileKey(
                          group.first.gameId,
                        ),
                      },
                      gridDelegate: bgeCoverGridDelegate(context),
                      itemBuilder: (context, group) => BgeFocusHandoff(
                        identity: group.first.gameId,
                        child: switch (group) {
                          [final item] => _CollectionTile(
                            item: item,
                            onOpen: onOpen,
                          ),
                          _ => _StackTile(items: group, onOpen: onOpen),
                        },
                      ),
                    )
                  else
                    BgeKeyedSliverList<CollectionRow>(
                      items: collectionRows(
                        items,
                        titleOf: (item) => _title(l10n, item),
                      ),
                      keyOf: (row) => switch ((row.group, row.parentGameId)) {
                        ([final item], null) => GameCollectionListScreen.rowKey(
                          item.entry.id,
                        ),
                        (_, null) => GameCollectionListScreen.stackKey(
                          row.group.first.gameId,
                        ),
                        ([final item], final parent?) =>
                          GameCollectionListScreen.nestedRowKey(
                            parent,
                            item.entry.id,
                          ),
                        (_, final parent?) =>
                          GameCollectionListScreen.nestedStackKey(
                            parent,
                            row.group.first.gameId,
                          ),
                      },
                      itemBuilder: (context, row) => BgeFocusHandoff(
                        identity: row.group.first.gameId,
                        place: row.parentGameId,
                        child: switch (row.group) {
                          [final item] => _CollectionRow(
                            item: item,
                            onOpen: onOpen,
                            expansionOf: row.parentTitle,
                            missingBase: row.missingBase,
                          ),
                          final group => _StackRow(
                            items: group,
                            onOpen: onOpen,
                            expansionOf: row.parentTitle,
                            missingBase: row.missingBase,
                          ),
                        },
                      ),
                    ),
                ],
              ),
            ),
          },
        ],
      ),
    );
  }
}

/// One entry (#44): the thumbnail, the title line, the detail line and
/// the favorite, as one semantics node.
class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    required this.item,
    this.onOpen,
    this.expansionOf,
    this.missingBase = false,
  });

  final GameCollectionListItem item;
  final void Function(BuildContext context, String entryId)? onOpen;

  /// The title of the base game this row is shown under, or null at top
  /// level (#711).
  final String? expansionOf;

  /// Whether the game is an expansion shown without its base game (#711).
  final bool missingBase;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final entry = item.entry;
    final open = onOpen;

    final title = _title(l10n, item);
    final details = [
      if (missingBase) _same(l10n.collectionListBaseGameMissing),
      ..._details(l10n, item),
    ];

    // MergeSemantics rather than a Semantics container: a tappable ListTile
    // builds an InkWell with its own node, and merging keeps the tap action
    // and the words on one node (the household row's reasoning).
    return MergeSemantics(
      child: _Nested(
        nested: expansionOf != null,
        child: ListTile(
          // Without an onTap the tile's InkWell has no handler, so it is
          // disabled: no tap action, and not a focus stop under ordinary
          // keyboard navigation. That is the inert row #44 wants.
          onTap: open == null ? null : () => open(context, entry.id),
          leading: BgeThumbnail(
            key: GameCollectionListScreen.thumbnailKey(entry.id),
            url: item.thumbnail,
            placeholderIcon: Icons.casino_outlined,
            placeholderKey: GameCollectionListScreen.thumbnailPlaceholderKey,
          ),
          title: Text(
            title,
            semanticsLabel: _spokenTitle(l10n, title, expansionOf),
          ),
          // Joined differently for the eye and the ear: a screen reader
          // would read the visual separator's symbol out.
          subtitle: Text(
            details
                .map((d) => d.shown)
                .join(l10n.collectionListDetailSeparator),
            semanticsLabel: details
                .map((d) => d.spoken)
                .join(l10n.collectionListDetailSpokenSeparator),
          ),
          trailing: entry.hasFavorited
              ? Icon(Icons.favorite, semanticLabel: l10n.collectionListFavorite)
              : null,
        ),
      ),
    );
  }
}

/// Indents a row shown under its base game by a step of the scale (#711).
class _Nested extends StatelessWidget {
  const _Nested({required this.nested, required this.child});

  final bool nested;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!nested) return child;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: BgeTokens.of(context).spaceLg),
      child: child,
    );
  }
}

/// What is spoken for a title: "X, expansion for Y" under a base game, else
/// null, to speak the words drawn (#711).
String? _spokenTitle(
  GameCollectionLocalizations l10n,
  String title,
  String? expansionOf,
) => expansionOf == null
    ? null
    : l10n.collectionListExpansionOf(title, expansionOf);

/// The title line: the game's title, with its subtitle when it has one.
String _title(GameCollectionLocalizations l10n, GameCollectionListItem item) {
  final subtitle = item.subtitle;
  return subtitle == null || subtitle.isEmpty
      ? item.title
      : l10n.collectionListTitleWithSubtitle(item.title, subtitle);
}

({String shown, String spoken}) _same(String text) =>
    (shown: text, spoken: text);

/// Each detail part as it is shown and as it is spoken, shared by the row and
/// the tile (#710). Only the rating differs: "7/10" read aloud is "seven
/// slash ten".
List<({String shown, String spoken})> _details(
  GameCollectionLocalizations l10n,
  GameCollectionListItem item,
) {
  final entry = item.entry;
  final rating = entry.rating;
  final lastPlayed = entry.lastPlayed;
  return [
    _same(item.platformName),
    _same(mediumLabel(l10n, entry.medium)),
    if (entry.quantity > 1) _same(l10n.collectionListQuantity(entry.quantity)),
    if (rating != null)
      (
        shown: l10n.collectionListRating(rating),
        spoken: l10n.collectionListRatingSpoken(rating),
      ),
    // The server stamps it in UTC; the user played it on their own day.
    if (lastPlayed != null)
      _same(l10n.collectionListLastPlayed(lastPlayed.toLocal())),
  ];
}

/// An entry's cover alone, named as its row is: the title and the row's
/// spoken details, then the favourite, since no text is drawn to tell two
/// covers apart (#710).
class _CollectionTile extends StatelessWidget {
  const _CollectionTile({required this.item, this.onOpen});

  final GameCollectionListItem item;
  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final entry = item.entry;
    final open = onOpen;
    return BgeCoverTile(
      extent: null,
      label: [
        _title(l10n, item),
        ..._details(l10n, item).map((d) => d.spoken),
        if (entry.hasFavorited) l10n.collectionListFavorite,
      ].join(l10n.collectionListDetailSpokenSeparator),
      imageUrl: item.thumbnail,
      onTap: open == null ? null : () => open(context, entry.id),
    );
  }
}

/// A stack's copies as shown and as spoken, shared by its row and its tile
/// (#709): how many, then each entry's platform, with its medium where two
/// share one ([collectionEntryLabel]), as "2 copies: Tabletop, Steam".
({String shown, String spoken}) _copies(
  GameCollectionLocalizations l10n,
  List<GameCollectionListItem> items,
) {
  final labels = [
    for (final item in items) collectionEntryLabel(l10n, item, items),
  ];
  String copies(Iterable<String> platforms) => l10n.collectionListStackCopies(
    items.length,
    platforms.join(l10n.collectionListDetailSpokenSeparator),
  );
  return (
    shown: copies(labels.map((label) => label.shown)),
    spoken: copies(labels.map((label) => label.spoken)),
  );
}

/// The entries of one game owned more than once, as one row (#709): the
/// thumbnail marked with their count, the title line, and the copies in
/// place of an entry's details. The heart shows when any of them is a
/// favourite. A tap opens the picker of the entries.
///
/// ## Focus
///
/// A tap gives the row focus before it opens the picker, so the picker hands
/// focus back to this row when it closes, as it does after a keyboard
/// activation. A list tile's ink takes no focus from a tap of its own, and
/// focus would land back on the page instead.
///
/// As on [BgeCoverTile], focus a mouse or a trackpad gave draws no focus tint
/// ([BgePointerFocus]). On a desktop a mouse leaves the highlight mode at the
/// keyboard's, so the row would be tinted when the picker closed, for a user
/// who never touched the keyboard. A touch turns the highlight mode to touch,
/// which hides the tint anyway.
///
/// The next key press ends that, but the row's focus shows again only from
/// its next focus. Its tint is its only focus feedback, and an ink highlight
/// keeps the strength it was first drawn with: a Tab away and back draws it,
/// as does opening the picker again from the keyboard and closing it. The
/// cover tile's ring covers that gap, and a row has none. Nor can the row
/// redraw the tint: a list tile passes its ink nothing that makes the ink
/// draw it afresh, and taking focus off the row and back would move focus.
class _StackRow extends StatefulWidget {
  const _StackRow({
    required this.items,
    this.onOpen,
    this.expansionOf,
    this.missingBase = false,
  });

  final List<GameCollectionListItem> items;
  final void Function(BuildContext context, String entryId)? onOpen;

  /// The title of the base game this row is shown under, or null at top
  /// level (#711).
  final String? expansionOf;

  /// Whether the game is an expansion shown without its base game (#711).
  final bool missingBase;

  @override
  State<_StackRow> createState() => _StackRowState();
}

class _StackRowState extends State<_StackRow> with BgePointerFocus<_StackRow> {
  final _focusNode = FocusNode(debugLabel: '_StackRow');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final items = widget.items;
    final open = widget.onOpen;
    final first = items.first;
    final copies = _copies(l10n, items);
    final missing = widget.missingBase
        ? l10n.collectionListBaseGameMissing
        : null;

    // MergeSemantics outermost, as on an entry's row, so the row's node is
    // the first thing under the list's key. The indent is inside it.
    return MergeSemantics(
      child: _Nested(
        nested: widget.expansionOf != null,
        child: Listener(
          // Every pointer's press on the row, as a list tile offers no
          // tap-down. A keyboard's activation sends none, so its focus shows.
          onPointerDown: open == null
              ? null
              : (event) => notePointerPress(event.kind),
          child: ListTile(
            focusNode: _focusNode,
            // The theme's tint, with no strength while the focus is a pointer's.
            focusColor: pointerFocusColor,
            onTap: open == null
                ? null
                : () {
                    _focusNode.requestFocus();
                    unawaited(
                      openCollectionEntries(
                        context,
                        items: items,
                        onOpen: open,
                      ),
                    );
                  },
            // The picture is smaller by the marker's offsets, so the marked
            // whole is an entry's thumbnail's size and the titles line up. A
            // list tile caps its leading at that height, so a full-size picture
            // with its offsets would be squeezed.
            leading: BgeStackMarker(
              count: items.length,
              child: BgeThumbnail(
                url: first.thumbnail,
                extent:
                    BgeThumbnail.listExtent - BgeStackMarker.reachOf(context),
                placeholderIcon: Icons.casino_outlined,
                placeholderKey:
                    GameCollectionListScreen.thumbnailPlaceholderKey,
              ),
            ),
            title: Text(
              _title(l10n, first),
              semanticsLabel: _spokenTitle(
                l10n,
                _title(l10n, first),
                widget.expansionOf,
              ),
            ),
            subtitle: Text(
              [?missing, copies.shown].join(l10n.collectionListDetailSeparator),
              semanticsLabel: [
                ?missing,
                copies.spoken,
              ].join(l10n.collectionListDetailSpokenSeparator),
            ),
            trailing: items.any((item) => item.entry.hasFavorited)
                ? Icon(
                    Icons.favorite,
                    semanticLabel: l10n.collectionListFavorite,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// A stack's cover (#709), marked with the count of its entries and named as
/// its row is: the title, the copies, then the favourite.
class _StackTile extends StatelessWidget {
  const _StackTile({required this.items, this.onOpen});

  final List<GameCollectionListItem> items;
  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final open = onOpen;
    final first = items.first;
    return BgeCoverTile(
      extent: null,
      stackCount: items.length,
      label: [
        _title(l10n, first),
        _copies(l10n, items).spoken,
        if (items.any((item) => item.entry.hasFavorited))
          l10n.collectionListFavorite,
      ].join(l10n.collectionListDetailSpokenSeparator),
      imageUrl: first.thumbnail,
      // The tile takes focus on a tap before this runs, so the picker hands
      // it back when it closes.
      onTap: open == null
          ? null
          : () => unawaited(
              openCollectionEntries(context, items: items, onOpen: open),
            ),
    );
  }
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
