import 'dart:async';

import 'package:game_collection/game_collection.dart';
import 'package:models/domain.dart';

/// What the detail page is told when no pass on this device has refreshed
/// the collection for this user and one has failed (#708), so what the cache
/// says the user owns is unknown.
///
/// Before any pass on this device has landed the user's rows, the cache
/// holds only what this device wrote. Once one has, in this session or an
/// earlier one, the cache is confirmed (#771), and a failed pass after that
/// raises nothing: an offline cold start answers from the cache.
final class CollectionNotRefreshedException implements Exception {
  const CollectionNotRefreshedException();

  @override
  String toString() =>
      'CollectionNotRefreshedException: the collection has not been '
      'refreshed, so what the user owns is unknown';
}

/// The cache's [entries] for the detail page's ownership (#708), held back
/// until [hydration] says the cache can answer.
///
/// An empty cache while the device's first refresh runs is unknown, not
/// empty (#269). Answered from it, the page would call a copy the user owns
/// "not in your collection" and offer to add it again. So the cache's answer
/// waits while no pass on this device has landed rows
/// ([Hydration.everConfirmed]) and one is running, or the status hasn't
/// spoken yet.
///
/// It reads this device's passes, not this session's (#771): what an earlier
/// session's pass landed is what the user owned then, and the chips need
/// nothing fresher. The entry page waits on this session's instead, as an
/// entry opened by link may be one this pass is bringing.
///
/// - **Released** once a pass on this device has landed rows, once the
///   status is idle (no pass will bring anything), or once the status stream
///   ends. From then on every answer the cache gives goes through, the
///   latest one held back first.
/// - **A failed pass before any on this device landed rows** is a
///   [CollectionNotRefreshedException] on the stream, once for that
///   failure. The page reads it as ownership unknown: plain chips, and an
///   add offering every platform in either medium. A later pass that lands
///   rows releases the cache's answer then.
///
/// An error from [entries] goes through as it is, and drops the answer held
/// back before it: the read that failed may have been the one to change it.
/// The stream ends when [entries] does, and stops listening to [hydration]
/// then. Cancelling it cancels both.
Stream<List<GameCollection>> ownershipOnceRefreshed(
  Stream<List<GameCollection>> entries,
  Stream<Hydration> hydration,
) {
  late final StreamController<List<GameCollection>> out;
  StreamSubscription<List<GameCollection>>? entriesSubscription;
  StreamSubscription<Hydration>? hydrationSubscription;
  List<GameCollection>? latest;
  Hydration? reading;
  var released = false;

  void releaseIfSettled() {
    if (released) return;
    final current = reading;
    if (current == null) return;
    if (!current.everConfirmed &&
        (current.state == HydrationState.running ||
            current.state == HydrationState.failed)) {
      return;
    }
    released = true;
    if (latest case final held?) out.add(held);
  }

  out = StreamController<List<GameCollection>>(
    onListen: () {
      hydrationSubscription = hydration.listen(
        (next) {
          final failedFirst =
              !released &&
              !next.everConfirmed &&
              next.state == HydrationState.failed &&
              reading?.state != HydrationState.failed;
          reading = next;
          if (failedFirst) {
            out.addError(const CollectionNotRefreshedException());
            return;
          }
          releaseIfSettled();
        },
        // A status that can say no more settles the wait, as the entry
        // page's does.
        onDone: () {
          if (released) return;
          released = true;
          if (latest case final held?) out.add(held);
        },
      );
      entriesSubscription = entries.listen(
        (next) {
          latest = next;
          if (released) out.add(next);
        },
        onError: (Object error, StackTrace stackTrace) {
          latest = null;
          out.addError(error, stackTrace);
        },
        // The status stops first: one settling before the close reaches the
        // listener would add to a closed stream.
        onDone: () {
          unawaited(hydrationSubscription?.cancel());
          unawaited(out.close());
        },
      );
    },
    onCancel: () async {
      await hydrationSubscription?.cancel();
      await entriesSubscription?.cancel();
    },
  );
  return out.stream;
}
