import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:game_collection/src/home/stats_cubit.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The home page's "Your stats" card (#614): how many games are in the user's
/// collection, and how many their households share. See [StatsCubit] for what
/// each number is, and when it is read.
///
/// ## The household line
///
/// It is one of three things, and none of them is a guess. The count, where it
/// can be vouched for. A link to the households screen, for someone who is in
/// no household. Or nothing, where the count may be stale or false: offline,
/// after a failed read, or before the household list is known. The collection
/// line stays whichever it is, and draws nothing itself until its number is
/// known.
///
/// Each line keeps its element as the others come and go, so a user focused on
/// the link is not moved by a count arriving above it.
///
/// ## What a screen reader walks
///
/// The heading is a header, and each count and the link is a node of its own,
/// in the order drawn. The [Card] doesn't make them one node: it is not a
/// semantics container.
///
/// ## With nothing to say
///
/// With neither line, the card draws nothing, heading included, because a
/// heading with nothing under it says nothing. It comes up when a line does. The
/// cubit is the same throughout, so it goes on reading, including when the page
/// is uncovered.
///
/// ## The link
///
/// A [TextButton], which stays enabled and focusable throughout. Its target is
/// at least [BgeTokens.minTapTarget] tall at any text scale, and its label wraps
/// within the card, as the counts do. Nothing here is clipped or cut short: at
/// 200% text on a narrow window the lines get taller.
///
/// Its label lines up with the lines above it at rest. Its tint, on hover and
/// keyboard focus, reaches [BgeTokens.spaceSm] past the label on each side, with
/// small corners, so that it holds the label whole. All of it is inside the
/// card's column, so a press or a hover anywhere on it reaches the button.
///
/// The cubit lives as long as the card and is created with it, and reads the
/// count again when the page is uncovered, as the other readers of the server
/// do.
class StatsCard extends StatelessWidget {
  const StatsCard({
    required this.collection,
    required this.onOpenHouseholds,
    this.collectionHydration,
    this.households,
    this.householdHydration,
    this.pool,
    this.connectivity,
    super.key,
  });

  /// Key on the heading's text.
  static const Key headingKey = Key('collection_stats.heading');

  /// Key on the collection's count.
  static const Key ownedKey = Key('collection_stats.owned');

  /// Key on the households' count.
  static const Key householdsKey = Key('collection_stats.households');

  /// Key on the link to the households screen.
  static const Key promptKey = Key('collection_stats.prompt');

  /// The user's own games, saved on this device.
  final GameCollectionRepository collection;

  /// Opens the households screen, from the link shown to someone in none.
  final void Function(BuildContext context) onOpenHouseholds;

  /// What the collection's hydrate is doing, when this composition runs one.
  /// Null reads as settled rather than as loading forever.
  final Stream<Hydration>? collectionHydration;

  /// Makes the stream of the user's cached households. Read once, when the card
  /// is created. Null, or a null stream, shows no household line.
  final Stream<List<Household>>? Function()? households;

  /// What the households' hydrate is doing, when this composition runs one.
  /// Null reads as settled rather than as loading forever, which lets the link
  /// show as soon as the cache says the user is in no household.
  final Stream<Hydration>? householdHydration;

  /// Reads the count of the games the user's households share. Null shows no
  /// count.
  final HouseholdRemoteDataSource? pool;

  /// Says when the server is worth asking again. Null reads as connected.
  final ConnectivityService? connectivity;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<StatsCubit>(
      // Not lazy, so that the first read doesn't wait on a first reader.
      lazy: false,
      create: (_) => StatsCubit(
        collection: collection,
        collectionHydration: collectionHydration,
        households: households?.call(),
        householdHydration: householdHydration,
        pool: pool,
        connectivity: connectivity,
      ),
      child: _Card(onOpenHouseholds: onOpenHouseholds),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.onOpenHouseholds});

  final void Function(BuildContext context) onOpenHouseholds;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final tokens = BgeTokens.of(context);
    final side = EdgeInsets.symmetric(horizontal: tokens.spaceMd);

    return ReadAgainWhenUncovered(
      onUncovered: context.read<StatsCubit>().reload,
      child: BlocBuilder<StatsCubit, StatsState>(
        builder: (context, state) {
          // A heading with nothing under it says nothing, so the card waits
          // for a line. The cubit is above this, and keeps reading.
          if (state.collectionGames == null &&
              state.households is HouseholdStatHidden) {
            return const SizedBox.shrink();
          }
          return Card(
            // Not a semantics container, which would read the heading, the
            // counts and all as one header. Each is a node of its own, and
            // only the heading is a header.
            semanticContainer: false,
            // In line with the other sections.
            margin: EdgeInsets.zero,
            child: Padding(
              // Top and bottom only. The sides are on each line, so that the
              // link's tint can reach past its label without leaving the
              // column, where nothing would hear a press or a hover on it.
              padding: EdgeInsets.symmetric(vertical: tokens.spaceMd),
              // Every line below is keyed, or sits at the same place from the
              // end, so that a line coming or going does not remount the
              // others. The keys of the padding round a line are its own.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: side,
                    child: Semantics(
                      header: true,
                      child: Text(
                        l10n.collectionStatsHeading,
                        key: StatsCard.headingKey,
                        style: textTheme.titleLarge,
                      ),
                    ),
                  ),
                  if (state.collectionGames case final games?) ...[
                    const BgeGap.sm(),
                    Padding(
                      key: const ValueKey(StatsCard.ownedKey),
                      padding: side,
                      child: Text(
                        l10n.collectionStatsOwned(games),
                        key: StatsCard.ownedKey,
                        style: textTheme.bodyMedium,
                      ),
                    ),
                  ],
                  ...switch (state.households) {
                    HouseholdStatHidden() => const <Widget>[],
                    HouseholdStatCount(:final games) => [
                      const BgeGap.sm(),
                      Padding(
                        key: const ValueKey(StatsCard.householdsKey),
                        padding: side,
                        child: Text(
                          l10n.collectionStatsHouseholds(games),
                          key: StatsCard.householdsKey,
                          style: textTheme.bodyMedium,
                        ),
                      ),
                    ],
                    HouseholdStatPrompt() => [
                      const BgeGap.xs(),
                      _prompt(context, tokens, l10n),
                    ],
                  },
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The link to the households screen. Its tint is a small-cornered box that
  /// holds the label with room around it, as a pill with no side padding cut
  /// under the first and last letters on hover and focus.
  ///
  /// The label lines up with the lines above it: the button is inset from the
  /// card's edge by what the lines are, less what it pads its label with. The
  /// tint is then wholly inside the column, so that a press or hover anywhere on
  /// it reaches the button.
  Widget _prompt(
    BuildContext context,
    BgeTokens tokens,
    GameCollectionLocalizations l10n,
  ) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.radiusSm),
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spaceMd - tokens.spaceSm,
      ),
      child: TextButton(
        key: StatsCard.promptKey,
        onPressed: () => onOpenHouseholds(context),
        style: TextButton.styleFrom(
          // Taller as the label wraps, never shorter than a finger, whether or
          // not the theme pads its buttons.
          minimumSize: Size.square(tokens.minTapTarget),
          alignment: AlignmentDirectional.centerStart,
          padding: EdgeInsets.all(tokens.spaceSm),
          shape: shape,
          // The theme's focus ring follows the theme's shape, so this button
          // passes its own (#644). Inside the edge, as on every text button.
          backgroundBuilder: BgeButtonFocusRing.builder(
            shape,
            placement: BgeButtonFocusRingPlacement.inside,
          ),
        ),
        child: Text(l10n.collectionStatsCreateOrJoin),
      ),
    );
  }
}
