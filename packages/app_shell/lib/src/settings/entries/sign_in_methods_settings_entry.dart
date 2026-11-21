import 'package:app_shell/src/router/app_router.dart';
import 'package:app_shell/src/settings/settings_entry.dart';
import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';

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
    return BgeRowFocusRing(
      builder: (context, row) => ListTile(
        key: const Key('settings_sign_in_methods'),
        focusNode: row.focusNode,
        onFocusChange: row.onFocusChange,
        focusColor: row.focusColor,
        title: Text(l10n.signInMethodsTitle),
        subtitle: Text(l10n.signInMethodsSettingsSubtitle(serverName)),
        // Decorative: it adds nothing to the row's name.
        trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
        onTap: row.onTap(() => context.push(AppRoutes.settingsSignInMethods)),
      ),
    );
  }
}
