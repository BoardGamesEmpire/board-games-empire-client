import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:events/src/overview/event_groups.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What the home section's fallback holds (#613).
sealed class UpcomingFallbackState extends Equatable {
  const UpcomingFallbackState();

  @override
  List<Object?> get props => [];
}

/// Not wanted: the user has upcoming events of their own, or the cache hasn't
/// settled on their having none.
final class UpcomingFallbackIdle extends UpcomingFallbackState {
  const UpcomingFallbackIdle();
}

/// The first read is running, with nothing to show yet.
final class UpcomingFallbackLoading extends UpcomingFallbackState {
  const UpcomingFallbackLoading();
}

/// The last answer's rows, soonest first. Empty means there's nothing to offer,
/// for any reason: none coming up, no connection, or a failed read.
final class UpcomingFallbackReady extends UpcomingFallbackState {
  const UpcomingFallbackReady(this.rows);

  final List<EventRow> rows;

  @override
  List<Object?> get props => [rows];
}

/// Reads what's coming up that the user doesn't attend, for the home section
/// to show when they have nothing of their own (#613).
///
/// The rows come straight from the server and stop here. Nothing is written to
/// the events cache, so they never reach the events screen, and offline there
/// is nothing to show.
///
/// [activate] and [deactivate] say whether the rows are wanted, and the section
/// decides that from the cache. Going away discards any read in flight, because
/// the user's own event arriving means a late answer has no place on the page.
/// While active it reads again on [reload] and on regaining a connection, and
/// keeps the rows up until the new answer arrives.
///
/// A suggestion list isn't worth an error surface on the landing page, so a
/// failed read is logged and isn't an answer: rows already up stay up, and
/// with none it reads as nothing to offer. The next uncover or reconnect reads
/// again.
///
/// ## The household names annotate
///
/// As on the overview, `households` names each row's household where it's
/// cached. New names regroup the last answer rather than asking again, and a
/// failed stream loses only the names.
class UpcomingFallbackCubit extends Cubit<UpcomingFallbackState> {
  UpcomingFallbackCubit({
    this._remote,
    ConnectivityService? connectivity,
    Stream<List<Household>>? households,
    DateTime Function()? now,
    BgeLogger? logger,
  }) : _connectivity = connectivity,
       _lastConnectivity = connectivity?.current,
       _now = now ?? DateTime.now,
       _logger = logger ?? BgeLogger('bge.events.home'),
       super(const UpcomingFallbackIdle()) {
    _connectivityUpdates = connectivity?.watch().listen(
      _onConnectivity,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Connectivity stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    _householdUpdates = households?.listen(
      _onHouseholds,
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Upcoming events households stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  /// How many rows the fallback asks for and shows.
  static const int rowCap = 10;

  final EventRemoteDataSource? _remote;
  final ConnectivityService? _connectivity;
  final DateTime Function() _now;
  final BgeLogger _logger;

  StreamSubscription<ConnectivityState>? _connectivityUpdates;
  StreamSubscription<List<Household>>? _householdUpdates;

  /// The state a change is measured from. The service replays its current
  /// state to a new subscriber, which is not a change.
  ConnectivityState? _lastConnectivity;

  bool _active = false;

  /// Bumped to discard whatever read is in flight.
  int _generation = 0;

  /// The last answer, kept so that new household names can regroup it.
  List<EventSnapshot> _answer = const [];

  Map<String, String> _householdNames = const {};

  /// Starts wanting the rows, and reads them unless they're already wanted.
  void activate() {
    if (_active || isClosed) return;
    _active = true;
    _read();
  }

  /// Stops wanting the rows, and discards any read in flight.
  void deactivate() {
    if (!_active || isClosed) return;
    _active = false;
    _generation++;
    _answer = const [];
    emit(const UpcomingFallbackIdle());
  }

  /// Reads again, if the rows are wanted.
  void reload() {
    if (_active && !isClosed) _read();
  }

  void _read() {
    final generation = ++_generation;
    final remote = _remote;
    if (remote == null || _connectivity?.current == ConnectivityState.offline) {
      _show(const []);
      return;
    }
    if (state is UpcomingFallbackIdle) emit(const UpcomingFallbackLoading());
    unawaited(_fetch(remote, generation));
  }

  Future<void> _fetch(EventRemoteDataSource remote, int generation) async {
    List<EventSnapshot>? answer;
    try {
      final page = await remote.browseEvents(limit: rowCap);
      answer = page.items;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Upcoming events read failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Cubit.emit throws once closed.
    if (isClosed || generation != _generation) return;
    _show(answer ?? _answer);
  }

  void _show(List<EventSnapshot> answer) {
    _answer = answer;
    final groups = groupEvents(
      [
        for (final snapshot in answer)
          EventListItem(
            event: snapshot.event,
            occurrences: snapshot.occurrences,
          ),
      ],
      now: _now(),
      householdNames: _householdNames,
    );
    emit(UpcomingFallbackReady(groups.upcoming.take(rowCap).toList()));
  }

  void _onConnectivity(ConnectivityState next) {
    final previous = _lastConnectivity;
    _lastConnectivity = next;
    if (next == previous || !_active) return;

    switch (next) {
      case ConnectivityState.online:
        _read();
      case ConnectivityState.offline:
        _generation++;
        _show(const []);
      case ConnectivityState.unknown:
        // Says nothing new: what's up stays up, and the next change decides.
        break;
    }
  }

  void _onHouseholds(List<Household> households) {
    _householdNames = {for (final h in households) h.id: h.name};
    if (state is UpcomingFallbackReady) _show(_answer);
  }

  @override
  Future<void> close() async {
    await _connectivityUpdates?.cancel();
    await _householdUpdates?.cancel();
    return super.close();
  }
}
