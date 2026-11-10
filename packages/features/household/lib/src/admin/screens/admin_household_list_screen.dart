import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:household/src/admin/bloc/admin_household_list_bloc.dart';
import 'package:household/src/admin/bloc/admin_household_list_event.dart';
import 'package:household/src/admin/bloc/admin_household_list_state.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The staff households section's name (#684, #685): this screen's title,
/// and its entry's on the admin dashboard.
String adminHouseholdsTitle(HouseholdLocalizations l10n) =>
    l10n.adminHouseholdsTitle;

/// Every household on the server, for server staff (#685): searched,
/// filtered by status and sorted, a page at a time, with a deleted one's
/// restore.
///
/// Decoupled from DI like the other household screens: the caller resolves
/// the per-server [AdminHouseholdRemoteDataSource] and the session's
/// [CallerAccessRepository], and owns the route to a live household's detail
/// through [onOpen]. Nothing is cached (#683): [AdminHouseholdListBloc] reads
/// the server when the screen opens, on each query change, and whenever the
/// screen comes back into view.
///
/// ## The head of the list
///
/// The search field, then the Show and Sort menus, each a button that names
/// its choice. They head the content rather than sit in the app bar: beside
/// the back button, two more actions left the title a few letters at 200%
/// text on a 320dp phone. They are there in every state, so they keep their
/// place and their focus as the content below them changes, and a list that
/// failed under one query can be read under another.
///
/// The recently deleted order is offered only while deleted households are
/// shown: the server refuses it over live ones.
///
/// ## Rows
///
/// Name, member count and owners, and for a deleted household when it was
/// deleted, in words beside an icon, never colour alone. Each row reads as
/// one node that says all of that. A live row opens the household; a deleted
/// one opens nothing (the server has no detail for it) and offers Restore
/// instead, behind a confirmation that names the household and its owners.
///
/// ## Restore
///
/// Restore is offered on every deleted row (#685): no answer the client can
/// ask for tells who may restore. It is a direct write, so offline it is
/// disabled and says why. While its restore runs it stays enabled and ignores
/// presses, so it keeps keyboard focus, which a disabled button gives up
/// (#607).
///
/// What a restore answered shows in a banner in the page's footer, with its
/// own Dismiss. A footer is always built and always on screen, so the banner
/// is seen and announced wherever the user is in a long list, and its coming
/// and going moves no row. An answer that repeats the last is a new banner,
/// or it would go unsaid.
///
/// ## Keeping keyboard focus
///
/// A restored row leaves the list under Deleted, and turns live in place
/// under All, where its Restore goes. Either way, if Restore had focus it
/// goes to the banner's Dismiss, else to the page's heading, which is no Tab
/// stop but is always there. So does a Restore that goes while its
/// confirmation is open, as a read lands without its row: focus has nothing
/// to come back to when the dialog closes. Load more, gone with the last
/// page, hands its focus to the first row that page brought, or to the same
/// places. A live row that goes with focus, as when a read takes a household
/// deleted meanwhile, hands it to its own Restore if it is still listed as
/// deleted, else to the next row, else the row before it, else the same
/// places. Focus the user has moved meanwhile is left where it is. Retry,
/// which goes with the failure as the read starts, and Dismiss, which goes
/// with the banner, hand their focus to the heading.
class AdminHouseholdListScreen extends StatelessWidget {
  const AdminHouseholdListScreen({
    required this.remote,
    this.access,
    this.onOpen,
    super.key,
  });

  static const Key loadingKey = Key('admin_household_list.loading');
  static const Key emptyKey = Key('admin_household_list.empty');
  static const Key errorKey = Key('admin_household_list.error');
  static const Key refusedKey = Key('admin_household_list.refused');
  static const Key searchKey = Key('admin_household_list.search');
  static const Key statusKey = Key('admin_household_list.status');
  static const Key sortKey = Key('admin_household_list.sort');
  static const Key outcomeKey = Key('admin_household_list.outcome');
  static const Key moreKey = Key('admin_household_list.more');
  static const Key restoreConfirmKey = Key(
    'admin_household_list.restore_confirm',
  );

  /// Per-row key: `admin_household_list.row_<id>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String id) => Key('admin_household_list.row_$id');

  /// A deleted row's Restore button: `admin_household_list.restore_<id>`.
  static Key restoreKey(String id) => Key('admin_household_list.restore_$id');

  final AdminHouseholdRemoteDataSource remote;

  /// The session's access, asked again when the server refuses. Null for a
  /// composition without one.
  final CallerAccessRepository? access;

  /// Opens a live household's detail, or null where there is none to open,
  /// and then rows stay content rather than controls that do nothing.
  ///
  /// Takes the id rather than the row: the detail reads the household from
  /// the server itself.
  final void Function(BuildContext context, String id)? onOpen;

  @override
  Widget build(BuildContext context) => BlocProvider<AdminHouseholdListBloc>(
    create: (_) =>
        AdminHouseholdListBloc(remote: remote, access: access)
          ..add(const AdminHouseholdListLoadRequested()),
    // Reads the list again when the screen comes back into view, as from a
    // household's detail.
    child: Builder(
      builder: (context) => ReadAgainWhenUncovered(
        onUncovered: () => context.read<AdminHouseholdListBloc>().add(
          const AdminHouseholdListLoadRequested(),
        ),
        child: _AdminHouseholdListView(onOpen: onOpen),
      ),
    ),
  );
}

class _AdminHouseholdListView extends StatefulWidget {
  const _AdminHouseholdListView({this.onOpen});

  final void Function(BuildContext context, String id)? onOpen;

  @override
  State<_AdminHouseholdListView> createState() =>
      _AdminHouseholdListViewState();
}

class _AdminHouseholdListViewState extends State<_AdminHouseholdListView> {
  /// On the page's heading, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'admin households heading',
    skipTraversal: true,
  );

  final FocusNode _search = FocusNode(debugLabel: 'admin households search');

  /// The outcome banner's Dismiss, owned here so that it keeps focus when an
  /// answer makes the banner new.
  final FocusNode _dismiss = FocusNode(debugLabel: 'admin households dismiss');

  /// Around the load-more button, so a hand-off can tell it has focus. It
  /// takes none itself.
  final FocusNode _more = FocusNode(
    debugLabel: 'admin households more',
    canRequestFocus: false,
  );

  /// Around each row, by id, for as long as the row is listed: the handle on
  /// the first control in it. It takes no focus itself.
  final Map<String, FocusNode> _rows = {};

  /// Around each deleted row's Restore, by id, for as long as it is offered.
  /// It takes no focus itself: the button inside does.
  final Map<String, FocusNode> _restores = {};

  final TextEditingController _query = TextEditingController();

  /// The ids of the rows listed, as the last state had them.
  List<String> _listed = const [];

  /// How many restores have answered, to make each answer's banner new.
  int _answers = 0;

  FocusNode _rowNode(String id) => _rows.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'admin household $id', canRequestFocus: false),
  );

  FocusNode _restoreNode(String id) => _restores.putIfAbsent(
    id,
    () => FocusNode(
      debugLabel: 'admin household restore $id',
      canRequestFocus: false,
    ),
  );

  @override
  void dispose() {
    _heading.dispose();
    _search.dispose();
    _dismiss.dispose();
    _more.dispose();
    for (final node in [..._rows.values, ..._restores.values]) {
      node.dispose();
    }
    _query.dispose();
    super.dispose();
  }

  static bool _offersRestore(AdminHouseholdListState state, String id) =>
      state is AdminHouseholdListReady &&
      state.rows.any((row) => row.id == id && row.isDeleted);

  static bool _offersMore(AdminHouseholdListState state) =>
      state is AdminHouseholdListReady && state.hasMore;

  /// Whether [state] lists [id] as a live row, whose tile can keep focus.
  static bool _listsLive(AdminHouseholdListState state, String id) =>
      state is AdminHouseholdListReady &&
      state.rows.any((row) => row.id == id && !row.isDeleted);

  /// Where focus goes when the control that had it goes, with nothing more
  /// fitting: the banner's Dismiss while an outcome shows, else the heading.
  FocusNode _fallbackIn(AdminHouseholdListState state) =>
      state is AdminHouseholdListReady && state.outcome != null
      ? _dismiss
      : _heading;

  /// Puts focus on [target], bringing it into view for a user who can see
  /// focus: the footer's Dismiss within the footer, the heading at the top.
  void _focus(FocusNode target) {
    target.requestFocus();
    if (FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
      target.context?.findRenderObject()?.showOnScreen();
    }
  }

  void _onState(BuildContext context, AdminHouseholdListState state) {
    _handOffFocus(context, state);
    _forgetRowsGone(state);
    _listed = [
      if (state is AdminHouseholdListReady)
        for (final row in state.rows) row.id,
    ];
  }

  /// When [state] takes away a control with keyboard focus, hands it on.
  ///
  /// Runs before the frame that takes the control away, while it still has
  /// focus, and hands it on after that frame. Not if the user has moved focus
  /// meanwhile, and not if the control still has it then.
  void _handOffFocus(BuildContext context, AdminHouseholdListState state) {
    final restoreGoes = _restores.entries
        .where((entry) => entry.value.hasFocus)
        .where((entry) => !_offersRestore(state, entry.key))
        .firstOrNull
        ?.key;
    final moreGoes = _more.hasFocus && !_offersMore(state);
    // A live row's tile, taken away or turned deleted. Focus on a Restore is
    // [restoreGoes]'s.
    final rowGoes = restoreGoes != null
        ? null
        : _rows.entries
              .where((entry) => entry.value.hasFocus)
              .where((entry) => !(_restores[entry.key]?.hasFocus ?? false))
              .where((entry) => !_listsLive(state, entry.key))
              .firstOrNull
              ?.key;
    if (restoreGoes == null && !moreGoes && rowGoes == null) return;

    // The first row the last page brought, which follows Load more as the
    // next control along.
    final listed = _listed.toSet();
    final firstNew = moreGoes && state is AdminHouseholdListReady
        ? state.rows.where((row) => !listed.contains(row.id)).firstOrNull?.id
        : null;
    // The row itself first, for its Restore, then those after it, nearest
    // first, then those before it.
    final around = rowGoes == null ? const <String>[] : _around(rowGoes);
    final focused = FocusManager.instance.primaryFocus;
    final bloc = context.read<AdminHouseholdListBloc>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(this.context, untouched: focused)) return;
      // A tile turned deleted still holds focus here: it lets go only in a
      // microtask after this frame. It keeps focus only if listed live again.
      final kept = rowGoes != null
          ? _listsLive(bloc.state, rowGoes) &&
                (_rows[rowGoes]?.hasFocus ?? false)
          : restoreGoes == null
          ? _more.hasFocus
          : _restores[restoreGoes]?.hasFocus ?? false;
      if (kept) return;
      // Looked up now, as that frame built it: a row that is not built has
      // nothing to take focus.
      final next = [
        ?firstNew,
        ...around,
      ].map(_firstControlIn).nonNulls.firstOrNull;
      _focus(next ?? _fallbackIn(bloc.state));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// [id] then the ids listed around it, as the last state had them: those
  /// after it, nearest first, then those before it.
  List<String> _around(String id) {
    final index = _listed.indexOf(id);
    if (index < 0) return [id];
    return [
      id,
      for (var i = index + 1; i < _listed.length; i++) _listed[i],
      for (var i = index - 1; i >= 0; i--) _listed[i],
    ];
  }

  /// The first control in [id]'s row, if the row is listed and built.
  FocusNode? _firstControlIn(String id) =>
      _rows[id]?.traversalDescendants.firstOrNull;

  /// Disposes the nodes of rows no longer listed, and of Restores no longer
  /// offered, after the frame that takes them down: a [Focus] holds its node
  /// until then.
  void _forgetRowsGone(AdminHouseholdListState state) {
    final rows = state is AdminHouseholdListReady
        ? state.rows
        : const <AdminHouseholdRow>[];
    final listed = {for (final row in rows) row.id};
    final deleted = {
      for (final row in rows)
        if (row.isDeleted) row.id,
    };
    final nodes = [
      for (final id in [..._rows.keys])
        if (!listed.contains(id)) ?_rows.remove(id),
      for (final id in [..._restores.keys])
        if (!deleted.contains(id)) ?_restores.remove(id),
    ];
    if (nodes.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in nodes) {
        node.dispose();
      }
    });
  }

  /// Whether a restore has answered between [previous] and [current].
  static bool _answered(
    AdminHouseholdListState previous,
    AdminHouseholdListState current,
  ) =>
      previous is AdminHouseholdListReady &&
      current is AdminHouseholdListReady &&
      previous.restoring.difference(current.restoring).isNotEmpty;

  /// Whether [current] brings an outcome that wasn't showing.
  static bool _arrives(
    AdminHouseholdListState previous,
    AdminHouseholdListState current,
  ) =>
      current is AdminHouseholdListReady &&
      current.outcome != null &&
      !(previous is AdminHouseholdListReady &&
          previous.outcome == current.outcome);

  /// Runs before the frame that builds the banner. The banner takes room
  /// from the foot of the view, which may cover a Restore that keeps focus,
  /// as after a failed restore: it is brought back into view, as Tab would,
  /// for a user who can see focus.
  void _onArrival(BuildContext context, AdminHouseholdListState state) {
    bool restoreFocused() => _restores.values.any((node) => node.hasFocus);
    if (!restoreFocused()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !restoreFocused() ||
          FocusManager.instance.highlightMode !=
              FocusHighlightMode.traditional) {
        return;
      }
      FocusManager.instance.primaryFocus?.context
          ?.findRenderObject()
          ?.showOnScreen();
    });
  }

  /// Asks to restore [row], and restores it if confirmed.
  Future<void> _confirmRestore(AdminHouseholdRow row) async {
    final l10n = HouseholdLocalizations.of(context);
    // Read before the dialog opens: a read that fails meanwhile takes the
    // row, and its context, off the screen.
    final bloc = context.read<AdminHouseholdListBloc>();
    final owners = _ownerNames(l10n, row);
    // Focus on Restore now comes back to it when the dialog closes.
    final returning = _restores[row.id]?.hasFocus ?? false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(l10n.adminHouseholdRestoreConfirmTitle(row.name)),
        content: Text(
          owners.isEmpty
              ? l10n.adminHouseholdRestoreConfirmBodyNoOwners
              : l10n.adminHouseholdRestoreConfirmBody(owners),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.adminHouseholdRestoreCancel),
          ),
          TextButton(
            key: AdminHouseholdListScreen.restoreConfirmKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.adminHouseholdRestore),
          ),
        ],
      ),
    );
    if (!mounted) return;
    // The bloc drops a restore of a row it no longer lists as deleted.
    if ((confirmed ?? false) && !bloc.isClosed) {
      bloc.add(AdminHouseholdListRestoreRequested(row.id));
    }
    if (!returning) return;
    // Focus is back on Restore as the dialog closes, before the restore's
    // answer can land, so [_handOffFocus] sees it go. A read that took the
    // row while the dialog was open has taken Restore already, and focus
    // falls back on the page's last focus before it: somewhere the user
    // wasn't. Nobody can have moved it since the dialog closed, so it goes
    // where a Restore that goes sends it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (_restores[row.id]?.hasFocus ?? false)) return;
      final onPage =
          focusIsFree(context) ||
          FocusScope.of(context, createDependency: false).hasFocus;
      if (!onPage) return;
      _focus(_fallbackIn(bloc.state));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _dismissOutcome() {
    // Dismiss goes with the banner, and would take focus with it.
    if (_dismiss.hasFocus) _focus(_heading);
    context.read<AdminHouseholdListBloc>().add(
      const AdminHouseholdListOutcomeDismissed(),
    );
  }

  void _searchChanged(String text) => context
      .read<AdminHouseholdListBloc>()
      .add(AdminHouseholdListSearchChanged(text));

  void _clearSearch() {
    _query.clear();
    _searchChanged('');
    // The clear button goes with the text, and would take focus with it.
    _search.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final inset = tokens.spaceLg;
    final open = widget.onOpen;

    return MultiBlocListener(
      listeners: [
        BlocListener<AdminHouseholdListBloc, AdminHouseholdListState>(
          listener: _onState,
        ),
        BlocListener<AdminHouseholdListBloc, AdminHouseholdListState>(
          listenWhen: _answered,
          listener: (_, _) => setState(() => _answers++),
        ),
        BlocListener<AdminHouseholdListBloc, AdminHouseholdListState>(
          listenWhen: _arrives,
          listener: _onArrival,
        ),
      ],
      child: BlocBuilder<AdminHouseholdListBloc, AdminHouseholdListState>(
        builder: (context, state) {
          final bloc = context.read<AdminHouseholdListBloc>();
          final ready = state is AdminHouseholdListReady ? state : null;
          final outcome = ready?.outcome;

          return BgePage.slivers(
            title: Focus(
              focusNode: _heading,
              child: Text(adminHouseholdsTitle(l10n)),
            ),
            width: BgePageWidth.pane,
            // "Household 3 of 25": the rows loaded so far.
            semanticChildCount: ready == null || ready.rows.isEmpty
                ? null
                : ready.rows.length,
            // The bottom inset ends the slivers instead. The page would put
            // it around the footer, which would then be a band with nothing
            // in it.
            padding: EdgeInsets.fromLTRB(inset, inset, inset, 0),
            // On every build, in every state: BgePage builds a different tree
            // with a footer than without one, so a footer that came and went
            // would lose the scroll position and focus.
            footer: outcome == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: EdgeInsets.only(
                      top: tokens.spaceSm,
                      bottom: tokens.spaceLg,
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(_answers),
                      child: _OutcomeBanner(
                        outcome: outcome,
                        dismissFocus: _dismiss,
                        onDismiss: _dismissOutcome,
                      ),
                    ),
                  ),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spaceMd),
                  child: _Head(
                    query: state.query,
                    controller: _query,
                    focusNode: _search,
                    onChanged: _searchChanged,
                    onClear: _clearSearch,
                  ),
                ),
              ),
              ...switch (state) {
                AdminHouseholdListLoading() => [
                  BgeStateSliver(
                    child: BgeLoadingState(
                      key: AdminHouseholdListScreen.loadingKey,
                      label: l10n.adminHouseholdsLoading,
                    ),
                  ),
                ],
                AdminHouseholdListRefused() => [
                  BgeStateSliver(
                    child: BgeEmptyState(
                      key: AdminHouseholdListScreen.refusedKey,
                      icon: Icons.lock_outline,
                      title: l10n.adminHouseholdsRefused,
                    ),
                  ),
                ],
                AdminHouseholdListFailed() => [
                  BgeStateSliver(
                    child: BgeErrorState(
                      key: AdminHouseholdListScreen.errorKey,
                      icon: Icons.cloud_off_outlined,
                      title: l10n.adminHouseholdsFailed,
                      body: l10n.adminHouseholdsFailedBody,
                      retryLabel: l10n.adminHouseholdsRetry,
                      onRetry: () {
                        // Retry goes as the read starts, and would take
                        // focus with it.
                        _heading.requestFocus();
                        bloc.add(const AdminHouseholdListLoadRequested());
                      },
                    ),
                  ),
                ],
                // Restores can empty a list that has more to load, and the
                // bloc reads on.
                AdminHouseholdListReady(:final rows, :final hasMore)
                    when rows.isEmpty && !hasMore =>
                  [_EmptySliver(query: state.query)],
                final AdminHouseholdListReady ready => [
                  BgeKeyedSliverList<AdminHouseholdRow>(
                    items: ready.rows,
                    keyOf: (row) => AdminHouseholdListScreen.rowKey(row.id),
                    itemBuilder: (context, row) => _HouseholdRow(
                      row: row,
                      restoring: ready.restoring.contains(row.id),
                      focusNode: _rowNode(row.id),
                      restoreFocusNode: row.isDeleted
                          ? _restoreNode(row.id)
                          : null,
                      onOpen: open == null ? null : () => open(context, row.id),
                      onRestore: () => unawaited(_confirmRestore(row)),
                    ),
                  ),
                  if (ready.hasMore)
                    SliverToBoxAdapter(
                      child: _MoreFooter(state: ready, focusNode: _more),
                    ),
                ],
              },
              const SliverToBoxAdapter(child: BgeGap.lg()),
            ],
          );
        },
      ),
    );
  }
}

/// A household's owners by name, in the order the server gives them, or ''
/// when it has none.
String _ownerNames(HouseholdLocalizations l10n, AdminHouseholdRow row) => row
    .owners
    .map((owner) => owner.name ?? l10n.adminHouseholdOwnerUnnamed)
    .join(l10n.adminHouseholdOwnerSeparator);

/// The search field, then the Show and Sort menus.
class _Head extends StatelessWidget {
  const _Head({
    required this.query,
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
  });

  /// The query the state answers: its status and sort. Its text lags the
  /// field's by the bloc's pause, so the field reads its own.
  final AdminHouseholdQuery query;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final status = query.status;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            // The server's measure, as the bloc's: one emoji is one
            // character.
            final length = AdminHouseholdRemoteDataSource.queryLength(
              AdminHouseholdQuery.termOf(value.text),
            );
            const shortest = AdminHouseholdRemoteDataSource.minQueryLength;
            const longest = AdminHouseholdRemoteDataSource.maxQueryLength;
            // Until the term is one the server takes, the list reads
            // unsearched, which this says. Too long passes the field's own
            // cap, which counts an accent typed as a mark of its own, or a
            // family emoji, as one character where the server counts more.
            final hint = length > 0 && length < shortest
                ? l10n.adminHouseholdsSearchTooShort(shortest)
                : length > longest
                ? l10n.adminHouseholdsSearchTooLong(longest)
                : null;
            return TextField(
              key: AdminHouseholdListScreen.searchKey,
              controller: controller,
              focusNode: focusNode,
              // Names and usernames are not prose: a corrected username
              // searches for someone else, and finds nothing the user can
              // explain.
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.search,
              maxLength: longest,
              // The limit is far past any name; a counter would be noise.
              buildCounter: _noCounter,
              onChanged: onChanged,
              decoration: InputDecoration(
                labelText: l10n.adminHouseholdsSearchLabel,
                hintText: l10n.adminHouseholdsSearchHint,
                helper: hint == null ? null : _SearchHint(hint),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10n.adminHouseholdsSearchClear,
                        icon: const Icon(Icons.clear),
                        onPressed: onClear,
                      ),
              ),
            );
          },
        ),
        const BgeGap.sm(),
        Wrap(
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          children: [
            _ChoiceMenu<AdminHouseholdStatus>(
              buttonKey: AdminHouseholdListScreen.statusKey,
              choices: AdminHouseholdStatus.values,
              chosen: status,
              labelOf: (choice) => _statusLabel(l10n, choice),
              buttonLabel: (choice) =>
                  l10n.adminHouseholdsStatusMenu(_statusLabel(l10n, choice)),
              onChosen: (bloc, choice) =>
                  bloc.add(AdminHouseholdListStatusChanged(choice)),
            ),
            _ChoiceMenu<AdminHouseholdSort>(
              buttonKey: AdminHouseholdListScreen.sortKey,
              choices: [
                for (final sort in AdminHouseholdSort.values)
                  if (sort.allowedWith(status)) sort,
              ],
              chosen: query.sort,
              labelOf: (choice) => _sortLabel(l10n, choice),
              buttonLabel: (choice) =>
                  l10n.adminHouseholdsSortMenu(_sortLabel(l10n, choice)),
              onChosen: (bloc, choice) =>
                  bloc.add(AdminHouseholdListSortChanged(choice)),
            ),
          ],
        ),
      ],
    );
  }
}

/// Why the search isn't sent, under the field: a live region, so a screen
/// reader says it once as it appears, and again only if it changes. Without
/// it, a person who types one letter hears no reason the list is unfiltered.
///
/// The field's `helper` rather than its `helperText`, which Flutter puts in a
/// node with no live region. A `helper` takes none of the field's styling,
/// so it is drawn here as Flutter draws helper text, and wraps as far as it
/// needs to at 200% text.
class _SearchHint extends StatelessWidget {
  const _SearchHint(this.words);

  final String words;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Text(
        words,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Widget? _noCounter(
  BuildContext context, {
  required int currentLength,
  required bool isFocused,
  required int? maxLength,
}) => null;

String _statusLabel(HouseholdLocalizations l10n, AdminHouseholdStatus status) =>
    switch (status) {
      AdminHouseholdStatus.live => l10n.adminHouseholdsStatusLive,
      AdminHouseholdStatus.deleted => l10n.adminHouseholdsStatusDeleted,
      AdminHouseholdStatus.all => l10n.adminHouseholdsStatusAll,
    };

String _sortLabel(HouseholdLocalizations l10n, AdminHouseholdSort sort) =>
    switch (sort) {
      AdminHouseholdSort.name => l10n.adminHouseholdsSortName,
      AdminHouseholdSort.newest => l10n.adminHouseholdsSortNewest,
      AdminHouseholdSort.members => l10n.adminHouseholdsSortMembers,
      AdminHouseholdSort.deleted => l10n.adminHouseholdsSortDeleted,
    };

/// A button naming the choice made, which opens a menu of the [choices].
///
/// A menu rather than a [DropdownMenu], whose single-line field cut its
/// choice short at 320dp and 2.0 text, as on the sent invites' filter. The
/// button's label wraps instead.
class _ChoiceMenu<T> extends StatelessWidget {
  const _ChoiceMenu({
    required this.buttonKey,
    required this.choices,
    required this.chosen,
    required this.labelOf,
    required this.buttonLabel,
    required this.onChosen,
  });

  final Key buttonKey;
  final List<T> choices;
  final T chosen;
  final String Function(T choice) labelOf;

  /// The button's label, naming [chosen].
  final String Function(T choice) buttonLabel;
  final void Function(AdminHouseholdListBloc bloc, T choice) onChosen;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    // Within the screen. Left unconstrained, the menu takes its widest
    // entry's width and clips past the edge.
    crossAxisUnconstrained: false,
    menuChildren: [
      for (final choice in choices)
        MenuItemButton(
          // An empty icon on the others keeps their labels in line.
          leadingIcon: Icon(choice == chosen ? Icons.check : null),
          overflowAxis: Axis.vertical,
          // The chosen one only closes the menu. The press arrives after a
          // frame, by when the screen may be gone.
          onPressed: () {
            if (choice == chosen || !context.mounted) return;
            onChosen(context.read<AdminHouseholdListBloc>(), choice);
          },
          // The check is only drawn, so the label says it is chosen. Inside
          // the item, where it merges into the item's own node; around it,
          // it would stand as a node of its own.
          child: Semantics(
            selected: choice == chosen,
            child: Text(labelOf(choice)),
          ),
        ),
    ],
    builder: (context, controller, _) => MergeSemantics(
      child: Semantics(
        expanded: controller.isOpen,
        child: OutlinedButton(
          key: buttonKey,
          onPressed: controller.isOpen ? controller.close : controller.open,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(buttonLabel(chosen))),
              Icon(
                controller.isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EmptySliver extends StatelessWidget {
  const _EmptySliver({required this.query});

  /// The query the empty list answers.
  final AdminHouseholdQuery query;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    // A search too short or too long to send was not asked, so it is not
    // what found nothing.
    final searched = query.sentQuery != null;

    return BgeStateSliver(
      child: BgeEmptyState(
        key: AdminHouseholdListScreen.emptyKey,
        icon: searched ? Icons.search_off : Icons.groups_outlined,
        title: searched
            ? l10n.adminHouseholdsEmptySearch
            : query.status == AdminHouseholdStatus.deleted
            ? l10n.adminHouseholdsEmptyDeleted
            : l10n.adminHouseholdsEmpty,
      ),
    );
  }
}

/// One household: its facts as one node, and on a deleted one, Restore.
class _HouseholdRow extends StatelessWidget {
  const _HouseholdRow({
    required this.row,
    required this.restoring,
    required this.focusNode,
    required this.restoreFocusNode,
    required this.onOpen,
    required this.onRestore,
  });

  final AdminHouseholdRow row;

  /// Whether its restore is running.
  final bool restoring;

  /// Around the whole row. It takes no focus itself.
  final FocusNode focusNode;

  /// Around Restore, on a deleted row. It takes no focus itself.
  final FocusNode? restoreFocusNode;

  /// Opens a live row. Null leaves it content.
  final VoidCallback? onOpen;

  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final members = l10n.adminHouseholdMembers(row.memberCount);
    final owners = _ownerNames(l10n, row);
    final deletedAt = row.deletedAt;
    // On the device's clock. The strings carry the year: a household deleted
    // last year must not read as this year's.
    final deletedOn = deletedAt?.toLocal();
    final facts = owners.isEmpty
        ? l10n.adminHouseholdRowLabelNoOwners(row.name, members)
        : l10n.adminHouseholdRowLabel(row.name, members, owners);
    final restoreFocusNode = this.restoreFocusNode;

    return Focus(
      focusNode: focusNode,
      includeSemantics: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // One node that says the row's facts in a sentence, rather than its
          // lines one after another. A live row's tile merges its tap and
          // focus into it; a deleted row's has neither.
          MergeSemantics(
            child: Semantics(
              label: deletedOn == null
                  ? facts
                  : l10n.adminHouseholdRowLabelDeleted(facts, deletedOn),
              child: ListTile(
                // A deleted household has no detail to open.
                onTap: deletedAt == null ? onOpen : null,
                title: ExcludeSemantics(child: Text(row.name)),
                // Under the name rather than in `trailing`, which at 200%
                // text takes the whole row and fails to lay out.
                subtitle: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(members),
                      if (owners.isNotEmpty)
                        Text(l10n.adminHouseholdOwners(owners)),
                      if (deletedOn != null) ...[
                        const BgeGap.xs(),
                        _DeletedLine(l10n.adminHouseholdDeletedOn(deletedOn)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (restoreFocusNode != null)
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: tokens.spaceMd,
                end: tokens.spaceMd,
                bottom: tokens.spaceSm,
              ),
              child: Focus(
                focusNode: restoreFocusNode,
                includeSemantics: false,
                child: _RestoreButton(
                  row: row,
                  restoring: restoring,
                  onPressed: onRestore,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Deleted" and when, beside a bin icon: never colour alone.
class _DeletedLine extends StatelessWidget {
  const _DeletedLine(this.words);

  final String words;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    // Scales with its words.
    final iconSize = MediaQuery.textScalerOf(context)
        .scale(style.fontSize ?? 0);
    final oneLine = iconSize * (style.height ?? 1);

    return Row(
      mainAxisSize: MainAxisSize.min,
      // Against the first line, in a slot as tall as one, so the icon starts
      // the words however many lines they wrap to at 200% text.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: oneLine,
          child: Icon(Icons.delete_outline, size: iconSize, color: style.color),
        ),
        const BgeGap.xs(axis: Axis.horizontal),
        // Flexible, so the words wrap inside the row at 200% text.
        Flexible(child: Text(words)),
      ],
    );
  }
}

/// A deleted row's Restore: a direct write, so disabled offline and saying
/// why (#49), and enabled but ignoring presses while its restore runs, so it
/// keeps focus (#607).
class _RestoreButton extends StatelessWidget {
  const _RestoreButton({
    required this.row,
    required this.restoring,
    required this.onPressed,
  });

  final AdminHouseholdRow row;
  final bool restoring;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BgeOnlineOnly(
      child: BgeInertButton(
        inert: restoring,
        // Names the household, since every deleted row has one, and while
        // its restore runs says so, since the node is not enabled then. A
        // label, because VoiceOver doesn't read a tooltip on a control that
        // can't be pressed.
        label: restoring
            ? l10n.adminHouseholdRestoreInProgress(row.name)
            : l10n.adminHouseholdRestoreLabel(row.name),
        onPressed: BgeConnectivityScope.offlineOf(context) ? null : onPressed,
        builder: (context, focusNode, onPressed) => TextButton(
          key: AdminHouseholdListScreen.restoreKey(row.id),
          focusNode: focusNode,
          onPressed: onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The busy cue for a sighted user; the node says not available.
              if (restoring) ...[
                const _Spinner(),
                const BgeGap.sm(axis: Axis.horizontal),
              ],
              Flexible(child: Text(l10n.adminHouseholdRestore)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A held control's spinner: scaled with the label beside it, in the
/// control's colour.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: BgeTextScale.clampedOf(context)
        .scale(BgeTokens.of(context).spaceMd),
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: DefaultTextStyle.of(context).style.color,
    ),
  );
}

/// The end of the list while the server has more: the next page's button,
/// and when that failed, saying so.
///
/// The button keeps its place and its focus while the page loads, ignoring
/// presses and saying what it is doing, rather than giving way to a spinner
/// or going disabled, which would drop focus (#607).
class _MoreFooter extends StatelessWidget {
  const _MoreFooter({required this.state, required this.focusNode});

  final AdminHouseholdListReady state;

  /// Around the button. It takes no focus itself.
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final loading = state.loadingMore;
    final failed = state.loadMoreFailed;
    final label = loading
        ? l10n.adminHouseholdsMoreLoading
        : failed
        ? l10n.adminHouseholdsRetry
        : l10n.adminHouseholdsMore;

    return Padding(
      padding: EdgeInsets.only(top: BgeTokens.of(context).spaceMd),
      child: Column(
        children: [
          if (failed) ...[
            Semantics(
              liveRegion: true,
              child: Text(
                l10n.adminHouseholdsMoreFailed,
                textAlign: TextAlign.center,
              ),
            ),
            const BgeGap.sm(),
          ],
          Focus(
            focusNode: focusNode,
            includeSemantics: false,
            child: BgeInertButton(
              inert: loading,
              label: label,
              onPressed: () => context.read<AdminHouseholdListBloc>().add(
                const AdminHouseholdListMoreRequested(),
              ),
              builder: (context, node, onPressed) => OutlinedButton(
                key: AdminHouseholdListScreen.moreKey,
                focusNode: node,
                onPressed: onPressed,
                child: Text(label),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the last restore answered, with its Dismiss.
class _OutcomeBanner extends StatelessWidget {
  const _OutcomeBanner({
    required this.outcome,
    required this.dismissFocus,
    required this.onDismiss,
  });

  final AdminHouseholdRestoreOutcome outcome;

  /// For the Dismiss, which takes focus from a Restore that goes.
  final FocusNode dismissFocus;

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final name = outcome.name;

    final (tone, message) = switch (outcome.result) {
      AdminHouseholdRestoreResult.restored => (
        BgeBannerTone.success,
        l10n.adminHouseholdRestored(name),
      ),
      AdminHouseholdRestoreResult.notRestorable => (
        BgeBannerTone.warning,
        l10n.adminHouseholdNotRestorable(name),
      ),
      AdminHouseholdRestoreResult.failed => (
        BgeBannerTone.error,
        l10n.adminHouseholdRestoreFailed(name),
      ),
    };

    return BgeInlineBanner(
      key: AdminHouseholdListScreen.outcomeKey,
      tone: tone,
      message: message,
      action: TextButton(
        focusNode: dismissFocus,
        onPressed: onDismiss,
        child: Text(l10n.adminHouseholdsDismiss),
      ),
    );
  }
}
