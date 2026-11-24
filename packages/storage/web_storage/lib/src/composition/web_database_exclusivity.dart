import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// What asking to be a database's only tab came to (#686).
sealed class WebDatabaseHold {
  const WebDatabaseHold();
}

/// This tab holds the database until [release] is called.
final class WebDatabaseHeld extends WebDatabaseHold {
  /// Wraps the call that gives the hold back.
  const WebDatabaseHeld(this.release);

  /// Gives the hold back, so the next tab can have it. Calling it again does
  /// nothing.
  final void Function() release;
}

/// Another tab held the database for the whole wait.
final class WebDatabaseHeldElsewhere extends WebDatabaseHold {
  /// The one answer.
  const WebDatabaseHeldElsewhere();
}

/// No hold can be taken here: this browser context has no Web Locks, or the
/// request for one failed. The tab opens as it did before #686.
final class WebDatabaseHoldUnavailable extends WebDatabaseHold {
  /// The one answer.
  const WebDatabaseHoldUnavailable();
}

/// Lets one tab at a time have a database (#686).
///
/// `WebStorageInstaller` asks for it before the first query of a database on
/// `unsafeIndexedDb`, where each tab works on its own copy of the database and
/// writes it back over the others'.
abstract interface class WebDatabaseExclusivity {
  /// Asks to be [databaseName]'s only tab, waiting up to [wait] for another
  /// tab to let go. Answers, never throws.
  Future<WebDatabaseHold> acquire(
    String databaseName, {
    required Duration wait,
  });
}

/// A [WebDatabaseExclusivity] over the browser's Web Locks, which every tab of
/// the origin shares: an exclusive lock named [lockName], held from the grant
/// until the hold's `release`.
///
/// The browser drops a page's locks when the page goes, so a reload or a
/// closed tab gives the hold back without a `release`. The wait is for that:
/// a reloaded page can ask before the old one has gone.
///
/// A page the browser has frozen keeps its locks, so a background tab that
/// Android froze still holds the database, and a new tab shows the in-use
/// screen until that one is closed (#686). That is the accepted cost: unlike
/// the sync drain's lock, which a pass gives up on after a limit (#954), this
/// hold can't be dropped or stolen on a freeze, because the frozen tab keeps
/// its copy of the database and would write it back when it resumes.
///
/// A Flutter hot restart doesn't unload the page either, so the previous
/// run's hold is never released and the restarted app finds the database in
/// use. Reload the page instead.
///
/// The wait is a timer that aborts the request through an `AbortSignal`.
/// Aborting withdraws a request that is still queued, so a tab that gave up
/// doesn't get the lock later and hold it with nothing to release it. Not
/// `AbortSignal.timeout`: Safari 15.4 has Web Locks and no `SharedWorker`, so
/// it lands on `unsafeIndexedDb`, but `AbortSignal.timeout` arrived in
/// Safari 16.
final class WebLocksDatabaseExclusivity implements WebDatabaseExclusivity {
  /// Requests through `locks`, or through `navigator.locks` when it is null. A
  /// test passes one whose request fails.
  const WebLocksDatabaseExclusivity({this._locks});

  final web.LockManager? _locks;

  /// The Web Lock that [databaseName]'s holder holds.
  static String lockName(String databaseName) => 'bge.database.$databaseName';

  @override
  Future<WebDatabaseHold> acquire(
    String databaseName, {
    required Duration wait,
  }) {
    final locks = _locks ?? _navigatorLocks();
    if (locks == null) {
      return Future.value(const WebDatabaseHoldUnavailable());
    }

    final hold = Completer<WebDatabaseHold>();
    final released = Completer<void>();
    final abort = web.AbortController();
    var waitRanOut = false;
    final timer = Timer(wait, () {
      waitRanOut = true;
      abort.abort();
    });

    void release() {
      if (!released.isCompleted) released.complete();
    }

    // Granted is held: a grant the abort came too late to stop still arrives
    // here, and the lock is this tab's all the same.
    JSPromise<JSAny?> granted(web.Lock? _) {
      timer.cancel();
      hold.complete(WebDatabaseHeld(release));
      // The lock is held until this settles.
      return released.future.toJS;
    }

    // Not awaited: the request settles only once the hold is released. Before
    // the grant, a rejection is the answer: the wait running out means
    // another tab holds it, and any other failure leaves the tab to open as
    // it did before.
    unawaited(
      locks
          .request(
            lockName(databaseName),
            web.LockOptions(signal: abort.signal),
            granted.toJS,
          )
          .toDart
          .then<void>(
            (_) {},
            onError: (Object error) {
              timer.cancel();
              if (hold.isCompleted) return;
              hold.complete(
                waitRanOut && _isAbortError(error)
                    ? const WebDatabaseHeldElsewhere()
                    : const WebDatabaseHoldUnavailable(),
              );
            },
          ),
    );
    return hold.future;
  }

  /// `navigator.locks`, or null where this browser context has none: it
  /// exists only in a secure context, so a server served over plain http has
  /// none.
  static web.LockManager? _navigatorLocks() {
    final navigator = web.window.navigator;
    return navigator.has('locks') ? navigator.locks : null;
  }

  /// Whether [error] is the rejection of a request whose signal aborted
  /// before the grant.
  static bool _isAbortError(Object error) =>
      error.isA<web.DOMException>() &&
      (error as web.DOMException).name == 'AbortError';
}
