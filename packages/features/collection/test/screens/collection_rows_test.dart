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
}
