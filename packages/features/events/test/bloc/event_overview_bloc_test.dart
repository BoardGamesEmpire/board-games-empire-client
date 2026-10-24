import 'dart:async';

import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

class _MockEventRepository extends Mock implements EventRepository {}

Household _household(String id, String name) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// The overview's state (#497): the collection list's table over the cache
/// and the hydrate, with the grouping read against the clock at every
/// derivation and the households' names as an annotation.
void main() {
  final kNow = DateTime.utc(2026, 10, 23, 18);

  late _MockEventRepository repository;
  late StreamController<List<EventListItem>> items;
  late EventHydrationStatus status;

  setUp(() {
    repository = _MockEventRepository();
    items = StreamController<List<EventListItem>>();
    status = EventHydrationStatus();
    when(repository.watchAttendingEventListItems)
        .thenAnswer((_) => items.stream);
  });

  tearDown(() {
    // Not awaited: closing a single-subscription controller completes when
    // its done event is delivered, so a test whose bloc never listened to
    // `items` would hang here.
    unawaited(items.close());
    unawaited(status.close());
  });

  EventOverviewBloc build({
    bool withHydration = true,
    Stream<List<Household>>? households,
    Future<void> Function()? onRetry,
    DateTime Function()? now,
  }) => EventOverviewBloc(
    repository: repository,
    households: households,
    hydration: withHydration ? status.watch() : null,
    onRetry: onRetry,
    now: now ?? () => kNow,
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// An upcoming event, so its row lands in a group the tests can read.
  EventListItem upcoming(String id, {String? householdId}) => item(
    id,
    householdId: householdId,
    occurrences: [confirmed('o-$id', DateTime.utc(2026, 10, 30, 19))],
  );

  Matcher readyWith({
    Object? upcoming = anything,
    Object? isEmpty = anything,
    Object? refreshFailed = anything,
    Object? refreshing = anything,
  }) => isA<EventOverviewReady>()
      .having(
        (s) => s.groups.upcoming.map((r) => r.event.id).toList(),
        'upcoming',
        upcoming,
      )
      .having((s) => s.groups.isEmpty, 'groups.isEmpty', isEmpty)
      .having((s) => s.refreshFailed, 'refreshFailed', refreshFailed)
      .having((s) => s.refreshing, 'refreshing', refreshing);

  test('starts loading, before the cache has said anything', () {
    final bloc = build();
    addTearDown(bloc.close);

    expect(bloc.state, isA<EventOverviewLoading>());
  });

  test('shows the groups as soon as the cache has rows', () async {
    final bloc = build();
    addTearDown(bloc.close);

    status.started();
    items.add([upcoming('e-1'), item('e-2')]);

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<EventOverviewReady>()
            .having(
              (s) => s.groups.upcoming.map((r) => r.event.id),
              'upcoming',
              ['e-1'],
            )
            .having(
              (s) => s.groups.planning.map((r) => r.event.id),
              'planning',
              ['e-2'],
            )
            .having((s) => s.refreshFailed, 'refreshFailed', isFalse),
      ),
    );
  });

  test('an empty cache mid-hydrate is loading, not empty', () async {
    // The first sign-in case: the cache is empty because the hydrate has
    // not filled it yet, and the stream cannot say so.
    final bloc = build();
    addTearDown(bloc.close);

    status.started();
    items.add(const []);
    await settle();

    expect(bloc.state, isA<EventOverviewLoading>());
  });

  test('an empty cache is empty once the hydrate settles', () async {
    final bloc = build();
    addTearDown(bloc.close);

    status.started();
    items.add(const []);
    await settle();
    status.finished(EventHydrateOutcome.complete);

    await expectLater(bloc.stream, emits(readyWith(isEmpty: isTrue)));
  });

  test('an empty cache with no hydrate at all is empty, not loading', () async {
    // An absent status reads as idle. A spinner there would never resolve.
    final bloc = build(withHydration: false);
    addTearDown(bloc.close);

    items.add(const []);

    await expectLater(bloc.stream, emitsThrough(readyWith(isEmpty: isTrue)));
  });

  test('a failed hydrate marks the rows as possibly stale', () async {
    final bloc = build();
    addTearDown(bloc.close);

    items.add([upcoming('e-1')]);
    await settle();
    status.finished(EventHydrateOutcome.failed);

    await expectLater(
      bloc.stream,
      emitsThrough(readyWith(refreshFailed: isTrue)),
    );
  });

  test('a failing status stream leaves the rows up', () async {
    // The status annotates the list; losing it must not lose the list.
    final hydration = StreamController<EventHydration>();
    final bloc = EventOverviewBloc(
      repository: repository,
      hydration: hydration.stream,
      now: () => kNow,
    );
    addTearDown(() {
      unawaited(hydration.close());
      return bloc.close();
    });

    items.add([upcoming('e-1')]);
    await settle();
    hydration.addError(StateError('status failed'));
    await settle();

    expect(bloc.state, readyWith(upcoming: ['e-1']));
  });

  test('regroups against the clock at each emission', () async {
    // An event that ends while the overview is open moves to Past on the
    // next cache emission. Nothing writes to the cache when time passes, so
    // the rows can't say so; each grouping reads the clock instead.
    var clock = kNow;
    final bloc = build(now: () => clock);
    addTearDown(bloc.close);
    final rows = [
      item(
        'e-1',
        occurrences: [
          confirmed(
            'o-1',
            DateTime.utc(2026, 10, 23, 17),
            end: DateTime.utc(2026, 10, 23, 19),
          ),
        ],
      ),
    ];

    items.add(rows);
    await settle();
    expect(bloc.state, readyWith(upcoming: ['e-1']));

    clock = DateTime.utc(2026, 10, 23, 20);
    items.add(rows);
    await settle();

    expect(
      bloc.state,
      isA<EventOverviewReady>()
          .having((s) => s.groups.upcoming, 'upcoming', isEmpty)
          .having((s) => s.groups.past.map((r) => r.event.id), 'past', ['e-1']),
    );
  });

  group('the households', () {
    String? householdNameOf(EventOverviewState state) =>
        (state as EventOverviewReady).groups.upcoming.single.householdName;

    test('name a household once the households stream emits', () async {
      final households = StreamController<List<Household>>();
      addTearDown(households.close);
      final bloc = build(households: households.stream);
      addTearDown(bloc.close);

      // Never waited on: the rows are up before any name is known.
      items.add([upcoming('e-1', householdId: 'h-1')]);
      await settle();
      expect(householdNameOf(bloc.state), isNull);

      households.add([_household('h-1', 'The Smiths')]);
      await settle();

      expect(householdNameOf(bloc.state), 'The Smiths');
    });

    test('a households stream error leaves the rows as they were', () async {
      final households = StreamController<List<Household>>();
      addTearDown(households.close);
      final bloc = build(households: households.stream);
      addTearDown(bloc.close);

      items.add([upcoming('e-1', householdId: 'h-1')]);
      households.add([_household('h-1', 'The Smiths')]);
      await settle();
      households.addError(StateError('households failed'));
      await settle();

      expect(bloc.state, readyWith(upcoming: ['e-1']));
      expect(householdNameOf(bloc.state), 'The Smiths');
    });

    test('no households stream still reaches ready', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.add([upcoming('e-1', householdId: 'h-1')]);
      await settle();

      expect(bloc.state, readyWith(upcoming: ['e-1']));
      expect(householdNameOf(bloc.state), isNull);
    });
  });

  group('when the cache read fails', () {
    test('surfaces an error state', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.addError(StateError('no authenticated user'));

      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewError>()));
    });

    test('the next rows recover the screen', () async {
      // Drift keeps a stream open after a failed query, so real rows can
      // follow an error on the same subscription.
      final bloc = build();
      addTearDown(bloc.close);

      items.addError(StateError('transient read failure'));
      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewError>()));

      items.add([upcoming('e-1')]);

      await expectLater(
        bloc.stream,
        emitsThrough(readyWith(upcoming: ['e-1'])),
      );
    });

    test('a hydrate result does not lift the error', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.addError(StateError('no authenticated user'));
      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewError>()));

      status.finished(EventHydrateOutcome.complete);
      await settle();

      expect(bloc.state, isA<EventOverviewError>());
    });

    test('a households update does not lift the error', () async {
      final households = StreamController<List<Household>>();
      addTearDown(households.close);
      final bloc = build(households: households.stream);
      addTearDown(bloc.close);

      items.addError(StateError('no authenticated user'));
      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewError>()));

      households.add([_household('h-1', 'The Smiths')]);
      await settle();

      expect(bloc.state, isA<EventOverviewError>());
    });
  });

  group('when the session scope tears down', () {
    // Teardown closes the stream rather than erroring it.

    test('a cache that ends before saying anything is an error', () async {
      final bloc = build();
      addTearDown(bloc.close);

      await items.close();

      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewError>()));
    });

    test("a hydrate result does not lift an ended cache's error", () async {
      // Nothing will answer on a closed stream, so a pass completing later
      // must not put the spinner back.
      final bloc = build();
      addTearDown(bloc.close);

      await items.close();
      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewError>()));

      status.finished(EventHydrateOutcome.complete);
      await settle();

      expect(bloc.state, isA<EventOverviewError>());
    });

    test('a cache that ends after emitting leaves the rows up', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.add([upcoming('e-1')]);
      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewReady>()));

      await items.close();
      await settle();

      expect(bloc.state, isA<EventOverviewReady>());
    });
  });

  test('closing stops listening to every source', () async {
    final households = StreamController<List<Household>>.broadcast();
    addTearDown(households.close);
    final bloc = build(households: households.stream);
    await bloc.close();

    items.add([upcoming('e-1')]);
    households.add([_household('h-1', 'The Smiths')]);
    status.finished(EventHydrateOutcome.complete);
    await settle();

    expect(bloc.state, isA<EventOverviewLoading>());
    expect(households.hasListener, isFalse);
  });

  group('a re-check of a confirmed answer', () {
    // Entering the overview runs a stale re-hydrate, so a pass over a list
    // that is already known is routine.

    test('a confirmed-empty list stays empty under the next pass', () async {
      final bloc = build();
      addTearDown(bloc.close);

      items.add(const []);
      status.finished(EventHydrateOutcome.complete);
      await settle();

      status.started();
      await settle();

      expect(bloc.state, readyWith(isEmpty: isTrue, refreshing: isFalse));
    });

    test('an empty list only a failure has seen is still unknown', () async {
      // A failure confirms nothing, so a pass over that emptiness is still
      // the first fill.
      final bloc = build();
      addTearDown(bloc.close);

      items.add(const []);
      status.finished(EventHydrateOutcome.failed);
      await settle();

      status.started();
      await settle();

      expect(bloc.state, isA<EventOverviewLoading>());
    });
  });

  group('an overview opened while a pass is running', () {
    // Entry, resume, reconnect and the sign-in hydrate all start passes, so
    // the overview often subscribes mid-pass and is replayed only `running`.

    test('knows an earlier pass confirmed the empty list', () async {
      status
        ..started()
        ..finished(EventHydrateOutcome.complete)
        ..started();
      final bloc = build();
      addTearDown(bloc.close);

      items.add(const []);
      await settle();

      expect(bloc.state, readyWith(isEmpty: isTrue));
    });

    test('knows an earlier pass failed', () async {
      status
        ..started()
        ..finished(EventHydrateOutcome.failed)
        ..started();
      final bloc = build();
      addTearDown(bloc.close);

      items.add([upcoming('e-1')]);
      await settle();

      expect(bloc.state, readyWith(refreshFailed: isTrue));
    });
  });

  group('a retry the user asked for', () {
    late Completer<void> pass;
    late int calls;

    setUp(() {
      pass = Completer<void>();
      calls = 0;
    });

    EventOverviewBloc buildWithRetry() => build(
      onRetry: () {
        calls++;
        return pass.future;
      },
    );

    Future<void> settleOnAFailedRefresh() async {
      items.add([upcoming('e-1')]);
      status.finished(EventHydrateOutcome.failed);
      await settle();
    }

    test('can retry where a pass was supplied', () {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      expect(bloc.canRetry, isTrue);
    });

    test('runs the pass once and says a refresh is happening', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      bloc.add(const EventOverviewRetryRequested());
      status.started();
      await settle();

      expect(calls, 1);
      // Still failed underneath: the rows are no fresher until the pass
      // lands. The screen shows the refreshing copy over it.
      expect(bloc.state, readyWith(refreshing: isTrue, refreshFailed: isTrue));

      pass.complete();
    });

    test('a pass nobody asked for is not narrated', () async {
      // Entry, reconnect and resume all start passes. Announcing them would
      // be noise on a screen that otherwise says nothing.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      status.started();
      await settle();

      expect(calls, isZero);
      expect(bloc.state, readyWith(refreshing: isFalse));
    });

    test(
      'a pass nobody asked for leaves the warning up until it lands',
      () async {
        // The rows are no fresher while it runs, and a banner that vanished
        // on start would take keyboard focus with it.
        final bloc = buildWithRetry();
        addTearDown(bloc.close);
        await settleOnAFailedRefresh();

        status.started();
        await settle();

        expect(bloc.state, readyWith(refreshFailed: isTrue));

        status.finished(EventHydrateOutcome.complete);
        await settle();

        expect(bloc.state, readyWith(refreshFailed: isFalse));
      },
    );

    test('a retry that fails again puts the banner back', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      bloc.add(const EventOverviewRetryRequested());
      status.started();
      await settle();
      status.finished(EventHydrateOutcome.failed);
      pass.complete();
      await settle();

      expect(bloc.state, readyWith(refreshing: isFalse, refreshFailed: isTrue));
    });

    test('a second press while one is running starts nothing', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      bloc.add(const EventOverviewRetryRequested());
      await settle();
      bloc.add(const EventOverviewRetryRequested());
      await settle();

      expect(calls, 1);

      pass.complete();
    });

    test(
      'a retry over an unconfirmed empty list goes back to loading',
      () async {
        // An empty cache with a pass running is unknown, not empty, so the
        // screen must not put "no events yet" under a refreshing banner.
        final bloc = buildWithRetry();
        addTearDown(bloc.close);
        items.add(const []);
        status.finished(EventHydrateOutcome.failed);
        await settle();

        bloc.add(const EventOverviewRetryRequested());
        status.started();
        await settle();

        expect(bloc.state, isA<EventOverviewLoading>());

        pass.complete();
      },
    );

    test('a retry from a failed read runs the pass', () async {
      // A hydrate pass writes to the tables the failed query reads, which
      // is what makes Drift run it again on the same subscription.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      items.addError(StateError('transient read failure'));
      await settle();

      bloc.add(const EventOverviewRetryRequested());
      await settle();

      expect(calls, 1);
      expect(bloc.state, isA<EventOverviewError>());

      items.add([upcoming('e-1')]);
      pass.complete();
      await settle();

      expect(bloc.state, readyWith(upcoming: ['e-1'], refreshing: isFalse));
    });

    test('a pass that throws still ends the refresh', () async {
      // Passes report failure through the status, not by throwing. If one
      // throws anyway, "refreshing" must not stick where nothing clears it.
      final bloc = build(onRetry: () => Future.error(StateError('escaped')));
      addTearDown(bloc.close);
      await settleOnAFailedRefresh();

      bloc.add(const EventOverviewRetryRequested());
      await settle();

      expect(bloc.state, readyWith(refreshing: isFalse));
    });

    test('is a no-op where no pass was supplied', () async {
      final bloc = build();
      addTearDown(bloc.close);
      items.add([upcoming('e-1')]);
      await expectLater(bloc.stream, emitsThrough(isA<EventOverviewReady>()));

      bloc.add(const EventOverviewRetryRequested());
      await settle();

      expect(bloc.canRetry, isFalse);
      expect(bloc.state, readyWith(refreshing: isFalse));
    });
  });

  group('values', () {
    test('states compare by value', () {
      // A bloc drops an emit equal to its current state, so re-deriving
      // the state the screen already shows does not rebuild it.
      expect(EventOverviewLoading(), EventOverviewLoading());
      expect(EventOverviewError(), EventOverviewError());
      expect(EventOverviewLoading(), isNot(EventOverviewError()));
      expect(
        EventOverviewReady(groups: groupEvents([upcoming('e-1')], now: kNow)),
        EventOverviewReady(groups: groupEvents([upcoming('e-1')], now: kNow)),
      );
    });

    test('events compare by value', () {
      final rows = [upcoming('e-1')];
      final households = [_household('h-1', 'The Smiths')];
      const reading = EventHydration();

      expect(EventOverviewCacheUpdated(rows), EventOverviewCacheUpdated(rows));
      expect(
        EventOverviewHouseholdsUpdated(households),
        EventOverviewHouseholdsUpdated(households),
      );
      expect(
        EventOverviewHydrationUpdated(reading),
        EventOverviewHydrationUpdated(reading),
      );
      expect(EventOverviewCacheFailed(), EventOverviewCacheFailed());
      expect(EventOverviewCacheFailed(), isNot(EventOverviewCacheEnded()));
    });
  });
}
