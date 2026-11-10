import 'package:models/domain.dart';
import 'package:test/test.dart';

final _epoch = DateTime.utc(2026);

/// A list item titled [title], with game id `g-<title>` and entry id
/// `e-<title>` unless given, and every fact a filter or sort reads left
/// unset unless given.
GameCollectionListItem _item(
  String title, {
  String? id,
  String? gameId,
  String? subtitle,
  ContentType contentType = ContentType.baseGame,
  PlatformType? platformType,
  GameMedium medium = GameMedium.physical,
  List<ExpansionLink> baseGames = const [],
  DateTime? createdAt,
  int? rating,
  int? publishYear,
  int? minPlayers,
  int? maxPlayers,
  int? minPlayTime,
  int? maxPlayTime,
}) => GameCollectionListItem(
  entry: GameCollection(
    id: id ?? 'e-$title',
    userId: 'u-1',
    platformGameId: 'pg-$title',
    medium: medium,
    createdAt: createdAt ?? _epoch,
    updatedAt: createdAt ?? _epoch,
    rating: rating,
  ),
  gameId: gameId ?? 'g-$title',
  title: title,
  platformName: 'Platform',
  subtitle: subtitle,
  baseGames: baseGames,
  contentType: contentType,
  platformType: platformType,
  publishYear: publishYear,
  minPlayers: minPlayers,
  maxPlayers: maxPlayers,
  minPlayTime: minPlayTime,
  maxPlayTime: maxPlayTime,
);

ExpansionLink _link(String title, {bool standalone = false}) =>
    ExpansionLink(gameId: 'g-$title', isStandalone: standalone);

/// The titles of [items] that [filter] keeps, in order.
List<String> _titles(
  List<GameCollectionListItem> items,
  CollectionFilter filter,
) => [for (final item in filterCollection(items, filter)) item.title];

/// The titles of [items] in [sort]'s order.
List<String> _sorted(
  List<GameCollectionListItem> items,
  CollectionSort sort,
) => [for (final item in sortCollection(items, sort)) item.title];

void main() {
  group('CollectionFilter', () {
    test('the empty filter has no facet in use and does not narrow', () {
      expect(const CollectionFilter().facetsInUse, isEmpty);
      expect(const CollectionFilter().narrows, isFalse);
    });

    test('each facet is in use when it narrows', () {
      const inUse = {
        CollectionFacet.contentType: CollectionFilter(
          game: GameSearchFilter(contentTypes: {ContentType.expansion}),
        ),
        CollectionFacet.platformType: CollectionFilter(
          game: GameSearchFilter(platformTypes: {PlatformType.pc}),
        ),
        CollectionFacet.medium: CollectionFilter(
          mediums: {GameMedium.digital},
        ),
        CollectionFacet.publishYear: CollectionFilter(
          game: GameSearchFilter(publishYear: GameSearchRange(min: 2000)),
        ),
        CollectionFacet.playerCount: CollectionFilter(
          game: GameSearchFilter(playerCount: GameSearchRange(max: 4)),
        ),
        CollectionFacet.playTime: CollectionFilter(
          game: GameSearchFilter(playTime: GameSearchRange(min: 0)),
        ),
        CollectionFacet.missingBaseGame: CollectionFilter(
          missingBaseGame: true,
        ),
      };

      expect(inUse.keys, unorderedEquals(CollectionFacet.values));
      for (final MapEntry(key: facet, value: filter) in inUse.entries) {
        expect(filter.facetsInUse, {facet}, reason: '$facet');
        expect(filter.narrows, isTrue, reason: '$facet');
      }
    });

    test('a reversed range, or one with no bound, is not in use', () {
      const filter = CollectionFilter(
        game: GameSearchFilter(
          publishYear: GameSearchRange(min: 2010, max: 2000),
          playerCount: GameSearchRange(includeUnknown: true),
          playTime: GameSearchRange(min: 90, max: 30, includeUnknown: true),
        ),
      );

      expect(filter.facetsInUse, isEmpty);
      expect(filter.narrows, isFalse);
    });

    test('a query that is not blank narrows with no facet in use', () {
      expect(const CollectionFilter(query: 'cat').facetsInUse, isEmpty);
      expect(const CollectionFilter(query: 'cat').narrows, isTrue);
      expect(const CollectionFilter(query: '  ').narrows, isFalse);
    });

    test('a query of punctuation alone does not narrow', () {
      expect(const CollectionFilter(query: ':').narrows, isFalse);
      expect(const CollectionFilter(query: ' - : ').narrows, isFalse);
    });

    test('excluding a facet that is not in use puts nothing in use', () {
      final filter = CollectionFilter(
        excluded: CollectionFacet.values.toSet(),
      );

      expect(filter.facetsInUse, isEmpty);
      expect(filter.narrows, isFalse);
    });
  });

  group('filterCollection', () {
    test('nothing narrowing returns the same list', () {
      final items = [_item('Catan'), _item('Azul')];

      expect(
        identical(filterCollection(items, const CollectionFilter()), items),
        isTrue,
      );
      expect(
        identical(
          filterCollection(
            items,
            CollectionFilter(
              query: '   ',
              game: const GameSearchFilter(
                publishYear: GameSearchRange(min: 2010, max: 2000),
              ),
              excluded: CollectionFacet.values.toSet(),
            ),
          ),
          items,
        ),
        isTrue,
      );
    });

    test('a filter that narrows returns a new list in input order', () {
      final items = [
        _item('Zoo', medium: GameMedium.digital),
        _item('Azul'),
        _item('Moo', medium: GameMedium.digital),
      ];

      final result = filterCollection(
        items,
        const CollectionFilter(mediums: {GameMedium.digital}),
      );

      expect(identical(result, items), isFalse);
      expect([for (final item in result) item.title], ['Zoo', 'Moo']);
      expect(items, hasLength(3));
    });

    test('two facets are ANDed', () {
      final items = [
        _item(
          'Digital expansion',
          contentType: ContentType.expansion,
          medium: GameMedium.digital,
        ),
        _item('Physical expansion', contentType: ContentType.expansion),
        _item('Digital base', medium: GameMedium.digital),
      ];

      expect(
        _titles(
          items,
          const CollectionFilter(
            game: GameSearchFilter(contentTypes: {ContentType.expansion}),
            mediums: {GameMedium.digital},
          ),
        ),
        ['Digital expansion'],
      );
      expect(
        _titles(
          items,
          const CollectionFilter(
            game: GameSearchFilter(contentTypes: {ContentType.expansion}),
            mediums: {GameMedium.digital},
            excluded: {CollectionFacet.medium},
          ),
        ),
        ['Physical expansion'],
      );
    });

    group('query', () {
      final items = [
        _item('Catan', subtitle: 'Seafarers'),
        _item('Azul', subtitle: 'Summer Pavilion'),
        _item('Wingspan'),
      ];

      test('matches the title, ignoring case and the space around it', () {
        expect(_titles(items, const CollectionFilter(query: '  cAT ')), [
          'Catan',
        ]);
      });

      test('matches the subtitle', () {
        expect(_titles(items, const CollectionFilter(query: 'pavilion')), [
          'Azul',
        ]);
      });

      test('drops what matches in neither', () {
        expect(_titles(items, const CollectionFilter(query: 'gloom')), isEmpty);
      });

      test('a blank query matches everything', () {
        expect(_titles(items, const CollectionFilter(query: ' ')), [
          'Catan',
          'Azul',
          'Wingspan',
        ]);
      });

      test('is never flipped, whatever is excluded', () {
        expect(
          _titles(
            items,
            CollectionFilter(
              query: 'cat',
              excluded: CollectionFacet.values.toSet(),
            ),
          ),
          ['Catan'],
        );
      });

      test('finds a game by the name its row shows, each term in the title '
          'or the subtitle', () {
        for (final query in [
          'catan seafarers',
          'Catan: Seafarers',
          'catan sea',
          'seafarers catan',
        ]) {
          expect(
            _titles(items, CollectionFilter(query: query)),
            ['Catan'],
            reason: query,
          );
        }
      });

      test('drops an item when one term is in neither field', () {
        expect(
          _titles(items, const CollectionFilter(query: 'catan gloom')),
          isEmpty,
        );
      });

      test('a query of punctuation alone matches everything', () {
        final result = filterCollection(
          items,
          const CollectionFilter(query: ' : - '),
        );

        expect(identical(result, items), isTrue);
      });
    });

    group('contentType', () {
      final items = [
        _item('Catan'),
        _item('Seafarers', contentType: ContentType.expansion),
        _item('Moon DLC', contentType: ContentType.dlc),
      ];

      test('keeps the items whose content type the set names', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              game: GameSearchFilter(
                contentTypes: {ContentType.expansion, ContentType.dlc},
              ),
            ),
          ),
          ['Seafarers', 'Moon DLC'],
        );
      });

      test('drops the items whose content type it does not name', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              game: GameSearchFilter(contentTypes: {ContentType.bundle}),
            ),
          ),
          isEmpty,
        );
      });

      test('flipped, keeps the items whose content type it does not name', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              game: GameSearchFilter(contentTypes: {ContentType.expansion}),
              excluded: {CollectionFacet.contentType},
            ),
          ),
          ['Catan', 'Moon DLC'],
        );
      });

      test('reads every content type when given none', () {
        expect(
          _titles(
            items,
            const CollectionFilter(excluded: {CollectionFacet.contentType}),
          ),
          ['Catan', 'Seafarers', 'Moon DLC'],
        );
      });
    });

    group('platformType', () {
      final items = [
        _item('Catan', platformType: PlatformType.tabletop),
        _item('Hades', platformType: PlatformType.pc),
        _item('Old row'),
        _item('Mystery', platformType: PlatformType.unknown),
      ];

      test('keeps the items whose platform type the set names', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              game: GameSearchFilter(platformTypes: {PlatformType.pc}),
            ),
          ),
          ['Hades'],
        );
      });

      test('drops the items whose platform type it does not name', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              game: GameSearchFilter(platformTypes: {PlatformType.console}),
            ),
          ),
          isEmpty,
        );
      });

      test('flipped, keeps the items whose platform type it does not name', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              game: GameSearchFilter(platformTypes: {PlatformType.pc}),
              excluded: {CollectionFacet.platformType},
            ),
          ),
          ['Catan', 'Old row', 'Mystery'],
        );
      });

      test('a game with no platform type is dropped by Tabletop and kept by '
          'not-Tabletop', () {
        final noType = [_item('Old row')];
        const tabletop = GameSearchFilter(
          platformTypes: {PlatformType.tabletop},
        );

        expect(
          _titles(noType, const CollectionFilter(game: tabletop)),
          isEmpty,
        );
        expect(
          _titles(
            noType,
            const CollectionFilter(
              game: tabletop,
              excluded: {CollectionFacet.platformType},
            ),
          ),
          ['Old row'],
        );
      });

      test('an unknown platform type matches only a set that names it', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              game: GameSearchFilter(platformTypes: {PlatformType.unknown}),
            ),
          ),
          ['Mystery'],
        );
      });
    });

    group('medium', () {
      final items = [
        _item('Catan'),
        _item('Catan app', medium: GameMedium.digital),
      ];

      test("keeps the items whose entry's medium the set names", () {
        expect(
          _titles(
            items,
            const CollectionFilter(mediums: {GameMedium.digital}),
          ),
          ['Catan app'],
        );
      });

      test('drops the items whose medium it does not name', () {
        expect(
          _titles(
            [_item('Catan')],
            const CollectionFilter(mediums: {GameMedium.digital}),
          ),
          isEmpty,
        );
      });

      test('flipped, keeps the items whose medium it does not name', () {
        expect(
          _titles(
            items,
            const CollectionFilter(
              mediums: {GameMedium.digital},
              excluded: {CollectionFacet.medium},
            ),
          ),
          ['Catan'],
        );
      });
    });

    group('publishYear', () {
      final items = [
        _item('Game -2200', publishYear: -2200),
        _item('Game 1995', publishYear: 1995),
        _item('Game 2010', publishYear: 2010),
        _item('Game undated'),
      ];

      List<String> titles(GameSearchRange range, {bool flipped = false}) =>
          _titles(
            items,
            CollectionFilter(
              game: GameSearchFilter(publishYear: range),
              excluded: {if (flipped) CollectionFacet.publishYear},
            ),
          );

      test('a publish-year range keeps the years inside it, and undated '
          'games only when asked', () {
        expect(titles(const GameSearchRange(min: -3000, max: 2000)), [
          'Game -2200',
          'Game 1995',
        ]);
        expect(
          titles(
            const GameSearchRange(min: -3000, max: 2000, includeUnknown: true),
          ),
          ['Game -2200', 'Game 1995', 'Game undated'],
        );
      });

      test('a bound left out leaves that side open', () {
        expect(titles(const GameSearchRange(min: 2000)), ['Game 2010']);
        expect(titles(const GameSearchRange(max: 0)), ['Game -2200']);
      });

      test('drops the years outside it', () {
        expect(titles(const GameSearchRange(min: 2020, max: 2030)), isEmpty);
      });

      test('flipped, keeps what the range and its unknown arm do not', () {
        expect(
          titles(const GameSearchRange(min: -3000, max: 2000), flipped: true),
          ['Game 2010', 'Game undated'],
        );
        expect(
          titles(
            const GameSearchRange(min: -3000, max: 2000, includeUnknown: true),
            flipped: true,
          ),
          ['Game 2010'],
        );
      });
    });

    group('playerCount', () {
      List<String> titles(
        List<GameCollectionListItem> items,
        GameSearchRange range, {
        bool flipped = false,
      }) => _titles(
        items,
        CollectionFilter(
          game: GameSearchFilter(playerCount: range),
          excluded: {if (flipped) CollectionFacet.playerCount},
        ),
      );

      test('a single player-count bound is one count', () {
        final items = [
          _item('Game 2-6', minPlayers: 2, maxPlayers: 6),
          _item('Game 2-4', minPlayers: 2, maxPlayers: 4),
          _item('Game ?-6', maxPlayers: 6),
        ];

        expect(titles(items, const GameSearchRange(min: 5)), ['Game 2-6']);
        expect(titles(items, const GameSearchRange(max: 5)), ['Game 2-6']);
        expect(
          titles(items, const GameSearchRange(min: 5, includeUnknown: true)),
          ['Game 2-6', 'Game ?-6'],
        );
      });

      test('a player-count range needs every count in it', () {
        final items = [
          _item('Game 2-6', minPlayers: 2, maxPlayers: 6),
          _item('Game 2-4', minPlayers: 2, maxPlayers: 4),
        ];

        expect(titles(items, const GameSearchRange(min: 3, max: 5)), [
          'Game 2-6',
        ]);
      });

      test('flipped, keeps the games missing some count in it', () {
        final items = [
          _item('Game 2-6', minPlayers: 2, maxPlayers: 6),
          _item('Game 2-4', minPlayers: 2, maxPlayers: 4),
          _item('Game 1-2', minPlayers: 1, maxPlayers: 2),
        ];

        expect(
          titles(items, const GameSearchRange(min: 3, max: 5), flipped: true),
          ['Game 2-4', 'Game 1-2'],
        );
      });

      test('a game with no player counts follows includeUnknown, and the '
          'flip of it', () {
        final items = [_item('Game none')];
        const range = GameSearchRange(min: 2, max: 4);
        const orUnknown = GameSearchRange(min: 2, max: 4, includeUnknown: true);

        expect(titles(items, range), isEmpty);
        expect(titles(items, orUnknown), ['Game none']);
        expect(titles(items, range, flipped: true), ['Game none']);
        expect(titles(items, orUnknown, flipped: true), isEmpty);
      });

      test('one count missing makes a game unknown', () {
        final items = [_item('Game 2-?', minPlayers: 2)];

        expect(titles(items, const GameSearchRange(min: 2)), isEmpty);
        expect(
          titles(items, const GameSearchRange(min: 2, includeUnknown: true)),
          ['Game 2-?'],
        );
      });
    });

    group('playTime', () {
      final items = [
        _item('Game 30-60', minPlayTime: 30, maxPlayTime: 60),
        _item('Game 45-90', minPlayTime: 45, maxPlayTime: 90),
        _item('Game 90', maxPlayTime: 90),
        _item('Game none'),
      ];

      List<String> titles(
        GameSearchRange range, {
        List<GameCollectionListItem>? among,
        bool flipped = false,
      }) => _titles(
        among ?? items,
        CollectionFilter(
          game: GameSearchFilter(playTime: range),
          excluded: {if (flipped) CollectionFacet.playTime},
        ),
      );

      test('a play time fits when the whole time does', () {
        expect(titles(const GameSearchRange(max: 60)), ['Game 30-60']);
        expect(titles(const GameSearchRange(min: 45)), [
          'Game 45-90',
          'Game 90',
        ]);
        expect(titles(const GameSearchRange(min: 30, max: 90)), [
          'Game 30-60',
          'Game 45-90',
          'Game 90',
        ]);
        expect(
          titles(
            const GameSearchRange(min: 30, max: 90, includeUnknown: true),
          ),
          ['Game 30-60', 'Game 45-90', 'Game 90', 'Game none'],
        );
      });

      test('a game with one play time uses it for both ends', () {
        final one = [_item('Game 120', minPlayTime: 120)];

        expect(titles(const GameSearchRange(min: 100), among: one), [
          'Game 120',
        ]);
        expect(titles(const GameSearchRange(max: 100), among: one), isEmpty);
      });

      test('drops the times outside it', () {
        expect(titles(const GameSearchRange(min: 100, max: 200)), isEmpty);
      });

      test('flipped, keeps what the range and its unknown arm do not', () {
        expect(titles(const GameSearchRange(max: 60), flipped: true), [
          'Game 45-90',
          'Game 90',
          'Game none',
        ]);
        expect(
          titles(
            const GameSearchRange(max: 60, includeUnknown: true),
            flipped: true,
          ),
          ['Game 45-90', 'Game 90'],
        );
      });
    });

    group('missingBaseGame', () {
      const missing = CollectionFilter(missingBaseGame: true);
      const notMissing = CollectionFilter(
        missingBaseGame: true,
        excluded: {CollectionFacet.missingBaseGame},
      );

      test('missing base game reads the whole list', () {
        final items = [
          _item('Catan'),
          _item(
            'Seafarers',
            contentType: ContentType.expansion,
            baseGames: [_link('Catan')],
          ),
          _item(
            'Tides',
            contentType: ContentType.expansion,
            baseGames: [_link('Gone')],
          ),
        ];

        expect(_titles(items, missing), ['Tides']);
        // The query drops Catan, but Seafarers' base game is still in the
        // list the filter was given.
        expect(
          _titles(
            items,
            const CollectionFilter(query: 'e', missingBaseGame: true),
          ),
          ['Tides'],
        );
      });

      test('flipped, keeps the items that are not missing their base', () {
        final items = [
          _item('Catan'),
          _item(
            'Seafarers',
            contentType: ContentType.expansion,
            baseGames: [_link('Catan')],
          ),
          _item(
            'Tides',
            contentType: ContentType.expansion,
            baseGames: [_link('Gone')],
          ),
        ];

        expect(_titles(items, notMissing), ['Catan', 'Seafarers']);
      });

      test('an item with no base game matches when it is an expansion or '
          'DLC', () {
        final items = [
          _item('Lone expansion', contentType: ContentType.expansion),
          _item('Lone DLC', contentType: ContentType.dlc),
          _item('Lone base'),
          _item('Lone mod', contentType: ContentType.mod),
        ];

        expect(_titles(items, missing), ['Lone expansion', 'Lone DLC']);
        expect(_titles(items, notMissing), ['Lone base', 'Lone mod']);
      });

      test('a link to the item itself is no link', () {
        final items = [
          _item(
            'Self expansion',
            contentType: ContentType.expansion,
            baseGames: [_link('Self expansion')],
          ),
          _item('Self base', baseGames: [_link('Self base')]),
        ];

        expect(_titles(items, missing), ['Self expansion']);
      });

      test('a standalone item never matches', () {
        final items = [
          _item(
            'By content type',
            contentType: ContentType.standaloneExpansion,
            baseGames: [_link('Gone')],
          ),
          _item(
            'By link',
            contentType: ContentType.expansion,
            baseGames: [_link('Gone', standalone: true)],
          ),
        ];

        expect(_titles(items, missing), isEmpty);
        expect(_titles(items, notMissing), ['By content type', 'By link']);
      });

      test('an expansion of two base games matches only with both absent', () {
        final items = [
          _item('Catan'),
          _item(
            'One present',
            contentType: ContentType.expansion,
            baseGames: [_link('Catan'), _link('Gone')],
          ),
          _item(
            'Both absent',
            contentType: ContentType.expansion,
            baseGames: [_link('Gone'), _link('Lost')],
          ),
        ];

        expect(_titles(items, missing), ['Both absent']);
      });

      test('picks out exactly the games placeExpansions marks as missing '
          'their base', () {
        final items = [
          _item('Lone expansion', contentType: ContentType.expansion),
          _item('Lone DLC', contentType: ContentType.dlc),
          _item('Lone base'),
          _item(
            'Standalone',
            contentType: ContentType.standaloneExpansion,
            baseGames: [_link('Gone')],
          ),
          _item(
            'Self',
            contentType: ContentType.expansion,
            baseGames: [_link('Self')],
          ),
          _item(
            'Present',
            contentType: ContentType.expansion,
            baseGames: [_link('Lone base'), _link('Lone base')],
          ),
          _item(
            'Absent',
            id: 'e-absent-1',
            contentType: ContentType.expansion,
            baseGames: [_link('Gone')],
          ),
          _item(
            'Absent',
            id: 'e-absent-2',
            contentType: ContentType.expansion,
            baseGames: [_link('Gone')],
            medium: GameMedium.digital,
          ),
          _item(
            'Two bases',
            contentType: ContentType.expansion,
            baseGames: [_link('Lone base'), _link('Gone')],
          ),
        ];

        final filtered = filterCollection(items, missing);

        // placeExpansions takes one item per game.
        final seen = <String>{};
        final games = [
          for (final item in items)
            if (seen.add(item.gameId)) item,
        ];
        final marked = {
          for (final placed in placeExpansions<GameCollectionListItem>(
            games,
            gameIdOf: (item) => item.gameId,
            baseGamesOf: (item) => item.baseGames,
            contentTypeOf: (item) => item.contentType,
          ))
            if (placed.missingBase) placed.item.gameId,
        };

        expect({for (final item in filtered) item.gameId}, marked);
        expect(marked, {
          'g-Lone expansion',
          'g-Lone DLC',
          'g-Self',
          'g-Absent',
        });
        expect(
          [for (final item in filtered) item.entry.id],
          [
            'e-Lone expansion',
            'e-Lone DLC',
            'e-Self',
            'e-absent-1',
            'e-absent-2',
          ],
        );
      });
    });
  });

  group('sortCollection', () {
    test('title keeps the input order and returns the same list', () {
      final items = [_item('Zoo'), _item('Azul')];

      expect(
        identical(sortCollection(items, CollectionSort.title), items),
        isTrue,
      );
    });

    test('a sort returns a new list and leaves its input alone', () {
      final items = [_item('Low', rating: 1), _item('High', rating: 9)];

      final sorted = sortCollection(items, CollectionSort.rating);

      expect(identical(sorted, items), isFalse);
      expect([for (final item in sorted) item.title], ['High', 'Low']);
      expect([for (final item in items) item.title], ['Low', 'High']);
    });

    test('recentlyAdded puts the newest entry first, ties in title '
        'order', () {
      final items = [
        _item('Azul', createdAt: _epoch),
        _item('Catan', createdAt: _epoch.add(const Duration(days: 2))),
        _item('Dune', createdAt: _epoch.add(const Duration(days: 1))),
        _item('Everdell', createdAt: _epoch.add(const Duration(days: 2))),
      ];

      expect(_sorted(items, CollectionSort.recentlyAdded), [
        'Catan',
        'Everdell',
        'Dune',
        'Azul',
      ]);
    });

    test('playTime puts the shortest first by the minimum, else the maximum, '
        'missing last, ties in title order', () {
      final items = [
        _item('Azul', minPlayTime: 30, maxPlayTime: 45),
        _item('Brass'),
        _item('Catan', minPlayTime: 60, maxPlayTime: 120),
        _item('Dune', maxPlayTime: 20),
        _item('Everdell', minPlayTime: 30, maxPlayTime: 90),
      ];

      expect(_sorted(items, CollectionSort.playTime), [
        'Dune',
        'Azul',
        'Everdell',
        'Catan',
        'Brass',
      ]);
    });

    test('minPlayers puts the fewest first, missing last, ties in title '
        'order', () {
      final items = [
        _item('Azul', minPlayers: 2, maxPlayers: 4),
        _item('Brass', maxPlayers: 4),
        _item('Catan', minPlayers: 3, maxPlayers: 4),
        _item('Dune', minPlayers: 1, maxPlayers: 6),
        _item('Everdell', minPlayers: 2, maxPlayers: 6),
      ];

      expect(_sorted(items, CollectionSort.minPlayers), [
        'Dune',
        'Azul',
        'Everdell',
        'Catan',
        'Brass',
      ]);
    });

    test('maxPlayers puts the most first, missing last, ties in title '
        'order', () {
      final items = [
        _item('Azul', minPlayers: 2, maxPlayers: 4),
        _item('Brass', minPlayers: 2),
        _item('Catan', minPlayers: 3, maxPlayers: 6),
        _item('Dune', minPlayers: 1, maxPlayers: 2),
        _item('Everdell', minPlayers: 1, maxPlayers: 4),
      ];

      expect(_sorted(items, CollectionSort.maxPlayers), [
        'Catan',
        'Azul',
        'Everdell',
        'Dune',
        'Brass',
      ]);
    });

    test('rating puts the highest first, missing last, ties in title '
        'order', () {
      final items = [
        _item('Azul', rating: 7),
        _item('Brass'),
        _item('Catan', rating: 9),
        _item('Dune', rating: 3),
        _item('Everdell', rating: 7),
      ];

      expect(_sorted(items, CollectionSort.rating), [
        'Catan',
        'Azul',
        'Everdell',
        'Dune',
        'Brass',
      ]);
    });

    test('every sort keeps ties in input order on a long list, and leaves '
        'its input alone', () {
      // Long enough that List.sort leaves insertion sort for an unstable
      // one, with few distinct values so most items tie.
      final items = [
        for (var i = 0; i < 100; i++)
          _item(
            'Game ${i.toString().padLeft(3, '0')}',
            createdAt: _epoch.add(Duration(days: i % 3)),
            rating: i % 5 == 0 ? null : i % 3,
            minPlayers: i % 7 == 0 ? null : 1 + i % 2,
            maxPlayers: i % 6 == 0 ? null : 4 + i % 3,
            minPlayTime: i % 4 == 0 ? null : 30 * (1 + i % 2),
            maxPlayTime: i % 8 == 0 ? null : 90,
          ),
      ];
      final keys = <CollectionSort, Object? Function(GameCollectionListItem)>{
        CollectionSort.recentlyAdded: (item) => item.entry.createdAt,
        CollectionSort.playTime: (item) => item.minPlayTime ?? item.maxPlayTime,
        CollectionSort.minPlayers: (item) => item.minPlayers,
        CollectionSort.maxPlayers: (item) => item.maxPlayers,
        CollectionSort.rating: (item) => item.entry.rating,
      };
      final original = [...items];

      for (final MapEntry(key: sort, value: keyOf) in keys.entries) {
        final sorted = sortCollection(items, sort);
        expect(items, original, reason: '$sort leaves its input alone');
        expect(sorted, unorderedEquals(items), reason: '$sort');
        for (var i = 1; i < sorted.length; i++) {
          final (before, after) = (sorted[i - 1], sorted[i]);
          if (keyOf(before) != keyOf(after)) continue;
          expect(
            items.indexOf(before),
            lessThan(items.indexOf(after)),
            reason: '$sort: ${before.title} before ${after.title}',
          );
        }
      }
    });
  });

  group('matchesSearchTerms', () {
    test('needs every term in one field or another, ignoring case', () {
      expect(matchesSearchTerms('catan sea', ['Catan', 'Seafarers']), isTrue);
      expect(matchesSearchTerms('SEA catan', ['Catan', 'Seafarers']), isTrue);
      expect(
        matchesSearchTerms('catan gloom', ['Catan', 'Seafarers']),
        isFalse,
      );
    });

    test('strips the punctuation around a term, not inside it', () {
      expect(matchesSearchTerms('"Catan:"', ['Catan']), isTrue);
      expect(matchesSearchTerms('7-wonders', ['7 Wonders']), isFalse);
      expect(matchesSearchTerms('7-wonders', ['7-Wonders Duel']), isTrue);
    });

    test('skips a field that is null', () {
      expect(matchesSearchTerms('catan', [null, 'Catan']), isTrue);
      expect(matchesSearchTerms('catan', [null]), isFalse);
    });

    test('a query with no terms matches everything', () {
      expect(matchesSearchTerms('', const []), isTrue);
      expect(matchesSearchTerms('  ', ['Catan']), isTrue);
      expect(matchesSearchTerms(' : - ', ['Catan']), isTrue);
    });
  });
}
