import 'package:interfaces/repositories.dart';

/// The in-app browser tab a native provider sign-in runs in (#583).
abstract interface class ProviderSignInBrowser {
  /// Whether an in-app browser tab exists on this device (Android, iOS,
  /// macOS).
  bool get isSupported;

  /// Opens [url] in an in-app tab; completes with the URL it returned to under
  /// [callbackScheme], or null when the user closed it.
  ///
  /// Every other failure throws [AuthProviderSignInException] with
  /// [ProviderSignInFailureReason.generic].
  Future<Uri?> authenticate({required Uri url, required String callbackScheme});
}

/// The browser on a device that has none.
final class UnsupportedProviderSignInBrowser implements ProviderSignInBrowser {
  const UnsupportedProviderSignInBrowser();

  @override
  bool get isSupported => false;

  @override
  Future<Uri?> authenticate({
    required Uri url,
    required String callbackScheme,
  }) => throw StateError('No in-app browser tab exists on this device.');
}
