import 'package:cuid2/cuid2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/repositories/notification_summary_repository_impl.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

NotificationSummary _makeNotification({
  String? id,
  String localServerId = 'local-server-1',
  String bgeServerId = 'bge-uuid-1',
  String serverDisplayName = 'My Server',
  String title = 'Test Notification',
  String? body,
  bool isRead = false,
  bool requiresFullLoad = false,
  DateTime? receivedAt,
}) => NotificationSummary(
  id: id ?? cuid(),
  localServerId: localServerId,
  bgeServerId: bgeServerId,
  serverDisplayName: serverDisplayName,
  title: title,
  body: body,
  isRead: isRead,
  requiresFullLoad: requiresFullLoad,
  receivedAt: receivedAt ?? DateTime.now().toUtc(),
  createdAt: DateTime.now().toUtc(),
);

void main() {
  late MetaDatabase database;
  late NotificationSummaryRepository repository;

  setUp(() {
    database = MetaDatabase.test(NativeDatabase.memory());
    repository = NotificationSummaryRepositoryImpl(database);
  });

  tearDown(() async => database.close());

  group('NotificationSummaryRepositoryImpl', () {
    group('add', () {
      test('persists and returns notification', () async {
        final n = _makeNotification(title: 'Hello', body: 'World');
        final saved = await repository.add(n);

        expect(saved.id, n.id);
        expect(saved.title, 'Hello');
        expect(saved.body, 'World');
        expect(saved.isRead, isFalse);
      });

      test('persists requiresFullLoad flag', () async {
        final n = _makeNotification(requiresFullLoad: true);
        final saved = await repository.add(n);
        expect(saved.requiresFullLoad, isTrue);
      });

      test('persists null body', () async {
        final saved = await repository.add(_makeNotification());
        expect(saved.body, isNull);
      });
    });

    group('markRead', () {
      test('marks single notification as read', () async {
        final n = await repository.add(_makeNotification());
        await repository.markRead(n.id);

        final unread = await repository.getUnread();
        expect(unread, isEmpty);
      });

      test('does not affect other notifications', () async {
        final n1 = await repository.add(_makeNotification());
        final n2 = await repository.add(_makeNotification());

        await repository.markRead(n1.id);

        final unread = await repository.getUnread();
        expect(unread.map((n) => n.id), contains(n2.id));
        expect(unread.map((n) => n.id), isNot(contains(n1.id)));
      });
    });

    group('markAllReadForServer', () {
      test('marks all notifications for a server as read', () async {
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-b'));

        await repository.markAllReadForServer('server-a');

        final unread = await repository.getUnread();
        expect(unread.length, 1);
        expect(unread.first.localServerId, 'server-b');
      });
    });

    group('delete', () {
      test('removes notification', () async {
        final n = await repository.add(_makeNotification());
        await repository.delete(n.id);

        final all = await repository.watchAll().first;
        expect(all, isEmpty);
      });
    });

    group('deleteAllForServer', () {
      test('removes all notifications for server', () async {
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-b'));

        await repository.deleteAllForServer('server-a');

        final remaining = await repository.getForServer('server-a');
        expect(remaining, isEmpty);

        final other = await repository.getForServer('server-b');
        expect(other, hasLength(1));
      });
    });

    group('getUnread', () {
      test('returns only unread, ordered by receivedAt desc', () async {
        final older = DateTime(2024, 1, 1).toUtc();
        final newer = DateTime(2024, 1, 2).toUtc();

        final n1 = await repository.add(_makeNotification(receivedAt: older));
        final n2 = await repository.add(_makeNotification(receivedAt: newer));
        await repository.add(_makeNotification(isRead: true));

        final unread = await repository.getUnread();
        expect(unread.length, 2);
        expect(unread[0].id, n2.id); // newer first
        expect(unread[1].id, n1.id);
      });
    });

    group('getForServer', () {
      test('returns only notifications for the given server', () async {
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-b'));

        final result = await repository.getForServer('server-a');
        expect(result.length, 1);
        expect(result.first.localServerId, 'server-a');
      });
    });

    group('getUnreadCount', () {
      test('counts only unread across all servers', () async {
        await repository.add(_makeNotification());
        await repository.add(_makeNotification());
        await repository.add(_makeNotification(isRead: true));

        final count = await repository.getUnreadCount();
        expect(count, 2);
      });

      test('returns 0 when all are read', () async {
        final n = await repository.add(_makeNotification());
        await repository.markRead(n.id);

        expect(await repository.getUnreadCount(), 0);
      });
    });

    group('getUnreadCountForServer', () {
      test('counts unread for a specific server only', () async {
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-b'));
        await repository.markAllReadForServer('server-b');

        expect(await repository.getUnreadCountForServer('server-a'), 2);
        expect(await repository.getUnreadCountForServer('server-b'), 0);
      });
    });

    group('watchAll', () {
      test('emits empty initially', () async {
        await expectLater(repository.watchAll().take(1), emits(isEmpty));
      });

      test('emits updated list after add', () async {
        // Subscribe-then-mutate. Post-Pass-3c the stream emits the
        // current state on subscribe (no fake `yield <empty>`), so we
        // must listen BEFORE mutating to capture both the initial empty
        // list and the post-add list.
        final futureEmissions = repository.watchAll().take(2).toList();

        await pumpEventQueue();

        await repository.add(_makeNotification(title: 'Watch Test'));

        final emissions =
            await futureEmissions.timeout(const Duration(seconds: 5));
        expect(emissions, hasLength(2));
        expect(emissions[0], isEmpty);
        expect(
          emissions[1].any((n) => n.title == 'Watch Test'),
          isTrue,
        );
      });
    });

    group('watchUnreadCount', () {
      test('emits 0 initially', () async {
        await expectLater(repository.watchUnreadCount().take(1), emits(0));
      });

      test('increments after add, decrements after markRead', () async {
        // Subscribe-then-mutate-then-pump for each step. pumpEventQueue
        // between mutations gives Drift's reactivity time to deliver
        // the emission to the subscriber before the next mutation
        // fires, keeping the sequence deterministic.
        final futureEmissions =
            repository.watchUnreadCount().take(3).toList();

        await pumpEventQueue(); // emission 1: 0 (empty)

        final n = await repository.add(_makeNotification());
        await pumpEventQueue(); // emission 2: 1 (one unread)

        await repository.markRead(n.id);
        // emission 3 (back to 0) lands during the take(3) await below.

        expect(
          await futureEmissions.timeout(const Duration(seconds: 5)),
          equals([0, 1, 0]),
        );
      });
    });

    group('watchUnreadCountForServer', () {
      test(
        'is isolated to the given server '
        '(server-b mutations never raise server-a\'s count)',
        () async {
          // Listener-based capture rather than take(N). The prior
          // test capped emissions with take(2), which cancelled the
          // subscription as soon as [0, 1] arrived — BEFORE the
          // server-b add ran. That meant the test never actually
          // verified isolation; it only confirmed that the first two
          // emissions for server-a were [0, 1] (true regardless of
          // any cross-server interaction).
          //
          // Here we listen until cancel, perform the cross-server
          // mutation, and then assert two things:
          //
          // 1. The last emission for server-a is still 1 — the
          //    server-b row did not change the count.
          // 2. No emission for server-a is greater than 1 across the
          //    entire stream — even if Drift's reactivity re-fires
          //    the query on the server-b add (it may, since the
          //    table changed), the value comes back the same.
          final emissions = <int>[];
          final sub = repository
              .watchUnreadCountForServer('server-a')
              .listen(emissions.add);

          await pumpEventQueue();
          expect(
            emissions,
            equals([0]),
            reason: 'initial emission should be 0 (empty queue)',
          );

          await repository.add(_makeNotification(localServerId: 'server-a'));
          await pumpEventQueue();
          expect(
            emissions.last,
            equals(1),
            reason: 'server-a add should bring the count to 1',
          );

          // Cross-server mutation: must not change server-a's count.
          await repository.add(_makeNotification(localServerId: 'server-b'));
          await pumpEventQueue();

          expect(
            emissions.last,
            equals(1),
            reason: 'server-b add must not change server-a\'s count',
          );
          expect(
            emissions,
            everyElement(lessThanOrEqualTo(1)),
            reason:
                'no emission for server-a should ever exceed 1 across the run',
          );

          await sub.cancel();
        },
      );
    });
  });
}
