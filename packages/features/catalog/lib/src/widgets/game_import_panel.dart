import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/bloc/game_import_bloc.dart';
import 'package:game_catalog/src/bloc/game_import_event.dart';
import 'package:game_catalog/src/expansions/expansion_checklist.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_cubit.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_state.dart';
import 'package:game_catalog/src/search/data_gateway_search_grant.dart';
import 'package:game_catalog/src/widgets/game_import_progress.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

/// Imports a search result into the server, with the expansions the user
/// chooses for it, and follows the import in place (#713, #824).
///
/// A quick look's section: the [ExpansionChecklist] when
/// [mayChooseExpansions], then the import button, the section's last
/// control, just above the quick look's own actions. Pressed, the button
/// and the checklist give way to a [GameImportProgress], and focus moves to
/// its status.
///
/// The import takes the expansions ticked at [gatewayId]. While the
/// checklist loads, or after it failed, there are none, and the button
/// imports the game alone.
///
/// Not a scrollable: the quick look's scroll view hosts it.
///
/// ## Stopping
///
/// The import stops being followed once the route this panel is in has left:
/// closed by the user, dropped by the router, or removed when the imported
/// game's page has arrived over it. Each completes the route's `popped`,
/// where a router's drop never reaches a `PopScope`. A route on its way out
/// stays mounted through its exit, so waiting for `dispose` would leave
/// polls running, and one could finish the import and open a page from a
/// quick look that has gone. The server finishes the import anyway.
///
/// An import that completes while something covers the quick look, such as
/// a dialog, is held: a page opened then would land on top of whatever
/// covers it. [onImported] runs once the quick look is uncovered, unless the
/// import was stopped meanwhile.
class GameImportPanel extends StatefulWidget {
  const GameImportPanel({
    required this.remote,
    required this.gatewayId,
    required this.hit,
    required this.mayChooseExpansions,
    required this.onImported,
    this.grant,
    this.sourceNames = const {},
    super.key,
  });

  /// The import button.
  static const Key importKey = Key('catalog_import.import');

  final GamesRemoteDataSource remote;

  /// The DataGateway [hit] came from.
  final String gatewayId;

  final GameSearchHit hit;

  /// Whether to read the game's expansions and offer them to tick. Without
  /// it there is no checklist, nothing is read, and the import takes the
  /// game alone.
  final bool mayChooseExpansions;

  /// The session's search grant, which a refusal of the expansions read is
  /// recorded on, so nothing asks again this session.
  final DataGatewaySearchGrant? grant;

  /// DataGateway names by id, for the checklist's headings and notes.
  final Map<String, String> sourceNames;

  /// Called with this panel's context and the imported game's id, once the
  /// import completes, or when the user opens a game imported in part.
  final void Function(BuildContext context, String gameId) onImported;

  @override
  State<GameImportPanel> createState() => _GameImportPanelState();
}

class _GameImportPanelState extends State<GameImportPanel> {
  /// The expansions to choose from, when the panel may read them.
  ExpansionChecklistCubit? _checklist;

  /// The import, once started.
  GameImportBloc? _import;

  /// The expansions' titles when the import started, for the progress.
  Map<String, String> _titles = const {};

  /// The route this panel is in, once it has been read.
  ModalRoute<Object?>? _route;

  /// Whether that route has left: see "Stopping".
  bool _stopped = false;

  /// The game an import completed with while the route was covered, until
  /// it is handed to [GameImportPanel.onImported]: see "Stopping".
  String? _held;

  @override
  void initState() {
    super.initState();
    if (widget.mayChooseExpansions) {
      final checklist = ExpansionChecklistCubit(
        remote: widget.remote,
        target: GameExpansionsTarget.dataGateway(
          gatewayId: widget.gatewayId,
          externalId: widget.hit.externalId,
        ),
        tickOnServer: widget.hit.isOnServer,
        grant: widget.grant,
      );
      _checklist = checklist;
      unawaited(checklist.load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Called again whenever the route's status changes: each route is
    // listened to once, and only the latest one stops the import.
    final route = ModalRoute.of(context);
    if (route != null && !identical(route, _route)) {
      _route = route;
      unawaited(
        route.popped.then((_) {
          if (identical(_route, route)) _stop();
        }),
      );
    }
    // Uncovered, perhaps: a held completion is handed over once this frame
    // is built, since no page can be opened during a build.
    if (_held != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _handOver());
    }
  }

  @override
  void dispose() {
    _stop();
    unawaited(_checklist?.close());
    super.dispose();
  }

  /// Stops following the import, for good: see "Stopping".
  void _stop() {
    _stopped = true;
    final import = _import;
    if (import != null && !import.isClosed) unawaited(import.close());
  }

  void _start() {
    if (_import != null || _stopped) return;
    final checklist = _checklist;
    final import = GameImportBloc(
      remote: widget.remote,
      gatewayId: widget.gatewayId,
      externalId: widget.hit.externalId,
      expansionExternalIds: checklist?.tickedIn(widget.gatewayId) ?? const [],
    )..add(const GameImportRequested());
    setState(() {
      _import = import;
      _titles = checklist?.titlesByExternalId ?? const {};
    });
  }

  /// Hands the imported game to the caller, from this panel's context, now
  /// or once the route is uncovered: see "Stopping".
  void _imported(String gameId) {
    _held = gameId;
    _handOver();
  }

  /// Hands [_held] to the caller, unless the route has left or is covered.
  /// Left, the user has gone elsewhere, and a page opened now would land on
  /// top of wherever that is. Covered, it waits.
  void _handOver() {
    final gameId = _held;
    if (gameId == null || !mounted || _stopped) return;
    final route = _route;
    if (route != null && !route.isCurrent) return;
    _held = null;
    widget.onImported(context, gameId);
  }

  @override
  Widget build(BuildContext context) {
    final import = _import;
    if (import != null) {
      return BlocProvider<GameImportBloc>.value(
        value: import,
        child: GameImportProgress(
          requestedTitle: widget.hit.title,
          titlesByExternalId: _titles,
          onImported: (_, gameId) => _imported(gameId),
          autofocus: true,
        ),
      );
    }

    final checklist = _checklist;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (checklist != null)
          BlocProvider<ExpansionChecklistCubit>.value(
            value: checklist,
            child: ExpansionChecklist(sourceNames: widget.sourceNames),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: checklist == null
              ? _button(context, ticked: 0)
              : BlocBuilder<ExpansionChecklistCubit, ExpansionChecklistState>(
                  bloc: checklist,
                  builder: (context, _) => _button(
                    context,
                    ticked: checklist.tickedIn(widget.gatewayId).length,
                  ),
                ),
        ),
      ],
    );
  }

  /// The import button, counting the [ticked] expansions. A direct write:
  /// disabled offline, saying why (#49).
  Widget _button(BuildContext context, {required int ticked}) {
    final l10n = GameCatalogLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final again = widget.hit.isOnServer;
    final label = switch ((again, ticked)) {
      (false, 0) => l10n.catalogImportAction,
      (true, 0) => l10n.catalogReimportAction,
      (false, _) => l10n.catalogImportWithExpansions(ticked),
      (true, _) => l10n.catalogReimportWithExpansions(ticked),
    };
    return BgeOnlineOnly(
      child: FilledButton(
        key: GameImportPanel.importKey,
        onPressed: offline ? null : _start,
        child: Text(label),
      ),
    );
  }
}
