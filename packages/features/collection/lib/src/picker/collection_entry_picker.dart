import 'dart:async';

import 'package:flutter/material.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/medium_label.dart';
import 'package:game_collection/src/sync_label.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens a picker over [items], the entries of one game, through
/// [showBgePopup]: a sheet on a phone and a dialog on a wider window, on the
/// root navigator (#709).
///
/// A tile per entry, two across, in the order given: every entry of a game
/// shown once as a stack in Collection, or one platform's entries from the
/// game's detail page. [items] are two or more, all of one game; one entry
/// needs no picker, and its caller opens it directly. The set of tiles is
/// the entries the picker opened with; each tile's entry is live (below).
///
/// The pop-up is headed and named by `collectionPickerTitle`, with the
/// game's title.
///
/// **A tile says which copy hasn't synced** (#960). The pop-up is above the
/// session's sync scope, which sits under the app's shell, so it puts the
/// state back from the relay that scope carries, read from [context] here and
/// not from the pop-up's own, which has no scope above it. A tile's badge
/// then changes while the picker is open.
///
/// **A tile opens its entry from its own context, not [context].** [onOpen]
/// is given the tile's context and the entry's id, as the catalog's quick
/// look hands its View full details the pop-up's. The widget that opened the
/// picker can go while it is open, as a stack does when a sync leaves its
/// game with one entry, and a push from a context that has gone asserts.
///
/// **What is live is each copy's sync flags, not the set of tiles** (#960).
/// With [updates], the entries as the cache holds them, each tile takes its
/// entry as it stands, by id, from the newest emission, so a badge goes when
/// its push lands (it reads the entry's `isDirty` and `isLocalOnly`). An
/// emission may hold more entries than the picker has tiles, as the whole
/// collection's does: those add none.
/// A tile whose entry is missing from one keeps the entry it last had. The
/// subscription ends with the pop-up, and an error from it leaves the tiles
/// as they were. Without [updates] the entries are as they were when the
/// picker opened.
///
/// It doesn't close the picker either. The page it opens removes it once
/// the page has arrived ([BgeRemoveWhenCovered]), so back from that page
/// lands where the picker was opened, with no picker. Under the app's
/// navigation shell the page arrives beneath the picker, which goes once it
/// has (see `showBgePopup`).
Future<void> showCollectionEntryPicker(
  BuildContext context, {
  required List<GameCollectionListItem> items,
  required void Function(BuildContext context, String entryId) onOpen,
  Stream<List<GameCollection>>? updates,
}) {
  assert(items.length >= 2, 'one entry is opened directly, with no picker');
  assert(
    items.every((item) => item.gameId == items.first.gameId),
    'a picker lists the entries of one game',
  );
  final title = GameCollectionLocalizations.of(context)
      .collectionPickerTitle(items.first.title);
  final relay = BgeSyncStatusScope.relayOf(context);
  return showBgePopup<void>(
    context,
    semanticLabel: title,
    builder: (_) => BgeSyncStatusRelayScope(
      relay: relay,
      child: _CollectionEntryPickerContent(
        title: title,
        items: items,
        updates: updates,
        onOpen: onOpen,
      ),
    ),
  );
}

/// Opens [items], one game's entries (one or more): the entry itself when
/// there is one, the picker when there are several (#709).
///
/// The rule every caller shares, as the picker asks for two or more: a lone
/// entry is given to [onOpen] with [context], and several go to
/// [showCollectionEntryPicker], whose tiles hand [onOpen] their own context.
/// [updates] goes to the picker, and a lone entry, opened at once, has no use
/// for it.
Future<void> openCollectionEntries(
  BuildContext context, {
  required List<GameCollectionListItem> items,
  required void Function(BuildContext context, String entryId) onOpen,
  Stream<List<GameCollection>>? updates,
}) {
  assert(items.isNotEmpty, 'a game has at least one entry to open');
  if (items.length == 1) {
    onOpen(context, items.single.entry.id);
    return Future<void>.value();
  }
  return showCollectionEntryPicker(
    context,
    items: items,
    onOpen: onOpen,
    updates: updates,
  );
}

/// How [item] is named among [all], the entries of its game: its platform,
/// with its medium where another of [all] is on the same platform, so the
/// two can be told apart (#709).
///
/// "Steam · Physical" beside "Steam · Digital", and "Tabletop" alone. The
/// spoken form, "Steam Physical", drops the dot, which a screen reader
/// would read out, and puts no comma in its place: a stack's name lists these
/// with commas between them, and a comma inside each would make two copies
/// sound like four.
///
/// Entries are matched by the platform name the label shows, as the label is
/// there to tell apart what is shown: two entries under one name would read
/// the same without their mediums.
({String shown, String spoken}) collectionEntryLabel(
  GameCollectionLocalizations l10n,
  GameCollectionListItem item,
  List<GameCollectionListItem> all,
) {
  final platform = item.platformName;
  final shared = all.any(
    (other) =>
        other.entry.id != item.entry.id && other.platformName == platform,
  );
  if (!shared) return (shown: platform, spoken: platform);
  final medium = mediumLabel(l10n, item.entry.medium);
  return (
    shown: l10n.collectionPickerEntryWithMedium(platform, medium),
    spoken: l10n.collectionPickerEntryWithMediumSpoken(platform, medium),
  );
}

/// The keys of the picker [showCollectionEntryPicker] opens (#709).
abstract final class CollectionEntryPicker {
  /// Key on the tile of the entry [entryId].
  static Key tileKey(String entryId) => Key('collection_picker.tile_$entryId');
}

/// The picker's heading over its tiles, two across, and the live entries
/// behind them.
///
/// Built row by row rather than as a grid, whose cells are all one height:
/// a label that wraps to a second line, as a long platform name does at
/// large text, grows its own row instead of being cut.
///
/// The covers grow with the width up to [_maxCoverExtent], and the content
/// is no wider than two of them. Left to fill it, the dialog's 480dp made
/// each cover 216dp, and four entries didn't fit an 800 by 600 window.
///
/// Capped, the dialog is as wide as its content. A sheet would be too, as
/// Flutter lays a bottom sheet out, and float off a phone's edges, so in a
/// sheet the content fills the width and centres itself. Which of the two it
/// is in comes from the pop-up ([BgePopupForm.maybeOf]), not the window's
/// width, so it agrees with the form the pop-up is drawn in, and changes
/// with it when the window is resized (#733).
class _CollectionEntryPickerContent extends StatefulWidget {
  const _CollectionEntryPickerContent({
    required this.title,
    required this.items,
    required this.onOpen,
    this.updates,
  });

  /// The widest a tile's cover grows: the cover on a game's detail page.
  static const double _maxCoverExtent = 160;

  final String title;
  final List<GameCollectionListItem> items;
  final void Function(BuildContext context, String entryId) onOpen;
  final Stream<List<GameCollection>>? updates;

  @override
  State<_CollectionEntryPickerContent> createState() =>
      _CollectionEntryPickerContentState();
}

class _CollectionEntryPickerContentState
    extends State<_CollectionEntryPickerContent> {
  /// The tiles' items: the set the picker opened with, each with the latest
  /// entry the live source has given for it.
  late List<GameCollectionListItem> _items;
  StreamSubscription<List<GameCollection>>? _updates;

  @override
  void initState() {
    super.initState();
    _items = widget.items;
    _updates = widget.updates?.listen(
      _onEntries,
      // A source that fails, as a session's end can make it, leaves the tiles
      // as they were; there is no one to tell, and a picker is short-lived.
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    super.dispose();
  }

  void _onEntries(List<GameCollection> entries) {
    final latest = {for (final entry in entries) entry.id: entry};
    var changed = false;
    final next = [
      for (final item in _items)
        if (latest[item.entry.id] case final entry? when entry != item.entry)
          item.copyWith(entry: entry)
        else
          item,
    ];
    for (final (index, item) in next.indexed) {
      changed = changed || item != _items[index];
    }
    if (!changed) return;
    setState(() => _items = next);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final items = _items;
    final onOpen = widget.onOpen;
    final l10n = GameCollectionLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    Widget tile(GameCollectionListItem item) => _EntryTile(
      key: CollectionEntryPicker.tileKey(item.entry.id),
      item: item,
      label: collectionEntryLabel(l10n, item, items),
      onOpen: onOpen,
    );

    final maxWidth =
        2 * _CollectionEntryPickerContent._maxCoverExtent + tokens.spaceMd;
    final inDialog = BgePopupForm.maybeOf(context) == BgePopupForm.dialog;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceLg,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        widthFactor: inDialog ? 1 : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spaceMd,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (var i = 0; i < items.length; i += 2)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: tokens.spaceMd,
                  children: [
                    Expanded(child: tile(items[i])),
                    // The empty cell beside an odd last tile keeps that tile
                    // one column wide.
                    Expanded(
                      child: i + 1 < items.length
                          ? tile(items[i + 1])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One entry's cover with its label under it, as one button named by the
/// spoken label (#709).
///
/// The cover is a [BgeCoverTile] with no tap, which is inert content and not
/// a focus stop. With a tap it would be a button of its own, named by its
/// label alone, and one button inside another is two stops and two names for
/// one choice. This button covers the cover and the label, so a tap on either
/// opens the entry, and the label is drawn and not read: the button's name
/// already says it.
///
/// Its ink is a layer over the cover and the label, as [BgeCoverTile]'s is:
/// an ink beneath an opaque cover would never show. A [BgeFocusRing] rings
/// the whole tile while it has the keyboard's focus.
///
/// A copy whose change the server hasn't had carries a [BgeSyncBadge] under
/// its label, and its words join the button's name after the platform's, as a
/// row's badge is read after its details (#960).
///
/// A tap doesn't give the tile focus, as [BgeCoverTile]'s does to be handed
/// it back: the page it opens removes the picker, so there is nothing to
/// come back to, and focus from a click would ring the tile on a desktop.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.item,
    required this.label,
    required this.onOpen,
    super.key,
  });

  final GameCollectionListItem item;
  final ({String shown, String spoken}) label;
  final void Function(BuildContext context, String entryId) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final radius = BorderRadius.circular(tokens.radiusSm);
    final syncState = BgeSyncStatusScope.stateOf(
      context,
      recordId: item.entry.id,
      unsynced: hasUnsyncedChange(item.entry),
    );

    // MergeSemantics so the name and the ink's tap and focus are one node.
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: [
          label.spoken,
          if (syncState != null) syncLabel(l10n, syncState),
        ].join(l10n.collectionListDetailSpokenSeparator),
        child: BgeFocusRing(
          borderRadius: radius,
          builder: (_, onFocusChange) => Stack(
            children: [
              ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: tokens.spaceSm,
                  children: [
                    BgeCoverTile(
                      label: label.spoken,
                      imageUrl: item.thumbnail,
                      extent: null,
                    ),
                    // Clear of the focus ring, which is drawn inside the
                    // tile's edge.
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        start: tokens.spaceXs,
                        end: tokens.spaceXs,
                        bottom: tokens.spaceXs,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label.shown,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          if (syncState != null) ...[
                            const BgeGap.xs(),
                            // On the pop-up's container ground, where the
                            // status colours fall short of 7:1 as text in
                            // high contrast.
                            BgeSyncBadge(
                              state: syncState,
                              label: syncLabel(l10n, syncState),
                              onContainer: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => onOpen(context, item.entry.id),
                    onFocusChange: onFocusChange,
                    borderRadius: radius,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
