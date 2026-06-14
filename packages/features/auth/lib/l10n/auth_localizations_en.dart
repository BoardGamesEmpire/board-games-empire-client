// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'auth_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AuthLocalizationsEn extends AuthLocalizations {
  AuthLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get authSignInTitle => 'Sign In';

  @override
  String get authRegisterTitle => 'Create Account';

  @override
  String get authSwitchToRegister => 'Don\'t have an account? Register';

  @override
  String get authSwitchToSignIn => 'Already have an account? Sign in';

  @override
  String get authEmailLabel => 'Email';

  @override
  String get authEmailHint => 'Enter your email address';

  @override
  String get authPasswordLabel => 'Password';

  @override
  String get authPasswordHint => 'Enter your password';

  @override
  String get authUsernameLabel => 'Username';

  @override
  String get authUsernameHint => 'Choose a username';

  @override
  String get authFirstNameLabel => 'First Name';

  @override
  String get authLastNameLabel => 'Last Name';

  @override
  String get authSignInButton => 'Sign In';

  @override
  String get authRegisterButton => 'Create Account';

  @override
  String get authLoadingLabel => 'Signing in, please wait';

  @override
  String get authOrDivider => 'or';

  @override
  String authContinueWith(String provider) {
    return 'Continue with $provider';
  }

  @override
  String get authErrorRequired => 'This field is required';

  @override
  String get authErrorInvalidEmail => 'Enter a valid email address';

  @override
  String authErrorPasswordTooShort(int minLength) {
    return 'Password must be at least $minLength characters';
  }

  @override
  String authErrorUsernameTooShort(int minLength) {
    return 'Username must be at least $minLength characters';
  }

  @override
  String get authPasswordVisibilityShow => 'Show password';

  @override
  String get authPasswordVisibilityHide => 'Hide password';

  @override
  String get authServerLabel => 'Server';

  @override
  String get authRegistrationDisabled =>
      'Registration is currently disabled on this server.';
}
