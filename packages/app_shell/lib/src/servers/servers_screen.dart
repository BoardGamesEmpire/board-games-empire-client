import 'dart:async';

import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:app_shell/src/servers/server_activation.dart';
import 'package:app_shell/src/servers/server_list_cubit.dart';
import 'package:app_shell/src/servers/server_list_state.dart';
import 'package:app_shell/src/servers/server_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The server manager (#134): every server added on this device, with its
/// state, where a pick makes one the server in use and **Add server** adds
/// another.
///
/// It belongs to the device, not to a server's session: it reads only the
/// cubit [create] makes, so it opens signed out as well as signed in.
///
/// A pick that lands goes home, and the router takes a server that is
/// signed out to its sign-in screen. A pick that fails says why in a
/// SnackBar and stays; the row picked never left the focus order, so a
/// keyboard or screen-reader user is still on it. A pick that ends after
/// the screen has started to leave does the same from wherever the user
/// went: one that lands goes home, and one that fails says why over the
/// page showing. Back is the only way to leave while a pick runs: **Add
/// server** is disabled until it ends.
class ServersScreen extends StatelessWidget {
  const ServersScreen({required this.create, super.key});

  /// Makes the list's cubit. The screen owns it, and closes it as it goes.
  final ServerListCubit Function() create;

  /// Key on the **Add server** button.
  static const Key addKey = Key('servers.add');

  /// Key on the failed list's retry button.
  static const Key retryKey = Key('servers.retry');

  /// Per-row key, held by the wrapper `BgeKeyedSliverList` puts around each
  /// row (#549).
  static Key rowKey(String serverId) => Key('servers.row_$serverId');

  @override
  Widget build(BuildContext context) => BlocProvider<ServerListCubit>(
    create: (_) => create(),
    child: const _ServersView(),
  );
}

class _ServersView extends StatelessWidget {
  const _ServersView();

  Future<void> _pick(BuildContext context, String serverId) async {
    // Read before the await: Back mid-switch, or a redirect, can take the
    // screen away while the pick runs, and its outcome still has to reach
    // the user wherever they are. The messenger is the app's, above every
    // page, so a failure is said over whatever page is showing.
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = ShellLocalizations.of(context);
    final outcome = await context.read<ServerListCubit>().pick(serverId);
    switch (outcome) {
      case ServerPickDone():
        // Whatever page the screen left was built for the server the switch
        // just left, whose session it ended (#134). Home is built for the
        // server now active, or the router takes a signed-out one to its
        // sign-in screen.
        router.go(AppRoutes.home);
      case ServerPickFailed(:final error):
        messenger.replaceSnackBar(
          serverActivationFailureText(
            l10n,
            error,
            fallback: l10n.shellServerSwitchFailed,
          ),
        );
      case ServerPickIgnored():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    return BlocBuilder<ServerListCubit, ServerListState>(
      builder: (_, state) => BgePage.slivers(
        title: Text(l10n.shellServersTitle),
        width: BgePageWidth.pane,
        semanticChildCount: switch (state) {
          ServerListReady(:final rows) => rows.length,
          _ => null,
        },
        floatingActionButton: BgeExtendedFab(
          key: ServersScreen.addKey,
          // Disabled while a switch runs: a pick that lands goes home, and
          // would take an add form opened in the meantime with it, along
          // with whatever was typed there. Disabled rather than inert, as
          // the rows are: no press of its own made it unavailable, and the
          // row picked has the focus.
          onPressed: state is ServerListReady && state.switchingTo != null
              ? null
              : () => unawaited(context.push<void>(AppRoutes.serversAdd)),
          icon: const Icon(Icons.add),
          label: l10n.shellServersAdd,
        ),
        slivers: [
          switch (state) {
            ServerListLoading() => BgeStateSliver(
              child: BgeLoadingState(label: l10n.shellServersLoading),
            ),
            ServerListFailed() => BgeStateSliver(
              child: BgeErrorState(
                icon: Icons.dns_outlined,
                title: l10n.shellServersFailedTitle,
                body: l10n.shellServersFailedBody,
                retryLabel: l10n.shellServersRetry,
                retryKey: ServersScreen.retryKey,
                onRetry: context.read<ServerListCubit>().retry,
              ),
            ),
            ServerListReady(:final rows, :final switchingTo) =>
              BgeKeyedSliverList<ServerListRow>(
                items: rows,
                keyOf: (row) => ServersScreen.rowKey(row.server.id),
                itemBuilder: (_, row) => ServerTile(
                  row: row,
                  switchingTo: switchingTo,
                  onTap: () => unawaited(_pick(context, row.server.id)),
                ),
              ),
          },
        ],
      ),
    );
  }
}
