import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// `PendingDeepLinkHolder` — single slot, latest wins,
/// single-shot consumption (confirmed #10 decision: no queue, no TTL).
void main() {
  const first = ServerDeepLink(
    serverId: 's1',
    location: '/server/s1/game/1',
  );
  const second = ServerDeepLink(
    serverId: 's2',
    location: '/server/s2/event/9',
  );

  // Equal to `first` by value but never the same instance (non-const).
  NormalizedDeepLink equalCopyOfFirst() => ServerDeepLink(
    serverId: 's1',
    location: ['/server', 's1', 'game', '1'].join('/'),
  );

  group('PendingDeepLinkHolder', () {
    test('starts empty', () {
      final holder = PendingDeepLinkHolder();

      expect(holder.peek, isNull);
      expect(holder.take(), isNull);
    });

    test('peek returns the held link without consuming it', () {
      final holder = PendingDeepLinkHolder()..set(first);

      expect(holder.peek, first);
      expect(holder.peek, first, reason: 'peek must not consume');
    });

    test('set replaces any held link — latest wins', () {
      final holder = PendingDeepLinkHolder()
        ..set(first)
        ..set(second);

      expect(holder.peek, second);
    });

    test('take returns the held link and empties the slot', () {
      final holder = PendingDeepLinkHolder()..set(first);

      expect(holder.take(), first);
      expect(holder.peek, isNull);
      expect(holder.take(), isNull, reason: 'consumption is single-shot');
    });

    test('clear empties the slot without returning the link', () {
      final holder = PendingDeepLinkHolder()
        ..set(first)
        ..clear();

      expect(holder.peek, isNull);
      expect(holder.take(), isNull);
    });

    test('clear on an empty slot is a no-op', () {
      final holder = PendingDeepLinkHolder()..clear();

      expect(holder.peek, isNull);
    });

    test('the slot is reusable after consumption', () {
      final holder = PendingDeepLinkHolder()
        ..set(first)
        ..take()
        ..set(second);

      expect(holder.peek, second);
    });

    test('set notifies listeners', () {
      var calls = 0;
      PendingDeepLinkHolder()
        ..addListener(() => calls++)
        ..set(first);

      expect(calls, 1);
    });

    test('set notifies again for an equal link', () {
      var calls = 0;
      PendingDeepLinkHolder()
        ..set(first)
        ..addListener(() => calls++)
        ..set(equalCopyOfFirst());

      expect(calls, 1, reason: 'an equal link re-delivered must land again');
    });

    test('take and clear do not notify', () {
      var calls = 0;
      PendingDeepLinkHolder()
        ..set(first)
        ..addListener(() => calls++)
        ..take()
        ..clear();

      expect(calls, 0);
    });

    test('takeIf takes a link equal to the held one', () {
      final holder = PendingDeepLinkHolder()..set(first);
      final expected = equalCopyOfFirst();
      expect(identical(first, expected), isFalse, reason: 'must not be const');

      final taken = holder.takeIf(expected);

      expect(taken, first);
      expect(holder.peek, isNull);
    });

    test('takeIf leaves a different held link in place', () {
      final holder = PendingDeepLinkHolder()..set(second);

      expect(holder.takeIf(first), isNull);
      expect(holder.peek, second);
    });
  });
}
