import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The games pool's filter on an event's Games tab, and the attendees a
/// read of the pool names (#516).
void main() {
  /// A game [attendeeId] offers, titled [title], with the facts given.
  OfferedGame offered(
    String id,
    String attendeeId,
    String title, {
    String? subtitle,
    PlatformType? platformType,
    ContentType? contentType,
    GameMedium? medium,
    int? publishYear,
    int? minPlayers,
    int? maxPlayers,
    int? minPlayTime,
    int? maxPlayTime,
  }) => OfferedGame(
    id: id,
    attendeeId: attendeeId,
    collectionId: 'col-$id',
    platformGameId: 'pg-$id',
    gameId: 'g-$id',
    title: title,
    subtitle: subtitle,
    platformName: 'Tabletop',
    platformType: platformType,
    contentType: contentType,
    medium: medium,
    publishYear: publishYear,
    minPlayers: minPlayers,
    maxPlayers: maxPlayers,
    minPlayTime: minPlayTime,
    maxPlayTime: maxPlayTime,
  );

  /// A filter whose search is [query].
  PoolFilter searching(String query) =>
      PoolFilter(game: CollectionFilter(query: query));

  final catanMine = offered('o-1', 'att-me', 'Catan');
  final azul = offered('o-2', 'att-ada', 'Azul');
  final catanAdas = offered('o-3', 'att-ada', 'Catan');
  final root = offered('o-4', 'att-bo', 'Root');
  final pool = [catanMine, azul, catanAdas, root];

  group('filterPool', () {
    test('keeps every game, in order, when nothing narrows', () {
      expect(filterPool(pool, const PoolFilter()), pool);
      expect(const PoolFilter().narrows, isFalse);
    });

    test('the query matches the title, trimmed, ignoring case', () {
      final filter = searching('  cAT ');

      expect(filterPool(pool, filter), [catanMine, catanAdas]);
      expect(filter.narrows, isTrue);
    });

    test('a blank query narrows nothing', () {
      final filter = searching('   ');

      expect(filterPool(pool, filter), pool);
      expect(filter.narrows, isFalse);
    });

    test('one person chosen keeps only their games', () {
      const filter = PoolFilter(attendeeIds: {'att-ada'});

      expect(filterPool(pool, filter), [azul, catanAdas]);
      expect(filter.narrows, isTrue);
    });

    test('two people chosen keep both their games, in order', () {
      const filter = PoolFilter(attendeeIds: {'att-bo', 'att-me'});

      expect(filterPool(pool, filter), [catanMine, root]);
    });

    test('leave-out keeps everyone but the people chosen', () {
      const filter = PoolFilter(attendeeIds: {'att-ada'}, leaveOut: true);

      expect(filterPool(pool, filter), [catanMine, root]);
      expect(filter.narrows, isTrue);
    });

    test('nobody chosen with leave-out on narrows nothing', () {
      const filter = PoolFilter(leaveOut: true);

      expect(filterPool(pool, filter), pool);
      expect(filter.narrows, isFalse);
    });

    test('the query and the people narrow together', () {
      const filter = PoolFilter(
        game: CollectionFilter(query: 'catan'),
        attendeeIds: {'att-me'},
      );

      expect(filterPool(pool, filter), [catanMine]);
    });

    test('"Not mine" leaves the viewer\'s games out', () {
      const notMine = PoolFilter(attendeeIds: {'att-me'}, leaveOut: true);

      expect(filterPool(pool, notMine), [azul, catanAdas, root]);
    });

    test(
      'two people offering one game are two rows, and leaving one person out '
      "keeps the other's",
      () {
        expect(filterPool(pool, searching('Catan')), [
          catanMine,
          catanAdas,
        ]);

        expect(
          filterPool(
            pool,
            const PoolFilter(
              game: CollectionFilter(query: 'Catan'),
              attendeeIds: {'att-me'},
              leaveOut: true,
            ),
          ),
          [catanAdas],
        );
      },
    );

    test("the query matches by terms, each in the title, as Collection's "
        'search does', () {
      final seafarers = offered('o-5', 'att-bo', 'Catan: Seafarers');
      final games = [...pool, seafarers];

      for (final query in ['catan sea', 'Catan: Seafarers', 'seafarers cat']) {
        expect(
          filterPool(games, searching(query)),
          [seafarers],
          reason: query,
        );
      }
      expect(filterPool(games, searching('catan root')), isEmpty);
    });

    test('a query of punctuation alone narrows nothing', () {
      final filter = searching(' : - ');

      expect(filterPool(pool, filter), pool);
      expect(filter.narrows, isFalse);
    });

    test('search finds the subtitle', () {
      final seafarers = offered(
        'o-5',
        'att-bo',
        'Catan',
        subtitle: 'Seafarers',
      );
      final games = [...pool, seafarers];

      expect(filterPool(games, searching('seafarers')), [seafarers]);
      // Each term in either: the name the row shows.
      expect(filterPool(games, searching('catan sea')), [seafarers]);
      expect(filterPool(games, searching('Catan: Seafarers')), [seafarers]);
      expect(filterPool(games, searching('catan')), [
        catanMine,
        catanAdas,
        seafarers,
      ]);
    });

    // A row the server sent with no platform type or content type, as an old
    // server or a game with no data sends, is in no set (#851).
    final tabletop = offered(
      'o-5',
      'att-me',
      'Azul',
      platformType: PlatformType.tabletop,
      contentType: ContentType.baseGame,
    );
    final pc = offered(
      'o-6',
      'att-ada',
      'Root',
      platformType: PlatformType.pc,
      contentType: ContentType.expansion,
    );
    final unknown = offered('o-7', 'att-bo', 'Catan');
    final kinds = [tabletop, pc, unknown];

    PoolFilter platforms({bool flipped = false}) => PoolFilter(
      game: CollectionFilter(
        game: const GameSearchFilter(platformTypes: {PlatformType.tabletop}),
        excluded: {if (flipped) CollectionFacet.platformType},
      ),
    );

    PoolFilter contents({bool flipped = false}) => PoolFilter(
      game: CollectionFilter(
        game: const GameSearchFilter(contentTypes: {ContentType.baseGame}),
        excluded: {if (flipped) CollectionFacet.contentType},
      ),
    );

    test('a platform type filter keeps tabletop rows', () {
      expect(filterPool(kinds, platforms()), [tabletop]);
    });

    test('flipped, it keeps the rest, nulls included', () {
      expect(filterPool(kinds, platforms(flipped: true)), [pc, unknown]);
    });

    test('a content type filter drops a row with none, and flipped keeps '
        'it', () {
      expect(filterPool(kinds, contents()), [tabletop]);
      expect(filterPool(kinds, contents(flipped: true)), [pc, unknown]);
    });

    test('player count narrows', () {
      final duel = offered('o-5', 'att-me', 'Patchwork', minPlayers: 2);
      final party = offered(
        'o-6',
        'att-ada',
        'Codenames',
        minPlayers: 2,
        maxPlayers: 8,
      );
      final few = offered(
        'o-7',
        'att-bo',
        'Azul',
        minPlayers: 2,
        maxPlayers: 4,
      );
      const five = PoolFilter(
        game: CollectionFilter(
          game: GameSearchFilter(playerCount: GameSearchRange(min: 5)),
        ),
      );

      // Both counts must be known: Patchwork has no maximum.
      expect(filterPool([duel, party, few], five), [party]);
      expect(five.narrows, isTrue);
    });

    test('medium narrows', () {
      final boxed = offered(
        'o-5',
        'att-me',
        'Azul',
        medium: GameMedium.physical,
      );
      final app = offered('o-6', 'att-ada', 'Root', medium: GameMedium.digital);
      final none = offered('o-7', 'att-bo', 'Catan');
      const digital = PoolFilter(
        game: CollectionFilter(mediums: {GameMedium.digital}),
      );

      expect(filterPool([boxed, app, none], digital), [app]);
    });

    test('publish year narrows', () {
      final older = offered('o-5', 'att-me', 'Catan', publishYear: 1995);
      final newer = offered('o-6', 'att-ada', 'Root', publishYear: 2018);
      const since2000 = PoolFilter(
        game: CollectionFilter(
          game: GameSearchFilter(publishYear: GameSearchRange(min: 2000)),
        ),
      );

      expect(filterPool([older, newer], since2000), [newer]);
    });

    test('play time narrows, each end its own', () {
      final quick = offered(
        'o-5',
        'att-me',
        'Azul',
        minPlayTime: 30,
        maxPlayTime: 90,
      );
      final long = offered(
        'o-6',
        'att-ada',
        'Root',
        minPlayTime: 60,
        maxPlayTime: 90,
      );
      const fromThreeQuarters = PoolFilter(
        game: CollectionFilter(
          game: GameSearchFilter(playTime: GameSearchRange(min: 45, max: 90)),
        ),
      );

      // Azul can take 30 minutes, shorter than the range allows.
      expect(filterPool([quick, long], fromThreeQuarters), [long]);
    });

    test('facets and people both apply', () {
      final adasTabletop = offered(
        'o-8',
        'att-ada',
        'Catan',
        platformType: PlatformType.tabletop,
      );
      final adasPc = offered(
        'o-9',
        'att-ada',
        'Catan',
        platformType: PlatformType.pc,
      );
      final games = [...kinds, adasTabletop, adasPc];

      expect(
        filterPool(
          games,
          platforms().copyWith(attendeeIds: const {'att-ada'}),
        ),
        [adasTabletop],
      );
      expect(
        filterPool(
          games,
          platforms().copyWith(attendeeIds: const {'att-ada'}, leaveOut: true),
        ),
        [tabletop],
      );
      // With the search too, each of the three narrowing: the search and the
      // flip keep Bo's Catan and Ada's PC one, and Ada alone is chosen.
      expect(
        filterPool(
          games,
          platforms(flipped: true).copyWith(
            query: 'catan',
            attendeeIds: const {'att-ada'},
          ),
        ),
        [adasPc],
      );
    });

    test('narrows with a facet alone', () {
      const digital = PoolFilter(
        game: CollectionFilter(mediums: {GameMedium.digital}),
      );

      expect(digital.narrows, isTrue);
      expect(platforms().narrows, isTrue);
      expect(const PoolFilter().narrows, isFalse);
    });

    test('copyWith changes only the fields given', () {
      const tabletop = CollectionFilter(
        query: 'a',
        game: GameSearchFilter(platformTypes: {PlatformType.tabletop}),
      );
      const filter = PoolFilter(
        game: tabletop,
        attendeeIds: {'x'},
        leaveOut: true,
      );

      expect(filter.copyWith(), filter);
      expect(filter.query, 'a');
      // The query is the game filter's own, and its facets stay.
      expect(
        filter.copyWith(query: 'b'),
        PoolFilter(
          game: tabletop.copyWith(query: 'b'),
          attendeeIds: const {'x'},
          leaveOut: true,
        ),
      );
      expect(
        filter.copyWith(game: const CollectionFilter(query: 'c')),
        const PoolFilter(
          game: CollectionFilter(query: 'c'),
          attendeeIds: {'x'},
          leaveOut: true,
        ),
      );
      // Both given: the query over the game filter given.
      expect(
        filter.copyWith(query: 'd', game: const CollectionFilter()),
        const PoolFilter(
          game: CollectionFilter(query: 'd'),
          attendeeIds: {'x'},
          leaveOut: true,
        ),
      );
      expect(
        filter.copyWith(attendeeIds: const {}),
        const PoolFilter(game: tabletop, leaveOut: true),
      );
      expect(
        filter.copyWith(leaveOut: false),
        const PoolFilter(game: tabletop, attendeeIds: {'x'}),
      );
    });

    test('filters are equal by value', () {
      // Built apart, so not the one const instance.
      expect(
        const PoolFilter().copyWith(
          game: const CollectionFilter(query: 'a'),
          attendeeIds: {'x'},
          leaveOut: true,
        ),
        const PoolFilter(
          game: CollectionFilter(query: 'a'),
          attendeeIds: {'x'},
          leaveOut: true,
        ),
      );
      expect(const PoolFilter(), isNot(const PoolFilter(leaveOut: true)));
      expect(
        const PoolFilter(),
        isNot(
          const PoolFilter(
            game: CollectionFilter(mediums: {GameMedium.digital}),
          ),
        ),
      );
    });
  });

  final me = attendance(EventParticipationStatus.attending);
  EventAttendee member(String id) => me.copyWith(id: id, userId: 'u-$id');

  EventDetail detail({List<EventAttendee>? roster, EventAttendee? viewer}) =>
      EventDetail(
        snapshot: EventSnapshot(
          event: item('e').event,
          occurrences: const [],
          attendees: roster,
        ),
        attendance: viewer,
      );

  group('poolAttendeeIds', () {
    test("a roster is read whole, in the roster's order", () {
      expect(
        poolAttendeeIds(
          detail(roster: [member('att-b'), me, member('att-a')], viewer: me),
        ),
        ['att-b', 'att-me', 'att-a'],
      );
    });

    test("a null roster reads the viewer's own games", () {
      expect(poolAttendeeIds(detail(viewer: me)), ['att-me']);
    });

    test("a withheld roster reads the viewer's own games", () {
      expect(poolAttendeeIds(detail(roster: const [], viewer: me)), [
        'att-me',
      ]);
    });

    test('neither a roster nor a row of their own reads nothing', () {
      expect(poolAttendeeIds(detail()), isEmpty);
      expect(poolAttendeeIds(detail(roster: const [])), isEmpty);
    });

    test("poolNames names the roster's rows, and nobody without one", () {
      final ada = member('att-ada').copyWith(username: 'ada');
      final nameless = member('att-x').copyWith(
        username: null,
        displayName: null,
      );

      expect(poolNames(detail(roster: [ada, nameless], viewer: me)), {
        'att-ada': 'ada',
        'att-x': null,
      });
      expect(poolNames(detail(viewer: me)), isEmpty);
      expect(poolNames(detail(roster: const [], viewer: me)), isEmpty);
    });
  });

  // The ids a read sends (#851): none for everyone's games, unless the
  // roster says otherwise.
  group('poolReadIds', () {
    test('a roster read gives null', () {
      expect(
        poolReadIds(detail(roster: [member('att-b'), me], viewer: me)),
        isNull,
      );
    });

    test("a withheld roster gives the viewer's row", () {
      expect(poolReadIds(detail(roster: const [], viewer: me)), ['att-me']);
      // Not read yet, as for an event cached from the list.
      expect(poolReadIds(detail(viewer: me)), ['att-me']);
    });

    test('neither gives none', () {
      expect(poolReadIds(detail()), isEmpty);
      expect(poolReadIds(detail(roster: const [])), isEmpty);
    });
  });
}
