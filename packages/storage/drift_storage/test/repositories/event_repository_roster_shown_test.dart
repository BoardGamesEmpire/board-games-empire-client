import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/event_fixture.dart';
import '../support/fixed_clock.dart';

// The roster a detail read showed (#567): a cached roster is served to a user
// it names, and to one whose own detail read the server showed it to.

const _kA = 'user-a';
const _kB = 'user-b';
const _kG = 'user-g';
const _kH = 'user-h';
const _kJ = 'user-j';

final _clock = FixedClockService(DateTime.utc(2026, 10, 26, 12));

void main() {
  late ServerDatabase db;

  EventRepositoryImpl repoFor(String userId) => EventRepositoryImpl(
    db,
    userId: userId,
    syncQueue: SyncQueueRepositoryImpl(db, _clock, userId: userId),
    clock: _clock,
  );

  setUp(() => db = inMemoryServerDatabase());
  tearDown(() => db.close());

  List<EventAttendee> roster(List<String> users) => [
    for (final (i, u) in users.indexed)
      testAttendee(
        'att-$u',
        userId: u,
        createdAt: kFixtureEventInstant.add(Duration(minutes: i)),
      ),
  ];

  Future<void> read(EventRepositoryImpl repo, List<EventAttendee>? attendees) =>
      repo.cacheEvent(
        testSnapshot('e-1', attendees: attendees),
        source: EventAccessSource.read,
      );

  List<String?> users(EventSnapshot? s) => [
    for (final a in s!.attendees!) a.userId,
  ];

  test(
    'a user shown the roster reads it though it doesn\'t name them',
    () async {
      await read(repoFor(_kA), roster([_kA, _kH]));
      final b = repoFor(_kB);
      await read(b, roster([_kA, _kH]));

      expect(users(await b.getEvent('e-1')), [_kA, _kH]);
    },
  );

  test('a user never shown it reads it empty', () async {
    await read(repoFor(_kA), roster([_kA, _kH]));
    final g = repoFor(_kG);
    await g.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.household,
    );

    expect((await g.getEvent('e-1'))!.attendees, isEmpty);
  });

  test('an empty roster on a later read clears it', () async {
    final a = repoFor(_kA);
    final b = repoFor(_kB);
    await read(a, roster([_kA, _kH]));
    await read(b, roster([_kA, _kH]));
    await read(b, const []);

    expect((await b.getEvent('e-1'))!.attendees, isEmpty);
    expect(users(await a.getEvent('e-1')), [_kA, _kH]);
  });

  test('the flag survives another user\'s newer roster', () async {
    final a = repoFor(_kA);
    final b = repoFor(_kB);
    await read(a, roster([_kA, _kH]));
    await read(b, roster([_kA, _kH]));
    await read(a, roster([_kA, _kH, _kJ]));

    expect(users(await b.getEvent('e-1')), [_kA, _kH, _kJ]);
  });

  test('the flag is this user\'s alone', () async {
    await read(repoFor(_kA), roster([_kA, _kH]));
    await read(repoFor(_kB), roster([_kA, _kH]));
    final g = repoFor(_kG);
    await read(g, const []);

    expect((await g.getEvent('e-1'))!.attendees, isEmpty);
  });

  test('watchEvent re-emits when the flag clears', () async {
    await read(repoFor(_kA), roster([_kA, _kH]));
    final b = repoFor(_kB);
    await read(b, roster([_kA, _kH]));

    final details = <EventDetail?>[];
    final sub = b.watchEvent('e-1').listen(details.add);
    await pumpEventQueue();
    expect(details.last!.snapshot.attendees, hasLength(2));

    await read(b, const []);
    await pumpEventQueue();
    expect(details.last!.snapshot.attendees, isEmpty);
    await sub.cancel();
  });

  test('no roster cached is still null', () async {
    final b = repoFor(_kB);
    await read(b, const []);

    expect((await b.getEvent('e-1'))!.attendees, isNull);
  });

  test('forgetting the event drops the flag with the row', () async {
    await read(repoFor(_kA), roster([_kA, _kH]));
    final b = repoFor(_kB);
    await read(b, roster([_kA, _kH]));
    final event = await db.select(db.eventsTable).getSingle();

    expect(await b.forgetEvent('e-1', lastWrite: event.generation), isTrue);
    expect(await b.getEvent('e-1'), isNull);
  });

  test('a user purged from attendance reads it empty, another still reads '
      'it', () async {
    final a = repoFor(_kA);
    final b = repoFor(_kB);
    await read(a, roster([_kA, _kH]));
    await read(b, roster([_kA, _kH]));
    await b.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );
    expect(users(await b.getEvent('e-1')), [_kA, _kH]);

    final purged = await b.purgeAttendanceAbsentFrom(
      const {},
      purgeable: await b.purgeableAttendance(),
    );

    expect(purged, {'e-1'});
    expect((await b.getEvent('e-1'))!.attendees, isEmpty);
    expect(users(await a.getEvent('e-1')), [_kA, _kH]);
  });

  test('the household purge leaves the flag alone', () async {
    final a = repoFor(_kA);
    final b = repoFor(_kB);
    await read(a, roster([_kA, _kH]));
    await read(b, roster([_kA, _kH]));
    await b.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.household,
    );

    final purged = await b.purgeHouseholdEventsAbsentFrom(
      'household-1',
      const {},
      purgeable: await b.purgeableHouseholdEvents('household-1'),
    );

    expect(purged, {'e-1'});
    expect(users(await b.getEvent('e-1')), [_kA, _kH]);
  });

  test(
    'only a detail read touches the flag, not a list with no roster',
    () async {
      final a = repoFor(_kA);
      final b = repoFor(_kB);
      await read(a, roster([_kA, _kH]));
      await read(b, roster([_kA, _kH]));

      for (final source in [
        EventAccessSource.household,
        EventAccessSource.attending,
      ]) {
        await b.cacheEvent(
          testSnapshot('e-1', attendees: const []),
          source: source,
        );
        expect(users(await b.getEvent('e-1')), [_kA, _kH], reason: '$source');
      }
    },
  );
}
