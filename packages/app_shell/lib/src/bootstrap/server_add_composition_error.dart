/// Bootstrap found no server registered and could not resolve the set of
/// services adding one needs (#218).
///
/// `AppBootstrapCubit` raises it instead of emitting
/// `AppBootstrapNeedsServer`, which would pin the app to a server-add
/// route that cannot render. It is a wiring defect, not damaged device
/// state, so it never leads to the offer to reset the meta database.
final class ServerAddCompositionError implements Exception {
  const ServerAddCompositionError(this.cause);

  /// What resolving the set threw. When a service is not registered, the
  /// container's error names it.
  final Object cause;

  @override
  String toString() =>
      'ServerAddCompositionError: the services adding a server needs could '
      'not be resolved: $cause';
}
