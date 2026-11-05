import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_list_bloc.dart';
import '../bloc/household_list_event.dart';
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
/// The exception is an empty list **no pass has confirmed**, where #269
/// outranks all of this. An empty cache with a pass running and none ever
/// completed is unknown, not empty, so the whole surface goes back to the
/// spinner rather than putting "no households yet" under a refreshing
/// banner — the same answer the detail screen gives for an absent household
/// (#270). The spinner is the feedback there, and the banner returns with
/// the rows or with the failure. An emptiness an earlier pass did confirm
/// stays on its empty state while a later one runs (#453).
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
///
/// ## Focus when the household a row opened is gone (#479)
///
/// Leaving a household pops its detail screen back here, and the household
/// leaves the list. Focus can't go back to the row the user came from. Left
/// to the framework, it goes to whatever this page focused before that row,
/// which depends on how the user got there, or to the page itself, which
/// gives a screen reader nothing to say. Once the detail has gone, the
/// page's heading takes focus instead, for a keyboard and a screen reader
/// alike. It doesn't if the user has moved focus while the detail was
/// leaving.
///
/// The anchor belongs to the list, not to Leave: #477's Delete pops back
/// the same way and shares it.
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

  /// Key on the page's heading, which takes focus when the household a row
  /// opened is gone (#479).
  static const Key headingKey = Key('household_list.heading');

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
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String householdId) =>
      Key('household_list.row_$householdId');

  /// The user-session household repository. Read-only here — the list is a
  /// projection of the cache.
  final HouseholdRepository repository;

  /// What the hydrate is doing, when this composition runs one. Null where
  /// no household client exists (#125), which reads as settled rather than
  /// as forever-loading.
  final Stream<Hydration>? hydration;

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
  /// to run — the same #125 case that leaves [hydration] null. Absent, the
  /// banner still reports a failed refresh; it just offers nothing to do
  /// about it, rather than a button that does nothing.
  final Future<void> Function()? onRetry;

  /// Asks for a hydrate pass when this screen is entered, subject to the
  /// staleness window (#300 D1, D13). Null where this composition has no
  /// re-hydrate seam at all — the same #125 case that leaves [onRetry]
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

class _HouseholdListView extends StatefulWidget {
  const _HouseholdListView({this.onCreate, this.onOpen, this.canRetry = false});

  final void Function(BuildContext context)? onCreate;
  final void Function(BuildContext context, String householdId)? onOpen;

  /// Whether this composition can re-run the drain at all (#300 D5).
  final bool canRetry;

  @override
  State<_HouseholdListView> createState() => _HouseholdListViewState();
}

class _HouseholdListViewState extends State<_HouseholdListView> {
  /// On the page's heading, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'household list heading',
    skipTraversal: true,
  );

  /// The household whose row opened the route above this one, until that
  /// route has gone.
  String? _opened;

  /// This route's secondary animation, which runs as a route above it comes
  /// in and goes.
  Animation<double>? _above;

  /// Where the framework has put focus on this page since the route above
  /// started to leave, while [_onFocusChanged] follows it.
  FocusNode? _handedBack;

  /// Whether focus has moved some other way since the route above started
  /// to leave, such as by the user's Tab. Once it has, the heading doesn't
  /// take focus, wherever focus goes next.
  bool _userMoved = false;

  bool _following = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final above = ModalRoute.of(context)?.secondaryAnimation;
    if (identical(above, _above)) return;
    _above?.removeStatusListener(_onAboveChanged);
    _above = above?..addStatusListener(_onAboveChanged);
  }

  void _open(BuildContext context, String householdId) {
    _opened = householdId;
    widget.onOpen!(context, householdId);
  }

  /// Once the route a row opened has gone, hands focus to the heading if the
  /// household has left the list, unless the user has moved focus on this
  /// page meanwhile (#479).
  ///
  /// When the route has gone, not when it starts to leave. Leaving pops the
  /// detail as soon as its cache write resolves, and the list's read of the
  /// cache answers after that, so the row can still be listed as the route
  /// starts to leave. By the time the route has gone it has had the whole
  /// exit to answer.
  ///
  /// The heading takes focus from wherever the framework has handed it back,
  /// too. That is whatever this page focused last, such as the row above or
  /// the back button, which depends on how the user got to the row. The data
  /// gateway list does the same when a control is taken away (#456).
  ///
  /// A route above that settles back instead, as when a back gesture is let
  /// go of, never gets this far, and the row is still the one to come back
  /// from.
  void _onAboveChanged(AnimationStatus status) {
    final opened = _opened;
    if (opened == null) return;
    switch (status) {
      case AnimationStatus.reverse:
        _followFocus();
      case AnimationStatus.forward || AnimationStatus.completed:
        _forgetFocus();
      case AnimationStatus.dismissed:
        _opened = null;
        WidgetsBinding.instance
          ..addPostFrameCallback((_) {
            final handedBack = _handedBack;
            final userMoved = _userMoved;
            _forgetFocus();
            if (!mounted) return;
            final state = context.read<HouseholdListBloc>().state;
            final listed =
                state is HouseholdListReady &&
                state.households.any((household) => household.id == opened);
            // Before the check below: focus the user has moved back onto the
            // node the framework chose is still theirs.
            if (listed || userMoved) return;
            // Focus on nothing, as it is when the row went in this frame and
            // the framework has yet to hand focus on, counts as free.
            if (!focusIsFree(context, untouched: handedBack)) return;
            _heading.requestFocus();
          })
          // A post-frame callback does not ask for a frame.
          ..ensureVisualUpdate();
    }
  }

  /// Starts following focus as the route above starts to leave.
  ///
  /// The pop has not handed focus back yet: the framework does that from a
  /// microtask the pop queues. The first change after this is that hand-back.
  void _followFocus() {
    _handedBack = null;
    _userMoved = false;
    if (_following) return;
    _following = true;
    FocusManager.instance.addListener(_onFocusChanged);
  }

  void _stopFollowingFocus() {
    if (!_following) return;
    _following = false;
    FocusManager.instance.removeListener(_onFocusChanged);
  }

  void _forgetFocus() {
    _stopFollowingFocus();
    _handedBack = null;
    _userMoved = false;
  }

  /// Records where the framework puts focus: the hand-back after the pop,
  /// and the hand-on when the node it chose goes while it has focus, as the
  /// opened row does when its household leaves the list during the exit.
  ///
  /// A change away from that node while it is still built moved focus some
  /// other way, such as the user's Tab. That marks [_userMoved], and nothing
  /// after it is followed: a node the framework chose that goes once focus
  /// has left it hands nothing on, so the next change is the user's too.
  void _onFocusChanged() {
    final handedBack = _handedBack;
    if (handedBack != null && handedBack.parent != null) {
      _userMoved = true;
      _stopFollowingFocus();
      return;
    }
    _handedBack = FocusManager.instance.primaryFocus;
  }

  @override
  void dispose() {
    _above?.removeStatusListener(_onAboveChanged);
    _forgetFocus();
    _heading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final onOpen = widget.onOpen == null ? null : _open;
    final canRetry = widget.canRetry;

    return BlocBuilder<HouseholdListBloc, HouseholdListState>(
      builder: (context, state) {
        final households = switch (state) {
          HouseholdListReady(:final households) => households,
          _ => const <Household>[],
        };
        final create = widget.onCreate;

        return BgePage.slivers(
          title: Focus(
            key: HouseholdListScreen.headingKey,
            focusNode: _heading,
            child: Text(l10n.householdListTitle),
          ),
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
            if (state
                case HouseholdListReady(:final refreshFailed, :final refreshing)
                when refreshFailed || refreshing)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: BgeTokens.of(context).spaceMd,
                  ),
                  child: BgeRefreshBanner(
                    key: HouseholdListScreen.refreshBannerKey,
                    retryKey: HouseholdListScreen.refreshRetryKey,
                    failedMessage: l10n.householdListRefreshFailed,
                    inProgressLabel: l10n.householdRefreshInProgress,
                    retryLabel: l10n.householdRefreshRetry,
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
              HouseholdListLoading() => BgeStateSliver(
                child: BgeLoadingState(
                  key: HouseholdListScreen.loadingKey,
                  label: l10n.householdListLoading,
                ),
              ),
              HouseholdListError() => _ErrorSliver(
                message: l10n.householdListError,
              ),
              HouseholdListReady(:final households) when households.isEmpty =>
                _EmptySliver(onCreate: create),
              HouseholdListReady(:final households) =>
                BgeKeyedSliverList<Household>(
                  items: households,
                  keyOf: (household) =>
                      HouseholdListScreen.rowKey(household.id),
                  itemBuilder: (context, household) =>
                      _HouseholdRow(household: household, onOpen: onOpen),
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
  /// One badge for both, deliberately (#269): a created household stays
  /// local-only until the queue delivers it, which can be indefinitely when
  /// the server refused it and its op is parked for a retry by hand (#121),
  /// and a list that silently shows a household the server has never heard
  /// of is worse than no list. The pending-count plumbing and the shared
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
          size: MediaQuery.textScalerOf(context)
              .scale(theme.textTheme.labelMedium?.fontSize ?? 0),
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

class _EmptySliver extends StatelessWidget {
  const _EmptySliver({this.onCreate});

  final void Function(BuildContext context)? onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final create = onCreate;

    return BgeStateSliver(
      child: BgeEmptyState(
        key: HouseholdListScreen.emptyKey,
        title: l10n.householdListEmptyTitle,
        body: l10n.householdListEmptyBody,
        action: create == null
            ? null
            : FilledButton.icon(
                key: HouseholdListScreen.emptyCreateKey,
                onPressed: () => create(context),
                icon: const Icon(Icons.group_add_outlined),
                label: Text(l10n.createHouseholdTitle),
              ),
      ),
    );
  }
}

class _ErrorSliver extends StatelessWidget {
  const _ErrorSliver({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => BgeStateSliver(
    child: BgeInlineBanner(
      key: HouseholdListScreen.errorKey,
      tone: BgeBannerTone.error,
      message: message,
    ),
  );
}
