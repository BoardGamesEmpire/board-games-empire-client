import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/bloc/game_collection_list_bloc.dart';
import 'package:game_collection/src/bloc/game_collection_list_state.dart';
import 'package:game_collection/src/medium_label.dart';
import 'package:game_collection/src/picker/collection_entry_picker.dart';
import 'package:game_collection/src/screens/collection_rows.dart';
import 'package:game_collection/src/screens/game_collection_list_screen.dart';
import 'package:game_collection/src/sync_label.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The row for [row] (#873): one entry, or the stack of a game owned more
/// than once, nested under its base game when `parentGameId` names one.
///
/// A base game's row takes [expansions], the control at its end that folds
/// and unfolds the rows nested under it (#1048).
Widget collectionRowFor(
  CollectionRow row, {
  void Function(BuildContext context, String entryId)? onOpen,
  BgeCoverExpansions? expansions,
}) => switch (row.group) {
  [final item] => _CollectionRow(
    item: item,
    onOpen: onOpen,
    expansionOf: row.parentTitle,
    missingBase: row.missingBase,
    expansions: expansions,
  ),
  final group => _StackRow(
    items: group,
    onOpen: onOpen,
    expansionOf: row.parentTitle,
    missingBase: row.missingBase,
    expansions: expansions,
  ),
};

/// One entry (#44): the thumbnail, the title line, the detail line with its
/// sync badge under it (#47) and the favorite, as one semantics node. A base
/// game's row has the control for its expansions at its end (#1048).
class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    required this.item,
    this.onOpen,
    this.expansionOf,
    this.missingBase = false,
    this.expansions,
  });

  final GameCollectionListItem item;
  final void Function(BuildContext context, String entryId)? onOpen;

  /// The title of the base game this row is shown under, or null at top
  /// level (#711).
  final String? expansionOf;

  /// Whether the game is an expansion shown without its base game (#711).
  final bool missingBase;

  /// The game's expansions, for a base game's control (#1048).
  final BgeCoverExpansions? expansions;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final entry = item.entry;
    final open = onOpen;

    final title = collectionItemTitle(l10n, item);
    final details = [
      if (missingBase) _same(l10n.collectionListBaseGameMissing),
      ..._details(l10n, item),
    ];

    // BgeExpansionsRow merges the tile's semantics, rather than a Semantics
    // container: a tappable ListTile builds an InkWell with its own node,
    // and merging keeps the tap action and the words on one node. It is
    // inside the outline, so the merged node's rect leaves out the gap below
    // the row and a nested row's indent (#647). It puts a base game's
    // control beside the tile, outside that node, and is there with
    // expansions or without, so the tile keeps its element and its focus as
    // the game's first expansion arrives or its last goes (#1048). A tap
    // takes focus first, so what it opens hands focus back (#758).
    return _Nested(
      nested: expansionOf != null,
      child: BgeOutlinedRow(
        child: BgeExpansionsRow(
          expansions: expansions,
          builder: (_, focusNode) => BgeRowFocusRing(
            focusNode: focusNode,
            focusOnTap: true,
            builder: (_, row) => ListTile(
              // Both kinds lead with a thumbnail (#647).
              titleAlignment: BgeThumbnail.titleAlignmentOf(context),
              minTileHeight: BgeThumbnail.minTileHeightOf(context),
              focusNode: row.focusNode,
              onFocusChange: row.onFocusChange,
              focusColor: row.focusColor,
              onTap: row.onTap(
                open == null ? null : () => open(context, entry.id),
              ),
              leading: BgeThumbnail(
                key: GameCollectionListScreen.thumbnailKey(entry.id),
                url: item.thumbnail,
                placeholderIcon: Icons.casino_outlined,
                placeholderKey:
                    GameCollectionListScreen.thumbnailPlaceholderKey,
              ),
              title: Text(
                title,
                semanticsLabel: _spokenTitle(l10n, title, expansionOf),
              ),
              subtitle: _RowDetails(
                items: [item],
                // Joined differently for the eye and the ear: a screen reader
                // would read the visual separator's symbol out.
                details: Text(
                  details
                      .map((d) => d.shown)
                      .join(l10n.collectionListDetailSeparator),
                  semanticsLabel: details
                      .map((d) => d.spoken)
                      .join(l10n.collectionListDetailSpokenSeparator),
                ),
              ),
              trailing: entry.hasFavorited
                  ? Icon(
                      Icons.favorite,
                      semanticLabel: l10n.collectionListFavorite,
                    )
                  : null,
            ),
          ),
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
String collectionItemTitle(
  GameCollectionLocalizations l10n,
  GameCollectionListItem item,
) {
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

/// Where the changes to [items] stand on their way to the server (#47): the
/// worst of their states, stuck, then waiting, then none. One entry's row or
/// cover passes the entry alone; a stack passes its copies, and says the
/// state that most needs the user once, not once per copy.
///
/// Each copy is looked up by its entry's id, which its queued op names: an
/// add names its local id, the entry's id while it is local-only. Every copy
/// is looked up, so the caller rebuilds when any of them gets stuck or
/// unstuck.
BgeSyncState? _syncStateOf(
  BuildContext context,
  List<GameCollectionListItem> items,
) {
  final states = {
    for (final item in items)
      BgeSyncStatusScope.stateOf(
        context,
        recordId: item.entry.id,
        unsynced: hasUnsyncedChange(item.entry),
      ),
  };
  if (states.contains(BgeSyncState.stuck)) return BgeSyncState.stuck;
  if (states.contains(BgeSyncState.waiting)) return BgeSyncState.waiting;
  return null;
}

/// The collection's entries as the list's bloc holds them, for a picker to
/// follow its copies by (#960): each state's entries, so a copy's sync flags
/// change under an open picker. A state that holds none, as a failed read
/// does, leaves every tile as it was. Read from [context], the list's, as the
/// pop-up is above it.
///
/// It starts with the bloc's state when the picker listens, then follows its
/// stream, which replays nothing: the picker listens a frame after the tap
/// that opened it, and a state the bloc took in between, or the items the
/// tap read a frame before it, would otherwise stand until the next one.
Stream<List<GameCollection>> _entriesOf(BuildContext context) {
  final bloc = context.read<GameCollectionListBloc>();
  List<GameCollection> entriesOf(GameCollectionListState state) =>
      state is GameCollectionListReady
      ? [for (final item in state.all) item.entry]
      : const <GameCollection>[];
  return Stream.multi((controller) {
    // Delivered after the picker's initState, as every later state is.
    controller.add(entriesOf(bloc.state));
    final forwarded = bloc.stream
        .map(entriesOf)
        .listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
    controller.onCancel = forwarded.cancel;
  });
}

/// A row's detail line, with a [BgeSyncBadge] under it while [items], the
/// row's entry or a stack's copies, have a change the server hasn't had
/// (#47).
///
/// Under the details rather than in the tile's `trailing`, as on the
/// household list: "Not yet synced" at 200% text is wider than a phone row's
/// trailing slot has to spare, and a badge cut to fit would lose the words
/// that keep the state from resting on colour alone. The badge is drawn text
/// with no node of its own, so the row's `MergeSemantics` reads it after the
/// details.
///
/// One shape with the badge or without it: the details stay in the same
/// column and the badge is added after them, so they keep their element as
/// the entry syncs.
class _RowDetails extends StatelessWidget {
  const _RowDetails({required this.items, required this.details});

  final List<GameCollectionListItem> items;
  final Widget details;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final syncState = _syncStateOf(context, items);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        details,
        if (syncState != null) ...[
          const BgeGap.xs(),
          BgeSyncBadge(state: syncState, label: syncLabel(l10n, syncState)),
        ],
      ],
    );
  }
}

/// The collection as a grid of covers (#710): the top-level games alone,
/// with a badge on a base game's cover, or its stack's, that opens a strip
/// of its expansions' covers under its row (#711).
///
/// One game is unfolded at a time ([BgeUnfoldingCovers]), whether its
/// cover is one entry's or a stack's. The unfold goes once that game is no
/// longer at top level with expansions, as when a sync takes it or its
/// expansions away, so the grid is whole again and the game doesn't come
/// back unfolded.
///
/// Without [onOpen] the covers are inert, and carry no badge: a badge that
/// goes while it holds focus gives it to its cover, which an inert cover
/// can't take.
class CollectionCovers extends StatelessWidget {
  const CollectionCovers({required this.placed, this.onOpen, super.key});

  final List<PlacedGame<List<GameCollectionListItem>>> placed;
  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final onOpen = this.onOpen;
    return BgeUnfoldingCovers<PlacedGame<List<GameCollectionListItem>>>(
      items: placed,
      keyOf: (placed) => switch (placed.item) {
        [final item] => GameCollectionListScreen.tileKey(item.entry.id),
        final group => GameCollectionListScreen.stackTileKey(
          group.first.gameId,
        ),
      },
      idOf: (placed) => placed.item.first.gameId,
      hasStrip: (placed) => placed.expansions.isNotEmpty,
      itemBuilder: (context, placed, toggle, {required unfolded}) {
        final group = placed.item;
        final gameId = group.first.gameId;
        final count = placed.expansions.length;
        final expansions = count == 0 || onOpen == null
            ? null
            : BgeCoverExpansions(
                count: count,
                expanded: unfolded,
                onToggle: toggle,
                label: l10n.collectionExpansionsBadge(
                  collectionItemTitle(l10n, group.first),
                  count,
                ),
                showLabel: l10n.collectionShowExpansions,
                hideLabel: l10n.collectionHideExpansions,
              );
        return BgeFocusHandoff(
          identity: gameId,
          // A folded strip's games are under the badge, so a focused game
          // that moves in there, or whose open strip folds, is handed to it
          // (#813).
          folded: {
            if (!unfolded)
              for (final expansion in placed.expansions) expansion.first.gameId,
          },
          foldedPlace: BgeUnfoldingCovers.stripPlace(gameId),
          foldedControl: BgeCoverTile.expansionsControl,
          child: switch (group) {
            [final item] => _CollectionTile(
              item: item,
              onOpen: onOpen,
              missingBase: placed.missingBase,
              expansions: expansions,
            ),
            _ => _StackTile(
              items: group,
              onOpen: onOpen,
              missingBase: placed.missingBase,
              expansions: expansions,
            ),
          },
        );
      },
      stripBuilder: (context, placed) => _CollectionStrip(
        parent: placed.item.first,
        expansions: placed.expansions,
        onOpen: onOpen,
      ),
    );
  }
}

/// A base game's owned expansions, as a row of covers under its cover's row
/// (#711). Each opens its entry, or its picker for a stack, as a cover in
/// the grid does.
class _CollectionStrip extends StatelessWidget {
  const _CollectionStrip({
    required this.parent,
    required this.expansions,
    this.onOpen,
  });

  /// The base game's first entry, which names it.
  final GameCollectionListItem parent;
  final List<List<GameCollectionListItem>> expansions;
  final void Function(BuildContext context, String entryId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final parentTitle = collectionItemTitle(l10n, parent);
    return BgeShelf(
      heading: l10n.collectionExpansionsStrip(parentTitle),
      previousLabel: l10n.collectionShelfPrevious,
      nextLabel: l10n.collectionShelfNext,
      children: [
        for (final group in expansions)
          BgeFocusHandoff(
            key: switch (group) {
              [final item] => GameCollectionListScreen.nestedTileKey(
                parent.gameId,
                item.entry.id,
              ),
              _ => GameCollectionListScreen.nestedStackTileKey(
                parent.gameId,
                group.first.gameId,
              ),
            },
            identity: group.first.gameId,
            place: BgeUnfoldingCovers.stripPlace(parent.gameId),
            child: switch (group) {
              [final item] => _CollectionTile(
                item: item,
                onOpen: onOpen,
                expansionOf: parentTitle,
              ),
              _ => _StackTile(
                items: group,
                onOpen: onOpen,
                expansionOf: parentTitle,
              ),
            },
          ),
      ],
    );
  }
}

/// An entry's cover alone, named as its row is: the title and the row's
/// spoken details, then the favourite, since no text is drawn to tell two
/// covers apart (#710).
///
/// In a strip under its base game, a shelf's size, and named as an
/// expansion of it, as its nested row is (#711). In the grid, a cell's size,
/// marked when [missingBase].
///
/// While the server hasn't had the entry's change, the cover carries the
/// sync mark, and its label says the words the row's badge shows where the
/// row reads them: after the details, before the favourite (#47).
class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.item,
    this.onOpen,
    this.expansionOf,
    this.missingBase = false,
    this.expansions,
  });

  final GameCollectionListItem item;
  final void Function(BuildContext context, String entryId)? onOpen;

  /// The title of the base game whose strip the cover is in, or null in the
  /// grid (#711).
  final String? expansionOf;

  /// Whether the game is an expansion shown without its base game (#711).
  final bool missingBase;

  /// The game's expansions, for a base game's badge (#711).
  final BgeCoverExpansions? expansions;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final entry = item.entry;
    final open = onOpen;
    final title = collectionItemTitle(l10n, item);
    final syncState = _syncStateOf(context, [item]);
    return BgeCoverTile(
      extent: expansionOf == null ? null : BgeCoverTile.shelfExtent,
      label: [
        _spokenTitle(l10n, title, expansionOf) ?? title,
        if (missingBase) l10n.collectionListBaseGameMissing,
        ..._details(l10n, item).map((d) => d.spoken),
        if (syncState != null) syncLabel(l10n, syncState),
        if (entry.hasFavorited) l10n.collectionListFavorite,
      ].join(l10n.collectionListDetailSpokenSeparator),
      imageUrl: item.thumbnail,
      marked: missingBase,
      syncState: syncState,
      expansions: expansions,
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
/// favourite, and the sync badge says the worst state among them (#47). A
/// tap opens the picker of the entries, and takes focus first
/// ([BgeRowFocusRing.focusOnTap]). A base game's stack has the control for
/// its expansions at its end, as an entry's row does (#1048).
class _StackRow extends StatelessWidget {
  const _StackRow({
    required this.items,
    this.onOpen,
    this.expansionOf,
    this.missingBase = false,
    this.expansions,
  });

  final List<GameCollectionListItem> items;
  final void Function(BuildContext context, String entryId)? onOpen;

  /// The title of the base game this row is shown under, or null at top
  /// level (#711).
  final String? expansionOf;

  /// Whether the game is an expansion shown without its base game (#711).
  final bool missingBase;

  /// The game's expansions, for a base game's control (#1048).
  final BgeCoverExpansions? expansions;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final open = onOpen;
    final first = items.first;
    final copies = _copies(l10n, items);
    final missing = missingBase ? l10n.collectionListBaseGameMissing : null;

    // As on an entry's row, the merged node is inside the outline (#647),
    // with a base game's control beside it (#1048), and a tap takes focus
    // first (#758).
    return _Nested(
      nested: expansionOf != null,
      child: BgeOutlinedRow(
        child: BgeExpansionsRow(
          expansions: expansions,
          builder: (_, focusNode) => BgeRowFocusRing(
            focusNode: focusNode,
            focusOnTap: true,
            builder: (_, row) => ListTile(
              // Both kinds lead with a thumbnail (#647).
              titleAlignment: BgeThumbnail.titleAlignmentOf(context),
              minTileHeight: BgeThumbnail.minTileHeightOf(context),
              focusNode: row.focusNode,
              onFocusChange: row.onFocusChange,
              focusColor: row.focusColor,
              onTap: row.onTap(
                open == null
                    ? null
                    : () => unawaited(
                        openCollectionEntries(
                          context,
                          items: items,
                          onOpen: open,
                          updates: _entriesOf(context),
                        ),
                      ),
              ),
              // The picture is smaller by the marker's offsets, so the marked
              // whole is an entry's thumbnail's size and the titles line up.
              // A list tile caps its leading at that height, so a full-size
              // picture with its offsets would be squeezed.
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
                collectionItemTitle(l10n, first),
                semanticsLabel: _spokenTitle(
                  l10n,
                  collectionItemTitle(l10n, first),
                  expansionOf,
                ),
              ),
              subtitle: _RowDetails(
                items: items,
                details: Text(
                  [
                    ?missing,
                    copies.shown,
                  ].join(l10n.collectionListDetailSeparator),
                  semanticsLabel: [
                    ?missing,
                    copies.spoken,
                  ].join(l10n.collectionListDetailSpokenSeparator),
                ),
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
      ),
    );
  }
}

/// A stack's cover (#709), marked with the count of its entries and named as
/// its row is: the title, the copies, then the favourite.
///
/// In a strip, in the grid, marked and with a badge as [_CollectionTile] is
/// (#711).
///
/// The sync mark says the worst state among the copies, and the label says
/// it once, where the row reads its badge: after the copies, before the
/// favourite (#47).
class _StackTile extends StatelessWidget {
  const _StackTile({
    required this.items,
    this.onOpen,
    this.expansionOf,
    this.missingBase = false,
    this.expansions,
  });

  final List<GameCollectionListItem> items;
  final void Function(BuildContext context, String entryId)? onOpen;

  /// The title of the base game whose strip the cover is in, or null in the
  /// grid (#711).
  final String? expansionOf;

  /// Whether the game is an expansion shown without its base game (#711).
  final bool missingBase;

  /// The game's expansions, for a base game's badge (#711).
  final BgeCoverExpansions? expansions;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final open = onOpen;
    final first = items.first;
    final title = collectionItemTitle(l10n, first);
    final syncState = _syncStateOf(context, items);
    return BgeCoverTile(
      extent: expansionOf == null ? null : BgeCoverTile.shelfExtent,
      stackCount: items.length,
      label: [
        _spokenTitle(l10n, title, expansionOf) ?? title,
        if (missingBase) l10n.collectionListBaseGameMissing,
        _copies(l10n, items).spoken,
        if (syncState != null) syncLabel(l10n, syncState),
        if (items.any((item) => item.entry.hasFavorited))
          l10n.collectionListFavorite,
      ].join(l10n.collectionListDetailSpokenSeparator),
      imageUrl: first.thumbnail,
      marked: missingBase,
      syncState: syncState,
      expansions: expansions,
      // The tile takes focus on a tap before this runs, so the picker hands
      // it back when it closes.
      onTap: open == null
          ? null
          : () => unawaited(
              openCollectionEntries(
                context,
                items: items,
                onOpen: open,
                updates: _entriesOf(context),
              ),
            ),
    );
  }
}
