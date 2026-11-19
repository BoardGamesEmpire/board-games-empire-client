import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/src/bloc/game_import_event.dart';
import 'package:game_catalog/src/bloc/game_import_state.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Imports one DataGateway result into the server, with the expansions chosen
/// for it, and follows the import until every job in its batch has ended
/// (#43, #896, #824).
///
/// ## Starting
///
/// [GameImportRequested] sends `POST /games/import` with a correlation id for
/// this attempt, a UUID v4, and the [expansionExternalIds] chosen with the
/// game. The first request starts the import, and one after a failure tries
/// again. Any other is ignored, as is every event that arrives while one is
/// being handled.
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
/// Once queued, the batch is polled every [pollInterval] until its jobs have
/// ended, or until [deadlineFor] its job count has passed, because the server
/// sets no deadline of its own. The count is the latest poll's, and one job
/// before the first.
///
/// The import ends when no job of the batch is pending or running (#824).
/// Until then the batch's jobs say where it stands:
///
/// - **No requested job listed:** keep polling.
/// - **Any job pending, running, or in a status this client does not know:**
///   keep polling, whatever the requested game's job says. An unknown status
///   may be one a newer server still runs. A failed requested game is no
///   exception: the server cancels only the pending jobs that needed it, and
///   a running one goes on to its own end.
/// - **The requested game failed or was cancelled:** [GameImportFailed]. A
///   failure is by its error code: the DataGateway no longer has the game,
///   or did not answer. Any other code, or none, is a server failure.
///   **Cancelled** is [GameImportFailure.cancelled].
/// - **The requested game completed without a game id:** a server failure.
/// - **Every job completed:** [GameImportCompleted], with the requested
///   game's id.
/// - **Another job did not complete:** [GameImportPartlyCompleted], with the
///   requested game's id.
/// - **A poll that got no answer from the API keeps polling.** A 403 with
///   the API's envelope is [GameImportFailure.forbidden], and any other
///   failure, an unknown batch included, is a server failure. Once a poll
///   has seen the requested game completed, though, either is
///   [GameImportStillRunning] with its id: that game is on the server, and
///   only the rest of the batch can't be followed.
///
/// Every state after a poll carries that poll's jobs.
///
/// When the polls run out, [GameImportStillRunning]: the server may still
/// finish. A requested game whose own job has completed by then is on the
/// server, so the state carries its id, and the game can be opened while the
/// rest run on. [GameImportCheckAgainRequested] polls the same batch again,
/// with a fresh count, and starts nothing. A requested game that has failed,
/// been cancelled, or completed without a game id by then is
/// [GameImportFailed] as above instead: its outcome is known, whatever the
/// other jobs are still doing.
///
/// Trying again after that failure queues a new batch beside the one whose
/// jobs still run, and both may import the same games. That does no harm:
/// the server makes one game of two imports of it that race, and updates
/// it with the later.
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
    this.expansionExternalIds = const [],
    String Function()? newCorrelationId,
    Future<void> Function(Duration)? wait,
    this.pollInterval = const Duration(seconds: 2),
    this.baseDeadline = defaultBaseDeadline,
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

  /// The expansions imported with the game, by their ids at [gatewayId].
  final List<String> expansionExternalIds;

  /// How long each poll waits before it is sent.
  final Duration pollInterval;

  /// How long the polls run for a one-job batch before the import is said to
  /// be still running: the 90 seconds #43 settles on. A bigger batch gets
  /// longer: see [deadlineFor].
  ///
  /// It counts each wait as its [pollInterval] and each poll as long as it
  /// took, so a poll that waits out its timeouts uses up the deadline too.
  final Duration baseDeadline;

  /// The deadline of a one-job batch: the 90 seconds #43 settles on.
  static const Duration defaultBaseDeadline = Duration(seconds: 90);

  static const _perExtraJob = Duration(seconds: 30);
  static const _deadlineCap = Duration(minutes: 10);

  /// How long the polls run for a batch of [jobCount] jobs: [base], and 30
  /// seconds more for each job after the first, to at most 10 minutes (#824).
  static Duration deadlineFor(
    int jobCount, {
    Duration base = defaultBaseDeadline,
  }) {
    final extra = _perExtraJob * (jobCount < 1 ? 0 : jobCount - 1);
    final total = base + extra;
    return total > _deadlineCap ? _deadlineCap : total;
  }

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

  /// The jobs of the latest poll that answered; empty before one has.
  List<ImportJob> _jobs = const [];

  /// The requested game's job in [_jobs], once a poll has listed it.
  ImportJob? _requestedJob;

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
        expansionExternalIds: expansionExternalIds,
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
    _jobs = const [];
    _requestedJob = null;
    emit(const GameImportInProgress(running: false));
    await _poll(receipt.batchId, emit);
  }

  Future<void> _onCheckAgain(Emitter<GameImportState> emit) async {
    final batchId = _batchId;
    if (state is! GameImportStillRunning || batchId == null) return;

    emit(GameImportInProgress(running: true, jobs: _jobs));
    await _poll(batchId, emit);
  }

  /// Polls [batchId] until its jobs end, or the deadline for its job count
  /// passes.
  Future<void> _poll(String batchId, Emitter<GameImportState> emit) async {
    var elapsed = Duration.zero;
    var deadline = deadlineFor(_jobs.length, base: baseDeadline);
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
        return emit(_unfollowable(GameImportFailure.forbidden));
      } on Object catch (error, stackTrace) {
        _logger.warn(
          'Polling the import failed',
          error: error,
          stackTrace: stackTrace,
        );
        return emit(_unfollowable(GameImportFailure.server));
      } finally {
        elapsed += request.elapsed;
      }
      if (isClosed) return;

      _jobs = batch.jobs;
      _requestedJob = batch.requestedJob;
      deadline = deadlineFor(_jobs.length, base: baseDeadline);
      final next = _stateOf(batch);
      emit(next);
      if (next is! GameImportInProgress) return;
    }
    if (isClosed) return;
    final requested = _requestedJob;
    final failure = _failureOf(requested);
    emit(
      failure == null
          ? GameImportStillRunning(
              gameId: switch (requested) {
                ImportJob(status: ImportJobStatus.completed, :final gameId) =>
                  gameId,
                _ => null,
              },
              jobs: _jobs,
            )
          : GameImportFailed(failure: failure, jobs: _jobs),
    );
  }

  /// Where the import stands after a poll that failed for [failure]: see
  /// "Following". A requested game an earlier poll saw completed is on the
  /// server whatever this poll says, so its id is kept, and the batch is
  /// still running, to be checked again; before then, the import failed.
  GameImportState _unfollowable(GameImportFailure failure) =>
      switch (_requestedJob) {
        ImportJob(status: ImportJobStatus.completed, :final gameId?) =>
          GameImportStillRunning(gameId: gameId, jobs: _jobs),
        _ => GameImportFailed(failure: failure, jobs: _jobs),
      };

  /// Where the import stands, by the jobs of its batch: see "Following".
  static GameImportState _stateOf(ImportBatch batch) {
    final jobs = batch.jobs;
    final requested = batch.requestedJob;
    if (requested == null) {
      return GameImportInProgress(running: true, jobs: jobs);
    }

    final ended = jobs.every(
      (job) => switch (job.status) {
        ImportJobStatus.completed ||
        ImportJobStatus.failed ||
        ImportJobStatus.cancelled => true,
        _ => false,
      },
    );
    if (!ended) {
      return GameImportInProgress(
        running: requested.status != ImportJobStatus.pending,
        jobs: jobs,
      );
    }

    final failure = _failureOf(requested);
    if (failure != null) return GameImportFailed(failure: failure, jobs: jobs);

    final gameId = requested.gameId;
    if (gameId == null) {
      return GameImportFailed(failure: GameImportFailure.server, jobs: jobs);
    }
    return jobs.every((job) => job.status == ImportJobStatus.completed)
        ? GameImportCompleted(gameId: gameId, jobs: jobs)
        : GameImportPartlyCompleted(gameId: gameId, jobs: jobs);
  }

  /// Why the [requested] game's job ended without its game, or null while it
  /// hasn't: see "Following". A job completed without a game id is a server
  /// failure here, so the deadline and the batch's end judge it alike.
  static GameImportFailure? _failureOf(ImportJob? requested) =>
      switch (requested?.status) {
        ImportJobStatus.failed => switch (requested?.errorCode) {
          ImportErrorCode.notFound => GameImportFailure.notOnDataGateway,
          ImportErrorCode.gatewayError => GameImportFailure.dataGateway,
          _ => GameImportFailure.server,
        },
        ImportJobStatus.cancelled => GameImportFailure.cancelled,
        ImportJobStatus.completed when requested?.gameId == null =>
          GameImportFailure.server,
        _ => null,
      };
}
