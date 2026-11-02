import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  const available = AvailabilityResponse.available;
  const maybe = AvailabilityResponse.maybe;

  test('a read is equal by its event', () {
    expect(const EventPollRequested('e-1'), const EventPollRequested('e-1'));
    expect(
      const EventPollRequested('e-1'),
      isNot(const EventPollRequested('e-2')),
    );
  });

  test('a retry is equal by its event, and is not a read', () {
    expect(
      const EventPollRetryRequested('e-1'),
      const EventPollRetryRequested('e-1'),
    );
    expect(
      const EventPollRetryRequested('e-1'),
      isNot(const EventPollRetryRequested('e-2')),
    );
    expect(
      const EventPollRetryRequested('e-1'),
      isNot(const EventPollRequested('e-1')),
    );
  });

  test('a vote is equal by its event, its date and its answer', () {
    const vote = EventPollVoted('e-1', 'o-1', available);

    expect(vote, const EventPollVoted('e-1', 'o-1', available));
    expect(vote, isNot(const EventPollVoted('e-2', 'o-1', available)));
    expect(vote, isNot(const EventPollVoted('e-1', 'o-2', available)));
    expect(vote, isNot(const EventPollVoted('e-1', 'o-1', maybe)));
  });

  test('every dismissal is equal', () {
    // Not const: identical instances never reach the comparison.
    // ignore: prefer_const_constructors
    expect(EventPollOutcomeDismissed(), EventPollOutcomeDismissed());
  });
}
