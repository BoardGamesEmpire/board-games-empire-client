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
}) => HouseholdMember(
  id: 'm-$userId',
  userId: userId,
  householdId: householdId,
  role: role,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  late _MockHouseholdRepository repository;
  late StreamController<List<Household>> households;
  late StreamController<List<HouseholdMember>> members;
  late StreamController<HouseholdHydrationState> hydration;

  setUp(() {
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>();
    members = StreamController<List<HouseholdMember>>();
    hydration = StreamController<HouseholdHydrationState>();
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
    unawaited(hydration.close());
  });

  HouseholdDetailBloc build({bool withHydration = true}) => HouseholdDetailBloc(
    householdId: _id,
    repository: repository,
    hydration: withHydration ? hydration.stream : null,
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
        final bloc = build();
        addTearDown(bloc.close);

        hydration.add(HouseholdHydrationState.refreshed);
        households.add([_household('other')]);

        await expectLater(
          bloc.stream,
          emitsThrough(isA<HouseholdDetailNotFound>()),
        );
      },
    );

    test('an absent household mid-hydrate is loading, not not-found', () async {
      // The same distinction #269 D1 draws for the list, for the same
      // reason: a deep link or a restored route can arrive while the cache
      // is still filling, and "we couldn't find this household" shown to
      // someone who has it is the failure #267 exists to fix.
      final bloc = build();
      addTearDown(bloc.close);

      hydration.add(HouseholdHydrationState.running);
      households.add([_household('other')]);
      members.add(const []);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test(
      'the same absence resolves to not-found when the hydrate settles',
      () async {
        final bloc = build();
        addTearDown(bloc.close);

        hydration.add(HouseholdHydrationState.running);
        households.add([_household('other')]);
        await settle();
        hydration.add(HouseholdHydrationState.refreshed);

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
        final bloc = build();
        addTearDown(bloc.close);

        hydration.add(HouseholdHydrationState.failed);
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

      hydration.add(HouseholdHydrationState.running);
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

  group('races the review found', () {
    test('an absent household before the hydrate has said anything holds, '
        'rather than reporting not-found', () async {
      // `watchHouseholds()` is subscribed before the hydration stream, and
      // both deliver asynchronously. If the cache answers "absent" before
      // the status stream replays its current value, `_hydrationState` is
      // still its `idle` default — which reads as settled — and the screen
      // flashes not-found on its way to the content.
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test('and reports it once the hydrate does speak', () async {
      final bloc = build();
      addTearDown(bloc.close);

      households.add([_household('other')]);
      await settle();
      hydration.add(HouseholdHydrationState.refreshed);

      await expectLater(
        bloc.stream,
        emitsThrough(isA<HouseholdDetailNotFound>()),
      );
    });

    test('a hydration stream that closes without ever speaking still '
        'settles', () async {
      // The wait above must not become the spinner it was added to avoid.
      final bloc = build();
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
      // The hydrator writes cacheHousehold and cacheMembers as separate
      // writes, so between them the household is visible and the roster is
      // still `const []`. Rendering "No members" there states something
      // false about a household that always has at least its owner.
      final bloc = build();
      addTearDown(bloc.close);

      hydration.add(HouseholdHydrationState.running);
      members.add(const []);
      households.add([_household(_id)]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test('and gives up holding once the pass settles', () async {
      // Bounded by the same signal the absent-household branch uses: an
      // empty roster nothing is going to fill is rendered, not spun on.
      final bloc = build();
      addTearDown(bloc.close);

      hydration.add(HouseholdHydrationState.running);
      members.add(const []);
      households.add([_household(_id)]);
      await settle();
      hydration.add(HouseholdHydrationState.refreshed);

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
        hydration.add(HouseholdHydrationState.failed);

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

    test('an admin-scoped pass reads as refreshed, not failed', () async {
      final bloc = build();
      addTearDown(bloc.close);

      hydration.add(HouseholdHydrationState.refreshed);
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
      hydration.add(HouseholdHydrationState.refreshed);
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
        final bloc = build();
        addTearDown(bloc.close);

        hydration.add(HouseholdHydrationState.running);
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
      hydration: hydration.stream,
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
      hydration.add(HouseholdHydrationState.failed);
      await settle();

      bloc.add(const HouseholdDetailRetryRequested());
      hydration.add(HouseholdHydrationState.running);
      await settle();

      expect(calls, 1);
      expect(
        bloc.state,
        isA<HouseholdDetailReady>()
            .having((s) => s.refreshing, 'refreshing', isTrue)
            .having((s) => s.refreshFailed, 'refreshFailed', isFalse),
      );

      pass.complete();
    });

    test('a pass nobody asked for is not narrated', () async {
      // #302's triggers produce failed -> running without anyone pressing
      // anything; the screen stays quiet for those.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);
      hydration.add(HouseholdHydrationState.failed);
      await settle();

      hydration.add(HouseholdHydrationState.running);
      await settle();

      expect(calls, isZero);
      expect(
        bloc.state,
        isA<HouseholdDetailReady>().having(
          (s) => s.refreshing,
          'refreshing',
          isFalse,
        ),
      );
    });

    test('an unverified absence can be retried too (#300 D10)', () async {
      // The surface a retry is worth the most on: a household missing from
      // a cache whose last pass failed may well exist on the server.
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add(const []);
      members.add(const []);
      hydration.add(HouseholdHydrationState.failed);
      await settle();

      expect(bloc.state, isA<HouseholdDetailNotFound>());

      bloc.add(const HouseholdDetailRetryRequested());
      hydration.add(HouseholdHydrationState.running);
      await settle();

      expect(calls, 1);
      // No "refreshing" annotation on this surface, and deliberately so:
      // #270 already rules that an absence with a pass running is unknown
      // rather than missing, so the screen stops claiming the household is
      // gone while it is being looked for.
      expect(bloc.state, isA<HouseholdDetailLoading>());

      hydration.add(HouseholdHydrationState.failed);
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

    test('a second press while one is still running starts nothing', () async {
      final bloc = buildWithRetry();
      addTearDown(bloc.close);

      households.add([_household(_id)]);
      members.add([_member('u-me')]);
      hydration.add(HouseholdHydrationState.failed);
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
      final bloc = build();
      addTearDown(bloc.close);

      hydration.add(HouseholdHydrationState.refreshed);
      households.add([_household('other')]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailNotFound>());

      hydration.add(HouseholdHydrationState.running);
      await settle();

      expect(bloc.state, isA<HouseholdDetailNotFound>());
    });

    test('an absence only a failure has seen is still unknown', () async {
      // Unchanged from #270: a failed pass confirms nothing, so a pass over
      // an unverified absence is still the spinner.
      final bloc = build();
      addTearDown(bloc.close);

      hydration.add(HouseholdHydrationState.failed);
      households.add([_household('other')]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailNotFound>());

      hydration.add(HouseholdHydrationState.running);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test('a household that was shown and then vanished still waits on a '
        'running pass', () async {
      // The branch #300 D16 deliberately does NOT touch. Once the household
      // has been rendered, a pass in flight may be rewriting the very rows
      // this screen reads, so its disappearance mid-pass is not yet an
      // answer — #270's reasoning, unchanged.
      final bloc = build();
      addTearDown(bloc.close);

      hydration.add(HouseholdHydrationState.refreshed);
      households.add([_household(_id)]);
      members.add([_member('u-me', role: HouseholdRole.householdOwner)]);
      await settle();
      expect(bloc.state, isA<HouseholdDetailReady>());

      hydration.add(HouseholdHydrationState.running);
      households.add([_household('other')]);
      await settle();

      expect(bloc.state, isA<HouseholdDetailLoading>());
    });

    test(
      'the household arriving after a confirmed absence still renders',
      () async {
        final bloc = build();
        addTearDown(bloc.close);

        hydration.add(HouseholdHydrationState.refreshed);
        households.add([_household('other')]);
        await settle();

        hydration.add(HouseholdHydrationState.running);
        households.add([_household(_id)]);
        members.add([_member('u-me', role: HouseholdRole.householdOwner)]);
        await settle();

        expect(bloc.state, isA<HouseholdDetailReady>());
      },
    );
  });
}
