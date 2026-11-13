import 'package:game_filters/game_filters.dart' show GameFilterOptions;

/// What the filter sheet offers on Offer games and on the Games tab's pool,
/// one sheet for both (#516, #851), and so what its chips name and its
/// Filters button counts: the game search's sections, the medium, and a flip
/// under each. No expansions-missing-their-base switch: neither list marks
/// a row as one.
const eventGameFilterOptions = GameFilterOptions(
  medium: true,
  exclusion: true,
);
