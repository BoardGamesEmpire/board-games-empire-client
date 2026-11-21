import 'package:events/src/bloc/event_lineup_event.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:events/src/bloc/session_checked_reads.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Reads the lineup of an event: the games it will play, and the dates they
/// are on (#519). The lineup is read online and never cached, as the
/// nominations are.
///
/// ## Reading
///
/// [EventLineupRequested] and [EventLineupRetryRequested] read the whole
/// lineup, one read out at a time. A request while a read is out reads once
/// more after it, for the latest event id named, however many came in.
///
/// - Answered: the games replace the last ones.
/// - A 403: hidden, with no games.
/// - A 404: gone, with no games, or failed if the read started gone: the
///   event's own read since then didn't settle it.
/// - Anything else, or a session that couldn't be confirmed: failed, keeping
///   the games read before.
///
/// ## The session
///
/// On web every tab shares one session cookie, and a sign-in in another tab
/// moves it to another user under this screen (#432). So `confirmSession` is
/// asked before each read and again before its answer is used. A null
/// `confirmSession`, as on native, is always yes. A no, or a throw, fails the
/// read as above, and an answer that followed one is dropped, since it could
/// be another user's.
///
/// ## Closing
///
/// What closing stops is what the bloc emits, and the reads it would start. A
/// flag set first in [close] guards each emit, since a handler's emits can
/// come after close has started.
class EventLineupBloc extends Bloc<EventLineupEvent, EventLineupState> {
  EventLineupBloc({
    required this._remote,
    this._confirmSession,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.lineup'),
       super(const EventLineupState()) {
    on<EventLineupRequested>(_onRequested);
    on<EventLineupRetryRequested>(_onRetryRequested);
  }

  final EventRemoteDataSource _remote;
  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// The sequencing of reads, and the session check each read asks.
  late final SessionCheckedReads _reads = SessionCheckedReads(
    confirmSession: _confirmSession,
    logger: _logger,
  );

  Future<void> _onRequested(
    EventLineupRequested event,
    Emitter<EventLineupState> emit,
  ) => _read(event.eventId, emit);

  Future<void> _onRetryRequested(
    EventLineupRetryRequested event,
    Emitter<EventLineupState> emit,
  ) {
    _reads.retrying = true;
    // At once, before the session is asked, so the retry shows under way
    // from the press.
    if (!_reads.closing) emit(state.copyWith(refreshing: true));
    return _read(event.eventId, emit);
  }

  Future<void> _read(String eventId, Emitter<EventLineupState> emit) =>
      _reads.run(eventId, (id) => _readOnce(id, emit));

  /// Reads the lineup of the event [eventId] once the session says yes, and
  /// fails the read when the session says no. Never throws.
  Future<void> _readOnce(String eventId, Emitter<EventLineupState> emit) async {
    // Only reads change the load, and one is out at a time, so this is the
    // load the read started in.
    final startedGone = state.load == EventLineupLoad.gone;
    if (!await _reads.confirmed('Lineup not read')) {
      _readFailed(emit);
      return;
    }
    if (_reads.closing) return;

    emit(
      state.copyWith(
        load: switch (state.load) {
          EventLineupLoad.hidden || EventLineupLoad.gone => state.load,
          _ => EventLineupLoad.loading,
        },
        refreshing: _reads.retrying,
      ),
    );

    final List<LineupGame> games;
    try {
      games = await _remote.fetchLineup(eventId);
    } on EventRemoteForbiddenException catch (error) {
      _logger.info('Lineup not shown to this viewer', error: error);
      await _readRefused(EventLineupLoad.hidden, emit);
      return;
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Lineup read found the event gone', error: error);
      // The event's read since then didn't settle it, so this is a lineup the
      // server won't serve, not an event that went.
      await _readRefused(
        startedGone ? EventLineupLoad.failed : EventLineupLoad.gone,
        emit,
      );
      return;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Lineup read failed',
        error: error,
        stackTrace: stackTrace,
      );
      _readFailed(emit);
      return;
    }
    if (!await _reads.confirmed('Lineup answer dropped')) {
      _readFailed(emit);
      return;
    }
    if (_reads.closing) return;

    emit(
      state.copyWith(
        load: EventLineupLoad.loaded,
        games: List.unmodifiable(games),
        answered: true,
        refreshFailed: false,
        refreshing: _reads.stillRefreshing,
      ),
    );
  }

  /// Ends a read the server refused as [load], or as failed if the session
  /// has moved since, when the refusal was another user's.
  Future<void> _readRefused(
    EventLineupLoad load,
    Emitter<EventLineupState> emit,
  ) async {
    if (!await _reads.confirmed('Lineup answer dropped')) {
      _readFailed(emit);
      return;
    }
    if (_reads.closing) return;
    emit(
      EventLineupState(
        load: load,
        refreshFailed: load == EventLineupLoad.failed,
        refreshing: _reads.stillRefreshing,
      ),
    );
  }

  /// Ends a read as failed, keeping the games read before.
  void _readFailed(Emitter<EventLineupState> emit) {
    if (_reads.closing) return;
    emit(
      state.copyWith(
        load: EventLineupLoad.failed,
        refreshFailed: true,
        refreshing: _reads.stillRefreshing,
      ),
    );
  }

  @override
  Future<void> close() {
    _reads.closing = true;
    return super.close();
  }
}
