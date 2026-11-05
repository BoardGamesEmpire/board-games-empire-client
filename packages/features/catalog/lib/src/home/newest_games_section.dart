import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../quick_look/game_quick_look_seed.dart';
import 'empty_server_card.dart';
import 'newest_games_cubit.dart';
import 'shelf_loading.dart';

/// The home page's "Recently added" row (#615): the games most recently added
/// to the server, newest first, in a row that moves side to side.
///
/// ## A cover opens a quick look
///
/// A cover is the game's picture alone, and a tap on it opens the game's quick
/// look over home rather than its page (#707): the facts come to the user, who
/// stays where they were. The row holds whole games, so [onOpen] gets a seed
/// carrying the game, and the quick look shows its players, play time and age
/// before its own read lands. Where the quick look opens, and what opens from
/// it, is the host's: the section does no routing.
///
/// ## The header stays put
///
/// The heading and "See all" are the same widgets whether the row is loading,
/// has failed or is showing games, so the link keeps focus as the row under it
/// changes. A refused user is shown nothing, header included.
///
/// ## A server with no games
///
/// When the server answers that it has none (#617), the whole row gives way to
/// a statement of that, with no heading or link left over, as there is nothing
/// to see all of. Someone who can connect a DataGateway gets a card with a
/// button that opens the list of them; everyone else gets a plain message.
/// [onConnectDataGateway] says which: null is the plain message, and so is what
/// stands while it isn't yet known whether the user can.
///
/// Only the server's own answer says it has no games. A first read that fails,
/// and being offline for it, are the failed state however the user's access
/// stands, because "no games here" is a claim about the server, and a false one
/// sends an admin to connect a DataGateway they may already have. Once the
/// server has said it, a read that fails afterwards leaves it standing, so that
/// a blip doesn't swap the card for a failure and back.
///
/// The callback is read when the section builds, and not kept by the cubit, so
/// that it arriving, or going, swaps the one for the other without reading the
/// server again. Whichever of the two has focus as it goes hands it to the
/// other (#456).
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
    this.onConnectDataGateway,
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

  /// Key on the text saying the server has no games, in the card and out of
  /// it.
  static const Key emptyKey = Key('catalog.newest_empty');

  /// Key on the empty card's button.
  static const Key emptyActionKey = Key('catalog.newest_empty_action');

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

  /// Opens one game's quick look from its cover, given what the row holds of
  /// it (#707), or null where there is nowhere to open it.
  final void Function(BuildContext context, GameQuickLookSeed seed)? onOpen;

  /// Opens the list of DataGateways, for a user who can connect one. Null is
  /// the plain message to a server with no games.
  final void Function(BuildContext context)? onConnectDataGateway;

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
      child: _Section(
        onSeeAll: onSeeAll,
        onOpen: onOpen,
        onConnectDataGateway: onConnectDataGateway,
      ),
    );
  }
}

class _Section extends StatefulWidget {
  const _Section({
    required this.onSeeAll,
    required this.onOpen,
    required this.onConnectDataGateway,
  });

  final void Function(BuildContext context) onSeeAll;
  final void Function(BuildContext context, GameQuickLookSeed seed)? onOpen;
  final void Function(BuildContext context)? onConnectDataGateway;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  /// On the empty card's button.
  final FocusNode _connect = FocusNode(debugLabel: 'newest games connect');

  /// On the plain empty message, which takes focus only when sent there.
  final FocusNode _message = FocusNode(debugLabel: 'newest games empty');

  @override
  void didUpdateWidget(_Section oldWidget) {
    super.didUpdateWidget(oldWidget);
    _keepConnectFocus(oldWidget);
  }

  /// Hands focus between the card's button and the message as the callback
  /// comes and goes (#456).
  ///
  /// The callback follows the caller's access to create, which can change
  /// whenever the session asks again. Each of the two takes the other's
  /// place, and left to go with the one that had it, focus would fall to the
  /// page, which shows none, and the next Tab would start again from the top.
  /// So focus on the button goes to the message, which says why there is
  /// nothing to press, and the next Tab goes on from there. Focus on the
  /// message goes to the button, the one control in the card that replaces
  /// it.
  ///
  /// Runs before the frame that swaps them, while the one going still has
  /// focus.
  void _keepConnectFocus(_Section oldWidget) {
    final had = oldWidget.onConnectDataGateway != null;
    final has = widget.onConnectDataGateway != null;
    final FocusNode from;
    final FocusNode to;
    if (had && !has) {
      (from, to) = (_connect, _message);
    } else if (!had && has) {
      (from, to) = (_message, _connect);
    } else {
      return;
    }
    if (!from.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Not built when the section left its empty state in the same frame.
      if (!mounted || !(to.context?.mounted ?? false)) return;
      to.requestFocus();
    });
  }

  @override
  void dispose() {
    _connect.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NewestGamesCubit>();
    final onOpen = widget.onOpen;
    final onConnect = widget.onConnectDataGateway;

    return ReadAgainWhenUncovered(
      onUncovered: cubit.load,
      child: BlocBuilder<NewestGamesCubit, NewestGamesState>(
        builder: (context, state) => switch (state) {
          NewestGamesDenied() => const SizedBox.shrink(),
          NewestGamesEmpty() when onConnect != null => EmptyServerCard(
            onConnect: () => onConnect(context),
            messageKey: NewestGamesSection.emptyKey,
            actionKey: NewestGamesSection.emptyActionKey,
            actionFocusNode: _connect,
          ),
          NewestGamesEmpty() => EmptyServerMessage(
            messageKey: NewestGamesSection.emptyKey,
            focusNode: _message,
          ),
          NewestGamesLoading() => _shelf(
            context,
            placeholder: const ShelfLoading(
              key: NewestGamesSection.loadingKey,
              live: true,
            ),
          ),
          NewestGamesFailed(:final retrying) => _shelf(
            context,
            placeholder: _Failed(retrying: retrying, onRetry: cubit.retry),
          ),
          NewestGamesReady(:final games) => _shelf(
            context,
            children: [
              for (final game in games)
                BgeCoverTile(
                  key: NewestGamesSection.coverKey(game.id),
                  label: game.title,
                  imageUrl: game.thumbnail,
                  onTap: onOpen == null
                      ? null
                      : () => onOpen(context, GameQuickLookSeed.fromGame(game)),
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
          onPressed: () => widget.onSeeAll(context),
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
