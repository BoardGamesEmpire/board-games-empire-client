// Failure-path coverage: ServerContext.activate() performs real work and
// can throw; the orchestrator must attempt activation first and commit its
// own state only on success.

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:mocktail/mocktail.dart';

class _MockServerRepository extends Mock implements ServerRepository {}

class _MockPreferencesRepository extends Mock
    implements DevicePreferencesRepository {}

class _MockDevicePreferences extends Mock implements DevicePreferences {}

/// Installer that fails on the call numbers in [failOnCalls] and otherwise
/// succeeds. Contexts restored into monitoring install once; a later
/// promotion installs again — so `failOnCalls: {2}` means "connects fine,
/// fails when promoted to active".
class _CountedInstaller implements ServerScopeInstaller {
  _CountedInstaller({this.failOnCalls = const <int>{}});

  final Set<int> failOnCalls;
  var calls = 0;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    calls++;
    if (failOnCalls.contains(calls)) {
      throw StateError('installer boom #$calls');
    }
  }
}

ServerConfig _makeConfig({
  required String id,
  ConnectionState connectionState = ConnectionState.disconnected,
}) => ServerConfig(
  id: id,
  displayName: 'Server $id',
  serverUrl: 'https://$id.example.com',
  connectionState: connectionState,
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

void main() {
  setUpAll(() {
    registerFallbackValue(ConnectionState.disconnected);
    registerFallbackValue(DateTime(2026));
  });

  late _MockServerRepository serverRepository;
  late _MockPreferencesRepository preferencesRepository;
  late _MockDevicePreferences preferences;
  late Map<String, ServerScopeInstaller> installersById;
  late ServerOrchestratorImpl orchestrator;

  ServerContext contextFactory(ServerConfig config) => ServerContextImpl(
    config: config,
    installers: [
      if (installersById[config.id] != null) installersById[config.id]!,
    ],
  );

  setUp(() {
    serverRepository = _MockServerRepository();
    preferencesRepository = _MockPreferencesRepository();
    preferences = _MockDevicePreferences();
    installersById = {};

    when(() => preferences.maxMonitoredServers).thenReturn(5);
    when(
      () => preferences.backgroundingTimeoutSeconds(
        isDesktop: any(named: 'isDesktop'),
      ),
    ).thenReturn(300);
    when(
      () => preferencesRepository.get(),
    ).thenAnswer((_) async => preferences);
    when(
      () => serverRepository.updateConnectionState(
        serverId: any(named: 'serverId'),
        newState: any(named: 'newState'),
      ),
    ).thenAnswer(
      (i) async => _makeConfig(
        id: i.namedArguments[#serverId] as String,
        connectionState: i.namedArguments[#newState] as ConnectionState,
      ),
    );
    when(
      () => serverRepository.updateLastActive(any(), any()),
    ).thenAnswer((_) async {});

    orchestrator = ServerOrchestratorImpl(
      serverRepository: serverRepository,
      preferencesRepository: preferencesRepository,
      contextFactory: contextFactory,
      isDesktopOverride: false,
    );
  });

  tearDown(() => orchestrator.dispose());

  group('initialize()', () {
    test('one failing restore does not prevent initialization', () async {
      final good = _makeConfig(
        id: 'a',
        connectionState: ConnectionState.active,
      );
      final bad = _makeConfig(
        id: 'b',
        connectionState: ConnectionState.monitoring,
      );
      installersById['a'] = _CountedInstaller();
      installersById['b'] = _CountedInstaller(failOnCalls: {1});
      when(
        () => serverRepository.getConnectedServers(),
      ).thenAnswer((_) async => [good, bad]);

      await orchestrator.initialize();

      expect(orchestrator.isInitialized, isTrue);
      expect(orchestrator.activeServerId, 'a');
      expect(orchestrator.getContext('a')?.state, ServerContextState.active);
      expect(orchestrator.getContext('b'), isNull);
      // Dropped restore is persisted as disconnected so it isn't retried
      // on every startup.
      verify(
        () => serverRepository.updateConnectionState(
          serverId: 'b',
          newState: ConnectionState.disconnected,
        ),
      ).called(1);
    });

    test(
      'falls back when the previously-active server fails to restore',
      () async {
        final bad = _makeConfig(
          id: 'a',
          connectionState: ConnectionState.active,
        );
        final good = _makeConfig(
          id: 'b',
          connectionState: ConnectionState.monitoring,
        );
        installersById['a'] = _CountedInstaller(failOnCalls: {1});
        installersById['b'] = _CountedInstaller();
        when(
          () => serverRepository.getConnectedServers(),
        ).thenAnswer((_) async => [bad, good]);

        await orchestrator.initialize();

        expect(orchestrator.isInitialized, isTrue);
        expect(orchestrator.activeServerId, 'b');
        expect(orchestrator.getContext('a'), isNull);
      },
    );
  });

  group('connectServer()', () {
    setUp(() {
      when(
        () => serverRepository.getConnectedServers(),
      ).thenAnswer((_) async => []);
    });

    test(
      'failed connect leaves no orphaned context and can be retried',
      () async {
        final config = _makeConfig(id: 'x');
        installersById['x'] = _CountedInstaller(failOnCalls: {1});
        when(
          () => serverRepository.getServer('x'),
        ).thenAnswer((_) async => config);
        await orchestrator.initialize();

        await expectLater(
          orchestrator.connectServer('x', makeActive: true),
          throwsStateError,
        );

        expect(orchestrator.getContext('x'), isNull);
        expect(orchestrator.activeServerId, isNull);
        expect(orchestrator.currentConnectedCount, 0);

        // Retry must not hit "already connected" — the failed attempt left
        // nothing behind. (Install call #2 succeeds.)
        await orchestrator.connectServer('x', makeActive: true);

        expect(orchestrator.activeServerId, 'x');
        expect(orchestrator.getContext('x')?.state, ServerContextState.active);
      },
    );

    test('makeActive demotes the current active server', () async {
      final a = _makeConfig(id: 'a');
      final b = _makeConfig(id: 'b');
      installersById['a'] = _CountedInstaller();
      installersById['b'] = _CountedInstaller();
      when(() => serverRepository.getServer('a')).thenAnswer((_) async => a);
      when(() => serverRepository.getServer('b')).thenAnswer((_) async => b);
      await orchestrator.initialize();
      await orchestrator.connectServer('a', makeActive: true);

      await orchestrator.connectServer('b', makeActive: true);

      expect(orchestrator.activeServerId, 'b');
      expect(orchestrator.getContext('b')?.state, ServerContextState.active);
      // Single-active invariant: the previous active was demoted.
      expect(
        orchestrator.getContext('a')?.state,
        ServerContextState.backgrounding,
      );
    });

    test(
      'failed demotion rolls back the newcomer, previous stays active',
      () async {
        final a = _makeConfig(id: 'a');
        final b = _makeConfig(id: 'b');
        installersById['a'] = _CountedInstaller();
        installersById['b'] = _CountedInstaller();
        when(() => serverRepository.getServer('a')).thenAnswer((_) async => a);
        when(() => serverRepository.getServer('b')).thenAnswer((_) async => b);
        await orchestrator.initialize();
        await orchestrator.connectServer('a', makeActive: true);

        // Fail the demotion's persisted-state write for 'a'.
        when(
          () => serverRepository.updateConnectionState(
            serverId: 'a',
            newState: ConnectionState.backgrounding,
          ),
        ).thenThrow(StateError('demote boom'));

        await expectLater(
          orchestrator.connectServer('b', makeActive: true),
          throwsA(isA<StateError>()),
        );

        // Newcomer dropped; no orphan, no double-active.
        expect(orchestrator.getContext('b'), isNull);
        expect(orchestrator.activeServerId, 'a');
        // Previous is genuinely active again, not stranded in backgrounding.
        expect(orchestrator.getContext('a')?.state, ServerContextState.active);
      },
    );
  });

  group('switchActiveServer()', () {
    setUp(() {
      when(
        () => serverRepository.getConnectedServers(),
      ).thenAnswer((_) async => []);
    });

    Future<void> connectPair({required Set<int> targetFailures}) async {
      final a = _makeConfig(id: 'a');
      final b = _makeConfig(id: 'b');
      installersById['a'] = _CountedInstaller();
      installersById['b'] = _CountedInstaller(failOnCalls: targetFailures);
      when(() => serverRepository.getServer('a')).thenAnswer((_) async => a);
      when(() => serverRepository.getServer('b')).thenAnswer((_) async => b);
      await orchestrator.initialize();
      await orchestrator.connectServer('a', makeActive: true);
      await orchestrator.connectServer('b'); // → monitoring (install #1)
    }

    test(
      'failed target activation leaves the previous server active',
      () async {
        await connectPair(targetFailures: {2}); // fails on promotion

        await expectLater(
          orchestrator.switchActiveServer('b'),
          throwsStateError,
        );

        expect(orchestrator.activeServerId, 'a');
        expect(orchestrator.getContext('a')?.state, ServerContextState.active);
        expect(
          orchestrator.getContext('b')?.state,
          ServerContextState.monitoring,
        );
      },
    );

    test('successful switch demotes previous and commits target', () async {
      await connectPair(targetFailures: const {});

      await orchestrator.switchActiveServer('b');

      expect(orchestrator.activeServerId, 'b');
      expect(orchestrator.getContext('b')?.state, ServerContextState.active);
      expect(
        orchestrator.getContext('a')?.state,
        ServerContextState.backgrounding,
      );
    });

    test(
      'demotion failure rolls target back, previous stays sole active',
      () async {
        // Target activates fine; make the previous server's demotion fail by
        // having the repository reject its backgrounding state write. (The
        // demotion path is guarded on state == active, so a disposed previous
        // would be skipped rather than fail — the repo write is the reachable
        // failure point.)
        await connectPair(targetFailures: const {});

        when(
          () => serverRepository.updateConnectionState(
            serverId: 'a',
            newState: ConnectionState.backgrounding,
          ),
        ).thenThrow(StateError('repo demotion boom'));

        await expectLater(
          orchestrator.switchActiveServer('b'),
          throwsA(isA<StateError>()),
        );

        // Single-active invariant preserved: a is still the active id, and b
        // was rolled back out of active.
        expect(orchestrator.activeServerId, 'a');
        expect(
          orchestrator.getContext('b')?.state,
          isNot(ServerContextState.active),
        );
      },
    );
  });

  group('disconnectServer()', () {
    setUp(() {
      when(
        () => serverRepository.getConnectedServers(),
      ).thenAnswer((_) async => []);
    });

    test(
      'failed promotion leaves no active server, app keeps running',
      () async {
        final a = _makeConfig(id: 'a');
        final b = _makeConfig(id: 'b');
        installersById['a'] = _CountedInstaller();
        installersById['b'] = _CountedInstaller(failOnCalls: {2});
        when(() => serverRepository.getServer('a')).thenAnswer((_) async => a);
        when(() => serverRepository.getServer('b')).thenAnswer((_) async => b);
        await orchestrator.initialize();
        await orchestrator.connectServer('a', makeActive: true);
        await orchestrator.connectServer('b'); // → monitoring

        // Disconnecting the active server tries to promote b, which fails.
        await orchestrator.disconnectServer('a');

        expect(orchestrator.activeServerId, isNull);
        expect(orchestrator.getActiveContext(), isNull);
        expect(orchestrator.getContext('a'), isNull);
        // b remains connected (monitoring), just not active.
        expect(
          orchestrator.getContext('b')?.state,
          ServerContextState.monitoring,
        );
      },
    );
  });
}
