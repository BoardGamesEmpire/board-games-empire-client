import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What a write's answer does to a list of nominations.
typedef _Change = List<EventNomination> Function(List<EventNomination> rows);

/// How a nominate or a withdrawal ended, with the server's answer when it is
/// to be used.
typedef _Answered<R> = ({R result, EventNomination? answer});

/// Puts [row] at the head, in place of any row with its id.
_Change _atHead(EventNomination row) =>
    (rows) => [row, ...rows.where((each) => each.id != row.id)];

/// Puts [row] in place of the row with its id. A list without one is left as
/// it was.
_Change _replacing(EventNomination row) =>
    (rows) => [
      for (final each in rows)
        if (each.id == row.id) row else each,
    ];

/// Drops the row with the id [id].
_Change _dropping(String id) =>
    (rows) => [...rows.where((each) => each.id != id)];

/// What a nominate made of the game, read from the status it answered with.
NominateResult _nominated(NominationStatus status) => switch (status) {
  NominationStatus.open => NominateResult.open,
  NominationStatus.awaitingApproval => NominateResult.awaitingApproval,
  _ when status.inLineup => NominateResult.inLineup,
  _ => NominateResult.settled,
};

/// Reads every nomination on an event's Games tab, and sends the viewer's
/// nominate, vote and withdrawal (#517).
///
/// Writes go straight to the server, never through the sync queue, and
/// nothing is re-sent. The nominations are never cached: they live in
/// [EventNominationsState.nominations]. The screen asks for a read the first
/// time the Games tab shows, after each detail read from then on, and when
/// the user retries a failed read. The viewer's own writes are read back
/// through their answers, below, rather than by reading the whole list again.
/// A write the screen's re-check dropped reads nothing. The event's id travels
/// with each request rather than with the bloc, since a reconcile can move it
/// while the screen is open (#499).
///
/// Reads and writes are independent: a read asked for while a write is out
/// goes ahead under the rules below, and doesn't wait for it.
///
/// ## Reads
///
/// Each answer to the read, with the load and the nominations it leaves:
///
/// - 2xx; load: loaded; nominations: the ones read.
/// - A 403; load: hidden: not shown to this viewer; nominations: cleared.
/// - A 404: the event is gone; load: gone: the screen reads the event, which
///   settles it; nominations: cleared.
/// - A 404 again, on a read that started in gone: the event's read since
///   didn't settle it, as on a server without these routes; load: failed;
///   nominations: none. So the screen can offer a retry, and the bloc never
///   reads by itself on a gone.
/// - Anything else; load: failed; nominations: the last ones, kept.
/// - None: the session said no, or threw (below); load: failed; nominations:
///   the last ones, kept.
/// - Any of the first three, once the session has moved (below); load:
///   failed; nominations: the last ones, kept.
///
/// A read after a hidden or a gone keeps that load until it answers, rather
/// than going through loading, so what a refused viewer sees doesn't change
/// for the length of each read.
///
/// One read is out at a time. A request while one is out marks one more to
/// run after it, for the event the latest request names, however many come
/// in. A write's read is one more request like any other, for the event named
/// last: the write's own, or a request's that came in while it was out.
///
/// A failed read's [EventNominationsState.refreshFailed] stays while the next
/// read runs, and only a read that ends some other way clears it.
/// [EventNominationsRetryRequested] is a read the user asked for:
/// [EventNominationsState.refreshing] says so from the request until the
/// reads it joined have ended.
///
/// ## Writes
///
/// One write is out at a time: a nominate, a vote or a withdrawal is ignored
/// while another is out ([EventNominationsState.busy]). As each starts it
/// clears the last outcome, and [EventNominationsState.writing] names it
/// until its outcome comes in, in the same state as any row its answer
/// changes. So the outcome never lands beside the row as it was. The outcome
/// carries the game's title: the pool row's for a nominate, and the
/// nomination's for a vote or a withdrawal.
///
/// A row's change is kept over a read that was out as the write ended, whose
/// answer can predate the write: the change is made again on that answer. A
/// read that goes out after the write ended is the server's word, and is
/// taken as it comes.
///
/// ### Nominate
///
/// [GameNominated] sends the pool row's id and its game, and the date when
/// one was picked. Each answer:
///
/// - 2xx: the answer goes in at the head of the nominations, in place of any
///   row with its id, and nothing is read. The result follows the answer's
///   status: open, awaitingApproval, inLineup for an approved or a passed one
///   (as under `GameAdditionMode.direct`), and settled for any other. So the
///   outcome says what the server did with it, whatever rules the date has
///   (#517).
/// - A 403: refused.
/// - A 409: supplierNotGoing: the pool row's supplier isn't attending.
/// - A 400: notSupplied: the pool row doesn't supply the game.
/// - A 404: gone: the event, the date or the pool row is gone. The
///   nominations are read again.
/// - Anything else, a 429 among them: failed. The nominations are read
///   again, as they are after an answer the session drops (below): the
///   server may have saved it, and it takes the same row twice for one
///   choice, so the read shows a nomination that landed before the user
///   nominates it again.
///
/// ### A vote
///
/// [NominationVoteCast] sends the vote, and the note when there is one. Its
/// 2xx carries no row, so after a done or a closed the nomination is read
/// again by itself, and the write stays out until that read answers. No
/// other answer reads anything:
///
/// - 2xx: done, carrying the vote cast. The row read replaces the one held.
/// - A 400: closed: the nomination isn't open for votes now. The row read
///   replaces the one held.
/// - A 403: refused.
/// - A 404: gone, and the row is dropped.
/// - Anything else, a 429 among them: failed.
///
/// When the nomination's own read fails, or the session stops it, the
/// outcome comes in at once and the whole list is read instead.
///
/// ### Withdrawing
///
/// [NominationWithdrawn] withdraws the viewer's nomination. Each answer:
///
/// - 2xx: done. The answer replaces the row, and nothing is read.
/// - A 400: notWithdrawable: its status doesn't allow it now. The nomination
///   is read again as after a vote, the write staying out until it answers.
/// - A 403: refused.
/// - A 404: gone, and the row is dropped.
/// - Anything else, a 429 among them: failed.
///
/// ## A dropped write
///
/// [NominationWriteDropped] is a write the screen's own re-check stopped. It
/// sends nothing and sets an outcome of dropped for that write, with the
/// title, since a screen reader hears nothing happen when a press sends
/// nothing. It clears the last outcome first, as a write starting does, so a
/// drop like the one before it is still a new outcome. It is ignored while a
/// write is out, whose own outcome says what happened.
///
/// ## The session
///
/// On web every tab shares one session cookie, and a sign-in in another tab
/// moves it to another user under this screen (#432). So `confirmSession` is
/// asked before each send and before each read, the nomination's own read
/// included. A null `confirmSession`, as on native, is always yes. A no, or a
/// throw, sends nothing: a write ends as failed, and a read as above.
///
/// An answer is about whoever the session was as it went out, so the session
/// is asked again before an answer is used: a read's, a nominate's and a
/// withdrawal's, and a vote's or a withdrawal's 404, which drops a row. A no
/// fails the read as above, and ends the write as failed, its answer unused,
/// since it could be another user's. A vote's 2xx carries nothing to use, so
/// its check is the one before the nomination's own read.
///
/// ## Closing
///
/// What closing stops is what the bloc emits, and the sends and reads a write
/// would start. A send that is out ends at the server. Bloc runs a request
/// added in the same turn as [close], and a handler's emits can come after
/// close has started, so a flag set first in [close] guards each emit and
/// each send.
class EventNominationsBloc
    extends Bloc<EventNominationsEvent, EventNominationsState> {
  EventNominationsBloc({
    required this._remote,
    this._confirmSession,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.nominations'),
       super(const EventNominationsState()) {
    // The default transformer, which runs requests concurrently, so a read
    // goes ahead while a write is out. The fields below keep one read out at
    // a time, and [EventNominationsState.busy] one write.
    on<EventNominationsRequested>(_onRequested);
    on<EventNominationsRetryRequested>(_onRetryRequested);
    on<GameNominated>(_onNominated);
    on<NominationVoteCast>(_onVoteCast);
    on<NominationWithdrawn>(_onWithdrawn);
    on<NominationWriteDropped>(_onWriteDropped);
    on<EventNominationsOutcomeDismissed>(_onOutcomeDismissed);
  }

  final EventRemoteDataSource _remote;
  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// Set once [close] starts. A send's or a read's answer can land after it,
  /// and emits nothing then.
  bool _closing = false;

  /// Whether a read is out, or asking the session before it goes.
  bool _reading = false;

  /// What to read once the read that is out ends: the event the latest
  /// request while it was out named.
  String? _readAgain;

  /// The event named last, by a request to read or a write that started. A
  /// write's read is for this one.
  late String _lastNamed;

  /// Whether a retry joined the reads running now, which
  /// [EventNominationsState.refreshing] says until they end.
  bool _retrying = false;

  /// The changes writes made to the rows since the read that is out started,
  /// in order. Its answer can predate them, so they are made again on it.
  final List<_Change> _changedSinceRead = [];

  Future<void> _onRequested(
    EventNominationsRequested event,
    Emitter<EventNominationsState> emit,
  ) => _read(_named(event.eventId), emit);

  Future<void> _onRetryRequested(
    EventNominationsRetryRequested event,
    Emitter<EventNominationsState> emit,
  ) {
    _retrying = true;
    // At once, before the session is asked, so the retry shows under way
    // from the press.
    if (!_closing) emit(state.copyWith(refreshing: true));
    return _read(_named(event.eventId), emit);
  }

  /// Notes [eventId] as the one named last, and answers it.
  String _named(String eventId) => _lastNamed = eventId;

  Future<void> _onNominated(
    GameNominated event,
    Emitter<EventNominationsState> emit,
  ) async {
    if (_closing || state.busy) return;

    _named(event.eventId);
    final game = event.game;
    _started((write: NominationWrite.nominate, id: game.id), emit);

    final (:result, :answer, :sent) = await _nominate(event);
    if (_closing) return;

    _ended(
      NominateOutcome(result, title: game.title),
      emit,
      change: answer == null ? null : _atHead(answer),
    );
    if (result == NominateResult.gone ||
        (sent && result == NominateResult.failed)) {
      await _read(_lastNamed, emit);
    }
  }

  /// Nominates [event]'s game once the session says yes, and answers how it
  /// ended, with the answer to use on a 2xx, and whether it was sent. Never
  /// throws.
  Future<({NominateResult result, EventNomination? answer, bool sent})>
  _nominate(GameNominated event) async {
    const notSent = (result: NominateResult.failed, answer: null, sent: false);
    const failed = (result: NominateResult.failed, answer: null, sent: true);
    if (!await _confirmed('Nominate not sent')) return notSent;
    if (_closing) return notSent;

    final EventNomination answer;
    try {
      answer = await _remote.nominate(
        event.eventId,
        platformGameId: event.game.platformGameId,
        suppliedFromId: event.game.id,
        occurrenceId: event.occurrenceId,
      );
    } on EventWriteConflictException catch (error) {
      if (error.statusCode == 409) {
        _logger.info(
          'Nominate refused: the supplier is not going',
          error: error,
        );
        return (
          result: NominateResult.supplierNotGoing,
          answer: null,
          sent: true,
        );
      }
      _logger.info(
        'Nominate refused: the pool row does not supply the game',
        error: error,
      );
      return (result: NominateResult.notSupplied, answer: null, sent: true);
    } on EventRemoteNotFoundException catch (error) {
      _logger.info(
        'Nominate found the event or the pool row gone',
        error: error,
      );
      return (result: NominateResult.gone, answer: null, sent: true);
    } on EventWriteRefusedException catch (error) {
      _logger.info('Nominate refused', error: error);
      return (result: NominateResult.refused, answer: null, sent: true);
    } on Object catch (error, stackTrace) {
      _logger.warn('Nominate failed', error: error, stackTrace: stackTrace);
      return failed;
    }
    if (!await _confirmed('Nominate answer dropped')) return failed;
    return (result: _nominated(answer.status), answer: answer, sent: true);
  }

  Future<void> _onVoteCast(
    NominationVoteCast event,
    Emitter<EventNominationsState> emit,
  ) async {
    if (_closing || state.busy) return;

    _named(event.eventId);
    final nomination = event.nomination;
    _started((write: NominationWrite.vote, id: nomination.id), emit);

    final result = await _vote(event);
    if (_closing) return;

    final outcome = VoteOutcome(
      result,
      title: nomination.title,
      voteType: result == VoteResult.done ? event.voteType : null,
    );
    switch (result) {
      case VoteResult.done || VoteResult.closed:
        await _endedReadingOne(nomination.id, outcome, emit);
      case VoteResult.gone:
        _ended(outcome, emit, change: _dropping(nomination.id));
      case VoteResult.refused || VoteResult.failed || VoteResult.dropped:
        _ended(outcome, emit);
    }
  }

  /// Casts [event]'s vote once the session says yes, and answers how it
  /// ended. Never throws.
  Future<VoteResult> _vote(NominationVoteCast event) async {
    if (!await _confirmed('Vote not sent')) return VoteResult.failed;
    if (_closing) return VoteResult.failed;

    try {
      await _remote.castVote(
        event.eventId,
        event.nomination.id,
        voteType: event.voteType,
        comment: event.comment,
      );
    } on EventWriteConflictException catch (error) {
      _logger.info('Vote refused: voting is closed', error: error);
      return VoteResult.closed;
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Vote found the nomination gone', error: error);
      // It drops the row, so it is used as an answer is.
      if (!await _confirmed('Vote answer dropped')) return VoteResult.failed;
      return VoteResult.gone;
    } on EventWriteRefusedException catch (error) {
      _logger.info('Vote refused', error: error);
      return VoteResult.refused;
    } on Object catch (error, stackTrace) {
      _logger.warn('Vote failed', error: error, stackTrace: stackTrace);
      return VoteResult.failed;
    }
    return VoteResult.done;
  }

  Future<void> _onWithdrawn(
    NominationWithdrawn event,
    Emitter<EventNominationsState> emit,
  ) async {
    if (_closing || state.busy) return;

    _named(event.eventId);
    final nomination = event.nomination;
    _started((write: NominationWrite.withdraw, id: nomination.id), emit);

    final (:result, :answer) = await _withdraw(event);
    if (_closing) return;

    final outcome = WithdrawOutcome(result, title: nomination.title);
    switch ((result, answer)) {
      case (WithdrawResult.done, final EventNomination answer):
        _ended(outcome, emit, change: _replacing(answer));
      case (WithdrawResult.notWithdrawable, _):
        await _endedReadingOne(nomination.id, outcome, emit);
      case (WithdrawResult.gone, _):
        _ended(outcome, emit, change: _dropping(nomination.id));
      case _:
        _ended(outcome, emit);
    }
  }

  /// Withdraws [event]'s nomination once the session says yes, and answers
  /// how it ended, with the answer to use on a 2xx. Never throws.
  Future<_Answered<WithdrawResult>> _withdraw(NominationWithdrawn event) async {
    const failed = (result: WithdrawResult.failed, answer: null);
    if (!await _confirmed('Withdrawal not sent')) return failed;
    if (_closing) return failed;

    final EventNomination answer;
    try {
      answer = await _remote.withdrawNomination(
        event.eventId,
        event.nomination.id,
      );
    } on EventWriteConflictException catch (error) {
      _logger.info('Withdrawal refused for the status now', error: error);
      return (result: WithdrawResult.notWithdrawable, answer: null);
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Withdrawal found the nomination gone', error: error);
      // It drops the row, so it is used as an answer is.
      if (!await _confirmed('Withdrawal answer dropped')) return failed;
      return (result: WithdrawResult.gone, answer: null);
    } on EventWriteRefusedException catch (error) {
      _logger.info('Withdrawal refused', error: error);
      return (result: WithdrawResult.refused, answer: null);
    } on Object catch (error, stackTrace) {
      _logger.warn('Withdrawal failed', error: error, stackTrace: stackTrace);
      return failed;
    }
    if (!await _confirmed('Withdrawal answer dropped')) return failed;
    return (result: WithdrawResult.done, answer: answer);
  }

  /// Emits [writing] as the write that is out, clearing the last outcome.
  void _started(
    NominationWriting writing,
    Emitter<EventNominationsState> emit,
  ) => emit(state.copyWith(writing: () => writing, outcome: () => null));

  /// Ends the write that is out with [outcome], in one state with [change]
  /// made to the rows when there is one. A change is noted for a read that
  /// is out, whose answer can predate it. A hidden or a gone shows no rows,
  /// so a change isn't made to them; the next read's answer takes it.
  void _ended(
    EventNominationsOutcome outcome,
    Emitter<EventNominationsState> emit, {
    _Change? change,
  }) {
    if (_closing) return;
    if (change != null) _changedSinceRead.add(change);
    final shown = switch (state.load) {
      EventNominationsLoad.hidden || EventNominationsLoad.gone => false,
      _ => true,
    };
    emit(
      state.copyWith(
        writing: () => null,
        nominations: change != null && shown
            ? List.unmodifiable(change(state.nominations))
            : null,
        outcome: () => outcome,
      ),
    );
  }

  /// Reads the nomination [id] again, then ends the write that is out with
  /// [outcome] and the row read in its place. When that read fails, ends it
  /// at once and reads the whole list instead.
  Future<void> _endedReadingOne(
    String id,
    EventNominationsOutcome outcome,
    Emitter<EventNominationsState> emit,
  ) async {
    final row = await _readOne(_lastNamed, id);
    if (_closing) return;

    if (row != null) {
      _ended(outcome, emit, change: _replacing(row));
      return;
    }
    _ended(outcome, emit);
    await _read(_lastNamed, emit);
  }

  /// Reads the nomination [nominationId] of the event [eventId] once the
  /// session says yes, and answers it, or null when the read failed or the
  /// session stopped it. Never throws.
  Future<EventNomination?> _readOne(String eventId, String nominationId) async {
    if (!await _confirmed('Nomination not read')) return null;
    if (_closing) return null;

    final EventNomination row;
    try {
      row = await _remote.fetchNomination(eventId, nominationId);
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Nomination read found it gone', error: error);
      return null;
    } on EventRemoteForbiddenException catch (error) {
      _logger.info('Nomination not shown to this viewer', error: error);
      return null;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Nomination read failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
    if (!await _confirmed('Nomination answer dropped')) return null;
    return row;
  }

  void _onWriteDropped(
    NominationWriteDropped event,
    Emitter<EventNominationsState> emit,
  ) {
    if (_closing || state.busy) return;
    // Cleared first, so a drop like the last is a state of its own, which a
    // screen draws, and a screen reader hears, as new. Only when there is
    // one: Bloc emits a state equal to the initial one if it is the first.
    if (state.outcome != null) emit(state.copyWith(outcome: () => null));
    final title = event.title;
    emit(
      state.copyWith(
        outcome: () => switch (event.write) {
          NominationWrite.nominate => NominateOutcome(
            NominateResult.dropped,
            title: title,
          ),
          NominationWrite.vote => VoteOutcome(VoteResult.dropped, title: title),
          NominationWrite.withdraw => WithdrawOutcome(
            WithdrawResult.dropped,
            title: title,
          ),
        },
      ),
    );
  }

  /// Reads the nominations of the event [eventId], then again for the latest
  /// request that came in meanwhile, once each run. While a read is out, this
  /// marks one more and returns. Never throws.
  Future<void> _read(
    String eventId,
    Emitter<EventNominationsState> emit,
  ) async {
    if (_reading) {
      _readAgain = eventId;
      return;
    }
    _reading = true;
    try {
      String? next = eventId;
      while (next != null && !_closing) {
        _readAgain = null;
        await _readOnce(next, emit);
        next = _readAgain;
      }
    } finally {
      _readAgain = null;
      _reading = false;
      _retrying = false;
    }
  }

  /// Reads the nominations of the event [eventId] once the session says yes,
  /// and fails the read when the session says no. Never throws.
  Future<void> _readOnce(
    String eventId,
    Emitter<EventNominationsState> emit,
  ) async {
    _changedSinceRead.clear();
    // Only reads change the load, and one is out at a time, so this is the
    // load the read started in.
    final startedGone = state.load == EventNominationsLoad.gone;
    if (!await _confirmed('Nominations not read')) {
      _readEnded(EventNominationsLoad.failed, state.nominations, emit);
      return;
    }
    if (_closing) return;

    emit(
      state.copyWith(
        load: switch (state.load) {
          EventNominationsLoad.hidden ||
          EventNominationsLoad.gone => state.load,
          _ => EventNominationsLoad.loading,
        },
        refreshing: _retrying,
      ),
    );

    final List<EventNomination> nominations;
    try {
      nominations = await _remote.fetchNominations(eventId);
    } on EventRemoteForbiddenException catch (error) {
      _logger.info('Nominations not shown to this viewer', error: error);
      await _readRefused(EventNominationsLoad.hidden, emit);
      return;
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Nominations read found the event gone', error: error);
      // The event's read since then didn't settle it, so these are
      // nominations the server won't serve, not an event that went.
      await _readRefused(
        startedGone ? EventNominationsLoad.failed : EventNominationsLoad.gone,
        emit,
      );
      return;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Nominations read failed',
        error: error,
        stackTrace: stackTrace,
      );
      _readEnded(EventNominationsLoad.failed, state.nominations, emit);
      return;
    }
    if (!await _confirmed('Nominations answer dropped')) {
      _readEnded(EventNominationsLoad.failed, state.nominations, emit);
      return;
    }
    if (_closing) return;

    emit(
      state.copyWith(
        load: EventNominationsLoad.loaded,
        nominations: List.unmodifiable(
          _changedSinceRead.fold<List<EventNomination>>(
            nominations,
            (rows, change) => change(rows),
          ),
        ),
        refreshFailed: false,
        refreshing: _stillRefreshing,
      ),
    );
  }

  /// Ends a read the server refused as [load], or as failed if the session
  /// has moved since, when the refusal was another user's.
  Future<void> _readRefused(
    EventNominationsLoad load,
    Emitter<EventNominationsState> emit,
  ) async {
    if (await _confirmed('Nominations answer dropped')) {
      _readEnded(load, const [], emit);
    } else {
      _readEnded(EventNominationsLoad.failed, state.nominations, emit);
    }
  }

  /// Emits a read that ended without nominations as [load], showing
  /// [nominations].
  void _readEnded(
    EventNominationsLoad load,
    List<EventNomination> nominations,
    Emitter<EventNominationsState> emit,
  ) {
    if (_closing) return;
    emit(
      state.copyWith(
        load: load,
        nominations: nominations,
        refreshFailed: load == EventNominationsLoad.failed,
        refreshing: _stillRefreshing,
      ),
    );
  }

  /// Whether a retry is still under way as a read ends: one joined the
  /// reads, and another is to run after this one.
  bool get _stillRefreshing => _retrying && _readAgain != null;

  /// Whether the session is still this viewer's: `confirmSession` said yes,
  /// or there is none to ask. A no is logged, as is a throw, each saying
  /// what [stopped].
  Future<bool> _confirmed(String stopped) async {
    final confirm = _confirmSession;
    if (confirm == null) return true;

    final bool confirmed;
    try {
      confirmed = await confirm();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        '$stopped: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
    if (!confirmed) {
      _logger.info(
        "$stopped: the session could not be confirmed as this user's",
      );
    }
    return confirmed;
  }

  void _onOutcomeDismissed(
    EventNominationsOutcomeDismissed event,
    Emitter<EventNominationsState> emit,
  ) {
    if (state.outcome == null || _closing) return;
    emit(state.copyWith(outcome: () => null));
  }

  @override
  Future<void> close() {
    _closing = true;
    return super.close();
  }
}
