import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/screens/home_placeholder_screen.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// [HomePlaceholderScreen]'s audit (#50). Its buttons reach the router and
/// the auth bloc only when pressed, so the harness provides neither.
Widget _wrap({required ThemeData theme}) => MaterialApp(
  theme: theme,
  localizationsDelegates: const [
    ...ShellLocalizations.localizationsDelegates,
    AuthLocalizations.delegate,
    FeedbackLocalizations.delegate,
  ],
  supportedLocales: ShellLocalizations.supportedLocales,
  home: const HomePlaceholderScreen(),
);

void main() {
  group('accessibility audit', () {
    auditScreen('ready', build: (theme) => _wrap(theme: theme));
  });
}
