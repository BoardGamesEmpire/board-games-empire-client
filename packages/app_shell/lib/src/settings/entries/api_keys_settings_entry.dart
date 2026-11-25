import 'package:api_keys/api_keys.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:app_shell/src/settings/settings_entry.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';

/// The per-server Settings row that opens the user's API keys (#1028).
///
/// [serverName] is the name the server gives itself, the one the sign-in
/// methods row names too.
class ApiKeysSettingsEntry implements SettingsEntry {
  const ApiKeysSettingsEntry({required this.serverName});

  final String serverName;

  @override
  String get id => 'apiKeys';

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    return BgeRowFocusRing(
      builder: (context, row) => ListTile(
        key: const Key('settings_api_keys'),
        focusNode: row.focusNode,
        onFocusChange: row.onFocusChange,
        focusColor: row.focusColor,
        title: Text(l10n.apiKeysTitle),
        subtitle: Text(l10n.apiKeysSettingsSubtitle(serverName)),
        // Decorative: it adds nothing to the row's name.
        trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
        onTap: row.onTap(() => context.push(AppRoutes.settingsApiKeys)),
      ),
    );
  }
}
