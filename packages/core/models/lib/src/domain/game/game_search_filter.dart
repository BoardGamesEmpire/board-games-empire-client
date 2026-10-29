import 'package:freezed_annotation/freezed_annotation.dart';

import 'content_type.dart';
import 'platform_type.dart';

part 'game_search_filter.freezed.dart';

/// An inclusive range a search narrows by (#565, #580). Either bound may be
/// left out.
///
/// What a bound left out means is the axis's own rule: a publish year or a
/// play time is open on that side, while a single player count is one count.
/// [includeUnknown] keeps the games with no value, and with neither bound
/// the range narrows nothing, so it is not sent.
@freezed
abstract class GameSearchRange with _$GameSearchRange {
  const GameSearchRange._();

  const factory GameSearchRange({
    int? min,
    int? max,
    @Default(false) bool includeUnknown,
  }) = _GameSearchRange;

  /// Whether the range names a bound, which is what makes it a filter.
  bool get narrows => min != null || max != null;

  /// Whether both bounds are set and the minimum is above the maximum, which
  /// the server refuses.
  bool get isReversed {
    final (min, max) = (this.min, this.max);
    return min != null && max != null && min > max;
  }
}

/// What a search is narrowed to (#42, #474). An empty set or a range that
/// doesn't narrow is no filter.
///
/// A game matches a set when it has any value the set names, and the filter
/// when it matches every set and range that narrows.
@freezed
abstract class GameSearchFilter with _$GameSearchFilter {
  const GameSearchFilter._();

  const factory GameSearchFilter({
    @Default(<ContentType>{}) Set<ContentType> contentTypes,
    @Default(<PlatformType>{}) Set<PlatformType> platformTypes,

    /// Publish years, negative before the common era (#565).
    @Default(GameSearchRange()) GameSearchRange publishYear,

    /// Player counts, every one of which a game must support (#580).
    @Default(GameSearchRange()) GameSearchRange playerCount,

    /// Play time in minutes, which a game's whole play time must fit (#580).
    @Default(GameSearchRange()) GameSearchRange playTime,
  }) = _GameSearchFilter;

  /// Whether any axis narrows the search.
  bool get narrows =>
      contentTypes.isNotEmpty ||
      platformTypes.isNotEmpty ||
      publishYear.narrows ||
      playerCount.narrows ||
      playTime.narrows;
}
