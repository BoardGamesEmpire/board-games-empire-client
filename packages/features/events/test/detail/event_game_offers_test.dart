import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// Who is offered Offer games and Take back on an event (#516), and the two
/// value classes the offer flow passes around.
void main() {
  /// The detail as the screen holds it: [event] with [attendance] as the
  /// viewer's row, and [actions] the role table gave them.
  EventDetailReady ready({
    Event? event,
    Set<EventAction> actions = const {EventAction.offerGame},
    EventAttendee? attendance,
  }) => EventDetailReady(
    detail: EventDetail(
      snapshot: EventSnapshot(
        event: event ?? item('e').event,
        occurrences: const [],
      ),
      attendance: attendance,
    ),
    actions: actions,
  );

  group('offerGamesGate', () {
    test('is hidden for a spectator, who holds no offerGame', () {
      final state = ready(
        actions: eventActionsFor(
          item('e').event,
          eventRole: EventRole.spectator,
        ),
        attendance: attendance(EventParticipationStatus.attending),
      );

      expect(offerGamesGate(state), OfferGamesGate.hidden);
    });

    test('is hidden with no attendance, even holding offerGame', () {
      expect(offerGamesGate(ready()), OfferGamesGate.hidden);
    });

    test('is hidden on a cancelled event', () {
      final event = item(
        'e',
      ).event.copyWith(status: EventStatus.cancelled);

      expect(
        offerGamesGate(
          ready(
            event: event,
            attendance: attendance(EventParticipationStatus.attending),
          ),
        ),
        OfferGamesGate.hidden,
      );
    });

    test('is hidden on an archived event', () {
      final event = item('e').event.copyWith(status: EventStatus.archived);

      expect(
        offerGamesGate(
          ready(
            event: event,
            attendance: attendance(EventParticipationStatus.attending),
          ),
        ),
        OfferGamesGate.hidden,
      );
    });

    test('is hidden on a local-only event', () {
      final event = item('e').event.copyWith(isLocalOnly: true);

      expect(
        offerGamesGate(
          ready(
            event: event,
            attendance: attendance(EventParticipationStatus.attending),
          ),
        ),
        OfferGamesGate.hidden,
      );
    });

    test('is notGoing for a participant who answered Not attending', () {
      expect(
        offerGamesGate(
          ready(attendance: attendance(EventParticipationStatus.notAttending)),
        ),
        OfferGamesGate.notGoing,
      );
    });

    for (final status in [
      EventParticipationStatus.invited,
      EventParticipationStatus.maybe,
      EventParticipationStatus.attending,
    ]) {
      test('is open for a participant who is ${status.name}', () {
        expect(
          offerGamesGate(ready(attendance: attendance(status))),
          OfferGamesGate.open,
        );
      });
    }

    test('is open for a household owner on the roster as a spectator', () {
      final event = item('e', householdId: 'h-1').event;
      final row = attendance(
        EventParticipationStatus.attending,
      ).copyWith(role: EventRole.spectator);
      final state = ready(
        event: event,
        actions: eventActionsFor(
          event,
          eventRole: EventRole.spectator,
          householdRole: HouseholdRole.householdOwner,
        ),
        attendance: row,
      );

      expect(offerGamesGate(state), OfferGamesGate.open);
    });
  });

  group('OfferGamesArgs', () {
    test('offers nothing by default', () {
      expect(const OfferGamesArgs().offeredCollectionIds, isEmpty);
    });

    test('compares by the ids offered', () {
      expect(
        const OfferGamesArgs(offeredCollectionIds: {'a', 'b'}),
        const OfferGamesArgs(offeredCollectionIds: {'a', 'b'}),
      );
      expect(
        const OfferGamesArgs(offeredCollectionIds: {'a'}),
        isNot(const OfferGamesArgs(offeredCollectionIds: {'b'})),
      );
    });
  });

  group('OfferPick', () {
    test('compares by collection id and title', () {
      expect(
        const OfferPick(collectionId: 'c', title: 'Catan'),
        const OfferPick(collectionId: 'c', title: 'Catan'),
      );
      expect(
        const OfferPick(collectionId: 'c', title: 'Catan'),
        isNot(const OfferPick(collectionId: 'c', title: 'Azul')),
      );
      expect(
        const OfferPick(collectionId: 'c', title: 'Catan'),
        isNot(const OfferPick(collectionId: 'd', title: 'Catan')),
      );
    });
  });
}
