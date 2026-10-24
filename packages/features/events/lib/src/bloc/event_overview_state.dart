import 'package:equatable/equatable.dart';

import '../overview/event_groups.dart';

/// What the events overview is showing (#497).
///
/// The collection list's three states: *empty* is [EventOverviewReady] with
/// every group empty, so "empty, and possibly stale" is one value rather
/// than an awkward pair.
sealed class EventOverviewState extends Equatable {
  const EventOverviewState();

  @override
  List<Object?> get props => [];
}

/// Nothing to show yet: the cache has not emitted, or it emitted nothing
/// while a hydrate is filling it for the first time.
final class EventOverviewLoading extends EventOverviewState {
  const EventOverviewLoading();
}

/// The cache's current answer, grouped. [groups] may all be empty, which
/// means there genuinely are no events: a pass has confirmed it, or there is
/// no hydrate to wait for.
///
/// [refreshFailed] says the last pass to finish ended early, so the rows may
/// be stale. A pass starting does not clear it; one completing does.
/// [refreshing] says a pass **the user asked for** is running; passes
/// started by entry, reconnect or resume are not narrated.
final class EventOverviewReady extends EventOverviewState {
  const EventOverviewReady({
    required this.groups,
    this.refreshFailed = false,
    this.refreshing = false,
  });

  final EventGroups groups;
  final bool refreshFailed;
  final bool refreshing;

  @override
  List<Object?> get props => [groups, refreshFailed, refreshing];
}

/// The cache read itself failed, so there is nothing to show.
///
/// Two ways in: a read delivered as a stream error, such as an
/// unauthenticated one while a session ends, and a stream that closes on
/// teardown before it ever emitted.
final class EventOverviewError extends EventOverviewState {
  const EventOverviewError();
}
