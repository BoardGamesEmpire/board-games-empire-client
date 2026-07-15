import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'support/orchestrator_test_fixtures.dart';

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

void main() {
  setUpAll(() {
    registerFallbackValue(ConnectionState.disconnected);
  });

  group('ActiveServer', () {
    final identity = testServerIdentity('a');
    final container = DependencyContainerImpl();

    ActiveServer build({DependencyContainer? withContainer}) => ActiveServer(
      serverId: 'a',
      displayName: 'Server a',
      identity: identity,
      container: withContainer ?? container,
    );

    test('equal for identical snapshot fields and the same container', () {
      expect(build(), equals(build()));
      expect(build().hashCode, build().hashCode);
    });

    test('not equal for a different container instance', () {
      expect(
        build(),
        isNot(equals(build(withContainer: DependencyContainerImpl()))),
      );
    });

    test('not equal for a different serverId', () {
      final other = ActiveServer(
        serverId: 'b',
        displayName: 'Server a',
        identity: identity,
        container: container,
      );
      expect(build(), isNot(equals(other)));
    });
  });

  group('OrchestratorActiveServerScope (unit, mocked orchestrator)', () {
    late _MockServerOrchestrator orchestrator;
    late StreamController<ServerContext?> activeContextController;
    late OrchestratorActiveServerScope scope;

    setUp(() {
      orchestrator = _MockServerOrchestrator();
      activeContextController = StreamController<ServerContext?>.broadcast();
      when(
        () => orchestrator.watchActiveContext(),
      ).thenAnswer((_) => activeContextController.stream);
      when(() => orchestrator.getActiveContext()).thenReturn(null);
      scope = OrchestratorActiveServerScope(orchestrator: orchestrator);
    });

    tearDown(() async => activeContextController.close());

    /// Stubs the orchestrator's committed truth to [id] (or clears it
    /// when null), the way the real impl commits.
    void commitActive(String? id, {DependencyContainer? container}) {
      if (id == null) {
        when(() => orchestrator.getActiveContext()).thenReturn(null);
        return;
      }
      final ctx = mockServerContext(
        id,
        container: container ?? DependencyContainerImpl(),
      );
      when(() => orchestrator.getActiveContext()).thenReturn(ctx);
    }

    test('active is null when no server is active', () {
      expect(scope.active, isNull);
    });

    test('active maps serverId, displayName, identity, and container '
        'from the committed pair', () {
      final container = DependencyContainerImpl();
      commitActive('a', container: container);

      final active = scope.active;
      expect(active, isNotNull);
      expect(active!.serverId, 'a');
      expect(active.displayName, 'Server a');
      expect(active.identity, testServerIdentity('a'));
      expect(identical(active.container, container), isTrue);
    });

    test('watchActive replays the current value on subscribe — null', () async {
      expect(await scope.watchActive().first, isNull);
    });

    test('watchActive replays the current value on subscribe — active '
        '(late subscriber, no orchestrator emission needed)', () async {
      commitActive('a');

      final first = await scope.watchActive().first;
      expect(first?.serverId, 'a');
    });

    test('watchActive re-reads committed truth on each orchestrator '
        'emission', () async {
      final emitted = <ActiveServer?>[];
      final sub = scope.watchActive().listen(emitted.add);
      await pumpEventQueue();

      commitActive('a');
      activeContextController.add(orchestrator.getActiveContext());
      await pumpEventQueue();

      commitActive('b');
      activeContextController.add(orchestrator.getActiveContext());
      await pumpEventQueue();

      commitActive(null);
      activeContextController.add(null);
      await pumpEventQueue();

      await sub.cancel();

      expect(emitted.map((a) => a?.serverId).toList(), [null, 'a', 'b', null]);
    });

    test('a stale event delivery reflects current truth, never a torn '
        'snapshot', () async {
      // Simulate async broadcast delivery racing a rapid double-commit:
      // the event for 'a' is delivered AFTER truth moved to 'b'.
      commitActive('b');

      final emitted = <ActiveServer?>[];
      final sub = scope.watchActive().listen(emitted.add);
      await pumpEventQueue();

      final staleContextForA = mockServerContext(
        'a',
        container: DependencyContainerImpl(),
      );
      activeContextController.add(staleContextForA);
      await pumpEventQueue();
      await sub.cancel();

      // Seed + stale delivery: both read the committed truth ('b').
      expect(emitted.map((a) => a?.serverId).toList(), ['b', 'b']);
    });

    test('cancelling the subscription cancels the orchestrator '
        'subscription', () async {
      final sub = scope.watchActive().listen((_) {});
      await pumpEventQueue();
      expect(activeContextController.hasListener, isTrue);

      await sub.cancel();
      await pumpEventQueue();
      expect(activeContextController.hasListener, isFalse);
    });
  });

  group('OrchestratorActiveServerScope (end-to-end, real orchestrator)', () {
    late MockServerRepository repo;
    late MockDevicePreferencesRepository prefsRepo;
    late ServerOrchestratorImpl orchestrator;
    late OrchestratorActiveServerScope scope;

    setUp(() {
      repo = MockServerRepository();
      prefsRepo = MockDevicePreferencesRepository();
      when(() => prefsRepo.get()).thenAnswer((_) async => DevicePreferences());
      when(() => repo.getConnectedServers()).thenAnswer((_) async => []);
      when(
        () => repo.updateConnectionState(
          serverId: any(named: 'serverId'),
          newState: any(named: 'newState'),
        ),
      ).thenAnswer(
        (inv) async =>
            testServerConfig(id: inv.namedArguments[#serverId] as String),
      );
      when(() => repo.updateLastActive(any(), any())).thenAnswer((_) async {});

      orchestrator = ServerOrchestratorImpl(
        serverRepository: repo,
        preferencesRepository: prefsRepo,
        contextFactory: (config) =>
            mockServerContext(config.id, container: DependencyContainerImpl()),
        isDesktopOverride: true,
      );
      scope = OrchestratorActiveServerScope(orchestrator: orchestrator);
    });

    tearDown(() async => orchestrator.dispose());

    void stubGetServer(String id) {
      when(
        () => repo.getServer(id),
      ).thenAnswer((_) async => testServerConfig(id: id));
    }

    test('a late subscriber (post-connect) receives the active server via '
        'the replay — the returning-user scenario', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');
      await orchestrator.connectServer('server-a');

      // Subscribe AFTER the connect: the orchestrator's own stream has no
      // replay, so only the scope's seed can deliver this.
      final first = await scope.watchActive().first;
      expect(first?.serverId, 'server-a');
      expect(first?.displayName, 'Server server-a');
    });

    test('emits the new active server after a switch', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');
      stubGetServer('server-b');
      await orchestrator.connectServer('server-a');
      await orchestrator.connectServer('server-b');

      final emitted = <ActiveServer?>[];
      final sub = scope.watchActive().listen(emitted.add);
      await pumpEventQueue();

      await orchestrator.switchActiveServer('server-b');
      await pumpEventQueue();
      await sub.cancel();

      expect(emitted.first?.serverId, 'server-a'); // seed
      expect(emitted.last?.serverId, 'server-b');
    });

    test('emits null when the sole active server is disconnected', () async {
      await orchestrator.initialize();
      stubGetServer('server-a');
      await orchestrator.connectServer('server-a');

      final emitted = <ActiveServer?>[];
      final sub = scope.watchActive().listen(emitted.add);
      await pumpEventQueue();

      await orchestrator.disconnectServer('server-a');
      await pumpEventQueue();
      await sub.cancel();

      expect(emitted.first?.serverId, 'server-a'); // seed
      expect(emitted.last, isNull);
    });
  });
}
