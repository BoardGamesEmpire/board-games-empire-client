import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_invite_list_state.dart';
import '../bloc/sent_invites_bloc.dart';
import '../bloc/sent_invites_event.dart';
import '../bloc/sent_invites_state.dart';
import '../invites/invite_expiry_line.dart';
import '../invites/invite_refusal_message.dart';
import '../invites/sent_invite_filter.dart';
import '../permissions/household_actions.dart';
import '../widgets/household_invite_awaiting_badge.dart';
import '../widgets/household_invite_busy_indicator.dart';
import '../widgets/household_role_label.dart';

/// The invites the current user sent (#487), across every household, by
/// status: withdraw one still outstanding, or see how the others ended.
///
/// Online-only, read from the server when the screen opens. Decoupled from
/// DI like the other household screens: the caller resolves the per-server
/// [HouseholdInviteRemoteDataSource].
class SentInvitesScreen extends StatelessWidget {
  const SentInvitesScreen({required this.remote, super.key});

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

  @override
  Widget build(BuildContext context) => BlocProvider<SentInvitesBloc>(
    create: (_) =>
        SentInvitesBloc(remote: remote)..add(const SentInvitesLoadRequested()),
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
              SentInvitesLoading() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  key: SentInvitesScreen.loadingKey,
                  child: Semantics(
                    liveRegion: true,
                    label: l10n.sentInvitesLoading,
                    child: const ExcludeSemantics(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
              ),
              SentInvitesFailed() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: BgeErrorState(
                    key: SentInvitesScreen.failedKey,
                    icon: Icons.cloud_off_outlined,
                    title: l10n.sentInvitesFailed,
                    body: l10n.householdInvitesFailedBody,
                    retryLabel: l10n.householdInvitesRetry,
                    onRetry: () => bloc.add(const SentInvitesLoadRequested()),
                  ),
                ),
              ),
              SentInvitesReady(:final invites, :final filter)
                  when invites.isEmpty =>
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      key: SentInvitesScreen.emptyKey,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.outbox_outlined,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const BgeGap.sm(),
                        Text(
                          filter == SentInviteFilter.openAndExpired
                              ? l10n.sentInvitesEmpty
                              : l10n.sentInvitesEmptyFiltered,
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
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
///
/// A button that opens a menu rather than a [DropdownMenu], whose
/// single-line field cut the chosen status short at 320dp and 2.0 text.
/// This button's label wraps instead.
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({required this.filter});

  final SentInviteFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return LayoutBuilder(
      builder: (context, constraints) => MenuAnchor(
        // As wide as the button that opens it. Left unconstrained, the
        // menu takes its widest entry's width and clips past the screen.
        crossAxisUnconstrained: false,
        style: MenuStyle(
          minimumSize: WidgetStatePropertyAll(Size(constraints.maxWidth, 0)),
          maximumSize: WidgetStatePropertyAll(
            Size(constraints.maxWidth, double.infinity),
          ),
        ),
        menuChildren: [
          for (final choice in SentInviteFilter.values)
            MenuItemButton(
              // An empty icon on the others keeps their labels in line.
              leadingIcon: Icon(choice == filter ? Icons.check : null),
              overflowAxis: Axis.vertical,
              // The chosen one only closes the menu: asking for it again
              // would read the list over, losing the pages shown.
              onPressed: () {
                if (choice == filter) return;
                context.read<SentInvitesBloc>().add(
                  SentInvitesFilterChanged(choice),
                );
              },
              // The check is only drawn, so the label says it is chosen.
              // Inside the item, where it merges into the item's own node;
              // around it, it would stand as a node of its own.
              child: Semantics(
                selected: choice == filter,
                child: Text(_filterLabel(l10n, choice)),
              ),
            ),
        ],
        builder: (context, controller, _) => MergeSemantics(
          child: Semantics(
            expanded: controller.isOpen,
            child: OutlinedButton(
              key: SentInvitesScreen.filterKey,
              onPressed: controller.isOpen ? controller.close : controller.open,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.sentInvitesFilterLabel(_filterLabel(l10n, filter)),
                    ),
                  ),
                  Icon(
                    controller.isOpen
                        ? Icons.arrow_drop_up
                        : Icons.arrow_drop_down,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(invite.householdName ?? l10n.inviteInboxUnknownHousehold),
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
            child: OutlinedButton(
              key: SentInvitesScreen.withdrawKey(invite.id),
              onPressed: busy
                  ? null
                  : () => context.read<SentInvitesBloc>().add(
                      SentInvitesWithdrawRequested(invite.id),
                    ),
              child: Text(l10n.householdInviteWithdraw),
            ),
          ),
      ],
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
