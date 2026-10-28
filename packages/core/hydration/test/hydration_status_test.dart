import 'package:hydration/hydration.dart';
import 'package:test/test.dart';

enum _Outcome { complete, partial, failed }

bool _landed(_Outcome o) => o != _Outcome.failed;

void main() {
  late HydrationStatus<_Outcome> status;

  setUp(() => status = HydrationStatus<_Outcome>(landed: _landed));
  tearDown(() async => status.close());

  test('starts idle', () {
    // Idle is also what an ABSENT status means to the list screen (#269):
    // a container with no hydrator must render the empty state, not spin
    // forever.
    expect(status.state, equals(HydrationState.idle));
  });

  test('a new listener is given the current state before any change', () async {
    status.started();

    await expectLater(
      status.watch().map((h) => h.state).take(1),
      emits(HydrationState.running),
    );
  });

  test('reports a pass in flight, then its result', () async {
    final seen = <HydrationState>[];
    final sub = status.watch().map((h) => h.state).listen(seen.add);
    addTearDown(sub.cancel);

    status.started();
    status.finished(_Outcome.complete);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      equals([
        HydrationState.idle,
        HydrationState.running,
        HydrationState.refreshed,
      ]),
    );
  });

  test('a partial pass reads as refreshed, not failed', () {
    // Every page landed; the set is only not one snapshot, which matters
    // to a purge (#268) and not to a list. Surfacing "couldn't refresh"
    // there would cry wolf on every sign-in for a user with that many
    // households.
    status
      ..started()
      ..finished(_Outcome.partial);

    expect(status.state, equals(HydrationState.refreshed));
  });

  test('a failed pass reads as failed', () {
    status
      ..started()
      ..finished(_Outcome.failed);

    expect(status.state, equals(HydrationState.failed));
  });

  test('a listener subscribing mid-pass sees the result', () async {
    // The install-time drain is unawaited, so a screen can subscribe at
    // any point in it. No gap between the replayed value and the live
    // stream.
    status.started();
    final seen = <HydrationState>[];
    final sub = status.watch().map((h) => h.state).listen(seen.add);
    addTearDown(sub.cancel);

    status.finished(_Outcome.failed);
    await Future<void>.delayed(Duration.zero);

    expect(seen, equals([HydrationState.running, HydrationState.failed]));
  });

  test('updates after close are ignored rather than thrown', () async {
    // The real ordering hazard. The drain is unawaited and the scope pop
    // closes this; a pass still in flight then reports into a closed
    // status. Throwing there is an unhandled async error inside the very
    // code path (#267) that must never throw.
    await status.close();

    expect(() => status.started(), returnsNormally);
    expect(() => status.finished(_Outcome.complete), returnsNormally);
    expect(status.state, equals(HydrationState.idle));
  });

  test('close is idempotent', () async {
    await status.close();
    await expectLater(status.close(), completes);
  });

  group('what a reading carries', () {
    // A screen usually subscribes mid-pass and is replayed only the current
    // reading, so the history it needs has to be in it (#453).
    Future<Hydration> current() => status.watch().first;

    test('a status no pass has touched has established nothing', () async {
      expect(
        await current(),
        const Hydration(
          state: HydrationState.idle,
          everRefreshed: false,
          lastPassFailed: false,
        ),
      );
    });

    test(
      'a new listener is replayed what earlier passes established',
      () async {
        status
          ..started()
          ..finished(_Outcome.complete)
          ..started();

        expect(
          await current(),
          const Hydration(state: HydrationState.running, everRefreshed: true),
        );
      },
    );

    test('a failure is remembered through the next start', () async {
      status
        ..started()
        ..finished(_Outcome.failed)
        ..started();

      expect(
        await current(),
        const Hydration(state: HydrationState.running, lastPassFailed: true),
      );
    });

    test('a failure does not undo a completed pass', () async {
      // A failure confirms nothing, so it leaves everRefreshed where it
      // found it: an answer a success already gave stays an answer.
      status
        ..started()
        ..finished(_Outcome.complete)
        ..started()
        ..finished(_Outcome.failed);

      expect(
        await current(),
        const Hydration(
          state: HydrationState.failed,
          everRefreshed: true,
          lastPassFailed: true,
        ),
      );
    });

    test(
      'a completed pass clears the failure and keeps everRefreshed',
      () async {
        status
          ..started()
          ..finished(_Outcome.complete)
          ..started()
          ..finished(_Outcome.failed)
          ..started()
          ..finished(_Outcome.partial);

        expect(
          await current(),
          const Hydration(state: HydrationState.refreshed, everRefreshed: true),
        );
      },
    );

    test(
      'a pass invalidated mid-flight still reads refreshed, but stale',
      () async {
        // It landed rows, so what it read is an answer. The change that
        // invalidated the set may have reached the server after the pass
        // read from it, so the answer is not current: no stamp, and another
        // pass is wanted.
        status
          ..started()
          ..markStale()
          ..finished(_Outcome.complete);

        expect(
          await current(),
          const Hydration(
            state: HydrationState.refreshed,
            everRefreshed: true,
            lastPassFailed: false,
          ),
        );
        expect(status.isStaleAfter(const Duration(minutes: 5)), isTrue);
      },
    );

    test('started resets markStale, so a drain started after it stamps', () {
      status
        ..started()
        ..markStale()
        ..finished(_Outcome.complete)
        ..started()
        ..finished(_Outcome.complete);

      expect(status.isStaleAfter(const Duration(minutes: 5)), isFalse);
    });
  });

  group('the staleness clock (#300)', () {
    // A local injected `now`, not ClockService: a staleness window is
    // elapsed time on this device and has no consensus meaning, which is
    // what ClockService's own doc scopes itself to.
    late DateTime clock;
    late HydrationStatus<_Outcome> stamped;

    setUp(() {
      clock = DateTime.utc(2026, 8, 27, 12);
      stamped = HydrationStatus<_Outcome>(landed: _landed, now: () => clock);
    });
    tearDown(() async => stamped.close());

    void advance(Duration by) => clock = clock.add(by);

    test('a status that has never refreshed has no age', () {
      expect(stamped.sinceRefresh, isNull);
    });

    test('a successful pass stamps when it landed', () {
      stamped
        ..started()
        ..finished(_Outcome.complete);

      expect(stamped.sinceRefresh, equals(Duration.zero));

      advance(const Duration(minutes: 7));
      expect(stamped.sinceRefresh, equals(const Duration(minutes: 7)));
    });

    test('a partial pass stamps, like the state it reports', () {
      // It reads as refreshed because the cache is more current than it
      // was. The window has to agree, or a user with more than one page of
      // households re-drains on every entry forever.
      stamped
        ..started()
        ..finished(_Outcome.partial);

      expect(stamped.sinceRefresh, equals(Duration.zero));
    });

    test('a failed pass leaves the clock alone', () {
      stamped
        ..started()
        ..finished(_Outcome.failed);

      // Not "stale as of now" — never refreshed at all. `failed` is
      // already stale by state, and stamping here would make a failure
      // look like a success that has yet to age out.
      expect(stamped.sinceRefresh, isNull);
    });

    test('a failure after a success leaves the earlier stamp alone', () {
      // The rows on screen are still the ones that success landed, so that
      // is genuinely how old they are. A failure lands nothing, so it has
      // nothing to date -- and clearing the stamp would be #300's mistake
      // applied to the clock: letting a failure un-know what a success
      // established. `failed` is stale by state instead, which is what
      // every caller reads first.
      stamped
        ..started()
        ..finished(_Outcome.complete);
      advance(const Duration(minutes: 2));

      stamped
        ..started()
        ..finished(_Outcome.failed);

      expect(stamped.sinceRefresh, equals(const Duration(minutes: 2)));
    });

    test('a second successful pass re-stamps', () {
      stamped
        ..started()
        ..finished(_Outcome.complete);
      advance(const Duration(minutes: 9));

      stamped
        ..started()
        ..finished(_Outcome.complete);

      expect(stamped.sinceRefresh, equals(Duration.zero));
    });

    test('markStale drops the timestamp (#300)', () {
      stamped
        ..started()
        ..finished(_Outcome.complete);

      stamped.markStale();

      // The state is untouched — the rows on screen are still the rows we
      // have. Only the claim that they are current goes away.
      expect(stamped.state, equals(HydrationState.refreshed));
      expect(stamped.sinceRefresh, isNull);
    });

    test('a pass already running when markStale lands does not re-stamp', () {
      // The create that invalidated the set may well have reached the
      // server after this pass read from it, so its result cannot be
      // treated as current. Otherwise a create racing the install-time
      // drain would be papered over for the whole window.
      stamped.started();
      stamped.markStale();
      stamped.finished(_Outcome.complete);

      expect(stamped.sinceRefresh, isNull);
    });

    test('a pass started after markStale stamps normally', () {
      stamped
        ..started()
        ..finished(_Outcome.complete);
      stamped.markStale();

      stamped
        ..started()
        ..finished(_Outcome.complete);

      expect(stamped.sinceRefresh, equals(Duration.zero));
    });

    test('markStale after close is ignored rather than thrown', () async {
      await stamped.close();

      expect(stamped.markStale, returnsNormally);
    });

    test('a pass finishing after close stamps nothing', () async {
      stamped.started();
      await stamped.close();

      stamped.finished(_Outcome.complete);

      expect(stamped.sinceRefresh, isNull);
    });

    group('isStaleAfter', () {
      const window = Duration(minutes: 5);

      test('a status that has never refreshed is stale at any window', () {
        expect(stamped.isStaleAfter(window), isTrue);
        expect(stamped.isStaleAfter(const Duration(days: 1)), isTrue);
      });

      test('a pass that just landed is not stale', () {
        stamped
          ..started()
          ..finished(_Outcome.complete);

        expect(stamped.isStaleAfter(window), isFalse);
      });

      test('a minute short of the window is not stale', () {
        stamped
          ..started()
          ..finished(_Outcome.complete);
        advance(const Duration(minutes: 4));

        expect(stamped.isStaleAfter(window), isFalse);
      });

      test('exactly at the window is stale', () {
        stamped
          ..started()
          ..finished(_Outcome.complete);
        advance(window);

        // Inclusive: at exactly the window the answer is already that many
        // minutes old.
        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('a failed pass is stale however recently it ran', () {
        stamped
          ..started()
          ..finished(_Outcome.failed);

        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('reports a young age even when the last pass failed', () {
        // Deliberate, and the reason this method's doc says it answers
        // about age and nothing else. A failure inside the window leaves a
        // young stamp; what makes it stale is [state], and the installer's
        // registry entry reads that first.
        stamped
          ..started()
          ..finished(_Outcome.complete);
        advance(const Duration(minutes: 1));
        stamped
          ..started()
          ..finished(_Outcome.failed);

        expect(stamped.state, equals(HydrationState.failed));
        expect(stamped.isStaleAfter(window), isFalse);
      });

      test('markStale is stale immediately (#300)', () {
        stamped
          ..started()
          ..finished(_Outcome.complete);

        stamped.markStale();

        // A create does not wait out the remaining minutes.
        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('answers about the last pass while another one runs', () {
        // Deliberately says nothing about `running`. What a pass in flight
        // means is the caller's policy -- the installer's registry entry
        // skips it (#302) before ever asking about age.
        stamped
          ..started()
          ..finished(_Outcome.complete);
        advance(const Duration(minutes: 6));
        stamped.started();

        expect(stamped.state, equals(HydrationState.running));
        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('a clock set back since the stamp is stale', () {
        // The age is unknown, not small (#453). Read as fresh, it would let
        // every trigger skip the pass until the clock caught up.
        stamped
          ..started()
          ..finished(_Outcome.complete);
        advance(const Duration(minutes: -1));

        expect(stamped.isStaleAfter(const Duration(minutes: 5)), isTrue);
      });
    });
  });
}
