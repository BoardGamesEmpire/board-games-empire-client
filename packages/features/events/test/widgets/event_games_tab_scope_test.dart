import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

/// What the Games tab keeps across the screen's rebuilds (#516), and how its
/// filter takes each change (#851).
void main() {
  test("the filter sheet's facets leave the search field's query as it "
      'was', () {
    final controller = EventGamesTabController();
    addTearDown(controller.dispose);

    controller
      ..setQuery('catan')
      ..setGameFilter(
        const CollectionFilter(
          query: 'root',
          mediums: {GameMedium.digital},
        ),
      );

    expect(controller.filter.query, 'catan');
    expect(controller.filter.game.mediums, {GameMedium.digital});
  });
}
