import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

const _id = 'h-1';

Household _household(String id, {String name = 'Game Night'}) => Household(
  id: id,
  name: name,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _member(
  String userId, {
  HouseholdRole? role = HouseholdRole.householdMember,
  String householdId = _id,
  String? username,
  String? displayName,
}) => HouseholdMember(
  id: 'm-$userId',
  userId: userId,
  householdId: householdId,
  role: role,
  username: username,
  displayName: displayName,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  late _MockHouseholdRepository repository;
  late StreamController<List<Household>> households;
  late StreamController<List<HouseholdMember>> members;
  late HouseholdHydrationStatus status;

  /// For the tests about the stream itself: one that has not spoken yet, or
  /// that closes. A real status replays its reading the moment it is
  /// listened to.
  late StreamController<Hydration> hydration;

  setUp(() {
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>();
    members = StreamController<List<HouseholdMember>>();
    status = HouseholdHydrationStatus();
    hydration = StreamController<Hydration>();
    when(repository.watchHouseholds).thenAnswer((_) => households.stream);
    when(() => repository.watchMembers(_id)).thenAnswer((_) => members.stream);
    when(() => repository.getCurrentUserMember(_id)).thenAnswer(
      (_) async => _member('u-me', role: HouseholdRole.householdOwner),
    );
  });

  tearDown(() {
    // Deliberately not awaited, for the list bloc test's reason: `close()`
    // on a single-subscription controller completes when its done event is
    // delivered, so a controller nothing listened to would hang teardown.
    unawaited(households.close());
    unawaited(members.close());
    unawaited(status.close());
    unawaited(hydration.close());
  });

  /// A status call the bloc must hear before the cache's first answer goes
  /// before this, for the list bloc test's reason: the reading is then
  /// replayed on subscribe. Made after, it lands a turn later than a cache
  /// event added beside it, and the replayed `idle` answers first, which
  /// here also counts as the status's first word.
  HouseholdDetailBloc build({bool withHydration = true}) => HouseholdDetailBloc(
    householdId: _id,
    repository: repository,
    hydration: withHydration ? status.watch() : null,
  );

  /// Built on the raw [hydration] stream rather than a status.
  HouseholdDetailBloc buildOnRawStream() => HouseholdDetailBloc(
    householdId: _id,
    repository: repository,
    hydration: hydration.stream,
  );

  /// Drains the microtask queue so the `getCurrentUserMember` future and
  /// the events it schedules land before the assertion.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('starts loading, before anything has answered', () {
    final bloc = build();
    addTearDown(bloc.close);

    expect(bloc.state, isA<HouseholdDetailLoading>());
  });

  test('shows the household once both streams have answered', () async {
    final bloc = build();
    addTearDown(bloc.close);

    households.add([_household(_id)]);
    members.add([_member('u-me', role: HouseholdRole.householdOwner)]);

    await expectLater(
      bloc.stream,
      emitsThrough(
        isA<HouseholdDetailReady>()
            .having((s) => s.household.id, 'household.id', _id)
            .having((s) => s.memberCount, 'memberCount', 1)
            .having((s) => s.role, 'role', HouseholdRole.householdOwner)
            .having((s) => s.refreshFailed, 'refreshFailed', isFalse),
      ),
    );
  });

  test(
    'stays loading while the household is there but the roster is not',
    () async {
      // The count is part of what this screen exists to say. Rendering the
      // household with "no members" before the member stream has answered
      // would state something false about a household that always has at
      // least its owner.
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    },
  );

  test(
    'picks this household out of the list stream, ignoring others',
    () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('other'), _household(_id, name: 'Mine')]);
      members.add([_member('u-me')]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having(
            (s) => s.household.name,
            'household.name',
            'Mine',
          ),
        ),
      );
    },
  );

  group('not found', () {
    test(
      'a list without this id, with the hydrate settled, is not found',
      () async {
        status.finished(HydrateOutcome.complete);
        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household('other')]);

        await expectLater(
          bloc.stream,
          emitsThrough(isA<HouseholdDetailNotFound>()),
        );
      },
    );

    test('an absent household mid-hydrate is loading, not not-found', () async {
      // The same distinction #269 draws for the list, for the same reason:
      // a deep link can arrive while the cache is still filling, and "we
      // couldn't find this household" shown to someone who has it is the
      // failure #267 exists to fix.
      status.started();
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      members.add(const []);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test(
      'the same absence resolves to not-found when the hydrate settles',
      () async {
        status.started();
        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household('other')]);
        await settle();
        status.finished(HydrateOutcome.complete);

        await expectLater(
          bloc.stream,
          emitsThrough(isA<HouseholdDetailNotFound>()),
        );
      },
    );

    test(
      'a failed hydrate settles it too, and says the read was unverified',
      () async {
        // Waiting forever on a hydrate that already gave up would be a
        // spinner nothing resolves. Not-found is the honest answer the
        // repository contract gives; the banner says it could not be checked.
        status.finished(HydrateOutcome.failed);
        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household('other')]);

        await expectLater(
          bloc.stream,
          emitsThrough(
            isA<HouseholdDetailNotFound>().having(
              (s) => s.refreshFailed,
              'refreshFailed',
              isTrue,
            ),
          ),
        );
      },
    );

    test(
      'no hydration stream at all reads as settled, not as filling',
      () async {
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);

        households.add([_household('other')]);

        await expectLater(
          bloc.stream,
          emitsThrough(isA<HouseholdDetailNotFound>()),
        );
      },
    );

    test('a household that disappears mid-session becomes not found', () async {
      // Removed on another device, or tombstoned: the membership gate
      // drops it from the stream and the open screen must not keep
      // showing it.
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);
      await settle();
      households.add(const []);

      await expectLater(
        bloc.stream,
        emitsThrough(isA<HouseholdDetailNotFound>()),
      );
    });
  });

  group('the current user role', () {
    test('is read off the roster, so a role change flows through', () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me', role: HouseholdRole.householdMember)]);
      await settle();
      members.add([_member('u-me', role: HouseholdRole.householdAdmin)]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having(
            (s) => s.role,
            'role',
            HouseholdRole.householdAdmin,
          ),
        ),
      );
    });

    test('resolves on the deep-link path, where the cache was cold when we '
        'first asked', () async {
      // The path this bloc exists for. `getCurrentUserMember` reads the
      // local cache, so on a cold start it answers null — there are no
      // member rows yet. Latching that null for the life of the screen
      // leaves "Your role" silently missing even after the hydrate lands
      // the roster with our row in it.
      HouseholdMember? cached;
      when(() => repository.getCurrentUserMember(_id))
          .thenAnswer((_) async => cached);

      final bloc = build();
      addTearDown(bloc.close);

      status.started();
      await settle();

      // The drain lands: household, then members, and now the cache can
      // answer who we are.
      cached = _member('u-me', role: HouseholdRole.householdOwner);
      households.add([_household(_id)]);
      members.add([
        _member('u-me', role: HouseholdRole.householdOwner),
        _member('u-2'),
      ]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>()
              .having((s) => s.memberCount, 'memberCount', 2)
              .having((s) => s.role, 'role', HouseholdRole.householdOwner),
        ),
      );
    });

    test('asks again only while we are still unidentified', () async {
      // Bounded: the retry is driven by roster emissions and stops the
      // moment an answer arrives, so it cannot become a query per tick.
      HouseholdMember? cached;
      when(() => repository.getCurrentUserMember(_id))
          .thenAnswer((_) async => cached);

      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      cached = _member('u-me');
      members.add([_member('u-me')]);
      await settle();
      members.add([_member('u-me'), _member('u-2')]);
      await settle();
      members.add([_member('u-me'), _member('u-2'), _member('u-3')]);
      await settle();

      // Construction, plus one retry that succeeded. The two later
      // emissions ask nothing.
      verify(() => repository.getCurrentUserMember(_id)).called(2);
    });

    test('is null when the roster carries no role binding for us', () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me', role: null)]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having((s) => s.role, 'role', isNull),
        ),
      );
    });

    test(
      'survives getCurrentUserMember returning null — the screen still renders',
      () async {
        when(() => repository.getCurrentUserMember(_id))
            .thenAnswer((_) async => null);
        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household(_id)]);
        members.add([_member('u-other')]);

        await expectLater(
          bloc.stream,
          emitsThrough(
            isA<HouseholdDetailReady>()
                .having((s) => s.role, 'role', isNull)
                .having((s) => s.memberCount, 'memberCount', 1),
          ),
        );
      },
    );

    test('survives getCurrentUserMember throwing', () async {
      when(() => repository.getCurrentUserMember(_id))
          .thenThrow(StateError('disposed'));
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having((s) => s.role, 'role', isNull),
        ),
      );
    });
  });

  group('the roster (#304)', () {
    Future<HouseholdDetailReady> readyWith(List<HouseholdMember> roster) async {
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add(roster);

      return await bloc.stream.firstWhere((s) => s is HouseholdDetailReady)
          as HouseholdDetailReady;
    }

    test('orders the roster by role, then by name ignoring case', () async {
      final ready = await readyWith([
        _member('u-1', displayName: 'bea'),
        _member('u-2', role: HouseholdRole.householdOwner, displayName: 'Zed'),
        _member('u-3', username: 'Ann'),
        _member('u-4', role: HouseholdRole.householdAdmin, username: 'carl'),
      ]);

      expect(ready.members.map((m) => m.userId), ['u-2', 'u-4', 'u-3', 'u-1']);
      expect(ready.memberCount, 4);
    });

    test('nameless members follow the named ones in their role', () async {
      // Two nameless members compare equal on name, so the user id settles
      // them, and the order never depends on how the cache returned them.
      final ready = await readyWith([
        _member('u-3'),
        _member('u-2', username: 'zed'),
        _member('u-1'),
      ]);

      expect(ready.members.map((m) => m.userId), ['u-2', 'u-1', 'u-3']);
    });

    test('a member with no role sorts after every role', () async {
      final ready = await readyWith([
        _member('u-1', role: null, username: 'ann'),
        _member('u-2', role: HouseholdRole.unknown, username: 'bea'),
        _member('u-3', role: HouseholdRole.householdGuest, username: 'cy'),
      ]);

      expect(ready.members.map((m) => m.userId), ['u-3', 'u-2', 'u-1']);
    });

    test("carries the current user's id", () async {
      final ready = await readyWith([_member('u-me')]);

      expect(ready.currentUserId, 'u-me');
    });

    test('a member renamed in the cache re-emits the roster', () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me', displayName: 'Alex')]);
      await settle();
      members.add([_member('u-me', displayName: 'Alexandra')]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having(
            (s) => s.members.single.name,
            'members.single.name',
            'Alexandra',
          ),
        ),
      );
    });
  });

  group('races the review found', () {
    test('an absent household before the hydrate has said anything holds, '
        'rather than reporting not-found', () async {
      // `watchHouseholds()` is subscribed before the hydration stream, and
      // both deliver asynchronously. If the cache answers "absent" before
      // the status stream replays its current value, `_hydrationState` is
      // still its `idle` default — which reads as settled — and the screen
      // flashes not-found on its way to the content.
      final bloc = buildOnRawStream();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test('and reports it once the hydrate does speak', () async {
      final bloc = buildOnRawStream();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      await settle();
      hydration.add(
        const Hydration(state: HydrationState.refreshed, everRefreshed: true),
      );

      await expectLater(
        bloc.stream,
        emitsThrough(isA<HouseholdDetailNotFound>()),
      );
    });

    test('a hydration stream that closes without ever speaking still '
        'settles', () async {
      // The wait above must not become the spinner it was added to avoid.
      final bloc = buildOnRawStream();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      await settle();
      await hydration.close();
      await settle();

      expect(bloc.state, isA<HouseholdDetailNotFound>());
    });

    test('a roster arriving while the identity query is still open is not '
        'lost to the in-flight guard', () async {
      // The retry added for the cold-cache path is dropped when the
      // constructor's query has not returned yet — and since the roster is
      // stable once hydration lands, nothing asks again. The role goes
      // missing for the life of the screen, which is the exact symptom the
      // retry exists to prevent.
      var calls = 0;
      final firstQuery = Completer<void>();
      HouseholdMember? cached;
      when(() => repository.getCurrentUserMember(_id)).thenAnswer((_) async {
        calls++;
        if (calls == 1) {
          // Ran against the cold cache, and still open when the roster
          // lands.
          await firstQuery.future;
          return null;
        }
        return cached;
      });

      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me', role: HouseholdRole.householdOwner)]);
      await settle();

      // The hydrate has now written our row; the first query returns the
      // null it read before that.
      cached = _member('u-me', role: HouseholdRole.householdOwner);
      firstQuery.complete();

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having(
            (s) => s.role,
            'role',
            HouseholdRole.householdOwner,
          ),
        ),
      );
    });

    test(
      'a dropped retry does not re-ask forever once we are identified',
      () async {
        var calls = 0;
        final firstQuery = Completer<void>();
        when(() => repository.getCurrentUserMember(_id)).thenAnswer((_) async {
          calls++;
          if (calls == 1) {
            await firstQuery.future;
            return null;
          }
          return _member('u-me');
        });

        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household(_id)]);
        members.add([_member('u-me')]);
        await settle();
        firstQuery.complete();
        await settle();
        members.add([_member('u-me'), _member('u-2')]);
        await settle();

        // The dropped retry is honoured once; the later emission asks
        // nothing because we are identified by then.
        expect(calls, 2);
      },
    );
  });

  group('the roster gate', () {
    test('an empty roster under a visible household holds, rather than '
        'claiming nobody is in it', () async {
      // The household and its roster arrive on separate streams, so the
      // household can be visible while the roster is still `const []`.
      // Rendering "No members" there states something false about a
      // household that always has at least its owner.
      status.started();
      final bloc = build();
      addTearDown(bloc.close);

      members.add(const []);
      households.add([_household(_id)]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test('and gives up holding once the pass settles', () async {
      // Bounded by the same signal the absent-household branch uses: an
      // empty roster nothing is going to fill is rendered, not spun on.
      status.started();
      final bloc = build();
      addTearDown(bloc.close);

      members.add(const []);
      households.add([_household(_id)]);
      await settle();
      status.finished(HydrateOutcome.complete);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having(
            (s) => s.memberCount,
            'memberCount',
            0,
          ),
        ),
      );
    });

    test('does not hold where there is no hydrate to wait for', () async {
      final bloc = build(withHydration: false);
      addTearDown(bloc.close);

      members.add(const []);
      households.add([_household(_id)]);

      await expectLater(bloc.stream, emitsThrough(isA<HouseholdDetailReady>()));
    });
  });

  group('staleness', () {
    test(
      'a failed hydrate annotates the household rather than hiding it',
      () async {
        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household(_id)]);
        members.add([_member('u-me')]);
        await settle();
        status.finished(HydrateOutcome.failed);

        await expectLater(
          bloc.stream,
          emitsThrough(
            isA<HouseholdDetailReady>().having(
              (s) => s.refreshFailed,
              'refreshFailed',
              isTrue,
            ),
          ),
        );
      },
    );

    test('a refreshed pass does not read as a failed one', () async {
      status.finished(HydrateOutcome.complete);
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having(
            (s) => s.refreshFailed,
            'refreshFailed',
            isFalse,
          ),
        ),
      );
    });
  });

  group('the read failing', () {
    test('an errored household stream is the error state', () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.addError(StateError('unauthenticated'));

      await expectLater(bloc.stream, emitsThrough(isA<HouseholdDetailError>()));
    });

    test('an errored member stream is the error state', () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.addError(StateError('unauthenticated'));

      await expectLater(bloc.stream, emitsThrough(isA<HouseholdDetailError>()));
    });

    test('a hydrate result does not lift an error', () async {
      // Only fresh rows prove the stream recovered. Letting an annotation
      // clear the error would show a household nobody could read.
      final bloc = build();
      addTearDown(bloc.close);

      households.addError(StateError('unauthenticated'));
      await settle();
      status.finished(HydrateOutcome.complete);
      await settle();

      expect(bloc.state, isA<HouseholdDetailError>());
    });

    test('fresh rows do lift it', () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.addError(StateError('unauthenticated'));
      await settle();
      households.add([_household(_id)]);
      members.add([_member('u-me')]);

      await expectLater(bloc.stream, emitsThrough(isA<HouseholdDetailReady>()));
    });

    test('an emission on one stream does not clear the other stream\'s '
        'failure', () async {
      // The two streams fail independently. Treating them as one flag let
      // a household emission clear a member-stream failure and drop the
      // screen into a spinner that nothing could ever resolve — the
      // roster it was waiting on had already errored.
      final bloc = build();
      addTearDown(bloc.close);

      members.addError(StateError('unauthenticated'));
      await settle();
      expect(bloc.state, isA<HouseholdDetailError>());

      households.add([_household(_id)]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailError>());
    });

    test('recovery takes both streams, not either one', () async {
      final bloc = build();
      addTearDown(bloc.close);

      members.addError(StateError('unauthenticated'));
      await settle();
      households.add([_household(_id)]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailError>());

      members.add([_member('u-me')]);

      await expectLater(bloc.stream, emitsThrough(isA<HouseholdDetailReady>()));
    });

    test('a roster stream that closes before answering is an error, not a '
        'spinner', () async {
      // Session teardown mid-first-read. The household arrived, the
      // roster never will, and a loading state here is permanent.
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailLoading>());

      await members.close();
      await settle();

      expect(bloc.state, isA<HouseholdDetailError>());
    });

    test(
      'a hydration stream that closes mid-pass settles the absence',
      () async {
        // `running` is the last thing a closed status stream ever said, so
        // waiting for it to settle waits forever.
        final bloc = buildOnRawStream();
        addTearDown(bloc.close);

        hydration.add(const Hydration(state: HydrationState.running));
        households.add(const []);
        members.add(const []);
        await settle();
        expect(bloc.state, isA<HouseholdDetailLoading>());

        await hydration.close();
        await settle();

        expect(bloc.state, isA<HouseholdDetailNotFound>());
      },
    );

    test(
      'a stream that closes having said nothing is the error state',
      () async {
        // Session teardown: WatchDisposal closes vended streams rather than
        // erroring them. Nothing answered, and nothing will.
        final bloc = build();
        addTearDown(bloc.close);

        await households.close();

        await expectLater(
          bloc.stream,
          emitsThrough(isA<HouseholdDetailError>()),
        );
      },
    );

    test(
      'a stream that closes after answering freezes what it showed',
      () async {
        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household(_id)]);
        members.add([_member('u-me')]);
        await settle();
        expect(bloc.state, isA<HouseholdDetailReady>());

        await households.close();
        await settle();

        expect(bloc.state, isA<HouseholdDetailReady>());
      },
    );
  });

  test('cancels both subscriptions on close', () async {
    final bloc = build();

    await bloc.close();

    expect(households.hasListener, isFalse);
    expect(members.hasListener, isFalse);
  });

  group('a retry the user asked for (#300 D5, D6, D10)', () {
    late Completer<void> pass;
    late int calls;

    setUp(() {
      pass = Completer<void>();
      calls = 0;
    });

    HouseholdDetailBloc buildWithRetry() => HouseholdDetailBloc(
      householdId: _id,
      repository: repository,
      hydration: status.watch(),
      onRetry: () {
        calls++;
        return pass.future;
      },
    );

    test('runs the pass and says a refresh is happening', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);
      status.finished(HydrateOutcome.failed);
      await settle();

      bloc.add(const HouseholdDetailRetryRequested());
      status.started();
      await settle();

      expect(calls, 1);
      // Still failed underneath: the rows are no fresher until the pass
      // lands (#453). The screen shows the refreshing copy over it.
      expect(
        bloc.state,
        isA<HouseholdDetailReady>()
            .having((s) => s.refreshing, 'refreshing', isTrue)
            .having((s) => s.refreshFailed, 'refreshFailed', isTrue),
      );

      pass.complete();
    });

    test('a pass nobody asked for keeps the banner up', () async {
      // #302's triggers produce failed -> running without anyone pressing
      // anything, and the screen does not narrate those. But the rows are
      // no fresher while one runs, and a banner that vanished on start
      // would take a focused retry with it (#453). So the warning stays,
      // unnarrated, until a pass lands.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);
      status.finished(HydrateOutcome.failed);
      await settle();

      status.started();
      await settle();

      expect(calls, isZero);
      expect(
        bloc.state,
        isA<HouseholdDetailReady>()
            .having((s) => s.refreshing, 'refreshing', isFalse)
            .having((s) => s.refreshFailed, 'refreshFailed', isTrue),
      );
    });

    test('an unverified absence can be retried too (#300 D10)', () async {
      // The surface a retry is worth the most on: a household missing from
      // a cache whose last pass failed may well exist on the server. The
      // failure goes first: a status replays its reading on subscribe, and
      // the replay is the first word the absence waits for.
      status.finished(HydrateOutcome.failed);
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add(const []);
      members.add(const []);
      await settle();

      expect(bloc.state, isA<HouseholdDetailNotFound>());

      bloc.add(const HouseholdDetailRetryRequested());
      status.started();
      await settle();

      expect(calls, 1);
      // While the pass runs this surface is the spinner (#270): an absence
      // no pass has confirmed is unknown rather than missing, so the screen
      // stops claiming the household is gone while it is being looked for.
      expect(bloc.state, isA<HouseholdDetailLoading>());

      status.finished(HydrateOutcome.failed);
      pass.complete();
      await settle();

      expect(
        bloc.state,
        isA<HouseholdDetailNotFound>().having(
          (s) => s.refreshFailed,
          'refreshFailed',
          isTrue,
        ),
      );
    });

    group('on an absence an earlier pass confirmed', () {
      // The pass a press runs does not put this page back on the spinner,
      // because the absence is already an answer, and the failure the last
      // pass left keeps the banner up through it (#453). So the not-found
      // page has to narrate the press itself, or it shows nothing and a
      // second press is dropped unseen. The status is driven before the
      // bloc is built, so its history is the replayed reading.

      Future<HouseholdDetailBloc> openOnTheAbsence() async {
        status
          ..started()
          ..finished(HydrateOutcome.complete)
          ..started()
          ..finished(HydrateOutcome.failed);
        final bloc = buildWithRetry();
        addTearDown(bloc.close);

        households.add(const []);
        await settle();
        expect(
          bloc.state,
          isA<HouseholdDetailNotFound>()
              .having((s) => s.refreshFailed, 'refreshFailed', isTrue)
              .having((s) => s.refreshing, 'refreshing', isFalse),
        );
        return bloc;
      }

      Future<void> pressDuringItsPass(HouseholdDetailBloc bloc) async {
        bloc.add(const HouseholdDetailRetryRequested());
        status.started();
        await settle();
        bloc.add(const HouseholdDetailRetryRequested());
        await settle();
      }

      test('a retry says it is refreshing, and runs once', () async {
        final bloc = await openOnTheAbsence();

        await pressDuringItsPass(bloc);

        expect(calls, 1);
        expect(
          bloc.state,
          isA<HouseholdDetailNotFound>()
              .having((s) => s.refreshFailed, 'refreshFailed', isTrue)
              .having((s) => s.refreshing, 'refreshing', isTrue),
        );

        status.finished(HydrateOutcome.complete);
        pass.complete();
        await settle();

        expect(
          bloc.state,
          isA<HouseholdDetailNotFound>()
              .having((s) => s.refreshFailed, 'refreshFailed', isFalse)
              .having((s) => s.refreshing, 'refreshing', isFalse),
        );
      });

      test('a retry that fails again offers the retry again', () async {
        final bloc = await openOnTheAbsence();

        await pressDuringItsPass(bloc);
        expect(
          bloc.state,
          isA<HouseholdDetailNotFound>().having(
            (s) => s.refreshing,
            'refreshing',
            isTrue,
          ),
        );

        status.finished(HydrateOutcome.failed);
        pass.complete();
        await settle();

        expect(
          bloc.state,
          isA<HouseholdDetailNotFound>()
              .having((s) => s.refreshFailed, 'refreshFailed', isTrue)
              .having((s) => s.refreshing, 'refreshing', isFalse),
        );
      });
    });

    test('a second press while one is still running starts nothing', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);
      status.finished(HydrateOutcome.failed);
      await settle();

      bloc.add(const HouseholdDetailRetryRequested());
      await settle();
      bloc.add(const HouseholdDetailRetryRequested());
      await settle();

      expect(calls, 1);

      pass.complete();
    });
  });

  group('a confirmed-absent household survives a re-check (#300 D16)', () {
    test('an absence a pass has confirmed stays not-found under the next '
        'pass', () async {
      // The detail half of #300 D16. #270's rule is that an absence with a
      // pass running is *unknown* rather than missing — true while nothing
      // has confirmed it, and #300 D15 makes re-checks routine enough that
      // re-confirming a known absence must not flash a spinner over the
      // not-found page on every resume.
      status.finished(HydrateOutcome.complete);
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailNotFound>());

      status.started();
      await settle();

      expect(bloc.state, isA<HouseholdDetailNotFound>());
    });

    test('an absence only a failure has seen is still unknown', () async {
      // Unchanged from #270: a failed pass confirms nothing, so a pass over
      // an unverified absence is still the spinner.
      status.finished(HydrateOutcome.failed);
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailNotFound>());

      status.started();
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test('a household that was shown and then vanished still waits on a '
        'running pass', () async {
      // The branch #300 D16 deliberately does NOT touch. Once the household
      // has been rendered, a pass in flight may be rewriting the very rows
      // this screen reads, so its disappearance mid-pass is not yet an
      // answer — #270's reasoning, unchanged.
      status.finished(HydrateOutcome.complete);
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me', role: HouseholdRole.householdOwner)]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailReady>());

      // The pass is running before the household leaves. A status call lands
      // a turn after a cache event added beside it, hence the settle.
      status.started();
      await settle();
      households.add([_household('other')]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test(
      'the household arriving after a confirmed absence still renders',
      () async {
        status.finished(HydrateOutcome.complete);
        final bloc = build();
        addTearDown(bloc.close);

        households.add([_household('other')]);
        await settle();

        // The re-check is running before the household arrives. A status
        // call lands a turn after a cache event added beside it, hence the
        // settle.
        status.started();
        await settle();
        households.add([_household(_id)]);
        members.add([_member('u-me', role: HouseholdRole.householdOwner)]);
        await settle();

        expect(bloc.state, isA<HouseholdDetailReady>());
      },
    );
  });

  group('a detail opened while a pass is running', () {
    // Entering the household section starts a pass once the data is stale,
    // and resume, reconnect and the sign-in drain all start one, so this
    // screen often subscribes mid-pass and sees no earlier pass finish
    // (#453). The status is driven before the bloc is built, so what it
    // says arrives as the reading replayed on subscribe.

    test('shows not-found for an absence an earlier pass confirmed', () async {
      status
        ..started()
        ..finished(HydrateOutcome.complete)
        ..started();
      final bloc = build();
      addTearDown(bloc.close);

      households.add(const []);
      await settle();

      expect(
        bloc.state,
        isA<HouseholdDetailNotFound>().having(
          (s) => s.refreshFailed,
          'refreshFailed',
          isFalse,
        ),
      );
    });

    test('shows the stale banner when the last pass failed', () async {
      status
        ..started()
        ..finished(HydrateOutcome.failed)
        ..started();
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);
      await settle();

      expect(
        bloc.state,
        isA<HouseholdDetailReady>().having(
          (s) => s.refreshFailed,
          'refreshFailed',
          isTrue,
        ),
      );
    });
  });

  group('a household reconciled onto a new id (#306)', () {
    // A queued create reconciling while this screen is open, or before it
    // was rebuilt: the repository moves the household from the local id
    // this screen was built with onto the server's id, and records where
    // it went. The optimistic row is gone, so without following that
    // record the screen would report a household it is showing as missing.
    const serverId = 'hh_server';
    late StreamController<List<HouseholdMember>> serverMembers;
    String? reconciledTo;

    setUp(() {
      reconciledTo = null;
      serverMembers = StreamController<List<HouseholdMember>>();
      when(() => repository.reconciledHouseholdId(_id))
          .thenAnswer((_) => reconciledTo);
      when(() => repository.watchMembers(serverId))
          .thenAnswer((_) => serverMembers.stream);
      when(() => repository.getCurrentUserMember(serverId)).thenAnswer(
        (_) async => _member(
          'u-me',
          role: HouseholdRole.householdOwner,
          householdId: serverId,
        ),
      );
    });

    tearDown(() => unawaited(serverMembers.close()));

    final ownerOnServerId = isA<HouseholdDetailReady>()
        .having((s) => s.household.id, 'household.id', serverId)
        .having((s) => s.memberCount, 'memberCount', 1)
        .having((s) => s.role, 'role', HouseholdRole.householdOwner);

    Future<List<HouseholdDetailState>> openAndRender(
      HouseholdDetailBloc bloc,
    ) async {
      final states = <HouseholdDetailState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);
      households.add([_household(_id)]);
      members.add([_member('u-me', role: HouseholdRole.householdOwner)]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailReady>());
      states.clear();
      return states;
    }

    test('an open screen keeps the household rendered, under the new id, '
        'when the old roster empties first', () async {
      final bloc = build(withHydration: false);
      addTearDown(bloc.close);
      final states = await openAndRender(bloc);

      reconciledTo = serverId;
      members.add(const []);
      households.add([_household(serverId)]);
      serverMembers.add([
        _member(
          'u-me',
          role: HouseholdRole.householdOwner,
          householdId: serverId,
        ),
      ]);
      await settle();

      expect(states, isNotEmpty);
      expect(states, everyElement(isA<HouseholdDetailReady>()));
      expect(
        bloc.state,
        isA<HouseholdDetailReady>()
            .having((s) => s.household.id, 'household.id', serverId)
            .having((s) => s.memberCount, 'memberCount', 1)
            .having((s) => s.role, 'role', HouseholdRole.householdOwner),
      );
    });

    test('an open screen keeps the household rendered when the household '
        'list answers first, and ignores the old roster emptying', () async {
      final bloc = build(withHydration: false);
      addTearDown(bloc.close);
      final states = await openAndRender(bloc);

      reconciledTo = serverId;
      households.add([_household(serverId)]);
      members.add(const []);
      await settle();

      expect(states, everyElement(isA<HouseholdDetailReady>()));
      expect(
        bloc.state,
        isA<HouseholdDetailReady>()
            .having((s) => s.household.id, 'household.id', serverId)
            .having((s) => s.memberCount, 'memberCount', 1),
      );
    });

    test(
      'a screen built on the old id afterwards renders the household',
      () async {
        reconciledTo = serverId;
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);

        households.add([_household(serverId)]);
        serverMembers.add([
          _member(
            'u-me',
            role: HouseholdRole.householdOwner,
            householdId: serverId,
          ),
        ]);

        await expectLater(
          bloc.stream,
          emitsThrough(
            isA<HouseholdDetailReady>()
                .having((s) => s.household.id, 'household.id', serverId)
                .having((s) => s.role, 'role', HouseholdRole.householdOwner),
          ),
        );
      },
    );

    test('recovers on the household emission that follows the record, if '
        'both streams answered before it existed', () async {
      // Hearing the local row vanish, and the old roster empty, before the
      // record exists reads as a removal. The repository reads the moves
      // before delivering a household emission (#442), so it no longer
      // delivers this order, but any later emission that carries the move
      // corrects it.
      final bloc = build(withHydration: false);
      addTearDown(bloc.close);
      await openAndRender(bloc);

      households.add([_household(serverId)]);
      members.add(const []);
      await expectLater(
        bloc.stream,
        emitsThrough(isA<HouseholdDetailNotFound>()),
      );

      reconciledTo = serverId;
      households.add([_household(serverId)]);
      serverMembers.add([
        _member(
          'u-me',
          role: HouseholdRole.householdOwner,
          householdId: serverId,
        ),
      ]);

      await expectLater(
        bloc.stream,
        emitsThrough(
          isA<HouseholdDetailReady>().having(
            (s) => s.household.id,
            'household.id',
            serverId,
          ),
        ),
      );
    });

    test('a failure on the old roster, queued before the move, is not the '
        "new roster's failure", () async {
      final bloc = build(withHydration: false);
      addTearDown(bloc.close);
      final states = await openAndRender(bloc);

      reconciledTo = serverId;
      households.add([_household(serverId)]);
      members.addError(StateError('old roster'));
      await settle();

      expect(states, isNot(contains(isA<HouseholdDetailError>())));
      expect(
        bloc.state,
        isA<HouseholdDetailReady>().having(
          (s) => s.household.id,
          'household.id',
          serverId,
        ),
      );
    });

    test('a failure on the old roster, handled before anything else after '
        "the move, is not the new roster's failure", () async {
      // The failure is the first event after the record, so it is the one
      // that has to make the move before judging whose failure it is.
      final bloc = build(withHydration: false);
      addTearDown(bloc.close);
      final states = await openAndRender(bloc);

      reconciledTo = serverId;
      members.addError(StateError('old roster'));
      households.add([_household(serverId)]);
      serverMembers.add([
        _member(
          'u-me',
          role: HouseholdRole.householdOwner,
          householdId: serverId,
        ),
      ]);
      await settle();

      expect(states, isNot(contains(isA<HouseholdDetailError>())));
      expect(
        bloc.state,
        isA<HouseholdDetailReady>().having(
          (s) => s.household.id,
          'household.id',
          serverId,
        ),
      );
    });

    group('on a repository that has not read the move yet (#442)', () {
      // Another tab's repository learns of a move when its streams next
      // read, so a screen built there on the old id asks who we are about
      // the old id, whose rows the reconcile moved away. That answer must
      // not be the role the first paint shows.
      Future<List<HouseholdDetailState>> moveAndRender(
        HouseholdDetailBloc bloc,
      ) async {
        final states = <HouseholdDetailState>[];
        final sub = bloc.stream.listen(states.add);
        addTearDown(sub.cancel);
        reconciledTo = serverId;
        households.add([_household(serverId)]);
        serverMembers.add([
          _member(
            'u-me',
            role: HouseholdRole.householdOwner,
            householdId: serverId,
          ),
        ]);
        await settle();
        return states;
      }

      test('first paints the role, when the old id was asked about before '
          'the move', () async {
        when(() => repository.getCurrentUserMember(_id))
            .thenAnswer((_) async => null);
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);
        await settle();

        final states = await moveAndRender(bloc);

        expect(states.whereType<HouseholdDetailReady>(), [ownerOnServerId]);
      });

      test('first paints the role, when the answer about the old id lands '
          'after the move', () async {
        final oldIdAnswer = Completer<HouseholdMember?>();
        when(() => repository.getCurrentUserMember(_id))
            .thenAnswer((_) => oldIdAnswer.future);
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);

        final states = await moveAndRender(bloc);
        oldIdAnswer.complete(null);
        await settle();

        expect(states.whereType<HouseholdDetailReady>(), [ownerOnServerId]);
      });

      test(
        'keeps an answer that names us, though it was about the old id',
        () async {
          // Who we are does not depend on the id asked about; only "no row
          // of ours" does. So an answer naming us still counts once the
          // screen has moved, even when asking about the new id finds nothing.
          final oldIdAnswer = Completer<HouseholdMember?>();
          when(() => repository.getCurrentUserMember(_id))
              .thenAnswer((_) => oldIdAnswer.future);
          when(() => repository.getCurrentUserMember(serverId))
              .thenAnswer((_) async => null);
          final bloc = build(withHydration: false);
          addTearDown(bloc.close);

          final states = await moveAndRender(bloc);
          oldIdAnswer.complete(
            _member('u-me', role: HouseholdRole.householdOwner),
          );
          await settle();

          expect(states.whereType<HouseholdDetailReady>(), [ownerOnServerId]);
        },
      );

      test('an open screen that could not tell who we are stays rendered '
          'through the move, and learns the role after it', () async {
        // The re-ask the move makes must not put a rendered screen back on
        // a spinner: identity gates only the first paint.
        when(() => repository.getCurrentUserMember(_id))
            .thenAnswer((_) async => null);
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);
        await openAndRender(bloc);

        final states = await moveAndRender(bloc);

        expect(states, everyElement(isA<HouseholdDetailReady>()));
        expect(bloc.state, ownerOnServerId);
      });
    });

    group('when the move arrives with rows read before it (#442)', () {
      // The repository reads the moves after the rows it delivers with
      // them, so a reconcile that commits between the two reads delivers
      // the local row with the move that deleted it. That row is still
      // this household, and the reconcile's write brings the server's row
      // on the next emission.
      Future<void> deliverPreMoveRowsThenServerRows() async {
        reconciledTo = serverId;
        households.add([_household(_id)]);
        await settle();
        households.add([_household(serverId)]);
        serverMembers.add([
          _member(
            'u-me',
            role: HouseholdRole.householdOwner,
            householdId: serverId,
          ),
        ]);
        await settle();
      }

      test('an open screen stays rendered', () async {
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);
        final states = await openAndRender(bloc);

        await deliverPreMoveRowsThenServerRows();

        expect(states, everyElement(isA<HouseholdDetailReady>()));
        expect(bloc.state, ownerOnServerId);
      });

      test('a first paint is not the not-found page', () async {
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);
        final states = <HouseholdDetailState>[];
        final sub = bloc.stream.listen(states.add);
        addTearDown(sub.cancel);

        await deliverPreMoveRowsThenServerRows();

        expect(states, isNot(contains(isA<HouseholdDetailNotFound>())));
        expect(bloc.state, ownerOnServerId);
      });
    });

    test(
      'a household that disappears with no record is still not found',
      () async {
        // Following a record must not turn every disappearance into a wait.
        final bloc = build(withHydration: false);
        addTearDown(bloc.close);
        await openAndRender(bloc);

        households.add(const []);

        await expectLater(
          bloc.stream,
          emitsThrough(isA<HouseholdDetailNotFound>()),
        );
      },
    );
  });
}
