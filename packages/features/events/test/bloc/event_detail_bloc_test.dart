import 'dart:async';

import 'package:di/di.dart' show LocalClockService;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

class _MockBgeLogger extends Mock implements BgeLogger {}

Household _household(String id, String name) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// Event `e-1` as a detail read returns it.
EventSnapshot _snapshot({
  String title = 'Game night',
  String? householdId,
  bool isLocalOnly = false,
}) => EventSnapshot(
  event: item(
    'e-1',
    title: title,
    householdId: householdId,
  ).event.copyWith(isLocalOnly: isLocalOnly),
  occurrences: const [],
  attendees: const [],
);

/// Event `e-1` as the cache holds it.
EventDetail _detail({EventSnapshot? snapshot, EventAttendee? attendance}) =>
    EventDetail(snapshot: snapshot ?? _snapshot(), attendance: attendance);

/// The current user's own row on the roster, holding [role].
EventAttendee _attending(EventRole role) =>
    attendance(EventParticipationStatus.attending).copyWith(role: role);

/// The detail screen's state (#498): the cached event, read from the server
/// once per open and written back, with a 404 turned into not-found by
/// forgetting the event, and the household's name and the viewer's actions
/// added.
void main() {
  late _MockEventRepository repository;
  late StreamController<EventDetail?> cache;

  setUpAll(() {
    registerFallbackValue(_snapshot());
    registerFallbackValue(EventAccessSource.read);
  });

  setUp(() {
    repository = _MockEventRepository();
    cache = StreamController<EventDetail?>();
    when(() => repository.watchEvent('e-1')).thenAnswer((_) => cache.stream);
    when(() => repository.cacheEvent(any(), source: any(named: 'source')))
        .thenAnswer((_) async {});
    when(() => repository.lastWrite(any())).thenAnswer((_) async => 7);
    when(
      () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
    ).thenAnswer((_) async => true);
  });

  tearDown(() {
    // Not awaited, for the overview test's reason: closing a controller
    // nobody listened to would never complete.
    unawaited(cache.close());
  });

  EventDetailBloc build({
    EventRemoteDataSource? remote,
    Future<bool> Function()? confirmSession,
    Stream<List<Household>>? households,
    Future<HouseholdRole?> Function(String householdId)? householdRole,
    BgeLogger? logger,
  }) => EventDetailBloc(
    eventId: 'e-1',
    repository: repository,
    remote: remote,
    confirmSession: confirmSession,
    households: households,
    householdRole: householdRole,
    logger: logger,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// A server whose reads never answer.
  FakeEventRemote unanswered() =>
      FakeEventRemote.detail((_) => Completer<EventSnapshot>().future);

  /// A server whose reads fail with [error].
  FakeEventRemote failing(Exception error) =>
      FakeEventRemote.detail((_) => throw error);

  /// Every state [bloc] emits from now on, so a test can say what passed
  /// between two states as well as where it ended.
  List<EventDetailState> record(EventDetailBloc bloc) {
    final states = <EventDetailState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  Matcher readyWith({
    Object? detail = anything,
    Object? householdName = anything,
    Object? actions = anything,
    Object? refreshing = anything,
    Object? reading = anything,
    Object? refreshFailed = anything,
    Object? canRetry = anything,
  }) => isA<EventDetailReady>()
      .having((s) => s.detail, 'detail', detail)
      .having((s) => s.householdName, 'householdName', householdName)
      .having((s) => s.actions, 'actions', actions)
      .having((s) => s.refreshing, 'refreshing', refreshing)
      .having((s) => s.reading, 'reading', reading)
      .having((s) => s.refreshFailed, 'refreshFailed', refreshFailed)
      .having((s) => s.canRetry, 'canRetry', canRetry);

  Set<EventAction> actionsOf(EventDetailState state) =>
      (state as EventDetailReady).actions;

  test('starts loading, before the cache has said anything', () {
    final bloc = build(remote: unanswered());
    addTearDown(bloc.close);

    expect(bloc.state, const EventDetailLoading());
  });

  group('the read on open', () {
    test('reads the detail once on open and caches it as read', () async {
      final fresh = _snapshot(title: 'Game night, moved');
      final remote = FakeEventRemote.detail((_) => fresh);
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(remote.detailRequests, ['e-1']);
      verify(() => repository.cacheEvent(fresh, source: EventAccessSource.read))
          .called(1);

      // The watch delivers what the read wrote. A second emission is not a
      // second open, so it reads nothing more.
      cache.add(_detail(snapshot: fresh));
      await settle();

      expect(remote.detailRequests, ['e-1']);
      expect(
        bloc.state,
        readyWith(
          detail: _detail(snapshot: fresh),
          refreshFailed: isFalse,
        ),
      );
    });

    test('shows the cache before the read answers', () async {
      final read = Completer<EventSnapshot>();
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      // Nor is it narrated: every open reads, and nobody asked for this one.
      expect(
        bloc.state,
        readyWith(detail: _detail(), refreshFailed: isFalse, refreshing: false),
      );
    });

    test(
      'a failed read with nothing cached is an error, not loading',
      () async {
        // A deep link to an event this device never cached, while offline.
        // Nothing else will answer, so a spinner would never resolve.
        final bloc = build(
          remote: failing(const EventRemoteTransientException('offline')),
        );
        addTearDown(bloc.close);

        cache.add(null);
        await settle();

        expect(bloc.state, const EventDetailError(canRetry: true));
      },
    );

    test('a failed read over a cached event keeps it, flagged', () async {
      final bloc = build(
        remote: failing(const EventRemoteTransientException('offline')),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(
        bloc.state,
        readyWith(detail: _detail(), refreshFailed: isTrue, refreshing: false),
      );
    });

    test('a refused read is a failed read, not a missing event', () async {
      // Only a 404 says the event is gone for this user. A 403 refuses
      // event reads as such, and says nothing about this one.
      final bloc = build(
        remote: failing(const EventRemoteForbiddenException('no read:event')),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(bloc.state, readyWith(refreshFailed: isTrue));
      verifyNever(
        () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
      );
    });

    test('a write that fails after a good read is a failed read', () async {
      final logger = _MockBgeLogger();
      when(() => repository.cacheEvent(any(), source: any(named: 'source')))
          .thenThrow(StateError('database closed'));
      final bloc = build(
        remote: FakeEventRemote.detail((_) => _snapshot()),
        logger: logger,
      );
      addTearDown(bloc.close);

      cache.add(null);
      await settle();

      expect(bloc.state, const EventDetailError(canRetry: true));
      verify(
        () => logger.warn(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1);
    });

    test('a read that lands over nothing cached waits for the write', () async {
      // The read settles before the watch has re-read what it wrote, so
      // the cache still says null for a moment. Not found there would
      // flash on every open of an uncached event.
      final fresh = _snapshot();
      final bloc = build(remote: FakeEventRemote.detail((_) => fresh));
      addTearDown(bloc.close);
      final states = record(bloc);

      cache.add(null);
      await settle();

      verify(() => repository.cacheEvent(fresh, source: EventAccessSource.read))
          .called(1);
      expect(bloc.state, const EventDetailLoading());

      cache.add(_detail(snapshot: fresh));
      await settle();

      expect(bloc.state, readyWith(detail: _detail(snapshot: fresh)));
      expect(states, isNot(contains(isA<EventDetailNotFound>())));
    });

    test('a null after the write is not found', () async {
      // Something removed the access the read had just written.
      final bloc = build(remote: FakeEventRemote.detail((_) => _snapshot()));
      addTearDown(bloc.close);

      cache.add(null);
      await settle();
      cache.add(null);
      await settle();

      expect(bloc.state, const EventDetailNotFound());
    });

    test(
      'closing mid-read adds nothing, and the read is still written',
      () async {
        // An add after close would throw into the test's zone. The write is
        // the server's answer whether or not the screen is still open.
        final read = Completer<EventSnapshot>();
        final bloc = build(remote: FakeEventRemote.detail((_) => read.future));

        cache.add(null);
        await settle();
        await bloc.close();
        read.complete(_snapshot());
        await settle();

        verify(
          () => repository.cacheEvent(any(), source: EventAccessSource.read),
        ).called(1);
      },
    );
  });

  group('a roster the read withholds', () {
    // A friend, a household guest or a public reader reads an empty roster:
    // they may not see who is coming. The cache keeps no rows for it, so
    // over an event with no cached roster it reads the roster back as null.
    List<EventAttendee>? rosterOf(EventDetailState state) =>
        (state as EventDetailReady).detail.snapshot.attendees;

    final unread = _snapshot().copyWith(attendees: null);

    test('shows a null cached roster as withheld', () async {
      final read = Completer<EventSnapshot>();
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));
      addTearDown(bloc.close);

      cache.add(_detail(snapshot: unread));
      await settle();

      // Nothing has said otherwise yet.
      expect(rosterOf(bloc.state), isNull);

      read.complete(_snapshot());
      await settle();
      // The watch reading back what the read wrote.
      cache.add(_detail(snapshot: unread));
      await settle();

      expect(rosterOf(bloc.state), allOf(isNotNull, isEmpty));
      // The attendance stays the cache's.
      expect(bloc.state, readyWith(detail: _detail()));
    });

    test('a cached roster wins, and a read with one ends it', () async {
      final reads = <Completer<EventSnapshot>>[];
      final bloc = build(
        remote: FakeEventRemote.detail((_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        }),
      );
      addTearDown(bloc.close);
      final roster = [attendance(EventParticipationStatus.attending)];

      cache.add(_detail(snapshot: unread));
      await settle();
      reads.single.complete(_snapshot());
      await settle();
      expect(rosterOf(bloc.state), allOf(isNotNull, isEmpty));

      cache.add(_detail(snapshot: _snapshot().copyWith(attendees: roster)));
      await settle();
      expect(rosterOf(bloc.state), roster);

      bloc.add(const EventDetailRetryRequested());
      await settle();
      reads.last.complete(_snapshot().copyWith(attendees: roster));
      await settle();
      cache.add(_detail(snapshot: unread));
      await settle();

      expect(rosterOf(bloc.state), isNull);
    });

    test('over the real cache, for a user who never cached it', () async {
      final db = inMemoryServerDatabase();
      addTearDown(db.close);
      final cached = EventRepositoryImpl(
        db,
        userId: 'user-me',
        syncQueue: SyncQueueRepositoryImpl(
          db,
          const LocalClockService(),
          userId: 'user-me',
        ),
        clock: const LocalClockService(),
      );
      final remote = FakeEventRemote.detail((_) => _snapshot());
      final bloc = EventDetailBloc(
        eventId: 'e-1',
        repository: cached,
        remote: remote,
      );
      addTearDown(bloc.close);

      await bloc.stream
          .firstWhere((state) => state is EventDetailReady)
          .timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(remote.detailRequests, ['e-1']);
      // Why the bloc has to say it: the cache can't.
      expect((await cached.getEvent('e-1'))?.attendees, isNull);
      expect(rosterOf(bloc.state), allOf(isNotNull, isEmpty));
    });
  });

  group('when the server answers 404', () {
    test('a 404 forgets the event and stays not found', () async {
      // An event the user attends, so the forget empties the cache under the
      // screen and takes it off the overview. The watch answers the forget's
      // write while it runs, as the repository's would.
      when(() => repository.forgetEvent('e-1', lastWrite: 7))
          .thenAnswer((_) async {
            cache.add(null);
            return true;
          });
      final bloc = build(
        remote: failing(const EventRemoteNotFoundException('gone')),
      );
      addTearDown(bloc.close);
      final states = record(bloc);

      cache.add(_detail(attendance: _attending(EventRole.participant)));
      await settle();

      verify(() => repository.forgetEvent('e-1', lastWrite: 7)).called(1);
      expect(bloc.state, const EventDetailNotFound());

      cache.add(null);
      await settle();

      expect(bloc.state, const EventDetailNotFound());
      // The read is out when the detail shows, and is still reading through
      // the forget: a write waiting on it must not go out to an event the
      // forget is taking away (#506).
      expect(states, [readyWith(reading: true), const EventDetailNotFound()]);
    });

    test('a detail the cache gains later does not lift it', () async {
      // The server answered for this open. The event coming back into the
      // cache, from another user's read or the next hydrate, is not a new
      // answer from it.
      final bloc = build(
        remote: failing(const EventRemoteNotFoundException('gone')),
      );
      addTearDown(bloc.close);

      cache.add(null);
      await settle();
      expect(bloc.state, const EventDetailNotFound());

      cache.add(_detail());
      await settle();

      expect(bloc.state, const EventDetailNotFound());
    });

    test('a forget that fails is logged, and the event is not found', () async {
      final logger = _MockBgeLogger();
      when(() => repository.forgetEvent('e-1', lastWrite: 7))
          .thenThrow(StateError('database closed'));
      final bloc = build(
        remote: failing(const EventRemoteNotFoundException('gone')),
        logger: logger,
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(bloc.state, const EventDetailNotFound());
      verify(
        () => logger.warn(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1);
    });

    test('the forget names the cache from before the request', () async {
      // A write landing while the request is out, from a later open of the
      // event or a hydrate, is newer than the 404, and the mark taken before
      // the request is what tells the forget to leave it.
      final read = Completer<EventSnapshot>();
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      when(() => repository.lastWrite('e-1')).thenAnswer((_) async => 8);
      read.completeError(const EventRemoteNotFoundException('gone'));
      await settle();

      verify(() => repository.forgetEvent('e-1', lastWrite: 7)).called(1);
      expect(bloc.state, const EventDetailNotFound());
    });

    test('a read that outlives its screen forgets with its own mark', () async {
      // Closed while the request is out: the 404 still forgets, but only
      // the cache it was read over, never one a newer open has written.
      final read = Completer<EventSnapshot>();
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));

      cache.add(_detail());
      await settle();
      await bloc.close();
      when(() => repository.lastWrite('e-1')).thenAnswer((_) async => 8);
      read.completeError(const EventRemoteNotFoundException('gone'));
      await settle();

      verify(() => repository.forgetEvent('e-1', lastWrite: 7)).called(1);
    });

    test('a write that overtakes the 404 wins', () async {
      // A hydrate caches the event for a user invited back while the 404 is
      // out. The forget leaves it, and so does the screen.
      final read = Completer<EventSnapshot>();
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));
      addTearDown(bloc.close);
      final states = record(bloc);

      cache.add(_detail());
      await settle();
      final newer = _detail(snapshot: _snapshot(title: 'Game night, again'));
      when(() => repository.lastWrite('e-1')).thenAnswer((_) async => 8);
      when(() => repository.forgetEvent('e-1', lastWrite: 7))
          .thenAnswer((_) async => false);
      cache.add(newer);
      read.completeError(const EventRemoteNotFoundException('gone'));
      await settle();

      // Reading until the forget says the newer write stands.
      expect(
        bloc.state,
        readyWith(detail: newer, refreshFailed: isFalse, reading: false),
      );
      expect(states, everyElement(isA<EventDetailReady>()));
    });

    test('a forget the sync queue declines leaves the 404 standing', () async {
      // Declined with nothing written since: the event is dirty, say. That
      // is no newer answer than the server's.
      when(() => repository.forgetEvent('e-1', lastWrite: 7))
          .thenAnswer((_) async => false);
      final bloc = build(
        remote: failing(const EventRemoteNotFoundException('gone')),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(bloc.state, const EventDetailNotFound());
    });

    test('a write over nothing cached overtakes the 404', () async {
      // Opened before the event was cached, and the hydrate cached it while
      // the read was out.
      final read = Completer<EventSnapshot>();
      when(() => repository.lastWrite('e-1')).thenAnswer((_) async => null);
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));
      addTearDown(bloc.close);
      final states = record(bloc);

      cache.add(null);
      await settle();
      when(() => repository.lastWrite('e-1')).thenAnswer((_) async => 8);
      read.completeError(const EventRemoteNotFoundException('gone'));
      await settle();
      cache.add(_detail());
      await settle();

      verifyNever(
        () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
      );
      expect(bloc.state, readyWith(detail: _detail(), refreshFailed: isFalse));
      expect(states, isNot(contains(const EventDetailError())));
    });

    test('a retry while the forget decides reads nothing', () async {
      final forgotten = Completer<bool>();
      when(() => repository.forgetEvent('e-1', lastWrite: 7))
          .thenAnswer((_) => forgotten.future);
      final remote = failing(const EventRemoteNotFoundException('gone'));
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      bloc.add(const EventDetailRetryRequested());
      await settle();
      forgotten.complete(true);
      await settle();

      expect(remote.detailRequests, ['e-1']);
      expect(bloc.state, const EventDetailNotFound());
    });

    test('a 404 over nothing cached forgets nothing', () async {
      when(() => repository.lastWrite('e-1')).thenAnswer((_) async => null);
      final bloc = build(
        remote: failing(const EventRemoteNotFoundException('gone')),
      );
      addTearDown(bloc.close);

      cache.add(null);
      await settle();

      expect(bloc.state, const EventDetailNotFound());
      verifyNever(
        () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
      );
    });

    test('a retry in not found reads and forgets nothing more', () async {
      final remote = failing(const EventRemoteNotFoundException('gone'));
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      bloc.add(const EventDetailRetryRequested());
      await settle();

      expect(remote.detailRequests, ['e-1']);
      verify(() => repository.forgetEvent('e-1', lastWrite: 7)).called(1);
      expect(bloc.state, const EventDetailNotFound());
    });
  });

  group('the session (#432)', () {
    /// A guard that answers each of [answers] in turn, then the last again.
    Future<bool> Function() answering(List<bool> answers) {
      var asked = 0;
      return () async => answers[asked < answers.length ? asked++ : asked - 1];
    }

    test('a session that is not this user sends no read', () async {
      final remote = FakeEventRemote.detail((_) => _snapshot());
      final bloc = build(remote: remote, confirmSession: answering([false]));
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(remote.detailRequests, isEmpty);
      expect(bloc.state, readyWith(detail: _detail(), refreshFailed: isTrue));
    });

    test(
      'an answer that comes back on another session is not written',
      () async {
        // Another tab signed in while the request was out: the answer is the
        // other user's, and cached it would be this one's.
        final remote = FakeEventRemote.detail((_) => _snapshot(title: 'B'));
        final bloc = build(
          remote: remote,
          confirmSession: answering([true, false]),
        );
        addTearDown(bloc.close);

        cache.add(_detail());
        await settle();

        expect(remote.detailRequests, ['e-1']);
        verifyNever(
          () => repository.cacheEvent(any(), source: any(named: 'source')),
        );
        expect(bloc.state, readyWith(detail: _detail(), refreshFailed: isTrue));
      },
    );

    test('a 404 that comes back on another session forgets nothing', () async {
      // The other user may not read this user's event. That says nothing
      // about whether this user still may.
      final bloc = build(
        remote: failing(const EventRemoteNotFoundException('gone')),
        confirmSession: answering([true, false]),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      verifyNever(
        () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
      );
      expect(bloc.state, readyWith(refreshFailed: isTrue, canRetry: isTrue));
    });

    test('a confirmed session reads and writes as without a guard', () async {
      final fresh = _snapshot(title: 'Game night, moved');
      final bloc = build(
        remote: FakeEventRemote.detail((_) => fresh),
        confirmSession: answering([true]),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      verify(() => repository.cacheEvent(fresh, source: EventAccessSource.read))
          .called(1);
      expect(bloc.state, readyWith(refreshFailed: isFalse));
    });

    test('a guard that throws is a failed read, logged', () async {
      final logger = _MockBgeLogger();
      final remote = FakeEventRemote.detail((_) => _snapshot());
      final bloc = build(
        remote: remote,
        confirmSession: () async => throw StateError('no answer'),
        logger: logger,
      );
      addTearDown(bloc.close);

      cache.add(null);
      await settle();

      expect(remote.detailRequests, isEmpty);
      expect(bloc.state, const EventDetailError(canRetry: true));
      verify(
        () => logger.warn(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1);
    });
  });

  test('a local-only event is not read from the server', () async {
    // Created offline, so the server has never heard of its id. A read
    // would be a 404, and the 404 would forget it.
    final remote = failing(const EventRemoteNotFoundException('unknown id'));
    final bloc = build(remote: remote);
    addTearDown(bloc.close);

    cache.add(_detail(snapshot: _snapshot(isLocalOnly: true)));
    await settle();
    bloc.add(const EventDetailRetryRequested());
    await settle();

    expect(remote.detailRequests, isEmpty);
    verifyNever(
      () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
    );
    expect(
      bloc.state,
      readyWith(
        refreshing: false,
        refreshFailed: false,
        actions: isEmpty,
        canRetry: false,
      ),
    );
  });

  test(
    'no remote: an uncached event is not found, a cached one is ready',
    () async {
      final uncached = build();
      addTearDown(uncached.close);

      cache.add(null);
      await settle();

      expect(uncached.state, const EventDetailNotFound());

      final cached = StreamController<EventDetail?>();
      addTearDown(() => unawaited(cached.close()));
      when(() => repository.watchEvent('e-1')).thenAnswer((_) => cached.stream);
      final bloc = build();
      addTearDown(bloc.close);

      cached.add(_detail());
      await settle();
      bloc.add(const EventDetailRetryRequested());
      await settle();

      expect(
        bloc.state,
        readyWith(
          detail: _detail(),
          refreshFailed: false,
          refreshing: false,
          canRetry: false,
        ),
      );
    },
  );

  group('an event created here, moved onto its server id (#499)', () {
    // The sync queue delivers a create, and the reconcile deletes the local
    // event and caches the server's under the id it gave it. To a watch on
    // the local id that is the event going. The create's answer embeds each
    // attendee's role and not their user, so the names come with a read.
    late ServerDatabase db;
    late EventRepositoryImpl cached;

    EventRepositoryImpl over(ServerDatabase db) => EventRepositoryImpl(
      db,
      userId: 'user-me',
      syncQueue: SyncQueueRepositoryImpl(
        db,
        const LocalClockService(),
        userId: 'user-me',
      ),
      clock: const LocalClockService(),
    );

    setUp(() {
      db = inMemoryServerDatabase();
      cached = over(db);
    });

    tearDown(() => db.close());

    /// The current user's row as host of `ev-server`: bare, as the create
    /// answers it, or [named], as a detail read does.
    EventAttendee host({bool named = false}) {
      final row = _attending(EventRole.host).copyWith(eventId: 'ev-server');
      return named ? row.copyWith(username: 'me', displayName: 'Me') : row;
    }

    /// `ev-server`, the event the server made of the local one.
    EventSnapshot server({bool named = false}) => EventSnapshot(
      event: item('ev-server').event.copyWith(createdById: 'user-me'),
      occurrences: const [],
      attendees: [host(named: named)],
    );

    /// A server that reads `ev-server` with its roster named, and has never
    /// heard of any other id.
    FakeEventRemote serverOnly() => FakeEventRemote.detail(
      (id) => id == 'ev-server'
          ? server(named: true)
          : throw const EventRemoteNotFoundException('unknown id'),
    );

    Future<({String localId, String syncQueueId})> createHere() async {
      final created = await cached.create(
        const EventDraft(title: 'Game night'),
      );
      return (localId: created.event.id, syncQueueId: created.syncQueueId);
    }

    Future<void> reconcile(
      ({String localId, String syncQueueId}) created, {
      bool deleted = false,
    }) => cached.reconcileCreatedEvent(
      server(),
      localId: created.localId,
      deleted: deleted,
      completedSyncQueueId: created.syncQueueId,
    );

    final namedOnServerId = isA<EventDetailReady>()
        .having((s) => s.detail.snapshot.event.id, 'event.id', 'ev-server')
        .having(
          (s) => s.detail.snapshot.attendees?.map((a) => a.displayName),
          'attendee names',
          ['Me'],
        );

    test('a detail open on a local event follows it onto the server\'s '
        'id', () async {
      final created = await createHere();
      final remote = serverOnly();
      final bloc = EventDetailBloc(
        eventId: created.localId,
        repository: cached,
        remote: remote,
      );
      addTearDown(bloc.close);
      final states = record(bloc);
      await bloc.stream
          .firstWhere((state) => state is EventDetailReady)
          .timeout(const Duration(seconds: 5));

      await reconcile(created);
      await pumpEventQueue();

      expect(bloc.state, namedOnServerId);
      // Neither a spinner nor not found between the two.
      expect(states, everyElement(isA<EventDetailReady>()));
      // The move is a new open of the server's id, which reads it once.
      expect(remote.detailRequests, ['ev-server']);
    });

    test('a detail built on a local id after its move opens the server\'s '
        'event', () async {
      final created = await createHere();
      await reconcile(created);
      // A repository that did not run the reconcile, as after a reload or in
      // another tab: it hears of the move with its first answer.
      final reloaded = over(db);
      final remote = serverOnly();
      final bloc = EventDetailBloc(
        eventId: created.localId,
        repository: reloaded,
        remote: remote,
      );
      addTearDown(bloc.close);
      final states = record(bloc);

      await pumpEventQueue();

      expect(bloc.state, namedOnServerId);
      expect(states, everyElement(isA<EventDetailReady>()));
      expect(remote.detailRequests, ['ev-server']);
    });

    test('a deleted replay leaves the detail not found', () async {
      // The event was deleted before the create was answered: the local
      // event goes, and no move is recorded.
      final created = await createHere();
      final remote = serverOnly();
      final bloc = EventDetailBloc(
        eventId: created.localId,
        repository: cached,
        remote: remote,
      );
      addTearDown(bloc.close);
      await bloc.stream
          .firstWhere((state) => state is EventDetailReady)
          .timeout(const Duration(seconds: 5));

      await reconcile(created, deleted: true);
      await pumpEventQueue();

      expect(bloc.state, const EventDetailNotFound());
      expect(remote.detailRequests, isEmpty);
    });

    test('an answer the local id sent before the move was followed is '
        'dropped', () async {
      // The move can be known while the local id's watch still has answers
      // on their way: here the local event read before the reconcile
      // committed, and the null after it. Taken for the server id's first
      // answer, that null would put a spinner up between the two.
      final local = StreamController<EventDetail?>(sync: true);
      final moved = StreamController<EventDetail?>();
      addTearDown(() => unawaited(local.close()));
      addTearDown(() => unawaited(moved.close()));
      when(() => repository.watchEvent('e-1')).thenAnswer((_) => local.stream);
      when(() => repository.watchEvent('ev-server'))
          .thenAnswer((_) => moved.stream);
      final remote = unanswered();
      final bloc = build(remote: remote);
      addTearDown(bloc.close);
      final states = record(bloc);
      final localEvent = _detail(snapshot: _snapshot(isLocalOnly: true));

      local.add(localEvent);
      await settle();
      when(() => repository.reconciledEventId('e-1')).thenReturn('ev-server');
      local
        ..add(localEvent)
        ..add(null);
      await settle();
      moved.add(_detail(snapshot: server()));
      await settle();

      expect(bloc.state, readyWith(detail: _detail(snapshot: server())));
      expect(states, everyElement(isA<EventDetailReady>()));
      expect(remote.detailRequests, ['ev-server']);
    });

    test('a read of the local id answers only for it', () async {
      // The real cache never has the local id read before its move. Were it,
      // its 404 would forget the server's event, and put it on not found
      // for good.
      final moved = StreamController<EventDetail?>();
      addTearDown(() => unawaited(moved.close()));
      when(() => repository.watchEvent('ev-server'))
          .thenAnswer((_) => moved.stream);
      final reads = <String, Completer<EventSnapshot>>{};
      final remote = FakeEventRemote.detail(
        (id) => (reads[id] = Completer<EventSnapshot>()).future,
      );
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(null);
      await settle();
      when(() => repository.reconciledEventId('e-1')).thenReturn('ev-server');
      cache.add(null);
      await settle();
      moved.add(_detail(snapshot: server()));
      await settle();
      reads['e-1']!.completeError(
        const EventRemoteNotFoundException('unknown id'),
      );
      await settle();

      expect(remote.detailRequests, ['e-1', 'ev-server']);
      verifyNever(
        () => repository.forgetEvent(
          'ev-server',
          lastWrite: any(named: 'lastWrite'),
        ),
      );
      expect(
        bloc.state,
        readyWith(detail: _detail(snapshot: server()), refreshFailed: false),
      );
    });
  });

  group('when the user retries', () {
    late List<Completer<EventSnapshot>> reads;
    late FakeEventRemote remote;

    setUp(() {
      reads = [];
      remote = FakeEventRemote.detail((_) {
        final read = Completer<EventSnapshot>();
        reads.add(read);
        return read.future;
      });
    });

    void fail(Completer<EventSnapshot> read) =>
        read.completeError(const EventRemoteTransientException('offline'));

    test('retry reads again and says so while it runs', () async {
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      fail(reads.single);
      await settle();
      expect(bloc.state, readyWith(refreshFailed: true, refreshing: false));

      bloc.add(const EventDetailRetryRequested());
      await settle();

      expect(remote.detailRequests, ['e-1', 'e-1']);
      // Still failed underneath: the event is no fresher until it lands.
      expect(bloc.state, readyWith(refreshing: true, refreshFailed: true));

      reads.last.complete(_snapshot());
      await settle();

      expect(bloc.state, readyWith(refreshing: false, refreshFailed: false));
    });

    test('a retry that fails again flags the cache again', () async {
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      fail(reads.single);
      await settle();
      bloc.add(const EventDetailRetryRequested());
      await settle();
      fail(reads.last);
      await settle();

      expect(bloc.state, readyWith(refreshing: false, refreshFailed: true));
    });

    test('a press while a read runs reads nothing more', () async {
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      // The open's own read is still running.
      bloc.add(const EventDetailRetryRequested());
      await settle();

      expect(remote.detailRequests, ['e-1']);

      fail(reads.single);
      await settle();
      bloc
        ..add(const EventDetailRetryRequested())
        ..add(const EventDetailRetryRequested());
      await settle();

      expect(remote.detailRequests, ['e-1', 'e-1']);
    });

    group('from the error', () {
      Future<EventDetailBloc> buildOnTheError() async {
        final bloc = build(remote: remote);
        cache.add(null);
        await settle();
        fail(reads.single);
        await settle();
        expect(bloc.state, const EventDetailError(canRetry: true));
        return bloc;
      }

      test('says so on the error, rather than with a spinner', () async {
        final bloc = await buildOnTheError();
        addTearDown(bloc.close);

        bloc.add(const EventDetailRetryRequested());
        await settle();

        expect(
          bloc.state,
          const EventDetailError(refreshing: true, canRetry: true),
        );

        fail(reads.last);
        await settle();

        expect(bloc.state, const EventDetailError(canRetry: true));
      });

      test('that succeeds waits for the write, then shows it', () async {
        final bloc = await buildOnTheError();
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(const EventDetailRetryRequested());
        await settle();
        reads.last.complete(_snapshot());
        await settle();

        expect(bloc.state, const EventDetailLoading());

        cache.add(_detail());
        await settle();

        expect(states, [
          const EventDetailError(refreshing: true, canRetry: true),
          const EventDetailLoading(),
          readyWith(detail: _detail(), refreshing: false, refreshFailed: false),
        ]);
      });
    });

    test('re-reads a cache that failed before it answered', () async {
      // Until the cache answers, nothing says whether the event is
      // local-only, so the server is not asked. The retry asks the cache
      // again, and its answer starts the read the open would have.
      final reread = StreamController<EventDetail?>();
      addTearDown(() => unawaited(reread.close()));
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.addError(StateError('read failed'));
      await settle();

      expect(bloc.state, const EventDetailError(canRetry: true));
      expect(remote.detailRequests, isEmpty);

      when(() => repository.watchEvent('e-1')).thenAnswer((_) => reread.stream);
      bloc.add(const EventDetailRetryRequested());
      await settle();

      expect(
        bloc.state,
        const EventDetailError(refreshing: true, canRetry: true),
      );

      reread.add(_detail());
      await settle();

      expect(remote.detailRequests, ['e-1']);
      expect(bloc.state, readyWith(detail: _detail(), refreshing: true));

      reads.single.complete(_snapshot());
      await settle();

      expect(bloc.state, readyWith(refreshing: false, refreshFailed: false));
    });
  });

  group('reading (#501)', () {
    // A delete that lands while a read is out would be undone by the read's
    // 200, which caches the event again. The screen holds Delete on this
    // until the read has settled, whoever asked for it.
    test('the open\'s read is reading, not refreshing', () async {
      final read = Completer<EventSnapshot>();
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(
        bloc.state,
        readyWith(detail: _detail(), reading: true, refreshing: false),
      );

      read.complete(_snapshot());
      await settle();

      expect(bloc.state, readyWith(reading: false, refreshing: false));
    });

    test('keeps reading until the read has been written', () async {
      // The 200 that undoes a delete is the cache write, not the response.
      final write = Completer<void>();
      when(() => repository.cacheEvent(any(), source: any(named: 'source')))
          .thenAnswer((_) => write.future);
      final bloc = build(remote: FakeEventRemote.detail((_) => _snapshot()));
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      verify(() => repository.cacheEvent(any(), source: EventAccessSource.read))
          .called(1);
      expect(bloc.state, readyWith(reading: true));

      write.complete();
      await settle();

      expect(bloc.state, readyWith(reading: false));
    });

    test('a retry is both', () async {
      final reads = <Completer<EventSnapshot>>[];
      final bloc = build(
        remote: FakeEventRemote.detail((_) {
          final read = Completer<EventSnapshot>();
          reads.add(read);
          return read.future;
        }),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      reads.single.completeError(
        const EventRemoteTransientException('offline'),
      );
      await settle();

      expect(bloc.state, readyWith(reading: false, refreshing: false));

      bloc.add(const EventDetailRetryRequested());
      await settle();

      expect(bloc.state, readyWith(reading: true, refreshing: true));

      reads.last.complete(_snapshot());
      await settle();

      expect(bloc.state, readyWith(reading: false, refreshing: false));
    });

    test('a failed read stops reading', () async {
      final bloc = build(
        remote: failing(const EventRemoteTransientException('offline')),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(bloc.state, readyWith(reading: false, refreshFailed: true));
    });

    test('no remote never reads', () async {
      final bloc = build();
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();

      expect(bloc.state, readyWith(detail: _detail(), reading: false));
    });
  });

  group('the actions', () {
    test('the actions follow the attendance', () async {
      final bloc = build();
      addTearDown(bloc.close);

      cache.add(_detail(attendance: _attending(EventRole.host)));
      await settle();

      expect(actionsOf(bloc.state), contains(EventAction.delete));

      cache.add(_detail());
      await settle();

      expect(actionsOf(bloc.state), isEmpty);
    });

    test(
      'a household owner gets household actions without attending',
      () async {
        final asked = <String>[];
        final bloc = build(
          householdRole: (householdId) async {
            asked.add(householdId);
            return householdId == 'h-1' ? HouseholdRole.householdOwner : null;
          },
        );
        addTearDown(bloc.close);

        cache.add(_detail(snapshot: _snapshot(householdId: 'h-1')));
        await settle();

        expect(actionsOf(bloc.state), contains(EventAction.edit));

        // Asked once per household, not once per emission.
        cache.add(
          _detail(
            snapshot: _snapshot(householdId: 'h-1', title: 'Renamed'),
          ),
        );
        await settle();

        expect(asked, ['h-1']);
        expect(actionsOf(bloc.state), contains(EventAction.edit));
      },
    );

    test(
      'asks for the household role again when the households change',
      () async {
        // Right after sign-in the event can be cached before the household
        // hydrate has cached the viewer's membership, so the first answer is
        // none. The households stream emitting is that hydrate landing.
        final households = StreamController<List<Household>>();
        addTearDown(households.close);
        HouseholdRole? role;
        final bloc = build(
          households: households.stream,
          householdRole: (_) async => role,
        );
        addTearDown(bloc.close);

        cache.add(_detail(snapshot: _snapshot(householdId: 'h-1')));
        await settle();
        expect(actionsOf(bloc.state), isNot(contains(EventAction.edit)));

        role = HouseholdRole.householdOwner;
        households.add([_household('h-1', 'The Smiths')]);
        await settle();

        expect(actionsOf(bloc.state), contains(EventAction.edit));
      },
    );

    test('a later household-role answer wins over an earlier one', () async {
      // Lookups can finish out of order. The one asked last is the answer.
      final households = StreamController<List<Household>>();
      addTearDown(households.close);
      final lookups = <Completer<HouseholdRole?>>[];
      final bloc = build(
        households: households.stream,
        householdRole: (_) {
          final lookup = Completer<HouseholdRole?>();
          lookups.add(lookup);
          return lookup.future;
        },
      );
      addTearDown(bloc.close);

      cache.add(_detail(snapshot: _snapshot(householdId: 'h-1')));
      await settle();
      households.add([_household('h-1', 'The Smiths')]);
      await settle();
      expect(lookups, hasLength(2));

      lookups.last.complete(HouseholdRole.householdOwner);
      await settle();
      lookups.first.complete(null);
      await settle();

      expect(actionsOf(bloc.state), contains(EventAction.edit));
    });

    test('a failed household-role lookup keeps the last answer', () async {
      final households = StreamController<List<Household>>();
      addTearDown(households.close);
      var fail = false;
      final bloc = build(
        households: households.stream,
        householdRole: (_) async {
          if (fail) throw StateError('database closed');
          return HouseholdRole.householdOwner;
        },
        logger: _MockBgeLogger(),
      );
      addTearDown(bloc.close);

      cache.add(_detail(snapshot: _snapshot(householdId: 'h-1')));
      await settle();
      fail = true;
      households.add([_household('h-1', 'The Smiths')]);
      await settle();

      expect(actionsOf(bloc.state), contains(EventAction.edit));
    });

    test('a failed household-role lookup reads as no household role', () async {
      final logger = _MockBgeLogger();
      final bloc = build(
        householdRole: (_) async => throw StateError('no session'),
        logger: logger,
      );
      addTearDown(bloc.close);

      cache.add(
        _detail(
          snapshot: _snapshot(householdId: 'h-1'),
          attendance: _attending(EventRole.participant),
        ),
      );
      await settle();

      // What attending gives, and nothing from the household.
      expect(actionsOf(bloc.state), {EventAction.rsvp});
      verify(
        () => logger.warn(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1);
    });
  });

  group('the household name', () {
    String? householdNameOf(EventDetailState state) =>
        (state as EventDetailReady).householdName;

    test(
      'names the household when the households hold it, and not otherwise',
      () async {
        final households = StreamController<List<Household>>();
        addTearDown(households.close);
        final bloc = build(households: households.stream);
        addTearDown(bloc.close);

        // Never waited on: the event is up before any name is known.
        cache.add(_detail(snapshot: _snapshot(householdId: 'h-1')));
        await settle();
        expect(householdNameOf(bloc.state), isNull);

        households.add([_household('h-2', 'The Joneses')]);
        await settle();
        expect(householdNameOf(bloc.state), isNull);

        households.add([_household('h-1', 'The Smiths')]);
        await settle();
        expect(householdNameOf(bloc.state), 'The Smiths');

        // An event in no household is named by none.
        cache.add(_detail());
        await settle();
        expect(householdNameOf(bloc.state), isNull);
      },
    );

    test('a households error is logged and changes nothing', () async {
      final logger = _MockBgeLogger();
      final households = StreamController<List<Household>>();
      addTearDown(households.close);
      final bloc = build(households: households.stream, logger: logger);
      addTearDown(bloc.close);

      cache.add(_detail(snapshot: _snapshot(householdId: 'h-1')));
      households.add([_household('h-1', 'The Smiths')]);
      await settle();
      households.addError(StateError('households failed'));
      await settle();

      expect(householdNameOf(bloc.state), 'The Smiths');
      verify(
        () => logger.warn(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1);
    });
  });

  group('the cache', () {
    test('a cache error after a detail keeps the detail', () async {
      final bloc = build();
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      cache.addError(StateError('read failed'));
      await settle();

      expect(bloc.state, readyWith(detail: _detail()));
    });

    test('a cache error with nothing cached is an error', () async {
      final bloc = build();
      addTearDown(bloc.close);

      cache.add(null);
      await settle();
      cache.addError(StateError('read failed'));
      await settle();

      expect(bloc.state, const EventDetailError());
    });

    test('a cache error while the open reads stays loading', () async {
      // An error there would offer a retry the running read refuses. The
      // read settles the screen, as it would have without the error.
      final read = Completer<EventSnapshot>();
      final bloc = build(remote: FakeEventRemote.detail((_) => read.future));
      addTearDown(bloc.close);
      final states = record(bloc);

      cache.add(null);
      await settle();
      cache.addError(StateError('read failed'));
      await settle();

      expect(bloc.state, const EventDetailLoading());

      read.completeError(const EventRemoteTransientException('offline'));
      await settle();

      // Loading throughout, so no error came and went on the way.
      expect(states, [
        const EventDetailLoading(),
        const EventDetailError(canRetry: true),
      ]);
    });

    test('a cache that ends freezes the last state', () async {
      // How a session teardown arrives. The detail stays up while the auth
      // redirect pops the route.
      final bloc = build();
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      await cache.close();
      await settle();

      expect(bloc.state, readyWith(detail: _detail()));
    });

    test('a cache that ends before it answers is an error', () async {
      final bloc = build(remote: unanswered());
      addTearDown(bloc.close);

      await cache.close();
      await settle();

      expect(bloc.state, const EventDetailError());
    });

    test('a cache that ends while the read runs is an error', () async {
      // The read can't be shown: what it writes reaches the screen only
      // through the cache, and nothing reads it now.
      final bloc = build(remote: unanswered());
      addTearDown(bloc.close);

      cache.add(null);
      await settle();
      expect(bloc.state, const EventDetailLoading());

      await cache.close();
      await settle();

      expect(bloc.state, const EventDetailError());
    });

    test('an ended cache offers no retry', () async {
      // The error a session teardown leaves while loading: a retry would be
      // ignored, so the screen must not draw one.
      final bloc = build(remote: unanswered());
      addTearDown(bloc.close);

      cache.add(null);
      await settle();
      await cache.close();
      await settle();

      expect(bloc.state, const EventDetailError());
    });

    test('an ended cache takes the retry off a shown detail', () async {
      // The state is otherwise the one already up, and a bloc drops an
      // equal emit, so the retry's going is what rebuilds the banner.
      final bloc = build(
        remote: failing(const EventRemoteTransientException('offline')),
      );
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      expect(bloc.state, readyWith(refreshFailed: true, canRetry: true));

      await cache.close();
      await settle();

      expect(bloc.state, readyWith(refreshFailed: true, canRetry: false));
    });

    test('an ended cache takes the retry off a cache error', () async {
      final bloc = build(remote: unanswered());
      addTearDown(bloc.close);

      cache.addError(StateError('read failed'));
      await settle();
      expect(bloc.state, const EventDetailError(canRetry: true));

      await cache.close();
      await settle();

      expect(bloc.state, const EventDetailError());
    });

    test('an ended cache is not read again', () async {
      // Its repository is gone, so a read would have nowhere to go.
      final remote = failing(const EventRemoteTransientException('offline'));
      final bloc = build(remote: remote);
      addTearDown(bloc.close);

      cache.add(_detail());
      await settle();
      await cache.close();
      await settle();
      bloc.add(const EventDetailRetryRequested());
      await settle();

      expect(remote.detailRequests, ['e-1']);
      expect(bloc.state, readyWith(refreshing: false, refreshFailed: true));
    });
  });

  test('closing stops listening to every source', () async {
    final households = StreamController<List<Household>>.broadcast();
    addTearDown(households.close);
    final bloc = build(households: households.stream);
    cache.add(_detail());
    await settle();

    await bloc.close();

    expect(cache.hasListener, isFalse);
    expect(households.hasListener, isFalse);
  });

  group('values', () {
    test('states compare by value', () {
      // A bloc drops an emit equal to its current state, so deriving the
      // state the screen already shows does not rebuild it.
      expect(const EventDetailLoading(), const EventDetailLoading());
      expect(const EventDetailNotFound(), const EventDetailNotFound());
      expect(const EventDetailError(), const EventDetailError());
      expect(
        const EventDetailError(),
        isNot(const EventDetailError(refreshing: true)),
      );
      expect(
        const EventDetailError(),
        isNot(const EventDetailError(canRetry: true)),
      );
      expect(const EventDetailLoading(), isNot(const EventDetailNotFound()));
      expect(
        EventDetailReady(detail: _detail(), actions: {EventAction.rsvp}),
        EventDetailReady(detail: _detail(), actions: {EventAction.rsvp}),
      );
      expect(
        EventDetailReady(detail: _detail(), actions: const {}),
        isNot(
          EventDetailReady(
            detail: _detail(),
            actions: const {},
            refreshFailed: true,
          ),
        ),
      );
      expect(
        EventDetailReady(detail: _detail(), actions: const {}),
        isNot(
          EventDetailReady(
            detail: _detail(),
            actions: const {},
            canRetry: true,
          ),
        ),
      );
      expect(
        EventDetailReady(detail: _detail(), actions: const {}),
        isNot(
          EventDetailReady(detail: _detail(), actions: const {}, reading: true),
        ),
      );
    });

    test('events compare by value', () {
      final households = [_household('h-1', 'The Smiths')];

      expect(
        EventDetailCacheUpdated(_detail(), eventId: 'e-1'),
        EventDetailCacheUpdated(_detail(), eventId: 'e-1'),
      );
      expect(
        const EventDetailCacheUpdated(null, eventId: 'e-1'),
        isNot(EventDetailCacheUpdated(_detail(), eventId: 'e-1')),
      );
      expect(
        const EventDetailCacheUpdated(null, eventId: 'e-1'),
        isNot(const EventDetailCacheUpdated(null, eventId: 'ev-server')),
      );
      expect(
        const EventDetailCacheFailed(eventId: 'e-1'),
        const EventDetailCacheFailed(eventId: 'e-1'),
      );
      expect(
        const EventDetailCacheFailed(eventId: 'e-1'),
        isNot(const EventDetailCacheFailed(eventId: 'ev-server')),
      );
      expect(
        const EventDetailCacheFailed(eventId: 'e-1'),
        isNot(const EventDetailCacheEnded()),
      );
      expect(
        EventDetailHouseholdsUpdated(households),
        EventDetailHouseholdsUpdated(households),
      );
      expect(
        const EventDetailHouseholdRoleResolved(
          'h-1',
          HouseholdRole.householdOwner,
        ),
        const EventDetailHouseholdRoleResolved(
          'h-1',
          HouseholdRole.householdOwner,
        ),
      );
      expect(
        const EventDetailReadSettled(
          EventDetailReadOutcome.failed,
          eventId: 'e-1',
        ),
        isNot(
          const EventDetailReadSettled(
            EventDetailReadOutcome.notFound,
            eventId: 'e-1',
          ),
        ),
      );
      expect(
        const EventDetailReadSettled(
          EventDetailReadOutcome.failed,
          eventId: 'e-1',
        ),
        isNot(
          const EventDetailReadSettled(
            EventDetailReadOutcome.failed,
            eventId: 'ev-server',
          ),
        ),
      );
      expect(
        const EventDetailReadSettled(
          EventDetailReadOutcome.succeeded,
          eventId: 'e-1',
        ),
        isNot(
          const EventDetailReadSettled(
            EventDetailReadOutcome.succeeded,
            eventId: 'e-1',
            rosterWithheld: true,
          ),
        ),
      );
      expect(
        const EventDetailRetryRequested(),
        const EventDetailRetryRequested(),
      );
    });
  });
}
