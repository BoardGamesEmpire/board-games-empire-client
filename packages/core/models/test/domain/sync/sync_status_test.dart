import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

SyncQueueEntry _entry({required SyncStatus status}) => SyncQueueEntry(
  id: 'entry_1',
  payload:
      '{"type":"add_to_collection","local_id":"col_1",'
      '"platform_game_id":"pg_1","medium":"Physical","quantity":1}',
  status: status,
  createdAt: DateTime.parse('2024-01-15T10:30:00Z'),
);

void main() {
  group('SyncStatus', () {
    test('every Dart value round-trips through SyncQueueEntry', () {
      for (final value in SyncStatus.values) {
        final entry = _entry(status: value);
        final round = SyncQueueEntry.fromJson(entry.toJson());
        expect(round.status, equals(value));
      }
    });

    test('wire format uses Dart enum names (client-only enum)', () {
      const expectations = <SyncStatus, String>{
        SyncStatus.pending: 'pending',
        SyncStatus.inProgress: 'inProgress',
        SyncStatus.failed: 'failed',
        SyncStatus.completed: 'completed',
      };

      for (final entry in expectations.entries) {
        expect(
          _entry(status: entry.key).toJson()['status'],
          equals(entry.value),
          reason:
              'SyncStatus.${entry.key.name} should serialize as "${entry.value}"',
        );
      }
    });

    test('SyncStatus.inProgress wire form is camelCase, not snake_case', () {
      // Pre-schema-v2 storage used 'in_progress'. The new contract is
      // the Dart enum name. Storage migration handled in Pass 2.
      expect(
        _entry(status: SyncStatus.inProgress).toJson()['status'],
        equals('inProgress'),
      );
      expect(
        _entry(status: SyncStatus.inProgress).toJson()['status'],
        isNot(equals('in_progress')),
      );
    });
  });
}
