import 'dart:async';

import 'package:app_shell/src/servers/server_list_cubit.dart';
import 'package:app_shell/src/servers/server_list_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/server_list_fakes.dart';

final ServerConfig _alpha = testRegisteredServer('alpha', 'Alpha');
final ServerConfig _beta = testRegisteredServer('beta', 'Beta');
final ServerConfig _gamma = testRegisteredServer('gamma', 'Gamma');

void main() {
  late FakeRegisteredServers registered;
  late FakeServerOrchestrator orchestrator;

  setUp(() {
    registered = FakeRegisteredServers([_alpha, _beta, _gamma]);
    orchestrator = FakeServerOrchestrator()
      ..activate('alpha')
      ..connect('beta');
  });

  tearDown(() async {
    await registered.close();
    await orchestrator.close();
  });

  /// A cubit over the fakes, with the registry's first list read.
  Future<ServerListCubit> ready() async {
    final cubit = ServerListCubit(
      registered: registered,
      orchestrator: orchestrator,
    );
    addTearDown(cubit.close);
    await pumpEventQueue();
    return cubit;
  }

  Map<String, ServerRowState> statesOf(ServerListState state) => {
    for (final row in (state as ServerListReady).rows) row.server.id: row.state,
  };

  test('starts loading', () {
    final cubit = ServerListCubit(
      registered: registered,
      orchestrator: orchestrator,
    );
    addTearDown(cubit.close);

    expect(cubit.state, isA<ServerListLoading>());
  });

  test('lists every registered server with its state', () async {
    final cubit = await ready();

    final state = cubit.state as ServerListReady;
    expect(state.rows.map((row) => row.server), [_alpha, _beta, _gamma]);
    expect(statesOf(state), {
      'alpha': ServerRowState.inUse,
      'beta': ServerRowState.dormant,
      'gamma': ServerRowState.notConnected,
    });
    expect(state.switchingTo, isNull);
  });

  test('the list follows a switch made elsewhere', () async {
    final cubit = await ready();

    orchestrator.activate('gamma');
    await pumpEventQueue();

    final state = cubit.state as ServerListReady;
    // The marker moves; the rows keep the registry's order.
    expect(state.rows.map((row) => row.server.id), ['alpha', 'beta', 'gamma']);
    expect(statesOf(state), {
      'alpha': ServerRowState.dormant,
      'beta': ServerRowState.dormant,
      'gamma': ServerRowState.inUse,
    });
  });

  test('the list follows the registry', () async {
    final cubit = await ready();

    registered.emit([_gamma, _alpha]);
    await pumpEventQueue();

    expect(
      (cubit.state as ServerListReady).rows.map((row) => row.server.id),
      ['gamma', 'alpha'],
    );
  });

  test('a pick switches through activateServer and reports done', () async {
    final cubit = await ready();
    final gate = Completer<void>();
    orchestrator.onActivate = (_) => gate.future;

    final pick = cubit.pick('beta');

    expect((cubit.state as ServerListReady).switchingTo, 'beta');
    gate.complete();
    expect(await pick, isA<ServerPickDone>());
    // Beta was connected, so it was switched to rather than connected.
    expect(orchestrator.calls, ['switch beta']);
    expect(orchestrator.activeServerId, 'beta');
    await pumpEventQueue();
    final state = cubit.state as ServerListReady;
    expect(state.switchingTo, isNull);
    expect(statesOf(state)['beta'], ServerRowState.inUse);
  });

  test('a pick of a server not connected connects it', () async {
    final cubit = await ready();

    expect(await cubit.pick('gamma'), isA<ServerPickDone>());
    expect(orchestrator.calls, ['connect gamma']);
    expect(orchestrator.activeServerId, 'gamma');
  });

  test('a pick while a switch runs is ignored', () async {
    final cubit = await ready();
    final gate = Completer<void>();
    orchestrator.onActivate = (_) => gate.future;
    final first = cubit.pick('beta');

    expect(await cubit.pick('gamma'), isA<ServerPickIgnored>());
    expect((cubit.state as ServerListReady).switchingTo, 'beta');

    gate.complete();
    await first;
    expect(orchestrator.calls, ['switch beta']);
  });

  test('a pick of the server in use is ignored', () async {
    final cubit = await ready();
    final states = <ServerListState>[];
    final sub = cubit.stream.listen(states.add);
    addTearDown(sub.cancel);

    expect(await cubit.pick('alpha'), isA<ServerPickIgnored>());
    await pumpEventQueue();

    expect(orchestrator.calls, isEmpty);
    expect(states, isEmpty);
  });

  test('a failed pick reports the error and clears switching', () async {
    final cubit = await ready();
    const failure = ServerCapacityExceededException(
      currentConnected: 3,
      maxCapacity: 5,
    );
    orchestrator.onActivate = (_) async => throw failure;

    final pick = await cubit.pick('gamma');

    expect(pick, isA<ServerPickFailed>());
    // The failure itself, so the screen can name the limit, not the count.
    expect((pick as ServerPickFailed).error, same(failure));
    expect(
      pick.error,
      isA<ServerCapacityExceededException>().having(
        (e) => e.maxCapacity,
        'maxCapacity',
        5,
      ),
    );
    final state = cubit.state as ServerListReady;
    expect(state.switchingTo, isNull);
    expect(statesOf(state)['alpha'], ServerRowState.inUse);
    expect(statesOf(state)['gamma'], ServerRowState.notConnected);
  });

  test('a pick that ends after the cubit closed still reports it', () async {
    final cubit = await ready();
    final gate = Completer<void>();
    orchestrator.onActivate = (_) => gate.future;
    final pick = cubit.pick('beta');

    // The screen left mid-switch, and its provider closed the cubit.
    await cubit.close();
    gate.complete();

    expect(await pick, isA<ServerPickDone>());
  });

  group('when the registry cannot be read', () {
    test('it fails', () async {
      final failure = StateError('meta database closed');
      registered.failNextWatch = failure;

      final cubit = await ready();

      expect(cubit.state, isA<ServerListFailed>());
      expect((cubit.state as ServerListFailed).error, same(failure));
    });

    test('a failure after the first list fails it too', () async {
      final cubit = await ready();

      registered.fail(StateError('meta database closed'));
      await pumpEventQueue();

      expect(cubit.state, isA<ServerListFailed>());
    });

    test('a retry reads it again', () async {
      registered.failNextWatch = StateError('meta database closed');
      final cubit = await ready();

      cubit.retry();
      expect(cubit.state, isA<ServerListLoading>());
      await pumpEventQueue();

      expect(registered.watchCount, 2);
      expect(statesOf(cubit.state)['alpha'], ServerRowState.inUse);
    });

    test('a pick is ignored', () async {
      registered.failNextWatch = StateError('meta database closed');
      final cubit = await ready();

      expect(await cubit.pick('beta'), isA<ServerPickIgnored>());
      expect(orchestrator.calls, isEmpty);
    });
  });
}
