import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_invite_list_bloc.dart';
import '../bloc/household_invite_list_event.dart';
import '../bloc/household_invite_list_state.dart';
import '../invites/household_invite_permissions.dart';
import '../invites/invite_refusal_message.dart';
import '../widgets/household_invite_tile.dart';

/// A household's open invites, for its owners and admins (#455, #454,
/// #489), with withdraw, revoke and approve.
///
/// Online-only: read from the server when the screen opens, and again
/// whenever it comes back into view, so an invite sent from the form shows
/// up without the form handing anything back. That includes a form this
/// screen did not open, such as one a deep link built the list beneath.
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

  final String householdId;
  final HouseholdInviteRemoteDataSource remote;
  final HouseholdRepository repository;

  /// Opens the send form. Null hides the invite button, as does a viewer
  /// who may not invite.
  final void Function(BuildContext context)? onInvite;

  @override
  Widget build(BuildContext context) => BlocProvider<HouseholdInviteListBloc>(
    // A new id is a new list, not the old household's rows under it (#466).
    key: ValueKey<String>(householdId),
    create: (_) => HouseholdInviteListBloc(
      householdId: householdId,
      remote: remote,
      repository: repository,
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
            HouseholdInvitePermissions.mayManage(ready.viewerRole);
        final tokens = BgeTokens.of(context);

        return BgePage.slivers(
          title: Text(l10n.householdInvitesTitle),
          width: BgePageWidth.pane,
          semanticChildCount: ready == null || ready.invites.isEmpty
              ? null
              : ready.invites.length,
          floatingActionButton: showInvite
              ? FloatingActionButton.extended(
                  key: HouseholdInviteListScreen.inviteKey,
                  onPressed: () => invite(context),
                  icon: const Icon(Icons.person_add_alt),
                  label: Text(l10n.householdInvitesInvite),
                )
              : null,
          slivers: [
            if (state is! HouseholdInviteListDenied)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceMd),
                  child: _FilterControl(filter: bloc.filter),
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
              HouseholdInviteListLoading() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  key: HouseholdInviteListScreen.loadingKey,
                  child: Semantics(
                    liveRegion: true,
                    label: l10n.householdInvitesLoading,
                    child: const ExcludeSemantics(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
              ),
              HouseholdInviteListDenied() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: _Message(
                    key: HouseholdInviteListScreen.deniedKey,
                    icon: Icons.lock_outline,
                    text: l10n.householdInvitesDenied,
                  ),
                ),
              ),
              HouseholdInviteListFailed() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
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
              ),
              HouseholdInviteListReady(:final invites, :final filter)
                  when invites.isEmpty =>
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: _Message(
                      key: HouseholdInviteListScreen.emptyKey,
                      icon: Icons.mail_outline,
                      text: switch (filter) {
                        HouseholdInviteFilter.open =>
                          l10n.householdInvitesEmpty,
                        HouseholdInviteFilter.awaitingApproval =>
                          l10n.householdInvitesEmptyAwaiting,
                      },
                    ),
                  ),
                ),
              final HouseholdInviteListReady ready => SliverList.builder(
                itemCount: ready.invites.length,
                itemBuilder: (context, index) {
                  final row = ready.invites[index];
                  return HouseholdInviteTile(
                    invite: row,
                    actions: ready.actionsFor(row),
                    busy: ready.busy.contains(row.id),
                    onAction: (action) =>
                        unawaited(_request(context, action, row)),
                  );
                },
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
            // The invite button floats over the end of the list; room below
            // the rows lets the last one scroll clear of it.
            if (showInvite)
              SliverToBoxAdapter(
                child: SizedBox(height: tokens.spaceXxl + tokens.spaceMd),
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

class _FilterControl extends StatelessWidget {
  const _FilterControl({required this.filter});

  final HouseholdInviteFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return SegmentedButton<HouseholdInviteFilter>(
      key: HouseholdInviteListScreen.filterKey,
      segments: [
        ButtonSegment(
          value: HouseholdInviteFilter.open,
          label: Text(l10n.householdInvitesFilterOpen),
        ),
        ButtonSegment(
          value: HouseholdInviteFilter.awaitingApproval,
          label: Text(l10n.householdInvitesFilterAwaiting),
        ),
      ],
      selected: {filter},
      showSelectedIcon: false,
      onSelectionChanged: (selected) => context
          .read<HouseholdInviteListBloc>()
          .add(HouseholdInviteListFilterChanged(selected.single)),
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

/// A centred icon over one line of text, for the empty and denied states.
class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: theme.colorScheme.onSurfaceVariant),
        const BgeGap.sm(),
        Text(
          text,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
