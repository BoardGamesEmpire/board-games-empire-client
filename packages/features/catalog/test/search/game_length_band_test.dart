import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/search/game_length_band.dart';
import 'package:models/domain.dart';

void main() {
  test("the bands are the server's seven, in order", () {
    // backend libs/database/src/lib/seeds/game-lengths.seed.ts at 997cc084.
    expect(
      [
        for (final band in GameLengthBand.values)
          (band.name, band.minMinutes, band.maxMinutes),
      ],
      [
        ('filler', 0, 15),
        ('quick', 15, 30),
        ('short', 30, 60),
        ('medium', 60, 120),
        ('long', 120, 240),
        ('epic', 240, 480),
        ('marathon', 480, null),
      ],
    );
  });

  test('a band is the range it sends, keeping no unknown values', () {
    expect(
      GameLengthBand.medium.range,
      const GameSearchRange(min: 60, max: 120),
    );
    expect(GameLengthBand.marathon.range, const GameSearchRange(min: 480));
  });

  test('matching finds a band by its bounds alone', () {
    expect(
      GameLengthBand.matching(const GameSearchRange(min: 60, max: 120)),
      GameLengthBand.medium,
    );
    expect(
      GameLengthBand.matching(
        const GameSearchRange(min: 60, max: 120, includeUnknown: true),
      ),
      GameLengthBand.medium,
    );
    expect(
      GameLengthBand.matching(const GameSearchRange(min: 60, max: 100)),
      isNull,
    );
    expect(
      GameLengthBand.matching(const GameSearchRange(min: 480)),
      GameLengthBand.marathon,
    );
    expect(GameLengthBand.matching(const GameSearchRange()), isNull);
  });
}
