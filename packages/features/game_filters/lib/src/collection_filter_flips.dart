import 'package:models/domain.dart';

/// [filter] with every flip dropped whose facet has nothing chosen (#715).
///
/// A facet may be in [CollectionFilter.excluded] only while something is
/// chosen for it: a type or a medium, a range bound, or the missing-base
/// switch on. So a flip goes with its facet's last choice, in the same
/// change, and a filter chosen later never starts out flipped. A range whose
/// bounds are reversed still has them chosen, so it keeps its flip, though
/// it narrows nothing. The sheet's range field never sends reversed bounds,
/// so such a range only arrives in a filter handed in.
///
/// The sheet passes every edit through this, and each chip passes the
/// filter it hands back.
CollectionFilter withoutIdleFlips(CollectionFilter filter) {
  final kept = {
    for (final facet in filter.excluded)
      if (_hasChoice(filter, facet)) facet,
  };
  return kept.length == filter.excluded.length
      ? filter
      : filter.copyWith(excluded: kept);
}

bool _hasChoice(CollectionFilter filter, CollectionFacet facet) {
  final game = filter.game;
  return switch (facet) {
    CollectionFacet.contentType => game.contentTypes.isNotEmpty,
    CollectionFacet.platformType => game.platformTypes.isNotEmpty,
    CollectionFacet.medium => filter.mediums.isNotEmpty,
    CollectionFacet.publishYear => game.publishYear.narrows,
    CollectionFacet.playerCount => game.playerCount.narrows,
    CollectionFacet.playTime => game.playTime.narrows,
    CollectionFacet.missingBaseGame => filter.missingBaseGame,
  };
}
