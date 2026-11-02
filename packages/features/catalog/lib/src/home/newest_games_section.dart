import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import 'game_cover_tile.dart';
import 'newest_games_cubit.dart';

/// The home page's "Recently added" row (#615): the games most recently added
/// to the server, newest first, in a row that moves side to side.
///
/// ## The header stays put
///
/// The heading and "See all" are the same widgets whether the row is loading,
/// has failed or is showing games, so the link keeps focus as the row under it
/// changes. A refused user is shown nothing, header included. Nor is anything
/// drawn yet for a server with no games: the home page decides what to say
/// there.
///
/// ## A failed read
///
/// With no games saved on the device to show instead, a short message in a
/// live region and a retry. The retry stays enabled and ignores a press while
/// a read runs, because a button that goes disabled drops the focus it holds
/// (#607). It stays the same widget across the read for the same reason, and
/// its label says "Trying again…" meanwhile, so that a press has a result:
/// see [NewestGamesCubit.retry].
///
/// The cubit lives as long as the section, is created when it is, and reads
/// when the section is uncovered, as the other readers of the server do.
class NewestGamesSection extends StatelessWidget {
  const NewestGamesSection({
    required this.remote,
    required this.onSeeAll,
    this.cache,
    this.connectivity,
    this.gone,
    this.onOpen,
    super.key,
  });

  /// Key on the heading's text.
  static const Key headingKey = Key('catalog.newest_heading');

  /// Key on the link to the full list.
  static const Key linkKey = Key('catalog.newest_link');

  /// Key on the spinner.
  static const Key loadingKey = Key('catalog.newest_loading');

  /// Key on the text saying the games could not be loaded.
  static const Key failedKey = Key('catalog.newest_failed');

  /// Key on the failed message's retry button.
  static const Key retryKey = Key('catalog.newest_retry');

  /// Per-game key: `catalog.newest_cover_<gameId>`.
  static Key coverKey(String gameId) => Key('catalog.newest_cover_$gameId');

  /// Reads the games. Nothing is written back to the cache.
  final GamesRemoteDataSource remote;

  /// Opens the full list of games, newest first.
  final void Function(BuildContext context) onSeeAll;

  /// The games saved on this device, shown where the server can't be asked.
  /// Null shows none.
  final GameRepository? cache;

  /// Says when the server is worth asking again. Null reads as connected.
  final ConnectivityService? connectivity;

  /// Ids of games found gone, wherever they were found. A game named here
  /// comes down, and stays down.
  final Stream<String>? gone;

  /// Opens one game, or null where there is nowhere to open it.
  final void Function(BuildContext context, String gameId)? onOpen;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<NewestGamesCubit>(
      // Not lazy, so that the first read doesn't wait on a first reader.
      lazy: false,
      create: (_) => NewestGamesCubit(
        remote: remote,
        cache: cache,
        connectivity: connectivity,
        gone: gone,
      )..load(),
      child: _Section(onSeeAll: onSeeAll, onOpen: onOpen),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.onSeeAll, required this.onOpen});

  final void Function(BuildContext context) onSeeAll;
  final void Function(BuildContext context, String gameId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NewestGamesCubit>();
    final onOpen = this.onOpen;

    return ReadAgainWhenUncovered(
      onUncovered: cubit.load,
      child: BlocBuilder<NewestGamesCubit, NewestGamesState>(
        builder: (context, state) => switch (state) {
          NewestGamesDenied() || NewestGamesEmpty() => const SizedBox.shrink(),
          NewestGamesLoading() => _shelf(
            context,
            placeholder: const _Loading(),
          ),
          NewestGamesFailed(:final retrying) => _shelf(
            context,
            placeholder: _Failed(retrying: retrying, onRetry: cubit.retry),
          ),
          NewestGamesReady(:final games) => _shelf(
            context,
            children: [
              for (final game in games)
                GameCoverTile(
                  key: NewestGamesSection.coverKey(game.id),
                  title: game.title,
                  thumbnailUrl: game.thumbnail,
                  onTap: onOpen == null ? null : () => onOpen(context, game.id),
                ),
            ],
          ),
        },
      ),
    );
  }

  /// The same [BgeShelf] in every state that draws one, so that its header
  /// keeps its elements, and any focus, as what is under it changes.
  Widget _shelf(
    BuildContext context, {
    List<Widget> children = const [],
    Widget? placeholder,
  }) {
    final l10n = GameCatalogLocalizations.of(context);
    return BgeShelf(
      heading: l10n.catalogNewestHeading,
      headingKey: NewestGamesSection.headingKey,
      previousLabel: l10n.catalogShelfPrevious,
      nextLabel: l10n.catalogShelfNext,
      actions: [
        TextButton(
          key: NewestGamesSection.linkKey,
          onPressed: () => onSeeAll(context),
          child: Text(
            l10n.catalogNewestSeeAll,
            // "See all" alone doesn't say of what.
            semanticsLabel: l10n.catalogNewestSeeAllSpoken,
          ),
        ),
      ],
      placeholder: placeholder,
      children: children,
    );
  }
}

/// The spinner, announced as loading when it appears.
class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Padding(
    key: NewestGamesSection.loadingKey,
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceLg),
    child: Center(
      child: Semantics(
        liveRegion: true,
        label: GameCatalogLocalizations.of(context).catalogBrowseLoading,
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}

/// The message and its retry, side by side where both fit. A [Wrap] so that the
/// retry drops below the message rather than overflowing, as at 200% text on a
/// narrow window.
///
/// The retry is the same button throughout, and enabled, so that it keeps focus
/// (#607). While [retrying] its label says so, in a live region, and the
/// cubit ignores a press.
///
/// The message is a live region, because it takes the place of the spinner,
/// which said it was loading. It is announced when the row first fails and
/// again when a retry fails, but not when a retry starts, when it is already
/// there. That is a node keyed on [retrying] and live only when [retrying] is
/// false, so a fresh live node appears on the way back and none on the way in.
class _Failed extends StatelessWidget {
  const _Failed({required this.retrying, required this.onRetry});

  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: BgeTokens.of(context).spaceSm,
      children: [
        KeyedSubtree(
          key: ValueKey(retrying),
          child: Semantics(
            container: true,
            liveRegion: !retrying,
            child: Text(
              l10n.catalogNewestFailed,
              key: NewestGamesSection.failedKey,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
        TextButton(
          key: NewestGamesSection.retryKey,
          onPressed: onRetry,
          // Inside the button, so that the live flag lands on the button's own
          // node, which carries the label that changes. Around it, the flag
          // lands on an empty node above, which has nothing to announce.
          child: Semantics(
            liveRegion: retrying,
            child: Text(retrying ? l10n.catalogRetrying : l10n.catalogRetry),
          ),
        ),
      ],
    );
  }
}
