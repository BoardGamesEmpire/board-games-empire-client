import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_network/src/auth/auth_repository_impl.dart';
import 'package:dio_network/src/auth/token_storage_service.dart';
import 'package:dio_network/src/network/network_log_interceptor.dart';
import 'package:dio_network/src/network/token_interceptor.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/in_memory_session_tombstone_store.dart';

/// The keychain. Stubbed in `setUp` over a [Map] so a payload written by one
/// call is read back by the next. A mocktail mock rather than a hand-rolled
/// fake, matching the sibling suites: `FlutterSecureStorage` has far more
/// surface than [TokenStorageService] touches.
class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// Records the path and `Authorization` header of every request that reaches
/// the transport, which is what the server would see.
class _RecordingAdapter implements HttpClientAdapter {
  final List<({String path, String? authorization})> requests = [];

  Iterable<({String path, String? authorization})> requestsTo(String path) =>
      requests.where((request) => request.path == path);

  String? authorizationFor(String path) =>
      requestsTo(path).single.authorization;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add((
      path: options.path,
      authorization: options.headers['Authorization'] as String?,
    ));
    return ResponseBody.fromString('', 200);
  }
}

const _signOutEndpoint = '/api/auth/sign-out';

ServerIdentity _identity() => const ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: _signOutEndpoint,
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
  strategies: [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '/api/auth/sign-in/email',
      signUpEndpoint: '/api/auth/sign-up/email',
    ),
  ],
);

/// Pins what the sign-out POST puts on the wire (#433).
///
/// Everything between the repository and the transport is real: the Dio, the
/// production interceptor order, [TokenStorageService] and its sign-out latch.
/// Only the keychain and the socket are replaced. The sibling
/// `auth_repository_impl_sign_out_test.dart` mocks [Dio] outright, so it
/// cannot see the [TokenInterceptor] at all.
///
/// The race: `signOut()` latches storage, so by the time Dio runs the POST
/// through the interceptor chain `retrieve()` normally reports nothing and the
/// interceptor leaves the explicit header alone. If a sign-in lands before the
/// chain reads storage, the interceptor overwrites that header with the NEW
/// session's token and the POST revokes the wrong session.
void main() {
  late Map<String, String> keychain;
  late TokenStorageService storage;
  late _RecordingAdapter adapter;
  late Dio dio;
  late AuthRepositoryImpl repository;

  final t0 = DateTime.utc(2026);

  /// The sign-out POST is fire-and-forget, so `signOut()` resolving says
  /// nothing about whether it has been sent.
  Future<void> flushRequests() => pumpEventQueue();

  setUp(() {
    keychain = {};
    final secure = _MockSecureStorage();
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

    storage = TokenStorageService(
      serverId: 'server-1',
      tombstones: InMemorySessionTombstoneStore(),
      storage: secure,
    );
    adapter = _RecordingAdapter();
    dio =
        Dio(
            BaseOptions(
              baseUrl: 'https://api.example.com',
              validateStatus: (_) => true,
            ),
          )
          ..httpClientAdapter = adapter
          // The order registerServerNetwork builds, minus the clock-skew
          // interceptor, which sits after the token one and cannot affect it.
          // Request tracing is off so a passing run prints nothing.
          ..interceptors.addAll([
            NetworkLogInterceptor(traceRequests: false),
            TokenInterceptor(tokenStorage: storage),
          ]);
    repository = AuthRepositoryImpl(
      identity: _identity(),
      serverUrl: 'https://api.example.com',
      tokenStorage: storage,
      dio: dio,
    );
  });

  tearDown(() async {
    await repository.onDispose();
    dio.close();
  });

  // Gaps 0-3 are where the issue's probe found the interceptor winning; 4 and 8
  // are past the window and must keep passing.
  for (final gap in [0, 1, 2, 3, 4, 8]) {
    test('sign-out sends the departing token when another sign-in lands '
        '$gap timer turns later', () async {
      await storage.store(token: 'tok-A', expiresAt: null, persistedAt: t0);

      await repository.signOut();
      for (var i = 0; i < gap; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await storage.store(token: 'tok-B', expiresAt: null, persistedAt: t0);
      await flushRequests();

      expect(adapter.authorizationFor(_signOutEndpoint), 'Bearer tok-A');
    });
  }

  test('sign-out with no stored token sends no Authorization header', () async {
    await repository.signOut();
    await flushRequests();

    expect(adapter.requestsTo(_signOutEndpoint), hasLength(1));
    expect(adapter.authorizationFor(_signOutEndpoint), isNull);
  });
}
