import 'dart:async';

import 'package:interfaces/services.dart';
import 'package:observability/observability.dart';

final BgeLogger _log = BgeLogger('bge.auth.session_rejection');

/// A [SessionRejectionSignal] that merges concurrent reports into as few
/// revalidations as stay truthful (#484).
///
/// The first report starts a re-read. A report that arrives while it runs
/// does not simply join it: that re-read may have been answered before the
/// server revoked the session the new report's 401 saw. Every such report
/// shares one more re-read, started once the running one settles, and
/// skipped if the running one already found no session, since a later 401
/// can't make a gone session more gone. So a burst of 401s (a screen firing
/// several requests, the drain and the socket failing together) costs one
/// `getSession()` when the session is gone, and two when it stands. Once
/// nothing is running or queued, the next report starts afresh.
///
/// `revalidate` is the auth layer's session re-read (`getSession()`). It
/// publishes its own outcome (a null session ends the user scope). This
/// class reads the result only to tell whether the queued re-read is still
/// needed: null means no session.
final class MergedSessionRevalidation implements SessionRejectionSignal {
  /// Creates the signal over `revalidate`.
  MergedSessionRevalidation(this._revalidate);

  final Future<Object?> Function() _revalidate;

  /// The running re-read. Completes with whether it found no session.
  Future<bool>? _inFlight;

  /// The re-read queued behind [_inFlight], shared by every report that
  /// arrived while it ran.
  Future<void>? _queued;

  /// Re-reads the session, or waits for a re-read that started after this
  /// report could have been answered.
  ///
  /// Never throws: an error from the re-read is logged at warning and the
  /// returned future still completes normally. A failed re-read does not
  /// stick, so the next report tries again.
  @override
  Future<void> report() {
    final running = _inFlight;
    if (running == null) return _start();
    return _queued ??= running.then((gone) async {
      // Cleared before starting, so a report during the queued re-read
      // queues behind it in turn.
      _queued = null;
      if (!gone) await _start();
    });
  }

  Future<bool> _start() {
    final started = _run();
    _inFlight = started;
    // Registered before any queued `then`, so the slot is free by the time a
    // queued re-read starts and stores its own.
    unawaited(
      started.whenComplete(() {
        if (identical(_inFlight, started)) _inFlight = null;
      }),
    );
    return started;
  }

  Future<bool> _run() async {
    try {
      return await _revalidate() == null;
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Session revalidation after a rejection failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
