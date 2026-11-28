import 'package:flutter/material.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The reason the shell gives a control that waits for a connection.
const onlineOnlyCopy = "Available when you're online";

/// [child] under the app's theme, this feature's strings and a connectivity
/// scope that is [offline] or not, as the shell hosts a screen.
Widget hostScreen(Widget child, {ThemeData? theme, bool offline = false}) =>
    MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: NotificationsLocalizations.localizationsDelegates,
      supportedLocales: NotificationsLocalizations.supportedLocales,
      home: BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: onlineOnlyCopy,
        child: child,
      ),
    );

/// [page] as the page a pop-up opens from, under the app's theme, this
/// feature's strings and a connectivity scope that is [offline] or not.
///
/// The scope is above the navigator, where the shell puts it, so a pop-up on
/// the root navigator reads it as the app's do. [hostScreen] puts it inside
/// the page's route, where no pop-up can reach it.
Widget hostPopupOpener(Widget page, {ThemeData? theme, bool offline = false}) =>
    MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: NotificationsLocalizations.localizationsDelegates,
      supportedLocales: NotificationsLocalizations.supportedLocales,
      builder: (context, navigator) => BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: onlineOnlyCopy,
        child: navigator ?? const SizedBox.shrink(),
      ),
      home: page,
    );
