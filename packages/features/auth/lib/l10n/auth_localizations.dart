import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'auth_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AuthLocalizations
/// returned by `AuthLocalizations.of(context)`.
///
/// Applications need to include `AuthLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/auth_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AuthLocalizations.localizationsDelegates,
///   supportedLocales: AuthLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the AuthLocalizations.supportedLocales
/// property.
abstract class AuthLocalizations {
  AuthLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AuthLocalizations of(BuildContext context) {
    return Localizations.of<AuthLocalizations>(context, AuthLocalizations)!;
  }

  static const LocalizationsDelegate<AuthLocalizations> delegate =
      _AuthLocalizationsDelegate();

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

  /// Title for the sign-in form
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get authSignInTitle;

  /// Title for the registration form
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get authRegisterTitle;

  /// Link to switch to registration form
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account? Register'**
  String get authSwitchToRegister;

  /// Link to switch to sign-in form
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Sign in'**
  String get authSwitchToSignIn;

  /// Email field label
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get authEmailLabel;

  /// Email field hint text
  ///
  /// In en, this message translates to:
  /// **'Enter your email address'**
  String get authEmailHint;

  /// Password field label
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPasswordLabel;

  /// Password field hint text
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get authPasswordHint;

  /// Username field label
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get authUsernameLabel;

  /// Username field hint text
  ///
  /// In en, this message translates to:
  /// **'Choose a username'**
  String get authUsernameHint;

  /// First name field label
  ///
  /// In en, this message translates to:
  /// **'First Name'**
  String get authFirstNameLabel;

  /// Last name field label
  ///
  /// In en, this message translates to:
  /// **'Last Name'**
  String get authLastNameLabel;

  /// Sign-in submit button label
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get authSignInButton;

  /// Registration submit button label
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get authRegisterButton;

  /// Semantic label for loading indicator
  ///
  /// In en, this message translates to:
  /// **'Signing in, please wait'**
  String get authLoadingLabel;

  /// Divider between email/password and OIDC options
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get authOrDivider;

  /// OIDC button label
  ///
  /// In en, this message translates to:
  /// **'Continue with {provider}'**
  String authContinueWith(String provider);

  /// Validation error for empty required field
  ///
  /// In en, this message translates to:
  /// **'This field is required'**
  String get authErrorRequired;

  /// Validation error for bad email format
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address'**
  String get authErrorInvalidEmail;

  /// Validation error for short password
  ///
  /// In en, this message translates to:
  /// **'Password must be at least {minLength} characters'**
  String authErrorPasswordTooShort(int minLength);

  /// Validation error for short username
  ///
  /// In en, this message translates to:
  /// **'Username must be at least {minLength} characters'**
  String authErrorUsernameTooShort(int minLength);

  /// Semantic label to show password
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get authPasswordVisibilityShow;

  /// Semantic label to hide password
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get authPasswordVisibilityHide;

  /// Label showing which server the user is signing into
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get authServerLabel;

  /// Error when server disables sign-up
  ///
  /// In en, this message translates to:
  /// **'Registration is currently disabled on this server.'**
  String get authRegistrationDisabled;
}

class _AuthLocalizationsDelegate
    extends LocalizationsDelegate<AuthLocalizations> {
  const _AuthLocalizationsDelegate();

  @override
  Future<AuthLocalizations> load(Locale locale) {
    return SynchronousFuture<AuthLocalizations>(
      lookupAuthLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AuthLocalizationsDelegate old) => false;
}

AuthLocalizations lookupAuthLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AuthLocalizationsEn();
  }

  throw FlutterError(
    'AuthLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
