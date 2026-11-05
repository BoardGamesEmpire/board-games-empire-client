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
/// pass lands.
Future<void> awaitRefreshed(
  Map<String, HydrationStatus<Object>> statuses, {
  Duration timeout = const Duration(seconds: 10),
}) => Future.wait(eagerError: true, [
  for (final MapEntry(key: name, value: status) in statuses.entries)
    status
        .watch()
        .firstWhere(
          (h) =>
              h.state == HydrationState.refreshed ||
              h.state == HydrationState.failed,
        )
        .timeout(
          timeout,
          onTimeout: () => throw TimeoutException(
            '$name never landed a pass; it was left ${status.state.name}',
            timeout,
          ),
        )
        .then((h) {
          if (h.state == HydrationState.failed) {
            throw StateError('$name failed its pass instead of landing it');
          }
        }),
]);
