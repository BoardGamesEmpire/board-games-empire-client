import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_household_invite_remote.dart';

HouseholdInvite _sent(
  String id, {
  HouseholdInviteStatus status = HouseholdInviteStatus.pending,
}) => invite(
  id,
  status: status,
  inviterId: 'u_me',
  householdId: 'hh_9',
  householdName: 'Sunday Crew',
);

/// Lets every pending microtask and zero-delay timer run.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeHouseholdInviteRemote remote;

  setUp(() => remote = FakeHouseholdInviteRemote());

  SentInvitesBloc build({int pageSize = 25}) =>
      SentInvitesBloc(remote: remote, pageSize: pageSize);

  SentInvitesReady ready(SentInvitesBloc bloc) =>
      bloc.state as SentInvitesReady;

  void listing(List<HouseholdInvite> rows) =>
      remote.onFetchSent = (_, _, _) async => pageOf(rows);

  List<String> withdraws() =>
      remote.calls.where((c) => c.startsWith('withdraw')).toList();

  blocTest<SentInvitesBloc, SentInvitesState>(
    'loads open and expired invites',
    setUp: () => listing([_sent('i_1')]),
    build: build,
    act: (bloc) => bloc.add(const SentInvitesLoadRequested()),
    expect: () => [
      const SentInvitesLoading(),
      SentInvitesReady(
        invites: [_sent('i_1')],
        filter: SentInviteFilter.openAndExpired,
        hasMore: false,
        loadingMore: false,
      ),
    ],
    verify: (_) => expect(remote.calls, ['fetchSent(null, 1, 25)']),
  );

  blocTest<SentInvitesBloc, SentInvitesState>(
    'a filter asks for its status',
    setUp: () => listing([_sent('i_1', status: HouseholdInviteStatus.revoked)]),
    build: build,
    act: (bloc) =>
        bloc.add(const SentInvitesFilterChanged(SentInviteFilter.revoked)),
    expect: () => [
      const SentInvitesLoading(filter: SentInviteFilter.revoked),
      isA<SentInvitesReady>().having(
        (s) => s.filter,
        'filter',
        SentInviteFilter.revoked,
      ),
    ],
    verify: (bloc) {
      expect(remote.calls, ['fetchSent(revoked, 1, 25)']);
      expect(bloc.filter, SentInviteFilter.revoked);
    },
  );

  test('a filter changed before the first read answers shows only the new '
      "filter's rows", () async {
    final first = Completer<PaginatedResult<HouseholdInvite>>();
    remote.onFetchSent = (status, _, _) => status == null
        ? first.future
        : Future.value(
            pageOf([_sent('i_2', status: HouseholdInviteStatus.revoked)]),
          );
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    final states = <SentInvitesState>[];
    bloc.stream.listen(states.add);
    await _settle();
    bloc.add(const SentInvitesFilterChanged(SentInviteFilter.revoked));
    await _settle();
    // The first filter's read answers last, with a row of its own.
    first.complete(pageOf([_sent('i_1')]));
    await _settle();

    final last = states.whereType<SentInvitesReady>().last;
    expect(bloc.state, last);
    expect(last.invites.map((i) => i.id), ['i_2']);
    expect(last.filter, SentInviteFilter.revoked);
    expect(
      states
          .whereType<SentInvitesReady>()
          .expand((s) => s.invites)
          .map((i) => i.id),
      isNot(contains('i_1')),
    );
  });

  test(
    'a filter changed over loaded rows starts over from the spinner',
    () async {
      final revoked = Completer<PaginatedResult<HouseholdInvite>>();
      remote.onFetchSent = (status, _, _) => status == null
          ? Future.value(pageOf([_sent('i_1')]))
          : revoked.future;
      final bloc = build()..add(const SentInvitesLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      expect(ready(bloc).invites.map((i) => i.id), ['i_1']);

      bloc.add(const SentInvitesFilterChanged(SentInviteFilter.revoked));
      await _settle();
      expect(
        bloc.state,
        const SentInvitesLoading(filter: SentInviteFilter.revoked),
      );

      revoked.complete(
        pageOf([_sent('i_2', status: HouseholdInviteStatus.revoked)]),
      );
      await _settle();
      expect(ready(bloc).invites.map((i) => i.id), ['i_2']);
      expect(ready(bloc).filter, SentInviteFilter.revoked);
    },
  );

  test('a read that fails is retryable', () async {
    remote.onFetchSent = (_, _, _) async => throw offline();
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();
    expect(bloc.state, const SentInvitesFailed());

    listing([_sent('i_1')]);
    bloc.add(const SentInvitesLoadRequested());
    await _settle();
    expect(ready(bloc).invites.map((i) => i.id), ['i_1']);
  });

  test('a refused read is failed too', () async {
    remote.onFetchSent = (_, _, _) async => throw refused(403);
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();
    expect(bloc.state, const SentInvitesFailed());
  });

  Future<SentInvitesBloc> loaded(SentInviteFilter filter) async {
    listing([_sent('i_1'), _sent('i_2')]);
    final bloc = build();
    addTearDown(bloc.close);
    if (filter == SentInviteFilter.openAndExpired) {
      bloc.add(const SentInvitesLoadRequested());
    } else {
      bloc.add(SentInvitesFilterChanged(filter));
    }
    await _settle();
    return bloc;
  }

  for (final filter in [
    SentInviteFilter.openAndExpired,
    SentInviteFilter.pending,
  ]) {
    test(
      filter == SentInviteFilter.pending
          ? 'withdrawing under the pending filter drops the row'
          : 'withdrawing drops the row',
      () async {
        remote.onWithdraw = (id) async =>
            _sent(id, status: HouseholdInviteStatus.withdrawn);
        final bloc = await loaded(filter);
        final before = remote.calls.length;

        bloc.add(const SentInvitesWithdrawRequested('i_1'));
        await _settle();

        expect(ready(bloc).invites.map((i) => i.id), ['i_2']);
        expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.done);
        expect(ready(bloc).outcome?.action, HouseholdInviteRowAction.withdraw);
        expect(ready(bloc).busy, isEmpty);
        expect(remote.calls.skip(before), ['withdraw(i_1)']);
      },
    );
  }

  test('a double tap withdraws once', () async {
    final answer = Completer<HouseholdInvite>();
    remote.onWithdraw = (_) => answer.future;
    final bloc = await loaded(SentInviteFilter.openAndExpired);

    bloc
      ..add(const SentInvitesWithdrawRequested('i_1'))
      ..add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();
    expect(ready(bloc).busy, {'i_1'});
    answer.complete(_sent('i_1', status: HouseholdInviteStatus.withdrawn));
    await _settle();

    expect(withdraws(), hasLength(1));
  });

  test('an expired row is not withdrawn', () async {
    listing([_sent('i_1', status: HouseholdInviteStatus.expired)]);
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();

    expect(withdraws(), isEmpty);
    expect(ready(bloc).outcome, isNull);
  });

  test('a row no longer listed is not withdrawn', () async {
    final bloc = await loaded(SentInviteFilter.openAndExpired);

    bloc.add(const SentInvitesWithdrawRequested('i_gone'));
    await _settle();

    expect(withdraws(), isEmpty);
  });

  test('a 410 says it expired and reads the list again', () async {
    var reads = 0;
    remote
      ..onFetchSent = ((_, _, _) async => pageOf([
        ++reads == 1
            ? _sent('i_1')
            : _sent('i_1', status: HouseholdInviteStatus.expired),
      ]))
      ..onWithdraw = (_) async => throw refused(410);
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();

    expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.refused);
    expect(
      (ready(bloc).outcome?.error as HouseholdInviteRefusedException)
          .statusCode,
      410,
    );
    expect(remote.calls.where((c) => c == 'fetchSent(null, 1, 25)'), [
      'fetchSent(null, 1, 25)',
      'fetchSent(null, 1, 25)',
    ]);
    expect(ready(bloc).invites.single.status, HouseholdInviteStatus.expired);
  });

  test("changing the filter retires the last withdraw's outcome", () async {
    var reads = 0;
    remote
      ..onFetchSent = ((status, _, _) async => pageOf([
        if (status != null)
          _sent('i_2')
        else if (++reads == 1)
          _sent('i_1')
        else
          _sent('i_1', status: HouseholdInviteStatus.expired),
      ]))
      ..onWithdraw = (_) async => throw refused(410);
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();
    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();
    expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.refused);

    final states = <SentInvitesState>[];
    bloc.stream.listen(states.add);
    bloc.add(const SentInvitesFilterChanged(SentInviteFilter.pending));
    await _settle();

    expect(states, [
      const SentInvitesLoading(filter: SentInviteFilter.pending),
      SentInvitesReady(
        invites: [_sent('i_2')],
        filter: SentInviteFilter.pending,
        hasMore: false,
        loadingMore: false,
      ),
    ]);
  });

  test('a withdraw that answers after a reload settles against the reloaded '
      'rows', () async {
    final answer = Completer<HouseholdInvite>();
    listing([_sent('i_1')]);
    remote.onWithdraw = (_) => answer.future;
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();
    listing([_sent('i_1'), _sent('i_3')]);
    bloc.add(const SentInvitesLoadRequested());
    await _settle();
    expect(ready(bloc).invites.map((i) => i.id), ['i_1', 'i_3']);

    answer.complete(_sent('i_1', status: HouseholdInviteStatus.withdrawn));
    await _settle();

    expect(ready(bloc).invites.map((i) => i.id), ['i_3']);
  });

  test('a withdraw that spans a filter change reads the new filter again, '
      'which the server may have answered before the withdraw', () async {
    final answer = Completer<HouseholdInvite>();
    var withdrawn = false;
    remote
      ..onFetchSent = ((status, _, _) async => pageOf([
        if (status == null && !withdrawn) _sent('i_1'),
        if (status == HouseholdInviteStatus.withdrawn && withdrawn)
          _sent('i_1', status: HouseholdInviteStatus.withdrawn),
      ]))
      ..onWithdraw = (_) => answer.future;
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();
    bloc.add(const SentInvitesFilterChanged(SentInviteFilter.withdrawn));
    await _settle();
    expect(ready(bloc).invites, isEmpty);

    withdrawn = true;
    answer.complete(_sent('i_1', status: HouseholdInviteStatus.withdrawn));
    await _settle();

    expect(remote.calls.last, 'fetchSent(withdrawn, 1, 25)');
    expect(ready(bloc).invites.map((i) => i.id), ['i_1']);
  });

  test('a withdraw that fails after a filter change still says so', () async {
    final answer = Completer<HouseholdInvite>();
    listing([_sent('i_1')]);
    remote.onWithdraw = (_) => answer.future;
    final bloc = build()..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();
    bloc.add(const SentInvitesFilterChanged(SentInviteFilter.pending));
    await _settle();
    expect(ready(bloc).outcome, isNull);
    final reads = remote.calls.length;

    answer.completeError(offline());
    await _settle();

    // Nothing was written, so the new filter's rows stand.
    expect(remote.calls.length, reads);
    expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.failed);
  });

  test('a failure keeps the row', () async {
    remote.onWithdraw = (_) async => throw offline();
    final bloc = await loaded(SentInviteFilter.openAndExpired);
    final before = remote.calls.length;

    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();

    expect(ready(bloc).invites.map((i) => i.id), ['i_1', 'i_2']);
    expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.failed);
    expect(remote.calls.skip(before), ['withdraw(i_1)']);
  });

  test('dismissing the outcome clears it', () async {
    remote.onWithdraw = (_) async => throw offline();
    final bloc = await loaded(SentInviteFilter.openAndExpired);
    bloc.add(const SentInvitesWithdrawRequested('i_1'));
    await _settle();
    expect(ready(bloc).outcome, isNotNull);

    bloc.add(const SentInvitesOutcomeDismissed());
    await _settle();

    expect(ready(bloc).outcome, isNull);
  });

  test('more appends the next page', () async {
    remote.onFetchSent = (_, page, limit) async => pageOf(
      [_sent('i_$page')],
      page: page,
      limit: limit,
      hasMore: page == 1,
    );
    final bloc = build(pageSize: 1)..add(const SentInvitesLoadRequested());
    addTearDown(bloc.close);
    await _settle();
    expect(ready(bloc).hasMore, isTrue);

    bloc.add(const SentInvitesMoreRequested());
    await _settle();

    expect(remote.calls.last, 'fetchSent(null, 2, 1)');
    expect(ready(bloc).invites.map((i) => i.id), ['i_1', 'i_2']);
    expect(ready(bloc).hasMore, isFalse);
  });

  for (final withdrawFirst in [true, false]) {
    test('a row withdrawn while More is out reads the list again, so the page '
        'cannot skip a row (the withdraw answers '
        '${withdrawFirst ? 'first' : 'last'})', () async {
      // The server holds a, b, c, d. Withdrawing a before the server reads
      // page 2 moves c onto page 1, so page 2 is d alone.
      final more = Completer<PaginatedResult<HouseholdInvite>>();
      final withdraw = Completer<HouseholdInvite>();
      var reads = 0;
      remote
        ..onFetchSent = ((_, page, limit) => switch (++reads) {
          1 => Future.value(
            pageOf([_sent('i_a'), _sent('i_b')], limit: limit, hasMore: true),
          ),
          2 => more.future,
          _ => Future.value(
            pageOf([_sent('i_b'), _sent('i_c')], limit: limit, hasMore: true),
          ),
        })
        ..onWithdraw = (_) => withdraw.future;
      final bloc = build(pageSize: 2)..add(const SentInvitesLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      bloc.add(const SentInvitesMoreRequested());
      await _settle();
      bloc.add(const SentInvitesWithdrawRequested('i_a'));
      await _settle();

      final withdrawn = _sent('i_a', status: HouseholdInviteStatus.withdrawn);
      final page2 = pageOf([_sent('i_d')], page: 2, limit: 2);
      if (withdrawFirst) {
        withdraw.complete(withdrawn);
        await _settle();
        more.complete(page2);
      } else {
        more.complete(page2);
        await _settle();
        withdraw.complete(withdrawn);
      }
      await _settle();

      expect(remote.calls.last, 'fetchSent(null, 1, 2)');
      expect(ready(bloc).invites.map((i) => i.id), ['i_b', 'i_c']);
      expect(ready(bloc).hasMore, isTrue);
    });
  }
}
