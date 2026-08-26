import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_list_bloc.dart';
import '../bloc/household_list_state.dart';
import '../sync/household_hydration_status.dart';

/// The household list (#269): every household the signed-in user belongs
/// to, read reactively from the local cache.
///
/// Decoupled from DI like [CreateHouseholdScreen]: the caller resolves the
/// user-session [HouseholdRepository] and the optional
/// [HouseholdHydrationStatus] stream and passes them in; the screen owns
/// its bloc.
///
/// ## The four surfaces
///
/// Loading, empty, rows and error, from a sealed bloc state (#269 D6). The
/// distinction that costs something is loading-versus-empty: the hydrate
/// runs unawaited from sign-in (#267 D2), so this route can be reached with
/// the cache empty and filling, and `watchHouseholds()` emits the same
/// empty list either way. [hydration] is what tells them apart; absent, it
/// reads as settled (#269 D1).
///
/// A failed refresh is a **banner over whatever we have**, not a state of
/// its own (#269 D2) — including over the empty state, where it qualifies
/// an emptiness we could not verify. There is no retry here yet; the drain
/// retries at the next session activate, and a manual one is #300.
///
/// ## Rows do not navigate (#269 D5)
///
/// There is no household detail route yet, so a row is content, not a
/// control — a tap target that leads nowhere is worse than none. #301 adds
/// the detail screen and turns these into controls.
///
/// Each row is one merged semantics node, so a screen reader reads
/// "Sunday Crew, Not yet synced" rather than three fragments, and the
/// count comes from [BgePage.slivers]'s `semanticChildCount` ("item 3 of
/// 9"). Keyboard operability here is the scroll view's and the two real
/// controls' (create, back) — deliberately not focus stops on inert rows,
/// which would be traversal noise announcing nothing actionable.
class HouseholdListScreen extends StatelessWidget {
  const HouseholdListScreen({
    required this.repository,
    this.hydration,
    this.onCreate,
    super.key,
  });

  /// Key on the first-fill spinner.
  static const Key loadingKey = Key('household_list.loading');

  /// Key on the empty state.
  static const Key emptyKey = Key('household_list.empty');

  /// Key on the empty state's create button.
  static const Key emptyCreateKey = Key('household_list.empty_create');

  /// Key on the create FAB.
  static const Key createFabKey = Key('household_list.create_fab');

  /// Key on the couldn't-refresh banner.
  static const Key refreshBannerKey = Key('household_list.refresh_banner');

  /// Key on the failed-read surface.
  static const Key errorKey = Key('household_list.error');

  /// Per-row key: `household_list.row_<id>`.
  static Key rowKey(String householdId) =>
      Key('household_list.row_$householdId');

  /// The user-session household repository. Read-only here — the list is a
  /// projection of the cache.
  final HouseholdRepository repository;

  /// What the hydrate is doing, when this composition runs one. Null where
  /// no household client exists (#137), which reads as settled rather than
  /// as forever-loading.
  final Stream<HouseholdHydrationState>? hydration;

  /// Opens the create flow, or null where creating is not possible on this
  /// container — the create screen needs a `HouseholdRemoteDataSource` the
  /// list itself does not (#269 D4).
  ///
  /// Called with this screen's own context, mirroring `HomeMenuEntry`: the
  /// feature package does not know the route table.
  final void Function(BuildContext context)? onCreate;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<HouseholdListBloc>(
      create: (_) =>
          HouseholdListBloc(repository: repository, hydration: hydration),
      child: _HouseholdListView(onCreate: onCreate),
    );
  }
}

class _HouseholdListView extends StatelessWidget {
  const _HouseholdListView({this.onCreate});

  final void Function(BuildContext context)? onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BlocBuilder<HouseholdListBloc, HouseholdListState>(
      builder: (context, state) {
        final households = switch (state) {
          HouseholdListReady(:final households) => households,
          _ => const <Household>[],
        };
        final create = onCreate;

        return BgePage.slivers(
          title: Text(l10n.householdListTitle),
          // A list surface, not a form: rows are a name plus a trailing
          // badge, so they take the wider measure.
          width: BgePageWidth.pane,
          semanticChildCount: households.isEmpty ? null : households.length,
          floatingActionButton: create == null
              ? null
              : FloatingActionButton.extended(
                  key: HouseholdListScreen.createFabKey,
                  onPressed: () => create(context),
                  icon: const Icon(Icons.group_add_outlined),
                  label: Text(l10n.createHouseholdTitle),
                ),
          slivers: [
            if (state case HouseholdListReady(refreshFailed: true))
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: BgeTokens.of(context).spaceMd,
                  ),
                  child: BgeInlineBanner(
                    key: HouseholdListScreen.refreshBannerKey,
                    // Warning, not error: the rows below are real, they
                    // may just be old. Error tone here would read as "this
                    // list is broken".
                    tone: BgeBannerTone.warning,
                    message: l10n.householdListRefreshFailed,
                    // Furniture for as long as the refresh stays failed,
                    // and it already sits at the top of the viewport.
                    reveal: false,
                  ),
                ),
              ),
            switch (state) {
              HouseholdListLoading() => _LoadingSliver(
                message: l10n.householdListLoading,
              ),
              HouseholdListError() => _ErrorSliver(
                message: l10n.householdListError,
              ),
              HouseholdListReady(:final households) when households.isEmpty =>
                _EmptySliver(onCreate: create),
              HouseholdListReady(:final households) => SliverList.builder(
                itemCount: households.length,
                itemBuilder: (context, index) =>
                    _HouseholdRow(household: households[index]),
              ),
            },
          ],
        );
      },
    );
  }
}

/// One household. Content, not a control — see [HouseholdListScreen].
class _HouseholdRow extends StatelessWidget {
  const _HouseholdRow({required this.household});

  final Household household;

  /// Local work the server has not acknowledged: created offline
  /// ([Household.isLocalOnly]) or edited since ([Household.isDirty]).
  ///
  /// One badge for both, deliberately (#269): until the queue drains
  /// (#121) a created household can sit local-only indefinitely, and a
  /// list that silently shows a household the server has never heard of is
  /// worse than no list. The pending-count plumbing and the shared
  /// indicator are #47's.
  bool get _pending => household.isLocalOnly || household.isDirty;

  @override
  Widget build(BuildContext context) {
    final description = household.description;
    final hasDescription = description != null && description.isNotEmpty;

    return Semantics(
      key: HouseholdListScreen.rowKey(household.id),
      container: true,
      child: ListTile(
        title: Text(household.name),
        // The badge sits UNDER the name, not in `ListTile.trailing`.
        //
        // Trailing is a fixed slot measured against the tile width, and
        // "Not yet synced" at the 200% text scale this app guarantees
        // (`BgeTextScale.maxScaleFactor`) is wider than a phone row has to
        // spare — Flutter asserts *Trailing widget consumes the entire tile
        // width* and the row fails to lay out. It fires from 1.6× on a
        // 360dp window, so it is the ordinary large-text setting rather
        // than the extreme.
        //
        // Constraining the slot instead would have kept the position and
        // truncated the words, which is the one thing this badge cannot
        // afford to lose: it is the whole reason the state is not conveyed
        // by colour.
        subtitle: hasDescription || _pending
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasDescription) Text(description),
                  if (_pending) ...[
                    if (hasDescription) const BgeGap.xs(),
                    const _PendingBadge(),
                  ],
                ],
              )
            : null,
      ),
    );
  }
}

/// "Not yet synced", as an icon plus words.
///
/// The colour is [BgeStatus.pending] and the icon is the one paired with
/// it — never colour alone, which is the project's standing answer to
/// colour-vision deficiency and the issue's explicit accessibility ask.
class _PendingBadge extends StatelessWidget {
  const _PendingBadge();

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final color = BgeStatusColors.of(context).pending;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          // Scales with its label: an icon pinned to a fixed size beside
          // 200%-scaled text stops reading as part of the same badge.
          BgeStatusColors.iconFor(BgeStatus.pending),
          size: MediaQuery.textScalerOf(
            context,
          ).scale(theme.textTheme.labelMedium?.fontSize ?? 0),
          color: color,
        ),
        const BgeGap.xs(axis: Axis.horizontal),
        // Flexible, so the label wraps inside the row rather than
        // overflowing it on a narrow window.
        Flexible(
          child: Text(
            l10n.householdListNotSynced,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _LoadingSliver extends StatelessWidget {
  const _LoadingSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      key: HouseholdListScreen.loadingKey,
      child: Semantics(
        liveRegion: true,
        label: message,
        // The label carries the announcement; the spinner itself has
        // nothing to say to a screen reader.
        child: const ExcludeSemantics(child: CircularProgressIndicator()),
      ),
    ),
  );
}

class _EmptySliver extends StatelessWidget {
  const _EmptySliver({this.onCreate});

  final void Function(BuildContext context)? onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final create = onCreate;

    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        key: HouseholdListScreen.emptyKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.householdListEmptyTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const BgeGap.sm(),
            Text(
              l10n.householdListEmptyBody,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (create != null) ...[
              const BgeGap.lg(),
              FilledButton.icon(
                key: HouseholdListScreen.emptyCreateKey,
                onPressed: () => create(context),
                icon: const Icon(Icons.group_add_outlined),
                label: Text(l10n.createHouseholdTitle),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorSliver extends StatelessWidget {
  const _ErrorSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: BgeInlineBanner(
        key: HouseholdListScreen.errorKey,
        tone: BgeBannerTone.error,
        message: message,
      ),
    ),
  );
}
