import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/src/add/starting_medium.dart';
import 'package:models/domain.dart';

/// Pins #708's starting medium: Tabletop starts on Physical, any other known
/// type on Digital, and a platform with no type stored on nothing, so the
/// user picks. A start that isn't free gives way to the one that is.
void main() {
  const both = {GameMedium.physical, GameMedium.digital};

  for (final (type, free, result)
      in <(PlatformType?, Set<GameMedium>, GameMedium?)>[
        (PlatformType.tabletop, both, GameMedium.physical),
        (PlatformType.pc, both, GameMedium.digital),
        // A type this client can't read is still not Tabletop.
        (PlatformType.unknown, both, GameMedium.digital),
        (null, both, null),
        (PlatformType.tabletop, {GameMedium.digital}, GameMedium.digital),
        (null, {GameMedium.physical}, GameMedium.physical),
      ]) {
    test('${type?.name ?? 'no type'} with ${free.map((m) => m.name)} free '
        'starts on ${result?.name ?? 'nothing'}', () {
      expect(startingMedium(type, free), result);
    });
  }
}
