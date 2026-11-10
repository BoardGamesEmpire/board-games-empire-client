import 'package:flutter/foundation.dart';
import 'package:models/domain.dart';

/// What the filter sheet offers, and so what the chips naming the filters in
/// use can name (#474, #715).
///
/// The defaults are the game search's: every content type and platform type
/// it can send, and the highest bound the server accepts.
///
/// [medium], [missingBaseGame] and [exclusion] are off by default: the game
/// search's sheet has none of them. The collection's filters (#715) turn on
/// all three. The Offer games page (#516) turns on [medium] and [exclusion],
/// and leaves [missingBaseGame] off.
@immutable
class GameFilterOptions {
  const GameFilterOptions({
    this.contentTypes = searchContentTypes,
    this.platformTypes = searchPlatformTypes,
    this.maxRangeBound = defaultMaxRangeBound,
    this.medium = false,
    this.missingBaseGame = false,
    this.exclusion = false,
  });

  /// The content types the game search offers, in this order: the board-game
  /// kinds, then the video-game ones.
  static const List<ContentType> searchContentTypes = [
    ContentType.baseGame,
    ContentType.expansion,
    ContentType.standaloneExpansion,
    ContentType.expandedEdition,
    ContentType.accessory,
    ContentType.bundle,
    ContentType.dlc,
    ContentType.mod,
    ContentType.port,
    ContentType.remake,
    ContentType.remaster,
  ];

  /// The platform types the game search offers, in the backend's order:
  /// every one but unknown, which names none.
  static const List<PlatformType> searchPlatformTypes = [
    PlatformType.tabletop,
    PlatformType.console,
    PlatformType.portable,
    PlatformType.pc,
    PlatformType.mobile,
    PlatformType.arcade,
    PlatformType.other,
  ];

  /// The highest bound a search range may name: the server carries each as
  /// an int32 (#565, #580).
  ///
  /// It equals `GamesRemoteDataSource.maxRangeBound`, written out because
  /// this package doesn't depend on the data layer; a test in the catalog
  /// package, which depends on both, holds the two together. So do the
  /// lowest bounds below.
  static const int defaultMaxRangeBound = 2147483647;

  /// The lowest bound a search range may name, the int32 floor: the lowest
  /// publish year the sheet takes.
  static const int minRangeBound = -2147483648;

  /// The fewest players a player-count range may name.
  static const int minPlayerCount = 1;

  /// The shortest play time, in minutes, a play-time range may name.
  static const int minPlayTime = 0;

  /// The content types the sheet offers, in the order it offers them.
  final List<ContentType> contentTypes;

  /// The platform types the sheet offers, in the order it offers them.
  final List<PlatformType> platformTypes;

  /// The highest bound a range field accepts.
  final int maxRangeBound;

  /// Whether the sheet offers to narrow by a collection entry's medium,
  /// [CollectionFilter.mediums]. A game search result has no medium.
  final bool medium;

  /// Whether the sheet offers to keep only the expansions shown without
  /// their base game, [CollectionFilter.missingBaseGame].
  final bool missingBaseGame;

  /// Whether each section offers to leave out what it matches instead of
  /// keeping it, putting its facet in [CollectionFilter.excluded]. The chips
  /// say "Not" for a flipped facet whether or not this is on.
  final bool exclusion;
}
