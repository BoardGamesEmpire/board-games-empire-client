import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Events of `EventDetailBloc`.
///
/// Mostly not user events: the screen shows what the cache, the read and
/// the households say, and these are how the bloc's subscriptions and its
/// read reach its handlers. The exception is [EventDetailRetryRequested],
/// the only event the screen sends.
sealed class EventDetailEvent extends Equatable {
  const EventDetailEvent();

  @override
  List<Object?> get props => [];
}

/// The cache emitted the event [eventId] as it now holds it, or null where
/// it holds nothing this user may read.
///
/// Carries the id it was read for because the bloc can move to a new one
/// (#499): the local id's watch can still have answers queued after the bloc
/// has followed a created event onto its server id.
final class EventDetailCacheUpdated extends EventDetailEvent {
  const EventDetailCacheUpdated(this.detail, {required this.eventId});

  final EventDetail? detail;
  final String eventId;

  @override
  List<Object?> get props => [detail, eventId];
}

/// The cache stream for [eventId] failed. Carries the id for the reason
/// [EventDetailCacheUpdated] does.
final class EventDetailCacheFailed extends EventDetailEvent {
  const EventDetailCacheFailed({required this.eventId});

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The cache stream ended: how a user-session teardown arrives, since
/// `WatchDisposal` closes vended streams rather than erroring them.
///
/// Carries no id, though its siblings do: only a session teardown ends a
/// vended stream, and it ends the local id's and the server id's together.
final class EventDetailCacheEnded extends EventDetailEvent {
  const EventDetailCacheEnded();
}

/// The cached households changed, so the name the header shows may have.
final class EventDetailHouseholdsUpdated extends EventDetailEvent {
  const EventDetailHouseholdsUpdated(this.households);

  final List<Household> households;

  @override
  List<Object?> get props => [households];
}

/// The viewer's role in household [householdId] is known: [role], or null
/// where they hold none or the lookup failed.
final class EventDetailHouseholdRoleResolved extends EventDetailEvent {
  const EventDetailHouseholdRoleResolved(this.householdId, this.role);

  final String householdId;
  final HouseholdRole? role;

  @override
  List<Object?> get props => [householdId, role];
}

/// How a read of `GET /events/:id` ended.
enum EventDetailReadOutcome {
  /// The server answered, and the answer is written to the cache, whose
  /// watch delivers it.
  succeeded,

  /// The read or its write failed, for any reason but a 404: offline, a
  /// refusal, a server error or a database one. The cache is all there is.
  failed,

  /// The server answered 404: the event is gone, or this user may no longer
  /// read it. Nothing has written the cache since the request went out.
  notFound,

  /// The server answered 404, and the forget is running: whether a write
  /// since the request went out has overtaken the 404 is not known yet.
  forgetting,

  /// The server answered 404, but the cache was written after the request
  /// went out, by a later open or a hydrate. That write is the newer news,
  /// so it wins, and the 404 counts for nothing.
  overtaken,
}

/// A read the bloc started of [eventId] has ended.
///
/// [rosterWithheld] says a read that succeeded carried an empty roster, one
/// the viewer may not see, which the cache can't keep (`EventDetailBloc`
/// has why). [eventId] is the id it read, which the bloc may have followed
/// a move off since (#499): the answer is about that id alone.
final class EventDetailReadSettled extends EventDetailEvent {
  const EventDetailReadSettled(
    this.outcome, {
    required this.eventId,
    this.rosterWithheld = false,
  });

  final EventDetailReadOutcome outcome;
  final String eventId;
  final bool rosterWithheld;

  @override
  List<Object?> get props => [outcome, eventId, rosterWithheld];
}

/// The user asked for the event to be read from the server again.
final class EventDetailRetryRequested extends EventDetailEvent {
  const EventDetailRetryRequested();
}
