import 'package:flutter/material.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/notification_presentation.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One notification, on the Notifications page and in the bell's preview
/// (#475): its icon, its title, a line of detail and a quote, the server's
/// own words, when it has them, and when it arrived.
///
/// A row whose presentation has a target is one tap target, and a tap runs
/// [onOpen], online or not. A plain row opens nothing: while unread it offers
/// a "Mark read" button under it, which runs [onMarkRead], and once read it
/// offers nothing. Marking read is a direct write: offline the button is
/// disabled and says why.
///
/// An unread row's title is bold, and a screen reader hears "Unread" before
/// it. The title, detail, quote and date are one semantics node, with the
/// tap on it; the "Mark read" button is a node of its own after it.
/// Every line wraps, so nothing is cut at 320dp and 200% text.
///
/// The row draws no outline: the page puts it in a `BgeOutlinedRow`, and
/// the preview, a pop-up, leaves it plain.
class NotificationTile extends StatelessWidget {
  const NotificationTile({
    required this.presentation,
    required this.read,
    required this.createdAt,
    required this.onOpen,
    this.onMarkRead,
    this.quoteMaxLines,
    super.key,
  });

  final NotificationPresentation presentation;

  /// Whether the user has read the notification.
  final bool read;

  /// When the notification arrived. Shown in the device's time zone.
  final DateTime createdAt;

  /// Opens what the notification is about. Runs only for a row with a
  /// target.
  final VoidCallback onOpen;

  /// Marks a plain row read. Null disables its "Mark read" button.
  final VoidCallback? onMarkRead;

  /// The most lines the quote takes, cut with an ellipsis, as in the
  /// preview. Null shows all of it, as on the page.
  final int? quoteMaxLines;

  @override
  Widget build(BuildContext context) {
    final l10n = NotificationsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final detail = presentation.detail;
    final quote = presentation.quote;
    final opens = presentation.target != null;
    final local = createdAt.toLocal();

    final title = Text(
      presentation.title,
      style: read ? null : const TextStyle(fontWeight: FontWeight.bold),
    );

    // MergeSemantics outside the ring, so the tap and every line are one
    // node, as on the other list rows.
    final tile = MergeSemantics(
      child: BgeRowFocusRing(
        builder: (context, row) => ListTile(
          focusNode: row.focusNode,
          onFocusChange: row.onFocusChange,
          focusColor: row.focusColor,
          onTap: row.onTap(opens ? onOpen : null),
          leading: Icon(presentation.icon),
          title: read
              ? title
              : Semantics(label: l10n.notificationUnreadLabel, child: title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (detail != null) Text(detail),
              if (quote != null) _Quote(quote, maxLines: quoteMaxLines),
              Text(l10n.notificationReceivedAt(local, local)),
            ],
          ),
        ),
      ),
    );

    final padding = EdgeInsetsDirectional.only(
      start: tokens.spaceMd,
      end: tokens.spaceMd,
      bottom: tokens.spaceSm,
    );
    if (opens || read) {
      return tile;
    }
    // Marking read is a direct write, so offline the button is disabled and
    // says why (STYLE_GUIDE "Online-only controls"). Opening a row is not a
    // write, and still works offline.
    final offline = BgeConnectivityScope.offlineOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              BgeOnlineOnly(
                showNote: false,
                child: TextButton(
                  onPressed: offline ? null : onMarkRead,
                  child: Text(l10n.notificationMarkRead),
                ),
              ),
              if (offline) const BgeOnlineOnlyNote(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Text the server wrote, as it came.
///
/// Cut to [maxLines] where it is given; otherwise all of it. On a pointer
/// platform the app-wide selection region lets a user copy it, say an error
/// message to look up or report, while a tap on it still opens the row. It
/// takes no selection region of its own: that would make it selectable on
/// touch platforms, where the app leaves text unselectable (#322), take the
/// row's tap there, and add a Tab stop with no ring.
class _Quote extends StatelessWidget {
  const _Quote(this.quote, {required this.maxLines});

  final String quote;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final lines = maxLines;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Text(
      quote,
      style: style,
      maxLines: lines,
      overflow: lines == null ? null : TextOverflow.ellipsis,
    );
  }
}
