import 'package:flutter/material.dart';
import 'package:ui/ui.dart';

import '../../l10n/shell_localizations.dart';

/// Resolution target for reserved deep-link paths that have no feature UI
/// behind them yet (#10 declares the URL scheme from day one), and the
/// fallback for every route whose builder cannot back its screen.
///
/// Titled, so it has an app bar (#308). Most routes that fall back here are
/// pushed or have a parent beneath them, and the app bar is what implies a
/// back button for them; without it, desktop had nothing to press. The title
/// lives there and only there, so the body is the explanation alone rather
/// than a heading that repeats the one above it.
class NotYetAvailableScreen extends StatelessWidget {
  const NotYetAvailableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    return BgePage(
      title: Text(i18n.shellNotYetAvailableTitle),
      centerVertically: true,
      child: Text(i18n.shellNotYetAvailableBody, textAlign: TextAlign.center),
    );
  }
}
