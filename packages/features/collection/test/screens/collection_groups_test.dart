import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/src/screens/collection_groups.dart';

import '../support/list_items.dart';

/// Pins #709's grouping: the collection shows a game owned more than once as
/// one item, so the list's entries are gathered by game before they are
/// drawn.
void main() {
  test("groups by game, at the first item's place", () {
    final a1 = listItem('a-1', gameId: 'g-a', title: 'Azul');
    final b1 = listItem('b-1', gameId: 'g-b', title: 'Brass');
    final a2 = listItem('a-2', gameId: 'g-a', title: 'Azul');

    expect(groupByGame([a1, b1, a2]), [
      [a1, a2],
      [b1],
    ]);
  });

  test('a game owned once is a group of one, and order is kept', () {
    final a = listItem('a-1');
    final b = listItem('b-1');
    final c = listItem('c-1');

    expect(groupByGame([a, b, c]), [
      [a],
      [b],
      [c],
    ]);
  });

  test('no entries are no groups', () {
    expect(groupByGame(const []), isEmpty);
  });
}
