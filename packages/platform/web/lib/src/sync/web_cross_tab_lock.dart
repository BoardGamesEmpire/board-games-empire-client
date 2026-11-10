import 'dart:async';
import 'dart:js_interop';

import 'package:interfaces/sync.dart';
import 'package:web/web.dart' as web;

/// A [CrossTabLock] over the browser's Web Locks (#447), which every tab of
/// the origin shares.
///
/// The body runs inside the grant callback, and the lock is held until the
/// promise that callback returns settles. That promise never rejects: the
/// body's error is caught on the Dart side and thrown again once the request
/// has settled, because a Dart error that crosses a JS promise comes back
/// wrapped rather than as itself.
///
/// An abandon aborts the request through its `AbortSignal`, which cancels a
/// request still waiting. A grant the abort was too late to cancel still
/// calls back, and the signal, already aborted by then, is what keeps that
/// callback from running the body. Aborting a granted request does nothing,
/// so a body already running finishes holding the lock.
class WebCrossTabLock implements CrossTabLock {
  /// Requests through `locks`, or through `navigator.locks` when it is null.
  /// A test passes one that grants when told to, to put a grant after an
  /// abort on cue.
  const WebCrossTabLock({this._locks});

  final web.LockManager? _locks;

  @override
  Future<bool> run(
    String name,
    Future<void> Function() body, {
    Future<void>? abandon,
  }) async {
    final signal = _signalAbortedBy(abandon);
    var ran = false;
    Object? failure;
    StackTrace? failureStackTrace;

    Future<void> hold() async {
      try {
        await body();
      } on Object catch (error, stackTrace) {
        failure = error;
        failureStackTrace = stackTrace;
      }
    }

    JSPromise? granted(web.Lock? _) {
      // Released at once: a null result settles the request.
      if (signal.aborted) return null;
      ran = true;
      return hold().toJS;
    }

    try {
      await (_locks ?? web.window.navigator.locks)
          .request(name, web.LockOptions(signal: signal), granted.toJS)
          .toDart;
    } on Object catch (error) {
      if (!ran && _isAbortError(error)) return false;
      rethrow;
    }

    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureStackTrace!);
    }
    return ran;
  }

  /// A signal that aborts when [abandon] completes, either way.
  ///
  /// Its own function so the listener, which lives as long as [abandon] does
  /// and so outlives this request, holds the controller and nothing of the
  /// request's.
  static web.AbortSignal _signalAbortedBy(Future<void>? abandon) {
    final controller = web.AbortController();
    if (abandon != null) {
      unawaited(
        abandon.then(
          (_) => controller.abort(),
          onError: (Object _) => controller.abort(),
        ),
      );
    }
    return controller.signal;
  }

  /// Whether [error] is the rejection of a request whose signal aborted
  /// before the grant.
  static bool _isAbortError(Object error) =>
      error.isA<web.DOMException>() &&
      (error as web.DOMException).name == 'AbortError';
}
