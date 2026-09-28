import 'dart:async';

/// A stream that gives each new listener [current]'s value, then forwards
/// [updates] (#102).
///
/// This is the "current value on subscribe" contract that `watchState`,
/// `watchAuthState`, `watchActive` and `watchSkew` all promise, and that
/// each used to hand-roll with its own `Stream.multi`.
///
/// - [current] is read once per listen, at listen time. A late listener
///   sees the value current when it subscribed.
/// - [updates] is called once per listen too, so the stream can be
///   listened to again whatever kind of stream [updates] returns. Each
///   listener gets that stream's values, errors and done, and its cancel
///   cancels that stream's subscription.
/// - An [updates] stream that has already closed still yields the replay,
///   then done. A disposed source needs no special case.
/// - [updates] is required, so each caller says what follows the replay.
///   `() => const Stream.empty()` replays and then completes. `null`
///   forwards nothing, and the stream stays open until the listener
///   cancels.
///
/// ## A pause stays here
///
/// A listener's pause is not passed to [updates]. Its events wait in its
/// own buffer while the upstream subscription keeps draining. Every owner
/// awaits its controller's `close()` on dispose, and a broadcast
/// controller's `close()` does not complete while any subscription to it
/// is paused. Passing the pause through would let one paused watcher hold
/// dispose open: forever, for an `await for` whose body waits on the
/// teardown. It would buy nothing in return, because pausing a broadcast
/// subscription only moves the buffer, and cannot slow the source.
///
/// ## Delivery is asynchronous
///
/// Every event, the replay included, reaches the listener through the multi
/// controller's asynchronous `add`, never synchronously inside `listen()`
/// or inside the upstream's own `add`. That holds even when [updates] comes
/// from a `sync: true` controller, so its synchrony never escapes the
/// owning class. `WebAuthRepositoryImpl`'s reconcile success path depends on
/// that ordering (#278): no subscriber can observe an emission before an
/// awaiting caller resumes. Do not switch this to `addSync`.
Stream<T> replayThenForward<T>({
  required T Function() current,
  required Stream<T> Function()? updates,
}) {
  return Stream<T>.multi((controller) {
    controller.add(current());
    if (updates == null) return;
    final subscription = updates().listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  });
}
