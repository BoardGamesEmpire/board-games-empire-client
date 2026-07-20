import 'package:app_shell/src/observability/active_server_feedback_target_resolver.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:observability/observability.dart';

/// Contract pinned (#97):
///
/// - No scope / no active server → null (the service queues untagged).
/// - Active server → a target carrying `identity.serverId` (the stable
///   `bgeServerId`), regardless of auth — the tag must exist even when
///   nothing can send, or a later drain could deliver to the wrong
///   server.
/// - The transport is attached only when the active container holds an
///   authenticated [AuthRepository] AND a registered [FeedbackTransport].
/// - The scope is read through [scopeSource] fresh per resolve — a
///   replaced scope (bootstrap retry) is picked up without
///   re-registration.
void main() {
  const authBase = '/api/auth';

  ServerIdentity identity({String serverId = 'bge-uuid-1'}) => ServerIdentity(
    serverId: serverId,
    issuer: 'https://bge.example.com',
    wellKnownSchemaVersion: 1,
    name: 'Test BGE Server',
    deviceAuthorizationEndpoint: '$authBase/device',
    authBasePath: authBase,
    sessionEndpoint: '$authBase/get-session',
    signOutEndpoint: '$authBase/sign-out',
    passkeySupported: false,
    twoFactorSupported: false,
    anonymousAuthSupported: false,
    strategies: const [
      EmailAndPasswordStrategy(
        signUpDisabled: false,
        signInEndpoint: '$authBase/sign-in/email',
        signUpEndpoint: '$authBase/sign-up/email',
      ),
    ],
  );

  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
  });

  tearDown(() async {
    await container.dispose();
  });

  ActiveServer activeServer({String serverId = 'bge-uuid-1'}) => ActiveServer(
    serverId: 'local-1',
    displayName: 'Test BGE Server',
    identity: identity(serverId: serverId),
    container: container,
  );

  ActiveServerFeedbackTargetResolver resolver(ActiveServerScope? scope) =>
      ActiveServerFeedbackTargetResolver(scopeSource: () => scope);

  group('ActiveServerFeedbackTargetResolver', () {
    test('resolves null when no scope exists yet (pre-bootstrap / failed '
        'boot)', () {
      expect(resolver(null).resolve(), isNull);
    });

    test('resolves null when the scope has no active server', () {
      expect(resolver(_FakeScope(null)).resolve(), isNull);
    });

    test('active but unauthenticated → target with the identity serverId '
        '(bgeServerId) and a null transport', () {
      container.registerSingleton<AuthRepository>(
        _FakeAuthRepository(const AuthStateUnauthenticated()),
      );
      container.registerSingleton<FeedbackTransport>(_FakeTransport());

      final target = resolver(_FakeScope(activeServer())).resolve();

      expect(target, isNotNull);
      expect(target!.serverId, 'bge-uuid-1');
      expect(target.transport, isNull);
    });

    test('tags with identity.serverId, not the client-local '
        'ActiveServer.serverId', () {
      final target = resolver(_FakeScope(activeServer())).resolve();

      expect(target!.serverId, 'bge-uuid-1');
      expect(target.serverId, isNot('local-1'));
    });

    test('authenticated with a registered transport → the transport is '
        'attached', () {
      final transport = _FakeTransport();
      container.registerSingleton<AuthRepository>(
        _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
      );
      container.registerSingleton<FeedbackTransport>(transport);

      final target = resolver(_FakeScope(activeServer())).resolve();

      expect(target!.transport, same(transport));
    });

    test('authenticated but no FeedbackTransport registered (network leg '
        'not installed) → null transport, not a StateError', () {
      container.registerSingleton<AuthRepository>(
        _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
      );

      final target = resolver(_FakeScope(activeServer())).resolve();

      expect(target, isNotNull);
      expect(target!.transport, isNull);
    });

    test('no AuthRepository registered at all → null transport', () {
      container.registerSingleton<FeedbackTransport>(_FakeTransport());

      final target = resolver(_FakeScope(activeServer())).resolve();

      expect(target!.transport, isNull);
    });

    test('reads the scope fresh per resolve — a scope replaced by a '
        'bootstrap retry is picked up', () {
      ActiveServerScope? current;
      final r = ActiveServerFeedbackTargetResolver(scopeSource: () => current);

      expect(r.resolve(), isNull);

      current = _FakeScope(activeServer(serverId: 'bge-uuid-2'));
      expect(r.resolve()!.serverId, 'bge-uuid-2');
    });
  });
}

AuthResponse _session() => AuthResponse(
  token: 'session-token',
  user: AuthUser(
    id: 'user-1',
    username: 'tester',
    email: 'tester@example.com',
    emailVerified: true,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
);

class _FakeScope implements ActiveServerScope {
  _FakeScope(this._active);

  final ActiveServer? _active;

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(_active);
}

class _FakeTransport implements FeedbackTransport {
  @override
  Future<void> send(FeedbackReport report) async {}
}

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this._state);

  final AuthState _state;

  @override
  AuthState get currentAuthState => _state;

  @override
  Stream<AuthState> watchAuthState() => Stream.value(_state);

  @override
  Future<AuthResponse?> getCachedSession() async => null;

  @override
  Future<AuthResponse?> getSession() async => null;

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String username,
    String? firstName,
    String? lastName,
  }) => throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}
