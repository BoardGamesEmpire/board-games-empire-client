/// Game filters (#474, #715): the sheet a list of games is narrowed with, its
/// range fields, the Filters button and the chips naming the filters in use,
/// with the labels they share with the catalog's facts.
///
/// One of the two feature packages another feature may depend on, with
/// `user_search`. It holds no bloc and reads no data: the caller keeps the
/// `CollectionFilter`, hands it in, and applies what comes back. It exports
/// its localizations because the catalog labels its facts with them, and
/// `app_shell` registers the delegate.
library;

export 'l10n/game_filters_localizations.dart';

export 'src/game_facts.dart';
export 'src/game_filter_chip_label.dart';
export 'src/game_filter_keys.dart';
export 'src/game_filter_options.dart';
export 'src/game_filter_sheet.dart';
export 'src/game_filters_button.dart';
export 'src/game_filters_in_use.dart';
export 'src/game_length_band.dart';
export 'src/search_range_field.dart';
