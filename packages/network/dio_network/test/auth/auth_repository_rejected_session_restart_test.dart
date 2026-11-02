import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:di/di.dart' show LocalClockService;
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import 'package:dio_network/src/auth/auth_repository_impl.dart';
import 'package:dio_network/src/auth/token_storage_service.dart';

import '../support/in_memory_session_tombstone_store.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

const _kAuthBase = '/api/auth';
const _kServerId = 'server-1';

ServerIdentity _identity() => ServerIdentity(
  serverId: _kServerId,
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

Map<String, dynamic> _wireUser() => {
  'id': 'user-1',
  'name': 'testuser',
  'email': 'test@example.com',
  'emailVerified': true,
  'createdAt': '2024-01-01T00:00:00.000Z',
  'updatedAt': '2024-01-01T00:00:00.000Z',
};

/// A rejected or signed-out session stays refused across a restart (#356).
///
/// Everything under the repository is real except the keychain, whose delete
/// throws, and the marker's database. A second repository over a fresh
/// [TokenStorageService] and the same two stores is the next cold start, and
/// the server is unreachable by then.
void main() {
  late Map<String, String> keychain;
  late InMemorySessionTombstoneStore tombstones;
  late _MockSecureStorage secure;

  // Inside the confirmed session window, and after the material was persisted,
  // so the seeded payload qualifies for an offline restore on its own merits.
  final now = DateTime.utc(2026, 1, 2);

  TokenStorageService freshStorage() => TokenStorageService(
    serverId: _kServerId,
    tombstones: tombstones,
    storage: secure,
  );

  AuthRepositoryImpl repositoryOver(Dio dio) {
    final repository = AuthRepositoryImpl(
      identity: _identity(),
      tokenStorage: freshStorage(),
      dio: dio,
      clock: LocalClockService(() => now),
      deviceNowUtc: () => now,
    );
    addTearDown(repository.onDispose);
    return repository;
  }

  /// What a later launch finds with no route to the server.
  AuthRepositoryImpl offlineColdStart() =>
      repositoryOver(unreachableDio(DioExceptionType.connectionError));

  /// A session the server has confirmed, as a reconcile leaves it on disk.
  Future<void> seedRestorableSession() => freshStorage().store(
    token: 'tok-abc',
    expiresAt: DateTime.utc(2026, 1, 8),
    persistedAt: DateTime.utc(2026, 1, 1),
    user: AuthUser.fromJson(_wireUser()),
  );

  void failKeychainDeletes() {
    when(() => secure.delete(key: any(named: 'key')))
        .thenThrow(StateError('keychain unavailable'));
  }

  setUp(() {
    keychain = {};
    tombstones = InMemorySessionTombstoneStore();
    secure = _MockSecureStorage();
    when(() => secure.read(key: any(named: 'key'))).thenAnswer(
      (invocation) async => keychain[invocation.namedArguments[#key]],
    );
    when(
      () => secure.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      keychain[invocation.namedArguments[#key] as String] =
          invocation.namedArguments[#value] as String;
    });
    when(() => secure.delete(key: any(named: 'key')))
        .thenAnswer((invocation) async {
          keychain.remove(invocation.namedArguments[#key]);
        });
  });

  test('with no marker, the same payload restores at a cold start', () async {
    await seedRestorableSession();

    final second = offlineColdStart();

    expect((await second.restoreCachedSession())?.token, 'tok-abc');
    expect(second.currentAuthState, isA<AuthStateAuthenticated>());
  });

  test('a session the server rejected, with a failed delete, is not restored '
      'at the next cold start', () async {
    await seedRestorableSession();
    failKeychainDeletes();

    final first = repositoryOver(cannedDio(body: '', statusCode: 401));
    expect(await first.getSession(), isNull);
    expect(first.currentAuthState, isA<AuthStateUnauthenticated>());
    expect(keychain, isNotEmpty, reason: 'the payload survived the delete');

    final second = offlineColdStart();
    expect(await second.restoreCachedSession(), isNull);
    expect(second.currentAuthState, isNot(isA<AuthStateAuthenticated>()));
  });

  test('a signed-out session, with a failed delete, is not restored', () async {
    await seedRestorableSession();
    failKeychainDeletes();

    final first = repositoryOver(cannedDio(body: '', statusCode: 200));
    await expectLater(
      first.signOut(),
      throwsA(isA<AuthSignOutPersistenceException>()),
    );
    expect(keychain, isNotEmpty, reason: 'the payload survived the delete');

    expect(await offlineColdStart().restoreCachedSession(), isNull);
  });

  test('both stores failing on a rejected reconcile still refuses the '
      'sign-in', () async {
    tombstones.failWrites = true;
    failKeychainDeletes();

    final repository = repositoryOver(
      routingDio({
        '/sign-in/email': (
          jsonEncode({'token': 'tok-abc', 'user': _wireUser()}),
          200,
        ),
        '/get-session': ('', 401),
      }),
    );

    await expectLater(
      repository.signIn(email: 'a@b.c', password: 'pw'),
      throwsA(isA<AuthServerException>()),
    );
    expect(repository.currentAuthState, isA<AuthStateUnauthenticated>());
  });
}
