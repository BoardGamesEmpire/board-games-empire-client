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
