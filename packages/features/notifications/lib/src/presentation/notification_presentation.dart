import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';
import 'package:notifications/src/presentation/notification_target.dart';

/// How a row shows one notification (#475): an icon, a title, and at most a
/// line of detail and a quote, worded from the notification's type and
/// payload.
final class NotificationPresentation extends Equatable {
  const NotificationPresentation({
    required this.icon,
    required this.title,
    this.detail,
    this.quote,
    this.quoteIsError = false,
    this.target,
  });

  final IconData icon;
  final String title;

  /// A second line, in the app's words.
  final String? detail;

  /// Text the server wrote, shown as it came and never translated.
  final String? quote;

  /// Whether [quote] is an error message, such as a DataGateway's upstream
  /// error (#545). The Notifications page offers to copy one, so a server
  /// admin can look it up or report it on any platform.
  final bool quoteIsError;

  /// What the row opens. Null makes the row plain: it opens nothing, and
  /// the user can only mark it read.
  final NotificationTarget? target;

  @override
  List<Object?> get props => [icon, title, detail, quote, quoteIsError, target];
}
