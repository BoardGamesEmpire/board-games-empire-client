import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/orchestration/bootstrap_web_server_scope.dart';

class _MockWellKnownClient extends Mock implements WellKnownClient {}

const _kOrigin = 'https://bge.example.com';
const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: _kOrigin,
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

void main() {
  late _MockWellKnownClient wellKnownClient;
  // Assigned by successful runs so tearDown can dispose the created scope's
  // container; stays null when the fetch fails.
  ActiveServerScope? scope;

  setUp(() {
    wellKnownClient = _MockWellKnownClient();
    scope = null;
  });

  tearDown(() async {
    await scope?.active?.container.dispose();
  });

  Future<ActiveServerScope> bootstrap({
    WebServerScopeInstall? installStorage,
    List<UserScopeInstaller> userInstallers = const [],
  }) => bootstrapWebServerScope(
    wellKnownClient: wellKnownClient,
    // Uri.base has no origin on the VM, so the origin is injected; production
    // defaults to WebDioFactory.currentOrigin (the browser address bar).
    originProvider: () => _kOrigin,
    installStorage: installStorage,
    userInstallers: userInstallers,
  );

  void stubFetchSuccess() =>
      when(() => wellKnownClient.fetchIdentity(any()))
          .thenAnswer((_) async => _identity());

  group('bootstrapWebServerScope', () {
    test('fetches the origin identity and returns a scope with a non-null '
        'active server', () async {
      stubFetchSuccess();

      scope = await bootstrap();

      expect(scope!.active, isNotNull);
      verify(() => wellKnownClient.fetchIdentity(_kOrigin)).called(1);
    });

    test('sources the active server id and display name from the fetched '
        'identity', () async {
      stubFetchSuccess();

      scope = await bootstrap();

      final active = scope!.active!;
      expect(active.serverId, 'server-uuid-1');
      expect(active.displayName, 'Test BGE Server');
      expect(active.identity, _identity());
    });

    test(
      'populates the scope container with a resolvable AuthRepository',
      () async {
        stubFetchSuccess();

        scope = await bootstrap();

        expect(
          scope!.active!.container.get<AuthRepository>(),
          isA<WebAuthRepositoryImpl>(),
        );
      },
    );

    test(
      'builds the server Dio against the same origin used for the fetch',
      () async {
        stubFetchSuccess();

        scope = await bootstrap();

        final dio = scope!.active!.container.get<Dio>();
        expect(dio.options.baseUrl, _kOrigin);
        verify(() => wellKnownClient.fetchIdentity(_kOrigin)).called(1);
      },
    );

    test(
      'propagates well-known fetch failures unchanged (no scope built)',
      () async {
        when(() => wellKnownClient.fetchIdentity(any())).thenThrow(
          const WellKnownUnreachableException(
            serverUrl: _kOrigin,
            message: 'boom',
          ),
        );

        await expectLater(
          bootstrap(),
          throwsA(isA<WellKnownUnreachableException>()),
        );
        // The fetch runs before any container is created, so a failure leaks
        // nothing: `scope` stays null and tearDown disposes nothing.
        expect(scope, isNull);
      },
    );
  });

  // #288: the seam `web_platform` uses to register the drift/wasm data
  // layer without this package depending on a browser-only library. The
  // storage side is tested in `web_storage`; what matters here is the
  // contract — what it is handed, when, and what happens when it fails.
  group('bootstrapWebServerScope storage seam (#288)', () {
    test(
      'is omitted by default — the storage-less scope still builds',
      () async {
        stubFetchSuccess();

        scope = await bootstrap();

        expect(scope!.active, isNotNull);
      },
    );

    test(
      'runs with the identity, and with the network stack already registered',
      () async {
        stubFetchSuccess();
        ServerIdentity? seenIdentity;
        Dio? resolvedDuringInstall;

        scope = await bootstrap(
          installStorage: (container, identity) async {
            seenIdentity = identity;
            // The web installer derives its database name from the identity
            // and resolves per-server resources from this container, so both
            // must already be usable at this point.
            resolvedDuringInstall = container.get<Dio>();
          },
        );

        expect(seenIdentity, _identity());
        expect(resolvedDuringInstall, isNotNull);
        expect(scope!.active!.container.get<Dio>(), resolvedDuringInstall);
      },
    );

    test('can register into the scope the caller then receives', () async {
      stubFetchSuccess();

      scope = await bootstrap(
        installStorage: (container, identity) async =>
            container.registerSingleton<_FakeDatabase>(const _FakeDatabase()),
      );

      expect(scope!.active!.container.get<_FakeDatabase>(), isNotNull);
    });

    test('a storage failure propagates, and disposes what the network '
        'registration had already put in the container', () async {
      stubFetchSuccess();
      var disposed = false;

      await expectLater(
        bootstrap(
          installStorage: (container, identity) async {
            // Stands in for a resource registered before the failure — the
            // real leak this guard exists for is the Dio and the clock.
            container.registerSingleton<_FakeDatabase>(
              const _FakeDatabase(),
              dispose: (_) => disposed = true,
            );
            throw StateError('no storage for you');
          },
        ),
        throwsStateError,
      );

      expect(
        disposed,
        isTrue,
        reason:
            'the caller discards the scope on a failed bootstrap, so the '
            'partial container has to be disposed here or it leaks',
      );
      // Nothing was returned, so tearDown has nothing to dispose.
      expect(scope, isNull);
    });
  });

  group('bootstrapWebServerScope user-scope seam (#137)', () {
    setUp(stubFetchSuccess);

    test('registers a UserSessionScope when there are installers', () async {
      scope = await bootstrap(userInstallers: [_RecordingUserInstaller()]);

      expect(scope!.active!.container.isRegistered<UserSessionScope>(), isTrue);
    });

    test('registers none when there are no per-user services', () async {
      // The shell reads an absent UserSessionScope as "no per-user services
      // on this platform" and skips the scope step. A composition with no
      // installers has none, and must keep that shape rather than cycling an
      // empty child scope on every sign-in.
      scope = await bootstrap();

      expect(
        scope!.active!.container.isRegistered<UserSessionScope>(),
        isFalse,
      );
    });

    test(
      'installers are told the origin identity, server-vended id and all',
      () async {
        final installer = _RecordingUserInstaller();
        scope = await bootstrap(userInstallers: [installer]);

        await scope!.active!.container.get<UserSessionScope>().activate(
          'user-a',
        );

        expect(installer.calls, hasLength(1));
        expect(installer.calls.single.userId, 'user-a');
        expect(installer.calls.single.server.serverId, 'server-uuid-1');
        expect(installer.calls.single.server.displayName, 'Test BGE Server');
      },
    );

    test('per-user services resolve through ActiveServer.container', () async {
      // The point of the whole issue. Every consumer — the household routes,
      // the drawer gate, the re-hydrate triggers — resolves from this one
      // handle. Before #137 web handed out the raw origin container, so a
      // scope could be opened and installed correctly and nothing could see
      // into it.
      scope = await bootstrap(userInstallers: [_RecordingUserInstaller()]);
      final container = scope!.active!.container;

      expect(container.isRegistered<_UserService>(), isFalse);

      await container.get<UserSessionScope>().activate('user-a');

      expect(container.isRegistered<_UserService>(), isTrue);
      expect(container.get<_UserService>().userId, 'user-a');
    });

    test('the origin scope still resolves while a session is open', () async {
      scope = await bootstrap(userInstallers: [_RecordingUserInstaller()]);
      final container = scope!.active!.container;

      await container.get<UserSessionScope>().activate('user-a');

      // Fall-through, not shadowing: the network stack is still reachable.
      expect(container.get<AuthRepository>(), isA<WebAuthRepositoryImpl>());
      expect(container.get<Dio>(), isA<Dio>());
    });

    test(
      'a sign-out closes the per-user services and hides them again',
      () async {
        scope = await bootstrap(userInstallers: [_RecordingUserInstaller()]);
        final container = scope!.active!.container;
        final session = container.get<UserSessionScope>();
        await session.activate('user-a');
        final service = container.get<_UserService>();

        await session.deactivate();

        expect(service.disposed, isTrue);
        expect(container.isRegistered<_UserService>(), isFalse);
      },
    );

    test('a same-origin user change rebuilds the per-user services', () async {
      scope = await bootstrap(userInstallers: [_RecordingUserInstaller()]);
      final container = scope!.active!.container;
      final session = container.get<UserSessionScope>();
      await session.activate('user-a');
      final first = container.get<_UserService>();

      await session.deactivate();
      await session.activate('user-b');

      expect(first.disposed, isTrue);
      expect(container.get<_UserService>(), isNot(same(first)));
      expect(container.get<_UserService>().userId, 'user-b');
    });

    test(
      'disposing the scope ends a live session and closes the holder',
      () async {
        final built = await bootstrap(
          userInstallers: [_RecordingUserInstaller()],
        );
        final container = built.active!.container;
        final session = container.get<UserSessionScope>();
        await session.activate('user-a');
        final service = container.get<_UserService>();

        await container.dispose();
        // Disposed here rather than in tearDown.
        scope = null;

        expect(service.disposed, isTrue);
        // Terminal: a late activation cannot build a scope nothing will
        // dispose. (The container is gone, so this is the holder's own guard.)
        await expectLater(session.activate('user-b'), throwsStateError);
      },
    );

    test('a dispose racing an in-flight activation waits for it, rather than '
        'tearing the scope out from under the installers', () async {
      // The shell fires `activate` unawaited from its auth listener, so this
      // overlap is producible. Closing the host directly would step outside
      // the holder's serialization chain: the partial child would be
      // disposed mid-loop and the origin scope with it, so every installer
      // after the one in flight would fail resolving what it needs.
      //
      // Both halves matter. `_ParkingInstaller` puts the activation *past*
      // its first await, and `_OriginResolvingInstaller` runs after it and
      // resolves from the origin scope, which is what real installers do
      // (`UserSessionScopeInstaller` resolves the database, clock and auth
      // repository). An installer that only registers would not notice.
      final parking = _ParkingInstaller();
      final resolving = _OriginResolvingInstaller();
      final built = await bootstrap(userInstallers: [parking, resolving]);
      final container = built.active!.container;

      final activating = container.get<UserSessionScope>().activate('user-a');
      // Let the activation start and park inside the first installer.
      await Future<void>.delayed(Duration.zero);
      expect(parking.started, isTrue);

      final disposing = container.dispose();
      // Disposed here rather than in tearDown.
      scope = null;
      parking.release();

      await activating;
      await disposing;

      // The second installer ran, and resolved through to a live origin
      // scope rather than one already torn down underneath it.
      expect(resolving.resolved, isA<Dio>());
      expect(container.isRegistered<_UserService>(), isFalse);
    });
  });
}

/// Stands in for the `ServerDatabase` the real seam registers; this package
/// cannot see that type, which is the entire point of the seam.
class _FakeDatabase {
  const _FakeDatabase();
}

/// Stands in for a per-user repository: registered into the user-session
/// scope, and closed when that scope pops.
class _UserService {
  _UserService(this.userId);
  final String userId;
  bool disposed = false;
}

/// Parks the activation past its first await until [release] is called, so a
/// test can land another scope operation while one is genuinely in flight.
class _ParkingInstaller implements UserScopeInstaller {
  final _gate = Completer<void>();
  bool started = false;

  void release() => _gate.complete();

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    started = true;
    await _gate.future;
  }
}

/// Resolves a service the **origin** scope owns, the way every real
/// user-scope installer does. An installer that only registered would not
/// notice the origin scope being disposed underneath it.
class _OriginResolvingInstaller implements UserScopeInstaller {
  Object? resolved;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    resolved = container.get<Dio>();
    container.registerSingleton<_UserService>(_UserService(userId));
  }
}

/// Registers a [_UserService] for the session's user, recording what the
/// narrowed seam handed it.
class _RecordingUserInstaller implements UserScopeInstaller {
  final calls = <({ScopedServer server, String userId})>[];

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    calls.add((server: server, userId: userId));
    final service = _UserService(userId);
    container.registerSingleton<_UserService>(
      service,
      dispose: (s) => s.disposed = true,
    );
  }
}
