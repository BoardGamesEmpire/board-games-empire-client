import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../detail/event_actions.dart';
import 'event_detail_event.dart';
import 'event_detail_state.dart';

/// Drives the event detail screen (#498): one cached event, read from the
/// server once per open and written back, plus its household's name and
/// what the viewer may do to it.
///
/// The overview's design: the screen's state is a function of the cache and
/// of the read, and the cache stream ends in two ways that are not events.
/// The read never reaches the screen itself. It writes to the cache, and the
/// watch delivers what it wrote.
///
/// The first row that matches decides:
///
/// | cache | the read | state |
/// |---|---|---|
/// | any | 404, and nothing written since | not found, for the bloc's life or until a follow |
/// | a detail | any other | ready: a populated cache is never hidden |
/// | null | 404, its forget running | not found |
/// | null or an error | succeeded, and no answer since its write | loading |
/// | null or an error | the user's, running | error, `refreshing` |
/// | null or an error | the open's, running | loading |
/// | an error | any other | error, `refreshing` while a retry reads it again |
/// | nothing yet | not started | loading |
/// | null | failed | error |
/// | null | succeeded, overtaken, or never run | not found |
/// | ended | any | error where the rows above say loading, else theirs |
///
/// "The cache" is its latest answer. A cache error, logged, leaves the
/// detail it last delivered on screen, and is a row of its own only where
/// there is none and no read is running. Drift keeps a stream open after a
/// failed query, so the next write delivers on the same subscription, and
/// a running read settles the screen as it would have without the error:
/// an error over it would offer a retry the read refuses.
///
/// [EventDetailReady.refreshFailed] says the last read to finish failed,
/// so the detail is the cache's. A read starting does not clear it; one
/// succeeding does.
///
/// [EventDetailReady.reading] says a read is running, the open's included,
/// which `refreshing` leaves out. A read runs until it settles, and one that
/// succeeds settles after its write has reached the cache. The screen holds
/// Delete on it, so that a read's answer cannot cache the event again after
/// the delete (#501).
///
/// ## The read on open
///
/// Every open reads the event (#498), on the cache's first answer. Waiting
/// for it lets the bloc see first whether the event is local-only, created
/// offline under an id the server has never heard of. Such an event is never
/// read, by the open or by a retry, since the server would answer 404 and
/// the 404 would forget it. A null [remote] means there is no server to ask,
/// so the read counts as never run.
///
/// A read that succeeds while the cache holds nothing stays loading until the
/// cache next answers. The bloc hears the read settle before the watch has
/// read back what it wrote, so the null it still holds is from before the
/// write: not found there would flash on every open of an uncached event.
/// The write adds `read` access, so that answer is the event. Only a null
/// arriving after it is not found.
///
/// A read whose write fails is a failed read: the server's answer never
/// reached the cache, and the screen shows only the cache.
///
/// ## An event created on this device (#499)
///
/// An event created here is cached under a local id until the sync queue
/// delivers its create. The reconcile then deletes the local event and
/// caches the server's copy under the id the server gave it. To the watch on
/// the local id that is the event going, as a null, which the screen must
/// not show as not found.
///
/// So each cache answer first asks [EventRepository.reconciledEventId]
/// whether the id has moved. The repository reads the moves before it
/// delivers an answer, so the one that drops the local event finds the move,
/// whichever tab ran the reconcile. The bloc then follows it as though it
/// had been opened on the server's id. It watches that id instead, and drops
/// whatever the local id's watch or a read of the local id still delivers.
/// The server id's first answer starts the open's read, as any open's
/// does. The reconcile has cached the server's copy by then, but the
/// create's answer embeds each attendee's role and not their user, so the
/// read is what names the roster. The local event stays on screen until the
/// server's copy replaces it, so the screen passes through neither a spinner
/// nor not found. A bloc built on the local id after the move follows it on
/// its first answer, and reads only the server's id.
///
/// A replay of a create whose event was deleted since records no move: the
/// local event goes, and the detail settles on not found. An open on the
/// local event reads nothing, since the local-only flag outlasts the null.
///
/// ## A roster the read withholds
///
/// A friend, a household guest or anyone reading a Public event reads an
/// empty roster, which says they may not see who is coming (#498). The
/// cache keeps no rows for it, so over an event with no cached roster it
/// reads the roster back as null, which the screen says is not loaded yet.
/// So while the latest read to succeed carried an empty roster, a null
/// roster on the cache is shown as empty. A roster the cache does hold,
/// empty or not, wins, and the attendance stays the cache's. A read that
/// succeeds with someone on the roster ends it.
///
/// The bloc holds this, not the cache, so it lasts the bloc's life and no
/// longer: the screen opened again offline says the roster is not loaded
/// until a read answers.
///
/// ## A 404
///
/// The server no longer serves this user the event, so the bloc forgets it
/// ([EventRepository.forgetEvent]), and it leaves the overview at once
/// rather than on the next hydrate. While the forget runs, the screen shows
/// what the cache holds, and not found once the forget's null reaches it, so
/// it never passes through a spinner. Not found then holds for the bloc's
/// life, bar a follow of a reconcile (#499), which starts the outcome over:
/// what the cache says afterwards is not a new answer from the server.
/// A forget that fails is logged, and the event is not found all the same.
///
/// The forget takes the cache's [EventRepository.lastWrite], read before the
/// request went out, and leaves alone an event written since. The read runs
/// on after the screen closes, so its 404 can land after the event was
/// opened again and cached, or after a hydrate cached it for a user invited
/// back. That write is newer than the 404, and wins on screen too: the read
/// is overtaken, and the screen shows the cache as though the read had never
/// run. A 404 over nothing cached forgets nothing, and is overtaken the same
/// way by a write that lands while it is out.
///
/// Every other failure, a 403 included, is a failed read: only a 404 is an
/// answer about this event.
///
/// ## The session
///
/// On web every tab shares one session cookie, and a sign-in in another tab
/// moves it to another user under this screen (#432). A read sent then is
/// answered for that user: its event would be cached as this user's, and its
/// 404 would forget this user's. So [confirmSession] is asked before the
/// request goes out and again before its answer is written or forgotten, as
/// the hydrate asks before a pass and before each page. A no, or a throw, is
/// a failed read. A null [confirmSession], as on native, is always yes.
///
/// ## The retry
///
/// [EventDetailRetryRequested] runs the read again, and the state says so
/// while it runs: `refreshing` on the detail, or on the error it was pressed
/// on, which stays up rather than giving way to a spinner. It does nothing
/// while a read is running, in not found, for a local-only event, without a
/// [remote], or once the cache has ended, since its repository is gone.
/// The ready and error states' `canRetry` says when it would, for the screen
/// to draw its button. It leaves out the running read, which shows as one in
/// progress, and not found, which draws no retry.
///
/// A retry from a cache that failed before it ever answered reads the cache
/// again instead, on a new subscription: until it answers, nothing says
/// whether the event is local-only. Its answer starts the read, as the
/// open's would have.
///
/// ## A cache that ends
///
/// The user session's teardown closes the stream. A detail already shown
/// stays up while the auth redirect pops the route. A loading state becomes
/// an error: nothing will answer it, and the read's write can reach the
/// screen only through the cache.
///
/// ## The annotations
///
/// The household name comes from the latest [households] emission, and the
/// viewer's household role from [householdRole]. The role is asked for when
/// a household is first seen, and again on each [households] emission for
/// the event's own: right after sign-in the event can be cached before the
/// viewer's membership is, and a membership or role change reaches that
/// stream. The answer asked for last wins. Neither is waited on, so the
/// event is up before either arrives. A households error or a failed lookup
/// is logged, and a failed lookup leaves the last answer, or none. The
/// actions are recomputed from the event, the viewer's role on it and that
/// household role on each derivation ([eventActionsFor]).
class EventDetailBloc extends Bloc<EventDetailEvent, EventDetailState> {
  EventDetailBloc({
    required this._eventId,
    required this._repository,
    this._remote,
    this._confirmSession,
    Stream<List<Household>>? households,
    this._householdRole,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.detail'),
       super(const EventDetailLoading()) {
    on<EventDetailCacheUpdated>(_onCacheUpdated);
    on<EventDetailCacheFailed>(_onCacheFailed);
    on<EventDetailCacheEnded>(_onCacheEnded);
    on<EventDetailHouseholdsUpdated>(_onHouseholdsUpdated);
    on<EventDetailHouseholdRoleResolved>(_onHouseholdRoleResolved);
    on<EventDetailReadSettled>(_onReadSettled);
    on<EventDetailRetryRequested>(_onRetryRequested);

    _cache = _watchCache();

    _householdUpdates = households?.listen(
      (households) => add(EventDetailHouseholdsUpdated(households)),
      // The name annotates the header. Losing it must not lose the event,
      // and the last names read stay up.
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Event detail households stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  /// The id this detail watches and reads, which a reconcile can move
  /// (#499); see [_followReconcile].
  String _eventId;
  final EventRepository _repository;
  final EventRemoteDataSource? _remote;
  final Future<bool> Function()? _confirmSession;
  final Future<HouseholdRole?> Function(String householdId)? _householdRole;
  final BgeLogger _logger;

  late StreamSubscription<EventDetail?> _cache;
  StreamSubscription<List<Household>>? _householdUpdates;

  /// Whether the cache has delivered a value yet, which is not the same as
  /// having delivered a detail. A follow clears it, so that the server id's
  /// first answer is an open's.
  bool _cacheAnswered = false;

  /// The cache's latest value. A cache error leaves it as it was.
  EventDetail? _detail;

  /// Whether the event, as last delivered, was created offline. Kept apart
  /// from [_detail] so it outlasts a null, though not a follow: the server
  /// id's first answer decides it, null included.
  bool _localOnly = false;

  /// Set by a cache error, cleared by its next value.
  bool _cacheFailed = false;

  /// Set once the cache stream has ended, after which nothing reads it, or
  /// the server, again.
  bool _cacheEnded = false;

  /// Whether a retry is waiting on a cache read it started again, before
  /// the cache had ever answered.
  bool _cacheRetry = false;

  /// Whether a read is running, and whether the user asked for it.
  bool _reading = false;
  bool _userRead = false;

  /// How the last read to finish ended, or null before one has.
  EventDetailReadOutcome? _outcome;

  /// Set when a read's write lands, cleared by the cache's next answer: the
  /// window in which the cache's null is from before the write.
  bool _writePending = false;

  /// Whether the latest read to succeed carried an empty roster; see the
  /// class doc.
  bool _rosterWithheld = false;

  /// Each cached household's name, by id. Empty until the households
  /// stream emits, and for good when there is none.
  Map<String, String> _householdNames = const {};

  /// The viewer's role in each household asked about. A household asked
  /// about and not yet answered has no entry.
  final Map<String, HouseholdRole?> _householdRoles = {};

  /// How many lookups have been asked for each household, so an answer to
  /// any but the latest is dropped.
  final Map<String, int> _householdRoleLookups = {};

  /// Set once [close] starts. The read and the role lookup can end after
  /// it, and must add nothing: the event stream closes before [isClosed]
  /// says so.
  bool _closing = false;

  /// Whether a retry could read anything: there is a server to ask, the
  /// cache hasn't ended and the event isn't local-only. The states carry
  /// it, so the screen can't offer a button this bloc would ignore (#498).
  ///
  /// The other refusals aren't here. A read already running shows as one
  /// in progress, not found draws no retry, and a closing bloc's screen is
  /// already gone.
  bool get _canRetry => _remote != null && !_cacheEnded && !_localOnly;

  /// Whether a read the user asked for is still under way, or the cache read
  /// a retry started again.
  bool get _refreshing => (_reading && _userRead) || _cacheRetry;

  StreamSubscription<EventDetail?> _watchCache() {
    final eventId = _eventId;
    return _repository
        .watchEvent(eventId)
        .listen(
          (detail) => add(EventDetailCacheUpdated(detail, eventId: eventId)),
          onError: (Object error, StackTrace stackTrace) {
            _logger.warn(
              'Event detail cache read failed',
              error: error,
              stackTrace: stackTrace,
            );
            add(EventDetailCacheFailed(eventId: eventId));
          },
          onDone: () => add(const EventDetailCacheEnded()),
        );
  }

  void _onCacheUpdated(
    EventDetailCacheUpdated event,
    Emitter<EventDetailState> emit,
  ) {
    _followReconcile();
    // An answer about an id this detail has followed a move off: the one
    // that dropped the local event, or one sent before the move was known.
    // The server id's watch answers next, and the screen keeps what it
    // shows until then.
    if (event.eventId != _eventId) return;

    final detail = event.detail;
    final first = !_cacheAnswered;
    _cacheAnswered = true;
    _cacheFailed = false;
    _writePending = false;
    _detail = detail;
    if (detail != null) {
      _localOnly = detail.snapshot.event.isLocalOnly;
      _lookUpHouseholdRole(detail.snapshot.event.householdId);
    } else if (first) {
      // Set already only after a follow, and then it was the local event's.
      _localOnly = false;
    }

    if (first) {
      // A retry that read the cache again started this read, so it is the
      // user's.
      final asked = _cacheRetry;
      _cacheRetry = false;
      _startRead(asked: asked);
    }

    _emitDerived(emit);
  }

  /// Moves this detail onto the id a reconcile moved its event to, if one
  /// has (#499), as though it had been opened on that id: it watches that id
  /// instead, and its first answer starts the open's read.
  ///
  /// Asked on every cache answer, since the reconcile can land at any point
  /// in the detail's life, and the repository reads the moves before it
  /// delivers one, in whichever tab the reconcile ran.
  ///
  /// What the bloc knew of the old id's reads goes with it: whether one is
  /// running, how the last ended, a write waiting on the cache and a
  /// withheld roster. The local event is never read, so these are only ever
  /// set for a local id read before its move, whose answer is about that id
  /// alone. The detail and the cache's failure stay, so the screen keeps
  /// what it shows, and a retry the user pressed keeps its read theirs.
  void _followReconcile() {
    if (_closing) return;
    final movedTo = _repository.reconciledEventId(_eventId);
    if (movedTo == null) return;
    _eventId = movedTo;
    _cacheAnswered = false;
    _reading = false;
    _userRead = false;
    _outcome = null;
    _writePending = false;
    _rosterWithheld = false;
    final left = _cache;
    _cache = _watchCache();
    unawaited(left.cancel());
  }

  void _onCacheFailed(
    EventDetailCacheFailed event,
    Emitter<EventDetailState> emit,
  ) {
    // The local id's watch, failing after the move was followed.
    if (event.eventId != _eventId) return;
    _cacheFailed = true;
    _cacheRetry = false;
    // The cache's next answer, though not the one the write was waiting on.
    _writePending = false;
    _emitDerived(emit);
  }

  void _onCacheEnded(
    EventDetailCacheEnded event,
    Emitter<EventDetailState> emit,
  ) {
    _cacheEnded = true;
    _cacheRetry = false;
    _emitDerived(emit);
  }

  void _onHouseholdsUpdated(
    EventDetailHouseholdsUpdated event,
    Emitter<EventDetailState> emit,
  ) {
    _householdNames = {for (final h in event.households) h.id: h.name};
    final householdId = _detail?.snapshot.event.householdId;
    if (householdId != null) _lookUpHouseholdRole(householdId, again: true);
    _emitDerived(emit);
  }

  void _onHouseholdRoleResolved(
    EventDetailHouseholdRoleResolved event,
    Emitter<EventDetailState> emit,
  ) {
    _householdRoles[event.householdId] = event.role;
    _emitDerived(emit);
  }

  void _onReadSettled(
    EventDetailReadSettled event,
    Emitter<EventDetailState> emit,
  ) {
    // A read of an id this detail has followed a move off.
    if (event.eventId != _eventId) return;
    _reading = false;
    _userRead = false;
    _outcome = event.outcome;
    final succeeded = event.outcome == EventDetailReadOutcome.succeeded;
    _writePending = succeeded;
    // A failed read says nothing about the roster.
    if (succeeded) _rosterWithheld = event.rosterWithheld;
    _emitDerived(emit);
  }

  void _onRetryRequested(
    EventDetailRetryRequested event,
    Emitter<EventDetailState> emit,
  ) {
    if (_remote == null || _closing || _cacheEnded) return;
    // One read at a time, whoever started it.
    if (_reading || _cacheRetry) return;
    if (_localOnly || state is EventDetailNotFound) return;
    // A 404 whose forget is still deciding it.
    if (_outcome == EventDetailReadOutcome.forgetting) return;

    if (!_cacheAnswered) {
      // Still waiting on the cache's first answer, which starts the read.
      if (!_cacheFailed) return;
      _cacheRetry = true;
      final failed = _cache;
      _cache = _watchCache();
      unawaited(failed.cancel());
      return _emitDerived(emit);
    }

    _startRead(asked: true);
    _emitDerived(emit);
  }

  /// Starts a read of the event unless there is no server to ask or the
  /// event is local-only. [asked] says whether the user asked for it.
  void _startRead({required bool asked}) {
    final remote = _remote;
    if (remote == null || _localOnly || _closing) return;
    _reading = true;
    _userRead = asked;
    unawaited(_read(remote, _eventId));
  }

  /// Reads the event [eventId] and writes it to the cache as `read` access,
  /// or forgets it on a 404.
  ///
  /// Runs whether or not the screen is still open: a write or a forget is the
  /// server's answer either way. Only the settled event depends on it. It
  /// keeps to [eventId] when the bloc follows a move while it runs (#499), so
  /// a 404 for the local id never forgets the server's event.
  Future<void> _read(EventRemoteDataSource remote, String eventId) async {
    if (!await _confirmed()) {
      return _settle(eventId, EventDetailReadOutcome.failed);
    }

    int? lastWrite;
    final EventSnapshot snapshot;
    try {
      // Before the request goes out, so that a write landing while it is out
      // is one its 404 can't speak for.
      lastWrite = await _repository.lastWrite(eventId);
      snapshot = await remote.fetchEvent(eventId);
    } on EventRemoteNotFoundException {
      if (!await _confirmed()) {
        return _settle(eventId, EventDetailReadOutcome.failed);
      }
      // Settled before the forget starts, so the null its write puts on the
      // cache finds the screen on not found rather than a spinner. With
      // nothing cached there is nothing to forget, and no null coming.
      if (lastWrite != null) {
        _settle(eventId, EventDetailReadOutcome.forgetting);
      }
      return _settle(eventId, await _forget(eventId, lastWrite));
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Event detail read failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _settle(eventId, EventDetailReadOutcome.failed);
    }

    if (!await _confirmed()) {
      return _settle(eventId, EventDetailReadOutcome.failed);
    }
    try {
      await _repository.cacheEvent(snapshot, source: EventAccessSource.read);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Event detail read could not be written to the cache',
        error: error,
        stackTrace: stackTrace,
      );
      return _settle(eventId, EventDetailReadOutcome.failed);
    }

    _settle(
      eventId,
      EventDetailReadOutcome.succeeded,
      rosterWithheld: snapshot.attendees?.isEmpty ?? false,
    );
  }

  void _settle(
    String eventId,
    EventDetailReadOutcome outcome, {
    bool rosterWithheld = false,
  }) {
    if (_closing) return;
    add(
      EventDetailReadSettled(
        outcome,
        eventId: eventId,
        rosterWithheld: rosterWithheld,
      ),
    );
  }

  /// Whether the session is still this cache's user's: [confirmSession]
  /// said yes, or there is none to ask. A no is logged.
  Future<bool> _confirmed() async {
    final confirm = _confirmSession;
    if (confirm == null) return true;

    final bool confirmed;
    try {
      confirmed = await confirm();
    } on Object catch (error, stackTrace) {
      // The guard behind it never throws, but the read runs unawaited.
      _logger.warn(
        'Event detail read stopped: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
    if (!confirmed) {
      _logger.info(
        'Event detail read stopped: the session could not be confirmed as '
        'this user\'s',
      );
    }
    return confirmed;
  }

  /// Forgets [eventId], which a 404 answered for, unless the cache was
  /// written since [lastWrite] was read, and says which of the two the 404
  /// was.
  Future<EventDetailReadOutcome> _forget(String eventId, int? lastWrite) async {
    try {
      if (lastWrite != null &&
          await _repository.forgetEvent(eventId, lastWrite: lastWrite)) {
        return EventDetailReadOutcome.notFound;
      }
      // Declined, or nothing was cached to forget. A write since the request
      // went out names a new last write, and is newer than the 404. One that
      // isn't, for an event the sync queue owns say, leaves the 404 standing.
      return await _repository.lastWrite(eventId) == lastWrite
          ? EventDetailReadOutcome.notFound
          : EventDetailReadOutcome.overtaken;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Could not forget an event the server no longer serves',
        error: error,
        stackTrace: stackTrace,
      );
      return EventDetailReadOutcome.notFound;
    }
  }

  /// Asks for the viewer's role in [householdId] the first time it is seen,
  /// or [again] whether or not it has been.
  void _lookUpHouseholdRole(String? householdId, {bool again = false}) {
    final lookUp = _householdRole;
    if (lookUp == null || householdId == null || _closing) return;
    final asked = _householdRoleLookups[householdId] ?? 0;
    if (asked > 0 && !again) return;
    _householdRoleLookups[householdId] = asked + 1;
    unawaited(_resolveHouseholdRole(lookUp, householdId, asked + 1));
  }

  Future<void> _resolveHouseholdRole(
    Future<HouseholdRole?> Function(String householdId) lookUp,
    String householdId,
    int lookup,
  ) async {
    final HouseholdRole? role;
    try {
      role = await lookUp(householdId);
    } on Object catch (error, stackTrace) {
      // The household's actions are lost, not the event.
      _logger.warn(
        'Event detail household role lookup failed',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }
    if (_closing || _householdRoleLookups[householdId] != lookup) return;
    add(EventDetailHouseholdRoleResolved(householdId, role));
  }

  void _emitDerived(Emitter<EventDetailState> emit) => emit(_derive());

  /// The class doc's table, row by row.
  EventDetailState _derive() {
    if (_outcome == EventDetailReadOutcome.notFound) {
      return const EventDetailNotFound();
    }

    final detail = _detail;
    if (detail != null) return _ready(detail);
    // The forget's own null, or nothing newer yet.
    if (_outcome == EventDetailReadOutcome.forgetting) {
      return const EventDetailNotFound();
    }

    if (_writePending) return _waiting();
    if (_reading) return _userRead ? _error() : _waiting();
    if (_cacheFailed || _outcome == EventDetailReadOutcome.failed) {
      return _error();
    }
    if (!_cacheAnswered) return _waiting();
    return const EventDetailNotFound();
  }

  /// Loading while an answer can still arrive, and an error once the cache
  /// that would deliver it has ended.
  EventDetailState _waiting() =>
      _cacheEnded ? _error() : const EventDetailLoading();

  EventDetailError _error() =>
      EventDetailError(refreshing: _refreshing, canRetry: _canRetry);

  EventDetailReady _ready(EventDetail cached) {
    final detail = _rosterWithheld && cached.snapshot.attendees == null
        ? cached.copyWith.snapshot(attendees: const [])
        : cached;
    final event = detail.snapshot.event;
    final householdId = event.householdId;
    return EventDetailReady(
      detail: detail,
      householdName: householdId == null ? null : _householdNames[householdId],
      actions: eventActionsFor(
        event,
        eventRole: detail.attendance?.role,
        householdRole: householdId == null
            ? null
            : _householdRoles[householdId],
      ),
      refreshing: _refreshing,
      reading: _reading,
      refreshFailed: _outcome == EventDetailReadOutcome.failed,
      canRetry: _canRetry,
    );
  }

  @override
  Future<void> close() async {
    _closing = true;
    await _cache.cancel();
    await _householdUpdates?.cancel();
    return super.close();
  }
}
