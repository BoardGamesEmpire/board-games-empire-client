import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';

/// `PendingDeepLinkHolder` — single slot, latest wins,
/// single-shot consumption (confirmed #10 decision: no queue, no TTL).
void main() {
  const first = NormalizedDeepLink(
    serverId: 's1',
    location: '/server/s1/game/1',
  );
  const second = NormalizedDeepLink(
    serverId: 's2',
    location: '/server/s2/event/9',
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
      final holder = PendingDeepLinkHolder()..set(first);

      holder.clear();

      expect(holder.peek, isNull);
      expect(holder.take(), isNull);
    });

    test('clear on an empty slot is a no-op', () {
      final holder = PendingDeepLinkHolder()..clear();

      expect(holder.peek, isNull);
    });

    test('the slot is reusable after consumption', () {
      final holder = PendingDeepLinkHolder()..set(first);
      holder.take();

      holder.set(second);

      expect(holder.peek, second);
    });
  });
}
