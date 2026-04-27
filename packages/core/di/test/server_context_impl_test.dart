import 'package:flutter_test/flutter_test.dart';
import 'package:di/di.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:mocktail/mocktail.dart';

class MockDependencyContainer extends Mock implements DependencyContainer {}

ServerConfig _makeConfig({String id = 'server-local-1'}) => ServerConfig(
  id: id,
  displayName: 'Test Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.disconnected,
  bgeServerId: '550e8400-e29b-41d4-a716-446655440000',
  cachedIdentity: ServerIdentity(
    serverId: '550e8400-e29b-41d4-a716-446655440000',
    issuer: 'https://api.example.com',
    deviceAuthorizationEndpoint: 'https://api.example.com/api/auth/device',
    authBaseUrl: 'https://api.example.com/api/auth',
    sessionEndpoint: 'https://api.example.com/api/auth/get-session',
    signOutEndpoint: 'https://api.example.com/api/auth/sign-out',
    passkeySupported: true,
    twoFactorSupported: true,
    anonymousAuthSupported: true,
  ),
  lastIdentityFetchedAt: DateTime.now().toUtc(),
);

void main() {
  late ServerContextImpl context;
  late MockDependencyContainer mockContainer;

  setUp(() {
    mockContainer = MockDependencyContainer();
    when(() => mockContainer.dispose()).thenAnswer((_) async {});
    context = ServerContextImpl(
      config: _makeConfig(),
      container: mockContainer,
    );
  });

  tearDown(() async => context.dispose());

  group('ServerContextImpl', () {
    group('initial state', () {
      test('starts in initializing state', () {
        expect(context.state, ServerContextState.initializing);
      });

      test('exposes correct serverId', () {
        expect(context.serverId, 'server-local-1');
      });

      test('exposes injected container', () {
        expect(context.container, same(mockContainer));
      });
    });

    group('activate()', () {
      test('transitions initializing → active', () async {
        await context.activate();
        expect(context.state, ServerContextState.active);
      });

      test('transitions monitoring → active', () async {
        await context.activate(); // initializing → active
        await context.background(); // active → backgrounding
        await context.suspend(); // backgrounding → monitoring
        await context.activate(); // monitoring → active
        expect(context.state, ServerContextState.active);
      });

      test('transitions backgrounding → active', () async {
        await context.activate(); // initializing → active
        await context.background(); // active → backgrounding
        await context.activate(); // backgrounding → active
        expect(context.state, ServerContextState.active);
      });

      test('throws when already active', () async {
        await context.activate();
        expect(() => context.activate(), throwsStateError);
      });

      test('throws when disposed', () async {
        await context.dispose();
        expect(() => context.activate(), throwsStateError);
      });
    });

    group('background()', () {
      test('transitions active → backgrounding', () async {
        await context.activate();
        await context.background();
        expect(context.state, ServerContextState.backgrounding);
      });

      test('throws when not active', () {
        expect(() => context.background(), throwsStateError);
      });

      test('throws when monitoring', () async {
        await context.activate();
        await context.background();
        await context.suspend();
        expect(() => context.background(), throwsStateError);
      });
    });

    group('suspend()', () {
      test('transitions backgrounding → monitoring', () async {
        await context.activate();
        await context.background();
        await context.suspend();
        expect(context.state, ServerContextState.monitoring);
      });

      test('throws when active (must background first)', () async {
        await context.activate();
        expect(() => context.suspend(), throwsStateError);
      });

      test('throws when initializing', () {
        expect(() => context.suspend(), throwsStateError);
      });
    });

    group('dispose()', () {
      test('transitions to disposed', () async {
        await context.activate();
        await context.dispose();
        expect(context.state, ServerContextState.disposed);
      });

      test('calls container.dispose()', () async {
        await context.dispose();
        verify(() => mockContainer.dispose()).called(1);
      });

      test('is idempotent', () async {
        await context.dispose();
        await expectLater(context.dispose(), completes);
        verify(() => mockContainer.dispose()).called(1);
      });
    });

    group('watchState()', () {
      test('replays current state immediately', () async {
        await expectLater(
          context.watchState().take(1),
          emits(ServerContextState.initializing),
        );
      });

      test('emits full lifecycle sequence', () async {
        final states = <ServerContextState>[];
        final sub = context.watchState().listen(states.add);

        await context.activate();
        await context.background();
        await context.suspend();
        await context.dispose();

        await sub.cancel();

        expect(
          states,
          containsAllInOrder([
            ServerContextState.initializing,
            ServerContextState.transitioning,
            ServerContextState.active,
            ServerContextState.transitioning,
            ServerContextState.backgrounding,
            ServerContextState.transitioning,
            ServerContextState.monitoring,
            ServerContextState.disposed,
          ]),
        );
      });
    });

    group('concurrent transition guard', () {
      test('throws on concurrent activation attempt', () async {
        // Start an activate and immediately try another.
        final first = context.activate();
        expect(() => context.activate(), throwsStateError);
        await first;
      });
    });
  });
}
