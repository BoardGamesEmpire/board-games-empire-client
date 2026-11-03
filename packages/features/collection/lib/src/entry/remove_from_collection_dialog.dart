import 'package:flutter/material.dart';

import 'package:game_collection/l10n/game_collection_localizations.dart';

/// Asks whether to remove the game [title] from the collection (#46).
///
/// Resolves to true only on the confirm button. Cancel, the barrier and the
/// back gesture all resolve to false.
Future<bool> showRemoveFromCollectionDialog(
  BuildContext context, {
  required String title,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => RemoveFromCollectionDialog(title: title),
  );
  return confirmed ?? false;
}

/// The confirm dialog behind [showRemoveFromCollectionDialog].
///
/// It says what removal means: the entry says the user no longer owns the
/// game, and its plays, rating and comment are kept for if it is added again.
/// It scrolls, since at 2x text the title and body can outgrow a phone's
/// height.
class RemoveFromCollectionDialog extends StatelessWidget {
  const RemoveFromCollectionDialog({required this.title, super.key});

  static const Key confirmKey = Key('collection_remove.confirm');
  static const Key cancelKey = Key('collection_remove.cancel');

  /// The game's title, named in the question.
  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCollectionLocalizations.of(context);

    return AlertDialog(
      scrollable: true,
      title: Text(l10n.removeFromCollectionTitle(title)),
      content: Text(l10n.removeFromCollectionBody),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.removeFromCollectionCancel),
        ),
        TextButton(
          key: confirmKey,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.removeFromCollectionConfirm),
        ),
      ],
    );
  }
}
