import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_detail_bloc.dart';
import 'package:game_catalog/src/bloc/game_detail_event.dart';
import 'package:game_catalog/src/bloc/game_detail_state.dart';
import 'package:game_catalog/src/quick_look/game_quick_look_seed.dart';
import 'package:game_catalog/src/quick_look/quick_look_layout.dart';
import 'package:game_catalog/src/screens/game_detail_collection.dart';
import 'package:game_catalog/src/screens/game_detail_screen.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:game_catalog/src/widgets/platform_ownership.dart';
import 'package:game_filters/game_filters.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';

/// Opens [seed]'s [GameQuickLook] over the page (#707), through
/// [showBgePopup]: a sheet on a phone and a dialog on a wider window, on the
/// root navigator. The pop-up is named by the game's title.
///
/// **View full details opens from the pop-up's own context, not [context].**
/// The widget that opened the quick look can go while it is open: a read the
/// server refuses takes the cover it was opened from down from the home
/// shelves, and "Something to play" can draw new games under it. A push from
/// a context that has gone asserts. The pop-up's context is there for as
/// long as its button can be pressed, and is under the same router, so
/// [onViewDetails] pushes the detail page from it just as it would from
/// [context].
///
/// It doesn't close the quick look either. The page it opens removes it
/// once the page has arrived ([BgeRemoveWhenCovered]), so back from that
/// page lands where the quick look was opened, with no quick look. Under the
/// app's navigation shell the page arrives beneath the quick look, which
/// goes once it has (see `showBgePopup`).
///
/// So it opens the page once, however often it is pressed while the page
/// arrives (#978): later presses do nothing
/// ([BgeRemoveWhenCovered.openPage]). A page popped before it has arrived
/// leaves the quick look in place, and View full details opens the page
/// again.
///
/// Null [onViewDetails] offers no View full details. [sections], [actions]
/// and [watchOwned] are [GameQuickLook]'s.
Future<void> showGameQuickLook(
  BuildContext context, {
  required GameQuickLookSeed seed,
  required GamesRemoteDataSource remote,
  GameRepository? cache,
  void Function(String gameId)? onGone,
  void Function(BuildContext context, String gameId)? onViewDetails,
  List<Widget> sections = const [],
  List<Widget> actions = const [],
  WatchOwnedEntries? watchOwned,
}) {
  return showBgePopup<void>(
    context,
    semanticLabel: seed.title,
    builder: (popup) {
      // The guard is the route's, not the builder's, so a rebuild of the
      // pop-up doesn't reset it. And the route knows when the page has gone
      // back without arriving, which leaves the quick look as it was.
      final guard = switch (ModalRoute.of(popup)) {
        final BgeRemoveWhenCovered<dynamic> route => route,
        _ => null,
      };
      return GameQuickLook(
        seed: seed,
        remote: remote,
        cache: cache,
        onGone: onGone,
        onViewDetails: onViewDetails == null
            ? null
            : () {
                void view() => onViewDetails(popup, seed.id);
                if (guard == null) {
                  view();
                } else {
                  guard.openPage(view);
                }
              },
        sections: sections,
        actions: actions,
        watchOwned: watchOwned,
      );
    },
  );
}

/// A game's important facts in a pop-up, without leaving the page (#707):
/// its cover, title and publish year, its players, play time and age, the
/// platforms it is on, and its whole description, with **View full
/// details** to open its page.
///
/// ## The seed shows at once
///
/// [seed] is what the caller already holds, and it is drawn on the first
/// frame. The rest comes from a [GameDetailBloc] read, which also tells
/// [onGone] of a game found gone. Until the read lands, the facts and the
/// description are the seed's [GameQuickLookSeed.game], if it has one.
/// Only the read knows the platforms.
///
/// ## A read that doesn't land
///
/// It never becomes an empty pop-up. A read that fails keeps what the seed
/// had, and one answered from this device's cache shows the cached copy,
/// unless the seed is a full row: a cached copy is never newer than that,
/// and only its platforms are shown. Either way a banner says some details
/// couldn't be loaded, with a retry. The retry keeps everything in place while
/// it runs, itself included, so it keeps focus (#607). It says it is trying for
/// at least [retryDwell], however soon its answer comes. A game the server
/// refuses keeps the seed and says it isn't available.
///
/// ## The header follows the read
///
/// The title and subtitle are the read's once it lands, as the facts are, so
/// a stale title in the seed is put right. The cover stays the seed's, which
/// would only flash if swapped for the same picture, unless the seed had
/// none.
///
/// ## The platforms the user owns
///
/// Given [watchOwned], the platform chips say which of them the user owns
/// the game on (#799), as the detail page's do: an owned chip is the page's,
/// filled with a check, and every chip's spoken name says whether it is
/// owned. It follows the collection while the quick look is open. Until the
/// watch first answers, after it fails, and without it, the chips are plain
/// and say nothing of ownership.
///
/// ## No add to the collection
///
/// Nothing here adds the game to the collection, platform chips included,
/// which have no action. Adding is the detail page's, behind View full
/// details.
///
/// ## Callers add to it
///
/// [sections] sit below the description and [actions] beside View full
/// details, so a caller with more to offer about a game, such as an import
/// from search (#713), doesn't fork this.
///
/// A game the server answers as unavailable draws the banner and none of
/// them (#1040): what a caller adds is about a game that's there.
///
/// ## Opened through [showGameQuickLook]
///
/// Host it through [showGameQuickLook], as #713's search results will, not
/// in a layout of your own. It brings its own scroll view, and its header's
/// `LayoutBuilder` throws under intrinsic sizing, so it needs the bounded
/// box the pop-up gives it.
class GameQuickLook extends StatelessWidget {
  const GameQuickLook({
    required this.seed,
    required this.remote,
    this.cache,
    this.onGone,
    this.onViewDetails,
    this.sections = const [],
    this.actions = const [],
    this.openLink = GameDetailScreen.openLinkExternally,
    this.watchOwned,
    super.key,
  });

  static const Key viewDetailsKey = QuickLookLayout.viewDetailsKey;
  static const Key factsKey = QuickLookLayout.factsKey;
  static const Key platformsKey = QuickLookLayout.platformsKey;

  /// The banner over a read that didn't land, with its retry.
  static const Key partialKey = Key('catalog.quick_look.partial');

  /// The banner over a game the server refuses.
  static const Key unavailableKey = Key('catalog.quick_look.unavailable');

  /// How long a retry says it is trying before its answer replaces that,
  /// however soon the answer comes, as `NewestGamesCubit.retryDwell` holds a
  /// shelf's.
  ///
  /// An answer the app already has, such as a read that fails at once
  /// offline and falls back to the cache, would otherwise land in the same
  /// frame as the retry: the banner would build once, with the answer, and
  /// the press would seem to do nothing. An answer that takes longer isn't
  /// held any further.
  static const Duration retryDwell = Duration(milliseconds: 300);

  /// What the caller already holds, shown at once.
  final GameQuickLookSeed seed;
  final GamesRemoteDataSource remote;

  /// The user-session games cache, or null where there is none.
  final GameRepository? cache;

  /// Told the game's id when it turns out to be gone. Null tells no one.
  final void Function(String gameId)? onGone;

  /// Opens the game's detail page. Null offers no View full details: where
  /// there is nowhere to open it, there never will be while this is open.
  final VoidCallback? onViewDetails;

  /// The caller's own sections, below the description.
  final List<Widget> sections;

  /// The caller's own actions, before View full details.
  final List<Widget> actions;

  /// Opens a description link outside the app.
  final Future<void> Function(Uri uri) openLink;

  /// What the user owns of the game's platforms (#799). Null, as where the
  /// session can't write the collection, says nothing of ownership.
  final WatchOwnedEntries? watchOwned;

  @override
  Widget build(BuildContext context) => BlocProvider<GameDetailBloc>(
    key: ValueKey<String>(seed.id),
    create: (_) => GameDetailBloc(
      gameId: seed.id,
      remote: remote,
      cache: cache,
      onGone: onGone,
    )..add(const GameDetailLoadRequested()),
    child: _QuickLookBody(
      seed: seed,
      onViewDetails: onViewDetails,
      sections: sections,
      actions: actions,
      openLink: openLink,
      watchOwned: watchOwned,
    ),
  );
}

class _QuickLookBody extends StatefulWidget {
  const _QuickLookBody({
    required this.seed,
    required this.onViewDetails,
    required this.sections,
    required this.actions,
    required this.openLink,
    required this.watchOwned,
  });

  final GameQuickLookSeed seed;
  final VoidCallback? onViewDetails;
  final List<Widget> sections;
  final List<Widget> actions;
  final Future<void> Function(Uri uri) openLink;
  final WatchOwnedEntries? watchOwned;

  @override
  State<_QuickLookBody> createState() => _QuickLookBodyState();
}

class _QuickLookBodyState extends State<_QuickLookBody> {
  static final BgeLogger _log = BgeLogger('bge.catalog.quick_look.ownership');

  /// The read's last answer shown. A retry reads again from
  /// [GameDetailLoading], and this keeps what was shown on screen meanwhile.
  GameDetailState? _answer;

  /// Whether a retry is showing that it is trying.
  bool _retrying = false;

  /// Runs while a retry has yet to be up for [GameQuickLook.retryDwell].
  Timer? _dwell;

  /// An answer that came while [_dwell] ran, shown when it ends.
  GameDetailState? _held;

  /// The platform games [_owned] watches: those of the answer shown.
  Set<String> _watchedIds = const {};

  StreamSubscription<List<GameCollection>>? _owned;

  /// The user's entries on [_watchedIds], or null until the watch answers,
  /// and once it fails.
  List<GameCollection>? _entries;

  @override
  void didUpdateWidget(_QuickLookBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The pop-up hands over the same watch on each rebuild. One given or
    // taken away changes what is known.
    if ((oldWidget.watchOwned == null) != (widget.watchOwned == null)) {
      _watch(_watchedIds, force: true);
    }
  }

  @override
  void dispose() {
    _dwell?.cancel();
    // The route stays mounted through its exit, and the watch can answer
    // then; once it goes, nothing more is heard.
    unawaited(_owned?.cancel());
    super.dispose();
  }

  /// The platform games [answer] shows: none until the read gives them.
  static List<PlatformGame> _platformGamesOf(GameDetailState? answer) =>
      answer is GameDetailReady ? answer.platformGames : const [];

  /// Watches what the user owns of [ids], unless it already does: a new
  /// answer with the same platforms is not watched again. A new platform
  /// is, as the last answer says nothing of it. Called where a build
  /// follows: inside a setState, or from [didUpdateWidget].
  void _watch(Set<String> ids, {bool force = false}) {
    if (!force && setEquals(ids, _watchedIds)) return;
    unawaited(_owned?.cancel());
    _owned = null;
    _entries = null;
    _watchedIds = ids;
    final watchOwned = widget.watchOwned;
    if (watchOwned == null || ids.isEmpty) return;
    _owned = watchOwned(ids).listen(
      (entries) {
        if (mounted) setState(() => _entries = entries);
      },
      onError: (Object error, StackTrace stackTrace) {
        _log.warn(
          'Watching what the user owns of a game failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (mounted) setState(() => _entries = null);
      },
    );
  }

  /// Each state the read goes through, one at a time. A builder would see
  /// only the last of those that land in one frame.
  void _onState(BuildContext context, GameDetailState state) {
    if (state is GameDetailLoading) {
      // The first read: the seed is showing.
      if (_answer == null) return;
      _held = null;
      _dwell ??= Timer(GameQuickLook.retryDwell, _dwelt);
      if (!_retrying) setState(() => _retrying = true);
      return;
    }
    if (_dwell != null) {
      _held = state;
      return;
    }
    _show(state);
  }

  void _dwelt() {
    _dwell = null;
    final held = _held;
    _held = null;
    if (held != null && mounted) _show(held);
  }

  void _show(GameDetailState answer) => setState(() {
    _answer = answer;
    _retrying = false;
    _watch({
      for (final platformGame in _platformGamesOf(answer)) platformGame.id,
    });
  });

  @override
  Widget build(BuildContext context) =>
      BlocListener<GameDetailBloc, GameDetailState>(
        listener: _onState,
        child: _content(context, answer: _answer, retrying: _retrying),
      );

  /// What the quick look shows given the read's last [answer], null before
  /// the first. [retrying] while a retry reads again.
  Widget _content(
    BuildContext context, {
    required GameDetailState? answer,
    required bool retrying,
  }) {
    final l10n = GameCatalogLocalizations.of(context);
    final seed = widget.seed;
    final ready = answer is GameDetailReady ? answer : null;
    // Offline, the newer of a full seed and the cached copy. Either can be
    // ahead: newest games reads the server and leaves the cache as it was,
    // and a quick look's read caches a newer row than the list it was
    // opened from still holds. A tie keeps the seed, the row tapped.
    final game = switch (ready) {
      GameDetailReady(fromCache: true, game: final cached) =>
        switch (seed.game) {
          final seeded? when !seeded.updatedAt.isBefore(cached.updatedAt) =>
            seeded,
          _ => cached,
        },
      _ => ready?.game ?? seed.game,
    };
    final platformGames = _platformGamesOf(answer);
    final entries = _entries;
    final ownership = entries == null
        ? null
        : PlatformOwnership.of(platformGames: platformGames, entries: entries);
    // What a caller adds is about a game that's there (#1040). A game the
    // server won't show draws the banner and none of the caller's additions,
    // whichever caller they came from. Every slot a caller can fill is
    // gated here, so a new one joins this line.
    final additions = answer is! GameDetailUnavailable;
    final banner = switch (answer) {
      GameDetailFailed() ||
      GameDetailReady(fromCache: true) => CatalogFromCacheBanner(
        key: GameQuickLook.partialKey,
        message: l10n.catalogQuickLookPartial,
        retrying: retrying,
        onRetry: () =>
            context.read<GameDetailBloc>().add(const GameDetailLoadRequested()),
      ),
      GameDetailUnavailable() => BgeInlineBanner(
        key: GameQuickLook.unavailableKey,
        tone: BgeBannerTone.warning,
        title: l10n.catalogDetailUnavailableTitle,
        message: l10n.catalogDetailUnavailableBody,
      ),
      _ => null,
    };

    // The title and subtitle are the read's once it lands, the seed's until
    // then; the cover stays the seed's, unless the seed had none.
    return QuickLookLayout(
      title: game?.title ?? seed.title,
      subtitle: game == null ? seed.subtitle : game.subtitle,
      year: game?.publishYear,
      coverUrl: seed.thumbnail ?? seed.image ?? game?.thumbnail ?? game?.image,
      facts: game == null
          ? const <GameFact>[]
          : playFacts(l10n, GameFiltersLocalizations.of(context), game),
      platforms: [
        for (final platformGame in platformGames)
          QuickLookPlatform(
            key: ValueKey(platformGame.id),
            name: platformGame.platformName,
            owned: ownership?.owns(platformGame.id),
          ),
      ],
      banner: banner,
      description: game?.description,
      sections: additions ? widget.sections : const [],
      actions: additions ? widget.actions : const [],
      onViewDetails: widget.onViewDetails,
      openLink: widget.openLink,
    );
  }
}
