import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:interfaces/orchestration.dart';

/// One registered hydrate: how to ask whether it needs re-running, and how
/// to run it.
@immutable
class _Entry {
  const _Entry({required this.key, required this.isStale, required this.run});

  final String key;
  final bool Function() isStale;
  final Future<void> Function() run;
}

/// Session-scoped [SessionRehydrator] (#302 D2).
///
/// Registered by a leading `UserScopeInstaller` and disposed with the
/// session scope, so the "no re-run without an active session" rule is
/// structural rather than a guard anyone has to remember.
///
/// Registration runs on the composition path only; a pass runs on whatever
/// turn its trigger fires. Neither is concurrent with itself in the Dart
/// sense, and the single-flight guard below covers the one interleaving
/// that is real — a second trigger arriving while a pass is awaiting.
class SessionRehydratorImpl implements SessionRehydrator {
  final Map<String, _Entry> _entries = <String, _Entry>{};

  /// The pass currently running, or null when none is.
  Future<void>? _inFlight;

  bool _closed = false;

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {
    // Dropped rather than thrown: registration happens inside
    // `UserScopeInstaller.install`, where a throw aborts activation and
    // the shell converges that to a sign-out. A closed registry means the
    // session is already ending, which is not a wiring bug worth signing
    // anyone out over.
    if (_closed) return;

    if (_entries.containsKey(key)) {
      throw ArgumentError.value(
        key,
        'key',
        'A hydrate is already registered under this key',
      );
    }
    _entries[key] = _Entry(key: key, isStale: isStale, run: run);
  }

  @override
  Future<void> rehydrateStale() {
    if (_closed) return Future<void>.value();

    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final pass = _pass();
    _inFlight = pass;
    // Identity-checked so a settling pass cannot clear its successor.
    return pass.whenComplete(() {
      if (identical(_inFlight, pass)) _inFlight = null;
    });
  }

  /// Runs the stale entries, in registration order.
  ///
  /// The snapshot is taken once, up front: an entry registered while this
  /// is awaiting belongs to the next pass, not this one. Registration is
  /// a composition-time act and a pass is not, so the overlap is only
  /// reachable from a test — but iterating a map being mutated would throw
  /// out of a method whose contract is that it never does.
  Future<void> _pass() async {
    for (final entry in List<_Entry>.of(_entries.values)) {
      if (_closed) return;
      if (!_isStale(entry)) continue;

      try {
        await entry.run();
      } on Object catch (error, stackTrace) {
        // Isolated per entry: one feature's failed drain must not stop the
        // features after it, and must not fail a pass whose callers
        // (a connectivity edge, an app resume) have nowhere to report to.
        _report('hydrate', entry.key, error, stackTrace);
      }
    }
  }

  /// A staleness check that throws is treated as **not** stale: a broken
  /// predicate should skip its entry, not re-drain it on every trigger.
  bool _isStale(_Entry entry) {
    try {
      return entry.isStale();
    } on Object catch (error, stackTrace) {
      _report('staleness check', entry.key, error, stackTrace);
      return false;
    }
  }

  /// Debug-only breadcrumb. `di` carries no observability dependency, so
  /// this follows `ServerContextImpl`'s existing assert/debugPrint shape
  /// rather than adding one for a swallowed error.
  void _report(String what, String key, Object error, StackTrace stackTrace) {
    assert(() {
      debugPrint('SessionRehydrator: $what for "$key" threw: $error');
      return true;
    }());
  }

  /// Releases the registry. Idempotent; wired as the registration's
  /// `dispose:` callback so the session scope tears it down.
  ///
  /// A pass already in flight is left to settle — its entries hold
  /// resources from a scope that is disposing, and abandoning them
  /// mid-await would strand exactly the writes the drain is making. The
  /// loop checks [_closed] between entries, so the pass stops at the next
  /// boundary rather than running the rest.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _entries.clear();
  }
}
