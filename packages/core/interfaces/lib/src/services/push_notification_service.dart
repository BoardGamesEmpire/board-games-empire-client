import 'package:models/domain.dart';

/// App-level (device-global) push machinery (#15, Tier 2).
///
/// One instance per app: the platform issues a single push token per
/// app install, and notifications can arrive while any given
/// `ServerContext` is suspended or monitoring — so this surface must
/// not live inside a server scope. Per-server *registration* is the
/// separate, per-scope [PushRegistrar]: the two are deliberately split
/// so this service never needs a server's authenticated client and the
/// registrar never needs platform machinery.
///
/// Per ISP, lifecycle (`dispose`) is deliberately **not** part of this
/// interface: it lives on the concrete implementation and is owned by
/// the composition root that constructs it (cf. `ConnectivityService`).
///
/// v0.1 registers `UnsupportedPushNotificationService` (in `di`) on
/// every platform; real implementations arrive per platform (#111
/// Android, #112 Apple, #113 web go/no-go).
abstract interface class PushNotificationService {
  /// Whether push notifications are supported on this platform build.
  ///
  /// `false` everywhere in v0.1 (the `UnsupportedPushNotificationService`
  /// era) and permanently on platforms with no transport. Callers must
  /// gate [requestPermission] on this — the unsupported implementation
  /// throws there by design.
  bool get isPlatformSupported;

  /// Current platform permission status, read fresh from the platform.
  Future<PushPermissionStatus> get permissionStatus;

  /// Requests platform permission — the OS prompt appears.
  ///
  /// Just-in-time only: called when the user opts into a push-needing
  /// feature (e.g. enabling chat notifications), never at app startup.
  /// Deliberately separate from [PushRegistrar.register] to keep the
  /// prompt tied to user intent. Returns the resulting status.
  ///
  /// When [isPlatformSupported] is `false`, the returned [Future]
  /// completes with an [UnsupportedError] (never a synchronous throw —
  /// the error must reach `catchError`/`onError` handlers).
  Future<PushPermissionStatus> requestPermission();

  /// Broadcast stream of received notifications. Each subscriber sees
  /// a notification once; no replay.
  ///
  /// Implementations resolve the platform payload to the client-local
  /// [PushNotification.localServerId] before emitting: the payload can
  /// only carry the originating server's own identity
  /// ([PushRegistration.bgeServerId]) — servers never know client-local
  /// ids — so the persisted [PushRegistration] record is the lookup
  /// table. Payloads from servers with no matching registration are
  /// dropped, not emitted.
  ///
  /// Never throws — the unsupported implementation returns an empty
  /// broadcast stream, so UI wiring needs no support gate here.
  Stream<PushNotification> watchIncoming();
}
