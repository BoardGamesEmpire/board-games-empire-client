import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:di/di.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

// ── Mocks ────────────────────────────────────────────────────────────────────

class MockServerRepository extends Mock implements ServerRepository {}

class MockDevicePreferencesRepository extends Mock
    implements DevicePreferencesRepository {}

class MockServerContext extends Mock implements ServerContext {}

// ── Helpers ──────────────────────────────────────────────────────────────────

const _kPrefs = DevicePreferences();

ServerConfig _config({
  required String id,
  ConnectionState state = ConnectionState.disconnected,
}) => ServerConfig(
  id: id,
  displayName: 'Server $id',
  serverUrl: 'https://$id.example.com',
  connectionState: state,
  bgeServerId: 'bge-$id',
  cachedIdentity: ServerIdentity(
    serverId: 'bge-$id',
    issuer: 'https://$id.example.com',
    wellKnownSchemaVersion: 1,
    name: 'Test BGE Server',
    deviceAuthorizationEndpoint: 'https://$id.example.com/api/auth/device',
    authBasePath: 'https://$id.example.com/api/auth',
    sessionEndpoint: 'https://$id.example.com/api/auth/get-session',
    signOutEndpoint: 'https://$id.example.com/api/auth/sign-out',
    passkeySupported: true,
    twoFactorSupported: true,
    anonymousAuthSupported: true,
  ),
  lastIdentityFetchedAt: DateTime.now().toUtc(),
);

MockServerContext _mockContext(String serverId) {
  final ctx = MockServerContext();
  when(() => ctx.serverId).thenReturn(serverId);
  when(() => ctx.state).thenReturn(ServerContextState.initializing);
  when(() => ctx.activate()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.active);
  });
  when(() => ctx.background()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.backgrounding);
  });
  when(() => ctx.suspend()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.monitoring);
  });
  when(() => ctx.dispose()).thenAnswer((_) async {
    when(() => ctx.state).thenReturn(ServerContextState.disposed);
  });
  when(
    () => ctx.watchState(),
  ).thenAnswer((_) => Stream.value(ServerContextState.active));
  return ctx;
}

void main() {
  setUpAll(() {
    registerFallbackValue(ConnectionState.disconnected);
  });

  late MockServerRepository mockRepo;
  late MockDevicePreferencesRepository mockPrefsRepo;
  late Map<String, MockServerContext> mockContexts;

  late ServerOrchestratorImpl orchestrator;

  setUp(() {
    mockRepo = MockServerRepository();
    mockPrefsRepo = MockDevicePreferencesRepository();
    mockContexts = {};

    when(() => mockPrefsRepo.get()).thenAnswer((_) async => _kPrefs);

    // Default: no connected servers
    when(() => mockRepo.getConnectedServers()).thenAnswer((_) async => []);

    orchestrator = ServerOrchestratorImpl(
      serverRepository: mockRepo,
      preferencesRepository: mockPrefsRepo,
      contextFactory: (config) {
        final ctx = _mockContext(config.id);
        mockContexts[config.id] = ctx;
        return ctx;
      },
      isDesktopOverride: true,
    );
  });

  tearDown(() async => orchestrator.dispose());

  void stubUpdateConnectionState() {
    when(
      () => mockRepo.updateConnectionState(
        serverId: any(named: 'serverId'),
        newState: any(named: 'newState'),
      ),
    ).thenAnswer(
      (inv) async => _config(id: inv.namedArguments[#serverId] as String),
    );
  }

  void stubUpdateLastActive() {
    when(
      () => mockRepo.updateLastActive(any(), any()),
    ).thenAnswer((_) async {});
  }

  void stubGetServer(String id, {ServerConfig? config}) {
    when(
      () => mockRepo.getServer(id),
    ).thenAnswer((_) async => config ?? _config(id: id));
  }

  group('ServerOrchestratorImpl', () {
    group('initialize()', () {
      test('sets isInitialized to true', () async {
        await orchestrator.initialize();
        expect(orchestrator.isInitialized, isTrue);
      });

      test('starts with no active server when no connected servers', () async {
        await orchestrator.initialize();
        expect(orchestrator.activeServerId, isNull);
        expect(orchestrator.currentConnectedCount, 0);
      });

      test('restores previously active server', () async {
        when(() => mockRepo.getConnectedServers()).thenAnswer(
          (_) async => [
            _config(id: 'server-a', state: ConnectionState.active),
            _config(id: 'server-b', state: ConnectionState.monitoring),
          ],
        );
        stubUpdateConnectionState();
        stubUpdateLastActive();

        await orchestrator.initialize();

        expect(orchestrator.activeServerId, 'server-a');
        expect(orchestrator.currentConnectedCount, 2);
      });

      test('throws on double initialization', () async {
        await orchestrator.initialize();
        expect(() => orchestrator.initialize(), throwsStateError);
      });
    });

    group('connectServer()', () {
      setUp(() async {
        await orchestrator.initialize();
        stubUpdateConnectionState();
        stubUpdateLastActive();
      });

      test('connects and activates first server', () async {
        stubGetServer('server-a');

        await orchestrator.connectServer('server-a');

        expect(orchestrator.activeServerId, 'server-a');
        expect(orchestrator.currentConnectedCount, 1);
        verify(
          () => mockContexts['server-a']!.activate(),
        ).called(greaterThan(0));
      });

      test(
        'second server enters monitoring when makeActive is false',
        () async {
          stubGetServer('server-a');
          stubGetServer('server-b');

          await orchestrator.connectServer('server-a');
          await orchestrator.connectServer('server-b');

          expect(orchestrator.activeServerId, 'server-a');
          final ctx = mockContexts['server-b']!;
          verify(() => ctx.suspend()).called(1);
        },
      );

      test('makeActive:true promotes new server to active', () async {
        stubGetServer('server-a');
        stubGetServer('server-b');

        await orchestrator.connectServer('server-a');
        await orchestrator.connectServer('server-b', makeActive: true);

        expect(orchestrator.activeServerId, 'server-b');
      });

      test('throws ServerNotFoundException for unknown server', () async {
        when(() => mockRepo.getServer('ghost')).thenAnswer((_) async => null);

        expect(
          () => orchestrator.connectServer('ghost'),
          throwsA(isA<ServerNotFoundException>()),
        );
      });

      test('throws StateError if already connected', () async {
        stubGetServer('server-a');
        await orchestrator.connectServer('server-a');

        expect(() => orchestrator.connectServer('server-a'), throwsStateError);
      });

      test('throws ServerCapacityExceededException at capacity', () async {
        // Fill to max (default 5)
        for (var i = 0; i < 5; i++) {
          final id = 'server-$i';
          stubGetServer(id);
          await orchestrator.connectServer(id);
        }

        stubGetServer('server-overflow');
        expect(
          () => orchestrator.connectServer('server-overflow'),
          throwsA(isA<ServerCapacityExceededException>()),
        );
      });
    });

    group('disconnectServer()', () {
      setUp(() async {
        await orchestrator.initialize();
        stubUpdateConnectionState();
        stubUpdateLastActive();
        stubGetServer('server-a');
        await orchestrator.connectServer('server-a');
      });

      test('removes context and marks disconnected', () async {
        stubGetServer('server-a');

        await orchestrator.disconnectServer('server-a');

        expect(orchestrator.currentConnectedCount, 0);
        expect(orchestrator.getContext('server-a'), isNull);
        verify(
          () => mockRepo.updateConnectionState(
            serverId: 'server-a',
            newState: ConnectionState.disconnected,
          ),
        ).called(1);
      });

      test('promotes another server when active is disconnected', () async {
        stubGetServer('server-b');
        await orchestrator.connectServer('server-b');
        stubGetServer('server-a');

        await orchestrator.disconnectServer('server-a');

        expect(orchestrator.activeServerId, 'server-b');
      });

      test('throws StateError when not connected', () async {
        stubGetServer('server-a');
        await orchestrator.disconnectServer('server-a');

        expect(
          () => orchestrator.disconnectServer('server-a'),
          throwsStateError,
        );
      });
    });

    group('switchActiveServer()', () {
      setUp(() async {
        await orchestrator.initialize();
        stubUpdateConnectionState();
        stubUpdateLastActive();
        stubGetServer('server-a');
        stubGetServer('server-b');
        await orchestrator.connectServer('server-a');
        await orchestrator.connectServer('server-b');
      });

      test('switches active server', () async {
        await orchestrator.switchActiveServer('server-b');
        expect(orchestrator.activeServerId, 'server-b');
      });

      test('backgrounds the previous active server', () async {
        await orchestrator.switchActiveServer('server-b');
        verify(() => mockContexts['server-a']!.background()).called(1);
      });

      test('activates the target server', () async {
        // server-b is monitoring after connect; reset to verify activate
        when(
          () => mockContexts['server-b']!.state,
        ).thenReturn(ServerContextState.monitoring);

        await orchestrator.switchActiveServer('server-b');

        verify(
          () => mockContexts['server-b']!.activate(),
        ).called(greaterThan(0));
      });

      test('no-op when switching to already active server', () async {
        await orchestrator.switchActiveServer('server-a'); // already active
        verifyNever(() => mockContexts['server-a']!.background());
      });

      test('throws StateError for disconnected target', () async {
        expect(
          () => orchestrator.switchActiveServer('not-connected'),
          throwsStateError,
        );
      });
    });

    group('watchActiveContext()', () {
      test('emits new context after switch', () async {
        // Subscribe-then-mutate-then-pump.
        // The `await pumpEventQueue()` before sub.cancel() drains the
        // pending delivery microtasks so `emitted` captures both
        // emissions before the subscription is torn down.
        await orchestrator.initialize();
        stubUpdateConnectionState();
        stubUpdateLastActive();
        stubGetServer('server-a');
        stubGetServer('server-b');

        final emitted = <ServerContext?>[];
        final sub = orchestrator.watchActiveContext().listen(emitted.add);
        await pumpEventQueue();

        await orchestrator.connectServer('server-a');
        await orchestrator.connectServer('server-b', makeActive: true);

        await pumpEventQueue();
        await sub.cancel();

        expect(emitted.map((c) => c?.serverId), contains('server-b'));
      });
    });

    group('dispose()', () {
      test('disposes all contexts', () async {
        await orchestrator.initialize();
        stubUpdateConnectionState();
        stubUpdateLastActive();
        stubGetServer('server-a');
        await orchestrator.connectServer('server-a');

        await orchestrator.dispose();

        verify(() => mockContexts['server-a']!.dispose()).called(1);
      });

      test('is idempotent', () async {
        await orchestrator.initialize();
        await orchestrator.dispose();
        await expectLater(orchestrator.dispose(), completes);
      });
    });

    group('pre-initialization guards', () {
      test('connectServer throws before initialize', () {
        expect(() => orchestrator.connectServer('server-a'), throwsStateError);
      });

      test('disconnectServer throws before initialize', () {
        expect(
          () => orchestrator.disconnectServer('server-a'),
          throwsStateError,
        );
      });

      test('switchActiveServer throws before initialize', () {
        expect(
          () => orchestrator.switchActiveServer('server-a'),
          throwsStateError,
        );
      });
    });
  });
}
