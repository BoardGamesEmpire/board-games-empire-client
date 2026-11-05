import 'dart:io' show Platform;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';

/// Signature of [FlutterWebAuth2.authenticate], the test seam.
typedef WebAuthAuthenticate = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
  required FlutterWebAuth2Options options,
});

/// [ProviderSignInBrowser] over `flutter_web_auth_2` (#583): a Custom Tab /
/// Auth Tab on Android, `ASWebAuthenticationSession` on iOS and macOS.
///
/// Windows and Linux have no such tab, so [isSupported] is false there. The
/// screen still shows the provider buttons, disabled, with a label saying
/// provider sign-in isn't available on this device yet (#583). #703 tracks
/// signing in through the system browser there.
class FlutterWebAuthProviderSignInBrowser implements ProviderSignInBrowser {
  FlutterWebAuthProviderSignInBrowser({
    WebAuthAuthenticate? authenticate,
    bool? isSupported,
  }) : _authenticate = authenticate ?? FlutterWebAuth2.authenticate,
       isSupported =
           isSupported ??
           (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  final WebAuthAuthenticate _authenticate;

  @override
  final bool isSupported;

  /// The plugin reports a back gesture, the system sheet's Cancel button, and
  /// an app resumed with no return, all as this code.
  static const _canceledCode = 'CANCELED';

  @override
  Future<Uri?> authenticate({
    required Uri url,
    required String callbackScheme,
  }) async {
    final String returned;
    try {
      returned = await _authenticate(
        url: url.toString(),
        callbackUrlScheme: callbackScheme,
        // Not ephemeral: the user stays signed in to their provider, so
        // choosing the account is one tap (#583).
        options: const FlutterWebAuth2Options(preferEphemeral: false),
      );
    } on PlatformException catch (e) {
      if (e.code == _canceledCode) {
        return null;
      }
      throw AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        cause: e,
      );
    }

    final uri = Uri.tryParse(returned);
    if (uri == null) {
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'The browser returned an address that is not a URL.',
      );
    }
    return uri;
  }
}
