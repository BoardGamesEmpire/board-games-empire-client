import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

import 'hydration_status.dart';

/// A feature's hydrate pass: its drain, run one at a time, behind the
/// session check, with the [HydrationStatus] driven around it (#407).
///
/// Every cached feature used to carry its own copy of this — a
/// single-flight in the hydrator, a `pass()` and a re-hydrate registration
/// in the installer — and the copies had begun to disagree. What stays with
/// the feature is everything about its data: the page loop, the per-page
/// session check, the purge, and which outcomes count as landed. The drain
/// is that loop, and this never looks inside it.
///
/// ## Nothing here throws
///
/// The feature's installer starts the first pass **unawaited** (#267), on
/// the sign-in path, where a throw signs the user out. So [run] reports
/// every failure as the feature's `failed` outcome, a guard or a drain that
/// throws included, and [settled] completes either way.
///
/// ## One drain at a time
///
/// A call made while a drain runs **joins** it, and gets that drain's
/// outcome, rather than starting a second. A drain deletes as well as
/// writes, and one drain's purge racing another's writes is a question this
/// means nobody has to answer. It is a concurrency guard, **not a cache**:
/// once a drain settles, the next call asks the server again (#302).
///
/// A call that joins does nothing else. It makes no session check of its
/// own, and it writes nothing to the status: the call that started the
/// drain reported [HydrationStatus.started], and the drain reports
/// [HydrationStatus.finished] once when it ends. So the status sees one
/// start and one finish per drain however many callers share it, and a
/// [HydrationStatus.markStale] made mid-drain holds until the next drain
/// starts. That is why a status needs no count of the passes still out
/// (#407): a count was only ever needed because a call could overlap a drain
/// without joining it, and with the check inside the single-flight a call
/// no longer can.
///
/// ## The session check sits inside the single-flight (#563)
///
/// Only a call that starts a drain asks the [SessionIdentityGuard] whether
/// the session is still this scope's user (#432), and it asks before the
/// drain's first request. A refusal ends that drain as `failed` with no
/// request sent. When the check ran before the join, a retry pressed during
/// another pass could be refused and report `failed` while that pass was
/// still draining. The status read `running → failed → refreshed` for one
/// drain, or, where it counted overlapping passes (#453), stayed `running`
/// but flagged the last pass failed while the drain ran. Inside it, a
/// refusal can only end a drain it started, and a call that joins reports
/// what the running drain reports.
///
/// No guard, as on native, is a confirmed session.
///
/// ## Registering to be re-run (#302)
///
/// [registerRehydrate] hands [run] to the session's [SessionRehydrator],
/// which the shell's triggers drive. Staleness is answered from the status
/// rather than remembered by the registry: `failed` or `idle` is worth
/// another pass, `running` is one already happening, and `refreshed` is not,
/// until it ages out of the feature's window. A registry holding its own
/// copy of that would be a second answer free to drift from the one the
/// screen reads.
///
/// A trigger that lands while a drain is `running` is therefore **dropped,
/// not joined**. Joining would change nothing — the trigger would get the
/// running drain's own outcome, not a fresh request — so the case worth
/// naming is a slow failure: a drain hanging on a socket timeout can
/// swallow the one connectivity edge the transport produces, and the status
/// stays at `failed` afterwards with nothing left to re-trigger it. That is
/// a failure-driven retry (#311), not something a staleness rule can
/// answer; a screen's manual retry covers it in the meantime.
final class HydratePass<O extends Object> {
  /// [feature] is the capitalised subject of the log lines (`'Household'`).
  /// [drain] is the feature's page loop, and [failed] the outcome reported
  /// for a drain that was held off or threw. [userId] is the scope's user,
  /// whom [guard] is asked about. [context] is merged into every log line.
  HydratePass({
    required this._feature,
    required this._drain,
    required this._status,
    required this._failed,
    required this._userId,
    required this._logger,
    this._guard,
    this._context = const {},
  });

  final String _feature;
  final Future<O> Function() _drain;
  final HydrationStatus<O> _status;
  final O _failed;
  final String _userId;
  final BgeLogger _logger;

  /// Null where nothing can move the session to another user, as on native.
  final SessionIdentityGuard? _guard;

  final Map<String, dynamic> _context;

  /// The drain in flight, or null when none is.
  Future<O>? _inFlight;

  /// Starts a drain, or joins the one in flight, and returns its outcome.
  ///
  /// Never throws — see the class doc.
  ///
  /// A call that starts a drain leaves the status `running` before it
  /// returns: an async body runs synchronously up to its first await, so a
  /// screen built before the drain's first turn cannot read idle (#269).
  Future<O> run() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    // The future stored is the one returned, so every caller of a drain
    // holds the same one, and none resumes before the clear has run: a
    // caller that awaits [settled] and then runs gets a drain that started
    // after the one it waited out ended. Identity-checked so a drain cannot
    // clear its successor.
    late final Future<O> pass;
    pass = _drainOnce().whenComplete(() {
      if (identical(_inFlight, pass)) _inFlight = null;
    });
    _inFlight = pass;
    return pass;
  }

  /// Completes once the drain in flight has ended: at once when none is,
  /// else when the running one ends. Never throws.
  ///
  /// For a caller that needs a drain started after a local write (#190):
  /// [run] alone would join the running drain, which may have read the
  /// written row's page already. A [run] after this gets a drain that
  /// started after that one ended, so it reads the set after the write.
  ///
  /// Not necessarily a drain of the caller's own. Callers of the ended
  /// drain resume in the order they started waiting, so one that was
  /// waiting before this caller can start the next drain first, and this
  /// caller's [run] then joins it.
  Future<void> get settled async {
    await _inFlight;
  }

  /// Waits out the drain in flight, if any, then runs: a drain that starts
  /// after this call, for a caller that has just written (#190). See
  /// [settled]. Never throws.
  ///
  /// Every feature's "a pass after this change" comes here, so the answer
  /// rests on which drain is in flight rather than on when the status
  /// reads `running`.
  Future<O> runAfterSettled() async {
    await settled;
    return run();
  }

  /// Registers [run] with the session's [SessionRehydrator] under [name]
  /// (#302). A `refreshed` status goes stale once it is [staleAfter] old;
  /// the class doc gives the other states.
  ///
  /// A composition without the seam is a no-op rather than a resolution
  /// failure: a throw here aborts the session scope's activation, and the
  /// shell converges that to a sign-out.
  void registerRehydrate(
    DependencyContainer container,
    String name, {
    required Duration staleAfter,
  }) {
    if (!container.isRegistered<SessionRehydrator>()) return;

    container.get<SessionRehydrator>().register(
      name,
      isStale: () => switch (_status.state) {
        HydrationState.idle || HydrationState.failed => true,
        HydrationState.running => false,
        // The window is the feature's to choose; whether the stamp has aged
        // past it is the status's own question to answer (#300).
        HydrationState.refreshed => _status.isStaleAfter(staleAfter),
      },
      run: run,
    );
  }

  /// One drain, with the session check in front of it and the status
  /// driven around both. Only [run] calls this.
  Future<O> _drainOnce() async {
    _status.started();

    final SessionConfirmation? answer;
    try {
      answer = await _guard?.confirm(_userId);
    } on Object catch (error, stackTrace) {
      // Unreachable by contract: a guard answers `unanswered` rather than
      // throwing. Held off all the same, because a drain read as another
      // user writes that user's rows into this one's cache.
      _logger.warn(
        '$_feature hydrate held off: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
        context: _context,
      );
      _status.finished(_failed);
      return _failed;
    }
    if (answer != null && answer != SessionConfirmation.confirmed) {
      _logger.info(
        '$_feature hydrate held off: the session could not be confirmed as '
        'this scope\'s user',
        context: {..._context, 'answer': answer.name},
      );
      _status.finished(_failed);
      return _failed;
    }

    O outcome;
    try {
      // Awaited inside the try rather than given a catchError, so a drain
      // that throws before returning a future is caught too.
      outcome = await _drain();
    } on Object catch (error, stackTrace) {
      // Unreachable by contract: a drain reports failure in its return
      // value. Kept because the cost of being wrong is a sign-out.
      _logger.error(
        '$_feature hydrate escaped its own error handling',
        error: error,
        stackTrace: stackTrace,
        context: _context,
      );
      outcome = _failed;
    }
    _status.finished(outcome);
    return outcome;
  }
}
