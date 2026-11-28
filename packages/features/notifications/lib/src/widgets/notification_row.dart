import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/notification_target.dart';
import 'package:notifications/src/presentation/present_notification.dart';
import 'package:notifications/src/widgets/notification_tile.dart';
import 'package:ui/ui.dart';

/// The rows of a surface that lists notifications, the page's or the bell's
/// preview's, as focus sees them (#475): a group around each row, by
/// notification id, and where focus goes when the control that had it
/// leaves its row.
///
/// A plain row's "Mark read" goes as the row turns read, and the row has
/// nothing else that takes focus, so the keyboard's focus would fall to the
/// route's scope, and the user's place with it (STYLE_GUIDE §5). So a Mark
/// read pressed with focus in its row hands focus on once the frame that
/// takes the button away is built:
///
/// 1. to the row itself, if it now takes focus;
/// 2. else to the first control in a row after it, the next a Tab would
///    reach in the list, if one is built;
/// 3. else to [heading].
///
/// Not if the user has moved focus meanwhile. A press with a pointer, which
/// gives the button no focus, moves none.
class NotificationRowFocus {
  NotificationRowFocus({required this.heading, required this.order});

  /// Where focus waits when no row after has a control for it.
  final FocusNode heading;

  /// The ids of the rows shown now, top to bottom.
  final List<String> Function() order;

  final Map<String, FocusNode> _rows = {};

  /// The row whose Mark read was pressed with focus in it, until it turns
  /// read.
  String? _leaving;

  /// The control that had focus as it was pressed.
  FocusNode? _left;

  /// The group around row [id]. It takes no focus itself.
  FocusNode of(String id) => _rows[id] ??= FocusNode(
    debugLabel: 'Notification $id',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The first control in row [id] that takes focus, if the row is built
  /// and has one.
  FocusNode? firstIn(String id) => _rows[id]?.traversalDescendants.firstOrNull;

  void dispose() {
    for (final node in _rows.values) {
      node.dispose();
    }
    _rows.clear();
  }

  void _markReadPressed(String id) {
    if (!(_rows[id]?.hasFocus ?? false)) return;
    _leaving = id;
    _left = FocusManager.instance.primaryFocus;
  }

  /// Row [id], built from [context], has turned read in the frame being
  /// built, which takes its Mark read away.
  void _turnedRead(BuildContext context, String id) {
    if (_leaving != id) return;
    final left = _left;
    _leaving = null;
    _left = null;
    // Once the frame has taken the button away: focus is on nothing then,
    // and a request made there wins over Flutter's own fall-back, which
    // lands after it.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!context.mounted || !focusIsFree(context, untouched: left)) return;
        final ids = order();
        final at = ids.indexOf(id);
        final after = at < 0
            ? null
            : ids.skip(at + 1).map(firstIn).nonNulls.firstOrNull;
        (firstIn(id) ?? after ?? heading)
          ..requestFocus()
          ..context?.findRenderObject()?.showOnScreen();
      })
      // A post-frame callback does not ask for a frame.
      ..ensureVisualUpdate();
  }
}

/// One notification's row, on the page and in the bell's preview (#475):
/// its [NotificationTile], worded by [presentNotification], in the group
/// [focus] holds for it.
///
/// A tap on a row with somewhere to go gives [onOpen] its target. A plain
/// row's "Mark read" runs [onMarkRead], and hands focus on as it goes: see
/// [NotificationRowFocus]. [quoteMaxLines] and [offersCopy] are the tile's.
///
/// It draws no outline: the page puts it in a `BgeOutlinedRow`, and the
/// preview leaves it plain.
class NotificationRow extends StatefulWidget {
  const NotificationRow({
    required this.notification,
    required this.focus,
    required this.onOpen,
    required this.onMarkRead,
    this.quoteMaxLines,
    this.offersCopy = false,
    super.key,
  });

  final UserNotification notification;
  final NotificationRowFocus focus;
  final ValueChanged<NotificationTarget> onOpen;
  final VoidCallback onMarkRead;
  final int? quoteMaxLines;
  final bool offersCopy;

  @override
  State<NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends State<NotificationRow> {
  @override
  void didUpdateWidget(NotificationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.notification.read && widget.notification.read) {
      widget.focus._turnedRead(context, widget.notification.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notification = widget.notification;
    final presentation = presentNotification(
      NotificationsLocalizations.of(context),
      notification,
    );
    final target = presentation.target;
    return Focus(
      focusNode: widget.focus.of(notification.id),
      includeSemantics: false,
      child: NotificationTile(
        presentation: presentation,
        read: notification.read,
        createdAt: notification.createdAt,
        // A plain row never runs it: the tile offers no tap.
        onOpen: target == null ? () {} : () => widget.onOpen(target),
        onMarkRead: () {
          widget.focus._markReadPressed(notification.id);
          widget.onMarkRead();
        },
        quoteMaxLines: widget.quoteMaxLines,
        offersCopy: widget.offersCopy,
      ),
    );
  }
}
