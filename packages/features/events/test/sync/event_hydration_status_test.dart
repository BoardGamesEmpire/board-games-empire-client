import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';

/// The outcomes that cached every page the server sent. They differ in what
/// the pass could purge, and the status reads them alike.
const _cachedEverything = [
  EventHydrateOutcome.complete,
  EventHydrateOutcome.windowed,
  EventHydrateOutcome.drained,
];

void main() {
  late EventHydrationStatus status;

  setUp(() => status = EventHydrationStatus());
  tearDown(() async => status.close());

  test('starts idle', () {
    // Idle is also what an ABSENT status means to an event screen: a
    // container with no hydrate must render the empty state, not spin
    // forever.
    expect(status.state, equals(EventHydrationState.idle));
  });

  test('complete, windowed and drained all read as refreshed', () {
    // Each one cached every page the server sent, which is what the screens
    // show. The three differ only in what the purge could remove.
    for (final outcome in _cachedEverything) {
      final fresh = EventHydrationStatus();
      addTearDown(fresh.close);

      fresh
        ..started()
        ..finished(outcome);

      expect(
        fresh.state,
        equals(EventHydrationState.refreshed),
        reason: '$outcome',
      );
    }
  });

  test('a failed pass reads as failed', () {
    status
      ..started()
      ..finished(EventHydrateOutcome.failed);

    expect(status.state, equals(EventHydrationState.failed));
  });

  test('a new listener is given the current state before any change', () async {
    status.started();

    await expectLater(
      status.watch().map((h) => h.state).take(1),
      emits(EventHydrationState.running),
    );
  });

  test('reports a pass in flight, then its result', () async {
    final seen = <EventHydrationState>[];
    final sub = status.watch().map((h) => h.state).listen(seen.add);
    addTearDown(sub.cancel);

    status
      ..started()
      ..finished(EventHydrateOutcome.complete);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      equals([
        EventHydrationState.idle,
        EventHydrationState.running,
        EventHydrationState.refreshed,
      ]),
    );
  });

  test('a listener subscribing mid-pass sees the result', () async {
    // The install-time pass is unawaited, so a screen can subscribe at any
    // point in it. No gap between the replayed value and the live stream.
    status.started();
    final seen = <EventHydrationState>[];
    final sub = status.watch().map((h) => h.state).listen(seen.add);
    addTearDown(sub.cancel);

    status.finished(EventHydrateOutcome.failed);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      equals([EventHydrationState.running, EventHydrationState.failed]),
    );
  });

  test('updates after close are ignored rather than thrown', () async {
    // The pass is unawaited and the scope pop closes this, so a pass still in
    // flight reports into a closed status. A throw there would be an
    // unhandled async error on the sign-in path.
    await status.close();

    expect(() => status.started(), returnsNormally);
    expect(
      () => status.finished(EventHydrateOutcome.complete),
      returnsNormally,
    );
    expect(status.state, equals(EventHydrationState.idle));
  });

  test('close is idempotent', () async {
    await status.close();
    await expectLater(status.close(), completes);
  });

  group('what a reading carries', () {
    // A screen usually subscribes mid-pass and is replayed only the current
    // reading, so the history it needs has to be in it.
    Future<EventHydration> current() => status.watch().first;

    test('a completed pass is remembered through the next one', () async {
      status
        ..started()
        ..finished(EventHydrateOutcome.complete)
        ..started();

      expect(
        await current(),
        const EventHydration(
          state: EventHydrationState.running,
          everRefreshed: true,
        ),
      );
    });

    test('a failure is remembered until a pass completes', () async {
      status
        ..started()
        ..finished(EventHydrateOutcome.failed)
        ..started();

      expect((await current()).lastPassFailed, isTrue);

      status.finished(EventHydrateOutcome.complete);

      expect((await current()).lastPassFailed, isFalse);
    });

    test('a windowed or drained pass also clears an earlier failure', () async {
      // Neither is a failure: the rows on screen are the server's current
      // answer, so the banner for the last failure goes.
      for (final outcome in [
        EventHydrateOutcome.windowed,
        EventHydrateOutcome.drained,
      ]) {
        final after = EventHydrationStatus();
        addTearDown(after.close);

        after
          ..started()
          ..finished(EventHydrateOutcome.failed)
          ..started()
          ..finished(outcome);

        expect(
          await after.watch().first,
          const EventHydration(
            state: EventHydrationState.refreshed,
            everRefreshed: true,
          ),
          reason: '$outcome',
        );
      }
    });

    test('failed keeps everRefreshed from before', () async {
      // A failure does not undo what a success confirmed, whichever way that
      // success ended.
      for (final earlier in _cachedEverything) {
        final after = EventHydrationStatus();
        addTearDown(after.close);

        after
          ..started()
          ..finished(earlier)
          ..started()
          ..finished(EventHydrateOutcome.failed);

        expect(
          await after.watch().first,
          const EventHydration(
            state: EventHydrationState.failed,
            everRefreshed: true,
            lastPassFailed: true,
          ),
          reason: 'after $earlier',
        );
      }
    });

    test('a failure alone confirms nothing', () async {
      status
        ..started()
        ..finished(EventHydrateOutcome.failed);

      expect((await current()).everRefreshed, isFalse);
    });
  });

  group('the staleness clock', () {
    late DateTime clock;
    late EventHydrationStatus stamped;

    setUp(() {
      clock = DateTime.utc(2026, 10, 22, 12);
      stamped = EventHydrationStatus(now: () => clock);
    });
    tearDown(() async => stamped.close());

    void advance(Duration by) => clock = clock.add(by);

    test('a status that has never refreshed has no age', () {
      expect(stamped.sinceRefresh, isNull);
    });

    test('every pass that cached the list stamps when it landed', () {
      for (final outcome in _cachedEverything) {
        var now = DateTime.utc(2026, 10, 22, 12);
        final landed = EventHydrationStatus(now: () => now);
        addTearDown(landed.close);

        landed
          ..started()
          ..finished(outcome);
        now = now.add(const Duration(minutes: 7));

        expect(
          landed.sinceRefresh,
          equals(const Duration(minutes: 7)),
          reason: '$outcome',
        );
      }
    });

    test('a failed pass leaves the clock alone', () {
      stamped
        ..started()
        ..finished(EventHydrateOutcome.failed);

      expect(stamped.sinceRefresh, isNull);
    });

    test('a failure after a success keeps the earlier stamp', () {
      // The rows on screen are still the ones that success landed, so that is
      // how old they are. `failed` is stale by state instead.
      stamped
        ..started()
        ..finished(EventHydrateOutcome.complete);
      advance(const Duration(minutes: 2));
      stamped
        ..started()
        ..finished(EventHydrateOutcome.failed);

      expect(stamped.sinceRefresh, equals(const Duration(minutes: 2)));
    });

    test('a pass finishing after close stamps nothing', () async {
      stamped.started();
      await stamped.close();

      stamped.finished(EventHydrateOutcome.complete);

      expect(stamped.sinceRefresh, isNull);
    });

    group('isStaleAfter', () {
      const window = Duration(minutes: 5);

      test('a status that has never refreshed is stale at any window', () {
        expect(stamped.isStaleAfter(window), isTrue);
        expect(stamped.isStaleAfter(const Duration(days: 1)), isTrue);
      });

      test('stale after five minutes', () {
        stamped
          ..started()
          ..finished(EventHydrateOutcome.complete);

        advance(const Duration(minutes: 5) - const Duration(seconds: 1));
        expect(stamped.isStaleAfter(const Duration(minutes: 5)), isFalse);

        // Inclusive at the boundary: exactly the window is already that old.
        advance(const Duration(seconds: 1));
        expect(stamped.isStaleAfter(const Duration(minutes: 5)), isTrue);
      });

      test('a windowed or drained pass ages out like a complete one', () {
        // They read as refreshed, so they must not be exempt from the window:
        // a session that hydrated once would otherwise never ask again.
        for (final outcome in [
          EventHydrateOutcome.windowed,
          EventHydrateOutcome.drained,
        ]) {
          var now = DateTime.utc(2026, 10, 22, 12);
          final aged = EventHydrationStatus(now: () => now);
          addTearDown(aged.close);
          aged
            ..started()
            ..finished(outcome);

          now = now.add(window - const Duration(seconds: 1));
          expect(aged.isStaleAfter(window), isFalse, reason: '$outcome');

          now = now.add(const Duration(seconds: 1));
          expect(aged.isStaleAfter(window), isTrue, reason: '$outcome');
        }
      });

      test('a clock set back since the stamp is stale', () {
        // The age is unknown, not small. Otherwise every trigger would skip
        // the events until the clock caught up with the stamp.
        stamped
          ..started()
          ..finished(EventHydrateOutcome.complete);
        advance(const Duration(days: -1));

        expect(stamped.isStaleAfter(window), isTrue);
      });
    });
  });
}
