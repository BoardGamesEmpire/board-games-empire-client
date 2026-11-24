import 'dart:async';

import 'package:flutter/foundation.dart';
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
/// It draws nothing of its own. It holds the import over [child], and two
/// parts under it draw from what it holds, each in a slot of its own
/// (#1037):
///
/// - [GameImportSection], in the scroll view: the [ExpansionChecklist] when
///   [mayChooseExpansions], and the [GameImportProgress] in its place once
///   the import has started.
/// - [GameImportButton], pinned under the scroll view: the import button,
///   which counts the expansions ticked, on screen wherever a long checklist
///   is scrolled to. It draws nothing once the import has started.
///
/// So the button and the checklist give way together to the progress, whose
/// status takes focus and is scrolled into view.
///
/// A quick look takes this as its `host`, a [GameImportSection] among its
/// `sections` and a [GameImportButton] as its `footer`. The host stays one
/// element whatever the quick look draws under it, so the expansions ticked
/// and an import being followed outlive the answer of the quick look's own
/// read. The quick look pins the button in its footer; a page can pin it in
/// its `BgePage.footer` (#712).
///
/// The import takes the expansions ticked at [gatewayId]. While the
/// checklist loads, or after it failed, there are none, and the button
/// imports the game alone.
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
///
/// An import whose section has been taken away goes on being followed
/// here, until it ends or the route leaves. A quick look takes the section
/// and the button away when the server refuses the game (#1040), which can
/// be after Import was pressed. With no progress drawn, nothing is opened
/// when that import completes. Nor when the refusal and the completion land
/// in one frame: the completion is handed over once that frame is built,
/// and only while the progress that told of it is still drawn.
class GameImportPanel extends StatefulWidget {
  const GameImportPanel({
    required this.remote,
    required this.gatewayId,
    required this.hit,
    required this.mayChooseExpansions,
    required this.onImported,
    required this.child,
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

  /// What holds the [GameImportSection] and the [GameImportButton]: the
  /// quick look's layout. A page can hold them too (#712).
  final Widget child;

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

  /// The game an import completed with, until it is handed to
  /// [GameImportPanel.onImported] once the frame is built, or once the
  /// route is uncovered: see "Stopping".
  String? _held;

  /// The progress that told of [_held]. Once it is no longer drawn, [_held]
  /// is dropped: see "Stopping".
  BuildContext? _heldFrom;

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

  /// Hands the imported game, told of by the progress at [from], to the
  /// caller from this panel's context, once this frame is built or once
  /// the route is uncovered: see "Stopping".
  ///
  /// Not at once: a quick look the server has just refused takes the
  /// progress away in the frame to come (#1040).
  void _imported(BuildContext from, String gameId) {
    _held = gameId;
    _heldFrom = from;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _handOver())
      // A post-frame callback asks for no frame of its own.
      ..ensureVisualUpdate();
  }

  /// Hands [_held] to the caller, unless the route has left or is covered,
  /// or the progress is no longer drawn. Left, the user has gone elsewhere,
  /// and a page opened now would land on top of wherever that is. Covered,
  /// it waits. With no progress, the import ends unseen.
  void _handOver() {
    final gameId = _held;
    if (gameId == null || !mounted || _stopped) return;
    if (!(_heldFrom?.mounted ?? false)) {
      _held = null;
      _heldFrom = null;
      return;
    }
    final route = _route;
    if (route != null && !route.isCurrent) return;
    _held = null;
    _heldFrom = null;
    widget.onImported(context, gameId);
  }

  @override
  Widget build(BuildContext context) => _GameImportScope(
    panel: this,
    hit: widget.hit,
    gatewayId: widget.gatewayId,
    sourceNames: widget.sourceNames,
    checklist: _checklist,
    import: _import,
    titles: _titles,
    child: widget.child,
  );
}

/// What a [GameImportPanel] holds, for the [GameImportSection] and the
/// [GameImportButton] under it.
class _GameImportScope extends InheritedWidget {
  const _GameImportScope({
    required this.panel,
    required this.hit,
    required this.gatewayId,
    required this.sourceNames,
    required this.checklist,
    required this.import,
    required this.titles,
    required super.child,
  });

  /// The panel's state, for starting the import and handing over its game.
  final _GameImportPanelState panel;
  final GameSearchHit hit;
  final String gatewayId;
  final Map<String, String> sourceNames;

  /// The expansions to choose from, or null where the panel reads none.
  final ExpansionChecklistCubit? checklist;

  /// The import, once started.
  final GameImportBloc? import;

  /// The expansions' titles when the import started.
  final Map<String, String> titles;

  /// The scope above [context], which rebuilds with it. Throws where there
  /// is none: a part away from its panel has no import to draw.
  static _GameImportScope of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_GameImportScope>();
    if (scope == null) {
      throw FlutterError(
        '${context.widget.runtimeType} has no GameImportPanel above it. The '
        'panel holds the import that the section and the button share, so '
        'it goes around what holds them both: for a quick look, as its host.',
      );
    }
    return scope;
  }

  @override
  bool updateShouldNotify(_GameImportScope oldWidget) =>
      !identical(import, oldWidget.import) ||
      !identical(checklist, oldWidget.checklist) ||
      !identical(titles, oldWidget.titles) ||
      hit != oldWidget.hit ||
      gatewayId != oldWidget.gatewayId ||
      !mapEquals(sourceNames, oldWidget.sourceNames);
}

/// The scrolling part of the import under a [GameImportPanel] (#1037): the
/// [ExpansionChecklist] while the user chooses, where the panel may read
/// the expansions, and the [GameImportProgress] in its place once the import
/// has started. The progress's status takes focus as it arrives.
///
/// Not a scrollable: the quick look's scroll view hosts it, among its
/// sections. With no checklist it draws nothing until the import starts.
class GameImportSection extends StatelessWidget {
  const GameImportSection({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = _GameImportScope.of(context);
    final import = scope.import;
    if (import != null) {
      return BlocProvider<GameImportBloc>.value(
        value: import,
        child: GameImportProgress(
          requestedTitle: scope.hit.title,
          titlesByExternalId: scope.titles,
          onImported: scope.panel._imported,
          autofocus: true,
        ),
      );
    }

    final checklist = scope.checklist;
    if (checklist == null) return const SizedBox.shrink();
    return BlocProvider<ExpansionChecklistCubit>.value(
      value: checklist,
      child: ExpansionChecklist(sourceNames: scope.sourceNames),
    );
  }
}

/// The import button under a [GameImportPanel], counting the expansions
/// ticked in its [GameImportSection] (#1037).
///
/// For a pinned footer, so the count and the action stay on screen down a
/// checklist of any length: the quick look's, and a page can pin it in its
/// `BgePage.footer` (#712). A direct write: offline it is disabled and says
/// why (#49), with the same tree as online.
///
/// Once the import has started it draws nothing, and has no size: the
/// progress in the section has taken over from it and the checklist
/// together (#824).
class GameImportButton extends StatelessWidget {
  const GameImportButton({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = _GameImportScope.of(context);
    if (scope.import != null) return const SizedBox.shrink();

    final checklist = scope.checklist;
    if (checklist == null) return _button(context, scope, ticked: 0);
    return BlocBuilder<ExpansionChecklistCubit, ExpansionChecklistState>(
      bloc: checklist,
      builder: (context, _) => _button(
        context,
        scope,
        ticked: checklist.tickedIn(scope.gatewayId).length,
      ),
    );
  }

  Widget _button(
    BuildContext context,
    _GameImportScope scope, {
    required int ticked,
  }) {
    final l10n = GameCatalogLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final again = scope.hit.isOnServer;
    final label = switch ((again, ticked)) {
      (false, 0) => l10n.catalogImportAction,
      (true, 0) => l10n.catalogReimportAction,
      (false, _) => l10n.catalogImportWithExpansions(ticked),
      (true, _) => l10n.catalogReimportWithExpansions(ticked),
    };
    return BgeOnlineOnly(
      child: FilledButton(
        key: GameImportPanel.importKey,
        onPressed: offline ? null : scope.panel._start,
        child: Text(label),
      ),
    );
  }
}
