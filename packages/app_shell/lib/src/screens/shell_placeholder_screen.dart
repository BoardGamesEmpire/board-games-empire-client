import 'package:flutter/material.dart';

import '../../l10n/shell_localizations.dart';

/// Which shell route a [ShellPlaceholderScreen] stands in for.
enum ShellPlaceholderKind {
  /// Replaced by the server-add flow (#36).
  serverAdd,

  /// Replaced by the auth wiring (#37).
  auth,

  /// Replaced by the collection home (game collection feature).
  home,
}

/// Temporary route body used until the real feature UI lands. Titles are
/// stable localized strings so router tests remain valid across the
/// handoff to the feature issues.
class ShellPlaceholderScreen extends StatelessWidget {
  const ShellPlaceholderScreen({required this.kind, super.key});

  final ShellPlaceholderKind kind;

  String _title(ShellLocalizations l10n) => switch (kind) {
    ShellPlaceholderKind.serverAdd => l10n.shellPlaceholderServerAddTitle,
    ShellPlaceholderKind.auth => l10n.shellPlaceholderAuthTitle,
    ShellPlaceholderKind.home => l10n.shellPlaceholderHomeTitle,
  };

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
                  _title(l10n),
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(l10n.shellPlaceholderBody, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
