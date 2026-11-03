import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late FakeCallerAccessRepository access;

  final bgg = gateway('dg_1', name: 'BGG');
  final steam = gateway('dg_2', name: 'Steam', enabled: false);

  /// A caller who may do anything to a DataGateway.
  final everything = FakeCallerAccessRepository.dataGateway(
    create: AccessExtent.all,
    read: AccessExtent.all,
    update: AccessExtent.all,
    delete: AccessExtent.all,
  );

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = FakeCallerAccessRepository(everything);
  });

  DataGatewayListBloc build() =>
      DataGatewayListBloc(remote: remote, access: access);

  /// [gateways] as a caller who may do anything sees them.
  DataGatewayListReady ready(
    List<DataGateway> gateways, {
    Set<String> busy = const {},
    DataGatewayListOutcome? outcome,
  }) => DataGatewayListReady(
    gateways: gateways,
    mayCreate: true,
    mayUpdate: true,
    mayDelete: true,
    busy: busy,
    outcome: outcome,
  );

  group('loading', () {
    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'shows every DataGateway the server lists',
      setUp: () => remote.listing([bgg, steam]),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      expect: () => [
        const DataGatewayListLoading(),
        ready([bgg, steam]),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'follows the pages to the end of the list',
      setUp: () => remote.onFetchPage = (page, _) async =>
          page == 1 ? pageOf([bgg], hasMore: true) : pageOf([steam], page: 2),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      skip: 1,
      expect: () => [
        ready([bgg, steam]),
      ],
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
      verify: (_) => expect(access.refreshCount, 0),
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
        ready([steam], busy: const {'dg_2'}),
        ready(
          [steam.copyWith(enabled: true)],
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
        ready(
          [steam.copyWith(enabled: true)],
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
        ready(
          [steam],
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
        ready(
          const [],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.delete,
            result: DataGatewayActionResult.gone,
            name: 'BGG',
          ),
        ),
      ],
    );
  });

  group('what the caller may do (#456)', () {
    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'offers each action on its own permission',
      setUp: () {
        remote.listing([bgg]);
        access.current = FakeCallerAccessRepository.dataGateway(
          create: AccessExtent.all,
          read: AccessExtent.all,
          update: AccessExtent.some,
        );
      },
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      expect: () => [
        const DataGatewayListLoading(),
        DataGatewayListReady(gateways: [bgg], mayCreate: true, mayUpdate: true),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'offers nothing while access is unknown, then follows the answer',
      setUp: () {
        remote.listing([bgg]);
        access.current = const CallerAccess.unknown();
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          update: AccessExtent.all,
        );
      },
      expect: () => [
        const DataGatewayListLoading(),
        DataGatewayListReady(gateways: [bgg]),
        DataGatewayListReady(gateways: [bgg], mayUpdate: true),
      ],
      // Without reading the list again.
      verify: (_) => expect(remote.calls, ['fetchPage(1, 100)']),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'offers nothing without a session to ask',
      setUp: () => remote.listing([bgg]),
      build: () => DataGatewayListBloc(remote: remote),
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      skip: 1,
      expect: () => [
        DataGatewayListReady(gateways: [bgg]),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused change asks access again and keeps following it',
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
        await pumpEventQueue();
        expect(access.refreshCount, 1);
        // What the ask found.
        access.current = FakeCallerAccessRepository.dataGateway(
          create: AccessExtent.all,
          read: AccessExtent.all,
          delete: AccessExtent.all,
        );
      },
      skip: 3,
      expect: () {
        const refused = DataGatewayListOutcome(
          action: DataGatewayRowAction.connect,
          result: DataGatewayActionResult.refused,
          name: 'BGG',
        );
        return [
          ready([bgg], outcome: refused),
          DataGatewayListReady(
            gateways: [bgg],
            mayCreate: true,
            mayDelete: true,
            outcome: refused,
          ),
        ];
      },
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read asks access again',
      setUp: () => remote.refusingReads(),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListDenied(),
      ],
      verify: (_) => expect(access.refreshCount, 1),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read reads again once a changed answer allows read',
      setUp: () {
        // A first owner whose roles the server had not written yet.
        access = FakeCallerAccessRepository();
        remote.refusingReads();
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        remote.listing([bgg]);
        access.current = everything;
      },
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListDenied(),
        const DataGatewayListLoading(),
        ready([bgg]),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read stays denied while a changed answer still refuses read',
      setUp: () {
        access = FakeCallerAccessRepository();
        remote.refusingReads();
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        access.current = FakeCallerAccessRepository.dataGateway(
          create: AccessExtent.all,
        );
      },
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListDenied(),
      ],
      verify: (_) => expect(remote.calls, ['fetchPage(1, 100)']),
    );

    late Completer<PaginatedResult<DataGateway>> refusal;

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read reads again when an answer that allows read landed '
      'while it was out',
      setUp: () {
        access = FakeCallerAccessRepository();
        refusal = Completer();
        remote.onFetchPage = (_, _) => refusal.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        // The ask the refusal sets off finds this same answer, so it never
        // says anything changed.
        access.current = everything;
        await pumpEventQueue();
        remote.listing([bgg]);
        refusal.completeError(forbidden());
      },
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListDenied(),
        const DataGatewayListLoading(),
        ready([bgg]),
      ],
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read reads again only once for the answer that landed while '
      'it was out',
      setUp: () {
        access = FakeCallerAccessRepository();
        refusal = Completer();
        var reads = 0;
        remote.onFetchPage = (_, _) =>
            ++reads == 1 ? refusal.future : Future.error(forbidden());
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        access.current = everything;
        await pumpEventQueue();
        refusal.completeError(forbidden());
      },
      expect: () => [
        const DataGatewayListLoading(),
        const DataGatewayListDenied(),
        const DataGatewayListLoading(),
        const DataGatewayListDenied(),
      ],
      verify: (_) =>
          expect(remote.calls, ['fetchPage(1, 100)', 'fetchPage(1, 100)']),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a refused read asks access again even when a newer read has '
      'superseded it',
      setUp: () {
        final refused = Completer<PaginatedResult<DataGateway>>();
        var reads = 0;
        remote.onFetchPage = (_, _) {
          reads++;
          if (reads == 1) {
            // Refused after the second read has answered.
            Future<void>.delayed(
              Duration.zero,
              () => refused.completeError(forbidden()),
            );
            return refused.future;
          }
          return Future.value(pageOf([bgg]));
        };
      },
      build: build,
      act: (bloc) async {
        bloc
          ..add(const DataGatewayListLoadRequested())
          ..add(const DataGatewayListLoadRequested());
        await pumpEventQueue(times: 50);
      },
      verify: (bloc) {
        expect(bloc.state, ready([bgg]));
        expect(access.refreshCount, 1);
      },
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a read that succeeds while access is unknown asks access again',
      // The first ask failed with the server up, and nothing else would ask
      // again until a rehydrate trigger.
      setUp: () {
        remote.listing([bgg]);
        access.current = const CallerAccess.unknown();
      },
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      skip: 1,
      expect: () => [
        DataGatewayListReady(gateways: [bgg]),
      ],
      verify: (_) => expect(access.refreshCount, 1),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a read that succeeds while access is known asks nothing',
      setUp: () => remote.listing([bgg]),
      build: build,
      act: (bloc) => bloc.add(const DataGatewayListLoadRequested()),
      skip: 1,
      expect: () => [
        ready([bgg]),
      ],
      verify: (_) => expect(access.refreshCount, 0),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'drops a delete it may not send',
      setUp: () {
        remote.listing([bgg]);
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
          update: AccessExtent.all,
        );
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
      skip: 1,
      expect: () => [
        DataGatewayListReady(gateways: [bgg], mayUpdate: true),
      ],
      verify: (_) => expect(remote.calls, ['fetchPage(1, 100)']),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'drops a connect or disconnect it may not send',
      setUp: () {
        remote.listing([bgg]);
        access.current = FakeCallerAccessRepository.dataGateway(
          read: AccessExtent.all,
          delete: AccessExtent.all,
        );
      },
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        bloc
          ..add(
            const DataGatewayListActionRequested(
              DataGatewayRowAction.connect,
              'dg_1',
            ),
          )
          ..add(
            const DataGatewayListActionRequested(
              DataGatewayRowAction.disconnect,
              'dg_1',
            ),
          );
      },
      skip: 1,
      expect: () => [
        DataGatewayListReady(gateways: [bgg], mayDelete: true),
      ],
      verify: (_) => expect(remote.calls, ['fetchPage(1, 100)']),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'stops listening on close',
      setUp: () => remote.listing([bgg]),
      build: build,
      act: (bloc) async {
        bloc.add(const DataGatewayListLoadRequested());
        await pumpEventQueue();
        await bloc.close();
        access.current = const CallerAccess.unknown();
        await pumpEventQueue();
      },
      expect: () => [
        const DataGatewayListLoading(),
        ready([bgg]),
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
      ready(
        [bgg],
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
        expect(bloc.state, ready([bgg, steam], busy: const {'dg_2'}));
        // The server lists the connect's write once it has made it.
        remote.listing([bgg, steam.copyWith(enabled: true)]);
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
        ready(
          [bgg, steam.copyWith(enabled: true)],
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
      verify: (bloc) => expect(bloc.state, ready([steam])),
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
        ready(
          [bggOff],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.disconnect,
            result: DataGatewayActionResult.done,
            name: 'BGG',
          ),
        ),
      ),
    );

    blocTest<DataGatewayListBloc, DataGatewayListState>(
      'a connect that ends after a reload landed does not put back the row '
      'it saved before: the list is read again',
      // The server answers a connect with the row it saved before the
      // attempt, and the attempt can outlast a reload that saw someone
      // else's change to the same row.
      setUp: () {
        final renamed = steam.copyWith(enabled: true, name: 'Steam EU');
        var reads = 0;
        remote.onFetchPage = (_, _) async =>
            pageOf(++reads == 1 ? [bgg, steam] : [bgg, renamed]);
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
        ready(
          [bgg, steam.copyWith(enabled: true, name: 'Steam EU')],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.connect,
            result: DataGatewayActionResult.done,
            name: 'Steam',
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
        ready(
          [steam],
          outcome: const DataGatewayListOutcome(
            action: DataGatewayRowAction.delete,
            result: DataGatewayActionResult.done,
            name: 'BGG',
          ),
        ),
      ),
    );

    for (final (ends, error, result) in [
      ('fails', unreachable, DataGatewayActionResult.failed),
      ('is refused', forbidden, DataGatewayActionResult.refused),
    ]) {
      blocTest<DataGatewayListBloc, DataGatewayListState>(
        'an action that $ends after a reload landed keeps the reloaded row: '
        'it says nothing about the row',
        setUp: () {
          var reads = 0;
          remote.onFetchPage = (_, _) async =>
              pageOf(++reads == 1 ? [bgg] : [bggOff]);
          pending = Completer<DataGatewayChangeResult>();
          remote.onDisconnect = (_) => pending.future;
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
          // Someone else disabled it meanwhile, and the reload saw that.
          bloc.add(const DataGatewayListLoadRequested());
          await pumpEventQueue();
          pending.completeError(error());
          await pumpEventQueue();
        },
        verify: (bloc) => expect(
          bloc.state,
          ready(
            [bggOff],
            outcome: DataGatewayListOutcome(
              action: DataGatewayRowAction.disconnect,
              result: result,
              name: 'BGG',
            ),
          ),
        ),
      );
    }
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
      ready([bgg]),
    ],
  );
}
