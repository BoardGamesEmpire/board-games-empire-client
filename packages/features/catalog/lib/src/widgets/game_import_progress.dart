import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_import_bloc.dart';
import 'package:game_catalog/src/bloc/game_import_event.dart';
import 'package:game_catalog/src/bloc/game_import_state.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Where an import stands, in place: one status line, a row for each game of
/// the import once there is more than one, and what the user can do next
/// (#43, #824).
///
/// It reads the [GameImportBloc] provided above it and owns none. The quick
/// look hosts it where the import button was, so the import goes on in the
/// place the user started it, and nothing opens over it.
///
/// ## Ending
///
/// [onImported] runs once, when the requested game is on the server and every
/// other game of the import is too. When some of the others are not, the
/// status says so and an Open button calls [onImported] when the user
/// chooses.
class GameImportProgress extends StatefulWidget {
  const GameImportProgress({
    required this.requestedTitle,
    required this.onImported,
    this.titlesByExternalId = const {},
    this.autofocus = false,
    super.key,
  });

  /// One status line, in a live region that keeps its node across states.
  static const Key statusKey = Key('catalog_import.status');

  /// The row of the job [jobId].
  static Key jobKey(String jobId) => Key('catalog_import.job.$jobId');

  static const Key checkAgainKey = Key('catalog_import.check_again');
  static const Key tryAgainKey = Key('catalog_import.try_again');
  static const Key openKey = Key('catalog_import.open');

  /// The requested game's title, for its row and the summaries until the
  /// server names it.
  final String requestedTitle;

  /// Titles the caller knows by External ID, for the rows of games the server
  /// has not named yet: the expansions chosen with the game.
  final Map<String, String> titlesByExternalId;

  /// Called with the requested game's id: once when the import completes, and
  /// on each press of Open after it completes in part.
  final void Function(BuildContext context, String gameId) onImported;

  /// Whether the status takes focus when this is first built, so a screen
  /// reader lands on where the import stands.
  final bool autofocus;

  @override
  State<GameImportProgress> createState() => _GameImportProgressState();
}

class _GameImportProgressState extends State<GameImportProgress> {
  /// Whether [GameImportProgress.onImported] has run for a completion: the
  /// bloc, or a stream standing in for it, may announce it twice.
  bool _imported = false;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    return BlocConsumer<GameImportBloc, GameImportState>(
      listenWhen: (_, state) => state is GameImportCompleted,
      listener: (context, state) {
        if (state is! GameImportCompleted || _imported) return;
        _imported = true;
        widget.onImported(context, state.gameId);
      },
      builder: (context, state) {
        final bloc = context.read<GameImportBloc>();
        final jobs = state.jobs;
        final offline = BgeConnectivityScope.offlineOf(context);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Focus(
              autofocus: widget.autofocus,
              child: _status(context, l10n, state),
            ),
            if (jobs.length > 1) ...[
              SizedBox(height: tokens.spaceSm),
              Semantics(
                container: true,
                label: l10n.catalogImportBatchLabel(jobs.length),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final job in jobs)
                      Padding(
                        padding: EdgeInsets.only(top: tokens.spaceXs),
                        child: _JobRow(
                          key: GameImportProgress.jobKey(job.jobId),
                          title: _rowTitle(l10n, job, jobs),
                          status: _jobStatus(l10n, job),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (state is GameImportFailed &&
                _mayTryAgain(state.failure) &&
                offline) ...[
              SizedBox(height: tokens.spaceSm),
              const BgeOnlineOnlyNote(),
            ],
            if (state is GameImportStillRunning) ...[
              SizedBox(height: tokens.spaceSm),
              TextButton(
                key: GameImportProgress.checkAgainKey,
                onPressed: () =>
                    bloc.add(const GameImportCheckAgainRequested()),
                child: Text(l10n.catalogImportCheckAgain),
              ),
            ],
            if (state case GameImportFailed(:final failure)
                when _mayTryAgain(failure)) ...[
              SizedBox(height: tokens.spaceSm),
              // A new import is a write (#49). Check again only reads.
              BgeOnlineOnly(
                showNote: false,
                child: TextButton(
                  key: GameImportProgress.tryAgainKey,
                  onPressed: offline
                      ? null
                      : () => bloc.add(const GameImportRequested()),
                  child: Text(l10n.catalogImportTryAgain),
                ),
              ),
            ],
            if (state case GameImportPartlyCompleted(:final gameId)) ...[
              SizedBox(height: tokens.spaceSm),
              FilledButton(
                key: GameImportProgress.openKey,
                onPressed: () => widget.onImported(context, gameId),
                child: Text(l10n.catalogImportOpenGame(_requestedTitle(jobs))),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The requested job: the batch's first, as the server reports it.
  ImportJob? _requestedJob(List<ImportJob> jobs) =>
      jobs.where((job) => job.origin == ImportJobOrigin.requested).firstOrNull;

  String _requestedTitle(List<ImportJob> jobs) =>
      _requestedJob(jobs)?.gameTitle ?? widget.requestedTitle;

  /// The title [job] is known by, or null while nothing names it.
  String? _titleOf(ImportJob job) =>
      job.gameTitle ??
      widget.titlesByExternalId[job.externalId] ??
      (job.origin == ImportJobOrigin.requested ? widget.requestedTitle : null);

  String _rowTitle(
    GameCatalogLocalizations l10n,
    ImportJob job,
    List<ImportJob> jobs,
  ) {
    final title = _titleOf(job);
    if (job.origin != ImportJobOrigin.addedBaseGame) {
      return title ?? l10n.catalogImportJobUntitled;
    }
    final parent = jobs
        .where((other) => other.jobId == job.parentJobId)
        .firstOrNull;
    final parentTitle =
        (parent == null ? null : _titleOf(parent)) ?? widget.requestedTitle;
    return title == null
        ? l10n.catalogImportJobAddedBaseGameUntitled(parentTitle)
        : l10n.catalogImportJobAddedBaseGame(title, parentTitle);
  }

  static String _jobStatus(GameCatalogLocalizations l10n, ImportJob job) {
    final skipped =
        job.errorCode == ImportErrorCode.baseImportFailed &&
        (job.status == ImportJobStatus.failed ||
            job.status == ImportJobStatus.cancelled);
    if (skipped) return l10n.catalogImportJobSkipped;
    return switch (job.status) {
      ImportJobStatus.pending => l10n.catalogImportJobWaiting,
      ImportJobStatus.running ||
      ImportJobStatus.unknown => l10n.catalogImportJobImporting,
      ImportJobStatus.completed => l10n.catalogImportJobImported,
      ImportJobStatus.failed => l10n.catalogImportJobFailed,
      ImportJobStatus.cancelled => l10n.catalogImportJobCancelled,
    };
  }

  Widget _status(
    BuildContext context,
    GameCatalogLocalizations l10n,
    GameImportState state,
  ) {
    final (text, progress) = switch (state) {
      GameImportStarting() => (l10n.catalogImportStarting, true),
      GameImportInProgress(running: false) => (l10n.catalogImportQueued, true),
      // A completed import hands over at once, which goes on showing it as
      // running while the caller replaces this.
      GameImportInProgress() ||
      GameImportCompleted() => (l10n.catalogImportRunning, true),
      GameImportStillRunning() => (l10n.catalogImportStillRunning, false),
      GameImportPartlyCompleted() => (
        l10n.catalogImportPartlyCompleted(
          _requestedTitle(state.jobs),
          state.jobs
              .where(
                (job) =>
                    job.origin != ImportJobOrigin.requested &&
                    job.status != ImportJobStatus.completed,
              )
              .length,
        ),
        false,
      ),
      GameImportFailed(:final failure) => (_failureCopy(l10n, failure), false),
    };
    return _Status(text, progress: progress);
  }

  static String _failureCopy(
    GameCatalogLocalizations l10n,
    GameImportFailure failure,
  ) => switch (failure) {
    GameImportFailure.notOnDataGateway =>
      l10n.catalogImportFailedNotOnDataGateway,
    GameImportFailure.dataGateway => l10n.catalogImportFailedDataGateway,
    GameImportFailure.server => l10n.catalogImportFailedServer,
    GameImportFailure.cancelled => l10n.catalogImportFailedCancelled,
    GameImportFailure.forbidden => l10n.catalogImportFailedForbidden,
    GameImportFailure.unreachable => l10n.catalogImportFailedUnreachable,
  };

  /// Whether trying again could end differently: not for a game the
  /// DataGateway no longer has, nor for a user the server refuses.
  static bool _mayTryAgain(GameImportFailure failure) => switch (failure) {
    GameImportFailure.notOnDataGateway || GameImportFailure.forbidden => false,
    GameImportFailure.dataGateway ||
    GameImportFailure.server ||
    GameImportFailure.cancelled ||
    GameImportFailure.unreachable => true,
  };
}

/// Where the import stands: one live region, whatever the state, so a screen
/// reader hears each change, an outcome included. The region is one node
/// across the states.
class _Status extends StatelessWidget {
  const _Status(this.text, {required this.progress});

  final String text;

  /// Whether a spinner goes beside [text].
  final bool progress;

  @override
  Widget build(BuildContext context) => Semantics(
    key: GameImportProgress.statusKey,
    container: true,
    liveRegion: true,
    label: text,
    child: ExcludeSemantics(
      child: progress
          ? Row(
              children: [
                const CircularProgressIndicator(),
                const BgeGap.sm(axis: Axis.horizontal),
                Expanded(child: Text(text)),
              ],
            )
          : Text(text),
    ),
  );
}

/// One game of the import: its title line, and its state in words.
class _JobRow extends StatelessWidget {
  const _JobRow({required this.title, required this.status, super.key});

  final String title;
  final String status;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        Text(
          status,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}
