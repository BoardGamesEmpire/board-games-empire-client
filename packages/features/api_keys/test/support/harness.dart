import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The reason the shell gives a control that waits for a connection.
const onlineOnlyCopy = "Available when you're online";

/// [child] under the app's theme, this feature's strings and a connectivity
/// scope that is [offline] or not, as the shell hosts a screen.
Widget hostScreen(Widget child, {ThemeData? theme, bool offline = false}) =>
    MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: ApiKeysLocalizations.localizationsDelegates,
      supportedLocales: ApiKeysLocalizations.supportedLocales,
      home: BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: onlineOnlyCopy,
        child: child,
      ),
    );

/// The words on the page [hostOverPage] pushes a screen over.
const pageBeneathCopy = 'The page beneath';

/// [child] pushed over a plain page, as the app pushes a key's own page over
/// the key list: a pop goes back to it, and a SnackBar said as the screen
/// leaves shows on it.
///
/// The connectivity scope sits above the navigator, as the shell's does, so
/// a dialog reads it too.
Widget hostOverPage(Widget child, {ThemeData? theme, bool offline = false}) =>
    MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: ApiKeysLocalizations.localizationsDelegates,
      supportedLocales: ApiKeysLocalizations.supportedLocales,
      builder: (context, app) => BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: onlineOnlyCopy,
        child: app!,
      ),
      routes: {
        '/': (_) => const Scaffold(body: Text(pageBeneathCopy)),
        '/screen': (_) => child,
      },
      initialRoute: '/screen',
    );

/// Pumps [child] on a page, as a screen hosts it: under the app's theme,
/// this feature's strings and a connectivity scope that is [offline] or not.
///
/// Pumping again with the same shape updates the widgets in place, so a test
/// can hand a widget new values as its screen would.
Future<void> pumpOnPage(
  WidgetTester tester,
  Widget child, {
  bool offline = false,
}) => tester.pumpWidget(
  hostScreen(BgePage(child: child), offline: offline),
);
