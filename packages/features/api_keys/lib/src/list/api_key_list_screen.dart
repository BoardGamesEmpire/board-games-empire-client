import 'dart:async';

import 'package:api_keys/l10n/api_keys_localizations.dart';
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
/// opens, again when a key's own page closes, and on Refresh. Nothing is
/// stored. The list writes nothing, so nothing here waits for a connection.
///
/// Each row says its key's name, the start of its secret, its permissions
/// in words with the highest risk among them, its expiry, whether it is
/// enabled and when it was last used ([ApiKeyRow]). Tapping a row opens the
/// key through [openKey]; a second tap while that page is open does nothing.
///
/// A read that fails with keys on screen leaves them there, with their
/// focus, under a [BgeRefreshBanner] saying they may be out of date. Only a
/// read that fails with nothing loaded takes the page, as a [BgeErrorState].
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

  /// The row of the key [id]. Held by the wrapper [BgeKeyedSliverList] puts
  /// around each row, so a finder by it reaches the whole row.
  static Key rowKey(String id) => ValueKey('api_key_list.row.$id');

  final ApiKeyRemoteDataSource remote;

  /// Opens the key `id`'s own page. The list reads page 1 again when it
  /// completes, so a change made there shows here.
  final Future<void> Function(String id) openKey;

  /// Opens the page that makes a key. Null offers none.
  final Future<void> Function()? createKey;

  @override
  State<ApiKeyListScreen> createState() => _ApiKeyListScreenState();
}

class _ApiKeyListScreenState extends State<ApiKeyListScreen> {
  /// Whether a key's page is open from here, so a second tap opens nothing.
  bool _opening = false;

  Future<void> _open(BuildContext context, String id) async {
    if (_opening) return;
    _opening = true;
    // Read before the await: a new remote replaces the bloc meanwhile, and
    // the one closed with it is not asked to read again.
    final bloc = context.read<ApiKeyListBloc>();
    try {
      await widget.openKey(id);
    } finally {
      if (mounted) _opening = false;
    }
    // A provider can close its bloc before isClosed reads true, so the
    // screen being mounted is asked too.
    if (mounted && !bloc.isClosed) bloc.add(const ApiKeyListRequested());
  }

  @override
  Widget build(BuildContext context) => BlocProvider<ApiKeyListBloc>(
    // A new remote is another server's keys: a new list, not the old rows.
    key: ObjectKey(widget.remote),
    create: (_) =>
        ApiKeyListBloc(widget.remote)..add(const ApiKeyListRequested()),
    child: BlocBuilder<ApiKeyListBloc, ApiKeyListState>(
      builder: (context, state) => _ApiKeyListView(
        state: state,
        onOpen: (id) => unawaited(_open(context, id)),
      ),
    ),
  );
}

class _ApiKeyListView extends StatelessWidget {
  const _ApiKeyListView({required this.state, required this.onOpen});

  final ApiKeyListState state;
  final void Function(String id) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final bloc = context.read<ApiKeyListBloc>();
    final loaded = state.status == ApiKeyListStatus.loaded;
    final visible = state.visible;

    return BgePage.slivers(
      title: Text(l10n.apiKeysTitle),
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
              body: l10n.apiKeysLoadFailedBody,
              retryLabel: l10n.apiKeysRetry,
              onRetry: () => bloc.add(const ApiKeyListRequested()),
            ),
          ),
          // With more to load, More follows the words, so the state takes
          // only its own room rather than the rest of the page.
          ApiKeyListStatus.loaded when visible.isEmpty && state.hasMore =>
            SliverToBoxAdapter(child: _EmptyState(state: state)),
          ApiKeyListStatus.loaded when visible.isEmpty => BgeStateSliver(
            child: _EmptyState(state: state),
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
  const _EmptyState({required this.state});

  final ApiKeyListState state;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    // Keys the server has not sent yet may be the ones the filter wants.
    final more = state.hasMore ? l10n.apiKeysEmptyFilterMore : null;

    return switch (state.filter) {
      ApiKeyStatusFilter.all => BgeEmptyState(
        key: ApiKeyListScreen.emptyKey,
        icon: Icons.key_outlined,
        title: l10n.apiKeysEmptyTitle,
        body: l10n.apiKeysEmptyBody,
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
          label: Text(l10n.apiKeysFilterAll),
        ),
        ButtonSegment(
          value: ApiKeyStatusFilter.enabled,
          label: Text(l10n.apiKeysFilterEnabled),
        ),
        ButtonSegment(
          value: ApiKeyStatusFilter.disabled,
          label: Text(l10n.apiKeysFilterDisabled),
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
