import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:sync_queue/sync_queue.dart';

import 'support/harness.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

const _server = ScopedServer(serverId: 'server-1', displayName: 'My Server');

/// What the two installers wire into a user session (#121): the sender on
/// every platform, and on native the drain that runs it.
void main() {
  late Harness h;
  late DependencyContainerImpl container;

  setUp(() async {
    h = await Harness.open();
    container = DependencyContainerImpl();
  });

  tearDown(() async {
    await container.dispose();
    await h.close();
  });

  /// Registers what the session tier holds, less whatever a test leaves out.
  void register({
    bool queue = true,
    bool households = true,
    bool householdRemote = true,
    bool collection = true,
    bool collectionRemote = true,
  }) {
    if (queue) container.registerSingleton<SyncQueueRepository>(h.queue);
    if (households) {
      container.registerSingleton<HouseholdRepository>(h.households);
    }
    if (householdRemote) {
      container.registerSingleton<HouseholdRemoteDataSource>(h.householdRemote);
    }
    if (collection) {
      container.registerSingleton<GameCollectionRepository>(h.collection);
    }
    if (collectionRemote) {
      container.registerSingleton<GameCollectionRemoteDataSource>(
        h.collectionRemote,
      );
    }
  }

  Future<void> installSender() =>
      const SyncSenderInstaller().install(container, _server, kUserId);

  Future<void> installDrain() =>
      SyncQueueDrainInstaller(now: h.deviceNow)
          .install(container, _server, kUserId);

  group('SyncSenderInstaller', () {
    test('registers a sender over the session tier', () async {
      register();
      final queued = await h.queuedCreate();

      await installSender();

      final sender = container.get<SyncOperationSender>();
      expect(await sender.deliver(queued.id, queued.op), isA<SyncDelivered>());
    });

    for (final (label, registerAllBut) in <(String, void Function())>[
      ('the queue', () => register(queue: false)),
      ('the household repository', () => register(households: false)),
      ('the household client', () => register(householdRemote: false)),
      ('the collection repository', () => register(collection: false)),
      ('the collection client', () => register(collectionRemote: false)),
    ]) {
      test('registers nothing without $label, and does not throw', () async {
        registerAllBut();

        await installSender();

        expect(container.isRegistered<SyncOperationSender>(), isFalse);
      });
    }
  });

  group('SyncQueueDrainInstaller', () {
    test('install starts a pass: work left queued is sent', () async {
      register();
      final queued = await h.queuedCreate();
      await installSender();

      await installDrain();
      await pumpEventQueue();

      expect((await h.entry(queued.id)).status, SyncStatus.completed);
    });

    test('install does not wait for the pass', () async {
      // Activation is the bootstrap gate: awaiting the network here would
      // put it on the sign-in path.
      register();
      await h.queuedCreate();
      final blocked = Completer<Household>();
      h.householdRemote.respond = (_) => blocked.future;
      await installSender();

      await installDrain().timeout(const Duration(seconds: 1));

      expect(blocked.isCompleted, isFalse);
      blocked.complete(serverHousehold());
    });

    test('registers with the session rehydrator, which runs it only when '
        'there is something to send', () async {
      await const SessionRehydratorInstaller().install(
        container,
        _server,
        kUserId,
      );
      register();
      await installSender();
      await installDrain();
      await pumpEventQueue();
      final rehydrator = container.get<SessionRehydrator>();

      await rehydrator.rehydrateStale();
      expect(h.householdRemote.creates, isEmpty);

      await h.queuedCreate();
      await pumpEventQueue();
      await rehydrator.rehydrateStale();
      expect(h.householdRemote.creates, hasLength(1));
    });

    test('a refused session asks the auth layer', () async {
      final auth = _MockAuthRepository();
      when(auth.getSession).thenAnswer((_) async => null);
      container.registerSingleton<AuthRepository>(auth);
      register();
      await h.queuedCreate();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException(
            'Household create failed',
            statusCode: 401,
          );
      await installSender();

      await installDrain();
      await pumpEventQueue();

      verify(auth.getSession).called(1);
    });

    test('the scope teardown stops the drain', () async {
      register();
      await installSender();
      await installDrain();
      final drain = container.get<SyncQueueDrain>();
      await pumpEventQueue();

      await container.dispose();
      await h.queuedCreate();

      expect(drain.isStale, isFalse);
      await drain.drain();
      expect(h.householdRemote.creates, isEmpty);
    });

    test('without a sender it starts nothing, and does not throw', () async {
      register();
      await h.queuedCreate();

      await installDrain();
      await pumpEventQueue();

      expect(container.isRegistered<SyncQueueDrain>(), isFalse);
      expect(h.householdRemote.creates, isEmpty);
    });
  });
}
