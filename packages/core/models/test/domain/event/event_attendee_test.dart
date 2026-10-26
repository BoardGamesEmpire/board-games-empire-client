import 'package:test/test.dart';
import 'package:models/domain.dart';

DateTime get _now => DateTime.parse('2024-01-15T10:30:00Z');

EventAttendee _make({
  String? userId,
  String? guestName,
  String? username,
  String? displayName,
}) => EventAttendee(
  id: 'ea_1',
  eventId: 'e_1',
  userId: userId,
  guestName: guestName,
  username: username,
  displayName: displayName,
  status: EventParticipationStatus.invited,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('EventAttendee.name', () {
    test('the display name wins, then the username', () {
      expect(
        _make(userId: 'u_1', displayName: 'Alex Doe', username: 'alexd').name,
        'Alex Doe',
      );
      expect(_make(userId: 'u_1', username: 'alexd').name, 'alexd');
    });

    test('a guest is named by the name given when they were added', () {
      expect(_make(guestName: ' Sam ').name, 'Sam');
    });

    test('a blank username still falls through to the guest name', () {
      expect(_make(username: '  ', guestName: 'Sam').name, 'Sam');
    });

    test('nothing usable is null', () {
      expect(_make(username: '', guestName: ' ').name, isNull);
      expect(_make().name, isNull);
    });
  });
}
