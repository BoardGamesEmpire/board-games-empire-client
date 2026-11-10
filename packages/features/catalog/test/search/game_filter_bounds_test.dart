import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';
import 'package:network_interface/network_interface.dart';

/// `game_filters` may not depend on `network_interface`, so it writes the
/// server's search bounds as literals. The catalog depends on both, so it is
/// here that they are held together.
void main() {
  test("the filter sheet's bounds are the server's", () {
    expect(
      GameFilterOptions.defaultMaxRangeBound,
      GamesRemoteDataSource.maxRangeBound,
    );
    expect(
      GameFilterOptions.minRangeBound,
      GamesRemoteDataSource.minRangeBound,
    );
    expect(
      GameFilterOptions.minPlayerCount,
      GamesRemoteDataSource.minPlayerCount,
    );
    expect(GameFilterOptions.minPlayTime, GamesRemoteDataSource.minPlayTime);
  });
}
