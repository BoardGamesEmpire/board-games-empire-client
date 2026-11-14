import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:profile/l10n/profile_localizations.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The reason the shell gives a control that waits for a connection.
const onlineOnlyCopy = "Available when you're online";

/// Pumps [child] on a page, as the screen hosts it: under the app's theme,
/// this feature's strings and a connectivity scope that is [offline] or not.
///
/// Pumping again with the same shape updates the widgets in place, so a test
/// can hand a form new values as its screen would.
Future<void> pumpOnPage(
  WidgetTester tester,
  Widget child, {
  bool offline = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: ProfileLocalizations.localizationsDelegates,
    supportedLocales: ProfileLocalizations.supportedLocales,
    home: BgeConnectivityScope(
      offline: offline,
      noticeShowing: offline,
      onlineOnlyReason: onlineOnlyCopy,
      child: BgePage(child: child),
    ),
  ),
);
