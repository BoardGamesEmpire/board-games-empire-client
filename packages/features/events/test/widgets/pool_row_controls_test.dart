import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/nominate_scopes.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/pool_row_controls.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// What Nominate offers on a pool row (#517), in the date view the row of
/// dates chose (#1042), and under that view's mode (#519).
void main() {
  final now = DateTime.utc(2026, 10, 1, 12);

  /// A confirmed date [days] from [now], [order]th among the event's.
  EventOccurrence date(String id, int days, {int order = 0}) =>
      confirmed(id, now.add(Duration(days: days)), sortOrder: order);

  final passed = date('passed', -3);
  final soon = date('soon', 2, order: 1);
  final later = date('later', 9, order: 2);

  EventPolicy policy(GameAdditionMode mode) => EventPolicy(
    id: 'p',
    eventId: 'e',
    allowMemberInvites: true,
    allowGuestInvites: false,
    restrictToGameCategories: false,
    requireHostApprovalToJoin: false,
    allowSpectators: false,
    strictCapacity: false,
    gameAdditionMode: mode,
    restrictToAttendeePool: false,
    voteThresholdType: VoteThresholdType.simpleMajority,
    voteQuorumType: VoteQuorumType.none,
    voteEligibility: VoteEligibility.allAttendees,
    interestedWeight: InterestedWeight.asAbstain,
    createdAt: kItemInstant,
    updatedAt: kItemInstant,
  );

  /// [occurrenceId]'s own rules: only the hosts add games.
  EventOccurrencePolicy hostOnlyOn(String occurrenceId) =>
      occurrencePolicyOn(occurrenceId, mode: GameAdditionMode.hostOnly);

  /// The event on [dates], its games under [mode], needing a vote unless
  /// it says otherwise, with the dates' own [overrides], as an attending
  /// viewer who may nominate sees it.
  EventDetailReady ready(
    List<EventOccurrence> dates, {
    GameAdditionMode mode = GameAdditionMode.requiresVote,
    List<EventOccurrencePolicy> overrides = const [],
  }) => EventDetailReady(
    detail: EventDetail(
      snapshot: EventSnapshot(
        event: item('e').event,
        occurrences: dates,
        policy: policy(mode),
        occurrencePolicies: overrides,
      ),
      attendance: attendance(EventParticipationStatus.attending),
    ),
    actions: const {EventAction.nominateGame},
  );

  /// What [scopes] are for: null for the whole event, else the date's id.
  List<String?> forWhat(List<NominateScope> scopes) => [
    for (final each in scopes)
      switch (each.scope) {
        WholeEventScope() => null,
        DateScope(:final occurrenceId) => occurrenceId,
      },
  ];

  group('nominateChoicesIn', () {
    test("is null under a view whose mode offers no Nominate, and the view's "
        'choices otherwise', () {
      final detail = ready([soon, later], overrides: [hostOnlyOn('later')]);

      expect(
        nominateChoicesIn(detail, view: const OneDateView('later'), now: now),
        isNull,
      );
      expect(
        forWhat(
          nominateChoicesIn(
            detail,
            view: const OneDateView('soon'),
            now: now,
          )!,
        ),
        ['soon'],
      );
      expect(
        forWhat(
          nominateChoicesIn(detail, view: const EveryDateView(), now: now)!,
        ),
        [null],
      );
    });

    test('is empty, not null, under a date that takes no nomination now', () {
      final detail = ready([passed, soon]);

      expect(
        nominateChoicesIn(detail, view: const OneDateView('passed'), now: now),
        isEmpty,
      );
    });

    test("with no view, Nominate checks the whole event against the event's "
        'rule', () {
      // One date, so no row of dates: Nominate offers the whole event alone
      // (#1062), and a date that would take a vote doesn't open it (#1070).
      final detail = ready(
        [soon],
        mode: GameAdditionMode.hostOnly,
        overrides: [
          occurrencePolicyOn('soon', mode: GameAdditionMode.requiresVote),
        ],
      );

      expect(nominateChoicesIn(detail, view: null, now: now), isNull);
    });
  });

  // What the row's status line says, and what Take back says, under each of
  // the three views (#1090): no row of dates, Every date, and one date.
  group('poolRowGates, the Nominated line (#1090)', () {
    final l10n = lookupEventsLocalizations(const Locale('en'));

    /// The viewer's own copy.
    const mine = OfferedGame(
      id: 'o-1',
      attendeeId: 'att-me',
      collectionId: 'col-o-1',
      platformGameId: 'pg-o-1',
      gameId: 'g-o-1',
      title: 'Catan',
      platformName: 'Tabletop',
    );

    /// A live nomination of [mine], for the whole event or, with
    /// [occurrenceId], one date.
    EventNomination nominationOf(String id, {String? occurrenceId}) =>
        EventNomination(
          id: id,
          eventId: 'e',
          platformGameId: mine.platformGameId,
          gameId: mine.gameId,
          title: mine.title,
          platformName: mine.platformName,
          status: NominationStatus.open,
          nominatedById: 'att-bo',
          suppliedFromId: mine.id,
          occurrenceId: occurrenceId,
          createdAt: kItemInstant,
        );

    /// The row of [mine] on [dates], under [view], with [nominations] held.
    PoolRowGates gatesOf(
      List<EventOccurrence> dates, {
      required GamesDateView? view,
      required List<EventNomination> nominations,
    }) {
      final detail = EventDetailReady(
        detail: ready(dates).detail,
        actions: const {EventAction.nominateGame, EventAction.offerGame},
      );
      final controller = EventGamesTabController();
      addTearDown(controller.dispose);
      if (view != null) controller.chooseDate(view);
      return poolRowGates(
        l10n,
        game: mine,
        detail: detail,
        games: const EventGamesState(),
        nominations: EventNominationsState(
          load: EventNominationsLoad.loaded,
          nominations: nominations,
        ),
        controller: controller,
        names: const {},
        acting: false,
        scopes: nominateChoicesIn(detail, view: view, now: now),
        addScopes: null,
        now: now,
      );
    }

    test('with no row of dates, any nomination of the copy says it', () {
      // For the one date: Nominate, for the whole event, is still offered, so
      // the status line says it.
      final onTheDate = gatesOf(
        [soon],
        view: null,
        nominations: [nominationOf('n-1', occurrenceId: 'soon')],
      );

      expect(onTheDate.nominate!.already, isNull);
      expect(onTheDate.nominatedLine, isTrue);
      expect(onTheDate.takeBack!.blockedReason, isNotNull);

      // For the whole event, Nominate says it itself (#947).
      final wholeEvent = gatesOf(
        [soon],
        view: null,
        nominations: [nominationOf('n-2')],
      );

      expect(wholeEvent.nominate!.already, isNotNull);
      expect(wholeEvent.nominatedLine, isFalse);
      expect(wholeEvent.takeBack!.blockedReason, isNotNull);

      // None: nothing says it.
      final none = gatesOf([soon], view: null, nominations: const []);

      expect(none.nominatedLine, isFalse);
      expect(none.takeBack!.blockedReason, isNull);
    });

    test('under Every date, only a whole-event nomination says it', () {
      final onADate = gatesOf(
        [soon, later],
        view: const EveryDateView(),
        nominations: [nominationOf('n-1', occurrenceId: 'soon')],
      );

      expect(onADate.nominatedLine, isFalse);
      expect(onADate.nominate!.already, isNull);
      // Take back stays blocked while it supplies a date's nomination.
      expect(onADate.takeBack!.blockedReason, isNotNull);

      final wholeEvent = gatesOf(
        [soon, later],
        view: const EveryDateView(),
        nominations: [nominationOf('n-2')],
      );

      // Nominate says it, for the one choice there is.
      expect(wholeEvent.nominate!.already, isNotNull);
      expect(wholeEvent.nominatedLine, isFalse);
    });

    test('under one date, a nomination for that date or the whole event '
        'says it, and one for another date does not', () {
      final dates = [soon, later];
      GamesDateView view(String id) => OneDateView(id);

      // For another date: not in view, Nominate is offered, and Take back
      // is still blocked, as it is under every date (#905).
      final other = gatesOf(
        dates,
        view: view('later'),
        nominations: [nominationOf('n-1', occurrenceId: 'soon')],
      );
      expect(other.nominatedLine, isFalse);
      expect(other.nominate!.already, isNull);
      expect(other.takeBack!.blockedReason, isNotNull);

      // For the date in view, Nominate says it.
      final same = gatesOf(
        dates,
        view: view('soon'),
        nominations: [nominationOf('n-1', occurrenceId: 'soon')],
      );
      expect(same.nominate!.already, isNotNull);
      expect(same.nominatedLine, isFalse);

      // For the whole event, which each date votes on: Nominate has a date
      // left, so the status line says it, under both.
      for (final id in ['soon', 'later']) {
        final whole = gatesOf(
          dates,
          view: view(id),
          nominations: [nominationOf('n-2')],
        );
        expect(whole.nominate!.already, isNull, reason: id);
        expect(whole.nominatedLine, isTrue, reason: id);
      }
    });
  });
}
