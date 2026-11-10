import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/bloc/game_collection_list_bloc.dart';
import 'package:game_collection/src/bloc/game_collection_list_event.dart';
import 'package:game_collection/src/bloc/game_collection_list_state.dart';
import 'package:game_collection/src/screens/game_collection_list_screen.dart';
import 'package:game_filters/game_filters.dart';
// The domain's Visibility is who may see a thing; the widget is wanted here.
import 'package:models/domain.dart' hide Visibility;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the collection's filter sheet offers, and so what its chips name and
/// its Filters button counts (#715): the game search's sections, plus the
/// medium, the expansions missing their base game, and a flip under each.
const collectionFilterOptions = GameFilterOptions(
  medium: true,
  missingBaseGame: true,
  exclusion: true,
);

/// The head of the collection list (#715), top to bottom: the search field;
/// the Filters button and the sort button, with the layout toggle at the
/// end; a chip for each filter in use; and, while anything narrows the list,
/// how many games it shows of how many are owned.
///
/// Built in every state of the list, so each control keeps its place and its
/// focus as the list below changes. The filter and the sort live in the
/// [GameCollectionListBloc], so they last exactly as long as the screen, and
/// the header draws them from the bloc's [GameCollectionListBloc.filter] and
/// [GameCollectionListBloc.sort]. It is built again on each of the bloc's
/// states and on each change it sends, which the bloc has taken by the
/// frame that builds it: a loading or failed list emits no state for a
/// change, and the Filters count, the chips and the sort button would
/// otherwise show the one before.
///
/// ## Where focus goes
///
/// - **Clear filters**, in the no-matches state below, empties the search
///   field and leaves the list, so
///   [CollectionListControlsState.filtersCleared] hands focus to the Filters
///   button, never to the field, whose focus would open the on-screen
///   keyboard. Its press arms the hand-off however it arrived, and focus
///   moves only if it is free then. The field owns its text, so it is
///   emptied by building it afresh under a new key; typing never does that.
/// - **A chip removed**, by any press, hands focus to the chip in its place,
///   else the one before it, as `GameFiltersInUse` hands it on, if focus is
///   free then; after the last chip, to the Filters button.
/// - **The sort menu** gives focus back to its button after a pick or Escape,
///   as the menu focuses the button when it opens.
/// - **The search's clear button** keeps focus on the field itself.
class CollectionListControls extends StatefulWidget {
  const CollectionListControls({
    required this.thumbnails,
    required this.onLayoutChanged,
    super.key,
  });

  /// Whether the toggle shows thumbnails as chosen.
  final bool thumbnails;

  /// Called with the layout the user chose.
  final ValueChanged<bool> onLayoutChanged;

  @override
  State<CollectionListControls> createState() => CollectionListControlsState();
}

/// [CollectionListControls]' state, which the page reaches to say the
/// filters were cleared from outside it.
class CollectionListControlsState extends State<CollectionListControls> {
  /// The Filters button's, which takes focus after the last chip and after
  /// Clear filters.
  final _filtersFocus = FocusNode(debugLabel: 'CollectionListControls filters');

  /// The sort button's, which the menu focuses as it opens and so gives focus
  /// back to as it closes.
  final _sortFocus = FocusNode(debugLabel: 'CollectionListControls sort');
  final _sortMenu = MenuController();

  /// How many times the filters were cleared from outside the search field.
  /// Each builds the field afresh, empty.
  int _clears = 0;

  /// The text the search field is built with.
  late String _seed;

  @override
  void initState() {
    super.initState();
    _seed = context.read<GameCollectionListBloc>().filter.query;
  }

  @override
  void dispose() {
    _filtersFocus.dispose();
    _sortFocus.dispose();
    super.dispose();
  }

  /// The filters were cleared from outside the header, by the no-matches
  /// state's Clear filters, which sent the bloc an empty filter: the field
  /// is emptied, and focus handed to the Filters button.
  ///
  /// Clear filters leaves with the state it sits in, so its press, however
  /// it arrived, hands focus on, if focus is free once the field is
  /// emptied ([focusIsFree], with [held], the Clear filters button's node
  /// when it held focus, counting as free). Never to the search field: focus
  /// put on a text field opens the on-screen keyboard, over the list the
  /// user asked to see.
  void filtersCleared({FocusNode? held}) {
    setState(() {
      _clears++;
      _seed = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(context, untouched: held)) return;
      _filtersFocus.requestFocus();
    });
  }

  /// Sends [event] to [bloc], and draws what it changed, unless the header
  /// has gone.
  ///
  /// It is also the sheet's `onChanged`, which can come after the screen
  /// and its bloc have gone: a field closing with the sheet commits too.
  void _send(GameCollectionListBloc bloc, GameCollectionListEvent event) {
    if (bloc.isClosed) return;
    bloc.add(event);
    if (mounted) setState(() {});
  }

  void _setFilter(CollectionFilter filter) => _send(
    context.read<GameCollectionListBloc>(),
    GameCollectionListFilterChanged(filter),
  );

  Future<void> _openFilters(BuildContext context) {
    // The sheet's route sits above the screen's provider, so the bloc is
    // held here. A field closing with the sheet commits too, after the
    // screen and its bloc may have gone.
    final bloc = context.read<GameCollectionListBloc>();
    return showGameFilterSheet(
      context,
      initial: bloc.filter,
      options: collectionFilterOptions,
      onChanged: (filter) =>
          _send(bloc, GameCollectionListFilterChanged(filter)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    return BlocBuilder<GameCollectionListBloc, GameCollectionListState>(
      builder: (context, state) => _build(context, l10n, tokens, state),
    );
  }

  Widget _build(
    BuildContext context,
    GameCollectionLocalizations l10n,
    BgeTokens tokens,
    GameCollectionListState state,
  ) {
    final bloc = context.read<GameCollectionListBloc>();
    final filter = bloc.filter;
    final inUse = gameFiltersInUseCount(
      filter,
      options: collectionFilterOptions,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BgeSearchField(
          key: ValueKey(_clears),
          label: l10n.collectionSearchLabel,
          clearLabel: l10n.collectionSearchClear,
          initial: _seed,
          fieldKey: GameCollectionListScreen.searchKey,
          onChanged: (text) => _setFilter(bloc.filter.copyWith(query: text)),
        ),
        const BgeGap.sm(),
        // The layout toggle at the end edge where the row has room, and on
        // a line of its own where it doesn't, as at 320dp.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: tokens.spaceSm,
              runSpacing: tokens.spaceSm,
              children: [
                GameFiltersButton(
                  count: inUse,
                  focusNode: _filtersFocus,
                  onPressed: () => unawaited(_openFilters(context)),
                ),
                _SortMenu(
                  sort: bloc.sort,
                  onChanged: (sort) =>
                      _send(bloc, GameCollectionListSortChanged(sort)),
                  controller: _sortMenu,
                  focusNode: _sortFocus,
                ),
              ],
            ),
            // Never disabled: while the choice is read it shows the list,
            // which is what a missing choice means.
            BgeLayoutToggle(
              key: GameCollectionListScreen.layoutToggleKey,
              thumbnails: widget.thumbnails,
              onChanged: widget.onLayoutChanged,
              listLabel: l10n.collectionLayoutList,
              thumbnailsLabel: l10n.collectionLayoutThumbnails,
            ),
          ],
        ),
        // Always in the tree, drawing nothing without a chip, so that it is
        // there to hand focus on after its last chip goes. Spaced from above
        // only while it shows chips.
        Padding(
          padding: EdgeInsets.only(top: inUse > 0 ? tokens.spaceSm : 0),
          child: GameFiltersInUse(
            filter: filter,
            options: collectionFilterOptions,
            onChanged: _setFilter,
            onEmptied: _filtersFocus.requestFocus,
          ),
        ),
        // A live region on the text that changed, so applying a filter is
        // heard (STYLE_GUIDE, "Error and outcome surfaces"). From the list's
        // own state, whose shown and whole lists it counts. Not over an empty
        // collection, which its own state explains.
        if (state
            case GameCollectionListReady(
              :final filter,
              :final items,
              :final all,
            )
            when filter.narrows && all.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: tokens.spaceSm),
            child: Semantics(
              liveRegion: true,
              child: Text(
                l10n.collectionResultCount(_games(items), _games(all)),
                key: GameCollectionListScreen.resultCountKey,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
      ],
    );
  }
}

/// How many games [items] holds: a game owned more than once is one stack,
/// so it counts once.
int _games(List<GameCollectionListItem> items) =>
    items.map((item) => item.gameId).toSet().length;

/// The sort button and the menu of orders it opens (#715).
///
/// A `MenuAnchor`, never a `DropdownMenu`, whose single-line field clips at
/// 320dp and twice the text. The button's label names the order chosen, and
/// wraps rather than clips. The menu's panel is held to the screen's width,
/// so a long item wraps rather than being cut at the panel's edge.
class _SortMenu extends StatelessWidget {
  const _SortMenu({
    required this.sort,
    required this.onChanged,
    required this.controller,
    required this.focusNode,
  });

  /// The order chosen.
  final CollectionSort sort;

  /// Called with the order picked.
  final ValueChanged<CollectionSort> onChanged;
  final MenuController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    return MenuAnchor(
      controller: controller,
      childFocusNode: focusNode,
      crossAxisUnconstrained: false,
      menuChildren: [
        for (final order in CollectionSort.values)
          // Merged, so the item's own node carries its selected state.
          MergeSemantics(
            child: Semantics(
              selected: order == sort,
              child: MenuItemButton(
                key: GameCollectionListScreen.sortKey(order),
                overflowAxis: Axis.vertical,
                // The others keep the check's room, so the labels line up.
                leadingIcon: order == sort
                    ? const Icon(Icons.check)
                    : const Visibility(
                        visible: false,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: Icon(Icons.check),
                      ),
                onPressed: () => onChanged(order),
                child: Text(collectionSortName(l10n, order)),
              ),
            ),
          ),
      ],
      // Wrapped as Flutter's own SubmenuButton is, so assistive tech hears
      // whether the menu is open.
      builder: (context, controller, _) => MergeSemantics(
        child: Semantics(
          expanded: controller.isOpen,
          child: OutlinedButton.icon(
            key: GameCollectionListScreen.sortButtonKey,
            focusNode: focusNode,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.sort),
            label: Text(
              l10n.collectionSortButton(collectionSortName(l10n, sort)),
            ),
          ),
        ),
      ),
    );
  }
}

/// [sort]'s name, in the sort menu and on its button (#715).
String collectionSortName(
  GameCollectionLocalizations l10n,
  CollectionSort sort,
) => switch (sort) {
  CollectionSort.title => l10n.collectionSortTitle,
  CollectionSort.recentlyAdded => l10n.collectionSortRecentlyAdded,
  CollectionSort.playTime => l10n.collectionSortPlayTime,
  CollectionSort.minPlayers => l10n.collectionSortMinPlayers,
  CollectionSort.maxPlayers => l10n.collectionSortMaxPlayers,
  CollectionSort.rating => l10n.collectionSortRating,
};
