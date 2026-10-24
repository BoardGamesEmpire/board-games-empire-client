import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import '../overview/event_groups.dart';
import '../sync/event_hydration_status.dart';
import 'event_overview_event.dart';
import 'event_overview_state.dart';

/// Drives the events overview and each group's page (#497): the cached
/// events, grouped against the clock, plus what the hydrate is doing to
/// them.
///
/// The collection list's design (`GameCollectionListBloc`), for the same
/// reasons: the screen's state is a function of the cache and the hydrate,
/// and the cache stream ends in two ways that are not rows.
///
/// | cache | hydrate | state |
/// |---|---|---|
/// | nothing yet | any | loading |
/// | empty | running, and no pass has ever completed | loading |
/// | empty | anything else | ready, no rows |
/// | rows | any | ready: a populated cache is never hidden |
/// | error | any | error, until the cache emits rows again |
/// | ended, nothing read | any | error: nothing answered, and nothing will |
/// | ended, rows read | any | those rows, frozen |
///
/// An error is not terminal: drift keeps a stream open after a failed
/// query, so the next table update delivers rows on the same subscription.
/// Only rows clear it; a hydrate result is an annotation, not data.
///
/// A null [hydration] stream means there is no hydrate to wait for, which
/// reads as settled rather than as loading forever.
///
/// ## The households annotate
///
/// A row names its household from [households], the cached households, when
/// the event's is among them. The names are an annotation like the
/// hydrate's: they are never waited on, so the rows are up before the first
/// names arrive, and a stream error is logged and changes nothing. A null
/// stream means no names at all.
///
/// ## The clock
///
/// Every derivation groups the cached events again against [now], so an
/// event that ends while the overview is open moves to Past at the next
/// emission of any stream. Nothing writes to the cache when time passes,
/// and no timer is needed: the five-minute re-hydrate on entry and resume
/// supplies emissions (#300).
///
/// ## A re-check is not a first fill
///
/// Entering the overview runs a stale re-hydrate, so a pass over an answer
/// the overview already has is routine. "Empty and running" is loading only
/// until a pass has completed once; after that the emptiness is confirmed,
/// and re-checking it must not put the spinner back on every entry. A
/// failed pass confirms nothing. This is the household's #300 rule.
///
/// The status remembers which passes completed, not this bloc
/// ([EventHydration]). The overview is often opened while a pass is already
/// running, and a bloc that remembered only what it saw would treat that
/// pass as the first.
///
/// ## The warning outlasts the next pass
///
/// After a failed pass the banner stays up until a pass completes, not
/// until one starts: the rows are no fresher while the next one runs, and a
/// banner that vanished on start would take keyboard focus with it. A pass
/// nobody asked for is still not narrated (#300), so the banner keeps its
/// failed copy and its button.
///
/// ## The retry
///
/// The bloc calls [onRetry] rather than the button, because starting a pass
/// and saying one is running are the same event: the status stream reports
/// every pass as `running`, whoever started it. A retry from a failed read
/// runs the same pass, whose writes are what make drift run the read again.
class EventOverviewBloc extends Bloc<EventOverviewEvent, EventOverviewState> {
  EventOverviewBloc({
    required EventRepository repository,
    Stream<List<Household>>? households,
    Stream<EventHydration>? hydration,
    this._onRetry,
    DateTime Function()? now,
    BgeLogger? logger,
  }) : _now = now ?? DateTime.now,
       _logger = logger ?? BgeLogger('bge.events.overview'),
       super(const EventOverviewLoading()) {
    on<EventOverviewCacheUpdated>(_onCacheUpdated);
    on<EventOverviewCacheFailed>(_onCacheFailed);
    on<EventOverviewCacheEnded>(_onCacheEnded);
    on<EventOverviewHouseholdsUpdated>(_onHouseholdsUpdated);
    on<EventOverviewHydrationUpdated>(_onHydrationUpdated);
    on<EventOverviewRetryRequested>(_onRetryRequested);

    _cache = repository.watchAttendingEventListItems().listen(
      (items) => add(EventOverviewCacheUpdated(items)),
      onError: (Object error, StackTrace stackTrace) {
        _logger.warn(
          'Events overview read failed',
          error: error,
          stackTrace: stackTrace,
        );
        add(const EventOverviewCacheFailed());
      },
      onDone: () => add(const EventOverviewCacheEnded()),
    );

    _householdUpdates = households?.listen(
      (households) => add(EventOverviewHouseholdsUpdated(households)),
      // The names annotate the rows. Losing them must not lose the rows,
      // and the last names read stay up.
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Events overview households stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );

    _hydrationUpdates = hydration?.listen(
      (state) => add(EventOverviewHydrationUpdated(state)),
      // Nothing errors this stream today. If something does, the annotation
      // is what is lost, not the list it annotates.
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'Events hydration status stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  final DateTime Function() _now;
  final BgeLogger _logger;

  /// Runs one hydrate pass, or null where this composition has none.
  final Future<void> Function()? _onRetry;

  /// Whether a retry would run anything. Read by the screens to decide
  /// whether to draw a button at all, so a host cannot offer one this bloc
  /// would ignore.
  bool get canRetry => _onRetry != null;

  late final StreamSubscription<List<EventListItem>> _cache;
  StreamSubscription<List<Household>>? _householdUpdates;
  StreamSubscription<EventHydration>? _hydrationUpdates;

  /// Null until the cache has answered at all, which is not the same as
  /// having answered with nothing.
  List<EventListItem>? _items;

  /// Each cached household's name, by id. Empty until the households
  /// stream emits, and for good when there is none.
  Map<String, String> _householdNames = const {};

  /// Set by a failed read, cleared by the next rows.
  bool _readFailed = false;

  /// What the hydrate last reported. The default is also what an absent
  /// hydrate means: idle, nothing confirmed, nothing failed.
  EventHydration _hydration = const EventHydration();

  /// Whether a pass this screen asked for is still running.
  bool _retrying = false;

  void _onCacheUpdated(
    EventOverviewCacheUpdated event,
    Emitter<EventOverviewState> emit,
  ) {
    _readFailed = false;
    _items = event.items;
    _emitDerived(emit);
  }

  void _onCacheFailed(
    EventOverviewCacheFailed event,
    Emitter<EventOverviewState> emit,
  ) {
    _readFailed = true;
    emit(const EventOverviewError());
  }

  void _onCacheEnded(
    EventOverviewCacheEnded event,
    Emitter<EventOverviewState> emit,
  ) {
    // Rows already read stay up while the auth redirect pops the route.
    if (_items != null) return;
    // Held like a failed read: a closed stream will never send the rows
    // that would clear it, so a later hydrate result must not lift it.
    _readFailed = true;
    emit(const EventOverviewError());
  }

  void _onHouseholdsUpdated(
    EventOverviewHouseholdsUpdated event,
    Emitter<EventOverviewState> emit,
  ) {
    _householdNames = {for (final h in event.households) h.id: h.name};
    _emitDerived(emit);
  }

  void _onHydrationUpdated(
    EventOverviewHydrationUpdated event,
    Emitter<EventOverviewState> emit,
  ) {
    _hydration = event.hydration;
    _emitDerived(emit);
  }

  Future<void> _onRetryRequested(
    EventOverviewRetryRequested event,
    Emitter<EventOverviewState> emit,
  ) async {
    final retry = _onRetry;
    // The hydrator would join a second call rather than duplicate the
    // pass, but the button should not queue passes either.
    if (retry == null || _retrying) return;

    _retrying = true;
    _emitDerived(emit);

    try {
      await retry();
    } on Object catch (error, stackTrace) {
      // Unreachable by contract: the pass reports failure through the
      // status. Caught anyway, because the cost of being wrong is a stuck
      // "refreshing" the user cannot clear.
      _logger.warn(
        'Events refresh escaped its own error handling',
        error: error,
        stackTrace: stackTrace,
      );
    }

    _retrying = false;
    if (!isClosed) _emitDerived(emit);
  }

  void _emitDerived(Emitter<EventOverviewState> emit) {
    // Holds the error against everything except fresh rows.
    if (_readFailed) return emit(const EventOverviewError());

    final items = _items;
    if (items == null) return emit(const EventOverviewLoading());

    // Outranks [_retrying]: a retry over an unconfirmed empty list returns
    // to the spinner rather than annotating an emptiness no pass confirmed.
    final filling =
        items.isEmpty &&
        _hydration.state == EventHydrationState.running &&
        !_hydration.everRefreshed;
    if (filling) return emit(const EventOverviewLoading());

    emit(
      EventOverviewReady(
        groups: groupEvents(
          items,
          now: _now(),
          householdNames: _householdNames,
        ),
        refreshFailed: _hydration.lastPassFailed,
        refreshing: _retrying,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _cache.cancel();
    await _householdUpdates?.cancel();
    await _hydrationUpdates?.cancel();
    return super.close();
  }
}
