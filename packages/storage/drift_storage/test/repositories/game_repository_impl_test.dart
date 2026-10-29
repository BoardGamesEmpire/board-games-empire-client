import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

DateTime _now() => DateTime.now().toUtc();

Game _makeGame({
  String id = 'g-1',
  String title = 'Test Game',
  String? subtitle,
  ContentType contentType = ContentType.baseGame,
  int? publishYear,
  int? minPlayers,
  int? maxPlayers,
  int? minPlayTime,
  int? maxPlayTime,
  int totalPlayCount = 0,
  List<String> categories = const <String>[],
  List<String> mechanics = const <String>[],
  List<String> designers = const <String>[],
  List<String> publishers = const <String>[],
  List<String> tags = const <String>[],
  Reach reach = Reach.public,
  String? createdById,
  DateTime? deletedAt,
}) {
  final t = _now();
  return Game(
    id: id,
    title: title,
    subtitle: subtitle,
    contentType: contentType,
    publishYear: publishYear,
    minPlayers: minPlayers,
    maxPlayers: maxPlayers,
    minPlayTime: minPlayTime,
    maxPlayTime: maxPlayTime,
    totalPlayCount: totalPlayCount,
    categories: categories,
    mechanics: mechanics,
    designers: designers,
    publishers: publishers,
    tags: tags,
    reach: reach,
    createdById: createdById,
    deletedAt: deletedAt,
    createdAt: t,
    updatedAt: t,
  );
}

PlatformGame _makePlatformGame({
  String id = 'pg-1',
  String gameId = 'g-1',
  String platformId = 'plat-1',
  String platformName = 'Tabletop',
  bool supportsSolo = false,
  bool supportsLocal = false,
  bool supportsOnline = false,
  bool hasAsyncPlay = false,
  bool hasRealtime = false,
  bool hasTutorial = false,
}) {
  final t = _now();
  return PlatformGame(
    id: id,
    gameId: gameId,
    platformId: platformId,
    platformName: platformName,
    supportsSolo: supportsSolo,
    supportsLocal: supportsLocal,
    supportsOnline: supportsOnline,
    hasAsyncPlay: hasAsyncPlay,
    hasRealtime: hasRealtime,
    hasTutorial: hasTutorial,
    createdAt: t,
    updatedAt: t,
  );
}

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  late ServerDatabase db;
  late GameRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    repo = GameRepositoryImpl(db, userId: 'user-abc');
  });

  tearDown(() async => db.close());

  group('GameRepositoryImpl', () {
    // ── Game ────────────────────────────────────────────────────────────

    group('cacheGame() / getGame()', () {
      test('persists a game and reads it back', () async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Catan'));

        final found = await repo.getGame('g-1');
        expect(found, isNotNull);
        expect(found!.id, 'g-1');
        expect(found.title, 'Catan');
      });

      test('returns null when the id is unknown', () async {
        expect(await repo.getGame('nonexistent'), isNull);
      });

      test('upserts on conflicting id (second cacheGame wins)', () async {
        await repo.cacheGame(_makeGame(id: 'g-x', title: 'Original'));
        await repo.cacheGame(_makeGame(id: 'g-x', title: 'Updated'));

        final found = await repo.getGame('g-x');
        expect(found!.title, equals('Updated'));
      });

      test('round-trips ContentType enum', () async {
        await repo.cacheGame(
          _makeGame(id: 'g-ct', contentType: ContentType.expansion),
        );

        final found = (await repo.getGame('g-ct'))!;
        expect(found.contentType, ContentType.expansion);
      });

      test('round-trips denormalized list fields (categories/mechanics/designers/publishers)', () async {
        await repo.cacheGame(
          _makeGame(
            id: 'g-lists',
            categories: ['Strategy', 'Economic'],
            mechanics: ['Hand Management', 'Worker Placement'],
            designers: ['Klaus Teuber'],
            publishers: ['Asmodee'],
          ),
        );

        final found = (await repo.getGame('g-lists'))!;
        expect(found.categories, equals(['Strategy', 'Economic']));
        expect(
          found.mechanics,
          equals(['Hand Management', 'Worker Placement']),
        );
        expect(found.designers, equals(['Klaus Teuber']));
        expect(found.publishers, equals(['Asmodee']));
      });

      test('(minPlayTime / maxPlayTime / totalPlayCount / tags / reach / createdById)', () async {
        await repo.cacheGame(
          _makeGame(
            id: 'g-pass1',
            minPlayTime: 60,
            maxPlayTime: 120,
            totalPlayCount: 42,
            tags: ['Solo Mode', 'Heavy'],
            reach: Reach.private,
            createdById: 'user-abc',
          ),
        );

        final found = (await repo.getGame('g-pass1'))!;
        expect((found.minPlayTime, found.maxPlayTime), (60, 120));
        expect(found.totalPlayCount, 42);
        expect(found.tags, equals(['Solo Mode', 'Heavy']));
        expect(found.reach, Reach.private);
        expect(found.createdById, 'user-abc');
      });

      test('preserves model defaults for unset fields', () async {
        await repo.cacheGame(_makeGame(id: 'g-defaults'));

        final found = (await repo.getGame('g-defaults'))!;
        expect((found.minPlayTime, found.maxPlayTime), (null, null));
        expect(found.totalPlayCount, 0);
        expect(found.tags, isEmpty);
        expect(found.reach, Reach.public);
        expect(found.createdById, isNull);
      });

      test(
        'stores an unknown reach as Unknown and reads it back as unknown',
        () async {
          await repo.cacheGame(_makeGame(id: 'g-reach', reach: Reach.unknown));
          final row = await (db.select(
            db.gamesTable,
          )..where((t) => t.id.equals('g-reach'))).getSingle();
          expect(row.reach, 'Unknown');
          expect((await repo.getGame('g-reach'))!.reach, Reach.unknown);
        },
      );

      test('getGame returns null for a tombstoned game', () async {
        await repo.cacheGame(
          _makeGame(id: 'g-deleted', title: 'Removed', deletedAt: _now()),
        );

        expect(await repo.getGame('g-deleted'), isNull);
      });
    });

    group('getGames()', () {
      test('returns the games whose ids are present', () async {
        await repo.cacheGames([
          _makeGame(id: 'g-1'),
          _makeGame(id: 'g-2'),
          _makeGame(id: 'g-3'),
        ]);

        final result = await repo.getGames(['g-1', 'g-3']);
        expect(result.map((g) => g.id), unorderedEquals(['g-1', 'g-3']));
      });

      test('silently ignores unknown ids', () async {
        await repo.cacheGame(_makeGame(id: 'g-1'));

        final result = await repo.getGames(['g-1', 'nonexistent']);
        expect(result.map((g) => g.id), equals(['g-1']));
      });

      test('short-circuits on an empty list without hitting the DB', () async {
        expect(await repo.getGames([]), isEmpty);
      });

      test('excludes tombstoned games from the result', () async {
        await repo.cacheGame(_makeGame(id: 'g-live', title: 'Live'));
        await repo.cacheGame(
          _makeGame(id: 'g-deleted', title: 'Removed', deletedAt: _now()),
        );

        final result = await repo.getGames(['g-live', 'g-deleted']);
        expect(result.map((g) => g.id), equals(['g-live']));
      });
    });

    group('cacheGames() — batch', () {
      test('persists multiple games in one batch', () async {
        await repo.cacheGames([
          _makeGame(id: 'g-1', title: 'One'),
          _makeGame(id: 'g-2', title: 'Two'),
          _makeGame(id: 'g-3', title: 'Three'),
        ]);

        final all = await repo.getGames(['g-1', 'g-2', 'g-3']);
        expect(all, hasLength(3));
      });

      test('upserts mixed new + existing rows on conflict', () async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Original'));

        await repo.cacheGames([
          _makeGame(id: 'g-1', title: 'Updated'),
          _makeGame(id: 'g-2', title: 'New'),
        ]);

        expect((await repo.getGame('g-1'))!.title, equals('Updated'));
        expect((await repo.getGame('g-2'))!.title, equals('New'));
      });
    });

    group('searchGames()', () {
      test('returns empty for an empty or whitespace-only query', () async {
        await repo.cacheGame(_makeGame(title: 'Catan'));

        expect(await repo.searchGames(''), isEmpty);
        expect(await repo.searchGames('   '), isEmpty);
      });

      test('matches case-insensitively on title', () async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Wingspan'));
        await repo.cacheGame(_makeGame(id: 'g-2', title: 'Ticket to Ride'));

        final result = await repo.searchGames('WING');
        expect(result.map((g) => g.id), equals(['g-1']));
      });

      test('matches against subtitle', () async {
        await repo.cacheGame(
          _makeGame(id: 'g-1', title: 'Catan', subtitle: 'Seafarers'),
        );

        final result = await repo.searchGames('seafarers');
        expect(result.map((g) => g.id), equals(['g-1']));
      });

      test('ranks title-prefix matches ahead of in-title (substring) matches '
          '(ORDER BY runs before LIMIT — Copilot J)', () async {
        await repo.cacheGame(_makeGame(id: 'g-zoo', title: 'Zoo Cat'));
        await repo.cacheGame(_makeGame(id: 'g-emp', title: 'Cat Empire'));
        await repo.cacheGame(_makeGame(id: 'g-box', title: 'Cat in the Box'));
        await repo.cacheGame(_makeGame(id: 'g-wld', title: 'Wildcat'));

        final result = await repo.searchGames('cat');
        expect(
          result.map((g) => g.id),
          equals(['g-emp', 'g-box', 'g-wld', 'g-zoo']),
        );
      });

      test(
        'breaks ties among prefix matches alphabetically by title',
        () async {
          await repo.cacheGame(_makeGame(id: 'g-tan', title: 'Catan'));
          await repo.cacheGame(_makeGame(id: 'g-hed', title: 'Cathedral'));
          await repo.cacheGame(_makeGame(id: 'g-cmb', title: 'Catacombs'));

          final result = await repo.searchGames('cat');
          expect(result.map((g) => g.id), equals(['g-cmb', 'g-tan', 'g-hed']));
        },
      );

      test('respects the limit parameter', () async {
        for (var i = 0; i < 10; i++) {
          await repo.cacheGame(_makeGame(id: 'g-$i', title: 'Cat $i'));
        }

        final result = await repo.searchGames('cat', limit: 3);
        expect(result, hasLength(3));
      });

      test('narrows by content type before the limit', () async {
        for (var i = 0; i < 5; i++) {
          await repo.cacheGame(_makeGame(id: 'g-$i', title: 'Cat $i'));
        }
        await repo.cacheGame(
          _makeGame(
            id: 'g-exp',
            title: 'Cat Zzz',
            contentType: ContentType.expansion,
          ),
        );

        final result = await repo.searchGames(
          'cat',
          limit: 3,
          filter: const GameSearchFilter(contentTypes: {ContentType.expansion}),
        );
        expect(result.map((g) => g.id), equals(['g-exp']));
      });

      test('reads every content type when given none', () async {
        await repo.cacheGame(_makeGame(id: 'g-base', title: 'Catan'));
        await repo.cacheGame(
          _makeGame(
            id: 'g-exp',
            title: 'Catan: Seafarers',
            contentType: ContentType.expansion,
          ),
        );

        final result = await repo.searchGames('catan');
        expect(result.map((g) => g.id), equals(['g-base', 'g-exp']));
      });

      test('excludes tombstoned games from search results', () async {
        await repo.cacheGame(_makeGame(id: 'g-live', title: 'Catan'));
        await repo.cacheGame(
          _makeGame(id: 'g-deleted', title: 'Cathedral', deletedAt: _now()),
        );

        final result = await repo.searchGames('cat');
        expect(result.map((g) => g.id), equals(['g-live']));
      });

      test('returns empty when limit is zero', () async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Catan'));

        expect(await repo.searchGames('cat', limit: 0), isEmpty);
      });

      test('returns empty when limit is negative', () async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Catan'));

        expect(await repo.searchGames('cat', limit: -1), isEmpty);
        expect(await repo.searchGames('cat', limit: -100), isEmpty);
      });

      test(
        'strips LIKE wildcards (% and _) so they cannot match unintended rows',
        () async {
          await repo.cacheGame(_makeGame(id: 'g-1', title: 'Catan'));
          await repo.cacheGame(_makeGame(id: 'g-2', title: 'Wingspan'));
          await repo.cacheGame(_makeGame(id: 'g-3', title: 'Ticket to Ride'));

          // Pure-wildcard queries strip down to '' and return empty.
          expect(await repo.searchGames('%'), isEmpty);
          expect(await repo.searchGames('_'), isEmpty);
          expect(await repo.searchGames('%_%'), isEmpty);

          // Mixed input: wildcards stripped, remaining text searched.
          // 'cat%' → 'cat', matches only 'Catan'.
          final result = await repo.searchGames('cat%');
          expect(result.map((g) => g.id), equals(['g-1']));
        },
      );
    });

    group('searchGames() narrows by the filter\'s ranges (#565, #580)', () {
      /// The titles of the games matching "game" that [filter] keeps, in the
      /// search's order.
      Future<List<String>> titles(GameSearchFilter filter) async => [
        for (final game in await repo.searchGames('game', filter: filter))
          game.title,
      ];

      test('a publish-year range keeps the years inside it, and undated '
          'games only when asked', () async {
        await repo.cacheGames([
          _makeGame(id: 'g-1', title: 'Game -2200', publishYear: -2200),
          _makeGame(id: 'g-2', title: 'Game 1995', publishYear: 1995),
          _makeGame(id: 'g-3', title: 'Game 2010', publishYear: 2010),
          _makeGame(id: 'g-4', title: 'Game undated'),
        ]);

        expect(
          await titles(
            const GameSearchFilter(
              publishYear: GameSearchRange(min: -3000, max: 2000),
            ),
          ),
          ['Game -2200', 'Game 1995'],
        );
        expect(
          await titles(
            const GameSearchFilter(
              publishYear: GameSearchRange(
                min: -3000,
                max: 2000,
                includeUnknown: true,
              ),
            ),
          ),
          ['Game -2200', 'Game 1995', 'Game undated'],
        );
      });

      test('a single player-count bound is one count', () async {
        await repo.cacheGames([
          _makeGame(id: 'g-1', title: 'Game 2-6', minPlayers: 2, maxPlayers: 6),
          _makeGame(id: 'g-2', title: 'Game 2-4', minPlayers: 2, maxPlayers: 4),
          _makeGame(id: 'g-3', title: 'Game ?-6', maxPlayers: 6),
        ]);

        expect(
          await titles(
            const GameSearchFilter(playerCount: GameSearchRange(min: 5)),
          ),
          ['Game 2-6'],
        );
        expect(
          await titles(
            const GameSearchFilter(playerCount: GameSearchRange(max: 5)),
          ),
          ['Game 2-6'],
        );
        expect(
          await titles(
            const GameSearchFilter(
              playerCount: GameSearchRange(min: 5, includeUnknown: true),
            ),
          ),
          ['Game 2-6', 'Game ?-6'],
        );
      });

      test('a player-count range needs every count in it', () async {
        await repo.cacheGames([
          _makeGame(id: 'g-1', title: 'Game 2-6', minPlayers: 2, maxPlayers: 6),
          _makeGame(id: 'g-2', title: 'Game 2-4', minPlayers: 2, maxPlayers: 4),
        ]);

        expect(
          await titles(
            const GameSearchFilter(
              playerCount: GameSearchRange(min: 3, max: 5),
            ),
          ),
          ['Game 2-6'],
        );
      });

      test('a play time fits when the whole time does', () async {
        await repo.cacheGames([
          _makeGame(
            id: 'g-1',
            title: 'Game 30-60',
            minPlayTime: 30,
            maxPlayTime: 60,
          ),
          _makeGame(
            id: 'g-2',
            title: 'Game 45-90',
            minPlayTime: 45,
            maxPlayTime: 90,
          ),
          _makeGame(id: 'g-3', title: 'Game 90', maxPlayTime: 90),
          _makeGame(id: 'g-4', title: 'Game none'),
        ]);

        expect(
          await titles(
            const GameSearchFilter(playTime: GameSearchRange(max: 60)),
          ),
          ['Game 30-60'],
        );
        expect(
          await titles(
            const GameSearchFilter(playTime: GameSearchRange(min: 45)),
          ),
          ['Game 45-90', 'Game 90'],
        );
        expect(
          await titles(
            const GameSearchFilter(playTime: GameSearchRange(min: 30, max: 90)),
          ),
          ['Game 30-60', 'Game 45-90', 'Game 90'],
        );
        expect(
          await titles(
            const GameSearchFilter(
              playTime: GameSearchRange(min: 30, max: 90, includeUnknown: true),
            ),
          ),
          ['Game 30-60', 'Game 45-90', 'Game 90', 'Game none'],
        );
      });

      test('a game with one play time uses it for both ends', () async {
        await repo.cacheGame(
          _makeGame(id: 'g-1', title: 'Game 120', minPlayTime: 120),
        );

        expect(
          await titles(
            const GameSearchFilter(playTime: GameSearchRange(min: 100)),
          ),
          ['Game 120'],
        );
        expect(
          await titles(
            const GameSearchFilter(playTime: GameSearchRange(max: 100)),
          ),
          isEmpty,
        );
      });

      test('a platform-type filter finds nothing', () async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Game one'));
        expect(await titles(const GameSearchFilter()), ['Game one']);

        expect(
          await titles(
            const GameSearchFilter(platformTypes: {PlatformType.tabletop}),
          ),
          isEmpty,
        );
      });

      test('the ranges narrow before the limit', () async {
        // Titles sort by name, so the three in range sort last.
        await repo.cacheGames([
          for (var i = 0; i < 25; i++)
            _makeGame(
              id: 'g-$i',
              title: 'Game ${i.toString().padLeft(2, '0')}',
              publishYear: i < 22 ? 1990 : 2000,
            ),
        ]);

        final result = await repo.searchGames(
          'game',
          filter: const GameSearchFilter(
            publishYear: GameSearchRange(min: 2000),
          ),
        );
        expect(result.map((g) => g.title), ['Game 22', 'Game 23', 'Game 24']);
      });
    });

    group('watchGame()', () {
      test('emits the current game on subscribe', () async {
        await repo.cacheGame(_makeGame(id: 'g-w', title: 'Watched'));

        await expectLater(
          repo.watchGame('g-w').take(1),
          emits(predicate<Game?>((g) => g != null && g.id == 'g-w')),
        );
      });

      test('emits null for an unknown id', () async {
        await expectLater(repo.watchGame('missing').take(1), emits(isNull));
      });

      test('re-emits when the watched game is updated', () async {
        await repo.cacheGame(_makeGame(id: 'g-w', title: 'Before'));

        final futureEmissions = repo.watchGame('g-w').take(2).toList();
        await pumpEventQueue();

        await repo.cacheGame(_makeGame(id: 'g-w', title: 'After'));

        final emissions = await futureEmissions.timeout(
          const Duration(seconds: 5),
        );
        expect(emissions, hasLength(2));
        expect(emissions[0]!.title, 'Before');
        expect(emissions[1]!.title, 'After');
      });

      test('emits null for a tombstoned game id', () async {
        await repo.cacheGame(
          _makeGame(id: 'g-deleted', title: 'Removed', deletedAt: _now()),
        );

        await expectLater(repo.watchGame('g-deleted').take(1), emits(isNull));
      });
    });

    group('watchGames()', () {
      test('emits an empty list when no games are cached', () async {
        await expectLater(repo.watchGames().take(1), emits(isEmpty));
      });

      test('emits all cached games', () async {
        await repo.cacheGames([_makeGame(id: 'g-1'), _makeGame(id: 'g-2')]);

        await expectLater(repo.watchGames().take(1), emits(hasLength(2)));
      });

      test('excludes tombstoned games from the emission', () async {
        await repo.cacheGame(_makeGame(id: 'g-live', title: 'Live'));
        await repo.cacheGame(
          _makeGame(id: 'g-deleted', title: 'Removed', deletedAt: _now()),
        );

        await expectLater(
          repo.watchGames().take(1),
          emits(
            predicate<List<Game>>(
              (games) => games.length == 1 && games.single.id == 'g-live',
            ),
          ),
        );
      });
    });

    // ── PlatformGame ─────────────────────────────────────────────────────────

    group('PlatformGame', () {
      setUp(() async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Parent'));
      });

      test('cachePlatformGame + getPlatformGame round-trip', () async {
        await repo.cachePlatformGame(
          _makePlatformGame(
            id: 'pg-1',
            gameId: 'g-1',
            platformName: 'Steam',
            supportsOnline: true,
            hasAsyncPlay: true,
          ),
        );

        final found = await repo.getPlatformGame('pg-1');
        expect(found, isNotNull);
        expect(found!.gameId, 'g-1');
        expect(found.platformName, 'Steam');
        expect(found.supportsOnline, isTrue);
        expect(found.hasAsyncPlay, isTrue);
        expect(found.supportsSolo, isFalse);
      });

      test('getPlatformGame returns null when absent', () async {
        expect(await repo.getPlatformGame('missing'), isNull);
      });

      test('cachePlatformGame upserts on conflicting id', () async {
        await repo.cachePlatformGame(
          _makePlatformGame(
            id: 'pg-1',
            gameId: 'g-1',
            platformName: 'Tabletop',
          ),
        );
        await repo.cachePlatformGame(
          _makePlatformGame(
            id: 'pg-1',
            gameId: 'g-1',
            platformName: 'Tabletop Simulator',
          ),
        );

        final found = (await repo.getPlatformGame('pg-1'))!;
        expect(found.platformName, 'Tabletop Simulator');
      });

      test(
        'getPlatformGamesForGame returns only the platforms for the given game',
        () async {
          await repo.cacheGame(_makeGame(id: 'g-2', title: 'Other'));

          await repo.cachePlatformGames([
            _makePlatformGame(id: 'pg-1a', gameId: 'g-1', platformName: 'A'),
            _makePlatformGame(id: 'pg-1b', gameId: 'g-1', platformName: 'B'),
            _makePlatformGame(id: 'pg-2a', gameId: 'g-2', platformName: 'A'),
          ]);

          final forG1 = await repo.getPlatformGamesForGame('g-1');
          expect(forG1.map((p) => p.id), unorderedEquals(['pg-1a', 'pg-1b']));

          final forG2 = await repo.getPlatformGamesForGame('g-2');
          expect(forG2.map((p) => p.id), equals(['pg-2a']));
        },
      );

      test(
        'getPlatformGamesForGame returns empty when no rows match',
        () async {
          expect(await repo.getPlatformGamesForGame('g-1'), isEmpty);
          expect(await repo.getPlatformGamesForGame('nonexistent'), isEmpty);
        },
      );

      test('cachePlatformGames upserts in batch', () async {
        await repo.cachePlatformGames([
          _makePlatformGame(
            id: 'pg-1',
            gameId: 'g-1',
            platformName: 'Original',
          ),
        ]);

        await repo.cachePlatformGames([
          _makePlatformGame(id: 'pg-1', gameId: 'g-1', platformName: 'Updated'),
          _makePlatformGame(id: 'pg-new', gameId: 'g-1', platformName: 'New'),
        ]);

        expect(
          (await repo.getPlatformGame('pg-1'))!.platformName,
          equals('Updated'),
        );
        expect(
          (await repo.getPlatformGame('pg-new'))!.platformName,
          equals('New'),
        );
      });

      test(
        'rejects orphan platform game (FK enforced by PRAGMA foreign_keys)',
        () async {
          await expectLater(
            () => repo.cachePlatformGame(
              _makePlatformGame(id: 'orphan', gameId: 'nonexistent'),
            ),
            throwsA(isA<Exception>()),
          );
        },
      );
    });

    test('a record outlives the session: a fresh repository for the same '
        'user still reads what the disposed one cached (#469)', () async {
      await repo.cacheGame(_makeGame(id: 'g-1', title: 'Catan'));

      await repo.onDispose();

      final next = GameRepositoryImpl(db, userId: 'user-abc');
      expect((await next.getGame('g-1'))?.title, 'Catan');
      expect(await db.select(db.gamesTable).get(), hasLength(1));
    });
  });
}
