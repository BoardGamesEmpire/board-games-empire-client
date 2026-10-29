import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_search_bloc.dart';
import '../bloc/game_search_event.dart';
import '../bloc/game_search_state.dart';
import '../search/game_length_band.dart';
import '../widgets/catalog_chip_label.dart';
import '../widgets/catalog_facts.dart';
import 'game_search_screen.dart';
import 'search_range_field.dart';

/// Opens every control the search can be narrowed by, in a modal bottom
/// sheet (#474).
///
/// The same sheet at every width, scroll-controlled and inside the safe
/// area; Material 3 caps its width at 640dp, so a wide window doesn't
/// stretch it. It reads the screen's [GameSearchBloc] live and applies each
/// change as it is made, with no Apply button, so the results behind it are
/// already narrowed when it closes.
///
/// A range that closes with the sheet on bounds it can't send is dropped,
/// and the screen says why in a SnackBar, as an outcome whose surface pops
/// takes (docs/design/STYLE_GUIDE.md): the field can't show it any more.
Future<void> showGameSearchFilterSheet(BuildContext context) {
  // The sheet's route sits above the screen's provider, so it is handed on.
  final bloc = context.read<GameSearchBloc>();
  final messenger = ScaffoldMessenger.of(context);
  // Told as the field is disposed, when nothing may be rebuilt, so it waits
  // for the frame's end. A screen gone by then has nothing to say it on.
  void dropped(String message) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        messenger.showSnackBar(SnackBar(content: Text(message)));
      });
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => BlocProvider<GameSearchBloc>.value(
      value: bloc,
      child: _GameSearchFilterSheet(onDropped: dropped),
    ),
  );
}

class _GameSearchFilterSheet extends StatefulWidget {
  const _GameSearchFilterSheet({required this.onDropped});

  /// Says why a range closing with the sheet couldn't be sent.
  final ValueChanged<String> onDropped;

  @override
  State<_GameSearchFilterSheet> createState() => _GameSearchFilterSheetState();
}

class _GameSearchFilterSheetState extends State<_GameSearchFilterSheet> {
  /// How many times Clear all has been pressed. Each press makes the range
  /// fields drop what was typed and not sent, which would otherwise come
  /// back as a filter when the sheet closes.
  int _clears = 0;

  /// The filter this sheet last sent, which the bloc may not have taken yet.
  GameSearchFilter? _sent;

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<GameSearchBloc, GameSearchState>(
        buildWhen: (previous, current) => previous.filter != current.filter,
        builder: (context, state) => _sheet(context, state.filter),
      );

  Widget _sheet(BuildContext context, GameSearchFilter filter) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final bloc = context.read<GameSearchBloc>();

    // Each control changes the filter as this sheet last sent it, not as it
    // stood at this build, nor as the bloc shows it: the bloc takes a change
    // only after the turn it was sent in, so two controls acting in one turn,
    // such as a field that commits as it loses focus and the chip whose tap
    // took it, would otherwise undo each other. Nothing else changes the
    // filter while the sheet is open; the screen's chips sit under its
    // barrier. A field closing with the sheet commits too, so the bloc is
    // held here rather than looked up then.
    void edit(GameSearchFilter Function(GameSearchFilter filter) change) {
      if (bloc.isClosed) return;
      final changed = change(_sent ?? bloc.state.filter);
      _sent = changed;
      bloc.add(GameSearchFilterChanged(changed));
    }

    final dropped = widget.onDropped;

    final selectedBand = GameLengthBand.matching(filter.playTime);

    // As tall as its controls, scrolling once they outgrow the screen, and
    // above the keyboard, which the sheet itself doesn't make room for, so
    // the field being typed in stays in view. Not a lazy list: every control
    // stays built while the sheet is open, so what a field holds, and why it
    // can't be sent, outlive scrolling it out of view.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        key: GameSearchScreen.filterSheetKey,
        padding: EdgeInsets.only(
          left: tokens.spaceMd,
          right: tokens.spaceMd,
          bottom: tokens.spaceLg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.catalogSearchFiltersTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                TextButton(
                  key: GameSearchScreen.clearAllKey,
                  onPressed: filter == const GameSearchFilter()
                      ? null
                      : () {
                          setState(() => _clears++);
                          edit((_) => const GameSearchFilter());
                        },
                  child: Text(l10n.catalogSearchFiltersClearAll),
                ),
              ],
            ),
            const BgeGap.md(),
            _ChipSection(
              heading: l10n.catalogSearchFilterContentType,
              chips: [
                for (final type in GameSearchScreen.filterTypes)
                  FilterChip(
                    key: GameSearchScreen.filterKey(type),
                    label: CatalogChipLabel(contentTypeLabel(l10n, type)!),
                    selected: filter.contentTypes.contains(type),
                    onSelected: (on) => edit(
                      (filter) => filter.copyWith(
                        contentTypes: _toggled(filter.contentTypes, type, on),
                      ),
                    ),
                  ),
              ],
            ),
            const BgeGap.lg(),
            _ChipSection(
              heading: l10n.catalogSearchFilterPlatformType,
              chips: [
                for (final type in GameSearchScreen.platformFilterTypes)
                  FilterChip(
                    key: GameSearchScreen.platformFilterKey(type),
                    label: CatalogChipLabel(platformTypeLabel(l10n, type)!),
                    selected: filter.platformTypes.contains(type),
                    onSelected: (on) => edit(
                      (filter) => filter.copyWith(
                        platformTypes: _toggled(filter.platformTypes, type, on),
                      ),
                    ),
                  ),
              ],
            ),
            const BgeGap.lg(),
            _RangeSection(
              heading: l10n.catalogSearchFilterYear,
              field: SearchRangeField(
                fromKey: GameSearchScreen.rangeFieldKey('year', 'from'),
                toKey: GameSearchScreen.rangeFieldKey('year', 'to'),
                generation: _clears,
                value: filter.publishYear,
                lowest: GamesRemoteDataSource.minRangeBound,
                allowNegative: true,
                helper: l10n.catalogSearchYearHelper,
                onDropped: (problem) =>
                    dropped(l10n.catalogSearchYearNotApplied(problem)),
                onCommit: (range) => edit(
                  (filter) => filter.copyWith(
                    publishYear: _bounded(filter.publishYear, range),
                  ),
                ),
              ),
              includeUnknown: SwitchListTile(
                key: GameSearchScreen.includeUnknownKey('year'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.catalogSearchIncludeUnknownYear),
                value: filter.publishYear.includeUnknown,
                onChanged: (on) => edit(
                  (filter) => filter.copyWith(
                    publishYear: filter.publishYear.copyWith(
                      includeUnknown: on,
                    ),
                  ),
                ),
              ),
            ),
            const BgeGap.lg(),
            _RangeSection(
              heading: l10n.catalogSearchFilterPlayers,
              field: SearchRangeField(
                fromKey: GameSearchScreen.rangeFieldKey('players', 'from'),
                toKey: GameSearchScreen.rangeFieldKey('players', 'to'),
                generation: _clears,
                value: filter.playerCount,
                lowest: GamesRemoteDataSource.minPlayerCount,
                helper: l10n.catalogSearchPlayersHelper,
                onDropped: (problem) =>
                    dropped(l10n.catalogSearchPlayersNotApplied(problem)),
                onCommit: (range) => edit(
                  (filter) => filter.copyWith(
                    playerCount: _bounded(filter.playerCount, range),
                  ),
                ),
              ),
              includeUnknown: SwitchListTile(
                key: GameSearchScreen.includeUnknownKey('players'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.catalogSearchIncludeUnknownPlayers),
                value: filter.playerCount.includeUnknown,
                onChanged: (on) => edit(
                  (filter) => filter.copyWith(
                    playerCount: filter.playerCount.copyWith(
                      includeUnknown: on,
                    ),
                  ),
                ),
              ),
            ),
            const BgeGap.lg(),
            _RangeSection(
              heading: l10n.catalogSearchFilterPlayTime,
              bands: Wrap(
                spacing: tokens.spaceSm,
                runSpacing: tokens.spaceSm,
                children: [
                  for (final band in GameLengthBand.values)
                    _bandChip(
                      l10n,
                      band,
                      selected: band == selectedBand,
                      // One band at a time; the chosen one, tapped again,
                      // clears the play time. Either way the switch stays.
                      onSelected: (on) => edit(
                        (filter) => filter.copyWith(
                          playTime: (on ? band.range : const GameSearchRange())
                              .copyWith(
                                includeUnknown: filter.playTime.includeUnknown,
                              ),
                        ),
                      ),
                    ),
                ],
              ),
              field: SearchRangeField(
                fromKey: GameSearchScreen.rangeFieldKey('time', 'from'),
                toKey: GameSearchScreen.rangeFieldKey('time', 'to'),
                generation: _clears,
                value: filter.playTime,
                lowest: GamesRemoteDataSource.minPlayTime,
                helper: l10n.catalogSearchPlayTimeHelper,
                onDropped: (problem) =>
                    dropped(l10n.catalogSearchPlayTimeNotApplied(problem)),
                onCommit: (range) => edit(
                  (filter) => filter.copyWith(
                    playTime: _bounded(filter.playTime, range),
                  ),
                ),
              ),
              includeUnknown: SwitchListTile(
                key: GameSearchScreen.includeUnknownKey('time'),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.catalogSearchIncludeUnknownPlayTime),
                value: filter.playTime.includeUnknown,
                onChanged: (on) => edit(
                  (filter) => filter.copyWith(
                    playTime: filter.playTime.copyWith(includeUnknown: on),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A band's choice, labelled with its name and the play times it covers,
  /// read by the one duration formatter (#579): "Medium (1–2 hr)".
  static Widget _bandChip(
    GameCatalogLocalizations l10n,
    GameLengthBand band, {
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    final name = bandName(l10n, band);
    final range = playTimeRangeFact(l10n, band.minMinutes, band.maxMinutes)!;
    return ChoiceChip(
      key: GameSearchScreen.bandKey(band),
      label: CatalogChipLabel(
        l10n.catalogBandLabel(name, range.shown),
        semanticsLabel: l10n.catalogBandLabel(name, range.spoken),
      ),
      selected: selected,
      onSelected: onSelected,
    );
  }

  /// [current] with the bounds [typed] carries: a field owns its bounds,
  /// and the switch beside it owns whether unknown values are kept.
  static GameSearchRange _bounded(
    GameSearchRange current,
    GameSearchRange typed,
  ) => current.copyWith(min: typed.min, max: typed.max);

  static Set<T> _toggled<T>(Set<T> set, T value, bool on) =>
      on ? {...set, value} : ({...set}..remove(value));
}

/// One axis's choices under its heading: any number chosen, and none
/// chosen does not narrow.
class _ChipSection extends StatelessWidget {
  const _ChipSection({required this.heading, required this.chips});

  final String heading;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(heading, style: Theme.of(context).textTheme.labelLarge),
        ),
        const BgeGap.sm(),
        Wrap(
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          children: chips,
        ),
      ],
    );
  }
}

/// One range under its heading: the bands, where it has them, then the From
/// and To fields and the switch that keeps games with no value.
class _RangeSection extends StatelessWidget {
  const _RangeSection({
    required this.heading,
    required this.field,
    required this.includeUnknown,
    this.bands,
  });

  final String heading;
  final Widget field;
  final Widget includeUnknown;
  final Widget? bands;

  @override
  Widget build(BuildContext context) {
    final bands = this.bands;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(heading, style: Theme.of(context).textTheme.labelLarge),
        ),
        const BgeGap.sm(),
        if (bands != null) ...[bands, const BgeGap.md()],
        field,
        includeUnknown,
      ],
    );
  }
}
