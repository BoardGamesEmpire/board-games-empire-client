import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:key_storage/key_storage.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// In-memory secure storage that records each call in [log]. While
/// [readGate] is pending, every read waits on it, so a test can start a
/// second operation while a read is still in flight. A read takes its value
/// when it is issued, as a platform reply already on its way would.
///
/// Two fakes can share one [log]; [label] then tells their calls apart.
class _FakeSecureStorage extends Fake implements FlutterSecureStorage {
  _FakeSecureStorage({
    Map<String, String>? entries,
    List<String>? log,
    this.label = '',
  }) : entries = entries ?? {},
       log = log ?? [];

  final Map<String, String> entries;
  final List<String> log;
  final String label;
  Completer<void>? readGate;

  /// Thrown by the next read, which then clears it.
  Object? nextReadFailure;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    log.add('${label}read $key');
    final value = entries[key];
    final failure = nextReadFailure;
    nextReadFailure = null;
    await readGate?.future;
    if (failure != null) throw failure;
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    log.add('${label}write $key');
    entries[key] = value!;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    log.add('${label}delete $key');
    entries.remove(key);
  }
}

/// Lets every pending microtask and zero-delay timer run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

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
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

      final key = await service.getOrCreateServerKey('srv_1');

      expect(key, matches(keyPattern));
    });

    test('persists a newly generated key before returning it', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

      final key = await service.getOrCreateServerKey('srv_1');

      verify(() => storage.write(key: 'encryption_key:srv_1', value: key))
          .called(1);
    });

    test('returns the stored key without regenerating', () async {
      final stored = 'a' * 64;
      when(() => storage.read(key: 'encryption_key:srv_1'))
          .thenAnswer((_) async => stored);

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
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

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
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

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
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

      final key = await service.getOrCreateMetaKey();

      expect(key, matches(keyPattern));
      verify(() => storage.write(key: 'encryption_key:meta', value: key))
          .called(1);
    });

    test('returns the stored meta key without regenerating', () async {
      final stored = 'b' * 64;
      when(() => storage.read(key: 'encryption_key:meta'))
          .thenAnswer((_) async => stored);

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
      when(() => storage.read(key: 'encryption_key:srv_1'))
          .thenAnswer((_) async => held);
      when(() => storage.delete(key: 'encryption_key:srv_1'))
          .thenAnswer((_) async => held = null);

      final before = await service.getOrCreateServerKey('srv_1');
      await service.deleteServerKey('srv_1');
      final after = await service.getOrCreateServerKey('srv_1');

      expect(before, isNot(after));
    });
  });

  group('operations on one key run one at a time (#185)', () {
    test('two creations racing on an empty entry share one key', () async {
      final storage = _FakeSecureStorage()..readGate = Completer<void>();
      final service = SecureStorageEncryptionKeyService(storage: storage);

      final first = service.getOrCreateServerKey('srv_1');
      final second = service.getOrCreateServerKey('srv_1');
      await _settle();
      storage.readGate!.complete();

      expect(await first, await second);
      expect(
        storage.log.where((call) => call.startsWith('write')),
        hasLength(1),
      );
    });

    test('a delete issued while a read is in flight waits for it', () async {
      final stored = 'a' * 64;
      final storage = _FakeSecureStorage(
        entries: {'encryption_key:srv_1': stored},
      )..readGate = Completer<void>();
      final service = SecureStorageEncryptionKeyService(storage: storage);

      final read = service.getOrCreateServerKey('srv_1');
      final deletion = service.deleteServerKey('srv_1');
      final readAfterDelete = service.getOrCreateServerKey('srv_1');
      await _settle();

      expect(storage.log, ['read encryption_key:srv_1']);

      storage.readGate!.complete();
      expect(await read, stored);
      await deletion;
      expect(await readAfterDelete, isNot(stored));
    });

    test('keys of different servers do not wait on each other', () async {
      final storage = _FakeSecureStorage(
        entries: {'encryption_key:srv_2': 'b' * 64},
      )..readGate = Completer<void>();
      final service = SecureStorageEncryptionKeyService(storage: storage);

      unawaited(service.getOrCreateServerKey('srv_1'));
      final deletion = service.deleteServerKey('srv_2');
      await _settle();

      await deletion;
      expect(storage.entries, isNot(contains('encryption_key:srv_2')));
      storage.readGate!.complete();
    });

    test('a failed read is not served to the next caller', () async {
      final stored = 'a' * 64;
      final storage = _FakeSecureStorage(
        entries: {'encryption_key:srv_1': stored},
      )..nextReadFailure = PlatformException(code: 'Exception encountered');
      final service = SecureStorageEncryptionKeyService(storage: storage);

      final failed = service.getOrCreateServerKey('srv_1');
      final next = service.getOrCreateServerKey('srv_1');

      await expectLater(failed, throwsA(isA<EncryptionKeyUnavailableError>()));
      expect(await next, stored);
    });
  });

  group('finding a key without creating one (#428)', () {
    test('findServerKey returns the stored key', () async {
      final stored = 'a' * 64;
      final storage = _FakeSecureStorage(
        entries: {'encryption_key:srv_1': stored},
      );
      final service = SecureStorageEncryptionKeyService(storage: storage);

      expect(await service.findServerKey('srv_1'), stored);
    });

    test('findServerKey returns null and stores nothing', () async {
      final storage = _FakeSecureStorage();
      final service = SecureStorageEncryptionKeyService(storage: storage);

      expect(await service.findServerKey('srv_1'), isNull);
      expect(storage.entries, isEmpty);
    });

    test('findMetaKey reads the reserved meta entry', () async {
      final stored = 'b' * 64;
      final storage = _FakeSecureStorage(
        entries: {'encryption_key:meta': stored},
      );
      final service = SecureStorageEncryptionKeyService(storage: storage);

      expect(await service.findMetaKey(), stored);
    });

    test('findServerKey rejects an empty or reserved id', () {
      final service = SecureStorageEncryptionKeyService(
        storage: _FakeSecureStorage(),
      );

      expect(() => service.findServerKey(''), throwsA(isA<ArgumentError>()));
      expect(
        () => service.findServerKey('meta'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a find queued behind a creation sees the created key', () async {
      final storage = _FakeSecureStorage()..readGate = Completer<void>();
      final service = SecureStorageEncryptionKeyService(storage: storage);

      final created = service.getOrCreateServerKey('srv_1');
      final found = service.findServerKey('srv_1');
      await _settle();
      storage.readGate!.complete();

      expect(await found, await created);
    });
  });

  group('keys move out of the store the app shares (#428)', () {
    late List<String> log;
    late _FakeSecureStorage keyStore;
    late _FakeSecureStorage sharedStore;
    late SecureStorageEncryptionKeyService service;

    setUp(() {
      log = [];
      keyStore = _FakeSecureStorage(log: log, label: 'keys:');
      sharedStore = _FakeSecureStorage(log: log, label: 'shared:');
      service = SecureStorageEncryptionKeyService(
        storage: keyStore,
        legacyStorage: sharedStore,
      );
    });

    test('a key found only in the shared store is moved, then used', () async {
      final stored = 'a' * 64;
      sharedStore.entries['encryption_key:srv_1'] = stored;

      expect(await service.findServerKey('srv_1'), stored);
      expect(keyStore.entries, {'encryption_key:srv_1': stored});
      expect(sharedStore.entries, isEmpty);
      expect(
        log.indexOf('keys:write encryption_key:srv_1'),
        lessThan(log.indexOf('shared:delete encryption_key:srv_1')),
        reason: 'the copy is written before the original is deleted',
      );
    });

    test('the meta key moves too', () async {
      final stored = 'b' * 64;
      sharedStore.entries['encryption_key:meta'] = stored;

      expect(await service.findMetaKey(), stored);
      expect(keyStore.entries, {'encryption_key:meta': stored});
      expect(sharedStore.entries, isEmpty);
    });

    test('the shared store is not read once the key has moved', () async {
      keyStore.entries['encryption_key:srv_1'] = 'c' * 64;

      await service.findServerKey('srv_1');

      expect(log, ['keys:read encryption_key:srv_1']);
    });

    // Its database file does not exist yet, so no key moved from the shared
    // store could open it. Reading the shared store here would fix that
    // store's settings for the session's token calls, on a fresh install
    // too, since the plugin applies the first caller's.
    test('a new key is made in the key store without reading the shared '
        'store', () async {
      final key = await service.getOrCreateServerKey('srv_1');

      expect(keyStore.entries, {'encryption_key:srv_1': key});
      expect(log.where((call) => call.startsWith('shared:')), isEmpty);
    });

    test('a delete removes the key from both stores', () async {
      keyStore.entries['encryption_key:srv_1'] = 'd' * 64;
      sharedStore.entries['encryption_key:srv_1'] = 'e' * 64;

      await service.deleteServerKey('srv_1');

      expect(keyStore.entries, isEmpty);
      expect(sharedStore.entries, isEmpty);
    });
  });

  group('production stores', () {
    test('the key store is its own Android namespace, never reset', () {
      expect(
        SecureStorageEncryptionKeyService.androidKeyStoreOptions.toMap(),
        allOf(
          containsPair('resetOnError', 'false'),
          containsPair('storageNamespace', 'bge_encryption_keys'),
        ),
      );
    });

    test('the shared store is read without resetting it on error', () {
      expect(
        SecureStorageEncryptionKeyService.androidSharedStoreOptions.toMap(),
        allOf(
          containsPair('resetOnError', 'false'),
          containsPair('storageNamespace', ''),
        ),
      );
    });
  });

  group('a key store that cannot be reached (#428)', () {
    final failure = PlatformException(
      code: 'Exception encountered',
      message: 'Keystore operation failed',
    );

    Matcher unavailableCausedBy(Object cause) =>
        isA<EncryptionKeyUnavailableError>().having(
          (error) => error.cause,
          'cause',
          same(cause),
        );

    test('a failed read is reported as unavailable, not as no key', () async {
      when(() => storage.read(key: any(named: 'key'))).thenThrow(failure);

      await expectLater(
        service.getOrCreateServerKey('srv_1'),
        throwsA(unavailableCausedBy(failure)),
      );
      verifyNever(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      );
    });

    test('a failed write is reported as unavailable', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenThrow(failure);

      await expectLater(
        service.getOrCreateMetaKey(),
        throwsA(unavailableCausedBy(failure)),
      );
    });

    test('a failed delete is reported as unavailable', () async {
      when(() => storage.delete(key: any(named: 'key'))).thenThrow(failure);

      await expectLater(
        service.deleteServerKey('srv_1'),
        throwsA(unavailableCausedBy(failure)),
      );
    });
  });

  group('key generation', () {
    test('consumes the injected random source', () async {
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

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
