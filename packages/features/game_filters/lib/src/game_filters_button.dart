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
    super.key,
  });

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: GameFilterKeys.button,
    onPressed: onPressed,
    icon: const Icon(Icons.tune),
    label: Text(GameFiltersLocalizations.of(context).gameFiltersButton(count)),
  );
}
