import 'package:dio_network/src/games/game_search_wire.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  test('searchFilterFields keeps types and omits unset ranges', () {
    final fields = searchFilterFields(
      const GameSearchFilter(
        contentTypes: {ContentType.baseGame, ContentType.expansion},
        platformTypes: {PlatformType.pc},
        publishYear: GameSearchRange(min: 1990, max: 1999),
        playerCount: GameSearchRange(min: 2, includeUnknown: true),
      ),
    );

    expect(fields, {
      'contentTypes': ['BaseGame', 'Expansion'],
      'platformTypes': ['PC'],
      'publishYearMin': 1990,
      'publishYearMax': 1999,
      'playerCountMin': 2,
      'playerCountIncludeUnknown': true,
    });
    expect(searchFilterFields(const GameSearchFilter()), isEmpty);
  });
}
