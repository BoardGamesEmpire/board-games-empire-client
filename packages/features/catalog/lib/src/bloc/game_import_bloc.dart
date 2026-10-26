import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'game_import_event.dart';
import 'game_import_state.dart';
import 'uuid_v4.dart';

/// Imports one DataGateway result into the server, and follows the import
/// until its base game's job ends (#43).
///
/// ## Starting
///
/// [GameImportRequested] sends `POST /games/import` with a correlation id for
/// this attempt, a UUID v4. The first request starts the import, and one
/// after a failure tries again. Any other is ignored, as is every event that
/// arrives while one is being handled.
///
/// A start that got no answer ([GameImportFailure.unreachable]) keeps its
/// correlation id, so trying again sends the same one: the server may have
/// queued that start. Today the server starts a second batch anyway, which
/// does no harm, because importing a game again updates it. Once backend#900
/// keys import jobs on the correlation id, the same id will find the first
/// batch instead. A start the server answered, by queuing the import or by
/// refusing it, drops the id, so the next attempt takes a new one.
///
/// ## Following
///
/// Once queued, the batch is polled every [pollInterval] until [deadline]
/// has passed, because the server sets no deadline of its own.
///
/// - **The base game's job decides,** not the batch's rollup.
/// - **Pending, running, a status this client does not know, or no base job
///   listed:** keep polling. An unknown status may be one a newer server
///   still runs.
/// - **Completed** is [GameImportCompleted], with the game's id. A completed
///   job without one is a server failure.
/// - **Failed** is a failure by its error code: the DataGateway no longer
///   has the game, or did not answer. Any other code, or none, is a server
///   failure. **Cancelled** is [GameImportFailure.cancelled].
/// - **A poll that got no answer from the API keeps polling.** A 403 with
///   the API's envelope is [GameImportFailure.forbidden], and any other
///   failure, an unknown batch included, is a server failure.
///
/// When the polls run out, [GameImportStillRunning]: the server may still
/// finish. [GameImportCheckAgainRequested] polls the same batch again, with a
/// fresh count, and starts nothing.
///
/// ## Closing
///
/// No poll is sent, and nothing emitted, once the bloc has closed. The
/// server finishes the import anyway, and the next search shows the game as
/// one it holds.
class GameImportBloc extends Bloc<GameImportEvent, GameImportState> {
  GameImportBloc({
    required this._remote,
    required this.gatewayId,
    required this.externalId,
    String Function()? newCorrelationId,
    Future<void> Function(Duration)? wait,
    this.pollInterval = const Duration(seconds: 2),
    this.deadline = const Duration(seconds: 90),
    BgeLogger? logger,
  }) : _newCorrelationId = newCorrelationId ?? uuidV4,
       _wait = wait ?? Future<void>.delayed,
       _logger = logger ?? BgeLogger('bge.catalog.import'),
       super(const GameImportStarting()) {
    // One handler for both, so an event that arrives mid-import is dropped.
    on<GameImportEvent>(_onEvent, transformer: droppable());
  }

  /// The DataGateway the game is imported from.
  final String gatewayId;

  /// The game's id at [gatewayId].
  final String externalId;

  /// How long each poll waits before it is sent.
  final Duration pollInterval;

  /// How long the polls run before the import is said to be still running:
  /// the 90 seconds #43 settles on.
  ///
  /// It counts each wait as its [pollInterval] and each poll as long as it
  /// took, so a poll that waits out its timeouts uses up the deadline too.
  final Duration deadline;

  final GamesRemoteDataSource _remote;
  final String Function() _newCorrelationId;
  final Future<void> Function(Duration) _wait;
  final BgeLogger _logger;

  /// Whether the first [GameImportRequested] has arrived.
  bool _requested = false;

  /// The correlation id of an attempt whose start got no answer: see
  /// "Starting".
  String? _correlationId;

  /// The batch the server queued, which checking again polls.
  String? _batchId;

  Future<void> _onEvent(GameImportEvent event, Emitter<GameImportState> emit) =>
      switch (event) {
        GameImportRequested() => _onRequested(emit),
        GameImportCheckAgainRequested() => _onCheckAgain(emit),
      };

  Future<void> _onRequested(Emitter<GameImportState> emit) async {
    if (_requested && state is! GameImportFailed) return;
    _requested = true;
    emit(const GameImportStarting());

    final GameImportReceipt receipt;
    try {
      receipt = await _remote.startImport(
        gatewayId: gatewayId,
        externalId: externalId,
        correlationId: _correlationId ??= _newCorrelationId(),
      );
    } on GamesRemoteTransientException {
      // The correlation id stays: the server may have queued this start (see
      // "Starting").
      return emit(
        const GameImportFailed(failure: GameImportFailure.unreachable),
      );
    } on GamesForbiddenException {
      _correlationId = null;
      return emit(const GameImportFailed(failure: GameImportFailure.forbidden));
    } on Object catch (error, stackTrace) {
      _correlationId = null;
      _logger.warn(
        'Starting the import failed',
        error: error,
        stackTrace: stackTrace,
      );
      return emit(const GameImportFailed(failure: GameImportFailure.server));
    }
    if (isClosed) return;

    _correlationId = null;
    _batchId = receipt.batchId;
    emit(const GameImportInProgress(running: false));
    await _poll(receipt.batchId, emit);
  }

  Future<void> _onCheckAgain(Emitter<GameImportState> emit) async {
    final batchId = _batchId;
    if (state is! GameImportStillRunning || batchId == null) return;

    emit(const GameImportInProgress(running: true));
    await _poll(batchId, emit);
  }

  /// Polls [batchId] until its base game's job ends, or [deadline] passes.
  Future<void> _poll(String batchId, Emitter<GameImportState> emit) async {
    var elapsed = Duration.zero;
    while (elapsed < deadline) {
      await _wait(pollInterval);
      elapsed += pollInterval;
      if (isClosed) return;

      final ImportBatch batch;
      final request = Stopwatch()..start();
      try {
        batch = await _remote.fetchImport(batchId);
      } on GamesRemoteTransientException {
        // No answer from the API says nothing about the import.
        continue;
      } on GamesForbiddenException {
        return emit(
          const GameImportFailed(failure: GameImportFailure.forbidden),
        );
      } on Object catch (error, stackTrace) {
        _logger.warn(
          'Polling the import failed',
          error: error,
          stackTrace: stackTrace,
        );
        return emit(const GameImportFailed(failure: GameImportFailure.server));
      } finally {
        elapsed += request.elapsed;
      }
      if (isClosed) return;

      final next = _stateOf(batch.baseJob);
      emit(next);
      if (next is! GameImportInProgress) return;
    }
    if (isClosed) return;
    emit(const GameImportStillRunning());
  }

  /// Where the import stands, by its base game's job: see "Following".
  static GameImportState _stateOf(ImportJob? baseJob) => switch (baseJob) {
    null ||
    ImportJob(
      status: ImportJobStatus.running || ImportJobStatus.unknown,
    ) => const GameImportInProgress(running: true),
    ImportJob(status: ImportJobStatus.pending) => const GameImportInProgress(
      running: false,
    ),
    ImportJob(status: ImportJobStatus.completed, :final gameId?) =>
      GameImportCompleted(gameId: gameId),
    ImportJob(status: ImportJobStatus.completed) => const GameImportFailed(
      failure: GameImportFailure.server,
    ),
    ImportJob(status: ImportJobStatus.failed, :final errorCode) =>
      GameImportFailed(
        failure: switch (errorCode) {
          ImportErrorCode.notFound => GameImportFailure.notOnDataGateway,
          ImportErrorCode.gatewayError => GameImportFailure.dataGateway,
          _ => GameImportFailure.server,
        },
      ),
    ImportJob(status: ImportJobStatus.cancelled) => const GameImportFailed(
      failure: GameImportFailure.cancelled,
    ),
  };
}
