import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:household/src/bloc/household_invite_list_state.dart';
import 'package:household/src/bloc/sent_invites_bloc.dart';
import 'package:household/src/bloc/sent_invites_event.dart';
import 'package:household/src/bloc/sent_invites_state.dart';
import 'package:household/src/invites/invite_expiry_line.dart';
import 'package:household/src/invites/invite_refusal_message.dart';
import 'package:household/src/invites/sent_invite_filter.dart';
import 'package:household/src/permissions/household_actions.dart';
import 'package:household/src/widgets/household_invite_awaiting_badge.dart';
import 'package:household/src/widgets/household_invite_busy_indicator.dart';
import 'package:household/src/widgets/household_role_label.dart';
import 'package:household/src/widgets/invite_filter_menu.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The invites the current user sent (#487), across every household, by
/// status: withdraw one still outstanding, or see how the others ended.
///
/// Online-only, read from the server when the screen opens. Decoupled from
/// DI like the other household screens: the caller resolves the per-server
/// [HouseholdInviteRemoteDataSource].
class SentInvitesScreen extends StatelessWidget {
  const SentInvitesScreen({
    required this.remote,
    this.initialFilter = SentInviteFilter.openAndExpired,
    super.key,
  });

  static const Key loadingKey = Key('sent_invites.loading');
  static const Key emptyKey = Key('sent_invites.empty');
  static const Key failedKey = Key('sent_invites.failed');
  static const Key moreKey = Key('sent_invites.more');
  static const Key outcomeKey = Key('sent_invites.outcome');
  static const Key filterKey = Key('sent_invites.filter');

  /// Per-row keys.
  ///
  /// [rowKey] is held by the wrapper [BgeKeyedSliverList] puts around each
  /// row, not by the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String inviteId) => Key('sent_invites.row_$inviteId');
  static Key withdrawKey(String inviteId) =>
      Key('sent_invites.withdraw_$inviteId');

  final HouseholdInviteRemoteDataSource remote;

  /// The filter the list opens on: Open and expired, or Declined for a link
  /// from a notification (#475). The person changes it from there.
  final SentInviteFilter initialFilter;

  @override
  Widget build(BuildContext context) => BlocProvider<SentInvitesBloc>(
    // A new opening filter is a new list: the route's page key is its path
    // pattern, so a link to the other filter reuses this State (#475).
    key: ValueKey<SentInviteFilter>(initialFilter),
    create: (_) =>
        SentInvitesBloc(remote: remote, initialFilter: initialFilter)
          ..add(const SentInvitesLoadRequested()),
    child: const _SentInvitesView(),
  );
}

class _SentInvitesView extends StatelessWidget {
  const _SentInvitesView();

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BlocBuilder<SentInvitesBloc, SentInvitesState>(
      builder: (context, state) {
        final bloc = context.read<SentInvitesBloc>();
        final ready = state is SentInvitesReady ? state : null;
        final tokens = BgeTokens.of(context);

        return BgePage.slivers(
          title: Text(l10n.sentInvitesTitle),
          width: BgePageWidth.pane,
          semanticChildCount: ready == null || ready.invites.isEmpty
              ? null
              : ready.invites.length,
          slivers: [
            // In every state: a read that failed under one status can still
            // be switched away from. The bloc's filter, not the state's,
            // so a change made before the first read answers shows.
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
              SentInvitesLoading() => BgeStateSliver(
                child: BgeLoadingState(
                  key: SentInvitesScreen.loadingKey,
                  label: l10n.sentInvitesLoading,
                ),
              ),
              SentInvitesFailed() => BgeStateSliver(
                child: BgeErrorState(
                  key: SentInvitesScreen.failedKey,
                  icon: Icons.cloud_off_outlined,
                  title: l10n.sentInvitesFailed,
                  body: l10n.householdInvitesFailedBody,
                  retryLabel: l10n.householdInvitesRetry,
                  onRetry: () => bloc.add(const SentInvitesLoadRequested()),
                ),
              ),
              SentInvitesReady(:final invites, :final filter)
                  when invites.isEmpty =>
                BgeStateSliver(
                  child: BgeEmptyState(
                    key: SentInvitesScreen.emptyKey,
                    icon: Icons.outbox_outlined,
                    title: filter == SentInviteFilter.openAndExpired
                        ? l10n.sentInvitesEmpty
                        : l10n.sentInvitesEmptyFiltered,
                  ),
                ),
              final SentInvitesReady ready =>
                BgeKeyedSliverList<HouseholdInvite>(
                  items: ready.invites,
                  keyOf: (invite) => SentInvitesScreen.rowKey(invite.id),
                  itemBuilder: (context, invite) => _SentRow(
                    invite: invite,
                    busy: ready.busy.contains(invite.id),
                  ),
                ),
            },
            if (ready != null && ready.hasMore)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(top: tokens.spaceMd),
                  child: Center(
                    child: OutlinedButton(
                      key: SentInvitesScreen.moreKey,
                      onPressed: ready.loadingMore
                          ? null
                          : () => bloc.add(const SentInvitesMoreRequested()),
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
}

/// Which of the sent invites to list, as wide as the pane.
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({required this.filter});

  final SentInviteFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return InviteFilterMenu<SentInviteFilter>(
      buttonKey: SentInvitesScreen.filterKey,
      choices: SentInviteFilter.values,
      chosen: filter,
      choiceLabel: (choice) => _filterLabel(l10n, choice),
      buttonLabel: l10n.sentInvitesFilterLabel,
      onChosen: (choice) =>
          context.read<SentInvitesBloc>().add(SentInvitesFilterChanged(choice)),
    );
  }
}

String _filterLabel(HouseholdLocalizations l10n, SentInviteFilter filter) =>
    switch (filter) {
      SentInviteFilter.openAndExpired => l10n.sentInvitesFilterOpenAndExpired,
      SentInviteFilter.pending => l10n.inviteStatusPending,
      SentInviteFilter.awaitingApproval => l10n.householdInviteStatusAwaiting,
      SentInviteFilter.expired => l10n.inviteStatusExpired,
      SentInviteFilter.accepted => l10n.inviteStatusAccepted,
      SentInviteFilter.declined => l10n.inviteStatusDeclined,
      SentInviteFilter.withdrawn => l10n.inviteStatusWithdrawn,
      SentInviteFilter.revoked => l10n.inviteStatusRevoked,
    };

class _SentRow extends StatelessWidget {
  const _SentRow({required this.invite, required this.busy});

  final HouseholdInvite invite;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final invitee = invite.inviteeLabel;
    final role = invite.role;
    final message = invite.message;
    final statusLine =
        inviteExpiryLine(l10n, invite) ??
        inviteSettledLabel(l10n, invite.status);
    // As on the household list, withdrawing your own invite does not ask.
    final mayWithdraw = sentInviteRowActions(invite)
        .contains(HouseholdInviteRowAction.withdraw);

    return BgeOutlinedRow(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(
              invite.householdName ?? l10n.inviteInboxUnknownHousehold,
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  invitee == null
                      ? l10n.sentInviteForAccount
                      : l10n.sentInviteFor(invitee),
                ),
                if (role != null) Text(householdRoleLabel(l10n, role)),
                if (invite.status == HouseholdInviteStatus.awaitingApproval)
                  const HouseholdInviteAwaitingBadge(),
                if (statusLine != null) Text(statusLine),
                if (message != null) ...[
                  const BgeGap.xs(),
                  Text(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
            trailing: busy ? const HouseholdInviteBusyIndicator() : null,
          ),
          if (mayWithdraw)
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: tokens.spaceMd,
                end: tokens.spaceMd,
                bottom: tokens.spaceSm,
              ),
              // A direct write, so it waits for a connection (#49).
              child: BgeOnlineOnly(
                child: OutlinedButton(
                  key: SentInvitesScreen.withdrawKey(invite.id),
                  onPressed: busy || BgeConnectivityScope.offlineOf(context)
                      ? null
                      : () => context.read<SentInvitesBloc>().add(
                          SentInvitesWithdrawRequested(invite.id),
                        ),
                  child: Text(l10n.householdInviteWithdraw),
                ),
              ),
            ),
        ],
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

    final (tone, message) = switch (outcome.result) {
      HouseholdInviteActionResult.done => (
        BgeBannerTone.success,
        l10n.householdInviteDoneWithdraw,
      ),
      HouseholdInviteActionResult.refused => (
        BgeBannerTone.warning,
        inviteRefusalMessage(
          l10n,
          HouseholdInviteAction.withdraw,
          outcome.error ?? outcome,
        ),
      ),
      HouseholdInviteActionResult.failed => (
        BgeBannerTone.error,
        inviteRefusalMessage(
          l10n,
          HouseholdInviteAction.withdraw,
          outcome.error ?? outcome,
        ),
      ),
    };

    return BgeInlineBanner(
      key: SentInvitesScreen.outcomeKey,
      tone: tone,
      message: message,
      action: TextButton(
        onPressed: () => context.read<SentInvitesBloc>().add(
          const SentInvitesOutcomeDismissed(),
        ),
        child: Text(l10n.householdInvitesDismiss),
      ),
    );
  }
}
