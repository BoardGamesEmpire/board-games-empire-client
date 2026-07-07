import 'package:flutter/material.dart';

import '../../l10n/shell_localizations.dart';

/// Resolution target for reserved deep-link paths that have no feature UI
/// behind them yet (#10 declares the URL scheme from day one).
class NotYetAvailableScreen extends StatelessWidget {
  const NotYetAvailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.shellNotYetAvailableTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.shellNotYetAvailableBody,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
