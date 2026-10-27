import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_invite_list_state.dart';
import '../bloc/invite_inbox_bloc.dart';
import '../bloc/invite_inbox_event.dart';
import '../bloc/invite_inbox_state.dart';
import '../invites/invite_expiry_line.dart';
import '../invites/invite_refusal_message.dart';
import '../widgets/household_invite_busy_indicator.dart';
import '../widgets/household_role_label.dart';

/// The invites sent to the current user (#455, #454): accept one to join
/// its household, or decline it.
///
/// Online-only, read from the server when the screen opens. Decoupled from
/// DI like the other household screens: the caller resolves the per-server
/// [HouseholdInviteRemoteDataSource], brings a joined household onto the
/// device through [onJoined], and owns the routes to it through
/// [onOpenHousehold] and to the invites the user sent through [onOpenSent].
class InviteInboxScreen extends StatelessWidget {
  const InviteInboxScreen({
    required this.remote,
    this.onJoined,
    this.onOpenHousehold,
    this.onOpenSent,
    super.key,
  });

  static const Key loadingKey = Key('invite_inbox.loading');
  static const Key emptyKey = Key('invite_inbox.empty');
  static const Key failedKey = Key('invite_inbox.failed');
  static const Key moreKey = Key('invite_inbox.more');
  static const Key outcomeKey = Key('invite_inbox.outcome');
  static const Key openHouseholdKey = Key('invite_inbox.open_household');
  static const Key declineConfirmKey = Key('invite_inbox.decline_confirm');

  /// The app-bar action that opens the invites the user sent.
  static const Key sentKey = Key('invite_inbox.sent');

  /// The empty inbox's link to the invites the user sent.
  static const Key sentLinkKey = Key('invite_inbox.sent_link');

  /// Per-row keys.
  static Key rowKey(String inviteId) => Key('invite_inbox.row_$inviteId');
  static Key acceptKey(String inviteId) => Key('invite_inbox.accept_$inviteId');
  static Key declineKey(String inviteId) =>
      Key('invite_inbox.decline_$inviteId');

  final HouseholdInviteRemoteDataSource remote;

  /// Brings the household just joined onto the device. Null where this
  /// composition runs no hydrate; the household then arrives with the next
  /// pass that does.
  final Future<void> Function(String householdId)? onJoined;

  /// Opens a household just joined. Null offers no such button.
  final void Function(BuildContext context, String householdId)?
  onOpenHousehold;

  /// Opens the invites the user sent (#487). Null offers no way there.
  final void Function(BuildContext context)? onOpenSent;

  @override
  Widget build(BuildContext context) => BlocProvider<InviteInboxBloc>(
    create: (_) =>
        InviteInboxBloc(remote: remote, onJoined: onJoined)
          ..add(const InviteInboxLoadRequested()),
    child: _InviteInboxView(
      onOpenHousehold: onOpenHousehold,
      onOpenSent: onOpenSent,
    ),
  );
}

class _InviteInboxView extends StatelessWidget {
  const _InviteInboxView({this.onOpenHousehold, this.onOpenSent});

  final void Function(BuildContext context, String householdId)?
  onOpenHousehold;
  final void Function(BuildContext context)? onOpenSent;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BlocBuilder<InviteInboxBloc, InviteInboxState>(
      builder: (context, state) {
        final bloc = context.read<InviteInboxBloc>();
        final ready = state is InviteInboxReady ? state : null;
        final tokens = BgeTokens.of(context);
        final openSent = onOpenSent;

        return BgePage.slivers(
          title: Text(l10n.inviteInboxTitle),
          width: BgePageWidth.pane,
          semanticChildCount: ready == null || ready.invites.isEmpty
              ? null
              : ready.invites.length,
          actions: [
            if (openSent != null)
              IconButton(
                key: InviteInboxScreen.sentKey,
                icon: const Icon(Icons.outbox_outlined),
                tooltip: l10n.sentInvitesTitle,
                onPressed: () => openSent(context),
              ),
          ],
          slivers: [
            if (ready?.outcome case final outcome?)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceMd),
                  child: _OutcomeBanner(
                    outcome: outcome,
                    onOpenHousehold: onOpenHousehold,
                  ),
                ),
              ),
            switch (state) {
              InviteInboxLoading() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  key: InviteInboxScreen.loadingKey,
                  child: Semantics(
                    liveRegion: true,
                    label: l10n.inviteInboxLoading,
                    child: const ExcludeSemantics(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
              ),
              InviteInboxFailed() => SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: BgeErrorState(
                    key: InviteInboxScreen.failedKey,
                    icon: Icons.cloud_off_outlined,
                    title: l10n.inviteInboxFailed,
                    body: l10n.householdInvitesFailedBody,
                    retryLabel: l10n.householdInvitesRetry,
                    onRetry: () => bloc.add(const InviteInboxLoadRequested()),
                  ),
                ),
              ),
              InviteInboxReady(:final invites) when invites.isEmpty =>
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      key: InviteInboxScreen.emptyKey,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.mail_outline,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const BgeGap.sm(),
                        Text(
                          l10n.inviteInboxEmpty,
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                        if (openSent != null) ...[
                          const BgeGap.sm(),
                          TextButton(
                            key: InviteInboxScreen.sentLinkKey,
                            onPressed: () => openSent(context),
                            child: Text(l10n.inviteInboxSentLink),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              final InviteInboxReady ready => SliverList.builder(
                itemCount: ready.invites.length,
                itemBuilder: (context, index) {
                  final row = ready.invites[index];
                  return _InboxRow(
                    invite: row,
                    busy: ready.busy.contains(row.id),
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
                      key: InviteInboxScreen.moreKey,
                      onPressed: ready.loadingMore
                          ? null
                          : () => bloc.add(const InviteInboxMoreRequested()),
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

class _InboxRow extends StatelessWidget {
  const _InboxRow({required this.invite, required this.busy});

  final HouseholdInvite invite;
  final bool busy;

  /// Declining asks first: it cannot be taken back, and joining later takes
  /// a new invite. Accepting does not ask: it is what the invite is for.
  Future<void> _decline(BuildContext context) async {
    final l10n = HouseholdLocalizations.of(context);
    // Read before the dialog opens: a reload meanwhile can take this row,
    // and its context, off the screen.
    final bloc = context.read<InviteInboxBloc>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.inviteInboxDeclineConfirmTitle),
        content: Text(l10n.inviteInboxDeclineConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.householdInviteCancel),
          ),
          TextButton(
            key: InviteInboxScreen.declineConfirmKey,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.inviteInboxDecline),
          ),
        ],
      ),
    );
    if ((confirmed ?? false) && !bloc.isClosed) {
      bloc.add(
        InviteInboxAnswerRequested(HouseholdInviteAction.decline, invite.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final role = invite.role;
    final message = invite.message;
    final expiry = inviteExpiryLine(l10n, invite);

    return Column(
      key: InviteInboxScreen.rowKey(invite.id),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(invite.householdName ?? l10n.inviteInboxUnknownHousehold),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (role != null) Text(householdRoleLabel(l10n, role)),
              Text(l10n.householdInviteFrom(invite.inviter.label)),
              if (expiry != null) Text(expiry),
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
        Padding(
          padding: EdgeInsetsDirectional.only(
            start: tokens.spaceMd,
            end: tokens.spaceMd,
            bottom: tokens.spaceSm,
          ),
          child: Wrap(
            spacing: tokens.spaceSm,
            runSpacing: tokens.spaceSm,
            children: [
              FilledButton(
                key: InviteInboxScreen.acceptKey(invite.id),
                onPressed: busy
                    ? null
                    : () => context.read<InviteInboxBloc>().add(
                        InviteInboxAnswerRequested(
                          HouseholdInviteAction.accept,
                          invite.id,
                        ),
                      ),
                child: Text(l10n.inviteInboxAccept),
              ),
              TextButton(
                key: InviteInboxScreen.declineKey(invite.id),
                onPressed: busy ? null : () => unawaited(_decline(context)),
                child: Text(l10n.inviteInboxDecline),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({required this.outcome, this.onOpenHousehold});

  final InviteInboxOutcome outcome;
  final void Function(BuildContext context, String householdId)?
  onOpenHousehold;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final householdName = outcome.householdName.isEmpty
        ? l10n.inviteInboxUnknownHousehold
        : outcome.householdName;
    final joined = outcome.householdId;
    final open = onOpenHousehold;

    final (tone, message) = switch (outcome.result) {
      HouseholdInviteActionResult.done => (
        BgeBannerTone.success,
        outcome.action == HouseholdInviteAction.accept
            ? l10n.inviteInboxJoined(householdName)
            : l10n.inviteInboxDeclined,
      ),
      HouseholdInviteActionResult.refused => (
        BgeBannerTone.warning,
        inviteRefusalMessage(l10n, outcome.action, outcome.error ?? outcome),
      ),
      HouseholdInviteActionResult.failed => (
        BgeBannerTone.error,
        inviteRefusalMessage(l10n, outcome.action, outcome.error ?? outcome),
      ),
    };

    return BgeInlineBanner(
      key: InviteInboxScreen.outcomeKey,
      tone: tone,
      message: message,
      action: Wrap(
        // The banner puts its action at the end edge. Once the two buttons
        // no longer fit on one line, this keeps the second one there too.
        alignment: WrapAlignment.end,
        children: [
          if (joined != null && open != null)
            TextButton(
              key: InviteInboxScreen.openHouseholdKey,
              onPressed: () => open(context, joined),
              child: Text(l10n.inviteInboxOpenHousehold),
            ),
          TextButton(
            onPressed: () => context.read<InviteInboxBloc>().add(
              const InviteInboxOutcomeDismissed(),
            ),
            child: Text(l10n.householdInvitesDismiss),
          ),
        ],
      ),
    );
  }
}
