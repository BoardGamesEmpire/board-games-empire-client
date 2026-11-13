import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:events/src/widgets/event_game_filter_options.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:flutter/material.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Offer games page (#516): the viewer's collection, to pick games from
/// to offer to bring to an event. It pops its route with the picks, a
/// `List<OfferPick>` in the list's order, or with null on Back.
///
/// The page sends nothing. The event's Games tab opened it with [args], and
/// sends the picks once it is back on top, checked against the event as it
/// shows it then; its footer says the run is out, and then how it went. So
/// the footer's button is a choice made, not a request in flight, and needs
/// no connection: Offer games, which opened the page, did.
///
/// Read through [collection]'s `watchCollectionListItems`, in title order,
/// and kept up to date while the page is open.
///
/// - **Rows.** One checkbox row per collection entry, flat: two copies of a
///   game are two rows, and an expansion is a row of its own, never under
///   its base game. Each is one node saying its title, with its subtitle as
///   Collection's rows show it, since the search matches both, where it is
///   played and whether it is picked. An entry already offered
///   ([OfferGamesArgs.offeredCollectionIds]) is checked and disabled, and
///   says so; one made offline and not on the server
///   (`GameCollection.isLocalOnly`) is unchecked and disabled, and says so.
///   Neither is ever picked. A disabled row is left out of the Tab order, as
///   a disabled control is; a screen reader still reads it, with its
///   reason, and the reason is drawn on the row.
/// - **Narrowing.** A search field, then the shared Filters button and
///   chips (`game_filters`) with the medium and the flips, then how many
///   rows are shown, as a live region. Applied as each changes.
/// - **Picks.** Kept by collection entry id, so a pick stays through a
///   filter that hides its row and through an update that moves rows; an
///   entry that leaves the collection leaves the picks. *Select all shown*
///   picks every row shown that can be picked, adding to what is picked; it
///   becomes *Clear selection*, which clears every pick, shown or not, once
///   every such row is picked. Where nothing shown can be picked it is
///   disabled, saying why.
/// - **The footer.** "Offer {n} games", counting every pick, shown or not,
///   disabled with none.
///
/// ## States
///
/// A wait for the first answer, a collection with nothing in it, and a
/// search or filter that leaves nothing, with Clear filters. A collection
/// read that fails or ends, as it does when the session closes, shows an
/// error whose one button goes back to the event: there is nothing to read
/// again from here, and opening the page again reads it anew.
///
/// ## Where focus goes
///
/// - **Clear filters** leaves with the state it sits in, so its press,
///   however it came, hands focus to the Filters button, if focus is free
///   then; never to the emptied search field, whose focus would open the
///   on-screen keyboard.
/// - **A focused chip removed** goes to the chip in its place, else the one
///   before it, as `GameFiltersInUse` hands it on; after the last, to the
///   Filters button.
/// - **Select all shown** keeps its place, and its focus, as its label
///   swaps.
/// - **The footer's button and Back** close the page, and the route hands
///   focus back to Offer games on the event, which opened it.
class OfferGamesScreen extends StatelessWidget {
  const OfferGamesScreen({
    required this.collection,
    required this.args,
    super.key,
  });

  /// Key on the search field.
  static const Key searchKey = Key('offer_games.search');

  /// Key on *Select all shown*, which is *Clear selection* in its turn.
  static const Key selectAllKey = Key('offer_games.select_all');

  /// Key on the count of the rows shown.
  static const Key countKey = Key('offer_games.count');

  /// Key on the footer's Offer button.
  static const Key sendKey = Key('offer_games.send');

  /// Key on Clear filters, where nothing matches.
  static const Key clearFiltersKey = Key('offer_games.clear_filters');

  /// Key on the failed state's way back to the event.
  static const Key backKey = Key('offer_games.back');

  /// Key on the row of the collection entry [collectionId].
  static Key rowKey(String collectionId) =>
      Key('offer_games.row_$collectionId');

  /// The user-session collection the rows are read from.
  final GameCollectionRepository collection;

  /// What the event's Games tab opened the page with.
  final OfferGamesArgs args;

  @override
  Widget build(BuildContext context) => _OfferGamesPage(
    // Another collection, as after a session change, is read afresh.
    key: ObjectKey(collection),
    collection: collection,
    args: args,
  );
}

class _OfferGamesPage extends StatefulWidget {
  const _OfferGamesPage({
    required this.collection,
    required this.args,
    super.key,
  });

  final GameCollectionRepository collection;
  final OfferGamesArgs args;

  @override
  State<_OfferGamesPage> createState() => _OfferGamesPageState();
}

/// What the page shows under its header, if it has one.
enum _Body {
  /// Waiting for the first answer. No header.
  loading,

  /// The read failed or ended. No header.
  failed,

  /// The collection holds nothing. No header.
  empty,

  /// The search and the filters leave nothing.
  noMatches,

  /// The rows the search and the filters keep.
  rows,
}

class _OfferGamesPageState extends State<_OfferGamesPage> {
  static final _logger = BgeLogger('bge.events.offer_games');

  /// Key on the header's sliver, so it keeps its state, and its controls
  /// their focus, as what is under it changes.
  static const _headerKey = ValueKey<String>('offer_games.header');

  StreamSubscription<List<GameCollectionListItem>>? _watch;

  /// The collection as last read; null until the first answer.
  List<GameCollectionListItem>? _items;

  /// The read failed or ended.
  bool _failed = false;

  /// The entries picked, by collection entry id.
  final Set<String> _picked = {};

  /// What the rows are narrowed to; its query is the search field's.
  CollectionFilter _filter = const CollectionFilter();

  /// The entries of [_items] that [_filter] keeps. Worked out as either
  /// changes ([_narrow]), not at each build: a pick builds the page too, and
  /// narrows nothing.
  List<GameCollectionListItem> _rows = const [];

  /// How many times the filters were cleared from outside the search
  /// field. Each builds the field afresh, empty.
  int _clears = 0;

  /// The Filters button's, which takes focus after the last chip and after
  /// Clear filters.
  final _filtersFocus = FocusNode(debugLabel: 'Offer games filters');

  /// Clear filters', in the state that says nothing matches.
  final _clearFocus = FocusNode(debugLabel: 'Offer games clear filters');

  @override
  void initState() {
    super.initState();
    _watch = widget.collection.watchCollectionListItems().listen(
      _read,
      onError: (Object error, StackTrace stackTrace) {
        _logger.warn(
          'Collection read failed',
          error: error,
          stackTrace: stackTrace,
        );
        _stop();
      },
      onDone: _stop,
    );
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    _filtersFocus.dispose();
    _clearFocus.dispose();
    super.dispose();
  }

  /// Whether [item] can be picked: not offered already, and on the server.
  bool _pickable(GameCollectionListItem item) =>
      !widget.args.offeredCollectionIds.contains(item.entry.id) &&
      !item.entry.isLocalOnly;

  void _read(List<GameCollectionListItem> items) {
    if (!mounted || _failed) return;
    setState(() {
      _items = items;
      _narrow();
      // An entry that left, or that can't be picked, leaves the picks.
      final pickable = {
        for (final item in items)
          if (_pickable(item)) item.entry.id,
      };
      _picked.retainWhere(pickable.contains);
    });
  }

  /// The read failed or ended: nothing read can be sent.
  void _stop() {
    if (!mounted || _failed) return;
    setState(() {
      _failed = true;
      _picked.clear();
    });
  }

  /// Works out the rows again, for the collection and the filter as they
  /// are now.
  void _narrow() => _rows = filterCollection(
    _items ?? const <GameCollectionListItem>[],
    _filter,
  );

  void _setFilter(CollectionFilter filter) {
    if (filter == _filter) return;
    setState(() {
      _filter = filter;
      _narrow();
    });
  }

  void _toggle(String id, {required bool picked}) => setState(() {
    if (picked) {
      _picked.add(id);
    } else {
      _picked.remove(id);
    }
  });

  /// Picks every row of [shown] that can be picked, or, once all of them
  /// are, clears every pick.
  void _selectAll(List<String> shown, {required bool allPicked}) =>
      setState(() {
        if (allPicked) {
          _picked.clear();
        } else {
          _picked.addAll(shown);
        }
      });

  /// Clears the search and the filters, from Clear filters, which leaves
  /// with the state it sits in: the field is emptied, and focus handed to
  /// the Filters button, if focus is free then ([focusIsFree], with Clear
  /// filters counting as free if it held focus at the press). The press
  /// arms it however it came. Never to the search field: focus put on a text
  /// field opens the on-screen keyboard, over the rows the user asked to see.
  void _clearFilters() {
    final held = _clearFocus.hasFocus ? _clearFocus : null;
    setState(() {
      _clears++;
      _filter = const CollectionFilter();
      _narrow();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(context, untouched: held)) return;
      _filtersFocus.requestFocus();
    });
  }

  Future<void> _openFilters(BuildContext context) => showGameFilterSheet(
    context,
    initial: _filter,
    options: eventGameFilterOptions,
    onChanged: (filter) {
      if (mounted) _setFilter(filter);
    },
  );

  /// Pops with the picks, in the list's order, each named as its row names
  /// it.
  void _send() {
    final l10n = EventsLocalizations.of(context);
    final picks = [
      for (final item in _items ?? const <GameCollectionListItem>[])
        if (_picked.contains(item.entry.id))
          OfferPick(
            collectionId: item.entry.id,
            title: gameName(l10n, item.title, item.subtitle),
          ),
    ];
    if (picks.isEmpty) return;
    Navigator.of(context).pop(picks);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final items = _items;
    final rows = items == null || _failed
        ? const <GameCollectionListItem>[]
        : _rows;
    final body = _failed
        ? _Body.failed
        : items == null
        ? _Body.loading
        : items.isEmpty
        ? _Body.empty
        : rows.isEmpty
        ? _Body.noMatches
        : _Body.rows;

    return BgePage.slivers(
      title: Text(l10n.eventsOfferTitle),
      width: BgePageWidth.pane,
      semanticChildCount: body == _Body.rows ? rows.length : 0,
      // Passed on every build, so the page keeps one shape.
      footer: Padding(
        padding: EdgeInsets.only(top: BgeTokens.of(context).spaceSm),
        child: BgeSubmitButton(
          key: OfferGamesScreen.sendKey,
          label: l10n.eventsOfferSend(_picked.length),
          onPressed: _picked.isEmpty ? null : _send,
        ),
      ),
      slivers: [
        if (body == _Body.rows || body == _Body.noMatches)
          SliverToBoxAdapter(
            key: _headerKey,
            child: _header(context, l10n, rows),
          ),
        switch (body) {
          _Body.loading => BgeStateSliver(
            child: BgeLoadingState(label: l10n.eventsOfferLoading),
          ),
          _Body.failed => BgeStateSliver(
            child: BgeErrorState(
              icon: Icons.error_outline,
              title: l10n.eventsOfferFailedTitle,
              body: l10n.eventsOfferFailedBody,
              retryLabel: l10n.eventsOfferBack,
              retryKey: OfferGamesScreen.backKey,
              onRetry: () => Navigator.of(context).maybePop(),
            ),
          ),
          _Body.empty => BgeStateSliver(
            child: BgeEmptyState(
              icon: Icons.casino_outlined,
              title: l10n.eventsOfferEmptyTitle,
            ),
          ),
          _Body.noMatches => BgeStateSliver(
            child: BgeEmptyState(
              icon: Icons.search_off_outlined,
              title: l10n.eventsOfferNoMatchesTitle,
              action: OutlinedButton(
                key: OfferGamesScreen.clearFiltersKey,
                focusNode: _clearFocus,
                onPressed: _clearFilters,
                child: Text(l10n.eventsOfferClearFilters),
              ),
            ),
          ),
          _Body.rows => BgeKeyedSliverList<GameCollectionListItem>(
            items: rows,
            keyOf: (item) => OfferGamesScreen.rowKey(item.entry.id),
            itemBuilder: (context, item) {
              final id = item.entry.id;
              final offered = widget.args.offeredCollectionIds.contains(id);
              return _OfferRow(
                item: item,
                checked: offered || _picked.contains(id),
                reason: offered
                    ? l10n.eventsOfferAlready
                    : item.entry.isLocalOnly
                    ? l10n.eventsOfferNotSynced
                    : null,
                onChanged: (picked) => _toggle(id, picked: picked),
              );
            },
          ),
        },
      ],
    );
  }

  /// The search field, the Filters button and Select all shown, the chips
  /// of the filters in use, and how many of [rows] are shown.
  Widget _header(
    BuildContext context,
    EventsLocalizations l10n,
    List<GameCollectionListItem> rows,
  ) {
    final tokens = BgeTokens.of(context);
    final inUse = gameFiltersInUseCount(
      _filter,
      options: eventGameFilterOptions,
    );
    final shown = [
      for (final item in rows)
        if (_pickable(item)) item.entry.id,
    ];
    final allPicked = shown.isNotEmpty && shown.every(_picked.contains);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BgeSearchField(
          // A field built afresh, empty, only when the filters are cleared
          // from outside it.
          key: ValueKey<int>(_clears),
          fieldKey: OfferGamesScreen.searchKey,
          label: l10n.eventsOfferSearchLabel,
          clearLabel: l10n.eventsOfferSearchClear,
          initial: _filter.query,
          onChanged: (query) => _setFilter(_filter.copyWith(query: query)),
        ),
        const BgeGap.sm(),
        Wrap(
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            GameFiltersButton(
              count: inUse,
              focusNode: _filtersFocus,
              onPressed: () => unawaited(_openFilters(context)),
            ),
            // One button in one place whichever it says, so it keeps its
            // focus as its label swaps. Disabled, the merged node says so
            // itself, as `BgeOnlineOnly`'s does, so the text-contrast check
            // passes its dimmed label over, which WCAG 1.4.3 exempts.
            MergeSemantics(
              child: Semantics(
                hint: shown.isEmpty ? l10n.eventsOfferNothingToSelect : null,
                enabled: shown.isEmpty ? false : null,
                child: OutlinedButton.icon(
                  key: OfferGamesScreen.selectAllKey,
                  onPressed: shown.isEmpty
                      ? null
                      : () => _selectAll(shown, allPicked: allPicked),
                  icon: Icon(
                    allPicked ? Icons.deselect : Icons.select_all,
                  ),
                  label: Text(
                    allPicked
                        ? l10n.eventsOfferClearSelection
                        : l10n.eventsOfferSelectAll,
                  ),
                ),
              ),
            ),
          ],
        ),
        // Always in the tree, drawing nothing without a chip, so that it is
        // there to hand focus on after its last chip goes. Spaced from above
        // only while it shows chips.
        Padding(
          padding: EdgeInsets.only(top: inUse > 0 ? tokens.spaceSm : 0),
          child: GameFiltersInUse(
            filter: _filter,
            options: eventGameFilterOptions,
            onChanged: _setFilter,
            onEmptied: _filtersFocus.requestFocus,
          ),
        ),
        const BgeGap.sm(),
        // A filter applied takes a live region on the text that changed.
        Semantics(
          key: OfferGamesScreen.countKey,
          container: true,
          liveRegion: true,
          child: Text(
            l10n.eventsOfferCount(rows.length),
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        const BgeGap.md(),
      ],
    );
  }
}

/// One collection entry (#516): its picture, its title with its subtitle
/// where it has one ([gameName]), where it is played and, where it can't be
/// picked, why, with its checkbox, as one node. A null [reason] is a row
/// that can be picked.
///
/// A row that can't be picked is a disabled tile: its title and platform
/// line, the control's own label, take the disabled look, which WCAG 1.4.3
/// exempts. Its reason is what the user reads to know why, so it is drawn
/// legibly, as `BgeOnlineOnlyLabel` draws its reason on a disabled item:
/// `bodySmall` in `onSurfaceVariant`, which the scheme tests hold to AA on
/// every surface role.
class _OfferRow extends StatelessWidget {
  const _OfferRow({
    required this.item,
    required this.checked,
    required this.reason,
    required this.onChanged,
  });

  final GameCollectionListItem item;
  final bool checked;
  final String? reason;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final medium = switch (item.entry.medium) {
      GameMedium.physical => l10n.eventsGamesMediumPhysical,
      GameMedium.digital => l10n.eventsGamesMediumDigital,
    };
    final reason = this.reason;
    final theme = Theme.of(context);

    return CheckboxListTile(
      value: checked,
      onChanged: reason != null ? null : (value) => onChanged(value ?? false),
      contentPadding: EdgeInsets.zero,
      // The intra-control step either side of the text, not the tile's
      // 16dp: at 320dp and 200% text the picture and the checkbox leave
      // the title little room, and a long word would break mid-word.
      horizontalTitleGap: BgeTokens.of(context).spaceSm,
      secondary: BgeThumbnail(url: item.thumbnail),
      title: Text(gameName(l10n, item.title, item.subtitle)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.eventsGamesWhere(item.platformName, medium),
            semanticsLabel: l10n.eventsGamesWhereSpoken(
              item.platformName,
              medium,
            ),
          ),
          if (reason != null)
            Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
