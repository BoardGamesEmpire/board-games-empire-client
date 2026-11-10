/// Who is offered Offer games and Take back on an event, and the values the
/// offer flow passes between its pages (#516).
///
/// The role table ([EventAction.offerGame]) knows who may offer. This narrows
/// its answer by what the event and the viewer's own row say, so a screen
/// shows a control only when all of them agree.
library;

import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:models/domain.dart';

/// What [offerGamesGate] decides for the screen.
enum OfferGamesGate {
  /// Neither Offer games nor Take back is built.
  hidden,

  /// Offer games is shown disabled with its reason: the server would accept
  /// the offer, but a game offered by someone who isn't going can't be
  /// nominated or added.
  notGoing,

  /// Offer games and Take back are offered.
  open,
}

/// Whether the viewer is offered Offer games and Take back on [state].
///
/// [OfferGamesGate.hidden] unless the viewer's actions hold
/// [EventAction.offerGame], the detail has a row for them on the roster (a
/// household owner or admin with none has no list to add to), the event isn't
/// local-only (the server doesn't know it yet), and it takes writes at all
/// ([takesDateWrites]: not cancelled, archived or of unknown status).
/// Otherwise [OfferGamesGate.notGoing] when their row answers Not attending,
/// and [OfferGamesGate.open] when it doesn't.
OfferGamesGate offerGamesGate(EventDetailReady state) {
  final event = state.detail.snapshot.event;
  final attendance = state.detail.attendance;

  if (!state.actions.contains(EventAction.offerGame) ||
      attendance == null ||
      event.isLocalOnly ||
      !takesDateWrites(event)) {
    return OfferGamesGate.hidden;
  }

  return attendance.status == EventParticipationStatus.notAttending
      ? OfferGamesGate.notGoing
      : OfferGamesGate.open;
}

/// What the Offer games page needs from the event beneath it: the games the
/// viewer has already offered, by collection id, so the page can leave them
/// out of what it offers.
final class OfferGamesArgs extends Equatable {
  const OfferGamesArgs({this.offeredCollectionIds = const {}});

  final Set<String> offeredCollectionIds;

  @override
  List<Object?> get props => [offeredCollectionIds];
}

/// One game picked to offer: its [collectionId] is what the server is asked
/// to add, and its [title] is what the outcome names.
final class OfferPick extends Equatable {
  const OfferPick({required this.collectionId, required this.title});

  final String collectionId;
  final String title;

  @override
  List<Object?> get props => [collectionId, title];
}
