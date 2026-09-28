import 'package:flutter/material.dart';
import 'package:ui/ui.dart';

import '../../l10n/shell_localizations.dart';

/// Shown when bootstrap fails. Always offers retry; offers the destructive
/// delete-local-data recovery only when [canOfferReset] is true (repeated
/// failures on a platform with a local meta database), and even then only
/// executes it after explicit confirmation.
class BootstrapErrorScreen extends StatelessWidget {
  const BootstrapErrorScreen({
    required this.canOfferReset,
    required this.onRetry,
    required this.onReset,
    super.key,
  });

  static const retryButtonKey = Key('bootstrap_error_retry_button');
  static const resetButtonKey = Key('bootstrap_error_reset_button');
  static const resetConfirmButtonKey = Key(
    'bootstrap_error_reset_confirm_button',
  );
  static const resetCancelButtonKey = Key(
    'bootstrap_error_reset_cancel_button',
  );

  final bool canOfferReset;
  final VoidCallback onRetry;
  final VoidCallback onReset;

  Future<void> _confirmReset(BuildContext context) async {
    final i18n = ShellLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(i18n.shellBootstrapErrorResetConfirmTitle),
        content: Text(i18n.shellBootstrapErrorResetConfirmBody),
        actions: [
          TextButton(
            key: resetCancelButtonKey,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(i18n.shellBootstrapErrorResetCancel),
          ),
          FilledButton(
            key: resetConfirmButtonKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(i18n.shellBootstrapErrorResetConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed ?? false) onReset();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return BgePage(
      centerVertically: true,
      child: BgeErrorState(
        icon: Icons.error_outline,
        iconColor: colorScheme.error,
        title: i18n.shellBootstrapErrorTitle,
        body: i18n.shellBootstrapErrorBody,
        retryLabel: i18n.shellBootstrapErrorRetry,
        retryKey: retryButtonKey,
        onRetry: onRetry,
        secondaryActions: [
          if (canOfferReset)
            OutlinedButton(
              key: resetButtonKey,
              style: OutlinedButton.styleFrom(
                foregroundColor: colorScheme.error,
              ),
              onPressed: () => _confirmReset(context),
              child: Text(i18n.shellBootstrapErrorReset),
            ),
        ],
      ),
    );
  }
}
