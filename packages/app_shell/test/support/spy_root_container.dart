import 'package:di/di.dart';

/// The production [DependencyContainerImpl] with dispose-call spying, for
/// shell tests that assert root-container lifecycle ownership (#72).
///
/// `app_shell` now depends on `di` (the root-container fallback in
/// `runBgeApp` is a real `DependencyContainerImpl`), so tests use the
/// production container directly rather than a parallel hand-rolled
/// double. register/get/dispose semantics — the post-dispose guard and
/// GetIt's throw-on-duplicate-registration — therefore match production
/// exactly; there is no "green against the double, red against real code"
/// gap. The only test-specific need is observing disposal.
class SpyRootContainer extends DependencyContainerImpl {
  int disposeCallCount = 0;

  /// Whether [dispose] has been called at least once.
  bool get disposed => disposeCallCount > 0;

  @override
  Future<void> dispose() async {
    // Increment runs synchronously on invocation (before the first await),
    // so `disposed` is observable immediately after an unawaited
    // `dispose()` call — the shape `BgeApp.dispose` uses.
    disposeCallCount++;
    await super.dispose();
  }
}
