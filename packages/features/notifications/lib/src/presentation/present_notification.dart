import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/data_gateway_presenter.dart';
import 'package:notifications/src/presentation/household_presenter.dart';
import 'package:notifications/src/presentation/notification_presentation.dart';
import 'package:notifications/src/presentation/username_variant_presenter.dart';

/// Words [notification] for its row (#475). Never throws.
///
/// A type this version doesn't know, or a payload missing a field the
/// wording needs, gives a plain row: the server sends new kinds of
/// notification before the client knows them, and one it can't read must
/// never fail the list.
NotificationPresentation presentNotification(
  NotificationsLocalizations l10n,
  UserNotification notification,
) {
  final payload = notification.payload;
  final presentation = switch (notification.type) {
    'HouseholdInviteReceived' => presentHouseholdInviteReceived(l10n, payload),
    'HouseholdInviteAwaitingApproval' => presentHouseholdInviteAwaitingApproval(
      l10n,
      payload,
    ),
    'HouseholdInviteAccepted' => presentHouseholdInviteAccepted(l10n, payload),
    'HouseholdInviteDeclined' => presentHouseholdInviteDeclined(l10n, payload),
    'HouseholdOwnershipTransferred' => presentHouseholdOwnershipTransferred(
      l10n,
      payload,
    ),
    'DataGatewayAutoDisabled' => presentDataGatewayAutoDisabled(l10n, payload),
    'DataGatewayCapabilitiesLost' => presentDataGatewayCapabilitiesLost(
      l10n,
      payload,
    ),
    'UsernameVariantAssigned' => presentUsernameVariantAssigned(l10n, payload),
    _ => null,
  };
  return presentation ?? _plain(l10n);
}

NotificationPresentation _plain(NotificationsLocalizations l10n) =>
    NotificationPresentation(
      icon: Icons.notifications_none,
      title: l10n.notificationUnknownTitle,
    );
