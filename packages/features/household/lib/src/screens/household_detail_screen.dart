import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyRepeatEvent, LogicalKeyboardKey;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:household/src/bloc/awaiting_approval_count_cubit.dart';
import 'package:household/src/bloc/household_detail_bloc.dart';
import 'package:household/src/bloc/household_detail_event.dart';
import 'package:household/src/bloc/household_detail_state.dart';
import 'package:household/src/bloc/household_member_actions_bloc.dart';
import 'package:household/src/bloc/household_member_actions_event.dart';
import 'package:household/src/bloc/household_member_actions_state.dart';
import 'package:household/src/bloc/leave_household_bloc.dart';
import 'package:household/src/bloc/leave_household_event.dart';
import 'package:household/src/bloc/leave_household_state.dart';
import 'package:household/src/members/leave_message.dart';
import 'package:household/src/members/member_action_message.dart';
import 'package:household/src/members/send_member_request.dart';
import 'package:household/src/permissions/household_actions.dart';
import 'package:household/src/sync/household_hydration_status.dart';
import 'package:household/src/widgets/household_role_label.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

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
/// ## A member's menu (#480, #478)
///
/// To its owners and admins, a row offers a menu beside the member's name:
/// change their role, remove them, or make them owner, as the role table
/// allows the viewer on that member (#483). An admin acts only on members
/// and guests and makes no one owner, nobody acts on their own row, and on
/// another owner, an owner may only remove them. Make owner hands the
/// household over and leaves the viewer an admin, so it asks first, as
/// Remove does. Each is sent straight to the server and never queued, and
/// how it went shows in a banner under the member count until dismissed.
///
/// The menu is left out for a household the server does not know yet
/// (`isLocalOnly`), and where the composition passes no [members] client.
///
/// ## Where focus goes after a member's menu goes (#478)
///
/// An action can take away the menu it was chosen from: after a transfer
/// the viewer has no actions on the new owner, and after a removal the row
/// goes. Focus that was on it moves to the outcome banner's Dismiss, or,
/// with no outcome to show, to the member count. It moves only while the
/// bloc holds a roster, and not if the user has moved it meanwhile. The
/// roster's own doc has the details.
///
/// ## Leaving (#479)
///
/// The page ends with a Leave row, in the error colour, offered to every
/// role the role table gives `leave` (#483). It is left out for a household
/// the server does not know yet (`isLocalOnly`), where the composition
/// passes no [members] client, and where it passes no [onBack], since the
/// screen has to go once the person has left.
///
/// An owner who is the household's last is shown it disabled, with the
/// reason as its second line: with others in it, to make one of them the
/// owner first, which Make owner on their row does (#478), and alone, that
/// they are the only member. That reason comes before the online-only one,
/// since coming back online would not lift it. Otherwise the row is
/// disabled while offline, as every direct write is (#49). The row is one
/// tile in every state, so the connection coming and going changes only
/// its online-only note.
///
/// It asks first, then sends the request straight to the server, never
/// queued. While the request is on its way the row stays enabled and inert,
/// so it keeps focus (#607), and says it is leaving. That comes before both
/// reasons: whatever the roster or the connection does meanwhile, the answer
/// settles the row. Once the server says yes, the page is held: it goes on
/// drawing the household as it last was, rather than the not-found page the
/// membership gate turns it into, so nothing flashes on the way out. Then
/// the screen pops, and a snack bar says the person left. A refusal or a
/// failure stays on the page, in a banner directly above the row until
/// dismissed.
///
/// The screen holds the leave's bloc, not a `BlocProvider`, so a leave the
/// user walks away from still ends (#464). Gone while one is on its way, the
/// screen keeps the bloc until the answer lands, says it in a snack bar over
/// the page the user went to, that they left or, since the banner went with
/// the page, why they didn't, and then closes it, through
/// `closeWhenSettled`. An answer that lands while the route is still on its
/// way out is said the same way. That late answer never calls [onBack]: the
/// user has already gone. No answer is said once [session] has ended,
/// whether the screen is gone or still leaving: it is no news to whoever
/// signs in next (#694). The bloc closes either way.
///
/// A failure can leave the row disabled: offline by the time it lands, or
/// the last owner once a co-owner has gone, while the request was on its way
/// or with the refresh a refusal starts. A disabled row can't hold focus, so
/// focus that was on it moves to the banner's Dismiss, unless the user has
/// moved it meanwhile. The row's own doc has the details.
///
/// ## What this screen does not show
///
/// **No avatars** yet (#603), and no opening a member's row yet (#540).
/// **No deleting** the household yet (#477).
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
/// ## Events (#503)
///
/// Where the composition passes an [eventsSection], a household the server
/// knows shows an Events block to every role, guests included: a heading,
/// the section the composition builds for this household, and under it the
/// New event row. The household package doesn't depend on the events
/// package, so the section arrives as a builder. It is left out for a
/// household the server does not know yet, and where the composition passes
/// none; the New event row then stays after the Invite row.
///
/// The New event row (#499) goes to an owner, an admin or a member, as the
/// role table allows (#483), under the section or, without one, after the
/// Invite row. It opens the form for creating an event with this household
/// picked. A guest lacks `create:event:household`, so the row is left out for
/// a guest, and for a role this app does not recognise. It is left out for a
/// household the server does not know yet, whose id it would not recognise,
/// and where the composition passes no [onNewEvent].
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
    required this.session,
    this.hydration,
    this.onBack,
    this.onRetry,
    this.invites,
    this.onOpenInvites,
    this.onEdit,
    this.onInvite,
    this.onNewEvent,
    this.eventsSection,
    this.members,
    this.onMembershipChanged,
    super.key,
  });

  /// Key on the Events heading (#503).
  static const Key eventsHeadingKey = Key('household_detail.events_heading');

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

  /// Key on the Make owner item of the open member menu (#478).
  static const Key makeOwnerKey = Key('household_detail.make_owner');

  /// Key on a role's option in the change-role dialog.
  static Key roleOptionKey(HouseholdRole role) =>
      Key('household_detail.role_option.${role.name}');

  /// Key on the change-role dialog's Save button.
  static const Key roleSaveKey = Key('household_detail.role_save');

  /// Key on the remove dialog's confirm button.
  static const Key removeConfirmKey = Key('household_detail.remove_confirm');

  /// Key on the Make owner dialog's confirm button (#478).
  static const Key makeOwnerConfirmKey = Key(
    'household_detail.make_owner_confirm',
  );

  /// Key on the banner saying how the last member action went.
  static const Key memberOutcomeKey = Key('household_detail.member_outcome');

  /// Key on that banner's Dismiss button.
  static const Key memberOutcomeDismissKey = Key(
    'household_detail.member_outcome_dismiss',
  );

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

  /// Key on the Leave row (#479).
  static const Key leaveKey = Key('household_detail.leave');

  /// Key on the leave dialog's confirm button (#479).
  static const Key leaveConfirmKey = Key('household_detail.leave_confirm');

  /// Key on the banner saying why the last request to leave did not go
  /// through (#479).
  static const Key leaveFailureKey = Key('household_detail.leave_failure');

  /// The household to show. A literal `create` never reaches the
  /// repository — see the class doc.
  final String householdId;

  /// The user-session household repository. Read-only here.
  final HouseholdRepository repository;

  /// The user session this screen was opened in, from the same container as
  /// [repository] and [members]. A leave that settles after the screen is
  /// gone is said only while it is live (#694).
  final SessionLease session;

  /// What the hydrate is doing, when this composition runs one. Null reads
  /// as settled rather than as forever-loading (#269 D1).
  final Stream<Hydration>? hydration;

  /// Returns to the household list from the not-found state, as that
  /// surface's primary action: with no household to show, leaving is the
  /// likely intent, so it is offered in the body rather than left to the
  /// app bar's back button alone. Null offers no such button.
  ///
  /// Also how the screen goes once the person has left the household
  /// (#479), but not when the leave lands once the user has left the screen
  /// (#464). Null leaves the Leave row out.
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

  /// Builds the household's events section, with the household's current id
  /// (#503). Null leaves the Events block out, and the New event row where it
  /// was.
  final Widget Function(BuildContext context, String householdId)?
  eventsSection;

  /// The per-server member client, for changing a member's role, removing
  /// them or making them owner (#480, #478), and for leaving the household
  /// (#479). Null, or a null [onMembershipChanged], leaves every row
  /// without a menu and leaves the Leave row out.
  final HouseholdMemberRemoteDataSource? members;

  /// Marks the household list stale and reads it again after a member
  /// action or a leave, as `refreshAfterMembershipChange` does. Null leaves
  /// every row without a menu and the Leave row out, as a null [members]
  /// does.
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

    return _HouseholdDetailBlocs(
      // go_router keeps this page when only the id changes; the key makes a
      // new id new blocs rather than the old household under them (#466).
      key: ValueKey<String>(householdId),
      screen: this,
    );
  }
}

/// The screen's blocs for one household (#466), and what is said of a leave.
///
/// The leave's bloc is held here, so it outlives the route (#464), while
/// the detail's and the member actions' stay on their providers. The
/// household's name and the wording of a leave's outcome are kept here too,
/// so a leave that lands while the screen is up and one that lands after it
/// has gone are worded in one place.
class _HouseholdDetailBlocs extends StatefulWidget {
  const _HouseholdDetailBlocs({required this.screen, super.key});

  final HouseholdDetailScreen screen;

  @override
  State<_HouseholdDetailBlocs> createState() => _HouseholdDetailBlocsState();
}

class _HouseholdDetailBlocsState extends State<_HouseholdDetailBlocs> {
  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the route: a leave still on its way then would never say how it ended.
  /// Null without a member client and a refresh, which offers no Leave row.
  /// See [dispose].
  LeaveHouseholdBloc? _leave;

  /// The lease of the session the leave's bloc came from: taken from the
  /// same build as its repository and member client, whenever the bloc is
  /// made, since [dispose] can't trust a later build's.
  late SessionLease _session;

  /// The messenger above the route, which says a bar only while [_session] is
  /// live, and this screen's strings, captured while the screen is mounted: a
  /// leave that settles after it is gone is said with them, and [dispose] can't
  /// look them up.
  late final SessionMessenger _messenger = SessionMessenger(
    sessionIsLive: () => _session.isLive,
  );
  late HouseholdLocalizations _l10n;

  /// The household's name as the page last drew it, for saying the person
  /// left it. The cache may have let the household go by the time the leave
  /// is accepted, and the screen may be gone. Always set by then: Leave is
  /// offered only on a page that drew it.
  String? _name;

  @override
  void initState() {
    super.initState();
    _makeLeave();
  }

  @override
  void didUpdateWidget(_HouseholdDetailBlocs oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A member client and a refresh that arrive later bring the Leave row,
    // as a provider list that grew would have.
    if (_leave == null) _makeLeave();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger.attach(context);
    _l10n = HouseholdLocalizations.of(context);
  }

  @override
  void dispose() {
    // Gone with a leave on its way: it settles, is said while the session
    // lives, and the bloc closes then. Otherwise the screen has already
    // shown whatever there was, and the bloc closes now.
    final leave = _leave;
    if (leave != null) {
      unawaited(
        closeWhenSettled<LeaveHouseholdState>(
          current: leave.state,
          states: leave.stream,
          underWay: (state) => state.busy,
          outcomeOf: _leaveOutcome,
          say: _messenger.say,
          close: leave.close,
        ),
      );
    }
    super.dispose();
  }

  /// Both or neither: without the refresh, a 404 would leave the member on
  /// the list, and the banners that say the household is being read again
  /// would be wrong.
  ({HouseholdMemberRemoteDataSource remote, Future<void> Function() onChanged})?
  get _memberActions => switch ((
    widget.screen.members,
    widget.screen.onMembershipChanged,
  )) {
    (final remote?, final onChanged?) => (remote: remote, onChanged: onChanged),
    _ => null,
  };

  /// Makes the leave's bloc from this build's member client, or none
  /// without one, and takes this build's lease with it.
  void _makeLeave() {
    final screen = widget.screen;
    final actions = _memberActions;
    _session = screen.session;
    _leave = actions == null
        ? null
        : LeaveHouseholdBloc(
            remote: actions.remote,
            repository: screen.repository,
            onChanged: actions.onChanged,
          );
  }

  /// Keeps the household's name from a page drawn, while not held.
  void _remember(HouseholdDetailState state) {
    if (state is HouseholdDetailReady) _name = state.household.name;
  }

  /// Says [state]'s outcome in a snack bar on the messenger above the route,
  /// so it shows on the page beneath once the screen pops. Nothing when it
  /// has none to say, or [_messenger] holds it back.
  void _sayLeave(LeaveHouseholdState state) =>
      _messenger.say(_leaveOutcome(state));

  /// What a snack bar says of a leave: that the person left the household,
  /// or why they didn't, as the banner above the Leave row words it. While
  /// the screen is up only the first is asked for, since a failure is the
  /// banner's to show; once the user has left it, either is (#464).
  String? _leaveOutcome(LeaveHouseholdState state) {
    if (state.phase == LeavePhase.left) {
      final name = _name;
      return name == null ? null : _l10n.householdLeaveDone(name);
    }
    final failure = state.failure;
    return failure == null ? null : leaveFailureMessage(_l10n, failure);
  }

  @override
  Widget build(BuildContext context) {
    final screen = widget.screen;
    // Both or neither: the leave's bloc is made once there is a member
    // client, and a later build without one offers no member actions.
    final member = switch ((_memberActions, _leave)) {
      (final actions?, final leave?) => (actions: actions, leave: leave),
      _ => null,
    };

    final view = _HouseholdDetailView(
      onBack: screen.onBack,
      canRetry: screen.onRetry != null,
      invites: screen.invites,
      onOpenInvites: screen.onOpenInvites,
      onEdit: screen.onEdit,
      onInvite: screen.onInvite,
      onNewEvent: screen.onNewEvent,
      eventsSection: screen.eventsSection,
      hasMemberActionsBloc: member != null,
    );
    final back = screen.onBack;

    return MultiBlocProvider(
      providers: [
        BlocProvider<HouseholdDetailBloc>(
          create: (_) => HouseholdDetailBloc(
            householdId: screen.householdId,
            repository: screen.repository,
            hydration: screen.hydration,
            onRetry: screen.onRetry,
          ),
        ),
        // None without a member client and a refresh, and then no row has a
        // menu and there is no Leave row.
        if (member != null) ...[
          BlocProvider<HouseholdMemberActionsBloc>(
            create: (_) => HouseholdMemberActionsBloc(
              remote: member.actions.remote,
              repository: screen.repository,
              onChanged: member.actions.onChanged,
            ),
          ),
          BlocProvider<LeaveHouseholdBloc>.value(value: member.leave),
        ],
      ],
      // The callbacks stay with the blocs; the view only needs to know
      // whether there is one, to decide whether to draw a control. The Leave
      // row is offered only with a way back.
      child: member == null || back == null
          ? view
          : _LeaveOutcome(
              onBack: back,
              onDrawn: _remember,
              say: _sayLeave,
              child: view,
            ),
    );
  }
}

/// Whether the page is held (#479): the server has accepted a leave, so the
/// page goes on drawing the household as it last was while the screen pops,
/// rather than the not-found page the membership gate turns it into. A
/// detail state that arrives meanwhile is neither drawn nor acted on.
///
/// [leave] is null where no [LeaveHouseholdBloc] is provided, and then the
/// page is never held.
bool _isHeld(LeaveHouseholdBloc? leave) => leave?.state.accepted ?? false;

class _HouseholdDetailView extends StatelessWidget {
  const _HouseholdDetailView({
    this.onBack,
    this.canRetry = false,
    this.invites,
    this.onOpenInvites,
    this.onEdit,
    this.onInvite,
    this.onNewEvent,
    this.eventsSection,
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

  /// Builds the household's events section, with the household's current id
  /// (#503). Null leaves the Events block out, and the New event row where it
  /// was.
  final Widget Function(BuildContext context, String householdId)?
  eventsSection;

  /// Whether a [HouseholdMemberActionsBloc] and a [LeaveHouseholdBloc] are
  /// provided above, which is whether the composition passed a member
  /// client. The two come together or not at all.
  final bool hasMemberActionsBloc;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final leave = hasMemberActionsBloc
        ? context.read<LeaveHouseholdBloc>()
        : null;

    return BlocBuilder<HouseholdDetailBloc, HouseholdDetailState>(
      // The hold (#479). The builder keeps the last state it was given, so
      // a rebuild from above draws the held page too.
      buildWhen: (_, _) => !_isHeld(leave),
      builder: (context, state) {
        return switch (state) {
          HouseholdDetailLoading() => _MessagePage(
            title: l10n.householdListTitle,
            child: BgeLoadingState(
              key: HouseholdDetailScreen.loadingKey,
              label: l10n.householdDetailLoading,
            ),
          ),
          HouseholdDetailError() => _MessagePage(
            title: l10n.householdListTitle,
            child: BgeInlineBanner(
              key: HouseholdDetailScreen.errorKey,
              tone: BgeBannerTone.error,
              message: l10n.householdDetailError,
            ),
          ),
          HouseholdDetailNotFound(:final refreshFailed, :final refreshing) =>
            _NotFoundPage(
              onBack: onBack,
              refreshFailed: refreshFailed,
              refreshing: refreshing,
              canRetry: canRetry,
            ),
          HouseholdDetailReady() => _ReadyPage(
            state: state,
            onBack: onBack,
            canRetry: canRetry,
            invites: invites,
            onOpenInvites: onOpenInvites,
            onEdit: onEdit,
            onInvite: onInvite,
            onNewEvent: onNewEvent,
            eventsSection: eventsSection,
            hasMemberActionsBloc: hasMemberActionsBloc,
          ),
        };
      },
    );
  }
}

/// Says the person left, then pops the screen, once a leave has gone through
/// (#479). On the route's way out, says how any leave ended, and goes
/// nowhere (#464).
///
/// Above the page rather than in the Leave row, so it happens even when the
/// row has gone from under the request: a hydrate that read the list after
/// the server let the person go turns the page into the not-found one while
/// the answer is on its way. The hold then keeps that page drawn until the
/// screen has gone.
///
/// The words are the screen's, through [say], which also words a leave that
/// lands after the screen has gone (#464). So is the household's name they
/// use, which this keeps current through [onDrawn].
class _LeaveOutcome extends StatefulWidget {
  const _LeaveOutcome({
    required this.onBack,
    required this.onDrawn,
    required this.say,
    required this.child,
  });

  /// Where the screen goes once the person has left.
  final void Function(BuildContext context) onBack;

  /// Given each household state the page draws, from the one it is first
  /// built with, but none while it is held: the name in the snack bar is
  /// the household as the page last drew it.
  final void Function(HouseholdDetailState state) onDrawn;

  /// Says how a leave ended, through the screen's lease (#694).
  final void Function(LeaveHouseholdState state) say;

  final Widget child;

  @override
  State<_LeaveOutcome> createState() => _LeaveOutcomeState();
}

class _LeaveOutcomeState extends State<_LeaveOutcome> {
  @override
  void initState() {
    super.initState();
    widget.onDrawn(context.read<HouseholdDetailBloc>().state);
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<HouseholdDetailBloc, HouseholdDetailState>(
          // Not while the page is held, which draws none of them.
          listenWhen: (_, _) => !_isHeld(context.read<LeaveHouseholdBloc>()),
          listener: (_, state) => widget.onDrawn(state),
        ),
        BlocListener<LeaveHouseholdBloc, LeaveHouseholdState>(
          // A leave's end, either way.
          listenWhen: (previous, current) => previous.busy && !current.busy,
          listener: _onEnded,
        ),
      ],
      child: widget.child,
    );
  }

  /// Once the person has left, says so, then goes. [_LeaveOutcome.say] uses
  /// the messenger above the route, so the snack bar shows on the page
  /// beneath. A refusal or a failure is the banner's to show.
  ///
  /// A route already on its way out, by its back button say, says how the
  /// leave ended, a failure too, since its banner is on a page the user has
  /// left, and goes nowhere: popping then would take the page beneath with
  /// it (#464). By the screen's `dispose` the leave has ended, so
  /// `closeWhenSettled` says nothing more. One already gone hears no answer
  /// here: the screen says it as it closes the bloc.
  ///
  /// The page stays live while a leave is on its way, so a dialog or a route
  /// can be open over it when the answer lands, and an [_LeaveOutcome.onBack]
  /// that pops would take whichever is on top. Those go first.
  void _onEnded(BuildContext context, LeaveHouseholdState state) {
    final route = ModalRoute.of(context);
    if (route != null && !route.isActive) {
      widget.say(state);
      return;
    }
    if (state.phase != LeavePhase.left) return;
    if (route != null && !route.isCurrent) {
      Navigator.of(context).popUntil((r) => r == route);
    }
    widget.say(state);
    widget.onBack(context);
  }
}

/// The household itself.
class _ReadyPage extends StatelessWidget {
  const _ReadyPage({
    required this.state,
    this.onBack,
    this.canRetry = false,
    this.invites,
    this.onOpenInvites,
    this.onEdit,
    this.onInvite,
    this.onNewEvent,
    this.eventsSection,
    this.hasMemberActionsBloc = false,
  });

  final HouseholdDetailReady state;

  /// Where the screen goes once the person has left — see
  /// [HouseholdDetailScreen.onBack].
  final void Function(BuildContext context)? onBack;

  /// Whether a retry can be offered — see [HouseholdDetailScreen.onRetry].
  final bool canRetry;

  final HouseholdInviteRemoteDataSource? invites;
  final void Function(BuildContext context, String householdId)? onOpenInvites;
  final void Function(BuildContext context, String householdId)? onEdit;
  final void Function(BuildContext context, String householdId)? onInvite;
  final void Function(BuildContext context, String householdId)? onNewEvent;

  /// Builds the household's events section, with the household's current id
  /// (#503). Null leaves the Events block out, and the New event row where it
  /// was.
  final Widget Function(BuildContext context, String householdId)?
  eventsSection;

  /// Whether a [HouseholdMemberActionsBloc] and a [LeaveHouseholdBloc] are
  /// provided above.
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
    final eventsSection = this.eventsSection;
    final back = onBack;
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
          // Every role sees the events of a household the server knows (#503).
          if (eventsSection != null && !state.household.isLocalOnly) ...[
            const BgeGap.lg(),
            Semantics(
              header: true,
              child: Text(
                key: HouseholdDetailScreen.eventsHeadingKey,
                l10n.householdDetailEvents,
                style: theme.textTheme.titleMedium,
              ),
            ),
            const BgeGap.xs(),
            // Keyed on the id, which a reconcile changes (#306): the events
            // belong to the household the server knows by that id. Tagged,
            // since the invites entry in this Column is keyed on the id too.
            KeyedSubtree(
              key: ValueKey<(String, String)>(('events', state.household.id)),
              child: eventsSection(context, state.household.id),
            ),
          ],
          // Under the events, or after the Invite row where there is no
          // section, for an owner, an admin or a member: a guest may not
          // create an event here (#499).
          if (newEvent != null &&
              actions.contains(HouseholdAction.createEvent)) ...[
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
          // Last, after every other row: the one that ends the person's
          // place here (#479).
          if (hasMemberActionsBloc &&
              back != null &&
              actions.contains(HouseholdAction.leave)) ...[
            const BgeGap.lg(),
            _LeaveRow(state: state),
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
      create: (_) {
        final cubit = AwaitingApprovalCountCubit(
          householdId: householdId,
          remote: invites,
        );
        unawaited(cubit.load());
        return cubit;
      },
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

/// The member actions a row's menu offers: every one there is (#480, #478).
const Set<HouseholdMemberAction> _menuActions = {
  HouseholdMemberAction.changeRole,
  HouseholdMemberAction.remove,
  HouseholdMemberAction.makeOwner,
};

/// What [state]'s viewer may do to [member] from the member's menu, by the
/// role table (#483). Empty leaves the row without a menu.
Set<HouseholdMemberAction> _menuActionsOn(
  HouseholdDetailReady state,
  HouseholdMember member,
) {
  // A household the server does not know yet has no member ids it issued,
  // so its rows offer nothing, as Edit and invites are left out (#476).
  if (state.household.isLocalOnly) return const {};

  return householdMemberActionsFor(
    viewerRole: state.role,
    isSelf: member.userId == state.currentUserId,
    target: member,
  ).intersection(_menuActions);
}

/// The member count over the roster (#304), with each row's menu and the
/// banner saying how the last member action went (#480).
///
/// ## Where focus goes when a member's menu goes (#478)
///
/// A member action can take away the very menu it was chosen from. After a
/// transfer the viewer is an admin, with nothing to do to the new owner, and
/// after a removal the row goes. A hydrate can take a row away too. Left to
/// go with the menu, focus would fall back on whatever the page last had
/// focused, which may be anywhere on it. So when the member whose menu has
/// focus is no longer offered one, focus goes on to:
///
/// - the outcome banner's Dismiss, while an outcome shows;
/// - else, while that member's request is still on its way, the Dismiss of
///   the outcome it will show. The roster can drop the row before the bloc
///   says how the request went. Until then focus is held on the page itself,
///   so the framework's fallback can't put it on another control;
/// - else the member count, which heads the roster. It is no Tab stop: the
///   next Tab goes on from there.
///
/// Decided before the frame that takes the menu away, while it still has
/// focus, and done after that frame. Not if the user has moved focus
/// meanwhile, and only on a roster. Any other state, such as not-found,
/// leaves focus to whatever replaces the household, even while the last
/// roster is still drawn on the way out: a hand-off then would pull focus
/// off a menu still on screen.
///
/// Nor while the page is held after a leave (#479). The roster then drawn is
/// the one it last had, menus and all, whatever the bloc now holds: the
/// person's own row can go before the household does.
class _Roster extends StatefulWidget {
  const _Roster({required this.state, required this.hasMemberActionsBloc});

  final HouseholdDetailReady state;

  /// Whether a [HouseholdMemberActionsBloc] and a [LeaveHouseholdBloc] are
  /// provided above.
  final bool hasMemberActionsBloc;

  @override
  State<_Roster> createState() => _RosterState();
}

class _RosterState extends State<_Roster> {
  /// On the member count, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'household roster heading',
    skipTraversal: true,
  );

  /// The outcome banner's Dismiss.
  final FocusNode _dismiss = FocusNode(debugLabel: 'household member dismiss');

  /// The node of the [Focus] around each member's menu, by member id
  /// (`HouseholdMember.id`, which the bloc's busy set holds), for as long as
  /// the member is listed.
  ///
  /// The handle on a member's menu: the button inside has its own node. This
  /// one can't take focus itself, and has it while the button does.
  final Map<String, FocusNode> _menus = {};

  /// The member whose menu went, with focus on it, while a request for them
  /// was still on its way. Focus waits for that request's outcome.
  String? _pendingHandOff;

  FocusNode _menuNode(String memberId) => _menus.putIfAbsent(
    memberId,
    () => FocusNode(debugLabel: 'household member menu $memberId'),
  );

  static bool _offersMenu(HouseholdDetailReady state, String memberId) {
    final member = state.members.where((m) => m.id == memberId).firstOrNull;
    return member != null && _menuActionsOn(state, member).isNotEmpty;
  }

  /// When the member whose menu has focus is no longer offered one, hands
  /// focus on, as the class doc says.
  void _onRosterChanged(BuildContext context, HouseholdDetailState state) {
    if (state is! HouseholdDetailReady) return;
    final memberId = _menus.entries
        .where((entry) => entry.value.hasFocus)
        .firstOrNull
        ?.key;
    if (memberId == null || _offersMenu(state, memberId)) return;

    final focused = FocusManager.instance.primaryFocus;
    final detail = context.read<HouseholdDetailBloc>();
    final actions = context.read<HouseholdMemberActionsBloc>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(this.context, untouched: focused)) return;
      final now = detail.state;
      // No roster now (see the class doc), or the menu is back.
      if (now is! HouseholdDetailReady || _offersMenu(now, memberId)) return;
      final answered = actions.state;
      if (answered.outcome == null && answered.busy.contains(memberId)) {
        _pendingHandOff = memberId;
        // On the page itself, which counts as free, rather than wherever the
        // framework falls back to: the control the page had focused before
        // the menu.
        FocusScope.of(
          this.context,
          createDependency: false,
        ).requestScopeFocus();
        return;
      }
      _handFocusTo(answered.outcome != null ? _dismiss : _heading);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// When the request a hand-off waits on ends, hands focus to the outcome
  /// it shows.
  void _onPendingAnswered(
    BuildContext context,
    HouseholdMemberActionsState state,
  ) {
    _pendingHandOff = null;
    final detail = context.read<HouseholdDetailBloc>();
    final actions = context.read<HouseholdMemberActionsBloc>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !focusIsFree(this.context) ||
          detail.state is! HouseholdDetailReady) {
        return;
      }
      _handFocusTo(actions.state.outcome != null ? _dismiss : _heading);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Disposes the nodes of members no longer listed, after the frame that
  /// takes them down: a [Focus] holds its node until then.
  void _forgetMembersGone(HouseholdDetailState state) {
    // Only a roster says who has gone. Any other state replaces this page,
    // which disposes every node with it.
    if (state is! HouseholdDetailReady) return;
    final listed = {for (final member in state.members) member.id};
    final gone = [
      for (final id in _menus.keys)
        if (!listed.contains(id)) id,
    ];
    if (gone.isEmpty) return;
    final nodes = [for (final id in gone) ?_menus.remove(id)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in nodes) {
        node.dispose();
      }
    });
  }

  @override
  void dispose() {
    _heading.dispose();
    _dismiss.dispose();
    for (final node in _menus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Without a member client no row has a menu, so there is nothing to hand
    // focus on from.
    if (!widget.hasMemberActionsBloc) return _build(context, null);
    final leave = context.read<LeaveHouseholdBloc>();

    return MultiBlocListener(
      listeners: [
        BlocListener<HouseholdDetailBloc, HouseholdDetailState>(
          // A held page draws the roster as it last was, so a state it does
          // not draw says nothing about which menus are on screen, and a
          // member gone from it still has their node in use.
          listenWhen: (_, _) => !_isHeld(leave),
          listener: (context, state) {
            // In this order: the hand-off looks for the focused menu among
            // the nodes, and a member gone takes their node with them.
            _onRosterChanged(context, state);
            _forgetMembersGone(state);
          },
        ),
        BlocListener<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
          listenWhen: (_, current) {
            final pending = _pendingHandOff;
            return pending != null && !current.busy.contains(pending);
          },
          listener: _onPendingAnswered,
        ),
      ],
      child:
          BlocBuilder<HouseholdMemberActionsBloc, HouseholdMemberActionsState>(
            builder: _build,
          ),
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
    final state = widget.state;
    final outcome = actionsState?.outcome;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Focus(
          focusNode: _heading,
          child: Semantics(
            header: true,
            child: Text(
              key: HouseholdDetailScreen.memberCountKey,
              l10n.householdDetailMembers(state.memberCount),
              style: theme.textTheme.titleMedium,
            ),
          ),
        ),
        const BgeGap.xs(),
        if (outcome != null) ...[
          _MemberOutcomeBanner(outcome: outcome, dismissFocus: _dismiss),
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
    if (actionsState == null) return null;
    final state = widget.state;
    final offered = _menuActionsOn(state, member);
    if (offered.isEmpty) return null;

    return Focus(
      focusNode: _menuNode(member.id),
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: _MemberMenu(
        member: member,
        actions: offered,
        roles: assignableMemberRoles(state.role),
        busy: actionsState.busy.contains(member.id),
      ),
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

/// A member's menu: change their role, remove them, or make them owner, as
/// [actions] has it (#480, #478).
///
/// While a request for the member is on its way the button stays **enabled
/// and inert** rather than disabled: `ButtonStyleButton` passes
/// `canRequestFocus: enabled`, so a disabled button drops focus and a
/// keyboard or screen-reader user loses their place when they confirm an
/// action (#607). Staying enabled takes away the greyed look that was its
/// only busy cue, so it shows a spinner instead of the icon and its
/// accessible name says what is happening.
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
  /// answers, and the button stays enabled so it keeps focus (#607).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final name = member.name;
    final actionsLabel = name == null
        ? l10n.householdMemberActions
        : l10n.householdMemberActionsFor(name);
    final busyLabel = name == null
        ? l10n.householdMemberBusy
        : l10n.householdMemberBusyFor(name);
    // Every item is a direct write, so each waits for a connection (#49). The
    // button stays enabled, so the menu can be opened to read why.
    final online = !BgeConnectivityScope.offlineOf(context);

    return BgeOnlineOnlyMenu(
      builder: (context, menu) => MenuAnchor(
        controller: menu,
        // Left unconstrained, the panel sits in a hard-clipped box as wide as
        // its widest entry, which at 2.0 text runs past a phone's edge. Held
        // to the screen, the entries wrap instead.
        crossAxisUnconstrained: false,
        menuChildren: [
          if (actions.contains(HouseholdMemberAction.changeRole))
            MenuItemButton(
              key: HouseholdDetailScreen.changeRoleKey,
              overflowAxis: Axis.vertical,
              onPressed: online ? () => unawaited(_changeRole(context)) : null,
              child: BgeOnlineOnlyLabel(l10n.householdMemberChangeRole),
            ),
          if (actions.contains(HouseholdMemberAction.remove))
            MenuItemButton(
              key: HouseholdDetailScreen.removeKey,
              overflowAxis: Axis.vertical,
              onPressed: online ? () => unawaited(_remove(context)) : null,
              child: BgeOnlineOnlyLabel(l10n.householdMemberRemove),
            ),
          if (actions.contains(HouseholdMemberAction.makeOwner))
            MenuItemButton(
              key: HouseholdDetailScreen.makeOwnerKey,
              overflowAxis: Axis.vertical,
              onPressed: online ? () => unawaited(_makeOwner(context)) : null,
              child: BgeOnlineOnlyLabel(l10n.householdMemberMakeOwner),
            ),
        ],
        builder: (context, controller, _) => BgeInertButton(
          // Inert while busy, so it keeps focus through a write (#607). The
          // name is a label because VoiceOver skips a node named only by its
          // tooltip.
          inert: busy,
          label: busy ? busyLabel : actionsLabel,
          expanded: controller.isOpen,
          onPressed: controller.isOpen ? controller.close : controller.open,
          builder: (context, focusNode, onPressed) => IconButton(
            key: HouseholdDetailScreen.memberActionsKey(member.userId),
            focusNode: focusNode,
            icon: busy ? const _BusyIconSpinner() : const Icon(Icons.more_vert),
            // Every row has one, so the name says whose it is to a pointer
            // user hovering one after another.
            tooltip: busy ? busyLabel : actionsLabel,
            onPressed: onPressed,
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
    final l10n = HouseholdLocalizations.of(context);
    final name = member.name;
    final confirmed = await _confirm(
      context,
      title: name == null
          ? l10n.householdMemberRemoveConfirmTitleUnnamed
          : l10n.householdMemberRemoveConfirmTitle(name),
      body: l10n.householdMemberRemoveConfirmBody,
      confirmLabel: l10n.householdMemberRemoveConfirm,
      confirmKey: HouseholdDetailScreen.removeConfirmKey,
      destructive: true,
    );
    if (!confirmed || bloc.isClosed) return;
    bloc.add(HouseholdMemberRemovalRequested(member));
  }

  Future<void> _makeOwner(BuildContext context) async {
    final bloc = context.read<HouseholdMemberActionsBloc>();
    final l10n = HouseholdLocalizations.of(context);
    final name = member.name;
    final confirmed = await _confirm(
      context,
      title: name == null
          ? l10n.householdMemberMakeOwnerConfirmTitleUnnamed
          : l10n.householdMemberMakeOwnerConfirmTitle(name),
      body: l10n.householdMemberMakeOwnerConfirmBody,
      confirmLabel: l10n.householdMemberMakeOwnerConfirm,
      confirmKey: HouseholdDetailScreen.makeOwnerConfirmKey,
      // The viewer stays on, as an admin, and nobody loses access.
      destructive: false,
    );
    if (!confirmed || bloc.isClosed) return;
    bloc.add(HouseholdMemberOwnershipTransferRequested(member));
  }
}

/// Moves focus to [target] after a control holding it has gone or turned
/// disabled: the roster's hand-off (#478) and the Leave row's (#479). Scrolled
/// into view only for a keyboard user, whose focus ring would otherwise be
/// off screen; a touch user's view is left where they put it.
void _handFocusTo(FocusNode target) {
  target.requestFocus();
  if (FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
    target.context?.findRenderObject()?.showOnScreen();
  }
}

/// Asks before an action, and answers whether the user confirmed it: a
/// member's removal or transfer (#480, #478), or leaving (#479).
/// [destructive] colours the confirm button as an error.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  required Key confirmKey,
  required bool destructive,
}) async {
  final l10n = HouseholdLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      // At 2.0 text the title and body can outgrow a phone's height.
      scrollable: true,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.householdMemberCancel),
        ),
        TextButton(
          key: confirmKey,
          style: destructive
              ? TextButton.styleFrom(
                  foregroundColor: Theme.of(dialogContext).colorScheme.error,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// A busy control's icon: a spinner the size of the icon it replaces, silent
/// to a screen reader because the control's label says what is running
/// (#607). The member menu's (#480) and the Leave row's (#479).
class _BusyIconSpinner extends StatelessWidget {
  const _BusyIconSpinner();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: IconTheme.of(context).size,
      child: const CircularProgressIndicator(strokeWidth: 2),
    ),
  );
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

/// How the last role change, removal or transfer went (#480, #478), under
/// the member count until dismissed or replaced. A live region, as every
/// [BgeInlineBanner] is.
class _MemberOutcomeBanner extends StatelessWidget {
  const _MemberOutcomeBanner({
    required this.outcome,
    required this.dismissFocus,
  });

  final HouseholdMemberOutcome outcome;

  /// For the Dismiss button, which takes focus when the menu the action was
  /// chosen from goes (#478).
  final FocusNode dismissFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BgeInlineBanner(
      key: HouseholdDetailScreen.memberOutcomeKey,
      tone: _tone(outcome),
      message: memberActionMessage(l10n, outcome),
      action: TextButton(
        key: HouseholdDetailScreen.memberOutcomeDismissKey,
        focusNode: dismissFocus,
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

/// The Leave row (#479), with the banner saying why the last request to
/// leave did not go through directly above it. The pop once one did is
/// [_LeaveOutcome]'s. The screen's class doc says who is offered it and when
/// it is disabled.
///
/// Its states, first match wins:
///
/// - **Busy**, from the moment a request goes until the screen has gone:
///   enabled and inert, so it keeps focus (#607), with a spinner, and named
///   as leaving. Whatever the roster or the connection does meanwhile, since
///   being disabled would drop focus, and the answer is what settles the
///   row. The left phase counts, so the row does not go back to Leave on the
///   way out.
/// - **The last owner**, with others in the household or alone: disabled,
///   with the reason as its second line. Coming back online would not lift
///   it, so it comes before offline, and the row has no online-only note.
/// - **Offline**: disabled, with the online-only reason (#49).
/// - Otherwise a press asks, then sends.
///
/// Every state is the one [ListTile], with a focus node the row owns, under
/// one semantics node the row builds. So a request going and answering, the
/// roster changing and the connection coming and going keep the row's
/// element, its focus node and its semantics node, as STYLE_GUIDE's
/// online-only controls require. Only the reason line, the online-only note
/// and the spinner come and go.
///
/// The node is built here rather than by [BgeInertButton], whose node says
/// it can take focus in every state: over a disabled tile it would offer a
/// focus action the tile can't take. Otherwise it is built as that one is:
/// not enabled and with no tap action while inert, still focusable while
/// busy, and with the tile's own semantics left out, so its label carries
/// the second line itself.
///
/// ## Where focus goes when the row turns disabled
///
/// A disabled tile can't hold focus, so the row turning disabled drops focus
/// that was on it. A failure can do that, since busy outranks the rest only
/// until the answer. If the connection drops while the request is on its
/// way, the row is idle and offline once the failure lands. If the co-owner
/// who let the person leave goes, while the request is on its way or with
/// the refresh a refusal starts, the person is the last owner once it has
/// answered. Left to the framework, focus would fall back on whatever the
/// page last had focused, which may be anywhere on it. So while a failure
/// shows, focus moves to its banner's Dismiss.
///
/// Decided before the frame that disables the row, while it still has focus,
/// and done after that frame, as the roster's hand-off is. Not if the user
/// has moved focus meanwhile. With no failure to show, focus is left to the
/// framework, as it is for any online-only control disabled under it (#49).
/// The member count, where the roster sends focus, is the roster's own node.
class _LeaveRow extends StatefulWidget {
  const _LeaveRow({required this.state});

  /// The household as the page draws it. It is the held one once a leave is
  /// accepted.
  final HouseholdDetailReady state;

  @override
  State<_LeaveRow> createState() => _LeaveRowState();
}

class _LeaveRowState extends State<_LeaveRow> {
  /// On the row's tile in every state, so focus stays put from one to the
  /// next until the tile is disabled.
  final FocusNode _row = FocusNode(
    debugLabel: 'household leave row',
    onKeyEvent: _ignoreActivationRepeat,
  );

  static final Set<LogicalKeyboardKey> _activationKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
  };

  /// A held Enter or Space presses the row once, as [BgeInertButton] has it:
  /// the repeats still arriving as the confirmation opens would open it
  /// again.
  static KeyEventResult _ignoreActivationRepeat(FocusNode _, KeyEvent event) =>
      event is KeyRepeatEvent && _activationKeys.contains(event.logicalKey)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;

  /// The failure banner's Dismiss.
  final FocusNode _dismiss = FocusNode(debugLabel: 'household leave dismiss');

  /// Whether the row was disabled when last built. Null before the first
  /// build.
  bool? _wasDisabled;

  @override
  void dispose() {
    _row.dispose();
    _dismiss.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<LeaveHouseholdBloc, LeaveHouseholdState>(
      builder: (context, leave) {
        final failure = leave.failure;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (failure != null) ...[
              _LeaveFailureBanner(failure: failure, dismissFocus: _dismiss),
              const BgeGap.xs(),
            ],
            _tile(context, leave),
          ],
        );
      },
    );
  }

  /// When the row turns disabled with focus on it, hands focus on, as the
  /// class doc says. Called as the row is built, while it still has focus.
  void _onShape({required bool disabled}) {
    final wasDisabled = _wasDisabled;
    _wasDisabled = disabled;
    if (!disabled || wasDisabled != false || !_row.hasFocus) return;

    final focused = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(context, untouched: focused)) return;
      if (context.read<LeaveHouseholdBloc>().state.failure == null) return;
      _handFocusTo(_dismiss);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _tile(BuildContext context, LeaveHouseholdState leave) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final state = widget.state;
    // Plain colours: a disabled tile resolves them to its own disabled one.
    final error = theme.colorScheme.error;
    // In the class doc's order: busy, then the last owner, then offline.
    final busy = leave.phase != LeavePhase.idle;
    final reason = busy
        ? null
        : switch (householdLeaveBlock(
            viewerRole: state.role,
            currentUserId: state.currentUserId,
            members: state.members,
          )) {
            HouseholdLeaveBlock.lastOwner => l10n.householdLeaveLastOwner,
            HouseholdLeaveBlock.onlyMember => l10n.householdLeaveOnlyMember,
            null => null,
          };
    final offline =
        !busy && reason == null && BgeConnectivityScope.offlineOf(context);
    final disabled = reason != null || offline;
    final inert = busy || disabled;
    _onShape(disabled: disabled);

    final label = busy ? l10n.householdLeaving : l10n.householdLeave;
    void press() {
      if (!inert) unawaited(_confirmLeave(context));
    }

    return ListenableBuilder(
      listenable: _row,
      builder: (context, tile) => Semantics(
        container: true,
        button: true,
        enabled: !inert,
        // Only while the tile can take focus.
        focused: disabled ? null : _row.hasPrimaryFocus,
        // The tile's own semantics are left out, so the label carries its
        // second line, as a merged tile would read it.
        label: [
          label,
          ?reason,
          if (offline) ?BgeConnectivityScope.onlineOnlyReasonOf(context),
        ].join('\n'),
        onTap: inert ? null : press,
        // As `Focus` has it: withheld on iOS (flutter/flutter#150030).
        onFocus: disabled || defaultTargetPlatform == TargetPlatform.iOS
            ? null
            : _row.requestFocus,
        excludeSemantics: true,
        child: tile,
      ),
      child: ListTile(
        key: HouseholdDetailScreen.leaveKey,
        focusNode: _row,
        contentPadding: EdgeInsets.zero,
        enabled: !disabled,
        iconColor: error,
        textColor: error,
        leading: const Icon(Icons.logout),
        // A last owner's row has no online-only note, and nor does a busy
        // one: neither changes when the connection does.
        title: busy || reason != null ? Text(label) : BgeOnlineOnlyLabel(label),
        // In the online-only reason's style, `bodySmall` in
        // `onSurfaceVariant`, so the two reason lines match and this one
        // stays legible on the disabled row.
        subtitle: reason == null
            ? null
            : Text(
                reason,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
        trailing: busy ? const _BusyIconSpinner() : null,
        onTap: press,
      ),
    );
  }

  Future<void> _confirmLeave(BuildContext context) async {
    // Read before the dialog opens: the page can change under it.
    final bloc = context.read<LeaveHouseholdBloc>();
    final l10n = HouseholdLocalizations.of(context);
    final household = widget.state.household;
    final confirmed = await _confirm(
      context,
      title: l10n.householdLeaveConfirmTitle(household.name),
      body: l10n.householdLeaveConfirmBody,
      confirmLabel: l10n.householdLeaveConfirm,
      confirmKey: HouseholdDetailScreen.leaveConfirmKey,
      destructive: true,
    );
    if (!confirmed || bloc.isClosed) return;
    bloc.add(LeaveHouseholdRequested(household.id));
  }
}

/// Why the last request to leave did not go through (#479), directly above
/// the Leave row until dismissed or replaced. A live region, as every
/// [BgeInlineBanner] is.
class _LeaveFailureBanner extends StatelessWidget {
  const _LeaveFailureBanner({
    required this.failure,
    required this.dismissFocus,
  });

  /// Gone, refused or failed.
  final MemberRequestOutcome failure;

  /// For the Dismiss button, which takes focus when the failure leaves the
  /// row disabled.
  final FocusNode dismissFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BgeInlineBanner(
      key: HouseholdDetailScreen.leaveFailureKey,
      // A warning when the server answered no, and an error when nobody can
      // say.
      tone: failure.result == HouseholdMemberActionResult.failed
          ? BgeBannerTone.error
          : BgeBannerTone.warning,
      message: leaveFailureMessage(l10n, failure),
      action: TextButton(
        focusNode: dismissFocus,
        onPressed: () => context.read<LeaveHouseholdBloc>().add(
          const LeaveHouseholdFailureDismissed(),
        ),
        child: Text(l10n.householdMemberDismiss),
      ),
    );
  }
}

/// No readable household at this id — see [HouseholdDetailScreen].
class _NotFoundPage extends StatelessWidget {
  const _NotFoundPage({
    this.onBack,
    this.refreshFailed = false,
    this.refreshing = false,
    this.canRetry = false,
  });

  final void Function(BuildContext context)? onBack;

  /// Whether a retry can be offered. This is the surface where it is worth
  /// the most (#300 D10): a household absent from a cache whose last pass
  /// failed may well be on the server, so asking again can change what is
  /// on screen rather than only how fresh it is.
  ///
  /// Once the pass reports `running`, the bloc stops asserting an absence
  /// no pass has confirmed, and this page gives way to the spinner, which
  /// is the feedback. An absence an earlier pass confirmed stays on this
  /// page through the pass, so the banner narrates it — see [refreshing].
  final bool canRetry;

  /// The last pass to finish failed, so the absence is unverified or may be
  /// out of date. The screen says both things: we could not find it, and we
  /// could not check.
  final bool refreshFailed;

  /// A pass the user asked for is running. The banner shows while this or
  /// [refreshFailed] holds, as it does over the household: in-progress
  /// copy, and a retry that is disabled but keeps its place and its name,
  /// so a press is answered and a second one is not invited.
  final bool refreshing;

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
          if (refreshFailed || refreshing) ...[
            _refreshBanner(context, canRetry: canRetry, refreshing: refreshing),
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
  return BgeRefreshBanner(
    key: HouseholdDetailScreen.refreshBannerKey,
    retryKey: HouseholdDetailScreen.refreshRetryKey,
    failedMessage: l10n.householdDetailRefreshFailed,
    inProgressLabel: l10n.householdRefreshInProgress,
    retryLabel: l10n.householdRefreshRetry,
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
