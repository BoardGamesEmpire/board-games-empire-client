import 'package:events/src/bloc/event_actions_state.dart';
import 'package:events/src/bloc/event_poll_event.dart';
import 'package:events/src/bloc/event_poll_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// A vote to send on one date: the event the screen showed when it was
/// tapped, and the answer.
typedef _Vote = ({String eventId, AvailabilityResponse response});

/// Reads the availability poll on an event's detail screen and sends the
/// viewer's votes (#507), beside the `EventActionsBloc` that sends the
/// host's date writes.
///
/// Votes go straight to the server, never through the sync queue (#527
/// queues them later). The summary is never cached: it lives in
/// [EventPollState.summary], read when the screen opens, after each detail
/// read, once a run of votes ends, and on a retry after a failed read. The
/// event's id travels with each request rather than with the bloc, as the
/// actions' requests do, since a reconcile can move it while the screen is
/// open (#499).
///
/// ## Reads
///
/// Each answer to the read, with the load and the summary it leaves:
///
/// - 2xx; load: loaded; summary: the one read.
/// - An enveloped 403; load: hidden: not shown to this viewer;
///   summary: cleared.
/// - An enveloped 404; load: gone: the screen reads the event,
///   which settles it; summary: cleared.
/// - Anything else; load: failed; summary: the last one, kept.
/// - None: the session said no, or threw (below); load: failed;
///   summary: the last one, kept.
/// - Any of the first three, once the session has moved (below);
///   load: failed; summary: the last one, kept.
///
/// A read after a hidden or a gone keeps that load until it answers, rather
/// than going through loading, so what a refused viewer sees doesn't change
/// for the length of each read.
///
/// One read is out at a time. A request while one is out marks one more to
/// run after it, for the event the latest request names, however many come
/// in. A read leaves [EventPollState.pending] as it is, except that a
/// successful one clears each answer it holds (below).
///
/// A failed read's [EventPollState.refreshFailed] stays while the next read
/// runs, and only a read that ends some other way clears it, as the
/// detail's does. [EventPollRetryRequested] is a read the user asked for:
/// [EventPollState.refreshing] says so from the request until the reads it
/// joined have ended. So a screen can keep its failed banner and the retry
/// in it in place while the retry runs, and show it under way.
///
/// ## Votes
///
/// A tap shows in [EventPollState.pending] at once, and clears the last
/// banner, which described an earlier vote.
///
/// Votes on different dates go out together. On one date the latest tap
/// wins: while the date's vote is out, a tap replaces the answer queued
/// behind it, which goes out when that vote ends. So three quick taps send
/// two requests, the first and the last, and the server ends on the last.
///
/// The answers map as the actions' date writes do:
///
/// - 2xx; outcome: none: done isn't announced; pending: kept until a read
///   holds it; an answer queued behind it: sent; event read again: no.
/// - An enveloped 400; outcome: changed: the date isn't proposed now;
///   pending: dropped; an answer queued behind it: dropped; event read
///   again: yes.
/// - An enveloped 403; outcome: refused; pending: dropped; an answer queued
///   behind it: dropped; event read again: yes.
/// - An enveloped 404; outcome: gone: the date or its event; pending:
///   dropped; an answer queued behind it: dropped; event read again: yes.
/// - Anything else; outcome: failed; pending: dropped; an answer queued
///   behind it: sent, and the failure isn't announced; event read again: no.
/// - The session said no; outcome: failed, with no error; pending: dropped;
///   an answer queued behind it: dropped; event read again: no.
///
/// [EventActionOutcome.rereads] says which, and the screen starts the event
/// read.
///
/// A failure gives way to an answer queued behind it: the latest tap's own
/// end decides the banner. A 400, 403 or 404 drops the queued answer, which
/// the server would refuse for the same reason, and so does a session that
/// said no, which would say it again.
///
/// Once no vote is out or queued on any date, the run of votes has ended,
/// and the poll is read once, however it ended. A vote changes no event
/// status, so it reads the poll again, not the event.
///
/// A done answer stays pending until a read that went out after the vote
/// was answered succeeds. One that went out earlier, such as the screen's
/// read after a detail read, may not hold it, even if it lands after the
/// vote is answered. So each done answer takes the next number of a count,
/// and each read notes the count as it goes out: it clears an answer
/// numbered at or below that, unless the date has been tapped since.
///
/// ## The session
///
/// On web every tab shares one session cookie, and a sign-in in another tab
/// moves it to another user under this screen (#432). So `confirmSession` is
/// asked before each vote goes out, a queued one included, and before each
/// read, as the actions ask it. A null `confirmSession`, as on native, is
/// always yes. A no, or a throw, sends nothing: a vote is failed with no
/// error, and a read is failed, keeping the last summary, as the detail's
/// read is. A page waiting on the read would otherwise wait for ever, and a
/// retry can ask again.
///
/// A read's answer is about whoever the session was as it went out, so the
/// session is asked again before the answer is used, as the detail's read
/// asks before it writes or forgets. A no fails the read the same way: another
/// user's votes never reach this screen, nor another user's refusal.
///
/// ## Closing
///
/// Closing stops no vote. One that is out ends, and an answer queued behind
/// it still goes, since it is the answer the viewer last saw on the date.
/// What closing stops is what the bloc emits, and the read a run of votes
/// would start. Bloc runs a request added in the same turn as [close], and a
/// handler's emits can come after close has started, so a flag set first in
/// [close] guards each emit.
class EventPollBloc extends Bloc<EventPollEvent, EventPollState> {
  EventPollBloc({
    required this._remote,
    this._confirmSession,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.poll'),
       super(const EventPollState()) {
    // The default transformer, which runs requests concurrently, so votes
    // on different dates go out together. The fields below keep one read,
    // and one vote per date, out at a time.
    on<EventPollRequested>(_onRequested);
    on<EventPollRetryRequested>(_onRetryRequested);
    on<EventPollVoted>(_onVoted);
    on<EventPollOutcomeDismissed>(_onOutcomeDismissed);
  }

  final EventRemoteDataSource _remote;
  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// Set once [close] starts. A vote's or a read's answer can land after it,
  /// and emits nothing then.
  bool _closing = false;

  /// Whether a read is out, or asking the session before it goes.
  bool _reading = false;

  /// The event to read once the read that is out ends: the one the latest
  /// request while it was out named.
  String? _readAgain;

  /// Whether a retry joined the reads running now, which
  /// [EventPollState.refreshing] says until they end.
  bool _retrying = false;

  /// The dates with a vote out, or asking the session before it goes. Each
  /// date's handler sends the date's votes until none is queued.
  final Set<String> _sending = {};

  /// The answer to send on a date once its vote out ends: the latest tap's.
  final Map<String, _Vote> _queued = {};

  /// How many votes have been answered done, counting up.
  int _answered = 0;

  /// For each date whose pending answer was answered done, where that
  /// answer fell in [_answered]'s count. A date is left out while a vote on
  /// it is out or queued.
  final Map<String, int> _answeredAt = {};

  Future<void> _onRequested(
    EventPollRequested event,
    Emitter<EventPollState> emit,
  ) => _read(event.eventId, emit);

  Future<void> _onRetryRequested(
    EventPollRetryRequested event,
    Emitter<EventPollState> emit,
  ) {
    _retrying = true;
    // At once, before the session is asked, so the retry shows under way
    // from the press.
    if (!_closing) {
      emit(
        EventPollState(
          load: state.load,
          summary: state.summary,
          pending: state.pending,
          outcome: state.outcome,
          refreshFailed: state.refreshFailed,
          refreshing: true,
        ),
      );
    }
    return _read(event.eventId, emit);
  }

  Future<void> _onVoted(
    EventPollVoted event,
    Emitter<EventPollState> emit,
  ) async {
    final date = event.occurrenceId;
    var vote = (eventId: event.eventId, response: event.response);

    // Before anything is awaited. A read out now went before this answer,
    // so the date's place in the count goes until this vote is done, and
    // that read can't clear it.
    _answeredAt.remove(date);
    if (!_closing) {
      emit(
        EventPollState(
          load: state.load,
          summary: state.summary,
          pending: Map.unmodifiable({...state.pending, date: event.response}),
          refreshFailed: state.refreshFailed,
          refreshing: state.refreshing,
        ),
      );
    }

    if (!_sending.add(date)) {
      // The date's vote is out, and its handler sends this when it ends.
      _queued[date] = vote;
      return;
    }

    // This handler sends the date's votes until none is queued, so each
    // end emits while its emitter is live.
    while (true) {
      final outcome = await _send(date, vote);
      final queued = _queued.remove(date);
      if (queued != null && _givesWay(outcome)) {
        vote = queued;
        continue;
      }
      _settle(date, outcome, emit);
      break;
    }
    _sending.remove(date);

    if (_sending.isEmpty && !_closing) await _read(vote.eventId, emit);
  }

  /// Whether a vote that ended as [outcome] gives way to an answer queued
  /// behind it: it was done, or it failed in a way that says nothing about
  /// the next one. A 400, 403 or 404 would meet the queued answer too, and a
  /// session that said no would say it again.
  static bool _givesWay(EventActionOutcome outcome) => switch (outcome.result) {
    EventActionResult.done => true,
    EventActionResult.failed => outcome.error != null,
    EventActionResult.changed ||
    EventActionResult.gone ||
    EventActionResult.refused ||
    EventActionResult.partlyDone => false,
  };

  /// Settles [date] after its last vote ended as [outcome]: done stays
  /// pending, numbered for the reads, and anything else drops the date's
  /// answer and is announced.
  void _settle(
    String date,
    EventActionOutcome outcome,
    Emitter<EventPollState> emit,
  ) {
    if (outcome.result == EventActionResult.done) {
      _answeredAt[date] = ++_answered;
      return;
    }
    if (_closing) return;
    emit(
      EventPollState(
        load: state.load,
        summary: state.summary,
        pending: _pendingWithout({date}),
        outcome: outcome,
        refreshFailed: state.refreshFailed,
        refreshing: state.refreshing,
      ),
    );
  }

  /// Sends [vote] on [date] once the session says yes, and answers how it
  /// ended. Never throws.
  Future<EventActionOutcome> _send(String date, _Vote vote) async {
    EventActionOutcome ended(EventActionResult result, [Object? error]) =>
        EventActionOutcome(
          action: EventAction.voteAvailability,
          result: result,
          error: error,
        );

    if (!await _confirmed('Vote not sent')) {
      return ended(EventActionResult.failed);
    }

    try {
      await _remote.submitAvailability(vote.eventId, date, vote.response);
    } on EventWriteConflictException catch (error) {
      _logger.info('Vote refused for the date as it is now', error: error);
      return ended(EventActionResult.changed, error);
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Vote found the date or its event gone', error: error);
      return ended(EventActionResult.gone, error);
    } on EventWriteRefusedException catch (error) {
      _logger.info('Vote refused', error: error);
      return ended(EventActionResult.refused, error);
    } on Object catch (error, stackTrace) {
      _logger.warn('Vote failed', error: error, stackTrace: stackTrace);
      return ended(EventActionResult.failed, error);
    }
    return ended(EventActionResult.done);
  }

  /// Reads the poll on [eventId], then again for each request that came in
  /// meanwhile, once each run. While a read is out, this marks one more and
  /// returns. Never throws.
  Future<void> _read(String eventId, Emitter<EventPollState> emit) async {
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

  /// Reads the poll on [eventId] once the session says yes, and fails it
  /// when the session says no. Never throws.
  Future<void> _readOnce(String eventId, Emitter<EventPollState> emit) async {
    if (!await _confirmed('Poll not read')) {
      _readEnded(EventPollLoad.failed, state.summary, emit);
      return;
    }
    if (_closing) return;

    // Every answer counted so far was in before this read goes out, so the
    // summary it brings holds it.
    final holds = _answered;
    emit(
      EventPollState(
        load: switch (state.load) {
          EventPollLoad.hidden || EventPollLoad.gone => state.load,
          _ => EventPollLoad.loading,
        },
        summary: state.summary,
        pending: state.pending,
        outcome: state.outcome,
        refreshFailed: state.refreshFailed,
        refreshing: _retrying,
      ),
    );

    final AvailabilitySummary summary;
    try {
      summary = await _remote.fetchAvailabilitySummary(eventId);
    } on EventRemoteForbiddenException catch (error) {
      _logger.info('Poll not shown to this viewer', error: error);
      await _readRefused(EventPollLoad.hidden, emit);
      return;
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Poll read found the event gone', error: error);
      await _readRefused(EventPollLoad.gone, emit);
      return;
    } on Object catch (error, stackTrace) {
      _logger.warn('Poll read failed', error: error, stackTrace: stackTrace);
      _readEnded(EventPollLoad.failed, state.summary, emit);
      return;
    }
    if (!await _confirmed('Poll answer dropped')) {
      _readEnded(EventPollLoad.failed, state.summary, emit);
      return;
    }
    if (_closing) return;

    final held = {
      for (final MapEntry(key: date, value: number) in _answeredAt.entries)
        if (number <= holds) date,
    };
    _answeredAt.removeWhere((date, _) => held.contains(date));
    emit(
      EventPollState(
        load: EventPollLoad.loaded,
        summary: summary,
        pending: _pendingWithout(held),
        outcome: state.outcome,
        refreshing: _stillRefreshing,
      ),
    );
  }

  /// Ends a read the server refused as [load], or as failed if the session
  /// has moved since, when the refusal was another user's.
  Future<void> _readRefused(
    EventPollLoad load,
    Emitter<EventPollState> emit,
  ) async {
    if (await _confirmed('Poll answer dropped')) {
      _readEnded(load, null, emit);
    } else {
      _readEnded(EventPollLoad.failed, state.summary, emit);
    }
  }

  /// Emits a read that ended without a summary as [load], showing [summary].
  void _readEnded(
    EventPollLoad load,
    AvailabilitySummary? summary,
    Emitter<EventPollState> emit,
  ) {
    if (_closing) return;
    emit(
      EventPollState(
        load: load,
        summary: summary,
        pending: state.pending,
        outcome: state.outcome,
        refreshFailed: load == EventPollLoad.failed,
        refreshing: _stillRefreshing,
      ),
    );
  }

  /// Whether a retry is still under way as a read ends: one joined the
  /// reads, and another is to run after this one.
  bool get _stillRefreshing => _retrying && _readAgain != null;

  /// [EventPollState.pending] without [dates], unmodifiable.
  Map<String, AvailabilityResponse> _pendingWithout(Set<String> dates) =>
      Map.unmodifiable({
        for (final MapEntry(key: date, value: response)
            in state.pending.entries)
          if (!dates.contains(date)) date: response,
      });

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
    EventPollOutcomeDismissed event,
    Emitter<EventPollState> emit,
  ) {
    if (state.outcome == null || _closing) return;
    emit(
      EventPollState(
        load: state.load,
        summary: state.summary,
        pending: state.pending,
        refreshFailed: state.refreshFailed,
        refreshing: state.refreshing,
      ),
    );
  }

  @override
  Future<void> close() {
    _closing = true;
    return super.close();
  }
}
