import 'dart:async';

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_event_remote.dart';

/// Answers each question from [answers], the last one repeating, and records
/// whom it was asked about (#432).
class _FakeIdentityGuard implements SessionIdentityGuard {
  _FakeIdentityGuard(this.answers);

  final List<SessionConfirmation> answers;
  final askedFor = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    final asked = askedFor.length;
    askedFor.add(userId);
    return answers[asked < answers.length ? asked : answers.length - 1];
  }
}

/// Keeps what an installer registers with the rehydrator, so a test can read
/// the key it chose and drive the entry itself.
class _RecordingRehydrator implements SessionRehydrator {
  final entries =
      <String, ({bool Function() isStale, Future<void> Function() run})>{};

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) => entries[key] = (isStale: isStale, run: run);

  @override
  Future<void> rehydrateStale() async {}
}

const _server = ScopedServer(serverId: 'server-1', displayName: 'My Server');
const _kUserId = 'user-1';

/// The event [id] as the list returns it, created [minute] minutes past a
/// fixed hour. No roster, since the list carries none.
EventSnapshot _row(String id, int minute) {
  final createdAt = DateTime.utc(2026, 10, 1, 12, minute);
  return EventSnapshot(
    event: Event(
      id: id,
      title: 'Event $id',
      createdById: 'user-host',
      type: EventType.casualGathering,
      reach: Reach.friends,
      status: EventStatus.scheduled,
      schedulingMode: EventSchedulingMode.fixed,
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
    occurrences: const [],
  );
}

/// The only page of [rows]. [total] defaults to the rows sent; pass a larger
/// one for a page that counts events it did not send.
PaginatedResult<EventSnapshot> _page(List<EventSnapshot> rows, {int? total}) {
  final count = total ?? rows.length;
  return PaginatedResult(
    items: rows,
    meta: PaginationMeta(
      page: 1,
      limit: 100,
      total: count,
      totalPages: (count / 100).ceil(),
      hasMore: false,
    ),
  );
}

PaginatedResult<EventSnapshot> _empty() => _page(const []);

PaginatedResult<EventSnapshot> _offline(EventListRequest _) =>
    throw const EventRemoteTransientException('offline');

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl events;
  late DependencyContainerImpl container;
  late FakeEventRemote remote;
  late DateTime clock;

  /// What the remote answers to its next request. A test swaps it to script
  /// an outage and the end of it.
  late FutureOr<PaginatedResult<EventSnapshot>> Function(
    EventListRequest request,
  )
  answer;

  setUp(() {
    db = inMemoryServerDatabase();
    events = EventRepositoryImpl(
      db,
      userId: _kUserId,
      syncQueue: SyncQueueRepositoryImpl(
        db,
        const LocalClockService(),
        userId: _kUserId,
      ),
      clock: const LocalClockService(),
    );
    container = DependencyContainerImpl();
    answer = (_) => _empty();
    remote = FakeEventRemote((request) => answer(request));
    clock = DateTime.utc(2026, 10, 22, 12);
  });

  tearDown(() async {
    await container.dispose();
    await db.close();
  });

  /// Registers what the hydrate needs, less whatever a test leaves out.
  void register({bool client = true, bool repository = true}) {
    if (repository) {
      container.registerSingleton<EventRepository>(
        events,
        dispose: (_) => events.onDispose(),
      );
    }
    if (client) container.registerSingleton<EventRemoteDataSource>(remote);
  }

  Future<void> install({DateTime Function()? now}) =>
      EventHydrateInstaller(now: now).install(container, _server, _kUserId);

  Future<SessionRehydrator> withRehydrator() async {
    await const SessionRehydratorInstaller().install(
      container,
      _server,
      _kUserId,
    );
    return container.get<SessionRehydrator>();
  }

  /// Holds the remote's answer to its next request until `release` completes,
  /// and completes `arrived` once that request has reached it.
  ({Completer<PaginatedResult<EventSnapshot>> release, Future<void> arrived})
  hold() {
    final release = Completer<PaginatedResult<EventSnapshot>>();
    final arrived = Completer<void>();
    answer = (_) {
      if (!arrived.isCompleted) arrived.complete();
      return release.future;
    };
    return (release: release, arrived: arrived.future);
  }

  /// The reading the status settles on once no pass is in flight.
  Future<EventHydration> settled() => container
      .get<EventHydrationStatus>()
      .watch()
      .firstWhere((h) => h.state != EventHydrationState.running)
      .timeout(const Duration(seconds: 5));

  test('skips without a remote or repository and registers nothing', () async {
    for (final (label, client, repository) in <(String, bool, bool)>[
      ('the event client', false, true),
      ('the event repository', true, false),
      ('either', false, false),
    ]) {
      final bare = DependencyContainerImpl();
      addTearDown(bare.dispose);
      if (repository) bare.registerSingleton<EventRepository>(events);
      if (client) bare.registerSingleton<EventRemoteDataSource>(remote);
      await const SessionRehydratorInstaller().install(bare, _server, _kUserId);

      await const EventHydrateInstaller().install(bare, _server, _kUserId);
      // A registered entry would be stale, since it never ran, and would
      // resolve the collaborator that is missing.
      await bare.get<SessionRehydrator>().rehydrateStale();
      await pumpEventQueue();

      expect(remote.requests, isEmpty, reason: 'without $label');
      // An absent status reads as idle, and an absent refresher as no retry
      // to offer. A registered one would claim a hydrate that cannot run.
      expect(
        bare.isRegistered<EventHydrationStatus>(),
        isFalse,
        reason: 'without $label',
      );
      expect(
        bare.isRegistered<EventRefresher>(),
        isFalse,
        reason: 'without $label',
      );
    }
  });

  test(
    'starts a pass on install and reports running before it returns',
    () async {
      register();
      final held = hold();

      final installing = install();

      // Read before awaiting it, so before the pass takes its first turn.
      // install() has no await of its own, so its body has already run. A
      // screen can be built in that window, and an idle status there would
      // say the user has no events while the cache is about to fill.
      expect(
        container.get<EventHydrationStatus>().state,
        EventHydrationState.running,
      );

      // Activation is the bootstrap gate: awaiting the network here would put
      // it on the sign-in path.
      await installing.timeout(const Duration(seconds: 1));

      await held.arrived.timeout(const Duration(seconds: 5));
      expect(remote.requests, [(page: 1, limit: 100)]);

      held.release.complete(_page([_row('e-1', 10)]));
      final reading = await settled();

      expect(reading.state, EventHydrationState.refreshed);
      expect(await events.getEvent('e-1'), isNotNull);
    },
  );

  test('registers a rehydrate entry named events that is stale until a pass '
      'completes', () async {
    final rehydrator = _RecordingRehydrator();
    container.registerSingleton<SessionRehydrator>(rehydrator);
    register();
    final held = hold();

    await install(now: () => clock);

    expect(rehydrator.entries.keys, ['events']);
    final entry = rehydrator.entries['events']!;
    // The install-time pass is in flight. A trigger now would only be
    // dropped, so the entry does not ask for one.
    expect(entry.isStale(), isFalse);

    // Failed only once the request is waiting on it. An error on a future
    // nobody has listened to yet is reported as unhandled.
    await held.arrived.timeout(const Duration(seconds: 5));
    held.release.completeError(const EventRemoteTransientException('offline'));
    await settled();
    // It failed, and nothing is current.
    expect(entry.isStale(), isTrue);

    answer = (_) => _empty();
    await entry.run();
    // A pass completed, so the entry is current until it ages out.
    expect(entry.isStale(), isFalse);
  });

  test('the refresher runs a pass even while one is not stale', () async {
    register();
    final rehydrator = await withRehydrator();
    await install(now: () => clock);
    await settled();

    // A trigger finds the cache current and runs nothing...
    await rehydrator.rehydrateStale();
    expect(remote.requests, hasLength(1));

    // ...and a press is not a trigger: someone is waiting to see it work.
    await container.get<EventRefresher>().refresh();
    expect(remote.requests, hasLength(2));
  });

  test('a session the guard will not confirm ends the pass failed', () async {
    register();
    final guard = _FakeIdentityGuard([SessionConfirmation.notThisUser]);
    container.registerSingleton<SessionIdentityGuard>(guard);

    await install();
    final reading = await settled();

    expect(reading.state, EventHydrationState.failed);
    expect(guard.askedFor, [_kUserId]);
    expect(remote.requests, isEmpty);
  });

  test(
    'install completes when the pass fails, and reads it as failed',
    () async {
      // A throw out of install() aborts activation, which signs the user out.
      register();
      answer = _offline;

      await install();
      final reading = await settled();

      expect(remote.requests, hasLength(1));
      expect(reading.state, EventHydrationState.failed);
    },
  );

  test('a pass landing after the scope pops does not throw', () async {
    // The pass is unawaited, so it outlives the scope that started it.
    register();
    final held = hold();
    await install();
    final status = container.get<EventHydrationStatus>();
    final refresher = container.get<EventRefresher>();
    await held.arrived.timeout(const Duration(seconds: 5));

    await container.dispose();
    held.release.complete(_empty());
    // Joins the pass in flight, so this returns once it has ended.
    await refresher.refresh();

    // Closed by the teardown, so the late outcome is dropped.
    expect(status.state, EventHydrationState.running);
  });

  test('a pass that could purge nothing still reads as refreshed', () async {
    // The page counts an event it did not send, so it vouches for no absence
    // and the pass ends drained. Every event it did send is cached, which is
    // what the screens show, and a re-run would end the same way.
    register();
    final rehydrator = await withRehydrator();
    answer = (_) => _page([_row('e-1', 10)], total: 2);

    await install(now: () => clock);
    final reading = await settled();
    await rehydrator.rehydrateStale();

    expect(reading.state, EventHydrationState.refreshed);
    expect(remote.requests, hasLength(1));
  });

  group('the retry the screens call', () {
    test('drives the status the screens already watch', () async {
      register();
      answer = _offline;
      await install();
      await settled();
      final seen = <EventHydrationState>[];
      final watching = container
          .get<EventHydrationStatus>()
          .watch()
          .map((h) => h.state)
          .listen(seen.add);
      addTearDown(watching.cancel);

      answer = (_) => _empty();
      await container.get<EventRefresher>().refresh();
      await pumpEventQueue();

      expect(seen, [
        EventHydrationState.failed,
        EventHydrationState.running,
        EventHydrationState.refreshed,
      ]);
    });

    test('a press during the install-time pass joins it', () async {
      register();
      final held = hold();
      await install();

      final press = container.get<EventRefresher>().refresh();
      held.release.complete(_empty());
      await press;

      expect(remote.requests, hasLength(1));
      expect(
        container.get<EventHydrationStatus>().state,
        EventHydrationState.refreshed,
      );
    });
  });

  group('re-hydrate registration', () {
    test('a failed pass is re-run by a later trigger', () async {
      register();
      final rehydrator = await withRehydrator();
      answer = _offline;
      await install();
      await settled();

      // The server comes back.
      answer = (_) => _empty();
      await rehydrator.rehydrateStale();

      expect(remote.requests, hasLength(2));
    });

    group('a completed pass', () {
      const window = EventHydrateInstaller.staleAfter;

      Future<SessionRehydrator> completed() async {
        register();
        final rehydrator = await withRehydrator();
        await install(now: () => clock);
        await settled();
        return rehydrator;
      }

      test('is not re-run inside the window', () async {
        final rehydrator = await completed();

        clock = clock.add(window - const Duration(seconds: 1));
        await rehydrator.rehydrateStale();

        expect(remote.requests, hasLength(1));
      });

      test('is re-run once the window has passed', () async {
        final rehydrator = await completed();

        clock = clock.add(window);
        await rehydrator.rehydrateStale();

        expect(remote.requests, hasLength(2));
      });

      test('a failed re-run is re-run by the next trigger', () async {
        final rehydrator = await completed();
        clock = clock.add(window);
        answer = _offline;
        await rehydrator.rehydrateStale();

        answer = (_) => _empty();
        await rehydrator.rehydrateStale();

        expect(remote.requests, hasLength(3));
      });
    });

    test('a trigger arriving during the install-time pass adds no second '
        'request', () async {
      register();
      final rehydrator = await withRehydrator();
      final held = hold();
      await install();

      await rehydrator.rehydrateStale();
      held.release.complete(_empty());
      await settled();

      expect(remote.requests, hasLength(1));
    });
  });

  // On web another tab can move the shared session cookie to another user
  // while this scope still belongs to the first. A pass sent then would cache
  // the other user's events as this user's (#432).
  group('the session identity check', () {
    test('asks about the scope user before a pass, and before writing the '
        'page it reads', () async {
      register();
      final guard = _FakeIdentityGuard([SessionConfirmation.confirmed]);
      container.registerSingleton<SessionIdentityGuard>(guard);
      answer = (_) => _page([_row('e-1', 10)]);

      await install();
      final reading = await settled();

      expect(guard.askedFor, [_kUserId, _kUserId]);
      expect(remote.requests, hasLength(1));
      expect(reading.state, EventHydrationState.refreshed);
      expect(await events.getEvent('e-1'), isNotNull);
    });

    test('a session that stops being confirmed once the page is read caches '
        'nothing and ends the pass failed', () async {
      register();
      container.registerSingleton<SessionIdentityGuard>(
        _FakeIdentityGuard([
          SessionConfirmation.confirmed,
          SessionConfirmation.notThisUser,
        ]),
      );
      answer = (_) => _page([_row('e-1', 10)]);

      await install();
      final reading = await settled();

      expect(remote.requests, hasLength(1));
      expect(reading.state, EventHydrationState.failed);
      // The page was read as whoever holds the session now.
      expect(await events.getEvent('e-1'), isNull);
    });

    test('a guard that cannot answer is a refusal too, and reads as failed so '
        'a later trigger asks again', () async {
      register();
      final guard = _FakeIdentityGuard([SessionConfirmation.unanswered]);
      container.registerSingleton<SessionIdentityGuard>(guard);
      final rehydrator = await withRehydrator();

      await install();
      final reading = await settled();
      await rehydrator.rehydrateStale();

      expect(reading.state, EventHydrationState.failed);
      expect(guard.askedFor, [_kUserId, _kUserId]);
      expect(remote.requests, isEmpty);
    });
  });
}
