import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/notifications.dart';

import '../support/fake_notification_remote.dart';

void main() {
  late FakeNotificationRemote remote;
  late List<int> markedRead;
  late int allMarkedRead;

  final openedAt = DateTime.utc(2026, 11, 27, 12);
  final earlier = DateTime.utc(2026, 11, 20, 9);

  UserNotification note(String id, {bool read = false}) => UserNotification(
    id: id,
    type: 'household.invitation.received',
    payload: const {},
    read: read,
    readAt: read ? earlier : null,
    createdAt: DateTime.utc(2026, 11, 26),
  );

  final a = note('a');
  final b = note('b');
  final c = note('c');
  final z = note('z');
  final seen = note('seen', read: true);

  const offline = NotificationTransientException('offline');
  const badCursor = NotificationPermanentException(
    'malformed cursor',
    statusCode: 400,
  );

  setUp(() {
    remote = FakeNotificationRemote();
    markedRead = [];
    allMarkedRead = 0;
  });

  NotificationListBloc build({int? pageSize}) => pageSize == null
      ? NotificationListBloc(
          remote,
          onMarkedRead: markedRead.add,
          onAllMarkedRead: () => allMarkedRead++,
          now: () => openedAt,
        )
      : NotificationListBloc(
          remote,
          pageSize: pageSize,
          onMarkedRead: markedRead.add,
          onAllMarkedRead: () => allMarkedRead++,
          now: () => openedAt,
        );

  NotificationListState loaded(
    List<UserNotification> items, {
    String? nextCursor,
    bool refreshing = false,
    bool loadingMore = false,
    bool markingAll = false,
  }) => NotificationListState(
    status: NotificationListStatus.loaded,
    items: items,
    nextCursor: nextCursor,
    refreshing: refreshing,
    loadingMore: loadingMore,
    markingAll: markingAll,
  );

  /// [rest] carrying an outcome of type [T] for [failure].
  Matcher failed<T extends NotificationListOutcome>(
    NotificationListState rest,
    NotificationListFailure failure,
  ) => isA<NotificationListState>()
      .having(
        (state) => state.outcome,
        'outcome',
        isA<T>().having((outcome) => outcome.failure, 'failure', failure),
      )
      .having((state) => state.copyWith(), 'without its outcome', rest);

  test('starts loading, with nothing', () {
    final bloc = build();
    addTearDown(bloc.close);
    expect(bloc.state, const NotificationListState());
    expect(bloc.state.status, NotificationListStatus.loading);
    expect(bloc.state.items, isEmpty);
    expect(bloc.state.hasUnread, isFalse);
    expect(bloc.state.outcome, isNull);
  });

  test('hasUnread is whether any row is unread', () {
    expect(loaded([seen]).hasUnread, isFalse);
    expect(loaded([seen, a]).hasUnread, isTrue);
  });

  group('load', () {
    blocTest<NotificationListBloc, NotificationListState>(
      'load fetches the first page at pageSize',
      setUp: () => remote.scriptPages([
        NotificationPage(items: [a, seen], nextCursor: 'c1'),
      ]),
      build: () => build(pageSize: 5),
      act: (bloc) => bloc.add(const NotificationListLoadRequested()),
      expect: () => [
        loaded([a, seen], nextCursor: 'c1'),
      ],
      verify: (_) => expect(remote.fetchPageCalls, [(cursor: null, limit: 5)]),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'load asks for the default page size when none is given',
      setUp: () => remote.scriptPages([
        NotificationPage(items: [a]),
      ]),
      build: build,
      act: (bloc) => bloc.add(const NotificationListLoadRequested()),
      expect: () => [
        loaded([a]),
      ],
      verify: (_) => expect(remote.fetchPageCalls, [
        (cursor: null, limit: NotificationRemoteDataSource.defaultPageSize),
      ]),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'load failing transiently is loadFailed transient',
      setUp: () => remote.scriptPages([offline]),
      build: build,
      act: (bloc) => bloc.add(const NotificationListLoadRequested()),
      expect: () => [
        const NotificationListState(
          status: NotificationListStatus.loadFailed,
          failure: NotificationListFailure.transient,
        ),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'load failing permanently is loadFailed permanent',
      setUp: () => remote.scriptPages([
        const NotificationPermanentException('forbidden', statusCode: 403),
      ]),
      build: build,
      act: (bloc) => bloc.add(const NotificationListLoadRequested()),
      expect: () => [
        const NotificationListState(
          status: NotificationListStatus.loadFailed,
          failure: NotificationListFailure.permanent,
        ),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'load after a failure loads again from the start',
      setUp: () => remote.scriptPages([
        offline,
        NotificationPage(items: [a]),
      ]),
      build: build,
      act: (bloc) async {
        bloc.add(const NotificationListLoadRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListLoadRequested());
      },
      expect: () => [
        const NotificationListState(
          status: NotificationListStatus.loadFailed,
          failure: NotificationListFailure.transient,
        ),
        const NotificationListState(),
        loaded([a]),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'load failing with an error the remote does not name is loadFailed '
      'permanent, and the error surfaces',
      build: build,
      act: (bloc) async {
        final page = Completer<NotificationPage>();
        remote.scriptPages([page.future]);
        bloc.add(const NotificationListLoadRequested());
        await pumpEventQueue();
        page.completeError(StateError('bug'));
      },
      expect: () => [
        const NotificationListState(
          status: NotificationListStatus.loadFailed,
          failure: NotificationListFailure.permanent,
        ),
      ],
      errors: () => [isA<StateError>()],
    );
  });

  group('refresh', () {
    blocTest<NotificationListBloc, NotificationListState>(
      'refresh replaces the items and keeps them when it fails',
      setUp: () => remote.scriptPages([
        NotificationPage(items: [z, a], nextCursor: 'c9'),
        offline,
      ]),
      build: build,
      seed: () => loaded([a, b], nextCursor: 'c1'),
      act: (bloc) async {
        bloc.add(const NotificationListRefreshRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListRefreshRequested());
      },
      expect: () => [
        loaded([a, b], nextCursor: 'c1', refreshing: true),
        loaded([z, a], nextCursor: 'c9'),
        loaded([z, a], nextCursor: 'c9', refreshing: true),
        failed<RefreshFailed>(
          loaded([z, a], nextCursor: 'c9'),
          NotificationListFailure.transient,
        ),
      ],
      verify: (_) => expect(remote.fetchPageCalls, [
        (cursor: null, limit: NotificationRemoteDataSource.defaultPageSize),
        (cursor: null, limit: NotificationRemoteDataSource.defaultPageSize),
      ]),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'a refresh failing the same way twice is a new outcome each time',
      setUp: () => remote.scriptPages([offline, offline]),
      build: build,
      seed: () => loaded([a]),
      act: (bloc) async {
        bloc.add(const NotificationListRefreshRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListRefreshRequested());
      },
      expect: () => [
        loaded([a], refreshing: true),
        failed<RefreshFailed>(
          loaded([a]),
          NotificationListFailure.transient,
        ),
        loaded([a], refreshing: true),
        failed<RefreshFailed>(
          loaded([a]),
          NotificationListFailure.transient,
        ),
      ],
      verify: (bloc) {
        // Every state above was emitted, so the second outcome is not the
        // first: a page listening for a new outcome shows both.
        expect(bloc.state.outcome, isA<RefreshFailed>());
        expect(
          RefreshFailed(NotificationListFailure.transient),
          isNot(RefreshFailed(NotificationListFailure.transient)),
        );
      },
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'refresh with nothing loaded loads',
      setUp: () => remote.scriptPages([
        NotificationPage(items: [a]),
      ]),
      build: build,
      seed: () => const NotificationListState(
        status: NotificationListStatus.loadFailed,
        failure: NotificationListFailure.transient,
      ),
      act: (bloc) => bloc.add(const NotificationListRefreshRequested()),
      expect: () => [
        const NotificationListState(),
        loaded([a]),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'refresh after more replaces the items with the fresh first page and '
      'its cursor',
      setUp: () => remote.scriptPages([
        NotificationPage(items: [a, b], nextCursor: 'c1'),
        NotificationPage(items: [c], nextCursor: 'c2'),
        // z was written while the user paged down.
        NotificationPage(items: [z, a], nextCursor: 'c1-fresh'),
        NotificationPage(items: [b, c]),
      ]),
      build: build,
      act: (bloc) async {
        bloc.add(const NotificationListLoadRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListMoreRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListRefreshRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListMoreRequested());
      },
      expect: () => [
        loaded([a, b], nextCursor: 'c1'),
        loaded([a, b], nextCursor: 'c1', loadingMore: true),
        loaded([a, b, c], nextCursor: 'c2'),
        loaded([a, b, c], nextCursor: 'c2', refreshing: true),
        loaded([z, a], nextCursor: 'c1-fresh'),
        loaded([z, a], nextCursor: 'c1-fresh', loadingMore: true),
        loaded([z, a, b, c]),
      ],
      verify: (_) => expect(
        remote.fetchPageCalls.map((call) => call.cursor),
        [null, 'c1', null, 'c1-fresh'],
      ),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'a more that answers after a refresh adds nothing',
      build: build,
      seed: () => loaded([a, b], nextCursor: 'c1'),
      act: (bloc) async {
        final page2 = Completer<NotificationPage>();
        remote.scriptPages([
          page2.future,
          NotificationPage(items: [z, a], nextCursor: 'c1-fresh'),
        ]);
        bloc.add(const NotificationListMoreRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListRefreshRequested());
        await pumpEventQueue();
        page2.complete(NotificationPage(items: [c], nextCursor: 'c2'));
      },
      expect: () => [
        loaded([a, b], nextCursor: 'c1', loadingMore: true),
        loaded([a, b], nextCursor: 'c1', loadingMore: true, refreshing: true),
        loaded([z, a], nextCursor: 'c1-fresh', loadingMore: true),
        loaded([z, a], nextCursor: 'c1-fresh'),
      ],
    );
  });

  group('more', () {
    blocTest<NotificationListBloc, NotificationListState>(
      'more sends the last nextCursor unchanged and appends',
      setUp: () => remote.scriptPages([
        NotificationPage(items: [c], nextCursor: 'c2'),
      ]),
      build: () => build(pageSize: 5),
      seed: () => loaded([a, b], nextCursor: 'opaque/c1=='),
      act: (bloc) => bloc.add(const NotificationListMoreRequested()),
      expect: () => [
        loaded([a, b], nextCursor: 'opaque/c1==', loadingMore: true),
        loaded([a, b, c], nextCursor: 'c2'),
      ],
      verify: (_) => expect(remote.fetchPageCalls, [
        (cursor: 'opaque/c1==', limit: 5),
      ]),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'more de-duplicates by id',
      setUp: () => remote.scriptPages([
        NotificationPage(items: [note('b', read: true), c]),
      ]),
      build: build,
      seed: () => loaded([a, b], nextCursor: 'c1'),
      act: (bloc) => bloc.add(const NotificationListMoreRequested()),
      expect: () => [
        loaded([a, b], nextCursor: 'c1', loadingMore: true),
        // b keeps the row already shown.
        loaded([a, b, c]),
      ],
    );

    for (final (name, error, failure) in [
      ('transient', offline, NotificationListFailure.transient),
      ('a permanent 400', badCursor, NotificationListFailure.permanent),
    ]) {
      blocTest<NotificationListBloc, NotificationListState>(
        'more failing ($name) keeps the items and cursor, and emits '
        'LoadMoreFailed',
        setUp: () => remote.scriptPages([
          error,
          NotificationPage(items: [c]),
        ]),
        build: build,
        seed: () => loaded([a, b], nextCursor: 'c1'),
        act: (bloc) async {
          bloc.add(const NotificationListMoreRequested());
          await pumpEventQueue();
          bloc.add(const NotificationListMoreRequested());
        },
        expect: () => [
          loaded([a, b], nextCursor: 'c1', loadingMore: true),
          failed<LoadMoreFailed>(loaded([a, b], nextCursor: 'c1'), failure),
          loaded([a, b], nextCursor: 'c1', loadingMore: true),
          loaded([a, b, c]),
        ],
        verify: (_) => expect(
          remote.fetchPageCalls.map((call) => call.cursor),
          ['c1', 'c1'],
        ),
      );
    }

    blocTest<NotificationListBloc, NotificationListState>(
      'more is ignored without a cursor',
      build: build,
      seed: () => loaded([a, b]),
      act: (bloc) => bloc.add(const NotificationListMoreRequested()),
      expect: () => <NotificationListState>[],
      verify: (_) => expect(remote.fetchPageCalls, isEmpty),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'more is ignored while loading more',
      build: build,
      seed: () => loaded([a, b], nextCursor: 'c1'),
      act: (bloc) async {
        final page2 = Completer<NotificationPage>();
        remote.scriptPages([page2.future]);
        bloc
          ..add(const NotificationListMoreRequested())
          ..add(const NotificationListMoreRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListMoreRequested());
        await pumpEventQueue();
        page2.complete(NotificationPage(items: [c]));
      },
      expect: () => [
        loaded([a, b], nextCursor: 'c1', loadingMore: true),
        loaded([a, b, c]),
      ],
      verify: (_) => expect(remote.fetchPageCalls, hasLength(1)),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'more is ignored while refreshing',
      build: build,
      seed: () => loaded([a], nextCursor: 'c1', refreshing: true),
      act: (bloc) => bloc.add(const NotificationListMoreRequested()),
      expect: () => <NotificationListState>[],
      verify: (_) => expect(remote.fetchPageCalls, isEmpty),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'more is ignored before the list has loaded',
      build: build,
      seed: () => const NotificationListState(
        status: NotificationListStatus.loadFailed,
        failure: NotificationListFailure.transient,
      ),
      act: (bloc) => bloc.add(const NotificationListMoreRequested()),
      expect: () => <NotificationListState>[],
      verify: (_) => expect(remote.fetchPageCalls, isEmpty),
    );
  });

  group('opened', () {
    blocTest<NotificationListBloc, NotificationListState>(
      'opened marks the row read locally, calls markRead([id]) and reports '
      'onMarkedRead(1)',
      setUp: () => remote.scriptMarkRead([null]),
      build: build,
      seed: () => loaded([a, b], nextCursor: 'c1'),
      act: (bloc) => bloc.add(const NotificationListOpened('b')),
      expect: () => [
        loaded([a, b.markedRead(openedAt)], nextCursor: 'c1'),
      ],
      verify: (_) {
        expect(remote.markReadCalls, [
          ['b'],
        ]);
        expect(markedRead, [1]);
      },
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'opened shows the next row read while an earlier markRead hangs',
      build: build,
      seed: () => loaded([a, b]),
      act: (bloc) async {
        final first = Completer<void>();
        remote.scriptMarkRead([first.future, null]);
        bloc.add(const NotificationListOpened('a'));
        await pumpEventQueue();
        bloc.add(const NotificationListOpened('b'));
        await pumpEventQueue();
        // b shows read, and was sent, before a's request settles.
        expect(bloc.state.items, [
          a.markedRead(openedAt),
          b.markedRead(openedAt),
        ]);
        expect(remote.markReadCalls, [
          ['a'],
          ['b'],
        ]);
        first.complete();
      },
      expect: () => [
        loaded([a.markedRead(openedAt), b]),
        loaded([a.markedRead(openedAt), b.markedRead(openedAt)]),
      ],
      verify: (_) => expect(markedRead, [1, 1]),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'opened on a row already read sends nothing',
      build: build,
      seed: () => loaded([a, seen]),
      act: (bloc) => bloc.add(const NotificationListOpened('seen')),
      expect: () => <NotificationListState>[],
      verify: (_) {
        expect(remote.markReadCalls, isEmpty);
        expect(markedRead, isEmpty);
      },
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'opened on a row not in the list sends nothing',
      build: build,
      seed: () => loaded([a]),
      act: (bloc) => bloc.add(const NotificationListOpened('gone')),
      expect: () => <NotificationListState>[],
      verify: (_) => expect(remote.markReadCalls, isEmpty),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'opened with markRead failing keeps the row read locally and reports '
      'nothing more',
      setUp: () => remote.scriptMarkRead([offline]),
      build: build,
      seed: () => loaded([a, b]),
      act: (bloc) => bloc.add(const NotificationListOpened('a')),
      expect: () => [
        loaded([a.markedRead(openedAt), b]),
      ],
      verify: (bloc) {
        expect(remote.markReadCalls, [
          ['a'],
        ]);
        expect(markedRead, isEmpty);
        expect(bloc.state.outcome, isNull);
      },
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'opened while marking all read is sent on its own, and the row stays '
      'read when marking all fails',
      build: build,
      seed: () => loaded([a, b]),
      act: (bloc) async {
        final all = Completer<void>();
        remote
          ..scriptMarkAllRead([all.future])
          ..scriptMarkRead([null]);
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        bloc.add(const NotificationListOpened('a'));
        await pumpEventQueue();
        all.completeError(offline);
      },
      expect: () => [
        loaded([
          a.markedRead(openedAt),
          b.markedRead(openedAt),
        ], markingAll: true),
        failed<MarkAllFailed>(
          loaded([a.markedRead(openedAt), b]),
          NotificationListFailure.transient,
        ),
      ],
      verify: (_) {
        expect(remote.markReadCalls, [
          ['a'],
        ]);
        expect(markedRead, [1]);
        expect(allMarkedRead, 0);
      },
    );
  });

  group('all marked read', () {
    blocTest<NotificationListBloc, NotificationListState>(
      'all marked read marks every row read, calls markAllRead once and '
      'reports onAllMarkedRead',
      build: build,
      seed: () => loaded([a, seen, b], nextCursor: 'c1'),
      act: (bloc) async {
        final all = Completer<void>();
        remote.scriptMarkAllRead([all.future]);
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        // Asked again while the first is out: dropped.
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        all.complete();
      },
      expect: () => [
        loaded(
          [a.markedRead(openedAt), seen, b.markedRead(openedAt)],
          nextCursor: 'c1',
          markingAll: true,
        ),
        loaded(
          [a.markedRead(openedAt), seen, b.markedRead(openedAt)],
          nextCursor: 'c1',
        ),
      ],
      verify: (_) {
        expect(remote.markAllReadCalls, 1);
        expect(allMarkedRead, 1);
      },
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'all marked read failing restores the rows and emits MarkAllFailed',
      setUp: () => remote.scriptMarkAllRead([
        const NotificationPermanentException('refused', statusCode: 403),
      ]),
      build: build,
      seed: () => loaded([a, seen, b]),
      act: (bloc) => bloc.add(const NotificationListAllMarkedRead()),
      expect: () => [
        loaded(
          [a.markedRead(openedAt), seen, b.markedRead(openedAt)],
          markingAll: true,
        ),
        failed<MarkAllFailed>(
          loaded([a, seen, b]),
          NotificationListFailure.permanent,
        ),
      ],
      verify: (_) => expect(allMarkedRead, 0),
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'all marked read failing keeps rows as a refresh meanwhile read them',
      build: build,
      seed: () => loaded([a, b]),
      act: (bloc) async {
        final all = Completer<void>();
        remote
          ..scriptMarkAllRead([all.future])
          ..scriptPages([
            // Read on another device meanwhile.
            NotificationPage(items: [note('a', read: true), b]),
          ]);
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        bloc.add(const NotificationListRefreshRequested());
        await pumpEventQueue();
        all.completeError(offline);
      },
      expect: () => [
        loaded([
          a.markedRead(openedAt),
          b.markedRead(openedAt),
        ], markingAll: true),
        loaded(
          [a.markedRead(openedAt), b.markedRead(openedAt)],
          markingAll: true,
          refreshing: true,
        ),
        // b may have been read before the server marked it: it shows read
        // with the rest while marking all read is out.
        loaded([
          note('a', read: true),
          b.markedRead(openedAt),
        ], markingAll: true),
        failed<MarkAllFailed>(
          loaded([note('a', read: true), b]),
          NotificationListFailure.transient,
        ),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'all marked read failing keeps rows a more added while it was out',
      build: build,
      seed: () => loaded([a], nextCursor: 'c1'),
      act: (bloc) async {
        final all = Completer<void>();
        remote
          ..scriptMarkAllRead([all.future])
          ..scriptPages([
            NotificationPage(items: [b]),
          ]);
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        bloc.add(const NotificationListMoreRequested());
        await pumpEventQueue();
        all.completeError(offline);
      },
      expect: () => [
        loaded([a.markedRead(openedAt)], nextCursor: 'c1', markingAll: true),
        loaded(
          [a.markedRead(openedAt)],
          nextCursor: 'c1',
          markingAll: true,
          loadingMore: true,
        ),
        loaded([
          a.markedRead(openedAt),
          b.markedRead(openedAt),
        ], markingAll: true),
        failed<MarkAllFailed>(
          loaded([a, b]),
          NotificationListFailure.transient,
        ),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'all marked read shows read the rows a more adds while it is out, and '
      'they stay read when the server takes it',
      build: build,
      seed: () => loaded([a], nextCursor: 'c1'),
      act: (bloc) async {
        final page = Completer<NotificationPage>();
        final all = Completer<void>();
        remote
          ..scriptPages([page.future])
          ..scriptMarkAllRead([all.future]);
        bloc.add(const NotificationListMoreRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        // The page was read before the server marked them.
        page.complete(NotificationPage(items: [b, seen]));
        await pumpEventQueue();
        all.complete();
      },
      expect: () => [
        loaded([a], nextCursor: 'c1', loadingMore: true),
        loaded(
          [a.markedRead(openedAt)],
          nextCursor: 'c1',
          loadingMore: true,
          markingAll: true,
        ),
        loaded([
          a.markedRead(openedAt),
          b.markedRead(openedAt),
          seen,
        ], markingAll: true),
        loaded([a.markedRead(openedAt), b.markedRead(openedAt), seen]),
      ],
      verify: (bloc) {
        expect(bloc.state.hasUnread, isFalse);
        expect(allMarkedRead, 1);
      },
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'a more out while all marked read was answers read when it lands after',
      build: build,
      seed: () => loaded([a], nextCursor: 'c1'),
      act: (bloc) async {
        final page = Completer<NotificationPage>();
        remote
          ..scriptPages([page.future])
          ..scriptMarkAllRead([null]);
        bloc.add(const NotificationListMoreRequested());
        await pumpEventQueue();
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        page.complete(NotificationPage(items: [b]));
      },
      expect: () => [
        loaded([a], nextCursor: 'c1', loadingMore: true),
        loaded(
          [a.markedRead(openedAt)],
          nextCursor: 'c1',
          loadingMore: true,
          markingAll: true,
        ),
        loaded(
          [a.markedRead(openedAt)],
          nextCursor: 'c1',
          loadingMore: true,
        ),
        loaded([a.markedRead(openedAt), b.markedRead(openedAt)]),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'all marked read shows read the rows a refresh brings while it is out',
      build: build,
      seed: () => loaded([a]),
      act: (bloc) async {
        final all = Completer<void>();
        remote
          ..scriptMarkAllRead([all.future])
          ..scriptPages([
            NotificationPage(items: [z, a]),
          ]);
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        bloc.add(const NotificationListRefreshRequested());
        await pumpEventQueue();
        all.complete();
      },
      expect: () => [
        loaded([a.markedRead(openedAt)], markingAll: true),
        loaded(
          [a.markedRead(openedAt)],
          markingAll: true,
          refreshing: true,
        ),
        loaded([
          z.markedRead(openedAt),
          a.markedRead(openedAt),
        ], markingAll: true),
        loaded([z.markedRead(openedAt), a.markedRead(openedAt)]),
      ],
    );

    blocTest<NotificationListBloc, NotificationListState>(
      'a read sent after all marked read answered shows its rows as sent',
      build: build,
      seed: () => loaded([a]),
      act: (bloc) async {
        remote
          ..scriptMarkAllRead([null])
          ..scriptPages([
            // Arrived after the server marked them all.
            NotificationPage(items: [z, a.markedRead(openedAt)]),
          ]);
        bloc.add(const NotificationListAllMarkedRead());
        await pumpEventQueue();
        bloc.add(const NotificationListRefreshRequested());
      },
      expect: () => [
        loaded([a.markedRead(openedAt)], markingAll: true),
        loaded([a.markedRead(openedAt)]),
        loaded([a.markedRead(openedAt)], refreshing: true),
        loaded([z, a.markedRead(openedAt)]),
      ],
    );
  });
}
