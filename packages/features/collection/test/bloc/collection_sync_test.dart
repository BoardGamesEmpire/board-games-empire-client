import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/sync.dart';

void main() {
  group('CollectionSync.of', () {
    test('a delivered send is synced', () {
      expect(CollectionSync.of(const SyncDelivered()), CollectionSync.synced);
    });

    test('a parked send is refused', () {
      expect(
        CollectionSync.of(const SyncParked('400')),
        CollectionSync.refused,
      );
    });

    test('a send that was not claimed or failed stays queued', () {
      expect(CollectionSync.of(const SyncNotClaimed()), CollectionSync.queued);
      expect(
        CollectionSync.of(const SyncFailed(SyncFailure.unreachable, 'offline')),
        CollectionSync.queued,
      );
    });
  });
}
