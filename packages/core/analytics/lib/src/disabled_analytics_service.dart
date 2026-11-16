import 'package:analytics/src/analytics_event.dart';
import 'package:analytics/src/analytics_service.dart';

/// An [AnalyticsService] that records nothing.
///
/// It is the only implementation until consent and transport ship (#17),
/// and follows the null-object precedent of
/// `UnsupportedPushNotificationService`. The root container registers it
/// unless a platform module or test seam registered its own service first.
final class DisabledAnalyticsService implements AnalyticsService {
  /// Creates the null object. `const` so registration allocates nothing.
  const DisabledAnalyticsService();

  @override
  void record(AnalyticsEvent event) {}
}
