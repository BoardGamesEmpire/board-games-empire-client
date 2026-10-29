import 'dart:async';

import 'package:di/di.dart' show LocalClockService;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_collection_remote.dart';

const _kUserId = 'user-abc';

/// Server row [n]: entry `gc-n` on platform game `pg-n` of game `g-n`.
GameCollectionWithSummary _row(
  int n, {
  DateTime? updatedAt,
  DateTime? deletedAt,
  int quantity = 1,
  String userId = _kUserId,
}) => (
  entry: GameCollection(
    id: 'gc-$n',
    userId: userId,
    platformGameId: 'pg-$n',
    medium: GameMedium.physical,
    quantity: quantity,
    deletedAt: deletedAt,
    createdAt: DateTime.utc(2026),
    updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
  ),
  summary: PlatformGameSummary(
    id: 'pg-$n',
    platformId: 'plat-1',
    platformName: 'Tabletop',
    game: GameSummary(id: 'g-$n', title: 'Game $n'),
  ),
);

PaginatedResult<GameCollectionWithSummary> _page(
  List<GameCollectionWithSummary> rows, {
  int page = 1,
  int limit = 100,
  int? total,
  int? totalPages,
  bool hasMore = false,
}) {
  final count = total ?? rows.length;
  return PaginatedResult(
    items: rows,
    meta: PaginationMeta(
      page: page,
      limit: limit,
      total: count,
      totalPages: totalPages ?? (count / limit).ceil(),
      hasMore: hasMore,
    ),
  );
}

/// One hydrate pass: how it ended, and the requests it sent.
typedef _Pass = ({
  CollectionHydrateOutcome outcome,
  List<CollectionListRequest> requests,
});

void main() {
  late ServerDatabase db;
  late GameRepositoryImpl games;
  late SyncQueueRepositoryImpl queue;
  late GameCollectionRepositoryImpl collection;

  GameCollectionRepositoryImpl openCollection() => GameCollectionRepositoryImpl(
    db: db,
    syncQueue: queue,
    currentUserId: _kUserId,
    clock: const LocalClockService(),
  );

  setUp(() {
    db = inMemoryServerDatabase();
    games = GameRepositoryImpl(db, userId: _kUserId);
    queue = SyncQueueRepositoryImpl(
      db,
      const LocalClockService(),
      userId: _kUserId,
    );
    collection = openCollection();
  });

  tearDown(() async => db.close());

  GameCollectionHydrator build(
    FakeCollectionRemote remote, {
    int limit = 100,
  }) => GameCollectionHydrator(
    collection: collection,
    games: games,
    remote: remote,
    userId: _kUserId,
    limit: limit,
  );

  Future<List<String>> listedTitles() async => [
    for (final item in await collection.watchCollectionListItems().first)
      item.title,
  ];

  group('a hydrate into an empty cache (#259)', () {
    // The regression this issue exists for: the collection row's foreign key
    // onto its platform game failed every row of a fresh device.
    test('stores every entry, with the title its summary carries', () async {
      final remote = FakeCollectionRemote((_) => _page([_row(1), _row(2)]));

      final outcome = await build(remote).hydrate();

      expect(outcome, CollectionHydrateOutcome.complete);
      expect(await listedTitles(), ['Game 1', 'Game 2']);
    });

    test('asks for page 1 at the page-size cap, tombstones included', () async {
      final remote = FakeCollectionRemote((_) => _page(const []));

      await build(remote).hydrate();

      expect(remote.requests, [
        (page: 1, limit: 100, includeDeleted: true, updatedSince: null),
      ]);
    });

    test('an empty collection is complete', () async {
      final remote = FakeCollectionRemote((_) => _page(const []));

      expect(await build(remote).hydrate(), CollectionHydrateOutcome.complete);
      expect(await listedTitles(), isEmpty);
    });
  });

  group('the drain', () {
    test('follows hasMore across pages and stores all of them', () async {
      final remote = FakeCollectionRemote(
        (r) => switch ((r.page, r.updatedSince)) {
          (1, null) => _page(
            [_row(1), _row(2)],
            limit: 2,
            total: 3,
            hasMore: true,
          ),
          (2, null) => _page([_row(3)], page: 2, limit: 2, total: 3),
          _ => _page(const [], limit: 2),
        },
      );

      await build(remote, limit: 2).hydrate();

      expect(await listedTitles(), ['Game 1', 'Game 2', 'Game 3']);
    });

    test('a server tombstone takes the entry off the list', () async {
      await build(FakeCollectionRemote((_) => _page([_row(1)]))).hydrate();

      await build(
        FakeCollectionRemote(
          (_) => _page([_row(1, deletedAt: DateTime.utc(2026, 3))]),
        ),
      ).hydrate();

      expect(await listedTitles(), isEmpty);
    });

    test('a tombstone the cache never held caches no game for it', () async {
      // A tombstone never inserts an entry, so the foreign key needs no
      // parent, and caching one would fill a fresh device with a game for
      // every entry the user ever removed. No game read returns a
      // summary-only row (#406), so the tables are checked directly.
      await build(
        FakeCollectionRemote(
          (_) => _page([_row(1, deletedAt: DateTime.utc(2026, 3))]),
        ),
      ).hydrate();

      expect(await db.select(db.gamesTable).get(), isEmpty);
      expect(await db.select(db.platformGamesTable).get(), isEmpty);
    });

    // A list open during a first hydrate would otherwise fill one row at a
    // time, re-running its join after every write.
    test('a page reaches the list whole, never row by row', () async {
      final lengths = <int>[];
      final whole = Completer<void>();
      final subscription = collection.watchCollectionListItems().listen((
        items,
      ) {
        lengths.add(items.length);
        if (items.length == 3 && !whole.isCompleted) whole.complete();
      });
      final remote = FakeCollectionRemote(
        (_) => _page([_row(1), _row(2), _row(3)]),
      );

      await build(remote).hydrate();
      await whole.future;
      await subscription.cancel();

      expect(lengths, everyElement(anyOf(0, 3)));
    });

    test('a single page is a snapshot, so no catch-up pass is sent', () async {
      final remote = FakeCollectionRemote((_) => _page([_row(1)]));

      await build(remote).hydrate();

      expect(remote.requests, hasLength(1));
    });
  });

  // A row changed mid-drain moves to page 1, which was already read.
  group('the catch-up pass', () {
    final newest = DateTime.utc(2026, 5, 1, 12);

    FakeCollectionRemote twoPagesThen(
      FutureOr<PaginatedResult<GameCollectionWithSummary>> Function() catchUp,
    ) => FakeCollectionRemote(
      (r) => r.updatedSince != null
          ? catchUp()
          : switch (r.page) {
              1 => _page(
                [_row(1, updatedAt: newest), _row(2)],
                limit: 2,
                total: 3,
                hasMore: true,
              ),
              _ => _page([_row(3)], page: 2, limit: 2, total: 3),
            },
    );

    test('after a multi-page drain, asks once more for what changed since '
        'the newest row page 1 held', () async {
      final remote = twoPagesThen(() => _page(const [], limit: 2));

      await build(remote, limit: 2).hydrate();

      expect(remote.requests.last, (
        page: 1,
        limit: 2,
        includeDeleted: true,
        updatedSince: newest,
      ));
      expect(remote.requests, hasLength(3));
    });

    test('stores what it finds', () async {
      final remote = twoPagesThen(
        () => _page([_row(4, updatedAt: newest)], limit: 2),
      );

      final outcome = await build(remote, limit: 2).hydrate();

      expect(outcome, CollectionHydrateOutcome.complete);
      expect(await listedTitles(), ['Game 1', 'Game 2', 'Game 3', 'Game 4']);
    });

    test('a failed catch-up keeps what the drain stored', () async {
      final remote = twoPagesThen(
        () => throw const GameCollectionRemoteTransientException('offline'),
      );

      final outcome = await build(remote, limit: 2).hydrate();

      expect(outcome, CollectionHydrateOutcome.failed);
      expect(await listedTitles(), ['Game 1', 'Game 2', 'Game 3']);
    });
  });

  group('failures never escape', () {
    test('a transient failure completes as failed', () async {
      final remote = FakeCollectionRemote(
        (_) => throw const GameCollectionRemoteTransientException('offline'),
      );

      expect(await build(remote).hydrate(), CollectionHydrateOutcome.failed);
    });

    test('a permanent failure completes as failed', () async {
      final remote = FakeCollectionRemote(
        (_) => throw const GameCollectionRemotePermanentException('bad row'),
      );

      expect(await build(remote).hydrate(), CollectionHydrateOutcome.failed);
    });

    test('a request the data source rejects locally completes as '
        'failed', () async {
      final remote = FakeCollectionRemote((_) => throw ArgumentError('page'));

      expect(await build(remote).hydrate(), CollectionHydrateOutcome.failed);
    });

    test('keeps the pages stored before a later page failed', () async {
      final remote = FakeCollectionRemote(
        (r) => r.page == 1
            ? _page([_row(1)], limit: 1, total: 2, hasMore: true)
            : throw const GameCollectionRemoteTransientException('offline'),
      );

      final outcome = await build(remote, limit: 1).hydrate();

      expect(outcome, CollectionHydrateOutcome.failed);
      expect(await listedTitles(), ['Game 1']);
    });

    test('absorbs the session ending mid-drain', () async {
      final remote = FakeCollectionRemote((_) => _page([_row(1)]));
      await collection.onDispose();

      expect(await build(remote).hydrate(), CollectionHydrateOutcome.failed);
    });

    test('stops at the last page the server counted', () async {
      final remote = FakeCollectionRemote(
        (r) => _page(
          [_row(r.page)],
          page: r.page,
          limit: 1,
          total: 2,
          totalPages: 2,
          hasMore: true,
        ),
      );

      final outcome = await build(remote, limit: 1).hydrate();

      expect(outcome, CollectionHydrateOutcome.failed);
      expect(remote.requests, hasLength(2));
    });
  });

  // The remote attaches whichever token the server's store holds when it
  // sends, not this session's. A page answered for another user must not
  // record its games for this one (#434).
  group('a page holding another user\'s entry', () {
    test('writes nothing from that page and completes as failed', () async {
      final remote = FakeCollectionRemote(
        (_) => _page([_row(1), _row(2, userId: 'user-other')]),
      );

      final outcome = await build(remote).hydrate();

      expect(outcome, CollectionHydrateOutcome.failed);
      expect(await db.select(db.gameAccessTable).get(), isEmpty);
      expect(await db.select(db.platformGameAccessTable).get(), isEmpty);
      expect(await db.select(db.gamesTable).get(), isEmpty);
      expect(await listedTitles(), isEmpty);
    });
  });

  // The sync drain runs beside the hydrate, at install and on the same
  // triggers, so it can confirm a removal while a page is in flight.
  group('a removal confirmed while a page is in flight (#121)', () {
    test('stays removed, though the page still holds the entry', () async {
      await build(FakeCollectionRemote((_) => _page([_row(1)]))).hydrate();
      await collection.removeFromCollection('gc-1');
      final removal = (await queue.getPendingEntries()).single;
      final answer = Completer<PaginatedResult<GameCollectionWithSummary>>();
      final remote = FakeCollectionRemote((_) => answer.future);

      final pass = build(remote).hydrate();
      await Future<void>.delayed(Duration.zero);
      expect(remote.requests, hasLength(1));
      await collection.confirmRemoved('gc-1', completedSyncQueueId: removal.id);
      answer.complete(_page([_row(1)]));

      expect(await pass, CollectionHydrateOutcome.complete);
      expect(await listedTitles(), isEmpty);
    });
  });

  // A completed pass leaves a mark, and the next asks only for what changed
  // since it. Whenever the mark may not describe the cache, the next pass
  // reads everything instead.
  group('a re-run reads only what changed (#450)', () {
    final t = DateTime.utc(2026, 5, 1, 12);

    /// The mark a completed pass whose newest row was at [t] leaves.
    final markAtT = t.subtract(GameCollectionHydrator.deltaOverlap);

    /// The page a server holding [rows] answers [request] with: every row,
    /// or, for a delta, only those updated at or after its `updatedSince`.
    PaginatedResult<GameCollectionWithSummary> serverPage(
      List<GameCollectionWithSummary> rows,
      CollectionListRequest request,
    ) {
      final since = request.updatedSince;
      return _page([
        for (final row in rows)
          if (since == null || !row.entry.updatedAt.isBefore(since)) row,
      ]);
    }

    /// Runs [hydrator]'s next pass, and returns its outcome and the requests
    /// it sent [remote].
    Future<_Pass> nextPass(
      GameCollectionHydrator hydrator,
      FakeCollectionRemote remote,
    ) async {
      final from = remote.requests.length;
      final outcome = await hydrator.hydrate();
      return (outcome: outcome, requests: remote.requests.sublist(from));
    }

    test('the first pass is a full drain', () async {
      final remote = FakeCollectionRemote(
        (r) => serverPage([_row(1, updatedAt: t)], r),
      );

      await build(remote).hydrate();

      expect(remote.requests.first.updatedSince, isNull);
    });

    test('a completed pass that saw no rows leaves no delta mark, so the next '
        'is a full drain', () async {
      final remote = FakeCollectionRemote((r) => serverPage([], r));
      final hydrator = build(remote);
      final first = await nextPass(hydrator, remote);
      expect(first.outcome, CollectionHydrateOutcome.complete);

      final second = await nextPass(hydrator, remote);

      expect(second.requests.first.updatedSince, isNull);
    });

    test('after a completed pass, the next asks only for rows changed since '
        'the newest it saw, less the overlap', () async {
      final remote = FakeCollectionRemote(
        (r) => serverPage([
          _row(1, updatedAt: t),
          _row(2, updatedAt: t.subtract(const Duration(hours: 1))),
        ], r),
      );
      final hydrator = build(remote);
      await hydrator.hydrate();

      final second = await nextPass(hydrator, remote);

      expect(second.requests.first, (
        page: 1,
        limit: 100,
        includeDeleted: true,
        updatedSince: t.subtract(GameCollectionHydrator.deltaOverlap),
      ));
    });

    test('a delta read applies a server-side removal', () async {
      final older = t.subtract(const Duration(hours: 1));
      final remote = FakeCollectionRemote(
        (r) =>
            serverPage([_row(1, updatedAt: t), _row(2, updatedAt: older)], r),
      );
      final hydrator = build(remote);
      await hydrator.hydrate();
      final removedAt = t.add(const Duration(minutes: 5));
      remote.respond = (r) => serverPage([
        _row(1, updatedAt: removedAt, deletedAt: removedAt),
        _row(2, updatedAt: older),
      ], r);

      final second = await nextPass(hydrator, remote);

      expect(second.requests.single.updatedSince, markAtT);
      expect(await listedTitles(), ['Game 2']);
    });

    test('after a failed pass, the next is a full drain', () async {
      final rows = [_row(1, updatedAt: t)];
      final remote = FakeCollectionRemote((r) => serverPage(rows, r));
      final hydrator = build(remote);
      await hydrator.hydrate();
      remote.respond = (_) =>
          throw const GameCollectionRemoteTransientException('offline');
      final second = await nextPass(hydrator, remote);
      remote.respond = (r) => serverPage(rows, r);

      final third = await nextPass(hydrator, remote);

      expect(second.outcome, CollectionHydrateOutcome.failed);
      expect(third.requests.first.updatedSince, isNull);
    });

    test("a delta that hits another user's entry fails, and the next is a "
        'full drain', () async {
      final rows = [_row(1, updatedAt: t)];
      final remote = FakeCollectionRemote((r) => serverPage(rows, r));
      final hydrator = build(remote);
      await hydrator.hydrate();
      remote.respond = (_) => _page([
        _row(
          2,
          updatedAt: t.add(const Duration(minutes: 1)),
          userId: 'user-other',
        ),
      ]);
      final second = await nextPass(hydrator, remote);
      remote.respond = (r) => serverPage(rows, r);

      final third = await nextPass(hydrator, remote);

      expect(second.outcome, CollectionHydrateOutcome.failed);
      expect(second.requests.single.updatedSince, markAtT);
      expect(third.requests.first.updatedSince, isNull);
    });

    // A disposed repository is how this suite fails a cache write. The
    // summaries are written first, so a disposed game repository fails the
    // page while the removal mark can still be read. The next pass fails
    // the same way, but only after its first request.
    test('a delta whose cache write fails ends failed, and the next is a '
        'full drain', () async {
      final rows = [_row(1, updatedAt: t)];
      final remote = FakeCollectionRemote((r) => serverPage(rows, r));
      final hydrator = build(remote);
      await hydrator.hydrate();
      remote.respond = (_) =>
          _page([_row(2, updatedAt: t.add(const Duration(minutes: 1)))]);
      await games.onDispose();
      final second = await nextPass(hydrator, remote);

      final third = await nextPass(hydrator, remote);

      expect(second.outcome, CollectionHydrateOutcome.failed);
      expect(second.requests.single.updatedSince, markAtT);
      expect(third.requests.first.updatedSince, isNull);
    });

    test('the mark moves only forward', () async {
      final remote = FakeCollectionRemote(
        (r) => serverPage([_row(1, updatedAt: t)], r),
      );
      final hydrator = build(remote);
      await hydrator.hydrate();
      remote.respond = (_) =>
          _page([_row(2, updatedAt: t.subtract(const Duration(hours: 2)))]);
      final second = await nextPass(hydrator, remote);
      remote.respond = (_) => _page(const []);

      final third = await nextPass(hydrator, remote);

      expect(second.outcome, CollectionHydrateOutcome.complete);
      expect(second.requests.single.updatedSince, markAtT);
      expect(
        third.requests.single.updatedSince,
        second.requests.single.updatedSince,
      );
    });

    test('a completed pass that saw no rows keeps its mark', () async {
      final remote = FakeCollectionRemote(
        (r) => serverPage([_row(1, updatedAt: t)], r),
      );
      final hydrator = build(remote);
      await hydrator.hydrate();
      remote.respond = (_) => _page(const []);
      final second = await nextPass(hydrator, remote);

      final third = await nextPass(hydrator, remote);

      expect(second.outcome, CollectionHydrateOutcome.complete);
      expect(second.requests.single.updatedSince, markAtT);
      expect(
        third.requests.single.updatedSince,
        second.requests.single.updatedSince,
      );
    });

    test('the newest row of a catch-up counts toward the mark', () async {
      final caughtUp = t.add(const Duration(minutes: 1));
      final remote = FakeCollectionRemote(
        (r) => switch ((r.page, r.updatedSince)) {
          (1, null) => _page(
            [
              _row(1, updatedAt: t),
              _row(2, updatedAt: t.subtract(const Duration(hours: 1))),
            ],
            limit: 2,
            total: 3,
            hasMore: true,
          ),
          (2, null) => _page(
            [_row(3, updatedAt: t.subtract(const Duration(hours: 2)))],
            page: 2,
            limit: 2,
            total: 3,
          ),
          _ => _page([_row(4, updatedAt: caughtUp)], limit: 2),
        },
      );
      final hydrator = build(remote, limit: 2);
      await hydrator.hydrate();
      remote.respond = (_) => _page(const [], limit: 2);

      final second = await nextPass(hydrator, remote);

      expect(
        second.requests.single.updatedSince,
        caughtUp.subtract(GameCollectionHydrator.deltaOverlap),
      );
    });

    test('a delta spanning two pages runs a catch-up from its own '
        'page 1', () async {
      final remote = FakeCollectionRemote(
        (_) => _page([_row(1, updatedAt: t)], limit: 2),
      );
      final hydrator = build(remote, limit: 2);
      await hydrator.hydrate();
      final newestOnPageOne = t.add(const Duration(minutes: 10));
      remote.respond = (r) => r.updatedSince != markAtT
          ? _page(const [], limit: 2)
          : switch (r.page) {
              1 => _page(
                [
                  _row(2, updatedAt: newestOnPageOne),
                  _row(3, updatedAt: t.add(const Duration(minutes: 5))),
                ],
                limit: 2,
                total: 3,
                hasMore: true,
              ),
              _ => _page(
                [_row(4, updatedAt: t.add(const Duration(minutes: 2)))],
                page: 2,
                limit: 2,
                total: 3,
              ),
            };

      final second = await nextPass(hydrator, remote);

      expect(second.requests, [
        (page: 1, limit: 2, includeDeleted: true, updatedSince: markAtT),
        (page: 2, limit: 2, includeDeleted: true, updatedSince: markAtT),
        (
          page: 1,
          limit: 2,
          includeDeleted: true,
          updatedSince: newestOnPageOne,
        ),
      ]);
    });

    // A discard leaves the row holding the discarded op's values for a merge
    // to rebuild, and moves the removal mark. The server's copy did not
    // change, so a delta would never read it.
    test('after a stuck op is discarded, the next is a full drain that '
        'rebuilds its row, and the one after a delta', () async {
      // Older than the mark, so only a full drain reads it again.
      final rows = [
        _row(1, updatedAt: t.subtract(const Duration(hours: 1))),
        _row(2, updatedAt: t),
      ];
      final remote = FakeCollectionRemote((r) => serverPage(rows, r));
      final hydrator = build(remote);
      await hydrator.hydrate();
      await collection.updateCollectionEntry(id: 'gc-1', quantity: 4);
      final update = (await queue.getOutstandingEntries()).single;
      await queue.park(update.id, error: 'rejected: 400');
      expect(await collection.discardQueuedOp(update.id), isTrue);

      final second = await nextPass(hydrator, remote);

      expect(second.requests.single.updatedSince, isNull);
      final items = await collection.watchCollectionListItems().first;
      expect(items.firstWhere((i) => i.entry.id == 'gc-1').entry.quantity, 1);

      final third = await nextPass(hydrator, remote);

      expect(third.requests.single.updatedSince, markAtT);
    });

    // Another tab over the same database can discard the op, and close
    // before its own hydrate rebuilds the row.
    test('after another tab discards a stuck op, the next is a full drain '
        'that rebuilds its row, and the one after a delta', () async {
      // Older than the mark, so only a full drain reads it again.
      final rows = [
        _row(1, updatedAt: t.subtract(const Duration(hours: 1))),
        _row(2, updatedAt: t),
      ];
      final remote = FakeCollectionRemote((r) => serverPage(rows, r));
      final hydrator = build(remote);
      await hydrator.hydrate();
      final otherTab = openCollection();
      await otherTab.updateCollectionEntry(id: 'gc-1', quantity: 4);
      final update = (await queue.getOutstandingEntries()).single;
      await queue.park(update.id, error: 'rejected: 400');
      expect(await otherTab.discardQueuedOp(update.id), isTrue);
      await otherTab.onDispose();

      final second = await nextPass(hydrator, remote);

      expect(second.requests.single.updatedSince, isNull);
      final items = await collection.watchCollectionListItems().first;
      expect(items.firstWhere((i) => i.entry.id == 'gc-1').entry.quantity, 1);

      final third = await nextPass(hydrator, remote);

      expect(third.requests.single.updatedSince, markAtT);
    });

    // The pass records the removal mark it read before its first request,
    // not one read when it ends: a confirmation mid-pass can make the merge
    // skip a live copy, which the next pass must read again.
    test('after a removal is confirmed during a pass, the next is a full '
        'drain, and the one after a delta', () async {
      final remote = FakeCollectionRemote(
        (r) => serverPage([_row(1, updatedAt: t), _row(2, updatedAt: t)], r),
      );
      final hydrator = build(remote);
      await hydrator.hydrate();
      await collection.removeFromCollection('gc-1');
      final removal = (await queue.getPendingEntries()).single;
      final answer = Completer<PaginatedResult<GameCollectionWithSummary>>();
      remote.respond = (_) => answer.future;
      final during = hydrator.hydrate();
      await Future<void>.delayed(Duration.zero);
      expect(remote.requests, hasLength(2));
      expect(remote.requests.last.updatedSince, markAtT);
      await collection.confirmRemoved('gc-1', completedSyncQueueId: removal.id);
      answer.complete(_page([_row(1, updatedAt: t), _row(2, updatedAt: t)]));
      expect(await during, CollectionHydrateOutcome.complete);
      final removedAt = t.add(const Duration(minutes: 5));
      remote.respond = (r) => serverPage([
        _row(1, updatedAt: removedAt, deletedAt: removedAt),
        _row(2, updatedAt: t),
      ], r);

      final third = await nextPass(hydrator, remote);
      final fourth = await nextPass(hydrator, remote);

      expect(third.requests.single.updatedSince, isNull);
      expect(
        fourth.requests.single.updatedSince,
        removedAt.subtract(GameCollectionHydrator.deltaOverlap),
      );
    });
  });

  group('dirty entries', () {
    test('a dirty entry keeps its edit through a hydrate', () async {
      await build(FakeCollectionRemote((_) => _page([_row(1)]))).hydrate();
      await collection.updateCollectionEntry(id: 'gc-1', quantity: 4);

      await build(FakeCollectionRemote((_) => _page([_row(1)]))).hydrate();

      final item = (await collection.watchCollectionListItems().first).single;
      expect(item.entry.quantity, 4);
      expect(item.entry.isDirty, isTrue);
    });
  });

  group('an offline cold start', () {
    test('lists the titles an earlier session cached', () async {
      await build(FakeCollectionRemote((_) => _page([_row(1), _row(2)])))
          .hydrate();
      await collection.onDispose();

      // The next session: fresh repositories over the same database, and a
      // server that cannot be reached.
      collection = openCollection();
      final outcome = await build(
        FakeCollectionRemote(
          (_) => throw const GameCollectionRemoteTransientException('offline'),
        ),
      ).hydrate();

      expect(outcome, CollectionHydrateOutcome.failed);
      expect(await listedTitles(), ['Game 1', 'Game 2']);
    });
  });
}
