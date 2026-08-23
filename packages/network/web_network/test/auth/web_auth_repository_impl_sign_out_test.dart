import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/web_auth_repository_impl.dart';

class MockDio extends Mock implements Dio {}

const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
);

Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': 'session-tok-abc',
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': 'user-1',
  },
  'user': {
    'id': 'user-1',
    'name': 'testuser',
    'email': 'web@example.com',
    'emailVerified': true,
    'createdAt': '2024-01-01T00:00:00.000Z',
    'updatedAt': '2024-01-01T00:00:00.000Z',
  },
};

/// Pins the web side of the [AuthRepository.signOut] contract (#37
/// review). [WebAuthRepositoryImpl] has no persisted session material of
/// its own (the browser owns the httpOnly cookie), so — unlike the native
/// impl — its sign-out has nothing that can fail persistence: it NEVER
/// throws, and it reaches [AuthStateUnauthenticated] on every path. These
/// tests lock that in so a future refactor cannot reintroduce a path where
/// the state stream re-asserts an ended session.
///
/// The same absence of local session material is why web **awaits** the
/// revocation POST where native fires and forgets it (#180): with no
/// credential to clear locally, the `Set-Cookie: Max-Age=0` on that
/// response is the only thing that actually ends the session. That is
/// pinned below too — it reads as a parity gap and is not one.
///
/// Awaiting is only defensible because the local transition happens
/// FIRST, synchronously, before the POST goes out — so the await never
/// holds the gate. Both halves are pinned; either one alone is a defect.
void main() {
  late MockDio mockDio;
  late WebAuthRepositoryImpl repo;

  setUp(() {
    mockDio = MockDio();
    repo = WebAuthRepositoryImpl(identity: _identity(), dio: mockDio);
  });

  tearDown(() async => repo.onDispose());

  group('signOut() invariant (web)', () {
    test('completes and transitions to unauthenticated on success', () async {
      when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenAnswer(
        (_) async => Response<void>(
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );

      await expectLater(repo.signOut(), completes);

      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });

    test('a failed server call does not throw — best-effort — and still '
        'transitions to unauthenticated', () async {
      when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: ''),
        ),
      );

      await expectLater(repo.signOut(), completes);

      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });

    test('an ended (authenticated → signed-out) session is never '
        're-asserted by the stream, even when the server call fails', () async {
      // Reach an authenticated state first via the session endpoint.
      when(
        () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
      ).thenAnswer(
        (_) async => Response(
          data: _sessionJson(),
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );
      await repo.getSession();
      expect(await repo.watchAuthState().first, isA<AuthStateAuthenticated>());

      when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: ''),
        ),
      );

      final emissions = <AuthState>[];
      final sub = repo.watchAuthState().listen(emissions.add);
      await pumpEventQueue();

      await expectLater(repo.signOut(), completes);
      await pumpEventQueue();
      await sub.cancel();

      final afterSignOut = emissions.skipWhile(
        (s) => s is! AuthStateUnauthenticated,
      );
      expect(afterSignOut, isNotEmpty);
      expect(afterSignOut.whereType<AuthStateAuthenticated>(), isEmpty);
    });
  });

  group(
    'signOut() awaits the revocation POST (deliberately unlike native)',
    () {
      test('does not complete until the POST resolves — the Set-Cookie on that '
          'response is the only teardown web has', () async {
        final gate = Completer<Response<void>>();
        when(
          () => mockDio.post<void>('$_kAuthBase/sign-out'),
        ).thenAnswer((_) => gate.future);

        var completed = false;
        final pending = repo.signOut().then((_) => completed = true);
        await pumpEventQueue();

        // Fire-and-forget here would let the caller — and AuthBloc's gate —
        // proceed while the cookie is still live, so a page reload in this
        // window would send it again and sign the user straight back in.
        expect(
          completed,
          isFalse,
          reason: 'signOut must not resolve before the server revokes',
        );

        gate.complete(
          Response<void>(
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ),
        );
        await pending;
        expect(completed, isTrue);
      });

      // The transition is what makes the await above affordable, so it has
      // to be observable WHILE the POST is still pending — not merely once
      // it has failed. A `thenThrow` stub cannot show that: it raises at
      // call time, so the assertion would run after the failure had already
      // propagated, and a state set only on the way out would pass. In
      // production a receiveTimeout raises ten seconds in, and the question
      // is what the gate sees for those ten seconds.
      test('the state is already unauthenticated while the POST is still '
          'pending — the await must not hold the gate', () async {
        final gate = Completer<Response<void>>();
        when(
          () => mockDio.post<void>('$_kAuthBase/sign-out'),
        ).thenAnswer((_) => gate.future);

        final emissions = <AuthState>[];
        final sub = repo.watchAuthState().listen(emissions.add);

        final pending = repo.signOut();
        await pumpEventQueue();

        expect(
          repo.currentAuthState,
          isA<AuthStateUnauthenticated>(),
          reason:
              'a hung server would otherwise hold the gate on a spinner '
              'for the full 10s receiveTimeout',
        );
        expect(emissions.whereType<AuthStateUnauthenticated>(), isNotEmpty);

        gate.complete(
          Response<void>(
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ),
        );
        await pending;
        await sub.cancel();
      });

      test('a non-2xx revocation still leaves the state unauthenticated — '
          'validateStatus resolves it rather than throwing', () async {
        when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenAnswer(
          (_) async => Response<void>(
            statusCode: 500,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        await expectLater(repo.signOut(), completes);
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
      });

      test(
        'a transport failure still leaves the state unauthenticated',
        () async {
          when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenThrow(
            DioException(
              type: DioExceptionType.receiveTimeout,
              requestOptions: RequestOptions(path: ''),
            ),
          );

          await expectLater(repo.signOut(), completes);
          expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
        },
      );
    },
  );

  // Web's half of the supersession guard native gained in #146. The epoch
  // is bumped as signOut()'s first statement, so a session response still
  // in flight at that moment describes a session the user has already
  // ended — the newer intent wins and the response is dropped.
  group('sign-out supersedes an in-flight getSession()', () {
    setUp(() {
      when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenAnswer(
        (_) async => Response<void>(
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );
    });

    test(
      'a session response resolving AFTER sign-out is discarded — it must '
      'not re-assert a session whose cookie the server just revoked',
      () async {
        final gate = Completer<Response<Map<String, dynamic>>>();
        when(
          () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
        ).thenAnswer((_) => gate.future);

        final inFlight = repo.getSession();
        await pumpEventQueue();

        await repo.signOut();
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());

        // The endpoint now answers with a perfectly valid live session.
        // Too late: the user's sign-out is the newer intent.
        gate.complete(
          Response(
            data: _sessionJson(),
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        expect(await inFlight, isNull);
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
      },
    );

    test('the discard does not emit — the stream never shows a session '
        'after the unauthenticated transition', () async {
      final gate = Completer<Response<Map<String, dynamic>>>();
      when(
        () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
      ).thenAnswer((_) => gate.future);

      final emissions = <AuthState>[];
      final sub = repo.watchAuthState().listen(emissions.add);
      final inFlight = repo.getSession();
      await pumpEventQueue();

      await repo.signOut();
      gate.complete(
        Response(
          data: _sessionJson(),
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );
      await inFlight;
      await pumpEventQueue();
      await sub.cancel();

      final afterSignOut = emissions.skipWhile(
        (s) => s is! AuthStateUnauthenticated,
      );
      expect(afterSignOut.whereType<AuthStateAuthenticated>(), isEmpty);
    });

    test('a 401 resolving after sign-out is discarded too — it must not '
        'even re-emit unauthenticated, since nothing was checked', () async {
      final gate = Completer<Response<Map<String, dynamic>>>();
      when(
        () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
      ).thenAnswer((_) => gate.future);

      final inFlight = repo.getSession();
      await pumpEventQueue();
      await repo.signOut();

      final emissions = <AuthState>[];
      final sub = repo.watchAuthState().listen(emissions.add);
      gate.complete(
        Response(statusCode: 401, requestOptions: RequestOptions(path: '')),
      );

      expect(await inFlight, isNull);
      await pumpEventQueue();
      await sub.cancel();

      // Only the replayed current state, no fresh transition.
      expect(emissions, hasLength(1));
    });
  });
}
