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
}
