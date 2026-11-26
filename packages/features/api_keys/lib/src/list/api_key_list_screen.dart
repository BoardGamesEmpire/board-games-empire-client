import 'dart:async';

import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:api_keys/src/list/api_key_list_bloc.dart';
import 'package:api_keys/src/list/api_key_list_event.dart';
import 'package:api_keys/src/list/api_key_list_state.dart';
import 'package:api_keys/src/widgets/api_key_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The signed-in user's API keys on this server (#1028), newest first, with
/// an All / Enabled / Disabled filter over the pages loaded so far.
///
/// Online only, as the sign-in methods screen is: the keys and the
/// permissions the user may grant are read from the server when the screen
/// opens, again when a page over it has gone, and on Refresh. Nothing is
/// stored. The list writes nothing, so nothing here waits for a connection.
///
/// Each row says its key's name, the start of its secret, its permissions
/// in words with the highest risk among them, its expiry, whether it is
/// enabled and when it was last used ([ApiKeyRow]). Tapping a row opens the
/// key through [openKey]; a second tap while that page is open does nothing.
///
/// ## Create key
///
/// With a [createKey], a floating "Create key" opens the page that makes
/// one, and so does a button under the words of a list with no keys. The
/// floating button takes focus as either is pressed, so focus is back on it
/// when that page closes: a screen reader's press gives it none, and the
/// button under the words goes once there is a key to show.
///
/// ## Coming back
///
/// The list reads its pages again once a page over it has gone, so what
/// was done there shows here, and a key opened from a later page keeps its
/// row and its focus. There are two signs of that, and one read for both:
///
/// - [openKey]'s or [createKey]'s future completes, for a page the list
///   opened;
/// - the list's route is the top one again, after not being. That covers a
///   page the list never opened, as when a link or a reload builds the list
///   beneath a key's page, and a page the router took away without popping
///   it, as the browser's Back does. The future a push returned then never
///   completes, and waiting on it alone would leave the list unable to open
///   anything again.
///
/// A read that fails with keys on screen leaves them there, with their
/// focus, under a [BgeRefreshBanner] saying they may be out of date. Only a
/// read that fails with nothing loaded takes the page, as a [BgeErrorState]
/// that says why: the connection, or the server's refusal in its words. Its
/// Try again goes as the read starts, so focus waits on the page's title.
///
/// The screen makes its own [ApiKeyListBloc], and a new [remote] makes a new
/// one, so one server's keys never show under another's.
class ApiKeyListScreen extends StatefulWidget {
  const ApiKeyListScreen({
    required this.remote,
    required this.openKey,
    this.createKey,
    super.key,
  });

  static const Key loadingKey = Key('api_key_list.loading');
  static const Key filterKey = Key('api_key_list.filter');
  static const Key emptyKey = Key('api_key_list.empty');
  static const Key failedKey = Key('api_key_list.failed');
  static const Key moreKey = Key('api_key_list.more');
  static const Key moreFailedKey = Key('api_key_list.more_failed');
  static const Key refreshKey = Key('api_key_list.refresh');
  static const Key refreshFailedKey = Key('api_key_list.refresh_failed');
  static const Key refreshRetryKey = Key('api_key_list.refresh_retry');

  /// On the floating "Create key".
  static const Key createFabKey = Key('api_key_list.create');

  /// On the "Create key" under the words of a list with no keys.
  static const Key emptyCreateKey = Key('api_key_list.empty_create');

  /// The row of the key [id]. Held by the wrapper [BgeKeyedSliverList] puts
  /// around each row, so a finder by it reaches the whole row.
  static Key rowKey(String id) => ValueKey('api_key_list.row.$id');

  final ApiKeyRemoteDataSource remote;

  /// Opens the key `id`'s own page. The list reads page 1 again when it
  /// completes, so a change made there shows here.
  final Future<void> Function(String id) openKey;

  /// Opens the page that makes a key. The list reads page 1 again when it
  /// completes, so a key made there shows here. Null offers none.
  final Future<void> Function()? createKey;

  @override
  State<ApiKeyListScreen> createState() => _ApiKeyListScreenState();
}

class _ApiKeyListScreenState extends State<ApiKeyListScreen> {
  @override
  Widget build(BuildContext context) => BlocProvider<ApiKeyListBloc>(
    // A new remote is another server's keys: a new list, not the old rows.
    key: ObjectKey(widget.remote),
    create: (_) =>
        ApiKeyListBloc(widget.remote)..add(const ApiKeyListRequested()),
    child: _ApiKeyList(
      openKey: widget.openKey,
      createKey: widget.createKey,
    ),
  );
}

/// The list under its bloc's provider: what opens a page from it, and what
/// reads it again once a page over it has gone. See "Coming back" on
/// [ApiKeyListScreen].
class _ApiKeyList extends StatefulWidget {
  const _ApiKeyList({required this.openKey, required this.createKey});

  final Future<void> Function(String id) openKey;
  final Future<void> Function()? createKey;

  @override
  State<_ApiKeyList> createState() => _ApiKeyListState();
}

class _ApiKeyListState extends State<_ApiKeyList> {
  /// The page opened from here that is open, a key's or the one that makes a
  /// key, or null when none is. A second press then opens nothing. Each
  /// opening has its own, so an open that completes after its page has gone
  /// and another has opened answers for nothing.
  Object? _visit;

  /// Whether another route was over the list's when it was last asked.
  bool _covered = false;

  /// Whether the list has read again for the page now over it, so the
  /// second sign of that page going reads nothing more.
  bool _readAgain = false;

  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop. Where focus waits when Try again goes as the read starts.
  final FocusNode _heading = FocusNode(
    debugLabel: 'API keys heading',
    skipTraversal: true,
  );

  /// The floating Create key's, so focus can be sent to it and comes back
  /// to it.
  final FocusNode _createFocus = FocusNode(debugLabel: 'Create key');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_covered && current) {
      // The top route again: whatever was over the list has gone, by a pop
      // or by the router taking it away, whoever opened it.
      _visit = null;
      if (!_readAgain) _read();
    }
    // A page newly over the list has had no read made for it yet.
    if (!_covered || current) _readAgain = false;
    _covered = !current;
  }

  @override
  void dispose() {
    _heading.dispose();
    _createFocus.dispose();
    super.dispose();
  }

  /// Reads the pages loaded again, unless the list has gone: a new remote
  /// takes this State with the bloc it read from.
  void _read() {
    if (!mounted) return;
    context.read<ApiKeyListBloc>().add(const ApiKeyListRequested());
  }

  Future<void> _away(Future<void> Function() open) async {
    if (_visit != null) return;
    final visit = _visit = Object();
    try {
      await open();
    } finally {
      // Still this page's: the list's route coming back to the top has not
      // answered for it already, and no other page has opened since.
      if (identical(_visit, visit)) {
        _visit = null;
        _read();
        _readAgain = true;
      }
    }
  }

  void _create(Future<void> Function() createKey) {
    // Taken as either Create key is pressed, so the page it opens hands
    // focus back here when it closes: see "Create key" on the screen.
    _createFocus.requestFocus();
    unawaited(_away(createKey));
  }

  void _retry() {
    // Try again goes as the read starts, and would take focus with it.
    _heading.requestFocus();
    _read();
  }

  @override
  Widget build(BuildContext context) {
    final createKey = widget.createKey;
    return BlocBuilder<ApiKeyListBloc, ApiKeyListState>(
      builder: (context, state) => _ApiKeyListView(
        state: state,
        heading: _heading,
        onOpen: (id) => unawaited(_away(() => widget.openKey(id))),
        onRetry: _retry,
        onCreate: createKey == null ? null : () => _create(createKey),
        createFocus: _createFocus,
      ),
    );
  }
}

class _ApiKeyListView extends StatelessWidget {
  const _ApiKeyListView({
    required this.state,
    required this.heading,
    required this.onOpen,
    required this.onRetry,
    required this.onCreate,
    required this.createFocus,
  });

  final ApiKeyListState state;

  /// The page title's focus node.
  final FocusNode heading;

  final void Function(String id) onOpen;

  /// Reads page 1 again after a load failure.
  final VoidCallback onRetry;

  /// Opens the page that makes a key, or null when none is offered.
  final VoidCallback? onCreate;

  /// The floating Create key's focus node.
  final FocusNode createFocus;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final bloc = context.read<ApiKeyListBloc>();
    final loaded = state.status == ApiKeyListStatus.loaded;
    final visible = state.visible;
    final onCreate = this.onCreate;

    return BgePage.slivers(
      title: Focus(focusNode: heading, child: Text(l10n.apiKeysTitle)),
      // Offered however the read went: making a key needs no list.
      floatingActionButton: onCreate == null
          ? null
          : BgeExtendedFab(
              key: ApiKeyListScreen.createFabKey,
              focusNode: createFocus,
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: l10n.apiKeyCreateAction,
            ),
      // Rows of a name and its facts: the list measure.
      width: BgePageWidth.pane,
      // What the list holds now, grown as pages arrive. Not known until the
      // first page has answered.
      semanticChildCount: loaded ? visible.length : null,
      // In the header, not among the rows, so it is in the semantics tree
      // and heard however far down the list the reader is, as the re-read
      // after a key's page closes can leave them. Passed on every build, so
      // the page keeps one shape as it comes and goes.
      header: state.refreshFailed
          ? BgeRefreshBanner(
              key: ApiKeyListScreen.refreshFailedKey,
              retryKey: ApiKeyListScreen.refreshRetryKey,
              failedMessage: l10n.apiKeysRefreshFailed,
              inProgressLabel: l10n.apiKeysRefreshing,
              retryLabel: l10n.apiKeysRetry,
              refreshing: state.refreshing,
              onRetry: () => bloc.add(const ApiKeyListRequested()),
            )
          : const SizedBox.shrink(),
      actions: [
        BgeRefreshButton(
          buttonKey: ApiKeyListScreen.refreshKey,
          label: l10n.apiKeysRefresh,
          inProgressLabel: l10n.apiKeysRefreshing,
          // From any state: on the spinner the label is what says a press
          // was taken.
          refreshing:
              state.refreshing || state.status == ApiKeyListStatus.loading,
          onPressed: () => bloc.add(const ApiKeyListRequested()),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: tokens.spaceMd),
            child: _FilterControl(filter: state.filter),
          ),
        ),
        switch (state.status) {
          ApiKeyListStatus.loading => BgeStateSliver(
            child: BgeLoadingState(
              key: ApiKeyListScreen.loadingKey,
              label: l10n.apiKeysLoading,
            ),
          ),
          ApiKeyListStatus.loadFailed => BgeStateSliver(
            child: BgeErrorState(
              key: ApiKeyListScreen.failedKey,
              icon: Icons.cloud_off_outlined,
              title: l10n.apiKeysLoadFailed,
              body: switch (state.loadFailure) {
                // A refusal says why in its own words, the server's where
                // the client has none (#1028).
                final failure?
                    when failure.reason != ApiKeyFailureReason.transient =>
                  apiKeyFailureMessage(l10n, failure),
                _ => l10n.apiKeysLoadFailedBody,
              },
              retryLabel: l10n.apiKeysRetry,
              onRetry: onRetry,
            ),
          ),
          // With more to load, More follows the words, so the state takes
          // only its own room rather than the rest of the page.
          ApiKeyListStatus.loaded when visible.isEmpty && state.hasMore =>
            SliverToBoxAdapter(
              child: _EmptyState(state: state, onCreate: onCreate),
            ),
          ApiKeyListStatus.loaded when visible.isEmpty => BgeStateSliver(
            child: _EmptyState(state: state, onCreate: onCreate),
          ),
          ApiKeyListStatus.loaded => BgeKeyedSliverList<ApiKey>(
            items: visible,
            keyOf: (key) => ApiKeyListScreen.rowKey(key.id),
            itemBuilder: (context, key) => ApiKeyRow(
              apiKey: key,
              grantable: state.grantable,
              onOpen: () => onOpen(key.id),
            ),
          ),
        },
        if (loaded && state.hasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: tokens.spaceMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: tokens.spaceMd,
                children: [
                  if (state.moreFailed)
                    BgeInlineBanner(
                      key: ApiKeyListScreen.moreFailedKey,
                      tone: BgeBannerTone.error,
                      message: l10n.apiKeysMoreFailed,
                    ),
                  Center(child: _MoreButton(state: state)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Loads the next page. Busy, it stays enabled and keeps focus, and its
/// name says it is loading, so a keyboard or screen reader user who pressed
/// it stays where they were (STYLE_GUIDE §5).
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.state});

  final ApiKeyListState state;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final label = state.loadingMore
        ? l10n.apiKeysLoadingMore
        : l10n.apiKeysMore;

    return BgeInertButton(
      key: ApiKeyListScreen.moreKey,
      inert: state.loadingMore || state.refreshing,
      label: label,
      onPressed: () =>
          context.read<ApiKeyListBloc>().add(const ApiKeyListMoreRequested()),
      builder: (context, focusNode, onPressed) => OutlinedButton(
        focusNode: focusNode,
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.state, required this.onCreate});

  final ApiKeyListState state;

  /// Opens the page that makes a key, or null when none is offered.
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    // Keys the server has not sent yet may be the ones the filter wants.
    final more = state.hasMore ? l10n.apiKeysEmptyFilterMore : null;
    final onCreate = this.onCreate;

    return switch (state.filter) {
      ApiKeyStatusFilter.all => BgeEmptyState(
        key: ApiKeyListScreen.emptyKey,
        icon: Icons.key_outlined,
        title: l10n.apiKeysEmptyTitle,
        body: l10n.apiKeysEmptyBody,
        // Only where there is no key at all: a filter that shows none is
        // answered by the filter, not by making a key.
        action: onCreate == null
            ? null
            : FilledButton(
                key: ApiKeyListScreen.emptyCreateKey,
                onPressed: onCreate,
                child: Text(l10n.apiKeyCreateAction),
              ),
      ),
      ApiKeyStatusFilter.enabled => BgeEmptyState(
        key: ApiKeyListScreen.emptyKey,
        icon: Icons.key_outlined,
        title: l10n.apiKeysEmptyEnabled,
        body: more,
      ),
      ApiKeyStatusFilter.disabled => BgeEmptyState(
        key: ApiKeyListScreen.emptyKey,
        icon: Icons.key_off_outlined,
        title: l10n.apiKeysEmptyDisabled,
        body: more,
      ),
    };
  }
}

class _FilterControl extends StatelessWidget {
  const _FilterControl({required this.filter});

  final ApiKeyStatusFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);

    return SegmentedButton<ApiKeyStatusFilter>(
      key: ApiKeyListScreen.filterKey,
      segments: [
        ButtonSegment(
          value: ApiKeyStatusFilter.all,
          label: _SegmentLabel(l10n.apiKeysFilterAll),
        ),
        ButtonSegment(
          value: ApiKeyStatusFilter.enabled,
          label: _SegmentLabel(l10n.apiKeysFilterEnabled),
        ),
        ButtonSegment(
          value: ApiKeyStatusFilter.disabled,
          label: _SegmentLabel(l10n.apiKeysFilterDisabled),
        ),
      ],
      selected: {filter},
      showSelectedIcon: false,
      onSelectionChanged: (selected) => context.read<ApiKeyListBloc>().add(
        ApiKeyListFilterChanged(selected.single),
      ),
    );
  }
}

/// A filter segment's label. A segment is as wide as a third of the row, so
/// at 320dp and 200% text a word wider than that scales down to fit on one
/// line rather than breaking mid-word, as a tab's label does (STYLE_GUIDE,
/// "Tabs").
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));
}
