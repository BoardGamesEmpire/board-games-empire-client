import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:dio_network/src/auth/token_storage_service.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockSecureStorage secure;
  late TokenStorageService storage;

  const key = 'bge_session_server-1';

  String payload() =>
      '{"token":"tok-abc","expires_at":"2099-01-01T00:00:00.000Z"}';

  setUp(() {
    secure = _MockSecureStorage();
    storage = TokenStorageService(serverId: 'server-1', storage: secure);
    when(
      () => secure.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(() => secure.delete(key: any(named: 'key'))).thenAnswer((_) async {});
  });

  group('sign-out latch (#37 / PR #99)', () {
    test('retrieve returns null after clear, even if the token physically '
        'survives a failed delete', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => payload());
      when(
        () => secure.delete(key: any(named: 'key')),
      ).thenThrow(StateError('keychain unavailable'));

      // Token is present before sign-out.
      expect(await storage.retrieve(), isNotNull);

      // clear() latches first, then the delete throws.
      await expectLater(storage.clear(), throwsA(isA<StateError>()));

      // Despite the surviving persisted token, retrieve reports none — so
      // neither the interceptor's Authorization header nor getSession can
      // resurrect it.
      expect(await storage.retrieve(), isNull);
      expect(await storage.hasToken(), isFalse);
    });

    test('retrieve returns null after a successful clear', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => payload());

      await storage.clear();

      expect(await storage.retrieve(), isNull);
    });

    test('storing a new token lifts the latch (fresh sign-in supersedes '
        'the prior sign-out)', () async {
      when(() => secure.read(key: key)).thenAnswer((_) async => payload());
      await storage.clear();
      expect(await storage.retrieve(), isNull);

      await storage.store(token: 'tok-abc', expiresAt: DateTime(2099).toUtc());

      expect(await storage.retrieve(), isNotNull);
    });
  });
}
