import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:household/src/bloc/household_invite_list_bloc.dart';
import 'package:household/src/bloc/household_invite_list_event.dart';
import 'package:household/src/bloc/household_invite_list_state.dart';
import 'package:household/src/invites/invite_refusal_message.dart';
import 'package:household/src/permissions/household_actions.dart';
import 'package:household/src/widgets/household_invite_tile.dart';
import 'package:household/src/widgets/invite_filter_menu.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A household's open invites, for its owners and admins (#455, #454,
/// #489), with withdraw, revoke and approve; or, by its filter, those
/// awaiting approval or those declined (#475).
///
/// Online-only: read from the server when the screen opens, and again
/// whenever it comes back into view, so an invite sent from the form it
/// opened shows up without the form handing anything back.
///
/// Decoupled from DI like the other household screens: the caller resolves
/// the per-server [HouseholdInviteRemoteDataSource] and the user-session
/// [HouseholdRepository], and owns the route to the send form through
/// [onInvite].
class HouseholdInviteListScreen extends StatelessWidget {
  const HouseholdInviteListScreen({
    required this.householdId,
    required this.remote,
    required this.repository,
    this.initialFilter = HouseholdInviteFilter.open,
    this.onInvite,
    super.key,
  });

  static const Key loadingKey = Key('household_invite_list.loading');
  static const Key filterKey = Key('household_invite_list.filter');
  static const Key emptyKey = Key('household_invite_list.empty');
  static const Key deniedKey = Key('household_invite_list.denied');
  static const Key failedKey = Key('household_invite_list.failed');
  static const Key moreKey = Key('household_invite_list.more');
  static const Key inviteKey = Key('household_invite_list.invite');
  static const Key outcomeKey = Key('household_invite_list.outcome');
  static const Key confirmKey = Key('household_invite_list.confirm');

  /// Per-row key: `household_invite_list.row_<inviteId>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String inviteId) =>
      Key('household_invite_list.row_$inviteId');

  final String householdId;
  final HouseholdInviteRemoteDataSource remote;
  final HouseholdRepository repository;

  /// The filter the list opens on: Open, or Awaiting approval or Declined
  /// for a link from a notification (#475). The person changes it from
  /// there.
  final HouseholdInviteFilter initialFilter;

  /// Opens the send form. Null hides the invite button, as does a viewer
  /// who may not invite.
  final void Function(BuildContext context)? onInvite;

  @override
  Widget build(BuildContext context) => BlocProvider<HouseholdInviteListBloc>(
    // A new id is a new list, not the old household's rows under it (#466).
    // So is a new opening filter: the route's page key is its path pattern,
    // so a link to the same household's other filter reuses this State (#475).
    key: ValueKey<(String, HouseholdInviteFilter)>((
      householdId,
      initialFilter,
    )),
    create: (_) => HouseholdInviteListBloc(
      householdId: householdId,
      remote: remote,
      repository: repository,
      initialFilter: initialFilter,
    )..add(const HouseholdInviteListLoadRequested()),
    child: Builder(
      builder: (context) => ReadAgainWhenUncovered(
        onUncovered: () => context.read<HouseholdInviteListBloc>().add(
          const HouseholdInviteListLoadRequested(),
        ),
        child: _HouseholdInviteListView(onInvite: onInvite),
      ),
    ),
  );
}

class _HouseholdInviteListView extends StatelessWidget {
  const _HouseholdInviteListView({this.onInvite});

  final void Function(BuildContext context)? onInvite;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BlocBuilder<HouseholdInviteListBloc, HouseholdInviteListState>(
      builder: (context, state) {
        final bloc = context.read<HouseholdInviteListBloc>();
        final ready = state is HouseholdInviteListReady ? state : null;
        final invite = onInvite;
        final showInvite =
            invite != null &&
            ready != null &&
            householdRoleActions(ready.viewerRole)
                .contains(HouseholdAction.manageInvites);
        final tokens = BgeTokens.of(context);

        return BgePage.slivers(
          title: Text(l10n.householdInvitesTitle),
          width: BgePageWidth.pane,
          semanticChildCount: ready == null || ready.invites.isEmpty
              ? null
              : ready.invites.length,
          floatingActionButton: showInvite
              ? BgeExtendedFab(
                  key: HouseholdInviteListScreen.inviteKey,
                  onPressed: () => invite(context),
                  icon: const Icon(Icons.person_add_alt),
                  label: l10n.householdInvitesInvite,
                )
              : null,
          slivers: [
            if (state is! HouseholdInviteListDenied)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceMd),
                  child: _FilterMenu(filter: bloc.filter),
                ),
              ),
            if (ready?.outcome case final outcome?)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceMd),
                  child: _OutcomeBanner(outcome: outcome),
                ),
              ),
            switch (state) {
              HouseholdInviteListLoading() => BgeStateSliver(
                child: BgeLoadingState(
                  key: HouseholdInviteListScreen.loadingKey,
                  label: l10n.householdInvitesLoading,
                ),
              ),
              HouseholdInviteListDenied() => BgeStateSliver(
                child: BgeEmptyState(
                  key: HouseholdInviteListScreen.deniedKey,
                  icon: Icons.lock_outline,
                  title: l10n.householdInvitesDenied,
                ),
              ),
              HouseholdInviteListFailed() => BgeStateSliver(
                child: BgeErrorState(
                  key: HouseholdInviteListScreen.failedKey,
                  icon: Icons.cloud_off_outlined,
                  title: l10n.householdInvitesFailed,
                  body: l10n.householdInvitesFailedBody,
                  retryLabel: l10n.householdInvitesRetry,
                  onRetry: () =>
                      bloc.add(const HouseholdInviteListLoadRequested()),
                ),
              ),
              HouseholdInviteListReady(:final invites, :final filter)
                  when invites.isEmpty =>
                BgeStateSliver(
                  child: BgeEmptyState(
                    key: HouseholdInviteListScreen.emptyKey,
                    icon: Icons.mail_outline,
                    title: switch (filter) {
                      HouseholdInviteFilter.open => l10n.householdInvitesEmpty,
                      HouseholdInviteFilter.awaitingApproval =>
                        l10n.householdInvitesEmptyAwaiting,
                      HouseholdInviteFilter.declined =>
                        l10n.householdInvitesEmptyDeclined,
                    },
                  ),
                ),
              final HouseholdInviteListReady ready =>
                BgeKeyedSliverList<HouseholdInvite>(
                  items: ready.invites,
                  keyOf: (invite) =>
                      HouseholdInviteListScreen.rowKey(invite.id),
                  itemBuilder: (context, invite) => HouseholdInviteTile(
                    invite: invite,
                    actions: ready.actionsFor(invite),
                    busy: ready.busy.contains(invite.id),
                    onAction: (action) =>
                        unawaited(_request(context, action, invite)),
                  ),
                ),
            },
            if (ready != null && ready.hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(top: tokens.spaceMd),
                  child: Center(
                    child: OutlinedButton(
                      key: HouseholdInviteListScreen.moreKey,
                      onPressed: ready.loadingMore
                          ? null
                          : () => bloc.add(
                              const HouseholdInviteListMoreRequested(),
                            ),
                      child: Text(l10n.householdInvitesMore),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Revoking, or turning down, asks first. Withdrawing and approving do
  /// not: the first is the sender's own invite, and the second can be
  /// undone by revoking.
  static Future<void> _request(
    BuildContext context,
    HouseholdInviteRowAction action,
    HouseholdInvite invite,
  ) async {
    // Read before a dialog opens: a reload that fails meanwhile takes this
    // row, and the context it was asked from, off the screen.
    final bloc = context.read<HouseholdInviteListBloc>();
    if (action == HouseholdInviteRowAction.revoke &&
        !await _confirmRevoke(context, invite)) {
      return;
    }
    // The bloc drops an action on a row it no longer lists.
    if (!bloc.isClosed) {
      bloc.add(HouseholdInviteListActionRequested(action, invite.id));
    }
  }

  static Future<bool> _confirmRevoke(
    BuildContext context,
    HouseholdInvite invite,
  ) async {
    final l10n = HouseholdLocalizations.of(context);
    final awaiting = invite.status == HouseholdInviteStatus.awaitingApproval;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          awaiting
              ? l10n.householdInviteTurnDownConfirmTitle
              : l10n.householdInviteRevokeConfirmTitle,
        ),
        content: Text(
          awaiting
              ? l10n.householdInviteTurnDownConfirmBody
              : l10n.householdInviteRevokeConfirmBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.householdInviteCancel),
          ),
          TextButton(
            key: HouseholdInviteListScreen.confirmKey,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(HouseholdInviteTile.revokeLabel(l10n, invite)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

/// Which of the household's invites to list, as wide as the pane: the
/// same menu the sent invites filter with.
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({required this.filter});

  final HouseholdInviteFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return InviteFilterMenu<HouseholdInviteFilter>(
      buttonKey: HouseholdInviteListScreen.filterKey,
      choices: HouseholdInviteFilter.values,
      chosen: filter,
      choiceLabel: (choice) => switch (choice) {
        HouseholdInviteFilter.open => l10n.householdInvitesFilterOpen,
        HouseholdInviteFilter.awaitingApproval =>
          l10n.householdInvitesFilterAwaiting,
        HouseholdInviteFilter.declined => l10n.householdInvitesFilterDeclined,
      },
      buttonLabel: l10n.householdInvitesFilterLabel,
      onChosen: (choice) => context.read<HouseholdInviteListBloc>().add(
        HouseholdInviteListFilterChanged(choice),
      ),
    );
  }
}

class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({required this.outcome});

  final HouseholdInviteListOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final action = switch (outcome.action) {
      HouseholdInviteRowAction.withdraw => HouseholdInviteAction.withdraw,
      HouseholdInviteRowAction.revoke => HouseholdInviteAction.revoke,
      HouseholdInviteRowAction.approve => HouseholdInviteAction.approve,
    };

    final (tone, message) = switch (outcome.result) {
      HouseholdInviteActionResult.done => (
        BgeBannerTone.success,
        switch (outcome.action) {
          HouseholdInviteRowAction.withdraw => l10n.householdInviteDoneWithdraw,
          HouseholdInviteRowAction.revoke => l10n.householdInviteDoneRevoke,
          HouseholdInviteRowAction.approve => l10n.householdInviteDoneApprove,
        },
      ),
      HouseholdInviteActionResult.refused => (
        BgeBannerTone.warning,
        inviteRefusalMessage(l10n, action, outcome.error ?? outcome),
      ),
      HouseholdInviteActionResult.failed => (
        BgeBannerTone.error,
        inviteRefusalMessage(l10n, action, outcome.error ?? outcome),
      ),
    };

    return BgeInlineBanner(
      key: HouseholdInviteListScreen.outcomeKey,
      tone: tone,
      message: message,
      action: TextButton(
        onPressed: () => context.read<HouseholdInviteListBloc>().add(
          const HouseholdInviteListOutcomeDismissed(),
        ),
        child: Text(l10n.householdInvitesDismiss),
      ),
    );
  }
}
