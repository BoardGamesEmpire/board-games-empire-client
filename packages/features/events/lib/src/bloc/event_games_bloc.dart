import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// The event and the attendees a read of the pool names.
typedef _PoolRead = ({String eventId, List<String> attendeeIds});

/// How one pick of an offer run ended.
enum _Sent {
  /// On the list: offered now, or already.
  offered,

  /// Not offered, and the run goes on.
  skipped,

  /// Not offered, and the run stops as refused.
  refused,

  /// Not offered, and the run stops as failed.
  failed,
}

/// Reads the games pool on an event's Games tab, sends the viewer's offers
/// and takes a game back (#516).
///
/// Offers and take-backs go straight to the server, never through the sync
/// queue, and nothing is re-sent. The pool is never cached: it lives in
/// [EventGamesState.games]. The screen asks for a read the first time the
/// Games tab shows, after each detail read from then on, and when the user
/// retries a failed read. The bloc reads again as a run of offers ends,
/// however it ended, and as a take-back ends, unless the take-back failed,
/// which changed nothing the screen can know of. A write the screen's
/// re-check dropped reads nothing. The event's id and the roster's attendee
/// ids travel with each request rather than with the bloc, since a reconcile
/// can move the id while the screen is open (#499).
///
/// Reads and writes are independent: a read asked for while a write is out
/// goes ahead under the rules below, and doesn't wait for it.
///
/// ## Reads
///
/// Each answer to the read, with the load and the games it leaves:
///
/// - 2xx; load: loaded; games: the ones read.
/// - A 403 on any attendee's games; load: hidden: not shown to this viewer;
///   games: cleared.
/// - A 404: the event is gone, or everyone named left it; load: gone: the
///   screen reads the event, which settles it; games: cleared.
/// - Anything else; load: failed; games: the last ones, kept.
/// - None: the session said no, or threw (below); load: failed; games: the
///   last ones, kept.
/// - Any of the first three, once the session has moved (below); load:
///   failed; games: the last ones, kept.
///
/// A read after a hidden or a gone keeps that load until it answers, rather
/// than going through loading, so what a refused viewer sees doesn't change
/// for the length of each read.
///
/// One read is out at a time. A request while one is out marks one more to
/// run after it, for the event and the attendees the latest request names,
/// however many come in. A write's closing read is one more request like any
/// other.
///
/// A failed read's [EventGamesState.refreshFailed] stays while the next read
/// runs, and only a read that ends some other way clears it, as the detail's
/// does. [EventGamesRetryRequested] is a read the user asked for:
/// [EventGamesState.refreshing] says so from the request until the reads it
/// joined have ended. So a screen can keep its failed banner and the retry in
/// it in place while the retry runs, and show it under way.
///
/// ## An offer run
///
/// [EventGamesOffered] sends its picks one at a time, in order, never two at
/// once. It is ignored with no picks, or while a write is out
/// ([EventGamesState.busy]). As it starts it clears the last outcome, and
/// [EventGamesState.sending] is `(done: 0, total: n)`; after each pick is
/// settled, offered or not, `done` counts it.
///
/// Each send's answer, with what it makes of the pick and the run:
///
/// - 2xx; the pick: offered; the run: goes on.
/// - A 409: the game is already on the list; the pick: offered; the run:
///   goes on.
/// - A 400 conflict: the entry left the collection since, or a conflict with
///   any other status; or a 404: the pick's id is unknown now; the pick: not
///   offered; the run: goes on.
/// - A 403; the pick: not offered; the run: stops, refused.
/// - Anything else; the pick: not offered; the run: stops, failed.
/// - The session said no, or threw (below): nothing is sent; the pick: not
///   offered; the run: stops, failed.
///
/// The pick that stops a run isn't counted in `done`, and it and every pick
/// after it are not offered. The outcome counts both,
/// [EventGamesOutcome.offered] and [EventGamesOutcome.notOffered], which add
/// up to the picks. A stopped run keeps its refused or failed, whatever it
/// offered before it stopped. One that wasn't stopped is done when every
/// pick is offered, none when none is, and partly otherwise.
///
/// When the run ends, `sending` goes and the outcome comes in one state, and
/// then the pool is read again, however it ended.
///
/// ## Taking back
///
/// [EventGameTakenBack] is ignored while a write is out. As it starts it
/// clears the last outcome, and [EventGamesState.takingBack] holds the
/// offered game's id until the answer, which goes with the outcome's coming
/// in one state:
///
/// - 2xx, or a 404: the game is already off the pool; done.
/// - A 409: the game still supplies a nomination or a lineup;
///   stillSupplies.
/// - A 403; refused.
/// - Anything else, or the session said no or threw (below), when nothing is
///   sent; failed.
///
/// The outcome carries the game's title as the event carried it. Then the
/// pool is read again, unless the take-back failed, when the pool is as it
/// was.
///
/// ## A dropped write
///
/// [EventGamesWriteDropped] is a write the screen's own re-check stopped. It
/// sends nothing and sets an outcome of dropped for that write, with the
/// title when given, since a screen reader hears nothing happen when a press
/// sends nothing. It clears the last outcome first, as a write starting
/// does, so a drop like the one before it is still a new outcome. It is
/// ignored while a write is out, whose own outcome says what happened.
///
/// ## The session
///
/// On web every tab shares one session cookie, and a sign-in in another tab
/// moves it to another user under this screen (#432). So `confirmSession` is
/// asked before each send, each pick of a run included, and before each
/// read. A null `confirmSession`, as on native, is always yes. A no, or a
/// throw, sends nothing: a write ends as above, and a read is failed,
/// keeping the last games, as the detail's read is.
///
/// A read's answer is about whoever the session was as it went out, so the
/// session is asked again before the answer is used. A no fails the read the
/// same way: another user's pool never reaches this screen, nor another
/// user's refusal.
///
/// ## Closing
///
/// What closing stops is what the bloc emits, the sends a run has left, and
/// the read a write would start. A send that is out ends at the server.
/// Bloc runs a request added in the same turn as [close], and a handler's
/// emits can come after close has started, so a flag set first in [close]
/// guards each emit and each send.
class EventGamesBloc extends Bloc<EventGamesEvent, EventGamesState> {
  EventGamesBloc({
    required this._remote,
    this._confirmSession,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.games'),
       super(const EventGamesState()) {
    // The default transformer, which runs requests concurrently, so a read
    // goes ahead while a write is out. The fields below keep one read out at
    // a time, and [EventGamesState.busy] one write.
    on<EventGamesRequested>(_onRequested);
    on<EventGamesRetryRequested>(_onRetryRequested);
    on<EventGamesOffered>(_onOffered);
    on<EventGameTakenBack>(_onTakenBack);
    on<EventGamesWriteDropped>(_onWriteDropped);
    on<EventGamesOutcomeDismissed>(_onOutcomeDismissed);
  }

  final EventRemoteDataSource _remote;
  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// Set once [close] starts. A send's or a read's answer can land after it,
  /// and emits nothing then.
  bool _closing = false;

  /// Whether a read is out, or asking the session before it goes.
  bool _reading = false;

  /// What to read once the read that is out ends: what the latest request
  /// while it was out named.
  _PoolRead? _readAgain;

  /// Whether a retry joined the reads running now, which
  /// [EventGamesState.refreshing] says until they end.
  bool _retrying = false;

  Future<void> _onRequested(
    EventGamesRequested event,
    Emitter<EventGamesState> emit,
  ) => _read((eventId: event.eventId, attendeeIds: event.attendeeIds), emit);

  Future<void> _onRetryRequested(
    EventGamesRetryRequested event,
    Emitter<EventGamesState> emit,
  ) {
    _retrying = true;
    // At once, before the session is asked, so the retry shows under way
    // from the press.
    if (!_closing) emit(state.copyWith(refreshing: true));
    return _read((
      eventId: event.eventId,
      attendeeIds: event.attendeeIds,
    ), emit);
  }

  Future<void> _onOffered(
    EventGamesOffered event,
    Emitter<EventGamesState> emit,
  ) async {
    if (_closing || state.busy || event.picks.isEmpty) return;

    final total = event.picks.length;
    emit(
      state.copyWith(
        sending: () => (done: 0, total: total),
        outcome: () => null,
      ),
    );

    var offered = 0;
    var done = 0;
    EventGamesResult? stopped;
    for (final pick in event.picks) {
      final sent = await _offer(event, pick);
      if (_closing) return;
      switch (sent) {
        case _Sent.offered:
          offered++;
        case _Sent.skipped:
          break;
        case _Sent.refused:
          stopped = EventGamesResult.refused;
        case _Sent.failed:
          stopped = EventGamesResult.failed;
      }
      if (stopped != null) break;
      done++;
      emit(state.copyWith(sending: () => (done: done, total: total)));
    }

    final notOffered = total - offered;
    final result =
        stopped ??
        switch ((offered, notOffered)) {
          (_, 0) => EventGamesResult.done,
          (0, _) => EventGamesResult.none,
          _ => EventGamesResult.partly,
        };
    emit(
      state.copyWith(
        sending: () => null,
        outcome: () => EventGamesOutcome(
          write: EventGamesWrite.offer,
          result: result,
          offered: offered,
          notOffered: notOffered,
        ),
      ),
    );

    await _read(
      (eventId: event.eventId, attendeeIds: event.attendeeIds),
      emit,
    );
  }

  /// Offers [pick] for [event]'s attendee once the session says yes, and
  /// answers how it ended. Never throws.
  Future<_Sent> _offer(EventGamesOffered event, OfferPick pick) async {
    if (!await _confirmed('Offer not sent')) return _Sent.failed;
    // A run that sees close stops sending.
    if (_closing) return _Sent.failed;

    try {
      await _remote.offerGame(
        event.eventId,
        event.attendeeId,
        collectionId: pick.collectionId,
      );
    } on EventWriteConflictException catch (error) {
      if (error.statusCode == 409) {
        _logger.info('Offer found the game already offered', error: error);
        return _Sent.offered;
      }
      _logger.info('Offer refused for the entry as it is now', error: error);
      return _Sent.skipped;
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Offer found the entry or its event gone', error: error);
      return _Sent.skipped;
    } on EventWriteRefusedException catch (error) {
      _logger.info('Offer refused', error: error);
      return _Sent.refused;
    } on Object catch (error, stackTrace) {
      _logger.warn('Offer failed', error: error, stackTrace: stackTrace);
      return _Sent.failed;
    }
    return _Sent.offered;
  }

  Future<void> _onTakenBack(
    EventGameTakenBack event,
    Emitter<EventGamesState> emit,
  ) async {
    if (_closing || state.busy) return;

    final game = event.game;
    emit(state.copyWith(takingBack: () => game.id, outcome: () => null));

    final result = await _takeBack(event);
    if (_closing) return;

    emit(
      state.copyWith(
        takingBack: () => null,
        outcome: () => EventGamesOutcome(
          write: EventGamesWrite.takeBack,
          result: result,
          title: game.title,
        ),
      ),
    );

    // A failed take-back changed nothing the screen can know of.
    if (result == EventGamesResult.failed) return;
    await _read(
      (eventId: event.eventId, attendeeIds: event.attendeeIds),
      emit,
    );
  }

  /// Takes [event]'s game back once the session says yes, and answers how it
  /// ended. Never throws.
  Future<EventGamesResult> _takeBack(EventGameTakenBack event) async {
    if (!await _confirmed('Take-back not sent')) {
      return EventGamesResult.failed;
    }
    if (_closing) return EventGamesResult.failed;

    try {
      await _remote.takeBackGame(
        event.eventId,
        event.attendeeId,
        event.game.id,
      );
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Take-back found the game already gone', error: error);
      return EventGamesResult.done;
    } on EventWriteConflictException catch (error) {
      _logger.info('Take-back refused: the game still supplies', error: error);
      return EventGamesResult.stillSupplies;
    } on EventWriteRefusedException catch (error) {
      _logger.info('Take-back refused', error: error);
      return EventGamesResult.refused;
    } on Object catch (error, stackTrace) {
      _logger.warn('Take-back failed', error: error, stackTrace: stackTrace);
      return EventGamesResult.failed;
    }
    return EventGamesResult.done;
  }

  void _onWriteDropped(
    EventGamesWriteDropped event,
    Emitter<EventGamesState> emit,
  ) {
    if (_closing || state.busy) return;
    // Cleared first, so a drop like the last is a state of its own, which a
    // screen draws, and a screen reader hears, as new. Only when there is
    // one: Bloc emits a state equal to the initial one if it is the first.
    if (state.outcome != null) emit(state.copyWith(outcome: () => null));
    emit(
      state.copyWith(
        outcome: () => EventGamesOutcome(
          write: event.write,
          result: EventGamesResult.dropped,
          title: event.title,
        ),
      ),
    );
  }

  /// Reads the pool [read] names, then again for the latest request that
  /// came in meanwhile, once each run. While a read is out, this marks one
  /// more and returns. Never throws.
  Future<void> _read(_PoolRead read, Emitter<EventGamesState> emit) async {
    if (_reading) {
      _readAgain = read;
      return;
    }
    _reading = true;
    try {
      _PoolRead? next = read;
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

  /// Reads the pool [read] names once the session says yes, and fails it
  /// when the session says no. Never throws.
  Future<void> _readOnce(_PoolRead read, Emitter<EventGamesState> emit) async {
    if (!await _confirmed('Pool not read')) {
      _readEnded(EventGamesLoad.failed, state.games, emit);
      return;
    }
    if (_closing) return;

    emit(
      state.copyWith(
        load: switch (state.load) {
          EventGamesLoad.hidden || EventGamesLoad.gone => state.load,
          _ => EventGamesLoad.loading,
        },
        refreshing: _retrying,
      ),
    );

    final List<OfferedGame> games;
    try {
      games = await _remote.fetchGamesPool(
        read.eventId,
        attendeeIds: read.attendeeIds,
      );
    } on EventRemoteForbiddenException catch (error) {
      _logger.info('Pool not shown to this viewer', error: error);
      await _readRefused(EventGamesLoad.hidden, emit);
      return;
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Pool read found the event gone', error: error);
      await _readRefused(EventGamesLoad.gone, emit);
      return;
    } on Object catch (error, stackTrace) {
      _logger.warn('Pool read failed', error: error, stackTrace: stackTrace);
      _readEnded(EventGamesLoad.failed, state.games, emit);
      return;
    }
    if (!await _confirmed('Pool answer dropped')) {
      _readEnded(EventGamesLoad.failed, state.games, emit);
      return;
    }
    if (_closing) return;

    emit(
      state.copyWith(
        load: EventGamesLoad.loaded,
        games: List.unmodifiable(games),
        refreshFailed: false,
        refreshing: _stillRefreshing,
      ),
    );
  }

  /// Ends a read the server refused as [load], or as failed if the session
  /// has moved since, when the refusal was another user's.
  Future<void> _readRefused(
    EventGamesLoad load,
    Emitter<EventGamesState> emit,
  ) async {
    if (await _confirmed('Pool answer dropped')) {
      _readEnded(load, const [], emit);
    } else {
      _readEnded(EventGamesLoad.failed, state.games, emit);
    }
  }

  /// Emits a read that ended without games as [load], showing [games].
  void _readEnded(
    EventGamesLoad load,
    List<OfferedGame> games,
    Emitter<EventGamesState> emit,
  ) {
    if (_closing) return;
    emit(
      state.copyWith(
        load: load,
        games: games,
        refreshFailed: load == EventGamesLoad.failed,
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
    EventGamesOutcomeDismissed event,
    Emitter<EventGamesState> emit,
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
