import 'dart:async';

import 'package:hydration/hydration.dart';

/// Waits until every status in [statuses] has landed a pass
/// ([HydrationState.refreshed]). Each key names its status in a failure.
///
/// A status whose pass fails ([HydrationState.failed]) fails this at once,
/// with a [StateError] that names it, rather than at [timeout]: under a root,
/// a request no route answers ends the pass that way, so waiting longer
/// would only hide which status it was. A status that has done neither by
/// [timeout] fails with a [TimeoutException] that names it and the state it
/// was left in, such as `idle` for a hydrate that never ran.
///
/// It waits on the condition, not a delay, so it returns as soon as the last
/// pass lands. However it ends, it stops watching every status and cancels
/// its timer, so a failed wait leaves no listener behind on a status the test
/// keeps.
Future<void> awaitRefreshed(
  Map<String, HydrationStatus<Object>> statuses, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  // In map order, so a timeout names the first status still waited on.
  final waiting = statuses.keys.toSet();
  if (waiting.isEmpty) return;

  final ended = Completer<void>();
  final watches = [
    for (final MapEntry(key: name, value: status) in statuses.entries)
      status.watch().listen((h) {
        // A status counts once: a later pass on one that has landed is not
        // this wait's to report.
        if (ended.isCompleted || !waiting.contains(name)) return;
        if (h.state == HydrationState.failed) {
          ended.completeError(
            StateError('$name failed its pass instead of landing it'),
          );
        } else if (h.state == HydrationState.refreshed) {
          waiting.remove(name);
          if (waiting.isEmpty) ended.complete();
        }
      }),
  ];
  final deadline = Timer(timeout, () {
    if (ended.isCompleted) return;
    final name = waiting.first;
    ended.completeError(
      TimeoutException(
        '$name never landed a pass; it was left ${statuses[name]!.state.name}',
        timeout,
      ),
    );
  });

  try {
    await ended.future;
  } finally {
    deadline.cancel();
    await Future.wait([for (final watch in watches) watch.cancel()]);
  }
}
