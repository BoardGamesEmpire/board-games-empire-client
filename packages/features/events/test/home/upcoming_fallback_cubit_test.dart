import 'dart:async';

import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/event_list_items.dart';
import '../support/fake_connectivity.dart';
import '../support/fake_event_remote.dart';

/// [count] rows as the server sends them, `e-0` soonest.
List<EventSnapshot> _snapshots(int count, {String? householdId}) => [
  for (var n = 0; n < count; n++)
    EventSnapshot(
      event: item('e-$n', householdId: householdId).event,
      occurrences: [confirmed('o-$n', DateTime.utc(2026, 11, 2 + n, 19))],
    ),
];

/// Lets everything already scheduled run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

List<String> _rowIds(UpcomingFallbackState state) => switch (state) {
  UpcomingFallbackReady(:final rows) => [for (final r in rows) r.event.id],
  _ => fail('expected rows, got $state'),
};

void main() {
  final now = DateTime.utc(2026, 11, 1, 12);

  late FakeEventRemote remote;
  late FakeConnectivity connectivity;

  /// Fails a test that forgets to say what the server answers.
  setUp(() {
    remote = FakeEventRemote((_) => throw StateError('the list is not read'));
    connectivity = FakeConnectivity();
  });

  tearDown(() => connectivity.close());

  UpcomingFallbackCubit build({
    Stream<List<Household>>? households,
    bool hasRemote = true,
    bool hasConnectivity = true,
  }) {
    final cubit = UpcomingFallbackCubit(
      remote: hasRemote ? remote : null,
      connectivity: hasConnectivity ? connectivity : null,
      households: households,
      now: () => now,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  test('activate requests page 1 with limit 3', () async {
    remote.browse = (_) => browsePage(_snapshots(3));
    final cubit = build();

    cubit.activate();
    await _settle();

    expect(remote.browseRequests, [(page: 1, limit: 3)]);
    expect(remote.requests, isEmpty, reason: 'never the attending list');
  });

  test('is idle until activated, then loading until it answers', () async {
    final answer = Completer<PaginatedResult<EventSnapshot>>();
    remote.browse = (_) => answer.future;
    final cubit = build();
    expect(cubit.state, const UpcomingFallbackIdle());

    cubit.activate();
    expect(cubit.state, const UpcomingFallbackLoading());

    answer.complete(browsePage(_snapshots(1)));
    await _settle();
    expect(_rowIds(cubit.state), ['e-0']);
  });

  test('orders rows and carries no rsvp', () async {
    remote.browse = (_) => browsePage(_snapshots(3).reversed.toList());
    final cubit = build();

    cubit.activate();
    await _settle();

    expect(_rowIds(cubit.state), ['e-0', 'e-1', 'e-2']);
    final rows = (cubit.state as UpcomingFallbackReady).rows;
    expect(rows.map((row) => row.rsvp), everyElement(isNull));
  });

  test('caps the rows, whatever the server sends', () async {
    remote.browse = (_) => browsePage(_snapshots(5));
    final cubit = build();

    cubit.activate();
    await _settle();

    expect(_rowIds(cubit.state), ['e-0', 'e-1', 'e-2']);
  });

  test('a failed read is an empty ready', () async {
    remote.browse = (_) => throw const EventRemoteTransientException('down');
    final cubit = build();

    cubit.activate();
    await _settle();

    expect(cubit.state, const UpcomingFallbackReady([]));
  });

  test('offline makes no request', () async {
    connectivity.current = ConnectivityState.offline;
    final cubit = build();

    cubit.activate();
    await _settle();

    expect(remote.browseRequests, isEmpty);
    expect(cubit.state, const UpcomingFallbackReady([]));
  });

  test('an unknown connection is worth trying', () async {
    connectivity.current = ConnectivityState.unknown;
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build();

    cubit.activate();
    await _settle();

    expect(remote.browseRequests, hasLength(1));
    expect(_rowIds(cubit.state), ['e-0']);
  });

  test('a null remote is an empty ready', () async {
    final cubit = build(hasRemote: false);

    cubit.activate();
    await _settle();

    expect(cubit.state, const UpcomingFallbackReady([]));
  });

  test('no connectivity service still reads', () async {
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build(hasConnectivity: false);

    cubit.activate();
    await _settle();

    expect(_rowIds(cubit.state), ['e-0']);
  });

  test('reconnecting reads again while active', () async {
    connectivity.current = ConnectivityState.offline;
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build();
    cubit.activate();
    await _settle();
    expect(remote.browseRequests, isEmpty);

    connectivity.change(ConnectivityState.online);
    await _settle();

    expect(remote.browseRequests, hasLength(1));
    expect(_rowIds(cubit.state), ['e-0']);
  });

  test('reconnecting reads nothing while idle', () async {
    connectivity.current = ConnectivityState.offline;
    final cubit = build();
    await _settle();

    connectivity.change(ConnectivityState.online);
    await _settle();

    expect(remote.browseRequests, isEmpty);
    expect(cubit.state, const UpcomingFallbackIdle());
  });

  test('going offline empties the rows', () async {
    remote.browse = (_) => browsePage(_snapshots(2));
    final cubit = build();
    cubit.activate();
    await _settle();
    expect(_rowIds(cubit.state), hasLength(2));

    connectivity.change(ConnectivityState.offline);
    await _settle();

    expect(cubit.state, const UpcomingFallbackReady([]));
  });

  test('going offline drops a read in flight', () async {
    final answer = Completer<PaginatedResult<EventSnapshot>>();
    remote.browse = (_) => answer.future;
    final cubit = build();
    cubit.activate();
    await _settle();

    connectivity.change(ConnectivityState.offline);
    await _settle();
    answer.complete(browsePage(_snapshots(1)));
    await _settle();

    expect(cubit.state, const UpcomingFallbackReady([]));
  });

  test('the replayed connectivity state reads nothing extra', () async {
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build();

    cubit.activate();
    // Time for the service's replay of its current state to arrive.
    await _settle();
    await _settle();

    expect(remote.browseRequests, hasLength(1));
  });

  test('reload keeps the rows up until it answers', () async {
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build();
    cubit.activate();
    await _settle();

    final answer = Completer<PaginatedResult<EventSnapshot>>();
    remote.browse = (_) => answer.future;
    cubit.reload();
    await _settle();
    expect(remote.browseRequests, hasLength(2));
    expect(_rowIds(cubit.state), ['e-0']);

    answer.complete(browsePage(_snapshots(2)));
    await _settle();
    expect(_rowIds(cubit.state), ['e-0', 'e-1']);
  });

  test('a failed reload keeps the rows up', () async {
    remote.browse = (_) => browsePage(_snapshots(2));
    final cubit = build();
    cubit.activate();
    await _settle();

    remote.browse = (_) => throw const EventRemoteTransientException('down');
    cubit.reload();
    await _settle();

    expect(remote.browseRequests, hasLength(2));
    expect(_rowIds(cubit.state), ['e-0', 'e-1']);
  });

  test('a failed reload after going offline shows nothing old', () async {
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build();
    cubit.activate();
    await _settle();

    connectivity.change(ConnectivityState.offline);
    await _settle();
    remote.browse = (_) => throw const EventRemoteTransientException('down');
    connectivity.change(ConnectivityState.online);
    await _settle();

    expect(cubit.state, const UpcomingFallbackReady([]));
  });

  test('a read replacing another wins, whichever answers first', () async {
    final first = Completer<PaginatedResult<EventSnapshot>>();
    remote.browse = (_) => first.future;
    final cubit = build();
    cubit.activate();
    await _settle();

    remote.browse = (_) => browsePage(_snapshots(2));
    cubit.reload();
    await _settle();
    first.complete(browsePage(_snapshots(1)));
    await _settle();

    expect(_rowIds(cubit.state), ['e-0', 'e-1']);
  });

  test('reload while idle does nothing', () async {
    final cubit = build();

    cubit.reload();
    await _settle();

    expect(remote.browseRequests, isEmpty);
    expect(cubit.state, const UpcomingFallbackIdle());
  });

  test('activate while active reads nothing more', () async {
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build();
    cubit.activate();
    await _settle();

    cubit.activate();
    await _settle();

    expect(remote.browseRequests, hasLength(1));
  });

  test('deactivate drops a read in flight', () async {
    final answer = Completer<PaginatedResult<EventSnapshot>>();
    remote.browse = (_) => answer.future;
    final cubit = build();
    cubit.activate();
    await _settle();

    cubit.deactivate();
    expect(cubit.state, const UpcomingFallbackIdle());

    answer.complete(browsePage(_snapshots(1)));
    await _settle();
    expect(cubit.state, const UpcomingFallbackIdle());
  });

  test('activating again after deactivating reads again', () async {
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build();
    cubit.activate();
    await _settle();

    cubit.deactivate();
    cubit.activate();
    expect(cubit.state, const UpcomingFallbackLoading());
    await _settle();

    expect(remote.browseRequests, hasLength(2));
    expect(_rowIds(cubit.state), ['e-0']);
  });

  test('closing during a read throws nothing', () async {
    final answer = Completer<PaginatedResult<EventSnapshot>>();
    remote.browse = (_) => answer.future;
    final cubit = build();
    cubit.activate();
    await _settle();

    await cubit.close();
    answer.complete(browsePage(_snapshots(1)));
    await _settle();

    expect(cubit.isClosed, isTrue);
  });

  test('closing during a read that fails throws nothing', () async {
    final answer = Completer<PaginatedResult<EventSnapshot>>();
    remote.browse = (_) => answer.future;
    final cubit = build();
    cubit.activate();
    await _settle();

    await cubit.close();
    answer.completeError(const EventRemoteTransientException('down'));
    await _settle();

    expect(cubit.isClosed, isTrue);
  });

  test('household names reach the rows without another request', () async {
    final households = StreamController<List<Household>>.broadcast();
    addTearDown(households.close);
    remote.browse = (_) => browsePage(_snapshots(1, householdId: 'h-1'));
    final cubit = build(households: households.stream);
    cubit.activate();
    await _settle();
    expect(
      (cubit.state as UpcomingFallbackReady).rows.single.householdName,
      isNull,
    );

    households.add([
      Household(
        id: 'h-1',
        name: 'The Hearth',
        createdAt: kItemInstant,
        updatedAt: kItemInstant,
      ),
    ]);
    await _settle();

    expect(
      (cubit.state as UpcomingFallbackReady).rows.single.householdName,
      'The Hearth',
    );
    expect(remote.browseRequests, hasLength(1));
  });

  test('a failed households stream loses only the names', () async {
    final households = StreamController<List<Household>>.broadcast();
    addTearDown(households.close);
    remote.browse = (_) => browsePage(_snapshots(1));
    final cubit = build(households: households.stream);
    cubit.activate();
    await _settle();

    households.addError(StateError('no names'));
    await _settle();

    expect(_rowIds(cubit.state), ['e-0']);
  });
}
