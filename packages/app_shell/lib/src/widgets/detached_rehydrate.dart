import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

final BgeLogger _log = BgeLogger('bge.shell.session_rehydrate');

/// Starts a re-hydrate pass nobody is waiting on, and swallows — loudly —
/// every way that can fail (#302, #300 D13).
///
/// The shell has two callers with little else in common: the ambient
/// triggers in `SessionRehydrateTrigger` (a connectivity edge, an app
/// resume) and the household list's entry (#300 D14). What they share is
/// this error handling, and it is subtle enough that two copies of it
/// would be two places to get it wrong.
///
/// [resolve] returns the session's [SessionRehydrator], or null where this
/// composition has no re-hydrate seam at all (shell tests) or the scope it
/// would come from is gone. It runs **inside** the guard, so a caller
/// resolving from a container disposed since the last active-server event
/// is logged rather than thrown from.
///
/// [trigger] names the caller in the logs and does nothing else. The
/// registry decides what work a pass does, and a pass arriving while one is
/// in flight joins it (#302 D3), so no caller has to know who else is
/// asking.
///
/// ## Why both halves are guarded
///
/// `catchError` covers the pass's own future. Unreachable by contract —
/// [SessionRehydrator.rehydrateStale] isolates its entries — but an
/// unhandled async error here would raise a crash-report prompt (#34) for a
/// refresh nobody asked for.
///
/// The synchronous catch covers what `catchError` cannot see: [resolve]
/// itself, since a disposed per-server facade refuses use and so throws
/// from `isRegistered` on the way in; and a `rehydrateStale` that threw
/// *before* its first await — it returns a future but is not required to be
/// an `async` method, and the shipped one is not, so a throw there arrives
/// here instead of on the future's error channel.
///
/// Between them, nothing escapes — which is what makes this callable from
/// inside a `build`, as the #300 entry trigger is (D14).
void startDetachedRehydrate({
  required SessionRehydrator? Function() resolve,
  required String trigger,
}) {
  try {
    final rehydrator = resolve();
    if (rehydrator == null) return;

    unawaited(
      rehydrator.rehydrateStale().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _log.warn(
          'Session re-hydrate escaped its own error handling',
          error: error,
          stackTrace: stackTrace,
          context: {'trigger': trigger},
        );
      }),
    );
  } on Object catch (error, stackTrace) {
    _log.debug(
      'Session re-hydrate could not start a pass',
      error: error,
      stackTrace: stackTrace,
      context: {'trigger': trigger},
    );
  }
}
