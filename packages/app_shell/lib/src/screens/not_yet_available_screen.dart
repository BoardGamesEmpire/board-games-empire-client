import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Resolution target for reserved deep-link paths that have no feature UI
/// behind them yet (#10 declares the URL scheme from day one), and the
/// fallback for every route whose builder cannot back its screen.
///
/// Titled, so it has an app bar (#308). Most routes that fall back here are
/// pushed or have a parent beneath them, and the app bar is what implies a
/// back button for them; without it, desktop had nothing to press. The title
/// lives there and only there, so the body is the explanation alone rather
/// than a heading that repeats the one above it.
///
/// The reserved deep-link routes are the exception: each is top-level, with
/// nothing beneath it and no menu, and a consumed link lands on it (#82,
/// #243). There the app bar implies nothing, so the router passes
/// [showHomeAction] and the screen offers a way home, as the router's
/// not-found page does.
class NotYetAvailableScreen extends StatelessWidget {
  const NotYetAvailableScreen({super.key, this.showHomeAction = false});

  static const homeButtonKey = Key('not_yet_available_home_button');

  /// Whether to offer a button that goes home: true only where the route
  /// has nothing beneath it to go back to.
  final bool showHomeAction;

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final body = Text(
      i18n.shellNotYetAvailableBody,
      textAlign: TextAlign.center,
    );
    return BgePage(
      title: Text(i18n.shellNotYetAvailableTitle),
      centerVertically: true,
      child: showHomeAction
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                body,
                const BgeGap.lg(),
                FilledButton(
                  key: homeButtonKey,
                  onPressed: () => context.go(AppRoutes.home),
                  child: Text(i18n.shellNotYetAvailableHome),
                ),
              ],
            )
          : body,
    );
  }
}
