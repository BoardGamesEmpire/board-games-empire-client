@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:web_platform/web_storage_composition.dart';

/// The sync drain's cross-tab lock over the browser's Web Locks (#447).
///
/// One page. The test runner cannot open a second tab, and two requests from
/// one page queue on a name the way two tabs' requests do: Web Locks are
/// granted per origin, not per page. A test across two real tabs is #482.
void main() {
  var counter = 0;

  /// A name no other test in the run shares, so one test's holder cannot
  /// make another's request wait.
  String freshName() =>
      'bge.sync_drain.test.${DateTime.now().microsecondsSinceEpoch}.'
      '${counter++}';

  /// The names the browser's lock manager reports held, and waiting.
  Future<({List<String> held, List<String> pending})> snapshot() async {
    final state = await web.window.navigator.locks.query().toDart;
    return (
      held: [for (final lock in state.held.toDart) lock.name],
      pending: [for (final lock in state.pending.toDart) lock.name],
    );
  }

  /// Polls the lock manager until [condition] holds of its snapshot, rather
  /// than guessing how long the browser takes to grant or queue a request.
  Future<void> until(
    bool Function(({List<String> held, List<String> pending})) condition,
  ) async {
    for (var i = 0; i < 100; i++) {
      if (condition(await snapshot())) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the lock manager never reached the expected state');
  }

  const lock = WebCrossTabLock();

  test('runs the body holding the lock, and returns true', () async {
    final name = freshName();
    List<String>? heldDuringBody;

    final ran = await lock.run(name, () async {
      heldDuringBody = (await snapshot()).held;
    });

    expect(ran, isTrue);
    expect(heldDuringBody, contains(name));
    expect((await snapshot()).held, isNot(contains(name)));
  });

  test(
    'a second request for the same name waits until the first body finishes',
    () async {
      final name = freshName();
      final events = <String>[];
      final release = Completer<void>();

      final first = lock.run(name, () async {
        events.add('first start');
        await release.future;
        events.add('first end');
      });
      final second = lock.run(name, () async {
        events
          ..add('second start')
          ..add('second end');
      });
      await until((s) => s.held.contains(name) && s.pending.contains(name));

      expect(events, ['first start']);

      release.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(events, [
        'first start',
        'first end',
        'second start',
        'second end',
      ]);
    },
  );

  test('releases the lock when the body throws', () async {
    final name = freshName();
    final failure = StateError('the pass failed');

    // The body's own error, not the wrapper a Dart error crossing a JS
    // promise comes back as.
    await expectLater(
      lock.run(name, () async => throw failure),
      throwsA(same(failure)),
    );

    expect((await snapshot()).held, isNot(contains(name)));
    expect(await lock.run(name, () async {}), isTrue);
  });

  test(
    'abandon before the grant returns false and never runs the body',
    () async {
      final name = freshName();
      final release = Completer<void>();
      final holder = lock.run(name, () => release.future);
      await until((s) => s.held.contains(name));
      final abandon = Completer<void>();
      var ran = false;

      final waiting = lock.run(
        name,
        () async => ran = true,
        abandon: abandon.future,
      );
      await until((s) => s.pending.contains(name));
      abandon.complete();

      expect(await waiting, isFalse);
      // Cancelled, not merely skipped once granted: the request has left the
      // queue while the holder still holds.
      expect((await snapshot()).pending, isNot(contains(name)));

      release.complete();
      expect(await holder, isTrue);
      expect(ran, isFalse);
    },
  );

  test('an abandon already complete returns false and never runs the body, '
      'even with the lock free', () async {
    var ran = false;

    final result = await lock.run(
      freshName(),
      () async => ran = true,
      abandon: Future<void>.value(),
    );

    expect(result, isFalse);
    expect(ran, isFalse);
  });

  test('abandon after the grant lets the body finish holding the lock, and '
      'returns true', () async {
    final name = freshName();
    final abandon = Completer<void>();
    final events = <String>[];

    final result = await lock.run(name, () async {
      events.add('start');
      abandon.complete();
      // Long enough for the abort to reach the lock manager.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if ((await snapshot()).held.contains(name)) events.add('still held');
      events.add('end');
    }, abandon: abandon.future);

    expect(result, isTrue);
    expect(events, ['start', 'still held', 'end']);
  });

  test('a grant that arrives after abandon runs nothing, and returns '
      'false', () async {
    // A browser can settle the grant before the abort reaches its lock
    // queue, and still call back afterwards. Chrome cancels its own request
    // on the abort, so this hands in a lock manager that grants when told.
    final grant = Completer<void>();
    final abandon = Completer<void>();
    var ran = false;

    final result = WebCrossTabLock(locks: _grantingOn(grant.future))
        .run(freshName(), () async => ran = true, abandon: abandon.future);
    abandon.complete();
    await Future<void>.delayed(Duration.zero);
    grant.complete();

    expect(await result, isFalse);
    expect(ran, isFalse);
  });

  test('a request the browser refuses throws, rather than reading as '
      'abandoned', () async {
    var ran = false;

    // Names starting with '-' are reserved, and the request rejects with a
    // NotSupportedError.
    await expectLater(
      lock.run('-bge.reserved', () async => ran = true),
      throwsA(anything),
    );
    expect(ran, isFalse);
  });

  test("different names don't wait on each other", () async {
    final release = Completer<void>();

    final first = lock.run(freshName(), () => release.future);
    // Would never complete if it queued behind the first.
    expect(await lock.run(freshName(), () async {}), isTrue);

    release.complete();
    expect(await first, isTrue);
  });
}

/// A lock manager that ignores its request's signal and grants when [grant]
/// completes: the order a browser produces when the grant was settled before
/// the abort reached its lock queue.
web.LockManager _grantingOn(Future<void> grant) {
  final manager = JSObject();
  manager['request'] = ((
    String name,
    JSObject options,
    JSFunction callback,
  ) => grant.then((_) => callback.callAsFunction(null, null)).toJS).toJS;
  return manager as web.LockManager;
}
