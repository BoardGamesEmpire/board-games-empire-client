import 'package:equatable/equatable.dart';

/// What the create form shows of its submit (#499).
sealed class CreateEventState extends Equatable {
  const CreateEventState();

  @override
  List<Object?> get props => [];
}

/// Nothing submitted yet, or a refusal or failure the user has edited the
/// form past.
final class CreateEventInitial extends CreateEventState {
  const CreateEventInitial();
}

/// A submit is on its way.
final class CreateEventSubmitting extends CreateEventState {
  const CreateEventSubmitting();
}

/// What became of a create's first send.
enum CreateEventSync {
  /// The server confirmed it, and the cache holds its event.
  synced,

  /// It stays queued, and the event `isLocalOnly`, until a later sync
  /// confirms it. Also the answer for a refused create another tab retried
  /// or discarded since, whichever it was: see [CreateEventSuccess].
  queued,
}

/// The first send was parked: the server refused the create as it stands.
/// The form stays open (#499).
///
/// The refused create stays parked, with its local-only event, until the
/// next submit discards both and creates afresh.
final class CreateEventRefused extends CreateEventState {
  const CreateEventRefused({this.inviteeId});

  /// The invitee the refusal names: one of the draft's `inviteUserIds`, found
  /// in the server's own text of a 404, which the remote keeps as
  /// `EventCreateRefusedException.apiMessage`. The exception's `message` is
  /// this client's own and never names anyone. Null when the refusal names
  /// no one, as a 403 never does.
  final String? inviteeId;

  @override
  List<Object?> get props => [inviteeId];
}

/// The form is done.
///
/// Usually the event was created locally, and [eventId] is the server's id
/// when [sync] is [CreateEventSync.synced], and the local id otherwise.
///
/// The exception is a submit after a refusal whose parked create another tab
/// retried or discarded since (#499). That submit creates nothing, and
/// [eventId] is the parked create's local id, with [CreateEventSync.queued].
/// After a retry the event stands, and the detail follows it to the server's
/// id once the retry lands. After a discard the id names nothing, and the
/// submitted draft is dropped. `CreateEventBloc` has why it can't tell which.
final class CreateEventSuccess extends CreateEventState {
  const CreateEventSuccess({required this.eventId, required this.sync});

  final String eventId;
  final CreateEventSync sync;

  @override
  List<Object?> get props => [eventId, sync];
}

/// The local create threw: a draft the repository refuses, or a fault.
/// Nothing was created.
///
/// Also the submit after a refusal whose discard threw. That create may still
/// be parked, so the next submit tries the discard again first.
final class CreateEventFailure extends CreateEventState {
  const CreateEventFailure();
}
