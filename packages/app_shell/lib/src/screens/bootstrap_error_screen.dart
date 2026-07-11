import 'package:flutter/material.dart';

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

  /// Minimum tap-target size per the a11y baseline.
  static const _minTapTarget = Size(88, 48);

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
            style: TextButton.styleFrom(minimumSize: _minTapTarget),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(i18n.shellBootstrapErrorResetCancel),
          ),
          FilledButton(
            key: resetConfirmButtonKey,
            style: FilledButton.styleFrom(minimumSize: _minTapTarget),
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
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.error_outline,
                    size: 48,
                    color: colorScheme.error,
                  ),
                ),
                const SizedBox(height: 16),
                // Live region so screen readers announce the failure when
                // it appears, without needing focus to land on it.
                MergeSemantics(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      i18n.shellBootstrapErrorTitle,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(i18n.shellBootstrapErrorBody, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(
                  key: retryButtonKey,
                  style: FilledButton.styleFrom(minimumSize: _minTapTarget),
                  onPressed: onRetry,
                  child: Text(i18n.shellBootstrapErrorRetry),
                ),
                if (canOfferReset) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: resetButtonKey,
                    style: OutlinedButton.styleFrom(
                      minimumSize: _minTapTarget,
                      foregroundColor: colorScheme.error,
                    ),
                    onPressed: () => _confirmReset(context),
                    child: Text(i18n.shellBootstrapErrorReset),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
