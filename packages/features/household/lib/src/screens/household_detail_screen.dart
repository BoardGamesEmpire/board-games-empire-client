import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/awaiting_approval_count_cubit.dart';
import '../bloc/household_detail_bloc.dart';
import '../bloc/household_detail_event.dart';
import '../bloc/household_detail_state.dart';
import '../bloc/household_member_actions_bloc.dart';
import '../bloc/household_member_actions_event.dart';
import '../bloc/household_member_actions_state.dart';
import '../members/member_action_message.dart';
import '../permissions/household_actions.dart';
import '../widgets/household_refresh_banner.dart';
import '../widgets/household_role_label.dart';
import '../sync/household_hydration_status.dart';

/// One household (#270): its name, its description, who is in it, and what
/// the current user is in it.
///
/// Decoupled from DI like the list and create screens: the caller resolves
/// the user-session [HouseholdRepository] and the optional
/// [HouseholdHydrationStatus] stream and passes them in; the screen owns
/// its bloc.
///
/// ## The roster (#304)
///
/// The member count heads a list of the members: each one's name over their
/// role, by role and then by name, with the user's own row marked. A name
/// is the member's display name, else their username, which every account
/// has. A row no hydrate has named still renders, so the list is as long as
/// the count: the user's own reads "You", as on a household just created
/// here, and anyone else's reads as their role alone, or "Member" with none.
///
/// ## A member's menu (#480)
///
/// To its owners and admins, a row offers a menu beside the member's name:
/// change their role, remove them, or both, as the role table allows the
/// viewer on that member (#483). An admin acts only on members and guests,
/// nobody acts on their own row, and on another owner, an owner may only
/// remove them. Each is sent straight to the server and never queued, and
/// how it went shows in a banner under the member count until dismissed.
///
/// The menu is left out for a household the server does not know yet
/// (`isLocalOnly`), and where the composition passes no [members] client.
///
/// ## What this screen does not show
///
/// **No avatars** yet (#603), and no opening a member's row yet (#540).
/// **No leaving, transferring or deleting** the household yet (#479, #478,
/// #477).
///
/// ## Edit and invites are the exceptions
///
/// To its owners and admins, the screen offers Edit in the app bar (#476),
/// and an entry to the household's invites (#455), with how many await
/// approval (#489). Both are online-only: an edit is sent straight to the
/// server and its answer cached, and invites are read from the server and
/// never queued, so neither needs a sync op. Both are left out for a
/// household the server does not know yet (`isLocalOnly`), whose id it
/// would not recognise, and where the composition passes no [onEdit] or no
/// [invites] client.
///
/// To a member, the screen offers an Invite row in the entry's place when
/// the household's member invite policy lets members invite (#569). It
/// opens the send form, since a member can't read the household's invites.
/// It is left out for a household the server does not know yet, and where
/// the composition passes no [onInvite].
///
/// ## New event (#499)
///
/// To an owner, an admin or a member ([HouseholdRole.mayCreateEvents]), the
/// screen offers a New event row, after the Invite row. It opens the form for
/// creating an event with this household picked. A guest lacks
/// `create:event:household`, so the row is left out for a guest, and for a
/// role this app does not recognise. It is left out for a household the
/// server does not know yet, whose id it would not recognise, and where the
/// composition passes no [onNewEvent].
///
/// ## Not-found is an answer, not an error
///
/// An id the current user cannot read renders the not-found state, and it
/// is deliberately indistinguishable from a household that never existed
/// and from a tombstoned one — the repository merges those three cases at
/// the membership gate, and a screen cannot un-merge them. The literal id
/// `create` lands here too, so a stray `/household/create` match cannot
/// become a query.
class HouseholdDetailScreen extends StatelessWidget {
  const HouseholdDetailScreen({
    required this.householdId,
    required this.repository,
    this.hydration,
    this.onBack,
    this.onRetry,
    this.invites,
    this.onOpenInvites,
    this.onEdit,
    this.onInvite,
    this.onNewEvent,
    this.members,
    this.onMembershipChanged,
    super.key,
  });

  /// Key on the first-read spinner.
  static const Key loadingKey = Key('household_detail.loading');

  /// Key on the not-found surface.
  static const Key notFoundKey = Key('household_detail.not_found');

  /// Key on the not-found surface's return-to-list button.
  static const Key notFoundBackKey = Key('household_detail.not_found_back');

  /// Key on the refresh banner's retry button (#300 D10). One key for both
  /// banners — the ready one and the not-found one — because it is one
  /// control on one screen, in whichever place the screen currently is.
  static const Key refreshRetryKey = Key('household_detail.refresh_retry');

  /// Key on the failed-read surface.
  static const Key errorKey = Key('household_detail.error');

  /// Key on the couldn't-refresh banner.
  static const Key refreshBannerKey = Key('household_detail.refresh_banner');

  /// Key on the member count, which heads the roster.
  static const Key memberCountKey = Key('household_detail.member_count');

  /// Key on a member's row in the roster, by their user id: their name over
  /// their role, which a screen reader reads as one node. The row's menu
  /// sits beside it, under [memberActionsKey].
  static Key memberKey(String userId) => Key('household_detail.member.$userId');

  /// Key on the button that opens a member's menu, by their user id.
  static Key memberActionsKey(String userId) =>
      Key('household_detail.member_actions.$userId');

  /// Key on the Change role item of the open member menu.
  static const Key changeRoleKey = Key('household_detail.change_role');

  /// Key on the Remove item of the open member menu.
  static const Key removeKey = Key('household_detail.remove');

  /// Key on a role's option in the change-role dialog.
  static Key roleOptionKey(HouseholdRole role) =>
      Key('household_detail.role_option.${role.name}');

  /// Key on the change-role dialog's Save button.
  static const Key roleSaveKey = Key('household_detail.role_save');

  /// Key on the remove dialog's confirm button.
  static const Key removeConfirmKey = Key('household_detail.remove_confirm');

  /// Key on the banner saying how the last role change or removal went.
  static const Key memberOutcomeKey = Key('household_detail.member_outcome');

  /// Key on the current user's role.
  static const Key roleKey = Key('household_detail.role');

  /// Key on the entry to the household's invites.
  static const Key invitesKey = Key('household_detail.invites');

  /// Key on the Edit button.
  static const Key editKey = Key('household_detail.edit');

  /// Key on a member's Invite row.
  static const Key inviteKey = Key('household_detail.invite');

  /// Key on the New event row.
  static const Key newEventKey = Key('household_detail.new_event');

  /// The household to show. A literal `create` never reaches the
  /// repository — see the class doc.
  final String householdId;

  /// The user-session household repository. Read-only here.
  final HouseholdRepository repository;

  /// What the hydrate is doing, when this composition runs one. Null reads
  /// as settled rather than as forever-loading (#269 D1).
  final Stream<HouseholdHydrationState>? hydration;

  /// Returns to the household list from the not-found state, as that
  /// surface's primary action: with no household to show, leaving is the
  /// likely intent, so it is offered in the body rather than left to the
  /// app bar's back button alone. Null offers no such button.
  ///
  /// Called with this screen's own context, mirroring the list's
  /// `onCreate` — the feature package does not know the route table.
  final void Function(BuildContext context)? onBack;

  /// Runs one more hydrate pass, or null where this composition has none
  /// (#300 D5, D10). The same callback the list screen takes, driving the
  /// same status — this screen and that one are two views of one refresh.
  final Future<void> Function()? onRetry;

  /// The per-server invite client, for the awaiting-approval count. Null
  /// leaves the invites entry out.
  final HouseholdInviteRemoteDataSource? invites;

  /// Opens the household's invites, with this screen's context and the
  /// household's current id. The count is read again whenever this screen
  /// comes back into view, so it holds after a deep link too. Null leaves
  /// the invites entry out.
  final void Function(BuildContext context, String householdId)? onOpenInvites;

  /// Opens the household's edit form, with this screen's context and the
  /// household's current id. Offered to its owners and admins only. Null
  /// leaves Edit out.
  final void Function(BuildContext context, String householdId)? onEdit;

  /// Opens the send-invite form, with this screen's context and the
  /// household's current id. Offered to a member whose household's policy
  /// lets members invite. Null leaves the Invite row out.
  final void Function(BuildContext context, String householdId)? onInvite;

  /// Opens the form for a new event in this household, with this screen's
  /// context and the household's current id. Offered to an owner, an admin
  /// or a member. Null leaves the New event row out (#499).
  final void Function(BuildContext context, String householdId)? onNewEvent;

  /// The per-server member client, for changing a member's role or removing
  /// them (#480). Null, or a null [onMembershipChanged], leaves every row
  /// without a menu.
  final HouseholdMemberRemoteDataSource? members;

  /// Marks the household list stale and reads it again after a role change
  /// or removal, as `refreshAfterMembershipChange` does. Null leaves every
  /// row without a menu, as a null [members] does.
  final Future<void> Function()? onMembershipChanged;

  /// The reserved create segment. `/household/create` is a route of its
  /// own, declared first; this is the belt to that braces (#270 D6).
  static const String _reservedCreateId = 'create';

  @override
  Widget build(BuildContext context) {
    // A path that resolved `create` as an id means the route table changed
    // under us. Answer it locally rather than asking the repository about
    // a household nobody can have created with that id.
    if (householdId == _reservedCreateId) {
      return _NotFoundPage(onBack: onBack);
    }

    // Both or neither: without the refresh, a 404 would leave the member on
    // the list, and the banners that say the household is being read again
    // would be wrong.
    final memberActions = switch ((members, onMembershipChanged)) {
      (final remote?, final onChanged?) => (
        remote: remote,
        onChanged: onChanged,
      ),
      _ => null,
    };

    return MultiBlocProvider(
      // go_router keeps this page when only the id changes; the key makes a
      // new id new blocs rather than the old household under them (#466).
      key: ValueKey<String>(householdId),
      providers: [
        BlocProvider<HouseholdDetailBloc>(
          create: (_) => HouseholdDetailBloc(
            householdId: householdId,
            repository: repository,
            hydration: hydration,
            onRetry: onRetry,
          ),
        ),
        // None without a member client and a refresh, and then no row has a
        // menu.
        if (memberActions != null)
          BlocProvider<HouseholdMemberActionsBloc>(
            create: (_) => HouseholdMemberActionsBloc(
              remote: memberActions.remote,
              repository: repository,
              onChanged: memberActions.onChanged,
            ),
          ),
      ],
      // The callbacks stay with the blocs; the view only needs to know
      // whether there is one, to decide whether to draw a control.
      child: _HouseholdDetailView(
        onBack: onBack,
        canRetry: onRetry != null,
        invites: invites,
        onOpenInvites: onOpenInvites,
        onEdit: onEdit,
        onInvite: onInvite,
        onNewEvent: onNewEvent,
        hasMemberActionsBloc: memberActions != null,
      ),
    );
  }
}

class _HouseholdDetailView extends StatelessWidget {
  const _HouseholdDetailView({
    this.onBack,
    this.canRetry = false,
    this.invites,
    this.onOpenInvites,
    this.onEdit,
    this.onInvite,
    this.onNewEvent,
    this.hasMemberActionsBloc = false,
  });

  final void Function(BuildContext context)? onBack;

  /// Whether this composition can re-run the drain at all (#300 D5).
  final bool canRetry;

  final HouseholdInviteRemoteDataSource? invites;
  final void Function(BuildContext context, String householdId)? onOpenInvites;
  final void Function(BuildContext context, String householdId)? onEdit;
  final void Function(BuildContext context, String householdId)? onInvite;
  final void Function(BuildContext context, String householdId)? onNewEvent;

  /// Whether a [HouseholdMemberActionsBloc] is provided above, which is
  /// whether the composition passed a member client.
  final bool hasMemberActionsBloc;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BlocBuilder<HouseholdDetailBloc, HouseholdDetailState>(
      builder: (context, state) {
        return switch (state) {
          HouseholdDetailLoading() => _MessagePage(
            title: l10n.householdListTitle,
            child: _Loading(message: l10n.householdDetailLoading),
          ),
          HouseholdDetailError() => _MessagePage(
            title: l10n.householdListTitle,
            child: BgeInlineBanner(
              key: HouseholdDetailScreen.errorKey,
              tone: BgeBannerTone.error,
              message: l10n.householdDetailError,
            ),
          ),
          HouseholdDetailNotFound(:final refreshFailed) => _NotFoundPage(
            onBack: onBack,
            refreshFailed: refreshFailed,
            canRetry: canRetry,
          ),
          HouseholdDetailReady() => _ReadyPage(
            state: state,
            canRetry: canRetry,
            invites: invites,
            onOpenInvites: onOpenInvites,
            onEdit: onEdit,
            onInvite: onInvite,
            onNewEvent: onNewEvent,
            hasMemberActionsBloc: hasMemberActionsBloc,
          ),
        };
      },
    );
  }
}

/// The household itself.
class _ReadyPage extends StatelessWidget {
  const _ReadyPage({
    required this.state,
    this.canRetry = false,
    this.invites,
    this.onOpenInvites,
    this.onEdit,
    this.onInvite,
    this.onNewEvent,
    this.hasMemberActionsBloc = false,
  });

  final HouseholdDetailReady state;

  /// Whether a retry can be offered — see [HouseholdDetailScreen.onRetry].
  final bool canRetry;

  final HouseholdInviteRemoteDataSource? invites;
  final void Function(BuildContext context, String householdId)? onOpenInvites;
  final void Function(BuildContext context, String householdId)? onEdit;
  final void Function(BuildContext context, String householdId)? onInvite;
  final void Function(BuildContext context, String householdId)? onNewEvent;

  /// Whether a [HouseholdMemberActionsBloc] is provided above.
  final bool hasMemberActionsBloc;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final description = state.household.description;
    final hasDescription = description != null && description.isNotEmpty;
    final invites = this.invites;
    final openInvites = onOpenInvites;
    final edit = onEdit;
    final invite = onInvite;
    final newEvent = onNewEvent;
    // Empty for a household the server does not know yet, so none of the
    // controls below is offered for one.
    final actions = householdActionsFor(state.household, state.role);

    return BgePage(
      // The household's own name, not a generic one: the title is the first
      // thing that says where you landed, and the invite deep link (#243)
      // will land here without the user having walked past the list.
      title: Text(state.household.name),
      actions: [
        if (edit != null && actions.contains(HouseholdAction.edit))
          IconButton(
            key: HouseholdDetailScreen.editKey,
            icon: const Icon(Icons.edit_outlined),
            tooltip: l10n.householdDetailEdit,
            onPressed: () => edit(context, state.household.id),
          ),
      ],
      width: BgePageWidth.pane,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.refreshFailed || state.refreshing) ...[
            _refreshBanner(
              context,
              canRetry: canRetry,
              refreshing: state.refreshing,
            ),
            const BgeGap.md(),
          ],
          if (hasDescription) ...[
            Text(description, style: theme.textTheme.bodyLarge),
            const BgeGap.lg(),
          ],
          _Roster(state: state, hasMemberActionsBloc: hasMemberActionsBloc),
          // Omitted entirely when there is no role to state (#270 D4):
          // a null binding, or an identity we could not resolve. An empty
          // "Your role" label would be a question the screen asks itself.
          if (state.role != null) ...[
            const BgeGap.lg(),
            _RoleBlock(role: state.role!),
          ],
          if (invites != null &&
              openInvites != null &&
              actions.contains(HouseholdAction.manageInvites)) ...[
            const BgeGap.lg(),
            _InvitesEntry(
              // Keyed on the id, which a reconcile changes (#306): the count
              // belongs to the household the server knows by that id.
              key: ValueKey<String>(state.household.id),
              householdId: state.household.id,
              invites: invites,
              onOpen: openInvites,
              hasMemberActionsBloc: hasMemberActionsBloc,
            ),
          ],
          // In the entry's place, for a member who may invite but can't
          // read the household's invites (#569).
          if (invite != null &&
              actions.contains(HouseholdAction.sendInvite) &&
              !actions.contains(HouseholdAction.manageInvites)) ...[
            const BgeGap.lg(),
            ListTile(
              key: HouseholdDetailScreen.inviteKey,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: Text(l10n.householdDetailInvite),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => invite(context, state.household.id),
            ),
          ],
          // After the Invite row, for an owner, an admin or a member: a guest
          // may not create an event here (#499). Not for a household the
          // server does not know yet, whose id is this device's own.
          if (newEvent != null &&
              !state.household.isLocalOnly &&
              (state.role?.mayCreateEvents ?? false)) ...[
            const BgeGap.lg(),
            ListTile(
              key: HouseholdDetailScreen.newEventKey,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(l10n.householdNewEvent),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => newEvent(context, state.household.id),
            ),
          ],
        ],
      ),
    );
  }
}

/// The way to the household's invites, with how many await approval
/// (#455, #489).
class _InvitesEntry extends StatelessWidget {
  const _InvitesEntry({
    required this.householdId,
    required this.invites,
    required this.onOpen,
    required this.hasMemberActionsBloc,
    super.key,
  });

  final String householdId;
  final HouseholdInviteRemoteDataSource invites;
  final void Function(BuildContext context, String householdId) onOpen;

  /// Whether a [HouseholdMemberActionsBloc] is provided above.
  final bool hasMemberActionsBloc;

  @override
  Widget build(BuildContext context) {
    final entry = BlocBuilder<AwaitingApprovalCountCubit, int?>(
      builder: (context, count) {
        final l10n = HouseholdLocalizations.of(context);
        // Read again on the way back from the invites, or from any
        // route above this screen: approving there changes the count.
        return ReadAgainWhenUncovered(
          onUncovered: () =>
              unawaited(context.read<AwaitingApprovalCountCubit>().load()),
          child: ListTile(
            key: HouseholdDetailScreen.invitesKey,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.mail_outline),
            title: Text(l10n.householdDetailInvites),
            subtitle: count == null || count == 0
                ? null
                : Text(l10n.householdDetailInvitesAwaiting(count)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(context, householdId),
          ),
        );
      },
    );

    return BlocProvider<AwaitingApprovalCountCubit>(
      create: (_) =>
          AwaitingApprovalCountCubit(householdId: householdId, remote: invites)
            ..load(),
      child: !hasMemberActionsBloc
          ? entry
          // Removing a member revokes the invites they sent, those awaiting
          // approval among them (backend#747), and the dialogs that start
          // it never cover this screen. So every removal's outcome reads
          // the count again. Only a request's end emits one.
          : BlocListener<
              HouseholdMemberActionsBloc,
              HouseholdMemberActionsState
            >(
              listenWhen: (_, current) =>
                  current.outcome?.action == HouseholdMemberAction.remove,
              listener: (context, _) =>
                  unawaited(context.read<AwaitingApprovalCountCubit>().load()),
              child: entry,
            ),
    );
  }
}

/// The member actions a row's menu offers. Making someone owner has no
/// route until #478.
const _menuActions = {
  HouseholdMemberAction.changeRole,
  HouseholdMemberAction.remove,
};

/// The member count over the roster (#304), with each row's menu and the
/// banner saying how the last member action went (#480).
class _Roster extends StatelessWidget {
  const _Roster({required this.state, required this.hasMemberActionsBloc});

  final HouseholdDetailReady state;

  /// Whether a [HouseholdMemberActionsBloc] is provided above.
  final bool hasMemberActionsBloc;

  @override
  Widget build(BuildContext context) {
    if (!hasMemberActionsBloc) return _build(context, null);

    return BlocBuilder<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
      builder: _build,
    );
  }

  /// [actionsState] is null where there is no member client, and then no row
  /// has a menu.
  Widget _build(
    BuildContext context,
    HouseholdMemberActionsState? actionsState,
  ) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final outcome = actionsState?.outcome;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            key: HouseholdDetailScreen.memberCountKey,
            l10n.householdDetailMembers(state.memberCount),
            style: theme.textTheme.titleMedium,
          ),
        ),
        const BgeGap.xs(),
        if (outcome != null) ...[
          _MemberOutcomeBanner(outcome: outcome),
          const BgeGap.xs(),
        ],
        for (final member in state.members)
          _MemberRow(
            key: ValueKey<String>(member.userId),
            member: member,
            isYou: member.userId == state.currentUserId,
            menu: _menuFor(member, actionsState),
          ),
      ],
    );
  }

  /// [member]'s menu, with what the role table lets the viewer do to them
  /// (#483), or null where that is nothing.
  Widget? _menuFor(
    HouseholdMember member,
    HouseholdMemberActionsState? actionsState,
  ) {
    // A household the server does not know yet has no member ids it issued,
    // so its rows offer nothing, as Edit and invites are left out (#476).
    if (actionsState == null || state.household.isLocalOnly) return null;

    final offered = householdMemberActionsFor(
      viewerRole: state.role,
      isSelf: member.userId == state.currentUserId,
      target: member,
    ).intersection(_menuActions);
    if (offered.isEmpty) return null;

    return _MemberMenu(
      member: member,
      actions: offered,
      roles: assignableMemberRoles(state.role),
      busy: actionsState.busy.contains(member.id),
    );
  }
}

/// One member of the roster: their name over their role, as one semantics
/// node (#304). The role line is left out where the member has no role
/// binding, and stands in for the name of anyone else no hydrate has named:
/// "Member" over a role of member would say the same thing twice.
///
/// The member's menu, where the viewer has one, sits beside that node and
/// outside it, so a screen reader reaches it as a control of its own rather
/// than as part of the row's label (#480). Tapping the row itself does
/// nothing yet; #540 will open the member's profile there.
class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isYou,
    this.menu,
    super.key,
  });

  final HouseholdMember member;

  /// Whether this is the current user's own row.
  final bool isYou;

  /// The member's menu, or null for none.
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final name = member.name;
    final role = member.role;
    final roleLabel = role == null ? null : householdRoleLabel(l10n, role);
    final byRoleAlone = !isYou && name == null;
    final menu = this.menu;

    final details = MergeSemantics(
      key: HouseholdDetailScreen.memberKey(member.userId),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(switch ((isYou, name)) {
              (true, final name?) => l10n.householdDetailMemberYou(name),
              (true, null) => l10n.householdDetailMemberYouUnnamed,
              (false, final name?) => name,
              (false, null) => roleLabel ?? l10n.householdDetailMemberUnnamed,
            }, style: theme.textTheme.bodyLarge),
            if (roleLabel != null && !byRoleAlone)
              Text(
                roleLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );

    if (menu == null) return details;
    return Row(
      children: [
        Expanded(child: details),
        menu,
      ],
    );
  }
}

/// A member's menu: change their role, remove them, or both (#480).
class _MemberMenu extends StatelessWidget {
  const _MemberMenu({
    required this.member,
    required this.actions,
    required this.roles,
    required this.busy,
  });

  final HouseholdMember member;

  /// What the menu offers, never empty.
  final Set<HouseholdMemberAction> actions;

  /// The roles the viewer may give, in the order the dialog lists them.
  final List<HouseholdRole> roles;

  /// A request for this member is on its way. The menu stays shut until it
  /// answers.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final name = member.name;

    return MenuAnchor(
      // Left unconstrained, the panel sits in a hard-clipped box as wide as
      // its widest entry, which at 2.0 text runs past a phone's edge. Held
      // to the screen, the entries wrap instead.
      crossAxisUnconstrained: false,
      menuChildren: [
        if (actions.contains(HouseholdMemberAction.changeRole))
          MenuItemButton(
            key: HouseholdDetailScreen.changeRoleKey,
            overflowAxis: Axis.vertical,
            onPressed: () => unawaited(_changeRole(context)),
            child: Text(l10n.householdMemberChangeRole),
          ),
        if (actions.contains(HouseholdMemberAction.remove))
          MenuItemButton(
            key: HouseholdDetailScreen.removeKey,
            overflowAxis: Axis.vertical,
            onPressed: () => unawaited(_remove(context)),
            child: Text(l10n.householdMemberRemove),
          ),
      ],
      builder: (context, controller, _) => MergeSemantics(
        child: Semantics(
          expanded: controller.isOpen,
          child: IconButton(
            key: HouseholdDetailScreen.memberActionsKey(member.userId),
            icon: const Icon(Icons.more_vert),
            // Every row has one, so the name says whose it is to a screen
            // reader moving from button to button.
            tooltip: name == null
                ? l10n.householdMemberActions
                : l10n.householdMemberActionsFor(name),
            onPressed: busy
                ? null
                : controller.isOpen
                ? controller.close
                : controller.open,
          ),
        ),
      ),
    );
  }

  Future<void> _changeRole(BuildContext context) async {
    // Read before the dialog opens: a refresh that lands meanwhile can take
    // this row, and the context it was asked from, off the screen.
    final bloc = context.read<HouseholdMemberActionsBloc>();
    final role = await showDialog<HouseholdRole>(
      context: context,
      builder: (_) => _RoleDialog(roles: roles, current: member.role),
    );
    if (role == null || bloc.isClosed) return;
    bloc.add(HouseholdMemberRoleChangeRequested(member, role));
  }

  Future<void> _remove(BuildContext context) async {
    final bloc = context.read<HouseholdMemberActionsBloc>();
    if (!await _confirmRemove(context) || bloc.isClosed) return;
    bloc.add(HouseholdMemberRemovalRequested(member));
  }

  Future<bool> _confirmRemove(BuildContext context) async {
    final l10n = HouseholdLocalizations.of(context);
    final name = member.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // At 2.0 text the title and body can outgrow a phone's height.
        scrollable: true,
        title: Text(
          name == null
              ? l10n.householdMemberRemoveConfirmTitleUnnamed
              : l10n.householdMemberRemoveConfirmTitle(name),
        ),
        content: Text(l10n.householdMemberRemoveConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.householdMemberCancel),
          ),
          TextButton(
            key: HouseholdDetailScreen.removeConfirmKey,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.householdMemberRemoveConfirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

/// Picks a member's new role from the ones the viewer may give (#480), and
/// pops with it. Cancel pops with nothing.
class _RoleDialog extends StatefulWidget {
  const _RoleDialog({required this.roles, required this.current});

  final List<HouseholdRole> roles;

  /// The member's role now, chosen when the dialog opens. Saving it would
  /// change nothing, so Save waits for another.
  final HouseholdRole? current;

  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> {
  HouseholdRole? _chosen;

  @override
  void initState() {
    super.initState();
    _chosen = widget.current;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final chosen = _chosen;

    return AlertDialog(
      // Three options, each with a line on what the role may do, outgrow a
      // phone's height at 2.0 text.
      scrollable: true,
      title: Text(l10n.householdMemberRoleDialogTitle),
      content: RadioGroup<HouseholdRole>(
        groupValue: chosen,
        onChanged: (role) => setState(() => _chosen = role),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final role in widget.roles)
              RadioListTile<HouseholdRole>(
                key: HouseholdDetailScreen.roleOptionKey(role),
                value: role,
                contentPadding: EdgeInsets.zero,
                title: Text(householdRoleLabel(l10n, role)),
                subtitle: switch (_roleDescription(l10n, role)) {
                  final description? => Text(description),
                  null => null,
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.householdMemberCancel),
        ),
        TextButton(
          key: HouseholdDetailScreen.roleSaveKey,
          onPressed: chosen == null || chosen == widget.current
              ? null
              : () => Navigator.of(context).pop(chosen),
          child: Text(l10n.householdMemberRoleSave),
        ),
      ],
    );
  }
}

/// What [role] may do, under its option in the change-role dialog.
///
/// Owner is never offered, since an owner is made only by a transfer
/// (#478), and nor is a role this app does not recognise. Neither has one.
String? _roleDescription(HouseholdLocalizations l10n, HouseholdRole role) =>
    switch (role) {
      HouseholdRole.householdAdmin => l10n.householdRoleAdminDescription,
      HouseholdRole.householdMember => l10n.householdRoleMemberDescription,
      HouseholdRole.householdGuest => l10n.householdRoleGuestDescription,
      HouseholdRole.householdOwner || HouseholdRole.unknown => null,
    };

/// How the last role change or removal went (#480), under the member count
/// until dismissed or replaced. A live region, as every [BgeInlineBanner]
/// is.
class _MemberOutcomeBanner extends StatelessWidget {
  const _MemberOutcomeBanner({required this.outcome});

  final HouseholdMemberOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BgeInlineBanner(
      key: HouseholdDetailScreen.memberOutcomeKey,
      tone: _tone(outcome),
      message: memberActionMessage(l10n, outcome),
      action: TextButton(
        onPressed: () => context.read<HouseholdMemberActionsBloc>().add(
          const HouseholdMemberOutcomeDismissed(),
        ),
        child: Text(l10n.householdMemberDismiss),
      ),
    );
  }

  /// Success when what was asked for holds, a warning when it did not
  /// happen, and an error when nobody can say.
  static BgeBannerTone _tone(HouseholdMemberOutcome outcome) =>
      switch (outcome.result) {
        HouseholdMemberActionResult.done => BgeBannerTone.success,
        HouseholdMemberActionResult.gone => switch (outcome.action) {
          // They are out of the household, or it is gone, and either way
          // that is what removing them asked for.
          HouseholdMemberAction.remove => BgeBannerTone.success,
          // There was no one to change.
          HouseholdMemberAction.changeRole ||
          HouseholdMemberAction.makeOwner => BgeBannerTone.warning,
        },
        HouseholdMemberActionResult.refused => BgeBannerTone.warning,
        HouseholdMemberActionResult.failed => BgeBannerTone.error,
      };
}

/// "Your role" over its value, as one semantics node so a screen reader
/// reads the pair rather than a stray label.
class _RoleBlock extends StatelessWidget {
  const _RoleBlock({required this.role});

  final HouseholdRole role;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);

    return Semantics(
      key: HouseholdDetailScreen.roleKey,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.householdDetailYourRole,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            householdRoleLabel(l10n, role),
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

/// No readable household at this id — see [HouseholdDetailScreen].
class _NotFoundPage extends StatelessWidget {
  const _NotFoundPage({
    this.onBack,
    this.refreshFailed = false,
    this.canRetry = false,
  });

  final void Function(BuildContext context)? onBack;

  /// Whether a retry can be offered. This is the surface where it is worth
  /// the most (#300 D10): a household absent from a cache whose last pass
  /// failed may well be on the server, so asking again can change what is
  /// on screen rather than only how fresh it is.
  ///
  /// It carries no in-flight copy of its own. Once the pass reports
  /// `running`, the bloc stops asserting the absence and this page gives
  /// way to the spinner — which is the feedback.
  final bool canRetry;

  /// The pass that would have confirmed the absence did not finish. The
  /// screen says both things: we could not find it, and we could not
  /// check.
  final bool refreshFailed;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final back = onBack;

    return BgePage(
      title: Text(l10n.householdListTitle),
      width: BgePageWidth.pane,
      centerVertically: true,
      child: Column(
        key: HouseholdDetailScreen.notFoundKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (refreshFailed) ...[
            _refreshBanner(context, canRetry: canRetry),
            const BgeGap.lg(),
          ],
          Text(
            l10n.householdDetailNotFoundTitle,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const BgeGap.sm(),
          Text(
            l10n.householdDetailNotFoundBody,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          // The app bar's back button does the same thing. This one is here
          // because leaving is the likely intent on this surface.
          if (back != null) ...[
            const BgeGap.lg(),
            FilledButton.icon(
              key: HouseholdDetailScreen.notFoundBackKey,
              onPressed: () => back(context),
              icon: const Icon(Icons.groups_outlined),
              label: Text(l10n.householdDetailNotFoundAction),
            ),
          ],
        ],
      ),
    );
  }
}

/// This screen's half of the shared refresh banner (#300 D10): its own
/// copy and key, and a press routed to its own bloc.
///
/// [canRetry] is threaded down rather than the callback itself, because
/// the dispatch needs a context under the [BlocProvider] — which the
/// reserved-`create` path deliberately does not have.
Widget _refreshBanner(
  BuildContext context, {
  required bool canRetry,
  bool refreshing = false,
}) {
  final l10n = HouseholdLocalizations.of(context);
  return HouseholdRefreshBanner(
    key: HouseholdDetailScreen.refreshBannerKey,
    retryKey: HouseholdDetailScreen.refreshRetryKey,
    failedMessage: l10n.householdDetailRefreshFailed,
    refreshing: refreshing,
    onRetry: canRetry
        ? () => context.read<HouseholdDetailBloc>().add(
            const HouseholdDetailRetryRequested(),
          )
        : null,
  );
}

/// A centred single message on an otherwise empty page.
class _MessagePage extends StatelessWidget {
  const _MessagePage({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => BgePage(
    title: Text(title),
    width: BgePageWidth.pane,
    centerVertically: true,
    child: child,
  );
}

class _Loading extends StatelessWidget {
  const _Loading({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    key: HouseholdDetailScreen.loadingKey,
    child: Semantics(
      liveRegion: true,
      label: message,
      // The label carries the announcement; the spinner has nothing to say
      // to a screen reader.
      child: const ExcludeSemantics(child: CircularProgressIndicator()),
    ),
  );
}
