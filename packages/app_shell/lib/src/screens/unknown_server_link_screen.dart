import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';

/// What a link for a server this device hasn't added opens (#82).
///
/// It reuses the bootstrap failure screen's accessibility pattern, which
/// that screen now takes from [BgeErrorState]: the title and the body are
/// one live region, so a screen reader says why the link went nowhere
/// without the user having navigated here, and the one action is
/// autofocused. That action goes home, because the screen is a top-level
/// route with nothing beneath it (#82, #243).
///
/// The icon keeps [BgeErrorState]'s quiet default colour: nothing failed,
/// the link just can't be opened on this device.
class UnknownServerLinkScreen extends StatelessWidget {
  const UnknownServerLinkScreen({super.key});

  static const homeButtonKey = Key('unknown_server_link_home_button');

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    return BgePage(
      centerVertically: true,
      child: BgeErrorState(
        icon: Icons.link_off,
        title: i18n.shellUnknownServerLinkTitle,
        body: i18n.shellUnknownServerLinkBody,
        retryLabel: i18n.shellUnknownServerLinkHome,
        retryKey: homeButtonKey,
        onRetry: () => context.go(AppRoutes.home),
      ),
    );
  }
}
