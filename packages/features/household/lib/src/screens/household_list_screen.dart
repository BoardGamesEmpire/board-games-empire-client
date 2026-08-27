import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_list_bloc.dart';
import '../bloc/household_list_event.dart';
import '../bloc/household_list_state.dart';
import '../widgets/household_refresh_banner.dart';
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
/// an emptiness we could not verify.
///
/// ## The retry, and what it does and does not announce (#300)
///
/// That banner now carries a retry ([onRetry]), because the only other way
/// back was the next session activate — sign out and in. The button
/// dispatches to the bloc rather than calling [onRetry] itself: starting a
/// pass and saying one is running are the same event, and only the handler
/// that started it knows the user asked.
///
/// While that pass runs the banner **stays**, with refreshing copy and a
/// disabled button that keeps its name: a control that disappears
/// mid-interaction moves focus and loses the user's place, which is the
/// contract `BgeSubmitButton` already holds this package to.
///
/// The exception is an **empty** list, where #269 D1 outranks all of this.
/// An empty cache with a pass running is unknown, not empty, so the whole
/// surface goes back to the spinner rather than putting "no households
/// yet" under a refreshing banner — the same answer the detail screen
/// gives for an absent household (#270). The spinner is the feedback
/// there, and the banner returns with the rows or with the failure.
///
/// A pass **nobody asked for** — the #302 connectivity edge, an app resume
/// — is not narrated (#300 D6). The banner simply clears when it succeeds,
/// exactly as it did before. Announcing background work on a screen that
/// otherwise says nothing is noise, and the user has no decision to make
/// about it.
///
/// ## Rows navigate when there is somewhere to go (#270)
///
/// #269 **D5** shipped rows as content rather than controls, because no
/// household detail route existed and a tap target that leads nowhere is
/// worse than none. #270 built that route, so a row with [onOpen] is a
/// control: tappable, keyboard-activatable, and a focus stop.
///
/// The inert row is still what a caller gets without [onOpen], and that is
/// not dead code — it is the same judgement D5 made, now expressed as a
/// condition instead of an era. A composition that cannot reach the detail
/// screen should not offer a tap that does nothing.
///
/// Each row is one merged semantics node either way, so a screen reader
/// reads "Sunday Crew, Not yet synced" rather than three fragments, and
/// the count comes from [BgePage.slivers]'s `semanticChildCount` ("item 3
/// of 9"). What changes with [onOpen] is that the node becomes a button —
/// announced as one, and reachable by keyboard traversal, which inert rows
/// deliberately were not.
class HouseholdListScreen extends StatelessWidget {
  const HouseholdListScreen({
    required this.repository,
    this.hydration,
    this.onCreate,
    this.onOpen,
    this.onRetry,
    this.onEnter,
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

  /// Key on the banner's retry button (#300).
  static const Key refreshRetryKey = Key('household_list.refresh_retry');

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

  /// Opens one household's detail screen (#270), or null where there is no
  /// detail route to open — in which case rows stay inert content rather
  /// than becoming controls that do nothing.
  ///
  /// Takes the id rather than the [Household]: the destination re-reads it
  /// from the cache, so handing over the whole row would be offering a
  /// snapshot the receiver must not trust.
  final void Function(BuildContext context, String householdId)? onOpen;

  /// Runs one more hydrate pass, or null where this composition has none
  /// to run — the same #137 case that leaves [hydration] null. Absent, the
  /// banner still reports a failed refresh; it just offers nothing to do
  /// about it, rather than a button that does nothing.
  final Future<void> Function()? onRetry;

  /// Asks for a hydrate pass when this screen is entered, subject to the
  /// staleness window (#300 D1, D13). Null where this composition has no
  /// re-hydrate seam at all — the same #137 case that leaves [onRetry]
  /// null.
  ///
  /// Fire-and-forget by contract: the caller owns the error handling, and
  /// nothing here waits on it. What it starts is **not narrated** (#300
  /// D6) — the banner clears if it succeeds, and says nothing while it
  /// runs, because nobody pressed anything.
  final VoidCallback? onEnter;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<HouseholdListBloc>(
      create: (_) {
        final bloc = HouseholdListBloc(
          repository: repository,
          hydration: hydration,
          onRetry: onRetry,
        );
        // #300 D14: here, and not in the route builder. `create` runs once
        // per provider insertion — which is once per entry — whereas
        // go_router re-runs a route's builder on every router rebuild and
        // for every page in the match stack, so the same call there would
        // fire on rebuilds and on pushing the detail route. That is a poll,
        // which #300 D1 rejected by name.
        //
        // After the bloc, so its subscription is in place before the pass
        // can report anything.
        onEnter?.call();
        return bloc;
      },
      child: _HouseholdListView(
        onCreate: onCreate,
        onOpen: onOpen,
        // The callback itself stays with the bloc; the view only needs to
        // know whether there is one, to decide whether to draw a button.
        canRetry: onRetry != null,
      ),
    );
  }
}

class _HouseholdListView extends StatelessWidget {
  const _HouseholdListView({this.onCreate, this.onOpen, this.canRetry = false});

  final void Function(BuildContext context)? onCreate;
  final void Function(BuildContext context, String householdId)? onOpen;

  /// Whether this composition can re-run the drain at all (#300 D5).
  final bool canRetry;

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
            if (state case HouseholdListReady(
              :final refreshFailed,
              :final refreshing,
            ) when refreshFailed || refreshing)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: BgeTokens.of(context).spaceMd,
                  ),
                  child: HouseholdRefreshBanner(
                    key: HouseholdListScreen.refreshBannerKey,
                    retryKey: HouseholdListScreen.refreshRetryKey,
                    failedMessage: l10n.householdListRefreshFailed,
                    refreshing: refreshing,
                    onRetry: canRetry
                        ? () => context.read<HouseholdListBloc>().add(
                            const HouseholdListRetryRequested(),
                          )
                        : null,
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
                    _HouseholdRow(household: households[index], onOpen: onOpen),
              ),
            },
          ],
        );
      },
    );
  }
}

/// One household: a control when it can open something, content when it
/// cannot — see [HouseholdListScreen].
class _HouseholdRow extends StatelessWidget {
  const _HouseholdRow({required this.household, this.onOpen});

  final Household household;
  final void Function(BuildContext context, String householdId)? onOpen;

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
    final open = onOpen;

    // MergeSemantics rather than a Semantics container, and it is the tap
    // target that forces the change. A tappable ListTile builds an InkWell,
    // and that InkWell publishes its OWN semantics node — so the node
    // carrying the tap action stopped being the node carrying the name and
    // the badge, and a screen reader read an unlabelled button followed by
    // loose text. Merging collapses the pair back into the single node the
    // row has always been.
    //
    // Nothing here declares `button`: the tile is a control exactly when it
    // has an `onTap`, and letting the InkWell's own semantics say so keeps
    // one source of truth instead of two that can disagree.
    return MergeSemantics(
      key: HouseholdListScreen.rowKey(household.id),
      child: ListTile(
        // The tap target, the focus stop and the keyboard activation all
        // come from this one callback — ListTile builds an InkWell when it
        // has an onTap and nothing when it does not, which is exactly the
        // inert row #269 D5 wanted.
        onTap: open == null ? null : () => open(context, household.id),
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
