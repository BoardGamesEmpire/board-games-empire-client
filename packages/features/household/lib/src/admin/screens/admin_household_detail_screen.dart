import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../../widgets/household_role_label.dart';
import '../bloc/admin_household_detail_cubit.dart';
import '../bloc/admin_household_detail_state.dart';

/// Any household on the server, read-only, for server staff (#685).
///
/// Opened from a live row of the staff households list. It offers no action:
/// staff read the household here, and restoring a deleted one is the list's.
/// Nothing is cached (#683): [AdminHouseholdDetailCubit] reads the server
/// when the screen opens, and again on Retry.
///
/// Decoupled from DI like the other household screens: the caller resolves
/// the per-server [AdminHouseholdRemoteDataSource] and the session's
/// [CallerAccessRepository].
///
/// ## Content
///
/// The title is the household's name once it is read, and "Household" before
/// then and in every failure. The facts are text, one line each: the
/// description, who can see the household, its language and when it was
/// created. A fact the server has none of, or a reach this client does not
/// know, leaves no line. Then the roster, a name and a role per member, each
/// row one node.
///
/// ## Failures
///
/// A household that is gone, one the server refuses, and one that could not
/// be read each say so in place of the content. Only the last offers Retry.
/// When Retry goes, keyboard focus goes to the page's heading, which is no
/// Tab stop but is always there.
class AdminHouseholdDetailScreen extends StatelessWidget {
  const AdminHouseholdDetailScreen({
    required this.remote,
    required this.id,
    this.access,
    super.key,
  });

  static const Key loadingKey = Key('admin_household_detail.loading');
  static const Key goneKey = Key('admin_household_detail.gone');
  static const Key refusedKey = Key('admin_household_detail.refused');
  static const Key errorKey = Key('admin_household_detail.error');
  static const Key memberCountKey = Key('admin_household_detail.member_count');

  /// Per-member key: `admin_household_detail.member_<id>`, on the row.
  static Key memberKey(String id) => Key('admin_household_detail.member_$id');

  final AdminHouseholdRemoteDataSource remote;
  final String id;

  /// The session's access, asked again when the server refuses. Null for a
  /// composition without one.
  final CallerAccessRepository? access;

  @override
  Widget build(BuildContext context) => BlocProvider<AdminHouseholdDetailCubit>(
    create: (_) =>
        AdminHouseholdDetailCubit(remote: remote, access: access, id: id)
          ..load(),
    child: const _AdminHouseholdDetailView(),
  );
}

class _AdminHouseholdDetailView extends StatefulWidget {
  const _AdminHouseholdDetailView();

  @override
  State<_AdminHouseholdDetailView> createState() =>
      _AdminHouseholdDetailViewState();
}

class _AdminHouseholdDetailViewState extends State<_AdminHouseholdDetailView> {
  /// On the page's heading, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'admin household heading',
    skipTraversal: true,
  );

  @override
  void dispose() {
    _heading.dispose();
    super.dispose();
  }

  void _retry(AdminHouseholdDetailCubit cubit) {
    // Retry goes as the read starts, and would take focus with it.
    _heading.requestFocus();
    cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final inset = tokens.spaceLg;

    return BlocBuilder<AdminHouseholdDetailCubit, AdminHouseholdDetailState>(
      builder: (context, state) {
        final household = state is AdminHouseholdDetailReady
            ? state.household
            : null;

        return BgePage.slivers(
          title: Focus(
            focusNode: _heading,
            child: Text(household?.name ?? l10n.adminHouseholdDetailTitle),
          ),
          // "Member 2 of 5": the roster's rows.
          semanticChildCount: household?.members.length,
          padding: EdgeInsets.fromLTRB(inset, inset, inset, 0),
          slivers: [
            ...switch (state) {
              AdminHouseholdDetailLoading() => [
                BgeStateSliver(
                  child: BgeLoadingState(
                    key: AdminHouseholdDetailScreen.loadingKey,
                    label: l10n.adminHouseholdDetailLoading,
                  ),
                ),
              ],
              AdminHouseholdDetailGone() => [
                BgeStateSliver(
                  child: BgeEmptyState(
                    key: AdminHouseholdDetailScreen.goneKey,
                    icon: Icons.search_off_outlined,
                    title: l10n.adminHouseholdDetailGone,
                  ),
                ),
              ],
              AdminHouseholdDetailRefused() => [
                BgeStateSliver(
                  child: BgeEmptyState(
                    key: AdminHouseholdDetailScreen.refusedKey,
                    icon: Icons.lock_outline,
                    title: l10n.adminHouseholdDetailRefused,
                  ),
                ),
              ],
              AdminHouseholdDetailFailed() => [
                BgeStateSliver(
                  child: BgeErrorState(
                    key: AdminHouseholdDetailScreen.errorKey,
                    icon: Icons.cloud_off_outlined,
                    title: l10n.adminHouseholdDetailFailed,
                    body: l10n.adminHouseholdDetailFailedBody,
                    retryLabel: l10n.adminHouseholdsRetry,
                    onRetry: () =>
                        _retry(context.read<AdminHouseholdDetailCubit>()),
                  ),
                ),
              ],
              AdminHouseholdDetailReady(:final household) => [
                SliverToBoxAdapter(child: _Facts(household: household)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: tokens.spaceLg,
                      bottom: tokens.spaceXs,
                    ),
                    child: Semantics(
                      header: true,
                      child: Text(
                        key: AdminHouseholdDetailScreen.memberCountKey,
                        l10n.householdDetailMembers(household.members.length),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
                BgeKeyedSliverList<HouseholdMember>(
                  items: household.members,
                  keyOf: (member) =>
                      AdminHouseholdDetailScreen.memberKey(member.id),
                  itemBuilder: (context, member) => _MemberRow(member: member),
                ),
              ],
            },
            const SliverToBoxAdapter(child: BgeGap.lg()),
          ],
        );
      },
    );
  }
}

/// The household's facts, one line each, none of them a control.
class _Facts extends StatelessWidget {
  const _Facts({required this.household});

  final AdminHouseholdDetail household;

  static String? _reachLabel(HouseholdLocalizations l10n, Reach reach) =>
      switch (reach) {
        Reach.private => l10n.adminHouseholdDetailReachPrivate,
        Reach.friends => l10n.adminHouseholdDetailReachFriends,
        Reach.friendsOfFriends =>
          l10n.adminHouseholdDetailReachFriendsOfFriends,
        Reach.public => l10n.adminHouseholdDetailReachPublic,
        Reach.unknown => null,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final description = household.description;
    final reach = _reachLabel(l10n, household.reach);
    final language = household.languageName;
    final lines = [
      if (description != null && description.isNotEmpty) description,
      ?reach == null ? null : l10n.adminHouseholdDetailVisibleTo(reach),
      ?language == null ? null : l10n.adminHouseholdDetailLanguage(language),
      // On the device's clock, with the year.
      l10n.adminHouseholdDetailCreatedOn(household.createdAt.toLocal()),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      // Facts in their own right: the smaller step ties a label to its own
      // helper text (STYLE_GUIDE §3).
      spacing: BgeTokens.of(context).spaceSm,
      children: [
        for (final line in lines) Text(line, style: theme.textTheme.bodyLarge),
      ],
    );
  }
}

/// One member: a name and a role, as one node.
class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});

  final HouseholdMember member;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final name = member.name;
    final role = member.role;
    final roleLabel = role == null ? null : householdRoleLabel(l10n, role);
    // With neither name, the role alone says who this is.
    final title = name ?? roleLabel ?? l10n.householdDetailMemberUnnamed;

    return MergeSemantics(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.bodyLarge),
            if (roleLabel != null && name != null)
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
  }
}
