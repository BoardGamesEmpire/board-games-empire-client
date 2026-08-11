import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/shell_localizations.dart';

/// Which shell route a [ShellPlaceholderScreen] stands in for.
enum ShellPlaceholderKind {
  /// Replaced by the server-add flow (#36).
  serverAdd,

  /// Replaced by the auth wiring (#37).
  auth,
}

/// Temporary route body used until the real feature UI lands. Titles are
/// stable localized strings so router tests remain valid across the
/// handoff to the feature issues.
class ShellPlaceholderScreen extends StatelessWidget {
  const ShellPlaceholderScreen({required this.kind, super.key});

  final ShellPlaceholderKind kind;

  String _title(ShellLocalizations i18n) => switch (kind) {
    ShellPlaceholderKind.serverAdd => i18n.shellPlaceholderServerAddTitle,
    ShellPlaceholderKind.auth => i18n.shellPlaceholderAuthTitle,
  };

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    return BgePage(
      centerVertically: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _title(i18n),
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const BgeGap.sm(),
          Text(i18n.shellPlaceholderBody, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
