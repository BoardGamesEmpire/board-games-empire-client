import 'package:models/domain.dart';

/// The medium the add pop-up starts on for a platform of [type] with [free]
/// mediums still to add, or null to leave the choice to the user (#708).
///
/// A board game is most often a box, so Tabletop starts on Physical, and
/// every other known type on Digital. [PlatformType.unknown] is a type this
/// client can't read, which is still not Tabletop. A platform with no type
/// stored starts on nothing: a wrong start on a Tabletop game is the more
/// costly mistake, and an empty required field costs only a choice.
///
/// A start that is owned already gives way to the free one, and a platform
/// with one free medium starts on it whatever its type. It is only a start:
/// the user can change it, as a PS4 disc is physical.
GameMedium? startingMedium(PlatformType? type, Set<GameMedium> free) {
  if (free.length == 1) return free.single;
  final start = switch (type) {
    PlatformType.tabletop => GameMedium.physical,
    null => null,
    _ => GameMedium.digital,
  };
  // With both free, any start is. An empty set, which an option never has,
  // starts on nothing.
  return free.contains(start) ? start : null;
}
