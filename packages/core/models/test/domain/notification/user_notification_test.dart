import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  final created = DateTime.utc(2026, 11, 12, 10, 30);

  UserNotification unread() => UserNotification(
    id: 'n1',
    type: 'HouseholdInviteReceived',
    payload: const {'householdId': 'h1'},
    read: false,
    createdAt: created,
  );

  test('compares by value', () {
    expect(unread(), unread());
    expect(unread().markedRead(created), isNot(unread()));
  });

  test('markedRead sets read and readAt and keeps the rest', () {
    final readAt = DateTime.utc(2026, 11, 13);

    final marked = unread().markedRead(readAt);

    expect(marked.read, isTrue);
    expect(marked.readAt, readAt);
    expect(marked.id, 'n1');
    expect(marked.type, 'HouseholdInviteReceived');
    expect(marked.payload, const {'householdId': 'h1'});
    expect(marked.createdAt, created);
  });

  group('NotificationPage', () {
    test('hasMore follows nextCursor', () {
      expect(
        NotificationPage(items: [unread()], nextCursor: 'c1').hasMore,
        isTrue,
      );
      expect(NotificationPage(items: [unread()]).hasMore, isFalse);
    });

    test('compares by value', () {
      expect(
        NotificationPage(items: [unread()], nextCursor: 'c1'),
        NotificationPage(items: [unread()], nextCursor: 'c1'),
      );
      expect(
        NotificationPage(items: [unread()], nextCursor: 'c1'),
        isNot(NotificationPage(items: [unread()])),
      );
    });
  });
}
