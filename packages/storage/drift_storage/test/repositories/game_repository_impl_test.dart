import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

DateTime _now() => DateTime.now().toUtc();

Game _makeGame({
  String id = 'g-1',
  String title = 'Test Game',
  String? subtitle,
  ContentType contentType = ContentType.baseGame,
  int? minPlayers,
  int? maxPlayers,
  int? playingTime,
  int? minPlayTime,
  TimeMeasure? minPlayTimeMeasure,
  int? maxPlayTime,
  TimeMeasure? maxPlayTimeMeasure,
  int totalPlayCount = 0,
  List<String> categories = const <String>[],
  List<String> mechanics = const <String>[],
  List<String> designers = const <String>[],
  List<String> publishers = const <String>[],
  List<String> tags = const <String>[],
  Visibility visibility = Visibility.public,
  String? createdById,
  DateTime? deletedAt,
}) {
  final t = _now();
  return Game(
    id: id,
    title: title,
    subtitle: subtitle,
    contentType: contentType,
    minPlayers: minPlayers,
    maxPlayers: maxPlayers,
    playingTime: playingTime,
    minPlayTime: minPlayTime,
    minPlayTimeMeasure: minPlayTimeMeasure,
    maxPlayTime: maxPlayTime,
    maxPlayTimeMeasure: maxPlayTimeMeasure,
    totalPlayCount: totalPlayCount,
    categories: categories,
    mechanics: mechanics,
    designers: designers,
    publishers: publishers,
    tags: tags,
    visibility: visibility,
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
    db = ServerDatabase.memory();
    repo = GameRepositoryImpl(db);
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

      test('round-trips TimeMeasure enums through the wire format', () async {
        await repo.cacheGame(
          _makeGame(
            id: 'g-tm',
            minPlayTime: 30,
            minPlayTimeMeasure: TimeMeasure.minutes,
            maxPlayTime: 2,
            maxPlayTimeMeasure: TimeMeasure.hours,
          ),
        );

        final found = (await repo.getGame('g-tm'))!;
        expect(found.minPlayTime, 30);
        expect(found.minPlayTimeMeasure, TimeMeasure.minutes);
        expect(found.maxPlayTime, 2);
        expect(found.maxPlayTimeMeasure, TimeMeasure.hours);
      });

      test('round-trips ContentType enum', () async {
        await repo.cacheGame(
          _makeGame(id: 'g-ct', contentType: ContentType.expansion),
        );

        final found = (await repo.getGame('g-ct'))!;
        expect(found.contentType, ContentType.expansion);
      });

      test(
        'round-trips denormalized list fields (categories/mechanics/designers/publishers)',
        () async {
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
        },
      );

      test(
        'round-trips the Pass-1 fields '
        '(playingTime / totalPlayCount / tags / visibility / createdById)',
        () async {
          await repo.cacheGame(
            _makeGame(
              id: 'g-pass1',
              playingTime: 90,
              totalPlayCount: 42,
              tags: ['Solo Mode', 'Heavy'],
              visibility: Visibility.private,
              createdById: 'user-abc',
            ),
          );

          final found = (await repo.getGame('g-pass1'))!;
          expect(found.playingTime, 90);
          expect(found.totalPlayCount, 42);
          expect(found.tags, equals(['Solo Mode', 'Heavy']));
          expect(found.visibility, Visibility.private);
          expect(found.createdById, 'user-abc');
        },
      );

      test('preserves model defaults for unset Pass-1 fields', () async {
        await repo.cacheGame(_makeGame(id: 'g-defaults'));

        final found = (await repo.getGame('g-defaults'))!;
        expect(found.playingTime, isNull);
        expect(found.totalPlayCount, 0);
        expect(found.tags, isEmpty);
        expect(found.visibility, Visibility.public);
        expect(found.createdById, isNull);
      });

      test('getGame returns null for a tombstoned game', () async {
        // Pass-6 Tier-1 fix: the five game read paths (getGame,
        // getGames, searchGames, watchGame, watchGames) all
        // skipped the `deletedAt IS NULL` filter that the
        // collection and household repositories apply. This test
        // locks in the fix for the single-item lookup.
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

      test('excludes tombstoned games from search results', () async {
        await repo.cacheGame(_makeGame(id: 'g-live', title: 'Catan'));
        await repo.cacheGame(
          _makeGame(
            id: 'g-deleted',
            title: 'Cathedral',
            deletedAt: _now(),
          ),
        );

        final result = await repo.searchGames('cat');
        expect(result.map((g) => g.id), equals(['g-live']));
      });

      // ── Tier-2 input validation ──────────────────────────────────────────────────

      test('returns empty when limit is zero', () async {
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Catan'));

        expect(await repo.searchGames('cat', limit: 0), isEmpty);
      });

      test('returns empty when limit is negative', () async {
        // Pre-fix, `limit: -1` would silently disable SQLite's LIMIT
        // clause (negative LIMIT === no limit in SQLite) and turn the
        // search into an unbounded cache scan. Now short-circuited
        // before any SQL.
        await repo.cacheGame(_makeGame(id: 'g-1', title: 'Catan'));

        expect(await repo.searchGames('cat', limit: -1), isEmpty);
        expect(await repo.searchGames('cat', limit: -100), isEmpty);
      });

      test(
        'strips LIKE wildcards (% and _) so they cannot match unintended rows',
        () async {
          // Pre-fix, q='%' would have compiled to LIKE '%%%' which
          // matches every cached row — turning the search into a
          // cache flood that distorts the prefix ranking. Now the
          // impl strips `%` and `_` from the input before building
          // the predicate, so a pure-wildcard query becomes '' and
          // short-circuits to [].
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
          _makeGame(
            id: 'g-deleted',
            title: 'Removed',
            deletedAt: _now(),
          ),
        );

        await expectLater(
          repo.watchGame('g-deleted').take(1),
          emits(isNull),
        );
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
          emits(predicate<List<Game>>(
            (games) => games.length == 1 && games.single.id == 'g-live',
          )),
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
  });
}
