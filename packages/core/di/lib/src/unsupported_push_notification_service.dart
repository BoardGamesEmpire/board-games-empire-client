import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

/// Null-object [PushNotificationService] for platforms/builds with no
/// push transport (#15, Tier 2).
///
/// Registered as the app-level default on **every** platform in v0.1 —
/// each root module binds it eagerly (it is `const`, pure, and
/// plugin-free, so it trivially satisfies the defensive-module
/// contract). Real implementations replace it per platform (#111
/// Android, #112 Apple, #113 web go/no-go).
///
/// Stub semantics (locked in #15):
/// - [isPlatformSupported] → `false`; callers gate on this.
/// - [permissionStatus] → [PushPermissionStatus.notDetermined] — the
///   truthful value: nothing was ever asked.
/// - [requestPermission] → fails with [UnsupportedError], a loud "not
///   yet" for a call that should have been gated. `async` so the error
///   arrives on the returned [Future] (Effective Dart: never throw
///   synchronously from a Future-returning member), reaching
///   `catchError`/`onError` handlers and `unawaited` callers alike.
/// - [watchIncoming] → an empty broadcast stream that closes
///   immediately: UI can subscribe unconditionally with no support
///   gate and no try/catch.
final class UnsupportedPushNotificationService
    implements PushNotificationService {
  /// Creates the null object. `const` so registration allocates nothing.
  const UnsupportedPushNotificationService();

  @override
  bool get isPlatformSupported => false;

  @override
  Future<PushPermissionStatus> get permissionStatus =>
      Future<PushPermissionStatus>.value(PushPermissionStatus.notDetermined);

  @override
  Future<PushPermissionStatus> requestPermission() async =>
      throw UnsupportedError(
        'Push notifications are not supported in this build. Gate on '
        'PushNotificationService.isPlatformSupported before calling '
        'requestPermission() (#15).',
      );

  @override
  Stream<PushNotification> watchIncoming() =>
      const Stream<PushNotification>.empty();
}
