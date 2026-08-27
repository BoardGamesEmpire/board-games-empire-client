import 'package:app_shell/src/widgets/detached_rehydrate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';

/// The guard both of the shell's re-hydrate callers share (#302, #300 D13).
///
/// `SessionRehydrateTrigger` and the household list's entry trigger each
/// have their own tests for *when* they fire. What is pinned here is what
/// happens when the pass they fire cannot even start — the reason the
/// handling is one function rather than a copy in each of them.
void main() {
  test('a composition with no rehydrator starts nothing', () {
    // #137: a platform that runs no drain resolves nothing, and that is
    // not an error.
    expect(
      () => startDetachedRehydrate(resolve: () => null, trigger: 'test'),
      returnsNormally,
    );
  });

  test('a resolve that throws is swallowed', () {
    // A per-server facade refuses use once disposed, so a scope that went
    // away between wiring and firing throws on the way in.
    expect(
      () => startDetachedRehydrate(
        resolve: () => throw StateError('container disposed'),
        trigger: 'test',
      ),
      returnsNormally,
    );
  });

  test('a pass that throws before its first await is swallowed', () {
    // `rehydrateStale` returns a future but is not required to be an
    // `async` method, so this throw never reaches the future's error
    // channel.
    expect(
      () => startDetachedRehydrate(
        resolve: () => _ThrowingRehydrator(),
        trigger: 'test',
      ),
      returnsNormally,
    );
  });

  test('a pass that fails asynchronously raises no unhandled error', () async {
    // An unhandled async error here would raise the crash-report prompt
    // (#34) for a refresh nobody asked for.
    startDetachedRehydrate(
      resolve: () => _FailingRehydrator(),
      trigger: 'test',
    );

    // Let the rejected future settle inside this test's error zone.
    await Future<void>.delayed(Duration.zero);
  });
}

class _ThrowingRehydrator implements SessionRehydrator {
  @override
  Future<void> rehydrateStale() => throw StateError('sync throw');

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) => throw UnimplementedError();
}

class _FailingRehydrator implements SessionRehydrator {
  @override
  Future<void> rehydrateStale() => Future<void>.error(StateError('async'));

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) => throw UnimplementedError();
}
