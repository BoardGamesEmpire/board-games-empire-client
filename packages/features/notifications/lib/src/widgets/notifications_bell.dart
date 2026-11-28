import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/count/notification_count_cubit.dart';
import 'package:notifications/src/count/notification_count_state.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The bell in a top-level screen's header, with how many notifications are
/// unread (#475). Reads the [NotificationCountCubit] above it.
///
/// The badge shows the count from 1 to 99, and `99+` above that, so it stays
/// narrow; at zero, and until the count is known, there is none. The
/// button's name always says the real number: "Notifications, 250 unread"
/// while the badge shows `99+`, and plain "Notifications" with nothing
/// unread.
///
/// A standard 48dp icon button: the badge is drawn over it, takes no width
/// of its own and stays inside the button, so a header's budget for the bell
/// is the button's.
class NotificationsBell extends StatelessWidget {
  const NotificationsBell({required this.onPressed, super.key});

  /// Finds the button.
  static const Key buttonKey = Key('notifications_bell.button');

  /// Opens the preview of the latest notifications.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = NotificationsLocalizations.of(context);

    return BlocBuilder<NotificationCountCubit, NotificationCountState>(
      buildWhen: (previous, current) => previous.unread != current.unread,
      builder: (context, state) {
        final unread = state.unread ?? 0;
        // The tooltip stays out of the semantics tree: the button is named
        // by its label alone, which carries the count, so a screen reader
        // reads the name once rather than the label and the tooltip both.
        return Tooltip(
          message: l10n.notificationsBellTooltip,
          excludeFromSemantics: true,
          child: IconButton(
            key: buttonKey,
            onPressed: onPressed,
            icon: _BadgedBell(
              unread: unread,
              semanticLabel: l10n.notificationsBellLabel(unread),
            ),
          ),
        );
      },
    );
  }
}

/// The bell icon, with the badge over its top end corner.
///
/// The badge is anchored by its end and grows toward the start, so a longer
/// count never reaches past the button's end, where the bell sits at the
/// window's edge. At large text it scales down to the button's width rather
/// than reaching outside it: the button's name carries the count in full.
class _BadgedBell extends StatelessWidget {
  const _BadgedBell({required this.unread, required this.semanticLabel});

  final int unread;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = BgeTokens.of(context);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          unread > 0 ? Icons.notifications : Icons.notifications_none_outlined,
          semanticLabel: semanticLabel,
        ),
        // The icon sits in the button with room around it; the badge may use
        // part of that room, and keeps the rest clear of the button's edge.
        PositionedDirectional(
          top: -tokens.spaceXs,
          start: -tokens.spaceSm,
          end: -tokens.spaceSm,
          child: Align(
            alignment: AlignmentDirectional.topEnd,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.topEnd,
              child: Badge(
                isLabelVisible: unread > 0,
                // Ember, the accent kept for badges; error is for failures.
                backgroundColor: scheme.tertiary,
                textColor: scheme.onTertiary,
                // The name says the number; the badge would say it again.
                label: ExcludeSemantics(child: Text(unreadBadgeText(unread))),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
