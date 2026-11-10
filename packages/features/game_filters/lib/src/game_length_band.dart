import 'package:models/domain.dart';

/// The server's game-length bands, copied from backend
/// `libs/database/src/lib/seeds/game-lengths.seed.ts`; nothing detects drift
/// (#263, #580).
///
/// The seed's rows are served by no route, so the play-time filter offers
/// these as a constant. A band is only a quick way to set the range: the
/// server takes its minutes, never a band id.
enum GameLengthBand {
  filler(0, 15),
  quick(15, 30),
  short(30, 60),
  medium(60, 120),
  long(120, 240),
  epic(240, 480),

  /// Open-ended: it sends a minimum alone.
  marathon(480, null);

  const GameLengthBand(this.minMinutes, this.maxMinutes);

  final int minMinutes;
  final int? maxMinutes;

  /// The play-time range the band sends, keeping no unknown values.
  GameSearchRange get range =>
      GameSearchRange(min: minMinutes, max: maxMinutes);

  /// The band whose bounds [range] has, whether or not it keeps unknown
  /// values, or null for a custom range.
  static GameLengthBand? matching(GameSearchRange range) {
    for (final band in values) {
      if (band.minMinutes == range.min && band.maxMinutes == range.max) {
        return band;
      }
    }
    return null;
  }
}
