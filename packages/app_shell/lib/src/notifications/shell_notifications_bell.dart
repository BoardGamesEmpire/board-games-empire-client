import 'dart:async';

import 'package:app_shell/src/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:network_interface/network_interface.dart';
import 'package:notifications/notifications.dart';
import 'package:ui/ui.dart' show BgeNavigationMenu;

/// The notifications bell for a top-level screen's header (#475): Home,
/// Collection, Games and Events each put it at the end of theirs.
///
/// Only where the screen is a section's top, the page that shows the menu
/// button rather than a way back ([BgeNavigationMenu.isSectionTop]): the
/// first page on the shell's navigator, which picking a destination goes to,
/// and where the browser owns Back, the screen wherever its history stacked
/// it. The same screen pushed over another page on a phone, as Collection's
/// empty state pushes Games, has a back button and its own actions in the
/// header, and no room for the bell, so it draws nothing there.
///
/// It shows the session's unread count, which `BgeApp` keeps above the
/// navigation shell, and draws nothing while there is none, as while one
/// session hands over to the next. A page kept across that change shows the
/// next session's count, never the last one's.
///
/// Pressed, it opens the preview over the page. The preview is on the root
/// navigator, above what the shell provides, so it is given the count. A row
/// there opens through [onOpen], and "See all" pushes the Notifications page.
class ShellNotificationsBell extends StatelessWidget {
  const ShellNotificationsBell({
    required this.remote,
    required this.onOpen,
    super.key,
  });

  /// The active server's notifications, for the preview.
  final NotificationRemoteDataSource remote;

  /// Opens what a notification is about: pushes its page, and completes
  /// with the push's future, which a router drop may never complete. The
  /// preview doesn't wait on it: it removes itself once the page it opened
  /// covers it. It must not throw.
  final Future<void> Function(BuildContext context, NotificationTarget target)
  onOpen;

  @override
  Widget build(BuildContext context) {
    if (!BgeNavigationMenu.isSectionTop(context)) {
      return const SizedBox.shrink();
    }
    // Whether there is a count at all, which the bell reads and can't do
    // without. The bell follows one count to the next by itself; this hears
    // the count come and go, as a page the shell's navigator carries from
    // one session's host to the next moves.
    final counted = context.select<NotificationCountCubit?, bool>(
      (count) => count != null,
    );
    if (!counted) return const SizedBox.shrink();
    return NotificationsBell(onPressed: () => _openPreview(context));
  }

  void _openPreview(BuildContext context) {
    final count = context.read<NotificationCountCubit>();
    final router = GoRouter.of(context);
    unawaited(
      showNotificationsPreview(
        context,
        remote: remote,
        count: count,
        onOpen: onOpen,
        // A push, which the preview needs: the page it opens removes it once
        // it has arrived, so Back from the page lands here.
        onSeeAll: () => unawaited(router.push<void>(AppRoutes.notifications)),
      ),
    );
  }
}
