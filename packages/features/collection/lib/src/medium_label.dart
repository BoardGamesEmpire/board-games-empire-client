import 'package:models/domain.dart';

import 'package:game_collection/l10n/game_collection_localizations.dart';

/// The name of [medium] wherever the collection shows one: an entry's row and
/// tile, its page, the picker's tiles, and the add sheet's Medium field.
///
/// One switch for all of them, so a medium added to the enum is named in one
/// place and every surface calls it the same.
String mediumLabel(GameCollectionLocalizations l10n, GameMedium medium) =>
    switch (medium) {
      GameMedium.physical => l10n.collectionListMediumPhysical,
      GameMedium.digital => l10n.collectionListMediumDigital,
    };
