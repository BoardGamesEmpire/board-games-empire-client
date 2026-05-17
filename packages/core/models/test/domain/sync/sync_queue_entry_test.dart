import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('SyncQueueEntry', () {
    final createdAt = DateTime.parse('2024-01-15T10:30:00Z');

    test('defaults are correct', () {
      final entry = SyncQueueEntry(
        id: 'entry_1',
        payload: '{"type":"add_to_collection"}',
        createdAt: createdAt,
      );

      expect(entry.status, equals(SyncStatus.pending));
      expect(entry.retryCount, equals(0));
      expect(entry.lastError, isNull);
      expect(entry.lastAttemptAt, isNull);
    });

    group('lifecycle helpers', () {
      test('isPending true only when status is pending', () {
        final pending = SyncQueueEntry(
          id: 'e',
          payload: '{}',
          createdAt: createdAt,
        );
        expect(pending.isPending, isTrue);
        expect(
          pending.copyWith(status: SyncStatus.inProgress).isPending,
          isFalse,
        );
      });

      test('isExhausted true at maxRetries', () {
        final entry = SyncQueueEntry(
          id: 'e',
          payload: '{}',
          createdAt: createdAt,
        );
        expect(entry.isExhausted, isFalse);
        expect(
          entry.copyWith(retryCount: SyncQueueEntry.maxRetries).isExhausted,
          isTrue,
        );
      });

      test('canRetry true only when failed and not exhausted', () {
        final base = SyncQueueEntry(
          id: 'e',
          payload: '{}',
          createdAt: createdAt,
        );
        expect(
          base.canRetry,
          isFalse,
          reason: 'pending entries are not retried via canRetry',
        );
        expect(
          base.copyWith(status: SyncStatus.failed, retryCount: 2).canRetry,
          isTrue,
        );
        expect(
          base
              .copyWith(
                status: SyncStatus.failed,
                retryCount: SyncQueueEntry.maxRetries,
              )
              .canRetry,
          isFalse,
        );
      });
    });

    test('operation deserializes the embedded payload', () {
      const add = AddToCollectionOperation(
        localId: 'col_1',
        platformGameId: 'pg_1',
        medium: 'Physical',
        quantity: 2,
        rating: 9,
      );
      final entry = SyncQueueEntry(
        id: 'entry_1',
        payload: add.serialized,
        createdAt: createdAt,
      );

      final op = entry.operation;
      expect(op, isA<AddToCollectionOperation>());
      final typed = op as AddToCollectionOperation;
      expect(typed.localId, equals('col_1'));
      expect(typed.platformGameId, equals('pg_1'));
      expect(typed.medium, equals('Physical'));
      expect(typed.quantity, equals(2));
      expect(typed.rating, equals(9));
    });

    test('round-trips through JSON preserving status and retryCount', () {
      final entry = SyncQueueEntry(
        id: 'entry_1',
        payload: '{"type":"remove_from_collection","collection_id":"col_1"}',
        status: SyncStatus.failed,
        retryCount: 3,
        lastError: 'network unreachable',
        createdAt: createdAt,
        lastAttemptAt: createdAt,
      );

      final round = SyncQueueEntry.fromJson(entry.toJson());
      expect(round, equals(entry));
    });
  });
}
