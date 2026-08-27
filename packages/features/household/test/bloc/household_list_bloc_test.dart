import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

Household _household(String id, {String name = 'Game Night'}) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  late _MockHouseholdRepository repository;
  late StreamController<List<Household>> households;
  late StreamController<HouseholdHydrationState> hydration;

  setUp(() {
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>();
    hydration = StreamController<HouseholdHydrationState>();
    when(repository.watchHouseholds).thenAnswer((_) => households.stream);
  });

  tearDown(() {
    // Deliberately not awaited. `close()` on a single-subscription
    // controller completes when its done event is *delivered*, so the
    // no-hydration case — where nothing ever listens to `hydration` —
    // would hang the teardown forever.
    unawaited(households.close());
    unawaited(hydration.close());
  });

  HouseholdListBloc build({bool withHydration = true}) => HouseholdListBloc(
    repository: repository,
    hydration: withHydration ? hydration.stream : null,
  );

  test('starts loading, before the cache has said anything', () {
    final bloc = build();
    addTearDown(bloc.close);

    expect(bloc.state, isA<HouseholdListLoading>());
  });

  test('shows rows as soon as the cache has them', () async {
    final bloc = build();
    addTearDown(bloc.close);

    hydration.add(HouseholdHydrationState.running);
    households.add([_household('h-1')]);

    // `emitsThrough`, not `emits`: bloc replays its initial state to the
    // first event it handles, so Loading precedes the answer here.
    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<HouseholdListReady>()
            .having((s) => s.households, 'households', hasLength(1))
            .having((s) => s.refreshFailed, 'refreshFailed', isFalse),
      ),
    );
  });

  test('an empty cache mid-hydrate is loading, not empty', () async {
    // The distinction #269 D1 exists for: watchHouseholds() emits the same
    // empty list for "no households" and "not hydrated yet".
    final bloc = build();
    addTearDown(bloc.close);

    hydration.add(HouseholdHydrationState.running);
    households.add(const []);
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state, isA<HouseholdListLoading>());
  });

  test('an empty cache is empty once the hydrate settles', () async {
    final bloc = build();
    addTearDown(bloc.close);

    hydration.add(HouseholdHydrationState.running);
    households.add(const []);
    await Future<void>.delayed(Duration.zero);
    hydration.add(HouseholdHydrationState.refreshed);

    await expectLater(
      bloc.stream,
      emits(
        isA<HouseholdListReady>().having(
          (s) => s.households,
          'households',
          isEmpty,
        ),
      ),
    );
  });

  test(
    'an empty cache with no hydration at all is empty, not loading',
    () async {
      // Absent status reads as idle (#269 D1) — web, and any composition
      // without a household client. A spinner there would never resolve.
      final bloc = build(withHydration: false);
      addTearDown(bloc.close);

      households.add(const []);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdListReady>().having(
            (s) => s.households,
            'households',
            isEmpty,
          ),
        ),
      );
    },
  );

  test('a populated cache is never hidden behind the hydrate', () async {
    // A returning user has rows before the drain finishes. Replacing them
    // with a spinner would be a regression on a working screen.
    final bloc = build();
    addTearDown(bloc.close);

    households.add([_household('h-1')]);
    hydration.add(HouseholdHydrationState.running);

    await expectLater(bloc.stream, emitsThrough(isA<HouseholdListReady>()));
    expect(bloc.state, isA<HouseholdListReady>());
  });

  test('a failed hydrate marks the rows as possibly stale', () async {
    final bloc = build();
    addTearDown(bloc.close);

    households.add([_household('h-1')]);
    await Future<void>.delayed(Duration.zero);
    hydration.add(HouseholdHydrationState.failed);

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<HouseholdListReady>().having(
          (s) => s.refreshFailed,
          'refreshFailed',
          isTrue,
        ),
      ),
    );
  });

  test(
    'a failed hydrate over an empty cache still says the list is empty',
    () async {
      // Both facts are true and the screen shows both: the banner qualifies
      // the emptiness rather than replacing it.
      final bloc = build();
      addTearDown(bloc.close);

      households.add(const []);
      hydration.add(HouseholdHydrationState.failed);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdListReady>()
              .having((s) => s.households, 'households', isEmpty)
              .having((s) => s.refreshFailed, 'refreshFailed', isTrue),
        ),
      );
    },
  );

  test('a stream error surfaces as an error state', () async {
    // watchHouseholds() delivers an unauthenticated read as a stream
    // ERROR, not an empty list (household_repository_impl.dart) — the one
    // case a bare StreamBuilder of rows would drop on the floor.
    final bloc = build();
    addTearDown(bloc.close);

    households.addError(StateError('no authenticated user'));

    await expectLater(bloc.stream, emitsThrough(isA<HouseholdListError>()));
  });

  test(
    'a cache error is not terminal — the next rows recover the screen',
    () async {
      // Drift adds a query error to its listener and KEEPS the stream open
      // (`stream_queries.dart` catch → `controller.addError`), and both
      // `yield*` and `WatchDisposal.untilDisposed` forward it without
      // terminating. So a transient read failure is followed by real data,
      // and stranding the screen on the error surface would need a route
      // re-push to clear.
      final bloc = build();
      addTearDown(bloc.close);

      households.addError(StateError('transient read failure'));
      await expectLater(bloc.stream, emitsThrough(isA<HouseholdListError>()));

      households.add([_household('h-1')]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdListReady>().having(
            (s) => s.households,
            'households',
            hasLength(1),
          ),
        ),
      );
    },
  );

  test('the error state is not undone by a later hydrate result', () async {
    final bloc = build();
    addTearDown(bloc.close);

    households.addError(StateError('no authenticated user'));
    await expectLater(bloc.stream, emitsThrough(isA<HouseholdListError>()));

    hydration.add(HouseholdHydrationState.refreshed);
    await Future<void>.delayed(Duration.zero);

    expect(bloc.state, isA<HouseholdListError>());
  });

  group('when the session scope tears down', () {
    // The teardown path is a stream CLOSE, not an error: `WatchDisposal`
    // closes every vended watch stream on dispose and documents that
    // subscribers see onDone, never onError. A bloc that only handles
    // errors is deaf to the ordinary end of the session.

    test(
      'a cache that ends before saying anything is an error, not empty',
      () async {
        // Nothing ever answered, so "you have no households" is a claim we
        // cannot back — and leaving the spinner up is a screen that never
        // resolves.
        final bloc = build();
        addTearDown(bloc.close);

        await households.close();

        await expectLater(bloc.stream, emitsThrough(isA<HouseholdListError>()));
      },
    );

    test('a cache that ends after emitting leaves the rows up', () async {
      // The rows were real when they arrived, and the auth redirect is
      // already popping this route. Replacing them with an error would be
      // a flash of failure on the way out.
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('h-1')]);
      await expectLater(bloc.stream, emitsThrough(isA<HouseholdListReady>()));

      await households.close();
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<HouseholdListReady>());
    });
  });

  test(
    'an error on the hydration stream does not take down the screen',
    () async {
      // Nothing errors this stream today. If something ever does, the list
      // it annotates is still readable.
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('h-1')]);
      await expectLater(bloc.stream, emitsThrough(isA<HouseholdListReady>()));

      hydration.addError(StateError('unexpected'));
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state, isA<HouseholdListReady>());
    },
  );

  test('closing stops listening to both sources', () async {
    final bloc = build();
    await bloc.close();

    households.add([_household('h-1')]);
    hydration.add(HouseholdHydrationState.refreshed);
    await Future<void>.delayed(Duration.zero);

    // No emit-after-close error, and the last state stands.
    expect(bloc.state, isA<HouseholdListLoading>());
  });

  group('a retry the user asked for (#300 D5, D6)', () {
    late Completer<void> pass;
    late int calls;

    setUp(() {
      pass = Completer<void>();
      calls = 0;
    });

    HouseholdListBloc buildWithRetry() => HouseholdListBloc(
      repository: repository,
      hydration: hydration.stream,
      onRetry: () {
        calls++;
        return pass.future;
      },
    );

    /// Rows on screen, and the last pass failed — the state the banner and
    /// its retry are shown in.
    Future<void> settleOnAFailedRefresh(HouseholdListBloc bloc) async {
      households.add([_household('h-1')]);
      hydration.add(HouseholdHydrationState.failed);
      await Future<void>.delayed(Duration.zero);
    }

    test('runs the pass and says a refresh is happening', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh(bloc);

      bloc.add(const HouseholdListRetryRequested());
      hydration.add(HouseholdHydrationState.running);
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(
        bloc.state,
        isA<HouseholdListReady>()
            .having((s) => s.refreshing, 'refreshing', isTrue)
            .having((s) => s.refreshFailed, 'refreshFailed', isFalse),
      );

      pass.complete();
    });

    test('a pass nobody asked for is not narrated', () async {
      // The reason `refreshing` is not simply `failed -> running`: the
      // #302 triggers (a connectivity edge, an app resume) produce exactly
      // that transition today, and a banner that announces work the user
      // did not ask for is noise on a screen that otherwise says nothing.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh(bloc);

      hydration.add(HouseholdHydrationState.running);
      await Future<void>.delayed(Duration.zero);

      expect(calls, isZero);
      expect(
        bloc.state,
        isA<HouseholdListReady>()
            .having((s) => s.refreshing, 'refreshing', isFalse)
            .having((s) => s.refreshFailed, 'refreshFailed', isFalse),
      );
    });

    test('a retry that fails again puts the banner back', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh(bloc);

      bloc.add(const HouseholdListRetryRequested());
      hydration.add(HouseholdHydrationState.running);
      await Future<void>.delayed(Duration.zero);

      hydration.add(HouseholdHydrationState.failed);
      pass.complete();
      await Future<void>.delayed(Duration.zero);

      expect(
        bloc.state,
        isA<HouseholdListReady>()
            .having((s) => s.refreshing, 'refreshing', isFalse)
            .having((s) => s.refreshFailed, 'refreshFailed', isTrue),
      );
    });

    test('a second press while one is still running starts nothing', () async {
      // `HouseholdHydrator.hydrate()` single-flights (#302 D3), so a second
      // call would join rather than duplicate the drain — but the button
      // should not be a way to queue passes either.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);
      await settleOnAFailedRefresh(bloc);

      bloc.add(const HouseholdListRetryRequested());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const HouseholdListRetryRequested());
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);

      pass.complete();
    });

    test('a retried EMPTY list goes back to loading, not to a banner over an '
        'emptiness nobody has confirmed', () async {
      // #269 D1 outranks the retry treatment here. An empty cache with a
      // pass running is unknown, not empty — so the screen must not put
      // "no households yet" under a refreshing banner. The spinner is the
      // feedback, exactly as it is on the detail screen's absent
      // household (#270).
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add(const []);
      hydration.add(HouseholdHydrationState.failed);
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state, isA<HouseholdListReady>());

      bloc.add(const HouseholdListRetryRequested());
      hydration.add(HouseholdHydrationState.running);
      await Future<void>.delayed(Duration.zero);

      expect(calls, 1);
      expect(bloc.state, isA<HouseholdListLoading>());

      hydration.add(HouseholdHydrationState.failed);
      pass.complete();
      await Future<void>.delayed(Duration.zero);

      expect(
        bloc.state,
        isA<HouseholdListReady>()
            .having((s) => s.households, 'households', isEmpty)
            .having((s) => s.refreshFailed, 'refreshFailed', isTrue)
            .having((s) => s.refreshing, 'refreshing', isFalse),
      );
    });

    test('a retry is a no-op where no pass was supplied', () async {
      // A container with no household client (#137) renders a banner-less
      // list; nothing should throw if an event reaches the bloc anyway.
      final bloc = build();
      addTearDown(bloc.close);
      households.add([_household('h-1')]);
      await expectLater(bloc.stream, emitsThrough(isA<HouseholdListReady>()));

      bloc.add(const HouseholdListRetryRequested());
      await Future<void>.delayed(Duration.zero);

      expect(
        bloc.state,
        isA<HouseholdListReady>().having(
          (s) => s.refreshing,
          'refreshing',
          isFalse,
        ),
      );
    });
  });
}
