// packages/storage/drift_storage/lib/src/repositories/watch_disposal.dart
import 'dart:async';

import 'package:interfaces/orchestration.dart';

/// The close-on-dispose contract (#135, #138) shared by the user-session
/// scoped repositories (`HouseholdRepositoryImpl`,
/// `SyncQueueRepositoryImpl`) — a single fix surface for machinery that
/// previously lived as two hand-rolled copies.
///
/// Drift streams are tied to the per-server database, which outlives the
/// user session, so every vended `watch*` stream must be wrapped with
/// [untilDisposed]: on scope pop the stream **closes** (never errors),
/// regardless of whether the subscriber cancels — otherwise a
/// subscription taken under one user would keep emitting after sign-out.
///
/// Mixing classes must:
///
/// - be registered with `dispose: (_) => instance.onDispose()` by their
///   scope installer;
/// - call [checkNotDisposed] at the top of every public method **except**
///   the `watch*` methods, whose post-disposal contract is an
///   already-closed stream rather than a throw (a `Stream`-returning
///   method must not throw synchronously — `StreamBuilder`, bloc
///   `onError` and `.handleError` can only observe what arrives on the
///   stream — and [untilDisposed] already handles the disposed case by
///   closing immediately);
/// - route every vended stream through [untilDisposed], and any read such
///   a stream makes besides its own Drift query through
///   [awaitedOnDispose];
/// - override [disposedRepositoryName] for the post-disposal error text.
///
/// [onDispose] cancels every live source subscription and **awaits** the
/// cancellation, and any [awaitedOnDispose] read still under way, before
/// returning: the suspend path closes the per-server database right after
/// the scope's dispose callbacks return, so Drift teardown must have fully
/// completed by then, not merely started. It then closes every vended
/// outer stream (the done event of the close-not-error contract) and is
/// idempotent.
///
/// Post-disposal behaviour therefore splits by return type, deliberately:
/// `Future`-returning methods throw [StateError] via [checkNotDisposed]
/// (a caller awaiting a one-shot read should learn its scope is gone),
/// while `watch*` methods return an already-closed stream — subscribers
/// see `onDone`, never an error.
mixin WatchDisposal implements Disposable {
  /// Set once by [onDispose]; guards every public method (#135).
  bool _disposed = false;

  /// Live source (Drift) subscriptions behind vended watch streams,
  /// tracked so [onDispose] can cancel them and await the cancellation.
  final Set<StreamSubscription<dynamic>> _watchSubscriptions = {};

  /// The outer controllers paired with [_watchSubscriptions], closed on
  /// [onDispose] so every vended stream ends with a done event.
  final Set<MultiStreamController<dynamic>> _watchControllers = {};

  /// [awaitedOnDispose] reads still under way, each settled whether it
  /// succeeds or fails.
  final Set<Future<void>> _pendingReads = {};

  /// The interface name used in the post-disposal [StateError], e.g.
  /// `'HouseholdRepository'`.
  String get disposedRepositoryName;

  @override
  Future<void> onDispose() async {
    if (_disposed) return;
    _disposed = true;

    final subscriptions = List.of(_watchSubscriptions);
    _watchSubscriptions.clear();
    await Future.wait(subscriptions.map((sub) => sub.cancel()));
    // The cancellations stop new ones, but not those already started.
    await Future.wait(List.of(_pendingReads));

    final controllers = List.of(_watchControllers);
    _watchControllers.clear();
    for (final controller in controllers) {
      controller.close();
    }
  }

  /// Returns [read], which [onDispose] waits for if it is still under way.
  ///
  /// For a read a vended stream makes besides its own Drift query, as in an
  /// `asyncMap` step: cancelling the stream does not wait for a step
  /// already started, which would leave the read to run against a closed
  /// database. Its result and any error still reach the caller.
  Future<T> awaitedOnDispose<T>(Future<T> read) {
    final settled = read.then<void>((_) {}, onError: (Object _) {});
    _pendingReads.add(settled);
    unawaited(settled.whenComplete(() => _pendingReads.remove(settled)));
    return read;
  }

  /// Throws [StateError] once the owning user-session scope has popped.
  void checkNotDisposed() {
    if (_disposed) {
      throw StateError(
        '$disposedRepositoryName has been disposed — its user-session '
        'scope was torn down (#135). Resolve a fresh instance from the '
        'active user session.',
      );
    }
  }

  /// Wraps a watch [source] so the returned stream **closes** when this
  /// repository is disposed, regardless of whether the subscriber ever
  /// cancels. [source] is invoked lazily per listener — preserving any
  /// async* body's contract of delivering errors on the stream rather
  /// than as a synchronous throw. Each listener's source subscription and
  /// outer controller are tracked for [onDispose]; both deregister on
  /// their own done/cancel so the tracking sets only ever hold live
  /// entries. `onCancel` returns the source cancellation future so a
  /// subscriber's `cancel()` also awaits Drift teardown.
  Stream<T> untilDisposed<T>(Stream<T> Function() source) {
    return Stream<T>.multi((controller) {
      if (_disposed) {
        controller.close();
        return;
      }
      late final StreamSubscription<T> sub;
      sub = source().listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          _watchSubscriptions.remove(sub);
          _watchControllers.remove(controller);
          controller.close();
        },
      );
      _watchSubscriptions.add(sub);
      _watchControllers.add(controller);
      controller.onCancel = () {
        _watchSubscriptions.remove(sub);
        _watchControllers.remove(controller);
        return sub.cancel();
      };
    });
  }
}
