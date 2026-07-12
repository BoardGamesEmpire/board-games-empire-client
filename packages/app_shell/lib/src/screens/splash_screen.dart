import 'package:flutter/material.dart';

import '../../l10n/shell_localizations.dart';

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
