import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:rxdart/rxdart.dart';

/// `connectivity_plus`-backed [ConnectivityService] (#9).
///
/// Contract (tests are the spec; see
/// `test/connectivity_plus_service_test.dart`):
///
/// - **Optimistic seed.** [current] is [ConnectivityState.online]
///   immediately at construction.
/// - **Eager correction.** Construction fires one [connectivityCheck];
///   its result corrects the seed — unless a change event has already
///   arrived, in which case the (older) check result is discarded.
/// - **Never throws.** A failing check is swallowed; the seed stands
///   until the first change event.
/// - **Coarse mapping.** A list containing any non-`none` transport →
///   [ConnectivityState.online]; `[ConnectivityResult.none]`-only or
///   empty → [ConnectivityState.offline]. [ConnectivityState.unknown]
///   is never emitted (reserved, forward-compat).
/// - **Replay + dedupe.** [watch] replays [current] to each subscriber
///   ([BehaviorSubject] semantics); consecutive duplicate coarse states
///   are not re-emitted.
/// - **Lifecycle.** [dispose] cancels the source subscription and
///   completes [watch] streams; idempotent. Deliberately *not* on the
///   [ConnectivityService] interface (ISP); this class implements the
///   container's [Disposable] marker instead, so the root modules
///   register it with a dispose callback and the composition root's
///   container teardown drives cleanup.
///
/// [connectivityChanges] and [connectivityCheck] are the injectable
/// source seams for tests (same constructor-injection shape as
/// `PackageInfoBuildInfoReader`); production defaults come from a
/// [Connectivity] instance.
class ConnectivityPlusService implements ConnectivityService, Disposable {
  ConnectivityPlusService({
    Stream<List<ConnectivityResult>>? connectivityChanges,
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
  }) {
    // One instance backs both seams when defaults are used, avoiding
    // redundant platform channel wiring.
    final connectivity =
        (connectivityChanges == null || connectivityCheck == null)
        ? Connectivity()
        : null;
    final changes = connectivityChanges ?? connectivity!.onConnectivityChanged;
    final check = connectivityCheck ?? connectivity!.checkConnectivity;

    _subscription = changes.listen(_onEvent);
    unawaited(_eagerCheck(check));
  }

  final BehaviorSubject<ConnectivityState> _subject = BehaviorSubject.seeded(
    ConnectivityState.online,
  );

  late final StreamSubscription<List<ConnectivityResult>> _subscription;

  /// Set on the first change event; a check result resolving after this
  /// is older information and is discarded.
  bool _eventSeen = false;

  bool _disposed = false;

  @override
  ConnectivityState get current => _subject.value;

  @override
  Stream<ConnectivityState> watch() => _subject.stream;

  /// Cancels the platform subscription and completes [watch] streams.
  ///
  /// Idempotent. [current] remains readable (last known state) after
  /// disposal, but no further updates occur.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await _subject.close();
  }

  /// [Disposable] conformance: the container's dispose callback lands
  /// here and delegates to [dispose].
  @override
  Future<void> onDispose() => dispose();

  void _onEvent(List<ConnectivityResult> results) {
    _eventSeen = true;
    _emit(_map(results));
  }

  Future<void> _eagerCheck(
    Future<List<ConnectivityResult>> Function() check,
  ) async {
    try {
      final results = await check();
      // Discard if stale (an event arrived first) or already disposed.
      if (_eventSeen || _disposed) return;
      _emit(_map(results));
    } on Object {
      // Swallowed by contract: the optimistic seed stands until the
      // first change event. The degraded behaviour is itself the
      // signal — attempts proceed and fail honestly.
    }
  }

  void _emit(ConnectivityState next) {
    if (_disposed || next == _subject.value) return;
    _subject.add(next);
  }

  /// Coarse mapping: any live transport wins; `none`-only or empty
  /// (defensive — `connectivity_plus` shouldn't emit it) is offline.
  ConnectivityState _map(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none)
      ? ConnectivityState.online
      : ConnectivityState.offline;
}
