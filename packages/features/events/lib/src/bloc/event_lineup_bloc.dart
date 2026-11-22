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
/// - Answered: the games replace the last ones, less any a removal has
///   dropped since the read started, which its answer can predate.
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
    on<LineupGameAdded>(_onAdded);
    on<LineupGameRemoved>(_onRemoved);
    on<LineupWriteDropped>(_onWriteDropped);
    on<EventLineupOutcomeDismissed>(_onOutcomeDismissed);
  }

  final EventRemoteDataSource _remote;
  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// The sequencing of reads, and the session check each read asks.
  late final SessionCheckedReads _reads = SessionCheckedReads(
    confirmSession: _confirmSession,
    logger: _logger,
  );

  /// The lineup games removals have dropped from the rows since the read that
  /// is out started. Its answer can predate them, so they are dropped from
  /// it again.
  final Set<String> _droppedSinceRead = {};

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

  Future<void> _onAdded(
    LineupGameAdded event,
    Emitter<EventLineupState> emit,
  ) async {
    if (_reads.closing || state.busy) return;

    final game = event.game;
    _started((write: LineupWrite.add, id: game.id), emit);

    final (:result, :sent) = await _add(event);
    if (_reads.closing) return;

    _ended(
      LineupAddOutcome(result, title: game.title, subtitle: game.subtitle),
      emit,
    );
    if (sent) await _read(event.eventId, emit);
  }

  /// Adds [event]'s game once the session says yes, and answers how it ended
  /// and whether it was sent. Never throws.
  Future<({LineupAddResult result, bool sent})> _add(
    LineupGameAdded event,
  ) async {
    const notSent = (result: LineupAddResult.failed, sent: false);
    const failed = (result: LineupAddResult.failed, sent: true);
    if (!await _reads.confirmed('Lineup add not sent')) return notSent;
    if (_reads.closing) return notSent;

    try {
      await _remote.directAddGame(
        event.eventId,
        platformGameId: event.game.platformGameId,
        suppliedById: event.game.id,
        occurrenceId: event.occurrenceId,
        role: event.role,
        notes: event.notes,
        maxPlayTime: event.maxPlayTime,
      );
    } on EventWriteConflictException catch (error) {
      _logger.info(
        'Lineup add refused: the supplier is not going',
        error: error,
      );
      return (result: LineupAddResult.supplierNotGoing, sent: true);
    } on EventRemoteNotFoundException catch (error) {
      // The event, the date or the pool row: the server's 404s come in
      // that order, and say nothing the client can tell apart.
      _logger.info('Lineup add found something gone', error: error);
      return (result: LineupAddResult.gone, sent: true);
    } on EventWriteRefusedException catch (error) {
      _logger.info('Lineup add refused', error: error);
      return (result: LineupAddResult.refused, sent: true);
    } on Object catch (error, stackTrace) {
      _logger.warn('Lineup add failed', error: error, stackTrace: stackTrace);
      return failed;
    }
    if (!await _reads.confirmed('Lineup add answer dropped')) return failed;
    return (result: LineupAddResult.done, sent: true);
  }

  Future<void> _onRemoved(
    LineupGameRemoved event,
    Emitter<EventLineupState> emit,
  ) async {
    if (_reads.closing || state.busy) return;

    final game = event.game;
    _started((write: LineupWrite.remove, id: game.id), emit);

    final (:result, :sent) = await _remove(event);
    if (_reads.closing) return;

    _ended(
      LineupRemoveOutcome(result, title: game.title, subtitle: game.subtitle),
      emit,
      // A done or an already gone leaves the game out of the lineup, so its
      // row goes at once, ahead of the read.
      dropping: switch (result) {
        LineupRemoveResult.done || LineupRemoveResult.alreadyGone => game.id,
        _ => null,
      },
    );
    if (sent) await _read(event.eventId, emit);
  }

  /// Removes [event]'s game once the session says yes, and answers how it
  /// ended and whether it was sent. Never throws.
  Future<({LineupRemoveResult result, bool sent})> _remove(
    LineupGameRemoved event,
  ) async {
    const notSent = (result: LineupRemoveResult.failed, sent: false);
    const failed = (result: LineupRemoveResult.failed, sent: true);
    if (!await _reads.confirmed('Lineup removal not sent')) return notSent;
    if (_reads.closing) return notSent;

    try {
      await _remote.removeLineupGame(event.eventId, event.game.id);
    } on EventWriteConflictException catch (error) {
      if (error.code == 'LINEUP_STARTED') {
        _logger.info('Lineup removal refused: it has started', error: error);
        if (!await _reads.confirmed('Lineup removal answer dropped')) {
          return failed;
        }
        return (result: LineupRemoveResult.started, sent: true);
      }
      _logger.warn('Lineup removal refused, uncoded', error: error);
      return failed;
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Lineup removal found the game gone', error: error);
      // It drops the row, so it is used as an answer is.
      if (!await _reads.confirmed('Lineup removal answer dropped')) {
        return failed;
      }
      return (result: LineupRemoveResult.alreadyGone, sent: true);
    } on EventWriteRefusedException catch (error) {
      _logger.info('Lineup removal refused', error: error);
      return (result: LineupRemoveResult.refused, sent: true);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Lineup removal failed',
        error: error,
        stackTrace: stackTrace,
      );
      return failed;
    }
    if (!await _reads.confirmed('Lineup removal answer dropped')) return failed;
    return (result: LineupRemoveResult.done, sent: true);
  }

  void _onWriteDropped(
    LineupWriteDropped event,
    Emitter<EventLineupState> emit,
  ) {
    if (_reads.closing || state.busy) return;
    // Cleared first, so a drop like the last is a state of its own, which a
    // screen draws, and a screen reader hears, as new. Only when there is
    // one: Bloc emits a state equal to the initial one if it is the first.
    if (state.outcome != null) emit(state.copyWith(outcome: () => null));
    final outcome = switch (event.write) {
      LineupWrite.add => LineupAddOutcome(
        LineupAddResult.dropped,
        title: event.title,
        subtitle: event.subtitle,
      ),
      LineupWrite.remove => LineupRemoveOutcome(
        LineupRemoveResult.dropped,
        title: event.title,
        subtitle: event.subtitle,
      ),
    };
    emit(state.copyWith(outcome: () => outcome));
  }

  void _onOutcomeDismissed(
    EventLineupOutcomeDismissed event,
    Emitter<EventLineupState> emit,
  ) {
    if (state.outcome == null || _reads.closing) return;
    emit(state.copyWith(outcome: () => null));
  }

  /// Emits [writing] as the write that is out, clearing the last outcome.
  void _started(LineupWriting writing, Emitter<EventLineupState> emit) =>
      emit(state.copyWith(writing: () => writing, outcome: () => null));

  /// Ends the write that is out with [outcome], dropping the game [dropping]
  /// from the rows when there is one, and from the answer of a read that is
  /// out.
  void _ended(
    EventLineupOutcome outcome,
    Emitter<EventLineupState> emit, {
    String? dropping,
  }) {
    if (_reads.closing) return;
    if (dropping != null) _droppedSinceRead.add(dropping);
    emit(
      state.copyWith(
        writing: () => null,
        outcome: () => outcome,
        games: dropping == null
            ? null
            : List.unmodifiable(
                state.games.where((each) => each.id != dropping),
              ),
      ),
    );
  }

  /// Reads the lineup of the event [eventId] once the session says yes, and
  /// fails the read when the session says no. Never throws.
  Future<void> _readOnce(String eventId, Emitter<EventLineupState> emit) async {
    _droppedSinceRead.clear();
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
        games: List.unmodifiable(
          games.where((each) => !_droppedSinceRead.contains(each.id)),
        ),
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
        writing: state.writing,
        outcome: state.outcome,
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
