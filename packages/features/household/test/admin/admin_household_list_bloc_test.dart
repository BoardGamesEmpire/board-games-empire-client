import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_admin_household_remote.dart';

const _live = AdminHouseholdQuery();
const _deleted = AdminHouseholdQuery(status: AdminHouseholdStatus.deleted);
const _all = AdminHouseholdQuery(status: AdminHouseholdStatus.all);

const _forbidden = AdminHouseholdForbiddenException('no', statusCode: 403);
const _transient = AdminHouseholdTransientException('unreachable');
const _notFound = AdminHouseholdNotFoundException(
  'nothing to restore',
  statusCode: 404,
);
const _notDeleted = AdminHouseholdNotDeletedException(
  'already live',
  statusCode: 409,
);

typedef _Page = PaginatedResult<AdminHouseholdRow>;

String _fetch({
  AdminHouseholdStatus status = AdminHouseholdStatus.live,
  String? q,
  AdminHouseholdSort sort = AdminHouseholdSort.name,
  int page = 1,
  int limit = AdminHouseholdRemoteDataSource.pageSize,
}) => describeFetchPage(
  status: status,
  query: q,
  sort: sort,
  page: page,
  limit: limit,
);

/// Rows h[from] to h[to], deleted unless said otherwise.
List<AdminHouseholdRow> _rows(int from, int to, {bool deleted = true}) => [
  for (var i = from; i <= to; i++) adminRow('h$i', deleted: deleted),
];

AdminHouseholdRestoreOutcome _outcome(
  AdminHouseholdRestoreResult result,
  String name,
) => AdminHouseholdRestoreOutcome(result: result, name: name);

void main() {
  late FakeAdminHouseholdRemote remote;
  late FakeCallerAccessRepository access;

  // Answers a test's setUp scripts as pending, for its act to give.
  late Completer<_Page> more;
  late Completer<_Page> reload;
  late Completer<void> restore;

  final ada = adminRow('h_ada', name: "Ada's table");
  final bea = adminRow('h_bea', name: 'Bea games');
  final gone = adminRow('h_gone', name: 'Old crew', deleted: true);
  final lost = adminRow('h_lost', name: 'Lost club', deleted: true);

  /// A full first page, with more behind it, and the row after it.
  final firstPage = _rows(1, 25, deleted: false);
  final next = adminRow('h26');

  setUp(() {
    remote = FakeAdminHouseholdRemote();
    access = FakeCallerAccessRepository(
      FakeCallerAccessRepository.of({ResourceType.household: AccessExtent.all}),
    );
  });

  /// No pause before a search, unless a test times it.
  AdminHouseholdListBloc build() => AdminHouseholdListBloc(
    remote: remote,
    access: access,
    searchDelay: Duration.zero,
  );

  AdminHouseholdListReady ready(
    List<AdminHouseholdRow> rows, {
    AdminHouseholdQuery query = _live,
    bool hasMore = false,
    bool loadingMore = false,
    bool loadMoreFailed = false,
    Set<String> restoring = const {},
    AdminHouseholdRestoreOutcome? outcome,
  }) => AdminHouseholdListReady(
    query: query,
    rows: rows,
    hasMore: hasMore,
    loadingMore: loadingMore,
    loadMoreFailed: loadMoreFailed,
    restoring: restoring,
    outcome: outcome,
  );

  /// Answers each first-page read with the next of [pages], and the last one
  /// from then on. Any later page is [later].
  void firstPages(List<_Page> pages, {_Page Function(int page)? later}) {
    var reads = 0;
    remote.onFetchPage = (request) async {
      if (request.page > 1) return later!(request.page);
      final page = pages[reads < pages.length ? reads : pages.length - 1];
      reads++;
      return page;
    };
  }

  /// Answers every list read from [rows], as the server pages them: each
  /// request's page of its own limit. A restore takes its row out, as under
  /// Deleted.
  void serve(List<AdminHouseholdRow> rows) {
    remote
      ..onFetchPage = (request) async {
        final start = (request.page - 1) * request.limit;
        final end = start + request.limit;
        return adminPageOf(
          rows.sublist(start.clamp(0, rows.length), end.clamp(0, rows.length)),
          page: request.page,
          hasMore: end < rows.length,
        );
      }
      ..onRestore = (id) async => rows.removeWhere((row) => row.id == id);
  }

  group('AdminHouseholdQuery', () {
    test('defaults to live households by name, unsearched', () {
      expect(_live.status, AdminHouseholdStatus.live);
      expect(_live.sort, AdminHouseholdSort.name);
      expect(_live.text, '');
      expect(_live.sentQuery, isNull);
    });

    test('sends the trimmed text the server takes, else nothing', () {
      expect(const AdminHouseholdQuery(text: '  ab ').sentQuery, 'ab');
      expect(const AdminHouseholdQuery(text: ' a ').sentQuery, isNull);
      expect(const AdminHouseholdQuery(text: '   ').sentQuery, isNull);
      // One emoji is two UTF-16 code units, and one character to the server.
      expect(const AdminHouseholdQuery(text: '\u{1F600}').sentQuery, isNull);
      expect(
        const AdminHouseholdQuery(text: '\u{1F600}\u{1F600}').sentQuery,
        '\u{1F600}\u{1F600}',
      );
      expect(AdminHouseholdQuery(text: 'a' * 100).sentQuery, 'a' * 100);
      expect(AdminHouseholdQuery(text: 'a' * 101).sentQuery, isNull);
    });

    test('never sends U+0000, which the server refuses', () {
      expect(const AdminHouseholdQuery(text: 'ab\u0000').sentQuery, 'ab');
      expect(const AdminHouseholdQuery(text: 'a\u0000b').sentQuery, 'ab');
      expect(const AdminHouseholdQuery(text: 'a\u0000 ').sentQuery, isNull);
    });
  });

  group('reading', () {
    late Completer<_Page> deletedRead;
    late Completer<_Page> allRead;

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'loads the first page with the defaults',
      setUp: () => remote.listing([ada, bea]),
      build: build,
      act: (bloc) => bloc.add(const AdminHouseholdListLoadRequested()),
      expect: () => [
        const AdminHouseholdListLoading(),
        ready([ada, bea]),
      ],
      verify: (_) => expect(remote.calls, [_fetch()]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a failed read is Failed, and LoadRequested from Failed reads again',
      setUp: () {
        var reads = 0;
        remote.onFetchPage = (_) async {
          if (reads++ == 0) throw _transient;
          return adminPageOf([ada]);
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListLoadRequested());
      },
      expect: () => [
        const AdminHouseholdListLoading(),
        const AdminHouseholdListFailed(),
        const AdminHouseholdListLoading(),
        ready([ada]),
      ],
      verify: (_) {
        expect(remote.calls, [_fetch(), _fetch()]);
        expect(access.refreshCount, 0);
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a refused read is Refused and asks access again',
      setUp: () => remote.onFetchPage = (_) async => throw _forbidden,
      build: build,
      act: (bloc) => bloc.add(const AdminHouseholdListLoadRequested()),
      expect: () => [
        const AdminHouseholdListLoading(),
        const AdminHouseholdListRefused(),
      ],
      verify: (_) => expect(access.refreshCount, 1),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'the latest query wins: an earlier read that answers last is dropped',
      setUp: () {
        deletedRead = Completer<_Page>();
        allRead = Completer<_Page>();
        remote.onFetchPage = (request) =>
            request.status == AdminHouseholdStatus.deleted
            ? deletedRead.future
            : allRead.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        allRead.complete(adminPageOf([ada, gone]));
        await pumpEventQueue();
        deletedRead.complete(adminPageOf([lost]));
        await pumpEventQueue();
      },
      expect: () => [
        const AdminHouseholdListLoading(query: _deleted),
        const AdminHouseholdListLoading(query: _all),
        ready([ada, gone], query: _all),
      ],
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a reload keeps the rows shown until it answers',
      setUp: () => firstPages([
        adminPageOf([ada]),
        adminPageOf([ada, bea]),
      ]),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListLoadRequested());
      },
      expect: () => [
        const AdminHouseholdListLoading(),
        ready([ada]),
        ready([ada, bea]),
      ],
    );
  });

  group('load more', () {
    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'appends the next page',
      setUp: () => firstPages([
        adminPageOf(firstPage, hasMore: true),
      ], later: (page) => adminPageOf([next], page: page)),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
      },
      skip: 2,
      expect: () => [
        ready(firstPage, hasMore: true, loadingMore: true),
        ready([...firstPage, next]),
      ],
      verify: (_) => expect(remote.calls, [_fetch(), _fetch(page: 2)]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a failed load more keeps the rows and sets loadMoreFailed, and '
      'another asks for the same page',
      setUp: () {
        var pageTwoReads = 0;
        firstPages(
          [adminPageOf(firstPage, hasMore: true)],
          later: (page) {
            if (pageTwoReads++ == 0) throw _transient;
            return adminPageOf([next], page: page);
          },
        );
      },
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
      },
      skip: 2,
      expect: () => [
        ready(firstPage, hasMore: true, loadingMore: true),
        ready(firstPage, hasMore: true, loadMoreFailed: true),
        ready(firstPage, hasMore: true, loadingMore: true),
        ready([...firstPage, next]),
      ],
      verify: (_) {
        expect(remote.calls, [_fetch(), _fetch(page: 2), _fetch(page: 2)]);
        expect(access.refreshCount, 0);
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a refused load more is Refused and asks access again',
      setUp: () => firstPages([
        adminPageOf(firstPage, hasMore: true),
      ], later: (_) => throw _forbidden),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
      },
      skip: 2,
      expect: () => [
        ready(firstPage, hasMore: true, loadingMore: true),
        const AdminHouseholdListRefused(),
      ],
      verify: (_) => expect(access.refreshCount, 1),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'asks nothing when the server has no more',
      setUp: () => remote.listing([ada]),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
      },
      skip: 2,
      expect: () => <AdminHouseholdListState>[],
      verify: (_) => expect(remote.calls, [_fetch()]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'an answer from an older query is dropped',
      setUp: () {
        more = Completer<_Page>();
        remote.onFetchPage = (request) async {
          if (request.page == 2) return more.future;
          return request.status == AdminHouseholdStatus.deleted
              ? adminPageOf([gone])
              : adminPageOf(firstPage, hasMore: true);
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        more.complete(adminPageOf([next], page: 2));
        await pumpEventQueue();
      },
      skip: 3,
      expect: () => [
        const AdminHouseholdListLoading(query: _deleted),
        ready([gone], query: _deleted),
      ],
      verify: (_) => expect(remote.calls, [
        _fetch(),
        _fetch(page: 2),
        _fetch(status: AdminHouseholdStatus.deleted),
      ]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'one asked for during a reload waits for it, then reads the page after '
      'the reloaded one',
      setUp: () {
        reload = Completer<_Page>();
        var firstReads = 0;
        remote.onFetchPage = (request) async {
          if (request.page == 2) return adminPageOf([next], page: 2);
          return firstReads++ == 0
              ? adminPageOf(firstPage, hasMore: true)
              : reload.future;
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        expect(remote.calls, [_fetch(), _fetch()]);
        expect(bloc.state, ready(firstPage, hasMore: true, loadingMore: true));
        reload.complete(adminPageOf(firstPage, hasMore: true));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [_fetch(), _fetch(), _fetch(page: 2)]);
        expect(bloc.state, ready([...firstPage, next]));
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'one asked for during a reload that fails is dropped with it',
      setUp: () {
        reload = Completer<_Page>();
        var firstReads = 0;
        remote.onFetchPage = (request) async {
          if (request.page == 2) return adminPageOf([next], page: 2);
          return firstReads++ == 0
              ? adminPageOf(firstPage, hasMore: true)
              : reload.future;
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        reload.completeError(_transient);
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [_fetch(), _fetch()]);
        expect(bloc.state, const AdminHouseholdListFailed());
      },
    );
  });

  group('reading the list shown again', () {
    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'reads as many pages as were read, in one request, and load more '
      'goes on after them',
      setUp: () => serve(_rows(1, 80, deleted: false)),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        // As when the list comes back into view from a household's detail.
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        expect(
          (bloc.state as AdminHouseholdListReady).rows,
          _rows(1, 50, deleted: false),
        );
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(),
          _fetch(page: 2),
          _fetch(limit: 50),
          _fetch(page: 3),
        ]);
        expect(
          (bloc.state as AdminHouseholdListReady).rows,
          _rows(1, 75, deleted: false),
        );
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      "past the server's largest page, reads in pages of that size",
      setUp: () => serve(_rows(1, 260, deleted: false)),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        for (var i = 0; i < 4; i++) {
          bloc.add(const AdminHouseholdListMoreRequested());
          await pumpEventQueue();
        }
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        // 125 rows were shown; two pages of 100 read 200.
        expect(
          (bloc.state as AdminHouseholdListReady).rows,
          _rows(1, 200, deleted: false),
        );
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls.skip(5), [
          _fetch(limit: 100),
          _fetch(page: 2, limit: 100),
          _fetch(page: 9),
        ]);
        expect(
          (bloc.state as AdminHouseholdListReady).rows,
          _rows(1, 225, deleted: false),
        );
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'after a restore took a row out, reads the whole pages it was among',
      setUp: () => serve(_rows(1, 60)),
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h1'));
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          _fetch(status: AdminHouseholdStatus.deleted, page: 2),
          'restore(h1)',
          _fetch(status: AdminHouseholdStatus.deleted, limit: 50),
        ]);
        expect((bloc.state as AdminHouseholdListReady).rows, _rows(2, 51));
      },
    );
  });

  group('search, filter and sort', () {
    test('a search waits for typing to pause', () {
      fakeAsync((async) {
        remote.listing([ada]);
        final bloc = AdminHouseholdListBloc(remote: remote, access: access);
        bloc.add(const AdminHouseholdListSearchChanged('a'));
        async.elapse(const Duration(milliseconds: 100));
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(const Duration(milliseconds: 299));
        expect(remote.calls, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(remote.calls, [_fetch(q: 'ab')]);
        expect(
          bloc.state,
          ready([ada], query: const AdminHouseholdQuery(text: 'ab')),
        );

        unawaited(bloc.close());
        async.flushMicrotasks();
      });
    });

    for (final (label, text) in [
      ('spaces round one letter', ' a '),
      ('one emoji', '\u{1F600}'),
    ]) {
      blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
        'a search under two characters reads without q: $label',
        setUp: () => remote.listing([ada]),
        build: build,
        act: (bloc) async {
          bloc.add(const AdminHouseholdListSearchChanged('ab'));
          await pumpEventQueue();
          bloc.add(AdminHouseholdListSearchChanged(text));
          await pumpEventQueue();
        },
        verify: (bloc) {
          expect(remote.calls, [_fetch(q: 'ab'), _fetch()]);
          expect(
            bloc.state,
            ready([ada], query: AdminHouseholdQuery(text: text)),
          );
          expect(bloc.state.query.text, text);
        },
      );
    }

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a change that sends the same search reads nothing, and keeps the rows',
      setUp: () => remote.listing([ada]),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListSearchChanged(' ab '));
        await pumpEventQueue();
      },
      expect: () => [
        const AdminHouseholdListLoading(query: AdminHouseholdQuery(text: 'ab')),
        ready([ada], query: const AdminHouseholdQuery(text: 'ab')),
        ready([ada], query: const AdminHouseholdQuery(text: ' ab ')),
      ],
      verify: (_) => expect(remote.calls, [_fetch(q: 'ab')]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'live with the deleted sort falls back to name',
      setUp: () => remote.listing([ada]),
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListSortChanged(AdminHouseholdSort.deleted),
        );
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.live),
        );
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.all),
          _fetch(
            status: AdminHouseholdStatus.all,
            sort: AdminHouseholdSort.deleted,
          ),
          _fetch(),
        ]);
        expect(bloc.state, ready([ada]));
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a sort the status refuses is not sent',
      setUp: () => remote.listing([ada]),
      build: build,
      act: (bloc) async {
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListSortChanged(AdminHouseholdSort.deleted),
        );
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => <AdminHouseholdListState>[],
      verify: (_) => expect(remote.calls, [_fetch()]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a query change clears the last restore outcome',
      setUp: () {
        remote.onRestore = (_) async {};
        remote.onFetchPage = (request) async => adminPageOf(
          request.status == AdminHouseholdStatus.deleted ? [gone, lost] : [ada],
        );
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.live),
        );
        await pumpEventQueue();
      },
      skip: 4,
      expect: () => [
        const AdminHouseholdListLoading(),
        ready([ada]),
      ],
    );
  });

  group('typing while the list reads', () {
    const pause = Duration(milliseconds: 300);
    const ab = AdminHouseholdQuery(text: 'ab');
    const abc = AdminHouseholdQuery(text: 'abc');

    /// Runs [body] against a bloc with the default pause, under fake time.
    /// Answers every state the bloc emitted.
    ///
    /// A completer an answer waits on is made inside [body]: one made
    /// outside fake time completes on the real event loop, which fake time
    /// never runs.
    List<AdminHouseholdListState> underFakeTime(
      void Function(FakeAsync async, AdminHouseholdListBloc bloc) body,
    ) {
      final states = <AdminHouseholdListState>[];
      fakeAsync((async) {
        final bloc = AdminHouseholdListBloc(remote: remote, access: access);
        final subscription = bloc.stream.listen(states.add);
        body(async, bloc);
        async.flushMicrotasks();
        unawaited(subscription.cancel());
        unawaited(bloc.close());
        async.flushMicrotasks();
      });
      return states;
    }

    test('a keystroke that asks something new drops the search read out: '
        'the spinner stays through the pause', () {
      late Completer<_Page> first;
      remote.onFetchPage = (request) async =>
          request.query == 'ab' ? first.future : adminPageOf([bea]);
      final states = underFakeTime((async, bloc) {
        first = Completer<_Page>();
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(pause);
        bloc.add(const AdminHouseholdListSearchChanged('abc'));
        async.elapse(const Duration(milliseconds: 100));
        first.complete(adminPageOf([ada]));
        async.flushMicrotasks();
        expect(bloc.state, const AdminHouseholdListLoading(query: ab));
        async.elapse(const Duration(milliseconds: 200));
      });
      expect(remote.calls, [_fetch(q: 'ab'), _fetch(q: 'abc')]);
      expect(states, [
        const AdminHouseholdListLoading(query: ab),
        const AdminHouseholdListLoading(query: abc),
        ready([bea], query: abc),
      ]);
    });

    test('a keystroke that sends the same search keeps the read out', () {
      late Completer<_Page> first;
      remote.onFetchPage = (_) => first.future;
      final states = underFakeTime((async, bloc) {
        first = Completer<_Page>();
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(pause);
        bloc.add(const AdminHouseholdListSearchChanged('ab '));
        async.elapse(const Duration(milliseconds: 100));
        first.complete(adminPageOf([ada]));
        async.elapse(pause);
      });
      expect(remote.calls, [_fetch(q: 'ab')]);
      expect(states, [
        const AdminHouseholdListLoading(query: ab),
        ready([ada], query: ab),
        ready([ada], query: const AdminHouseholdQuery(text: 'ab ')),
      ]);
    });

    test('typing back to the search being read, before the pause ends, reads '
        'it again', () {
      late Completer<_Page> first;
      var reads = 0;
      remote.onFetchPage = (_) async =>
          reads++ == 0 ? first.future : adminPageOf([ada]);
      final states = underFakeTime((async, bloc) {
        first = Completer<_Page>();
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(pause);
        bloc.add(const AdminHouseholdListSearchChanged('abc'));
        async.elapse(const Duration(milliseconds: 100));
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(const Duration(milliseconds: 100));
        first.complete(adminPageOf([bea]));
        async.elapse(pause);
      });
      expect(remote.calls, [_fetch(q: 'ab'), _fetch(q: 'ab')]);
      expect(states, [
        const AdminHouseholdListLoading(query: ab),
        ready([ada], query: ab),
      ]);
    });

    test('a keystroke that asks something new drops a reload of the rows '
        'shown: they stay through the pause', () {
      var reads = 0;
      remote.onFetchPage = (request) async {
        if (request.query == 'ab') return adminPageOf([bea]);
        return reads++ == 0 ? adminPageOf([ada]) : reload.future;
      };
      final states = underFakeTime((async, bloc) {
        reload = Completer<_Page>();
        bloc.add(const AdminHouseholdListLoadRequested());
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListLoadRequested());
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(const Duration(milliseconds: 100));
        reload.complete(adminPageOf([ada, gone]));
        async.flushMicrotasks();
        expect(bloc.state, ready([ada]));
        async.elapse(const Duration(milliseconds: 200));
      });
      expect(remote.calls, [_fetch(), _fetch(), _fetch(q: 'ab')]);
      expect(states, [
        const AdminHouseholdListLoading(),
        ready([ada]),
        const AdminHouseholdListLoading(query: ab),
        ready([bea], query: ab),
      ]);
    });

    test('typing back to the rows shown reads what the dropped reload owed '
        'them, keeping them until it answers', () {
      var reads = 0;
      remote.onFetchPage = (_) async => switch (reads++) {
        0 => adminPageOf([ada]),
        1 => reload.future,
        _ => adminPageOf([ada, bea]),
      };
      final states = underFakeTime((async, bloc) {
        reload = Completer<_Page>();
        bloc.add(const AdminHouseholdListLoadRequested());
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListLoadRequested());
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(const Duration(milliseconds: 100));
        bloc.add(const AdminHouseholdListSearchChanged(''));
        async.elapse(const Duration(milliseconds: 100));
        reload.complete(adminPageOf([ada, gone]));
        async.flushMicrotasks();
        expect(bloc.state, ready([ada]));
        async.elapse(pause);
      });
      expect(remote.calls, [_fetch(), _fetch(), _fetch()]);
      expect(states, [
        const AdminHouseholdListLoading(),
        ready([ada]),
        ready([ada, bea]),
      ]);
    });

    test('a keystroke that asks something new drops a load more out, and '
        'one asked in the pause is dropped too', () {
      remote.onFetchPage = (request) async {
        if (request.query == 'ab') return adminPageOf([bea]);
        return request.page == 2
            ? more.future
            : adminPageOf(firstPage, hasMore: true);
      };
      underFakeTime((async, bloc) {
        more = Completer<_Page>();
        bloc.add(const AdminHouseholdListLoadRequested());
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListMoreRequested());
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.flushMicrotasks();
        expect(bloc.state, ready(firstPage, hasMore: true));
        bloc.add(const AdminHouseholdListMoreRequested());
        async.flushMicrotasks();
        more.complete(adminPageOf([next], page: 2));
        async.flushMicrotasks();
        expect(bloc.state, ready(firstPage, hasMore: true));
        async.elapse(pause);
        expect(bloc.state, ready([bea], query: ab));
      });
      expect(remote.calls, [_fetch(), _fetch(page: 2), _fetch(q: 'ab')]);
    });

    test("the list's own load more, as restores empty it in a pause, reads "
        'the list again when the person types back', () {
      var reads = 0;
      remote
        ..onRestore = ((_) => restore.future)
        ..onFetchPage = ((_) async => reads++ == 0
            ? adminPageOf([gone], hasMore: true)
            : adminPageOf([lost]));
      final restored = _outcome(
        AdminHouseholdRestoreResult.restored,
        'Old crew',
      );
      underFakeTime((async, bloc) {
        restore = Completer<void>();
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListSearchChanged('ol'));
        async.elapse(const Duration(milliseconds: 100));
        // The only row shown leaves while the server has more, so the list
        // asks for the next page, in the pause.
        restore.complete();
        async.flushMicrotasks();
        expect(
          bloc.state,
          ready(const [], query: _deleted, hasMore: true, outcome: restored),
        );
        bloc.add(const AdminHouseholdListSearchChanged(''));
        async.elapse(pause);
        expect(bloc.state, ready([lost], query: _deleted, outcome: restored));
      });
      expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.deleted),
        'restore(h_gone)',
        _fetch(status: AdminHouseholdStatus.deleted),
      ]);
    });

    test('a keystroke that asks something new clears the last banner', () {
      remote
        ..listing([gone, lost])
        ..onRestore = (_) async {};
      underFakeTime((async, bloc) {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        async.flushMicrotasks();
        expect(
          bloc.state,
          ready(
            [lost],
            query: _deleted,
            outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
          ),
        );
        bloc.add(const AdminHouseholdListSearchChanged('ol'));
        async.flushMicrotasks();
        expect(bloc.state, ready([lost], query: _deleted));
        async.elapse(pause);
      });
    });

    test('a restore that ends while a search waits out its pause keeps its '
        'banner, and reads nothing of the older search', () {
      remote
        ..onRestore = ((_) => restore.future)
        ..onFetchPage = ((request) async =>
            adminPageOf(request.query == 'ol' ? [lost] : [gone, lost]));
      underFakeTime((async, bloc) {
        restore = Completer<void>();
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListSearchChanged('ol'));
        async.elapse(const Duration(milliseconds: 100));
        // A 409, which on its own reads the list again.
        restore.completeError(_notDeleted);
        async.flushMicrotasks();
        expect(
          bloc.state,
          ready(
            [lost],
            query: _deleted,
            outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
          ),
        );
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h_gone)',
        ]);
        async.elapse(const Duration(milliseconds: 200));
        expect(
          bloc.state,
          ready(
            [lost],
            query: const AdminHouseholdQuery(
              status: AdminHouseholdStatus.deleted,
              text: 'ol',
            ),
            outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
          ),
        );
      });
      expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.deleted),
        'restore(h_gone)',
        _fetch(status: AdminHouseholdStatus.deleted, q: 'ol'),
      ]);
    });

    test('a status change while a search waits out its pause reads with the '
        'text typed, and the search reads nothing more', () {
      remote.listing([ada]);
      underFakeTime((async, bloc) {
        bloc.add(const AdminHouseholdListLoadRequested());
        async.flushMicrotasks();
        bloc.add(const AdminHouseholdListSearchChanged('ab'));
        async.elapse(const Duration(milliseconds: 100));
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        async.elapse(pause);
        expect(
          bloc.state,
          ready(
            [ada],
            query: const AdminHouseholdQuery(
              status: AdminHouseholdStatus.deleted,
              text: 'ab',
            ),
          ),
        );
      });
      expect(remote.calls, [
        _fetch(),
        _fetch(status: AdminHouseholdStatus.deleted, q: 'ab'),
      ]);
    });
  });

  group('restore', () {
    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'under Deleted, a restored row leaves the list',
      setUp: () {
        remote
          ..listing([gone, lost])
          ..onRestore = (_) async {};
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
      },
      skip: 2,
      expect: () => [
        ready([gone, lost], query: _deleted, restoring: const {'h_gone'}),
        ready(
          [lost],
          query: _deleted,
          outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
        ),
      ],
      verify: (_) => expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.deleted),
        'restore(h_gone)',
      ]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'under All, a restored row is replaced by its live self',
      setUp: () {
        remote
          ..listing([gone, ada])
          ..onRestore = (_) async {};
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
      },
      skip: 2,
      expect: () => [
        ready([gone, ada], query: _all, restoring: const {'h_gone'}),
        ready(
          [gone.restored(), ada],
          query: _all,
          outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
        ),
      ],
      verify: (_) => expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.all),
        'restore(h_gone)',
      ]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a 409 is done, and the list is read again',
      setUp: () {
        firstPages([
          adminPageOf([gone, lost]),
          adminPageOf([lost]),
        ]);
        remote.onRestore = (_) async => throw _notDeleted;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        ready([gone, lost], query: _deleted, restoring: const {'h_gone'}),
        ready(
          [lost],
          query: _deleted,
          outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
        ),
      ],
      verify: (_) => expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.deleted),
        'restore(h_gone)',
        _fetch(status: AdminHouseholdStatus.deleted),
      ]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      "a 404 says it couldn't be restored, and reads the list again: the "
      'row stays until the read answers',
      setUp: () {
        reload = Completer<_Page>();
        var reads = 0;
        remote.onRestore = (_) async => throw _notFound;
        remote.onFetchPage = (_) async =>
            reads++ == 0 ? adminPageOf([gone, lost]) : reload.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h_gone)',
          _fetch(status: AdminHouseholdStatus.deleted),
        ]);
        reload.complete(adminPageOf([lost]));
        await pumpEventQueue();
      },
      skip: 2,
      expect: () => [
        ready([gone, lost], query: _deleted, restoring: const {'h_gone'}),
        ready(
          [gone, lost],
          query: _deleted,
          outcome: _outcome(
            AdminHouseholdRestoreResult.notRestorable,
            'Old crew',
          ),
        ),
        ready(
          [lost],
          query: _deleted,
          outcome: _outcome(
            AdminHouseholdRestoreResult.notRestorable,
            'Old crew',
          ),
        ),
      ],
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a refused restore is Refused and asks access again',
      setUp: () {
        remote
          ..listing([gone, lost])
          ..onRestore = (_) async => throw _forbidden;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
      },
      skip: 2,
      expect: () => [
        ready([gone, lost], query: _deleted, restoring: const {'h_gone'}),
        const AdminHouseholdListRefused(query: _deleted),
      ],
      verify: (_) {
        expect(access.refreshCount, 1);
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h_gone)',
        ]);
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a transient restore failure keeps the row',
      setUp: () {
        remote
          ..listing([gone, lost])
          ..onRestore = (_) async => throw _transient;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
      },
      skip: 2,
      expect: () => [
        ready([gone, lost], query: _deleted, restoring: const {'h_gone'}),
        ready(
          [gone, lost],
          query: _deleted,
          outcome: _outcome(AdminHouseholdRestoreResult.failed, 'Old crew'),
        ),
      ],
      verify: (_) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h_gone)',
        ]);
        expect(access.refreshCount, 0);
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a restore already running is not sent again',
      setUp: () {
        remote
          ..listing([gone, lost])
          ..onRestore = (_) => Completer<void>().future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h_gone)',
        ]);
        expect(
          bloc.state,
          ready([gone, lost], query: _deleted, restoring: const {'h_gone'}),
        );
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a row that is not deleted is not sent',
      setUp: () => remote.listing([gone, ada]),
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        bloc
          ..add(const AdminHouseholdListRestoreRequested('h_ada'))
          ..add(const AdminHouseholdListRestoreRequested('h_missing'));
        await pumpEventQueue();
      },
      verify: (_) =>
          expect(remote.calls, [_fetch(status: AdminHouseholdStatus.all)]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'OutcomeDismissed clears the outcome',
      setUp: () {
        remote
          ..listing([gone, lost])
          ..onRestore = (_) async {};
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListOutcomeDismissed());
      },
      skip: 4,
      expect: () => [
        ready([lost], query: _deleted),
      ],
    );
  });

  group('restore while the list moves', () {
    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'after a restore takes a row out, load more asks for the page that now '
      'holds the next row',
      setUp: () => firstPages([
        adminPageOf(_rows(1, 25), hasMore: true),
        // The server's rows moved up one once h1 was restored.
        adminPageOf(_rows(2, 26), hasMore: true),
      ], later: (page) => adminPageOf(_rows(27, 51), page: page)),
      build: () {
        remote.onRestore = (_) async {};
        return build();
      },
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h1'));
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        expect((bloc.state as AdminHouseholdListReady).rows, _rows(2, 26));
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h1)',
          _fetch(status: AdminHouseholdStatus.deleted),
          _fetch(status: AdminHouseholdStatus.deleted, page: 2),
        ]);
        expect((bloc.state as AdminHouseholdListReady).rows, _rows(2, 51));
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a list emptied by restores reads on while the server has more',
      setUp: () {
        firstPages([
          adminPageOf([gone], hasMore: true),
          adminPageOf([lost]),
        ]);
        remote.onRestore = (_) async {};
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h_gone)',
          _fetch(status: AdminHouseholdStatus.deleted),
        ]);
        expect(
          bloc.state,
          ready(
            [lost],
            query: _deleted,
            outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
          ),
        );
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a restore that ends after the query changed applies to the rows shown, '
      'and reads the list again',
      setUp: () {
        restore = Completer<void>();
        var allReads = 0;
        remote
          ..onFetchPage = (request) async {
            if (request.status == AdminHouseholdStatus.deleted) {
              return adminPageOf([gone, lost]);
            }
            return adminPageOf(
              allReads++ == 0 ? [gone, ada] : [gone.restored(), ada],
            );
          }
          ..onRestore = (_) => restore.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        restore.complete();
        await pumpEventQueue();
      },
      skip: 3,
      expect: () => [
        const AdminHouseholdListLoading(query: _all),
        // Still restoring, so its Restore stays disabled under the new query.
        ready([gone, ada], query: _all, restoring: const {'h_gone'}),
        ready(
          [gone.restored(), ada],
          query: _all,
          outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
        ),
      ],
      verify: (_) => expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.deleted),
        'restore(h_gone)',
        _fetch(status: AdminHouseholdStatus.all),
        _fetch(status: AdminHouseholdStatus.all),
      ]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a restore that ends while a read is out reads the list again: that '
      'read may be answered as the list was before the restore',
      setUp: () {
        restore = Completer<void>();
        reload = Completer<_Page>();
        var reads = 0;
        remote.onRestore = (_) => restore.future;
        remote.onFetchPage = (_) async => switch (reads++) {
          0 => adminPageOf([gone, lost]),
          1 => reload.future,
          _ => adminPageOf([lost]),
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        // Out from before the restore began, so no newer read starts during
        // it.
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
        restore.complete();
        await pumpEventQueue();
        // The read that was out answers last, with the row still deleted.
        reload.complete(adminPageOf([gone, lost]));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          _fetch(status: AdminHouseholdStatus.deleted),
          'restore(h_gone)',
          _fetch(status: AdminHouseholdStatus.deleted),
        ]);
        expect(
          bloc.state,
          ready(
            [lost],
            query: _deleted,
            outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
          ),
        );
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a restore that takes a row out while a load more is out reads the '
      'list again: the page may have been read either side of it',
      setUp: () {
        more = Completer<_Page>();
        firstPages([
          adminPageOf(_rows(1, 25), hasMore: true),
          adminPageOf(_rows(2, 26), hasMore: true),
        ], later: (_) => throw StateError('answered by the completer'));
        final pages = remote.onFetchPage!;
        remote.onRestore = (_) async {};
        remote.onFetchPage = (request) =>
            request.page == 2 ? more.future : pages(request);
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h1'));
        await pumpEventQueue();
        // The page read before the restore lands after the list was read
        // again, and is dropped.
        more.complete(adminPageOf(_rows(26, 50), page: 2));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.deleted),
          _fetch(status: AdminHouseholdStatus.deleted, page: 2),
          'restore(h1)',
          _fetch(status: AdminHouseholdStatus.deleted),
        ]);
        expect(
          bloc.state,
          ready(
            _rows(2, 26),
            query: _deleted,
            hasMore: true,
            outcome: _outcome(
              AdminHouseholdRestoreResult.restored,
              'Household h1',
            ),
          ),
        );
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'under All by recently deleted, a restored row moves past rows shown '
      'that are all deleted: load more asks for the page that now holds the '
      'next row',
      setUp: () {
        firstPages([
          adminPageOf(_rows(1, 25), hasMore: true),
        ], later: (page) => adminPageOf(_rows(26, 50), page: page));
        remote.onRestore = (_) async {};
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListSortChanged(AdminHouseholdSort.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h1'));
        await pumpEventQueue();
        expect(
          (bloc.state as AdminHouseholdListReady).rows.first,
          adminRow('h1'),
        );
        bloc.add(const AdminHouseholdListMoreRequested());
        await pumpEventQueue();
      },
      verify: (_) => expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.all),
        _fetch(
          status: AdminHouseholdStatus.all,
          sort: AdminHouseholdSort.deleted,
        ),
        'restore(h1)',
        _fetch(
          status: AdminHouseholdStatus.all,
          sort: AdminHouseholdSort.deleted,
        ),
      ]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'under All by recently deleted with live rows shown, a restored row '
      'may move among them: the list is read again',
      setUp: () {
        remote
          ..listing([gone, ada], hasMore: true)
          ..onRestore = (_) async {};
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        bloc.add(
          const AdminHouseholdListSortChanged(AdminHouseholdSort.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
      },
      verify: (_) => expect(remote.calls, [
        _fetch(status: AdminHouseholdStatus.all),
        _fetch(
          status: AdminHouseholdStatus.all,
          sort: AdminHouseholdSort.deleted,
        ),
        'restore(h_gone)',
        _fetch(
          status: AdminHouseholdStatus.all,
          sort: AdminHouseholdSort.deleted,
        ),
      ]),
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'under All by name, a restored row keeps its place: nothing is read '
      'again',
      setUp: () {
        remote
          ..listing([gone, ada], hasMore: true)
          ..onRestore = (_) async {};
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.all),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(remote.calls, [
          _fetch(status: AdminHouseholdStatus.all),
          'restore(h_gone)',
        ]);
        expect(
          bloc.state,
          ready(
            [gone.restored(), ada],
            query: _all,
            hasMore: true,
            outcome: _outcome(AdminHouseholdRestoreResult.restored, 'Old crew'),
          ),
        );
      },
    );

    blocTest<AdminHouseholdListBloc, AdminHouseholdListState>(
      'a refused restore ends a read that is out',
      setUp: () {
        restore = Completer<void>();
        reload = Completer<_Page>();
        var reads = 0;
        remote.onRestore = (_) => restore.future;
        remote.onFetchPage = (_) async =>
            reads++ == 0 ? adminPageOf([gone, lost]) : reload.future;
      },
      build: build,
      act: (bloc) async {
        bloc.add(
          const AdminHouseholdListStatusChanged(AdminHouseholdStatus.deleted),
        );
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListRestoreRequested('h_gone'));
        await pumpEventQueue();
        bloc.add(const AdminHouseholdListLoadRequested());
        await pumpEventQueue();
        restore.completeError(_forbidden);
        await pumpEventQueue();
        reload.complete(adminPageOf([gone, lost]));
        await pumpEventQueue();
      },
      verify: (bloc) {
        expect(bloc.state, const AdminHouseholdListRefused(query: _deleted));
        expect(access.refreshCount, 1);
      },
    );
  });
}
