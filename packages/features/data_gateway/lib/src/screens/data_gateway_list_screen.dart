import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

import '../access/data_gateway_access.dart';
import '../bloc/data_gateway_list_bloc.dart';
import '../bloc/data_gateway_list_event.dart';
import '../bloc/data_gateway_list_state.dart';
import '../widgets/data_gateway_message.dart';
import '../widgets/data_gateway_status.dart';

/// The DataGateway admin screen (#41): every DataGateway on the active
/// server, with add, edit, delete, connect and disconnect.
///
/// Decoupled from DI like the household screens: the caller resolves the
/// per-server [DataGatewayRemoteDataSource] and the session's
/// [DataGatewayAccess], and owns the routes to the form and to a
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
/// A refused read is the access-denied surface, with nothing to act on. A
/// refused change hides the add button and every row's menu for the rest of
/// the session, and the banner says why (#41).
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

  /// The session's access, or null for a composition without one.
  final DataGatewayAccess? access;

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

class _DataGatewayListView extends StatelessWidget {
  const _DataGatewayListView({this.onAdd, this.onEdit, this.onOpen});

  final void Function(BuildContext context)? onAdd;
  final void Function(BuildContext context, String id)? onEdit;
  final void Function(BuildContext context, String id)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);

    return BlocBuilder<DataGatewayListBloc, DataGatewayListState>(
      builder: (context, state) {
        final ready = state is DataGatewayListReady ? state : null;
        final add = onAdd;
        final edit = onEdit;
        final open = onOpen;
        final mayChange = ready?.mayChange ?? false;
        final tokens = BgeTokens.of(context);

        return BgePage.slivers(
          title: Text(l10n.dataGatewayListTitle),
          width: BgePageWidth.pane,
          semanticChildCount: ready == null || ready.gateways.isEmpty
              ? null
              : ready.gateways.length,
          floatingActionButton: add == null || !mayChange
              ? null
              : FloatingActionButton.extended(
                  key: DataGatewayListScreen.addKey,
                  onPressed: () => add(context),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.dataGatewayAdd),
                ),
          slivers: [
            if (ready?.outcome case final outcome?)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceMd),
                  child: _OutcomeBanner(outcome: outcome),
                ),
              ),
            switch (state) {
              DataGatewayListLoading() => _LoadingSliver(
                message: l10n.dataGatewayListLoading,
              ),
              DataGatewayListDenied() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: DataGatewayMessage(
                    key: DataGatewayListScreen.deniedKey,
                    icon: Icons.lock_outline,
                    title: l10n.dataGatewayDeniedTitle,
                    body: l10n.dataGatewayDeniedBody,
                  ),
                ),
              ),
              DataGatewayListFailed() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
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
              ),
              DataGatewayListReady(:final gateways) when gateways.isEmpty =>
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: DataGatewayMessage(
                      key: DataGatewayListScreen.emptyKey,
                      title: l10n.dataGatewayListEmptyTitle,
                      body: l10n.dataGatewayListEmptyBody,
                    ),
                  ),
                ),
              DataGatewayListReady(:final gateways, :final busy) =>
                BgeKeyedSliverList<DataGateway>(
                  items: gateways,
                  keyOf: (gateway) => DataGatewayListScreen.rowKey(gateway.id),
                  itemBuilder: (context, gateway) => _DataGatewayRow(
                    gateway: gateway,
                    busy: busy.contains(gateway.id),
                    mayChange: mayChange,
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
    );
  }
}

class _DataGatewayRow extends StatelessWidget {
  const _DataGatewayRow({
    required this.gateway,
    required this.busy,
    required this.mayChange,
    this.onEdit,
    this.onOpen,
  });

  final DataGateway gateway;
  final bool busy;

  /// False hides the row's menu: the user may not change anything.
  final bool mayChange;
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
          : mayChange
          ? _RowMenu(gateway: gateway, onEdit: onEdit)
          : null,
    );
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.gateway, this.onEdit});

  final DataGateway gateway;
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
    // The bloc drops a delete for a row it no longer lists.
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
        _MenuItem.connect => _request(context, DataGatewayRowAction.connect),
        _MenuItem.disconnect => _request(
          context,
          DataGatewayRowAction.disconnect,
        ),
        _MenuItem.delete => unawaited(_confirmDelete(context)),
      },
      itemBuilder: (_) => [
        if (edit != null)
          PopupMenuItem(
            key: DataGatewayListScreen.editKey,
            value: _MenuItem.edit,
            child: Text(l10n.dataGatewayEdit),
          ),
        // Offered on an enabled DataGateway too: the server keeps no record
        // of whether it is connected, so trying again is the only way back
        // from a connect that failed.
        PopupMenuItem(
          key: DataGatewayListScreen.connectKey,
          value: _MenuItem.connect,
          child: Text(l10n.dataGatewayConnect),
        ),
        if (gateway.enabled)
          PopupMenuItem(
            key: DataGatewayListScreen.disconnectKey,
            value: _MenuItem.disconnect,
            child: Text(l10n.dataGatewayDisconnect),
          ),
        PopupMenuItem(
          key: DataGatewayListScreen.deleteKey,
          value: _MenuItem.delete,
          child: Text(l10n.dataGatewayDelete),
        ),
      ],
    );
  }
}

enum _MenuItem { edit, connect, disconnect, delete }

class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({required this.outcome});

  final DataGatewayListOutcome outcome;

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
        onPressed: () => context.read<DataGatewayListBloc>().add(
          const DataGatewayListOutcomeDismissed(),
        ),
        child: Text(l10n.dataGatewayDismiss),
      ),
    );
  }
}

class _LoadingSliver extends StatelessWidget {
  const _LoadingSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      key: DataGatewayListScreen.loadingKey,
      child: Semantics(
        liveRegion: true,
        label: message,
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}
