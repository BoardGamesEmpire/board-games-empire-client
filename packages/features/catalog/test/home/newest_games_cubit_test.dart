import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/catalog_app.dart';
import '../support/fake_connectivity.dart';
import '../support/fake_games_remote.dart';

/// A games cache that remembers what it was asked, so that a test can say what
/// the shelf did and did not do to it.
class _RecordingCache extends FakeGamesCache {
  _RecordingCache([super.games]);

  /// Every write, by name.
  final List<String> writes = [];

  /// Every page read.
  final List<({int offset, int limit, GameSort sort})> pageReads = [];

  @override
  Future<void> cacheGames(List<Game> games) async => writes.add('cacheGames');

  @override
  Future<void> cacheGame(Game game) async => writes.add('cacheGame');

  @override
  Future<void> forgetCatalog() async => writes.add('forgetCatalog');

  @override
  Future<void> forgetGame(String id) async => writes.add('forgetGame');

  @override
  Future<List<Game>> getGamesPage({
    int offset = 0,
    required int limit,
    GameSort sort = GameSort.title,
  }) {
    pageReads.add((offset: offset, limit: limit, sort: sort));
    return super.getGamesPage(offset: offset, limit: limit, sort: sort);
  }
}

/// A cache whose reads fail.
class _BrokenCache extends _RecordingCache {
  @override
  Future<List<Game>> getGamesPage({
    int offset = 0,
    required int limit,
    GameSort sort = GameSort.title,
  }) => throw StateError('the session ended');
}

/// [count] games as the server sends them, newest first: `g-0` is the newest.
List<Game> _newest(int count) => [
  for (var n = 0; n < count; n++)
    game('g-$n').copyWith(createdAt: DateTime.utc(2026, 10, 30 - n)),
];

/// Lets everything already scheduled run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

List<String> _ids(NewestGamesState state) => switch (state) {
  NewestGamesReady(:final games) => [for (final g in games) g.id],
  _ => fail('expected games, got $state'),
};

void main() {
  late FakeGamesRemote remote;
  late FakeConnectivity connectivity;
  late _RecordingCache cache;

  /// Fails a test that forgets to say what the server answers.
  setUp(() {
    remote = FakeGamesRemote();
    connectivity = FakeConnectivity();
    cache = _RecordingCache();
  });

  // Not awaited: a cubit made under a fake clock leaves the fake's stream
  // waiting on microtasks that nothing runs once the test has ended.
  tearDown(() => unawaited(connectivity.close()));

  NewestGamesCubit build({
    bool withCache = true,
    bool withConnectivity = true,
    Stream<String>? gone,
  }) {
    final cubit = NewestGamesCubit(
      remote: remote,
      cache: withCache ? cache : null,
      connectivity: withConnectivity ? connectivity : null,
      gone: gone,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// Every state [cubit] emits from here on.
  List<NewestGamesState> record(NewestGamesCubit cubit) {
    final states = <NewestGamesState>[];
    final subscription = cubit.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  StreamController<String> goneStream() {
    final controller = StreamController<String>.broadcast();
    addTearDown(controller.close);
    return controller;
  }

  test('asks for the first 10 games, newest first', () async {
    remote.onFetchPage = (_, _) async => pageOf(_newest(3));
    final cubit = build();
    expect(cubit.state, const NewestGamesLoading());

    cubit.load();
    await _settle();

    expect(NewestGamesCubit.shelfSize, 10);
    expect(remote.calls, ['fetchPage(1, 10, newest)']);
    expect(cubit.state, NewestGamesReady(games: _newest(3)));
  });

  test('writes nothing to the cache, on any path', () async {
    final paths = <String, void Function()>{
      'an answer': () =>
          remote.onFetchPage = (_, _) async => pageOf(_newest(2)),
      'an empty answer': () => remote.onFetchPage = (_, _) async => pageOf([]),
      'a refusal': () =>
          remote.onFetchPage = (_, _) async =>
              throw const GamesForbiddenException('no'),
      'a failed read': () =>
          remote.onFetchPage = (_, _) async => throw unreachable(),
      'being offline': () => connectivity.current = ConnectivityState.offline,
    };

    for (final MapEntry(:key, :value) in paths.entries) {
      connectivity.current = ConnectivityState.online;
      value();
      final cubit = build()..load();
      await _settle();
      await cubit.close();
      expect(cache.writes, isEmpty, reason: key);
    }
  });

  test('an empty answer is Empty, whatever the cache holds', () async {
    cache = _RecordingCache(_newest(3));
    remote.onFetchPage = (_, _) async => pageOf([]);
    final cubit = build();

    cubit.load();
    await _settle();

    expect(cubit.state, const NewestGamesEmpty());
    expect(cache.pageReads, isEmpty);
  });

  test('a 403 is Denied, and reads nothing from the cache', () async {
    cache = _RecordingCache(_newest(3));
    remote.onFetchPage = (_, _) async =>
        throw const GamesForbiddenException('no');
    final cubit = build();

    cubit.load();
    await _settle();

    expect(cubit.state, const NewestGamesDenied());
    expect(cache.pageReads, isEmpty);
    expect(cache.writes, isEmpty, reason: 'a refusal forgets nothing');
  });

  test('a failed read shows the cache, newest first', () async {
    cache = _RecordingCache(_newest(12));
    remote.onFetchPage = (_, _) async => throw unreachable();
    final cubit = build();

    cubit.load();
    await _settle();

    expect(cubit.state, NewestGamesReady(games: _newest(10), fromCache: true));
    expect(cache.pageReads, [(offset: 0, limit: 10, sort: GameSort.newest)]);
  });

  group('a failed read with nothing to show is Failed, never Empty', () {
    final causes = <String, ({bool hasCache, _RecordingCache? cache})>{
      'an empty cache': (hasCache: true, cache: null),
      'no cache': (hasCache: false, cache: null),
      'a cache that cannot be read': (hasCache: true, cache: _BrokenCache()),
    };

    for (final MapEntry(:key, :value) in causes.entries) {
      test(key, () async {
        cache = value.cache ?? cache;
        remote.onFetchPage = (_, _) async => throw unreachable();
        final cubit = build(withCache: value.hasCache);
        final states = record(cubit);

        cubit.load();
        await _settle();

        expect(states, [const NewestGamesFailed()]);
      });
    }
  });

  test('offline: no request, the cache instead', () async {
    connectivity.current = ConnectivityState.offline;
    cache = _RecordingCache(_newest(12));
    final cubit = build();

    cubit.load();
    await _settle();

    expect(remote.calls, isEmpty);
    expect(cubit.state, NewestGamesReady(games: _newest(10), fromCache: true));
    expect(cache.pageReads, [(offset: 0, limit: 10, sort: GameSort.newest)]);
  });

  test('offline with nothing cached is Failed, never Empty', () async {
    connectivity.current = ConnectivityState.offline;
    final cubit = build();
    final states = record(cubit);

    cubit.load();
    await _settle();

    expect(remote.calls, isEmpty);
    expect(states, [const NewestGamesFailed()]);
  });

  test('a failed reload keeps the rows up', () async {
    cache = _RecordingCache(_newest(5));
    remote.onFetchPage = (_, _) async => pageOf(_newest(3));
    final cubit = build();
    cubit.load();
    await _settle();
    final states = record(cubit);

    remote.onFetchPage = (_, _) async => throw unreachable();
    cubit.load();
    await _settle();

    expect(remote.calls, hasLength(2));
    expect(cubit.state, NewestGamesReady(games: _newest(3)));
    expect(states, isEmpty);
    expect(cache.pageReads, isEmpty, reason: 'the server rows are fresher');
  });

  test('a reload leaves the state alone until its answer lands', () async {
    remote.onFetchPage = (_, _) async => pageOf(_newest(1));
    final cubit = build();
    cubit.load();
    await _settle();
    final states = record(cubit);

    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => answer.future;
    cubit.load();
    await _settle();
    expect(states, isEmpty);
    expect(_ids(cubit.state), ['g-0']);

    answer.complete(pageOf(_newest(2)));
    await _settle();
    expect(_ids(cubit.state), ['g-0', 'g-1']);
  });

  test('a failed read after a refusal stays refused', () async {
    cache = _RecordingCache(_newest(3));
    remote.onFetchPage = (_, _) async =>
        throw const GamesForbiddenException('no');
    final cubit = build();
    cubit.load();
    await _settle();

    remote.onFetchPage = (_, _) async => throw unreachable();
    cubit.load();
    await _settle();

    expect(cubit.state, const NewestGamesDenied());
    expect(cache.pageReads, isEmpty);
  });

  test('going offline keeps the rows from the server', () async {
    cache = _RecordingCache(_newest(5));
    remote.onFetchPage = (_, _) async => pageOf(_newest(3));
    final cubit = build();
    cubit.load();
    await _settle();

    connectivity.change(ConnectivityState.offline);
    await _settle();

    expect(remote.calls, hasLength(1));
    expect(cubit.state, NewestGamesReady(games: _newest(3)));
    expect(cache.pageReads, isEmpty);
  });

  test('going offline drops a read in flight', () async {
    cache = _RecordingCache(_newest(2));
    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => answer.future;
    final cubit = build();
    cubit.load();
    await _settle();

    connectivity.change(ConnectivityState.offline);
    await _settle();
    answer.complete(pageOf(_newest(5)));
    await _settle();

    expect(cubit.state, NewestGamesReady(games: _newest(2), fromCache: true));
  });

  test('reconnecting reads again', () async {
    connectivity.current = ConnectivityState.offline;
    cache = _RecordingCache(_newest(2));
    remote.onFetchPage = (_, _) async => pageOf(_newest(4));
    final cubit = build();
    cubit.load();
    await _settle();
    expect(remote.calls, isEmpty);
    expect(cubit.state, NewestGamesReady(games: _newest(2), fromCache: true));

    connectivity.change(ConnectivityState.online);
    await _settle();

    expect(remote.calls, ['fetchPage(1, 10, newest)']);
    expect(cubit.state, NewestGamesReady(games: _newest(4)));
  });

  test('a replayed connectivity state is not a change', () async {
    remote.onFetchPage = (_, _) async => pageOf(_newest(1));
    final cubit = build();

    cubit.load();
    // Time for the service's replay of its current state to arrive.
    await _settle();
    await _settle();
    expect(remote.calls, hasLength(1));

    connectivity.change(ConnectivityState.online);
    await _settle();
    expect(remote.calls, hasLength(1), reason: 'online to online');

    connectivity.change(ConnectivityState.unknown);
    await _settle();
    expect(remote.calls, hasLength(1), reason: 'unknown says nothing new');
  });

  group('a game found gone', () {
    test('comes down, and stays down after a reload that repeats it', () async {
      final gone = goneStream();
      remote.onFetchPage = (_, _) async => pageOf(_newest(3));
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();

      gone.add('g-1');
      await _settle();
      expect(_ids(cubit.state), ['g-0', 'g-2']);

      cubit.load();
      await _settle();
      expect(remote.calls, hasLength(2));
      expect(_ids(cubit.state), ['g-0', 'g-2']);
    });

    test('is not shown by a read already on its way', () async {
      final gone = goneStream();
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();

      gone.add('g-1');
      await _settle();
      answer.complete(pageOf(_newest(3)));
      await _settle();

      expect(_ids(cubit.state), ['g-0', 'g-2']);
    });

    test('comes down from the cache rows too', () async {
      final gone = goneStream();
      cache = _RecordingCache(_newest(3));
      remote.onFetchPage = (_, _) async => throw unreachable();
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();

      gone.add('g-0');
      await _settle();

      expect(
        cubit.state,
        NewestGamesReady(games: _newest(3).skip(1).toList(), fromCache: true),
      );
    });

    test('one the shelf does not show changes nothing', () async {
      final gone = goneStream();
      remote.onFetchPage = (_, _) async => pageOf(_newest(2));
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();
      final states = record(cubit);

      gone.add('elsewhere');
      await _settle();

      expect(states, isEmpty);
    });

    test('the last row gone reads again rather than saying Empty', () async {
      final gone = goneStream();
      remote.onFetchPage = (_, _) async => pageOf(_newest(1));
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();
      final states = record(cubit);

      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;
      gone.add('g-0');
      await _settle();

      expect(remote.calls, hasLength(2));
      expect(cubit.state, const NewestGamesLoading());
      expect(states, [const NewestGamesLoading()]);

      answer.complete(pageOf(_newest(3).skip(1).toList()));
      await _settle();
      expect(_ids(cubit.state), ['g-1', 'g-2']);
      expect(states, isNot(contains(const NewestGamesEmpty())));
    });

    test('the last row gone, then an empty answer, is Empty', () async {
      final gone = goneStream();
      remote.onFetchPage = (_, _) async => pageOf(_newest(1));
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();

      remote.onFetchPage = (_, _) async => pageOf([]);
      gone.add('g-0');
      await _settle();

      expect(cubit.state, const NewestGamesEmpty());
    });

    test('the last row gone, with the same one answered, is Failed', () async {
      final gone = goneStream();
      remote.onFetchPage = (_, _) async => pageOf(_newest(1));
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();
      final states = record(cubit);

      gone.add('g-0');
      await _settle();

      expect(states, [const NewestGamesLoading(), const NewestGamesFailed()]);
    });
  });

  test('an answer whose rows are all gone is Failed, never Empty', () async {
    final gone = goneStream();
    final answer = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => answer.future;
    final cubit = build(gone: gone.stream);
    final states = record(cubit);
    cubit.load();
    await _settle();

    gone.add('g-0');
    gone.add('g-1');
    await _settle();
    answer.complete(pageOf(_newest(2)));
    await _settle();

    expect(states, [const NewestGamesFailed()]);
  });

  test('cached rows that are all gone are Failed, never Empty', () async {
    final gone = goneStream();
    cache = _RecordingCache(_newest(1));
    remote.onFetchPage = (_, _) async => throw unreachable();
    final cubit = build(gone: gone.stream);
    gone.add('g-0');
    final states = record(cubit);

    cubit.load();
    await _settle();

    expect(states, [const NewestGamesFailed()]);
  });

  test('a late answer after a newer load is discarded', () async {
    final first = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => first.future;
    final cubit = build();
    final states = record(cubit);
    cubit.load();
    await _settle();

    remote.onFetchPage = (_, _) async => pageOf(_newest(2));
    cubit.load();
    await _settle();
    first.complete(pageOf(_newest(5)));
    await _settle();

    expect(_ids(cubit.state), ['g-0', 'g-1']);
    expect(states, hasLength(1));
  });

  test('a late failure after a newer load is discarded', () async {
    final first = Completer<PaginatedResult<Game>>();
    remote.onFetchPage = (_, _) => first.future;
    final cubit = build();
    cubit.load();
    await _settle();

    remote.onFetchPage = (_, _) async => pageOf(_newest(2));
    cubit.load();
    await _settle();
    first.completeError(unreachable());
    await _settle();

    expect(_ids(cubit.state), ['g-0', 'g-1']);
    expect(cache.pageReads, isEmpty);
  });

  // Under fake time, since a retry's state is held for a stretch of it.
  group('retry', () {
    const dwell = NewestGamesCubit.retryDwell;
    final justUnder = dwell - const Duration(milliseconds: 1);

    /// A cubit under the test's fake clock. Closing it cancels its timer at
    /// once, and the rest waits on microtasks that only a pump runs, so it is
    /// not awaited.
    NewestGamesCubit buildFake() {
      final cubit = NewestGamesCubit(
        remote: remote,
        cache: cache,
        connectivity: connectivity,
      );
      addTearDown(() => unawaited(cubit.close()));
      return cubit;
    }

    List<NewestGamesState> recordFake(NewestGamesCubit cubit) {
      final states = <NewestGamesState>[];
      cubit.stream.listen(states.add);
      return states;
    }

    /// A cubit that has failed, with nothing saved to show instead.
    Future<NewestGamesCubit> failed(WidgetTester tester) async {
      remote.onFetchPage = (_, _) async => throw unreachable();
      final cubit = buildFake();
      cubit.load();
      await tester.pump();
      expect(cubit.state, const NewestGamesFailed());
      return cubit;
    }

    testWidgets('says it is retrying, and fails again only after the dwell', (
      tester,
    ) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);

      cubit.retry();
      await tester.pump();
      expect(remote.calls, hasLength(2));
      expect(states, [const NewestGamesFailed(retrying: true)]);

      await tester.pump(justUnder);
      expect(states, [const NewestGamesFailed(retrying: true)]);

      await tester.pump(const Duration(milliseconds: 1));
      expect(states, [
        const NewestGamesFailed(retrying: true),
        const NewestGamesFailed(),
      ]);
    });

    testWidgets('says so even when the answer is already known', (
      tester,
    ) async {
      // Offline with nothing saved: the read answers without waiting on
      // anything, in the turn it begins.
      connectivity.current = ConnectivityState.offline;
      final cubit = buildFake();
      cubit.load();
      await tester.pump();
      expect(cubit.state, const NewestGamesFailed());
      final states = recordFake(cubit);

      cubit.retry();
      await tester.pump();
      expect(states, [const NewestGamesFailed(retrying: true)]);
      expect(remote.calls, isEmpty);

      await tester.pump(dwell);
      expect(states, [
        const NewestGamesFailed(retrying: true),
        const NewestGamesFailed(),
      ]);
    });

    testWidgets('an answer inside the dwell waits for the rest of it', (
      tester,
    ) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);
      remote.onFetchPage = (_, _) async => pageOf(_newest(2));

      cubit.retry();
      await tester.pump(justUnder);
      expect(states, [const NewestGamesFailed(retrying: true)]);

      await tester.pump(const Duration(milliseconds: 1));
      expect(states, [
        const NewestGamesFailed(retrying: true),
        NewestGamesReady(games: _newest(2)),
      ]);
    });

    testWidgets('an answer after the dwell is not held any longer', (
      tester,
    ) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;

      cubit.retry();
      await tester.pump(dwell * 3);
      expect(states, [const NewestGamesFailed(retrying: true)]);

      answer.complete(pageOf(_newest(1)));
      await tester.pump();
      expect(states, [
        const NewestGamesFailed(retrying: true),
        NewestGamesReady(games: _newest(1)),
      ]);
    });

    testWidgets('a press while it dwells or reads is ignored', (tester) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);

      cubit.retry();
      await tester.pump(const Duration(milliseconds: 100));
      cubit.retry();
      await tester.pump(dwell);
      expect(remote.calls, hasLength(2));
      expect(states, [
        const NewestGamesFailed(retrying: true),
        const NewestGamesFailed(),
      ]);

      // And it works again once the read has finished.
      cubit.retry();
      await tester.pump(dwell);
      expect(remote.calls, hasLength(3));
    });

    testWidgets('a second press does not start the dwell over', (tester) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;

      cubit.retry();
      await tester.pump(const Duration(milliseconds: 100));
      cubit.retry();
      await tester.pump(const Duration(milliseconds: 100));
      answer.completeError(unreachable());
      await tester.pump(const Duration(milliseconds: 99));
      expect(states, [const NewestGamesFailed(retrying: true)]);

      // 300ms after the first press, not after the second.
      await tester.pump(const Duration(milliseconds: 1));
      expect(states, [
        const NewestGamesFailed(retrying: true),
        const NewestGamesFailed(),
      ]);
    });

    testWidgets('a read begun by something else stays quiet, and is not held', (
      tester,
    ) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;

      cubit.load();
      await tester.pump();
      expect(remote.calls, hasLength(2));
      expect(states, isEmpty);

      answer.complete(pageOf(_newest(1)));
      await tester.pump();
      expect(states, [NewestGamesReady(games: _newest(1))]);
    });

    testWidgets('a read begun by something else is the one it reports', (
      tester,
    ) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;
      cubit.load();
      await tester.pump();

      cubit.retry();
      await tester.pump();
      expect(remote.calls, hasLength(2), reason: 'it asks nothing more');
      expect(states, [const NewestGamesFailed(retrying: true)]);

      // Answered at once, it still waits out the dwell before replacing it.
      answer.completeError(unreachable());
      await tester.pump(justUnder);
      expect(states, [const NewestGamesFailed(retrying: true)]);

      await tester.pump(const Duration(milliseconds: 1));
      expect(states.last, const NewestGamesFailed());
      expect(states, hasLength(2));
    });

    testWidgets('stays retrying until the read that counts answers', (
      tester,
    ) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);
      final first = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => first.future;
      cubit.retry();
      await tester.pump();

      final second = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => second.future;
      cubit.load();
      await tester.pump();
      first.completeError(unreachable());
      await tester.pump(dwell);
      expect(states, [const NewestGamesFailed(retrying: true)]);

      second.completeError(unreachable());
      await tester.pump();
      expect(states.last, const NewestGamesFailed());
    });

    testWidgets('after close asks for nothing', (tester) async {
      final cubit = await failed(tester);
      unawaited(cubit.close());
      // Closing waits on a stream's cancel, which completes on the real event
      // loop, then in the fake one.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(cubit.isClosed, isTrue);

      cubit.retry();
      await tester.pump(dwell);

      expect(remote.calls, hasLength(1));
    });

    testWidgets('closing during the dwell leaves nothing running', (
      tester,
    ) async {
      final cubit = await failed(tester);
      final states = recordFake(cubit);

      cubit.retry();
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(cubit.close());

      // Ends here, with the dwell not yet over: the test binding fails a test
      // that leaves a timer pending.
      expect(states, [const NewestGamesFailed(retrying: true)]);
    });
  });

  group('after close', () {
    test('an answer emits nothing and throws nothing', () async {
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;
      final cubit = build();
      cubit.load();
      await _settle();

      await cubit.close();
      answer.complete(pageOf(_newest(1)));
      await _settle();

      expect(cubit.isClosed, isTrue);
      expect(cubit.state, const NewestGamesLoading());
    });

    test('a failure emits nothing and throws nothing', () async {
      final answer = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => answer.future;
      final cubit = build();
      cubit.load();
      await _settle();

      await cubit.close();
      answer.completeError(unreachable());
      await _settle();

      expect(cubit.state, const NewestGamesLoading());
    });

    test('the streams are no longer heard', () async {
      final gone = goneStream();
      remote.onFetchPage = (_, _) async => pageOf(_newest(2));
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();

      await cubit.close();
      gone.add('g-0');
      connectivity.change(ConnectivityState.offline);
      connectivity.change(ConnectivityState.online);
      await _settle();

      expect(remote.calls, hasLength(1));
      expect(cubit.state, NewestGamesReady(games: _newest(2)));
    });

    test('a game found gone as it closes asks for nothing', () async {
      final gone = goneStream();
      remote.onFetchPage = (_, _) async => pageOf(_newest(1));
      final cubit = build(gone: gone.stream);
      cubit.load();
      await _settle();
      final states = record(cubit);

      // The last row going would read again, but the event is still on its
      // way when the close begins.
      gone.add('g-0');
      await cubit.close();
      await _settle();

      expect(remote.calls, hasLength(1));
      expect(states, isEmpty);
    });

    test('load asks for nothing', () async {
      final cubit = build();
      await cubit.close();

      cubit.load();
      await _settle();

      expect(remote.calls, isEmpty);
    });
  });
}
