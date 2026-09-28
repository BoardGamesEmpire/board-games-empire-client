import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('replayThenForward', () {
    test('replays the current value to a new listener', () async {
      final stream = replayThenForward(current: () => 7, updates: null);

      expect(await stream.first, 7);
    });

    test('reads the current value at each listen, not at creation', () async {
      var value = 1;
      final stream = replayThenForward(current: () => value, updates: null);
      value = 2;

      expect(await stream.first, 2);
      value = 3;
      expect(await stream.first, 3, reason: 'the stream is re-listenable');
    });

    test('calls updates once per listen, so even a single-subscription '
        'upstream can be listened to again', () async {
      var listens = 0;
      Stream<int> upstream() async* {
        yield ++listens;
      }

      final stream = replayThenForward(current: () => 0, updates: upstream);

      expect(await stream.toList(), [0, 1]);
      expect(await stream.toList(), [0, 2]);
    });

    test('forwards updates after the replay, in order', () async {
      final updates = StreamController<int>.broadcast();
      addTearDown(updates.close);
      final seen = <int>[];
      final sub = replayThenForward(
        current: () => 0,
        updates: () => updates.stream,
      ).listen(seen.add);
      addTearDown(sub.cancel);

      await pumpEventQueue();
      updates
        ..add(1)
        ..add(2);
      await pumpEventQueue();

      expect(seen, [0, 1, 2]);
    });

    test('closes when the updates close', () async {
      final updates = StreamController<int>.broadcast();
      final all = replayThenForward(
        current: () => 0,
        updates: () => updates.stream,
      ).toList();

      await pumpEventQueue();
      updates.add(1);
      await updates.close();

      expect(await all, [0, 1]);
    });

    test('replays, then closes, when the updates are already closed', () async {
      // A disposed source: a late listener still gets the last value, then
      // done, rather than a stream that never completes.
      final updates = StreamController<int>.broadcast();
      await updates.close();

      final all = replayThenForward(
        current: () => 5,
        updates: () => updates.stream,
      ).toList().timeout(const Duration(seconds: 1));

      expect(await all, [5]);
    });

    test('forwards errors from the updates', () async {
      final updates = StreamController<int>.broadcast();
      addTearDown(updates.close);
      final errors = <Object>[];
      final sub = replayThenForward(
        current: () => 0,
        updates: () => updates.stream,
      ).listen((_) {}, onError: errors.add);
      addTearDown(sub.cancel);

      await pumpEventQueue();
      updates.addError(StateError('upstream failed'));
      await pumpEventQueue();

      expect(errors, [isA<StateError>()]);
    });

    test('with null updates, stays open after the replay', () async {
      var done = false;
      final seen = <int>[];
      final sub = replayThenForward(
        current: () => 9,
        updates: null,
      ).listen(seen.add, onDone: () => done = true);
      addTearDown(sub.cancel);

      await pumpEventQueue();

      expect(seen, [9]);
      expect(done, isFalse, reason: 'a value that never changes is not done');
    });

    test('cancelling the listener cancels its updates subscription', () async {
      final updates = StreamController<int>.broadcast();
      addTearDown(updates.close);
      final sub = replayThenForward(
        current: () => 0,
        updates: () => updates.stream,
      ).listen((_) {});

      await pumpEventQueue();
      expect(updates.hasListener, isTrue);

      await sub.cancel();

      expect(updates.hasListener, isFalse);
    });

    // Every owner awaits its controller's close() on dispose, and a
    // broadcast controller's close() waits for any paused subscription to
    // it. Passing the pause upstream fails this test by timing out.
    test('a paused listener does not hold up the updates closing', () async {
      final updates = StreamController<int>.broadcast();
      final seen = <int>[];
      var done = false;
      final sub = replayThenForward(
        current: () => 0,
        updates: () => updates.stream,
      ).listen(seen.add, onDone: () => done = true);
      await pumpEventQueue();

      sub.pause();
      updates.add(1);
      await updates.close().timeout(const Duration(seconds: 1));
      sub.resume();
      await pumpEventQueue();

      expect(seen, [0, 1], reason: 'events wait for the listener to resume');
      expect(done, isTrue);
    });

    // WebAuthRepositoryImpl relies on this: its reconcile success path skips
    // an epoch recheck because no subscriber can react to an emission before
    // the awaiting caller resumes, even though its own controller is
    // `sync: true`. Delivering with `addSync` fails this test.
    test('an update from a sync upstream reaches listeners only after the '
        'awaiting caller resumes', () async {
      final updates = StreamController<int>.broadcast(sync: true);
      addTearDown(updates.close);
      final order = <String>[];
      final sub = replayThenForward(
        current: () => 0,
        updates: () => updates.stream,
      ).listen((value) => order.add('listener($value)'));
      addTearDown(sub.cancel);
      await pumpEventQueue();
      order.clear();

      Future<void> emitAfterIo() async {
        await Future<void>.value();
        updates.add(1);
      }

      await emitAfterIo().then((_) => order.add('awaiting-caller'));
      await pumpEventQueue();

      expect(order, ['awaiting-caller', 'listener(1)']);
    });
  });
}
