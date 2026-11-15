import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';

/// Shown when bootstrap fails. Always offers retry; offers the destructive
/// delete-local-data recovery only when [canOfferReset] is true (repeated
/// failures the platform says a reset could fix: native's local meta
/// database, or web's stored server databases), and even then only executes
/// it after explicit confirmation.
class BootstrapErrorScreen extends StatelessWidget {
  const BootstrapErrorScreen({
    required this.canOfferReset,
    required this.onRetry,
    required this.onReset,
    this.localDataInUse = false,
    this.isWeb = kIsWeb,
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

  /// The last reset could not finish because other tabs or windows hold the
  /// local data (#793). The body then asks the user to close them.
  final bool localDataInUse;

  /// Picks the confirmation text: web has no server list to lose, and may
  /// lose changes the server hasn't received (#793).
  final bool isWeb;

  Future<void> _confirmReset(BuildContext context) async {
    final i18n = ShellLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(i18n.shellBootstrapErrorResetConfirmTitle),
        content: Text(
          isWeb
              ? i18n.shellBootstrapErrorResetConfirmBodyWeb
              : i18n.shellBootstrapErrorResetConfirmBody,
        ),
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
        body: localDataInUse
            ? i18n.shellBootstrapErrorInUseBody
            : i18n.shellBootstrapErrorBody,
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
