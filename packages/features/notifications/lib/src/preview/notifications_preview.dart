import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/count/notification_count_cubit.dart';
import 'package:notifications/src/count/notification_count_state.dart';
import 'package:notifications/src/list/notification_list_bloc.dart';
import 'package:notifications/src/list/notification_list_event.dart';
import 'package:notifications/src/list/notification_list_state.dart';
import 'package:notifications/src/presentation/notification_target.dart';
import 'package:notifications/src/widgets/notification_list_parts.dart';
import 'package:notifications/src/widgets/notification_row.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens the bell's preview over the page (#475): the
/// [NotificationsPreview.pageSize] latest notifications, read or not, with
/// "Mark all read" while one of them is unread, and "See all" for the
/// Notifications page.
///
/// It is [showBgePopup]'s: a sheet on a phone and a dialog on a wider window,
/// on the root navigator, named "Notifications". On the root navigator it is
/// above whatever the shell provides to its pages, so the unread [count] is
/// given here rather than read from [context]. The count is read again as the
/// preview opens, and hears of each notification the preview marks read,
/// whether the server answers before the preview has gone or after.
///
/// It reads the latest page once, as it opens, and stores nothing. A read
/// that fails takes the rows' place, with Try again; "See all" stays, as it
/// does in every state. A Mark all read that fails says so in a banner under
/// the button, and the rows it marked show unread again.
///
/// ## Opening a page from it
///
/// A row with somewhere to go marks its notification read and gives
/// [onOpen] its target, with the preview's own context, which is there for
/// as long as the row can be tapped. "See all" calls [onSeeAll], which opens
/// the Notifications page. A plain row opens nothing: its "Mark read" marks
/// it read, and goes, so one pressed from the keyboard hands focus on to the
/// next row with a control, or else to the heading
/// ([NotificationRowFocus]).
///
/// Neither closes the preview. The page each opens removes it once the page
/// has arrived ([BgeRemoveWhenCovered]), so Back from that page lands on the
/// screen the preview was opened over, with no preview. Under the app's
/// navigation shell the page arrives beneath the preview, which goes once it
/// has (see `showBgePopup`).
///
/// So each opens its page once, however often a row or "See all" is pressed
/// while the page arrives ([BgeRemoveWhenCovered.openPage]): a later press
/// opens nothing and marks nothing read. A page that leaves before it has
/// arrived leaves the preview as it was, ready to open a page again.
///
/// Both must open a page: until one arrives or leaves, nothing else in the
/// preview opens one. [onOpen]'s future isn't waited on, and it must not
/// throw.
Future<void> showNotificationsPreview(
  BuildContext context, {
  required NotificationRemoteDataSource remote,
  required NotificationCountCubit count,
  required Future<void> Function(
    BuildContext context,
    NotificationTarget target,
  )
  onOpen,
  required VoidCallback onSeeAll,
}) {
  // The session's count may have ended under the bell.
  if (!count.isClosed) unawaited(count.refresh());
  return showBgePopup<void>(
    context,
    semanticLabel: NotificationsLocalizations.of(
      context,
    ).notificationsPreviewTitle,
    // The route, which is the guard [BgeRemoveWhenCovered.openPage] holds
    // and what says the preview has gone, is the same on every run of this
    // builder. The app's router runs it again on each push.
    builder: (popup) => _NotificationsPreview(
      key: NotificationsPreview.contentKey,
      route: ModalRoute.of(popup),
      remote: remote,
      count: count,
      onOpen: onOpen,
      onSeeAll: onSeeAll,
    ),
  );
}

/// The size and the keys of the preview [showNotificationsPreview] opens
/// (#475).
abstract final class NotificationsPreview {
  /// How many of the latest notifications it shows.
  static const int pageSize = 5;

  /// On the preview's content, inside the pop-up.
  static const Key contentKey = Key('notifications_preview');

  static const Key loadingKey = Key('notifications_preview.loading');
  static const Key emptyKey = Key('notifications_preview.empty');
  static const Key failedKey = Key('notifications_preview.failed');

  /// On "Mark all read".
  static const Key markAllKey = Key('notifications_preview.mark_all');

  /// On the banner under "Mark all read" after it failed.
  static const Key markAllFailedKey = Key(
    'notifications_preview.mark_all_failed',
  );

  /// On "See all", pinned at the foot.
  static const Key seeAllKey = Key('notifications_preview.see_all');

  /// The row of the notification [id].
  static Key rowKey(String id) => ValueKey('notifications_preview.row.$id');
}

/// The preview's content: its own [NotificationListBloc] over the latest
/// page, under a heading, with "See all" pinned under the scroll view.
///
/// One element for the pop-up's life, across a change of form, so what it
/// holds stays: the rows, a banner, and the focus.
class _NotificationsPreview extends StatefulWidget {
  const _NotificationsPreview({
    required this.route,
    required this.remote,
    required this.count,
    required this.onOpen,
    required this.onSeeAll,
    super.key,
  });

  /// The pop-up's route.
  final ModalRoute<Object?>? route;
  final NotificationRemoteDataSource remote;
  final NotificationCountCubit count;
  final Future<void> Function(BuildContext context, NotificationTarget target)
  onOpen;
  final VoidCallback onSeeAll;

  @override
  State<_NotificationsPreview> createState() => _NotificationsPreviewState();
}

class _NotificationsPreviewState extends State<_NotificationsPreview> {
  late final NotificationListBloc _bloc;

  /// Whether [_bloc] has been asked to close: from then on nothing is added
  /// to it. Its own `isClosed` turns only once the close has run.
  bool _closing = false;

  /// On the heading, which takes focus only when sent there: it is no Tab
  /// stop. Where focus waits when the control that had it goes: Try again
  /// as the read starts, Mark all read once nothing is unread, and a row's
  /// Mark read with no row after it to take focus.
  final FocusNode _heading = FocusNode(
    debugLabel: 'Notifications preview heading',
    skipTraversal: true,
  );

  /// Around Mark all read, to tell whether it had focus as it goes.
  final FocusNode _markAll = FocusNode(
    debugLabel: 'Mark all read',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Around each row, by notification id, so that focus can be handed on
  /// from a row whose Mark read has gone.
  late final NotificationRowFocus _rows = NotificationRowFocus(
    heading: _heading,
    order: () => [for (final item in _shown(_bloc.state)) item.id],
  );

  /// What the last Mark all read answered, while it failed and still
  /// applies; null otherwise.
  MarkAllFailed? _markAllFailure;

  /// How many times Mark all read has failed, so that a repeat is a new
  /// banner: a live region speaks only as it appears or changes.
  int _markAllFailures = 0;

  @override
  void initState() {
    super.initState();
    final count = widget.count;
    _bloc = NotificationListBloc(
      widget.remote,
      pageSize: NotificationsPreview.pageSize,
      // The session's count may have gone before an answer came.
      onMarkedRead: (marked) {
        if (!count.isClosed) count.markedRead(marked);
      },
      onAllMarkedRead: () {
        if (!count.isClosed) count.allMarkedRead();
      },
    )..add(const NotificationListLoadRequested());
    // Closed as the pop-up goes, not when it is disposed: a popped pop-up
    // stays mounted through its exit, where a read that answers would still
    // be drawn, and a failure's Try again would take focus. The route says
    // it has gone however it went: popped, removed once a page it opened has
    // arrived, or dropped by a router (#475). A mark-read already sent is
    // still answered, and the count still hears of it.
    unawaited(widget.route?.popped.then((_) => _close()));
  }

  @override
  void dispose() {
    _close();
    _heading.dispose();
    _markAll.dispose();
    _rows.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    unawaited(_bloc.close());
  }

  void _add(NotificationListEvent event) {
    if (!_closing) _bloc.add(event);
  }

  /// Runs [open], which opens a page from the preview, through the pop-up's
  /// guard, so a page on its way is opened once.
  void _openPage(VoidCallback open) {
    switch (widget.route) {
      case final BgeRemoveWhenCovered<dynamic> route:
        route.openPage(open);
      case _:
        open();
    }
  }

  /// Marks [notification] read and opens [target], unless a page the preview
  /// opened is still on its way.
  void _open(UserNotification notification, NotificationTarget target) =>
      _openPage(() {
        _add(NotificationListOpened(notification.id));
        unawaited(widget.onOpen(context, target));
      });

  void _seeAll() => _openPage(widget.onSeeAll);

  void _markRead(UserNotification notification) =>
      _add(NotificationListOpened(notification.id));

  void _markAllRead() => _add(const NotificationListAllMarkedRead());

  void _retry() {
    // Try again goes as the read starts, and would take focus with it.
    _heading.requestFocus();
    _add(const NotificationListLoadRequested());
  }

  /// The rows the preview shows: the first [NotificationsPreview.pageSize]
  /// of the page, should the server send more.
  static List<UserNotification> _shown(NotificationListState state) =>
      state.items.take(NotificationsPreview.pageSize).toList();

  /// Whether a row shown is unread.
  static bool _unreadShown(NotificationListState state) =>
      _shown(state).any((item) => !item.read);

  void _onMarkAllFailed(MarkAllFailed outcome) => setState(() {
    _markAllFailure = outcome;
    _markAllFailures++;
  });

  @override
  Widget build(BuildContext context) => NotificationsMarkAllAnswers(
    bloc: _bloc,
    count: widget.count,
    showingFailure: () => _markAllFailure != null,
    unread: _unreadShown,
    button: _markAll,
    heading: _heading,
    onFailed: _onMarkAllFailed,
    onRetired: () => setState(() => _markAllFailure = null),
    // The count too, so Mark all read comes and goes with it.
    child: BlocBuilder<NotificationCountCubit, NotificationCountState>(
      bloc: widget.count,
      builder: (context, _) =>
          BlocBuilder<NotificationListBloc, NotificationListState>(
            bloc: _bloc,
            builder: _content,
          ),
    ),
  );

  Widget _content(BuildContext context, NotificationListState state) {
    final l10n = NotificationsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final loaded = state.status == NotificationListStatus.loaded;
    final shown = _shown(state);
    final failure = _markAllFailure;
    // The heading and the controls line up with the rows' icons, which the
    // rows inset themselves.
    final inset = EdgeInsets.fromLTRB(
      tokens.spaceMd,
      tokens.spaceSm,
      tokens.spaceMd,
      0,
    );
    final stateInset = EdgeInsets.all(tokens.spaceLg);

    // One tree in every state, so the scroll view keeps its position and
    // the focus stays as the rows arrive (`BgePinnedFooter`).
    return BgePinnedFooter(
      // As tall as its content, which the pop-up is sized to.
      shrinkWrap: true,
      footerPadding: EdgeInsets.symmetric(
        horizontal: tokens.spaceMd,
        vertical: tokens.spaceSm,
      ),
      // A traversal group each, as `BgePage` gives its content and its
      // footer: Tab takes the rows before See all, wherever the body is
      // scrolled to.
      body: FocusTraversalGroup(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            top: tokens.spaceSm,
            bottom: tokens.spaceMd,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            // Each keyed: Mark all read and its banner come and go above
            // the rows, which would otherwise be matched to the slot one of
            // them left, and built again, losing what they hold.
            children: [
              Padding(
                key: const ValueKey('heading'),
                padding: inset,
                child: Focus(
                  focusNode: _heading,
                  // A heading by its level, which is what iOS and Android
                  // read as one, and by its flag elsewhere.
                  child: Semantics(
                    header: true,
                    headingLevel: 2,
                    child: Text(
                      l10n.notificationsPreviewTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
              ),
              // Above the rows, at the end, as on the page.
              if (loaded &&
                  NotificationsMarkAllAnswers.offered(
                    state,
                    unread: _unreadShown,
                    count: widget.count.state,
                  ))
                Padding(
                  key: const ValueKey('mark all'),
                  padding: inset,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Focus(
                      focusNode: _markAll,
                      includeSemantics: false,
                      child: NotificationsMarkAllReadButton(
                        key: NotificationsPreview.markAllKey,
                        markingAll: state.markingAll,
                        onPressed: _markAllRead,
                      ),
                    ),
                  ),
                ),
              // Under the button it answers, where the user pressed: the
              // rows are few, and always built, so it is always heard.
              if (failure != null)
                Padding(
                  key: const ValueKey('mark all failed'),
                  padding: inset,
                  child: KeyedSubtree(
                    key: ValueKey('mark all $_markAllFailures'),
                    child: BgeInlineBanner(
                      key: NotificationsPreview.markAllFailedKey,
                      tone: BgeBannerTone.error,
                      message:
                          failure.failure == NotificationListFailure.transient
                          ? l10n.notificationsMarkAllFailedOffline
                          : l10n.notificationsMarkAllRefused,
                    ),
                  ),
                ),
              Padding(
                key: const ValueKey('rows'),
                padding: EdgeInsets.only(top: tokens.spaceSm),
                child: switch (state.status) {
                  NotificationListStatus.loading => Padding(
                    padding: stateInset,
                    child: Center(
                      child: BgeLoadingState(
                        key: NotificationsPreview.loadingKey,
                        label: l10n.notificationsLoading,
                      ),
                    ),
                  ),
                  NotificationListStatus.loadFailed => Padding(
                    padding: stateInset,
                    child: NotificationsLoadFailed(
                      key: NotificationsPreview.failedKey,
                      failure: state.failure,
                      onRetry: _retry,
                    ),
                  ),
                  NotificationListStatus.loaded when shown.isEmpty => Padding(
                    padding: stateInset,
                    child: const NotificationsEmptyState(
                      key: NotificationsPreview.emptyKey,
                    ),
                  ),
                  NotificationListStatus.loaded => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in shown) _row(item),
                    ],
                  ),
                },
              ),
            ],
          ),
        ),
      ),
      // In every state: the way to the rest, and to the page's own Mark
      // all read, Load more and refresh.
      footer: FocusTraversalGroup(
        child: SingleChildScrollView(
          // Never the route's primary scroll view, which is the body's.
          primary: false,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            // As tall as the button, not as the footer's cap.
            heightFactor: 1,
            child: TextButton(
              key: NotificationsPreview.seeAllKey,
              onPressed: _seeAll,
              child: Text(l10n.notificationsPreviewSeeAll),
            ),
          ),
        ),
      ),
    );
  }

  /// One row, plain, as rows in a pop-up are (STYLE_GUIDE, List surfaces),
  /// with its quote cut to two lines: the preview is a glance.
  Widget _row(UserNotification item) => KeyedSubtree(
    key: NotificationsPreview.rowKey(item.id),
    child: NotificationRow(
      notification: item,
      focus: _rows,
      onOpen: (target) => _open(item, target),
      onMarkRead: () => _markRead(item),
      quoteMaxLines: 2,
    ),
  );
}
