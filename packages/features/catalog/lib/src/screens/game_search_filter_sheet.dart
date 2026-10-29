import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_search_bloc.dart';
import '../bloc/game_search_event.dart';
import '../bloc/game_search_state.dart';
import '../widgets/catalog_chip_label.dart';
import '../widgets/catalog_facts.dart';
import 'game_search_screen.dart';

/// Opens every control the search can be narrowed by, in a modal bottom
/// sheet (#474).
///
/// The same sheet at every width, scroll-controlled and inside the safe
/// area; Material 3 caps its width at 640dp, so a wide window doesn't
/// stretch it. It reads the screen's [GameSearchBloc] live and applies each
/// change as it is made, with no Apply button, so the results behind it are
/// already narrowed when it closes.
Future<void> showGameSearchFilterSheet(BuildContext context) {
  // The sheet's route sits above the screen's provider, so it is handed on.
  final bloc = context.read<GameSearchBloc>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => BlocProvider<GameSearchBloc>.value(
      value: bloc,
      child: const _GameSearchFilterSheet(),
    ),
  );
}

class _GameSearchFilterSheet extends StatelessWidget {
  const _GameSearchFilterSheet();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<GameSearchBloc, GameSearchState>(
        buildWhen: (previous, current) => previous.filter != current.filter,
        builder: (context, state) => _sheet(context, state.filter),
      );

  Widget _sheet(BuildContext context, GameSearchFilter filter) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    void apply(GameSearchFilter next) =>
        context.read<GameSearchBloc>().add(GameSearchFilterChanged(next));

    return ListView(
      key: GameSearchScreen.filterSheetKey,
      // As tall as its controls, scrolling once they outgrow the screen.
      shrinkWrap: true,
      padding: EdgeInsets.only(
        left: tokens.spaceMd,
        right: tokens.spaceMd,
        bottom: tokens.spaceLg,
      ),
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
                  : () => apply(const GameSearchFilter()),
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
                onSelected: (on) => apply(
                  filter.copyWith(
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
                onSelected: (on) => apply(
                  filter.copyWith(
                    platformTypes: _toggled(filter.platformTypes, type, on),
                  ),
                ),
              ),
          ],
        ),
        // The publish-year, player-count and play-time ranges follow the
        // type axes (#565, #580).
      ],
    );
  }

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
