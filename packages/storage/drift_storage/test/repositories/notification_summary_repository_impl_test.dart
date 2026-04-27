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
        final stream = repository.watchAll();
        await repository.add(_makeNotification(title: 'Watch Test'));

        await expectLater(
          stream.take(2),
          emitsInOrder([
            isEmpty,
            predicate<List<NotificationSummary>>(
              (list) => list.any((n) => n.title == 'Watch Test'),
            ),
          ]),
        );
      });
    });

    group('watchUnreadCount', () {
      test('emits 0 initially', () async {
        await expectLater(repository.watchUnreadCount().take(1), emits(0));
      });

      test('increments after add, decrements after markRead', () async {
        final stream = repository.watchUnreadCount();
        final n = await repository.add(_makeNotification());
        await repository.markRead(n.id);

        await expectLater(stream.take(3), emitsInOrder([0, 1, 0]));
      });
    });

    group('watchUnreadCountForServer', () {
      test('is isolated to the given server', () async {
        final stream = repository.watchUnreadCountForServer('server-a');
        await repository.add(_makeNotification(localServerId: 'server-a'));
        await repository.add(_makeNotification(localServerId: 'server-b'));

        await expectLater(
          stream.take(2),
          emitsInOrder([0, 1]), // only server-a count changes
        );
      });
    });
  });
}
