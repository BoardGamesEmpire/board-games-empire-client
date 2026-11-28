import 'package:flutter/material.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/notification_presentation.dart';
import 'package:notifications/src/presentation/notification_target.dart';
import 'package:notifications/src/presentation/payload_fields.dart';

// The DataGateway notifications (#475), sent to server admins. Both carry
// `gatewayId` and `gatewayName`. Each function returns null when a field its
// wording or target needs is missing or isn't a string, and
// `presentNotification` then shows a plain row. The gateway's name and the
// upstream's error go in as the server sent them.

/// `DataGatewayAutoDisabled`: repeated failures switched a DataGateway off.
/// Opens it. The `reason` code is worded; `lastError` is the upstream's own
/// text, so it is the quote, untranslated, and an error the page offers to
/// copy.
NotificationPresentation? presentDataGatewayAutoDisabled(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final gatewayId = nonBlankString(payload, 'gatewayId');
  final gatewayName = nonBlankString(payload, 'gatewayName');
  if (gatewayId == null || gatewayName == null) return null;
  return NotificationPresentation(
    icon: Icons.power_off_outlined,
    title: l10n.notificationDataGatewayAutoDisabledTitle(gatewayName),
    detail: switch (nonBlankString(payload, 'reason')) {
      'repeated_connection_failure' =>
        l10n.notificationDataGatewayConnectDetail,
      'repeated_call_failure' => l10n.notificationDataGatewayCallDetail,
      _ => l10n.notificationDataGatewayGenericDetail,
    },
    quote: nonBlankString(payload, 'lastError'),
    quoteIsError: true,
    target: DataGatewayTarget(gatewayId),
  );
}

/// `DataGatewayCapabilitiesLost`: a check found capabilities gone that the
/// server was routing. Opens the DataGateway, whose page lists them. The row
/// gives the count: the capabilities' names are the data_gateway package's,
/// which this one doesn't depend on.
NotificationPresentation? presentDataGatewayCapabilitiesLost(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final gatewayId = nonBlankString(payload, 'gatewayId');
  final gatewayName = nonBlankString(payload, 'gatewayName');
  final lost = payload['lostCapabilities'];
  if (gatewayId == null || gatewayName == null || lost is! List<Object?>) {
    return null;
  }
  final count = lost
      .where((item) => item is String && item.trim().isNotEmpty)
      .length;
  return NotificationPresentation(
    icon: Icons.extension_off_outlined,
    title: l10n.notificationDataGatewayCapabilitiesLostTitle(gatewayName),
    detail: count == 0
        ? null
        : l10n.notificationDataGatewayCapabilitiesLostDetail(count),
    target: DataGatewayTarget(gatewayId),
  );
}
