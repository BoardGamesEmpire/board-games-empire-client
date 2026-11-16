import 'package:flutter/material.dart';
import 'package:game_filters/l10n/game_filters_localizations.dart';
import 'package:game_filters/src/game_filter_keys.dart';

/// The button that opens the filter sheet, counting the filters in use
/// (#474): "Filters (2)". [count] is `gameFiltersInUseCount`'s; the caller
/// opens the sheet from [onPressed].
class GameFiltersButton extends StatelessWidget {
  const GameFiltersButton({
    required this.count,
    required this.onPressed,
    this.focusNode,
    this.semanticsLabel,
    super.key,
  });

  final int count;
  final VoidCallback onPressed;

  /// The button's focus node, for a caller that sends focus to it, as when
  /// the last chip of `GameFiltersInUse` goes (#715).
  final FocusNode? focusNode;

  /// What a screen reader calls the button, for a caller whose screen has
  /// another Filters button and so says what this one filters (#919). It
  /// starts with the button's text. The text on screen is unchanged. Null
  /// reads the text.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: GameFilterKeys.button,
    focusNode: focusNode,
    onPressed: onPressed,
    icon: const Icon(Icons.tune),
    label: Text(
      GameFiltersLocalizations.of(context).gameFiltersButton(count),
      semanticsLabel: semanticsLabel,
    ),
  );
}
