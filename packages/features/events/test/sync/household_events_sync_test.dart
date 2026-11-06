import 'dart:async';

import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';

/// A hydrator that answers each household's pass from [answers], or holds it
/// on a [hold] until the test releases it, and records the household each
/// pass named.
class _FakeHydrator implements HouseholdEventsHydrator {
  final passes = <String>[];

  /// Each household's outcome. One not named here completes.
  final answers = <String, HouseholdEventsOutcome>{};

  final _held = <String, Completer<HouseholdEventsOutcome>>{};

  /// Holds [householdId]'s next pass until the returned completer completes.
  Completer<HouseholdEventsOutcome> hold(String householdId) =>
      _held[householdId] = Completer<HouseholdEventsOutcome>();

  @override
  Future<HouseholdEventsOutcome> hydrate(String householdId) {
    passes.add(householdId);
    final held = _held.remove(householdId);
    if (held != null) return held.future;
    return Future.value(
      answers[householdId] ?? HouseholdEventsOutcome.complete,
    );
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// Answers every question with [answer], and records whom it was asked about.
class _FakeIdentityGuard implements SessionIdentityGuard {
  _FakeIdentityGuard(this.answer);

  final SessionConfirmation answer;
  final askedFor = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    askedFor.add(userId);
    return answer;
  }
}

const _kUserId = 'user-1';

void main() {
  late _FakeHydrator hydrator;
  late HouseholdEventsSync sync;

  setUp(() {
    hydrator = _FakeHydrator();
    sync = HouseholdEventsSync(hydrator: hydrator, userId: _kUserId);
  });

  tearDown(() => sync.close());

  /// Every reading [householdId]'s status gives, from now on.
  List<HydrationState> record(String householdId) {
    final seen = <HydrationState>[];
    final watching = sync
        .watch(householdId)
        .map((h) => h.state)
        .listen(seen.add);
    addTearDown(watching.cancel);
    return seen;
  }

  test('watch reads idle before any refresh', () async {
    // The screen opens before its pass starts, or with no pass at all.
    expect(await sync.watch('h-1').first, const Hydration());
    expect(hydrator.passes, isEmpty);
  });

  test('refresh runs the hydrator for that household and reports running then '
      'refreshed', () async {
    final seen = record('h-1');
    await pumpEventQueue();

    await sync.refresh('h-1');
    await pumpEventQueue();

    expect(hydrator.passes, ['h-1']);
    expect(seen, [
      HydrationState.idle,
      HydrationState.running,
      HydrationState.refreshed,
    ]);
  });

  test('refresh leaves the status running before it returns', () async {
    // The screen's open calls refresh unawaited and builds at once; an idle
    // status there would read as nothing to wait for.
    hydrator.hold('h-1');

    unawaited(sync.refresh('h-1'));

    final reading = await sync.watch('h-1').first;
    expect(reading.state, HydrationState.running);
  });

  test('two refreshes of one household share a pass', () async {
    // A retry pressed while the open's pass runs joins it.
    final held = hydrator.hold('h-1');

    final first = sync.refresh('h-1');
    final second = sync.refresh('h-1');
    held.complete(HouseholdEventsOutcome.complete);
    await Future.wait([first, second]);

    expect(hydrator.passes, ['h-1']);
  });

  test('a refresh after a pass ends starts another', () async {
    // A concurrency guard, not a cache: the next open asks the server again.
    await sync.refresh('h-1');
    await sync.refresh('h-1');

    expect(hydrator.passes, ['h-1', 'h-1']);
  });

  test('a refresh after a change waits out the running pass and starts '
      'another', () async {
    // Coming back to the screen: the open's pass may have read the list
    // before an event made meanwhile, so joining it would leave that out.
    final held = hydrator.hold('h-1');

    final open = sync.refresh('h-1');
    final back = sync.refreshAfterChange('h-1');
    await pumpEventQueue();
    expect(hydrator.passes, ['h-1'], reason: 'nothing starts mid-pass');

    held.complete(HouseholdEventsOutcome.complete);
    await Future.wait([open, back]);

    expect(hydrator.passes, ['h-1', 'h-1']);
  });

  test('a refresh after a change with no pass running starts one', () async {
    await sync.refreshAfterChange('h-1');

    expect(hydrator.passes, ['h-1']);
  });

  test('households have separate passes and statuses', () async {
    final held = hydrator.hold('h-1');
    hydrator.answers['h-2'] = HouseholdEventsOutcome.failed;

    final first = sync.refresh('h-1');
    await sync.refresh('h-2');

    expect(hydrator.passes, ['h-1', 'h-2']);
    expect((await sync.watch('h-1').first).state, HydrationState.running);
    expect((await sync.watch('h-2').first).state, HydrationState.failed);

    held.complete(HouseholdEventsOutcome.complete);
    await first;

    expect((await sync.watch('h-1').first).state, HydrationState.refreshed);
    expect((await sync.watch('h-2').first).state, HydrationState.failed);
  });

  test(
    'a failed pass reads failed, and the next pass that lands reads refreshed',
    () async {
      hydrator.answers['h-1'] = HouseholdEventsOutcome.failed;
      await sync.refresh('h-1');

      expect(
        await sync.watch('h-1').first,
        const Hydration(state: HydrationState.failed, lastPassFailed: true),
      );

      hydrator.answers['h-1'] = HouseholdEventsOutcome.complete;
      await sync.refresh('h-1');

      expect(
        await sync.watch('h-1').first,
        const Hydration(state: HydrationState.refreshed, everRefreshed: true),
      );
    },
  );

  group('every outcome but failed lands', () {
    // A drained pass cached every page it was sent, and a household that is
    // gone lists nothing, which its emptied section now shows.
    for (final outcome in [
      HouseholdEventsOutcome.complete,
      HouseholdEventsOutcome.drained,
      HouseholdEventsOutcome.notFound,
    ]) {
      test(outcome.name, () async {
        hydrator.answers['h-1'] = outcome;

        await sync.refresh('h-1');

        expect((await sync.watch('h-1').first).state, HydrationState.refreshed);
      });
    }
  });

  test(
    'a session the guard will not confirm runs no pass, and reads failed',
    () async {
      // On web another tab can move the shared session to another user, and
      // a pass sent then would cache what the household shows them (#432).
      final guard = _FakeIdentityGuard(SessionConfirmation.notThisUser);
      final guarded = HouseholdEventsSync(
        hydrator: hydrator,
        userId: _kUserId,
        guard: guard,
      );
      addTearDown(guarded.close);

      await guarded.refresh('h-1');

      expect(guard.askedFor, [_kUserId]);
      expect(hydrator.passes, isEmpty);
      expect((await guarded.watch('h-1').first).state, HydrationState.failed);
    },
  );

  group('close', () {
    test('close closes every status\'s stream', () async {
      await sync.refresh('h-1');
      final first = sync.watch('h-1');
      final second = sync.watch('h-2');
      final done = [
        first.toList().timeout(const Duration(seconds: 5)),
        second.toList().timeout(const Duration(seconds: 5)),
      ];

      await sync.close();

      expect(await done[0], [
        const Hydration(state: HydrationState.refreshed, everRefreshed: true),
      ]);
      expect(await done[1], [const Hydration()]);
    });

    test('a refresh after close runs nothing', () async {
      await sync.close();

      await sync.refresh('h-1');
      await sync.refreshAfterChange('h-1');

      expect(hydrator.passes, isEmpty);
    });

    test('a watch after close gives the last reading, idle for a household it '
        'never named, and ends', () async {
      await sync.refresh('h-1');
      await sync.close();

      expect(
        await sync.watch('h-1').toList().timeout(const Duration(seconds: 5)),
        [const Hydration(state: HydrationState.refreshed, everRefreshed: true)],
      );
      expect(
        await sync.watch('h-2').toList().timeout(const Duration(seconds: 5)),
        [const Hydration()],
      );
    });

    test('a pass still in flight at close lands without throwing', () async {
      // The screen's open is unawaited, so its pass can outlive the session
      // scope that closes this.
      final held = hydrator.hold('h-1');
      final refreshing = sync.refresh('h-1');

      await sync.close();
      held.complete(HouseholdEventsOutcome.complete);
      await refreshing;

      expect(hydrator.passes, ['h-1']);
      // Its closed status dropped the late outcome.
      expect(
        await sync.watch('h-1').toList().timeout(const Duration(seconds: 5)),
        [const Hydration(state: HydrationState.running)],
      );
    });
  });
}
