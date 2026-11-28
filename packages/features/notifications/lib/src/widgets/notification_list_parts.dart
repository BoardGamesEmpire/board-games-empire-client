/// What the two surfaces that list notifications share (#475): the
/// Notifications page and the bell's preview. Each gives these its own key,
/// for its tests.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/list/notification_list_bloc.dart';
import 'package:notifications/src/list/notification_list_state.dart';
import 'package:ui/ui.dart';

/// The read of the notifications failed, and there is nothing else to show,
/// with Try again: the offline wording for a [NotificationListFailure]
/// that a retry may cure, and the server's refusal for one it won't.
class NotificationsLoadFailed extends StatelessWidget {
  const NotificationsLoadFailed({
    required this.failure,
    required this.onRetry,
    super.key,
  });

  final NotificationListFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = NotificationsLocalizations.of(context);
    final refused = failure == NotificationListFailure.permanent;
    return BgeErrorState(
      icon: refused ? Icons.error_outline : Icons.cloud_off_outlined,
      title: l10n.notificationsLoadFailed,
      body: refused
          ? l10n.notificationsLoadFailedRefusedBody
          : l10n.notificationsLoadFailedOfflineBody,
      retryLabel: l10n.notificationsRetry,
      onRetry: onRetry,
    );
  }
}

/// The server holds no notifications for the user, read or not.
class NotificationsEmptyState extends StatelessWidget {
  const NotificationsEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = NotificationsLocalizations.of(context);
    return BgeEmptyState(
      icon: Icons.notifications_none_outlined,
      title: l10n.notificationsEmptyTitle,
      body: l10n.notificationsEmptyBody,
    );
  }
}

/// Marks every notification the user holds read, loaded or not, with no
/// confirmation: nothing is lost.
///
/// Busy ([markingAll]), it stays enabled and keeps focus, and its name says
/// it is marking, so a keyboard or screen reader user who pressed it stays
/// where they were (STYLE_GUIDE §5). Offline it is disabled, and says why,
/// as a direct write does.
class NotificationsMarkAllReadButton extends StatelessWidget {
  const NotificationsMarkAllReadButton({
    required this.markingAll,
    required this.onPressed,
    super.key,
  });

  final bool markingAll;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = NotificationsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final label = markingAll
        ? l10n.notificationsMarkingAllRead
        : l10n.notificationsMarkAllRead;

    return Column(
      mainAxisSize: MainAxisSize.min,
      // The reason lines up with the button's end, as the button does with
      // the list's.
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        BgeOnlineOnly(
          showNote: false,
          child: BgeInertButton(
            inert: markingAll,
            label: label,
            onPressed: offline ? null : onPressed,
            builder: (context, focusNode, onPressed) => TextButton.icon(
              focusNode: focusNode,
              onPressed: onPressed,
              icon: const Icon(Icons.done_all),
              label: Text(label),
            ),
          ),
        ),
        if (offline) const BgeOnlineOnlyNote(),
      ],
    );
  }
}

/// Hears what each Mark all read answers, and moves focus as the button
/// goes, for a surface that shows a failure in a banner of its own (#475).
///
/// - A failure goes to [onFailed], which shows it.
/// - One that worked retires the failure shown, through [onRetired].
/// - So does a list with nothing [unread] left while a failure shows: a row
///   opened or marked read, or a refresh. There is then nothing for Mark all
///   read to mark, and it has gone.
///
/// Once nothing is unread, the button goes in the next frame, and focus in
/// [button], the group around it, waits on [heading] instead.
///
/// [bloc] is the list's, or null for the one in context.
class NotificationsMarkAllAnswers extends StatelessWidget {
  const NotificationsMarkAllAnswers({
    required this.showingFailure,
    required this.unread,
    required this.button,
    required this.heading,
    required this.onFailed,
    required this.onRetired,
    required this.child,
    this.bloc,
    super.key,
  });

  final NotificationListBloc? bloc;

  /// Whether a failure shows now. A function, so that a state that comes
  /// before the surface has rebuilt reads what it set.
  final bool Function() showingFailure;

  /// Whether a row the surface shows is unread in [NotificationListState].
  final bool Function(NotificationListState state) unread;

  final FocusNode button;
  final FocusNode heading;
  final ValueChanged<MarkAllFailed> onFailed;
  final VoidCallback onRetired;
  final Widget child;

  void _answered(BuildContext context, NotificationListState state) {
    final outcome = state.outcome;
    if (outcome is MarkAllFailed) {
      onFailed(outcome);
      return;
    }
    if (showingFailure()) onRetired();
    // Nothing left unread: Mark all read goes in the next frame.
    if (!unread(state) && button.hasFocus) heading.requestFocus();
  }

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<NotificationListBloc, NotificationListState>(
        bloc: bloc,
        listenWhen: (previous, current) =>
            previous.markingAll && !current.markingAll,
        listener: _answered,
      ),
      BlocListener<NotificationListBloc, NotificationListState>(
        bloc: bloc,
        listenWhen: (previous, current) =>
            showingFailure() && !current.markingAll && !unread(current),
        listener: (context, state) => onRetired(),
      ),
    ],
    child: child,
  );
}
