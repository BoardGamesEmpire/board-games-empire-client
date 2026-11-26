import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_lineup_bloc.dart';
import 'package:events/src/bloc/event_lineup_event.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/detail/games_date_view.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

class _MockGames extends MockBloc<EventGamesEvent, EventGamesState>
    implements EventGamesBloc {}

class _MockNominations
    extends MockBloc<EventNominationsEvent, EventNominationsState>
    implements EventNominationsBloc {}

class _MockDetail extends MockBloc<EventDetailEvent, EventDetailState>
    implements EventDetailBloc {}

class _MockLineup extends MockBloc<EventLineupEvent, EventLineupState>
    implements EventLineupBloc {}

/// The scope under the screen's tab controller and the blocs it reads, with
/// the controller it holds handed to [onBuild] on each build. The detail's
/// bloc starts on [initialDetail] and emits [details], and the scope opens
/// on [initialDate], the date the location names (#1042), by the clock
/// [now]. With a [child], that is built under the scope in place of the
/// widget that hands the controller to [onBuild].
Widget _harness({
  required void Function(EventGamesTabController controller) onBuild,
  Widget? child,
  EventGamesSection initialSection = EventGamesSection.nominations,
  bool disableAnimations = false,
  Stream<EventDetailState> details = const Stream.empty(),
  EventDetailState initialDetail = const EventDetailLoading(),
  String? initialDate,
  DateTime Function() now = DateTime.now,
}) {
  final games = _MockGames();
  final nominations = _MockNominations();
  final lineup = _MockLineup();
  final detail = _MockDetail();
  whenListen(
    games,
    const Stream<EventGamesState>.empty(),
    initialState: const EventGamesState(),
  );
  whenListen(
    nominations,
    const Stream<EventNominationsState>.empty(),
    initialState: const EventNominationsState(),
  );
  whenListen(
    lineup,
    const Stream<EventLineupState>.empty(),
    initialState: const EventLineupState(),
  );
  whenListen(detail, details, initialState: initialDetail);
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: MultiBlocProvider(
      providers: [
        BlocProvider<EventGamesBloc>.value(value: games),
        BlocProvider<EventNominationsBloc>.value(value: nominations),
        BlocProvider<EventLineupBloc>.value(value: lineup),
        BlocProvider<EventDetailBloc>.value(value: detail),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DefaultTabController(
          length: EventDetailTab.values.length,
          child: EventGamesTabScope(
            onFirstShown: (_, _) => false,
            initialSection: initialSection,
            initialDate: initialDate,
            now: now,
            child:
                child ??
                Builder(
                  builder: (context) {
                    onBuild(EventGamesTabScope.of(context));
                    return const SizedBox();
                  },
                ),
          ),
        ),
      ),
    ),
  );
}

/// What the Games tab keeps across the screen's rebuilds (#516), and how its
/// filter takes each change (#851).
void main() {
  test("the filter sheet's facets leave the search field's query as it "
      'was', () {
    final controller = EventGamesTabController();
    addTearDown(controller.dispose);

    controller
      ..setQuery('catan')
      ..setGameFilter(
        const CollectionFilter(
          query: 'root',
          mediums: {GameMedium.digital},
        ),
      );

    expect(controller.filter.query, 'catan');
    expect(controller.filter.game.mediums, {GameMedium.digital});
  });

  group('the sub-tabs', () {
    testWidgets('open on initialSection', (tester) async {
      late EventGamesTabController controller;
      await tester.pumpWidget(
        _harness(
          initialSection: EventGamesSection.pool,
          onBuild: (c) => controller = c,
        ),
      );

      expect(controller.section, EventGamesSection.pool);
    });

    testWidgets('a sub-tab change notifies once, as it starts, not again '
        'when it settles', (tester) async {
      late EventGamesTabController controller;
      await tester.pumpWidget(_harness(onBuild: (c) => controller = c));
      var notified = 0;
      controller.addListener(() => notified++);

      controller.sections.animateTo(
        EventGamesSection.pool.index,
        duration: const Duration(milliseconds: 300),
      );
      await tester.pump();

      expect(controller.sections.indexIsChanging, isTrue);
      expect(notified, 1);

      await tester.pumpAndSettle();

      expect(controller.sections.indexIsChanging, isFalse);
      expect(controller.section, EventGamesSection.pool);
      expect(notified, 1);
    });

    testWidgets('reduced motion moves the indicator at once and keeps the '
        'sub-tab', (tester) async {
      late EventGamesTabController controller;
      await tester.pumpWidget(
        _harness(
          initialSection: EventGamesSection.pool,
          onBuild: (c) => controller = c,
        ),
      );
      final before = controller.sections;
      expect(before.animationDuration, isNot(Duration.zero));
      var notified = 0;
      controller.addListener(() => notified++);

      await tester.pumpWidget(
        _harness(
          initialSection: EventGamesSection.pool,
          disableAnimations: true,
          onBuild: (c) => controller = c,
        ),
      );
      await tester.pump();

      expect(controller.section, EventGamesSection.pool);
      expect(controller.sections, isNot(same(before)));
      expect(controller.sections.animationDuration, Duration.zero);
      expect(controller.sections.index, EventGamesSection.pool.index);
      // The swap tells the page once, so it builds on the new controller; it
      // is not a change of sub-tab, so nothing more.
      expect(notified, 1);

      controller.sections.animateTo(0);
      await tester.pumpAndSettle();

      expect(controller.section, EventGamesSection.lineup);
      expect(notified, 2);
    });
  });

  // Which of the event's dates the tab shows, as each of the detail's
  // states arrives, and what the location is to name for it.
  group('the date view (#1042)', () {
    final now = DateTime.utc(2026, 10, 1, 12);

    /// A confirmed date [days] after [now], [order]th among the event's.
    EventOccurrence date(String id, int days, {int order = 0}) =>
        confirmed(id, now.add(Duration(days: days)), sortOrder: order);

    final soon = date('soon', 2);
    final later = date('later', 9, order: 1);
    final last = date('last', 16, order: 2);

    /// The event with [dates], ready, made offline where [localOnly], with a
    /// read running where [reading], and the last read failed where
    /// [refreshFailed]. By default a read has ended with these dates, and
    /// with their rules, so a read running leaves each date's mode known
    /// (#1063).
    EventDetailReady ready(
      List<EventOccurrence> dates, {
      bool localOnly = false,
      String title = 'Game night',
      bool reading = false,
      bool refreshFailed = false,
    }) => EventDetailReady(
      detail: EventDetail(
        snapshot: EventSnapshot(
          event: item(
            'e',
            title: title,
          ).event.copyWith(isLocalOnly: localOnly),
          occurrences: dates,
          occurrencePolicies: const [],
        ),
      ),
      actions: const {},
      reading: reading,
      refreshFailed: refreshFailed,
    );

    late StreamController<EventDetailState> details;
    late EventGamesTabController controller;

    /// How many times the controller has told its listeners since [open].
    late int notified;

    /// Opens the scope on the location's [date] and [section], with nothing
    /// yet read.
    Future<void> open(
      WidgetTester tester, {
      String? date,
      EventGamesSection section = EventGamesSection.nominations,
    }) async {
      details = StreamController<EventDetailState>();
      addTearDown(() => unawaited(details.close()));
      await tester.pumpWidget(
        _harness(
          details: details.stream,
          initialDate: date,
          initialSection: section,
          now: () => now,
          onBuild: (c) => controller = c,
        ),
      );
      notified = 0;
      controller.addListener(() => notified++);
    }

    Future<void> emit(WidgetTester tester, EventDetailState state) async {
      details.add(state);
      await tester.pump();
    }

    testWidgets('a date added makes the row appear on the default and keeps '
        'the sub-tab', (tester) async {
      await open(tester, section: EventGamesSection.pool);

      await emit(tester, ready([soon]));
      expect(controller.dateView, isNull);
      expect(notified, 0);

      await emit(tester, ready([soon, later]));

      expect(controller.dateView, const OneDateView('soon'));
      // A location naming none opens the default, so it is to name none.
      expect(controller.dateQuery, isNull);
      expect(controller.section, EventGamesSection.pool);
      expect(notified, 1);
    });

    testWidgets('a date removed takes the row away and keeps the sub-tab', (
      tester,
    ) async {
      await open(tester, date: 'later', section: EventGamesSection.pool);
      await emit(tester, ready([soon, later]));
      expect(controller.dateView, const OneDateView('later'));
      notified = 0;

      await emit(tester, ready([soon]));

      expect(controller.dateView, isNull);
      // The location is to name no date then.
      expect(controller.dateQuery, isNull);
      expect(controller.section, EventGamesSection.pool);
      expect(notified, 1);
    });

    testWidgets('the chosen date removed falls back to the default', (
      tester,
    ) async {
      await open(tester);
      await emit(tester, ready([soon, later, last]));
      controller.chooseDate(const OneDateView('later'));
      expect(controller.dateView, const OneDateView('later'));
      expect(notified, 2);

      await emit(tester, ready([soon, last]));

      expect(controller.dateView, const OneDateView('soon'));
      expect(controller.dateQuery, 'soon');
      expect(notified, 3);
    });

    testWidgets('Every date chosen stays as the dates change', (
      tester,
    ) async {
      await open(tester);
      await emit(tester, ready([soon, later, last]));
      controller.chooseDate(const EveryDateView());
      notified = 0;

      await emit(tester, ready([later, last]));

      expect(controller.dateView, const EveryDateView());
      expect(controller.dateQuery, 'all');
      expect(notified, 0);
    });

    testWidgets("the location's date opens that date once the dates are "
        'known', (tester) async {
      await open(tester, date: 'later');
      // Until then the location's date stands as it came.
      expect(controller.dateView, isNull);
      expect(controller.dateQuery, 'later');

      await emit(tester, ready([soon, later]));

      expect(controller.dateView, const OneDateView('later'));
      expect(controller.dateQuery, 'later');
    });

    testWidgets('a date the event lacks opens the default, which the '
        'location is to name', (tester) async {
      await open(tester, date: 'gone');

      await emit(tester, ready([soon, later]));

      expect(controller.dateView, const OneDateView('soon'));
      expect(controller.dateQuery, 'soon');
    });

    testWidgets('a location that names no date opens the default, and is to '
        'name none for it, as the date shown goes too', (tester) async {
      await open(tester);

      await emit(tester, ready([soon, later, last]));
      expect(controller.dateView, const OneDateView('soon'));
      expect(controller.dateQuery, isNull);
      expect(notified, 1);

      await emit(tester, ready([later, last]));
      expect(controller.dateView, const OneDateView('later'));
      expect(controller.dateQuery, isNull);
      expect(notified, 2);
    });

    testWidgets('date=all opens Every date', (tester) async {
      await open(tester, date: 'all');

      await emit(tester, ready([soon, later]));

      expect(controller.dateView, const EveryDateView());
      expect(controller.dateQuery, 'all');
    });

    testWidgets('on an event with one date the location is to name none', (
      tester,
    ) async {
      await open(tester, date: 'soon');

      await emit(tester, ready([soon]));

      expect(controller.dateView, isNull);
      expect(controller.dateQuery, isNull);
      expect(notified, 1);
    });

    testWidgets('a state that changes no date tells nobody', (tester) async {
      await open(tester, date: 'later');
      await emit(tester, ready([soon, later]));
      expect(notified, 1);

      await emit(tester, ready([soon, later]));
      await emit(tester, ready([soon, later], title: 'Renamed'));
      await emit(tester, ready([soon, later], reading: true));
      await emit(tester, const EventDetailNotFound());

      expect(controller.dateView, const OneDateView('later'));
      expect(notified, 1);
    });

    testWidgets('an event made offline has no date view, and the location '
        'keeps its date', (tester) async {
      await open(tester, date: 'later');

      await emit(tester, ready([soon, later], localOnly: true));

      expect(controller.dateView, isNull);
      expect(controller.dateQuery, 'later');
      expect(notified, 0);
    });

    testWidgets('a later date from the location moves the view; one the '
        'event lacks moves it to the default', (tester) async {
      await open(tester);
      await emit(tester, ready([soon, later]));
      notified = 0;

      controller.takeDate('later', now: now);
      expect(controller.dateView, const OneDateView('later'));
      expect(notified, 1);

      controller.takeDate('later', now: now);
      expect(notified, 1);

      controller.takeDate('all', now: now);
      expect(controller.dateView, const EveryDateView());

      controller.takeDate('gone', now: now);
      expect(controller.dateView, const OneDateView('soon'));
      expect(controller.dateQuery, 'soon');
      expect(notified, 3);

      // A location that names none opens the default, and is to name none.
      controller.takeDate(null, now: now);
      expect(controller.dateView, const OneDateView('soon'));
      expect(controller.dateQuery, isNull);
      expect(notified, 4);
    });

    testWidgets('a date from the location before the dates are known waits '
        'for them', (tester) async {
      await open(tester, date: 'soon');

      controller.takeDate('later', now: now);
      expect(controller.dateView, isNull);
      expect(controller.dateQuery, 'later');

      await emit(tester, ready([soon, later]));

      expect(controller.dateView, const OneDateView('later'));
    });

    testWidgets('choosing a date tells the listeners once, and choosing it '
        'again tells nothing', (tester) async {
      await open(tester);
      await emit(tester, ready([soon, later]));
      notified = 0;

      controller.chooseDate(const OneDateView('later'));
      expect(controller.dateView, const OneDateView('later'));
      expect(controller.dateQuery, 'later');
      expect(notified, 1);

      controller.chooseDate(const OneDateView('later'));
      expect(notified, 1);
    });

    // A detail can be ready as the scope is made, as one handed in already
    // read could be: the sub-tabs it opens with follow the date the location
    // names, not the event's own rules, so a link to Nominations on a date
    // that takes nominations lands there (#519).
    testWidgets('a detail ready as the scope is made opens on the sub-tabs of '
        'the date the location names', (tester) async {
      final at = now;
      // Only the hosts add games to the event, but its later date takes
      // nominations.
      final detail = EventDetailReady(
        detail: EventDetail(
          snapshot: EventSnapshot(
            event: item('e').event,
            occurrences: [soon, later],
            policy: EventPolicy(
              id: 'p',
              eventId: 'e',
              allowMemberInvites: true,
              allowGuestInvites: false,
              restrictToGameCategories: false,
              requireHostApprovalToJoin: false,
              allowSpectators: false,
              strictCapacity: false,
              gameAdditionMode: GameAdditionMode.hostOnly,
              restrictToAttendeePool: false,
              voteThresholdType: VoteThresholdType.simpleMajority,
              voteQuorumType: VoteQuorumType.none,
              voteEligibility: VoteEligibility.allAttendees,
              interestedWeight: InterestedWeight.asAbstain,
              createdAt: at,
              updatedAt: at,
            ),
            occurrencePolicies: [
              EventOccurrencePolicy(
                id: 'op-later',
                occurrenceId: 'later',
                allowedCategoryIds: const [],
                allowedPlatformIds: const [],
                allowedPlatformTypes: const [],
                platformTypesUnrestricted: false,
                platformsUnrestricted: false,
                capacityUnrestricted: false,
                gameAdditionMode: GameAdditionMode.requiresVote,
                createdAt: at,
                updatedAt: at,
              ),
            ],
          ),
        ),
        actions: const {},
      );

      await tester.pumpWidget(
        _harness(
          initialDetail: detail,
          initialDate: 'later',
          now: () => now,
          onBuild: (c) => controller = c,
        ),
      );

      expect(controller.dateView, const OneDateView('later'));
      expect(controller.visibleSections, EventGamesSection.values);
      expect(controller.section, EventGamesSection.nominations);
    });

    // Nominate's "which date?" dialog asked only where the date view was
    // null on a multi-date event (#1062). That holds only if the view exists
    // before any pool row builds. A pool row builds under the scope only on a
    // Ready detail, as the screen's page does (`_ReadyPage`, under a
    // `BlocBuilder` on the detail's bloc), so the stand-in below builds on
    // the same terms and records the view it finds there.
    group('before any pool row builds (#1062)', () {
      /// What stands in for a pool row: built under the scope only once the
      /// detail is Ready, recording the controller's date view each time.
      Widget poolRow(List<GamesDateView?> seen) =>
          BlocBuilder<EventDetailBloc, EventDetailState>(
            builder: (context, state) {
              if (state is! EventDetailReady) return const SizedBox();
              seen.add(EventGamesTabScope.of(context).dateView);
              return const SizedBox();
            },
          );

      testWidgets("a multi-date event's first Ready detail has a date view "
          'before any pool row builds (#1062)', (tester) async {
        final seen = <GamesDateView?>[];
        final details = StreamController<EventDetailState>();
        addTearDown(() => unawaited(details.close()));
        await tester.pumpWidget(
          _harness(
            details: details.stream,
            now: () => now,
            child: poolRow(seen),
            onBuild: (_) {},
          ),
        );
        expect(seen, isEmpty);

        details.add(ready([soon, later]));
        // Once for the event to reach the builder, once for its frame.
        await tester.pump();
        await tester.pump();

        expect(seen, isNotEmpty);
        expect(seen.first, isNotNull);
      });

      testWidgets('a detail already Ready as the scope mounts has a date '
          'view on the first build (#1062)', (tester) async {
        final seen = <GamesDateView?>[];
        await tester.pumpWidget(
          _harness(
            initialDetail: ready([soon, later]),
            now: () => now,
            child: poolRow(seen),
            onBuild: (_) {},
          ),
        );

        expect(seen, isNotEmpty);
        expect(seen.first, isNotNull);
      });
    });

    // The row takes the place of the nominations' date facet: a date set
    // in the filter before the row appears is cleared as it does, none is
    // taken while it shows, and none is set back as it goes.
    testWidgets("the row clears the nominations' filter's date, and takes "
        'none while it shows', (tester) async {
      await open(tester);
      await emit(tester, ready([soon]));
      controller.setNominationFilter(
        const NominationFilter(scope: DateScope('soon'), mine: true),
      );
      expect(controller.nominationFilter.scope, const DateScope('soon'));
      notified = 0;

      await emit(tester, ready([soon, later]));

      expect(controller.dateView, const OneDateView('soon'));
      expect(controller.nominationFilter, const NominationFilter(mine: true));
      expect(notified, 1);

      controller.setNominationFilter(
        const NominationFilter(scope: WholeEventScope(), mine: true),
      );
      expect(controller.nominationFilter, const NominationFilter(mine: true));
      expect(notified, 1);

      await emit(tester, ready([soon]));

      expect(controller.dateView, isNull);
      expect(controller.nominationFilter, const NominationFilter(mine: true));
    });

    // The cache's dates can be older than the server's: a link to a date
    // added since the event was last read is held until a read ends.
    group('a date the cached dates lack', () {
      testWidgets('waits for the read, and shows once it brings it', (
        tester,
      ) async {
        await open(tester, date: 'later', section: EventGamesSection.pool);

        await emit(tester, ready([soon, last], reading: true));
        expect(controller.dateView, const OneDateView('soon'));
        // The location keeps naming it.
        expect(controller.dateQuery, 'later');

        // What the read wrote reaches the cache before it ends.
        await emit(tester, ready([soon, later, last], reading: true));
        expect(controller.dateView, const OneDateView('later'));
        expect(controller.dateQuery, 'later');
        expect(controller.section, EventGamesSection.pool);

        await emit(tester, ready([soon, later, last]));
        expect(controller.dateView, const OneDateView('later'));
        expect(controller.dateQuery, 'later');
      });

      testWidgets("gives way to the default once a read ends that doesn't "
          'bring it, and the location is to name that', (tester) async {
        await open(tester, date: 'later');
        await emit(tester, ready([soon, last], reading: true));
        expect(controller.dateQuery, 'later');

        await emit(tester, ready([soon, last]));

        expect(controller.dateView, const OneDateView('soon'));
        expect(controller.dateQuery, 'soon');
      });

      testWidgets("still shows once the read's own answer brings it, just "
          'after the read ends', (tester) async {
        await open(tester, date: 'later');
        await emit(tester, ready([soon, last], reading: true));
        // The read settles before the cache delivers what it wrote.
        await emit(tester, ready([soon, last]));
        expect(controller.dateQuery, 'soon');

        await emit(tester, ready([soon, later, last]));

        expect(controller.dateView, const OneDateView('later'));
        expect(controller.dateQuery, 'later');
      });

      testWidgets("isn't judged by a read that failed", (tester) async {
        await open(tester, date: 'later');
        await emit(tester, ready([soon, last], reading: true));

        await emit(tester, ready([soon, last], refreshFailed: true));
        expect(controller.dateView, const OneDateView('soon'));
        expect(controller.dateQuery, 'later');

        // A retry that succeeds settles it.
        await emit(tester, ready([soon, last]));
        expect(controller.dateQuery, 'soon');
      });

      testWidgets('on a cached event with one date, waits for the read', (
        tester,
      ) async {
        await open(tester, date: 'later');

        await emit(tester, ready([soon], reading: true));
        expect(controller.dateView, isNull);
        expect(controller.dateQuery, 'later');

        await emit(tester, ready([soon, later]));
        expect(controller.dateView, const OneDateView('later'));
        expect(controller.dateQuery, 'later');
      });

      testWidgets('a date chosen meanwhile ends the wait', (tester) async {
        await open(tester, date: 'later');
        await emit(tester, ready([soon, last], reading: true));

        controller.chooseDate(const EveryDateView());
        expect(controller.dateQuery, 'all');

        await emit(tester, ready([soon, later, last]));
        expect(controller.dateView, const EveryDateView());
        expect(controller.dateQuery, 'all');
      });

      testWidgets('Every date, or a date the cache has, needs no wait', (
        tester,
      ) async {
        await open(tester, date: 'all');
        await emit(tester, ready([soon, last], reading: true));
        expect(controller.dateView, const EveryDateView());

        controller.takeDate('last', now: now);
        expect(controller.dateView, const OneDateView('last'));
        expect(controller.dateQuery, 'last');
      });
    });
  });
}
