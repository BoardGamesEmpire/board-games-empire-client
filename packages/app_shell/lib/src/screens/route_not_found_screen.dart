import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../../l10n/shell_localizations.dart';
import '../router/app_router.dart';

/// The router's error page (#465): an address that matches no screen.
///
/// Reached only once bootstrap is ready, since the redirect pins every
/// location to a bootstrap screen before that. A location that matched
/// nothing has nothing beneath it to go back to, so the page offers a way
/// home instead.
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
