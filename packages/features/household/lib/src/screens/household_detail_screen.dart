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
import '../invites/household_invite_permissions.dart';
import '../widgets/household_refresh_banner.dart';
import '../widgets/household_role_label.dart';
import '../sync/household_hydration_status.dart';

/// One household, read-only (#270): its name, its description, how many
/// people are in it, and what the current user is in it.
///
/// Decoupled from DI like the list and create screens: the caller resolves
/// the user-session [HouseholdRepository] and the optional
/// [HouseholdHydrationStatus] stream and passes them in; the screen owns
/// its bloc.
///
/// ## What this screen does not show
///
/// **No roster.** Not a scope call — `HouseholdMember` has no name on it.
/// The domain model carries `userId` and nothing else identifying, the
/// `household_members` table has no column for a name, and the wire
/// adapter drops the username and display name the server embeds. A
/// "roster" built on what is actually cached would be a column of cuid2s,
/// which is worse than the count. See the deviation recorded on #270.
///
/// **No avatars** (#124, the media pipeline) and **no membership actions**
/// — no rename, no delete, no leave, no kick. Those need sync-queue op
/// types of their own for the drain (#121) to send, and they stay with
/// #246.
///
/// ## Invites are the exception
///
/// To its owners and admins, the screen offers an entry to the household's
/// invites (#455), with how many await approval (#489). Invites are
/// online-only, read from the server and never queued, so they need no sync
/// op. The entry is left out for a household the server does not know yet
/// (`isLocalOnly`), whose id it would not recognise, and where the
/// composition passes no [invites] client.
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

  /// Key on the member count.
  static const Key memberCountKey = Key('household_detail.member_count');

  /// Key on the current user's role.
  static const Key roleKey = Key('household_detail.role');

  /// Key on the entry to the household's invites.
  static const Key invitesKey = Key('household_detail.invites');

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

    return BlocProvider<HouseholdDetailBloc>(
      // go_router keeps this page when only the id changes; the key makes a
      // new id a new bloc rather than the old household under it (#466).
      key: ValueKey<String>(householdId),
      create: (_) => HouseholdDetailBloc(
        householdId: householdId,
        repository: repository,
        hydration: hydration,
        onRetry: onRetry,
      ),
      // The callback stays with the bloc; the view only needs to know
      // whether there is one, to decide whether to draw a button.
      child: _HouseholdDetailView(
        onBack: onBack,
        canRetry: onRetry != null,
        invites: invites,
        onOpenInvites: onOpenInvites,
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
  });

  final void Function(BuildContext context)? onBack;

  /// Whether this composition can re-run the drain at all (#300 D5).
  final bool canRetry;

  final HouseholdInviteRemoteDataSource? invites;
  final void Function(BuildContext context, String householdId)? onOpenInvites;

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
  });

  final HouseholdDetailReady state;

  /// Whether a retry can be offered — see [HouseholdDetailScreen.onRetry].
  final bool canRetry;

  final HouseholdInviteRemoteDataSource? invites;
  final void Function(BuildContext context, String householdId)? onOpenInvites;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final description = state.household.description;
    final hasDescription = description != null && description.isNotEmpty;
    final invites = this.invites;
    final openInvites = onOpenInvites;

    return BgePage(
      // The household's own name, not a generic one: the title is the first
      // thing that says where you landed, and the invite deep link (#243)
      // will land here without the user having walked past the list.
      title: Text(state.household.name),
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
          Text(
            key: HouseholdDetailScreen.memberCountKey,
            l10n.householdDetailMembers(state.memberCount),
            style: theme.textTheme.titleMedium,
          ),
          // Omitted entirely when there is no role to state (#270 D4):
          // a null binding, or an identity we could not resolve. An empty
          // "Your role" label would be a question the screen asks itself.
          if (state.role != null) ...[
            const BgeGap.lg(),
            _RoleBlock(role: state.role!),
          ],
          if (invites != null &&
              openInvites != null &&
              HouseholdInvitePermissions.mayManage(state.role) &&
              !state.household.isLocalOnly) ...[
            const BgeGap.lg(),
            _InvitesEntry(
              // Keyed on the id, which a reconcile changes (#306): the count
              // belongs to the household the server knows by that id.
              key: ValueKey<String>(state.household.id),
              householdId: state.household.id,
              invites: invites,
              onOpen: openInvites,
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
    super.key,
  });

  final String householdId;
  final HouseholdInviteRemoteDataSource invites;
  final void Function(BuildContext context, String householdId) onOpen;

  @override
  Widget build(BuildContext context) =>
      BlocProvider<AwaitingApprovalCountCubit>(
        create: (_) => AwaitingApprovalCountCubit(
          householdId: householdId,
          remote: invites,
        )..load(),
        child: BlocBuilder<AwaitingApprovalCountCubit, int?>(
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
        ),
      );
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
