import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';

// The state machine, the clock and the replay are `HydrationStatus`'s, and
// tested with it. What is the collection's is which outcomes land.
void main() {
  late GameCollectionHydrationStatus status;

  setUp(() => status = GameCollectionHydrationStatus());
  tearDown(() async => status.close());

  test('a complete pass lands as refreshed', () {
    status
      ..started()
      ..finished(CollectionHydrateOutcome.complete);

    expect(status.state, equals(HydrationState.refreshed));
  });

  test('a failed pass lands as failed', () {
    status
      ..started()
      ..finished(CollectionHydrateOutcome.failed);

    expect(status.state, equals(HydrationState.failed));
  });
}
