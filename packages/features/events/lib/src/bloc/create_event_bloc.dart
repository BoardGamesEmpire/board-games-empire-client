import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'create_event_event.dart';
import 'create_event_state.dart';

/// Drives the event create form (#499): the local write, then one send of it
/// straight away, as the household create does.
///
/// 1. [EventRepository.create] writes the local-only event and queues its
///    `CreateEventOperation`, in one transaction. A draft it refuses, or a
///    fault, is [CreateEventFailure], and nothing was written.
/// 2. The op as queued goes out once through [SyncOperationSender.deliver],
///    the one delivery path the queue drain takes too. It claims the entry
///    first, so this send and a drain can't both deliver it, and keys the
///    create by the op's `localId`, so a send whose answer is lost cannot
///    become a second event on the retry.
///    - delivered → the cache holds the server's event and the op is closed
///      → [CreateEventSuccess] with [CreateEventSync.synced], under the
///      server's id.
///    - parked → the server refused it as it stands → [CreateEventRefused],
///      naming the invitee its 404 names. The form stays open. A 403 for a
///      create in a household also reads the user's households again
///      ([_onRefresh]): their role there may have changed on another
///      device, and the form offers only households the cache says they
///      may create in.
///    - anything else → the event stays queued, and the create still
///      succeeded locally → [CreateEventSuccess] with
///      [CreateEventSync.queued], under the local id. What became of the
///      queue entry is the sender's to record, and the drain's to retry.
///
/// A delivery that throws means the claim itself failed and nothing was
/// sent, which also leaves the event queued.
///
/// Only this first send's refusal reaches the form. A create the drain sends
/// later, and the server refuses then, is parked for the sync queue's own
/// surface (#190).
///
/// ## A refusal and the next submit
///
/// A refused create stays parked with its local-only event, so the bloc
/// keeps its queue entry and local id. The next submit, with the invitee
/// taken off say, first discards the parked create and its local-only event
/// ([EventRepository.discardQueuedOp]), then creates afresh under a new
/// local id:
///
/// - discarded → the bloc forgets them, and the submit goes on as any other.
///   Another refusal keeps the new create in their place.
/// - declined → another tab has retried the parked create since, or
///   discarded it from the sync queue's surface (#190). The bloc reads the
///   event under the kept local id ([EventRepository.watchEvent]), and then
///   the move a reconcile recorded for it
///   ([EventRepository.reconciledEventId]):
///   - the event is there → a retry stands, on its way or landed under the
///     local id → [CreateEventSuccess] under that id, queued or synced as
///     the event is still local-only or not. Nothing new is created.
///   - it moved → a retry landed under the server's id →
///     [CreateEventSuccess] with [CreateEventSync.synced] under that id.
///     Nothing new is created.
///   - neither → it was discarded, and the submit goes on as any other.
///   - the read throws → [CreateEventFailure], and nothing is created. The
///     bloc keeps the parked create, and the next submit tries again.
/// - throws → [CreateEventFailure], and nothing is created. The create may
///   still be parked, so the bloc keeps it, and the next submit tries the
///   discard again.
///
/// The move is read only after the watch has emitted: the repository reads
/// a move another tab recorded before it delivers each emission, and not
/// before. Asked any earlier, a retry that landed would read as a discard,
/// and the draft would become a second event.
///
/// [CreateEventFailureCleared] keeps the parked create too: the screen sends
/// it on every edit, and an edit is what a refusal asks for before the next
/// submit.
class CreateEventBloc extends Bloc<CreateEventEvent, CreateEventState> {
  CreateEventBloc({
    required this._repository,
    required this._sender,
    this._onRefresh,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.create'),
       super(const CreateEventInitial()) {
    on<CreateEventSubmitted>(_onSubmitted);
    on<CreateEventFailureCleared>(_onFailureCleared);
  }

  final EventRepository _repository;
  final SyncOperationSender _sender;

  /// Reads the user's households again. Started, never awaited, after a
  /// 403 for a create in a household.
  final Future<void> Function()? _onRefresh;
  final BgeLogger _logger;

  /// The queue entry and local id of the create a send left parked, until a
  /// submit discards it.
  ({String syncQueueId, String localId})? _parked;

  /// Takes a refusal or a failure down once the user edits the form. A
  /// stray event can't wipe a submit in flight or a success, and the parked
  /// create stays kept.
  void _onFailureCleared(
    CreateEventFailureCleared event,
    Emitter<CreateEventState> emit,
  ) {
    if (state case CreateEventRefused() || CreateEventFailure()) {
      emit(const CreateEventInitial());
    }
  }

  Future<void> _onSubmitted(
    CreateEventSubmitted event,
    Emitter<CreateEventState> emit,
  ) async {
    // Re-entrancy guard: ignore submits while one is in flight.
    if (state is CreateEventSubmitting) return;
    emit(const CreateEventSubmitting());

    if (_parked case final parked?) {
      final bool discarded;
      try {
        discarded = await _repository.discardQueuedOp(parked.syncQueueId);
      } on Object catch (error, stackTrace) {
        _logger.error(
          'Could not discard the refused event create; kept for the next '
          'submit',
          error: error,
          stackTrace: stackTrace,
        );
        emit(const CreateEventFailure());
        return;
      }
      if (!discarded) {
        final CreateEventSuccess? retried;
        try {
          retried = await _retriedElsewhere(parked.localId);
        } on Object catch (error, stackTrace) {
          _logger.error(
            'Could not read what became of the refused event create; kept '
            'for the next submit',
            error: error,
            stackTrace: stackTrace,
          );
          emit(const CreateEventFailure());
          return;
        }
        if (retried != null) {
          _parked = null;
          _logger.info(
            'Discard of the refused event create declined: retried '
            'elsewhere since; nothing new created',
          );
          emit(retried);
          return;
        }
        _logger.info(
          'Discard of the refused event create declined: discarded '
          'elsewhere since; creating the draft',
        );
      }
      _parked = null;
    }

    final ({Event event, String syncQueueId, CreateEventOperation operation})
    created;
    try {
      created = await _repository.create(event.draft);
    } on Object catch (error, stackTrace) {
      _logger.error(
        'Local event create failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const CreateEventFailure());
      return;
    }

    // From here the event is written and queued, so every outcome below but
    // a refusal is a success; only `sync` varies.
    final localId = created.event.id;
    final queued = CreateEventSuccess(
      eventId: localId,
      sync: CreateEventSync.queued,
    );

    final SyncDelivery delivery;
    try {
      // The op exactly as the repository queued it, so this send carries
      // what a drain's retry would.
      delivery = await _sender.deliver(created.syncQueueId, created.operation);
    } on Object catch (error, stackTrace) {
      _logger.error(
        'Could not claim the queued event create; left queued',
        error: error,
        stackTrace: stackTrace,
      );
      emit(queued);
      return;
    }

    switch (delivery) {
      case SyncDelivered(:final eventId):
        emit(
          CreateEventSuccess(
            eventId: eventId ?? localId,
            sync: CreateEventSync.synced,
          ),
        );
      case SyncParked(:final error):
        _parked = (syncQueueId: created.syncQueueId, localId: localId);
        if (error case EventCreateRefusedException(statusCode: 403)
            when created.operation.draft.householdId != null) {
          _refresh();
        }
        emit(
          CreateEventRefused(
            // The draft as the op carries it: what the server judged.
            inviteeId: _refusedInvitee(error, created.operation.draft),
          ),
        );
      case SyncNotClaimed() || SyncFailed():
        emit(queued);
    }
  }

  /// What a retry made of the parked create under [localId], as success,
  /// or null if nothing did: it was discarded.
  ///
  /// The watch's first emission comes after the repository has read the
  /// event's move, so [EventRepository.reconciledEventId] answers for a
  /// reconcile another tab made too.
  Future<CreateEventSuccess?> _retriedElsewhere(String localId) async {
    final detail = await _repository.watchEvent(localId).first;
    if (detail != null) {
      return CreateEventSuccess(
        eventId: localId,
        sync: detail.snapshot.event.isLocalOnly
            ? CreateEventSync.queued
            : CreateEventSync.synced,
      );
    }
    final movedTo = _repository.reconciledEventId(localId);
    if (movedTo == null) return null;
    return CreateEventSuccess(eventId: movedTo, sync: CreateEventSync.synced);
  }

  void _refresh() {
    final onRefresh = _onRefresh;
    if (onRefresh == null) return;
    unawaited(_runRefresh(onRefresh));
  }

  Future<void> _runRefresh(Future<void> Function() onRefresh) async {
    try {
      await onRefresh();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household refresh after a refused event create failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// The first of [draft]'s invitees that [error] names, or null.
  ///
  /// Only the API's 404 is read: the server answers an invitee it has no
  /// account for with their id in its message. Its 403 won't say which
  /// invitee it refused, or why.
  static String? _refusedInvitee(Object error, EventDraft draft) {
    if (error case EventCreateRefusedException(
      statusCode: 404,
      :final apiMessage?,
    )) {
      return draft.inviteUserIds.where(apiMessage.contains).firstOrNull;
    }
    return null;
  }
}
