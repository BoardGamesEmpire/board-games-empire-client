import 'package:equatable/equatable.dart';

import 'package:models/src/domain/notification/unread_notification.dart';

/// Why the server could not send mail (#807).
enum MailFailure {
  notConfigured,
  settingsUnreadable,
  authFailed,
  hostUnreachable,
  tlsFailed,
  rejected,
  sendFailed,

  /// A code this client does not know.
  unknown;

  /// Resolves the server's failure code, degrading to [unknown].
  static MailFailure fromWire(String code) => switch (code) {
    'MAIL_NOT_CONFIGURED' => MailFailure.notConfigured,
    'MAIL_SETTINGS_UNREADABLE' => MailFailure.settingsUnreadable,
    'MAIL_AUTH_FAILED' => MailFailure.authFailed,
    'MAIL_HOST_UNREACHABLE' => MailFailure.hostUnreachable,
    'MAIL_TLS_FAILED' => MailFailure.tlsFailed,
    'MAIL_REJECTED' => MailFailure.rejected,
    'MAIL_SEND_FAILED' => MailFailure.sendFailed,
    _ => MailFailure.unknown,
  };
}

/// The outcome of a test email, delivered as a notification (#807).
final class MailTestResult extends Equatable {
  const MailTestResult({
    required this.sent,
    required this.failure,
    required this.message,
  });

  /// The notification type that carries a test result.
  static const String notificationType = 'MailTestResult';

  /// Whether the mail went out.
  final bool sent;

  /// Why it did not; null when [sent].
  final MailFailure? failure;

  /// The server's own text, shown only for a failure this client does not
  /// know.
  final String message;

  /// Reads [notification] as a test result, or null when it is another type
  /// or its payload is not one this client understands.
  static MailTestResult? fromNotification(UnreadNotification notification) {
    if (notification.type != notificationType) {
      return null;
    }
    final payload = notification.payload;
    final outcome = payload['outcome'];
    final message = payload['message'];
    if (message is! String) {
      return null;
    }
    switch (outcome) {
      case 'sent':
        return MailTestResult(sent: true, failure: null, message: message);
      case 'failed':
        final code = payload['code'];
        return MailTestResult(
          sent: false,
          failure: code is String
              ? MailFailure.fromWire(code)
              : MailFailure.unknown,
          message: message,
        );
      default:
        return null;
    }
  }

  @override
  List<Object?> get props => [sent, failure, message];
}
