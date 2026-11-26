import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:flutter/material.dart';

/// Asks before an API key is deleted (#1028), naming the key, and saying
/// that programs using it stop at once and that it can't be undone.
///
/// Cancel and a tap outside both keep the key.
class DeleteKeyDialog extends StatelessWidget {
  const DeleteKeyDialog({required this.name, super.key});

  static const Key confirmKey = Key('api_key_detail.delete_confirm');
  static const Key cancelKey = Key('api_key_detail.delete_cancel');

  /// The key's name as its page shows it: "Unnamed key" when it has none.
  final String name;

  /// Shows the dialog over [context]'s page, and completes with whether the
  /// user confirmed.
  static Future<bool> show(BuildContext context, {required String name}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteKeyDialog(name: name),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);

    return AlertDialog(
      // A name of 32 characters at 200% text runs to several lines.
      scrollable: true,
      title: Text(l10n.apiKeyDeleteConfirmTitle(name)),
      content: Text(l10n.apiKeyDeleteConfirmBody),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.apiKeyDeleteCancel),
        ),
        TextButton(
          key: confirmKey,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.apiKeyDeleteConfirm),
        ),
      ],
    );
  }
}
