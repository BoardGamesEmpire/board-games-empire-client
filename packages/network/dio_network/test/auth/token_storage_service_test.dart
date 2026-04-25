import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:dio_network/src/auth/token_storage_service.dart';

class MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late MockSecureStorage mockStorage;
  late TokenStorageService service;

  const kServerId = 'local-server-abc';
  const kKey = 'bge_session_local-server-abc';
  final kExpiry = DateTime(2099, 1, 1).toUtc();
  final kExpired = DateTime(2000, 1, 1).toUtc();

  setUp(() {
    mockStorage = MockSecureStorage();
    service = TokenStorageService(serverId: kServerId, storage: mockStorage);
  });

  group('TokenStorageService', () {
    group('store', () {
      test('writes JSON-encoded payload under namespaced key', () async {
        when(
          () => mockStorage.write(
            key: kKey,
            value: any(named: 'value'),
          ),
        ).thenAnswer((_) async {});

        await service.store(token: 'tok_abc', expiresAt: kExpiry);

        final captured =
            verify(
                  () => mockStorage.write(
                    key: kKey,
                    value: captureAny(named: 'value'),
                  ),
                ).captured.single
                as String;

        expect(captured, contains('tok_abc'));
        expect(captured, contains('2099'));
      });
    });

    group('retrieve', () {
      test('returns null when no entry exists', () async {
        when(() => mockStorage.read(key: kKey)).thenAnswer((_) async => null);
        expect(await service.retrieve(), isNull);
      });

      test('returns StoredToken with correct fields', () async {
        final payload =
            '{"token":"tok_abc","expires_at":"${kExpiry.toIso8601String()}"}';
        when(
          () => mockStorage.read(key: kKey),
        ).thenAnswer((_) async => payload);

        final result = await service.retrieve();
        expect(result?.token, 'tok_abc');
        expect(result?.isExpired, isFalse);
      });

      test('isExpired true when past expiry', () async {
        final payload =
            '{"token":"old","expires_at":"${kExpired.toIso8601String()}"}';
        when(
          () => mockStorage.read(key: kKey),
        ).thenAnswer((_) async => payload);

        expect((await service.retrieve())?.isExpired, isTrue);
      });

      test('clears and returns null on corrupted entry', () async {
        when(
          () => mockStorage.read(key: kKey),
        ).thenAnswer((_) async => 'not-json{{{');
        when(() => mockStorage.delete(key: kKey)).thenAnswer((_) async {});

        expect(await service.retrieve(), isNull);
        verify(() => mockStorage.delete(key: kKey)).called(1);
      });
    });

    group('clear', () {
      test('deletes the namespaced key', () async {
        when(() => mockStorage.delete(key: kKey)).thenAnswer((_) async {});
        await service.clear();
        verify(() => mockStorage.delete(key: kKey)).called(1);
      });
    });

    group('key isolation', () {
      test('different server IDs use different keys', () async {
        final other = TokenStorageService(
          serverId: 'other-server',
          storage: mockStorage,
        );

        when(
          () => mockStorage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((_) async {});

        await service.store(token: 'a', expiresAt: kExpiry);
        await other.store(token: 'b', expiresAt: kExpiry);

        final keys = verify(
          () => mockStorage.write(
            key: captureAny(named: 'key'),
            value: any(named: 'value'),
          ),
        ).captured;

        expect(keys[0], 'bge_session_local-server-abc');
        expect(keys[1], 'bge_session_other-server');
      });
    });
  });
}
