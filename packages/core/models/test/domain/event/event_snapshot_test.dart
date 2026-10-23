import 'package:models/domain.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 10, 22, 19);

Event _event() => Event(
  id: 'event_1',
  title: 'Friday night',
  createdById: 'user_1',
  type: EventType.casualGathering,
  reach: Reach.friends,
  status: EventStatus.scheduled,
  schedulingMode: EventSchedulingMode.fixed,
  createdAt: _at,
  updatedAt: _at,
);

EventSnapshot _snapshot({List<EventAttendee>? attendees}) =>
    EventSnapshot(event: _event(), occurrences: const [], attendees: attendees);

EventAttendee _attendee({String? userId, String? guestName}) => EventAttendee(
  id: 'attendee_1',
  eventId: 'event_1',
  userId: userId,
  guestName: guestName,
  status: EventParticipationStatus.invited,
  createdAt: _at,
  updatedAt: _at,
);

void main() {
  group('EventSnapshot', () {
    test('a snapshot without a roster is not the same as an unreadable one', () {
      // `GET /events` carries no roster and `GET /events/:id` carries an empty
      // one when the caller cannot read it, so a snapshot that folded the two
      // together would let a list read stand for "nobody is coming".
      //
      // Equal inputs must compare equal first, or the inequality below would
      // hold for any two snapshots and prove nothing.
      expect(_snapshot(attendees: null), _snapshot(attendees: null));
      expect(_snapshot(attendees: const []), _snapshot(attendees: const []));

      expect(_snapshot(attendees: null), isNot(_snapshot(attendees: const [])));
    });
  });

  group('EventAttendee', () {
    test('an attendee with no user is a guest', () {
      expect(_attendee(userId: null, guestName: 'Sam').isGuest, isTrue);
    });

    test('an attendee with a user is not a guest', () {
      expect(_attendee(userId: 'user_2').isGuest, isFalse);
    });
  });
}
