import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The router's error page (#465): an address that matches no screen.
///
/// Mostly reached once bootstrap is ready, since before that the redirect
/// sends a location to a bootstrap screen; native lets the server manager's
/// paths through while signed out, so an unknown one under them lands here
/// too. It is also the server manager's page where the composition has no
/// manager, as on web (#134). A location that matched nothing has nothing
/// beneath it to go back to, so the page offers a way home instead.
class RouteNotFoundScreen extends StatelessWidget {
  const RouteNotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    return BgePage(
      title: Text(i18n.shellRouteNotFoundTitle),
      centerVertically: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(i18n.shellRouteNotFoundBody, textAlign: TextAlign.center),
          const BgeGap.lg(),
          FilledButton(
            onPressed: () => context.go(AppRoutes.home),
            child: Text(i18n.shellRouteNotFoundHome),
          ),
        ],
      ),
    );
  }
}
