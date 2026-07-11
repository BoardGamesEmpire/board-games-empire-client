import 'package:app_shell/app_shell.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';

import 'spy_root_container.dart';

/// Scriptable [PlatformBootstrap] for shell tests.
///
/// [outcomes] is consumed in order by successive [initialize] calls; each
/// entry is either a [BootstrapResult] (returned) or an error object
/// (thrown). The final entry repeats once the list is exhausted. With no
/// outcomes configured, [initialize] succeeds with
/// `BootstrapResult(hasServer: true, orchestrator: orchestrator)`.
///
/// [createRootContainer] (#72) is scripted via [rootContainerOutcome]: a
/// [DependencyContainer] is returned as-is, any other object is thrown,
/// and `null` (the default) builds a fresh [SpyRootContainer] — the real
/// [DependencyContainerImpl] with dispose spying, so tests exercise
/// production container semantics. [onCreateRootContainer] fires
/// synchronously at the start of the call — the probe point sequencing
/// tests use to observe process globals (e.g. "error hooks not installed
/// yet") at container-build time.
///
/// [createDeepLinkSource] (#10) returns [deepLinkSource] as-is — null by
/// default, matching the platform with no out-of-band channel (web).
/// Wiring tests script a fake source here.
class FakePlatformBootstrap implements PlatformBootstrap {
  FakePlatformBootstrap({
    List<Object> outcomes = const [],
    this.supportsReset = true,
    ServerOrchestrator? orchestrator,
    this.rootContainerOutcome,
    this.onCreateRootContainer,
    this.deepLinkSource,
  }) : _outcomes = List.of(outcomes),
       _orchestrator = orchestrator;

  final List<Object> _outcomes;
  final ServerOrchestrator? _orchestrator;

  @override
  final bool supportsReset;

  /// Scripts [createRootContainer]; see the class docs.
  Object? rootContainerOutcome;

  /// Invoked synchronously at the start of [createRootContainer].
  void Function()? onCreateRootContainer;

  /// Scripts [createDeepLinkSource] (#10); null = no out-of-band channel.
  DeepLinkSource? deepLinkSource;

  /// The last container returned from [createRootContainer], if any.
  DependencyContainer? lastRootContainer;

  /// Ordered log of lifecycle calls: `'createRootContainer'`,
  /// `'createDeepLinkSource'`, `'initialize'`, and `'reset'`.
  final List<String> calls = [];

  int get initializeCallCount => calls.where((c) => c == 'initialize').length;
  int get resetCallCount => calls.where((c) => c == 'reset').length;
  int get createRootContainerCallCount =>
      calls.where((c) => c == 'createRootContainer').length;
  int get createDeepLinkSourceCallCount =>
      calls.where((c) => c == 'createDeepLinkSource').length;

  @override
  Future<DependencyContainer> createRootContainer() async {
    calls.add('createRootContainer');
    onCreateRootContainer?.call();
    final outcome = rootContainerOutcome;
    if (outcome is DependencyContainer) {
      return lastRootContainer = outcome;
    }
    if (outcome != null) {
      // Anything that isn't a container is scripted to be thrown.
      // ignore: only_throw_errors
      throw outcome;
    }
    return lastRootContainer = SpyRootContainer();
  }

  @override
  DeepLinkSource? createDeepLinkSource() {
    calls.add('createDeepLinkSource');
    return deepLinkSource;
  }

  @override
  Future<BootstrapResult> initialize() async {
    calls.add('initialize');
    if (_outcomes.isEmpty) {
      return BootstrapResult(hasServer: true, orchestrator: _orchestrator);
    }
    final outcome = _outcomes.length == 1
        ? _outcomes.first
        : _outcomes.removeAt(0);
    if (outcome is BootstrapResult) return outcome;
    // Anything that isn't a result is scripted to be thrown.
    // ignore: only_throw_errors
    throw outcome;
  }

  @override
  Future<void> reset() async {
    if (!supportsReset) {
      throw UnsupportedError('reset() is not supported on this platform');
    }
    calls.add('reset');
  }

  @override
  Future<HydratedStorageDirectory> hydratedStorageDirectory() async =>
      HydratedStorageDirectory('unused-in-tests');
}
