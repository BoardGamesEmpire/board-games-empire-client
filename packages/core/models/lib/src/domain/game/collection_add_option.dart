import 'package:freezed_annotation/freezed_annotation.dart';

import 'game_medium.dart';
import 'platform_game.dart';

part 'collection_add_option.freezed.dart';

/// A platform game the add can be made on, with the mediums still free
/// there (#708).
///
/// Taken as a snapshot of what the user owned when the add was opened. A
/// platform owned in every medium is left out, so [freeMediums] is never
/// empty.
@freezed
abstract class CollectionAddOption with _$CollectionAddOption {
  const factory CollectionAddOption({
    required PlatformGame platformGame,

    /// The mediums not yet owned on [platformGame]. Never empty.
    required Set<GameMedium> freeMediums,
  }) = _CollectionAddOption;
}
