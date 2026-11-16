import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:sync_queue/sync_queue.dart';

import '../support/streaming_queue.dart';

SyncQueueEntry _entry(String id, String payload) =>
    SyncQueueEntry(id: id, payload: payload, createdAt: DateTime(2026));

final SyncQueueEntry _add = _entry(
  'q1',
  const AddToCollectionOperation(
    localId: 'local-1',
    platformGameId: 'p1',
    medium: 'physical',
    quantity: 1,
  ).serialized,
);
final SyncQueueEntry _update = _entry(
  'q2',
  const UpdateCollectionOperation(collectionId: 'c-2', quantity: 2).serialized,
);
final SyncQueueEntry _undecodable = _entry(
  'q3',
  '{"type":"from_the_future","local_id":"x-3"}',
);
final SyncQueueEntry _unreadable = _entry('q4', 'not json');

void main() {
  late StreamingQueue queue;

  setUp(() => queue = StreamingQueue());
  tearDown(() => queue.dispose());

  SyncStatusCubit build() => SyncStatusCubit(queue: queue);

  test('starts with neither half read', () async {
    final cubit = build();
    addTearDown(cubit.close);
    expect(cubit.state, const SessionSyncStatus());
    expect(cubit.state.waiting, isNull);
    expect(cubit.state.stuck, isNull);
  });

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'maps the pending count to waiting, with stuck still unread',
    build: build,
    act: (_) => queue.pending.add(3),
    expect: () => [const SessionSyncStatus(waiting: 3)],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'maps stuck entries to a count and their record ids, with waiting still '
    'unread',
    build: build,
    act: (_) => queue.stuck.add([_add, _update]),
    // The pending count hasn't arrived, and the stuck records show anyway:
    // a row needn't say waiting for a change that won't send on its own.
    expect: () => [
      const SessionSyncStatus(stuck: 2, stuckRecordIds: {'local-1', 'c-2'}),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'holds both halves once both streams have delivered',
    build: build,
    act: (_) async {
      queue.pending.add(3);
      await pumpEventQueue();
      queue.stuck.add([_add]);
    },
    expect: () => [
      const SessionSyncStatus(waiting: 3),
      const SessionSyncStatus(
        waiting: 3,
        stuck: 1,
        stuckRecordIds: {'local-1'},
      ),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'counts an undecodable stuck entry and reads its id from the payload',
    build: build,
    act: (_) => queue.stuck.add([_undecodable]),
    expect: () => [
      const SessionSyncStatus(stuck: 1, stuckRecordIds: {'x-3'}),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'counts a stuck entry with no readable id without naming a record',
    build: build,
    act: (_) => queue.stuck.add([_unreadable]),
    expect: () => [const SessionSyncStatus(stuck: 1)],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'a pending-count error unreads waiting, and keeps the stuck records',
    build: build,
    act: (_) async {
      queue.pending.add(2);
      await pumpEventQueue();
      queue.stuck.add([_add]);
      await pumpEventQueue();
      queue.pending.addError(StateError('read failed'));
    },
    expect: () => [
      const SessionSyncStatus(waiting: 2),
      const SessionSyncStatus(
        waiting: 2,
        stuck: 1,
        stuckRecordIds: {'local-1'},
      ),
      const SessionSyncStatus(stuck: 1, stuckRecordIds: {'local-1'}),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'a stuck-entries error unreads stuck and its records, and keeps waiting',
    build: build,
    act: (_) async {
      queue.pending.add(1);
      await pumpEventQueue();
      queue.stuck.add([_add]);
      await pumpEventQueue();
      queue.stuck.addError(StateError('read failed'));
    },
    expect: () => [
      const SessionSyncStatus(waiting: 1),
      const SessionSyncStatus(
        waiting: 1,
        stuck: 1,
        stuckRecordIds: {'local-1'},
      ),
      const SessionSyncStatus(waiting: 1),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'a pending count after its error reads waiting again',
    build: build,
    act: (_) async {
      queue.pending.add(1);
      await pumpEventQueue();
      queue.stuck.add(const []);
      await pumpEventQueue();
      queue.pending.addError(StateError('read failed'));
      await pumpEventQueue();
      queue.pending.add(1);
    },
    expect: () => [
      const SessionSyncStatus(waiting: 1),
      const SessionSyncStatus(waiting: 1, stuck: 0),
      const SessionSyncStatus(stuck: 0),
      const SessionSyncStatus(waiting: 1, stuck: 0),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'stuck entries after their error read stuck again',
    build: build,
    act: (_) async {
      queue.pending.add(1);
      await pumpEventQueue();
      queue.stuck.add(const []);
      await pumpEventQueue();
      queue.stuck.addError(StateError('read failed'));
      await pumpEventQueue();
      queue.stuck.add(const []);
    },
    expect: () => [
      const SessionSyncStatus(waiting: 1),
      const SessionSyncStatus(waiting: 1, stuck: 0),
      const SessionSyncStatus(waiting: 1),
      const SessionSyncStatus(waiting: 1, stuck: 0),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'a stream that fails before its first value leaves its half unread',
    build: build,
    act: (_) async {
      queue.pending.addError(StateError('read failed'));
      await pumpEventQueue();
      queue.stuck.add(const []);
    },
    expect: () => [const SessionSyncStatus(stuck: 0)],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'a first read of nothing outstanding reads zero for both',
    build: build,
    act: (_) async {
      queue.pending.add(0);
      await pumpEventQueue();
      queue.stuck.add(const []);
      await pumpEventQueue();
    },
    // A zero read is news: before it, nobody knew.
    expect: () => [
      const SessionSyncStatus(waiting: 0),
      const SessionSyncStatus(waiting: 0, stuck: 0),
    ],
  );

  blocTest<SyncStatusCubit, SessionSyncStatus>(
    'does not emit an equal state',
    build: build,
    act: (_) async {
      queue.pending.add(2);
      await pumpEventQueue();
      queue.pending.add(2);
      await pumpEventQueue();
      queue.stuck.add(const []);
      await pumpEventQueue();
      queue.stuck.add(const []);
      await pumpEventQueue();
      queue.pending.add(2);
    },
    expect: () => [
      const SessionSyncStatus(waiting: 2),
      const SessionSyncStatus(waiting: 2, stuck: 0),
    ],
  );

  test('closes quietly when both streams end', () async {
    final cubit = build();
    await queue.pending.close();
    await queue.stuck.close();
    await pumpEventQueue();
    expect(cubit.state, const SessionSyncStatus());
    await cubit.close();
    expect(cubit.isClosed, isTrue);
  });

  test('ignores a late event after close', () async {
    final cubit = build();
    await cubit.close();
    expect(() {
      queue.pending.add(5);
      queue.stuck.add([_add]);
    }, returnsNormally);
    await pumpEventQueue();
    expect(cubit.state, const SessionSyncStatus());
  });
}
