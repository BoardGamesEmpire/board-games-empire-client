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
}
