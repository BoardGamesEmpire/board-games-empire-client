import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

import '../bloc/data_gateway_list_bloc.dart';
import '../bloc/data_gateway_list_event.dart';
import '../bloc/data_gateway_list_state.dart';
import '../widgets/data_gateway_status.dart';

/// The DataGateway admin screen (#41): every DataGateway on the active
/// server, with add, edit, delete, connect and disconnect.
///
/// Decoupled from DI like the household screens: the caller resolves the
/// per-server [DataGatewayRemoteDataSource] and the session's
/// [CallerAccessRepository], and owns the routes to the form and to a
/// DataGateway's own page through [onAdd], [onEdit] and [onOpen].
///
/// The list is read again whenever it comes back into view, so a save shows
/// up without the form having to hand anything back. That includes a form
/// this screen did not open: a deep link or a web reload on a form builds
/// the list beneath it.
///
/// ## What a row says
///
/// Name, the address the server dials, and enabled or disabled, as an icon
/// and a word rather than color alone. Not "connected": the server does not
/// store that (#41). A connect or disconnect reports its answer once, in the
/// banner above the list.
///
/// An enabled row also says whether the server uses it yet (#457), in the
/// same icon and words. The server does not use a DataGateway until an
/// interview has succeeded, so an enabled one that no interview has succeeded
/// for returns nothing, and the row says why: it is waiting for its first
/// interview, or that interview failed ([DataGatewayStatusLine]). A disabled
/// row has no such line, only its badge.
///
/// ## Opening a row
///
/// A row with [onOpen] is a control: tapping it opens the DataGateway. Its
/// menu keeps its own tap. Without [onOpen] a row is content, not a focus
/// stop, as in the household list: a tap that leads nowhere is worse than
/// none.
///
/// ## Access
///
/// Each action shows while the caller's access says they may take it, and
/// is hidden while that is unknown (#456): the add button needs create, and
/// a row's menu offers edit, connect and disconnect with update, and delete
/// with delete. With neither, a row has no menu. They come and go as the
/// answer changes. One that goes with keyboard focus hands it to the banner's
/// Dismiss while an outcome shows, else from a row's menu to its own row when
/// rows open, else to the page's heading, which is no Tab stop but is always
/// there.
///
/// A refused read is the access-denied surface, with nothing to act on. A
/// refused change is reported in the banner, which says why. Both ask the
/// session's access again, and the actions follow its answer.
class DataGatewayListScreen extends StatelessWidget {
  const DataGatewayListScreen({
    required this.remote,
    this.access,
    this.onAdd,
    this.onEdit,
    this.onOpen,
    super.key,
  });

  static const Key loadingKey = Key('data_gateway_list.loading');
  static const Key emptyKey = Key('data_gateway_list.empty');
  static const Key errorKey = Key('data_gateway_list.error');
  static const Key deniedKey = Key('data_gateway_list.denied');
  static const Key addKey = Key('data_gateway_list.add');
  static const Key outcomeKey = Key('data_gateway_list.outcome');
  static const Key editKey = Key('data_gateway_list.edit');
  static const Key connectKey = Key('data_gateway_list.connect');
  static const Key disconnectKey = Key('data_gateway_list.disconnect');
  static const Key deleteKey = Key('data_gateway_list.delete');
  static const Key deleteConfirmKey = Key('data_gateway_list.delete_confirm');

  /// Per-row key: `data_gateway_list.row_<id>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String id) => Key('data_gateway_list.row_$id');

  /// Per-row menu button key: `data_gateway_list.menu_<id>`.
  static Key rowMenuKey(String id) => Key('data_gateway_list.menu_$id');

  /// Per-row status line key: `data_gateway_list.status_<id>` (#457).
  ///
  /// On the [DataGatewayStatusLine] inside the row. A disabled row has none.
  static Key statusKeyOf(String id) => Key('data_gateway_list.status_$id');

  final DataGatewayRemoteDataSource remote;

  /// The session's access, or null for a composition without one, which
  /// offers no action.
  final CallerAccessRepository? access;

  /// Opens the add form. Null hides the add button.
  final void Function(BuildContext context)? onAdd;

  /// Opens the edit form for one DataGateway. Null leaves edit out of the row
  /// menu.
  final void Function(BuildContext context, String id)? onEdit;

  /// Opens one DataGateway's own page (#457), or null where there is none to
  /// open, and then rows stay content rather than controls that do nothing.
  ///
  /// Takes the id rather than the row: the destination reads the
  /// DataGateway from the server itself.
  final void Function(BuildContext context, String id)? onOpen;

  @override
  Widget build(BuildContext context) => BlocProvider<DataGatewayListBloc>(
    create: (_) =>
        DataGatewayListBloc(remote: remote, access: access)
          ..add(const DataGatewayListLoadRequested()),
    // Reads the list again when the screen comes back into view, so it
    // covers a form this screen opened and one a deep link built it beneath.
    child: Builder(
      builder: (context) => ReadAgainWhenUncovered(
        onUncovered: () => context.read<DataGatewayListBloc>().add(
          const DataGatewayListLoadRequested(),
        ),
        child: _DataGatewayListView(
          onAdd: onAdd,
          onEdit: onEdit,
          onOpen: onOpen,
        ),
      ),
    ),
  );
}

class _DataGatewayListView extends StatefulWidget {
  const _DataGatewayListView({this.onAdd, this.onEdit, this.onOpen});

  final void Function(BuildContext context)? onAdd;
  final void Function(BuildContext context, String id)? onEdit;
  final void Function(BuildContext context, String id)? onOpen;

  @override
  State<_DataGatewayListView> createState() => _DataGatewayListViewState();
}

class _DataGatewayListViewState extends State<_DataGatewayListView> {
  /// On the page's heading, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'data gateway list heading',
    skipTraversal: true,
  );

  final FocusNode _add = FocusNode(debugLabel: 'data gateway add');

  /// The outcome banner's Dismiss.
  final FocusNode _dismiss = FocusNode(debugLabel: 'data gateway dismiss');

  /// Each row's own node, by id, for as long as the row is listed. It takes
  /// focus only while the row opens.
  final Map<String, FocusNode> _rows = {};

  /// The node of the [Focus] around each row's menu, by id, for as long as
  /// the row is listed.
  ///
  /// `PopupMenuButton` takes no focus node of its own, so this is the handle
  /// on a row's menu. It can't take focus itself: focus goes to the button
  /// inside.
  final Map<String, FocusNode> _menus = {};

  FocusNode _rowNode(String id) =>
      _rows.putIfAbsent(id, () => FocusNode(debugLabel: 'data gateway $id'));

  FocusNode _menuNode(String id) => _menus.putIfAbsent(
    id,
    () =>
        FocusNode(debugLabel: 'data gateway menu $id', canRequestFocus: false),
  );

  static bool _offersMenus(DataGatewayListReady state) =>
      state.mayUpdate || state.mayDelete;

  /// Whether [current] takes away a control [previous] offered, because the
  /// caller's access fell (#456): the Add button, or every row's menu.
  static bool _takesControlAway(
    DataGatewayListState previous,
    DataGatewayListState current,
  ) =>
      previous is DataGatewayListReady &&
      current is DataGatewayListReady &&
      ((previous.mayCreate && !current.mayCreate) ||
          (_offersMenus(previous) && !_offersMenus(current)));

  /// When the control that goes has keyboard focus, hands it on (#456).
  ///
  /// Left to go with the control, focus would fall back on whatever had it
  /// before, or on the page with nothing to show for it. Access can fall at
  /// any time, whenever the session asks again, so it goes somewhere chosen:
  ///
  /// - the banner's Dismiss, while an outcome shows, as on the detail screen;
  /// - else from a row's menu to its own row, when rows open and the row is
  ///   still built: the stop just before the menu, on the DataGateway the
  ///   user was at;
  /// - else to the page's heading, which is always there, with rows that
  ///   don't open and with none at all, and once a read refused or failed
  ///   meanwhile has taken the list away. The next Tab goes on from the top
  ///   of the page, to whatever control is left.
  ///
  /// Runs before the frame that takes the control away, while it still has
  /// focus, and hands it on after that frame. Not if the user has moved focus
  /// meanwhile, and not if access has given the control back by then.
  void _onControlTakenAway(BuildContext context, DataGatewayListState state) {
    if (state is! DataGatewayListReady) return;
    final addGoes = !state.mayCreate && _add.hasFocus;
    final menuGoes = _offersMenus(state)
        ? null
        : _menus.entries.where((entry) => entry.value.hasFocus).firstOrNull;
    if (!addGoes && menuGoes == null) return;

    final ownRowId = menuGoes != null && widget.onOpen != null
        ? menuGoes.key
        : null;
    final focused = FocusManager.instance.primaryFocus;
    final bloc = context.read<DataGatewayListBloc>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(this.context, untouched: focused)) return;
      final now = bloc.state;
      final FocusNode target;
      if (now is DataGatewayListReady) {
        if (addGoes ? now.mayCreate : _offersMenus(now)) return;
        // The banner and the row are looked up now, as that frame built them.
        // It may have dismissed the banner, or taken the row away, and
        // [_forgetRowsGone] has dropped its node. Or it left the row listed
        // but out of the built range, where its node would take focus only
        // once the row is built again.
        final ownRow = ownRowId == null ? null : _rows[ownRowId];
        target = now.outcome != null
            ? _dismiss
            : ownRow?.parent != null
            ? ownRow!
            : _heading;
      } else {
        // A read refused or failed meanwhile: the list offers nothing.
        target = _heading;
      }
      target.requestFocus();
      if (FocusManager.instance.highlightMode ==
          FocusHighlightMode.traditional) {
        // The banner heads the list, which may be scrolled past it.
        target.context?.findRenderObject()?.showOnScreen();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Disposes the nodes of rows no longer listed, after the frame that takes
  /// them down: a [Focus] holds its node until then.
  void _forgetRowsGone(BuildContext context, DataGatewayListState state) {
    final listed = {
      if (state is DataGatewayListReady)
        for (final gateway in state.gateways) gateway.id,
    };
    final gone = [
      for (final id in {..._rows.keys, ..._menus.keys})
        if (!listed.contains(id)) id,
    ];
    if (gone.isEmpty) return;
    final nodes = [
      for (final id in gone) ...[?_rows.remove(id), ?_menus.remove(id)],
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in nodes) {
        node.dispose();
      }
    });
  }

  @override
  void dispose() {
    _heading.dispose();
    _add.dispose();
    _dismiss.dispose();
    for (final node in [..._rows.values, ..._menus.values]) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return MultiBlocListener(
      listeners: [
        BlocListener<DataGatewayListBloc, DataGatewayListState>(
          listenWhen: _takesControlAway,
          listener: _onControlTakenAway,
        ),
        BlocListener<DataGatewayListBloc, DataGatewayListState>(
          listener: _forgetRowsGone,
        ),
      ],
      child: BlocBuilder<DataGatewayListBloc, DataGatewayListState>(
        builder: (context, state) {
          final ready = state is DataGatewayListReady ? state : null;
          final add = widget.onAdd;
          final edit = widget.onEdit;
          final open = widget.onOpen;
          final mayCreate = ready?.mayCreate ?? false;
          final mayUpdate = ready?.mayUpdate ?? false;
          final mayDelete = ready?.mayDelete ?? false;
          final tokens = BgeTokens.of(context);

          return BgePage.slivers(
            title: Focus(
              focusNode: _heading,
              child: Text(l10n.dataGatewayListTitle),
            ),
            width: BgePageWidth.pane,
            semanticChildCount: ready == null || ready.gateways.isEmpty
                ? null
                : ready.gateways.length,
            floatingActionButton: add == null || !mayCreate
                ? null
                : FloatingActionButton.extended(
                    key: DataGatewayListScreen.addKey,
                    focusNode: _add,
                    onPressed: () => add(context),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.dataGatewayAdd),
                  ),
            slivers: [
              if (ready?.outcome case final outcome?)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: tokens.spaceMd),
                    child: _OutcomeBanner(
                      outcome: outcome,
                      dismissFocus: _dismiss,
                    ),
                  ),
                ),
              switch (state) {
                DataGatewayListLoading() => BgeStateSliver(
                  child: BgeLoadingState(
                    key: DataGatewayListScreen.loadingKey,
                    label: l10n.dataGatewayListLoading,
                  ),
                ),
                DataGatewayListDenied() => BgeStateSliver(
                  child: BgeEmptyState(
                    key: DataGatewayListScreen.deniedKey,
                    icon: Icons.lock_outline,
                    title: l10n.dataGatewayDeniedTitle,
                    body: l10n.dataGatewayDeniedBody,
                  ),
                ),
                DataGatewayListFailed() => BgeStateSliver(
                  child: BgeErrorState(
                    key: DataGatewayListScreen.errorKey,
                    icon: Icons.cloud_off_outlined,
                    title: l10n.dataGatewayListErrorTitle,
                    body: l10n.dataGatewayListErrorBody,
                    retryLabel: l10n.dataGatewayRetry,
                    onRetry: () => context.read<DataGatewayListBloc>().add(
                      const DataGatewayListLoadRequested(),
                    ),
                  ),
                ),
                DataGatewayListReady(:final gateways) when gateways.isEmpty =>
                  BgeStateSliver(
                    child: BgeEmptyState(
                      key: DataGatewayListScreen.emptyKey,
                      title: l10n.dataGatewayListEmptyTitle,
                      body: l10n.dataGatewayListEmptyBody,
                    ),
                  ),
                DataGatewayListReady(:final gateways, :final busy) =>
                  BgeKeyedSliverList<DataGateway>(
                    items: gateways,
                    keyOf: (gateway) =>
                        DataGatewayListScreen.rowKey(gateway.id),
                    itemBuilder: (context, gateway) => _DataGatewayRow(
                      gateway: gateway,
                      busy: busy.contains(gateway.id),
                      mayUpdate: mayUpdate,
                      mayDelete: mayDelete,
                      focusNode: _rowNode(gateway.id),
                      menuFocusNode: _menuNode(gateway.id),
                      onEdit: edit == null
                          ? null
                          : () => edit(context, gateway.id),
                      onOpen: open == null
                          ? null
                          : () => open(context, gateway.id),
                    ),
                  ),
              },
            ],
          );
        },
      ),
    );
  }
}

class _DataGatewayRow extends StatelessWidget {
  const _DataGatewayRow({
    required this.gateway,
    required this.busy,
    required this.mayUpdate,
    required this.mayDelete,
    required this.focusNode,
    required this.menuFocusNode,
    this.onEdit,
    this.onOpen,
  });

  final DataGateway gateway;
  final bool busy;

  /// The row's own, which takes focus only while the row opens.
  final FocusNode focusNode;

  /// For the [Focus] around the row's menu.
  final FocusNode menuFocusNode;

  /// Whether to offer edit, connect and disconnect.
  final bool mayUpdate;

  /// Whether to offer delete. With neither this nor [mayUpdate], the row has
  /// no menu.
  final bool mayDelete;
  final VoidCallback? onEdit;

  /// Null leaves the row untappable.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final description = gateway.description;

    return ListTile(
      // Without an onTap the tile's InkWell has no handler, so the row is no
      // tap target and no focus stop. The menu in `trailing` is a control of
      // its own and takes its own taps.
      onTap: onOpen,
      focusNode: focusNode,
      title: Text(gateway.name),
      // Under the name rather than in `trailing`, for the reason the
      // household list gives: at 200% text a trailing badge takes the whole
      // row and fails to lay out.
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${gateway.connectionUrl}:${gateway.connectionPort}'),
          if (description != null && description.isNotEmpty) Text(description),
          const BgeGap.xs(),
          DataGatewayEnabledBadge(enabled: gateway.enabled),
          // A disabled row has no line, and so no gap for it.
          if (gateway.enabled) ...[
            const BgeGap.xs(),
            DataGatewayStatusLine(
              key: DataGatewayListScreen.statusKeyOf(gateway.id),
              gateway: gateway,
            ),
          ],
        ],
      ),
      trailing: busy
          ? Semantics(
              label: l10n.dataGatewayBusy(gateway.name),
              child: ExcludeSemantics(
                child: SizedBox.square(
                  // The size of the menu button's icon it stands in for.
                  dimension: BgeTokens.of(context).spaceLg,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : mayUpdate || mayDelete
          ? Focus(
              focusNode: menuFocusNode,
              child: _RowMenu(
                gateway: gateway,
                mayUpdate: mayUpdate,
                mayDelete: mayDelete,
                onEdit: onEdit,
              ),
            )
          : null,
    );
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({
    required this.gateway,
    required this.mayUpdate,
    required this.mayDelete,
    this.onEdit,
  });

  final DataGateway gateway;

  /// Offers edit, connect and disconnect.
  final bool mayUpdate;

  /// Offers delete.
  final bool mayDelete;
  final VoidCallback? onEdit;

  void _request(BuildContext context, DataGatewayRowAction action) => context
      .read<DataGatewayListBloc>()
      .add(DataGatewayListActionRequested(action, gateway.id));

  Future<void> _confirmDelete(BuildContext context) async {
    final l10n = DataGatewayLocalizations.of(context);
    // Read before the dialog opens: a reload that fails meanwhile takes this
    // row, and the context it was asked from, off the screen.
    final bloc = context.read<DataGatewayListBloc>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.dataGatewayDeleteConfirmTitle(gateway.name)),
        content: Text(l10n.dataGatewayDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.dataGatewayCancel),
          ),
          TextButton(
            key: DataGatewayListScreen.deleteConfirmKey,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.dataGatewayDelete),
          ),
        ],
      ),
    );
    // The bloc drops a delete for a row it no longer lists, and one the
    // caller's access no longer allows.
    if ((confirmed ?? false) && !bloc.isClosed) {
      bloc.add(
        DataGatewayListActionRequested(DataGatewayRowAction.delete, gateway.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final edit = onEdit;

    return PopupMenuButton<_MenuItem>(
      key: DataGatewayListScreen.rowMenuKey(gateway.id),
      tooltip: l10n.dataGatewayRowActions(gateway.name),
      onSelected: (item) => switch (item) {
        _MenuItem.edit => edit?.call(),
        // A menu opened online can outlast the connection (#49).
        _MenuItem.connect ||
        _MenuItem.disconnect ||
        _MenuItem.delete when BgeConnectivityScope.offlineOf(context) => null,
        _MenuItem.connect => _request(context, DataGatewayRowAction.connect),
        _MenuItem.disconnect => _request(
          context,
          DataGatewayRowAction.disconnect,
        ),
        _MenuItem.delete => unawaited(_confirmDelete(context)),
      },
      itemBuilder: (_) {
        // Connect, Disconnect and Delete are direct writes (#49). Their items
        // follow the connection while the menu is open; a press that lands
        // as it drops is guarded in onSelected.
        return [
          if (mayUpdate) ...[
            if (edit != null)
              PopupMenuItem(
                key: DataGatewayListScreen.editKey,
                value: _MenuItem.edit,
                child: Text(l10n.dataGatewayEdit),
              ),
            // Offered on an enabled DataGateway too: the server keeps no
            // record of whether it is connected, so trying again is the only
            // way back from a connect that failed.
            BgeOnlineOnlyPopupMenuItem(
              key: DataGatewayListScreen.connectKey,
              value: _MenuItem.connect,
              label: l10n.dataGatewayConnect,
            ),
            if (gateway.enabled)
              BgeOnlineOnlyPopupMenuItem(
                key: DataGatewayListScreen.disconnectKey,
                value: _MenuItem.disconnect,
                label: l10n.dataGatewayDisconnect,
              ),
          ],
          if (mayDelete)
            BgeOnlineOnlyPopupMenuItem(
              key: DataGatewayListScreen.deleteKey,
              value: _MenuItem.delete,
              label: l10n.dataGatewayDelete,
            ),
        ];
      },
    );
  }
}

enum _MenuItem { edit, connect, disconnect, delete }

class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({required this.outcome, required this.dismissFocus});

  final DataGatewayListOutcome outcome;

  /// For the Dismiss, which takes focus from a control access takes away.
  final FocusNode dismissFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final name = outcome.name;

    final (tone, message) = switch ((outcome.action, outcome.result)) {
      (_, DataGatewayActionResult.refused) => (
        BgeBannerTone.info,
        l10n.dataGatewayChangeRefused,
      ),
      (_, DataGatewayActionResult.gone) => (
        BgeBannerTone.info,
        l10n.dataGatewayGone(name),
      ),
      (DataGatewayRowAction.connect, DataGatewayActionResult.done) => (
        BgeBannerTone.success,
        l10n.dataGatewayConnected(name),
      ),
      (DataGatewayRowAction.connect, DataGatewayActionResult.attemptFailed) => (
        BgeBannerTone.warning,
        l10n.dataGatewayConnectAttemptFailed(name),
      ),
      (DataGatewayRowAction.connect, DataGatewayActionResult.failed) => (
        BgeBannerTone.error,
        l10n.dataGatewayConnectFailed(name),
      ),
      (DataGatewayRowAction.disconnect, DataGatewayActionResult.done) => (
        BgeBannerTone.success,
        l10n.dataGatewayDisconnected(name),
      ),
      (
        DataGatewayRowAction.disconnect,
        DataGatewayActionResult.attemptFailed,
      ) =>
        (BgeBannerTone.warning, l10n.dataGatewayDisconnectAttemptFailed(name)),
      (DataGatewayRowAction.disconnect, DataGatewayActionResult.failed) => (
        BgeBannerTone.error,
        l10n.dataGatewayDisconnectFailed(name),
      ),
      // A delete never reports a failed attempt: see the bloc.
      (
        DataGatewayRowAction.delete,
        DataGatewayActionResult.done || DataGatewayActionResult.attemptFailed,
      ) =>
        (BgeBannerTone.success, l10n.dataGatewayDeleted(name)),
      (DataGatewayRowAction.delete, DataGatewayActionResult.failed) => (
        BgeBannerTone.error,
        l10n.dataGatewayDeleteFailed(name),
      ),
    };

    return BgeInlineBanner(
      key: DataGatewayListScreen.outcomeKey,
      tone: tone,
      message: message,
      action: TextButton(
        focusNode: dismissFocus,
        onPressed: () => context.read<DataGatewayListBloc>().add(
          const DataGatewayListOutcomeDismissed(),
        ),
        child: Text(l10n.dataGatewayDismiss),
      ),
    );
  }
}
