import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:flutter/material.dart';

/// Shown while `AppBootstrapCubit` is initializing.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: CircularProgressIndicator(
          semanticsLabel: i18n.shellSplashLoadingLabel,
        ),
      ),
    );
  }
}
