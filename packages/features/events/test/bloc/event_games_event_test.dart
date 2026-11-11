import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

/// The games pool's input (#516) is equal by what it names, so a test can
/// say which request reached the bloc.
void main() {
  const ids = ['a-1', 'a-2'];
  const otherIds = ['a-1'];
  const pick = OfferPick(collectionId: 'c-1', title: 'Game 1');
  const otherPick = OfferPick(collectionId: 'c-2', title: 'Game 2');
  const game = OfferedGame(
    id: 'g-1',
    attendeeId: 'a-1',
    collectionId: 'c-1',
    platformGameId: 'pg-1',
    gameId: 'game-1',
    title: 'Game 1',
    platformName: 'Tabletop',
  );
  final otherGame = game.copyWith(id: 'g-2');

  test('a read is equal by its event and attendees', () {
    expect(
      const EventGamesRequested('e-1', ids),
      const EventGamesRequested('e-1', ids),
    );
    expect(
      const EventGamesRequested('e-1', ids),
      isNot(const EventGamesRequested('e-2', ids)),
    );
    expect(
      const EventGamesRequested('e-1', ids),
      isNot(const EventGamesRequested('e-1', otherIds)),
    );
  });

  test('a retry is equal by its event and attendees, and is not a read', () {
    expect(
      const EventGamesRetryRequested('e-1', ids),
      const EventGamesRetryRequested('e-1', ids),
    );
    expect(
      const EventGamesRetryRequested('e-1', ids),
      isNot(const EventGamesRetryRequested('e-1', otherIds)),
    );
    expect(
      const EventGamesRetryRequested('e-1', ids),
      isNot(const EventGamesRequested('e-1', ids)),
    );
  });

  test('an offer is equal by its event, attendee, picks and roster', () {
    const offer = EventGamesOffered('e-1', 'a-1', [pick], attendeeIds: ids);

    expect(
      offer,
      const EventGamesOffered('e-1', 'a-1', [pick], attendeeIds: ids),
    );
    expect(
      offer,
      isNot(const EventGamesOffered('e-2', 'a-1', [pick], attendeeIds: ids)),
    );
    expect(
      offer,
      isNot(const EventGamesOffered('e-1', 'a-2', [pick], attendeeIds: ids)),
    );
    expect(
      offer,
      isNot(
        const EventGamesOffered('e-1', 'a-1', [otherPick], attendeeIds: ids),
      ),
    );
    expect(
      offer,
      isNot(
        const EventGamesOffered('e-1', 'a-1', [pick], attendeeIds: otherIds),
      ),
    );
  });

  test('a take-back is equal by its event, attendee, game and roster', () {
    const takeBack = EventGameTakenBack('e-1', 'a-1', game, attendeeIds: ids);

    expect(
      takeBack,
      const EventGameTakenBack('e-1', 'a-1', game, attendeeIds: ids),
    );
    expect(
      takeBack,
      isNot(const EventGameTakenBack('e-2', 'a-1', game, attendeeIds: ids)),
    );
    expect(
      takeBack,
      isNot(const EventGameTakenBack('e-1', 'a-2', game, attendeeIds: ids)),
    );
    expect(
      takeBack,
      isNot(EventGameTakenBack('e-1', 'a-1', otherGame, attendeeIds: ids)),
    );
    expect(
      takeBack,
      isNot(
        const EventGameTakenBack('e-1', 'a-1', game, attendeeIds: otherIds),
      ),
    );
  });

  test('a dropped write is equal by its write and title', () {
    const dropped = EventGamesWriteDropped(
      EventGamesWrite.takeBack,
      title: 'Game 1',
    );

    expect(
      dropped,
      const EventGamesWriteDropped(EventGamesWrite.takeBack, title: 'Game 1'),
    );
    expect(
      dropped,
      isNot(
        const EventGamesWriteDropped(EventGamesWrite.offer, title: 'Game 1'),
      ),
    );
    expect(
      dropped,
      isNot(const EventGamesWriteDropped(EventGamesWrite.takeBack)),
    );
  });

  test('every dismissal is equal', () {
    // Not const: identical instances never reach the comparison.
    // ignore: prefer_const_constructors
    expect(EventGamesOutcomeDismissed(), EventGamesOutcomeDismissed());
  });
}
