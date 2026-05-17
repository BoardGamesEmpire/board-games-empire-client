import 'package:test/test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

class MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class MockServerContext extends Mock implements ServerContext {}

class MockDependencyContainer extends Mock implements DependencyContainer {}

void main() {
  group('ServerOrchestrator Contract', () {
    late MockServerOrchestrator orchestrator;

    setUp(() {
      orchestrator = MockServerOrchestrator();
    });

    test('enforces capacity limits during connection', () async {
      when(() => orchestrator.maxMonitoringCapacity).thenReturn(5);
      when(() => orchestrator.currentConnectedCount).thenReturn(5);
      when(() => orchestrator.canConnect()).thenReturn(false);
      when(() => orchestrator.connectServer('server_6')).thenThrow(
        ServerCapacityExceededException(currentConnected: 5, maxCapacity: 5),
      );

      expect(orchestrator.canConnect(), isFalse);
      expect(
        () => orchestrator.connectServer('server_6'),
        throwsA(isA<ServerCapacityExceededException>()),
      );
    });

    test('allows connection when capacity available', () async {
      when(() => orchestrator.maxMonitoringCapacity).thenReturn(5);
      when(() => orchestrator.currentConnectedCount).thenReturn(3);
      when(() => orchestrator.canConnect()).thenReturn(true);
      when(
        () => orchestrator.connectServer('server_4'),
      ).thenAnswer((_) async {});

      expect(orchestrator.canConnect(), isTrue);
      await expectLater(orchestrator.connectServer('server_4'), completes);
    });

    test('maintains exactly one active context', () async {
      final activeContext = MockServerContext();
      when(() => activeContext.serverId).thenReturn('server_1');
      when(() => activeContext.state).thenReturn(ServerContextState.active);

      when(() => orchestrator.activeServerId).thenReturn('server_1');
      when(() => orchestrator.getActiveContext()).thenReturn(activeContext);

      final context = orchestrator.getActiveContext();
      expect(context?.serverId, 'server_1');
      expect(context?.state, ServerContextState.active);
    });

    test('switches active server atomically', () async {
      final originalActive = MockServerContext();
      final newActive = MockServerContext();

      when(() => originalActive.serverId).thenReturn('server_1');
      when(() => originalActive.state).thenReturn(ServerContextState.active);
      when(() => originalActive.suspend()).thenAnswer((_) async {});

      when(() => newActive.serverId).thenReturn('server_2');
      when(() => newActive.state).thenReturn(ServerContextState.monitoring);
      when(() => newActive.activate()).thenAnswer((_) async {});

      when(() => orchestrator.activeServerId).thenReturn('server_1');
      when(() => orchestrator.getActiveContext()).thenReturn(originalActive);
      when(() => orchestrator.switchActiveServer('server_2')).thenAnswer((
        _,
      ) async {
        await originalActive.suspend();
        await newActive.activate();
      });

      await orchestrator.switchActiveServer('server_2');

      verify(() => originalActive.suspend()).called(1);
      verify(() => newActive.activate()).called(1);
    });

    test(
      'disconnecting active server requires replacement selection',
      () async {
        when(() => orchestrator.activeServerId).thenReturn('server_1');
        when(() => orchestrator.currentConnectedCount).thenReturn(2);
        when(
          () => orchestrator.disconnectServer('server_1'),
        ).thenAnswer((_) async {});

        await expectLater(orchestrator.disconnectServer('server_1'), completes);
      },
    );

    test('prevents operations on uninitialized orchestrator', () {
      when(() => orchestrator.isInitialized).thenReturn(false);
      when(
        () => orchestrator.connectServer('server_1'),
      ).thenThrow(StateError('Orchestrator not initialized'));

      expect(orchestrator.isInitialized, isFalse);
      expect(() => orchestrator.connectServer('server_1'), throwsStateError);
    });
  });

  group('ServerContext Contract', () {
    late MockServerContext context;

    setUp(() {
      context = MockServerContext();
    });

    test('transitions through valid lifecycle states', () async {
      when(() => context.state).thenReturn(ServerContextState.initializing);
      expect(context.state, ServerContextState.initializing);

      when(() => context.activate()).thenAnswer((_) async {});
      when(() => context.state).thenReturn(ServerContextState.active);
      await context.activate();
      expect(context.state, ServerContextState.active);

      when(() => context.suspend()).thenAnswer((_) async {});
      when(() => context.state).thenReturn(ServerContextState.monitoring);
      await context.suspend();
      expect(context.state, ServerContextState.monitoring);

      when(() => context.dispose()).thenAnswer((_) async {});
      when(() => context.state).thenReturn(ServerContextState.disposed);
      await context.dispose();
      expect(context.state, ServerContextState.disposed);
    });

    test('provides isolated dependency container', () {
      final container = MockDependencyContainer();
      when(() => context.container).thenReturn(container);
      when(() => container.get<String>()).thenReturn('isolated_dependency');

      final retrieved = context.container.get<String>();
      expect(retrieved, 'isolated_dependency');
    });

    test('prevents operations during transitioning state', () {
      when(() => context.state).thenReturn(ServerContextState.transitioning);
      when(
        () => context.activate(),
      ).thenThrow(StateError('Cannot activate during transition'));

      expect(() => context.activate(), throwsStateError);
    });

    test('prevents operations on disposed context', () {
      when(() => context.state).thenReturn(ServerContextState.disposed);
      when(
        () => context.activate(),
      ).thenThrow(StateError('Cannot activate disposed context'));

      expect(() => context.activate(), throwsStateError);
    });
  });

  group('DependencyContainer Contract', () {
    late MockDependencyContainer container;

    setUp(() {
      container = MockDependencyContainer();
    });

    test('resolves registered dependencies', () {
      when(() => container.get<String>()).thenReturn('test_value');

      final result = container.get<String>();
      expect(result, 'test_value');
    });

    test('throws when retrieving unregistered dependency', () {
      when(
        () => container.get<int>(),
      ).thenThrow(StateError('Type int is not registered'));

      expect(() => container.get<int>(), throwsStateError);
    });

    test('registers and retrieves singletons', () {
      when(
        () => container.registerSingleton('singleton_instance'),
      ).thenReturn(null);
      when(() => container.get<String>()).thenReturn('singleton_instance');

      container.registerSingleton('singleton_instance');
      final retrieved = container.get<String>();
      expect(retrieved, 'singleton_instance');
    });

    test('disposes all managed dependencies', () async {
      when(() => container.dispose()).thenAnswer((_) async {});

      await expectLater(container.dispose(), completes);
      verify(() => container.dispose()).called(1);
    });
  });
}
