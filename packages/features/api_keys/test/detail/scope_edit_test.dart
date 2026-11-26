import 'package:api_keys/src/detail/scope_edit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/fixtures.dart';

void main() {
  final read = permission('collection:read');
  final hooks = permission('webhooks:manage', pinnable: true);
  final users = permission('users:manage', riskLevel: RiskLevel.critical);
  final plugins = permission('plugins:manage', riskLevel: RiskLevel.critical);

  /// The permissions on offer, by slug, in the order given.
  Map<String, GrantablePermission> offer(List<GrantablePermission> each) => {
    for (final permission in each) permission.slug: permission,
  };

  const readScope = ApiKeyScope(slug: 'collection:read');
  const pinnedHook = ApiKeyScope(slug: 'webhooks:manage', resourceId: 'h_1');
  const usersScope = ApiKeyScope(slug: 'users:manage');
  // A permission its owner may no longer give.
  const goneScope = ApiKeyScope(slug: 'events:manage');

  final key = apiKey(
    'k_1',
    scopes: const [readScope, pinnedHook, usersScope, goneScope],
  );

  group('heldGrantable', () {
    test('keeps what may still be given, pins included, in the key order', () {
      expect(heldGrantable(key, offer([read, hooks, users])), [
        readScope,
        pinnedHook,
        usersScope,
      ]);
    });

    test('leaves out a scope whose permission is no longer offered', () {
      expect(heldGrantable(key, offer([read])), [readScope]);
    });
  });

  group('scopesToSend', () {
    final grantable = offer([read, hooks, users]);

    test('the picks as the key holds them send nothing', () {
      expect(scopesToSend(key, grantable, [readScope, usersScope]), isNull);
      // In another order, too: the picks are a set.
      expect(scopesToSend(key, grantable, [usersScope, readScope]), isNull);
    });

    test('a change sends the picks with every pin as it was, and never a '
        'scope no longer offered', () {
      expect(scopesToSend(key, grantable, [readScope]), [
        readScope,
        pinnedHook,
      ]);
    });

    test('a pick no longer offered is not sent, nor counted as a change', () {
      final fewer = offer([read, hooks]);
      expect(scopesToSend(key, fewer, [readScope, usersScope]), isNull);
      expect(scopesToSend(key, fewer, [usersScope]), [pinnedHook]);
    });

    test('an unpinned scope beside a pin of the same permission is its own '
        'pick', () {
      expect(
        scopesToSend(key, grantable, [
          readScope,
          usersScope,
          const ApiKeyScope(slug: 'webhooks:manage'),
        ]),
        [
          readScope,
          usersScope,
          const ApiKeyScope(slug: 'webhooks:manage'),
          pinnedHook,
        ],
      );
    });
  });

  group('newCritical', () {
    final grantable = offer([read, hooks, users, plugins]);

    test('names a Critical permission the key does not hold yet', () {
      expect(
        newCritical(key, const [
          readScope,
          usersScope,
          ApiKeyScope(slug: 'plugins:manage'),
        ], grantable),
        [plugins],
      );
    });

    test('keeping one the key holds asks for nothing', () {
      expect(
        newCritical(key, const [readScope, usersScope], grantable),
        isEmpty,
      );
    });

    test('a pin of a held permission asks for nothing again', () {
      expect(
        newCritical(key, const [
          ApiKeyScope(slug: 'users:manage', resourceId: 'u_1'),
        ], grantable),
        isEmpty,
      );
    });

    test('one the offer does not have is never counted', () {
      expect(
        newCritical(key, const [
          ApiKeyScope(slug: 'plugins:manage'),
        ], offer([read])),
        isEmpty,
      );
    });
  });
}
