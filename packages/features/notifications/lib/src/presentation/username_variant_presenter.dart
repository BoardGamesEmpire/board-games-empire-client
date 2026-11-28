import 'package:flutter/material.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/notification_presentation.dart';
import 'package:notifications/src/presentation/payload_fields.dart';

// The username-variant notification (#633, #475): a first sign-in through a
// provider brought a username another account had, so the server gave the
// nearest free one. Both usernames are user data and go in as the server
// sent them.

/// `UsernameVariantAssigned`: names the username the account got and the one
/// that was taken. Returns null when either isn't a string with more than
/// whitespace in it, and `presentNotification` then shows a plain row.
///
/// The detail follows `usernameChangeAllowed`, and only `true` says the user
/// can change it: a missing or non-bool value takes the cautious wording. The
/// target is null, so the row opens nothing and the user can only mark it
/// read. Changing a username is #1145, which gives this row its action.
NotificationPresentation? presentUsernameVariantAssigned(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final username = nonBlankString(payload, 'username');
  final requestedUsername = nonBlankString(payload, 'requestedUsername');
  if (username == null || requestedUsername == null) return null;
  return NotificationPresentation(
    icon: Icons.alternate_email,
    title: l10n.notificationUsernameVariantAssignedTitle(
      username,
      requestedUsername,
    ),
    detail: payload['usernameChangeAllowed'] == true
        ? l10n.notificationUsernameVariantAssignedChangeAllowedDetail
        : l10n.notificationUsernameVariantAssignedChangeNotAllowedDetail,
  );
}
