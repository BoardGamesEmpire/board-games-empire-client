import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_import_bloc.dart';
import 'package:game_catalog/src/bloc/game_import_event.dart';
import 'package:game_catalog/src/bloc/game_import_state.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Where an import stands, in place: one status, a row for each game of the
/// import once there is more than one, and what the user can do next (#43,
/// #824).
///
/// It reads the [GameImportBloc] provided above it and owns none. The quick
/// look hosts it where the import button was, so the import goes on in the
/// place the user started it, and nothing opens over it.
///
/// ## The status
///
/// While the import runs, the status is a line saying how far it has got.
/// An outcome the user stays to read, a failure or an import completed in
/// part, is a banner in its place (STYLE_GUIDE §4), its tone said by its icon
/// and its words as well as its colour. Line or banner, it is one focus node
/// and one semantics node, a live region, so each change is heard once and
/// focus on it stays as the outcome lands.
///
/// It takes focus only when handed it ([autofocus], or a button below going)
/// and is no Tab stop: Tab goes on from it. While it has focus from a
/// keyboard, it is ringed.
///
/// ## Its buttons
///
/// Check again and Try again stay where they are through the poll or the
/// start they began, enabled and inert, so the focus on them stays (#607,
/// STYLE_GUIDE §5). When the import then lands where the button no longer
/// applies, focus on it goes to the status.
///
/// ## Ending
///
/// [onImported] runs once, when the requested game is on the server and every
/// other game of the import is too, and the status says it was imported, for
/// a caller that leaves this in place. When some of the others are not, the
/// banner says so, and when they are still importing as the polls run out,
/// the status does. Either way an Open button calls [onImported] when the
/// user chooses.
class GameImportProgress extends StatefulWidget {
  const GameImportProgress({
    required this.requestedTitle,
    required this.onImported,
    this.titlesByExternalId = const {},
    this.autofocus = false,
    super.key,
  });

  /// The status: the line, or the outcome's banner in its place. One node
  /// across every state, in a live region.
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
  /// on each press of Open after it completes in part, or while the others
  /// still run.
  final void Function(BuildContext context, String gameId) onImported;

  /// Whether the status takes focus once this is first drawn, from whatever
  /// had it, so a keyboard or screen-reader user lands on where the import
  /// stands.
  ///
  /// It asks for focus at the end of that frame rather than through
  /// [Focus.autofocus]. The control that started the import is usually the
  /// one this replaces, and once it has gone, Flutter's autofocus gives way
  /// to the focus the page had before it, such as a description's More
  /// (#713).
  final bool autofocus;

  @override
  State<GameImportProgress> createState() => _GameImportProgressState();
}

/// A button whose press starts something the import then answers.
enum _Retry {
  /// Check again: polls the same import.
  checkAgain,

  /// Try again: starts the import again.
  tryAgain,
}

class _GameImportProgressState extends State<GameImportProgress> {
  /// Whether [GameImportProgress.onImported] has run for a completion: the
  /// bloc, or a stream standing in for it, may announce it twice.
  bool _imported = false;

  /// The status's focus node, line and banner alike. It takes focus only
  /// when handed it.
  final FocusNode _statusFocus = FocusNode(
    debugLabel: 'GameImportProgress status',
    skipTraversal: true,
  );

  /// Around each button of [_Retry], to tell whether focus is on it as it
  /// goes. They take no focus of their own.
  final Map<_Retry, FocusNode> _areas = {
    for (final retry in _Retry.values)
      retry: FocusNode(
        debugLabel: 'GameImportProgress ${retry.name}',
        canRequestFocus: false,
        skipTraversal: true,
      ),
  };

  /// The button whose press started what runs now. It stays, inert, until
  /// the import lands.
  _Retry? _pressed;

  /// Whether the connection is lost, which disables Try again unless its
  /// own start runs.
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    // The listener hears only what the bloc emits after this mounts. An
    // import that completed before then, as one can while the app sits in
    // the background with no frame drawn, is handed over once this frame is
    // built, since no page can be opened during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<GameImportBloc>().state;
      if (state is GameImportCompleted) _onState(context, state);
    });
    if (widget.autofocus) {
      // After the frame that removed the control that had focus: a request
      // made then wins over the page's focus history (see autofocus). This
      // runs in that frame's build, so the callback needs no frame asked
      // for.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _statusFocus.requestFocus();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _offline = BgeConnectivityScope.offlineOf(context);
  }

  @override
  void dispose() {
    _statusFocus.dispose();
    for (final area in _areas.values) {
      area.dispose();
    }
    super.dispose();
  }

  void _press(GameImportBloc bloc, _Retry retry) {
    setState(() => _pressed = retry);
    bloc.add(switch (retry) {
      _Retry.checkAgain => const GameImportCheckAgainRequested(),
      _Retry.tryAgain => const GameImportRequested(),
    });
  }

  void _onState(BuildContext context, GameImportState state) {
    final pressed = _pressed;
    if (pressed != null && !_runs(state)) {
      // Landed. Focus on a button that goes, or that is offered again but
      // disabled offline, where it can't hold focus, moves to the status
      // first, so it never falls to the page's focus history.
      final keeps =
          _offers(state, pressed) && !(pressed == _Retry.tryAgain && _offline);
      if (!keeps && _areas[pressed]!.hasFocus) _statusFocus.requestFocus();
      setState(() => _pressed = null);
    }
    if (state is GameImportCompleted && !_imported) {
      _imported = true;
      widget.onImported(context, state.gameId);
    }
  }

  /// Whether the import is under way in [state], as it is after a press of
  /// either button until it lands.
  static bool _runs(GameImportState state) =>
      state is GameImportStarting || state is GameImportInProgress;

  /// Whether [state] offers [retry], live.
  static bool _offers(GameImportState state, _Retry retry) => switch (retry) {
    _Retry.checkAgain => state is GameImportStillRunning,
    _Retry.tryAgain => switch (state) {
      GameImportFailed(:final failure) => _mayTryAgain(failure),
      _ => false,
    },
  };

  /// Whether [retry] is drawn in [state]: offered, or inert while what its
  /// press started runs.
  bool _shows(GameImportState state, _Retry retry) =>
      _offers(state, retry) || (_pressed == retry && _runs(state));

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    return BlocConsumer<GameImportBloc, GameImportState>(
      listener: _onState,
      builder: (context, state) {
        final bloc = context.read<GameImportBloc>();
        final jobs = state.jobs;
        final offline = _offline;
        final pressed = _pressed;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _status(context, l10n, tokens, state),
            if (jobs.length > 1) ...[
              const BgeGap.md(),
              Semantics(
                container: true,
                label: l10n.catalogImportBatchLabel(jobs.length),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: tokens.spaceSm,
                  children: [
                    for (final job in jobs)
                      _JobRow(
                        key: GameImportProgress.jobKey(job.jobId),
                        title: _rowTitle(l10n, job, jobs),
                        status: _jobStatus(l10n, job),
                      ),
                  ],
                ),
              ),
            ],
            // Keyed, so each keeps its element and its focus as the rows
            // above it come and go.
            if (_shows(state, _Retry.checkAgain)) ...[
              const BgeGap.md(),
              _area(
                _Retry.checkAgain,
                BgeInertButton(
                  inert: pressed == _Retry.checkAgain,
                  label: l10n.catalogImportCheckAgain,
                  // A poll only reads: offline too.
                  onPressed: () => _press(bloc, _Retry.checkAgain),
                  builder: (context, focusNode, onPressed) => TextButton(
                    key: GameImportProgress.checkAgainKey,
                    focusNode: focusNode,
                    onPressed: onPressed,
                    child: Text(l10n.catalogImportCheckAgain),
                  ),
                ),
              ),
            ],
            if (_shows(state, _Retry.tryAgain)) ...[
              const BgeGap.md(),
              _area(
                _Retry.tryAgain,
                // A new import is a write (#49); its note goes under it.
                BgeOnlineOnly(
                  child: BgeInertButton(
                    inert: pressed == _Retry.tryAgain,
                    label: l10n.catalogImportTryAgain,
                    // Offline it is disabled, unless its own start runs:
                    // that keeps it, and its focus, until the start lands.
                    onPressed: offline && pressed != _Retry.tryAgain
                        ? null
                        : () => _press(bloc, _Retry.tryAgain),
                    builder: (context, focusNode, onPressed) => TextButton(
                      key: GameImportProgress.tryAgainKey,
                      focusNode: focusNode,
                      onPressed: onPressed,
                      child: Text(l10n.catalogImportTryAgain),
                    ),
                  ),
                ),
              ),
            ],
            if (_openable(state) case final gameId?) ...[
              const BgeGap.md(),
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

  /// The requested game's id where [state] offers Open: the import completed
  /// in part, or ran out of polls with that game on the server.
  static String? _openable(GameImportState state) => switch (state) {
    GameImportPartlyCompleted(:final gameId) => gameId,
    GameImportStillRunning(:final gameId) => gameId,
    _ => null,
  };

  /// [button], keyed by [retry] and inside its area.
  Widget _area(_Retry retry, Widget button) => Focus(
    key: ValueKey(retry),
    focusNode: _areas[retry],
    includeSemantics: false,
    child: button,
  );

  /// The status: a line while the import runs, a banner once it has failed
  /// or completed in part. One focus node and one merged node, a live
  /// region, whichever it is (see "The status").
  Widget _status(
    BuildContext context,
    GameCatalogLocalizations l10n,
    BgeTokens tokens,
    GameImportState state,
  ) {
    final content = switch (state) {
      GameImportStarting() => _Status(l10n.catalogImportStarting),
      GameImportInProgress(running: false) => _Status(l10n.catalogImportQueued),
      GameImportInProgress() => _Status(l10n.catalogImportRunning),
      // Usually the caller replaces this at once; one that doesn't, or that
      // waits for its page to be uncovered, still says the import ended.
      GameImportCompleted(:final jobs) => _Status(
        l10n.catalogImportCompleted(_requestedTitle(jobs)),
        progress: false,
      ),
      GameImportStillRunning(gameId: null) => _Status(
        l10n.catalogImportStillRunning,
        progress: false,
      ),
      GameImportStillRunning(:final jobs) => _Status(
        l10n.catalogImportStillRunningImported(_requestedTitle(jobs)),
        progress: false,
      ),
      GameImportPartlyCompleted(:final jobs) => BgeInlineBanner(
        tone: BgeBannerTone.warning,
        message: l10n.catalogImportPartlyCompleted(
          _requestedTitle(jobs),
          jobs
              .where(
                (job) =>
                    job.origin != ImportJobOrigin.requested &&
                    job.status != ImportJobStatus.completed,
              )
              .length,
        ),
      ),
      GameImportFailed(:final failure) => BgeInlineBanner(
        tone: BgeBannerTone.error,
        // Some of the messages state only a cause (STYLE_GUIDE §4).
        title: l10n.catalogImportFailedTitle,
        message: _failureCopy(l10n, failure),
      ),
    };
    // The ring is drawn inside its box, focusOutlineWidth wide, so the
    // content sits that far in and focusRingGap more: clear of the ring, as
    // a filled button's outside ring keeps clear of its fill.
    final reach = tokens.focusRingGap + tokens.focusOutlineWidth;
    return BgeFocusRing(
      // A banner's corners, out by the ring's reach.
      borderRadius: BorderRadius.circular(
        content is BgeInlineBanner ? tokens.radiusMd + reach : tokens.radiusSm,
      ),
      builder: (context, onFocusChange) => MergeSemantics(
        child: Focus(
          focusNode: _statusFocus,
          onFocusChange: onFocusChange,
          child: KeyedSubtree(
            key: GameImportProgress.statusKey,
            // Inset from the ring, which would otherwise run through the
            // spinner, the first letter, or the banner's fill.
            child: Padding(
              padding: EdgeInsets.all(reach),
              child: content,
            ),
          ),
        ),
      ),
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
    final neededBy =
        (parent == null ? null : _titleOf(parent)) ?? widget.requestedTitle;
    return title == null
        ? l10n.catalogImportJobAddedBaseGameUntitled(neededBy)
        : l10n.catalogImportJobAddedBaseGame(title, neededBy);
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

/// A stage of the import, in a live region: a screen reader hears each
/// change. Merged into the status's node with its focus.
class _Status extends StatelessWidget {
  const _Status(this.text, {this.progress = true});

  final String text;

  /// Whether a spinner goes beside [text].
  final bool progress;

  @override
  Widget build(BuildContext context) => Semantics(
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
