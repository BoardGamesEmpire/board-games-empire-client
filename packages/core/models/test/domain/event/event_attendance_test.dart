import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('EventAttendance.fromAttendee', () {
    test('copies the id, status, role and RSVP date', () {
      final rsvp = DateTime.utc(2026, 10, 20, 9);
      final stamp = DateTime.utc(2026, 9);
      final attendee = EventAttendee(
        id: 'a1',
        eventId: 'e1',
        userId: 'u1',
        status: EventParticipationStatus.maybe,
        role: EventRole.guest,
        rsvpDate: rsvp,
        createdAt: stamp,
        updatedAt: stamp,
      );

      expect(
        EventAttendance.fromAttendee(attendee),
        EventAttendance(
          attendeeId: 'a1',
          status: EventParticipationStatus.maybe,
          role: EventRole.guest,
          rsvpDate: rsvp,
        ),
      );
    });
  });
}
