import 'dart:async';
import 'dart:math';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What the home page's "Something to play" row holds (#616).
sealed class SomethingToPlayState extends Equatable {
  const SomethingToPlayState();

  @override
  List<Object?> get props => [];
}

/// The first draw is running, or waiting on the collection's first answer.
final class SomethingToPlayLoading extends SomethingToPlayState {
  const SomethingToPlayLoading();
}

/// There is nothing to show, and no rows up to keep showing. The row draws
/// nothing.
final class SomethingToPlayNothing extends SomethingToPlayState {
  const SomethingToPlayNothing();
}

/// The games to show, in the order drawn.
final class SomethingToPlayReady extends SomethingToPlayState {
  const SomethingToPlayReady({required this.games, required this.draw});

  final List<GameSummary> games;

  /// Counts the draws that have reached the screen, from 1. A new value is a
  /// new set of games, and a game coming down keeps it.
  final int draw;

  @override
  List<Object?> get props => [games, draw];
}

/// Draws a random pick of games, for the home page's "Something to play" row
/// (#616).
///
/// ## The draw
///
/// A sample of the pool the caller's households share, merged with the caller's
/// own games from the local cache, one row per game, shuffled, and cut to
/// [shelfSize]. With nothing from either, the server's random games. The
/// sampled rows stop here: nothing is written to any cache.
///
/// A failed pool read leaves the caller's own games, with no error. With
/// nothing to show and the server's random read failed too, the row is
/// [SomethingToPlayNothing], unless it has rows up. A draw that couldn't ask,
/// or was refused or sent something unreadable, says nothing about those, so
/// they stay, unchanged and unannounced, and reconnecting tries again where
/// that could help. A flaky link doesn't take the section away, and an offline
/// press doesn't take away the button it was made on. Only an answer from every
/// source, with no games in it, replaces rows with nothing.
///
/// The first draw waits for the collection's first answer, so that a user with
/// games in the cache doesn't see the server's random ones flash up first. A
/// stream that errors or closes before answering counts as nothing own.
///
/// ## Drawing again
///
/// A draw leaves the state as it is until its answer lands, so the old rows
/// stay up meanwhile, and a newer draw discards an older one, whenever that
/// answers. It runs on entry and on [reshuffle], and:
///
/// - On regaining a connection, if the last draw was incomplete: the pool has a
///   remote and its read was skipped or failed, or the random read was skipped
///   or failed. Having no pool remote at all is not incomplete, as reconnecting
///   wouldn't change what there is to ask. Nor is a failure that asking again
///   would only repeat: a refusal, a request the server rejects, or an answer
///   this client can't read. So too if a read is still out, which may have
///   gone with the connection and not yet said so.
/// - When the collection or the households go from empty to filled, if the last
///   draw had nothing of the caller's to show, as after a first hydrate. Any
///   later change to the collection reaches the next draw, and leaves the rows
///   up alone.
///
/// Uncovering the page draws only if the row is [SomethingToPlayNothing]: see
/// [drawIfNothing]. With rows up it doesn't, so the row isn't swapped under a
/// user who went to look at one of its games and came back. With none up,
/// nothing can change under them, and what emptied the row may have cleared,
/// as a server that was empty and has since been filled, or a first draw that
/// failed while online, which nothing else would try again.
///
/// ## A game found gone
///
/// A game that the server no longer has, or this user may no longer read, is
/// taken down when `gone` says so, with no redraw, and is left out of later
/// draws. Losing the last row is [SomethingToPlayNothing].
class SomethingToPlayCubit extends Cubit<SomethingToPlayState> {
  /// Starts the first draw: at once with no [collection], or when it answers.
  SomethingToPlayCubit({
    required this._remote,
    this._pool,
    GameCollectionRepository? collection,
    Stream<List<Household>>? households,
    this._connectivity,
    Stream<String>? gone,
    Random? random,
    BgeLogger? logger,
  }) : _lastConnectivity = _connectivity?.current,
       _random = random ?? Random(),
       _logger = logger ?? BgeLogger('bge.catalog.something_to_play'),
       super(const SomethingToPlayLoading()) {
    _connectivityUpdates = _connectivity?.watch().listen(
      _onConnectivity,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Connectivity stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    _goneUpdates = gone?.listen(_onGone);
    _householdUpdates = households?.listen(
      _onHouseholds,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Households stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    if (collection == null) {
      _ownAnswered = true;
      _begin();
    } else {
      _ownUpdates = collection.watchCollectionListItems().listen(
        _onOwn,
        onError: _onOwnFailed,
        onDone: _onOwnClosed,
      );
    }
  }

  /// How many games the row asks each source for, and shows.
  static const int shelfSize = 10;

  final GamesRemoteDataSource _remote;
  final HouseholdRemoteDataSource? _pool;
  final ConnectivityService? _connectivity;
  final Random _random;
  final BgeLogger _logger;

  StreamSubscription<ConnectivityState>? _connectivityUpdates;
  StreamSubscription<String>? _goneUpdates;
  StreamSubscription<List<Household>>? _householdUpdates;
  StreamSubscription<List<GameCollectionListItem>>? _ownUpdates;

  /// The state a change is measured from. The service replays its current
  /// state to a new subscriber, which is not a change.
  ConnectivityState? _lastConnectivity;

  /// The households' last answer, or null before their first.
  List<Household>? _lastHouseholds;

  /// The caller's own games, as the collection last said: one per game.
  List<GameSummary> _own = const [];

  /// Whether the collection has answered, or can't. The first draw waits on it.
  bool _ownAnswered = false;

  /// Bumped to discard whatever draw is in flight.
  int _generation = 0;

  /// Whether a draw is running.
  bool _reading = false;

  /// How many draws have reached the screen.
  int _draws = 0;

  /// Whether reconnecting could improve on the last draw. See the class doc.
  bool _incomplete = false;

  /// Whether the draw last to reach the merge had nothing of the caller's to
  /// show, so that their first games or households are worth drawing for. That
  /// is set before any random read, so that a change during one starts over.
  bool _nothingOfTheirs = false;

  /// Games found gone since this row was made, never shown again.
  final Set<String> _gone = {};

  /// Draws again, discarding any draw already out, and leaving the rows up
  /// until the answer lands.
  ///
  /// Before the collection has answered, there is a first draw to come, and
  /// that will be the newest.
  void reshuffle() {
    if (_ownAnswered) _begin();
  }

  /// Draws again if the row is [SomethingToPlayNothing], as on uncovering the
  /// page, and otherwise does nothing: rows that are up are left as they are.
  void drawIfNothing() {
    if (state is SomethingToPlayNothing) reshuffle();
  }

  void _begin() {
    if (isClosed) return;
    final generation = ++_generation;
    _reading = true;
    unawaited(_draw(generation));
  }

  Future<void> _draw(int generation) async {
    final offline = _connectivity?.current == ConnectivityState.offline;
    final pool = await _readPool(offline: offline);
    if (!_wanted(generation)) return;

    // The collection and the found-gone games as they stand now, not as they
    // stood when the read began.
    final merged = _rows([...?pool.sample?.games, ..._own])..shuffle(_random);
    _nothingOfTheirs = merged.isEmpty;
    if (merged.isNotEmpty) {
      return _land(merged, incomplete: pool.incomplete, answered: true);
    }
    if (offline) return _land(const [], incomplete: true, answered: false);

    final random = await _readRandom();
    if (!_wanted(generation)) return;
    _land(
      _rows(random.games ?? const []),
      incomplete: pool.incomplete || random.incomplete,
      answered: (_pool == null || pool.sample != null) && random.games != null,
    );
  }

  /// [games] with one row per game, without those found gone.
  List<GameSummary> _rows(List<GameSummary> games) => [
    ...{
      for (final game in games)
        if (!_gone.contains(game.id)) game.id: game,
    }.values,
  ];

  /// The pool's sample, or null with no pool remote, offline, or a failed
  /// read, and whether reconnecting could bring one.
  Future<({GamePoolSample? sample, bool incomplete})> _readPool({
    required bool offline,
  }) async {
    final pool = _pool;
    if (pool == null) return (sample: null, incomplete: false);
    if (offline) return (sample: null, incomplete: true);
    try {
      // The argument must follow the constant the surrounding arithmetic
      // also uses.
      // ignore: avoid_redundant_argument_values
      final sample = await pool.fetchGamePoolSample(size: shelfSize);
      return (sample: sample, incomplete: false);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Game pool sample read failed',
        error: error,
        stackTrace: stackTrace,
      );
      return (sample: null, incomplete: _askingAgainCouldChange(error));
    }
  }

  /// The server's random games, or null with a failed read, and whether
  /// reconnecting could bring them.
  Future<({List<GameSummary>? games, bool incomplete})> _readRandom() async {
    try {
      // The argument must follow the constant the surrounding arithmetic
      // also uses.
      // ignore: avoid_redundant_argument_values
      final games = await _remote.fetchRandom(size: shelfSize);
      return (games: games, incomplete: false);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Random games read failed',
        error: error,
        stackTrace: stackTrace,
      );
      return (games: null, incomplete: _askingAgainCouldChange(error));
    }
  }

  /// Whether a read that failed with [error] could answer if asked again. A
  /// refusal or a rejected request is the server's answer, and it would give
  /// the same one. Anything it didn't answer, or anything unforeseen, could.
  static bool _askingAgainCouldChange(Object error) => switch (error) {
    GamesRemoteTransientException() ||
    HouseholdRemoteTransientException() => true,
    GamesRemoteException() || HouseholdRemoteException() => false,
    _ => true,
  };

  /// Shows [games] as the draw's answer. [incomplete] is whether reconnecting
  /// could improve on it. [answered] is whether every source asked gave an
  /// answer: a read refused, rejected or unreadable says no more about what
  /// there is to play than one lost in transit, so it takes no rows down,
  /// though asking again would only repeat it.
  void _land(
    List<GameSummary> games, {
    required bool incomplete,
    required bool answered,
  }) {
    _reading = false;
    _incomplete = incomplete;
    if (games.isEmpty && !answered && state is SomethingToPlayReady) return;
    emit(
      games.isEmpty
          ? const SomethingToPlayNothing()
          : SomethingToPlayReady(
              games: games.take(shelfSize).toList(),
              draw: ++_draws,
            ),
    );
  }

  /// Whether the draw begun as [generation] is the latest, on a cubit that is
  /// open. Cubit.emit throws once closed.
  bool _wanted(int generation) => !isClosed && generation == _generation;

  void _onOwn(List<GameCollectionListItem> items) {
    final wasEmpty = _own.isEmpty;
    final seen = <String>{};
    _own = [
      for (final item in items)
        if (seen.add(item.gameId))
          GameSummary(
            id: item.gameId,
            title: item.title,
            subtitle: item.subtitle,
            thumbnail: item.thumbnail,
          ),
    ];
    if (_firstOwnAnswer()) return;
    if (wasEmpty && _own.isNotEmpty) _drawForTheirs();
  }

  void _onOwnFailed(Object error, StackTrace stackTrace) {
    _logger.warn(
      'Collection stream failed',
      error: error,
      stackTrace: stackTrace,
    );
    _firstOwnAnswer();
  }

  /// A repository closes its stream when disposed, rather than failing it.
  void _onOwnClosed() => _firstOwnAnswer();

  /// Starts the first draw, if this is the collection's first answer of any
  /// kind, and says whether it was.
  bool _firstOwnAnswer() {
    if (_ownAnswered) return false;
    _ownAnswered = true;
    _begin();
    return true;
  }

  void _onHouseholds(List<Household> households) {
    final last = _lastHouseholds;
    _lastHouseholds = households;
    if (last != null && last.isEmpty && households.isNotEmpty) {
      _drawForTheirs();
    }
  }

  /// The caller's first games or households have arrived. Worth a draw once, if
  /// the last had nothing of theirs: the draw it starts is what counts next.
  void _drawForTheirs() {
    if (!_nothingOfTheirs) return;
    _nothingOfTheirs = false;
    _begin();
  }

  void _onConnectivity(ConnectivityState next) {
    final previous = _lastConnectivity;
    _lastConnectivity = next;
    if (next == previous || next != ConnectivityState.online) return;
    if (_incomplete || _reading) _begin();
  }

  void _onGone(String gameId) {
    _gone.add(gameId);
    final shown = state;
    if (shown is! SomethingToPlayReady) return;
    final games = [
      for (final game in shown.games)
        if (game.id != gameId) game,
    ];
    if (games.length == shown.games.length) return;
    emit(
      games.isEmpty
          ? const SomethingToPlayNothing()
          : SomethingToPlayReady(games: games, draw: shown.draw),
    );
  }

  @override
  Future<void> close() async {
    // First, and in one turn: nothing should land, or start, while the
    // subscriptions are cancelled.
    _generation++;
    await Future.wait([
      ?_connectivityUpdates?.cancel(),
      ?_goneUpdates?.cancel(),
      ?_householdUpdates?.cancel(),
      ?_ownUpdates?.cancel(),
    ]);
    return super.close();
  }
}
