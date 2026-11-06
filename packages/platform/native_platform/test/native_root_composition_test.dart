// The composition test for the native root (#435): the real
// `NativePlatformBootstrap`, with only its external boundaries faked (see
// `NativeRootHarness`), signs a user in, and every installer the root ships
// has to have taken effect. It fails when an installer goes missing from
// `buildNativeServerScopeInstallers`, `buildNativeUserScopeInstallers`, or
// from the factory that passes them to the context.
//
// Plain `test()`, not `testWidgets`: drift and the real async work under the
// root need real time, and the widget tester's fake async would stall them.

import 'package:bge_test_support/waits.dart';
import 'package:dio_network/dio_network.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:interfaces/sync.dart';
import 'package:network_interface/network_interface.dart';
import 'package:sync_queue/sync_queue.dart';

import 'support/native_root_harness.dart';

void main() {
  group('the native root\'s composition (#435)', () {
    late NativeRootHarness harness;

    Future<void> signedIn() async {
      await harness.boot();
      await harness.addServer();
      await harness.signIn();
      await harness.activateUser();
    }

    setUp(() async {
      harness = await NativeRootHarness.create();
      addTearDown(harness.dispose);
    });

    group('with the default answers', () {
      setUp(signedIn);

      test('the server scope holds the real storage and network', () {
        final container = harness.container;

        expect(container.isRegistered<ServerDatabase>(), isTrue);
        expect(container.isRegistered<ClockService>(), isTrue);
        expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
        expect(container.get<AuthRepository>(), isA<AuthRepositoryImpl>());
      });

      test('the user scope holds what each of the eight user installers '
          'registers', () async {
        final container = harness.container;
        // The context's container falls through to the server scope, so
        // being registered here does not say which tier registered it.
        // Closing the user scope does: what it held goes with it.
        final byInstaller = <String, bool Function()>{
          'SessionRehydrator, by SessionRehydratorInstaller':
              container.isRegistered<SessionRehydrator>,
          'SyncQueueRepository, by UserSessionScopeInstaller':
              container.isRegistered<SyncQueueRepository>,
          'HouseholdRepository, by UserSessionScopeInstaller':
              container.isRegistered<HouseholdRepository>,
          'GameCollectionRepository, by UserSessionScopeInstaller':
              container.isRegistered<GameCollectionRepository>,
          'EventRepository, by UserSessionScopeInstaller':
              container.isRegistered<EventRepository>,
          'HouseholdHydrationStatus, by HouseholdHydrateInstaller':
              container.isRegistered<HouseholdHydrationStatus>,
          'GameCollectionHydrationStatus, by GameCollectionHydrateInstaller':
              container.isRegistered<GameCollectionHydrationStatus>,
          'EventHydrationStatus, by EventHydrateInstaller':
              container.isRegistered<EventHydrationStatus>,
          'CallerAccessRepository, by CallerAccessInstaller':
              container.isRegistered<CallerAccessRepository>,
          'SyncOperationSender, by SyncSenderInstaller':
              container.isRegistered<SyncOperationSender>,
          'SyncQueueDrain, by SyncQueueDrainInstaller':
              container.isRegistered<SyncQueueDrain>,
        };

        for (final MapEntry(key: registration, value: isRegistered)
            in byInstaller.entries) {
          expect(isRegistered(), isTrue, reason: registration);
        }

        // Let the hydrates land first, so none is mid-write when the scope
        // closes under it.
        await harness.awaitHydrated();
        await container.get<UserSessionScope>().deactivate();

        for (final MapEntry(key: registration, value: isRegistered)
            in byInstaller.entries) {
          expect(
            isRegistered(),
            isFalse,
            reason:
                '$registration outlived the user scope, so the server scope '
                'holds it too (#135)',
          );
        }
      });

      test('caller access is asked for once at sign-in, and the answer '
          'kept', () async {
        final access = harness.container.get<CallerAccessRepository>();

        await pollUntil(
          () => access.current.isKnown,
          describe: () =>
              'No caller access answer was kept. Requests: '
              '${harness.server.requests.map((r) => r.path).toList()}',
        );
        // Then a quiet window, so a second ask sent soon after the first, a
        // re-ask on activation say, has arrived before the count. The
        // hydrates land about 2 ms after the answer, too soon to wait on: an
        // ask 5 ms late slipped past them. A re-ask later than the window,
        // such as the recheck an all-none answer schedules after 2 s, is
        // pinned in the reader's own suite, and `_someAccess` keeps it out
        // of this one.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          harness.server.requestsTo('GET', '/api/users/me/access'),
          hasLength(1),
        );
      });

      test('the hydrates run at sign-in, on the session', () async {
        await harness.awaitHydrated();

        // The bearer is the server network's `TokenInterceptor` at work. The
        // sign-out request carries its token itself, so this is the root
        // test that fails if the interceptor goes missing.
        for (final path in [
          '/api/households',
          '/api/game-collections',
          '/api/events',
        ]) {
          final requests = harness.server.requestsTo('GET', path);
          expect(requests, hasLength(1), reason: path);
          expect(
            requests.single.authorization,
            'Bearer ${NativeRootHarness.sessionToken}',
            reason: path,
          );
        }
      });
    });

    group('a household page fills the cache', () {
      setUp(() async {
        harness.server.json(
          'GET',
          '/api/households',
          NativeRootHarness.householdPageWithOne,
        );
        await signedIn();
      });

      test('through the hydrate the root installs', () async {
        await harness.awaitHydrated();

        final households = await harness.container
            .get<HouseholdRepository>()
            .watchHouseholds()
            .firstWhere(
              (list) => list.any((h) => h.id == NativeRootHarness.householdId),
            )
            .timeout(const Duration(seconds: 10));

        expect(
          households.map((h) => h.id),
          contains(NativeRootHarness.householdId),
        );
      });
    });
  });
}
