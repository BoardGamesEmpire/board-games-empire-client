import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/home/shelf_loading.dart';
import 'package:game_catalog/src/home/something_to_play_cubit.dart';
import 'package:game_catalog/src/quick_look/game_quick_look_seed.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

/// The home page's "Something to play" row (#616): a random pick of games from
/// the households the user is in and their own collection, or the server's when
/// those have none. See [SomethingToPlayCubit] for what is drawn and when.
///
/// ## A cover opens a quick look
///
/// A cover is the game's picture alone, and a tap on it opens the game's quick
/// look over home rather than its page (#707): the facts come to the user, who
/// stays where they were. The row holds summaries, with a title and pictures
/// and no more, so [onOpen] gets a seed of those, and the quick look reads the
/// rest. Where the quick look opens, and what opens from it, is the host's:
/// the section does no routing.
///
/// ## Reshuffle
///
/// Draws again. It stays enabled and stays the same widget while the draw runs,
/// because a button that goes disabled drops the focus it holds (#607), and a
/// second press starts a newer draw. The old rows stay up until the answer
/// lands, when the row returns to its start and a screen reader hears that
/// there are new games: see [_ReshuffleAction].
///
/// A draw that finds nothing because it couldn't ask, as offline, leaves the
/// rows and the button as they were.
///
/// With nothing to show the section draws nothing, heading included. A
/// reshuffle comes to that only when the server says it has no games and the
/// user has none of their own. That takes the button down with it, and its
/// focus falls back to the route, whose first control is the next Tab's stop.
///
/// The cubit lives as long as the section and is created when it is. When the
/// section is uncovered it draws again only if there is nothing up, as the
/// server may have been filled meanwhile, or the first draw may have failed with
/// nothing else to try it again. With rows up it doesn't, so that the pick stays
/// as the user left it. With none up, nothing can change under them: see
/// [SomethingToPlayCubit.drawIfNothing].
class SomethingToPlaySection extends StatelessWidget {
  const SomethingToPlaySection({
    required this.remote,
    this.pool,
    this.collection,
    this.households,
    this.connectivity,
    this.gone,
    this.onOpen,
    super.key,
  });

  /// Key on the heading's text.
  static const Key headingKey = Key('catalog.something_to_play_heading');

  /// Key on the reshuffle button.
  static const Key reshuffleKey = Key('catalog.something_to_play_reshuffle');

  /// Key on the spinner.
  static const Key loadingKey = Key('catalog.something_to_play_loading');

  /// Per-game key: `catalog.something_to_play_cover_<gameId>`.
  static Key coverKey(String gameId) =>
      Key('catalog.something_to_play_cover_$gameId');

  /// Reads the server's random games.
  final GamesRemoteDataSource remote;

  /// Reads a sample of the games the user's households share. Null asks for
  /// none, and isn't counted as a read that was missed.
  final HouseholdRemoteDataSource? pool;

  /// The user's own games, saved on this device. Null is none.
  final GameCollectionRepository? collection;

  /// Gives the stream of the user's households, whose filling up after a draw
  /// of the server's random games is worth a new draw. Read once, when the
  /// section is created. Null, or a null stream, never triggers one.
  final Stream<List<Household>>? Function()? households;

  /// Says when the server is worth asking again. Null reads as connected.
  final ConnectivityService? connectivity;

  /// Ids of games found gone, wherever they were found. A game named here
  /// comes down, and stays down.
  final Stream<String>? gone;

  /// Opens one game's quick look from its cover, given what the row holds of
  /// it (#707), or null where there is nowhere to open it.
  final void Function(BuildContext context, GameQuickLookSeed seed)? onOpen;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<SomethingToPlayCubit>(
      // Not lazy, so that the first draw doesn't wait on a first reader.
      lazy: false,
      create: (_) => SomethingToPlayCubit(
        remote: remote,
        pool: pool,
        collection: collection,
        households: households?.call(),
        connectivity: connectivity,
        gone: gone,
      ),
      child: _Section(onOpen: onOpen),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.onOpen});

  final void Function(BuildContext context, GameQuickLookSeed seed)? onOpen;

  @override
  Widget build(BuildContext context) {
    final onOpen = this.onOpen;
    return ReadAgainWhenUncovered(
      onUncovered: context.read<SomethingToPlayCubit>().drawIfNothing,
      child: BlocBuilder<SomethingToPlayCubit, SomethingToPlayState>(
        builder: (context, state) => switch (state) {
          SomethingToPlayNothing() => const SizedBox.shrink(),
          SomethingToPlayLoading() => _shelf(
            context,
            placeholder: const ShelfLoading(
              key: SomethingToPlaySection.loadingKey,
              // "Recently added" is offered with this section, and announces it.
              live: false,
            ),
          ),
          SomethingToPlayReady(:final games, :final draw) => _shelf(
            context,
            actions: [
              _ReshuffleAction(
                draw: draw,
                onPressed: context.read<SomethingToPlayCubit>().reshuffle,
              ),
            ],
            resetToken: draw,
            children: [
              for (final game in games)
                BgeCoverTile(
                  key: SomethingToPlaySection.coverKey(game.id),
                  label: game.title,
                  imageUrl: game.thumbnail,
                  onTap: onOpen == null
                      ? null
                      : () => onOpen(
                          context,
                          GameQuickLookSeed.fromSummary(game),
                        ),
                ),
            ],
          ),
        },
      ),
    );
  }

  Widget _shelf(
    BuildContext context, {
    List<Widget> actions = const [],
    List<Widget> children = const [],
    Widget? placeholder,
    Object? resetToken,
  }) {
    final l10n = GameCatalogLocalizations.of(context);
    return BgeShelf(
      heading: l10n.catalogSomethingToPlayHeading,
      headingKey: SomethingToPlaySection.headingKey,
      previousLabel: l10n.catalogShelfPrevious,
      nextLabel: l10n.catalogShelfNext,
      actions: actions,
      placeholder: placeholder,
      resetToken: resetToken,
      children: children,
    );
  }
}

/// The reshuffle button, and the live region that says a new draw has landed.
///
/// A live region speaks when its node appears, so each draw after the first
/// gets a node of its own, keyed on [draw], and the first draw gets none. It
/// isn't an announcement call because Android has deprecated those.
///
/// The node is [_announcementExtent] square, because a node with no size is
/// dropped from the semantics tree. It is positioned, so it takes no room from
/// the header and moves nothing, and it paints nothing and has no focus node,
/// so it is no one's stop on the way past with the keyboard. The button comes
/// first in the stack, and keeps its element, and so its focus, as the node
/// changes.
class _ReshuffleAction extends StatelessWidget {
  const _ReshuffleAction({required this.draw, required this.onPressed});

  static const double _announcementExtent = 1;

  final int draw;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    return Stack(
      children: [
        TextButton(
          key: SomethingToPlaySection.reshuffleKey,
          onPressed: onPressed,
          child: Text(l10n.catalogReshuffle),
        ),
        if (draw > 1)
          PositionedDirectional(
            key: ValueKey(draw),
            start: 0,
            top: 0,
            child: Semantics(
              container: true,
              liveRegion: true,
              label: l10n.catalogReshuffled,
              child: const SizedBox.square(dimension: _announcementExtent),
            ),
          ),
      ],
    );
  }
}
