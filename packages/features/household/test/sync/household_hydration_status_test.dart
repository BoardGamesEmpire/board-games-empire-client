import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';

void main() {
  late HouseholdHydrationStatus status;

  setUp(() => status = HouseholdHydrationStatus());
  tearDown(() async => status.close());

  test('starts idle', () {
    // Idle is also what an ABSENT status means to the list screen (#269
    // D1): a container with no hydrator must render the empty state, not
    // spin forever.
    expect(status.state, equals(HouseholdHydrationState.idle));
  });

  test('a new listener is given the current state before any change', () async {
    status.started();

    await expectLater(
      status.watch().take(1),
      emits(HouseholdHydrationState.running),
    );
  });

  test('reports a pass in flight, then its result', () async {
    final seen = <HouseholdHydrationState>[];
    final sub = status.watch().listen(seen.add);
    addTearDown(sub.cancel);

    status.started();
    status.finished(HydrateOutcome.complete);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      equals([
        HouseholdHydrationState.idle,
        HouseholdHydrationState.running,
        HouseholdHydrationState.refreshed,
      ]),
    );
  });

  test('an admin-scoped pass reads as refreshed, not failed', () {
    // #269 D2. The set is incomplete, not broken: page 1 landed and the
    // cache is more current than it was. Surfacing "couldn't refresh"
    // there would cry wolf on every admin sign-in.
    status
      ..started()
      ..finished(HydrateOutcome.adminScoped);

    expect(status.state, equals(HouseholdHydrationState.refreshed));
  });

  test('a failed pass reads as failed', () {
    status
      ..started()
      ..finished(HydrateOutcome.failed);

    expect(status.state, equals(HouseholdHydrationState.failed));
  });

  test('a listener subscribing mid-pass sees the result', () async {
    // The install-time drain is unawaited, so a screen can subscribe at
    // any point in it. No gap between the replayed value and the live
    // stream.
    status.started();
    final seen = <HouseholdHydrationState>[];
    final sub = status.watch().listen(seen.add);
    addTearDown(sub.cancel);

    status.finished(HydrateOutcome.failed);
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      equals([HouseholdHydrationState.running, HouseholdHydrationState.failed]),
    );
  });

  test('updates after close are ignored rather than thrown', () async {
    // The real ordering hazard. The drain is unawaited and the scope pop
    // closes this; a pass still in flight then reports into a closed
    // status. Throwing there is an unhandled async error inside the very
    // code path (#267) that must never throw.
    await status.close();

    expect(() => status.started(), returnsNormally);
    expect(() => status.finished(HydrateOutcome.complete), returnsNormally);
    expect(status.state, equals(HouseholdHydrationState.idle));
  });

  test('close is idempotent', () async {
    await status.close();
    await expectLater(status.close(), completes);
  });

  group('the staleness clock (#300 D8)', () {
    // A local injected `now`, not ClockService: a staleness window is
    // elapsed time on this device and has no consensus meaning, which is
    // what ClockService's own doc scopes itself to.
    late DateTime clock;
    late HouseholdHydrationStatus stamped;

    setUp(() {
      clock = DateTime.utc(2026, 8, 27, 12);
      stamped = HouseholdHydrationStatus(now: () => clock);
    });
    tearDown(() async => stamped.close());

    void advance(Duration by) => clock = clock.add(by);

    test('a status that has never refreshed has no age', () {
      expect(stamped.sinceRefresh, isNull);
    });

    test('a successful pass stamps when it landed', () {
      stamped
        ..started()
        ..finished(HydrateOutcome.complete);

      expect(stamped.sinceRefresh, equals(Duration.zero));

      advance(const Duration(minutes: 7));
      expect(stamped.sinceRefresh, equals(const Duration(minutes: 7)));
    });

    test('an admin-scoped pass stamps, like the state it reports', () {
      // It reads as refreshed (#269 D2) because the cache is more current
      // than it was. The window has to agree, or an admin re-drains on
      // every entry forever.
      stamped
        ..started()
        ..finished(HydrateOutcome.adminScoped);

      expect(stamped.sinceRefresh, equals(Duration.zero));
    });

    test('a failed pass leaves the clock alone', () {
      stamped
        ..started()
        ..finished(HydrateOutcome.failed);

      // Not "stale as of now" — never refreshed at all. `failed` is
      // already stale by state, and stamping here would make a failure
      // look like a success that has yet to age out.
      expect(stamped.sinceRefresh, isNull);
    });

    test('a second successful pass re-stamps', () {
      stamped
        ..started()
        ..finished(HydrateOutcome.complete);
      advance(const Duration(minutes: 9));

      stamped
        ..started()
        ..finished(HydrateOutcome.complete);

      expect(stamped.sinceRefresh, equals(Duration.zero));
    });

    test('markStale drops the timestamp (#300 D9)', () {
      stamped
        ..started()
        ..finished(HydrateOutcome.complete);

      stamped.markStale();

      // The state is untouched — the rows on screen are still the rows we
      // have. Only the claim that they are current goes away.
      expect(stamped.state, equals(HouseholdHydrationState.refreshed));
      expect(stamped.sinceRefresh, isNull);
    });

    test('a pass already running when markStale lands does not re-stamp', () {
      // The create that invalidated the set may well have reached the
      // server after this pass read from it, so its result cannot be
      // treated as current. Otherwise a create racing the install-time
      // drain would be papered over for the whole window.
      stamped.started();
      stamped.markStale();
      stamped.finished(HydrateOutcome.complete);

      expect(stamped.sinceRefresh, isNull);
    });

    test('a pass started after markStale stamps normally', () {
      stamped
        ..started()
        ..finished(HydrateOutcome.complete);
      stamped.markStale();

      stamped
        ..started()
        ..finished(HydrateOutcome.complete);

      expect(stamped.sinceRefresh, equals(Duration.zero));
    });

    test('markStale after close is ignored rather than thrown', () async {
      await stamped.close();

      expect(stamped.markStale, returnsNormally);
    });

    test('a pass finishing after close stamps nothing', () async {
      stamped.started();
      await stamped.close();

      stamped.finished(HydrateOutcome.complete);

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
          ..finished(HydrateOutcome.complete);

        expect(stamped.isStaleAfter(window), isFalse);
      });

      test('a minute short of the window is not stale', () {
        stamped
          ..started()
          ..finished(HydrateOutcome.complete);
        advance(const Duration(minutes: 4));

        expect(stamped.isStaleAfter(window), isFalse);
      });

      test('exactly at the window is stale', () {
        stamped
          ..started()
          ..finished(HydrateOutcome.complete);
        advance(window);

        // Inclusive: at exactly the window the answer is already that many
        // minutes old.
        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('a failed pass is stale however recently it ran', () {
        stamped
          ..started()
          ..finished(HydrateOutcome.failed);

        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('markStale is stale immediately (#300 D9)', () {
        stamped
          ..started()
          ..finished(HydrateOutcome.complete);

        stamped.markStale();

        // A create does not wait out the remaining minutes.
        expect(stamped.isStaleAfter(window), isTrue);
      });

      test('answers about the last pass while another one runs', () {
        // Deliberately says nothing about `running`. What a pass in flight
        // means is the caller's policy -- the installer's registry entry
        // skips it (#302 D4) before ever asking about age.
        stamped
          ..started()
          ..finished(HydrateOutcome.complete);
        advance(const Duration(minutes: 6));
        stamped.started();

        expect(stamped.state, equals(HouseholdHydrationState.running));
        expect(stamped.isStaleAfter(window), isTrue);
      });
    });
  });

  group('HouseholdHydrationMemory (#300 D16)', () {
    late HouseholdHydrationMemory memory;

    setUp(() => memory = HouseholdHydrationMemory());

    test('starts idle, with nothing confirmed', () {
      expect(memory.state, equals(HouseholdHydrationState.idle));
      expect(memory.everRefreshed, isFalse);
    });

    test('remembers the latest state', () {
      memory.absorb(HouseholdHydrationState.running);

      expect(memory.state, equals(HouseholdHydrationState.running));
    });

    test('a refreshed pass confirms, permanently', () {
      memory
        ..absorb(HouseholdHydrationState.running)
        ..absorb(HouseholdHydrationState.refreshed);

      expect(memory.everRefreshed, isTrue);
    });

    test('a later failure does not un-know a confirmed answer', () {
      memory
        ..absorb(HouseholdHydrationState.refreshed)
        ..absorb(HouseholdHydrationState.running)
        ..absorb(HouseholdHydrationState.failed);

      expect(memory.state, equals(HouseholdHydrationState.failed));
      expect(memory.everRefreshed, isTrue);
    });

    test('a failed pass confirms nothing', () {
      // Not "ever settled". A failure leaves an empty cache as unknown as
      // it found it, which is what keeps #269 D1's spinner over a
      // failed-then-retried first pass (#300 D12).
      memory
        ..absorb(HouseholdHydrationState.running)
        ..absorb(HouseholdHydrationState.failed);

      expect(memory.everRefreshed, isFalse);
    });
  });
}
