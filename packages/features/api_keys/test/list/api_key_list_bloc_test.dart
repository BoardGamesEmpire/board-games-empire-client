import 'dart:async';

import 'package:api_keys/api_keys.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fixtures.dart';

void main() {
  late MockApiKeyRemoteDataSource remote;

  final a = apiKey('k_a');
  final b = apiKey('k_b', enabled: false);
  final c = apiKey('k_c');
  final d = apiKey('k_d', enabled: false);
  final read = permission('collection:read');

  setUp(() {
    remote = MockApiKeyRemoteDataSource();
    answerGrantable(remote, [read]);
  });

  ApiKeyListBloc build() => ApiKeyListBloc(remote);

  /// The state once page 1 holds [keys], with [read] grantable.
  ApiKeyListState loaded(List<ApiKey> keys, {bool hasMore = false}) =>
      ApiKeyListState(
        status: ApiKeyListStatus.loaded,
        keys: keys,
        hasMore: hasMore,
        grantable: {read.slug: read},
      );

  test('the bloc starts loading, under All', () {
    final bloc = build();
    addTearDown(bloc.close);
    expect(bloc.state.status, ApiKeyListStatus.loading);
    expect(bloc.state.filter, ApiKeyStatusFilter.all);
    expect(bloc.state.keys, isEmpty);
  });

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'requested loads page 1',
    setUp: () => answerPage(remote, [a, b], hasMore: true),
    build: build,
    act: (bloc) => bloc.add(const ApiKeyListRequested()),
    expect: () => [
      loaded([a, b], hasMore: true),
    ],
    verify: (_) {
      verify(
        () => remote.fetchPage(),
      ).called(1);
      verify(remote.fetchGrantable).called(1);
    },
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'grantable is read alongside page 1, not after it',
    build: build,
    act: (bloc) async {
      final page = Completer<PaginatedResult<ApiKey>>();
      when(
        () => remote.fetchPage(limit: any(named: 'limit')),
      ).thenAnswer((_) => page.future);
      bloc.add(const ApiKeyListRequested());
      await pumpEventQueue();
      // Page 1 has not answered, and both were asked for.
      verify(() => remote.fetchPage(limit: any(named: 'limit'))).called(1);
      verify(remote.fetchGrantable).called(1);
      page.complete(pageOf([a]));
    },
    expect: () => [
      loaded([a]),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a grantable failure still loads the list with counts only',
    setUp: () {
      answerPage(remote, [a]);
      when(
        remote.fetchGrantable,
      ).thenThrow(const ApiKeyTransientException('down'));
    },
    build: build,
    act: (bloc) => bloc.add(const ApiKeyListRequested()),
    expect: () => [
      ApiKeyListState(status: ApiKeyListStatus.loaded, keys: [a]),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a page 1 failure is a load failure',
    setUp: () => when(
      () => remote.fetchPage(limit: any(named: 'limit')),
    ).thenThrow(const ApiKeyTransientException('down')),
    build: build,
    act: (bloc) => bloc.add(const ApiKeyListRequested()),
    expect: () => [
      const ApiKeyListState(
        status: ApiKeyListStatus.loadFailed,
        loadFailure: ApiKeyFailure(ApiKeyFailureReason.transient),
      ),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    "a load failure keeps why, with the server's words, and a read again "
    'drops it',
    setUp: () {
      var calls = 0;
      when(() => remote.fetchPage(limit: any(named: 'limit'))).thenAnswer((
        _,
      ) async {
        if (calls++ == 0) {
          throw const ApiKeyPermanentException(
            'refused',
            statusCode: 400,
            apiMessage: 'Listing keys is switched off on this server',
          );
        }
        return pageOf([a]);
      });
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListRequested());
    },
    expect: () => [
      const ApiKeyListState(
        status: ApiKeyListStatus.loadFailed,
        loadFailure: ApiKeyFailure(
          ApiKeyFailureReason.generic,
          serverMessage: 'Listing keys is switched off on this server',
        ),
      ),
      const ApiKeyListState(),
      loaded([a]),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'more appends page 2 and stops at hasMore false',
    setUp: () {
      answerPage(remote, [a, b], hasMore: true);
      answerPage(remote, [c, d], page: 2);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
      await Future<void>.delayed(Duration.zero);
      // Nothing more to read: this one sends nothing.
      bloc.add(const ApiKeyListMoreRequested());
    },
    expect: () => [
      loaded([a, b], hasMore: true),
      loaded([a, b], hasMore: true).copyWith(loadingMore: true),
      loaded([a, b, c, d]),
    ],
    verify: (_) {
      verify(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).called(1);
      // More re-reads no grantable list.
      verify(remote.fetchGrantable).called(1);
    },
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a key that moved onto the next page is not listed twice',
    setUp: () {
      answerPage(remote, [a, b], hasMore: true);
      // A key made meanwhile pushed b down onto page 2, and one removed
      // left the count as it was.
      answerPage(remote, [b, c], page: 2);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
    },
    skip: 2,
    expect: () => [
      loaded([a, b, c]),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a failed more keeps the loaded keys and sets moreFailed',
    setUp: () {
      answerPage(remote, [a, b], hasMore: true);
      when(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).thenThrow(const ApiKeyTransientException('down'));
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
    },
    expect: () => [
      loaded([a, b], hasMore: true),
      loaded([a, b], hasMore: true).copyWith(loadingMore: true),
      loaded([a, b], hasMore: true).copyWith(moreFailed: true),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'more after a failed more asks for the same page again',
    setUp: () {
      answerPage(remote, [a], hasMore: true);
      var calls = 0;
      when(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).thenAnswer((_) async {
        if (calls++ == 0) throw const ApiKeyTransientException('down');
        return pageOf([c], page: 2);
      });
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
    },
    skip: 3,
    expect: () => [
      loaded([a], hasMore: true).copyWith(loadingMore: true),
      loaded([a, c]),
    ],
    verify: (_) => verify(
      () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
    ).called(2),
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'filter enabled shows only enabled keys and keeps the loaded pages',
    setUp: () {
      answerPage(remote, [a, b], hasMore: true);
      answerPage(remote, [c, d], page: 2);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListFilterChanged(ApiKeyStatusFilter.enabled));
    },
    skip: 3,
    expect: () => [
      loaded([a, b, c, d]).copyWith(filter: ApiKeyStatusFilter.enabled),
    ],
    verify: (bloc) {
      expect(bloc.state.visible, [a, c]);
      // The filter is over the loaded pages: it reads nothing.
      verify(
        () => remote.fetchPage(limit: any(named: 'limit')),
      ).called(1);
      verify(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).called(1);
      verify(remote.fetchGrantable).called(1);
      verifyNoMoreInteractions(remote);
    },
  );

  test('filter disabled shows only disabled keys, and All every key', () {
    final state = loaded([a, b, c, d]);
    expect(
      state.copyWith(filter: ApiKeyStatusFilter.disabled).visible,
      [b, d],
    );
    expect(state.visible, [a, b, c, d]);
  });

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'requested again reads every page loaded again, and replaces the list',
    setUp: () {
      answerPage(remote, [a, b], hasMore: true);
      answerPage(remote, [c, d], page: 2, hasMore: true);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
      await Future<void>.delayed(Duration.zero);
      // b was deleted elsewhere, which moved c onto page 1.
      answerPage(remote, [a, c], hasMore: true, total: 3);
      answerPage(remote, [d], page: 2, total: 3);
      bloc.add(const ApiKeyListRequested());
    },
    skip: 3,
    expect: () => [
      // The rows stay while the list is read again.
      loaded([a, b, c, d], hasMore: true).copyWith(refreshing: true),
      // d, on page 2, keeps its row.
      loaded([a, c, d]),
    ],
    verify: (_) {
      verify(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).called(2);
      verify(remote.fetchGrantable).called(2);
    },
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a page read again that has gone is no row and no More',
    setUp: () {
      answerPage(remote, [a], hasMore: true);
      answerPage(remote, [b], page: 2);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
      await Future<void>.delayed(Duration.zero);
      // b was deleted elsewhere, so page 2 is empty now.
      answerPage(remote, [a], total: 1);
      answerPage(remote, const [], page: 2, total: 1);
      bloc.add(const ApiKeyListRequested());
    },
    skip: 4,
    expect: () => [
      loaded([a]),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a More whose count moved reads every page up to its own again',
    setUp: () {
      answerPage(remote, [a, b], hasMore: true, total: 4);
      // b was deleted elsewhere, which moved c up onto page 1: page 2 alone
      // would skip it.
      answerPage(remote, [d], page: 2, total: 3);
    },
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      answerPage(remote, [a, c], hasMore: true, total: 3);
      bloc.add(const ApiKeyListMoreRequested());
    },
    skip: 1,
    expect: () => [
      loaded([a, b], hasMore: true).copyWith(loadingMore: true),
      loaded([a, c, d]),
    ],
    verify: (_) {
      verify(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).called(2);
      // The pages, not the grantable list.
      verify(remote.fetchGrantable).called(1);
    },
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'after a More whose count moved, the next More follows on from it',
    // One key a page, to keep the pages short.
    setUp: () => answerPage(remote, [a], hasMore: true, total: 3),
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      // b was made elsewhere, newest of all, which moved a down to page 2.
      answerPage(remote, [b], hasMore: true, total: 4);
      answerPage(remote, [a], page: 2, hasMore: true, total: 4);
      answerPage(remote, [c], page: 3, hasMore: true, total: 4);
      bloc.add(const ApiKeyListMoreRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
    },
    skip: 1,
    expect: () => [
      loaded([a], hasMore: true).copyWith(loadingMore: true),
      loaded([b, a], hasMore: true),
      loaded([b, a], hasMore: true).copyWith(loadingMore: true),
      loaded([b, a, c], hasMore: true),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a failed re-read keeps the rows and says the refresh failed',
    setUp: () => answerPage(remote, [a, b], hasMore: true),
    build: build,
    act: (bloc) async {
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      when(
        () => remote.fetchPage(limit: any(named: 'limit')),
      ).thenThrow(const ApiKeyTransientException('down'));
      bloc.add(const ApiKeyListRequested());
    },
    skip: 1,
    expect: () => [
      loaded([a, b], hasMore: true).copyWith(refreshing: true),
      loaded([a, b], hasMore: true).copyWith(refreshFailed: true),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a refresh that succeeds after a failed one clears the failure',
    setUp: () => answerPage(remote, [a]),
    build: build,
    seed: () => loaded([a, b]).copyWith(refreshFailed: true),
    act: (bloc) => bloc.add(const ApiKeyListRequested()),
    expect: () => [
      // The banner stays while the retry runs, saying it is refreshing.
      loaded([a, b]).copyWith(refreshFailed: true, refreshing: true),
      loaded([a]),
    ],
  );

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'a more out across a failed re-read still lands on the rows shown',
    build: build,
    setUp: () => answerPage(remote, [a], hasMore: true),
    act: (bloc) async {
      final more = Completer<PaginatedResult<ApiKey>>();
      when(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).thenAnswer((_) => more.future);
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const ApiKeyListMoreRequested());
      await Future<void>.delayed(Duration.zero);
      when(
        () => remote.fetchPage(limit: any(named: 'limit')),
      ).thenThrow(const ApiKeyTransientException('down'));
      bloc.add(const ApiKeyListRequested());
      await Future<void>.delayed(Duration.zero);
      more.complete(pageOf([c], page: 2));
      await Future<void>.delayed(Duration.zero);
    },
    skip: 4,
    // The re-read replaced nothing, so the page it was paging through is
    // still the one on screen, and More settles rather than spinning on.
    expect: () => [
      loaded([a, c]).copyWith(refreshFailed: true),
    ],
  );

  group('answers that land late', () {
    late Completer<PaginatedResult<ApiKey>> held;

    setUp(() => held = Completer<PaginatedResult<ApiKey>>());

    blocTest<ApiKeyListBloc, ApiKeyListState>(
      'the last of two overlapping reads stands',
      build: build,
      setUp: () {
        var calls = 0;
        when(
          () => remote.fetchPage(limit: any(named: 'limit')),
        ).thenAnswer((_) {
          if (calls++ == 0) return held.future;
          return Future.value(pageOf([c]));
        });
      },
      act: (bloc) async {
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        // The first answers last, with what the server held before.
        held.complete(pageOf([a, b]));
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        loaded([c]),
      ],
    );

    blocTest<ApiKeyListBloc, ApiKeyListState>(
      'More can be pressed again at once after a re-read dropped the last',
      build: build,
      setUp: () {
        answerPage(remote, [a], hasMore: true);
        var calls = 0;
        when(
          () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
        ).thenAnswer((_) {
          // The first More hangs on a slow connection.
          if (calls++ == 0) return held.future;
          return Future.value(pageOf([c], page: 2));
        });
      },
      act: (bloc) async {
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyListMoreRequested());
        await Future<void>.delayed(Duration.zero);
        answerPage(remote, [b], hasMore: true);
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        // The re-read has answered while the first More is still out.
        bloc.add(const ApiKeyListMoreRequested());
        await Future<void>.delayed(Duration.zero);
        held.complete(pageOf([d], page: 2));
        await Future<void>.delayed(Duration.zero);
      },
      skip: 4,
      expect: () => [
        loaded([b], hasMore: true).copyWith(loadingMore: true),
        loaded([b, c]),
      ],
      verify: (_) => verify(
        () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
      ).called(2),
    );

    blocTest<ApiKeyListBloc, ApiKeyListState>(
      'a More while the pages are read again ends one still out',
      build: build,
      setUp: () {
        answerPage(remote, [a], hasMore: true);
        when(
          () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
        ).thenAnswer((_) => held.future);
      },
      act: (bloc) async {
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyListMoreRequested());
        await Future<void>.delayed(Duration.zero);
        final reread = Completer<PaginatedResult<ApiKey>>();
        when(
          () => remote.fetchPage(limit: any(named: 'limit')),
        ).thenAnswer((_) => reread.future);
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        // Pressed in code: the button is inert while the pages are read.
        bloc.add(const ApiKeyListMoreRequested());
        await Future<void>.delayed(Duration.zero);
        reread.completeError(const ApiKeyTransientException('down'));
        await Future<void>.delayed(Duration.zero);
        held.complete(pageOf([c], page: 2));
        await Future<void>.delayed(Duration.zero);
      },
      skip: 2,
      // The refresh failed, and More is ready to be pressed again rather
      // than saying it loads a page nothing is waiting for.
      expect: () => [
        loaded([a], hasMore: true).copyWith(
          loadingMore: true,
          refreshing: true,
        ),
        loaded([a], hasMore: true).copyWith(refreshing: true),
        loaded([a], hasMore: true).copyWith(refreshFailed: true),
      ],
    );

    blocTest<ApiKeyListBloc, ApiKeyListState>(
      'a more that answers while the pages are read again adds nothing',
      build: build,
      setUp: () {
        answerPage(remote, [a], hasMore: true);
        when(
          () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
        ).thenAnswer((_) => held.future);
      },
      act: (bloc) async {
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyListMoreRequested());
        await Future<void>.delayed(Duration.zero);
        final reread = Completer<PaginatedResult<ApiKey>>();
        when(
          () => remote.fetchPage(limit: any(named: 'limit')),
        ).thenAnswer((_) => reread.future);
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        // More answers first. The re-read only asked for page 1, so rows
        // added now would vanish when it lands.
        held.complete(pageOf([c], page: 2));
        await Future<void>.delayed(Duration.zero);
        reread.complete(pageOf([a], hasMore: true));
        await Future<void>.delayed(Duration.zero);
      },
      skip: 2,
      expect: () => [
        loaded([a], hasMore: true).copyWith(
          loadingMore: true,
          refreshing: true,
        ),
        loaded([a], hasMore: true).copyWith(refreshing: true),
        loaded([a], hasMore: true),
      ],
    );

    blocTest<ApiKeyListBloc, ApiKeyListState>(
      'a more that answers after a re-read adds nothing to it',
      build: build,
      setUp: () {
        answerPage(remote, [a], hasMore: true);
        when(
          () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
        ).thenAnswer((_) => held.future);
      },
      act: (bloc) async {
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const ApiKeyListMoreRequested());
        await Future<void>.delayed(Duration.zero);
        answerPage(remote, [b]);
        bloc.add(const ApiKeyListRequested());
        await Future<void>.delayed(Duration.zero);
        held.complete(pageOf([c], page: 2));
        await Future<void>.delayed(Duration.zero);
      },
      skip: 2,
      expect: () => [
        loaded([a], hasMore: true).copyWith(
          loadingMore: true,
          refreshing: true,
        ),
        loaded([b]),
      ],
    );
  });

  blocTest<ApiKeyListBloc, ApiKeyListState>(
    'more while page 1 is out sends nothing',
    build: build,
    setUp: () => answerPage(remote, [a], hasMore: true),
    act: (bloc) => bloc
      ..add(const ApiKeyListRequested())
      ..add(const ApiKeyListMoreRequested()),
    expect: () => [
      loaded([a], hasMore: true),
    ],
    verify: (_) => verifyNever(
      () => remote.fetchPage(page: 2, limit: any(named: 'limit')),
    ),
  );
}
