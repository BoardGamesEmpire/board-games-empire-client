import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';

// The state machine, the clock and the replay are `HydrationStatus`'s, and
// tested with it. What is the events' is which outcomes land.
void main() {
  late EventHydrationStatus status;

  setUp(() => status = EventHydrationStatus());
  tearDown(() async => status.close());

  test('a complete pass lands as refreshed', () {
    status
      ..started()
      ..finished(EventHydrateOutcome.complete);

    expect(status.state, equals(HydrationState.refreshed));
  });

  test('a windowed pass lands as refreshed, not failed', () {
    // Every page landed; the pass only could not vouch for an absence beyond
    // its window, which matters to a purge and not to a list. A failure
    // banner there would sit over rows that are current.
    status
      ..started()
      ..finished(EventHydrateOutcome.windowed);

    expect(status.state, equals(HydrationState.refreshed));
  });

  test('a drained pass lands as refreshed, not failed', () {
    status
      ..started()
      ..finished(EventHydrateOutcome.drained);

    expect(status.state, equals(HydrationState.refreshed));
  });

  test('a failed pass lands as failed', () {
    status
      ..started()
      ..finished(EventHydrateOutcome.failed);

    expect(status.state, equals(HydrationState.failed));
  });
}
