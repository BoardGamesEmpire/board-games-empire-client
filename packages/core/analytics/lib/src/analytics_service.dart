import 'package:analytics/src/analytics_event.dart';

/// Records analytics events from the catalog (#17).
///
/// The contract:
///
/// - **Device-global.** One instance lives in the root container, like
///   `FeedbackService`, not one per server.
/// - **Synchronous and fire-and-forget.** [record] returns nothing to wait
///   on.
/// - **Never throws.** A failure to record is the implementation's to
///   absorb; recording must never break the feature that called it.
/// - **Callers do not branch on whether analytics is on.** Consent,
///   recipients and the device id stay behind the implementation, so there
///   is no surface here to ask about them.
///
/// There is no timestamp or clock parameter. `ClockService` is registered
/// per server scope while this service is device-global, so timestamps
/// arrive with the queue, through the resolved per-server target the way
/// feedback reports get theirs (#97, #17).
abstract interface class AnalyticsService {
  /// Records [event]. Returns immediately and never throws.
  void record(AnalyticsEvent event);
}
