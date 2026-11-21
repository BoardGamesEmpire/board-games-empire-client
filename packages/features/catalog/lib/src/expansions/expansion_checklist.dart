import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_cubit.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_state.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A game's expansions as a checklist, one group per DataGateway (#713,
/// #712). Reads the [ExpansionChecklistCubit] above it; its owner calls
/// `load`, and this widget's retry calls it again.
///
/// Not a scrollable: a column of tiles, for the scroll view that hosts it,
/// which spaces it from what precedes it, as a quick look spaces its
/// sections. A user the server refuses (403) sees nothing here.
class ExpansionChecklist extends StatelessWidget {
  const ExpansionChecklist({this.sourceNames = const {}, super.key});

  /// DataGateway names by id, for a group's heading and a note naming a
  /// source that did not answer. An id with no name is shown as it is.
  final Map<String, String> sourceNames;

  static Key selectAllKey(String gatewayId) =>
      ValueKey('expansion-select-all-$gatewayId');

  static Key rowKey(String gatewayId, String externalId) =>
      ValueKey('expansion-row-$gatewayId-$externalId');

  static const Key retryKey = ValueKey('expansion-retry');

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ExpansionChecklistCubit>();
    return BlocBuilder<ExpansionChecklistCubit, ExpansionChecklistState>(
      builder: (context, state) {
        if (state is ExpansionChecklistRefused) return const SizedBox.shrink();
        final l10n = GameCatalogLocalizations.of(context);
        final space = BgeTokens.of(context).spaceMd;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // As the quick look's own sections are headed, with no room
            // above: the host spaces the checklist from what precedes it.
            CatalogSectionHeading(
              l10n.catalogExpansionsHeading,
              spaceAbove: false,
            ),
            Padding(
              padding: EdgeInsets.only(bottom: space),
              child: switch (state) {
                ExpansionChecklistLoading() => Center(
                  child: BgeLoadingState(label: l10n.catalogExpansionsLoading),
                ),
                ExpansionChecklistFailed() => _failed(
                  l10n,
                  cubit,
                  l10n.catalogExpansionsFailedBody,
                ),
                ExpansionChecklistReady() => _ready(
                  context,
                  l10n,
                  cubit,
                  state,
                ),
                ExpansionChecklistRefused() => const SizedBox.shrink(),
              },
            ),
          ],
        );
      },
    );
  }

  /// The failure, with [body] saying why: the read failed, or a source
  /// did not answer.
  Widget _failed(
    GameCatalogLocalizations l10n,
    ExpansionChecklistCubit cubit,
    String body,
  ) => BgeErrorState(
    icon: Icons.cloud_off_outlined,
    title: l10n.catalogExpansionsFailedTitle,
    body: body,
    retryLabel: l10n.catalogRetry,
    retryKey: retryKey,
    onRetry: cubit.load,
  );

  Widget _ready(
    BuildContext context,
    GameCatalogLocalizations l10n,
    ExpansionChecklistCubit cubit,
    ExpansionChecklistReady state,
  ) {
    final results = state.results;
    final groups = [
      for (final entry in results.byDataGateway.entries)
        if (entry.value.isNotEmpty) entry,
    ];
    // Missing sources, once each, in the order the server named them.
    final missing = {
      ...results.failedDataGateways,
      ...results.rateLimitedDataGateways,
      ...results.unavailableDataGateways,
    };

    // Nothing found and some source could not say: that is a failure to
    // read, not an empty answer (#713).
    if (groups.isEmpty && missing.isNotEmpty) {
      return _failed(l10n, cubit, l10n.catalogExpansionsUnansweredBody);
    }
    if (groups.isEmpty) {
      return BgeEmptyState(title: l10n.catalogExpansionsEmpty);
    }

    final tokens = BgeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spaceMd,
      children: [
        for (final MapEntry(key: id, value: hits) in groups)
          _group(
            context,
            l10n,
            cubit,
            state,
            id,
            hits,
            named: groups.length > 1,
          ),
        for (final id in missing)
          Text(
            l10n.catalogExpansionsMissing(sourceNames[id] ?? id),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
      ],
    );
  }

  Widget _group(
    BuildContext context,
    GameCatalogLocalizations l10n,
    ExpansionChecklistCubit cubit,
    ExpansionChecklistReady state,
    String id,
    List<GameSearchHit> hits, {
    required bool named,
  }) {
    final filterL10n = GameFiltersLocalizations.of(context);
    final ticked = state.ticked[id] ?? const <String>{};
    final tickable = hits.where(cubit.isTickable).length;
    final all = tickable > 0 && ticked.length == tickable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A source's name, styled as the section's heading is. Without the
        // heading's room above it: the groups are spaced already.
        if (named)
          Semantics(
            header: true,
            child: Text(
              sourceNames[id] ?? id,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        // Ringed on keyboard focus (#758). Each ring is keyed as its tile is:
        // it keeps the row's focus node, so it must stay with its source and
        // its game as the groups and their games change.
        BgeRowFocusRing(
          key: ValueKey('ring.select-all.$id'),
          builder: (context, row) => CheckboxListTile(
            key: selectAllKey(id),
            focusNode: row.focusNode,
            onFocusChange: row.onFocusChange,
            controlAffinity: ListTileControlAffinity.leading,
            tristate: true,
            value: all ? true : (ticked.isEmpty ? false : null),
            // With nothing to tick it stays, disabled (STYLE_GUIDE §5).
            onChanged: tickable == 0
                ? null
                : (_) => cubit.setAll(id, ticked: !all),
            title: Text(l10n.catalogExpansionsSelectAll),
          ),
        ),
        for (final hit in hits)
          BgeRowFocusRing(
            key: ValueKey('ring.$id.${hit.externalId}'),
            builder: (context, row) => CheckboxListTile(
              key: rowKey(id, hit.externalId),
              focusNode: row.focusNode,
              onFocusChange: row.onFocusChange,
              controlAffinity: ListTileControlAffinity.leading,
              value: ticked.contains(hit.externalId),
              // A game the server holds is informational: it was never
              // available to tick, so nothing is disabled mid-interaction.
              onChanged: cubit.isTickable(hit)
                  ? (_) => cubit.toggle(id, hit.externalId)
                  : null,
              title: Text(hit.title),
              subtitle: _subtitle(l10n, filterL10n, hit),
            ),
          ),
      ],
    );
  }

  Widget? _subtitle(
    GameCatalogLocalizations l10n,
    GameFiltersLocalizations filterL10n,
    GameSearchHit hit,
  ) {
    final facts = [
      ...rowFacts(
        filterL10n,
        year: hit.yearPublished,
        minPlayers: hit.minPlayers,
        maxPlayers: hit.maxPlayers,
        contentType: hit.contentType,
      ),
      if (hit.isOnServer) sameFact(l10n.catalogExpansionOnServer),
    ];
    return facts.isEmpty ? null : CatalogFactsText(facts);
  }
}
