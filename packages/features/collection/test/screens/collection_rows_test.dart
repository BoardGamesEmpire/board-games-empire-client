import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/src/screens/collection_rows.dart';
import 'package:models/domain.dart';

import '../support/list_items.dart';

/// Pins #711's placement in the collection: an owned expansion follows its
/// owned base game, matched by game rather than by platform.
void main() {
  const link = [ExpansionLink(gameId: 'g-base', isStandalone: false)];

  final base = listItem('b-1', gameId: 'g-base', title: 'Wingspan');
  final expansion = listItem(
    'x-1',
    gameId: 'g-exp',
    title: 'European Expansion',
    contentType: ContentType.expansion,
    baseGames: link,
  );

  test('an owned expansion follows its owned base game', () {
    final rows = collectionRows([expansion, base]);

    expect(rows.map((r) => r.group.first.entry.id), ['b-1', 'x-1']);
    expect(rows[0].parentGameId, isNull);
    expect(rows[1].parentGameId, 'g-base');
    expect(rows[1].parentTitle, 'Wingspan');
    expect(rows[1].missingBase, isFalse);
  });

  test('a list is placed once, however often it is asked for', () {
    final items = [expansion, base];

    expect(placeCollection(items), same(placeCollection(items)));
    // Another list, even with the same items, is placed for itself.
    expect(placeCollection([...items]), isNot(same(placeCollection(items))));
  });

  test('matched by game, not platform', () {
    final steamBase = listItem(
      'b-1',
      gameId: 'g-base',
      title: 'Wingspan',
      platformName: 'Steam',
    );
    final tabletopExpansion = listItem(
      'x-1',
      gameId: 'g-exp',
      platformName: 'Tabletop',
      contentType: ContentType.expansion,
      baseGames: link,
    );

    final rows = collectionRows([steamBase, tabletopExpansion]);

    expect(rows[1].parentGameId, 'g-base');
  });

  test('an expansion owned twice nests as one stack', () {
    final second = listItem(
      'x-2',
      gameId: 'g-exp',
      title: 'European Expansion',
      contentType: ContentType.expansion,
      baseGames: link,
    );

    final rows = collectionRows([base, expansion, second]);

    expect(rows, hasLength(2));
    expect(rows[1].group, [expansion, second]);
    expect(rows[1].parentGameId, 'g-base');
  });

  test('an expansion without its base game owned is top level and marked', () {
    final rows = collectionRows([expansion]);

    expect(rows, hasLength(1));
    expect(rows.single.parentGameId, isNull);
    expect(rows.single.missingBase, isTrue);
  });

  test('an unlinked DLC is top level and marked', () {
    final dlc = listItem('d-1', gameId: 'g-dlc', contentType: ContentType.dlc);

    final rows = collectionRows([dlc]);

    expect(rows.single.parentGameId, isNull);
    expect(rows.single.missingBase, isTrue);
  });

  test('a standalone expansion is top level and not marked', () {
    final standalone = listItem(
      's-1',
      gameId: 'g-s',
      contentType: ContentType.standaloneExpansion,
    );

    expect(collectionRows([standalone]).single.missingBase, isFalse);
  });

  test('the parent title is what titleOf makes of the parent', () {
    final rows = collectionRows([
      base,
      expansion,
    ], titleOf: (item) => '${item.title}!');

    expect(rows[1].parentTitle, 'Wingspan!');
  });

  group('a filtered list, with the whole collection beside it (#715)', () {
    final other = listItem('o-1', gameId: 'g-other', title: 'Azul');

    test('an expansion whose base game a filter hid is top level and '
        'unmarked', () {
      final rows = collectionRows([expansion], all: [base, expansion]);

      expect(rows, hasLength(1));
      expect(rows.single.group, [expansion]);
      expect(rows.single.parentGameId, isNull);
      expect(rows.single.missingBase, isFalse);
    });

    test("an expansion whose base game isn't owned stays marked under a "
        'filter', () {
      final rows = collectionRows([expansion], all: [expansion, other]);

      expect(rows.single.parentGameId, isNull);
      expect(rows.single.missingBase, isTrue);
    });

    test('an expansion with no base links at all stays marked', () {
      final dlc = listItem(
        'd-1',
        gameId: 'g-dlc',
        contentType: ContentType.dlc,
      );

      final rows = collectionRows([dlc], all: [base, dlc, other]);

      expect(rows.single.missingBase, isTrue);
    });

    test('an expansion the whole collection leaves unmarked is unmarked '
        'when a filter keeps it alone', () {
      // Each lists the other as its base game: in the whole collection the
      // two are a cycle, top level and unmarked. Kept alone, one has no
      // base game in the list, and its placement there marks it.
      final a = listItem(
        'a-1',
        gameId: 'g-a',
        contentType: ContentType.expansion,
        baseGames: const [ExpansionLink(gameId: 'g-b', isStandalone: false)],
      );
      final b = listItem(
        'b-1',
        gameId: 'g-b',
        contentType: ContentType.expansion,
        baseGames: const [ExpansionLink(gameId: 'g-a', isStandalone: false)],
      );
      expect(collectionRows([a]).single.missingBase, isTrue);

      final rows = collectionRows([a], all: [a, b]);

      expect(rows.single.group, [a]);
      expect(rows.single.missingBase, isFalse);
    });

    test('a stack is made of the entries that matched', () {
      final digital = listItem(
        'b-2',
        gameId: 'g-base',
        title: 'Wingspan',
        medium: GameMedium.digital,
      );

      final rows = collectionRows([base], all: [base, digital]);

      expect(rows, hasLength(1));
      expect(rows.single.group, [base]);
    });

    test('a list placed with all is placed once', () {
      final items = [expansion];
      final all = [base, expansion];

      expect(
        placeCollection(items, all: all),
        same(placeCollection(items, all: all)),
      );
    });

    test('one list placed from another whole is placed again, for that '
        'whole', () {
      // The answer kept for a list is the one for the whole it was placed
      // from: the first call never decides the marker for a later one.
      final items = [expansion];
      final owned = [base, expansion];
      final unowned = [expansion, other];

      expect(placeCollection(items, all: owned).single.missingBase, isFalse);
      expect(placeCollection(items, all: unowned).single.missingBase, isTrue);
      expect(placeCollection(items).single.missingBase, isTrue);
      expect(placeCollection(items, all: owned).single.missingBase, isFalse);
      expect(
        placeCollection(items, all: owned),
        same(placeCollection(items, all: owned)),
      );
    });

    test('all left out and all that is items itself are the same', () {
      final items = [expansion, base];
      placeCollection(items);

      expect(placeCollection(items, all: items), same(placeCollection(items)));
    });

    test('an all that is items itself places the list once', () {
      final items = _CountingList([expansion, base]);

      final placed = placeCollection(items, all: items);

      expect(items.reads, 1);
      expect(placed.map((p) => p.item.first.entry.id), ['b-1']);
    });

    test('the whole collection is read once per list shown from it, for '
        'its game ids, and not again for the same list', () {
      final all = _CountingList([base, expansion, other]);
      final shown = [expansion];

      placeCollection(shown, all: all);
      placeCollection(shown, all: all);
      expect(all.reads, 1);

      placeCollection([expansion, other], all: all);
      expect(all.reads, 2);
    });
  });
}

/// A list that counts how often it is iterated, to tell how often it was
/// read: placing a list reads it once, and so does gathering its game ids.
class _CountingList extends ListBase<GameCollectionListItem> {
  _CountingList(this._items);

  final List<GameCollectionListItem> _items;

  int reads = 0;

  @override
  int get length => _items.length;

  @override
  set length(int value) => _items.length = value;

  @override
  GameCollectionListItem operator [](int index) => _items[index];

  @override
  void operator []=(int index, GameCollectionListItem value) =>
      _items[index] = value;

  @override
  Iterator<GameCollectionListItem> get iterator {
    reads++;
    return super.iterator;
  }
}
