import 'feedback_transport.dart';

/// A snapshot of the active submission target, resolved fresh per
/// `submit` / `drainPending` call (#97).
///
/// Splits the two facts the device-global `FeedbackService` needs about
/// "where would this report go right now":
///
/// - [serverId] — the active server's stable `bgeServerId`, present
///   whenever a server is active, **even unauthenticated**. It tags
///   queued records so server A's reports never drain into server B.
/// - [transport] — the active server's [FeedbackTransport], present only
///   when that server also has an authenticated session (the feedback
///   endpoint requires one). Null → the report queues, correctly tagged.
class FeedbackTarget {
  const FeedbackTarget({required this.serverId, this.transport});

  /// Stable server-vended UUID (`bgeServerId`) of the active server.
  final String serverId;

  /// The active server's transport when authenticated, else null.
  final FeedbackTransport? transport;
}

/// The seam the device-global `FeedbackService` reads its submission
/// target through (#97).
///
/// Replaces the raw `FeedbackTransport? Function()` closure: the service
/// stays device-global (its collaborators — error hooks, breadcrumb
/// ring, crash overlay, durable sink — all are), while the per-server
/// dimension lives entirely in the resolved snapshot and in the
/// `serverId` tag on queued records. The "no active server" case is the
/// null branch of this one resolver, not a second service.
///
/// Implementations must be cheap and synchronous — the service re-reads
/// the target on every `submit` and `drainPending`. The production
/// adapter (`ActiveServerFeedbackTargetResolver` in `app_shell`) reads
/// the `ActiveServerScope` and the active container's
/// `AuthRepository.currentAuthState`.
abstract interface class FeedbackTargetResolver {
  /// The current submission target, or null when no server is active.
  FeedbackTarget? resolve();
}
