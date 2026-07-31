import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

/// Probe registered into the user-session scope by [RecordingUserInstaller];
/// its dispose callback flips [disposed] so tests can observe scope
/// teardown (#135).
class UserProbe {
  UserProbe(this.userId);
  final String userId;
  bool disposed = false;
}

/// Probe registered into the *base* (per-server) scope so tests can prove
/// user-session teardown leaves the per-server scope untouched.
class BaseProbe {
  bool disposed = false;
}

/// [ServerScopeInstaller] registering one [BaseProbe] into the per-server
/// scope.
class BaseInstaller implements ServerScopeInstaller {
  final probes = <BaseProbe>[];

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    final probe = BaseProbe();
    probes.add(probe);
    container.registerSingleton<BaseProbe>(
      probe,
      dispose: (p) => p.disposed = true,
    );
  }
}

/// [UserScopeInstaller] that records every install call and registers a
/// fresh [UserProbe] with a teardown callback.
class RecordingUserInstaller implements UserScopeInstaller {
  final installs = <(ServerConfig, String)>[];
  final probes = <UserProbe>[];

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
    String userId,
  ) async {
    installs.add((config, userId));
    final probe = UserProbe(userId);
    probes.add(probe);
    container.registerSingleton<UserProbe>(
      probe,
      dispose: (p) => p.disposed = true,
    );
  }
}

/// User installer that resolves a base-scope service before registering —
/// proving the installer view falls through to the per-server scope.
class BaseResolvingUserInstaller implements UserScopeInstaller {
  BaseProbe? resolvedBase;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
    String userId,
  ) async {
    resolvedBase = container.get<BaseProbe>();
    container.registerSingleton<UserProbe>(UserProbe(userId));
  }
}

/// User installer that always throws, for activation-failure paths.
class FailingUserInstaller implements UserScopeInstaller {
  var calls = 0;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
    String userId,
  ) async {
    calls++;
    throw StateError('user installer boom');
  }
}

ServerConfig _makeConfig({String id = 'server-local-1'}) => ServerConfig(
  id: id,
  displayName: 'Test Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.disconnected,
  bgeServerId: '550e8400-e29b-41d4-a716-446655440000',
  cachedIdentity: ServerIdentity(
    serverId: '550e8400-e29b-41d4-a716-446655440000',
    issuer: 'https://api.example.com',
    wellKnownSchemaVersion: 1,
    name: 'Test BGE Server',
    deviceAuthorizationEndpoint: '/api/auth/device',
    authBasePath: '/api/auth',
    sessionEndpoint: '/api/auth/get-session',
    signOutEndpoint: '/api/auth/sign-out',
    passkeySupported: true,
    twoFactorSupported: true,
    anonymousAuthSupported: true,
  ),
  lastIdentityFetchedAt: DateTime.now().toUtc(),
);

void main() {
  group('UserSessionScope registration', () {
    test('activation registers a resolvable UserSessionScope seam', () async {
      final context = ServerContextImpl(config: _makeConfig());
      addTearDown(context.dispose);

      await context.activate();

      expect(context.container.isRegistered<UserSessionScope>(), isTrue);
      final scope = context.container.get<UserSessionScope>();
      expect(scope.activeUserId, isNull);
    });

    test('the seam is re-registered on a fresh post-suspend scope', () async {
      final context = ServerContextImpl(config: _makeConfig());
      addTearDown(context.dispose);

      await context.activate();
      await context.background();
      await context.suspend();
      await context.activate();

      expect(context.container.isRegistered<UserSessionScope>(), isTrue);
    });
  });

  group('activateUserSession', () {
    test('runs user installers with the config and user id, and the '
        'registered services resolve through context.container', () async {
      final installer = RecordingUserInstaller();
      final config = _makeConfig();
      final context = ServerContextImpl(
        config: config,
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();

      await context.activateUserSession('user-a');

      expect(installer.installs, [(config, 'user-a')]);
      expect(context.activeUserId, 'user-a');
      expect(context.container.get<UserSessionScope>().activeUserId, 'user-a');
      expect(context.container.isRegistered<UserProbe>(), isTrue);
      expect(context.container.get<UserProbe>().userId, 'user-a');
    });

    test('the installer view falls through to the per-server scope', () async {
      final base = BaseInstaller();
      final userInstaller = BaseResolvingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        installers: [base],
        userInstallers: [userInstaller],
      );
      addTearDown(context.dispose);
      await context.activate();

      await context.activateUserSession('user-a');

      expect(userInstaller.resolvedBase, same(base.probes.single));
    });

    test('is idempotent for the already-active user', () async {
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();

      await context.activateUserSession('user-a');
      await context.activateUserSession('user-a');

      expect(installer.installs, hasLength(1));
      expect(installer.probes.single.disposed, isFalse);
    });

    test('a different user replaces the scope: the prior user\'s services '
        'are disposed and per-user singleton identity differs', () async {
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();

      await context.activateUserSession('user-a');
      final probeA = context.container.get<UserProbe>();

      await context.activateUserSession('user-b');
      final probeB = context.container.get<UserProbe>();

      expect(probeA.disposed, isTrue, reason: 'user-a scope must be popped');
      expect(identical(probeA, probeB), isFalse);
      expect(probeB.userId, 'user-b');
      expect(context.activeUserId, 'user-b');
    });

    test('throws StateError when the context is not active', () async {
      final context = ServerContextImpl(config: _makeConfig());
      addTearDown(context.dispose);

      // Never activated: initializing.
      await expectLater(
        context.activateUserSession('user-a'),
        throwsA(isA<StateError>()),
      );

      await context.activate();
      await context.background();
      // Backgrounding is not a session-hosting state either.
      await expectLater(
        context.activateUserSession('user-a'),
        throwsA(isA<StateError>()),
      );
    });

    test('an installer failure discards the partial user scope, leaves the '
        'base scope intact, and a retry starts clean', () async {
      final base = BaseInstaller();
      final failing = FailingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        installers: [base],
        userInstallers: [failing],
      );
      addTearDown(context.dispose);
      await context.activate();

      await expectLater(
        context.activateUserSession('user-a'),
        throwsA(isA<StateError>()),
      );

      expect(context.activeUserId, isNull);
      expect(
        base.probes.single.disposed,
        isFalse,
        reason: 'per-server scope must be untouched',
      );
      expect(context.container.get<BaseProbe>(), same(base.probes.single));
      expect(context.state, ServerContextState.active);

      // Retry hits a clean scope (would throw "already active" otherwise).
      await expectLater(
        context.activateUserSession('user-a'),
        throwsA(isA<StateError>()),
      );
      expect(failing.calls, 2);
    });
  });

  group('deactivateUserSession', () {
    test('disposes the user scope; per-server services survive', () async {
      final base = BaseInstaller();
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        installers: [base],
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();
      await context.activateUserSession('user-a');

      await context.deactivateUserSession();

      expect(installer.probes.single.disposed, isTrue);
      expect(context.container.isRegistered<UserProbe>(), isFalse);
      expect(context.activeUserId, isNull);
      expect(base.probes.single.disposed, isFalse);
      expect(context.container.get<BaseProbe>(), same(base.probes.single));
    });

    test('is a no-op without an active session and is idempotent', () async {
      final context = ServerContextImpl(config: _makeConfig());
      addTearDown(context.dispose);
      await context.activate();

      await context.deactivateUserSession();
      await context.deactivateUserSession();

      expect(context.activeUserId, isNull);
    });

    test('is a no-op on a disposed context', () async {
      final context = ServerContextImpl(config: _makeConfig());
      await context.activate();
      await context.dispose();

      await expectLater(context.deactivateUserSession(), completes);
    });
  });

  group('lifecycle interactions', () {
    test('background tears the user-session scope down — a server switch '
        'never emits an auth transition for the departing server, so the '
        'context must end the session itself (#135 review)', () async {
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();
      await context.activateUserSession('user-a');

      await context.background();

      expect(
        installer.probes.single.disposed,
        isTrue,
        reason: 'leaving the active state must end the user session',
      );
      expect(context.activeUserId, isNull);
      expect(context.container.isRegistered<UserProbe>(), isFalse);

      // Cheap re-activation (container retained), then the next sign-in
      // emission rebuilds the session from clean state.
      await context.activate();
      await context.activateUserSession('user-a');
      expect(installer.installs, hasLength(2));
      expect(context.container.get<UserProbe>().disposed, isFalse);
    });

    test('deactivateUserSession after background is a harmless no-op — '
        'the scope already died with the foreground', () async {
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();
      await context.activateUserSession('user-a');

      await context.background();
      await expectLater(context.deactivateUserSession(), completes);

      expect(context.activeUserId, isNull);
    });

    test('a deactivation issued concurrently with a transition is queued, '
        'never skipped: the caller\'s future completes with the scope '
        'gone (#135 review)', () async {
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();
      await context.activateUserSession('user-a');

      // Fire the transition and the deactivation without awaiting in
      // between — the shared scope-op chain serializes them.
      final transition = context.background();
      final deactivation = context.deactivateUserSession();
      await Future.wait([transition, deactivation]);

      expect(installer.probes.single.disposed, isTrue);
      expect(
        context.activeUserId,
        isNull,
        reason:
            'a silently skipped deactivation would leave the '
            'bookkeeping set and a same-user re-sign-in would reuse a '
            'stale scope',
      );
    });

    test('suspend tears the user-session scope down with the server scope; '
        'a fresh session can be activated after resume', () async {
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        userInstallers: [installer],
      );
      addTearDown(context.dispose);
      await context.activate();
      await context.activateUserSession('user-a');

      await context.background();
      await context.suspend();

      expect(installer.probes.single.disposed, isTrue);
      expect(context.activeUserId, isNull);

      await context.activate();
      await context.activateUserSession('user-a');

      expect(
        installer.installs,
        hasLength(2),
        reason:
            'post-resume same-user activation must reinstall — the '
            'prior scope died when the context left the active state',
      );
      expect(context.container.get<UserProbe>().disposed, isFalse);
    });

    test('context.dispose disposes an active user-session scope', () async {
      final installer = RecordingUserInstaller();
      final context = ServerContextImpl(
        config: _makeConfig(),
        userInstallers: [installer],
      );
      await context.activate();
      await context.activateUserSession('user-a');

      await context.dispose();

      expect(installer.probes.single.disposed, isTrue);
      expect(context.activeUserId, isNull);
    });

    test('user-scope registrations shadow a base registration of the same '
        'type and the base instance resurfaces after deactivation', () async {
      final shared = UserProbe('base');
      final context = ServerContextImpl(
        config: _makeConfig(),
        installers: [
          _InlineBaseInstaller((c) => c.registerSingleton<UserProbe>(shared)),
        ],
        userInstallers: [RecordingUserInstaller()],
      );
      addTearDown(context.dispose);
      await context.activate();

      expect(context.container.get<UserProbe>(), same(shared));

      await context.activateUserSession('user-a');
      expect(context.container.get<UserProbe>().userId, 'user-a');

      await context.deactivateUserSession();
      expect(context.container.get<UserProbe>(), same(shared));
    });
  });
}

/// Adapts a closure into a [ServerScopeInstaller] for one-off base wiring.
class _InlineBaseInstaller implements ServerScopeInstaller {
  _InlineBaseInstaller(this._body);
  final void Function(DependencyContainer container) _body;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    _body(container);
  }
}
