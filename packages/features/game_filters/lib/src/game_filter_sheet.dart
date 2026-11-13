import 'package:flutter/material.dart';
import 'package:game_filters/l10n/game_filters_localizations.dart';
import 'package:game_filters/src/collection_filter_flips.dart';
import 'package:game_filters/src/game_facts.dart';
import 'package:game_filters/src/game_filter_chip_label.dart';
import 'package:game_filters/src/game_filter_keys.dart';
import 'package:game_filters/src/game_filter_options.dart';
import 'package:game_filters/src/game_length_band.dart';
import 'package:game_filters/src/search_range_field.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens every control a list of games can be narrowed by, in a modal bottom
/// sheet (#474).
///
/// The same sheet at every width, scroll-controlled and inside the safe
/// area; Material 3 caps its width at 640dp, so a wide window doesn't
/// stretch it. [options] says which sections it offers: always the content
/// types and platform types it names and the three ranges; with
/// [GameFilterOptions.medium], a Medium section after Platform; with
/// [GameFilterOptions.missingBaseGame], a switch, last, keeping only the
/// expansions shown without their base game (#715).
///
/// With [GameFilterOptions.exclusion], each section ends in a switch that
/// flips it to leave out what it matches, putting its facet in
/// [CollectionFilter.excluded]. The switch can be turned only while its
/// section narrows ([CollectionFilter.facetsInUse]), and says why until
/// then. A flip goes with its section's last choice, so a choice made later
/// never starts out flipped. A flipped range leaves out the games with no
/// value that its switch would keep, so that switch says so while the flip
/// is on.
///
/// It opens on [initial] and applies each change as it is made, with no
/// Apply button: [onChanged] gets the whole filter after every edit, so the
/// list behind it is already narrowed when it closes. The sheet keeps its
/// own copy and reads nothing else while it is open; nothing else changes
/// the filter then, since the caller's controls sit under its barrier.
/// [CollectionFilter.query] is the caller's own, carried through as given.
///
/// One change is sent later than it is made: a range field that still holds
/// bounds as the sheet closes commits them as it is disposed, when nothing
/// may be marked to build, so [onChanged] gets that filter once the frame
/// ends. A caller may then rebuild from [onChanged] whenever it is called,
/// and checks only that it is still there to.
///
/// A range that closes with the sheet on bounds it can't send is dropped,
/// and the sheet says why once the frame ends, as an outcome whose surface
/// pops takes (docs/design/STYLE_GUIDE.md): the field can't show it any
/// more. [onDropped] is told, or, without one, a SnackBar on the opener's
/// [ScaffoldMessenger] says it. An opener gone by then is told nothing.
Future<void> showGameFilterSheet(
  BuildContext context, {
  required CollectionFilter initial,
  required ValueChanged<CollectionFilter> onChanged,
  GameFilterOptions options = const GameFilterOptions(),
  ValueChanged<String>? onDropped,
}) {
  final tell = onDropped ?? _snackBarOn(ScaffoldMessenger.of(context));
  // Told as the field is disposed, when nothing may be rebuilt, so it waits
  // for the frame's end.
  void dropped(String message) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        tell(message);
      });
  return showModalBottomSheet<void>(
    context: context,
    // Over the navigation shell's bar or rail too, not only the page (#414).
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _GameFilterSheet(
      initial: initial,
      onChanged: onChanged,
      options: options,
      onDropped: dropped,
    ),
  );
}

ValueChanged<String> _snackBarOn(ScaffoldMessengerState messenger) =>
    (message) => messenger.showSnackBar(SnackBar(content: Text(message)));

class _GameFilterSheet extends StatefulWidget {
  const _GameFilterSheet({
    required this.initial,
    required this.onChanged,
    required this.options,
    required this.onDropped,
  });

  final CollectionFilter initial;
  final ValueChanged<CollectionFilter> onChanged;
  final GameFilterOptions options;

  /// Says why a range closing with the sheet couldn't be sent.
  final ValueChanged<String> onDropped;

  @override
  State<_GameFilterSheet> createState() => _GameFilterSheetState();
}

class _GameFilterSheetState extends State<_GameFilterSheet> {
  /// How many times Clear all has been pressed. Each press makes the range
  /// fields drop what was typed and not sent, which would otherwise come
  /// back as a filter when the sheet closes.
  int _clears = 0;

  /// The filter as this sheet last sent it.
  ///
  /// Each control changes this, not the filter as it stood at the last
  /// build: two controls acting in one turn, such as a field that commits
  /// as it loses focus and the chip whose tap took it, would otherwise undo
  /// each other. A field closing with the sheet commits too, after the sheet
  /// has left the screen.
  late CollectionFilter _filter;

  /// Whether the sheet has been taken out of the tree, as it is in the
  /// frame that disposes it.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _filter = widget.initial;
  }

  @override
  void activate() {
    super.activate();
    _leaving = false;
  }

  @override
  void deactivate() {
    _leaving = true;
    super.deactivate();
  }

  /// Applies [change] to the filter and sends the result, with any flip
  /// left with nothing chosen dropped (#715).
  ///
  /// A field closing with the sheet commits from its `dispose`, while the
  /// tree is locked and a caller's `setState` would throw. That filter is
  /// sent once the frame ends, in the order the fields committed.
  void _edit(CollectionFilter Function(CollectionFilter filter) change) {
    final changed = withoutIdleFlips(change(_filter));
    if (_leaving) {
      _filter = changed;
      final onChanged = widget.onChanged;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChanged(changed));
      return;
    }
    setState(() => _filter = changed);
    widget.onChanged(changed);
  }

  /// [_edit] for the facets the game search shares.
  void _editGame(GameSearchFilter Function(GameSearchFilter game) change) =>
      _edit((filter) => filter.copyWith(game: change(filter.game)));

  /// [filter] with every choice this sheet offers under its options cleared,
  /// and with them the flips of the facets left with nothing chosen (#715).
  ///
  /// The caller's query stays, and so does what the options leave out, such
  /// as a medium where the sheet has no Medium section, with its flip.
  CollectionFilter _cleared(CollectionFilter filter) {
    final options = widget.options;
    final game = filter.game;
    return withoutIdleFlips(
      filter.copyWith(
        game: GameSearchFilter(
          contentTypes: game.contentTypes.difference(
            options.contentTypes.toSet(),
          ),
          platformTypes: game.platformTypes.difference(
            options.platformTypes.toSet(),
          ),
        ),
        mediums: options.medium ? const {} : filter.mediums,
        missingBaseGame: !options.missingBaseGame && filter.missingBaseGame,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = GameFiltersLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final options = widget.options;
    final game = _filter.game;

    // One section per facet, in the order the sheet offers them; a gap
    // separates each from the next.
    final sections = <Widget>[
      _ChipSection(
        heading: l10n.gameFiltersFilterContentType,
        chips: [
          for (final type in options.contentTypes)
            FilterChip(
              key: GameFilterKeys.contentType(type),
              label: GameFilterChipLabel(contentTypeLabel(l10n, type)!),
              selected: game.contentTypes.contains(type),
              onSelected: (on) => _editGame(
                (game) => game.copyWith(
                  contentTypes: _toggled(game.contentTypes, type, on),
                ),
              ),
            ),
        ],
        exclude: _exclude(
          CollectionFacet.contentType,
          l10n.gameFiltersFilterContentType,
        ),
      ),
      _ChipSection(
        heading: l10n.gameFiltersFilterPlatformType,
        chips: [
          for (final type in options.platformTypes)
            FilterChip(
              key: GameFilterKeys.platformType(type),
              label: GameFilterChipLabel(platformTypeLabel(l10n, type)!),
              selected: game.platformTypes.contains(type),
              onSelected: (on) => _editGame(
                (game) => game.copyWith(
                  platformTypes: _toggled(game.platformTypes, type, on),
                ),
              ),
            ),
        ],
        exclude: _exclude(
          CollectionFacet.platformType,
          l10n.gameFiltersFilterPlatformType,
        ),
      ),
      if (options.medium)
        _ChipSection(
          heading: l10n.gameFiltersMedium,
          chips: [
            for (final medium in GameMedium.values)
              FilterChip(
                key: GameFilterKeys.medium(medium),
                label: GameFilterChipLabel(mediumLabel(l10n, medium)),
                selected: _filter.mediums.contains(medium),
                onSelected: (on) => _edit(
                  (filter) => filter.copyWith(
                    mediums: _toggled(filter.mediums, medium, on),
                  ),
                ),
              ),
          ],
          exclude: _exclude(CollectionFacet.medium, l10n.gameFiltersMedium),
        ),
      _range(
        CollectionFacet.publishYear,
        heading: l10n.gameFiltersFilterYear,
        lowest: GameFilterOptions.minRangeBound,
        allowNegative: true,
        helper: l10n.gameFiltersYearHelper,
        notApplied: l10n.gameFiltersYearNotApplied,
        includeUnknown: l10n.gameFiltersIncludeUnknownYear,
        leaveOutUnknown: l10n.gameFiltersLeaveOutUnknownYear,
      ),
      _range(
        CollectionFacet.playerCount,
        heading: l10n.gameFiltersFilterPlayers,
        lowest: GameFilterOptions.minPlayerCount,
        helper: l10n.gameFiltersPlayersHelper,
        notApplied: l10n.gameFiltersPlayersNotApplied,
        includeUnknown: l10n.gameFiltersIncludeUnknownPlayers,
        leaveOutUnknown: l10n.gameFiltersLeaveOutUnknownPlayers,
      ),
      _range(
        CollectionFacet.playTime,
        heading: l10n.gameFiltersFilterPlayTime,
        lowest: GameFilterOptions.minPlayTime,
        helper: l10n.gameFiltersPlayTimeHelper,
        notApplied: l10n.gameFiltersPlayTimeNotApplied,
        includeUnknown: l10n.gameFiltersIncludeUnknownPlayTime,
        leaveOutUnknown: l10n.gameFiltersLeaveOutUnknownPlayTime,
        bands: _bands(l10n, tokens, game.playTime),
      ),
      if (options.missingBaseGame)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: GameFilterKeys.missingBaseGame,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.gameFiltersMissingBaseGame),
              value: _filter.missingBaseGame,
              onChanged: (on) =>
                  _edit((filter) => filter.copyWith(missingBaseGame: on)),
            ),
            ?_exclude(
              CollectionFacet.missingBaseGame,
              l10n.gameFiltersMissingBaseGameInUse,
            ),
          ],
        ),
    ];

    // As tall as its controls, scrolling once they outgrow the screen, and
    // above the keyboard, which the sheet itself doesn't make room for, so
    // the field being typed in stays in view. Not a lazy list: every control
    // stays built while the sheet is open, so what a field holds, and why it
    // can't be sent, outlive scrolling it out of view.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        key: GameFilterKeys.sheet,
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
                      l10n.gameFiltersTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                TextButton(
                  key: GameFilterKeys.clearAll,
                  onPressed: _filter == _cleared(_filter)
                      ? null
                      : () {
                          setState(() => _clears++);
                          _edit(_cleared);
                        },
                  child: Text(l10n.gameFiltersClearAll),
                ),
              ],
            ),
            const BgeGap.md(),
            for (final (index, section) in sections.indexed) ...[
              if (index > 0) const BgeGap.lg(),
              section,
            ],
          ],
        ),
      ),
    );
  }

  /// The switch ending [facet]'s section that leaves out what the section
  /// matches instead (#715), or null where the options don't offer it.
  ///
  /// It can be turned only while the section narrows, and until then it
  /// stays, disabled, and says why. A screen reader hears it named for its
  /// section by [name], since every section's reads the same on screen.
  Widget? _exclude(CollectionFacet facet, String name) {
    if (!widget.options.exclusion) return null;
    final l10n = GameFiltersLocalizations.of(context);
    final narrows = _filter.facetsInUse.contains(facet);
    return SwitchListTile(
      key: GameFilterKeys.exclude(facet),
      contentPadding: EdgeInsets.zero,
      title: Text(
        l10n.gameFiltersExclude,
        semanticsLabel: l10n.gameFiltersExcludeNamed(name),
      ),
      subtitle: narrows ? null : Text(l10n.gameFiltersExcludeNothingChosen),
      value: _filter.excluded.contains(facet),
      onChanged: narrows
          ? (on) => _edit(
              (filter) => filter.copyWith(
                excluded: _toggled(filter.excluded, facet, on),
              ),
            )
          : null,
    );
  }

  /// The section for [range], one of the three ranges: the From and To
  /// fields, the switch that keeps games with no value, any [bands], and the
  /// switch that flips it where the options offer one.
  ///
  /// The no-value switch is titled [includeUnknown], or [leaveOutUnknown]
  /// while the range is flipped: a flip leaves out everything the range
  /// keeps, games with no value included (`filterCollection`), so there the
  /// switch leaves them out (#715). Its key, its value and its place stay.
  Widget _range(
    CollectionFacet range, {
    required String heading,
    required int lowest,
    required String helper,
    required String Function(String problem) notApplied,
    required String includeUnknown,
    required String leaveOutUnknown,
    bool allowNegative = false,
    Widget? bands,
  }) {
    final value = _rangeOf(_filter.game, range);
    final flipped = _filter.excluded.contains(range);
    return _RangeSection(
      heading: heading,
      bands: bands,
      field: SearchRangeField(
        fromKey: GameFilterKeys.rangeField(range, from: true),
        toKey: GameFilterKeys.rangeField(range, from: false),
        name: heading,
        generation: _clears,
        value: value,
        lowest: lowest,
        highest: widget.options.maxRangeBound,
        allowNegative: allowNegative,
        helper: helper,
        onDropped: (problem) => widget.onDropped(notApplied(problem)),
        onCommit: (typed) => _editGame((game) {
          // A field owns its bounds, and the switch beside it owns whether
          // unknown values are kept.
          final current = _rangeOf(game, range);
          return _withRange(
            game,
            range,
            current.copyWith(min: typed.min, max: typed.max),
          );
        }),
      ),
      includeUnknown: SwitchListTile(
        key: GameFilterKeys.includeUnknown(range),
        contentPadding: EdgeInsets.zero,
        title: Text(flipped ? leaveOutUnknown : includeUnknown),
        value: value.includeUnknown,
        onChanged: (on) => _editGame(
          (game) => _withRange(
            game,
            range,
            _rangeOf(game, range).copyWith(includeUnknown: on),
          ),
        ),
      ),
      exclude: _exclude(range, heading),
    );
  }

  /// The play time's bands, one chosen at a time; the chosen one, tapped
  /// again, clears the play time. Either way the switch stays.
  Widget _bands(
    GameFiltersLocalizations l10n,
    BgeTokens tokens,
    GameSearchRange playTime,
  ) {
    final selected = GameLengthBand.matching(playTime);
    return Wrap(
      spacing: tokens.spaceSm,
      runSpacing: tokens.spaceSm,
      children: [
        for (final band in GameLengthBand.values)
          _bandChip(
            l10n,
            band,
            selected: band == selected,
            onSelected: (on) => _editGame(
              (game) => game.copyWith(
                playTime: (on ? band.range : const GameSearchRange()).copyWith(
                  includeUnknown: game.playTime.includeUnknown,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// A band's choice, labelled with its name and the play times it covers,
  /// read by the one duration formatter (#579): "Medium (1–2 hr)".
  static Widget _bandChip(
    GameFiltersLocalizations l10n,
    GameLengthBand band, {
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    final name = bandName(l10n, band);
    final range = playTimeRangeFact(l10n, band.minMinutes, band.maxMinutes)!;
    return ChoiceChip(
      key: GameFilterKeys.band(band),
      label: GameFilterChipLabel(
        l10n.gameFiltersBandLabel(name, range.shown),
        semanticsLabel: l10n.gameFiltersBandLabel(name, range.spoken),
      ),
      selected: selected,
      onSelected: onSelected,
    );
  }

  /// [game]'s value for [range], one of the three ranges.
  static GameSearchRange _rangeOf(
    GameSearchFilter game,
    CollectionFacet range,
  ) => switch (range) {
    CollectionFacet.publishYear => game.publishYear,
    CollectionFacet.playerCount => game.playerCount,
    CollectionFacet.playTime => game.playTime,
    CollectionFacet.contentType ||
    CollectionFacet.platformType ||
    CollectionFacet.medium ||
    CollectionFacet.missingBaseGame => throw ArgumentError.value(
      range,
      'range',
      'is not a range',
    ),
  };

  /// [game] with [range], one of the three ranges, set to [value].
  static GameSearchFilter _withRange(
    GameSearchFilter game,
    CollectionFacet range,
    GameSearchRange value,
  ) => switch (range) {
    CollectionFacet.publishYear => game.copyWith(publishYear: value),
    CollectionFacet.playerCount => game.copyWith(playerCount: value),
    CollectionFacet.playTime => game.copyWith(playTime: value),
    CollectionFacet.contentType ||
    CollectionFacet.platformType ||
    CollectionFacet.medium ||
    CollectionFacet.missingBaseGame => throw ArgumentError.value(
      range,
      'range',
      'is not a range',
    ),
  };

  static Set<T> _toggled<T>(Set<T> set, T value, bool on) =>
      on ? {...set, value} : ({...set}..remove(value));
}

/// One axis's choices under its heading: any number chosen, and none
/// chosen does not narrow. Any [exclude] switch comes last.
class _ChipSection extends StatelessWidget {
  const _ChipSection({
    required this.heading,
    required this.chips,
    this.exclude,
  });

  final String heading;
  final List<Widget> chips;
  final Widget? exclude;

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
        ?exclude,
      ],
    );
  }
}

/// One range under its heading: the bands, where it has them, then the From
/// and To fields, the switch that keeps games with no value, and any
/// [exclude] switch.
class _RangeSection extends StatelessWidget {
  const _RangeSection({
    required this.heading,
    required this.field,
    required this.includeUnknown,
    this.bands,
    this.exclude,
  });

  final String heading;
  final Widget field;
  final Widget includeUnknown;
  final Widget? bands;
  final Widget? exclude;

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
        ?exclude,
      ],
    );
  }
}
