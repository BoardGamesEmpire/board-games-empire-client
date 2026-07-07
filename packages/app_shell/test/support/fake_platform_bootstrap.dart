import 'package:app_shell/app_shell.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';

/// Scriptable [PlatformBootstrap] for shell tests.
///
/// [outcomes] is consumed in order by successive [initialize] calls; each
/// entry is either a [BootstrapResult] (returned) or an error object
/// (thrown). The final entry repeats once the list is exhausted. With no
/// outcomes configured, [initialize] succeeds with
/// `BootstrapResult(hasServer: true, orchestrator: orchestrator)`.
class FakePlatformBootstrap implements PlatformBootstrap {
  FakePlatformBootstrap({
    List<Object> outcomes = const [],
    this.supportsReset = true,
    ServerOrchestrator? orchestrator,
  }) : _outcomes = List.of(outcomes),
       _orchestrator = orchestrator;

  final List<Object> _outcomes;
  final ServerOrchestrator? _orchestrator;

  @override
  final bool supportsReset;

  /// Ordered log of lifecycle calls: `'initialize'` and `'reset'`.
  final List<String> calls = [];

  int get initializeCallCount => calls.where((c) => c == 'initialize').length;
  int get resetCallCount => calls.where((c) => c == 'reset').length;

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
