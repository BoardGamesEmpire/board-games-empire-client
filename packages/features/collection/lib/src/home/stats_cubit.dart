import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What the stats card says about the user's households (#614).
sealed class HouseholdStat extends Equatable {
  const HouseholdStat();

  @override
  List<Object?> get props => [];
}

/// Nothing: the card draws no household line.
///
/// Not a claim that there are no games. It is what stands whenever the number
/// can't be vouched for: the households are unknown, the connection is down, a
/// read failed, the first answer hasn't landed, or an empty list isn't yet
/// known to be the whole truth.
final class HouseholdStatHidden extends HouseholdStat {
  const HouseholdStatHidden();
}

/// The user is in no household, and the cache has settled on that: the card
/// offers the way to create or join one.
final class HouseholdStatPrompt extends HouseholdStat {
  const HouseholdStatPrompt();
}

/// How many games the user's households share between them.
final class HouseholdStatCount extends HouseholdStat {
  const HouseholdStatCount(this.games);

  final int games;

  @override
  List<Object?> get props => [games];
}

/// What the stats card holds (#614).
final class StatsState extends Equatable {
  const StatsState({
    this.collectionGames,
    this.households = const HouseholdStatHidden(),
  });

  /// How many different games the user's collection holds, or null where that
  /// isn't known: the cache hasn't answered, its read failed, or it is empty
  /// and only a failed pass has looked.
  final int? collectionGames;

  final HouseholdStat households;

  @override
  List<Object?> get props => [collectionGames, households];
}

/// Reads the numbers on the home page's "Your stats" card (#614).
///
/// ## The collection half
///
/// The number of different games in the user's collection, from the local
/// cache. It counts distinct game ids, because an entry is per game and medium:
/// a game owned both boxed and digital is one game.
///
/// A list with rows always counts. An empty one is 0 where there is no
/// `collectionHydration` to wait for, or once a pass has landed rows, and
/// unknown before that: a failure confirms nothing, so a cache that only a
/// failed pass has seen is not yet known to be empty
/// ([Hydration.everRefreshed]). An unknown number draws no line. A stream that
/// fails is unknown until its next rows, and one that closes before answering
/// never is: the repository closes its streams when it is disposed.
///
/// ## The households half
///
/// Read from the server, separately from "Something to play": `GET
/// /households/game-pool/random?size=1`, for the `gameCount` of the whole pool
/// the user's households share. Nothing is written to any cache.
///
/// It depends on what `households`, the cached list, says:
///
/// - **Unknown**: no stream, or none that has answered, or one that failed.
///   [HouseholdStatHidden], and nothing is asked.
/// - **Empty**: the user is in no household. [HouseholdStatPrompt], and nothing
///   is asked, but only once the cache is known to be empty: with no
///   `householdHydration` to wait for, or when a pass has landed and the last
///   one to finish did not fail. Before that the cache may only not have
///   filled yet, and the prompt would flash for someone who has households.
///   Connectivity is not asked: that the list is empty is a fact about the
///   list, not a number that goes stale.
/// - **Filled**: the count, if there is one to show. Without a `pool` there is
///   none.
///
/// ## When the count can't be shown
///
/// It is hidden, rather than left standing, where it might be stale or false:
/// offline, after a read that failed, and once the list has gone empty. The
/// earlier number is dropped and does not come back while the next read runs.
///
/// ## Reading again
///
/// The count is read when the households first show some, so on entry and when
/// the first hydrate fills the list; on [reload], which the card calls when the
/// page is uncovered; and on regaining a connection. A read leaves the count as
/// it is until its answer lands, so what is on screen doesn't flicker while it
/// runs. A newer read discards an older one, whenever that answers.
class StatsCubit extends Cubit<StatsState> {
  StatsCubit({
    required GameCollectionRepository collection,
    Stream<Hydration>? collectionHydration,
    Stream<List<Household>>? households,
    Stream<Hydration>? householdHydration,
    this._pool,
    this._connectivity,
    BgeLogger? logger,
  }) : _collectionHydrationGiven = collectionHydration != null,
       _householdHydrationGiven = householdHydration != null,
       _lastConnectivity = _connectivity?.current,
       _logger = logger ?? BgeLogger('bge.collection.stats'),
       super(const StatsState()) {
    _connectivityUpdates = _connectivity?.watch().listen(
      _onConnectivity,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Connectivity stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    _collectionHydrationUpdates = collectionHydration?.listen(
      _onCollectionHydration,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Collection hydration status stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    _householdHydrationUpdates = householdHydration?.listen(
      _onHouseholdHydration,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Household hydration status stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    _ownUpdates = collection.watchCollectionListItems().listen(
      _onOwn,
      onError: _onOwnFailed,
    );
    _householdUpdates = households?.listen(
      _onHouseholds,
      onError: _onHouseholdsFailed,
    );
  }

  /// The smallest sample the server allows. Only the size of the pool is used,
  /// not the games in the sample.
  static const int _sampleSize = 1;

  final HouseholdRemoteDataSource? _pool;
  final ConnectivityService? _connectivity;
  final BgeLogger _logger;

  /// Whether there is a hydrate to wait for, as against none: an absent status
  /// reads as settled, and not as loading forever.
  final bool _collectionHydrationGiven;
  final bool _householdHydrationGiven;

  StreamSubscription<ConnectivityState>? _connectivityUpdates;
  StreamSubscription<Hydration>? _collectionHydrationUpdates;
  StreamSubscription<Hydration>? _householdHydrationUpdates;
  StreamSubscription<List<GameCollectionListItem>>? _ownUpdates;
  StreamSubscription<List<Household>>? _householdUpdates;

  /// The state a change is measured from. The service replays its current
  /// state to a new subscriber, which is not a change.
  ConnectivityState? _lastConnectivity;

  /// Bumped to discard whatever read is in flight.
  int _generation = 0;

  /// What each hydrate last reported. The default is also what an absent or
  /// silent one means: idle, nothing confirmed, nothing failed.
  Hydration _collectionHydration = const Hydration();
  Hydration _householdHydration = const Hydration();

  /// The distinct games in the cache, or null before it answers and after its
  /// read fails. 0 is an empty cache, which [_collectionGames] weighs.
  int? _ownedGames;

  /// Whether the cache holds a household, or null where that isn't known.
  bool? _inHouseholds;

  /// The last answer's `gameCount`, or null where none may be shown.
  int? _poolCount;

  /// Reads the count again, if the households are there to read it for.
  ///
  /// The count stays up until the answer lands. If it can't be asked, because
  /// there are no households, no pool or no connection, the earlier one goes.
  void reload() {
    if (isClosed) return;
    _read();
  }

  void _read() {
    final generation = ++_generation;
    final pool = _pool;
    if (_inHouseholds != true || pool == null || _offline) {
      _poolCount = null;
      _publish();
      return;
    }
    unawaited(_fetch(pool, generation));
  }

  Future<void> _fetch(HouseholdRemoteDataSource pool, int generation) async {
    int? count;
    try {
      count = (await pool.fetchGamePoolSample(size: _sampleSize)).gameCount;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household game count read failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_wanted(generation)) return;
    // A failure is not an answer: it drops the count rather than keeping one
    // that may no longer be true.
    _poolCount = count;
    _publish();
  }

  /// Whether the read begun as [generation] is the latest, on a cubit that is
  /// open. Cubit.emit throws once closed.
  bool _wanted(int generation) => !isClosed && generation == _generation;

  bool get _offline => _connectivity?.current == ConnectivityState.offline;

  void _onConnectivity(ConnectivityState next) {
    final previous = _lastConnectivity;
    _lastConnectivity = next;
    // Unknown says nothing new: what's up stays up, and the next change
    // decides.
    if (next == previous || next == ConnectivityState.unknown) return;
    _read();
  }

  void _onOwn(List<GameCollectionListItem> items) {
    _ownedGames = {for (final item in items) item.gameId}.length;
    _publish();
  }

  void _onOwnFailed(Object error, StackTrace stackTrace) {
    _logger.warn(
      'Collection read failed',
      error: error,
      stackTrace: stackTrace,
    );
    _ownedGames = null;
    _publish();
  }

  void _onHouseholds(List<Household> households) {
    final wasIn = _inHouseholds ?? false;
    _inHouseholds = households.isNotEmpty;
    // Into a household is a reason to read, and out of the last one is a
    // reason to drop the count and any read out. Everything else is not.
    if (_inHouseholds! != wasIn) {
      _read();
    } else {
      _publish();
    }
  }

  void _onHouseholdsFailed(Object error, StackTrace stackTrace) {
    _logger.warn(
      'Households read failed',
      error: error,
      stackTrace: stackTrace,
    );
    _inHouseholds = null;
    _read();
  }

  void _onCollectionHydration(Hydration hydration) {
    _collectionHydration = hydration;
    _publish();
  }

  void _onHouseholdHydration(Hydration hydration) {
    _householdHydration = hydration;
    _publish();
  }

  void _publish() {
    final next = StatsState(
      collectionGames: _collectionGames,
      households: _householdStat,
    );
    // Not left to the cubit, which lets a state equal to the first one through.
    if (next != state) emit(next);
  }

  int? get _collectionGames {
    final games = _ownedGames;
    if (games == null) return null;
    // Rows always count.
    if (games > 0) return games;
    final unconfirmed =
        _collectionHydrationGiven && !_collectionHydration.everRefreshed;
    return unconfirmed ? null : 0;
  }

  HouseholdStat get _householdStat {
    final inHouseholds = _inHouseholds;
    if (inHouseholds == null) return const HouseholdStatHidden();
    if (!inHouseholds) {
      return _householdsSettledEmpty
          ? const HouseholdStatPrompt()
          : const HouseholdStatHidden();
    }
    final count = _poolCount;
    return count == null
        ? const HouseholdStatHidden()
        : HouseholdStatCount(count);
  }

  /// Whether an empty household list is the whole truth, rather than a cache
  /// that hasn't filled yet or a pass that couldn't say.
  ///
  /// A pass running after an earlier one landed still counts: the landing is
  /// never un-known. A failure after it does not, because the rows are those
  /// the failure left.
  bool get _householdsSettledEmpty =>
      !_householdHydrationGiven ||
      (_householdHydration.everRefreshed &&
          !_householdHydration.lastPassFailed);

  @override
  Future<void> close() async {
    // First, and not after an await: nothing should be left running. An answer
    // still out is dropped with the cubit.
    _generation++;
    // Every subscription is cancelled before any is awaited, so that none can
    // deliver while another is still being cancelled.
    await Future.wait([
      ?_connectivityUpdates?.cancel(),
      ?_collectionHydrationUpdates?.cancel(),
      ?_householdHydrationUpdates?.cancel(),
      ?_ownUpdates?.cancel(),
      ?_householdUpdates?.cancel(),
    ]);
    return super.close();
  }
}
