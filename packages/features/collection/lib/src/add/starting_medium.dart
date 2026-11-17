import 'package:models/domain.dart';

/// The medium the add pop-up starts on for a platform of [type] with [free]
/// mediums still to add, or null to leave the choice to the user (#708).
///
/// Every known type starts on Digital, including [PlatformType.unknown], a
/// type this client can't read. A platform with no type stored starts on
/// nothing: a wrong start is the more costly mistake, and an empty required
/// field costs only a choice.
///
/// A start that is owned already gives way to the free one, and a platform
/// with one free medium starts on it whatever its type. That is how Tabletop,
/// which offers Physical only, starts on Physical (#797). It is only a start
/// where there is a choice: the user can change it, as a PS4 disc is
/// physical.
GameMedium? startingMedium(PlatformType? type, Set<GameMedium> free) {
  if (free.length == 1) return free.single;
  final start = switch (type) {
    null => null,
    _ => GameMedium.digital,
  };
  // With both free, any start is. An empty set, which an option never has,
  // starts on nothing.
  return free.contains(start) ? start : null;
}
