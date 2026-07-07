/// States emitted by `AppBootstrapCubit`.
///
/// The router maps each state to a location:
///
/// | State                       | Location      |
/// |-----------------------------|---------------|
/// | [AppBootstrapInitializing]  | `/` (splash)  |
/// | [AppBootstrapFailed]        | `/error`      |
/// | [AppBootstrapNeedsServer]   | `/server-add` |
/// | [AppBootstrapNeedsAuth]     | `/auth`       |
/// | [AppBootstrapReady]         | `/home`       |
///
/// In this issue's scope the cubit never emits [AppBootstrapReady] from
/// bootstrap: a registered server routes to the auth leg unconditionally,
/// and the authenticated → home transition is owned by the auth wiring
/// issue (#37), which feeds real auth state into the same redirect seam.
sealed class AppBootstrapState {
  const AppBootstrapState();
}

/// Bootstrap is running; the splash screen is shown.
final class AppBootstrapInitializing extends AppBootstrapState {
  const AppBootstrapInitializing();
}

/// Bootstrap threw. Always retryable; the destructive recovery action is
/// offered only after repeated failures on platforms that support it.
final class AppBootstrapFailed extends AppBootstrapState {
  const AppBootstrapFailed({
    required this.error,
    required this.attemptCount,
    required this.canOfferReset,
  });

  /// The error thrown by the failing attempt.
  final Object error;

  /// Consecutive failed attempts since the last success or reset.
  final int attemptCount;

  /// Whether the UI may offer the delete-local-data recovery action:
  /// `attemptCount` has reached the configured threshold **and** the
  /// platform supports reset. Deletion itself still requires explicit
  /// user confirmation — the shell never destroys the meta database on
  /// its own.
  final bool canOfferReset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppBootstrapFailed &&
          other.error == error &&
          other.attemptCount == attemptCount &&
          other.canOfferReset == canOfferReset;

  @override
  int get hashCode => Object.hash(error, attemptCount, canOfferReset);

  @override
  String toString() =>
      'AppBootstrapFailed(attemptCount: $attemptCount, '
      'canOfferReset: $canOfferReset, error: $error)';
}

/// No server is registered on this device — route to server-add (#24/#36).
final class AppBootstrapNeedsServer extends AppBootstrapState {
  const AppBootstrapNeedsServer();
}

/// A server is registered (or implied by the web origin) — route to auth.
final class AppBootstrapNeedsAuth extends AppBootstrapState {
  const AppBootstrapNeedsAuth();
}

/// Fully ready — route to home. Reached via #37's auth wiring, not from
/// bootstrap itself in this issue's scope.
final class AppBootstrapReady extends AppBootstrapState {
  const AppBootstrapReady();
}
