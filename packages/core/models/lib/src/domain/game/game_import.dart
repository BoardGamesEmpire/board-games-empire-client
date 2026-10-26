/// What an import of a DataGateway's game reports (#43): the receipt
/// `POST /games/import` answers with, and the batch
/// `GET /games/import/:batchId` reports while the import runs.
///
/// Read-only, and stored nowhere. The import is followed only while its
/// dialog is open, and the game it ends with is cached when its detail is
/// read.
///
/// A completed job's [ImportJob.platformGames] are read because they are the
/// wire contract, but nothing uses them yet. Adding the game to a collection
/// (#45) starts from its detail, which lists its platform games once
/// `GET /games/:id` sends them (backend#791).
library;

import 'package:freezed_annotation/freezed_annotation.dart';

part 'game_import.freezed.dart';

/// Where one job of an import stands: the backend's `JobStatus`.
///
/// Pending and running are in flight. The rest are terminal.
enum ImportJobStatus {
  pending,
  running,
  completed,
  failed,
  cancelled,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole batch.
  static ImportJobStatus fromWire(String name) => switch (name) {
    'Pending' => ImportJobStatus.pending,
    'Running' => ImportJobStatus.running,
    'Completed' => ImportJobStatus.completed,
    'Failed' => ImportJobStatus.failed,
    'Cancelled' => ImportJobStatus.cancelled,
    _ => ImportJobStatus.unknown,
  };
}

/// The server's rollup of every job in an import batch: the backend's
/// `ImportBatchStatus`.
///
/// The base game's job decides how an import ended (#43), so this is read
/// but nothing decides by it.
enum ImportBatchStatus {
  pending,
  running,
  completed,
  partiallyCompleted,
  failed,
  cancelled,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole batch.
  static ImportBatchStatus fromWire(String name) => switch (name) {
    'Pending' => ImportBatchStatus.pending,
    'Running' => ImportBatchStatus.running,
    'Completed' => ImportBatchStatus.completed,
    'PartiallyCompleted' => ImportBatchStatus.partiallyCompleted,
    'Failed' => ImportBatchStatus.failed,
    'Cancelled' => ImportBatchStatus.cancelled,
    _ => ImportBatchStatus.unknown,
  };
}

/// Why an import job failed: the backend's `ImportErrorCode`.
enum ImportErrorCode {
  /// The DataGateway has no game with this id.
  notFound,

  /// Fetching the game from the DataGateway failed.
  gatewayError,

  /// The server failed to store the game.
  internalError,

  /// An expansion was never imported, because its base game's import failed.
  baseImportFailed,

  /// A code this client does not know. Never sent.
  unknown;

  /// Resolves the backend's code, degrading to [unknown] for one this client
  /// does not know rather than failing the whole batch.
  static ImportErrorCode fromWire(String code) => switch (code) {
    'NOT_FOUND' => ImportErrorCode.notFound,
    'GATEWAY_ERROR' => ImportErrorCode.gatewayError,
    'INTERNAL_ERROR' => ImportErrorCode.internalError,
    'BASE_IMPORT_FAILED' => ImportErrorCode.baseImportFailed,
    _ => ImportErrorCode.unknown,
  };
}

/// What `POST /games/import` answers once the import is queued: the batch to
/// poll, and the job importing the base game.
@freezed
abstract class GameImportReceipt with _$GameImportReceipt {
  const factory GameImportReceipt({
    required String batchId,
    required String baseJobId,

    /// The id the import was started with, as the server echoes it.
    required String correlationId,
  }) = _GameImportReceipt;
}

/// One platform game an import created or found for its game.
@freezed
abstract class ImportPlatformGame with _$ImportPlatformGame {
  const factory ImportPlatformGame({
    required String platformId,
    required String platformGameId,
  }) = _ImportPlatformGame;
}

/// One job of an import batch: the base game's, or an expansion's.
@freezed
abstract class ImportJob with _$ImportJob {
  const factory ImportJob({
    required String jobId,
    required ImportJobStatus status,

    /// False for the base game, true for an expansion imported with it.
    required bool isExpansion,

    /// The game's id at its DataGateway.
    required String externalId,

    /// The game's id on this server, once the job has completed.
    String? gameId,

    /// The game's title, once the job has completed.
    String? gameTitle,

    /// The platform games the import created or found, once the job has
    /// completed. Read but unused: see the library doc.
    @Default(<ImportPlatformGame>[]) List<ImportPlatformGame> platformGames,

    /// Why the job failed, once it has.
    ImportErrorCode? errorCode,
  }) = _ImportJob;
}

/// One import batch as `GET /games/import/:batchId` reports it: the base
/// game's job first, then any expansions'.
@freezed
abstract class ImportBatch with _$ImportBatch {
  const ImportBatch._();

  const factory ImportBatch({
    required String batchId,
    required String correlationId,
    required ImportBatchStatus status,
    required List<ImportJob> jobs,
  }) = _ImportBatch;

  /// The first job that is not an expansion; null when the server listed
  /// none.
  ImportJob? get baseJob => jobs.where((job) => !job.isExpansion).firstOrNull;
}
