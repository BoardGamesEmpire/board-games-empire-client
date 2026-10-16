import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late DataGatewayAccess access;

  final bgg = gateway('dg_1', name: 'BGG');
  final steam = gateway('dg_2', name: 'Steam', enabled: false);

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = DataGatewayAccess(remote: remote);
  });

  tearDown(() => access.dispose());

  DataGatewayListBloc build() =>
      DataGatewayListBloc(remote: remote, access: access);

  group('loading', () {
    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'shows every DataGateway the server lists',
      setUp: () => remote.listing([bgg, steam]),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      expect: () => [
        const DataGatewayListLoading(),
        DataGatewayListReady(gateways: [bgg, steam]),
      ],
      verify: (_) => expect(access.value.read, DataGatewayRead.granted),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'follows the pages to the end of the list',
      setUp: () => remote.onFetchPage = (page, _) async =>
          page == 1 ? pageOf([bgg], hasMore: true) : pageOf([steam], page: 2),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      skip: 1,
      expect: () => [
        DataGatewayListReady(gateways: [bgg, steam]),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read is access-denied, and the session learns it',
      setUp: () => remote.refusingReads(),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListDenied(),
      ],
      verify: (_) => expect(access.value.read, DataGatewayRead.denied),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a list that never ends is a failed read, not part of a list shown as '
      'the whole of it',
      setUp: () =>
          remote.onFetchPage = (page, _) async =>
              pageOf([gateway('dg_$page')], page: page, hasMore: true),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListFailed(),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'any other failure offers a retry and says nothing about access',
      setUp: () => remote.onFetchPage = (_, _) async => throw unreachable(),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListFailed(),
      ],
      verify: (_) => expect(access.value.read, DataGatewayRead.unknown),
    );
  });

  group('connect and disconnect', () {
    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'marks the row busy, then shows the row the server returned and what '
      'its attempt answered',
      setUp: () {
        remote.listing([steam]);
        remote.onConnect = (_) async => changed(
          steam.copyWith(enabled: true),
          attempted: DataGatewayConnectionAction.connect,
        );
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.connect,
            'dg_2',
          ),
        );
      },
      skip: 2,
      expect: () => [
        DataGatewayListReady(gateways: [steam], busy: const {'dg_2'}),
        DataGatewayListReady(
          gateways: [steam.copyWith(enabled: true)],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.connect,
            result: DataGatewayActionResult.done,
            name: 'Steam',
          ),
        ),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a connect the server could not complete is reported as such, with the '
      'row still enabled, because the server enables it first',
      setUp: () {
        remote.listing([steam]);
        remote.onConnect = (_) async => changed(
          steam.copyWith(enabled: true),
          attempted: DataGatewayConnectionAction.connect,
          succeeded: false,
        );
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.connect,
            'dg_2',
          ),
        );
      },
      skip: 3,
      expect: () => [
        DataGatewayListReady(
          gateways: [steam.copyWith(enabled: true)],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.connect,
            result: DataGatewayActionResult.attemptFailed,
            name: 'Steam',
          ),
        ),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'ignores a second action on a row that is already busy',
      setUp: () {
        remote.listing([bgg]);
        final pending = Completer<DataGatewayChangeResult>();
        remote.onDisconnect = (_) => pending.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc
          ..add(
            const DataGatewayListActionRequested(
              DataGatewayRowAction.disconnect,
              'dg_1',
            ),
          )
          ..add(
            const DataGatewayListActionRequested(
              DataGatewayRowAction.delete,
              'dg_1',
            ),
          );
        await pumpEventQueue();
      },
      verify: (_) =>
          expect(remote.calls, ['fetchPage(1, 100)', 'disconnect(dg_1)']),
    );
  });

  group('delete', () {
    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'removes the row',
      setUp: () {
        remote.listing([bgg, steam]);
        remote.onDelete = (_) async =>
            changed(bgg, attempted: DataGatewayConnectionAction.disconnect);
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.delete,
            'dg_1',
          ),
        );
      },
      skip: 3,
      expect: () => [
        DataGatewayListReady(
          gateways: [steam],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.delete,
            result: DataGatewayActionResult.done,
            name: 'BGG',
          ),
        ),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a row someone else deleted is removed and reported as gone',
      setUp: () {
        remote.listing([bgg]);
        remote.onDelete = (_) async =>
            throw const DataGatewayNotFoundException('gone', statusCode: 404);
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.delete,
            'dg_1',
          ),
        );
      },
      skip: 3,
      expect: () => [
        const DataGatewayListReady(
          gateways: [],
          outcome: DataGatewayListOutcome(
            action: DataGatewayRowAction.delete,
            result: DataGatewayActionResult.gone,
            name: 'BGG',
          ),
        ),
      ],
    );
  });

  group('a reader who may not change DataGateways (#41)', () {
    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'the first refused change hides the change actions and tells the '
      'session',
      setUp: () {
        remote.listing([bgg]);
        remote.onConnect = (_) async => throw forbidden();
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.connect,
            'dg_1',
          ),
        );
      },
      skip: 3,
      expect: () => [
        DataGatewayListReady(
          gateways: [bgg],
          mayChange: false,
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.connect,
            result: DataGatewayActionResult.refused,
            name: 'BGG',
          ),
        ),
      ],
      verify: (_) => expect(access.value.mayChange, isFalse),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read is not a refused change: a user let in later in the '
      'session is offered the change actions',
      setUp: () {
        remote.listing([bgg]);
        access.readDenied();
      },
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      skip: 1,
      expect: () => [
        DataGatewayListReady(gateways: [bgg]),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'opens with the change actions hidden once the session has learned it',
      setUp: () {
        remote.listing([bgg]);
        access.changeDenied();
      },
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      skip: 1,
      expect: () => [
        DataGatewayListReady(gateways: [bgg], mayChange: false),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'hides them when another screen learns it',
      setUp: () => remote.listing([bgg]),
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        access.changeDenied();
      },
      skip: 2,
      expect: () => [
        DataGatewayListReady(gateways: [bgg], mayChange: false),
      ],
    );
  });

  blocTest<DataGatewayListBloc, DataGatewayListState>(
    'any other failed change keeps the row and says the action failed',
    setUp: () {
      remote.listing([bgg]);
      remote.onDisconnect = (_) async => throw unreachable();
    },
    build: build,
    act: (bloc) async {
      bloc.add(const DataGatewayListLoadRequested());
      await pumpEventQueue();
      bloc.add(
        const DataGatewayListActionRequested(
          DataGatewayRowAction.disconnect,
          'dg_1',
        ),
      );
    },
    skip: 3,
    expect: () => [
      DataGatewayListReady(
        gateways: [bgg],
        outcome: const DataGatewayListOutcome(
          action: DataGatewayRowAction.disconnect,
          result: DataGatewayActionResult.failed,
          name: 'BGG',
        ),
      ),
    ],
  );

  group('reloading while work is in flight', () {
    late Completer<DataGatewayChangeResult> pending;
    late Completer<PaginatedResult<DataGateway>> stale;
    final bggOff = bgg.copyWith(enabled: false);

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'keeps the busy row busy, and still reports its outcome',
      // The route back from editing one row reloads the list while an
      // action on another may still be running.
      setUp: () {
        remote.listing([bgg, steam]);
        pending = Completer<DataGatewayChangeResult>();
        remote.onConnect = (_) => pending.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.connect,
            'dg_2',
          ),
        );
        await pumpEventQueue();
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        expect(
          bloc.state,
          DataGatewayListReady(gateways: [bgg, steam], busy: const {'dg_2'}),
        );
        pending.complete(
          changed(
            steam.copyWith(enabled: true),
            attempted: DataGatewayConnectionAction.connect,
          ),
        );
        await pumpEventQueue();
      },
      verify: (bloc) => expect(
        bloc.state,
        DataGatewayListReady(
          gateways: [bgg, steam.copyWith(enabled: true)],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.connect,
            result: DataGatewayActionResult.done,
            name: 'Steam',
          ),
        ),
      ),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'the latest of two overlapping reads wins, whichever answers first',
      setUp: () {
        final slow = Completer<PaginatedResult<DataGateway>>();
        var reads = 0;
        remote.onFetchPage = (_, _) {
          reads++;
          if (reads == 1) {
            Future<void>.delayed(
              Duration.zero,
              () => slow.complete(pageOf([bgg])),
            );
            return slow.future.then((page) async {
              // Answers after the second read has.
              await pumpEventQueue();
              return page;
            });
          }
          return Future.value(pageOf([steam]));
        };
      },
      build: build,
      act: (bloc) async {
        bloc
          ..add(const DataGatewayListLoadRequested())
          ..add(const DataGatewayListLoadRequested());
        await pumpEventQueue(times: 50);
      },
      verify: (bloc) =>
          expect(bloc.state, DataGatewayListReady(gateways: [steam])),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a read the server may have answered before an action does not put the '
      'row back: the list is read again',
      // The server can serve the reload first and the disconnect second while
      // the client hears the disconnect first. The reload's rows are then
      // older than the row the disconnect returned.
      setUp: () {
        stale = Completer<PaginatedResult<DataGateway>>();
        var reads = 0;
        remote
          ..onFetchPage = (_, _) {
            reads++;
            return switch (reads) {
              1 => Future.value(pageOf([bgg])),
              2 => stale.future,
              _ => Future.value(pageOf([bggOff])),
            };
          }
          ..onDisconnect = (_) async => changed(
            bggOff,
            attempted: DataGatewayConnectionAction.disconnect,
          );
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.disconnect,
            'dg_1',
          ),
        );
        await pumpEventQueue();
        stale.complete(pageOf([bgg]));
        await pumpEventQueue();
      },
      verify: (bloc) => expect(
        bloc.state,
        DataGatewayListReady(
          gateways: [bggOff],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.disconnect,
            result: DataGatewayActionResult.done,
            name: 'BGG',
          ),
        ),
      ),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'an action that ends while a failed reload has taken the list down '
      'reports its outcome when the list is back',
      setUp: () {
        var reads = 0;
        remote.onFetchPage = (_, _) async {
          reads++;
          if (reads == 2) throw unreachable();
          return pageOf(reads == 1 ? [bgg, steam] : [steam]);
        };
        pending = Completer<DataGatewayChangeResult>();
        remote.onDelete = (_) => pending.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const DataGatewayListActionRequested(
            DataGatewayRowAction.delete,
            'dg_1',
          ),
        );
        await pumpEventQueue();
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        expect(bloc.state, const DataGatewayListFailed());

        pending.complete(changed(bgg));
        await pumpEventQueue();
        // The retry the failed state offers.
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
      },
      verify: (bloc) => expect(
        bloc.state,
        DataGatewayListReady(
          gateways: [steam],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.delete,
            result: DataGatewayActionResult.done,
            name: 'BGG',
          ),
        ),
      ),
    );
  });

  blocTest<DataGatewayListBloc, DataGatewayListState>(
    'dismissing the outcome clears it',
    setUp: () {
      remote.listing([bgg]);
      remote.onDisconnect = (_) async => throw unreachable();
    },
    build: build,
    act: (bloc) async {
      bloc.add(const DataGatewayListLoadRequested());
      await pumpEventQueue();
      bloc.add(
        const DataGatewayListActionRequested(
          DataGatewayRowAction.disconnect,
          'dg_1',
        ),
      );
      await pumpEventQueue();
      bloc.add(const DataGatewayListOutcomeDismissed());
    },
    skip: 4,
    expect: () => [
      DataGatewayListReady(gateways: [bgg]),
    ],
  );
}
