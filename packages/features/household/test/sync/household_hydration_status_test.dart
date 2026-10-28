import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';

// The state machine, the clock and the replay are `HydrationStatus`'s, and
// tested with it. What is the household's is which outcomes land.
void main() {
  late HouseholdHydrationStatus status;

  setUp(() => status = HouseholdHydrationStatus());
  tearDown(() async => status.close());

  test('a drained pass lands as refreshed, not failed', () {
    // Every page landed; the set is only not one snapshot, which matters
    // to a purge (#268) and not to a list. Surfacing "couldn't refresh"
    // there would cry wolf on every sign-in for a user with that many
    // households.
    status
      ..started()
      ..finished(HydrateOutcome.drained);

    expect(status.state, equals(HydrationState.refreshed));
  });

  test('a failed pass lands as failed', () {
    status
      ..started()
      ..finished(HydrateOutcome.failed);

    expect(status.state, equals(HydrationState.failed));
  });
}
