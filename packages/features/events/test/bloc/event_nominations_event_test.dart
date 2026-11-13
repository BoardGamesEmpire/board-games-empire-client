import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

/// The nominations' input (#517, #518) is equal by what it names, so a test
/// can say which request reached the bloc.
void main() {
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
  final nomination = EventNomination(
    id: 'n-1',
    eventId: 'e-1',
    platformGameId: 'pg-1',
    gameId: 'game-1',
    title: 'Game 1',
    platformName: 'Tabletop',
    status: NominationStatus.open,
    nominatedById: 'a-1',
    suppliedFromId: 'g-1',
    createdAt: DateTime.utc(2026, 11),
  );
  final otherNomination = nomination.copyWith(id: 'n-2');

  test('a read is equal by its event', () {
    expect(
      const EventNominationsRequested('e-1'),
      const EventNominationsRequested('e-1'),
    );
    expect(
      const EventNominationsRequested('e-1'),
      isNot(const EventNominationsRequested('e-2')),
    );
  });

  test('a retry is equal by its event, and is not a read', () {
    expect(
      const EventNominationsRetryRequested('e-1'),
      const EventNominationsRetryRequested('e-1'),
    );
    expect(
      const EventNominationsRetryRequested('e-1'),
      isNot(const EventNominationsRetryRequested('e-2')),
    );
    expect(
      const EventNominationsRetryRequested('e-1'),
      isNot(const EventNominationsRequested('e-1')),
    );
  });

  test('a nominate is equal by its event, game and date', () {
    const nominate = GameNominated('e-1', game, occurrenceId: 'o-1');

    expect(nominate, const GameNominated('e-1', game, occurrenceId: 'o-1'));
    expect(
      nominate,
      isNot(const GameNominated('e-2', game, occurrenceId: 'o-1')),
    );
    expect(
      nominate,
      isNot(GameNominated('e-1', otherGame, occurrenceId: 'o-1')),
    );
    expect(
      nominate,
      isNot(const GameNominated('e-1', game, occurrenceId: 'o-2')),
    );
    expect(nominate, isNot(const GameNominated('e-1', game)));
  });

  test('a vote is equal by its event, nomination, vote and note', () {
    final vote = NominationVoteCast(
      'e-1',
      nomination,
      VoteType.forGame,
      comment: 'Yes',
    );

    expect(
      vote,
      NominationVoteCast('e-1', nomination, VoteType.forGame, comment: 'Yes'),
    );
    expect(
      vote,
      isNot(
        NominationVoteCast('e-2', nomination, VoteType.forGame, comment: 'Yes'),
      ),
    );
    expect(
      vote,
      isNot(
        NominationVoteCast(
          'e-1',
          otherNomination,
          VoteType.forGame,
          comment: 'Yes',
        ),
      ),
    );
    expect(
      vote,
      isNot(
        NominationVoteCast('e-1', nomination, VoteType.against, comment: 'Yes'),
      ),
    );
    expect(
      vote,
      isNot(NominationVoteCast('e-1', nomination, VoteType.forGame)),
    );
  });

  test('a withdrawal is equal by its event and nomination', () {
    final withdrawal = NominationWithdrawn('e-1', nomination);

    expect(withdrawal, NominationWithdrawn('e-1', nomination));
    expect(withdrawal, isNot(NominationWithdrawn('e-2', nomination)));
    expect(withdrawal, isNot(NominationWithdrawn('e-1', otherNomination)));
  });

  test('a host decision is equal by its event and nomination, and by which '
      'decision it is', () {
    for (final decide
        in <EventNominationsEvent Function(String, EventNomination)>[
          NominationApproved.new,
          NominationRejected.new,
          NominationResolved.new,
        ]) {
      expect(decide('e-1', nomination), decide('e-1', nomination));
      expect(decide('e-1', nomination), isNot(decide('e-2', nomination)));
      expect(decide('e-1', nomination), isNot(decide('e-1', otherNomination)));
    }
    expect(
      NominationApproved('e-1', nomination),
      isNot(NominationRejected('e-1', nomination)),
    );
    expect(
      NominationApproved('e-1', nomination),
      isNot(NominationResolved('e-1', nomination)),
    );
    expect(
      NominationRejected('e-1', nomination),
      isNot(NominationResolved('e-1', nomination)),
    );
  });

  test('a dropped write is equal by its write, title and subtitle', () {
    const dropped = NominationWriteDropped(
      NominationWrite.vote,
      title: 'Game 1',
    );

    expect(
      dropped,
      const NominationWriteDropped(NominationWrite.vote, title: 'Game 1'),
    );
    expect(
      dropped,
      isNot(
        const NominationWriteDropped(NominationWrite.withdraw, title: 'Game 1'),
      ),
    );
    expect(
      dropped,
      isNot(
        const NominationWriteDropped(NominationWrite.vote, title: 'Game 2'),
      ),
    );
    expect(
      dropped,
      isNot(
        const NominationWriteDropped(
          NominationWrite.vote,
          title: 'Game 1',
          subtitle: 'Seafarers',
        ),
      ),
    );
  });

  test('every dismissal is equal', () {
    expect(
      // Not const: identical instances never reach the comparison.
      // ignore: prefer_const_constructors
      EventNominationsOutcomeDismissed(),
      // Not const, for the same reason.
      // ignore: prefer_const_constructors
      EventNominationsOutcomeDismissed(),
    );
  });
}
