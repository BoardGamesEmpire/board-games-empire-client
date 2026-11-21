import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/deep_links/deep_link_normalizer.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';

/// What a link for a server this device hasn't added opens (#82).
///
/// It reuses the bootstrap failure screen's accessibility pattern, which
/// that screen now takes from [BgeErrorState]: the title and the body are
/// one live region, so a screen reader says why the link went nowhere
/// without the user having navigated here, and the primary action is
/// autofocused.
///
/// When the [link] carries the server's address, the body names that
/// address and the primary action is *Add this server*, which pushes the server
/// manager's add route with the link, so Back returns here (#971). *Go home*
/// follows it as the secondary action. Without an address the one action
/// goes home, because the screen is a top-level route with nothing beneath
/// it (#82, #243).
///
/// The screen fetches nothing: the address shown is the one the link
/// carries, and opening a link never contacts the server it names. Whether
/// that address really is the link's server is checked when the add is
/// submitted (#971).
///
/// The icon keeps [BgeErrorState]'s quiet default colour, with an address
/// too: nothing failed, the link just can't be opened on this device yet.
class UnknownServerLinkScreen extends StatelessWidget {
  const UnknownServerLinkScreen({this.link, super.key});

  /// The link that led here, or null when the route carried none.
  final ServerDeepLink? link;

  static const homeButtonKey = Key('unknown_server_link_home_button');
  static const addButtonKey = Key('unknown_server_link_add_button');

  @override
  Widget build(BuildContext context) {
    final i18n = ShellLocalizations.of(context);
    final link = this.link;
    final address = link?.address;
    if (link == null || address == null) {
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
    return BgePage(
      centerVertically: true,
      child: BgeErrorState(
        icon: Icons.link_off,
        title: i18n.shellUnknownServerLinkTitle,
        body: i18n.shellUnknownServerLinkBodyAt(_shownAddress(address)),
        retryLabel: i18n.shellUnknownServerLinkAdd,
        retryKey: addButtonKey,
        onRetry: () => context.push(AppRoutes.serversAddOf(link.location)),
        secondaryActions: [
          OutlinedButton(
            key: homeButtonKey,
            onPressed: () => context.go(AppRoutes.home),
            child: Text(i18n.shellUnknownServerLinkHome),
          ),
        ],
      ),
    );
  }

  /// [address] as the body names it: its host, with its port when it gives
  /// one, and its path prefix, without the scheme. The address is already
  /// validated and normalized, so this only parses it.
  ///
  /// The path stays because several servers can share one host behind a
  /// reverse proxy, each under its own prefix: the host alone could name a
  /// server the user trusts while the link is for another under it (#971).
  ///
  /// `authority`, not `host` and `port`: `host` drops an IPv6 literal's
  /// brackets, and no userinfo can occur, since a link address with `@` is
  /// refused (#971).
  static String _shownAddress(String address) {
    final uri = Uri.parse(address);
    return '${uri.authority}${uri.path}';
  }
}
