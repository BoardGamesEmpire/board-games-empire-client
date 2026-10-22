import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_household_invite_remote.dart';

HouseholdInvite _received(
  String id, {
  HouseholdInviteStatus status = HouseholdInviteStatus.pending,
}) => invite(
  id,
  status: status,
  householdId: 'hh_9',
  householdName: 'Sunday Crew',
);

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeHouseholdInviteRemote remote;
  late List<String> joined;

  setUp(() {
    remote = FakeHouseholdInviteRemote();
    joined = [];
  });

  InviteInboxBloc build({int pageSize = 25}) => InviteInboxBloc(
    remote: remote,
    onJoined: (householdId) async => joined.add(householdId),
    pageSize: pageSize,
  );

  InviteInboxReady ready(InviteInboxBloc bloc) =>
      bloc.state as InviteInboxReady;

  void listing(List<HouseholdInvite> rows) =>
      remote.onFetchInbox = (_, _) async => pageOf(rows);

  blocTest<InviteInboxBloc, InviteInboxState>(
    'loads the invites sent to you, each naming its household',
    setUp: () => listing([_received('i_1')]),
    build: build,
    act: (bloc) => bloc.add(const InviteInboxLoadRequested()),
    expect: () => [
      const InviteInboxLoading(),
      InviteInboxReady(
        invites: [_received('i_1')],
        hasMore: false,
        loadingMore: false,
      ),
    ],
    verify: (_) {
      expect(remote.calls, ['fetchInbox(1, 25)']);
    },
  );

  blocTest<InviteInboxBloc, InviteInboxState>(
    'a failed read can be tried again',
    setUp: () => remote.onFetchInbox = (_, _) async => throw offline(),
    build: build,
    act: (bloc) async {
      bloc.add(const InviteInboxLoadRequested());
      await _settle();
      listing(const []);
      bloc.add(const InviteInboxLoadRequested());
    },
    expect: () => [
      const InviteInboxLoading(),
      const InviteInboxFailed(),
      const InviteInboxLoading(),
      const InviteInboxReady(invites: [], hasMore: false, loadingMore: false),
    ],
  );

  group('accept', () {
    test('joins, removes the row, and refreshes the households', () async {
      listing([_received('i_1'), _received('i_2')]);
      remote.onAccept = (id) async => (
        invite: _received(id, status: HouseholdInviteStatus.accepted),
        householdId: 'hh_9',
      );
      final bloc = build()..add(const InviteInboxLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const InviteInboxAnswerRequested(HouseholdInviteAction.accept, 'i_1'),
      );
      await _settle();

      expect(remote.calls.last, 'accept(i_1)');
      expect(ready(bloc).invites, [_received('i_2')]);
      expect(joined, ['hh_9']);
      expect(
        ready(bloc).outcome,
        const InviteInboxOutcome(
          action: HouseholdInviteAction.accept,
          result: HouseholdInviteActionResult.done,
          householdName: 'Sunday Crew',
          householdId: 'hh_9',
        ),
      );
    });

    test('a double tap accepts once', () async {
      final answer = Completer<AcceptedHouseholdInvite>();
      listing([_received('i_1')]);
      remote.onAccept = (_) => answer.future;
      final bloc = build()..add(const InviteInboxLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      const accept = InviteInboxAnswerRequested(
        HouseholdInviteAction.accept,
        'i_1',
      );
      bloc
        ..add(accept)
        ..add(accept);
      await _settle();

      expect(ready(bloc).busy, {'i_1'});
      expect(remote.calls.where((c) => c.startsWith('accept')), hasLength(1));
      answer.complete((
        invite: _received('i_1', status: HouseholdInviteStatus.accepted),
        householdId: 'hh_9',
      ));
      await _settle();
      expect(joined, ['hh_9']);
    });

    test('a 409 says why and reads the inbox again', () async {
      listing([_received('i_1')]);
      remote.onAccept = (_) async => throw refused(409);
      final bloc = build()..add(const InviteInboxLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const InviteInboxAnswerRequested(HouseholdInviteAction.accept, 'i_1'),
      );
      await _settle();

      expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.refused);
      expect(
        ready(bloc).outcome?.error,
        isA<HouseholdInviteRefusedException>(),
      );
      expect(
        remote.calls.where((c) => c.startsWith('fetchInbox')),
        hasLength(2),
      );
      expect(joined, isEmpty);
    });

    test('a 410 is refused and reads the inbox again', () async {
      listing([_received('i_1')]);
      remote.onAccept = (_) async => throw refused(410);
      final bloc = build()..add(const InviteInboxLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const InviteInboxAnswerRequested(HouseholdInviteAction.accept, 'i_1'),
      );
      await _settle();

      expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.refused);
      expect(
        remote.calls.where((c) => c.startsWith('fetchInbox')),
        hasLength(2),
      );
    });

    test('a failure keeps the row', () async {
      listing([_received('i_1')]);
      remote.onAccept = (_) async => throw offline();
      final bloc = build()..add(const InviteInboxLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const InviteInboxAnswerRequested(HouseholdInviteAction.accept, 'i_1'),
      );
      await _settle();

      expect(ready(bloc).invites, [_received('i_1')]);
      expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.failed);
    });
  });

  test('decline removes the row', () async {
    listing([_received('i_1')]);
    remote.onDecline = (id) async =>
        _received(id, status: HouseholdInviteStatus.declined);
    final bloc = build()..add(const InviteInboxLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    bloc.add(
      const InviteInboxAnswerRequested(HouseholdInviteAction.decline, 'i_1'),
    );
    await _settle();

    expect(remote.calls.last, 'decline(i_1)');
    expect(ready(bloc).invites, isEmpty);
    expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.done);
    expect(ready(bloc).outcome?.householdId, isNull);
    expect(joined, isEmpty);
  });

  test('more appends the next page', () async {
    remote.onFetchInbox = (page, limit) async => page == 1
        ? pageOf(
            [_received('i_1'), _received('i_2')],
            limit: limit,
            hasMore: true,
          )
        : pageOf([_received('i_3')], page: page, limit: limit);
    final bloc = build(pageSize: 2)..add(const InviteInboxLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    bloc.add(const InviteInboxMoreRequested());
    await _settle();

    expect(remote.calls.last, 'fetchInbox(2, 2)');
    expect(ready(bloc).invites.map((i) => i.id), ['i_1', 'i_2', 'i_3']);
    expect(ready(bloc).hasMore, isFalse);
  });

  test('more during a reload waits for it, then reads the next page', () async {
    final firstPage = pageOf(
      [_received('i_1'), _received('i_2')],
      limit: 2,
      hasMore: true,
    );
    var reload = Completer<PaginatedResult<HouseholdInvite>>()
      ..complete(firstPage);
    remote.onFetchInbox = (page, limit) => page == 1
        ? reload.future
        : Future.value(pageOf([_received('i_3')], page: page, limit: limit));
    final bloc = build(pageSize: 2)..add(const InviteInboxLoadRequested());
    addTearDown(bloc.close);
    await _settle();

    reload = Completer();
    bloc
      ..add(const InviteInboxLoadRequested())
      ..add(const InviteInboxMoreRequested());
    await _settle();
    expect(ready(bloc).loadingMore, isTrue);

    reload.complete(firstPage);
    await _settle();
    expect(remote.calls.last, 'fetchInbox(2, 2)');
    expect(ready(bloc).invites.map((i) => i.id), ['i_1', 'i_2', 'i_3']);
  });

  test('a page that answers after an answer settled one of its rows does not '
      'bring the row back', () async {
    final more = Completer<PaginatedResult<HouseholdInvite>>();
    var reads = 0;
    remote
      ..onFetchInbox = ((page, limit) => ++reads == 1
          ? Future.value(
              pageOf(
                [_received('i_a'), _received('i_b')],
                limit: limit,
                hasMore: true,
              ),
            )
          : more.future)
      ..onDecline = (id) async =>
          _received(id, status: HouseholdInviteStatus.declined);
    final bloc = build(pageSize: 2)..add(const InviteInboxLoadRequested());
    addTearDown(bloc.close);
    await _settle();
    bloc.add(
      const InviteInboxAnswerRequested(HouseholdInviteAction.decline, 'i_a'),
    );
    await _settle();
    bloc.add(const InviteInboxMoreRequested());
    await _settle();
    expect(remote.calls.last, 'fetchInbox(1, 2)');

    bloc.add(
      const InviteInboxAnswerRequested(HouseholdInviteAction.decline, 'i_b'),
    );
    await _settle();
    // Read before i_b was declined, so it still lists i_b as pending.
    more.complete(pageOf([_received('i_b'), _received('i_c')], limit: 2));
    await _settle();

    expect(ready(bloc).invites.map((i) => i.id), ['i_c']);
  });
}
