import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/data_gateway_presenter.dart';
import 'package:notifications/src/presentation/event_presenter.dart';
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
    'EventCreated' => presentEventCreated(l10n, payload),
    'EventReopened' => presentEventReopened(l10n, payload),
    'EventCancelled' => presentEventCancelled(l10n, payload),
    'EventDeleted' => presentEventDeleted(l10n, payload),
    'EventAttendeeRemoved' => presentEventAttendeeRemoved(l10n, payload),
    'EventRsvpReceived' => presentEventRsvpReceived(l10n, payload),
    'EventRsvpChanged' => presentEventRsvpChanged(l10n, payload),
    'EventInviteReceived' => presentEventInviteReceived(l10n, payload),
    'EventInviteAccepted' => presentEventInviteAccepted(l10n, payload),
    'EventInviteDeclined' => presentEventInviteDeclined(l10n, payload),
    'EventOccurrenceProposed' => presentEventDateChange(
      l10n,
      payload,
      EventDateChange.proposed,
    ),
    'EventOccurrenceConfirmed' => presentEventDateChange(
      l10n,
      payload,
      EventDateChange.confirmed,
    ),
    'EventOccurrenceDeclined' => presentEventDateChange(
      l10n,
      payload,
      EventDateChange.declined,
    ),
    'EventOccurrenceCanceled' => presentEventDateChange(
      l10n,
      payload,
      EventDateChange.canceled,
    ),
    'EventOccurrenceRescheduled' => presentEventDateChange(
      l10n,
      payload,
      EventDateChange.rescheduled,
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
