// The waits the composed session suite (#369) takes before it reads the cache
// or counts requests. `awaitRefreshed` and `pollUntil` come from
// `bge_test_support/waits.dart`, shared with the native root harness; what is
// here only names the statuses and the drain this root registers.

import 'dart:async';

import 'package:bge_test_support/waits.dart';
import 'package:events/events.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:sync_queue/sync_queue.dart';

/// Waits until the household, collection and event hydrates in [container]
/// have each landed a pass ([HydrationState.refreshed]).
///
/// The user tier sends its first requests after `UserSessionScope.activate`
/// returns, so a test that reads the cache or counts requests waits on this
/// first. A pass that fails fails it at once, and one that never runs fails
/// it after [timeout], each naming the status; see [awaitRefreshed].
Future<void> awaitHydrated(
  DependencyContainer container, {
  Duration timeout = const Duration(seconds: 10),
}) => awaitRefreshed({
  'HouseholdHydrationStatus': container.get<HouseholdHydrationStatus>(),
  'GameCollectionHydrationStatus': container
      .get<GameCollectionHydrationStatus>(),
  'EventHydrationStatus': container.get<EventHydrationStatus>(),
}, timeout: timeout);

/// Joins the user tier's [SyncQueueDrain] pass in flight in [container], or
/// runs one, and returns when that pass completes. Throws a
/// [TimeoutException] after [timeout].
///
/// The drain runs each pass under the server's Web Lock, so a pass that
/// never completes is also how a lock still held by a closed scope shows.
Future<void> joinOrRunDrainPass(
  DependencyContainer container, {
  Duration timeout = const Duration(seconds: 10),
}) => container.get<SyncQueueDrain>().drain().timeout(
  timeout,
  onTimeout: () => throw TimeoutException(
    'The sync drain still had a pass in flight',
    timeout,
  ),
);
