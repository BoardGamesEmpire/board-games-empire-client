import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import '../bloc/game_import_bloc.dart';
import '../bloc/game_import_event.dart';
import '../bloc/game_import_state.dart';

/// Imports one DataGateway result into the server, and shows how the import
/// goes while it is open (#43).
///
/// ## A dialog, not a route
///
/// #43 asks for an import screen that replaces itself with the game's
/// detail. A route would have to carry the [GameSearchHit] in go_router's
/// `extra`, which a web reload loses. A dialog over the search needs no
/// route: [show] completes with the game's id when the import completes, and
/// the caller opens that game's detail in its place.
///
/// ## Leaving
///
/// Closing the dialog, by its button, the barrier or Back, completes [show]
/// with null and stops the polling. The server finishes the import anyway,
/// and the next search shows the game as one it holds.
///
/// The polling stops when the dialog is closed, not when it is disposed: it
/// stays mounted while it animates away, and a poll it sent then could
/// complete the import and pop the page beneath it.
class GameImportDialog extends StatefulWidget {
  const GameImportDialog({
    required this.remote,
    required this.gatewayId,
    required this.hit,
    super.key,
  });

  /// Opens the dialog and starts the import. Completes with the imported
  /// game's id when the base job completes, or null when the user closes it
  /// or the import completes beneath another page.
  static Future<String?> show(
    BuildContext context, {
    required GamesRemoteDataSource remote,
    required String gatewayId,
    required GameSearchHit hit,
  }) => showDialog<String>(
    context: context,
    builder: (_) =>
        GameImportDialog(remote: remote, gatewayId: gatewayId, hit: hit),
  );

  static const Key progressKey = Key('catalog_import.progress');
  static const Key stillRunningKey = Key('catalog_import.still_running');
  static const Key failedKey = Key('catalog_import.failed');
  static const Key checkAgainKey = Key('catalog_import.check_again');
  static const Key tryAgainKey = Key('catalog_import.try_again');
  static const Key closeKey = Key('catalog_import.close');

  final GamesRemoteDataSource remote;

  /// The DataGateway [hit] came from.
  final String gatewayId;

  final GameSearchHit hit;

  @override
  State<GameImportDialog> createState() => _GameImportDialogState();
}

class _GameImportDialogState extends State<GameImportDialog> {
  late final GameImportBloc _bloc = GameImportBloc(
    remote: widget.remote,
    gatewayId: widget.gatewayId,
    externalId: widget.hit.externalId,
  )..add(const GameImportRequested());

  /// Stops the import's polling, once: see "Leaving".
  void _stop() {
    if (!_bloc.isClosed) unawaited(_bloc.close());
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _stop();
    },
    child: BlocProvider<GameImportBloc>.value(
      value: _bloc,
      child: _GameImportView(title: widget.hit.title),
    ),
  );
}

class _GameImportView extends StatelessWidget {
  const _GameImportView({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);

    return BlocConsumer<GameImportBloc, GameImportState>(
      listenWhen: (_, state) => state is GameImportCompleted,
      listener: (context, state) {
        if (state is! GameImportCompleted) return;
        final route = ModalRoute.of(context);
        if (route == null || !route.isActive) return;
        // A pop takes the top route, which is not the dialog once a page has
        // opened above it. Then the dialog leaves from beneath that page and
        // opens nothing: the user has gone somewhere else.
        if (route.isCurrent) {
          Navigator.of(context).pop(state.gameId);
        } else {
          Navigator.of(context).removeRoute(route);
        }
      },
      builder: (context, state) {
        final bloc = context.read<GameImportBloc>();

        return AlertDialog(
          // The title and the copy scroll together, so neither overflows at
          // a large text size; the actions stay put.
          scrollable: true,
          // Held to three lines: a long title at a large text size would
          // otherwise fill the dialog and push where the import stands out
          // of view. A screen reader still hears all of it.
          title: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis),
          content: switch (state) {
            GameImportStarting() => _Status.progress(
              l10n.catalogImportStarting,
            ),
            GameImportInProgress(running: false) => _Status.progress(
              l10n.catalogImportQueued,
            ),
            // A completed import closes the dialog at once, which goes on
            // showing it as running while it animates away.
            GameImportInProgress() || GameImportCompleted() => _Status.progress(
              l10n.catalogImportRunning,
            ),
            GameImportStillRunning() => _Status(
              l10n.catalogImportStillRunning,
              contentKey: GameImportDialog.stillRunningKey,
            ),
            GameImportFailed(:final failure) => _Status(
              _failureCopy(l10n, failure),
              contentKey: GameImportDialog.failedKey,
            ),
          },
          actions: [
            TextButton(
              key: GameImportDialog.closeKey,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.catalogImportClose),
            ),
            if (state is GameImportStillRunning)
              TextButton(
                key: GameImportDialog.checkAgainKey,
                onPressed: () =>
                    bloc.add(const GameImportCheckAgainRequested()),
                child: Text(l10n.catalogImportCheckAgain),
              ),
            if (state case GameImportFailed(:final failure)
                when _mayTryAgain(failure))
              TextButton(
                key: GameImportDialog.tryAgainKey,
                onPressed: () => bloc.add(const GameImportRequested()),
                child: Text(l10n.catalogImportTryAgain),
              ),
          ],
        );
      },
    );
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
/// reader hears each change, an outcome included.
///
/// The region stays one node across the states: [contentKey] goes on what it
/// shows, not on the region.
class _Status extends StatelessWidget {
  const _Status(this.text, {required this.contentKey}) : progress = false;

  const _Status.progress(this.text)
    : contentKey = GameImportDialog.progressKey,
      progress = true;

  final String text;
  final Key contentKey;

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
              key: contentKey,
              children: [
                const CircularProgressIndicator(),
                const BgeGap.sm(axis: Axis.horizontal),
                Expanded(child: Text(text)),
              ],
            )
          : Text(text, key: contentKey),
    ),
  );
}
