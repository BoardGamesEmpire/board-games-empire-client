import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_household_invite_remote.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

const _hh = 'hh_1';
const _me = 'u_me';

HouseholdMember _member(HouseholdRole role) => HouseholdMember(
  id: 'm_me',
  userId: _me,
  householdId: _hh,
  role: role,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// Lets every pending microtask and zero-delay timer run.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeHouseholdInviteRemote remote;
  late _MockHouseholdRepository repository;
  late StreamController<List<HouseholdMember>> roster;

  setUp(() {
    remote = FakeHouseholdInviteRemote();
    repository = _MockHouseholdRepository();
    roster = StreamController.broadcast();
    addTearDown(roster.close);
    when(() => repository.getCurrentUserMember(_hh))
        .thenAnswer((_) async => _member(HouseholdRole.householdOwner));
    when(() => repository.watchMembers(_hh)).thenAnswer((_) => roster.stream);
  });

  HouseholdInviteListBloc build({int pageSize = 25}) => HouseholdInviteListBloc(
    householdId: _hh,
    remote: remote,
    repository: repository,
    pageSize: pageSize,
  );

  HouseholdInviteListReady ready(HouseholdInviteListBloc bloc) =>
      bloc.state as HouseholdInviteListReady;

  group('reading', () {
    blocTest<HouseholdInviteListBloc, HouseholdInviteListState>(
      'loads the open invites with who is looking',
      setUp: () => remote.listing([invite('i_1')]),
      build: build,
      act: (bloc) => bloc.add(const HouseholdInviteListLoadRequested()),
      expect: () => [
        const HouseholdInviteListLoading(),
        HouseholdInviteListReady(
          invites: [invite('i_1')],
          filter: HouseholdInviteFilter.open,
          hasMore: false,
          loadingMore: false,
          viewerUserId: _me,
          viewerRole: HouseholdRole.householdOwner,
        ),
      ],
      verify: (_) =>
          expect(remote.calls, ['fetchHouseholdInvites(hh_1, null, 1, 25)']),
    );

    blocTest<HouseholdInviteListBloc, HouseholdInviteListState>(
      'the awaiting-approval filter asks for that status',
      setUp: () => remote.listing([
        invite('i_2', status: HouseholdInviteStatus.awaitingApproval),
      ]),
      build: build,
      act: (bloc) => bloc.add(
        const HouseholdInviteListFilterChanged(
          HouseholdInviteFilter.awaitingApproval,
        ),
      ),
      expect: () => [
        const HouseholdInviteListLoading(
          filter: HouseholdInviteFilter.awaitingApproval,
        ),
        isA<HouseholdInviteListReady>().having(
          (s) => s.filter,
          'filter',
          HouseholdInviteFilter.awaitingApproval,
        ),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchHouseholdInvites(hh_1, awaitingApproval, 1, 25)',
      ]),
    );

    blocTest<HouseholdInviteListBloc, HouseholdInviteListState>(
      'a filter changed before the first read answers is shown at once',
      // The open read never answers, so the filter changes before it does.
      setUp: () => remote.onFetchHouseholdInvites = (_, status, _, _) =>
          status == null
          ? Completer<PaginatedResult<HouseholdInvite>>().future
          : Future.value(
              pageOf([
                invite('i_2', status: HouseholdInviteStatus.awaitingApproval),
              ]),
            ),
      build: build,
      act: (bloc) => bloc
        ..add(const HouseholdInviteListLoadRequested())
        ..add(
          const HouseholdInviteListFilterChanged(
            HouseholdInviteFilter.awaitingApproval,
          ),
        ),
      expect: () => [
        const HouseholdInviteListLoading(),
        const HouseholdInviteListLoading(
          filter: HouseholdInviteFilter.awaitingApproval,
        ),
        isA<HouseholdInviteListReady>().having(
          (s) => s.filter,
          'filter',
          HouseholdInviteFilter.awaitingApproval,
        ),
      ],
    );

    blocTest<HouseholdInviteListBloc, HouseholdInviteListState>(
      'a refused read is denied',
      setUp: () =>
          remote.onFetchHouseholdInvites = (_, _, _, _) async =>
              throw refused(403),
      build: build,
      act: (bloc) => bloc.add(const HouseholdInviteListLoadRequested()),
      expect: () => [
        const HouseholdInviteListLoading(),
        const HouseholdInviteListDenied(),
      ],
    );

    test('a failed read can be tried again', () async {
      remote.onFetchHouseholdInvites = (_, _, _, _) async => throw offline();
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      expect(bloc.state, const HouseholdInviteListFailed());

      remote.listing([invite('i_1')]);
      bloc.add(const HouseholdInviteListLoadRequested());
      await _settle();

      expect(ready(bloc).invites, [invite('i_1')]);
    });

    test('a viewer the cache cannot place is offered no action', () async {
      when(() => repository.getCurrentUserMember(_hh))
          .thenAnswer((_) async => null);
      remote.listing([invite('i_1', inviterId: _me)]);
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      expect(ready(bloc).viewerUserId, isNull);
      expect(ready(bloc).viewerRole, isNull);

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.withdraw,
          'i_1',
        ),
      );
      await _settle();

      expect(remote.calls, hasLength(1));
    });

    test('of two overlapping loads, the later wins even when it answers '
        'first', () async {
      final first = Completer<PaginatedResult<HouseholdInvite>>();
      final second = Completer<PaginatedResult<HouseholdInvite>>();
      final answers = [first, second];
      remote.onFetchHouseholdInvites = (_, _, _, _) =>
          answers.removeAt(0).future;
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      bloc.add(const HouseholdInviteListLoadRequested());
      await _settle();

      second.complete(pageOf([invite('new')]));
      await _settle();
      first.complete(pageOf([invite('old')]));
      await _settle();

      expect(ready(bloc).invites, [invite('new')]);
    });

    test("the old filter's read, answering after the filter changed, is "
        'never shown', () async {
      final open = Completer<PaginatedResult<HouseholdInvite>>();
      final awaiting = Completer<PaginatedResult<HouseholdInvite>>();
      remote.onFetchHouseholdInvites = (_, status, _, _) =>
          status == null ? open.future : awaiting.future;
      // The second load's viewer is slow, which holds that load's own read
      // back if the read waits for it.
      final laterViewer = Completer<HouseholdMember?>();
      var viewerReads = 0;
      when(() => repository.getCurrentUserMember(_hh)).thenAnswer(
        (_) => ++viewerReads == 1
            ? Future.value(_member(HouseholdRole.householdOwner))
            : laterViewer.future,
      );
      final bloc = build();
      addTearDown(bloc.close);
      final shown = <List<HouseholdInvite>>[];
      final states = bloc.stream.listen((state) {
        if (state is HouseholdInviteListReady) shown.add(state.invites);
      });
      addTearDown(states.cancel);
      bloc.add(const HouseholdInviteListLoadRequested());
      await _settle();
      bloc.add(
        const HouseholdInviteListFilterChanged(
          HouseholdInviteFilter.awaitingApproval,
        ),
      );
      await _settle();

      open.complete(pageOf([invite('i_open')]));
      await _settle();
      laterViewer.complete(_member(HouseholdRole.householdOwner));
      awaiting.complete(
        pageOf([
          invite('i_waiting', status: HouseholdInviteStatus.awaitingApproval),
        ]),
      );
      await _settle();

      expect(shown, [
        [invite('i_waiting', status: HouseholdInviteStatus.awaitingApproval)],
      ]);
    });

    test("of two overlapping loads, the later one's viewer stands even when "
        "the older one's answers last", () async {
      final olderViewer = Completer<HouseholdMember?>();
      var viewerReads = 0;
      when(() => repository.getCurrentUserMember(_hh)).thenAnswer(
        (_) => ++viewerReads == 1
            ? olderViewer.future
            : Future.value(_member(HouseholdRole.householdOwner)),
      );
      remote.listing([invite('i_1')]);
      final bloc = build()
        ..add(const HouseholdInviteListLoadRequested())
        ..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      olderViewer.complete(_member(HouseholdRole.householdAdmin));
      await _settle();

      expect(ready(bloc).viewerRole, HouseholdRole.householdOwner);
    });

    test('a viewer the cache could not place gets their controls when the '
        'hydrate brings their row', () async {
      HouseholdMember? cached;
      when(() => repository.getCurrentUserMember(_hh))
          .thenAnswer((_) async => cached);
      remote.listing([invite('i_1')]);
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      expect(ready(bloc).viewerRole, isNull);

      final me = _member(HouseholdRole.householdOwner);
      cached = me;
      roster.add([me]);
      await _settle();

      expect(ready(bloc).viewerUserId, _me);
      expect(ready(bloc).viewerRole, HouseholdRole.householdOwner);
      // Placed, so the roster is no longer watched, and the list was not
      // read again for it.
      expect(roster.hasListener, isFalse);
      expect(remote.calls, hasLength(1));
    });
  });

  group('actions', () {
    test('withdrawing your own invite removes it', () async {
      remote
        ..listing([invite('i_1', inviterId: _me), invite('i_2')])
        ..onWithdraw = (id) async =>
            invite(id, inviterId: _me, status: HouseholdInviteStatus.withdrawn);
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.withdraw,
          'i_1',
        ),
      );
      await _settle();

      expect(remote.calls.last, 'withdraw(i_1)');
      expect(ready(bloc).invites, [invite('i_2')]);
      expect(ready(bloc).busy, isEmpty);
      expect(
        ready(bloc).outcome,
        const HouseholdInviteListOutcome(
          action: HouseholdInviteRowAction.withdraw,
          result: HouseholdInviteActionResult.done,
        ),
      );
    });

    test('a row is busy while its action runs', () async {
      final answer = Completer<HouseholdInvite>();
      remote
        ..listing([invite('i_1')])
        ..onRevoke = (_, _) => answer.future;
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      const revoke = HouseholdInviteListActionRequested(
        HouseholdInviteRowAction.revoke,
        'i_1',
      );
      bloc
        ..add(revoke)
        ..add(revoke);
      await _settle();

      expect(ready(bloc).busy, {'i_1'});
      expect(remote.calls.where((c) => c.startsWith('revoke')), hasLength(1));
      answer.complete(invite('i_1', status: HouseholdInviteStatus.revoked));
      await _settle();
      expect(ready(bloc).busy, isEmpty);
    });

    test('an approved invite leaves the awaiting-approval list', () async {
      remote
        ..listing([
          invite('i_1', status: HouseholdInviteStatus.awaitingApproval),
        ])
        ..onApprove = (_, id) async => invite(id);
      final bloc = build()
        ..add(
          const HouseholdInviteListFilterChanged(
            HouseholdInviteFilter.awaitingApproval,
          ),
        );
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.approve,
          'i_1',
        ),
      );
      await _settle();

      expect(remote.calls.last, 'approve(hh_1, i_1)');
      expect(ready(bloc).invites, isEmpty);
    });

    test('an approved invite stays on the open list, now pending', () async {
      remote
        ..listing([
          invite('i_1', status: HouseholdInviteStatus.awaitingApproval),
        ])
        ..onApprove = (_, id) async => invite(id);
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.approve,
          'i_1',
        ),
      );
      await _settle();

      expect(ready(bloc).invites, [invite('i_1')]);
    });

    test('a revoke refused as already settled reloads the list', () async {
      remote
        ..listing([invite('i_1')])
        ..onRevoke = (_, _) async => throw refused(409);
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.revoke,
          'i_1',
        ),
      );
      await _settle();

      expect(
        ready(bloc).outcome,
        isA<HouseholdInviteListOutcome>()
            .having(
              (o) => o.result,
              'result',
              HouseholdInviteActionResult.refused,
            )
            .having(
              (o) => o.error,
              'error',
              isA<HouseholdInviteRefusedException>(),
            ),
      );
      expect(
        remote.calls.where((c) => c.startsWith('fetchHouseholdInvites')),
        hasLength(2),
      );
    });

    test('a failed action keeps the row and says so', () async {
      remote
        ..listing([invite('i_1')])
        ..onRevoke = (_, _) async => throw offline();
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.revoke,
          'i_1',
        ),
      );
      await _settle();

      expect(ready(bloc).invites, [invite('i_1')]);
      expect(ready(bloc).outcome?.result, HouseholdInviteActionResult.failed);
      expect(
        remote.calls.where((c) => c.startsWith('fetchHouseholdInvites')),
        hasLength(1),
      );
    });

    test('an action the viewer may not take sends nothing', () async {
      when(() => repository.getCurrentUserMember(_hh))
          .thenAnswer((_) async => _member(HouseholdRole.householdAdmin));
      remote.listing([invite('i_1', role: HouseholdRole.householdAdmin)]);
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.revoke,
          'i_1',
        ),
      );
      await _settle();

      expect(remote.calls, ['fetchHouseholdInvites(hh_1, null, 1, 25)']);
    });

    test('a revoke that answers after a reload settles against the reloaded '
        'rows', () async {
      final answer = Completer<HouseholdInvite>();
      remote
        ..listing([invite('i_1')])
        ..onRevoke = (_, _) => answer.future;
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.revoke,
          'i_1',
        ),
      );
      await _settle();
      remote.listing([invite('i_1'), invite('i_3')]);
      bloc.add(const HouseholdInviteListLoadRequested());
      await _settle();
      expect(ready(bloc).invites, [invite('i_1'), invite('i_3')]);

      answer.complete(invite('i_1', status: HouseholdInviteStatus.revoked));
      await _settle();

      expect(ready(bloc).invites, [invite('i_3')]);
    });

    test('an outcome is dismissed', () async {
      remote
        ..listing([invite('i_1')])
        ..onRevoke = (_, id) async =>
            invite(id, status: HouseholdInviteStatus.revoked);
      final bloc = build()..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.revoke,
          'i_1',
        ),
      );
      await _settle();
      expect(ready(bloc).outcome, isNotNull);

      bloc.add(const HouseholdInviteListOutcomeDismissed());
      await _settle();

      expect(ready(bloc).outcome, isNull);
    });
  });

  group('more', () {
    test('appends the next page', () async {
      remote.onFetchHouseholdInvites = (_, _, page, limit) async => page == 1
          ? pageOf([invite('i_1'), invite('i_2')], limit: limit, hasMore: true)
          : pageOf([invite('i_3')], page: 2, limit: limit);
      final bloc = build(pageSize: 2)
        ..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      expect(ready(bloc).hasMore, isTrue);

      bloc.add(const HouseholdInviteListMoreRequested());
      await _settle();

      expect(remote.calls.last, 'fetchHouseholdInvites(hh_1, null, 2, 2)');
      expect(ready(bloc).invites, [
        invite('i_1'),
        invite('i_2'),
        invite('i_3'),
      ]);
      expect(ready(bloc).hasMore, isFalse);
      expect(ready(bloc).loadingMore, isFalse);
    });

    test('a second request while one is in flight sends nothing', () async {
      final more = Completer<PaginatedResult<HouseholdInvite>>();
      remote.onFetchHouseholdInvites = (_, _, page, limit) => page == 1
          ? Future.value(
              pageOf(
                [invite('i_1'), invite('i_2')],
                limit: limit,
                hasMore: true,
              ),
            )
          : more.future;
      final bloc = build(pageSize: 2)
        ..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      bloc
        ..add(const HouseholdInviteListMoreRequested())
        ..add(const HouseholdInviteListMoreRequested());
      await _settle();

      expect(ready(bloc).loadingMore, isTrue);
      expect(remote.calls, hasLength(2));
      more.complete(pageOf([invite('i_3')], page: 2, limit: 2));
      await _settle();
      expect(ready(bloc).invites, hasLength(3));
    });

    test('a request during a reload waits for it, then asks for the page '
        'after it', () async {
      final firstPage = pageOf(
        [invite('i_1'), invite('i_2')],
        limit: 2,
        hasMore: true,
      );
      var reload = Completer<PaginatedResult<HouseholdInvite>>()
        ..complete(firstPage);
      remote.onFetchHouseholdInvites = (_, _, page, limit) => page == 1
          ? reload.future
          : Future.value(pageOf([invite('i_3')], page: page, limit: limit));
      final bloc = build(pageSize: 2)
        ..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();

      reload = Completer();
      bloc
        ..add(const HouseholdInviteListLoadRequested())
        ..add(const HouseholdInviteListMoreRequested());
      await _settle();
      expect(ready(bloc).loadingMore, isTrue);
      expect(remote.calls, hasLength(2));

      reload.complete(firstPage);
      await _settle();
      expect(remote.calls.last, 'fetchHouseholdInvites(hh_1, null, 2, 2)');
      expect(ready(bloc).invites, [
        invite('i_1'),
        invite('i_2'),
        invite('i_3'),
      ]);
      expect(ready(bloc).loadingMore, isFalse);
    });

    test('after a row leaves, asks again for the page holding the first row '
        'not shown, and skips what is already shown', () async {
      // Two rows on page 1; withdrawing one shifts the server's rows up, so
      // page 2 would now start one row later and skip a row. Asking for the
      // page that holds row 2 again, and dropping the duplicate, does not.
      remote
        ..onFetchHouseholdInvites = ((_, _, page, limit) async => pageOf(
          [invite('i_1', inviterId: _me), invite('i_2')],
          limit: limit,
          hasMore: true,
        ))
        ..onWithdraw = (id) async =>
            invite(id, inviterId: _me, status: HouseholdInviteStatus.withdrawn);
      final bloc = build(pageSize: 2)
        ..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.withdraw,
          'i_1',
        ),
      );
      await _settle();
      expect(ready(bloc).invites, [invite('i_2')]);

      remote.onFetchHouseholdInvites = (_, _, page, limit) async => page == 1
          ? pageOf([invite('i_2'), invite('i_3')], limit: limit, hasMore: true)
          : pageOf([invite('i_4')], page: page, limit: limit);
      bloc.add(const HouseholdInviteListMoreRequested());
      await _settle();

      expect(remote.calls.last, 'fetchHouseholdInvites(hh_1, null, 1, 2)');
      expect(ready(bloc).invites, [invite('i_2'), invite('i_3')]);
      expect(ready(bloc).hasMore, isTrue);
    });

    test('a page that answers after an action settled one of its rows does '
        'not bring the row back', () async {
      final more = Completer<PaginatedResult<HouseholdInvite>>();
      var reads = 0;
      remote
        ..onFetchHouseholdInvites = ((_, _, page, limit) => switch (++reads) {
          1 => Future.value(
            pageOf(
              [invite('i_a', inviterId: _me), invite('i_b', inviterId: _me)],
              limit: limit,
              hasMore: true,
            ),
          ),
          2 => more.future,
          // The reload the second withdraw asks for, once both are gone.
          _ => Future.value(pageOf([invite('i_c')], limit: limit)),
        })
        ..onWithdraw = (id) async =>
            invite(id, inviterId: _me, status: HouseholdInviteStatus.withdrawn);
      final bloc = build(pageSize: 2)
        ..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.withdraw,
          'i_a',
        ),
      );
      await _settle();
      bloc.add(const HouseholdInviteListMoreRequested());
      await _settle();
      expect(remote.calls.last, 'fetchHouseholdInvites(hh_1, null, 1, 2)');

      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.withdraw,
          'i_b',
        ),
      );
      await _settle();
      // Read before i_b was withdrawn, so it still lists i_b as open.
      more.complete(
        pageOf([invite('i_b', inviterId: _me), invite('i_c')], limit: 2),
      );
      await _settle();

      expect(ready(bloc).invites, [invite('i_c')]);
    });

    for (final withdrawFirst in [true, false]) {
      test('a row dropped while More is out reads the list again, so the '
          'page cannot skip a row (the withdraw answers '
          '${withdrawFirst ? 'first' : 'last'})', () async {
        // The server holds a, b, c, d. Withdrawing a before the server reads
        // page 2 moves c onto page 1, so page 2 is d alone.
        final more = Completer<PaginatedResult<HouseholdInvite>>();
        final withdraw = Completer<HouseholdInvite>();
        var reads = 0;
        remote
          ..onFetchHouseholdInvites = ((_, _, page, limit) => switch (++reads) {
            1 => Future.value(
              pageOf(
                [invite('i_a', inviterId: _me), invite('i_b')],
                limit: limit,
                hasMore: true,
              ),
            ),
            2 => more.future,
            _ => Future.value(
              pageOf(
                [invite('i_b'), invite('i_c')],
                limit: limit,
                hasMore: true,
              ),
            ),
          })
          ..onWithdraw = (_) => withdraw.future;
        final bloc = build(pageSize: 2)
          ..add(const HouseholdInviteListLoadRequested());
        addTearDown(bloc.close);
        await _settle();
        bloc.add(const HouseholdInviteListMoreRequested());
        await _settle();
        bloc.add(
          const HouseholdInviteListActionRequested(
            HouseholdInviteRowAction.withdraw,
            'i_a',
          ),
        );
        await _settle();

        final withdrawn = invite(
          'i_a',
          inviterId: _me,
          status: HouseholdInviteStatus.withdrawn,
        );
        final page2 = pageOf([invite('i_d')], page: 2, limit: 2);
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

        expect(remote.calls.last, 'fetchHouseholdInvites(hh_1, null, 1, 2)');
        expect(ready(bloc).invites, [invite('i_b'), invite('i_c')]);
        expect(ready(bloc).hasMore, isTrue);
      });
    }

    test('an action that keeps its row while More is out does not read the '
        'list again', () async {
      final more = Completer<PaginatedResult<HouseholdInvite>>();
      var reads = 0;
      remote
        ..onFetchHouseholdInvites = ((_, _, page, limit) => ++reads == 1
            ? Future.value(
                pageOf(
                  [
                    invite(
                      'i_a',
                      status: HouseholdInviteStatus.awaitingApproval,
                    ),
                    invite('i_b'),
                  ],
                  limit: limit,
                  hasMore: true,
                ),
              )
            : more.future)
        ..onApprove = (_, id) async => invite(id);
      final bloc = build(pageSize: 2)
        ..add(const HouseholdInviteListLoadRequested());
      addTearDown(bloc.close);
      await _settle();
      bloc.add(const HouseholdInviteListMoreRequested());
      await _settle();
      bloc.add(
        const HouseholdInviteListActionRequested(
          HouseholdInviteRowAction.approve,
          'i_a',
        ),
      );
      await _settle();
      more.complete(pageOf([invite('i_c')], page: 2, limit: 2));
      await _settle();

      expect(remote.calls.where((c) => c.startsWith('fetch')), hasLength(2));
      expect(ready(bloc).invites, [
        invite('i_a'),
        invite('i_b'),
        invite('i_c'),
      ]);
    });
  });
}
