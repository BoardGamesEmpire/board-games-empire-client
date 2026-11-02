import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What the home page's "Recently added" row holds (#615).
sealed class NewestGamesState extends Equatable {
  const NewestGamesState();

  @override
  List<Object?> get props => [];
}

/// The first read is running, with nothing to show yet. Also what the row
/// holds while it reads again after its last game was found gone.
final class NewestGamesLoading extends NewestGamesState {
  const NewestGamesLoading();
}

/// The server answered, and has no games.
///
/// Only the server's own answer says so. A read that failed, a connection
/// that is down and a cache with nothing in it are [NewestGamesFailed], and so
/// is an answer whose games have all been found gone: "no games here" is a
/// claim about the server, and a false one sends an admin to connect a
/// DataGateway they already have.
final class NewestGamesEmpty extends NewestGamesState {
  const NewestGamesEmpty();
}

/// There is nothing to show and the server could not say why: the read failed,
/// or the connection is down, and this device has no games saved to show
/// instead.
final class NewestGamesFailed extends NewestGamesState {
  const NewestGamesFailed({this.retrying = false});

  /// Whether a read that the user asked for ([NewestGamesCubit.retry]) is
  /// running. A read begun by the page, on its uncovering or a reconnection,
  /// stays quiet: it says nothing the user asked to hear.
  final bool retrying;

  @override
  List<Object?> get props => [retrying];
}

/// The server refused this user its games. The row draws nothing.
final class NewestGamesDenied extends NewestGamesState {
  const NewestGamesDenied();
}

/// The games to show, newest first.
final class NewestGamesReady extends NewestGamesState {
  const NewestGamesReady({required this.games, this.fromCache = false});

  final List<Game> games;

  /// Whether [games] are the ones saved on this device, because the server
  /// could not be asked.
  final bool fromCache;

  @override
  List<Object?> get props => [games, fromCache];
}

/// Reads the games most recently added to the server, for the home page's
/// "Recently added" row (#615).
///
/// ## Page 1 of the newest, and nothing written
///
/// The row is the first [shelfSize] games of `GET /games?sort=newest`. They
/// stop here: nothing is written to the games cache, so a game the user only
/// saw on the home page is not saved on the device, and a refusal forgets
/// nothing. The browse screen is what fills and empties that cache.
///
/// ## When the server can't be asked
///
/// Offline, or after a failed read, the row shows the games already saved on
/// this device, newest first ([GameRepository.getGamesPage]). With none saved
/// it is [NewestGamesFailed], not [NewestGamesEmpty]: a device that has seen
/// no games says nothing about the server.
///
/// Rows already up stay up when a read fails or the connection goes, and a
/// refusal stays a refusal: a failure says nothing about either.
///
/// ## Reading again
///
/// [load] reads, and the section calls it on entry and when the page is
/// uncovered. So does every change of connection. Regaining one asks the
/// server again. Losing one shows the saved games at once, where no answer is
/// up, rather than waiting out a read that the connection may have taken with
/// it. A read leaves the state as it is until its answer lands, so what is on
/// screen isn't swapped out under the user while it runs. A newer read
/// discards an older one, whenever that answers.
///
/// [retry] is the user's own read, from [NewestGamesFailed]. It says so with
/// [NewestGamesFailed.retrying] while it runs, and again when it fails, so
/// that the button can say it is trying and the message can say it failed
/// again. It ignores a press while one is running.
///
/// An answer that comes at once, as it does offline, would otherwise replace
/// the retrying state before the page had drawn it, and the page would see the
/// same failure as before. So whichever read answers, the state it replaces
/// has been up for [retryDwell]. A read begun by the page is not held.
///
/// ## A game found gone
///
/// A game that the server no longer has, or this user may no longer read, is
/// taken down when [gone] says so, wherever it was found. It stays down for
/// as long as this row exists: a read that repeats it neither shows it nor
/// counts it as an answer. Losing the last game reads again, showing
/// [NewestGamesLoading] meanwhile rather than a claim that there are none.
class NewestGamesCubit extends Cubit<NewestGamesState> {
  NewestGamesCubit({
    required this._remote,
    this._cache,
    ConnectivityService? connectivity,
    Stream<String>? gone,
    BgeLogger? logger,
  }) : _connectivity = connectivity,
       _lastConnectivity = connectivity?.current,
       _logger = logger ?? BgeLogger('bge.catalog.newest'),
       super(const NewestGamesLoading()) {
    _connectivityUpdates = connectivity?.watch().listen(
      _onConnectivity,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Connectivity stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    _goneUpdates = gone?.listen(_onGone);
  }

  /// How many games the row asks for and shows.
  static const int shelfSize = 10;

  /// How long [retry]'s state stays up before an answer replaces it, whatever
  /// the answer and however soon it comes.
  ///
  /// Long enough to be seen and heard as a state of its own, not a flicker, and
  /// short enough that a retry whose answer is already known, such as one made
  /// offline, doesn't leave the user waiting on nothing. It costs nothing to an
  /// answer that takes longer: that isn't held any further.
  static const Duration retryDwell = Duration(milliseconds: 300);

  final GamesRemoteDataSource _remote;
  final GameRepository? _cache;
  final ConnectivityService? _connectivity;
  final BgeLogger _logger;

  StreamSubscription<ConnectivityState>? _connectivityUpdates;
  StreamSubscription<String>? _goneUpdates;

  /// The state a change is measured from. The service replays its current
  /// state to a new subscriber, which is not a change.
  ConnectivityState? _lastConnectivity;

  /// Bumped to discard whatever read is in flight.
  int _generation = 0;
  bool _reading = false;

  /// Completes when the retrying state, if it is up, has been up for
  /// [retryDwell].
  Completer<void> _dwell = Completer<void>()..complete();
  Timer? _dwellTimer;

  /// Games found gone since this row was made, never shown again.
  final Set<String> _gone = {};

  /// Reads the row, discarding any read already out.
  void load() {
    if (isClosed) return;
    final generation = ++_generation;
    _reading = true;
    unawaited(_read(generation));
  }

  /// Reads the row because the user asked, and says so while it runs.
  ///
  /// Asks for nothing while a read is out, since a second would only discard
  /// the first. So a second press is ignored, and a press while a read the page
  /// began is out reports that read rather than starting another.
  void retry() {
    if (isClosed) return;
    final shown = state;
    if (shown is NewestGamesFailed) {
      // A second press, while the first dwells or reads.
      if (shown.retrying) return;
      emit(const NewestGamesFailed(retrying: true));
      // A turn can answer before the page has drawn a frame, and the page
      // builds once, from the last state: so what this says is held up until
      // it has had its time on screen.
      _dwell = Completer<void>();
      _dwellTimer = Timer(retryDwell, _dwell.complete);
    }
    if (!_reading) load();
  }

  Future<void> _read(int generation) async {
    try {
      if (_connectivity?.current == ConnectivityState.offline) {
        await _fallBack(generation);
      } else {
        await _fetch(generation);
      }
    } finally {
      if (generation == _generation) _reading = false;
    }
  }

  Future<void> _fetch(int generation) async {
    final List<Game> answer;
    try {
      final page = await _remote.fetchPage(
        page: 1,
        limit: shelfSize,
        sort: GameSort.newest,
      );
      answer = page.items;
    } on GamesForbiddenException {
      return _show(generation, const NewestGamesDenied());
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Recently added games read failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _fallBack(generation);
    }
    // The server's own answer, before any game is taken out of it.
    if (answer.isEmpty) return _show(generation, const NewestGamesEmpty());
    return _show(generation, _rows(answer, fromCache: false));
  }

  /// The games saved on this device, unless a row or a refusal is already up.
  Future<void> _fallBack(int generation) async {
    final shown = state;
    if (shown is NewestGamesDenied || shown is NewestGamesReady) return;
    final saved = await _readCache();
    return _show(generation, _rows(saved, fromCache: true));
  }

  /// [games] without those found gone. Nothing left is [NewestGamesFailed],
  /// never [NewestGamesEmpty]: the caller has no answer from the server that
  /// says there are none.
  NewestGamesState _rows(List<Game> games, {required bool fromCache}) {
    final shown = [
      for (final game in games)
        if (!_gone.contains(game.id)) game,
    ];
    return shown.isEmpty
        ? const NewestGamesFailed()
        : NewestGamesReady(games: shown, fromCache: fromCache);
  }

  /// The cache's newest games, or none where there is no cache or the read
  /// failed.
  Future<List<Game>> _readCache() async {
    final cache = _cache;
    if (cache == null) return const [];
    try {
      return await cache.getGamesPage(limit: shelfSize, sort: GameSort.newest);
    } on Object catch (error, stackTrace) {
      // A session ending mid-read lands here, as a disposed cache.
      _logger.warn(
        'Reading cached games failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  /// Shows [next], if the read begun as [generation] is still the one wanted.
  ///
  /// While [retry]'s state is up, whichever read answers waits for its dwell
  /// first, and is then judged again: a newer read may have taken its place.
  Future<void> _show(int generation, NewestGamesState next) async {
    if (!_wanted(generation)) return;
    if (state case NewestGamesFailed(retrying: true)) {
      await _dwell.future;
      if (!_wanted(generation)) return;
    }
    emit(next);
  }

  /// Whether the read begun as [generation] is the latest, on a cubit that is
  /// open. Cubit.emit throws once closed.
  bool _wanted(int generation) => !isClosed && generation == _generation;

  void _onConnectivity(ConnectivityState next) {
    final previous = _lastConnectivity;
    _lastConnectivity = next;
    // Unknown says nothing new: what's up stays up, and the next change decides.
    if (next == previous || next == ConnectivityState.unknown) return;
    load();
  }

  void _onGone(String gameId) {
    _gone.add(gameId);
    final shown = state;
    if (shown is! NewestGamesReady) return;
    final games = [
      for (final game in shown.games)
        if (game.id != gameId) game,
    ];
    if (games.length == shown.games.length) return;
    if (games.isEmpty) {
      emit(const NewestGamesLoading());
      load();
      return;
    }
    emit(NewestGamesReady(games: games, fromCache: shown.fromCache));
  }

  @override
  Future<void> close() async {
    // First, and in one turn: nothing should land, or start, while the
    // subscriptions are cancelled. An answer held for the dwell is released,
    // to find itself discarded.
    _generation++;
    _dwellTimer?.cancel();
    if (!_dwell.isCompleted) _dwell.complete();
    await Future.wait([
      ?_connectivityUpdates?.cancel(),
      ?_goneUpdates?.cancel(),
    ]);
    return super.close();
  }
}
