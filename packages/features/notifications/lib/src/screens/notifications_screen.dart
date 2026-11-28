import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/count/notification_count_cubit.dart';
import 'package:notifications/src/list/notification_list_bloc.dart';
import 'package:notifications/src/list/notification_list_event.dart';
import 'package:notifications/src/list/notification_list_state.dart';
import 'package:notifications/src/presentation/notification_target.dart';
import 'package:notifications/src/widgets/notification_list_parts.dart';
import 'package:notifications/src/widgets/notification_row.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The Notifications page (#475): every notification the user has on the
/// active server, read or not, newest first, a page at a time.
///
/// Online only: the list is read from the server when the page opens, when
/// the app comes back to the foreground, on a pull, and on the header's
/// Refresh, and nothing is stored. A read that
/// fails with nothing loaded takes the page, as a [BgeErrorState] with Try
/// again. A refresh that fails over the rows keeps them, under a
/// [BgeRefreshBanner] in the header, until a refresh works.
///
/// What Mark all read and Load more answer when they fail is a banner in
/// the page's footer, always built and on screen. Each stays until the next
/// Mark all read or Load more answers, until it no longer applies (nothing
/// left unread; the rows replaced by a refresh), or until it is dismissed. A
/// repeat of the same failure is a new banner, so it is heard again.
///
/// ## Reading a notification
///
/// Tapping a row that opens something marks it read and calls [onOpen] with
/// its target; until that completes, other rows open nothing. A plain row
/// opens nothing: its "Mark read" marks it read, and goes, so one pressed
/// from the keyboard hands focus on to the next row with a control, or else
/// to the title ([NotificationRowFocus]). The row stays on the page either
/// way, shown read. A mark-read that fails says nothing, and the
/// next refresh tells the truth. Offline a row still opens and shows read;
/// a plain row's "Mark read" waits for a connection.
///
/// "Mark all read" sits in a row of its own above the list, at its end, at
/// every width, while a row loaded is unread. It asks for no confirmation,
/// since nothing is lost. While the server marks them it stays, inert and
/// named for the pass, and once it has gone focus waits on the page's title.
/// It waits for a connection, as a direct write does.
///
/// ## The unread count
///
/// With a [NotificationCountCubit] above it, the page refreshes the count as
/// it opens, on a pull and on Refresh, and tells it of each notification it
/// marks read. Without one it reads and marks the list alone.
///
/// The screen makes its own [NotificationListBloc], and a new [remote] makes
/// a new one, so one server's notifications never show under another's.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({
    required this.remote,
    required this.onOpen,
    super.key,
  });

  static const Key loadingKey = Key('notifications.loading');
  static const Key emptyKey = Key('notifications.empty');
  static const Key failedKey = Key('notifications.failed');

  /// On "Mark all read".
  static const Key markAllKey = Key('notifications.mark_all');

  /// On the header's Refresh.
  static const Key refreshKey = Key('notifications.refresh');

  /// On "Load more", under the list.
  static const Key loadMoreKey = Key('notifications.load_more');

  /// On the banner in the header after a refresh over the rows failed, and
  /// on its Try again.
  static const Key refreshFailedKey = Key('notifications.refresh_failed');
  static const Key refreshRetryKey = Key('notifications.refresh_retry');

  /// On the footer's banner after Mark all read failed.
  static const Key markAllFailedKey = Key('notifications.mark_all_failed');

  /// On the footer's banner after Load more failed.
  static const Key loadMoreFailedKey = Key('notifications.load_more_failed');

  /// The row of the notification [id]. Held by the wrapper
  /// [BgeKeyedSliverList] puts around each row, so a finder by it reaches
  /// the whole row.
  static Key rowKey(String id) => ValueKey('notifications.row.$id');

  final NotificationRemoteDataSource remote;

  /// Opens what a notification is about. app_shell turns the target into a
  /// location.
  ///
  /// The future completes once what it opened has gone, or at once when it
  /// replaces this page. While it is pending, a tap on another row opens
  /// nothing, so a double tap opens one page. It must not throw: the page
  /// awaits it and catches nothing.
  final Future<void> Function(BuildContext context, NotificationTarget target)
  onOpen;

  @override
  Widget build(BuildContext context) => BlocProvider<NotificationListBloc>(
    // A new remote is another server's notifications: a new list, not the
    // old rows.
    key: ObjectKey(remote),
    create: (context) {
      final count = _countOf(context);
      return NotificationListBloc(
        remote,
        onMarkedRead: count == null
            ? null
            : (marked) {
                // The session's count may have gone before an answer came.
                if (!count.isClosed) count.markedRead(marked);
              },
        onAllMarkedRead: count == null
            ? null
            : () {
                if (!count.isClosed) count.allMarkedRead();
              },
      )..add(const NotificationListLoadRequested());
    },
    child: _NotificationsView(onOpen: onOpen),
  );
}

/// The session's unread count, when the page is under one.
NotificationCountCubit? _countOf(BuildContext context) =>
    context.read<NotificationCountCubit?>();

class _NotificationsView extends StatefulWidget {
  const _NotificationsView({required this.onOpen});

  final Future<void> Function(BuildContext context, NotificationTarget target)
  onOpen;

  @override
  State<_NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends State<_NotificationsView> {
  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop. Where focus waits when the control that had it goes: Try
  /// again as the load starts, Mark all read once nothing is unread, and a
  /// row's Mark read with no row after it to take focus.
  final FocusNode _heading = FocusNode(
    debugLabel: 'Notifications heading',
    skipTraversal: true,
  );

  /// Around Mark all read, to tell whether it had focus as it goes.
  final FocusNode _markAll = FocusNode(
    debugLabel: 'Mark all read',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Around Load more, to tell whether it has focus as a banner arrives.
  final FocusNode _loadMore = FocusNode(
    debugLabel: 'Load more',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The Dismiss on each footer banner, held here so that it keeps focus
  /// when a repeat makes its banner new.
  final FocusNode _markAllDismiss = FocusNode(debugLabel: 'Mark all dismiss');
  final FocusNode _loadMoreDismiss = FocusNode(
    debugLabel: 'Load more dismiss',
  );

  /// What the last Mark all read answered, while it failed and still
  /// applies; null otherwise.
  MarkAllFailed? _markAllFailure;

  /// What the last Load more answered, while it failed and still applies;
  /// null otherwise.
  LoadMoreFailed? _loadMoreFailure;

  /// How many times each has failed, so that a repeat is a new banner: a
  /// live region speaks only as it appears or changes.
  int _markAllFailures = 0;
  int _loadMoreFailures = 0;

  /// Whether the last refresh over the rows failed, until one succeeds.
  bool _refreshFailed = false;

  /// What a row opened, until it completes or this page's route is the top
  /// one again: a second open meanwhile does nothing.
  Future<void>? _opening;

  /// Whether another route was over this page's when it was last asked.
  bool _covered = false;

  /// Around the refresh banner, to tell whether its Try again has focus as
  /// the banner goes.
  final FocusNode _refreshBanner = FocusNode(
    debugLabel: 'Refresh banner',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Around each row, by notification id, so that focus can be handed to a
  /// row once it is built, and on from a row whose Mark read has gone.
  late final NotificationRowFocus _rows = NotificationRowFocus(
    heading: _heading,
    order: () => [
      for (final item in context.read<NotificationListBloc>().state.items)
        item.id,
    ],
  );

  /// How many rows were loaded when the running Load more started: the
  /// index of the first row it adds.
  int _shownBeforeMore = 0;

  /// Re-reads the list when the app comes back to the foreground (#475).
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // The count refreshes on resume in its own host; the list is this
    // page's.
    _lifecycle = AppLifecycleListener(
      onResume: () => context.read<NotificationListBloc>().add(
        const NotificationListRefreshRequested(),
      ),
    );
    _refreshCount();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    // The top route again: what a row opened has gone, however it went. A
    // pop completes its future, but a page the router took away, as the
    // browser's Back or a `go` does, may never complete it, and waiting on
    // that alone would leave every row unable to open again.
    if (_covered && current) _opening = null;
    _covered = !current;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _heading.dispose();
    _markAll.dispose();
    _loadMore.dispose();
    _markAllDismiss.dispose();
    _loadMoreDismiss.dispose();
    _refreshBanner.dispose();
    _rows.dispose();
    super.dispose();
  }

  void _refreshCount() {
    final count = _countOf(context);
    if (count != null && !count.isClosed) unawaited(count.refresh());
  }

  /// Reads the first page again, and the count with it (#475).
  void _refresh() {
    _refreshCount();
    context.read<NotificationListBloc>().add(
      const NotificationListRefreshRequested(),
    );
  }

  /// A pull's refresh: completes once the pass it starts has ended, so the
  /// spinner holds until then, and never with an error, which would escape
  /// uncaught.
  Future<void> _pull() {
    final bloc = context.read<NotificationListBloc>();
    var started = _reading(bloc.state);
    final ended = bloc.stream.firstWhere((state) {
      if (_reading(state)) {
        started = true;
        return false;
      }
      return started;
    });
    _refresh();
    // The page may close first, which ends the stream with nothing found.
    return ended.then((_) {}, onError: (Object _) {});
  }

  /// Whether the first page is being read, from nothing or over the rows.
  static bool _reading(NotificationListState state) =>
      state.refreshing || state.status == NotificationListStatus.loading;

  void _retry() {
    // Try again goes as the load starts, and would take focus with it.
    _heading.requestFocus();
    context.read<NotificationListBloc>().add(
      const NotificationListLoadRequested(),
    );
  }

  /// Marks [notification] read and opens [target], unless what a row opened
  /// earlier is still open.
  Future<void> _open(
    UserNotification notification,
    NotificationTarget target,
  ) async {
    if (_opening != null) return;
    context.read<NotificationListBloc>().add(
      NotificationListOpened(notification.id),
    );
    final opening = _opening = widget.onOpen(context, target);
    try {
      await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  void _markRead(UserNotification notification) => context
      .read<NotificationListBloc>()
      .add(NotificationListOpened(notification.id));

  /// Whether a Load more that was running has answered.
  static bool _loadMoreAnswered(
    NotificationListState previous,
    NotificationListState current,
  ) => previous.loadingMore && !current.loadingMore;

  /// Whether a read of the first page has replaced the rows and the cursor:
  /// a load starting, or a refresh that worked.
  static bool _listingReplaced(
    NotificationListState previous,
    NotificationListState current,
  ) =>
      (current.status == NotificationListStatus.loading &&
          previous.status != NotificationListStatus.loading) ||
      (previous.refreshing &&
          !current.refreshing &&
          current.outcome is! RefreshFailed);

  void _onMarkAllFailed(MarkAllFailed outcome) {
    setState(() {
      _markAllFailure = outcome;
      _markAllFailures++;
    });
    _keepInView(_markAll);
  }

  void _onLoadMoreAnswered(BuildContext context, NotificationListState state) {
    final outcome = state.outcome;
    if (outcome is LoadMoreFailed) {
      setState(() {
        _loadMoreFailure = outcome;
        _loadMoreFailures++;
      });
      _keepInView(_loadMore);
      return;
    }
    if (_loadMoreFailure != null) setState(() => _loadMoreFailure = null);
    // The last page has come: Load more goes in the next frame.
    if (!state.hasMore && _loadMore.hasFocus) _handOffFromLoadMore(state);
  }

  /// Hands focus from Load more, which the next frame takes away, to the
  /// first row it added once that frame has built it, or to the title when
  /// it added none or that row takes no focus. Not if the user has moved
  /// focus meanwhile.
  void _handOffFromLoadMore(NotificationListState state) {
    final first = _shownBeforeMore < state.items.length
        ? state.items[_shownBeforeMore].id
        : null;
    final focused = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !focusIsFree(context, untouched: focused)) return;
        final row = first == null ? null : _rows.firstIn(first);
        if (row == null) {
          _heading.requestFocus();
          return;
        }
        row.requestFocus();
        row.context?.findRenderObject()?.showOnScreen();
      })
      // A post-frame callback does not ask for a frame.
      ..ensureVisualUpdate();
  }

  /// The banner takes room from the foot of the view as it arrives, which
  /// may cover the control under [group] that keeps focus: it is brought
  /// back into view, as Tab would, for a user who can see focus.
  void _keepInView(FocusNode group) {
    if (!group.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !group.hasFocus ||
          FocusManager.instance.highlightMode !=
              FocusHighlightMode.traditional) {
        return;
      }
      FocusManager.instance.primaryFocus?.context
          ?.findRenderObject()
          ?.showOnScreen();
    });
  }

  void _dismissMarkAllFailure() {
    // Dismiss goes with the banner, and would take focus with it.
    if (_markAllDismiss.hasFocus) _focusIn(_markAll);
    setState(() => _markAllFailure = null);
  }

  void _dismissLoadMoreFailure() {
    if (_loadMoreDismiss.hasFocus) _focusIn(_loadMore);
    setState(() => _loadMoreFailure = null);
  }

  /// The rows and the cursor Load more failed on have gone, and with a load,
  /// the rows Mark all read failed on; a refresh banner no longer applies.
  void _clearOnNewListing(NotificationListState state) => setState(() {
    _loadMoreFailure = null;
    _refreshFailed = false;
    if (state.status == NotificationListStatus.loading) {
      _markAllFailure = null;
    }
  });

  /// Focuses the control under [group], or the title when it isn't built.
  void _focusIn(FocusNode group) =>
      (group.traversalDescendants.firstOrNull ?? _heading).requestFocus();

  @override
  Widget build(BuildContext context) => NotificationsMarkAllAnswers(
    showingFailure: () => _markAllFailure != null,
    unread: (state) => state.hasUnread,
    button: _markAll,
    heading: _heading,
    onFailed: _onMarkAllFailed,
    onRetired: () => setState(() => _markAllFailure = null),
    child: MultiBlocListener(
      listeners: [
        BlocListener<NotificationListBloc, NotificationListState>(
          listenWhen: (previous, current) =>
              !previous.loadingMore && current.loadingMore,
          listener: (context, state) => _shownBeforeMore = state.items.length,
        ),
        BlocListener<NotificationListBloc, NotificationListState>(
          listenWhen: _loadMoreAnswered,
          listener: _onLoadMoreAnswered,
        ),
        BlocListener<NotificationListBloc, NotificationListState>(
          // The rows and the cursor Load more failed on have gone, and with a
          // load, the rows Mark all read failed on.
          listenWhen: _listingReplaced,
          listener: (context, state) {
            // The refresh banner goes in the next frame, and would take focus
            // on its Try again with it.
            if (_refreshFailed && _refreshBanner.hasFocus) {
              _heading.requestFocus();
            }
            _clearOnNewListing(state);
          },
        ),
        BlocListener<NotificationListBloc, NotificationListState>(
          listenWhen: (previous, current) =>
              current.outcome is RefreshFailed &&
              current.outcome != previous.outcome,
          listener: (context, state) => setState(() => _refreshFailed = true),
        ),
      ],
      child: BlocBuilder<NotificationListBloc, NotificationListState>(
        builder: _page,
      ),
    ),
  );

  Widget _page(BuildContext context, NotificationListState state) {
    final l10n = NotificationsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final loaded = state.status == NotificationListStatus.loaded;
    final items = state.items;
    final inset = tokens.spaceLg;

    return BgePage.slivers(
      title: Focus(focusNode: _heading, child: Text(l10n.notificationsTitle)),
      // Rows of a title and its facts: the list measure.
      width: BgePageWidth.pane,
      // What the list holds now, grown as pages arrive. Not known until the
      // first page has answered.
      semanticChildCount: loaded ? items.length : null,
      onRefresh: _pull,
      // A refresh that failed over the rows answers the whole list, so it
      // sits above it, in the header, which stays in the semantics tree
      // however far down the reader is. Passed on every build, so the page
      // keeps one shape as it comes and goes.
      header: loaded && _refreshFailed
          ? Focus(
              focusNode: _refreshBanner,
              includeSemantics: false,
              child: BgeRefreshBanner(
                key: NotificationsScreen.refreshFailedKey,
                retryKey: NotificationsScreen.refreshRetryKey,
                failedMessage: l10n.notificationsRefreshFailed,
                inProgressLabel: l10n.notificationsRefreshing,
                retryLabel: l10n.notificationsRetry,
                refreshing: state.refreshing,
                onRetry: _refresh,
              ),
            )
          : const SizedBox.shrink(),
      // The bottom inset ends the content and the footer's banners instead.
      // The page would put it around the footer, which would then be a band
      // with nothing in it.
      padding: EdgeInsets.fromLTRB(inset, inset, inset, 0),
      // What Mark all read and Load more answered: actions on a long list,
      // so the answer is always built and on screen, wherever the user is
      // (STYLE_GUIDE, "Error and outcome surfaces"). On every build, in
      // every state: the page builds a different tree with a footer than
      // without one, so a footer that came and went would lose the scroll
      // position and focus.
      footer: _Outcomes(
        markAll: _markAllFailure,
        markAllFailures: _markAllFailures,
        markAllDismiss: _markAllDismiss,
        onDismissMarkAll: _dismissMarkAllFailure,
        loadMore: _loadMoreFailure,
        loadMoreFailures: _loadMoreFailures,
        loadMoreDismiss: _loadMoreDismiss,
        onDismissLoadMore: _dismissLoadMoreFailure,
      ),
      actions: [
        BgeRefreshButton(
          buttonKey: NotificationsScreen.refreshKey,
          label: l10n.notificationsRefresh,
          inProgressLabel: l10n.notificationsRefreshing,
          // From any state: on the spinner the label is what says a press
          // was taken.
          refreshing: _reading(state),
          onPressed: _refresh,
        ),
      ],
      slivers: [
        // Above the list at every width, so a resize never moves it between
        // the header and the page while it has focus.
        if (loaded && (state.hasUnread || state.markingAll))
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: tokens.spaceSm),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Focus(
                  focusNode: _markAll,
                  includeSemantics: false,
                  child: NotificationsMarkAllReadButton(
                    key: NotificationsScreen.markAllKey,
                    markingAll: state.markingAll,
                    onPressed: () => context.read<NotificationListBloc>().add(
                      const NotificationListAllMarkedRead(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        switch (state.status) {
          NotificationListStatus.loading => BgeStateSliver(
            child: BgeLoadingState(
              key: NotificationsScreen.loadingKey,
              label: l10n.notificationsLoading,
            ),
          ),
          NotificationListStatus.loadFailed => BgeStateSliver(
            child: NotificationsLoadFailed(
              key: NotificationsScreen.failedKey,
              failure: state.failure,
              onRetry: _retry,
            ),
          ),
          // With more to load, Load more follows the words, so the state
          // takes only its own room rather than the rest of the page.
          NotificationListStatus.loaded when items.isEmpty && state.hasMore =>
            const SliverToBoxAdapter(
              child: NotificationsEmptyState(key: NotificationsScreen.emptyKey),
            ),
          NotificationListStatus.loaded when items.isEmpty =>
            const BgeStateSliver(
              child: NotificationsEmptyState(key: NotificationsScreen.emptyKey),
            ),
          NotificationListStatus.loaded => BgeKeyedSliverList<UserNotification>(
            items: items,
            keyOf: (item) => NotificationsScreen.rowKey(item.id),
            itemBuilder: (context, item) => BgeOutlinedRow(
              child: NotificationRow(
                notification: item,
                focus: _rows,
                onOpen: (target) => unawaited(_open(item, target)),
                onMarkRead: () => _markRead(item),
              ),
            ),
          ),
        },
        if (loaded && state.hasMore)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: tokens.spaceMd, bottom: inset),
              child: Center(
                child: Focus(
                  focusNode: _loadMore,
                  includeSemantics: false,
                  child: _LoadMore(state: state),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Loads the next page. Busy, it stays enabled and keeps focus, and its
/// name says it is loading (STYLE_GUIDE §5).
class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.state});

  final NotificationListState state;

  @override
  Widget build(BuildContext context) {
    final l10n = NotificationsLocalizations.of(context);
    final label = state.loadingMore
        ? l10n.notificationsLoadingMore
        : l10n.notificationsLoadMore;

    return BgeInertButton(
      key: NotificationsScreen.loadMoreKey,
      inert: state.loadingMore || state.refreshing,
      label: label,
      onPressed: () => context.read<NotificationListBloc>().add(
        const NotificationListMoreRequested(),
      ),
      builder: (context, focusNode, onPressed) => OutlinedButton(
        focusNode: focusNode,
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// What the last Mark all read and the last Load more answered, while each
/// failed and still applies, for the page's footer: one banner each, with
/// its own Dismiss.
///
/// Renders nothing while neither has anything to report. To leave no band
/// then, it pads itself only while it shows a banner, and the page gives it
/// no bottom inset of its own.
class _Outcomes extends StatelessWidget {
  const _Outcomes({
    required this.markAll,
    required this.markAllFailures,
    required this.markAllDismiss,
    required this.onDismissMarkAll,
    required this.loadMore,
    required this.loadMoreFailures,
    required this.loadMoreDismiss,
    required this.onDismissLoadMore,
  });

  final MarkAllFailed? markAll;

  /// How many times Mark all read has failed: each is a new banner.
  final int markAllFailures;
  final FocusNode markAllDismiss;
  final VoidCallback onDismissMarkAll;

  final LoadMoreFailed? loadMore;

  /// How many times Load more has failed: each is a new banner.
  final int loadMoreFailures;
  final FocusNode loadMoreDismiss;
  final VoidCallback onDismissLoadMore;

  @override
  Widget build(BuildContext context) {
    final markAll = this.markAll;
    final loadMore = this.loadMore;
    if (markAll == null && loadMore == null) return const SizedBox.shrink();
    final l10n = NotificationsLocalizations.of(context);
    final tokens = BgeTokens.of(context);

    Widget banner({
      required Key key,
      required String message,
      required FocusNode dismiss,
      required VoidCallback onDismiss,
    }) => BgeInlineBanner(
      key: key,
      tone: BgeBannerTone.error,
      message: message,
      action: TextButton(
        focusNode: dismiss,
        onPressed: onDismiss,
        child: Text(l10n.notificationsDismiss),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(top: tokens.spaceSm, bottom: tokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spaceSm,
        children: [
          if (markAll != null)
            KeyedSubtree(
              key: ValueKey('mark all $markAllFailures'),
              child: banner(
                key: NotificationsScreen.markAllFailedKey,
                message: markAll.failure == NotificationListFailure.transient
                    ? l10n.notificationsMarkAllFailedOffline
                    : l10n.notificationsMarkAllRefused,
                dismiss: markAllDismiss,
                onDismiss: onDismissMarkAll,
              ),
            ),
          if (loadMore != null)
            KeyedSubtree(
              key: ValueKey('load more $loadMoreFailures'),
              child: banner(
                key: NotificationsScreen.loadMoreFailedKey,
                message: loadMore.failure == NotificationListFailure.transient
                    ? l10n.notificationsLoadMoreFailedOffline
                    : l10n.notificationsLoadMoreRefused,
                dismiss: loadMoreDismiss,
                onDismiss: onDismissLoadMore,
              ),
            ),
        ],
      ),
    );
  }
}
