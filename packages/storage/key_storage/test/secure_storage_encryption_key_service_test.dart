import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:key_storage/key_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  late _MockSecureStorage storage;
  late SecureStorageEncryptionKeyService service;

  final keyPattern = RegExp(r'^[0-9a-f]{64}$');

  setUp(() {
    storage = _MockSecureStorage();
    service = SecureStorageEncryptionKeyService(storage: storage);

    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((_) async {});
  });

  group('getOrCreateServerKey', () {
    test('generates a 64-char lowercase hex key when none is stored', () async {
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => null);

      final key = await service.getOrCreateServerKey('srv_1');

      expect(key, matches(keyPattern));
    });

    test('persists a newly generated key before returning it', () async {
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => null);

      final key = await service.getOrCreateServerKey('srv_1');

      verify(
        () => storage.write(key: 'encryption_key:srv_1', value: key),
      ).called(1);
    });

    test('returns the stored key without regenerating', () async {
      final stored = 'a' * 64;
      when(
        () => storage.read(key: 'encryption_key:srv_1'),
      ).thenAnswer((_) async => stored);

      final key = await service.getOrCreateServerKey('srv_1');

      expect(key, stored);
      verifyNever(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
    });

    test('namespaces keys per server id', () async {
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => null);

      await service.getOrCreateServerKey('srv_1');
      await service.getOrCreateServerKey('srv_2');

      verify(
        () => storage.write(
          key: 'encryption_key:srv_1',
          value: any(named: 'value'),
        ),
      ).called(1);
      verify(
        () => storage.write(
          key: 'encryption_key:srv_2',
          value: any(named: 'value'),
        ),
      ).called(1);
    });

    test('generated keys differ between servers', () async {
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => null);

      final a = await service.getOrCreateServerKey('srv_1');
      final b = await service.getOrCreateServerKey('srv_2');

      expect(a, isNot(b));
    });

    test('rejects an empty server id', () {
      expect(
        () => service.getOrCreateServerKey(''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects the reserved id "meta"', () {
      expect(
        () => service.getOrCreateServerKey('meta'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('getOrCreateMetaKey', () {
    test('uses the reserved meta storage entry', () async {
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => null);

      final key = await service.getOrCreateMetaKey();

      expect(key, matches(keyPattern));
      verify(
        () => storage.write(key: 'encryption_key:meta', value: key),
      ).called(1);
    });

    test('returns the stored meta key without regenerating', () async {
      final stored = 'b' * 64;
      when(
        () => storage.read(key: 'encryption_key:meta'),
      ).thenAnswer((_) async => stored);

      expect(await service.getOrCreateMetaKey(), stored);
      verifyNever(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
    });
  });

  group('deletion', () {
    test('deleteServerKey removes the per-server entry', () async {
      await service.deleteServerKey('srv_1');

      verify(() => storage.delete(key: 'encryption_key:srv_1')).called(1);
    });

    test('deleteMetaKey removes the meta entry', () async {
      await service.deleteMetaKey();

      verify(() => storage.delete(key: 'encryption_key:meta')).called(1);
    });

    test('a fresh key is generated after deletion', () async {
      // Simulate storage that forgets after delete.
      String? held = 'c' * 64;
      when(
        () => storage.read(key: 'encryption_key:srv_1'),
      ).thenAnswer((_) async => held);
      when(
        () => storage.delete(key: 'encryption_key:srv_1'),
      ).thenAnswer((_) async => held = null);

      final before = await service.getOrCreateServerKey('srv_1');
      await service.deleteServerKey('srv_1');
      final after = await service.getOrCreateServerKey('srv_1');

      expect(before, isNot(after));
    });
  });

  group('key generation', () {
    test('consumes the injected random source', () async {
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => null);

      // A seeded Random makes generation deterministic and proves the
      // injected source is the one being consumed.
      final a = SecureStorageEncryptionKeyService(
        storage: storage,
        random: Random(42),
      );
      final b = SecureStorageEncryptionKeyService(
        storage: storage,
        random: Random(42),
      );

      expect(
        await a.getOrCreateServerKey('srv_1'),
        await b.getOrCreateServerKey('srv_1'),
      );
    });
  });
}
