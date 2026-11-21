import 'package:app_shell/src/router/app_router.dart';
import 'package:app_shell/src/settings/settings_entry.dart';
import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The per-server Settings row that opens the sign-in methods screen (#582).
///
/// [serverName] is the name the server gives itself, the one the export row
/// names too.
class SignInMethodsSettingsEntry implements SettingsEntry {
  const SignInMethodsSettingsEntry({required this.serverName});

  final String serverName;

  @override
  String get id => 'signInMethods';

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);
    return ListTile(
      key: const Key('settings_sign_in_methods'),
      title: Text(l10n.signInMethodsTitle),
      subtitle: Text(l10n.signInMethodsSettingsSubtitle(serverName)),
      // Decorative: it adds nothing to the row's name.
      trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
      onTap: () => context.push(AppRoutes.settingsSignInMethods),
    );
  }
}
