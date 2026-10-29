import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../detail/event_actions.dart';

/// What the event detail screen is showing (#498).
///
/// Four states, as the household detail's are: [EventDetailNotFound] is the
/// server's answer about the event, not a fault, and [EventDetailError] is
/// a read that failed with nothing cached to show instead.
sealed class EventDetailState extends Equatable {
  const EventDetailState();

  @override
  List<Object?> get props => [];
}

/// Nothing to show yet: the cache has not answered, or it holds nothing and
/// the open's read, or what that read wrote, has not reached it yet.
final class EventDetailLoading extends EventDetailState {
  const EventDetailLoading();
}

/// The event as the cache holds it, but for a roster the latest read
/// withheld: the cache reads that back as null, and [detail] has it empty
/// (`EventDetailBloc` has why).
///
/// [householdName] names the event's household from the cached households,
/// and is null where the event has none or they don't name it. [actions]
/// is what the viewer may do to it, by their role on it and, on a
/// household event, in its household.
///
/// [refreshing] says a read **the user asked for** is running. The read
/// every open makes is not narrated. [reading] says a read is running
/// whoever asked for it, which is what the screen holds Delete and the date
/// writes on (#501, #506).
/// [refreshFailed] says the last read to finish failed, so this is the
/// cache, possibly stale. A read starting does not clear it; one succeeding
/// does.
///
/// [canRetry] says a retry would read anything, for the screen to decide
/// whether to draw its button at all (`EventDetailBloc` has when). It is
/// state rather than a question put to the bloc, so the button goes the
/// moment the retry would stop working.
final class EventDetailReady extends EventDetailState {
  const EventDetailReady({
    required this.detail,
    required this.actions,
    this.householdName,
    this.refreshing = false,
    this.reading = false,
    this.refreshFailed = false,
    this.canRetry = false,
  });

  final EventDetail detail;
  final String? householdName;
  final Set<EventAction> actions;
  final bool refreshing;

  /// Whether a read of this event is running, the open's or a retry's, until
  /// it settles: for a read that succeeds, after its answer has been written
  /// to the cache; for one answered 404, after its forget. Delete and the
  /// date writes wait on it, because a read's 200 landing after a write
  /// would cache the event as it was (#501, #506).
  final bool reading;
  final bool refreshFailed;
  final bool canRetry;

  @override
  List<Object?> get props => [
    detail,
    householdName,
    actions,
    refreshing,
    reading,
    refreshFailed,
    canRetry,
  ];
}

/// The server answered 404 for this event, or nothing holds it and nothing
/// will read it: no server to ask, or a read that succeeded and was then
/// taken away.
///
/// One state for every cause, because the server's 404 deliberately does
/// not say whether the event was deleted or this user may no longer read
/// it. Once the server has said so it holds for the screen's life, while the
/// forget empties the cache under it.
final class EventDetailNotFound extends EventDetailState {
  const EventDetailNotFound();
}

/// Nothing cached to show, and nothing that will answer: the read failed,
/// the cache read itself failed, or the cache stream closed before it could
/// deliver one.
///
/// [refreshing] says a read the user asked for from here is running, so the
/// error stays up with its retry in progress rather than giving way to a
/// spinner. [canRetry] is [EventDetailReady.canRetry]'s.
final class EventDetailError extends EventDetailState {
  const EventDetailError({this.refreshing = false, this.canRetry = false});

  final bool refreshing;
  final bool canRetry;

  @override
  List<Object?> get props => [refreshing, canRetry];
}
