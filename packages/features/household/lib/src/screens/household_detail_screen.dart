import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_detail_bloc.dart';
import '../bloc/household_detail_state.dart';
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
/// types and a drain worker (#121) to behave, and they stay with #246.
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
    super.key,
  });

  /// Key on the first-read spinner.
  static const Key loadingKey = Key('household_detail.loading');

  /// Key on the not-found surface.
  static const Key notFoundKey = Key('household_detail.not_found');

  /// Key on the not-found surface's return-to-list button.
  static const Key notFoundBackKey = Key('household_detail.not_found_back');

  /// Key on the failed-read surface.
  static const Key errorKey = Key('household_detail.error');

  /// Key on the couldn't-refresh banner.
  static const Key refreshBannerKey = Key('household_detail.refresh_banner');

  /// Key on the member count.
  static const Key memberCountKey = Key('household_detail.member_count');

  /// Key on the current user's role.
  static const Key roleKey = Key('household_detail.role');

  /// The household to show. A literal `create` never reaches the
  /// repository — see the class doc.
  final String householdId;

  /// The user-session household repository. Read-only here.
  final HouseholdRepository repository;

  /// What the hydrate is doing, when this composition runs one. Null reads
  /// as settled rather than as forever-loading (#269 D1).
  final Stream<HouseholdHydrationState>? hydration;

  /// Returns to the household list from the not-found state, where the
  /// back button is not enough on its own: this route can be entered
  /// directly by deep link or a restored route, with nothing beneath it.
  ///
  /// Called with this screen's own context, mirroring the list's
  /// `onCreate` — the feature package does not know the route table.
  final void Function(BuildContext context)? onBack;

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
      create: (_) => HouseholdDetailBloc(
        householdId: householdId,
        repository: repository,
        hydration: hydration,
      ),
      child: _HouseholdDetailView(onBack: onBack),
    );
  }
}

class _HouseholdDetailView extends StatelessWidget {
  const _HouseholdDetailView({this.onBack});

  final void Function(BuildContext context)? onBack;

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
          ),
          HouseholdDetailReady() => _ReadyPage(state: state),
        };
      },
    );
  }
}

/// The household itself.
class _ReadyPage extends StatelessWidget {
  const _ReadyPage({required this.state});

  final HouseholdDetailReady state;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final description = state.household.description;
    final hasDescription = description != null && description.isNotEmpty;

    return BgePage(
      // The household's own name, not a generic one: this route can be
      // arrived at cold from a deep link, and the title is the first thing
      // that says where you landed.
      title: Text(state.household.name),
      width: BgePageWidth.pane,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.refreshFailed) ...[
            BgeInlineBanner(
              key: HouseholdDetailScreen.refreshBannerKey,
              // Warning, not error, for the list banner's reason: what is
              // below is real, it may just be old. And the copy does not
              // name a cause — the screen cannot know which failure the
              // drain hit.
              tone: BgeBannerTone.warning,
              message: l10n.householdDetailRefreshFailed,
              reveal: false,
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
        ],
      ),
    );
  }
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
          Text(_label(l10n, role), style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }

  /// [HouseholdRole.unknown] gets its own words rather than a shrug.
  /// After the #266 D2 wire adapter it can only mean a role name this
  /// deployment defined and this client does not know — the adapter throws
  /// on a malformed role rather than degrading into it — so saying so is
  /// reporting real data, not admitting a parse failure.
  static String _label(HouseholdLocalizations l10n, HouseholdRole role) =>
      switch (role) {
        HouseholdRole.householdOwner => l10n.householdDetailRoleOwner,
        HouseholdRole.householdAdmin => l10n.householdDetailRoleAdmin,
        HouseholdRole.householdMember => l10n.householdDetailRoleMember,
        HouseholdRole.householdGuest => l10n.householdDetailRoleGuest,
        HouseholdRole.unknown => l10n.householdDetailRoleUnknown,
      };
}

/// No readable household at this id — see [HouseholdDetailScreen].
class _NotFoundPage extends StatelessWidget {
  const _NotFoundPage({this.onBack, this.refreshFailed = false});

  final void Function(BuildContext context)? onBack;

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
            BgeInlineBanner(
              key: HouseholdDetailScreen.refreshBannerKey,
              tone: BgeBannerTone.warning,
              message: l10n.householdDetailRefreshFailed,
              reveal: false,
            ),
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
          // The route can be entered cold — a deep link, a restored route
          // — with nothing under it to go back to, so this offers the way
          // out that the app bar's back button may not have.
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
