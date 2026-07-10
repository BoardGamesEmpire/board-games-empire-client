import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'shell_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of ShellLocalizations
/// returned by `ShellLocalizations.of(context)`.
///
/// Applications need to include `ShellLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/shell_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: ShellLocalizations.localizationsDelegates,
///   supportedLocales: ShellLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the ShellLocalizations.supportedLocales
/// property.
abstract class ShellLocalizations {
  ShellLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static ShellLocalizations of(BuildContext context) {
    return Localizations.of<ShellLocalizations>(context, ShellLocalizations)!;
  }

  static const LocalizationsDelegate<ShellLocalizations> delegate =
      _ShellLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Application title used by the OS task switcher and browser tab
  ///
  /// In en, this message translates to:
  /// **'Board Games Empire'**
  String get shellAppTitle;

  /// Semantics label announced by screen readers while the app bootstraps
  ///
  /// In en, this message translates to:
  /// **'Loading Board Games Empire'**
  String get shellSplashLoadingLabel;

  /// Title of the bootstrap failure screen
  ///
  /// In en, this message translates to:
  /// **'Startup failed'**
  String get shellBootstrapErrorTitle;

  /// Body of the bootstrap failure screen; reassures that no destructive action was taken
  ///
  /// In en, this message translates to:
  /// **'Board Games Empire couldn\'t finish starting. Your data has not been changed.'**
  String get shellBootstrapErrorBody;

  /// Label for the retry button on the bootstrap failure screen
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get shellBootstrapErrorRetry;

  /// Label for the destructive recovery button, shown only after repeated startup failures; opens a confirmation dialog
  ///
  /// In en, this message translates to:
  /// **'Delete local data…'**
  String get shellBootstrapErrorReset;

  /// Title of the confirmation dialog before deleting the device-local database
  ///
  /// In en, this message translates to:
  /// **'Delete local data?'**
  String get shellBootstrapErrorResetConfirmTitle;

  /// Body of the delete-local-data confirmation dialog; explains exactly what is lost and what is safe
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes this device\'s local Board Games Empire data, including the list of servers you\'ve added. Data on your servers is not affected. You\'ll need to add your server again.'**
  String get shellBootstrapErrorResetConfirmBody;

  /// Confirming action of the delete-local-data dialog
  ///
  /// In en, this message translates to:
  /// **'Delete and retry'**
  String get shellBootstrapErrorResetConfirmAction;

  /// Dismissing action of the delete-local-data dialog
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get shellBootstrapErrorResetCancel;

  /// Body of the in-build failure view that replaces Flutter's default ErrorWidget (#66); must stay reassuring and free of technical detail — the exception summary is appended separately in debug builds only
  ///
  /// In en, this message translates to:
  /// **'Board Games Empire couldn\'t display this part of the screen. The app is still running — going back or restarting usually clears it.'**
  String get shellBuildErrorBody;

  /// Title shown when a reserved deep-link route has no UI behind it yet
  ///
  /// In en, this message translates to:
  /// **'Not yet available'**
  String get shellNotYetAvailableTitle;

  /// Body shown when a reserved deep-link route has no UI behind it yet
  ///
  /// In en, this message translates to:
  /// **'This part of Board Games Empire isn\'t available yet. It\'s coming in a future update.'**
  String get shellNotYetAvailableBody;

  /// Title of the server-add route placeholder (real UI lands with the server-add flow)
  ///
  /// In en, this message translates to:
  /// **'Add a server'**
  String get shellPlaceholderServerAddTitle;

  /// Title of the auth route placeholder (real UI lands with auth wiring)
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get shellPlaceholderAuthTitle;

  /// Title of the home route placeholder
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get shellPlaceholderHomeTitle;

  /// Shared body text for placeholder route screens
  ///
  /// In en, this message translates to:
  /// **'This screen is under construction and arrives with an upcoming update.'**
  String get shellPlaceholderBody;

  /// Title of the ask-each-time crash report prompt (#69)
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get crashReportPromptTitle;

  /// Explanation line under the crash prompt title; states the privacy contract — nothing is sent without explicit approval
  ///
  /// In en, this message translates to:
  /// **'You can send this crash report to your server to help get it fixed. Nothing is sent without your approval.'**
  String get crashReportPromptExplanation;

  /// Label of the optional comment field on the crash prompt; doubles as the field's screen-reader label
  ///
  /// In en, this message translates to:
  /// **'What were you doing? (optional)'**
  String get crashReportPromptCommentLabel;

  /// Label of the crash prompt's send button
  ///
  /// In en, this message translates to:
  /// **'Send report'**
  String get crashReportPromptSend;

  /// Label of the crash prompt's decline button; declining clears the crash draft without sending anything
  ///
  /// In en, this message translates to:
  /// **'Don\'t send'**
  String get crashReportPromptDiscard;

  /// Label of the button that dismisses the crash prompt after a terminal outcome (sent, saved, or failed)
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get crashReportPromptDismiss;

  /// Confirmation shown when the crash report reached the server
  ///
  /// In en, this message translates to:
  /// **'Report sent. Thank you!'**
  String get crashReportPromptSent;

  /// Confirmation shown when the crash report was saved locally for a later send (offline, or not signed in); must stay honest — it was NOT sent yet
  ///
  /// In en, this message translates to:
  /// **'Saved. It will be sent once you\'re connected and signed in.'**
  String get crashReportPromptQueued;

  /// Shown when both sending and local saving failed; the prompt can still be closed
  ///
  /// In en, this message translates to:
  /// **'The report couldn\'t be sent or saved.'**
  String get crashReportPromptFailed;
}

class _ShellLocalizationsDelegate
    extends LocalizationsDelegate<ShellLocalizations> {
  const _ShellLocalizationsDelegate();

  @override
  Future<ShellLocalizations> load(Locale locale) {
    return SynchronousFuture<ShellLocalizations>(
      lookupShellLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_ShellLocalizationsDelegate old) => false;
}

ShellLocalizations lookupShellLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return ShellLocalizationsEn();
  }

  throw FlutterError(
    'ShellLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
