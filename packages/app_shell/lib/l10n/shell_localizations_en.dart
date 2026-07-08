// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'shell_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class ShellLocalizationsEn extends ShellLocalizations {
  ShellLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get shellAppTitle => 'Board Games Empire';

  @override
  String get shellSplashLoadingLabel => 'Loading Board Games Empire';

  @override
  String get shellBootstrapErrorTitle => 'Startup failed';

  @override
  String get shellBootstrapErrorBody =>
      'Board Games Empire couldn\'t finish starting. Your data has not been changed.';

  @override
  String get shellBootstrapErrorRetry => 'Try again';

  @override
  String get shellBootstrapErrorReset => 'Delete local data…';

  @override
  String get shellBootstrapErrorResetConfirmTitle => 'Delete local data?';

  @override
  String get shellBootstrapErrorResetConfirmBody =>
      'This permanently deletes this device\'s local Board Games Empire data, including the list of servers you\'ve added. Data on your servers is not affected. You\'ll need to add your server again.';

  @override
  String get shellBootstrapErrorResetConfirmAction => 'Delete and retry';

  @override
  String get shellBootstrapErrorResetCancel => 'Cancel';

  @override
  String get shellBuildErrorBody =>
      'Board Games Empire couldn\'t display this part of the screen. The app is still running — going back or restarting usually clears it.';

  @override
  String get shellNotYetAvailableTitle => 'Not yet available';

  @override
  String get shellNotYetAvailableBody =>
      'This part of Board Games Empire isn\'t available yet. It\'s coming in a future update.';

  @override
  String get shellPlaceholderServerAddTitle => 'Add a server';

  @override
  String get shellPlaceholderAuthTitle => 'Sign in';

  @override
  String get shellPlaceholderHomeTitle => 'Home';

  @override
  String get shellPlaceholderBody =>
      'This screen is under construction and arrives with an upcoming update.';
}
