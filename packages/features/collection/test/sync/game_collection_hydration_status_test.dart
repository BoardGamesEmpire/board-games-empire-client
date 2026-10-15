import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';

void main() {
  late GameCollectionHydrationStatus status;

  setUp(() => status = GameCollectionHydrationStatus());
  tearDown(() async => status.close());

  test('starts idle', () {
    // Idle is also what an ABSENT status means to the list screen: a
    // container with no hydrate must render the empty state, not spin
    // forever.
    expect(status.state, equals(GameCollectionHydrationState.idle));
  });

  test('a new listener is given the current state before any change', () async {
    status.started();

    await expectLater(
      status.watch().map((h) => h.state).take(1),
      emits(GameCollectionHydrationState.running),
    );
  });

  test('reports a pass in flight, then its result', () async {
    final seen = <GameCollectionHydrationState>[];
    final sub = status.watch().map((h) => h.state).listen(seen.add);
    addTearDown(sub.cancel);

    status
      ..started()
      ..finished(CollectionHydrateOutcome.complete);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      equals([
        GameCollectionHydrationState.idle,
        GameCollectionHydrationState.running,
        GameCollectionHydrationState.refreshed,
      ]),
    );
  });

  test('a failed pass reads as failed', () {
    status
      ..started()
      ..finished(CollectionHydrateOutcome.failed);

    expect(status.state, equals(GameCollectionHydrationState.failed));
  });

  test('a listener subscribing mid-pass sees the result', () async {
    // The install-time drain is unawaited, so the list can subscribe at any
    // point in it. No gap between the replayed value and the live stream.
    status.started();
    final seen = <GameCollectionHydrationState>[];
    final sub = status.watch().map((h) => h.state).listen(seen.add);
    addTearDown(sub.cancel);

    status.finished(CollectionHydrateOutcome.failed);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      equals([
        GameCollectionHydrationState.running,
        GameCollectionHydrationState.failed,
      ]),
    );
  });

  test('updates after close are ignored rather than thrown', () async {
    // The drain is unawaited and the scope pop closes this, so a pass still
    // in flight reports into a closed status. A throw there would be an
    // unhandled async error on the sign-in path.
    await status.close();

    expect(() => status.started(), returnsNormally);
    expect(
      () => status.finished(CollectionHydrateOutcome.complete),
      returnsNormally,
    );
    expect(status.state, equals(GameCollectionHydrationState.idle));
  });

  test('close is idempotent', () async {
    await status.close();
    await expectLater(status.close(), completes);
  });

  group('what a reading carries', () {
    // The list usually subscribes mid-pass and is replayed only the current
    // reading, so the history a screen needs has to be in it.
    Future<GameCollectionHydration> current() => status.watch().first;

    test('a completed pass is remembered through the next one', () async {
      status
        ..started()
        ..finished(CollectionHydrateOutcome.complete)
        ..started();

      expect(
        await current(),
        const GameCollectionHydration(
          state: GameCollectionHydrationState.running,
          everRefreshed: true,
        ),
      );
    });

    test('a failure is remembered until a pass completes', () async {
      status
        ..started()
        ..finished(CollectionHydrateOutcome.failed)
        ..started();

      expect((await current()).lastPassFailed, isTrue);

      status.finished(CollectionHydrateOutcome.complete);

      expect((await current()).lastPassFailed, isFalse);
    });

    test('a failure does not undo a completed pass', () async {
      status
        ..started()
        ..finished(CollectionHydrateOutcome.complete)
        ..started()
        ..finished(CollectionHydrateOutcome.failed);

      expect(
        await current(),
        const GameCollectionHydration(
          state: GameCollectionHydrationState.failed,
          everRefreshed: true,
          lastPassFailed: true,
        ),
      );
    });

    test('a failure alone confirms nothing', () async {
      status
        ..started()
        ..finished(CollectionHydrateOutcome.failed);

      expect((await current()).everRefreshed, isFalse);
    });
  });

  group('the staleness clock', () {
    late DateTime clock;
    late GameCollectionHydrationStatus stamped;

    setUp(() {
      clock = DateTime.utc(2026, 10, 15, 12);
      stamped = GameCollectionHydrationStatus(now: () => clock);
    });
    tearDown(() async => stamped.close());

    void advance(Duration by) => clock = clock.add(by);

    test('a status that has never refreshed has no age', () {
      expect(stamped.sinceRefresh, isNull);
    });

    test('a completed pass stamps when it landed', () {
      stamped
        ..started()
        ..finished(CollectionHydrateOutcome.complete);
      advance(const Duration(minutes: 7));

      expect(stamped.sinceRefresh, equals(const Duration(minutes: 7)));
    });

    test('a failed pass leaves the clock alone', () {
      stamped
        ..started()
        ..finished(CollectionHydrateOutcome.failed);

      expect(stamped.sinceRefresh, isNull);
    });

    test('a failure after a success keeps the earlier stamp', () {
      // The rows on screen are still the ones that success landed, so that
      // is how old they are. `failed` is stale by state instead.
      stamped
        ..started()
        ..finished(CollectionHydrateOutcome.complete);
      advance(const Duration(minutes: 2));
      stamped
        ..started()
        ..finished(CollectionHydrateOutcome.failed);

      expect(stamped.sinceRefresh, equals(const Duration(minutes: 2)));
    });

    test('a pass finishing after close stamps nothing', () async {
      stamped.started();
      await stamped.close();

      stamped.finished(CollectionHydrateOutcome.complete);

      expect(stamped.sinceRefresh, isNull);
    });

    group('isStaleAfter', () {
      const window = Duration(minutes: 5);

      test('a status that has never refreshed is stale at any window', () {
        expect(stamped.isStaleAfter(window), isTrue);
        expect(stamped.isStaleAfter(const Duration(days: 1)), isTrue);
      });

      test('a second short of the window is not stale', () {
        stamped
          ..started()
          ..finished(CollectionHydrateOutcome.complete);
        advance(window - const Duration(seconds: 1));

        expect(stamped.isStaleAfter(window), isFalse);
      });

      test('exactly at the window is stale', () {
        stamped
          ..started()
          ..finished(CollectionHydrateOutcome.complete);
        advance(window);

        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('a clock set back since the stamp is stale', () {
        // The age is unknown, not small. Otherwise every trigger would skip
        // the collection until the clock caught up with the stamp.
        stamped
          ..started()
          ..finished(CollectionHydrateOutcome.complete);
        advance(const Duration(days: -1));

        expect(stamped.isStaleAfter(window), isTrue);
      });
    });
  });
}
