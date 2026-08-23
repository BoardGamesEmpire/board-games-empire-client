import 'package:interfaces/services.dart';

/// Pass-through [ClockService] null object (#12).
///
/// For scopes without a skew source, and tests that want real
/// wall-clock behaviour without constructing an estimator. No
/// *container* registers it any more — native and web both register
/// `ServerSkewClockService` (#12, #118) — but it remains the production
/// constructor default for `TokenInterceptor` and `AuthRepositoryImpl`,
/// which fall back to it when no estimator is injected. Follows the
/// `UnsupportedPushNotificationService` null-object precedent: honest
/// about its limits ([skewEstimate] is permanently `null`) rather than
/// pretending to correct.
///
/// [nowUtc] is trivially non-decreasing on any device whose clock
/// isn't stepped backwards mid-session; no guard is applied because a
/// pass-through has no correction event that could introduce a
/// regression of its own.
class LocalClockService implements ClockService {
  /// Creates the service. [localNowUtc] injects the clock for tests;
  /// production uses `DateTime.now().toUtc()`.
  const LocalClockService([this._localNowUtc = _systemNowUtc]);

  static DateTime _systemNowUtc() => DateTime.now().toUtc();

  final DateTime Function() _localNowUtc;

  @override
  DateTime nowUtc() => _localNowUtc();

  @override
  Duration? get skewEstimate => null;

  @override
  Stream<Duration?> watchSkew() =>
      // Replays the (permanently null) current estimate to every
      // listener, then completes: there will never be an update to wait
      // for. Stream.multi rather than Stream.value so the returned
      // stream is re-listenable, matching ServerSkewClockService's
      // semantics — a null object must be substitutable (LSP).
      Stream<Duration?>.multi((controller) {
        controller
          ..add(null)
          ..close();
      });
}
