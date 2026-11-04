import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

final _log = BgeLogger('bge.di.lookup');

/// Lookups for **optional** capabilities: services a composition may leave
/// out, whose absence the caller already degrades around (#218).
///
/// A required service keeps [DependencyContainer.get]. A null for something
/// the caller cannot do without only moves the failure somewhere quieter,
/// usually a placeholder the user has no way out of (#219).
extension DependencyContainerLookups on DependencyContainer {
  /// Resolves [T], or returns null when it is not registered or its
  /// factory throws. A disposed `DependencyContainerImpl` reports nothing
  /// registered, so it reads as absent too. A container whose own
  /// `isRegistered` throws once disposed throws here as well.
  ///
  /// A throwing factory is logged at error level and then read as absent,
  /// so the caller's degraded path runs instead of an error surfacing
  /// mid-build. GetIt caches nothing for a lazy factory that threw, so the
  /// next call runs it again: a transient failure recovers, and a permanent
  /// one logs on every call.
  T? tryGet<T extends Object>() {
    if (!isRegistered<T>()) return null;
    try {
      return get<T>();
    } on Object catch (error, stackTrace) {
      _log.error(
        'Resolving $T failed; treating it as absent.',
        error: error,
        stackTrace: stackTrace,
        context: {'type': '$T'},
      );
      return null;
    }
  }
}
