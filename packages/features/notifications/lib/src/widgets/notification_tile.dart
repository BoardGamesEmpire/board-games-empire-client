import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// A quote that is an error, a DataGateway's upstream error (#545), gets a
/// "Copy error" button under the row where [offersCopy] is set, as on the
/// page. On a touch platform the app leaves text unselectable (#322), so
/// the button is how it is copied there; on a pointer platform it copies
/// the whole error, where a drag might take part of it.
///
/// An unread row's title is bold, and a screen reader hears "Unread" before
/// it. The title, detail, quote and date are one semantics node, with the
/// tap on it; each button under it is a node of its own after it.
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
    this.offersCopy = false,
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

  /// Whether a quote that is an error gets a "Copy error" button, as on the
  /// page. The bell's preview, a glance, leaves it out.
  final bool offersCopy;

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
    final copy = offersCopy && presentation.quoteIsError ? quote : null;
    final marksRead = !opens && !read;
    if (copy == null && !marksRead) {
      return tile;
    }
    // Marking read is a direct write, so offline the button is disabled and
    // says why (STYLE_GUIDE "Online-only controls"). Opening a row is not a
    // write, and still works offline; nor is copying.
    final offline = marksRead && BgeConnectivityScope.offlineOf(context);
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
              if (copy != null) _CopyErrorButton(copy),
              if (marksRead)
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

/// Copies an error the server sent, as it came, to the clipboard.
///
/// The clipboard is a round trip to the platform, so the button can look
/// idle and be pressed again: each press copies, and only the newest answer
/// is said, in a SnackBar that replaces the last. The SnackBar is the whole
/// confirmation, since it is a live region already. Never disabled, so it
/// keeps focus through its own press. As on the API key's Copy
/// (`SecretPanel`).
class _CopyErrorButton extends StatefulWidget {
  const _CopyErrorButton(this.error);

  final String error;

  @override
  State<_CopyErrorButton> createState() => _CopyErrorButtonState();
}

class _CopyErrorButtonState extends State<_CopyErrorButton> {
  /// Counts copies, so an answer that a later press has overtaken says
  /// nothing.
  int _copyToken = 0;

  Future<void> _copy(NotificationsLocalizations l10n) async {
    // Claimed before the await: presses are not serialised, and the platform
    // need not answer them in order.
    final token = ++_copyToken;
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: widget.error));
      copied = true;
    } on Object {
      // Not rethrown: the press discards this future, so an error escaping
      // it would raise the app's crash prompt over a failed copy.
    }
    if (!mounted || token != _copyToken) return;
    ScaffoldMessenger.of(context).replaceSnackBar(
      copied ? l10n.notificationErrorCopied : l10n.notificationErrorCopyFailed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = NotificationsLocalizations.of(context);
    return TextButton.icon(
      onPressed: () => unawaited(_copy(l10n)),
      icon: const Icon(Icons.copy_outlined),
      // TextButton.icon puts the label in a Flexible, so it wraps.
      label: Text(l10n.notificationCopyError),
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
/// row's tap there, and add a Tab stop with no ring. An error is copied on
/// any platform with the "Copy error" button under the row, on the page.
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
