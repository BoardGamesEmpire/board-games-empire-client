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

/// Answers [confirm] with [answer], recording whom it was asked about
/// (#432).
class _FakeIdentityGuard implements SessionIdentityGuard {
  _FakeIdentityGuard({required this.answer});

  SessionConfirmation answer;
  final askedFor = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    askedFor.add(userId);
    return answer;
  }
}

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

    // #432: on web another tab can move the shared session cookie to another
    // user while this session still belongs to the first. A create sent then
    // is owned by one user on the server and another here.
    group('with a session identity guard', () {
      test('asks about the session user, and sends what it confirms', () async {
        register();
        final guard = _FakeIdentityGuard(answer: SessionConfirmation.confirmed);
        container.registerSingleton<SessionIdentityGuard>(guard);
        final queued = await h.queuedCreate();

        await installSender();
        final delivery = await container.get<SyncOperationSender>().deliver(
          queued.id,
          queued.op,
        );

        expect(guard.askedFor, [kUserId]);
        expect(delivery, isA<SyncDelivered>());
      });

      test('sends nothing as another user, and hands it back as a refused '
          'session for a later attempt to claim', () async {
        register();
        final guard = _FakeIdentityGuard(
          answer: SessionConfirmation.notThisUser,
        );
        container.registerSingleton<SessionIdentityGuard>(guard);
        final queued = await h.queuedCreate();
        await installSender();
        final sender = container.get<SyncOperationSender>();

        final refused = await sender.deliver(queued.id, queued.op);

        expect(
          refused,
          isA<SyncFailed>().having(
            (f) => f.failure,
            'failure',
            SyncFailure.sessionRejected,
          ),
        );
        expect(h.householdRemote.creates, isEmpty);

        guard.answer = SessionConfirmation.confirmed;
        expect(
          await sender.deliver(queued.id, queued.op),
          isA<SyncDelivered>(),
        );
      });

      // Not a 401: a drain reads that as worth asking the auth layer about,
      // and offline there is nothing to ask.
      test('sends nothing it could not confirm, and hands it back as '
          'unreachable', () async {
        register();
        container.registerSingleton<SessionIdentityGuard>(
          _FakeIdentityGuard(answer: SessionConfirmation.unanswered),
        );
        final queued = await h.queuedCreate();
        await installSender();

        final refused = await container.get<SyncOperationSender>().deliver(
          queued.id,
          queued.op,
        );

        expect(
          refused,
          isA<SyncFailed>().having(
            (f) => f.failure,
            'failure',
            SyncFailure.unreachable,
          ),
        );
        expect(h.householdRemote.creates, isEmpty);
      });

      test('refuses an entry read from the queue the same way', () async {
        register();
        container.registerSingleton<SessionIdentityGuard>(
          _FakeIdentityGuard(answer: SessionConfirmation.notThisUser),
        );
        final queued = await h.queuedCreate();
        await installSender();

        final refused = await container.get<SyncOperationSender>().deliverEntry(
          await h.entry(queued.id),
        );

        expect(refused, isA<SyncFailed>());
        expect(h.householdRemote.creates, isEmpty);
      });
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

    test('without the collection repository it starts nothing, and does not '
        'throw', () async {
      register(collection: false);
      container.registerSingleton<SyncOperationSender>(h.sender);
      await h.queuedCreate();

      await installDrain();
      await pumpEventQueue();

      expect(container.isRegistered<SyncQueueDrain>(), isFalse);
      expect(h.householdRemote.creates, isEmpty);
    });
  });
}
