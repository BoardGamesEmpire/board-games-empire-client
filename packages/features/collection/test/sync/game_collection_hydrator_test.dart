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
}) => (
  entry: GameCollection(
    id: 'gc-$n',
    userId: _kUserId,
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
    games = GameRepositoryImpl(db);
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
      // every entry the user ever removed.
      await build(
        FakeCollectionRemote(
          (_) => _page([_row(1, deletedAt: DateTime.utc(2026, 3))]),
        ),
      ).hydrate();

      expect(await games.getGame('g-1'), isNull);
      expect(await games.getPlatformGame('pg-1'), isNull);
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

  group('one pass at a time', () {
    test('a call made while a pass is in flight joins it', () async {
      final gate = Completer<PaginatedResult<GameCollectionWithSummary>>();
      final remote = FakeCollectionRemote((_) => gate.future);
      final hydrator = build(remote);

      final first = hydrator.hydrate();
      final second = hydrator.hydrate();
      gate.complete(_page([_row(1)]));

      expect(await first, CollectionHydrateOutcome.complete);
      expect(await second, CollectionHydrateOutcome.complete);
      expect(remote.requests, hasLength(1));
    });

    test('a call after a pass settles asks the server again', () async {
      final remote = FakeCollectionRemote((_) => _page([_row(1)]));
      final hydrator = build(remote);

      await hydrator.hydrate();
      await hydrator.hydrate();

      expect(remote.requests, hasLength(2));
    });
  });
}
