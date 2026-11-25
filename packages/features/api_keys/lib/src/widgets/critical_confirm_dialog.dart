import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Asks before an API key is given the Critical permissions [critical]
/// (#1028), and completes with whether the user confirmed.
///
/// True only on Confirm: Cancel, a tap outside and Back all answer false,
/// and the caller then sends nothing. `confirmCritical` goes to the server
/// only after a true from here.
///
/// The dialog names each permission by its description and says the server
/// may ask for a new sign-in, which it does when the session is too old.
/// With none to name, as when the server finds a permission Critical that
/// this app's list does not, it asks all the same, in general words.
Future<bool> showCriticalConfirm(
  BuildContext context,
  List<GrantablePermission> critical,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => CriticalConfirmDialog(critical: critical),
  );
  return confirmed ?? false;
}

/// The question [showCriticalConfirm] asks.
class CriticalConfirmDialog extends StatelessWidget {
  const CriticalConfirmDialog({required this.critical, super.key});

  static const Key confirmKey = Key('api_key.critical_confirm');
  static const Key cancelKey = Key('api_key.critical_cancel');

  /// The Critical permissions the key would hold. May be empty.
  final List<GrantablePermission> critical;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    return AlertDialog(
      // A long list, or a short one at 200% text, runs past a phone's height.
      scrollable: true,
      title: Text(l10n.apiKeyCriticalConfirmTitle),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (critical.isEmpty)
            Text(l10n.apiKeyCriticalConfirmBodyUnnamed)
          else ...[
            Text(l10n.apiKeyCriticalConfirmBody),
            const BgeGap.sm(),
            for (final permission in critical)
              Padding(
                padding: EdgeInsetsDirectional.only(
                  start: tokens.spaceMd,
                  bottom: tokens.spaceXs,
                ),
                child: Text(permission.description),
              ),
          ],
          const BgeGap.md(),
          Text(l10n.apiKeyCriticalConfirmSignIn),
        ],
      ),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.apiKeyCriticalConfirmCancel),
        ),
        TextButton(
          key: confirmKey,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.apiKeyCriticalConfirmAction),
        ),
      ],
    );
  }
}
