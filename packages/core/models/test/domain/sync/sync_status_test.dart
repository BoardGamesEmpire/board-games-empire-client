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
      // Strict / no-legacy: pre-production this codebase has no
      // released clients yet, so no v1-state databases exist out
      // there and the storage layer doesn't accept the legacy
      // snake_case 'in_progress' as an alias for 'inProgress'. The
      // canonical wire form is the Dart enum `name`. This test
      // pins that one direction (Dart → wire); the parse-side
      // strictness is locked in by
      // `sync_queue_repository_impl_test.dart`'s `_parseStatus`
      // tests, which assert that 'in_progress' throws StateError
      // rather than being silently coerced.
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
