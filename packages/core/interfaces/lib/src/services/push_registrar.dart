import 'package:models/domain.dart';

/// Per-server-scope push registration (#15, Tier 2).
///
/// One instance per `ServerContext` scope, installed by a
/// `ServerScopeInstaller` beside the network/storage installers — which
/// is why [register] and [unregister] take **no parameters**: the
/// instance already knows its server and holds that server's
/// authenticated scoped client. Multi-server follows structurally: the
/// same user on the same device with three servers has three registrars
/// and three independent [PushRegistration] records.
///
/// Counterpart to the app-level [PushNotificationService], which owns
/// the device-global machinery (platform token, permission, incoming
/// stream). The split keeps this type free of platform plumbing and
/// that type free of per-server networking.
///
/// **No implementation or scope installation exists yet.** The
/// interface lands with #15; the first real platform implementation
/// (#111/#112) brings the installer wiring. The server-side endpoint
/// shape is owned by the backend investigation
/// (BoardGamesEmpire/board-games-empire-backend#186), and per-server
/// availability gating arrives via tier-2 discovery (#114).
abstract interface class PushRegistrar {
  /// Registers this device with this scope's server: uploads the
  /// platform-issued token, persists the resulting registration record
  /// locally, and returns it.
  ///
  /// Requires granted permission and a supported platform
  /// ([PushNotificationService.isPlatformSupported]); requires network —
  /// registration is not queued offline.
  Future<PushRegistration> register();

  /// Unregisters this device from this scope's server and removes the
  /// local registration record. Used on sign-out (#37 flow), server
  /// removal, or explicit user request. Idempotent — safe to call when
  /// no registration exists.
  Future<void> unregister();
}
